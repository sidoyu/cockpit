#!/bin/bash
# codex_call.sh — 보조 검토(2차 의견) wrapper.
#
# 외부 LLM CLI(OpenAI Codex)를 "보이지 않는 보조 검토자"로 호출한다. cockpit 패키지의
# **선택 기능**이며, 활성화 스위치 파일이 있을 때만 동작한다(기본 비활성).
#
# ⚠️ 이중 송출: 이 wrapper를 호출하면 검토 대상 맥락이 OpenAI에도 전송된다
#    (Anthropic + OpenAI 두 곳). GOVERNANCE.md 3장 참조. 민감정보·PII 입력 금지.
#
# 사용:
#   codex_call.sh --brief BRIEF_FILE --resp RESP_FILE [--trigger TYPE] [-C DIR]
#   codex_call.sh --health
#
# 안전 설계(그대로 둘 것):
#   - 활성화 스위치 파일이 있을 때만 동작(기본 비활성).
#   - `OPENAI_API_KEY=` 빈 접두 → ChatGPT 구독 인증만 사용, API 종량 과금을 원천 차단.
#   - 결과($RESP)를 사용자에게 그대로 노출하지 않음(호출한 Claude가 본인 결론과 비교만).
#   - 송신 brief·디스크 캡처물 양쪽에서 시크릿 패턴 레닥션(키가 섞여 있어도 외부 미전송).
#   - 타임아웃 watchdog: hang 시 우아한 스킵(보조 검토자라 실패해도 본작업 무영향).
#   - 큰 응답은 raw 인용을 피하도록 $RESP.meta(안전 요약)만 읽게 유도.
#
# 경로 규약(패키지):
#   - 활성화 스위치  = $CC_CODEX_ENABLED (기본 ~/.claude/codex_enabled, 사용자가 touch/rm)
#   - 글로벌 브리프  = $CC_CODEX_GLOBAL_BRIEF (기본 ~/.codex/codex_global_brief.md, **선택**)
#   - 로그·캡처물    = $CC_STATE_DIR/codex (기본 ~/.claude/cc-companion/codex)
#   설치 마법사가 이 값들을 안내한다. plugin/codex/README.md 참조.

set -u
umask 077
export PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:$PATH"

# ── 경로(파라미터화) ───────────────────────────────────────────────
CC_STATE_DIR="${CC_STATE_DIR:-$HOME/.claude/cc-companion}"
CODEX_HOME="$CC_STATE_DIR/codex"
CALLS_LOG="$CODEX_HOME/codex_calls.log"
CALLS_DIR="$CODEX_HOME/codex_calls"
ENABLE_SWITCH="${CC_CODEX_ENABLED:-$HOME/.claude/codex_enabled}"
GLOBAL_BRIEF="${CC_CODEX_GLOBAL_BRIEF:-$HOME/.codex/codex_global_brief.md}"

# ── 호출 default (단일 출처) ───────────────────────────────────────
# 본 두 상수가 model/reasoning effort의 single source of truth.
# 다른 문서(CLAUDE.md·README)는 본 wrapper만 참조한다(drift 방지).
# 호출 직전 환경변수로 1회 override 가능:
#   CODEX_REASONING_EFFORT=medium codex_call.sh ...
CODEX_MODEL="${CODEX_MODEL:-gpt-5.5}"
CODEX_REASONING_EFFORT="${CODEX_REASONING_EFFORT:-high}"

# ── 타임아웃 ───────────────────────────────────────────────────────
# codex 호출이 hang 시 세션을 무한정 붙잡는 것을 방지한다.
# 초과 시 프로세스(+자식 트리) 종료 → exit 124 → 우아한 스킵(재시도 없음·부분응답 미노출).
# 보조 검토자라 실패해도 본작업에 영향을 주지 않는 것이 설계 원칙.
CODEX_TIMEOUT_SEC="${CODEX_TIMEOUT_SEC:-600}"
LOGIN_TIMEOUT_SEC="${LOGIN_TIMEOUT_SEC:-20}"

# ── 글로벌 브리프 부재 시 내장 최소 프리앰블 ──────────────────────
# 글로벌 브리프(역할·톤·금지사항)는 선택 사항이라 없을 수 있다. 그 경우에도
# 상위 안전·형식 규율이 빠진 채 호출되지 않도록, 최소 프리앰블을 작업 brief 앞에 붙인다.
# (PII 없음 — 고정 문자열. 글로벌 브리프가 있으면 그쪽이 우선이며 이 값은 쓰지 않는다.)
BUILTIN_PREAMBLE='당신은 사용자의 Claude Code 가 호출하는 보이지 않는 보조 검토자다. 사용자에게 직접 응답하지 않으며, Claude 가 본인 결론과 비교해 의미 있는 차이만 노출한다. "발견 / 영향 / 권장 조치 / 사용자 결정 필요 여부" 형식으로 결함·리스크 위주 간결히. 추정은 추정으로 명시하고 모르면 모른다고 한다. 개인정보·자격증명을 추가하지도 요청하지도 말 것.'

# ── 시크릿 레닥션 가드 ─────────────────────────────────────────────
# 송신 brief(코덱스로 전송 전)와 캡처물(stderr/response/meta, 디스크 보관 전) 양쪽에서
# 흔한 API 키 값 패턴을 제거한다. 정상 호출엔 no-op(브리프에 키가 없으므로).
# 정규식은 '접두 + 충분한 길이의 실제 값 문자'에만 매칭 → 짧은 예시 토큰 오탐 회피.
REDACT_PAT='sk-proj-[A-Za-z0-9_-]{20,}|sk-ant-api03-[A-Za-z0-9_-]{20,}|sk-ant-[A-Za-z0-9_-]{20,}|sk-[A-Za-z0-9]{20,}|AIza[A-Za-z0-9_-]{30,}|r8_[A-Za-z0-9]{30,}|xai-[A-Za-z0-9]{20,}|ghp_[A-Za-z0-9]{30,}|glpat-[A-Za-z0-9_-]{20,}|AKIA[A-Z0-9]{16}'
redact_file() {
  [ -f "$1" ] && sed -i '' -E "s/($REDACT_PAT)/[REDACTED-KEY]/g" "$1" 2>/dev/null
}

# ── 타임아웃 watchdog ──────────────────────────────────────────────
# timed_run SECS STDIN_FILE CMD...  →  CMD 를 STDIN_FILE 을 stdin 으로 실행.
#   타임아웃 시 프로세스 + 자식 트리(pkill -P) 종료 후 124 반환. 정상 시 CMD 의 exit 보존.
# 함정(검증된 사항):
#   - 백그라운드(&) 프로세스는 비대화형 셸에서 stdin 이 /dev/null 로 자동 전환되므로
#     `< "$stdin_file"` 를 백그라운드 명령에 **명시**해야 프롬프트가 전달된다.
#   - 단일 PID kill 은 손자 프로세스를 놓칠 수 있어 pkill -P 보조 + 최종 KILL.
#   - marker(mktemp -d 사설 디렉터리 내 파일)로 타임아웃을 판정하고, marker 유실 시
#     시그널 종료코드(143 SIGTERM / 137 SIGKILL) 백스톱.
timed_run() {
  local secs="$1" stdin_file="$2"; shift 2
  local mdir; mdir="$(mktemp -d "${TMPDIR:-/tmp}/codex_to.XXXXXX" 2>/dev/null)" || mdir=""
  local marker="${mdir:+$mdir/timed_out}"
  { "$@" < "$stdin_file" ; } &
  local cpid=$!
  (
    sleep "$secs"
    if kill -0 "$cpid" 2>/dev/null; then
      [ -n "$marker" ] && : > "$marker" 2>/dev/null
      pkill -TERM -P "$cpid" 2>/dev/null; kill -TERM "$cpid" 2>/dev/null
      sleep 3
      pkill -KILL -P "$cpid" 2>/dev/null; kill -KILL "$cpid" 2>/dev/null
    fi
  ) &
  local wpid=$!
  wait "$cpid" 2>/dev/null
  local rc=$?
  kill "$wpid" 2>/dev/null; wait "$wpid" 2>/dev/null
  if [ -n "$marker" ] && [ -f "$marker" ]; then
    rc=124
  elif [ "$rc" -eq 143 ] || [ "$rc" -eq 137 ]; then
    rc=124
  fi
  [ -n "$mdir" ] && rm -rf "$mdir" 2>/dev/null
  return $rc
}

# 상태 디렉터리는 비활성(스위치 off) 호출에서 부수효과를 남기지 않도록, 정상 호출 경로의
# 활성 스위치 검사 통과 후 또는 --health 에서만 생성한다.
ensure_dirs() {
  mkdir -p "$CALLS_DIR"
  chmod 700 "$CODEX_HOME" "$CALLS_DIR" 2>/dev/null
}

# ---------- Health check ----------
if [ "${1:-}" = "--health" ]; then
  echo "=== codex_call.sh --health ==="
  ensure_dirs
  SELF="${BASH_SOURCE[0]}"
  ok=0; fail=0
  # eval 미사용(제네릭 배포본 — 경로에 특수문자가 있어도 안전). 직접 조건문으로 판정.
  pass()  { echo "  ✓ $1"; ok=$((ok+1)); }
  failc() { echo "  ✗ $1"; fail=$((fail+1)); }
  [ -r "$SELF" ] && pass "wrapper 읽기 가능" || failc "wrapper 읽기 가능"
  command -v codex >/dev/null && pass "codex binary 존재" || failc "codex binary 존재"
  [ -f "$ENABLE_SWITCH" ] && pass "활성 스위치 ($ENABLE_SWITCH)" || failc "활성 스위치 ($ENABLE_SWITCH)"
  if [ -f "$GLOBAL_BRIEF" ]; then
    pass "글로벌 브리프 ($GLOBAL_BRIEF)"
  else
    echo "  - 글로벌 브리프 없음 (선택 — 내장 최소 프리앰블 + 작업 브리프 전송): $GLOBAL_BRIEF"
  fi
  [ "$(stat -f%Lp "$CALLS_DIR" 2>/dev/null)" = "700" ] && pass "calls 디렉토리 권한 700" || failc "calls 디렉토리 권한 700"
  if [ -f "$CALLS_LOG" ]; then
    [ "$(stat -f%Lp "$CALLS_LOG" 2>/dev/null)" = "600" ] && pass "calls.log 권한 600" || failc "calls.log 권한 600"
  else
    echo "  - calls.log 아직 미생성 (첫 호출 시 생성됨)"
  fi
  if command -v codex >/dev/null; then
    if timed_run "$LOGIN_TIMEOUT_SEC" /dev/null env OPENAI_API_KEY= codex login status >/dev/null 2>&1; then
      pass "codex login 상태"
    else
      failc "codex login 상태"
    fi
  else
    echo "  - codex 미설치 → login 상태 검사 생략"
  fi
  # 임시 brief/resp 사이클 (실 API 호출 X, 파일 시스템만)
  TEST_TS=$(date +%s)
  TEST_DIR="$CALLS_DIR/health-$TEST_TS"
  if mkdir -p "$TEST_DIR" && echo "ping" > "$TEST_DIR/brief.txt" && [ -f "$TEST_DIR/brief.txt" ]; then
    pass "brief/resp 파일 쓰기 가능"; rm -rf "$TEST_DIR"
  else
    failc "brief/resp 파일 쓰기 가능"
  fi
  echo ""
  echo "결과: $ok OK / $fail FAIL"
  [ $fail -eq 0 ] && exit 0 || exit 1
fi

# ---------- 정상 호출 ----------
BRIEF=""
RESP=""
TRIGGER="manual"
EXTRA_ARGS=()

while [ $# -gt 0 ]; do
  case "$1" in
    --brief) BRIEF="$2"; shift 2 ;;
    --resp) RESP="$2"; shift 2 ;;
    --trigger) TRIGGER="$2"; shift 2 ;;
    -C|--cd) EXTRA_ARGS+=(-C "$2"); shift 2 ;;
    *) echo "[wrapper] unknown arg: $1" >&2; exit 2 ;;
  esac
done

if [ -z "$BRIEF" ] || [ -z "$RESP" ]; then
  echo "Usage: $0 --brief BRIEF_FILE --resp RESP_FILE [--trigger TYPE] [-C DIR]" >&2
  echo "       $0 --health" >&2
  exit 2
fi

# 활성 스위치 검사 (CLAUDE.md §4.1) — 여기서 통과해야 비로소 상태 디렉터리를 만든다(off=부수효과 없음).
if [ ! -f "$ENABLE_SWITCH" ]; then
  echo "[wrapper] 보조 검토(Codex) 비활성 (스위치 없음): $ENABLE_SWITCH" >&2
  echo "[wrapper] 켜려면: touch '$ENABLE_SWITCH'" >&2
  exit 3
fi
ensure_dirs

# 인증 1차 검사 (CLAUDE.md §4.2) — 네트워크 hang 대비 LOGIN_TIMEOUT_SEC 보호
# exit code 단독 판정(substring match 금지 — "Not logged in"에 "Logged in"이 부분 포함됨).
# login status 에도 OPENAI_API_KEY= 빈 접두(과금 모드 차단 정책 일관성).
if ! timed_run "$LOGIN_TIMEOUT_SEC" /dev/null env OPENAI_API_KEY= codex login status >/dev/null 2>&1; then
  echo "[wrapper] codex login status 실패/타임아웃(${LOGIN_TIMEOUT_SEC}s) → 이번 턴 스킵" >&2
  exit 4
fi

[ -f "$BRIEF" ] || { echo "[wrapper] brief 없음: $BRIEF" >&2; exit 2; }

# 본 호출 brief (+ 글로벌 브리프가 있으면 앞에 결합). 글로벌 브리프는 선택 사항.
TS=$(date +%Y%m%d_%H%M%S)
# 호출한 Claude 세션 ID (대시보드에서 세션↔검토 연결용). 메타데이터 전용 — PII 아님.
# 개행·| 제거: 로그 행 깨짐 방지.
SID="$(printf '%s' "${CLAUDE_CODE_SESSION_ID:-unknown}" | tr -d '\n\r|' )"
[ -n "$SID" ] || SID="unknown"
# 디렉토리 고유화: 초 단위 TS만으론 두 세션이 같은 초에 호출 시 덮어쓰기 → pid+RANDOM 부가.
CALL_DIR="$CALLS_DIR/${TS}_$$_${RANDOM}"
mkdir -p "$CALL_DIR"
chmod 700 "$CALL_DIR"
printf '%s\n' "$SID" > "$CALL_DIR/session_id"
chmod 600 "$CALL_DIR/session_id"
COMBINED="$CALL_DIR/brief.txt"
if [ -f "$GLOBAL_BRIEF" ]; then
  cat "$GLOBAL_BRIEF" "$BRIEF" > "$COMBINED"
else
  # 글로벌 브리프 없음 → 내장 최소 프리앰블을 앞에 붙여 상위 규율 누락 방지.
  { printf '%s\n\n' "$BUILTIN_PREAMBLE"; cat "$BRIEF"; } > "$COMBINED"
fi
chmod 600 "$COMBINED"
redact_file "$COMBINED"  # 키 값이 섞여 있어도 Codex(OpenAI)로 절대 전송하지 않음
# 질문(작업 브리프)만 별도 저장 — 대시보드가 글로벌 브리프 노이즈 없이 질문을 표시.
if cp "$BRIEF" "$CALL_DIR/question.txt" 2>/dev/null; then
  chmod 600 "$CALL_DIR/question.txt"
  redact_file "$CALL_DIR/question.txt"
fi

# Codex 실 호출 (timed_run watchdog 으로 CODEX_TIMEOUT_SEC 보호)
# macOS bash 3.2 호환: 빈 array의 [@]가 set -u와 충돌 → ${EXTRA_ARGS[@]+...} 패턴.
# 출력은 RESP.tmp 로 받고, 성공(exit 0)일 때만 RESP 로 원자적 교체 → 타임아웃/실패 시
# 부분응답이 Claude 에 노출되지 않음. 부분응답은 레닥션 후 CALL_DIR 에만 보관.
RESP_TMP="$RESP.tmp.$$"
trap 'rm -f "${RESP_TMP:-}" 2>/dev/null' EXIT   # ${:-} 가드(set -u 안전)
START=$(date +%s)
timed_run "$CODEX_TIMEOUT_SEC" "$COMBINED" \
  env OPENAI_API_KEY= codex exec \
    --sandbox read-only \
    --skip-git-repo-check \
    --ignore-user-config \
    -c model="$CODEX_MODEL" \
    -c model_reasoning_effort="$CODEX_REASONING_EFFORT" \
    ${EXTRA_ARGS[@]+"${EXTRA_ARGS[@]}"} \
    -o "$RESP_TMP" - \
  2>"$CALL_DIR/stderr.txt"
EXIT=$?
END=$(date +%s)
DURATION=$((END - START))

# 캡처물 키 레닥션 — 성공/실패/타임아웃 무관하게 항상 수행 (디스크 평문키 방지).
chmod 600 "$CALL_DIR/stderr.txt" 2>/dev/null
redact_file "$CALL_DIR/stderr.txt"
redact_file "$RESP_TMP"

# 부분응답 포렌식 보관(레닥션됨). Claude 노출용 RESP 로는 승격 안 함.
if [ -f "$RESP_TMP" ]; then
  cp "$RESP_TMP" "$CALL_DIR/response.txt" 2>/dev/null
  chmod 600 "$CALL_DIR/response.txt" 2>/dev/null
  redact_file "$CALL_DIR/response.txt"
fi

# 승격: 성공일 때만 원자적 move. 타임아웃(124)/실패 시 고정 스킵문구만 RESP 에.
if [ "$EXIT" -eq 0 ]; then
  mv "$RESP_TMP" "$RESP" 2>/dev/null
else
  rm -f "$RESP_TMP" 2>/dev/null
  if [ "$EXIT" -eq 124 ]; then
    echo "[wrapper] Codex timeout - skipped (>${CODEX_TIMEOUT_SEC}s). 보조검토자라 본작업 무영향." > "$RESP"
    echo "[wrapper] Codex 타임아웃(${CODEX_TIMEOUT_SEC}s 초과) — 우아한 스킵(재시도 없음)" >&2
  else
    echo "[wrapper] Codex failed - skipped (exit $EXIT). 상세는 .meta 의 raw_archive 참조." > "$RESP"
    echo "[wrapper] Codex 호출 실패(exit $EXIT) — 스킵. stderr: $CALL_DIR/stderr.txt" >&2
  fi
  chmod 600 "$RESP" 2>/dev/null
fi
redact_file "$RESP"

# Metadata 로그 (인덱스, 원문 X)
BRIEF_SIZE=$(wc -c < "$COMBINED" | tr -d ' ')
RESP_SIZE=$([ -f "$RESP" ] && wc -c < "$RESP" | tr -d ' ' || echo 0)
HASH=$(shasum -a 256 "$COMBINED" 2>/dev/null | cut -d' ' -f1 | cut -c1-12)

if [ ! -f "$CALLS_LOG" ]; then
  echo "# ts | trigger | exit | brief_size | resp_size | duration_s | hash | session_id" > "$CALLS_LOG"
fi
echo "$TS | $TRIGGER | $EXIT | $BRIEF_SIZE | $RESP_SIZE | $DURATION | $HASH | $SID" >> "$CALLS_LOG"
chmod 600 "$CALLS_LOG"

# ─── Claude용 안전 요약 자동 생성 ($RESP.meta) ────────────────────
# Claude가 raw 응답을 본문에 끌어오지 않고도 응답 상태를 파악하게 하는 메타 파일.
# 누적 컨텍스트 농도가 응답 단계 안전 필터를 건드릴 수 있어, raw 는 디스크에서만 참조.
if [ -f "$RESP" ]; then
  META="$RESP.meta"
  RESP_LINES=$(wc -l < "$RESP" | tr -d ' ')
  {
    echo "# Codex response meta — $TS"
    echo "raw_path: $RESP"
    echo "raw_archive: $CALL_DIR/response.txt"
    echo "size_bytes: $RESP_SIZE"
    echo "size_lines: $RESP_LINES"
    echo "exit: $EXIT"
    echo "duration_s: $DURATION"
    echo "trigger: $TRIGGER"
    [ "$EXIT" -eq 124 ] && echo "status: TIMEOUT (>${CODEX_TIMEOUT_SEC}s) — skipped, 재시도 없음, 본작업 무영향"
    { [ "$EXIT" -ne 0 ] && [ "$EXIT" -ne 124 ]; } && echo "status: FAILED (exit $EXIT) — skipped"
    echo ""
    echo "## first 5 lines (header peek only)"
    head -n 5 "$RESP" | sed 's/^/  /'
    echo ""
    if [ "$RESP_SIZE" -gt 2000 ]; then
      echo "[WARN] 응답이 큼($RESP_SIZE B). Claude는 본문에 raw 인용하지 말 것."
      echo "       필요 시 별 .md/.sql 파일에 분리 후 경로로만 참조."
      echo "       grep/head로 필요한 라인만 좁혀서 읽을 것."
    fi
  } > "$META"
  chmod 600 "$META"
fi

exit $EXIT
