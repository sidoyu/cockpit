#!/bin/bash
# cockpit 원격 대시보드 — 로그→HTML 주기 변환 sweep (cron 등록용 템플릿).
# crontab 예: * * * * * /bin/bash <경로>/cron-sweep.sh   (매분, 내부에서 sub-minute 반복)
#
# 설정은 ~/.config/cockpit/dashboard.env(config.example.sh 참조)에서 읽는다.
# 개인 경로·healthcheck UUID·키를 이 파일에 박지 말 것 — 전부 설정/환경변수로.
set -uo pipefail
umask 077  # 생성·회전 파일(cron.log 등) owner-only — 세션 본문 PII 보호

# ── 설정 로드 ──────────────────────────────────────────────────
CONF="${CC_DASH_CONF:-$HOME/.config/cockpit/dashboard.env}"
[ -f "$CONF" ] && . "$CONF"

CC_DASH_HOME="${CC_DASH_HOME:-$HOME/claude-logs}"
PYTHON_BIN="${CC_DASH_PYTHON:-python3}"
SCRIPT="${CC_DASH_CONVERTER:-$CC_DASH_HOME/convert_session.py}"
LOG_FILE="${CC_DASH_CRON_LOG:-$CC_DASH_HOME/cron.log}"
HEALTHCHECKS_URL="${CC_DASH_HEALTHCHECK_URL:-}"   # 비면 ping 안 함

# 1분 cron 안에서 sub-minute 주기로 변환(t=0/20/40s → ~20초 갱신). 매분 새 프로세스로 자가 감독
# (데몬 silent death 회피). 변환 직렬화/중첩 보호는 convert_session.py 내부 락이 담당.
INTERVAL="${CC_DASH_SWEEP_INTERVAL:-20}"
RUNS="${CC_DASH_SWEEP_RUNS:-3}"

fail=0

# 이식성 stat 래퍼(BSD/macOS 의 -f vs GNU/Linux·WSL 의 -c 분기).
_fsize()  { stat -f%z "$1" 2>/dev/null || stat -c%s "$1" 2>/dev/null || echo 0; }
_fperm()  { stat -f '%Sp' "$1" 2>/dev/null || stat -c '%A' "$1" 2>/dev/null || echo ''; }
_fowner() { stat -f '%Su' "$1" 2>/dev/null || stat -c '%U' "$1" 2>/dev/null || echo ''; }

ping_hc() {  # healthcheck URL 이 설정됐을 때만 ping(선택 기능)
  [ -n "$HEALTHCHECKS_URL" ] || return 0
  curl -fsS -m 10 --retry 3 "${HEALTHCHECKS_URL}${1:-}" >/dev/null 2>&1 || true
}

on_exit() {
  local code=$?
  if [ "$code" -ne 0 ] || [ "$fail" -ne 0 ]; then
    ping_hc "/fail"
  fi
}
trap 'on_exit' EXIT

# 로그 회전(10MB 초과 시 뒤 5MB 보존)
if [ -f "$LOG_FILE" ] && [ "$(_fsize "$LOG_FILE")" -gt 10485760 ]; then
  tail -c 5242880 "$LOG_FILE" > "${LOG_FILE}.tmp" && mv "${LOG_FILE}.tmp" "$LOG_FILE"
fi

# (선택) AI 제목 요약용 키 로드 — cron 은 로그인 셸 프로파일 미로드라 별도 600 키파일에서만.
# 권한 가드: owner=본인 + group/other 쓰기금지일 때만 source(느슨하면 거부).
KEY_ENV="${CC_DASH_SUMMARY_KEY_ENV:-}"
if [ -n "$KEY_ENV" ] && [ -f "$KEY_ENV" ]; then
  _perm=$(_fperm "$KEY_ENV")
  _owner=$(_fowner "$KEY_ENV")
  case "$_perm" in
    -rw-------|-r--------)
      if [ "$_owner" = "$(id -un)" ]; then set -a; . "$KEY_ENV"; set +a; fi ;;
    *)
      echo "[cron-sweep] WARN: $KEY_ENV 권한($_perm)/소유자($_owner) 부적합 — 키 로드 생략" >&2 ;;
  esac
fi

ping_hc "/start"
for i in $(seq 1 "$RUNS"); do
  # 변경 중심 로깅: convert 가 출력을 낸 경우(실제 변환/오류)에만 기록.
  OUT="$("$PYTHON_BIN" "$SCRIPT" 2>&1)" || fail=1
  if [ -n "$OUT" ]; then
    {
      echo "=== $(date '+%Y-%m-%d %H:%M:%S %Z') sweep ==="
      printf '%s\n' "$OUT"
    } >> "$LOG_FILE"
  fi
  if [ "$i" -lt "$RUNS" ]; then
    sleep "$INTERVAL"
  fi
done

# 성공 ping 은 실패 없을 때만(trap 이 fail 시 /fail 담당 — 신호 혼선 방지).
if [ "$fail" -eq 0 ]; then
  ping_hc ""
else
  # exit code 기반 모니터(cron MAILTO 등)도 실패를 인지하도록 비0 종료.
  exit 1
fi
