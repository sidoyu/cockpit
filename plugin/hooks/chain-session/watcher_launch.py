#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
watcher_launch.py — SessionStart 훅. transcript_watcher 데몬을 **기동만** 한다.

- 출력 없음(additionalContext 미생성) → session_context 의 단일 병합 출력과 충돌하지 않는다.
- 이미 가동 중이면(lockfile 소유자 생존) 아무것도 안 한다(중복 기동 방지·G19는 데몬이 최종 보증).
- 데몬은 detached(start_new_session=True·표준스트림 분리)로 띄우고 즉시 반환한다(세션 시작 지연 0).
- 어떤 예외도 세션 시작을 막지 않는다(fail-open).
- 옵트아웃: CC_WATCHER_DISABLED=1 이면 기동하지 않는다.
"""
import os, sys, time, subprocess


def _running():
    """데몬 락 소유자가 살아있는지(있으면 기동 생략)."""
    try:
        sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
        sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "memory"))
        try:
            import cc_paths  # type: ignore
            base = cc_paths.STATE_DIR
        except Exception:
            base = os.path.realpath(os.path.expanduser(
                os.environ.get("CC_STATE_DIR") or "~/.claude/cc-companion"))
        lock_file = os.path.join(base, "watcher", "watcher.lock")
        age = time.time() - os.stat(lock_file).st_mtime
        if age > 43_500:            # MAX_RUNTIME(12h)+grace 초과 = stale → 재기동 허용(PID 재사용 백스톱)
            return False
        with open(lock_file) as f:
            pid = int((f.read().split() or ["0"])[0])
        if pid:
            os.kill(pid, 0)  # 살아있으면 예외 없음
            return True
    except Exception:
        return False
    return False


def main():
    if os.environ.get("CC_WATCHER_DISABLED") == "1":
        return
    if _running():
        return
    watcher = os.path.join(os.path.dirname(os.path.abspath(__file__)), "transcript_watcher.py")
    if not os.path.exists(watcher):
        return
    try:
        devnull = open(os.devnull, "wb")
        kwargs = {"stdin": subprocess.DEVNULL, "stdout": devnull, "stderr": devnull,
                  "close_fds": True}
        if hasattr(os, "setsid"):
            kwargs["start_new_session"] = True  # 세션 리더로 분리(POSIX)
        subprocess.Popen([sys.executable or "python3", watcher], **kwargs)
    except Exception:
        pass  # 기동 실패도 조용히(감시원 없이 세션 정상 진행)


if __name__ == "__main__":
    try:
        main()
    except Exception:
        pass
