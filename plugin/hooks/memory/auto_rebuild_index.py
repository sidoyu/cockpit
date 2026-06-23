#!/usr/bin/env python3
"""PostToolUse 자동 메모리 인덱스 재생성 hook (2026-06-18).

목적: memory/*.md 의 description 편집 → MEMORY.md(인덱스) 자동 동기화.
      수동 rebuild 누락으로 drift-watch 가 반복 경보(flapping)하던 것을 편집 시점에 원천 차단.

설계(Codex 4f 설계 + 4b 구현 점검 반영):
- cwp_guard PostToolUse **뒤**에 배치(settings.json 순서) — 소유권 가드 통과 후 재생성.
- **동기·fail-soft**: 어떤 경우에도 exit 0(원 편집을 절대 막지 않음).
- **deadline 예산제**(F1): 전체 subprocess 합계를 DEADLINE 안에 묶어 PostToolUse timeout 과 충돌 방지.
- 경로 게이트(realpath canonical, F6): MEM_DIR **직하위** *.md 만(생성기 범위와 일치).
- index 자기 자신 편집(F3·F4): samefile 로 식별, **--check 만 하고 drift 면 flag**(덮어쓰기 금지 — 수기 편집 보존).
- apply 성공 후 **재-check**(F5): 동시편집 stale 꼬리 남으면 flag 유지.
- build실패(예산초과)·지속 실패 → needs_rebuild flag + 실패 로그(buried 방지; drift-watch 가 픽업).
- 루프 없음: 재생성은 생성기 python 직접 쓰기(Edit 도구 미경유) → PostToolUse 재발화 안 함.
- 한계: Bash/sed 로 직접 편집한 memory 파일은 matcher(Write|Edit|MultiEdit) 밖 → 즉시 재생성 X, 일일 drift-watch 가 백스톱.

생성기 exit 규약: --check 0=동일/1=드리프트/2=build실패(fail). --apply 0=성공/2=lock·CAS·예산·사후검증.
"""
import sys, os, json, subprocess, time

HERE = os.path.dirname(os.path.realpath(__file__))
if HERE not in sys.path:
    sys.path.insert(0, HERE)
from cc_paths import MEMORY_DIR as MEM_DIR, CWP_STATE, AUTO_REBUILD_LOG as LOG
REBUILD = os.path.join(HERE, "rebuild_memory_index.py")
INDEX_NAME = "MEMORY.md"
INDEX_PATH = os.path.join(MEM_DIR, INDEX_NAME)
FLAG = os.path.join(CWP_STATE, "needs_rebuild.flag")
DEADLINE_BUDGET = 13.0   # 전체 subprocess 합계 상한(PostToolUse timeout 20s 안)
SUBPROC_CAP = 6.0        # 단일 호출 상한(정상 <1s, hang 방어)


def log(action, detail=""):
    try:
        with open(LOG, "a", encoding="utf-8") as f:
            f.write("%s\t%s\t%s\n" % (time.strftime("%Y-%m-%dT%H:%M:%S"), action, detail))
    except Exception:
        pass


def set_flag(reason, sid):
    try:
        os.makedirs(os.path.dirname(FLAG), exist_ok=True)
        with open(FLAG, "w", encoding="utf-8") as f:
            json.dump({"ts": time.strftime("%Y-%m-%dT%H:%M:%S"), "reason": reason, "sid": sid},
                      f, ensure_ascii=False)
    except Exception:
        pass


def clear_flag():
    try:
        if os.path.exists(FLAG):
            os.unlink(FLAG)
    except Exception:
        pass


def run(extra, deadline):
    """deadline(monotonic) 까지 남은 시간 안에서 생성기 실행. (rc, out)."""
    remaining = deadline - time.monotonic()
    if remaining < 0.5:
        return 199, "deadline_exceeded"
    to = max(1.0, min(SUBPROC_CAP, remaining))
    try:
        p = subprocess.run([sys.executable, REBUILD] + extra,
                           capture_output=True, text=True, timeout=to)
        return p.returncode, (p.stdout or "") + (p.stderr or "")
    except subprocess.TimeoutExpired:
        return 124, "timeout"
    except Exception as e:  # noqa
        return 125, str(e)


def is_index_file(rp):
    try:
        return os.path.exists(INDEX_PATH) and os.path.samefile(rp, INDEX_PATH)
    except OSError:
        return os.path.basename(rp).lower() == INDEX_NAME.lower()


def main():
    deadline = time.monotonic() + DEADLINE_BUDGET
    try:
        data = json.loads(sys.stdin.read() or "{}")
    except Exception:
        return
    ti = data.get("tool_input") or {}
    fp = ti.get("file_path") or ti.get("notebook_path") or ""
    if not fp:
        return
    sid = (data.get("session_id") or "hook")[:8]
    rp = os.path.realpath(fp)

    # ── 게이트(F6): MEM_DIR 직하위 *.md (생성기 범위와 일치) ──
    if os.path.dirname(rp) != MEM_DIR or not rp.endswith(".md"):
        return
    if not os.path.exists(REBUILD):
        return

    # ── index 자기 자신 편집(F3·F4): 감지만, 덮어쓰기 금지 ──
    if is_index_file(rp):
        rc, _ = run(["--check"], deadline)
        if rc == 1:
            set_flag("manual_index_drift", sid)
            log("manual_index_drift", "")
        return

    # 1) 드리프트 검사
    rc, out = run(["--check"], deadline)
    if rc == 0:
        clear_flag()                 # 동일 — 이전 실패 flag 가 남아 있으면 해소(self-heal, 4b 축9)
        return                       # body만 바뀐 편집 등 = no-op
    if rc == 2:                      # build 실패(예산 초과 등) = 자동 복구 불가
        set_flag("build_fail", sid)
        log("build_fail", out.strip()[:200])
        return
    if rc != 1:                      # timeout/deadline/기타
        set_flag("check_err:%d" % rc, sid)
        log("check_err", "rc=%d %s" % (rc, out.strip()[:120]))
        return

    # 2) 드리프트 확정 → --apply (deadline 까지 bounded 재시도)
    attempt = 0
    while True:
        attempt += 1
        rc, out = run(["--apply", "--sid", sid], deadline)
        if rc == 0:
            # F5: 동시편집 stale 꼬리 확인
            rc2, _ = run(["--check"], deadline)
            if rc2 == 1:
                set_flag("stale_tail", sid)
                log("stale_tail", "attempt=%d" % attempt)
            else:
                clear_flag()
                log("applied", "attempt=%d" % attempt)
            return
        transient = ("lock" in out) or ("동시 편집" in out) or ("stale" in out) or rc in (124, 199)
        if transient and time.monotonic() < deadline - 1.0:
            time.sleep(0.4)
            continue
        reason = "budget" if "예산" in out else ("postverify" if "사후검증" in out else "apply_fail")
        set_flag(reason, sid)
        log(reason, "attempt=%d rc=%d %s" % (attempt, rc, out.strip()[:140]))
        return


if __name__ == "__main__":
    try:
        main()
    except Exception as e:  # noqa — 절대 turn 을 깨지 않음
        try:
            log("hook_exc", str(e)[:160])
        except Exception:
            pass
    sys.exit(0)  # fail-soft: 항상 0
