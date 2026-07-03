#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""기억 신선도 점검 — report-only.

기억 본문 속 기계검증 가능 단언(파일경로·repo명·도메인·ID)을 추출해 실물과 대조,
4분류 보고서만 출력한다: 존재확인 / 불일치의심 / 검증불가 / 과거기록가능.

**기본 = 로컬 파일경로 존재검사만**(외부 호출 없음). repo·도메인·ID 검사는 아래 env 로
명시 설정할 때만 수행한다(설정 시 gh api·DNS 조회 = 외부 호출 발생).
  CC_FRESHNESS_REPO_ORGS   쉼표구분 GitHub org/user 목록(예: "myorg,myuser") → `owner/repo` 참조를 gh 로 확인
  CC_FRESHNESS_DOMAINS     쉼표구분 도메인 접미사(예: "example.com,foo.org") → 해당 도메인 DNS 조회
  CC_FRESHNESS_ID_RE       ID 추출 정규식(옵션) → 매칭 ID 를 '검증불가'로 분류(기계검증 경로 없음)

금지: 자동 수정 X · 기억 파일 표식 X. 분류는 휴리스틱 — 최종 판단은 사람.
경로: 기억 = cc_paths.MEMORY_DIR · 출력 = cc_paths.REPORT_DIR.
실행: python3 freshness_check.py  (다이어트/강등 라운드의 한 단계로 수동 실행)
"""
import os, re, sys, socket, subprocess, datetime

_HERE = os.path.dirname(os.path.realpath(__file__))
if _HERE not in sys.path:
    sys.path.insert(0, _HERE)
from cc_paths import MEMORY_DIR as MEM_DIR, REPORT_DIR

HOME = os.path.expanduser("~")

# 과거/계획 서술 맥락 마커 — 단언이 이 맥락에 있으면 불일치라도 "과거·계획기록가능"으로 강등
PAST_MARKERS = ["구 ", "옛", "과거", "아카이브", "보관함", "폐기", "강등", "이력",
                "사고", "레거시", "동결", "superseded", "~~", "백업", ".bak", "이전",
                "시나리오", "예정", "향후", "검토 중", "계획", "휘발 위험", "삭제"]
# 한글 조사가 경로 끝에 붙은 채 추출되는 오탐 보정용
JOSA = ["에서", "에는", "으로", "은", "는", "이", "가", "을", "를", "의", "에", "로", "와", "과", "도", "만"]
PLACEHOLDER_PAT = re.compile(r'(원하는|<[^>]*>|\{|YYYY|<date>|<slug>|\bfile\b)')

# 경로 패턴은 실제 HOME 에서 도출(개인 경로 하드코딩 없음)
_H = re.escape(HOME)
PATH_RE = re.compile(r'(?:~|%s)/[^\s`"\'()\[\],;:!?<>{}|]+' % _H)
BACKTICK_RE = re.compile(r'`((?:~|%s)/[^`]+)`' % _H)


def _csv_env(name):
    return [x.strip() for x in (os.environ.get(name) or "").split(",") if x.strip()]


# repo/도메인/ID 검사는 opt-in(env 설정 시에만 정규식 구성 → 미설정이면 추출 자체를 안 함 = 외부호출 0)
_REPO_ORGS = _csv_env("CC_FRESHNESS_REPO_ORGS")
REPO_RE = re.compile(r'\b(%s)/([A-Za-z0-9._\-]+)\b' % "|".join(re.escape(o) for o in _REPO_ORGS)) if _REPO_ORGS else None
_DOMAINS = _csv_env("CC_FRESHNESS_DOMAINS")
DOMAIN_RE = re.compile(r'\b([a-z0-9-]+\.(?:%s))\b' % "|".join(re.escape(d) for d in _DOMAINS)) if _DOMAINS else None
_ID_PAT = os.environ.get("CC_FRESHNESS_ID_RE") or ""
try:
    ID_RE = re.compile(_ID_PAT) if _ID_PAT else None
except re.error:
    ID_RE = None


def clean_path(p):
    p = p.rstrip(".,·…")
    while p and p[-1] in ")]»」』":
        p = p[:-1]
    return p


def is_past_context(line):
    return any(m in line for m in PAST_MARKERS)


def gh_repo_exists(full):
    """gh api로 repo 존재 확인. (True존재/False부재/None확인불가)"""
    try:
        r = subprocess.run(["gh", "api", f"repos/{full}", "--jq", ".id"],
                           capture_output=True, text=True, timeout=10)
        if r.returncode == 0:
            return True
        if "404" in (r.stderr or ""):
            return False
        return None
    except Exception:
        return None


def domain_resolves(d):
    try:
        socket.setdefaulttimeout(5)
        socket.getaddrinfo(d, None)
        return True
    except socket.gaierror:
        return False
    except Exception:
        return None


def main():
    if not os.path.isdir(MEM_DIR):
        print("기억 저장소 없음(%s) — 점검 대상 없음." % MEM_DIR)
        return 0
    today = datetime.date.today().isoformat()
    files = sorted(f for f in os.listdir(MEM_DIR)
                   if f.endswith(".md") and f != "MEMORY.md")
    # assertion -> {"kind","occurrences":[(file,lineno,line,past?)]}
    seen = {}
    for fn in files:
        for i, line in enumerate(open(os.path.join(MEM_DIR, fn), encoding="utf-8"), 1):
            past = is_past_context(line)
            # 백틱 안 경로는 공백 포함 전체를 우선 채택, 같은 줄의 절단 매치는 배제
            bt_paths = [clean_path(m.group(1).rstrip("/ ")) for m in BACKTICK_RE.finditer(line)]
            cands = list(dict.fromkeys(bt_paths))
            for m in PATH_RE.finditer(line):
                p = clean_path(m.group(0))
                if any(b.startswith(p) or p.startswith(b) for b in bt_paths):
                    continue
                cands.append(p)
            for p in cands:
                if len(p) < 4 or "*" in p or "$" in p or PLACEHOLDER_PAT.search(p):
                    continue
                seen.setdefault(("path", p), []).append((fn, i, line.strip(), past))
            if REPO_RE is not None:
                for m in REPO_RE.finditer(line):
                    seen.setdefault(("repo", f"{m.group(1)}/{m.group(2)}"), []).append((fn, i, line.strip(), past))
            if DOMAIN_RE is not None:
                for m in DOMAIN_RE.finditer(line):
                    seen.setdefault(("domain", m.group(1)), []).append((fn, i, line.strip(), past))
            if ID_RE is not None:
                for m in ID_RE.finditer(line):
                    seen.setdefault(("id", m.group(0)), []).append((fn, i, line.strip(), past))

    verified, mismatch, unverifiable, past_ok = [], [], [], []
    repo_cache, dom_cache = {}, {}
    for (kind, val), occs in sorted(seen.items()):
        if kind == "path":
            full = val.replace("~", HOME, 1) if val.startswith("~") else val
            ok = os.path.exists(full)
            if not ok:
                # "경로 변수명"·"스크립트 --플래그" 표기: 첫 공백 토큰이 존재하면 존재로 판정
                head = full.split(" ")[0]
                if head != full and os.path.exists(head):
                    ok = True
                # 조사 절단 보정: 끝의 한글 조사를 떼고 존재하면 존재로 판정
                for j in JOSA:
                    if not ok and val.endswith(j) and os.path.exists(full[: -len(j)]):
                        ok = True
                        break
                # 접두 디렉터리 자체가 없으면 진짜 불일치, 있으면 공백 절단 가능성 → 검증불가
                if not ok and " " not in val and os.path.isdir(os.path.dirname(full)):
                    parent_entries = os.listdir(os.path.dirname(full))
                    base = os.path.basename(full)
                    if any(e.startswith(base) for e in parent_entries):
                        ok = None  # 같은 접두의 항목 존재 = 절단 의심
        elif kind == "repo":
            if val not in repo_cache:
                repo_cache[val] = gh_repo_exists(val)
            ok = repo_cache[val]
            # 비공개 repo 는 권한으로 404 가능 → 참고: 최종 판단은 사람(보고서 주석 참조)
        elif kind == "domain":
            if val not in dom_cache:
                dom_cache[val] = domain_resolves(val)
            ok = dom_cache[val]
        else:  # id — 기계검증 경로 없음
            ok = None
        entry = (kind, val, occs)
        if ok is True:
            verified.append(entry)
        elif ok is None:
            unverifiable.append(entry)
        else:
            if all(past for *_, past in occs):
                past_ok.append(entry)
            else:
                mismatch.append(entry)

    os.makedirs(REPORT_DIR, exist_ok=True)
    out = os.path.join(REPORT_DIR, f"freshness-{today.replace('-', '')}.md")
    tmp = "%s.tmp.%d" % (out, os.getpid())   # 원자쓰기: 중단 시 부분 리포트가 완성본처럼 남는 것 차단
    ext_note = []
    if REPO_RE is not None:
        ext_note.append("repo(gh): %s" % ",".join(_REPO_ORGS))
    if DOMAIN_RE is not None:
        ext_note.append("domain(DNS): %s" % ",".join(_DOMAINS))
    if ID_RE is not None:
        ext_note.append("id: /%s/" % _ID_PAT)
    with open(tmp, "w", encoding="utf-8") as w:
        w.write(f"# 기억 신선도 점검 보고서 — {today}\n\n")
        w.write("> report-only. 자동 수정 없음. 분류는 휴리스틱이므로 최종 판단은 사람.\n")
        w.write("> 과거기록가능 = 모든 출현이 과거 서술 맥락(구·아카이브·사고 등)인 불일치 — 정정 불요 가능성.\n")
        if ext_note:
            w.write("> 외부검사 활성: %s (비공개 repo 는 권한으로 404 가능 — 불일치로 표시돼도 사람 확인).\n" % " · ".join(ext_note))
        else:
            w.write("> 외부검사 비활성(로컬 파일경로 존재검사만). repo·도메인 검사는 CC_FRESHNESS_* env 로 opt-in.\n")
        w.write("\n")
        w.write(f"검사 대상: 기억 파일 {len(files)}개 · 고유 단언 {len(seen)}건\n\n")
        w.write(f"| 분류 | 건수 |\n|---|---|\n| ① 존재확인 | {len(verified)} |\n"
                f"| ② 불일치의심 | {len(mismatch)} |\n| ③ 검증불가 | {len(unverifiable)} |\n"
                f"| ④ 과거기록가능 | {len(past_ok)} |\n\n")

        def section(title, items, show_ctx=True, cap=None):
            w.write(f"## {title} ({len(items)}건)\n\n")
            for n, (kind, val, occs) in enumerate(items):
                if cap and n >= cap:
                    w.write(f"- …외 {len(items)-cap}건 (생략)\n")
                    break
                locs = ", ".join(f"{f}:{ln}" for f, ln, *_ in occs[:5])
                w.write(f"- `{val}` ({kind}) — {locs}\n")
                if show_ctx:
                    for f, ln, ctx, _ in occs[:2]:
                        w.write(f"  - {f}:{ln}: {ctx[:150]}\n")
            w.write("\n")

        section("② 불일치의심 — 우선 검토", mismatch)
        section("④ 과거기록가능 — 참고", past_ok)
        section("③ 검증불가 — 기계검증 경로 없음(ID·권한 등)", unverifiable, show_ctx=False, cap=40)
        w.write(f"## ① 존재확인 ({len(verified)}건)\n\n생략(전수 나열 무가치). 건수만 기록.\n")
    os.replace(tmp, out)
    print(f"보고서: {out}")
    print(f"존재확인 {len(verified)} / 불일치의심 {len(mismatch)} / 검증불가 {len(unverifiable)} / 과거기록가능 {len(past_ok)}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
