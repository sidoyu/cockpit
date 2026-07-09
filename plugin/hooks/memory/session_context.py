#!/usr/bin/env python3
"""
SessionStart hook (단일 통합):
  (0) pending 항목별 ack 큐에 status:new 가 있으면 알림 (구 check_pending.sh 흡수)
  (1) 동시세션 인지 — 동일/유사 프로젝트의 최근 30분 활성 세션을 내 컨텍스트에만 주입
  (2) PROJECT_STATUS.md 결정적 로드 — "현재 결론/완료/금지" 권위 상태를 시작 시 항상 주입

세 출력을 하나의 additionalContext로 합쳐 내보낸다 → 두 hook의 병합 런타임 의존을 제거(Codex audit #2).
출력은 Claude 컨텍스트에만 주입(사용자 화면 X, 차단 X).
설계 원칙: 절대 세션 시작을 막지 않는다 — 모든 단계 try/except, 실패 시 그 섹션만 생략.
관련: Stage 1,
"""
import json
import os
import re
import subprocess
import sys
from datetime import datetime

# pending frontmatter 파서 (top-level + harness 노드스키마 dual-schema).
# import 실패 시 구 top-level 동작으로 폴백 → SessionStart 를 절대 막지 않는다.
try:
    from pending_schema import pending_status, field
except Exception as _e:
    sys.stderr.write(f"[session_context] pending_schema import 실패 → top-level 폴백: {_e}\n")
    def pending_status(text):
        m = re.search(r"^status:\s*(\w+)", text or "", re.M)
        return m.group(1) if m else None
    def field(text, key):
        m = re.search(r"(?m)^[ \t]*" + re.escape(key) + r":[ \t]*(.*)$", text or "")
        return (m.group(1).strip().strip('"').strip("'").strip() or None) if m else None

_HERE = os.path.dirname(os.path.realpath(__file__))
if _HERE not in sys.path:
    sys.path.insert(0, _HERE)
import cc_paths
MEMORY_DIR = cc_paths.MEMORY_DIR
STATUS_FILE = cc_paths.STATUS_FILE
MEMORY_INDEX = cc_paths.MEMORY_INDEX
# 세션 트랜스크립트 디렉터리: 하드코딩 금지. 기본=cwd 인코딩 도출, main() 이 transcript_path 로 갱신.
PROJ_DIR = cc_paths.proj_transcript_dir()
# harness 는 MEMORY.md 를 앞 200줄 OR 25KB 까지만 로드(초과분 침묵 드롭).
# 2단(Codex 4f #4): SessionStart 는 소프트(24,000=조기 경고 리드), test 는 하드(24,500=게이트).
MEMORY_BUDGET = 24000
# PROJECT_STATUS.md 크기 예산(F2, 2026-06-19): 압축 목표 ~14KB → 재비만 조기 경고.
# 총량 SOFT/HARD + 줄당 SOFT/HARD(문단 재발 방지, Codex 권고). 측정·경고만(자동 절삭 안 함=사일런트 손실 방지).
STATUS_SOFT_BYTES = 16000
STATUS_HARD_BYTES = 24000
STATUS_LINE_SOFT = 900
STATUS_LINE_HARD = 1400
# 조건부 정리 넛지 임계(2026-06-05 사용자 결정 = 중간 프리셋). 차단 안 함(평소 침묵·임계 초과 시 차분 한 줄).
# new/skipped 는 pending/ 누적 건수, MEM 임계는 MEMORY_BUDGET 재사용(소프트경고와 단일 기준 → drift 방지).
NUDGE_NEW = 3       # pending status:new 미반영 누적 → 메모리 반영 권유
NUDGE_SKIP = 30     # pending 중 **사유코드(skip_reason) 미기입** skipped 누적 → 재검토 권유.
                    # 사유코드화(큐1, 2026-06-05) 후엔 정리완료 skip 은 세지 않음(영구 잔소리 방지) — 미정리 백로그만 발동.
# 정식 사유코드 4종(큐1). 이 집합 밖 값(오타·unverified_skip·빈값)은 '미정리'로 간주해 uncoded 에 포함
# → 오타가 재검토를 침묵시키는 사각지대 차단(Codex 발견1). 코드 추가 시 여기와 재검토 ledger 동시 갱신.
VALID_SKIP_REASONS = {"duplicate", "already_inline", "low_value", "config_detail"}
# pending ack 큐는 memory/ 밖(hook 디렉터리)에 둔다 (Fix B, 2026-05-30).
# 이유: harness 메모리 인덱서가 projects/.../memory/ 안의 모든 .md frontmatter 를
# 노드 스키마(name + metadata.*)로 canonicalize 한다. pending .md 가 그 대상이 되면
# extract_pending 가 쓴 top-level `status:` 가 nested `  status:` 로 바뀌어, 카운터/
# 회귀가드가 status 를 놓치는 latent 데이터손실이 난다(알림 누락·완료항목 회귀).
# hook 디렉터리는 그 인덱서 대상이 아니므로 top-level 포맷이 그대로 유지된다.
# (후속1: analyzed_sessions.json·락·retry 등 다른 hook 운영상태도 hooks/memory/ 로
#  함께 모았다 — extract_pending 가 관리. projects/.../memory/ 는 순수 지식(.md)만 남음.)
# pending_schema.py 의 dual-schema 파서는 B 이후에도 안전망으로 유지.
HOOK_DIR = _HERE
PENDING_DIR = cc_paths.PENDING_DIR
LEGACY_PENDING = os.path.join(cc_paths.STATE_DIR, "pending_analysis.md")
ACTIVE_WINDOW_MIN = 30
MAX_SESSIONS_SCANNED = 12


def read_input():
    try:
        raw = sys.stdin.read()
        if not raw.strip():
            return {}
        return json.loads(raw)
    except Exception:
        return {}


def git_root(path):
    try:
        out = subprocess.run(
            ["git", "-C", path, "rev-parse", "--show-toplevel"],
            capture_output=True, text=True, timeout=2,
        )
        if out.returncode == 0:
            return out.stdout.strip()
    except Exception:
        pass
    return ""


def session_cwd(jsonl_path):
    """jsonl 앞부분에서 그 세션의 cwd 추출."""
    try:
        with open(jsonl_path, "r", encoding="utf-8", errors="ignore") as f:
            for _ in range(12):
                line = f.readline()
                if not line:
                    break
                try:
                    d = json.loads(line)
                    cwd = d.get("cwd")
                    if cwd:
                        return cwd
                except Exception:
                    continue
    except Exception:
        pass
    return ""


def tail_lines(jsonl_path, n=400):
    """jsonl 끝 n줄. SessionStart 에서 같은 세션 파일을 last_tool_path·last_turn_ts 가
    각각 읽어 끝부분을 2회 통째로 readlines 하던 I/O 증폭(Codex 10축 #4)을 막기 위해
    1회 읽어 공유한다. 실패 시 빈 리스트(절대 차단 안 함)."""
    try:
        with open(jsonl_path, "r", encoding="utf-8", errors="ignore") as f:
            return f.readlines()[-n:]
    except Exception:
        return []


def last_turn_ts(jsonl_path, lines=None):
    """마지막 '실제 대화턴'(user/assistant) 의 timestamp(epoch). 없으면 0.0.
    C3 후속(2026-05-30): '유휴 N일' 을 파일 mtime 으로 재면, 대화 종료 후 쓰인
    비대화 system 이벤트(권한모드 변경 등)가 mtime 만 밀어올려 실제보다 젊게 표시된다
    (9a5eb944: 마지막 대화 05-18 인데 mtime 은 05-23 → 12일을 7일로 오표시).
    claude-logs 대시보드와 동일 기준(마지막 user/assistant 턴)으로 맞춘다.
    lines 가 주어지면 그 끝줄 리스트를 재사용(I/O 공유), 아니면 자체로 끝 400줄 읽음.
    tz: ts 는 aware(UTC), 호출부 now 는 naive(local) 이나 .timestamp() 가 둘 다 epoch 로
    환산하므로 비교는 정확(naive 비교로 바꾸지 말 것 — Codex 10축 #1)."""
    if lines is None:
        lines = tail_lines(jsonl_path, 400)
    for line in reversed(lines):
        try:
            d = json.loads(line)
            if d.get("type") in ("user", "assistant"):
                ts = d.get("timestamp")
                if ts:
                    return datetime.fromisoformat(ts.replace("Z", "+00:00")).timestamp()
        except Exception:
            continue
    return 0.0


def _redact(s):
    """다른 세션의 명령 문자열을 내 컨텍스트에 넣기 전 시크릿 마스킹(Codex audit #7)."""
    s = re.sub(r'([A-Za-z0-9_]*(?:KEY|TOKEN|SECRET|PASSWORD|PASSWD|BEARER)[A-Za-z0-9_]*\s*[=:]\s*)\S+',
               r'\1[REDACTED]', s, flags=re.I)
    s = re.sub(r'(Authorization\s*:?\s*)\S+', r'\1[REDACTED]', s, flags=re.I)
    s = re.sub(r'\b[A-Za-z0-9_\-]{32,}\b', '[REDACTED]', s)          # 긴 토큰/해시
    s = re.sub(r'([?&](?:token|key|secret|sig|access_token)=)[^&\s]+', r'\1[REDACTED]', s, flags=re.I)
    return s


def _display_path(p):
    """타 세션 경로(cwd·file_path)를 내 컨텍스트에 표시하기 전 위생 처리(후속 a, §4d).
    동일프로젝트 *판정* 은 raw 경로(realpath·match)로 하고 이 함수는 표시(display)에만 쓴다
    → 판정 정확성 불변. `_redact` 재사용은 32자+ 영숫자 run 을 통째 가려 UUID 디렉터리·해시
    빌드경로·긴 slug 파일명을 과마스킹하므로(Codex 정밀화) 경로 전용으로 분리한다.
    한글 환자명 등 임의 이름의 일반 검출은 신뢰성 없어 시도하지 않는다(억지 검출 금지);
    구조적 PII 최소화는 외부전송 정책(현행 유지) 영역으로 분리."""
    if not p:
        return p
    s = str(p)
    home = os.path.expanduser("~")
    if s == home or s.startswith(home + "/"):
        s = "~" + s[len(home):]
    # 쿼리스트링에 박힌 토큰·키만 제거(경로 세그먼트 자체는 보존 → 진단가치 유지)
    s = re.sub(r'([?&](?:token|key|secret|sig|access_token|api_key)=)[^&\s]+', r'\1[REDACTED]', s, flags=re.I)
    # 명백한 라벨드 시크릿(KEY=…/TOKEN:…)만 — 일반 경로엔 거의 없으나 file_path 가 명령 일부일 때 방어.
    # 값은 `[^&\s]+`(공백·& 전까지) — `\S+` 는 url 형 표시에서 뒤 &query 까지 과마스킹(Codex 4b 미세개선).
    s = re.sub(r'([A-Za-z0-9_]*(?:KEY|TOKEN|SECRET|PASSWORD|BEARER)[A-Za-z0-9_]*\s*[=:]\s*)[^&\s]+',
               r'\1[REDACTED]', s, flags=re.I)
    return s


def last_tool_path(jsonl_path, lines=None):
    """반환: (match, display)
    match  = 동일프로젝트 판정용 경로 문자열(내부에서만 사용, 외부 노출 안 함)
    display= 컨텍스트에 노출할 안전 문자열(file_path 우선, Bash는 시크릿 마스킹+축약)
    lines 가 주어지면 재사용(I/O 공유, Codex 10축 #4), 아니면 자체로 끝 80줄 읽음.
    (끝 400줄을 받아도 마지막 tool_use 를 찾는 동작은 동일 — 결과 불변.)"""
    if lines is None:
        lines = tail_lines(jsonl_path, 80)
    match, display = "", ""
    for line in lines:
        try:
            d = json.loads(line)
            if d.get("type") == "assistant":
                for it in d.get("message", {}).get("content", []):
                    if it.get("type") == "tool_use":
                        inp = it.get("input", {})
                        fp = inp.get("file_path")
                        cmd = inp.get("command")
                        if fp:
                            match = str(fp)
                            display = _display_path(str(fp))[:120]
                        elif cmd:
                            match = str(cmd)
                            display = "Bash: " + _redact(str(cmd))[:90]
        except Exception:
            continue
    return match, display


def _pending_counts():
    """pending/ 의 (new, skipped, uncoded_skipped) 건수 — pending_section·cleanup_nudge_section 단일출처.
    source_session 있는 정식 항목만 집계(수동 파일 오탐 방지, 기존 pending_section 필터 그대로).
    main 에서 1회 호출해 두 섹션이 공유 → 같은 디렉터리를 두 번 스캔하던 I/O 증폭 방지(Codex 10축 #4 정신).
    - skipped: status:skipped 전체(총량·투명성 보존).
    - uncoded_skipped: 그 중 **정식 사유코드 미기입**(skip_reason ∉ VALID_SKIP_REASONS = 오타·빈값·
      unverified_skip 포함 = 재검토 백로그). 사유코드화(큐1, 2026-06-05) 후 넛지는 이 값만 본다
      → 정리완료 skip 이 영구히 재검토를 권하지 않음(잔소리 방지). skip_reason 은 frontmatter
      최상단에 와 head(400B) 안에서 파싱됨(nested 스키마의 들여쓰긴 status 아래 skip_reason 도 인식).
    어떤 예외도 (0, 0, 0) 으로 흡수 — SessionStart 비차단 불변식 유지."""
    new = skipped = uncoded = 0
    try:
        if os.path.isdir(PENDING_DIR):
            for name in os.listdir(PENDING_DIR):
                if not name.endswith(".md"):
                    continue
                try:
                    with open(os.path.join(PENDING_DIR, name), "r", encoding="utf-8") as f:
                        # 2000B: frontmatter 전체 커버(큐1서 skip_reason/skip_ref/skip_note 가 status~source_session
                        # 사이에 들어가 400B 경계 밖으로 source_session 이 밀릴 수 있던 잠복버그 차단, Codex 발견1)
                        head = f.read(2000)
                    # frontmatter에 source_session 있는 정식 항목만 카운트(수동 파일 오탐 방지, Codex audit)
                    if "source_session:" not in head:
                        continue
                    st = pending_status(head)
                    if st == "new":
                        new += 1
                    elif st == "skipped":
                        skipped += 1
                        # 정식 사유코드(VALID_SKIP_REASONS) 가 아니면 '미정리'로 계산(오타·빈값·unverified_skip 포함)
                        if field(head, "skip_reason") not in VALID_SKIP_REASONS:
                            uncoded += 1
                except Exception:
                    continue
    except Exception:
        pass
    return new, skipped, uncoded


def pending_section(counts=None):
    """status:new 미반영 알림(CLAUDE.md 가 의존하는 건수 알림). counts=(new,skipped) 주면
    재사용(I/O 공유), None 이면 자체 집계. 문구·동작은 기존과 불변(카운트만 헬퍼로 분리)."""
    try:
        new_count = (counts if counts is not None else _pending_counts())[0]
        legacy = os.path.exists(LEGACY_PENDING) and os.path.getsize(LEGACY_PENDING) > 0
        if new_count > 0 or legacy:
            note = " (레거시 pending_analysis.md 잔여 있음 — pending/ 으로 이관 필요)" if legacy else ""
            return (
                f"[메모리] pending/ 미반영(status: new) 항목 {new_count}건{note}. "
                "각 항목을 메모리에 반영 후 그 파일만 status: applied(또는 skipped)로 바꾸고 reflected_at 기록. "
                "파일을 통째로 비우거나 삭제하지 말 것."
            )
    except Exception:
        pass
    return ""


def live_session_ids():
    """ps 로 현재 *실행 중인* Claude CLI 세션 id 집합 반환 → (ids:set, ok:bool).
    C3(2026-05-30): 종료된 세션을 mtime 만으로 '활성' 오판(F1)하지 않도록 '프로세스 실재'를
    1차 신호로 쓴다. 종료된 세션은 ps 에 없다 → false positive 제거.

    self-match 방지(헌장 detection 사고 교훈): 특정 uuid 를 grep 하지 않고 전체 프로세스를
    열거한 뒤 정규식으로 --session-id/--resume 뒤의 uuid 만 추출한다.
    ('ps | grep <uuid>' 는 자기 명령줄을 매칭하고, 'pgrep -f claude' 는 데스크톱앱·렌더러·
     MCP 헬퍼까지 세어 무의미하다 — 둘 다 이번 세션에서 실제로 오답을 냈다.)

    ok=False(ps 부재·returncode!=0·파싱 0건) 면 호출부가 mtime 휴리스틱으로 폴백한다
    (ps false-negative — wrapper/no-TTY/재시작 race — 방어, degraded confidence)."""
    try:
        # -ww: 명령줄 절단 비활성(무제한 폭). 절단 시 uuid 가 잘려 live 세션을
        # 놓치는 false-negative 방지(Codex C3 검토 #1).
        out = subprocess.run(["ps", "-ww", "-eo", "command"],
                             capture_output=True, text=True, timeout=2)
        if out.returncode != 0:
            return set(), False
        pat = re.compile(
            r"(?:--session-id|--resume)\s+"
            r"([0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-"
            r"[0-9a-fA-F]{4}-[0-9a-fA-F]{12})")
        ids = set()
        for line in out.stdout.splitlines():
            if "claude" not in line:  # claude CLI 실행 라인만 (앱/렌더러/MCP 헬퍼 제외)
                continue
            m = pat.search(line)
            if m:
                ids.add(m.group(1).lower())
        # 정상이면 최소한 본인 세션이 잡힌다. 0건이면 ps 출력이 예상과 달라 신뢰불가 → 폴백.
        return ids, bool(ids)
    except Exception:
        return set(), False


def _enumerate_live_candidates(self_sid, exclude_self):
    """살아있는 동일프로젝트 세션 후보 열거 — 단일출처(B1, 2026-05-30).
    multisession_section·report_text 가 각자 복제하던 '파일열거 + agent/self 필터 +
    ps/mtime liveness 필터' 를 한 곳으로 모은다. 과거 C7(수기·hook 두 경로가 갈라져
    유휴기간 오산) 과 같은 부류의 drift 벡터를 차단(같은 필터를 한 함수가 소유).
    반환: (cands, ps_ok, now, cutoff). cands=[(mt, sid, full), ...] **미정렬**.
    정렬키·turn_ts hydrate·self_guessed·상위N·포맷은 호출부 책임(두 호출부가 서로 다름):
      - multisession_section: self 제외, mt 정렬, 상위 12건만 tail hydrate
      - report_text: self 포함(표시), turn_ts 정렬, 전건 hydrate
    listdir 예외는 잡지 않고 호출부 try/except 로 전파(원동작 보존 — 섹션 생략).
    exclude_self=True 면 본인 sid(대소문자무시)를 후보에서 뺀다(Codex C3 #1 기준)."""
    live_ids, ps_ok = live_session_ids()
    now = datetime.now().timestamp()
    cutoff = now - ACTIVE_WINDOW_MIN * 60
    self_l = (self_sid or "").lower()
    cands = []
    for name in os.listdir(PROJ_DIR):
        if not name.endswith(".jsonl") or name.startswith("agent-"):
            continue
        sid = name[:-6]
        if exclude_self and self_l and sid.lower() == self_l:
            continue
        full = os.path.join(PROJ_DIR, name)
        try:
            mt = os.path.getmtime(full)
        except OSError:
            continue
        if ps_ok:
            if sid.lower() not in live_ids:   # 프로세스 없는(종료된) 세션 제외 = F1 수정
                continue
        else:
            if mt < cutoff:                    # 폴백: mtime-30분 휴리스틱(degraded)
                continue
        cands.append((mt, sid, full))
    return cands, ps_ok, now, cutoff


def multisession_section(self_sid, cwd, cwd_root):
    """동시 세션 인지. C3(2026-05-30): mtime-30분 단독 → 본 프로젝트(PROJ_DIR) 세션을
    ps(프로세스 실재)로 거르고, mtime 은 최근/유휴 라벨·폴백용으로만 쓴다.
    개선: (a) 종료됐는데 mtime 신선한 세션 false-positive 제거(F1, 이번 세션 라이브 재현)
          (b) 열려있으나 유휴(mtime 오래)인 세션도 포착(이전엔 30분 컷오프로 누락 — 공유쓰기 위험원)
          (c) ps 실패 시 mtime-30분 휴리스틱으로 degraded-confidence 폴백."""
    try:
        # 후보 열거·liveness 필터는 단일출처 헬퍼(B1). 정렬·self_guessed·hydrate 는 여기 유지.
        cand, ps_ok, now, cutoff = _enumerate_live_candidates(self_sid, exclude_self=True)
        self_l = (self_sid or "").lower()
        cand.sort(reverse=True)   # (mt, sid, full) — mt 내림차순(원동작)

        # self_sid 미전달(드묾) 폴백: 본인 jsonl false-positive 제거(가장 최근 1건 제외).
        # 평시엔 session_id/transcript_path 가 전달돼 이 분기는 타지 않는다.
        self_guessed = ""
        if not self_l and cand:
            self_guessed = cand[0][1]
            cand = cand[1:]

        rows = []
        same_n = 0
        active_n = 0
        total_n = len(cand)  # 표시 잘림(상위 12) 투명화용(Codex 10축 #3)
        for mt, sid, full in cand[:MAX_SESSIONS_SCANNED]:
            tail = tail_lines(full, 400)  # 1회 읽어 last_tool_path·last_turn_ts 가 공유(Codex 10축 #4)
            o_cwd = session_cwd(full)     # cwd 는 파일 head 에 있어 별도(앞 12줄)
            o_root = git_root(o_cwd) if o_cwd else ""
            match, display = last_tool_path(full, tail)
            same = False
            if cwd and o_cwd and os.path.realpath(o_cwd) == os.path.realpath(cwd):
                same = True
            elif cwd_root and o_root and cwd_root == o_root:
                same = True
            elif cwd_root and match and cwd_root in match:
                same = True
            if same:
                same_n += 1
            # 유휴/최근 표시는 '마지막 실제 대화턴'(user/assistant) 기준 — 비대화 system
            # 이벤트가 mtime 만 밀어올리는 왜곡 차단(C3 후속, 대시보드와 일치). 못 읽으면 mtime 폴백.
            turn_ts = last_turn_ts(full, tail) or mt
            if turn_ts > now + 300:  # 미래 timestamp 방어(Codex 10축 #1): mtime 폴백
                turn_ts = mt
            recent = turn_ts >= cutoff
            if recent:
                active_n += 1
                when = "최근 " + datetime.fromtimestamp(turn_ts).strftime("%H:%M")
            else:
                age_h = (now - turn_ts) / 3600
                when = f"유휴 {int(age_h // 24)}일" if age_h >= 24 else f"유휴 {int(age_h)}시간"
            if ps_ok:
                state = "활성" if recent else "유휴(열림)"
            else:
                state = "추정(mtime)"
            rows.append(
                f"  - {sid[:8]} [{state}] {when}"
                f" {'★동일프로젝트' if same else ''} cwd={_display_path(o_cwd) or '?'} 최근작업: {display or '?'}"
            )

        mode = "ps 실행중 기준" if ps_ok else "⚠ps미확인→mtime추정"  # ps실패∪세션ID미검출(Codex C3 #2)
        if not rows:
            return f"[multi-session, {mode}] 동시 세션 없음."
        guess_note = (f" (session_id 미전달 → {self_guessed[:8]} 본인 추정 제외)"
                      if self_guessed else "")
        if ps_ok:
            cnt = f"{len(rows)}건(활성 {active_n}/유휴 {len(rows) - active_n})"
        else:
            cnt = f"{len(rows)}건"
        if total_n > len(rows):  # 상위 N건만 표시됨을 투명화(Codex 10축 #3)
            cnt += f" ※상위 {len(rows)}/총 {total_n}건만 표시"
        head = (
            f"[multi-session, {mode}] 본 세션 외 {cnt}"
            + (f", 동일 프로젝트 {same_n}건" if same_n else "")
            + guess_note
            + " — 외부 손/공유상태 작업 전 확인:"
        )
        return head + "\n" + "\n".join(rows)
    except Exception:
        return ""


def memory_budget_section():
    """MEMORY.md 가 harness 로드 한도(200줄/25KB)에 근접·초과하면 읽기전용 경고(cwp Phase A).
    silent drop(인덱스 뒷부분 미로드)·sentinel 소실(파일 잘림)을 매 세션 surfacing 한다.
    절대 비차단(어떤 예외도 빈 문자열). 자동 복구 아님 — 사람이 다이어트/rebuild 하도록 알림만."""
    try:
        b = os.path.getsize(MEMORY_INDEX)
        warns = []
        # 예산·sentinel 은 **독립** 검사(Codex 4f #1: 초과 시 sentinel 검사 생략하던 결함 수정).
        if b > MEMORY_BUDGET:
            warns.append(f"MEMORY.md {b}B > {MEMORY_BUDGET}B 임계 — 인덱스 뒷부분이 세션시작에 미로드될 수 있음. "
                         "다이어트 필요(test_memory_system.sh TEST9 참조).")
        with open(MEMORY_INDEX, "rb") as f:
            tail = f.read()[-200:]
        if b"MEMORY_INDEX_END" not in tail:
            warns.append("MEMORY.md end sentinel 소실 — 파일 잘림/손상 의심. 백업(cwp_state) 대조 권장.")
        # PROJECT_STATUS.md 크기 측정·경고(F2, 2026-06-19) — 같은 warns 리스트로 단일 표면.
        # 자체 try/except(비차단). 총량 + 줄당(문단 재발 방지, Codex 권고). 측정만, 자동 절삭 안 함.
        try:
            sb = os.path.getsize(STATUS_FILE)
            if sb > STATUS_HARD_BYTES:
                warns.append(f"PROJECT_STATUS.md {sb}B > HARD {STATUS_HARD_BYTES}B — 완료(✅) 줄을 아카이브로 강등 필요"
                             "(snapshot-demotions.md).")
            elif sb > STATUS_SOFT_BYTES:
                warns.append(f"PROJECT_STATUS.md {sb}B > SOFT {STATUS_SOFT_BYTES}B — 다음 다이어트 때 완료 줄 압축 권장.")
            over_soft = over_hard = longest = 0
            with open(STATUS_FILE, "rb") as f:
                for ln in f:
                    # 스냅샷 항목('- [') + changelog 날짜줄('- 20YY-') 둘 다 문단화 감시(Codex 4b #3)
                    if ln.startswith(b"- [") or ln.startswith(b"- 20"):
                        n = len(ln.rstrip(b"\n"))
                        longest = max(longest, n)
                        if n > STATUS_LINE_HARD:
                            over_hard += 1
                        elif n > STATUS_LINE_SOFT:
                            over_soft += 1
            if over_hard:
                warns.append(f"PROJECT_STATUS.md 줄당 {STATUS_LINE_HARD}B 초과 {over_hard}건(최장 {longest}B) — 문단 재발, 한 줄로 압축.")
            elif over_soft:
                warns.append(f"PROJECT_STATUS.md 줄당 {STATUS_LINE_SOFT}B 초과 {over_soft}건(최장 {longest}B) — 압축 권장.")
        except Exception:
            pass
        if warns:
            return "[기억·상태판 크기 경고]\n" + "\n".join("  ⚠ " + w for w in warns)
    except Exception:
        pass
    return ""


def cleanup_nudge_section(counts=None, mem_size=None):
    """조건부 정리 넛지(2026-06-05). pending new / MEMORY.md 크기 / pending skipped 누적 중
    하나라도 중간임계를 넘으면 '차분 한 줄' 로 정리를 권유한다.
    **차단 안 함** — 다른 섹션과 동일하게 try/except·빈문자열 폴백, 임계 미달이면 침묵.
    발동한 신호만 나열(노이즈 최소화 — 왜 떴는지 신호별로 명확). 톤·임계는 사용자 결정:
      new≥NUDGE_NEW · MEMORY≥MEMORY_BUDGET(소프트경고와 동일 기준) · uncoded_skipped≥NUDGE_SKIP.
      (skip 신호는 사유코드 미기입분만 — 큐1 사유코드화 후 정리완료 skip 은 발동 안 함.)
    pending 카운트·MEMORY 크기는 main 에서 1회 계산해 전달(I/O 공유); None 이면 자체 계산.
    counts 는 _pending_counts() 가 주는 **3-tuple (new, skipped, uncoded) 전용**(내부 헬퍼·외부 호출자
    없음). 다른 arity 가 들어오면 except 로 흡수돼 빈 문자열(=비차단 fail-open).
    역할 분리: pending_section=미반영 절차 안내, memory_budget_section=한도 기술경고,
    본 함수=임계 초과 시 '지금 정리' 행동 권유 종합(평소 침묵이라 중복 노이즈 없음)."""
    try:
        new, skipped, uncoded = counts if counts is not None else _pending_counts()
        if mem_size is None:
            try:
                mem_size = os.path.getsize(MEMORY_INDEX)
            except OSError:
                mem_size = 0
        hits = []
        if new >= NUDGE_NEW:
            hits.append(f"pending 미반영 {new}건→메모리 반영")
        if mem_size >= MEMORY_BUDGET:
            hits.append(f"MEMORY.md {mem_size/1000:.1f}KB→다이어트")
        # 사유코드 미기입(uncoded) skip 만 재검토 백로그로 계산 — 정리완료 skip 은 침묵(큐1, 2026-06-05)
        if uncoded >= NUDGE_SKIP:
            hits.append(f"미정리 skipped {uncoded}건→재검토")
        if hits:
            return "[정리 권장] " + " · ".join(hits) + ". 한가할 때 권장(차단 아님)."
    except Exception:
        pass
    return ""


def wiring_section():
    """기억 배선(settings.json `autoMemoryDirectory`)이 기억 저장소를 가리키는지 **매 세션** 확인.

    끊겨 있으면 이 저장소의 MEMORY.md 색인은 세션에 로드되지 않는다(기억을 쌓아도 Claude 가 못 봄).
    doctor 에도 같은 점검이 있지만 사용자가 doctor 를 안 돌리면 결함이 조용히 지속된다(Codex 4b) →
    사용자가 아무것도 안 해도 보이도록 세션 시작에 표면화한다. 읽기 전용·절대 비차단."""
    try:
        settings = os.path.join(os.path.expanduser("~"), ".claude", "settings.json")
        with open(settings, encoding="utf-8") as f:
            cur = json.load(f).get("autoMemoryDirectory")
        if isinstance(cur, str) and cur and \
                os.path.realpath(os.path.expanduser(cur)) == os.path.realpath(MEMORY_DIR):
            return ""
        return ("[기억 배선 끊김 — 조치 필요]\n"
                "settings.json 의 autoMemoryDirectory 가 기억 저장소(%s)를 가리키지 않습니다(현재: %s).\n"
                "이 상태에선 MEMORY.md 색인이 세션에 로드되지 않아, 기억을 쌓아도 Claude 가 보지 못합니다.\n"
                "고치기(한 번만): python3 \"${CLAUDE_PLUGIN_ROOT}/skills/setup-wizard/setup.py\" wire-auto-memory --apply\n"
                "이전 기억이 ~/.claude/projects/*/memory/ 에 남아 있다면: "
                "python3 \"${CLAUDE_PLUGIN_ROOT}/skills/setup-wizard/import_existing.py\" adopt-native --apply"
                % (MEMORY_DIR, cur if cur else "없음"))
    except Exception:
        return ""   # settings 부재·손상·권한 문제 등 — 세션 시작을 절대 막지 않는다


def status_section():
    try:
        if os.path.getsize(STATUS_FILE) > 0:
            with open(STATUS_FILE, "r", encoding="utf-8") as f:
                return ("[PROJECT_STATUS — 현재 권위 상태, 세션 시작 시 결정적 로드]\n"
                        + f.read().strip())
    except Exception:
        pass
    return ""


def report_text(self_sid=""):
    """수기 단일세션 게이트용 단일-출처 리포트(C7, 2026-05-30).
    재발방지(F10): 수기 보고가 raw `ps etime`(=프로세스 *가동시간*, 포맷 [[dd-]hh:]mm:ss)을
    세션 '유휴기간'으로 오독하던 문제 — etime 17일을 유휴 17일로, `00:12`(12초)를 12분으로.
    hook 의 '유휴 N일' 계산은 이미 last_turn_ts(마지막 대화턴) 로 고쳐졌으나(C3 후속), 수기
    경로가 그 값을 인용하지 않고 별도로 ps 를 눈으로 읽어 재발했다(= 단일 출처 위반).
    이 함수는 hook 과 *동일* 함수(live_session_ids·last_turn_ts·미래ts가드)만 재사용해 같은
    '유휴 N일' 을 산출한다. ps 는 내부 liveness 판정에만 쓰고 etime 은 어디에도 노출하지 않는다.
    수기 게이트는 raw ps 대신 `python3 session_context.py --report <self_sid>` 출력을 인용한다.
    절대 예외를 올리지 않는다(실패해도 한 줄 반환)."""
    try:
        # 후보 열거·liveness 필터는 hook(multisession) 과 동일 단일출처 헬퍼(B1).
        # report 는 self 포함(표시)·전건 hydrate(turn_ts 정렬). exclude_self=False 가 차이.
        cand_raw, ps_ok, now, cutoff = _enumerate_live_candidates(self_sid, exclude_self=False)
        self_l = (self_sid or "").lower()
        cand = []  # (turn_ts, sid, full)
        for mt, sid, full in cand_raw:
            tail = tail_lines(full, 400)
            turn_ts = last_turn_ts(full, tail) or mt
            if turn_ts > now + 300:                # 미래 ts 가드(hook 과 동일)
                turn_ts = mt
            cand.append((turn_ts, sid, full))
        cand.sort(reverse=True)

        mode = "ps 실행중 기준" if ps_ok else "⚠ps미확인→mtime추정"
        out = [f"# session report [{mode}] {datetime.fromtimestamp(now):%Y-%m-%d %H:%M} "
               "(유휴=마지막 user/assistant 대화턴 기준 · 프로세스 가동시간 인용 금지)"]
        if not cand:
            out.append("  (live 세션 없음)")
            return "\n".join(out)
        active_n = 0
        for turn_ts, sid, full in cand:
            recent = turn_ts >= cutoff   # hook 과 *동일* 경계(>=cutoff) — age<1800 분기 시 30분 정확지점에서
                                         # hook='활성' vs report='유휴 0시간' 불일치 나던 것 제거(Codex C7 검증)
            if recent:
                active_n += 1
                when = "활성 (최근 " + datetime.fromtimestamp(turn_ts).strftime("%H:%M") + ")"
            else:
                age_h = (now - turn_ts) / 3600   # hook 의 유휴 일/시간 산식과 동일
                when = (f"유휴 {int(age_h // 24)}일" if age_h >= 24
                        else f"유휴 {int(age_h)}시간")
            sl = sid.lower()
            is_self = self_l and (sl == self_l or (len(self_l) >= 8 and sl.startswith(self_l)))
            mark = " ←본 세션" if is_self else ""
            o_cwd = session_cwd(full)
            out.append(f"  {sid[:8]}  {when:16s} cwd={_display_path(o_cwd) or '?'}{mark}")
        out.append(f"# live {len(cand)}건 (활성 {active_n}/유휴 {len(cand) - active_n}) "
                   "— 본인 외 '활성'이 있으면 공유 hook/상태 변경 보류")
        return "\n".join(out)
    except Exception as e:
        # 예외 메시지에 개행이 섞여도 '한 줄 반환' 보장(Codex C7 검증)
        return "# session report 실패(무시 가능): " + str(e).replace("\n", " ")[:200]


_WATCH_LABEL = {"AUP": "AUP차단", "5xx": "서버5xx", "RateLimit": "레이트리밋",
                "Auth": "인증", "Timeout": "타임아웃", "Context": "컨텍스트", "API": "API"}


def watcher_section():
    """transcript-watcher 가 지난 세션 이후 감지한 차단/에러 요약(있으면 1줄). 소비 후 정리.
    가동 중 watcher(append)와의 경합 회피 = 같은 findings 파일에 advisory lock 을 잡고
    read+truncate(in-place). fcntl 없으면 best-effort. 실패는 조용히 무시(fail-safe).
    로그 경로는 홈/사용자명 노출 방지 위해 비식별 표기만 준다."""
    try:
        wdir = os.path.join(cc_paths.STATE_DIR, "watcher")
        findings = os.path.join(wdir, "findings.jsonl")
        if not os.path.exists(findings) or os.path.getsize(findings) == 0:
            return ""
        try:
            import fcntl
        except Exception:
            fcntl = None
        try:
            with open(findings, "r+", encoding="utf-8") as f:
                if fcntl is not None:
                    fcntl.flock(f.fileno(), fcntl.LOCK_EX)
                try:
                    data = f.read()
                    f.seek(0)
                    f.truncate()   # in-place 비우기(inode 유지 → writer FD 무효화 안 함·재주입 방지)
                finally:
                    if fcntl is not None:
                        try:
                            fcntl.flock(f.fileno(), fcntl.LOCK_UN)
                        except Exception:
                            pass
        except OSError:
            return ""
        cats, total = {}, 0
        for line in data.splitlines():
            line = line.strip()
            if not line:
                continue
            try:
                o = json.loads(line)
            except Exception:
                continue
            c = str(o.get("category", "API"))
            cats[c] = cats.get(c, 0) + 1
            total += 1
        if total == 0:
            return ""
        order = ["AUP", "5xx", "RateLimit", "Auth", "Timeout", "Context", "API"]
        seq = [k for k in order if cats.get(k)] + [k for k in cats if k not in order]
        detail = " · ".join(f"{_WATCH_LABEL.get(k, k)} {cats[k]}" for k in seq)
        return (f"[watcher] 지난 세션 이후 감지 {total}건: {detail}. "
                f"hook 이 못 잡은 차단/에러일 수 있음(진단 참고). "
                f"상세: CC_STATE_DIR/watcher/watcher.log")
    except Exception:
        return ""


def main():
    try:
        inp = read_input()
        cwd = inp.get("cwd") or os.getcwd()
        global PROJ_DIR
        _tp0 = inp.get("transcript_path", "")
        if _tp0.endswith(".jsonl"):
            PROJ_DIR = os.path.dirname(os.path.realpath(_tp0))
        elif cwd:
            PROJ_DIR = cc_paths.proj_transcript_dir(cwd)
        self_sid = inp.get("session_id", "")
        # transcript_path가 오면 그 파일명이 본인 sid — mtime 휴리스틱보다 정확 (Codex audit).
        if not self_sid:
            tp = inp.get("transcript_path", "")
            if tp.endswith(".jsonl"):
                self_sid = os.path.basename(tp)[:-6]
        cwd_root = git_root(cwd)

        head = f"[session-context] cwd={cwd}" + (f" (git root: {cwd_root})" if cwd_root else "")
        parts = [head]
        pcounts = _pending_counts()  # (new, skipped, uncoded) 1회 스캔 → pending·nudge 공유(중복 디렉터리 스캔 방지)
        for sec in (wiring_section(), pending_section(pcounts),
                    multisession_section(self_sid, cwd, cwd_root),
                    watcher_section(), memory_budget_section(), cleanup_nudge_section(pcounts),
                    status_section()):
            if sec and sec.strip():
                parts.append(sec)

        msg = "\n\n".join(parts)
        if not msg.strip():
            return
        print(json.dumps({
            "hookSpecificOutput": {
                "hookEventName": "SessionStart",
                "additionalContext": msg,
            }
        }))
    except Exception:
        return  # 절대 세션 시작을 막지 않는다.


if __name__ == "__main__":
    if "--report" in sys.argv:
        # 수기 단일세션 게이트용 단일-출처 리포트(C7). 본인 sid 는 --report 다음 인자로 선택 전달.
        _args = [a for a in sys.argv[1:] if a != "--report"]
        print(report_text(_args[0] if _args else ""))
    else:
        main()
