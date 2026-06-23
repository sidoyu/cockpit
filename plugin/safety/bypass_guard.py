#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""bypass_guard.py — PreToolUse 안전망: 파괴/비가역 deny-list + kill switch + 감사로그.

bypass(권한 확인 생략) 환경의 '그물'. **1차 방어는 AI 판단 + CLAUDE.md '멈춰 질문' 규율**이고,
이 가드는 catastrophic 셸 패턴을 결정적으로 차단하는 backstop 이다(완전 보호 아님 — GOVERNANCE.md 5장).

매처(hooks.json): Bash|Write|Edit|MultiEdit|NotebookEdit
  1) kill switch 파일 존재 → 매칭된 모든 도구 deny (자동 진행 즉시 중단)
  2) Bash → 명령을 deny-list 정규식과 대조, 매칭 시 deny
  3) 그 외(write 도구·killswitch 없음) → allow (메모리 파일 보호는 cwp_guard 가 담당)
  4) deny / killswitch / override = audit.log(JSONL, 시크릿 레닥션) 기록

실패 정책: 내부 오류 = **fail-open**(셸 잠금 방지) + 감사로그(조용한 해제 금지).
  근거: deny-list 는 backstop 이고 1차 방어는 AI 판단이다. 가드 버그로 사용자가 셸에서 잠기는
  비용 > 가드 버그로 backstop 1건이 새는 비용. (catastrophic 명령은 사용자가 직접 터미널에서 실행.)
override: touch <CC_STATE_DIR>/safety-override.flag (TTL 5분, 감사 기록) — 오탐 1회 통과용.
설정(env): CC_STATE_DIR, CC_KILL_SWITCH, CC_DENYLIST(추가 파일 경로).
"""
import sys, os, re, json, time

HERE = os.path.dirname(os.path.realpath(__file__))

# ── 경로(cc_paths 규약과 동기화 유지 — 안전 가드는 메모리 훅 import 에 의존하지 않도록 self-contained) ──
STATE_DIR = os.path.expanduser(os.environ.get("CC_STATE_DIR") or "~/.claude/cc-companion")
AUDIT_LOG = os.path.join(STATE_DIR, "audit.log")
KILL_SWITCH = os.path.expanduser(os.environ.get("CC_KILL_SWITCH") or "~/.claude/CC_KILL_SWITCH")
OVERRIDE_FLAG = os.path.join(STATE_DIR, "safety-override.flag")
OVERRIDE_TTL = 300.0
SHIPPED_DENYLIST = os.path.join(HERE, "deny-list.txt")
LOCAL_DENYLIST = os.path.join(STATE_DIR, "deny-list.local.txt")
EXTRA_DENYLIST = os.environ.get("CC_DENYLIST") or ""

WRITE_TOOLS = {"Write", "Edit", "MultiEdit", "NotebookEdit"}
AUDIT_MAX = 512 * 1024

# 시크릿 레닥션(session_context._redact 계열 — 감사로그/사유 메시지에 평문 키 금지)
_KEY_PAT = re.compile(
    r"sk-proj-[A-Za-z0-9_-]{20,}|sk-ant-[A-Za-z0-9_-]{20,}|sk-[A-Za-z0-9]{20,}|"
    r"AIza[A-Za-z0-9_-]{30,}|ghp_[A-Za-z0-9]{30,}|AKIA[A-Z0-9]{16}|xox[baprs]-[A-Za-z0-9-]{10,}")


def _redact(s):
    s = s[:4096]
    s = _KEY_PAT.sub("[REDACTED-KEY]", s)
    s = re.sub(r'([A-Za-z0-9_]*(?:KEY|TOKEN|SECRET|PASSWORD|PASSWD|BEARER)[A-Za-z0-9_]*\s*[=:]\s*)\S+',
               r'\1[RED]', s, flags=re.I)
    s = re.sub(r'(Authorization\s*:?\s*)\S+', r'\1[RED]', s, flags=re.I)
    s = re.sub(r'\b[A-Za-z0-9_\-]{40,}\b', '[RED-LONG]', s)
    if len(s) > 1200:
        s = s[:1200] + "…[T]"
    return s


def _audit(rec):
    try:
        os.makedirs(STATE_DIR, exist_ok=True)
        try:
            if os.path.getsize(AUDIT_LOG) > AUDIT_MAX:
                os.replace(AUDIT_LOG, AUDIT_LOG + ".1")
        except OSError:
            pass
        rec["ts"] = time.strftime("%Y-%m-%dT%H:%M:%S")
        data = (json.dumps(rec, ensure_ascii=False) + "\n").encode("utf-8")
        if len(data) >= 8192:
            data = (json.dumps({k: rec.get(k) for k in ("ts", "event", "tool", "decision", "pattern", "sid")},
                               ensure_ascii=False) + "\n").encode("utf-8")
        fd = os.open(AUDIT_LOG, os.O_WRONLY | os.O_APPEND | os.O_CREAT, 0o600)
        try:
            os.write(fd, data)
        finally:
            os.close(fd)
    except Exception:
        pass


def _load_patterns():
    """shipped + local + env 추가 deny-list 컴파일. 잘못된 정규식은 건너뜀(가드 자체는 안 죽음)."""
    pats, raw = [], []
    for path in (SHIPPED_DENYLIST, LOCAL_DENYLIST, EXTRA_DENYLIST):
        if not path or not os.path.exists(path):
            continue
        try:
            with open(path, encoding="utf-8") as f:
                for ln in f:
                    s = ln.strip()
                    if not s or s.startswith("#"):
                        continue
                    raw.append((s, path))
        except Exception:
            continue
    for s, src in raw:
        try:
            pats.append((re.compile(s, re.I), s, src))
        except re.error:
            _audit({"event": "denylist_bad_pattern", "pattern": s[:120], "src": os.path.basename(src)})
    return pats


def _override_active():
    try:
        age = time.time() - os.stat(OVERRIDE_FLAG).st_mtime
        return 0 <= age <= OVERRIDE_TTL
    except OSError:
        return False


def _allow():
    sys.exit(0)   # PreToolUse 무출력 = allow


def _deny(msg):
    sys.stdout.write(json.dumps({
        "hookSpecificOutput": {
            "hookEventName": "PreToolUse",
            "permissionDecision": "deny",
            "permissionDecisionReason": msg,
            "additionalContext": msg,
        }
    }, ensure_ascii=False))
    sys.exit(0)


def main():
    raw = sys.stdin.read()
    data = json.loads(raw)
    tool = data.get("tool_name", "")
    ti = data.get("tool_input") or {}
    sid = (data.get("session_id") or "")[:8]

    # 1) kill switch — 존재하면 매칭된 모든 도구 즉시 차단
    if os.path.exists(KILL_SWITCH):
        msg = ("🛑 [cockpit kill switch] 긴급정지 활성 — 자동 진행이 중단되었습니다. "
               "재개하려면 긴급정지 파일을 삭제하세요:  rm '%s'" % KILL_SWITCH)
        _audit({"event": "kill_switch", "tool": tool, "decision": "deny", "sid": sid})
        _deny(msg)

    # 2) Bash deny-list
    if tool == "Bash":
        cmd = ti.get("command", "") or ""
        if not cmd.strip():
            _allow()
        for rx, pat, src in _load_patterns():
            if rx.search(cmd):
                if _override_active():
                    _audit({"event": "denylist", "tool": "Bash", "decision": "override",
                            "pattern": pat[:120], "cmd": _redact(cmd), "sid": sid})
                    sys.stdout.write(json.dumps({
                        "hookSpecificOutput": {
                            "hookEventName": "PreToolUse",
                            "permissionDecision": "allow",
                            "additionalContext": ("⚠️ [cockpit] deny-list 매칭(%s)을 safety-override.flag 로 "
                                                  "강등 통과 — 감사 기록됨. 끝나면 flag 제거 권장." % pat[:60]),
                        }
                    }, ensure_ascii=False))
                    sys.exit(0)
                _audit({"event": "denylist", "tool": "Bash", "decision": "deny",
                        "pattern": pat[:120], "cmd": _redact(cmd), "sid": sid})
                _deny("⛔ [cockpit 안전망] 파괴/비가역으로 분류된 명령이 차단되었습니다(패턴: %s). "
                      "정말 필요하면 직접 터미널에서 실행하세요. 오탐이면 1회 강행: "
                      "touch '%s' (5분 유효·감사 기록). 패턴 영구 예외는 deny-list.local.txt 참조."
                      % (_redact(pat)[:80], OVERRIDE_FLAG))
        _allow()

    # 3) 그 외 도구(write 등) — killswitch 없으면 통과(메모리 보호는 cwp_guard)
    _allow()


if __name__ == "__main__":
    try:
        main()
    except SystemExit:
        raise
    except Exception as e:
        # fail-open + 감사(조용한 해제 금지)
        try:
            _audit({"event": "guard_error", "decision": "fail_open", "err": str(e)[:200]})
        except Exception:
            pass
        sys.exit(0)
