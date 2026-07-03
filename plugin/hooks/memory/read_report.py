#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""기억 열람 리포트 — one-shot.

세션 JSONL을 사후 배치 파싱해 기억 파일별 "명시 열람"(Read/Grep/Bash 등
tool_use 입력에 등장)을 집계한다. 훅 0개·동시쓰기 0·과거 전체 소급.

⚠️ 용도 제한: harness recall 주입은 JSONL에서 비관측 = 과소집계.
   따라서 "안 읽힘"을 강등 근거로 쓰는 것 금지(negative evidence 금지).
   "최근 명시 열람 = 강등 보류" 보호 신호로만 사용한다.

경로: 기억 = cc_paths.MEMORY_DIR · 보관함 = cc_paths.ARCHIVE_DIR ·
      세션 트랜스크립트 = 현재 프로젝트(cc_paths.proj_transcript_dir) ·
      출력 = cc_paths.REPORT_DIR.
실행: python3 read_report.py  (강등 결정 시점에 수동 1회)
"""
import os, re, sys, json, datetime, collections

_HERE = os.path.dirname(os.path.realpath(__file__))
if _HERE not in sys.path:
    sys.path.insert(0, _HERE)
from cc_paths import MEMORY_DIR as MEM_DIR, ARCHIVE_DIR as ARCH_DIR, REPORT_DIR, proj_transcript_dir

RECENT_DAYS = 30

# tool_use 입력 직렬화 문자열에서 기억 파일 참조 추출.
# 패턴은 실제 저장소/보관함 디렉터리 basename 에서 도출(CC_MEMORY_DIR 재정의에도 견고).
_MEM_BASE = os.path.basename(MEM_DIR.rstrip("/")) or "cc-memory"
_ARCH_BASE = os.path.basename(ARCH_DIR.rstrip("/")) or "cc-memory-archive"
# 긴 basename 을 먼저(예: cc-memory-archive 가 cc-memory 보다 우선 매칭되도록)
_BASES = sorted({_MEM_BASE, _ARCH_BASE}, key=len, reverse=True)
# 경로 구분자 경계(?<![\w-]) 로 my-cc-memory/ 같은 상이 경로의 부분문자열 과매칭 차단(직전이 단어/하이픈이면 불매칭)
REF_RE = re.compile(r'(?<![\w-])(?:%s)/([A-Za-z0-9_.\-]+\.md)' % "|".join(re.escape(b) for b in _BASES))


def known_names():
    names = set()
    for d in (MEM_DIR, ARCH_DIR):
        if os.path.isdir(d):
            names |= {f for f in os.listdir(d) if f.endswith(".md")}
    return names


def main():
    proj_dir = proj_transcript_dir()
    if not os.path.isdir(proj_dir):
        print("트랜스크립트 디렉터리 없음(%s) — 세션 기록 없음." % proj_dir)
        return 0
    today = datetime.date.today()
    cutoff = (today - datetime.timedelta(days=RECENT_DAYS)).isoformat()
    names = known_names()
    # Tier1 = Read/Grep 도구(본문을 실제로 읽은 실질 열람) / Tier2 = Bash·Edit 등(유지보수성 접촉 포함)
    last = {}                       # file -> (ts, session)   (tier 무관 최신)
    last_t1 = {}                    # file -> (ts, session)   (실질 열람 최신)
    count_all = collections.Counter()
    count_recent = collections.Counter()      # tier1 recent
    count_recent_t2 = collections.Counter()   # tier2 recent
    sessions = sorted(f for f in os.listdir(proj_dir) if f.endswith(".jsonl"))
    parsed = 0
    for sf in sessions:
        sid = sf[:8]
        path = os.path.join(proj_dir, sf)
        try:
            with open(path, encoding="utf-8", errors="replace") as fh:
                for line in fh:
                    # 빠른 사전 필터: tool_use 이벤트 + 기억 경로 동시 포함 줄만 파싱
                    if "tool_use" not in line or not any(b in line for b in _BASES):
                        continue
                    try:
                        obj = json.loads(line)
                    except Exception:
                        continue
                    if obj.get("type") != "assistant":
                        continue  # 주입 컨텍스트·tool_result(파일 내용)는 열람으로 안 침
                    content = (obj.get("message") or {}).get("content") or []
                    refs_t1, refs_t2 = set(), set()
                    for blk in content:
                        if isinstance(blk, dict) and blk.get("type") == "tool_use":
                            found = set(REF_RE.findall(json.dumps(blk.get("input", {}), ensure_ascii=False)))
                            if blk.get("name") in ("Read", "Grep"):
                                refs_t1 |= found
                            else:
                                refs_t2 |= found
                    if not (refs_t1 or refs_t2):
                        continue
                    parsed += 1
                    ts = obj.get("timestamp", "")
                    for r in refs_t1 | refs_t2:
                        if r not in names or r == "MEMORY.md":
                            continue
                        count_all[r] += 1
                        if ts and (r not in last or ts > last[r][0]):
                            last[r] = (ts, sid)
                        if r in refs_t1:
                            if ts >= cutoff:
                                count_recent[r] += 1
                            if ts and (r not in last_t1 or ts > last_t1[r][0]):
                                last_t1[r] = (ts, sid)
                        elif ts >= cutoff:
                            count_recent_t2[r] += 1
        except OSError:
            continue

    os.makedirs(REPORT_DIR, exist_ok=True)
    out = os.path.join(REPORT_DIR, f"read-report-{today.isoformat().replace('-', '')}.md")
    tmp = "%s.tmp.%d" % (out, os.getpid())   # 원자쓰기: 중단 시 부분 리포트가 완성본처럼 남는 것 차단
    live = sorted(n for n in names if os.path.exists(os.path.join(MEM_DIR, n)) and n != "MEMORY.md")
    with open(tmp, "w", encoding="utf-8") as w:
        w.write(f"# 기억 열람 리포트 — {today.isoformat()} (세션 {len(sessions)}개 소급)\n\n")
        w.write("> ⚠️ **negative evidence 금지**: harness recall 주입은 여기 안 잡힌다(과소집계).\n")
        w.write("> '안 읽힘'은 강등 근거가 아니다. **'최근 명시 열람 = 강등 보류' 보호 신호 전용.**\n\n")
        w.write(f"## 보호 신호 — 최근 {RECENT_DAYS}일 내 실질 열람(Read·Grep) (강등 보류 대상)\n\n")
        w.write("| 기억 파일 | 최근 실질열람 | 30일 횟수 | 누적(전체도구) |\n|---|---|---|---|\n")
        prot = sorted((n for n in count_recent), key=lambda n: last_t1[n][0], reverse=True)
        for n in prot:
            w.write(f"| {n} | {last_t1[n][0][:10]} ({last_t1[n][1]}) | {count_recent[n]} | {count_all[n]} |\n")
        t2only = sorted((n for n in count_recent_t2 if n not in count_recent and n in live),
                        key=lambda n: last[n][0], reverse=True)
        w.write(f"\n## 참고 — 30일 내 유지보수성 접촉만(Bash·Edit 등, 실질 열람 아님 가능) {len(t2only)}개\n\n")
        w.write("인덱스 rebuild·다이어트·일괄 마이그레이션의 접촉 포함. 약한 보호 신호로만.\n\n")
        for n in t2only:
            w.write(f"- {n} (마지막 접촉 {last[n][0][:10]}, 30일 {count_recent_t2[n]}회)\n")
        cold = [n for n in live if n not in count_recent and n not in count_recent_t2]
        w.write(f"\n## 참고 — 30일 내 무기록 (현역 {len(live)}개 중 {len(cold)}개)\n\n")
        w.write("⚠️ 강등 근거 아님(recall 주입 비관측=과소집계). 후보 검토 시 '보호 신호 부재' 확인용으로만.\n\n")
        for n in cold:
            tail = f" (마지막 {last[n][0][:10]})" if n in last else " (관측 0)"
            w.write(f"- {n}{tail}\n")
        w.write(f"\n집계: tool_use 이벤트 {parsed}건 매칭. Tier 구분에도 유지보수 세션의 Read/Grep은 실질 열람으로 집계되는 과보호 방향 오차 있음(안전한 방향).\n")
    os.replace(tmp, out)
    print(f"보고서: {out}")
    print(f"보호신호(30일) {len(count_recent)}개 / 무기록 현역 {len(cold)}개 / 매칭 이벤트 {parsed}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
