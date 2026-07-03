#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""창고 차례표 생성기 — 보관함(ARCHIVE_DIR) 인덱스.

보관함 .md 파일들의 frontmatter description(없으면 본문 첫 줄)으로
ARCHIVE_INDEX.md 를 결정적으로 재생성한다. 본채 MEMORY.md·기억 폴더 무접촉.
강등이 "기억 상실"이 아니라 "서가 이동"이 되도록 — 1-hop 탐색 보조.

경로: 보관함 = cc_paths.ARCHIVE_DIR(기본 ~/.claude/cc-memory-archive, CC_ARCHIVE_DIR 로 조정).
실행: python3 build_archive_index.py  (보관함 변동 시 재실행, 같은 입력=같은 출력)
      보관함이 없으면 아무 것도 하지 않는다(강등 전에는 정상).
"""
import os, re, sys, datetime

_HERE = os.path.dirname(os.path.realpath(__file__))
if _HERE not in sys.path:
    sys.path.insert(0, _HERE)
from cc_paths import ARCHIVE_DIR

OUT = os.path.join(ARCHIVE_DIR, "ARCHIVE_INDEX.md")

DESC_RE = re.compile(r'^description:\s*"?(.*?)"?\s*$')


def hook_for(path):
    desc, in_fm, fm_done = None, False, False
    first_body = None
    for line in open(path, encoding="utf-8"):
        s = line.rstrip("\n")
        if s == "---":
            if not in_fm and not fm_done:
                in_fm = True
                continue
            in_fm, fm_done = False, True
            continue
        if in_fm:
            m = DESC_RE.match(s)
            if m and m.group(1):
                desc = m.group(1)
        elif fm_done and s.strip() and first_body is None:
            first_body = s.strip()
    return desc or (first_body[:100] + "…" if first_body and len(first_body) > 100 else first_body) or "(설명 없음)"


def main():
    if not os.path.isdir(ARCHIVE_DIR):
        print("보관함 없음(%s) — 강등된 기억 없음. 차례표 생성 불필요." % ARCHIVE_DIR)
        return 0
    files = sorted(f for f in os.listdir(ARCHIVE_DIR)
                   if f.endswith(".md") and f != "ARCHIVE_INDEX.md")
    lines = [
        "# 보관함 차례표 (ARCHIVE_INDEX)",
        "",
        "> 완료·휴면으로 본채 인덱스(MEMORY.md)에서 강등된 기억들. 내용은 각 파일에 무손실 보존.",
        "> 재생성: 이 스크립트(build_archive_index.py)를 다시 실행 (수동 편집 금지 — 덮인다).",
        "> 항목 후크의 출처는 각 파일 frontmatter description.",
        "",
    ]
    for f in files:
        p = os.path.join(ARCHIVE_DIR, f)
        moved = datetime.date.fromtimestamp(os.path.getmtime(p)).isoformat()
        lines.append(f"- [{f}]({f}) — {hook_for(p)} (보관 ~{moved})")
    lines.append("")
    lines.append(f"_{len(files)}건 · 생성 {datetime.date.today().isoformat()}_")
    tmp = "%s.tmp.%d" % (OUT, os.getpid())   # 원자쓰기: 중단 시 부분 인덱스가 완성본처럼 남는 것 차단
    with open(tmp, "w", encoding="utf-8") as w:
        w.write("\n".join(lines) + "\n")
    os.replace(tmp, OUT)
    print(f"생성: {OUT} ({len(files)}건)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
