#!/usr/bin/env python3
"""
Stop hook: 종료된 세션을 Haiku API로 분석하여 기억할 만한 정보를 추출.
다음 세션 시작 시 Claude가 pending/ 항목 파일을 읽고 메모리를 업데이트한다.
pending 큐 위치는 memory/ 밖(HOOK_DIR) — harness canonicalize 회피(Fix B).
"""
import errno
import fcntl
import json
import os
import re
import sys
import time
import urllib.request
import uuid
from datetime import datetime, timedelta

# pending frontmatter 파서 (top-level + harness 노드스키마 dual-schema).
# import 실패 시 구 top-level 동작으로 폴백 → Stop hook 을 절대 막지 않는다.
try:
    from pending_schema import pending_status
except Exception as _e:
    sys.stderr.write(f"[extract_pending] pending_schema import 실패 → top-level 폴백: {_e}\n")
    def pending_status(text):
        m = re.search(r"^status:\s*(\w+)", text or "", re.M)
        return m.group(1) if m else None

# 모든 hook 운영상태(pending 큐 + analyzed 캐시 + 락/retry)는 indexed memory/ 밖,
# hook 디렉터리(HOOK_DIR)에 모은다 (Fix B + 후속1, 2026-05-30).
# 이유: harness 메모리 인덱서가 projects/.../memory/ 의 .md frontmatter 를 노드 스키마로
# canonicalize 해 pending 의 top-level `status:` 가 nested 로 바뀌면 카운터/회귀가드가
# 놓치는 latent 손실(알림 누락·완료항목 회귀)을 원천 차단. analyzed_sessions.json 은
# .json 이라 canonicalize 대상은 아니지만 hook 운영상태를 한 곳에 모으는 일관성을 위해
# 함께 이전(후속1, 사용자 요청). projects/.../memory/ 는 이제 순수 지식(.md)만 남는다.
HOOK_DIR = os.path.dirname(os.path.realpath(__file__))  # 플러그인 스크립트 위치(읽기전용 캐시)
if HOOK_DIR not in sys.path:
    sys.path.insert(0, HOOK_DIR)
import cc_paths
STATE_DIR = cc_paths.STATE_DIR              # 런타임 상태(영속): pending/analyzed/log 는 여기에
PENDING_DIR = cc_paths.PENDING_DIR          # 항목별 ack 큐 (status: new/applied/skipped)
ANALYZED_FILE = cc_paths.ANALYZED_FILE      # 세션 분석 캐시 (어느 sid 를 분석했나)
# 동시성 (개선5 / Codex audit #5): analyzed_sessions.json 은 모든 활성 세션이
# 매 턴 Stop hook 으로 read-modify-write 하는 공유 파일이다. 락 없는 전체 overwrite 는
# 두 세션이 "기억할 내용 있는" 턴의 load→save 창(중간에 Haiku 수 초)을 거의 동시에
# 끝낼 때 나중 저장이 상대의 done 마커를 덮어쓴다(lost update, 테스트로 재현됨).
LOCK_FILE = ANALYZED_FILE + ".lock"
# 락 타임아웃 시 결과 유실 방지용 per-entry 원자 파일 큐. 단일 append 파일 대신
# 파일 하나당 항목 하나(tmp→fsync→rename)라 append/rename 경합·부분쓰기가 없다.
RETRY_DIR = ANALYZED_FILE + ".retry.d"
LOCK_TIMEOUT = 5.0  # Stop hook 30s 예산 안. 락 보유 구간은 작은 JSON I/O 뿐이라 실제 대기는 ms.
MAX_ANALYZED = 200  # 이 수를 넘으면 저장 시 cleanup
# 같은 sid 충돌 시 우선순위 (file_size 는 jsonl 단조 증가라 1차 기준).
_STATUS_RANK = {"done": 2, "skipped": 1}

MIN_USER_MESSAGES = 3
MAX_CONVERSATION_CHARS = 15000
# analyzed_sessions.json 보관 기간 (일)
RETENTION_DAYS = 90


LOG_FILE = cc_paths.DEBUG_LOG
MAX_LOG_SIZE = 100000  # 100KB

def log(msg):
    try:
        os.makedirs(os.path.dirname(LOG_FILE), exist_ok=True)
    except Exception:
        pass
    # 로그 크기 제한
    if os.path.exists(LOG_FILE) and os.path.getsize(LOG_FILE) > MAX_LOG_SIZE:
        try:
            with open(LOG_FILE, "r") as f:
                lines = f.readlines()
            with open(LOG_FILE, "w") as f:
                f.writelines(lines[-100:])  # 최근 100줄만 유지
        except Exception:
            pass
    with open(LOG_FILE, "a") as f:
        f.write(f"{datetime.now().isoformat()} {msg}\n")

def get_session_from_stdin():
    """stdin에서 hook 데이터를 읽어 세션 ID와 JSONL 경로 반환"""
    try:
        raw = sys.stdin.read()
        log(f"stdin raw length: {len(raw)}")
        if not raw.strip():
            log("stdin is empty")
            return None, None
        data = json.loads(raw)
        sid = data.get("session_id", "")
        transcript = data.get("transcript_path", "")
        log(f"parsed: sid={sid[:12]}... transcript={transcript[:60] if transcript else 'none'}")
        if sid and transcript and os.path.exists(transcript):
            return sid, transcript
        log(f"transcript not found: {transcript}")
    except Exception as e:
        log(f"stdin parse error: {e}")
    return None, None


def extract_conversation(jsonl_path):
    """JSONL에서 사용자+어시스턴트 대화를 추출"""
    messages = []
    user_count = 0
    try:
        # errors="ignore": Stop-hook-race 로 멀티바이트(한글)가 flush 경계서 잘려도
        # UnicodeDecodeError 로 바깥 except 에 빠져 거짓 too_short 를 만들지 않게 한다(C2a).
        # session_context.py 의 reader 와 동일 정책.
        with open(jsonl_path, "r", encoding="utf-8", errors="ignore") as f:
            for line in f:
                try:
                    data = json.loads(line)
                    msg = data.get("message", {})
                    if not isinstance(msg, dict):
                        continue
                    role = msg.get("role", data.get("type", ""))
                    content = msg.get("content", "")

                    text = ""
                    if isinstance(content, str):
                        text = content.strip()
                    elif isinstance(content, list):
                        parts = []
                        for part in content:
                            if isinstance(part, dict) and part.get("type") == "text":
                                parts.append(part["text"].strip())
                        text = " ".join(parts).strip()

                    if not text:
                        continue

                    # 시스템 태그 제거
                    text = re.sub(r"<system-reminder>.*?</system-reminder>", "", text, flags=re.DOTALL).strip()
                    text = re.sub(r"<local-command-caveat>.*?</local-command-caveat>", "", text, flags=re.DOTALL).strip()
                    text = re.sub(r"<command-\w+>.*?</command-\w+>", "", text, flags=re.DOTALL).strip()
                    text = re.sub(r"<local-command-stdout>.*?</local-command-stdout>", "", text, flags=re.DOTALL).strip()
                    if not text:
                        continue

                    if role in ("human", "user"):
                        if re.match(r"^#\s+\w+.*Skill", text):
                            continue
                        messages.append(f"사용자: {text}")
                        user_count += 1
                    elif role == "assistant":
                        messages.append(f"Claude: {text}")
                except (json.JSONDecodeError, KeyError):
                    continue
    except Exception:
        return [], 0

    return messages, user_count


def redact_secrets(text):
    """Haiku 외부 API 전송 전 시크릿/식별성 높은 토큰 마스킹 (Codex 10축 audit #1).
    대화 원문에 키·토큰·비밀번호가 섞일 수 있어 외부 송신 전 제거. 의료 PII는
    프롬프트 지시로도 막지만, 명백한 시크릿 패턴은 여기서 결정적으로 제거."""
    if not text:
        return text
    t = re.sub(r'([A-Za-z0-9_]*(?:KEY|TOKEN|SECRET|PASSWORD|PASSWD|BEARER|APIKEY)[A-Za-z0-9_]*\s*[=:]\s*)\S+',
               r'\1[REDACTED]', text, flags=re.I)
    t = re.sub(r'(Authorization\s*:?\s*)(Bearer\s+)?\S+', r'\1[REDACTED]', t, flags=re.I)
    t = re.sub(r'\b(sk|pk|rk|ghp|gho|xox[baprs]|AKIA|AIza)[-_A-Za-z0-9]{16,}\b', '[REDACTED]', t)
    # 긴 토큰/해시: 하이픈/언더스코어 없는 40자+ 연속 영숫자 AND 영문·숫자 혼합만.
    # (readable-slug·snake_case_long_name 같은 사람 친화 식별자는 구분자 때문에 제외)
    t = re.sub(r'\b(?=[A-Za-z0-9]*[0-9])(?=[A-Za-z0-9]*[A-Za-z])[A-Za-z0-9]{40,}\b', '[REDACTED]', t)
    # standalone base64 (라벨 없는 토큰, 24자+, 영문+숫자 혼합). 하이픈/언더스코어가 없는
    # 연속 base64 run만 — readable slug(really-long-words)는 하이픈 때문에 제외됨.
    t = re.sub(r'(?<![A-Za-z0-9+/=\-_])(?=[A-Za-z0-9+/]*[0-9])(?=[A-Za-z0-9+/]*[A-Za-z])[A-Za-z0-9+/]{24,512}={0,2}(?![A-Za-z0-9+/=\-_])',
               '[REDACTED]', t)
    t = re.sub(r'([?&](?:token|key|secret|sig|access_token|api_key)=)[^&\s]+', r'\1[REDACTED]', t, flags=re.I)
    return t


def build_conversation_text(messages):
    """대화 텍스트를 MAX_CONVERSATION_CHARS 이내로 구성."""
    full = "\n".join(messages)
    if len(full) <= MAX_CONVERSATION_CHARS:
        return full

    front_limit = int(MAX_CONVERSATION_CHARS * 0.4)
    back_limit = MAX_CONVERSATION_CHARS - front_limit - 50

    front = []
    front_len = 0
    for msg in messages:
        if front_len + len(msg) > front_limit:
            break
        front.append(msg)
        front_len += len(msg) + 1

    back = []
    back_len = 0
    for msg in reversed(messages):
        if back_len + len(msg) > back_limit:
            break
        back.insert(0, msg)
        back_len += len(msg) + 1

    return "\n".join(front) + "\n\n[... 중간 생략 ...]\n\n" + "\n".join(back)


def _egress_consented():
    """발행 안전 불변식: 외부 egress 는 setup wizard 동의·설치 완료 후에만.
    플러그인 plugin.json 은 defaultEnabled=true 라 설치 직후 Stop hook 이 로드된다.
    동의(GOVERNANCE §8 체크리스트) 전에 세션 본문이 Anthropic API 로 나가는 것을
    이 게이트가 막는다 — /cockpit-setup(install --apply) 이 STATE_DIR/setup_complete
    마커를 쓴 뒤에만 추출 egress 허용. 마법사 없이 쓰는 고급 사용자는 그 마커를 직접
    touch 해 명시 opt-in 한다(rollback 은 마커를 제거 → egress 다시 OFF). 키 부재와
    동일하게 (None, False) 폴백이라 로컬 메모리 시스템 동작에는 영향 없음."""
    try:
        return os.path.exists(os.path.join(STATE_DIR, "setup_complete"))
    except Exception:
        return False


def analyze_with_haiku(conversation_text, session_summary=""):
    """Haiku API로 세션에서 기억할 만한 정보 추출.
    반환: (text, truncated) — text 는 추출 결과 문자열(실패 시 None),
    truncated 는 stop_reason=="max_tokens" 여부(C1 침묵 절단 식별)."""
    if not _egress_consented():
        return None, False  # 동의·설치 완료 전 egress 금지(발행 불변식). 키 부재 폴백과 동일.
    api_key = os.environ.get("ANTHROPIC_API_KEY_FOR_SCRIPTS", os.environ.get("ANTHROPIC_API_KEY", ""))
    if not api_key:
        return None, False  # 호출부가 (result, truncated) 로 언팩 — 키 없을 때도 2-tuple 유지(C1)

    context = f"세션 제목: {session_summary}\n\n" if session_summary else ""

    body = json.dumps({
        "model": "claude-haiku-4-5-20251001",
        "max_tokens": 2000,
        "messages": [{
            "role": "user",
            "content": (
                "아래는 사용자와 Claude 간의 대화 기록이야.\n"
                "이 대화에서 **향후 대화에 도움이 될 정보**를 추출해줘.\n\n"
                "추출 대상:\n"
                "- 사용자의 역할, 직업, 기술 수준에 대한 새로운 정보\n"
                "- 사용자의 선호도나 작업 스타일 (예: '확인 후 실행', '간결한 답변 선호')\n"
                "- 진행 중인 프로젝트의 중요한 결정사항이나 변경점\n"
                "- 사용자가 명시적으로 '기억해' 또는 유사한 요청을 한 내용\n"
                "- 진행 중인 프로젝트의 결정·완료·보류·번복 상태 (어느 프로젝트의 무엇이 끝났는지/막혔는지)\n"
                "- 외부 시스템/서비스의 설정 정보 (서비스명·용도·URL 정도. 키/토큰/비밀번호 값은 적지 말 것)\n\n"
                "추출 제외 (보안·법규):\n"
                "- API 키·토큰·비밀번호·접속 자격증명 값 — 절대 적지 말 것 (존재 여부만 언급 가능)\n"
                "- 환자 식별정보·의료 개인정보 등 민감정보 — 적지 말 것\n"
                "- 코드 구현 세부사항 (코드에서 직접 확인 가능)\n"
                "- 일회성 디버깅/오류 해결 과정\n"
                "- 이미 코드나 설정 파일에 반영된 내용\n\n"
                "기억할 만한 정보가 없으면 '없음'이라고만 답해.\n"
                "있으면 각 항목을 '- ' 로 시작하는 간결한 문장으로 나열해.\n\n"
                f"{context}"
                f"---\n{conversation_text}"
            )
        }]
    }).encode("utf-8")

    req = urllib.request.Request(
        "https://api.anthropic.com/v1/messages",
        data=body,
        headers={
            "Content-Type": "application/json",
            "x-api-key": api_key,
            "anthropic-version": "2023-06-01",
        },
    )

    try:
        with urllib.request.urlopen(req, timeout=30) as resp:
            result = json.loads(resp.read().decode("utf-8"))
            truncated = result.get("stop_reason") == "max_tokens"  # C1: 침묵 절단 감지
            for block in result.get("content", []):
                if block.get("type") == "text":
                    return block["text"].strip(), truncated
    except Exception:
        pass
    return None, False


def load_analyzed():
    if os.path.exists(ANALYZED_FILE):
        try:
            with open(ANALYZED_FILE, "r") as f:
                raw = json.load(f)
        except (json.JSONDecodeError, IOError):
            return {}
        # 레거시 문자열 항목을 dict로 정규화.
        # 구버전은 값이 "done" 같은 문자열이었음 → cleanup_analyzed / main()의
        # .get() 호출에서 AttributeError가 났다. 빈 ts는 다음 cleanup 때 자연히 걸러짐.
        normalized = {}
        for k, v in raw.items():
            if isinstance(v, dict):
                normalized[k] = v
            else:
                normalized[k] = {"status": str(v), "ts": "", "file_size": 0}
        return normalized
    return {}


def _acquire_lock(fd, timeout=LOCK_TIMEOUT):
    """fcntl.flock(LOCK_EX) 를 timeout 내 폴링 획득. 성공 True / 타임아웃 False.
    수제 lockfile(존재 여부 검사) 대신 OS flock 사용 — 프로세스가 죽으면 fd close
    로 자동 해제되어 stale lock 이 남지 않는다."""
    deadline = time.monotonic() + timeout
    while True:
        try:
            fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
            return True
        except OSError as e:
            # 락 경합(EAGAIN/EWOULDBLOCK/EACCES — 플랫폼별 flock LOCK_NB 경합 errno)만
            # 재시도. EBADF·I/O·FS 오류 등 진짜 실패는 5초 은폐하지 말고 즉시 False
            # (상위가 retry.d 보존, Codex 10축 #6).
            if e.errno not in (errno.EAGAIN, errno.EWOULDBLOCK, errno.EACCES):
                log(f"_acquire_lock unexpected error (errno={e.errno}): {e}")
                return False
            if time.monotonic() >= deadline:
                return False
            time.sleep(0.05)


def _fsync_dir(path):
    """디렉터리 엔트리(rename/create) 를 영속화. crash durability (Codex #8).
    best-effort — 일부 FS/플랫폼에서 디렉터리 fsync 미지원 시 실패는 무시(원자성은 유지)."""
    try:
        dfd = os.open(path, os.O_RDONLY)
        try:
            os.fsync(dfd)
        finally:
            os.close(dfd)
    except OSError:
        pass


def _atomic_write_analyzed(data):
    """tmp → fsync → rename → dir fsync 로 analyzed_sessions.json 원자적 교체.
    rename 은 같은 파일시스템에서 원자적이라 부분 쓰기/깨진 JSON 이 노출되지 않는다."""
    tmp = ANALYZED_FILE + ".tmp"
    with open(tmp, "w", encoding="utf-8") as f:
        json.dump(data, f, indent=2, ensure_ascii=False)
        f.flush()
        os.fsync(f.fileno())
    os.replace(tmp, ANALYZED_FILE)
    _fsync_dir(STATE_DIR)


def _merge_entry(old, new):
    """같은 sid 충돌 시 더 '강하고 최신'인 entry 선택 (Codex #4·#5).
    jsonl 은 단조 증가하므로 file_size 큰 쪽이 더 진전된 분석 → 1차 기준.
    동률이면 done > skipped, 그래도 동률이면 ts 늦은 쪽."""
    if not isinstance(old, dict):
        return new
    o_sz, n_sz = old.get("file_size", 0), new.get("file_size", 0)
    if n_sz != o_sz:
        return new if n_sz > o_sz else old
    o_rank = _STATUS_RANK.get(old.get("status"), 0)
    n_rank = _STATUS_RANK.get(new.get("status"), 0)
    if n_rank != o_rank:
        return new if n_rank > o_rank else old
    return new if new.get("ts", "") >= old.get("ts", "") else old


def _quarantine_retry(fp):
    """깨진/형식불명 retry 파일을 corrupt/ 로 격리 (무한 적체·매-hook 재시도 방지, Codex r2 G).
    락 보유 중 호출되며 커밋과 무관(파싱 불가한 garbage). 파일명에 uuid 가 있어 corrupt/ 내
    basename 충돌은 사실상 없음 — 만일 있으면 os.replace 가 덮어쓴다(적체 방지 우선).
    **격리 성공 시에만** 루트에서 사라진다. 격리 실패 시엔 임의 삭제하지 않고 보존+로그
    (검사 불가한 데이터를 말없이 지우지 않음, Codex 10축 r3) — 다음 hook 에서 재시도.
    어느 경우에도 consumed 에는 넣지 않는다."""
    try:
        bad = os.path.join(RETRY_DIR, "corrupt")
        os.makedirs(bad, exist_ok=True)
        os.replace(fp, os.path.join(bad, os.path.basename(fp)))
        log(f"_drain_retry quarantined corrupt retry file: {os.path.basename(fp)}")
    except OSError as e:
        log(f"_quarantine_retry FAILED (kept, will retry): {os.path.basename(fp)}: {e}")


def _write_retry(sid, entry):
    """락 타임아웃 시 결과 유실 방지: retry.d/ 에 per-entry 원자 파일 기록 (tmp→fsync→rename).
    단일 append 파일이 아니라 항목당 1파일이라 append/rename 경합·부분쓰기가 없다(Codex #2·#3·#6).
    다음 성공 save 또는 drain_pending_retry 가 락 안에서 흡수한다."""
    try:
        created = not os.path.isdir(RETRY_DIR)
        os.makedirs(RETRY_DIR, exist_ok=True)
        if created:
            _fsync_dir(STATE_DIR)  # 새 디렉터리 엔트리 영속화 (Codex r2 #8)
        # 파일명: sanitized sid prefix(디버깅용) + uuid(고유성). 권위 sid 는 JSON 본문에 보존.
        # raw sid 를 파일명에 직접 넣으면 '/'·'..'·과길이로 경로 이탈/쓰기 실패 위험(Codex r2 #2new).
        safe = re.sub(r"[^A-Za-z0-9_.-]", "_", sid)[:48] or "sid"
        fp = os.path.join(RETRY_DIR, f"{safe}.{uuid.uuid4().hex}.json")
        tmp = fp + ".tmp"
        with open(tmp, "w", encoding="utf-8") as f:
            json.dump({sid: entry}, f, ensure_ascii=False)
            f.flush()
            os.fsync(f.fileno())
        os.replace(tmp, fp)
        _fsync_dir(RETRY_DIR)
        return True
    except Exception as e:
        log(f"_write_retry FAILED for {sid[:12]}: {e}")
        return False


def _drain_retry(disk):
    """retry.d/*.json 을 disk 에 merge 흡수 (반드시 락 보유 중 호출).
    소비한 파일 경로 리스트를 반환 — 호출자가 **atomic write 성공 후** 삭제해야 한다
    (커밋 전 삭제 시 그 사이 crash 면 양쪽에서 유실, Codex #1).
    깨진/형식불명 파일은 corrupt/ 로 격리해 무한 적체를 막는다(Codex r2 G)."""
    consumed = []
    if not os.path.isdir(RETRY_DIR):
        return consumed
    try:
        names = sorted(os.listdir(RETRY_DIR))  # uuid 정렬(순서 무의미, 안정적)
    except OSError:
        return consumed
    for nm in names:
        if not nm.endswith(".json"):
            continue  # .tmp(진행중)·corrupt(디렉터리) 는 건너뜀
        fp = os.path.join(RETRY_DIR, nm)
        try:
            with open(fp, "r", encoding="utf-8") as f:
                obj = json.load(f)
        except Exception:
            _quarantine_retry(fp)  # 깨진 파일 격리(소비 X, 데이터 없음)
            continue
        # 형식 검증: {str sid: dict entry} 여야 한다. JSON 은 맞지만 value 가 dict 가
        # 아니면(예: {sid: "bad"}) _merge_entry 의 .get 에서 예외 → 매 hook 크래시 +
        # 그 파일이 영영 안 지워져 drain 영구 실패. 그래서 형식 불명은 격리(Codex 10축 #1).
        if not isinstance(obj, dict) or not all(
            isinstance(k, str) and isinstance(v, dict) for k, v in obj.items()
        ):
            _quarantine_retry(fp)
            continue
        for k, v in obj.items():
            disk[k] = _merge_entry(disk.get(k), v)
        consumed.append(fp)
    return consumed


def _locked_commit(mutate, force_write, on_timeout=None):
    """공유 락 critical section: LOCK_EX 획득 → 디스크 최신본 재-read → retry 흡수 →
    mutate(disk) → (>MAX 면 cleanup 후 재-mutate) → atomic write → 소비한 retry 삭제.

    - 락은 이 I/O 구간에만. Haiku 호출 등 느린 작업은 호출자에서 이미 끝났다.
    - 재-read 로 load 이후 타 세션 추가분을 보존(merge, lost-update 제거).
    - force_write=False 이고 흡수/변경 없으면 디스크 안 건드림(drain-only 무동작).
    - 타임아웃 시 on_timeout() 후 False.
    - 계약: mutate 는 **순수·멱등**해야 한다(cleanup 전후 2회 호출됨, Codex r2 F)."""
    os.makedirs(STATE_DIR, exist_ok=True)
    lock_fd = os.open(LOCK_FILE, os.O_CREAT | os.O_RDWR, 0o644)
    try:
        if not _acquire_lock(lock_fd):
            if on_timeout:
                on_timeout()
            return False
        try:
            disk = load_analyzed()
            consumed = _drain_retry(disk)
            mutate(disk)
            if not (force_write or consumed):
                return True  # drain-only 인데 흡수할 게 없음
            if len(disk) > MAX_ANALYZED:
                # cleanup 은 90일(RETENTION_DAYS) 경과 항목만 제거(의도된 retention).
                # 타 세션의 done 도 90일 넘으면 제거되나 그건 정책이고, 재mutate 로
                # '이번 sid' 는 항상 보존한다(Codex 10축 #5: 현재 대상만 보존 설계).
                disk = cleanup_analyzed(disk)
                mutate(disk)
            _atomic_write_analyzed(disk)
            # 커밋 성공 후에야 retry 파일 삭제 (Codex #1).
            for fp in consumed:
                try:
                    os.remove(fp)
                except OSError as e:
                    # 삭제 실패 시 다음 hook 에서 재흡수됨(merge 로 멱등). 가시성 위해 로그.
                    log(f"retry remove failed (will re-absorb): {os.path.basename(fp)}: {e}")
            if consumed:
                _fsync_dir(RETRY_DIR)
                log(f"drained {len(consumed)} retry entry(s)")  # 적체 가시성 (Codex 10축 #9)
            return True
        finally:
            fcntl.flock(lock_fd, fcntl.LOCK_UN)
    finally:
        os.close(lock_fd)


def save_analyzed(sid, entry):
    """단일 세션 결과를 flock 보호 하에 merge 기록 (lost-update 제거 / 개선5).
    같은 sid 충돌은 _merge_entry 로 더 진전된 분석을 보존한다. 타임아웃 시 retry.d 보존.
    성공 True / 타임아웃 False."""
    def mutate(disk):
        disk[sid] = _merge_entry(disk.get(sid), entry)

    def on_timeout():
        _write_retry(sid, entry)
        log(f"LOCK TIMEOUT {LOCK_TIMEOUT}s — queued retry for {sid[:12]}")

    return _locked_commit(mutate, force_write=True, on_timeout=on_timeout)


def drain_pending_retry():
    """retry.d 에 쌓인 항목을 본체에 흡수 (early-skip 으로 save 미도달 시 적체 방지, Codex #7).
    흡수할 .json 이 없으면(통상) 락도 잡지 않는다. 타임아웃이면 로그 후 다음 기회로 미룬다."""
    try:
        if not any(n.endswith(".json") for n in os.listdir(RETRY_DIR)):
            return  # corrupt/ 서브디렉터리·.tmp 만 있으면 흡수 대상 아님
    except OSError:
        return  # retry.d 자체가 없으면 listdir 가 OSError → 무동작
    _locked_commit(lambda disk: None, force_write=False,
                   on_timeout=lambda: log(f"drain_pending_retry: LOCK TIMEOUT {LOCK_TIMEOUT}s, deferred"))


def cleanup_analyzed(data):
    """오래된 항목 정리"""
    cutoff = (datetime.now() - timedelta(days=RETENTION_DAYS)).isoformat()
    return {k: v for k, v in data.items() if v.get("ts", "") >= cutoff}


def get_session_summary(sid):
    """summaries.json에서 세션 제목 가져오기.
    summaries.json 은 claude-logs convert_session.py 가 (동시성 보호 없이) 쓰므로,
    부분 쓰기 순간과 겹치면 json.load 가 깨질 수 있다 → 짧게 read-retry(C6, 최대 ~0.2s)
    후에도 실패하면 ""(무해 — 제목 없이 진행). 절대 예외를 올리지 않는다(Stop hook 비차단)."""
    summaries_path = cc_paths.SUMMARIES_PATH
    if not os.path.exists(summaries_path):
        return ""
    for attempt in range(3):
        try:
            with open(summaries_path) as f:
                summaries = json.load(f)
        except (json.JSONDecodeError, OSError):
            # 비원자 쓰기와 겹친 부분 읽기 가능 → 짧게 재시도 후 ""
            if attempt < 2:
                time.sleep(0.1)
                continue
            return ""
        except Exception:
            return ""
        # 파싱 성공: 값 추출은 재시도 대상 아님(dict면 title 키)
        val = summaries.get(sid, "")
        if isinstance(val, dict):
            return val.get("title", "")
        return str(val)
    return ""


def wait_transcript_stable(path, checks=3, delay=0.15):
    """Stop hook 은 transcript 최종 flush 전에 발화할 수 있다(stop-hook-race,).
    파일 크기가 안정될 때까지 짧게 폴링(최대 ~checks*delay≈0.45s)해 마지막 턴 누락을 완화한다(C5).
    절대 예외를 올리지 않는다 — Stop hook 을 막지 않기 위함. errors="ignore"(C2a)와 조합해
    race 의 두 결함(거짓 too_short + 마지막 턴 누락)을 reader 측에서 직접 줄인다."""
    try:
        prev = -1
        for _ in range(checks):
            cur = os.path.getsize(path)
            if cur == prev:
                return
            prev = cur
            time.sleep(delay)
    except Exception:
        return


def _run():
    log("=== extract_pending.py started ===")
    sid, path = get_session_from_stdin()
    if not sid or not path:
        log("no session from stdin, exiting")
        return

    log(f"session: {sid[:12]}... path: {path}")

    if sid.startswith("agent-"):
        log("agent session, skipping")
        return

    # 이전 락 타임아웃으로 적체된 retry 항목 흡수 (이 hook 이 early-skip 으로
    # save 에 안 닿아도 retry 가 영구 미흡수되지 않도록, Codex #7). 통상 무비용.
    drain_pending_retry()

    # 스킵 판정용 advisory read. 권위 있는 기록은 save_analyzed() 가 락 안에서
    # 디스크를 재-read 해 merge 하므로(>200 cleanup 포함) 여기선 락이 필요 없다.
    analyzed = load_analyzed()

    wait_transcript_stable(path)   # C5: Stop-hook-race 완화 — transcript 크기 안정화 후 read
    current_size = os.path.getsize(path)

    if sid in analyzed:
        prev = analyzed[sid]
        # C2a(b): 구버전 reader(errors="ignore" 없음)가 UnicodeDecodeError 를 거짓 too_short 로
        # 고착시킨 기록을 1회 재검증한다. decode_mode 마커 없는 too_short 는 size-skip 을 건너뛰고
        # 재분석한 뒤 마커를 남겨(아래 too_short save) 적체된 오판만 회수한다. 진짜 짧으면 다시 pin
        # 되고 그 땐 마커가 있어 재검증 안 됨 → 영구 churn 없음.
        # status=="skipped" 도 함께 확인(방어적, Codex 4f): reason 은 skipped 에만 붙지만
        # 비정상/레거시 레코드가 done+reason:too_short 여도 size-skip 을 우회하지 않게 한다.
        stale_too_short = (prev.get("status") == "skipped"
                           and prev.get("reason") == "too_short"
                           and not prev.get("decode_mode"))
        if stale_too_short:
            log(f"re-analyzing stale too_short (no decode_mode marker): {prev.get('file_size')} -> {current_size}")
        else:
            prev_size = prev.get("file_size", 0)
            if prev_size > 0:
                size_diff = current_size - prev_size
                change_ratio = size_diff / prev_size
                # 최소 변화량: 30KB 이상 AND 20% 이상 (C2b: floor 100KB→30KB.
                # 중간 크기 dense 변경이 100KB 문턱 미달로 영영 미재분석되던 갭 차단).
                if size_diff < 30000 or change_ratio < 0.2:
                    log(f"skipping: insufficient change ({prev_size} -> {current_size}, diff={size_diff}, {change_ratio:.1%})")
                    return
            elif current_size == prev_size:
                log(f"already analyzed, same size ({current_size})")
                return
            log(f"re-analyzing: size changed {prev_size} -> {current_size}")

    messages, user_count = extract_conversation(path)
    log(f"extracted: {user_count} user messages, {len(messages)} total")

    if user_count < MIN_USER_MESSAGES:
        # decode_mode 마커: errors="ignore" reader 로 정상 추출했음에도 짧음을 뜻한다(진짜 too_short).
        # 마커 없는 기존 too_short(구버전 reader)는 위 stale_too_short 로 1회 재검증된다(C2a).
        save_analyzed(sid, {"status": "skipped", "reason": "too_short", "ts": datetime.now().isoformat(), "file_size": current_size, "decode_mode": "utf8_ignore_v2"})
        return

    conversation_text = redact_secrets(build_conversation_text(messages))
    summary = get_session_summary(sid)
    result, truncated = analyze_with_haiku(conversation_text, summary)
    # 로컬 pending 저장 전에도 결과를 2차 레닥션한다(defense-in-depth): 모델이 실수로
    # 대화 속 시크릿/식별 토큰을 요약에 옮겨도 디스크 영속본에 평문이 남지 않게.
    # (의료/PII 누출 방지는 프롬프트 지시 + 사용자의 비입력이 1차, 이건 backstop.)
    if result:
        result = redact_secrets(result)

    if result and "없음" not in result[:20]:
        # 항목별 ack 큐: 세션당 1파일. status: new → (다음 세션이 메모리 반영 후) applied.
        # 단일 pending_analysis.md 통째 비우기 방식이 유발하던 유실·중복·누락을 제거.
        _pdir_created = not os.path.isdir(PENDING_DIR)
        os.makedirs(PENDING_DIR, exist_ok=True)
        if _pdir_created:
            _fsync_dir(STATE_DIR)  # 새 pending/ 디렉터리 엔트리 영속화 (cold-start durability, _write_retry 와 동일 패턴)
        # .rN cleanup (Codex audit): applied/skipped + RETENTION_DAYS 경과한 리비전 정리.
        try:
            cutoff_ts = (datetime.now() - timedelta(days=RETENTION_DAYS)).timestamp()
            for nm in os.listdir(PENDING_DIR):
                if not re.search(r"\.r\d+\.md$", nm):
                    continue
                fp = os.path.join(PENDING_DIR, nm)
                try:
                    with open(fp, "r", encoding="utf-8") as cf:
                        h = cf.read(400)
                    st = pending_status(h)
                    if st in ("applied", "skipped") and os.path.getmtime(fp) < cutoff_ts:
                        arch = os.path.join(PENDING_DIR, "_legacy_archive")
                        os.makedirs(arch, exist_ok=True)
                        os.replace(fp, os.path.join(arch, nm))
                except Exception:
                    continue
        except Exception:
            pass
        safe_summary = redact_secrets((summary or "").replace("\n", " ").replace("\r", " ").strip())
        now = datetime.now().isoformat()
        item_path = os.path.join(PENDING_DIR, f"{sid}.md")
        # 재분석 회귀 방지: 이미 applied/skipped 처리된 항목을 status:new로 되돌리지 않는다.
        # 기존 항목이 new가 아니면 새 리비전 파일(sid.rN.md)로 분리 생성.
        if os.path.exists(item_path):
            try:
                with open(item_path, "r", encoding="utf-8") as rf:
                    head = rf.read(400)
                st = pending_status(head)
                if st and st != "new":
                    n = 2
                    while os.path.exists(os.path.join(PENDING_DIR, f"{sid}.r{n}.md")):
                        n += 1
                    item_path = os.path.join(PENDING_DIR, f"{sid}.r{n}.md")
            except Exception:
                pass
        item_id = os.path.basename(item_path)[:-3]
        # tmp → rename 으로 원자적 기록 (동시 종료 세션 간 부분쓰기 방지)
        tmp_path = item_path + ".tmp"
        with open(tmp_path, "w", encoding="utf-8") as f:
            f.write("---\n")
            f.write(f"id: {item_id}\n")
            f.write("status: new\n")
            f.write(f"source_session: {sid}\n")
            f.write(f"created_at: {now}\n")
            if safe_summary:
                f.write(f"summary: {safe_summary}\n")
            f.write("reflected_at:\n")
            if truncated:
                f.write("truncated: true\n")  # C1: Haiku max_tokens 절단 식별(재처리 대상)
            f.write("---\n\n")
            header = f"## 세션: {sid[:8]}"
            if safe_summary:
                header += f" — {safe_summary}"
            header += f" ({datetime.now().strftime('%Y-%m-%d %H:%M')})"
            f.write(header + "\n")
            f.write(result + "\n")
            if truncated:
                f.write("\n> ⚠️ 이 추출은 Haiku 토큰 한도(max_tokens)에서 잘렸을 수 있습니다. "
                        "꼬리 항목이 누락됐을 수 있으니 필요 시 원본 세션을 확인하세요. (C1 절단 마커)\n")
            f.flush()
            os.fsync(f.fileno())          # crash durability (analyzed.json 과 동일 패턴, 2026-05-30 후속2)
        os.replace(tmp_path, item_path)
        _fsync_dir(PENDING_DIR)           # rename 엔트리 영속화 (best-effort, _fsync_dir 은 미지원 FS 시 무시)
        entry = {"status": "done", "ts": datetime.now().isoformat(), "file_size": current_size}
    else:
        entry = {"status": "skipped", "reason": "nothing_notable", "ts": datetime.now().isoformat(), "file_size": current_size}

    save_analyzed(sid, entry)


def main():
    """최상위 비차단 래퍼(Phase 5, Codex 발견). `_run()` 의 getsize·pending 파일쓰기·락
    open/save 등에서 새는 예외를 흡수해, Stop hook 이 어떤 경우에도 세션을 막지 않게 한다
    (공통 불변식 '절대 차단 안 함' 완성 — 내부 함수 다수가 방어적이나 최상위 보장은 없었다).
    실패 로그조차 실패하면 무시한다."""
    try:
        _run()
    except Exception as e:
        try:
            log(f"main() FATAL (ignored, non-blocking): {e}")
        except Exception:
            pass


if __name__ == "__main__":
    main()
