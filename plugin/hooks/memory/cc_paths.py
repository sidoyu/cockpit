#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""cc_paths.py — cockpit 메모리 시스템의 경로 단일 출처(single source of truth).

플러그인 설치 위치(`${CLAUDE_PLUGIN_ROOT}`)는 **업데이트마다 교체되는 읽기전용 캐시**다.
따라서 사용자 데이터·런타임 상태는 플러그인 밖의 영속 위치에 둔다:

  - 메모리 저장소(지식)  = CC_MEMORY_DIR   (기본 ~/.claude/cc-memory)
        MEMORY.md(인덱스·자동생성) · PROJECT_STATUS.md(권위 상태) · *.md(기억 파일)
  - 런타임 상태(운영)    = CC_STATE_DIR    (기본 ~/.claude/cc-companion)
        pending/(기억 후보 ack 큐) · cwp_state/(동시쓰기 보호) · analyzed_sessions.json · 로그 · audit.log
  - 세션 트랜스크립트 디렉터리 = 하드코딩하지 않고 hook 이 받는 transcript_path / cwd 에서 런타임 도출.

테스트 격리(기존 계약 보존): MEMORY_DIR / CWP_STATE_DIR env 가 있으면 그것을 우선한다.
"""
import os


def expand(p):
    return os.path.expanduser(p)


def realexpand(p):
    return os.path.realpath(os.path.expanduser(p))


# ── 메모리 저장소(지식) ──
MEMORY_DIR = realexpand(
    os.environ.get("CC_MEMORY_DIR") or os.environ.get("MEMORY_DIR") or "~/.claude/cc-memory")
MEMORY_INDEX = os.path.join(MEMORY_DIR, "MEMORY.md")
STATUS_FILE = os.path.join(MEMORY_DIR, "PROJECT_STATUS.md")

# ── 런타임 상태(운영) ── (realpath 고정: 상대 경로가 들어와 cwd 따라 상태가 갈라지는 것 방지)
STATE_DIR = realexpand(os.environ.get("CC_STATE_DIR") or "~/.claude/cc-companion")
PENDING_DIR = os.path.join(STATE_DIR, "pending")
ANALYZED_FILE = os.path.join(STATE_DIR, "analyzed_sessions.json")
# cwp_state: 기존 테스트 백도어 env(CWP_STATE_DIR) 보존
CWP_STATE = realexpand(os.environ.get("CWP_STATE_DIR") or os.path.join(STATE_DIR, "cwp_state"))
DEBUG_LOG = os.path.join(STATE_DIR, "debug.log")
AUTO_REBUILD_LOG = os.path.join(STATE_DIR, "auto_rebuild.log")
AUDIT_LOG = os.path.join(STATE_DIR, "audit.log")

# ── 선택: 세션 제목 소스(없으면 "" → 기능 degrade, 개인 대시보드 결합 제거) ──
SUMMARIES_PATH = expand(os.environ.get("CC_SUMMARIES_PATH") or "") if os.environ.get("CC_SUMMARIES_PATH") else ""


def proj_transcript_dir(cwd=None):
    """현재 프로젝트의 세션 트랜스크립트 디렉터리(~/.claude/projects/<...>) 도출.
    authoritative = hook stdin 의 transcript_path 의 dirname(호출부가 우선). 이 함수는 fallback.
    1차: ~/.claude/projects/*/ 중 **기록된 cwd 가 일치**하는 디렉터리를 찾는다(인코딩 추측보다 정확 —
         특수문자/유니코드 경로의 충돌·정보소실 회피, Codex 발견).
    2차: Claude Code 인코딩 근사(특수문자→'-'). 어느 경우에도 예외를 내지 않는다."""
    import re, json, glob
    base = os.path.expanduser("~/.claude/projects")
    target = os.path.realpath(os.path.abspath(cwd or os.getcwd()))
    try:
        dirs = [d for d in glob.glob(os.path.join(base, "*")) if os.path.isdir(d)]
        for d in sorted(dirs, key=lambda p: -os.path.getmtime(p)):
            jl = glob.glob(os.path.join(d, "*.jsonl"))
            if not jl:
                continue
            with open(max(jl, key=os.path.getmtime), "r", encoding="utf-8", errors="ignore") as f:
                for _ in range(10):
                    line = f.readline()
                    if not line:
                        break
                    try:
                        c = json.loads(line).get("cwd")
                    except Exception:
                        continue
                    if c and os.path.realpath(c) == target:
                        return d
    except Exception:
        pass
    return os.path.join(base, re.sub(r"[^A-Za-z0-9]", "-", target))
