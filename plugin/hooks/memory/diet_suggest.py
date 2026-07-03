#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""기억 다이어트 반자동화 — 후보 triage 리포트.

목적: 수동 다이어트 라운드의 *후보 탐색* 노동을 자동화. 사용자는 일괄 승인(체크)만.
  **report-only · 사실만**: 추측성 '낡음' 판정 안 함(mtime 은 일괄작업으로 균일할 수 있고,
  완료 메모리는 의도적 보존). 대신 **구조적 사실 신호**만:
    예산 압박 / 인덱스 무결성 / dangling 링크 / 스텁 / 병합중복 / 종료프로젝트 cross-ref.
  **자동삭제/자동이동 절대 안 함**. apply = 사용자 체크 후 기존 안전 파이프:
    mv <file> <ARCHIVE_DIR>/  →  rebuild_memory_index.py --apply

사유코드(전부 사실 기반):
  index_orphan    memory/ 에 있으나 MEMORY.md 인덱스에 없음(드리프트) → 인덱스 추가/아카이브
  index_dangling  인덱스에 있으나 파일 부재 → 인덱스 줄 제거
  dangling_link   본문 [[X]] 의 X.md 부재(아카이브 잔재/오타) → 링크 정리
  stub_review     작은 파일(<STUB_BYTES) → 병합 검토(작음=정상일 수 있음, 사용자 판단)
  merge_overlap   동일 prefix 형제와 키워드 중복 높음 → 병합 검토
  frozen_review   PROJECT_STATUS 대표상태 🚫/동결/↩️ → 보관 검토(태그≠메모리범위 주의, 사용자 판단)

경로: 기억 = cc_paths.MEMORY_DIR · 보관함 = cc_paths.ARCHIVE_DIR · 출력 = cc_paths.REPORT_DIR.
실행:
  diet_suggest.py                  # 콘솔 리포트 + 매니페스트 산출
  diet_suggest.py --merge-jac 0.45 # 병합 키워드 중복 임계(기본 0.45)
"""
import os, re, sys, time, argparse, datetime, collections

_HERE = os.path.dirname(os.path.realpath(__file__))
if _HERE not in sys.path:
    sys.path.insert(0, _HERE)
from cc_paths import MEMORY_DIR as MEM_DIR, MEMORY_INDEX as MEMORY_IDX, STATUS_FILE as PROJECT_STATUS, \
    CLAUDE_MD, ARCHIVE_DIR, REPORT_DIR
# 예산 상수는 인덱스 생성기가 단일출처(드리프트 방지)
from rebuild_memory_index import HARD_BYTES as MEMORY_LIMIT_B, HARD_LINES as MEMORY_LIMIT_LINES, SOFT_BYTES as SOFT_B

STUB_BYTES = 1200
KO_STOP = set("그 이 저 것 수 등 및 또 더 가 의 를 을 은 는 에 와 과 로 으로 도 만 한 할 함 됨 명 건 줄 후 전 시 중 및".split())


def read(p):
    try:
        with open(p, encoding="utf-8") as f:
            return f.read()
    except Exception:
        return ""


def stem(fn):
    return fn[:-3] if fn.endswith(".md") else fn


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--merge-jac", type=float, default=0.45)
    ap.add_argument("--now", type=float, default=None)
    args = ap.parse_args()
    now = args.now if args.now is not None else time.time()
    today = datetime.datetime.fromtimestamp(now).strftime("%Y-%m-%d")
    daystamp = datetime.datetime.fromtimestamp(now).strftime("%Y%m%d")

    if not os.path.isdir(MEM_DIR):
        print("기억 저장소 없음(%s) — 다이어트 대상 없음." % MEM_DIR)
        return 0
    files = sorted(f for f in os.listdir(MEM_DIR)
                   if f.endswith(".md") and f not in ("MEMORY.md", "PROJECT_STATUS.md"))
    fileset = set(files)
    bodies = {f: read(os.path.join(MEM_DIR, f)) for f in files}
    idx_text = read(MEMORY_IDX)
    ps_text = read(PROJECT_STATUS)
    claude_text = read(CLAUDE_MD)
    # 링크 슬러그는 kebab/snake 혼용 허용(rebuild_memory_index 의 넓은 파일명 규약과 정렬)
    link_re = re.compile(r"\[\[([a-z0-9_\-]+)\]\]")

    # 인바운드
    inbound = collections.Counter()
    for b in list(bodies.values()) + [ps_text, claude_text]:
        for m in link_re.findall(b):
            inbound[m] += 1

    findings = collections.defaultdict(list)   # reason -> [(name, evidence)]

    # 1) 인덱스 무결성 (인덱스 줄 = plain '- name — desc'; 옛 링크형도 허용)
    #    파일명 char class 는 rebuild_memory_index 와 정렬(하이픈·점·대문자 허용 → orphan 오탐 차단).
    idx_names = set(
        (m.group(1) or m.group(2))
        for m in re.finditer(r'(?m)^- (?:\[([A-Za-z0-9._\-]+\.md)\]\([^)]*\)|([A-Za-z0-9._\-]+\.md)) — ', idx_text))
    for f in files:
        if f not in idx_names:
            findings["index_orphan"].append((stem(f), "memory/ 존재·인덱스 부재"))
    for m in idx_names:
        if m not in fileset and m not in ("MEMORY.md", "PROJECT_STATUS.md"):
            findings["index_dangling"].append((stem(m), "인덱스 줄 존재·파일 부재"))

    # 2) dangling [[link]] (리터럴 'link' 제외)
    targets = set()
    for b in list(bodies.values()) + [ps_text, claude_text]:
        targets.update(link_re.findall(b))
    for t in sorted(targets):
        if t == "link":
            continue
        if (t + ".md") not in fileset:
            findings["dangling_link"].append((t, "본문 [[%s]] 의 %s.md 부재" % (t, t)))

    # 3) 스텁
    for f in files:
        b = len(bodies[f].encode("utf-8"))
        if b < STUB_BYTES:
            findings["stub_review"].append((stem(f), "%dB·inbound=%d" % (b, inbound.get(stem(f), 0))))

    # 4) 병합 중복(동일 prefix·키워드 Jaccard)
    def keywords(b):
        toks = re.findall(r"[A-Za-z][A-Za-z0-9_]{2,}|[가-힣]{2,}", b.lower())
        return set(t for t in toks if t not in KO_STOP)
    kw = {f: keywords(bodies[f][:1500]) for f in files}
    by_prefix = collections.defaultdict(list)
    for f in files:
        by_prefix[f.split("_")[0]].append(f)
    seen_merge = set()
    for grp in by_prefix.values():
        for i in range(len(grp)):
            for j in range(i + 1, len(grp)):
                a, b = grp[i], grp[j]
                ka, kb = kw[a], kw[b]
                if not ka or not kb:
                    continue
                jac = len(ka & kb) / len(ka | kb)
                if jac >= args.merge_jac:
                    key = tuple(sorted((stem(a), stem(b))))
                    if key not in seen_merge:
                        seen_merge.add(key)
                        findings["merge_overlap"].append(("%s ⇄ %s" % key, "키워드중복 %.2f" % jac))

    # 5) 종료 프로젝트 cross-ref — 메모리별 상태 합산(per-line 전파의 오탐 차단)
    #    한 메모리는 여러 PS 줄에 링크될 수 있다(예: 🚫 하위결정 줄 + ✅ LIVE 현역 줄).
    #    줄 단위로 frozen 을 전파하면 하위결정 🚫 가 현역 메모리 전체를 종료로 오탐한다
    #    → 메모리별로 합산하고, 명시적 live 신호(🔴/🔶 또는 LIVE 토큰)가 한 줄이라도 있으면 frozen 에서 제외.
    #    ✅ 는 'LIVE-현역'과 '완료-보관가능'이 섞여 약한 신호 → 단독 live 취급 안 함.
    #    report-only 다이어트는 false negative(종료 후보 일부 누락)가
    #    false positive(현역 오탐)보다 안전. 누락분은 다음 수동 라운드에서 발견.
    EMO = ("🔴", "🔶", "⏳", "✅", "🚫", "↩️")
    LIVE_EMO = ("🔴", "🔶")
    LIVE_TOK = ("LIVE", "가동", "운영중", "현역", "매분", "프로덕션")
    mem_ps = collections.defaultdict(list)  # 메모리 → [(prim, frozen, live, tag), ...]
    for line in ps_text.splitlines():
        s = line.lstrip("- ").strip()
        if not s.startswith("["):
            continue
        prim = next((e for e in EMO if e in line), None)
        live = (prim in LIVE_EMO) or any(t in line for t in LIVE_TOK)
        # 종료/번복만. '유지모드 동결'(=✅ 건강한 완료 상태)은 제외 — 종료 프로젝트 아님.
        frozen = prim in ("🚫", "↩️") or ("동결" in line and "유지모드" not in line and prim not in ("🔶", "🔴", "✅"))
        tag = s[1:s.index("]")] if "]" in s else ""
        for lk in link_re.findall(line):
            if (lk + ".md") in fileset:
                mem_ps[lk].append((prim or "동결", frozen, live, tag))
    for lk, rows in mem_ps.items():
        if any(r[1] for r in rows) and not any(r[2] for r in rows):
            states = " / ".join("%s %s" % (r[0], r[3]) for r in rows)
            findings["frozen_review"].append((lk, "PS 상태들: %s (태그≠메모리범위 주의)" % states))

    # ── 콘솔 리포트 ──
    idx_b = len(idx_text.encode("utf-8"))
    idx_lines = idx_text.count("\n") + 1
    print("=== 기억 다이어트 triage (report-only · 사실 기반 · %s) ===" % today)
    print("스캔 %d 메모리 파일" % len(files))
    print("예산: MEMORY.md %dB/%dB (여유 %dB%s) · %d줄/%d줄"
          % (idx_b, MEMORY_LIMIT_B, MEMORY_LIMIT_B - idx_b,
             " ⚠소프트선 초과" if idx_b > SOFT_B else "", idx_lines, MEMORY_LIMIT_LINES))
    order = ["index_orphan", "index_dangling", "dangling_link", "frozen_review", "stub_review", "merge_overlap"]
    total = 0
    for r in order:
        items = findings.get(r, [])
        total += len(items)
        tag = "✓ 없음(clean)" if not items else "%d건" % len(items)
        print("\n[%s] %s" % (r, tag))
        for name, ev in items:
            print("   - %-46s %s" % (name, ev))
    print("\n총 triage 항목 %d건. 구조적 사실만 — '낡음' 추측 안 함(완료 메모리는 의도적 보존)." % total)

    # ── 매니페스트 ──
    os.makedirs(REPORT_DIR, exist_ok=True)
    mpath = os.path.join(REPORT_DIR, "diet-candidates-%s.md" % daystamp)
    arch = ARCHIVE_DIR.rstrip("/") + "/"
    L = [
        "# 기억 다이어트 triage 매니페스트 (%s · diet_suggest.py)" % today,
        "",
        "> **report-only · 사실 기반.** 체크([x])한 항목만 사용자 승인분. 자동삭제 안 함.",
        "> 예산: MEMORY.md %dB/%dB (여유 %dB) · %d줄/%d줄." % (idx_b, MEMORY_LIMIT_B, MEMORY_LIMIT_B - idx_b, idx_lines, MEMORY_LIMIT_LINES),
        "> 적용: 체크 후 (필요 시) 링크 rewrite → `mv <file> %s` → `rebuild_memory_index.py --apply`." % arch,
        "",
    ]
    titles = {
        "index_orphan": "인덱스 누락(추가 또는 아카이브 결정)",
        "index_dangling": "인덱스 dangling(줄 제거)",
        "dangling_link": "본문 dangling 링크(정리)",
        "frozen_review": "종료 프로젝트 보관 검토(사용자 판단)",
        "stub_review": "스텁 병합 검토(작음=정상일 수 있음)",
        "merge_overlap": "병합 중복 검토",
    }
    for r in order:
        items = findings.get(r, [])
        L.append("## %s (%d) — `%s`" % (titles[r], len(items), r))
        if not items:
            L.append("- (없음 — clean)")
        for name, ev in items:
            L.append("- [ ] %s  — %s" % (name, ev))
        L.append("")
    L += [
        "## 적용 절차(사용자 승인 후)",
        "1. 위 항목 [x] 체크.",
        "2. dangling 링크 = 본문에서 해당 [[링크]] 제거/수정(아카이브 잔재면 삭제).",
        "3. 아카이브: `mv %s<file> %s` (얽힌 링크 rewrite 먼저)." % (MEM_DIR.rstrip("/") + "/", arch),
        "4. 인덱스 재생성: `python3 rebuild_memory_index.py --apply`.",
        "5. archive 폴더 = 롤백 경로(git 없음).",
        "",
    ]
    tmp = "%s.tmp.%d" % (mpath, os.getpid())   # 원자쓰기: 부분/동시 산출 리포트가 '완료'로 멱등 승격되는 것 차단
    with open(tmp, "w", encoding="utf-8") as f:
        f.write("\n".join(L) + "\n")
    os.replace(tmp, mpath)
    print("\n매니페스트: %s" % mpath)
    return 0


if __name__ == "__main__":
    sys.exit(main())
