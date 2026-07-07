#!/bin/bash
# install-viewer.sh — 대시보드 옵트인 설치(뷰어 핀 클론 + 설정 생성). /cockpit-setup 마법사가 실행.
#
# 하는 일(멱등):
#   1) 공개 뷰어(claude-session-dashboard)를 viewer-pin.txt 의 핀 커밋으로 CC_DASH_HOME 에 클론/checkout
#   2) 뷰어 config.json 생성(기존재 시 보존) — port·allow_cidr 는 뷰어가 env 를 읽지 않아 여기가 단일 출처
#   3) ~/.config/cockpit/dashboard.env 생성(기존재 시 보존 + 안전 키 CC_DASH_IDLE_EXIT_SECS 누락 시만 보충)
#   4) 세션 목록 초기 변환 1회(비치명 — 실패해도 cockpit-dashboard start 가 재시도)
#
# 하지 않는 일(불변식): 자동시작 등록 · 서버 기동(설치≠기동 분리 — 기동은 Windows 의
#   Cockpit-Dashboard.cmd 더블클릭 또는 /usr/local/bin/cockpit-dashboard start).
# 기본 allow_cidr=127.0.0.1/32(loopback 전용) — v0.1.3 범위="호스트 본인 localhost 열람 전용"의
#   구현(Codex 4d). 원격(타기기) 열람은 고급 사용만: plugin/dashboard/README 자가검증 통과 후 직접 변경.
# 네트워크 필요(github.com 클론) — 실패는 정직 에러.
set -euo pipefail
umask 077

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PIN_FILE="$SCRIPT_DIR/viewer-pin.txt"

say() { printf '%s\n' "$*"; }
die() { printf '[install-viewer] 오류: %s\n' "$*" >&2; exit 1; }

# ── 실패 UX 계약(#16·설계 §4.1): nonzero exit 시 stderr 마지막 줄에 표준 토큰을 반드시 emit.
#   ps1(Invoke-DashboardInstall)이 이 토큰을 한국어 완료화면 문구로 매핑. git clone/fetch 실패는
#   stderr 를 _classify_git_err 로 분류해 FAIL_CLASS 지정, 그 외 실패(set -e·die)는 unknown 강제.
#   성공 경로(exit 0)와 기존 정직 에러 문구는 그대로. 토큰은 ASCII → ps1 출력 인코딩과 무관.
FAIL_CLASS=""
_on_exit() {
  local rc=$?
  if [ "$rc" -ne 0 ]; then
    printf 'INSTALL_VIEWER_FAIL=%s\n' "${FAIL_CLASS:-unknown}" >&2
  fi
}
trap _on_exit EXIT

_classify_git_err() {
  # git clone/fetch stderr → 표준 클래스. 우선순위: proxy → tls → github-blocked → network → unknown.
  # (403 메시지에도 'unable to access' 가 붙으므로 github-blocked 를 network 보다 먼저 판정.)
  case "$1" in
    *[Pp]roxy*|*407*)                                                     printf 'proxy' ;;
    *certificate*|*SSL*|*TLS*|*"self-signed"*|*"self signed"*|*gnutls_handshake*|*schannel*) printf 'tls' ;;
    *403*|*"Repository not found"*|*"Permission denied"*|*"Authentication failed"*|*"could not read Username"*) printf 'github-blocked' ;;
    *"Could not resolve host"*|*"Temporary failure in name resolution"*|*"unable to access"*|*"Failed to connect"*|*"Couldn't connect"*|*timeout*|*"timed out"*|*"Operation timed out"*|*"Connection refused"*|*"Connection timed out"*|*"Network is unreachable"*) printf 'network' ;;
    *)                                                                    printf 'unknown' ;;
  esac
}

[ -f "$PIN_FILE" ] || die "viewer-pin.txt 없음: $PIN_FILE"
VIEWER_REPO_URL="$(grep -E '^VIEWER_REPO_URL=' "$PIN_FILE" | head -1 | cut -d= -f2-)"
VIEWER_PIN="$(grep -E '^VIEWER_PIN=' "$PIN_FILE" | head -1 | cut -d= -f2-)"
case "$VIEWER_PIN" in
  *[!0-9a-f]*|'') die "VIEWER_PIN 형식 오류(40-hex 아님): '$VIEWER_PIN'" ;;
esac
[ "${#VIEWER_PIN}" -eq 40 ] || die "VIEWER_PIN 길이 오류(${#VIEWER_PIN}≠40)"
# 공급망 앵커 — 정식 https git URL 만 허용(스킴 강제·공백/메타문자 거부, Codex 4d ⑦).
case "$VIEWER_REPO_URL" in
  https://*[!\ ]*) : ;;
  *) die "VIEWER_REPO_URL 형식 오류(https:// git URL 아님): '$VIEWER_REPO_URL'" ;;
esac
case "$VIEWER_REPO_URL" in *[\ \'\"\`\$\;\|\&]*) die "VIEWER_REPO_URL 에 허용되지 않는 문자" ;; esac
command -v git >/dev/null 2>&1 || die "git 없음"
command -v python3 >/dev/null 2>&1 || die "python3 없음"

CONF_DIR="$HOME/.config/cockpit"
CONF="${CC_DASH_CONF:-$CONF_DIR/dashboard.env}"
# 기존 dashboard.env 가 CC_DASH_HOME 을 지정했으면 존중(dashboard-run.sh 와 동일 규약).
[ -f "$CONF" ] && . "$CONF"
DASH_HOME="${CC_DASH_HOME:-$HOME/claude-logs}"

say "=== cockpit 대시보드 뷰어 설치(핀 ${VIEWER_PIN:0:7}) ==="
say "  뷰어: $VIEWER_REPO_URL"
say "  위치: $DASH_HOME"
say ""

# ── 1) 뷰어 클론/checkout(핀 고정·detached) ─────────────────────────
if [ -e "$DASH_HOME" ]; then
  [ -d "$DASH_HOME/.git" ] || die "$DASH_HOME 이 이미 있고 git 저장소가 아님 — 데이터 보호를 위해 건드리지 않습니다. 옮기거나 CC_DASH_HOME 을 바꾼 뒤 재실행하세요."
  ORIGIN="$(git -C "$DASH_HOME" remote get-url origin 2>/dev/null || true)"
  [ "$ORIGIN" = "$VIEWER_REPO_URL" ] || die "$DASH_HOME 의 origin 이 다름($ORIGIN) — 다른 저장소를 덮지 않습니다."
  say "[1] 기존 클론 재사용 — fetch 후 핀 checkout"
  if ! _git_err="$(git -C "$DASH_HOME" fetch --quiet origin 2>&1 1>/dev/null)"; then
    [ -n "$_git_err" ] && printf '%s\n' "$_git_err" >&2
    FAIL_CLASS="$(_classify_git_err "$_git_err")"
    die "뷰어 fetch 실패 — 네트워크/프록시/GitHub 접근 확인(상세는 위 git 메시지)"
  fi
else
  say "[1] 뷰어 클론"
  if ! _git_err="$(git clone --quiet "$VIEWER_REPO_URL" "$DASH_HOME" 2>&1 1>/dev/null)"; then
    [ -n "$_git_err" ] && printf '%s\n' "$_git_err" >&2
    FAIL_CLASS="$(_classify_git_err "$_git_err")"
    die "뷰어 클론 실패 — 네트워크/프록시/GitHub 접근 확인(상세는 위 git 메시지)"
  fi
fi
git -C "$DASH_HOME" checkout --quiet "$VIEWER_PIN"
HEAD="$(git -C "$DASH_HOME" rev-parse HEAD)"
[ "$HEAD" = "$VIEWER_PIN" ] || die "checkout 후 HEAD($HEAD)가 핀과 불일치"
chmod 700 "$DASH_HOME"
say "    ✓ HEAD=$HEAD (핀 일치)"

# ── 2) 뷰어 config.json(기존재 시 보존) ────────────────────────────
CFG="$DASH_HOME/config.json"
if [ -f "$CFG" ]; then
  say "[2] config.json 기존재 — 보존(사용자 설정 존중)"
  BIND="$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1])).get("bind","127.0.0.1"))' "$CFG" 2>/dev/null || echo '?')"
  case "$BIND" in
    127.*|'::1'|localhost|'?') : ;;
    *) say "    ⚠ bind=$BIND (loopback 아님) — 원격 노출 구성입니다. README 자가검증을 통과했는지 확인하세요." ;;
  esac
else
  say "[2] config.json 생성(port 18080 · bind 127.0.0.1 · allow_cidr 127.0.0.1/32 = 호스트 본인 전용)"
  python3 - "$CFG" <<'PYCFG'
import json, sys
cfg = {"port": 18080, "bind": "127.0.0.1", "lang": "ko", "allow_cidr": "127.0.0.1/32"}
with open(sys.argv[1], "w", encoding="utf-8") as f:
    json.dump(cfg, f, ensure_ascii=False, indent=2)
    f.write("\n")
PYCFG
  chmod 600 "$CFG"
fi

# ── 3) dashboard.env(기존재 시 보존 + 안전 키 보충) ─────────────────
mkdir -p "$CONF_DIR"; chmod 700 "$CONF_DIR"
if [ -f "$CONF" ]; then
  say "[3] dashboard.env 기존재 — 보존"
  if ! grep -qE '^\s*(export\s+)?CC_DASH_IDLE_EXIT_SECS=' "$CONF"; then
    # 안전 키 누락만 보충(창-수명 백스톱) — 기존 값은 절대 안 바꿈(Codex 4d).
    printf '\n# cockpit install-viewer 보충: 창 닫힘 감지 실패 대비 유휴 자가종료 백스톱\nexport CC_DASH_IDLE_EXIT_SECS=900\n' >> "$CONF"
    say "    + CC_DASH_IDLE_EXIT_SECS=900 보충(누락이던 백스톱)"
  fi
  EBIND="$(grep -E '^\s*(export\s+)?CC_DASH_BIND=' "$CONF" | tail -1 | sed 's/.*=//; s/["'"'"']//g; s/[[:space:]].*//' || true)"
  case "${EBIND:-}" in
    ''|127.*|'::1'|localhost) : ;;
    *) say "    ⚠ CC_DASH_BIND=$EBIND (loopback 아님) — 원격 노출 구성입니다. README 자가검증 필수." ;;
  esac
else
  say "[3] dashboard.env 생성(loopback 전용 · idle-exit 백스톱 900초)"
  cat > "$CONF" <<EOF
# cockpit 대시보드 설정 — install-viewer.sh 생성($(date +%Y-%m-%d)). 상세: plugin/dashboard/config.example.sh
export CC_DASH_HOME="$DASH_HOME"
export CC_DASH_BIND=127.0.0.1
# 창 닫힘 감지 실패(브라우저 크래시 등) 대비 백스톱 — 허용 요청 900초 무발생 시 서버 자가종료.
export CC_DASH_IDLE_EXIT_SECS=900
EOF
  chmod 600 "$CONF"
fi

# ── 4) 초기 변환(비치명) ───────────────────────────────────────────
say "[4] 세션 목록 초기 변환(실패해도 기동 시 재시도)"
( cd "$DASH_HOME" && timeout 300 python3 convert_session.py ) >/dev/null 2>&1 \
  && say "    ✓ 변환 완료" \
  || say "    ⚠ 변환 실패/시간초과 — cockpit-dashboard start 가 재시도합니다."

say ""
say "설치 완료. 자동시작은 등록하지 않았습니다(출고 불변식 — 켜는 것은 항상 명시적)."
say "켜기: Windows 에서 Cockpit-Dashboard.cmd 더블클릭(창 닫으면 꺼짐)"
say "      또는 WSL 안에서: /usr/local/bin/cockpit-dashboard start"
say "끄기: 창 닫기(자동) · 수동은 cockpit-dashboard stop 또는 disable-remote.sh --apply"
exit 0
