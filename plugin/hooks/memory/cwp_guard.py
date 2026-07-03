#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""cwp_guard.py — CWP Stage 3 guard (보호 기억파일 쓰기 차단 + 경고, fail-open).

멀티세션 공유 기억파일(PROJECT_STATUS·MEMORY·memory/**.md) 동시쓰기 보호.
Stage 2(경고-only, 11일 832건 관찰) → Stage 3(차단) 전환. 정책 4결정(2026-06-10 사용자 확정):
  P1 seen 없는 Write = 기존 파일 한정 차단(신규 생성 허용)
  P2 override = 플래그 파일(cwp_state/override.flag, TTL 5분, 내용=경로 substring scope) + 감사로그 필수
  P3 fail-open 유지 + 내부오류 시 경고(additionalContext) + guard_err.log
  P4 path-중심 최소 락(단일 도구호출 구간, Pre 획득→Post 해제) + agent 계측 보강
  P5 Bash = 차단 범위 밖(휴리스틱 오탐 ~65%) — 경고-only 유지 + cmd 마스킹(REDACT) 저장 추가
  P6 잔여 liveness 경고 = 다른 *활성*(대화턴 30분) 세션 있을 때만(Stage2 idle 과경고 97% 해소)

차단 매트릭스(보호 .md × 쓰기도구 한정 — 그 외 어떤 경로도 deny 없음):
  D1 Write & 기존 파일 & seen 없음/sentinel → DENY (blind overwrite, P1)
  D2 쓰기도구 & seen-cur 해시 불일치(stale read) 또는 seen 있는데 파일 소실 → DENY (회복=Read 재시도, 수렴)
  D3 path 락을 타 holder 보유(not stale) → DENY (병렬 서브에이전트 포함)
  ※ Edit/MultiEdit no-seen(기존 파일) = 경고+계측만(no_seen_edit) — P1 확정범위가 Write 한정이라
    차단 확장은 측정 데이터 확보 후 별도 결정(Stage3 Codex 검토 #1, 2026-06-10).
  ※ override 유효 시 D1·D2 만 허용 강등 + decision="override" 감사로그(P2). D3(락)은 override 미적용 —
    진행 중인 실제 쓰기 위로 강행하면 보호 목적 자체가 무력화(Codex 4b #2), 락은 TTL 내 자가 해소.

락(P4, Codex Stage3 검토 #2 ABA 보강):
  - owner = {path, sid, agent, ts, tic, lock_id}. tic = sha256(tool_input 정렬 JSON)[:16]
    → 같은 도구호출의 Pre/Post 가 프로세스 경계 너머로 자기 락을 식별(release 는 tic 일치 시만).
  - 획득 = unique tmp 에 owner 완성 기록 → os.link 2단 원자(부분기록 owner 방지) → tmp 제거.
  - stale 강 = owner sid 가 ps live 목록에 없음(즉시 회수) / 약 = age>TTL 180s(회수+로그).
  - self(동일 sid+agent): 동일 tic=동일 논리호출 재진입(크래시 재시도) → 즉시 회수.
    이종 tic & age<45s = 병렬 형제 호출 가능 → DENY / age≥45s = 직전 Post 미발화 크래시로 보고 회수.
  - corrupt owner: age<TTL 보유 취급(DENY·override 가능), age≥TTL 회수(Codex 합의: 차단=정책 결과지 오류 아님).
  - deny 호출 = 락 미획득. deny 후 PostToolUse 발화 여부는 문서 미정의 — release 가 owner(sid+agent+path+tic)
    일치 시만 unlink 라 발화/미발화 양쪽 안전. "락 없음/내 락 아님" = 정상 no-op(롤아웃 신구 혼재 안전).

agent 계측(P4, 882건 전부 빈 값이던 공백 보강): agent_id(기존) → transcript_path 가
agent-<id>.jsonl 이면 그 stem(인스턴스 식별자) → 없으면 "". agent_type 은 인스턴스 구분 불가
(동일 타입 병렬 혼동, Codex #3) → 계측 라벨(agent_label)로만 기록, 식별·키잉엔 미사용.
seen 키 = sid + ("__"+agent | "") — 서브에이전트는 자기 Read 기준으로 판정.

불변식: I-CWP-2(보호=realpath canonicalize) / I-CWP-3' (Stage3: deny 는 보호파일×쓰기도구만,
Read·Bash·SessionStart 경로는 영원히 비차단) / I-CWP-6(fail-open: 내부오류=exit0 통과+경고+err 로그).
운영상태 = hooks/memory/cwp_state/ (indexed memory/ 밖, I-CWP-1). seen/intent = append-only JSONL.
주의: intent.log 는 혼합 스키마(tool="rebuild_index" 레코드엔 cur_sha 등 없음) — 분석기는 tool/kind 분기.

테스트 전용 백도어(CWP_STATE_DIR + CWP_TEST_MODE=1 둘 다 있어야 활성): CWP_TEST_LIVE_SIDS·CWP_TEST_ACTIVE·CWP_TEST_RAISE.
설계서: 2026-05-30-cwp-phase0-design.md + cwp-living-review.md Stage3 결정로그. Stage2 백업: cwp_guard.py.stage2.bak
"""
import sys, os, json, re, time, hashlib, contextlib, traceback

_SHA_MAX = 5 * 1024 * 1024   # 5MB 초과 보호파일은 hash skip(타임아웃 방지). 기억파일은 <30KB.

HERE = os.path.dirname(os.path.realpath(__file__))
if HERE not in sys.path:
    sys.path.insert(0, HERE)
from cc_paths import MEMORY_DIR as PROJ_MEMORY, CWP_STATE
SEEN_DIR = os.path.join(CWP_STATE, "seen")
INTENT_LOG = os.path.join(CWP_STATE, "intent.log")
LOCK_DIR = os.path.join(CWP_STATE, "locks")
OVERRIDE_FLAG = os.path.join(CWP_STATE, "override.flag")
ERR_LOG = os.path.join(CWP_STATE, "guard_err.log")

LOCK_TTL = 180.0          # 약 stale: 단일 도구호출 락이라 보유는 수초가 정상 — 3분이면 확실한 잔존물
SELF_GRACE = 45.0         # self 이종-tic 락: 이 안이면 병렬 형제 호출 가능성 → deny
OVERRIDE_TTL = 300.0      # override.flag 유효창 5분(Codex #5: 전역 10분은 과대)
SEEN_COMPACT_BYTES = 64 * 1024
ERR_LOG_MAX = 256 * 1024
# 테스트 백도어 = 격리 state + 명시 플래그 둘 다 필요(Codex 4b #4: STATE_DIR 단독 게이트는 경계 약함)
_TEST_MODE = bool(os.environ.get("CWP_STATE_DIR")) and os.environ.get("CWP_TEST_MODE") == "1"

WRITE_TOOLS = {"Write", "Edit", "MultiEdit", "NotebookEdit"}
# Bash 휴리스틱(완전보장 불가 — design §4). 보호경로 토큰이 있을 때만 평가.
# F7(2026-06-19, Codex 4f): 쓰기 연산자가 '보호경로를 대상으로' 할 때만 발화하도록 좁힘.
#   과거 r"(>>?|...)" 는 2>/dev/null 의 '>' + 경로의 'memory/' 부분문자열이 *따로* 매치돼
#   읽기 명령마다 오경고(docstring 자인 ~65% FP). target-bound 결합으로 fd-redirect(2>,2>&1,&>)는
#   대상이 보호경로 아니면 자동 제외되고, 1>/2>/&>/>| 로 보호파일에 쓰는 진짜 쓰기는 포착.
#   실측: 읽기 오탐 4→0, 진짜 쓰기 놓침 1(install)→0, ReDoS 안전(20k자 0.4ms). lookbehind 불요(Codex).
_PROT_ALT = r"(?:memory/|PROJECT_STATUS\.md|MEMORY\.md)"
_BASH_WRITE_RE = re.compile(
    r">>?\|?\s*[^\s;|&]*" + _PROT_ALT                          # 리다이렉트(>,>>,>|) 대상이 보호경로
    + r"|\btee\b(?:\s+-\S+)*\s+[^|;&]*" + _PROT_ALT             # tee 대상
    + r"|\bsed\b\s+-i\S*\s+[^|;&]*" + _PROT_ALT                 # sed -i 대상
    + r"|\b(?:mv|cp|dd|truncate|install)\b[^|;&]*" + _PROT_ALT  # mv/cp/dd/truncate/install 인자에 보호경로
    + r"|(?:os\.replace|write_text|open)\s*\([^)]*" + _PROT_ALT  # python 쓰기(인자형)
    + r"|" + _PROT_ALT + r"[^\s;'\"|&)]*['\"]?\s*\)\s*\.(?:write_text|write_bytes)\s*\("  # pathlib 수신자형(Path(...PROT...).write_text(), Codex 4b)
)
_BASH_READ_RE = re.compile(r"\b(cat|less|more|head|tail|bat|grep|rg|ag|nl|view)\b")
_PROT_TOKENS = ("memory/", "PROJECT_STATUS.md", "MEMORY.md")

# REDACT(P5): ①알려진 키 prefix(레닥션 wrapper 의 REDACT_PAT 포팅, 보수적 superset 유지)
_KEY_PAT = re.compile(
    r"sk-proj-[A-Za-z0-9_-]{20,}|sk-ant-api03-[A-Za-z0-9_-]{20,}|sk-ant-[A-Za-z0-9_-]{20,}|"
    r"sk-[A-Za-z0-9]{20,}|AIza[A-Za-z0-9_-]{30,}|r8_[A-Za-z0-9]{30,}|xai-[A-Za-z0-9]{20,}|"
    r"ghp_[A-Za-z0-9]{30,}|glpat-[A-Za-z0-9_-]{20,}|AKIA[A-Z0-9]{16}")
_OV_HINT = "(의도적 강행: touch '%s' — 5분 유효·감사 기록됨)" % OVERRIDE_FLAG

_EVT = {"evt": None}   # 최상위 예외 핸들러가 '경고 JSON 을 내도 되는 이벤트인가' 판별용


def _emit(msg):
    """exit 0 + JSON(additionalContext) 로 **비차단** 경고. msg=None 이면 침묵 통과."""
    if msg:
        sys.stdout.write(json.dumps({
            "hookSpecificOutput": {
                "hookEventName": "PreToolUse",
                "permissionDecision": "allow",
                "additionalContext": msg,
            }
        }, ensure_ascii=False))
    sys.exit(0)


def _deny(msg):
    """Stage3 차단. reason+additionalContext 동시 기재(모델 피드백 경로 이중화). exit 0."""
    sys.stdout.write(json.dumps({
        "hookSpecificOutput": {
            "hookEventName": "PreToolUse",
            "permissionDecision": "deny",
            "permissionDecisionReason": msg,
            "additionalContext": msg,
        }
    }, ensure_ascii=False))
    sys.exit(0)


def _log_err(text):
    """guard 내부오류를 파일로만 기록(stdout 오염 금지, Codex #7). 256KB rotate."""
    try:
        os.makedirs(CWP_STATE, exist_ok=True)
        try:
            if os.path.getsize(ERR_LOG) > ERR_LOG_MAX:
                os.replace(ERR_LOG, ERR_LOG + ".1")
        except OSError:
            pass
        with open(ERR_LOG, "a", encoding="utf-8") as f:
            f.write("---- %s ----\n%s\n" % (time.strftime("%Y-%m-%d %H:%M:%S"), text))
        os.chmod(ERR_LOG, 0o600)
    except Exception:
        pass


def _canon(path):
    if not path:
        return ""
    try:
        return os.path.realpath(os.path.expanduser(path))
    except Exception:
        return ""


def is_protected(rp):
    return bool(rp) and rp.endswith(".md") and rp.startswith(PROJ_MEMORY + os.sep)


def _sha(rp):
    """sentinel 분리(Codex #4): MISSING=파일 없음 / ERROR=읽기 실패 / OVERSIZE=대용량 skip."""
    try:
        if os.path.getsize(rp) > _SHA_MAX:
            return "OVERSIZE"
        with open(rp, "rb") as f:
            return hashlib.sha256(f.read()).hexdigest()
    except FileNotFoundError:
        return "MISSING"
    except Exception:
        return "ERROR"


def _append_atomic(path, obj):
    """append-only JSONL. regular file O_APPEND 단일 write = contiguous append.
    한 줄 4096B 이상이면 깨진 JSONL 남기느니 그 줄을 버린다(valid-JSONL 불변식)."""
    try:
        os.makedirs(os.path.dirname(path), exist_ok=True)
        data = (json.dumps(obj, ensure_ascii=False) + "\n").encode("utf-8")
        if len(data) >= 4096:
            return
        fd = os.open(path, os.O_WRONLY | os.O_APPEND | os.O_CREAT, 0o600)
        try:
            os.write(fd, data)
        finally:
            os.close(fd)
    except Exception:
        pass   # 로깅 실패가 세션을 막지 않음(fail-open)


def _intent(rec):
    rec["ts"] = round(time.time(), 3)
    # cmd_red 등으로 한 줄 4096B 초과가 예상되면 통째 유실 대신 큰 필드만 탈락(Codex #6 fallback)
    try:
        if len((json.dumps(rec, ensure_ascii=False) + "\n").encode("utf-8")) >= 4000 and "cmd_red" in rec:
            rec.pop("cmd_red", None)
            rec["cmd_red_dropped"] = True
    except Exception:
        rec.pop("cmd_red", None)
    _append_atomic(INTENT_LOG, rec)


def _agent_identity(data):
    """(agent, agent_src). transcript stem(agent-<id>.jsonl)만 인스턴스 식별자로 신뢰(Codex #3).
    agent_type 은 동일 타입 병렬 구분 불가 → 식별자 아님(라벨로만 별도 기록)."""
    aid = (data.get("agent_id") or "").strip()
    if aid:
        return re.sub(r"[^A-Za-z0-9_-]", "", aid)[:16], "agent_id"
    tp = os.path.basename(data.get("transcript_path") or "")
    if tp.startswith("agent-") and tp.endswith(".jsonl"):
        return re.sub(r"[^A-Za-z0-9_-]", "", tp[6:-6])[:16], "transcript"
    return "", ""


def _seen_key(sid_full, agent):
    return sid_full + ("__" + agent if agent else "")


def _seen_lookup(key, rp):
    p = os.path.join(SEEN_DIR, key + ".jsonl")
    latest = None
    try:
        with open(p, "r") as f:
            for ln in f:
                try:
                    e = json.loads(ln)
                except Exception:
                    continue
                if e.get("path") == rp:
                    latest = e.get("sha")
    except Exception:
        return None
    return latest


def _compact_seen(p):
    """path 별 최신만 남기고 원자 재작성(Stage3 잔여항목: 장기 세션 seen 비대 방지).
    같은 seen 파일은 같은 sid+agent 만 쓰고 agent 단위 호출은 직렬 → append 경합 없음."""
    latest, order = {}, []
    with open(p, "r") as f:
        for ln in f:
            try:
                e = json.loads(ln)
            except Exception:
                continue
            k = e.get("path")
            if not k:
                continue
            if k not in latest:
                order.append(k)
            latest[k] = e
    if not latest:
        return
    tmp = p + ".tmp.%d" % os.getpid()
    with open(tmp, "w") as f:
        for k in order:
            f.write(json.dumps(latest[k], ensure_ascii=False) + "\n")
    os.chmod(tmp, 0o600)
    os.replace(tmp, p)


def _seen_record(key, rp, sha):
    p = os.path.join(SEEN_DIR, key + ".jsonl")
    _append_atomic(p, {"ts": round(time.time(), 3), "path": rp, "sha": sha})
    try:
        if os.path.getsize(p) > SEEN_COMPACT_BYTES:
            _compact_seen(p)
    except Exception:
        pass


def _liveness():
    """live claude 세션 full-uuid 집합. 단일출처 session_context.live_session_ids 재사용.
    테스트 백도어는 CWP_STATE_DIR(격리 state) 설정 시에만 읽음."""
    if _TEST_MODE:
        v = os.environ.get("CWP_TEST_LIVE_SIDS")
        if v is not None:
            if v == "!fail":
                return set(), False
            return {x.strip().lower() for x in v.split(",") if x.strip()}, True
    try:
        if HERE not in sys.path:
            sys.path.insert(0, HERE)
        with open(os.devnull, "w") as _dn, contextlib.redirect_stdout(_dn), contextlib.redirect_stderr(_dn):
            from session_context import live_session_ids
            return live_session_ids()
    except Exception:
        return set(), False


def _other_live(self_sid):
    ids, ok = _liveness()
    if not ok:
        return -1
    self_l = (self_sid or "").lower()
    return len([i for i in ids if i.lower() != self_l])


def _other_active(self_sid):
    """본인 외 *활성*(대화턴 30분 내) 동일프로젝트 세션 수. -1=불명. (P6 경고 좁힘)
    단일출처 session_context 의 후보열거+last_turn_ts 재사용(드리프트 방지)."""
    if _TEST_MODE:
        v = os.environ.get("CWP_TEST_ACTIVE")
        if v is not None:
            try:
                return int(v)
            except Exception:
                return -1
    try:
        if HERE not in sys.path:
            sys.path.insert(0, HERE)
        with open(os.devnull, "w") as _dn, contextlib.redirect_stdout(_dn), contextlib.redirect_stderr(_dn):
            from session_context import _enumerate_live_candidates, last_turn_ts
            cands, ps_ok, now, cutoff = _enumerate_live_candidates(self_sid, True)
            if not ps_ok:
                return -1
            return len([1 for _mt, _sid, full in cands if last_turn_ts(full) >= cutoff])
    except Exception:
        return -1


def _redact_cmd(cmd):
    """마스킹 → 절단 순서(Codex #6: 절단 먼저 하면 키가 중간에서 잘려 패턴 탐지를 피함).
    규칙은 session_context._redact 와 동일 계열(로컬 사본 = import 실패 시 raw 저장 위험 제거)."""
    s = cmd[:65536]
    s = _KEY_PAT.sub("[REDACTED-KEY]", s)
    s = re.sub(r'([A-Za-z0-9_]*(?:KEY|TOKEN|SECRET|PASSWORD|PASSWD|BEARER)[A-Za-z0-9_]*\s*[=:]\s*)\S+',
               r'\1[RED]', s, flags=re.I)
    s = re.sub(r'(Authorization\s*:?\s*)\S+', r'\1[RED]', s, flags=re.I)
    s = re.sub(r'\b[A-Za-z0-9_\-]{40,}\b', '[RED-LONG]', s)   # 40+: 32+ 는 긴 메모리 파일명까지 가려 분류가치 훼손
    s = re.sub(r'([?&](?:token|key|secret|sig|access_token)=)[^&\s]+', r'\1[RED]', s, flags=re.I)
    if len(s) > 1200:
        s = s[:1200] + "…[T]"
    return s


# ---------------- path 락 ----------------

def _lock_path(rp):
    return os.path.join(LOCK_DIR, hashlib.sha256(rp.encode("utf-8", "replace")).hexdigest()[:16] + ".lock")


def _read_owner(lp):
    """(owner dict | None=corrupt, age_sec | None=absent, stat | None).
    stat(ino+mtime_ns) = 회수 시 compare-unlink 용 동일성 식별자(Codex 4b #1 ABA)."""
    try:
        st = os.stat(lp)
    except OSError:
        return None, None, None
    age = max(0.0, time.time() - st.st_mtime)
    try:
        with open(lp, "r") as f:
            o = json.loads(f.read())
        if isinstance(o, dict):
            # owner.ts 가 mtime 보다 신뢰 가능하면 사용(링크 후 mtime 변조 없음 — 동일하게 동작)
            ts = o.get("ts")
            if isinstance(ts, (int, float)):
                age = max(0.0, time.time() - ts)
            return o, age, st
    except Exception:
        pass
    return None, age, st   # corrupt


def _unlink_if_same(lp, st):
    """stale 로 판정한 *그 파일*일 때만 회수(compare-unlink, Codex 4b #1).
    판정~삭제 사이에 holder 가 해제되고 제3자가 새 락(=새 inode/mtime_ns)을 만들었으면 건드리지 않는다.
    재stat~unlink 사이 잔여 TOCTOU 창은 µs 단위 — 실패해도 다음 attempt 가 새 owner 를 재평가."""
    try:
        cur = os.stat(lp)
        if st is not None and (cur.st_ino, cur.st_mtime_ns) == (st.st_ino, st.st_mtime_ns):
            os.unlink(lp)
    except OSError:
        pass


def _try_acquire(rp, sid_full, agent, tic):
    """('acquired'|'held'|'held_self'|'held_corrupt'|'skip_err', holder|None, age|None).
    회수(stale) 후 1회 재시도. unlink→link 사이 타 프로세스가 끼면 link 실패=held 로 수렴(안전)."""
    lp = _lock_path(rp)
    me = {"path": rp, "sid": sid_full, "agent": agent, "ts": round(time.time(), 3),
          "tic": tic, "lock_id": hashlib.sha256(os.urandom(16)).hexdigest()[:12]}
    try:
        os.makedirs(LOCK_DIR, exist_ok=True)
        for _attempt in (1, 2):
            tmp = lp + ".tmp.%d.%s" % (os.getpid(), me["lock_id"])
            fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
            try:
                os.write(fd, json.dumps(me, ensure_ascii=False).encode("utf-8"))
            finally:
                os.close(fd)
            try:
                os.link(tmp, lp)            # 2단 원자: 완성된 owner 만 락 이름으로 노출
                return "acquired", None, None
            except FileExistsError:
                pass
            finally:
                try:
                    os.unlink(tmp)
                except OSError:
                    pass
            owner, age, st = _read_owner(lp)
            if age is None:                  # 그 사이 해제됨 → 재시도
                continue
            if owner is None:                # corrupt owner(Codex 합의: TTL 까지 보유 취급)
                if age >= LOCK_TTL:
                    _unlink_if_same(lp, st)
                    continue
                return "held_corrupt", None, age
            ids, ok = _liveness()
            o_sid = (owner.get("sid") or "").lower()
            if ok and o_sid and o_sid not in ids:        # 강: holder 프로세스 사망 → 즉시 회수
                _unlink_if_same(lp, st)
                continue
            if age >= LOCK_TTL:                          # 약: TTL 초과 잔존물
                _unlink_if_same(lp, st)
                continue
            if owner.get("sid") == sid_full and owner.get("agent") == agent:
                if owner.get("tic") == tic or age >= SELF_GRACE:
                    _unlink_if_same(lp, st)              # 동일 논리호출 재진입 or 크래시 잔존 → 회수
                    continue
                return "held_self", owner, age           # 병렬 형제 호출 가능성 → deny
            return "held", owner, age
        return "held", None, None
    except Exception:
        _log_err("lock infra error:\n" + traceback.format_exc())   # Codex 4b #3: 조용한 보호 해제 금지
        return "skip_err", None, None   # 락 인프라 오류 = 락 단계 스킵(fail-open, 경고는 호출부)


def _safe_unlink(p):
    try:
        os.unlink(p)
    except OSError:
        pass


def _release(rp, sid_full, agent, tic):
    """owner(sid+agent+path+tic) 일치 시만 unlink — deny 후 Post 발화/신구 혼재 모두 정상 no-op."""
    lp = _lock_path(rp)
    try:
        owner, _age, st = _read_owner(lp)
        if owner and owner.get("sid") == sid_full and owner.get("agent") == agent \
                and owner.get("path") == rp and owner.get("tic") == tic:
            _unlink_if_same(lp, st)
    except Exception:
        pass


def _override_status(rp):
    """('ok'|'absent'|'stale'|'scope', age|None, matched_scope).
    내용이 비어있지 않으면 각 줄=경로 substring scope. matched_scope=빈문자열이면 전역 flag(Codex 4b #5 감사)."""
    try:
        st = os.stat(OVERRIDE_FLAG)
    except OSError:
        return "absent", None, ""
    age = max(0.0, time.time() - st.st_mtime)
    if age > OVERRIDE_TTL:
        return "stale", age, ""
    try:
        with open(OVERRIDE_FLAG, "r", encoding="utf-8", errors="ignore") as f:
            scopes = [ln.strip() for ln in f if ln.strip()]
    except Exception:
        scopes = []
    if scopes:
        m = next((s for s in scopes if s in rp), None)
        if m is None:
            return "scope", age, ""
        return "ok", age, m
    return "ok", age, ""


def _tic(ti):
    try:
        return hashlib.sha256(json.dumps(ti, sort_keys=True, ensure_ascii=False)
                              .encode("utf-8", "replace")).hexdigest()[:16]
    except Exception:
        return ""


def main():
    raw = sys.stdin.read()
    data = json.loads(raw)
    evt = data.get("hook_event_name") or "PreToolUse"
    _EVT["evt"] = evt
    if _TEST_MODE and os.environ.get("CWP_TEST_RAISE"):
        raise RuntimeError("CWP_TEST_RAISE")
    tool = data.get("tool_name", "")
    ti = data.get("tool_input") or {}
    sid_full = data.get("session_id") or ""
    sid = sid_full[:8] if sid_full else "????????"
    agent, agent_src = _agent_identity(data)
    agent_label = (data.get("agent_type") or "")[:24]

    # ---------- PostToolUse: seen 갱신(성공 시) + 락 해제(성공/실패 무관) ----------
    if evt == "PostToolUse":
        if tool in WRITE_TOOLS:
            rp_post = _canon(ti.get("file_path") or ti.get("notebook_path") or "")
            if is_protected(rp_post):
                tr = data.get("tool_response")
                failed = isinstance(tr, dict) and bool(
                    tr.get("error") or tr.get("is_error") or tr.get("success") is False)
                if not failed:
                    # 실패한 쓰기 뒤 seen 갱신 금지: 타 세션 변경분을 '내가 본 최신'으로 가리지 않음
                    _seen_record(_seen_key(sid_full, agent), rp_post, _sha(rp_post))
                _release(rp_post, sid_full, agent, _tic(ti))   # 도구 호출 종료 = 해제(실패여도)
        sys.exit(0)

    # ---------- Bash: 휴리스틱 측정 + REDACT 저장(차단 없음, P5) ----------
    if tool == "Bash":
        cmd = ti.get("command", "") or ""
        matched = next((t for t in _PROT_TOKENS if t in cmd), None)
        if not matched:
            sys.exit(0)   # 보호경로 무관 — 빠른 통과
        is_write = bool(_BASH_WRITE_RE.search(cmd))
        is_read = bool(_BASH_READ_RE.search(cmd))
        ol = _other_live(sid_full)
        oa = _other_active(sid_full) if is_write else None
        rec = {
            "sid": sid, "tool": "Bash",
            "kind": "write" if is_write else ("read" if is_read else "other"),
            "cmd_sha": hashlib.sha256(cmd.encode("utf-8", "replace")).hexdigest()[:12],
            "cmd_len": len(cmd), "cmd_red": _redact_cmd(cmd), "token": matched,
            "other_live": ol, "agent": agent, "agent_src": agent_src,
        }
        if agent_label:
            rec["agent_label"] = agent_label
        if oa is not None:
            rec["other_active"] = oa
        _intent(rec)
        if is_write and isinstance(oa, int) and oa > 0:
            _emit("⚠️ [cwp Stage3·차단 안 함] 보호 기억파일을 Bash 로 쓰려 합니다. "
                  "다른 활성 세션 %d건 — 저장 전 최신본을 다시 확인하세요." % oa)
        sys.exit(0)

    # ---------- 파일 도구 ----------
    path = ti.get("file_path") or ti.get("notebook_path") or ""
    rp = _canon(path)
    if not is_protected(rp):
        sys.exit(0)   # 보호 대상 아님 — 빠른 통과

    if tool == "Read":
        _seen_record(_seen_key(sid_full, agent), rp, _sha(rp))
        sys.exit(0)   # 읽기 = 침묵·영원히 비차단(I-CWP-3')

    if tool in WRITE_TOOLS:
        tic = _tic(ti)
        cur = _sha(rp)
        exists = cur not in ("MISSING",) and os.path.exists(rp)
        seen = _seen_lookup(_seen_key(sid_full, agent), rp)
        seen_eff = seen if seen and seen not in ("MISSING", "ERROR", "OVERSIZE") else None
        real_cur = cur not in ("MISSING", "ERROR", "OVERSIZE")
        conflict = bool(seen_eff and real_cur and seen_eff != cur)
        deleted_conflict = bool(seen_eff and cur == "MISSING")
        no_seen_write = (tool == "Write" and seen_eff is None)
        no_seen_edit = (tool != "Write" and exists and seen_eff is None)

        # 1) 내용 차단(D1·D2) — override 로 강등 가능
        deny_reason, deny_msg = None, ""
        if no_seen_write and exists:
            deny_reason = "no_seen_write"
            deny_msg = ("⛔ [cwp Stage3 차단] 이 세션(에이전트)이 읽지 않은 기존 보호 기억파일을 통째로 "
                        "덮어쓰려 합니다(blind overwrite). 먼저 Read 도구로 %s 최신본을 읽은 뒤 다시 시도하세요. %s"
                        % (os.path.basename(rp), _OV_HINT))
        elif conflict or deleted_conflict:
            deny_reason = "stale_deleted" if deleted_conflict else "stale"
            deny_msg = ("⛔ [cwp Stage3 차단] 내가 읽은 시점 이후 이 파일이 %s(다른 세션/도구 편집 의심). "
                        "Read 로 최신본을 다시 읽은 뒤 재시도하세요. %s"
                        % ("삭제되었습니다" if deleted_conflict else "변경되었습니다", _OV_HINT))

        override_used, ov_age, ov_scope, ov_note = False, None, "", ""
        if deny_reason:
            ov, ov_age, ov_scope = _override_status(rp)
            if ov == "ok":
                override_used = True
            elif ov == "stale":
                ov_note = " (오래된 override.flag 무시됨 — 제거 요망)"
            elif ov == "scope":
                ov_note = " (override.flag 는 경로 scope 불일치로 미적용)"

        # 2) path 락(D3) — 통과(override 포함)한 쓰기 전부 획득 시도. 락 차단은 override 로 못 뚫는다
        #    (Codex 4b #2: 진행 중인 실제 쓰기 위로 강행하면 Stage3 목적 자체가 무력화. 락은 TTL 내 자가 해소).
        lock_status, holder, lock_age = None, None, None
        content_reason, ov_attempted = deny_reason, override_used   # lock-deny 가 덮어도 감사 보존(Codex 4b2)
        if not deny_reason or override_used:
            lock_status, holder, lock_age = _try_acquire(rp, sid_full, agent, tic)
            if lock_status in ("held", "held_self", "held_corrupt"):
                override_used = False                      # 락 차단은 강등 불가
                deny_reason = {"held": "lock_held", "held_self": "lock_held_self",
                               "held_corrupt": "lock_corrupt"}[lock_status]
                who = ""
                if holder:
                    who = " holder sid=%s agent=%s" % ((holder.get("sid") or "")[:8],
                                                       (holder.get("agent") or "-")[:8])
                deny_msg = ("⛔ [cwp Stage3 차단] 같은 파일에 진행 중인 쓰기가 있습니다(%s%s age=%.0fs). "
                            "잠시 후 재시도하세요(락 TTL %.0fs, override 미적용 대상)."
                            % ("동일 세션의 병렬 에이전트, " if lock_status == "held_self" else
                               ("owner 판독불가, " if lock_status == "held_corrupt" else ""),
                               who.strip(), lock_age or 0.0, LOCK_TTL))
                ov_note = ""

        ol = _other_live(sid_full)
        rec = {
            "sid": sid, "tool": tool, "path": rp,
            "cur_sha": (cur or "")[:12], "seen_sha": (seen or "")[:12], "other_live": ol,
            "conflict": conflict or deleted_conflict, "no_seen_write": no_seen_write,
            "no_seen_edit": no_seen_edit, "new_file": not exists,
            "decision": ("override" if override_used else ("deny" if deny_reason else "allow")),
            "reason": deny_reason or "", "lock": lock_status or "",
            "agent": agent, "agent_src": agent_src, "tic": tic,
        }
        if agent_label:
            rec["agent_label"] = agent_label
        if holder:
            rec["lock_holder"] = {"sid": (holder.get("sid") or "")[:8], "agent": holder.get("agent") or ""}
        if override_used:
            rec["ov_age"] = round(ov_age or 0.0, 1)        # 감사 재구성용(Codex 4b #5)
            rec["ov_scope"] = ov_scope
        if deny_reason and deny_reason.startswith("lock_") and content_reason:
            rec["prelock_reason"] = content_reason         # lock-deny 에 선행 D1/D2 사유 보존(Codex 4b2)
            rec["ov_attempted"] = ov_attempted
        _intent(rec)

        if deny_reason and not override_used:
            _deny(deny_msg + ov_note)

        warn = []
        if override_used:
            warn.append("override.flag 적용으로 차단(%s)을 강등 통과 — 감사 기록됨. 끝나면 flag 제거 권장"
                        % deny_reason)
        if lock_status == "skip_err":
            warn.append("락 인프라 오류로 락 없이 진행(fail-open) — cwp_state/guard_err.log 확인")
        if no_seen_edit:
            warn.append("이 세션(에이전트)이 읽지 않은 보호파일을 편집하려 합니다 — Read 로 최신본 확인 권장")
        if not warn:
            oa = _other_active(sid_full)
            if isinstance(oa, int) and oa > 0:
                warn.append("다른 활성 세션 %d건이 동시에 있습니다 — 저장 전 최신본 확인 권장" % oa)
        if warn:
            _emit("⚠️ [cwp Stage3·차단 안 함] " + " / ".join(warn))
        sys.exit(0)

    sys.exit(0)


if __name__ == "__main__":
    try:
        main()
    except SystemExit:
        raise
    except Exception:
        try:
            _log_err(traceback.format_exc())
        except Exception:
            pass
        try:
            # 이벤트가 Pre 로 확인된 경우에만 경고 JSON(P3 오류 경고) — 파싱실패/Post 는 침묵(계약 보존)
            if _EVT.get("evt") == "PreToolUse":
                sys.stdout.write(json.dumps({
                    "hookSpecificOutput": {
                        "hookEventName": "PreToolUse",
                        "permissionDecision": "allow",
                        "additionalContext": "⚠️ [cwp] guard 내부오류 — fail-open 통과(cwp_state/guard_err.log 확인)",
                    }
                }, ensure_ascii=False))
        except Exception:
            pass
        sys.exit(0)   # fail-open: 어떤 오류도 세션을 막지 않는다(I-CWP-6)
