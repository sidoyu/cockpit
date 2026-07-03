#!/bin/bash
# dashboard-run.sh — 뷰어 서버 기동 래퍼.
# launchd/직접 실행 모두 이 래퍼를 거쳐 ~/.config/cockpit/dashboard.env 의 설정을
# 환경변수로 적재한 뒤 서버를 exec 한다(launchd 가 plist 의 PATH 외 설정을 못 받는 문제 해소).
#
# ⚠️ 뷰어(공개 claude-session-dashboard)가 실제로 읽는 env — 핀 9f2bdba(2026-07-03)+ 기준:
#    CC_DASH_BIND·CC_DASH_IDLE_EXIT_SECS(+ CLAUDE_DASHBOARD_TZ). 포트·허용대역(CC_DASH_PORT·
#    CC_DASH_ALLOW_CIDR)은 뷰어가 env 를 읽지 않으므로 뷰어 config.json(port·allow_cidr)에 맞춰야 한다.
set -u

CONF="${CC_DASH_CONF:-$HOME/.config/cockpit/dashboard.env}"
[ -f "$CONF" ] && . "$CONF"

# 서버가 참조할 수 있도록 명시 export(없으면 기본값).
export CC_DASH_PORT="${CC_DASH_PORT:-18080}"
export CC_DASH_BIND="${CC_DASH_BIND:-127.0.0.1}"
export CC_DASH_IDLE_EXIT_SECS="${CC_DASH_IDLE_EXIT_SECS:-}"
export CC_DASH_TZ="${CC_DASH_TZ:-UTC}"
export CC_DASH_ALLOW_CIDR="${CC_DASH_ALLOW_CIDR:-100.64.0.0/10}"
# 일부 뷰어는 타임존을 TZ/CLAUDE_DASHBOARD_TZ 로 받는다 — 둘 다 채워 둔다.
export TZ="${TZ:-$CC_DASH_TZ}"
export CLAUDE_DASHBOARD_TZ="${CLAUDE_DASHBOARD_TZ:-$CC_DASH_TZ}"

PYTHON_BIN="${CC_DASH_PYTHON:-python3}"
SERVER="${CC_DASH_CONVERTER_SERVER:-${CC_DASH_HOME:-$HOME/claude-logs}/active_server.py}"

exec "$PYTHON_BIN" "$SERVER"
