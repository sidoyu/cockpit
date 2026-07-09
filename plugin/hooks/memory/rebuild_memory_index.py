#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""rebuild_memory_index.py — MEMORY.md 결정적 생성기 (cwp Phase B, 2026-06-10).

frontmatter `description` = 단일 출처 → MEMORY.md 인덱스를 결정적으로 재생성한다.
수동 인덱스 편집을 대체한다(수동으로 고친 후크는 다음 실행에서 description 으로 되돌아감).

설계 원칙 (reference_memory_index_budget · cwp-living-review '현재 위치'):
- **reconciler**: 기존 MEMORY.md 의 항목 순서 보존(최소 diff·recall 연속성). 신규 파일은
  footer 앞에 파일명순 append, 소실 파일 줄은 drop+보고. 같은 입력 → 같은 출력.
- **예산**: HARD 24,500B/195줄(TEST9 동일)·SOFT 24,000B(보고만). 초과 시 기본 = **쓰기 거부**
  (exit 2 + 아카이브 후보 보고). `--allow-truncate` 명시 시만 water-filling 절삭
  (description 만, 링크토큰=고정 overhead 절삭 금지, UTF-8 문자경계, per-entry floor 미달=exit 2).
  근거: "키워드 절삭=비대칭 손해" 사용자 결정(2026-06-09/10 다이어트 라운드).
- **파이프라인 고정**: parse → build → lint+hard check(메모리상) → 임시파일 → diff →
  (--apply 시) 백업 → atomic replace → fsync → 감사로그(intent.log) → 사후 재검증.
- **fail-loud**: cwp_guard(fail-open)와 반대 — 이 스크립트는 쓰기 경로라 모든 이상에서
  멈추고(exit 2) 아무것도 바꾸지 않는 쪽이 안전.

사용:
  rebuild_memory_index.py            # dry-run: 보고 + diff, 무변경
  rebuild_memory_index.py --apply    # 백업 후 교체
  rebuild_memory_index.py --check    # 현재 파일 == 생성본 이면 exit 0, 드리프트면 1
테스트 격리: MEMORY_DIR / CWP_STATE_DIR env override (실데이터 비오염).
롤백: cwp_state/MEMORY.md.bak.rebuild-<ts> 를 MEMORY.md 로 복사.
"""
import sys, os, re, json, time, difflib, hashlib, shutil, unicodedata, argparse, fcntl

_HERE = os.path.dirname(os.path.realpath(__file__))
if _HERE not in sys.path:
    sys.path.insert(0, _HERE)
from cc_paths import MEMORY_DIR as MEM_DIR, CWP_STATE
INDEX = os.path.join(MEM_DIR, "MEMORY.md")
INTENT_LOG = os.path.join(CWP_STATE, "intent.log")

HARD_BYTES, HARD_LINES, SOFT_BYTES = 24500, 195, 24000
FLOOR = 80          # --allow-truncate 시 per-entry description 최소 보장 바이트(미달=아카이브 신호)
ELLIPSIS = "…"      # 3 bytes UTF-8

ENTRY_RE = re.compile(r'^- \[([^\]]+)\]\(([^)]+)\) — (.*)$')
# 관용 파서(lenient): Claude Code 내장 auto memory 가 같은 디렉터리에 색인 줄을 직접 쓸 수 있다
# (`autoMemoryDirectory` 로 cc-memory 를 auto memory 위치로 지정 — 그래야 MEMORY.md 가 세션 시작에
#  로드된다. 미설정 시 이 색인은 아무도 읽지 않는다: 실측 NOTSEEN/SEEN). 하네스가 쓰는 줄은
# `- [사람이 읽는 제목](file.md) — hook` 처럼 **라벨≠타겟**이거나 구분자가 다를 수 있다.
# 이런 줄에 hard-fail 하면 생성기가 멈추고(hook 은 fail-soft) 색인이 조용히 언다 → 정규화해서 흡수한다.
_FNAME = r'[^/\\<>:"|?*\s\]]+\.md'
ENTRY_LOOSE_RE = re.compile(r'^- \[([^\]]+)\]\((' + _FNAME + r')\)[ \t]*(?:—|–|:|-)[ \t]*(.*)$')
BARE_ENTRY_RE = re.compile(r'^- (' + _FNAME + r')[ \t]*(?:—|–|:|-)[ \t]*(.*)$')
SENTINEL_MARK = "MEMORY_INDEX_END"
SENTINEL_DEFAULT = "<!-- MEMORY_INDEX_END · 자동 생성(rebuild_memory_index.py) · 직접 편집 금지 -->"
# frontmatter 없는 특수 파일: 기존 인덱스 줄을 그대로 유지. 인덱스 줄까지 사라진 경우(하네스가
# MEMORY.md 를 통째로 다시 쓴 경우)에도 멈추지 않도록 마지막 방어선 hook 을 둔다.
PINNED_NO_FM = {"PROJECT_STATUS.md"}
PINNED_FALLBACK = {
    "PROJECT_STATUS.md": "현재 권위 상태(결정·완료·금지) 단일 계층, SessionStart 결정적 주입",
}
NO_DESC = "(설명 미작성)"

SECRET_PATTERNS = [
    r'AKIA[0-9A-Z]{16}', r'\bsk-[A-Za-z0-9_-]{16,}', r'\bghp_[A-Za-z0-9]{20,}',
    r'\bgho_[A-Za-z0-9]{20,}', r'xox[baprs]-', r'AIza[0-9A-Za-z_-]{20,}',
    r'PRIVATE KEY', r'\beyJ[A-Za-z0-9_-]{20,}',
    r'(?i)(password|passwd|secret|token)\s*[=:]\s*\S{8,}',
]
# long hex 는 sha/hash 언급 오탐 가능성 높음(Codex Q3) → error 아닌 warning
SECRET_WARN_PATTERNS = [r'\b[0-9a-f]{32,}\b']
PII_PATTERNS = [r'\b\d{6}-[1-4]\d{6}\b', r'\b010-\d{3,4}-\d{4}\b']
# 명령문 lint 는 좁은 파괴 패턴만(gh auth switch 같은 정상 명령 후크는 통과해야 함)
DESTRUCT_PATTERNS = [
    r'rm\s+-rf\s+[/~]', r'\bsudo\s+rm\b', r'curl[^|\n]*\|\s*(ba)?sh',
    r'\bdd\s+if=', r'\bmkfs', r'DROP\s+TABLE', r'push\s+--force',
]


def fail(msgs):
    for m in (msgs if isinstance(msgs, list) else [msgs]):
        print("✗ %s" % m, file=sys.stderr)
    sys.exit(2)


def _match_entry(ln):
    """색인 줄 → (label, target, hook) 또는 None.
    **표준형(ENTRY_RE)을 먼저** 본다 — loose 의 `_FNAME` 은 공백·특수문자를 배제하므로, 순서를 뒤집으면
    `- [my file.md](my file.md) — d` 같은 **합법 표준 줄**이 '파싱 불가'로 떨어져 기존 hook 이 유실된다."""
    m = ENTRY_RE.match(ln)
    if m:
        return m.group(1), m.group(2), m.group(3)
    m = ENTRY_LOOSE_RE.match(ln)
    if m:
        return m.group(1), m.group(2), m.group(3)
    m = BARE_ENTRY_RE.match(ln)
    if m:
        return m.group(1), m.group(1), m.group(2)
    return None


def parse_index(text, strict=False):
    """현 MEMORY.md → (entries [(fname, hook)], footer lines, interleaved, anomalies).

    링크 타겟이 파일명의 **단일 출처**다(라벨은 표시용). 라벨≠타겟·비표준 구분자는 정규화해서
    흡수하고 anomalies 로 보고한다 — strict 모드에서만 치명. 파싱 불가한 항목-유사 줄은 색인에서
    제외한다(항목은 어차피 디스크의 파일 + frontmatter 로 재생성되므로 유실 아님)."""
    entries, footer, anomalies = [], [], []
    interleaved, sentinel_seen = False, 0
    for ln in text.splitlines():
        hit = _match_entry(ln)
        if hit:
            label, target, hook = hit
            if footer:
                interleaved = True   # 항목이 footer 뒤에 또 나옴 — 보고만(재배치됨)
            if label != target:
                anomalies.append("링크 라벨≠타겟 — 타겟을 파일명으로 채택: %r" % ln[:80])
            elif not ENTRY_RE.match(ln):
                anomalies.append("비표준 색인 줄 — 표준형으로 정규화: %r" % ln[:80])
            entries.append((target, hook))
        elif SENTINEL_MARK in ln:
            sentinel_seen += 1
        elif ln.strip():
            # 깨진 entry 조각이 footer 로 위장 잔존하는 것 차단(Codex impl #5) — 자유 텍스트(📦 등)는 허용
            if ln.lstrip().startswith("- [") or ".md)" in ln:
                anomalies.append("항목 형식 유사하나 파싱 불가 — 색인에서 제외(파일에서 재생성): %r" % ln[:80])
                continue
            footer.append(ln)
    if sentinel_seen > 1:
        fail("sentinel 중복 %d개 — 파일 손상 의심, 수동 확인 필요(Codex Q1)" % sentinel_seen)
    if strict and anomalies:
        fail(anomalies)
    return entries, footer, interleaved, anomalies


def _looks_sensitive(s):
    """색인(=매 세션 로드되는 프롬프트 표면)에 올리면 안 되는 문자열인가."""
    for p in SECRET_PATTERNS + PII_PATTERNS + DESTRUCT_PATTERNS:
        if re.search(p, s):
            return True
    return False


def derive_desc(path, cap=140):
    """frontmatter description 이 없는 파일의 hook 도출. 하네스(내장 auto memory)가 쓴 토픽 파일은
    description 이 없을 수 있는데, 그 한 건 때문에 색인 전체가 멈추면 안 된다.

    **제목(markdown 헤딩)만** 쓴다. 본문 첫 줄을 쓰면 `MEMORY.md` 는 매 세션 로드되는 표면이라
    본문 내용(PII·시크릿·엉뚱한 지시문)이 그대로 컨텍스트에 승격된다(Codex 4f 지적).
    헤딩이 없거나 민감해 보이면 자리표시자로 물러선다 — lint(치명)에 걸려 색인이 어는 것도 막는다.
    원본 파일은 어떤 경우에도 변경하지 않는다."""
    try:
        txt = open(path, encoding="utf-8").read()
    except Exception:
        return NO_DESC
    if txt.startswith("---"):
        end = txt.find("\n---", 3)
        if end >= 0:
            txt = txt[end + 4:]
    for ln in txt.splitlines():
        m = re.match(r'^\s{0,3}#{1,6}\s+(.+?)\s*#*\s*$', ln)
        if not m:
            continue
        s = re.sub(r'\s+', ' ', m.group(1)).strip()
        if not s or SENTINEL_MARK in s or _looks_sensitive(s):
            return NO_DESC
        return truncate_to(s, cap)
    return NO_DESC


def read_desc(path):
    """frontmatter description (단일행, 따옴표 해제). 반환 (desc, err)."""
    try:
        txt = open(path, encoding="utf-8").read()
    except Exception as e:
        return None, "읽기 실패: %s" % e
    if not txt.startswith("---"):
        return None, "frontmatter 없음"
    end = txt.find("\n---", 3)
    if end < 0:
        return None, "frontmatter 종결(---) 없음"
    m = re.search(r'^description:[ \t]*(.*)$', txt[3:end], re.M)
    if not m:
        return None, "description 없음"
    d = m.group(1).strip()
    if d in ("|", ">", "|-", ">-", "|+", ">+"):
        return None, "block scalar description 미지원(단일행 plain/quoted 만, Codex Q3)"
    if d.startswith('"') and d.endswith('"') and len(d) >= 2:
        d = d[1:-1].replace('\\"', '"').replace("\\\\", "\\")
    elif d.startswith("'") and d.endswith("'") and len(d) >= 2:
        d = d[1:-1].replace("''", "'")
    if not d:
        return None, "description 빈 값"
    if "\n" in d:
        return None, "description 멀티라인(단일행만 허용)"
    return d, None


def entry_line(fname, desc):
    return "- [%s](%s) — %s" % (fname, fname, desc)


def overhead_bytes(fname):
    return len(("- [%s](%s) — " % (fname, fname)).encode("utf-8"))


def truncate_to(desc, cap):
    """UTF-8 cap 바이트 이내로 문자경계 절삭 + ellipsis. cap ≥ FLOOR 전제."""
    raw = desc.encode("utf-8")
    if len(raw) <= cap:
        return desc
    budget = cap - len(ELLIPSIS.encode("utf-8"))
    out, used = [], 0
    for ch in desc:
        b = len(ch.encode("utf-8"))
        if used + b > budget:
            break
        out.append(ch)
        used += b
    return "".join(out) + ELLIPSIS


def water_fill_cap(items, fixed_total, budget):
    """sum(min(desc_bytes, C)) + fixed_total ≤ budget 인 최대 C. 불가능하면 None.
    items = [desc_bytes...]. 결정적(이분탐색)."""
    lo, hi, best = FLOOR, max(items + [FLOOR]), None
    while lo <= hi:
        mid = (lo + hi) // 2
        if fixed_total + sum(min(b, mid) for b in items) <= budget:
            best = mid
            lo = mid + 1
        else:
            hi = mid - 1
    return best


def _redact(s):
    return s[:2] + "…" + s[-2:] if len(s) > 6 else "***"


def run_lints(candidate, entries):
    """치명 lint(error 리스트)와 정보성 warning 리스트 반환.
    SECRET/PII 는 매칭값 평문 출력 금지(Codex impl #3) — 위치(항목/footer)+redact 만."""
    errors, warns = [], []
    # 항목별 스캔(위치 특정) + 나머지 줄(footer 등) 일괄
    units = [("entry:%s" % f, entry_line(f, d)) for f, d in entries]
    units.append(("footer/sentinel", "\n".join(
        ln for ln in candidate.splitlines() if not ENTRY_RE.match(ln))))
    for cat, pats, redact in (("SECRET", SECRET_PATTERNS, True), ("PII", PII_PATTERNS, True),
                              ("DESTRUCT", DESTRUCT_PATTERNS, False)):
        for p in pats:
            for loc, text in units:
                m = re.search(p, text)
                if m:
                    shown = _redact(m.group(0)) if redact else m.group(0)
                    errors.append("[%s lint] %s 에서 %r 매칭(%s)" % (cat, loc, p, shown))
                    break   # 패턴당 첫 위치만(나머지는 수정 후 재실행으로 드러남)
    for p in SECRET_WARN_PATTERNS:
        for loc, text in units:
            m = re.search(p, text)
            if m:
                warns.append("[SECRET lint·warn] %s long-hex 매칭(해시 언급 오탐 가능, %s) — 육안 확인"
                             % (loc, _redact(m.group(0))))
                break
    seen_names, seen_descs = set(), {}
    for fname, desc in entries:
        key = fname.lower()
        if key in seen_names:
            errors.append("[unique lint] 파일명 중복: %s" % fname)
        seen_names.add(key)
        nd = unicodedata.normalize("NFC", desc)
        if nd in seen_descs:
            errors.append("[unique lint] description 동일(라우팅 모호): %s == %s" % (fname, seen_descs[nd]))
        else:
            seen_descs[nd] = fname
        if SENTINEL_MARK in desc:
            errors.append("[format lint] description 에 sentinel 문자열: %s" % fname)
    # name 필드↔파일명 불일치는 기존 150건(역사적) — 건수만 보고, 차단하지 않음
    mismatch = 0
    for fname, _ in entries:
        if fname in PINNED_NO_FM:
            continue
        p = os.path.join(MEM_DIR, fname)
        try:
            txt = open(p, encoding="utf-8").read()
            end = txt.find("\n---", 3)
            m = re.search(r'^name:[ \t]*(.+)$', txt[3:end], re.M) if end > 0 else None
            if m and m.group(1).strip().strip('"\'') != fname[:-3]:
                mismatch += 1
        except Exception:
            pass
    info = []
    if mismatch:
        # 역사적 관례 혼재 146건 — 매 실행 경고는 진짜 경고를 묻음(Codex 4b 축8) → --verbose 전용 info
        info.append("frontmatter name≠파일명 %d건(역사적 관례 혼재, 링크 키=파일명이라 무해)" % mismatch)
    return errors, warns, info


def build(allow_truncate, strict=False):
    """후보 텍스트 생성. 반환 (candidate, report dict). 이상 시 fail().

    lenient(기본): description 부재는 본문에서 결정적으로 도출하고 `derived` 로 보고한다.
    strict: 옛 동작(하나라도 부재면 exit 2) — doctor·CI 가 규율을 강제할 때 쓴다."""
    if not os.path.isdir(MEM_DIR):
        fail("MEMORY_DIR 없음: %s" % MEM_DIR)
    files = sorted(f for f in os.listdir(MEM_DIR)
                   if f.endswith(".md") and f != "MEMORY.md"
                   and os.path.isfile(os.path.join(MEM_DIR, f)))
    cur_text = ""
    if os.path.exists(INDEX):
        cur_text = open(INDEX, encoding="utf-8").read()
    old_entries, footer, interleaved, anomalies = parse_index(cur_text, strict)
    # sentinel = 완전 상수(Codex serious point: 보존 방식은 stale metadata 위험·idempotence 유지 위해 통계/timestamp 미포함)
    sentinel = SENTINEL_DEFAULT
    old_hooks = dict(old_entries)

    errors, dropped, added, changed, derived = [], [], [], [], []
    derived_files = set()

    def _hook_for(fname, err):
        """description 부재 시 hook 결정: 기존 색인 줄 > 본문 도출. derived 에 기록."""
        d = old_hooks.get(fname) or derive_desc(os.path.join(MEM_DIR, fname))
        derived.append("%s(%s)" % (fname, err))
        derived_files.add(fname)
        return d

    out_entries = []   # (fname, desc)
    fileset = set(files)
    indexed = set()
    for fname, hook in old_entries:
        if fname in indexed:
            continue      # 중복 색인 줄(하네스 재기입 등) — 첫 줄만 채택
        indexed.add(fname)
        if fname not in fileset:
            dropped.append(fname)
            continue
        if fname in PINNED_NO_FM:
            out_entries.append((fname, hook))   # frontmatter 없는 특수 파일: 기존 줄 유지
            continue
        desc, err = read_desc(os.path.join(MEM_DIR, fname))
        if err:
            if strict:
                errors.append("%s: %s" % (fname, err))
                continue
            desc = _hook_for(fname, err)
        if desc != hook:
            changed.append(fname)
        out_entries.append((fname, desc))
    for fname in files:
        if fname in indexed:
            continue
        if fname in PINNED_NO_FM:
            # 색인 줄이 사라진 경우(하네스가 MEMORY.md 를 통째로 재기입) — 상수 hook 으로 복구
            if strict or fname not in PINNED_FALLBACK:
                errors.append("%s: 인덱스 줄이 없고 frontmatter 도 없음 — 수동 1줄 추가 필요" % fname)
                continue
            out_entries.append((fname, PINNED_FALLBACK[fname]))
            added.append(fname)
            derived.append("%s(색인 줄 소실 → 기본 hook 복구)" % fname)
            derived_files.add(fname)
            continue
        desc, err = read_desc(os.path.join(MEM_DIR, fname))
        if err:
            if strict:
                errors.append("%s: %s (신규 파일 — description 작성 필요)" % (fname, err))
                continue
            desc = _hook_for(fname, err)
        out_entries.append((fname, desc))
        added.append(fname)
    if errors:
        fail(errors)

    # 파생 hook 이 서로/기존과 겹치면 unique lint(치명)에 걸려 색인이 언다 → 파생분만 결정적으로 유일화.
    if derived_files:
        seen = {}
        uniq = []
        for fname, desc in out_entries:
            key = unicodedata.normalize("NFC", desc)
            if key in seen and fname in derived_files:
                desc = "%s [%s]" % (desc, fname[:-3])
                key = unicodedata.normalize("NFC", desc)
            seen[key] = fname
            uniq.append((fname, desc))
        out_entries = uniq

    # ---- 예산 ----
    tail_lines = footer + [sentinel]
    fixed = sum(overhead_bytes(f) for f, _ in out_entries) \
        + sum(len(l.encode("utf-8")) for l in tail_lines) \
        + len(out_entries) + len(tail_lines)          # 각 줄의 '\n'
    desc_bytes = [len(d.encode("utf-8")) for _, d in out_entries]
    total = fixed + sum(desc_bytes)
    truncated = []
    if total > HARD_BYTES:
        top = sorted(((b, f) for (f, _), b in zip(out_entries, desc_bytes)), reverse=True)[:10]
        over_msg = ["예산 초과: %dB > HARD %dB (+%dB) — 아카이브 신호" % (total, HARD_BYTES, total - HARD_BYTES),
                    "아카이브/병합 후보(후크 큰 순): " + ", ".join("%s(%dB)" % (f, b) for b, f in top)]
        if not allow_truncate:
            fail(over_msg + ["절삭은 키워드 손상(비대칭 손해) — 기본 거부. 비상시 --allow-truncate."])
        cap = water_fill_cap(desc_bytes, fixed, HARD_BYTES)
        if cap is None or cap < FLOOR:
            fail(over_msg + ["floor(%dB) 까지 절삭해도 예산 불가 — 아카이브 필수." % FLOOR])
        new_entries = []
        for (fname, desc), b in zip(out_entries, desc_bytes):
            if b > cap:
                desc = truncate_to(desc, cap)
                truncated.append("%s %d→%dB" % (fname, b, len(desc.encode("utf-8"))))
            new_entries.append((fname, desc))
        out_entries = new_entries

    lines = [entry_line(f, d) for f, d in out_entries] + tail_lines
    candidate = "\n".join(lines) + "\n"
    cb, cl = len(candidate.encode("utf-8")), len(lines)
    if cb > HARD_BYTES:
        fail("내부 오류: 절삭 후에도 %dB > %dB" % (cb, HARD_BYTES))
    if cl > HARD_LINES:
        fail("줄수 초과: %d줄 > %d — 줄 절삭은 불가, 아카이브 필수(진짜 천장=200줄)." % (cl, HARD_LINES))

    lint_errors, warns, info = run_lints(candidate, out_entries)
    if lint_errors:
        fail(lint_errors)
    if interleaved:
        warns.append("footer 뒤 항목 줄 발견 — 항목 블록으로 재배치됨(diff 확인)")
    for a in anomalies:
        warns.append("[색인 정규화] %s" % a)
    if derived:
        warns.append("description 부재 %d건 — 본문에서 도출(원본 파일에 description 추가 권장): %s"
                     % (len(derived), ", ".join(derived[:8]) + ("…" if len(derived) > 8 else "")))

    report = {
        "entries": len(out_entries), "added": added, "dropped": dropped,
        "changed": changed, "truncated": truncated, "bytes": cb, "lines": cl,
        "derived": derived, "anomalies": anomalies,
        "soft_over": max(0, cb - SOFT_BYTES), "warns": warns, "info": info,
        "cur_text": cur_text, "old_sha": hashlib.sha256(cur_text.encode("utf-8")).hexdigest()[:12],
        "new_sha": hashlib.sha256(candidate.encode("utf-8")).hexdigest()[:12],
    }
    return candidate, report


def append_audit(record):
    """cwp intent.log 와 동일 계약(O_APPEND 단일 write, <4096B, valid-JSONL).
    실패 = fail-open 유지하되 큰 경고 + audit_write_ok=False 반환(Codex Q5)."""
    try:
        os.makedirs(os.path.dirname(INTENT_LOG), exist_ok=True)
        data = (json.dumps(record, ensure_ascii=False) + "\n").encode("utf-8")
        if len(data) >= 4096:
            record = {k: record[k] for k in ("ts", "sid", "tool", "kind", "old_sha", "new_sha")}
            data = (json.dumps(record, ensure_ascii=False) + "\n").encode("utf-8")
        fd = os.open(INTENT_LOG, os.O_WRONLY | os.O_APPEND | os.O_CREAT, 0o600)
        try:
            os.write(fd, data)
        finally:
            os.close(fd)
        return True
    except Exception as e:
        # 감사로그는 의무 기록 — 조용히 삼키지 않되, 본체(이미 적용됨)는 되돌리지 않는다
        print("⚠ 감사로그 기록 실패(audit_write_ok=false): %s" % e, file=sys.stderr)
        return False


def post_verify(candidate):
    """적용 후 디스크 재검증(TEST9 등가). 실패 메시지 리스트 반환(빈 리스트=통과)."""
    probs = []
    disk = open(INDEX, "rb").read()
    if disk != candidate.encode("utf-8"):
        probs.append("디스크 내용 ≠ 생성본")
    if SENTINEL_MARK.encode() not in disk[-200:]:
        probs.append("sentinel 이 파일 끝에 없음")
    if len(disk) > HARD_BYTES:
        probs.append("바이트 초과 %d" % len(disk))
    text = disk.decode("utf-8")
    linked = set(re.findall(r'(?m)^- \[[^\]]+\]\(([^/)]+\.md)\)', text))
    files = {f for f in os.listdir(MEM_DIR) if f.endswith(".md")} - {"MEMORY.md", "PROJECT_STATUS.md"}
    dangling = [l for l in linked if l not in files and l != "PROJECT_STATUS.md"]
    orphan = [f for f in files if f not in linked]
    if dangling or orphan:
        probs.append("드리프트 dangling=%d orphan=%d" % (len(dangling), len(orphan)))
    return probs


def main():
    ap = argparse.ArgumentParser(description="MEMORY.md 결정적 생성기 (cwp Phase B)")
    ap.add_argument("--apply", action="store_true", help="백업 후 atomic 교체(기본=dry-run)")
    ap.add_argument("--check", action="store_true", help="현재 파일==생성본 검사(드리프트 감지)")
    ap.add_argument("--allow-truncate", action="store_true",
                    help="예산 초과 시 water-filling 절삭 허용(기본=거부, 비상용)")
    ap.add_argument("--no-diff", action="store_true", help="diff 출력 생략")
    ap.add_argument("--verbose", action="store_true", help="정보성 lint(name 불일치 등)도 출력")
    ap.add_argument("--strict", action="store_true",
                    help="description 부재·비표준 색인 줄을 치명 오류로(기본=도출·정규화 후 진행). "
                         "규율 점검(doctor·CI)용 — 훅은 기본(관용)으로 호출해 색인이 얼지 않게 한다.")
    ap.add_argument("--sid", default="cli", help="감사로그용 세션 ID(8자리)")
    args = ap.parse_args()

    candidate, rep = build(args.allow_truncate, args.strict)
    identical = (candidate == rep["cur_text"])

    if args.check:
        print("check: %s (현재 %dB, 생성본 %dB)" %
              ("일치" if identical else "드리프트", len(rep["cur_text"].encode("utf-8")), rep["bytes"]))
        for w in rep["warns"]:
            print("⚠ %s" % w)
        sys.exit(0 if identical else 1)

    print("entries=%d bytes=%d/%d(hard) lines=%d/%d soft+%d" %
          (rep["entries"], rep["bytes"], HARD_BYTES, rep["lines"], HARD_LINES, rep["soft_over"]))
    for k in ("added", "dropped", "changed", "truncated"):
        if rep[k]:
            print("%s(%d): %s" % (k, len(rep[k]), ", ".join(rep[k][:15]) + ("…" if len(rep[k]) > 15 else "")))
    for w in rep["warns"]:
        print("⚠ %s" % w)
    if args.verbose:
        for i in rep["info"]:
            print("ℹ %s" % i)

    if identical:
        print("변경 없음 — MEMORY.md 는 이미 생성본과 동일.")
        if args.apply:   # "생성기 실행도 감사로그 기록" — no-op apply 도 남긴다
            append_audit({"ts": round(time.time(), 3), "sid": args.sid[:8],
                          "tool": "rebuild_index", "kind": "apply_noop", "path": INDEX,
                          "old_sha": rep["old_sha"], "new_sha": rep["new_sha"],
                          "bytes": rep["bytes"], "lines": rep["lines"],
                          "entries": rep["entries"], "agent": ""})
        sys.exit(0)

    if not args.no_diff:
        for ln in difflib.unified_diff(rep["cur_text"].splitlines(), candidate.splitlines(),
                                       fromfile="MEMORY.md(현재)", tofile="MEMORY.md(생성)", lineterm=""):
            print(ln)

    if not args.apply:
        print("\n[dry-run] 적용하려면 --apply (백업→atomic 교체→감사로그→재검증)")
        sys.exit(0)

    # ---- apply: flock → 백업 → 임시파일 → CAS → atomic replace → fsync → 감사로그 → 재검증 ----
    ts = time.strftime("%Y%m%d-%H%M%S")
    os.makedirs(CWP_STATE, exist_ok=True)
    # 생성기 인스턴스 간 동시 apply 직렬화(Codex impl #1). advisory — cwp Stage 3 락이 시스템 해법.
    lockf = open(os.path.join(CWP_STATE, "rebuild_index.lock"), "w")
    try:
        fcntl.flock(lockf, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except OSError:
        fail("다른 rebuild --apply 가 실행 중(lock 점유) — 종료 후 재시도")
    try:
        backup = None
        old_mode = 0o600   # 신규 생성 기본(Codex impl #4)
        if os.path.exists(INDEX):
            old_mode = os.stat(INDEX).st_mode & 0o777
            # 백업 유니크 보장 — 같은 초 재실행에도 절대 덮어쓰기 금지(Codex impl #2)
            backup = os.path.join(CWP_STATE, "MEMORY.md.bak.rebuild-%s-%d" % (ts, os.getpid()))
            n = 0
            while os.path.exists(backup):
                n += 1
                backup = os.path.join(CWP_STATE, "MEMORY.md.bak.rebuild-%s-%d-%d" % (ts, os.getpid(), n))
            shutil.copy2(INDEX, backup)
            os.chmod(backup, 0o600)
            # 백업 내구성(Codex Q5): 백업 파일 + 백업 디렉터리 fsync 후에만 replace 진행
            bfd = os.open(backup, os.O_RDONLY)
            try:
                os.fsync(bfd)
            finally:
                os.close(bfd)
            sfd = os.open(CWP_STATE, os.O_RDONLY)
            try:
                os.fsync(sfd)
            finally:
                os.close(sfd)
        tmp = os.path.join(MEM_DIR, ".MEMORY.md.tmp.%d" % os.getpid())
        try:
            with open(tmp, "w", encoding="utf-8") as f:
                f.write(candidate)
                f.flush()
                os.fsync(f.fileno())
            os.chmod(tmp, old_mode)
            # CAS: build 이후 인덱스가 바뀌었으면 stale candidate — 적용 중단(Codex impl #1)
            cur_now = ""
            if os.path.exists(INDEX):
                cur_now = open(INDEX, encoding="utf-8").read()
            if hashlib.sha256(cur_now.encode("utf-8")).hexdigest()[:12] != rep["old_sha"]:
                fail("build 이후 MEMORY.md 가 변경됨(동시 편집) — 적용 중단, 재실행 필요")
            os.replace(tmp, INDEX)
            dfd = os.open(MEM_DIR, os.O_RDONLY)
            try:
                os.fsync(dfd)
            finally:
                os.close(dfd)
        finally:
            if os.path.exists(tmp):
                os.unlink(tmp)
    finally:
        try:
            fcntl.flock(lockf, fcntl.LOCK_UN)
        finally:
            lockf.close()
    audit_ok = append_audit({
        "ts": round(time.time(), 3), "sid": args.sid[:8], "tool": "rebuild_index",
        "kind": "apply", "path": INDEX, "old_sha": rep["old_sha"], "new_sha": rep["new_sha"],
        "bytes": rep["bytes"], "lines": rep["lines"], "entries": rep["entries"],
        "added": len(rep["added"]), "dropped": len(rep["dropped"]),
        "changed": len(rep["changed"]), "truncated": rep["truncated"], "agent": "",
    })
    probs = post_verify(candidate)
    if probs:
        print("✗ 사후검증 실패: %s" % "; ".join(probs), file=sys.stderr)
        if backup:
            print("롤백: cp %s %s" % (backup, INDEX), file=sys.stderr)
        sys.exit(2)
    # 백업 retention(2026-06-18, 4b 축4): rebuild 백업 최신 20개만 유지(best-effort, 임계경로 밖)
    try:
        _baks = [os.path.join(CWP_STATE, _n) for _n in os.listdir(CWP_STATE)
                 if _n.startswith("MEMORY.md.bak.rebuild-")]
        _baks.sort(key=os.path.getmtime, reverse=True)
        for _old in _baks[20:]:
            os.unlink(_old)
    except Exception:
        pass
    print("적용 완료 %dB/%d줄. 백업=%s audit_write_ok=%s"
          % (rep["bytes"], rep["lines"], backup or "(신규)", str(audit_ok).lower()))


if __name__ == "__main__":
    main()
