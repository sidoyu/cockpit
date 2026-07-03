#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""cwp 감사로그 로테이션 — intent.log.

목적: intent.log 무한증가 억제. raw ~30일 보존, 그 이전은 압축하되 **포렌식 레코드는 장기 원문 보존**.
  3계층:
    1) intent.log         = 최근 RAW_DAYS(기본 30)일 raw (회전 후에도 남김)
    2) intent-audit.jsonl = 포렌식 레코드(아래 KEEP 조건) 원문 장기 보존 (append, 절대 압축 안 함)
    3) intent-monthly.jsonl = 비포렌식(read/other 등) 월별 집계 1줄/월

포렌식 KEEP 조건(사후 분석 가치 높음, 30일 넘어도 원문 보존):
    decision in (deny, override)  OR  reason != ""  OR  no_seen_edit == true
    OR  kind == "write"           OR  lock not in ("", None)
    OR  tool == "rebuild_index"   (생성기 apply 감사)

절단 순서(분석재료 유실 방지):
    backup → audit/summary temp 생성 → JSON 검증 → atomic replace(audit, monthly)
    → 신 intent.log temp 생성 → atomic replace(intent.log). 어느 단계든 실패 시 원본 유지.

혼합 스키마(Stage2/Stage3/rebuild_index) 안전: 필드 존재를 전역 가정하지 않고 .get() 분기.

경로: cwp 상태 = cc_paths.CWP_STATE(기본 CC_STATE_DIR/cwp_state, CWP_STATE_DIR 로 테스트 격리).
실행:
    rotate_intent_log.py            # dry-run (무엇이 회전될지 보고만)
    rotate_intent_log.py --apply    # 실제 회전(백업 후)
    rotate_intent_log.py --days 30  # raw 보존창(기본 30)
"""
import os, sys, json, time, argparse, datetime, tempfile, shutil

_HERE = os.path.dirname(os.path.realpath(__file__))
if _HERE not in sys.path:
    sys.path.insert(0, _HERE)
from cc_paths import CWP_STATE

INTENT_LOG = os.path.join(CWP_STATE, "intent.log")
AUDIT_LOG = os.path.join(CWP_STATE, "intent-audit.jsonl")     # 포렌식 원문 장기보존(append)
MONTHLY_LOG = os.path.join(CWP_STATE, "intent-monthly.jsonl")  # 비포렌식 월별 집계


def is_forensic(r):
    """장기 원문 보존 대상인가."""
    if r.get("decision") in ("deny", "override"):
        return True
    if r.get("reason"):
        return True
    if r.get("no_seen_edit") is True:
        return True
    if r.get("kind") == "write":
        return True
    if r.get("lock"):
        return True
    if r.get("tool") == "rebuild_index":
        return True
    return False


def month_key(ts):
    try:
        return datetime.datetime.fromtimestamp(ts).strftime("%Y-%m")
    except Exception:
        return "unknown"


def load(path):
    rows, bad = [], 0
    if not os.path.exists(path):
        return rows, bad
    with open(path, encoding="utf-8") as f:
        for ln in f:
            ln = ln.strip()
            if not ln:
                continue
            try:
                rows.append(json.loads(ln))
            except Exception:
                bad += 1
    return rows, bad


def summarize(old_nonforensic):
    """비포렌식 old 레코드를 월별 1줄 집계로 압축."""
    by_month = {}
    for r in old_nonforensic:
        mk = month_key(r.get("ts", 0))
        m = by_month.setdefault(mk, {
            "month": mk, "kind": "monthly_summary", "n": 0,
            "tool": {}, "rec_kind": {}, "token": {},
            "ts_min": None, "ts_max": None,
        })
        m["n"] += 1
        for fld, key in (("tool", "tool"), ("rec_kind", "kind"), ("token", "token")):
            v = r.get(key, "?") or "?"
            m[fld][v] = m[fld].get(v, 0) + 1
        ts = r.get("ts")
        if ts:
            m["ts_min"] = ts if m["ts_min"] is None else min(m["ts_min"], ts)
            m["ts_max"] = ts if m["ts_max"] is None else max(m["ts_max"], ts)
    return [by_month[k] for k in sorted(by_month)]


def atomic_write_lines(path, lines):
    """temp → fsync → atomic replace. lines = 이미 직렬화된 문자열 리스트(각 \\n 없음)."""
    d = os.path.dirname(path)
    fd, tmp = tempfile.mkstemp(dir=d, prefix=".rot-", suffix=".tmp")
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as f:
            for ln in lines:
                f.write(ln + "\n")
            f.flush()
            os.fsync(f.fileno())
        os.replace(tmp, path)
    except Exception:
        try:
            os.unlink(tmp)
        except OSError:
            pass
        raise


def append_lines(path, lines):
    """audit append — 기존 보존 + 추가. 새로 쓸 전체를 atomic 으로 재작성(원자성)."""
    existing = []
    if os.path.exists(path):
        with open(path, encoding="utf-8") as f:
            existing = [ln.rstrip("\n") for ln in f if ln.strip()]
    atomic_write_lines(path, existing + lines)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--apply", action="store_true", help="실제 회전(기본=dry-run)")
    ap.add_argument("--days", type=int, default=30, help="raw 보존창(일, 기본 30)")
    ap.add_argument("--now", type=float, default=None, help="기준 시각(테스트용 epoch)")
    args = ap.parse_args()

    now = args.now if args.now is not None else time.time()
    cutoff = now - args.days * 86400

    rows, bad = load(INTENT_LOG)
    if not rows:
        print(f"intent.log 비어있음/없음 ({INTENT_LOG}) — 회전 불필요")
        return 0

    recent = [r for r in rows if r.get("ts", 0) >= cutoff]
    old = [r for r in rows if r.get("ts", 0) < cutoff]
    old_forensic = [r for r in old if is_forensic(r)]
    old_nonforensic = [r for r in old if not is_forensic(r)]
    summaries = summarize(old_nonforensic)

    cut_d = datetime.datetime.fromtimestamp(cutoff).strftime("%Y-%m-%d %H:%M")
    print(f"=== intent.log 로테이션 {'[APPLY]' if args.apply else '[DRY-RUN]'} ===")
    print(f"총 {len(rows)}건 (파싱실패 {bad}) · 컷오프 {cut_d} (raw {args.days}일)")
    print(f"  최근(raw 유지)        : {len(recent)}")
    print(f"  과거 → 포렌식 원문보존 : {len(old_forensic)}  → {os.path.basename(AUDIT_LOG)}")
    print(f"  과거 → 월별 집계 압축   : {len(old_nonforensic)} → {len(summaries)}줄 {os.path.basename(MONTHLY_LOG)}")
    if old:
        print(f"  (압축비: {len(old)} old → {len(old_forensic)}+{len(summaries)} 보존줄)")
    if not old:
        print("  과거 레코드 없음 — 회전 불필요(no-op). raw 보존창 내 전부.")
        return 0
    for s in summaries:
        print(f"    [{s['month']}] n={s['n']} tool={s['tool']} kind={s['rec_kind']}")

    if not args.apply:
        print("\n[dry-run] 적용하려면 --apply (백업 → audit/monthly 검증쓰기 → intent.log 절단)")
        return 0

    # ---- APPLY: 절단 순서 엄수 ----
    ts = datetime.datetime.fromtimestamp(now).strftime("%Y%m%d-%H%M%S")
    bak = os.path.join(CWP_STATE, f"intent.log.bak.rotate-{ts}")
    shutil.copy2(INTENT_LOG, bak)
    print(f"\n백업: {bak}")

    # 1) audit append (포렌식 원문) — temp+검증은 atomic_write_lines 내부 fsync
    if old_forensic:
        append_lines(AUDIT_LOG, [json.dumps(r, ensure_ascii=False) for r in old_forensic])
        a_rows, a_bad = load(AUDIT_LOG)
        assert a_bad == 0, "audit 재검증 실패(파싱오류)"
        print(f"audit 보존: {os.path.basename(AUDIT_LOG)} 총 {len(a_rows)}줄")

    # 2) monthly summary 병합(기존 월 집계와 합산 없이 append — 같은 달 재회전 드묾, 단순/안전 우선)
    if summaries:
        append_lines(MONTHLY_LOG, [json.dumps(s, ensure_ascii=False) for s in summaries])
        m_rows, m_bad = load(MONTHLY_LOG)
        assert m_bad == 0, "monthly 재검증 실패"
        print(f"월별집계: {os.path.basename(MONTHLY_LOG)} 총 {len(m_rows)}줄")

    # 3) 마지막에 intent.log 를 recent 만으로 atomic 교체
    atomic_write_lines(INTENT_LOG, [json.dumps(r, ensure_ascii=False) for r in recent])
    final, f_bad = load(INTENT_LOG)
    assert f_bad == 0 and len(final) == len(recent), "intent.log 절단 재검증 실패"
    print(f"intent.log 절단 완료: {len(final)}줄 (raw {args.days}일)")
    print(f"롤백: cp {bak} {INTENT_LOG}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
