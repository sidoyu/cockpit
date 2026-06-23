#!/usr/bin/env python3
"""pending ack 큐 frontmatter 파서 — top-level + harness 노드 스키마(metadata.*) 둘 다 지원.

배경: Claude Code harness 의 메모리/파일추적 계층이 `memory/` 아래 모든 .md frontmatter 를
노드 스키마(`name:` + `metadata: { node_type: memory, status: ... }`)로 canonicalize 한다.
extract_pending.py 가 쓴 top-level `status:` 가 그 뒤 metadata 아래로 들어가면,
top-level(`^status:`)만 보던 카운터/회귀가드가 status 를 놓쳐 두 가지 결함이 난다:
  (1) status:new 항목이 다음 SessionStart 카운트에서 누락 → 대기열에서 증발
  (2) 완료(applied/skipped) 항목 재분석 시 .rN 분리 실패 → 원본을 status:new 로 덮어씀(회귀)
이를 막기 위해 session_context.py 와 extract_pending.py 가 공유하는 단일 dual-schema 파서.

본문 오탐 방지: 첫 '---' ~ 다음 '---' 사이 frontmatter 블록에서만 매칭한다.
줄머리(들여쓰기 허용) 매칭이라 nested(`  status:`)·top-level(`status:`) 모두 인식하고
본문에 'status:' 가 있어도 잡지 않는다.
"""
import re

# 닫는 '---' 는 그 자체로 한 줄(delimiter line)일 때만 인정. CRLF(\r\n)도 허용.
_FM = re.compile(r"^---[ \t]*\r?\n(.*?)\r?\n---[ \t]*(?:\r?\n|\Z)", re.S)


def _frontmatter(text):
    """첫 '---'~'---' 블록 반환. 닫는 '---' 가 없으면(head 절단 등) 받은 텍스트 전체를
    보수적으로 사용(status 는 frontmatter 최상단에 있어 절단된 head 에서도 잡힘)."""
    m = _FM.match(text or "")
    return m.group(1) if m else (text or "")


def field(text, key):
    """frontmatter 에서 key 값을 반환(top-level 또는 metadata 아래 들여쓰기 모두). 없으면 None.
    값의 양끝 공백·따옴표(canonicalizer 가 YAML 직렬화 시 붙일 수 있음)·CRLF 를 벗긴다."""
    m = re.search(r"(?m)^[ \t]*" + re.escape(key) + r":[ \t]*(.*)$", _frontmatter(text))
    if not m:
        return None
    return m.group(1).strip().strip('"').strip("'").strip() or None


def pending_status(text):
    """pending 항목 status(new/applied/skipped) 또는 None. top-level·nested 스키마 모두 인식."""
    return field(text, "status")
