#!/bin/bash
# disable-remote.sh — cockpit 원격 대시보드 **비활성화**.
#
# 하는 일(멱등):
#   1) launchd 자동시작 해제 + **영구 disable**(다음 로그인 재기동 차단, macOS)
#   2) 해당 포트 LISTEN 서버를 cmdline 검증 후 중지(blind kill 안 함)
#   3) 포트가 더는 열려 있지 않은지 확인
#   4) 개인 VPN(Tailscale 등) 접근 차단·재활성화 절차 안내
#
# 기본은 **dry-run**(무엇을 멈출지 미리보기만). 실제 적용은 --apply.
#   bash disable-remote.sh            # 미리보기
#   bash disable-remote.sh --apply    # 적용
#
# 설계: eval 미사용(특수문자 경로 안전). 비가역 동작(프로세스 중지·launchctl) 전 항상 미리보기.
# 원격 조종은 이 패키지에서 가장 위험한 기능이라 끄는 절차는 명시적·관찰가능해야 한다(GOVERNANCE 6장).
set -uo pipefail

APPLY=0
[ "${1:-}" = "--apply" ] && APPLY=1

CONF="${CC_DASH_CONF:-$HOME/.config/cockpit/dashboard.env}"
[ -f "$CONF" ] && . "$CONF"
PORT="${CC_DASH_PORT:-18080}"
LABEL="com.cockpit.dashboard"
PLIST="$HOME/Library/LaunchAgents/${LABEL}.plist"
SERVER="${CC_DASH_CONVERTER_SERVER:-${CC_DASH_HOME:-$HOME/claude-logs}/active_server.py}"
SERVER_BASENAME="$(basename "$SERVER")"

say() { printf '%s\n' "$*"; }

say "=== cockpit 원격 대시보드 비활성화 ($([ "$APPLY" -eq 1 ] && echo APPLY || echo dry-run)) ==="
say "  대상: label=$LABEL · port=$PORT · server=$SERVER_BASENAME"
say ""

# ── 1) launchd 자동시작 해제 + 영구 disable (macOS) ─────────────
say "[1] 자동시작 해제 + 영구 disable"
if [ "$(uname)" = "Darwin" ]; then
  UID_N="$(id -u)"
  if [ -f "$PLIST" ]; then
    say "    \$ launchctl bootout gui/$UID_N/$LABEL   (현재 인스턴스 내림)"
    say "    \$ launchctl disable gui/$UID_N/$LABEL    (다음 로그인 재기동 차단 — 영구)"
    if [ "$APPLY" -eq 1 ]; then
      launchctl bootout "gui/$UID_N/$LABEL" 2>/dev/null || launchctl unload "$PLIST" 2>/dev/null || true
      launchctl disable "gui/$UID_N/$LABEL" 2>/dev/null || true
    fi
    say "    plist 보존: $PLIST (재활성화는 아래 안내)"
  else
    say "    (launchd plist 없음 — 자동시작 미설정: $PLIST)"
  fi
else
  say "    (비-macOS: systemd --user 등 등록한 자동시작 단위를 직접 stop·disable)"
fi
say ""

# ── 2) 포트 LISTEN 서버 중지 (cmdline 검증 후 — blind kill 금지) ─
say "[2] 포트 $PORT LISTEN 서버 중지"
PIDS=""
if command -v lsof >/dev/null; then
  PIDS="$(lsof -nP -tiTCP:"$PORT" -sTCP:LISTEN 2>/dev/null || true)"
fi
if [ -z "$PIDS" ]; then
  say "    (포트 $PORT 에 LISTEN 중인 프로세스 없음 — 이미 내려가 있음)"
else
  for pid in $PIDS; do
    # cmdline 에 기대 서버 basename 이 있는지 확인 — 무관 프로세스 오중지 방지.
    CMD="$(ps -o command= -p "$pid" 2>/dev/null || true)"
    case "$CMD" in
      *"$SERVER_BASENAME"*)
        say "    PID $pid (cmdline 확인됨): ${CMD%% *}…"
        say "    \$ kill -TERM $pid"
        [ "$APPLY" -eq 1 ] && kill -TERM "$pid" 2>/dev/null || true ;;
      *)
        say "    ⚠ PID $pid 는 포트 $PORT LISTEN 이지만 cmdline 에 '$SERVER_BASENAME' 없음 — 건너뜀(수동 확인):"
        say "      ps -o command= -p $pid" ;;
    esac
  done
fi
say ""

# ── 3) 포트 확인 ───────────────────────────────────────────────
say "[3] 포트 $PORT 닫힘 확인"
if [ "$APPLY" -eq 1 ]; then
  sleep 1
  if command -v lsof >/dev/null && lsof -nP -iTCP:"$PORT" -sTCP:LISTEN >/dev/null 2>&1; then
    say "    ⚠ 아직 $PORT 가 LISTEN 중 — 남은 프로세스 확인: lsof -nP -iTCP:$PORT -sTCP:LISTEN"
  else
    say "    ✓ 포트 $PORT 미개방(또는 lsof 미설치로 미확인)"
  fi
else
  say "    (dry-run: 적용 후 'lsof -nP -iTCP:$PORT -sTCP:LISTEN' 로 확인)"
fi
say ""

# ── 4) VPN 접근 차단 안내 ──────────────────────────────────────
say "[4] 개인 VPN 접근 차단(수동 — 환경 의존)"
say "    서버를 내렸으면 외부 기기 접속은 이미 불가하다. 추가로 VPN 노출을 줄이려면:"
say "      • Tailscale: 이 노드의 공유/Funnel/Serve 를 껐는지 확인(tailscale funnel status / serve status),"
say "        필요 시 ACL 에서 :$PORT 인바운드 제거."
say "      • 다른 VPN(WireGuard 등): 해당 포트 인바운드 규칙 제거."
say ""

# ── 재활성화 안내 ──────────────────────────────────────────────
say "── 재활성화(원할 때) ──"
if [ "$(uname)" = "Darwin" ]; then
  say "  macOS:  launchctl enable gui/$(id -u)/$LABEL && launchctl bootstrap gui/$(id -u) '$PLIST'"
  say "          (또는 setup 마법사 재실행)"
fi
say "  공통:   서버 수동 기동 → $SERVER"
say ""
[ "$APPLY" -eq 0 ] && say "※ dry-run 이었습니다. 실제로 끄려면: bash $0 --apply"
exit 0
