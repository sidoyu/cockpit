#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
transcript_watcher.py — 세션 트랜스크립트 감시 데몬 (알림 없음·로그+차기 세션 주입).

목적: hook 이 잡지 못하는 **AUP 차단·일부 API 에러**를 transcript(.jsonl)에서 감지한다.
동윤 환경의 launchd 30초 데몬(+Pushover)을 배포판용으로 **재설계**:
  - 서비스 매니저 불요: SessionStart 훅(watcher_launch.py)이 기동, transcript 유휴 시 **자가 종료**.
  - 단일 인스턴스: lockfile(원자적 mkdir + PID 생존 검사)로 중복 기동 방지(G19).
  - 출력 = **알림 없음**. (a) 로그(watcher.log·로테이션) + (b) findings.jsonl →
    다음 SessionStart 에서 session_context 가 읽어 "지난 세션 차단/에러 N건"으로 주입.
  - 개인정보 최소화: findings 에는 **분류(category)·파일명·시각만** 남기고 에러 본문은 저장하지 않는다
    (다음 세션 컨텍스트/로그로 세션 내용이 새는 것 방지).
  - 크로스플랫폼(WSL/Linux/macOS): stat -f/-c 분기 대신 os.stat, jq/md5 대신 json/hashlib.

상태 위치는 플러그인 캐시(읽기전용)가 아니라 CC_STATE_DIR/watcher/ (cc_paths 단일 출처).
어떤 예외도 데몬을 통째로 죽이지 않도록 방어한다(개별 파일 오류는 건너뜀).
"""
import os, sys, json, time, re, hashlib, glob
try:
    import fcntl  # POSIX advisory lock(WSL/Linux/macOS). 없으면 best-effort 폴백.
except Exception:
    fcntl = None

# ── 상태 위치(플러그인 밖·영속) ──
sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "memory"))
try:
    import cc_paths  # type: ignore
    _STATE_BASE = cc_paths.STATE_DIR
except Exception:
    _STATE_BASE = os.path.realpath(os.path.expanduser(
        os.environ.get("CC_STATE_DIR") or "~/.claude/cc-companion"))

WATCHER_DIR = os.path.join(_STATE_BASE, "watcher")
LOCK_FILE   = os.path.join(WATCHER_DIR, "watcher.lock")   # O_EXCL 단일파일 락(내용="pid ts")
LOG_FILE    = os.path.join(WATCHER_DIR, "watcher.log")
FINDINGS    = os.path.join(WATCHER_DIR, "findings.jsonl") # session_context 가 소비
OFFSET_DIR  = os.path.join(WATCHER_DIR, "offsets")

TRANSCRIPTS_ROOT = os.path.expanduser(os.environ.get("CC_TRANSCRIPTS_ROOT") or "~/.claude/projects")

# ── 튜닝(env override) ──
SCAN_INTERVAL   = int(os.environ.get("CC_WATCH_INTERVAL", 30))       # 스캔 주기(초)
IDLE_EXIT_SEC   = int(os.environ.get("CC_WATCH_IDLE_EXIT", 900))     # transcript 무활동 N초 → 자가종료
ACTIVE_WIN_SEC  = int(os.environ.get("CC_WATCH_ACTIVE_WIN", 3600))   # "활성 세션" 판정 창(초)
RECENT_DAYS     = int(os.environ.get("CC_WATCH_RECENT_DAYS", 7))     # 1차 cull
LOG_MAX_BYTES   = int(os.environ.get("CC_WATCH_LOG_MAX", 262_144))   # 로그 로테이션 임계(256KB)
FINDINGS_MAX_BYTES = int(os.environ.get("CC_WATCH_FINDINGS_MAX_BYTES", 131_072))  # findings 폭주 상한(바이트)
MAX_RUNTIME_SEC = int(os.environ.get("CC_WATCH_MAX_RUNTIME", 43_200))  # 절대 상한(12h) 백스톱
INITIAL_SCAN_MAX = int(os.environ.get("CC_WATCH_INITIAL_MAX", 524_288))  # 첫 관측 파일이 이 이하면 0부터 스캔(새 세션 초기에러 포착), 초과면 baseline
LOCK_STALE_AGE  = MAX_RUNTIME_SEC + 300  # 락이 이보다 오래되면 pid 생존과 무관하게 stale(정상 워처는 MAX_RUNTIME 에 자가종료)

ERR_RE = re.compile(r'"isApiErrorMessage"\s*:\s*true')


def _log(msg):
    try:
        os.makedirs(WATCHER_DIR, exist_ok=True)
        # 로테이션: 임계 초과 시 .1 로 1회 회전(단일 백업)
        try:
            if os.path.getsize(LOG_FILE) > LOG_MAX_BYTES:
                os.replace(LOG_FILE, LOG_FILE + ".1")
        except OSError:
            pass
        ts = time.strftime("%Y-%m-%d %H:%M:%S")
        with open(LOG_FILE, "a", encoding="utf-8") as f:
            f.write(f"{ts} {msg}\n")
    except Exception:
        pass


# ── 단일 인스턴스 락(원자적 mkdir·PID 생존 기준 탈취) ──
def _pid_alive(pid):
    try:
        os.kill(pid, 0)
        return True
    except OSError:
        return False
    except Exception:
        return True  # 판정 불가 시 보수적으로 살아있다고 봄


STARTUP_GRACE = 30  # 락 생성 직후 pid 기록 gap 동안 다른 기동자를 뺏지 않는 유예(초)


def _lock_owner_age():
    """(owner_pid, age_sec). 파일 없음/파싱불가 → owner=0."""
    try:
        age = time.time() - os.stat(LOCK_FILE).st_mtime
    except OSError:
        return 0, 1e9
    try:
        with open(LOCK_FILE) as f:
            parts = f.read().split()
        return (int(parts[0]) if parts else 0), age
    except Exception:
        return 0, age


def acquire_lock():
    """O_EXCL 단일파일 락. **죽은 소유자 or 오래된 빈 락만** 회수(파괴적 탈취 방지)."""
    os.makedirs(WATCHER_DIR, exist_ok=True)
    for _ in range(2):
        try:
            fd = os.open(LOCK_FILE, os.O_CREAT | os.O_EXCL | os.O_WRONLY, 0o600)
            os.write(fd, f"{os.getpid()} {int(time.time())}".encode())
            os.close(fd)
            return True
        except FileExistsError:
            owner, age = _lock_owner_age()
            if age > LOCK_STALE_AGE:
                pass                         # 아주 오래된 락 = 확실히 stale(PID 재사용 오판 백스톱·발견7)
            elif owner and _pid_alive(owner):
                return False                 # 다른 인스턴스 가동 중
            elif owner == 0 and age < STARTUP_GRACE:
                return False                 # 다른 기동자가 pid 기록 직전(gap) — 뺏지 않음
            try:
                os.remove(LOCK_FILE)         # 죽은 소유자 or 오래된/빈 락 → 회수 후 재시도
            except OSError:
                return False
        except Exception:
            return False
    return False


def release_lock():
    try:
        owner, _ = _lock_owner_age()
        if owner == os.getpid():             # 내 락일 때만 제거(타 인스턴스 오삭제 방지)
            os.remove(LOCK_FILE)
    except Exception:
        pass


# ── 분류 ──
def classify(text):
    t = text or ""
    if re.search(r"Usage Policy|AUP", t):
        return "AUP"
    if re.search(r"5[0-9]{2}|Internal server error", t):
        return "5xx"
    if re.search(r"rate.?limit|429", t, re.I):
        return "RateLimit"
    if re.search(r"401|unauthorized|invalid api key", t, re.I):
        return "Auth"
    if re.search(r"timeout|timed out", t, re.I):
        return "Timeout"
    if re.search(r"context|too many tokens|200K", t, re.I):
        return "Context"
    return "API"


def _state_key(path):
    try:
        ino = os.stat(path).st_ino
    except OSError:
        ino = 0
    h = hashlib.sha256(path.encode("utf-8", "ignore")).hexdigest()[:12]
    return f"{h}.{ino}"


def _read_offset(key):
    """오프셋. 미관측(파일 없음)=None, 관측됨=int."""
    try:
        with open(os.path.join(OFFSET_DIR, key + ".off")) as f:
            return int(f.read().strip() or 0)
    except FileNotFoundError:
        return None
    except Exception:
        return None


def _write_offset(key, val):
    try:
        os.makedirs(OFFSET_DIR, exist_ok=True)
        p = os.path.join(OFFSET_DIR, key + ".off")
        tmp = p + ".tmp"
        with open(tmp, "w") as f:
            f.write(str(val))
        os.replace(tmp, p)
    except Exception:
        pass


def _append_finding(rec):
    """findings 에 append. 소비자(session_context)와 **같은 advisory lock** 아래에서
    크기 판정+쓰기 → rename/truncate 경합에도 유실·중복 없음(발견2·3). fcntl 없으면 best-effort."""
    try:
        os.makedirs(WATCHER_DIR, exist_ok=True)   # 첫 감지가 offset write 보다 먼저일 수 있음
        with open(FINDINGS, "a", encoding="utf-8") as f:
            if fcntl is not None:
                fcntl.flock(f.fileno(), fcntl.LOCK_EX)
            try:
                if os.fstat(f.fileno()).st_size >= FINDINGS_MAX_BYTES:
                    return  # 폭주 상한 — 이번 건 생략(락 아래 판정이라 소비자 truncate 와 정합)
                f.write(json.dumps(rec, ensure_ascii=False) + "\n")
                f.flush()
            finally:
                if fcntl is not None:
                    try:
                        fcntl.flock(f.fileno(), fcntl.LOCK_UN)
                    except Exception:
                        pass
    except Exception:
        pass


def _extract_text(o):
    """message.content 에서 에러 본문 텍스트 추출(분류용·저장 안 함)."""
    try:
        m = o.get("message") or {}
        c = m.get("content")
        if isinstance(c, list):
            return " ".join(str(x.get("text", "")) for x in c if isinstance(x, dict))[:2000]
        if isinstance(c, str):
            return c[:2000]
    except Exception:
        pass
    return ""


def process_file(f):
    """파일의 새 바이트만 스캔해 에러 라인을 findings 로. **완성된(개행 종료) 라인만** 처리하고
    오프셋도 마지막 개행까지만 **처리 후** 커밋(부분 라인 유실 방지·발견5)."""
    key = _state_key(f)
    prev = _read_offset(key)     # None = 미관측
    try:
        cur = os.path.getsize(f)
    except OSError:
        return
    if prev is None:
        # 첫 관측: 작은(=최근 새 세션) 활성 파일은 0부터 스캔(초기 에러 포착·발견1),
        # 이미 큰 파일은 과거 이력 → baseline(홍수 방지).
        if cur <= INITIAL_SCAN_MAX:
            prev = 0
        else:
            _write_offset(key, cur)
            return
    else:
        if cur < prev:           # truncate/rotate → baseline
            _write_offset(key, cur)
            return
        if cur <= prev:
            return
    try:
        with open(f, "rb") as fh:
            fh.seek(prev)
            chunk = fh.read()
    except OSError:
        return
    nl = chunk.rfind(b"\n")
    if nl < 0:
        return                    # 완성된 라인 없음(부분 라인만) — 오프셋 미전진, 다음 사이클
    text = chunk[:nl + 1].decode("utf-8", "ignore")
    for line in text.split("\n"):
        if not ERR_RE.search(line):
            continue
        try:
            o = json.loads(line)
        except Exception:
            continue
        if not isinstance(o, dict) or o.get("isApiErrorMessage") is not True:
            continue             # parse 후 실제 필드 값 확인(발견4: substring 오탐/공백 차단)
        cat = classify(_extract_text(o))
        rec = {"ts": int(time.time()), "category": cat, "file": os.path.basename(f)}
        _append_finding(rec)
        _log(f"detected cat={cat} file={os.path.basename(f)}")
    _write_offset(key, prev + nl + 1)   # 마지막 완성 라인까지만 커밋(처리 후)


def scan_once():
    """활성 transcript 스캔. 반환=가장 최근 transcript 수정 시각(유휴 판정용)."""
    latest_mtime = 0.0
    now = time.time()
    try:
        files = glob.glob(os.path.join(TRANSCRIPTS_ROOT, "*", "*.jsonl"))
    except Exception:
        files = []
    for f in files:
        try:
            mt = os.path.getmtime(f)
        except OSError:
            continue
        if now - mt > RECENT_DAYS * 86400:
            continue  # 오래된 세션 무시
        if mt > latest_mtime:
            latest_mtime = mt
        if now - mt <= ACTIVE_WIN_SEC:
            process_file(f)  # 활성 세션만 실제 스캔
    # offset 정리: 오래된 것 제거
    try:
        for off in glob.glob(os.path.join(OFFSET_DIR, "*.off")):
            if now - os.path.getmtime(off) > RECENT_DAYS * 86400:
                os.remove(off)
    except Exception:
        pass
    return latest_mtime


def main():
    if not acquire_lock():
        return  # 다른 인스턴스 가동 중 — 조용히 종료
    started = time.time()
    _log(f"watcher start pid={os.getpid()}")
    try:
        while True:
            latest = scan_once()
            now = time.time()
            # 유휴 자가종료: 최근 활동 없음 → 종료(다음 SessionStart 가 재기동)
            if latest and (now - latest) > IDLE_EXIT_SEC:
                _log("idle exit")
                break
            if not latest and (now - started) > IDLE_EXIT_SEC:
                _log("no transcripts, idle exit")
                break
            if (now - started) > MAX_RUNTIME_SEC:
                _log("max runtime backstop exit")
                break
            time.sleep(SCAN_INTERVAL)
    except Exception:
        pass
    finally:
        release_lock()


if __name__ == "__main__":
    try:
        main()
    except SystemExit:
        raise
    except Exception:
        try:
            release_lock()
        except Exception:
            pass
