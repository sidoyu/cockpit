#!/usr/bin/env bash
# provision.sh — cockpit WSL 골든 이미지 **내부 프로비저닝**.
#
# 역할: 깨끗한 베이스 리눅스(rootfs) 안에서 실행되어, 비개발자가 Windows/WSL2 에서
#   Claude Code + cockpit 을 "거의 그대로" 쓸 수 있는 상태까지 채운다.
#   이 스크립트의 산출(파일시스템 상태)을 tar 로 떠서 골든 이미지가 된다(build-rootfs.sh).
#
# 실행 위치: **이미지 빌드 중**(CI 또는 베이스 distro 안), root 로. 사용자 PC 에서 직접 X.
#   staged fallback(골든 이미지 없이) 경로에서도 동일 스크립트를 베이스 distro 안에서 실행한다.
#
# 안전 불변식(절대 위반 금지 — secret-scan·Codex 게이트):
#   • 개인정보·키·계정·사내 식별자 **0건**. 어떤 비밀도 이미지에 굽지 않는다.
#   • v0.1.1 부터: 편의 설정은 사전적용(bypass·effort·model·remote-control·trust)하되,
#     **외부 송신(egress) 동의만은 첫 실행 게이트로 남긴다**(동의 무결성). 즉 이미지에 절대
#     굽지 않는 것: ① egress 동의 마커(STATE_DIR/setup_complete)
#     ② 원격 대시보드(자체호스팅 뷰어) 자동시작 ③ 어떤 비밀/자격증명.
#     (claude.ai Code 탭 원격조종 = remoteControlAtStartup, 아웃바운드 HTTPS 전용·수신포트 없음.)
#   • 멱등: 다시 실행해도 안전(이미 있으면 건너뜀). 단 v0.1.1 부터 ~/.claude 사전설정은
#     "비어있을 때만 생성"으로 보존(기존 사용자 데이터 미파괴).
#
# 파라미터(환경변수, 모두 선택 — 기본은 제네릭):
#   COCKPIT_USER          이미지의 기본 비-root 사용자 (기본: cockpit)
#   COCKPIT_PLUGIN_SRC    스테이징할 플러그인 트리 경로 (기본: 빌더가 /tmp/cockpit-plugin 에 둠)
#   COCKPIT_INSTALL_CC    1이면 Claude Code CLI 도 설치 시도 (기본: 1; 네트워크 없으면 경고 후 계속)
#   COCKPIT_MARKETPLACE   /plugin marketplace add 에 쓸 소스 (기본: example.invalid 플레이스홀더)
#   COCKPIT_MARKETPLACE_SRC  마켓플레이스 repo 트리(공개 sidoyu/cockpit 과 동일 content = clean export).
#                            빌더가 /tmp/cockpit-marketplace 에 둠. 플러그인 사전설치 베이크(4.5)의 소스.
#   COCKPIT_PLUGIN_COMMIT    베이크할 설치 정체성 commit(40-hex 전체 SHA·**공개 sidoyu/cockpit 기준** —
#                            F-1: private SHA 금지). 비우면 베이크 skip = 첫 실행 2단계 유지(정직 폴백).
#   COCKPIT_BAKE_PLUGINS     1(기본)이면 위 조건 충족 시 플러그인 사전설치 베이크. 0=강제 skip.
set -euo pipefail

log()  { printf '[provision] %s\n' "$*"; }
warn() { printf '[provision][warn] %s\n' "$*" >&2; }
die()  { printf '[provision][FATAL] %s\n' "$*" >&2; exit 1; }

[ "$(id -u)" -eq 0 ] || die "root 로 실행해야 합니다(이미지 빌드 컨텍스트)."

COCKPIT_USER="${COCKPIT_USER:-cockpit}"
COCKPIT_PLUGIN_SRC="${COCKPIT_PLUGIN_SRC:-/tmp/cockpit-plugin}"
COCKPIT_INSTALL_CC="${COCKPIT_INSTALL_CC:-1}"
COCKPIT_MARKETPLACE="${COCKPIT_MARKETPLACE:-https://example.invalid/cc-companion}"
COCKPIT_MARKETPLACE_SRC="${COCKPIT_MARKETPLACE_SRC:-/tmp/cockpit-marketplace}"
COCKPIT_PLUGIN_COMMIT="${COCKPIT_PLUGIN_COMMIT:-}"
COCKPIT_BAKE_PLUGINS="${COCKPIT_BAKE_PLUGINS:-1}"
# v0.1.1 사전설정 프로필(동윤님 맥미니 행동키 복제·2026-06-26 결정). 모두 선택 override 가능.
#   COCKPIT_MODEL_PIN="" 로 비우면 model 미핀(계정 기본 모델). 기본=Opus 4.8 1M(동료 Pro+ 전제).
COCKPIT_PRECONFIGURE="${COCKPIT_PRECONFIGURE:-1}"          # 0이면 ~/.claude 사전설정 전부 건너뜀(구 OFF-출고 동작)
COCKPIT_MODEL_PIN="${COCKPIT_MODEL_PIN-claude-opus-4-8[1m]}"
COCKPIT_EFFORT="${COCKPIT_EFFORT:-xhigh}"
COCKPIT_PRIMARY_LANGUAGE="${COCKPIT_PRIMARY_LANGUAGE:-한국어}"

# 사용자명 위생(옵션 주입 방지) — 반드시 [a-z_] 로 시작, 이후 [a-z0-9_-], 길이 ≤32.
# 선행 '-' 차단으로 useradd/usermod/chown 옵션 오해석을 원천 봉쇄(+ 아래 '--' 구분자 이중방어).
case "$COCKPIT_USER" in
  "" )            die "COCKPIT_USER 가 비어 있습니다." ;;
  [!a-z_]* )      die "COCKPIT_USER 는 영문 소문자 또는 '_' 로 시작해야 합니다: '$COCKPIT_USER'" ;;
  *[!a-z0-9_-]* ) die "COCKPIT_USER 형식 오류(소문자/숫자/_/-): '$COCKPIT_USER'" ;;
esac
[ "${#COCKPIT_USER}" -le 32 ] || die "COCKPIT_USER 가 너무 깁니다(≤32): '$COCKPIT_USER'"

export DEBIAN_FRONTEND=noninteractive

# ── 1) 베이스 패키지 ───────────────────────────────────────────────
log "1) 베이스 패키지 설치"
if command -v apt-get >/dev/null 2>&1; then
  apt-get update -y
  apt-get install -y --no-install-recommends \
    ca-certificates curl git python3 python3-venv nodejs npm zstd sudo locales tzdata
  # iproute2(ss): disable-remote.sh 의 포트→PID 탐지와 cockpit-dashboard orphan 폴백용(최소 WSL
  # Ubuntu 엔 부재 실측 — cc-cockpit2). 대시보드 정상 경로는 pidfile 이라 ss 무의존 → **비치명 설치**
  # (실패해도 이미지 빌드 계속·python socket 이 LISTEN 판정 커버, Codex 4d ⑧).
  apt-get install -y --no-install-recommends iproute2 \
    || warn "iproute2 설치 실패 — cockpit-dashboard 정상 경로(pidfile)는 무관, orphan 폴백만 제한"
  # wslu(wslview): /login 브라우저 자동 오픈 1순위 도구(5.5 래퍼가 사용). 비-우분투 베이스 등
  # 부재 시에도 이미지 빌드는 계속 — 래퍼의 powershell.exe 절대경로 폴백이 커버(비치명).
  apt-get install -y --no-install-recommends wslu \
    || warn "wslu 설치 실패 — cockpit-open-url 은 powershell.exe 폴백으로 동작"
  # 한글 메시지 깨짐 방지(선택). 실패해도 치명 아님.
  sed -i 's/^# *\(en_US.UTF-8\)/\1/; s/^# *\(ko_KR.UTF-8\)/\1/' /etc/locale.gen 2>/dev/null || true
  locale-gen en_US.UTF-8 ko_KR.UTF-8 2>/dev/null || true
  apt-get clean
  rm -rf /var/lib/apt/lists/*   # 이미지 크기·재현성: 캐시 제거
else
  warn "apt-get 없음 — 베이스 이미지가 Debian/Ubuntu 계열이 아닙니다. 패키지 단계 건너뜀."
fi

# ── 2) 기본 비-root 사용자(sudo) — 멱등 수렴 ───────────────────────
# 사용자 존재 여부와 무관하게 sudo 그룹 + NOPASSWD sudoers 를 '원하는 상태'로 수렴시킨다
# (재실행/커스텀 베이스에서 '사용자는 있는데 sudo 없음' 상태 방지).
log "2) 기본 사용자 '$COCKPIT_USER' (멱등 수렴)"
if id -- "$COCKPIT_USER" >/dev/null 2>&1; then
  log "   사용자 이미 존재 — 보존(권한만 수렴)"
else
  useradd -m -s /bin/bash -- "$COCKPIT_USER"
fi
# 비개발자 편의: sudo 비밀번호 생략(개인 PC·단일 사용자 전제). GOVERNANCE 2.1 경계.
usermod -aG sudo -- "$COCKPIT_USER" 2>/dev/null || true
install -d -m 0755 /etc/sudoers.d
printf '%s ALL=(ALL) NOPASSWD:ALL\n' "$COCKPIT_USER" > "/etc/sudoers.d/90-cockpit"
chmod 0440 "/etc/sudoers.d/90-cockpit"
visudo -cf "/etc/sudoers.d/90-cockpit" >/dev/null || die "sudoers 검증 실패"
USER_HOME="$(getent passwd "$COCKPIT_USER" | cut -d: -f6)"
[ -n "$USER_HOME" ] && [ -d "$USER_HOME" ] || die "사용자 홈을 찾지 못함: $COCKPIT_USER"

# Windows 드라이브 automount(/mnt/c 등) 소유 uid/gid = 이 사용자의 실제 uid/gid 에 맞춘다.
# base 이미지에 ubuntu(1000)가 있으면 useradd 로 만든 cockpit 은 1001 이 되므로, wsl.conf 의
# automount uid=1000 하드코딩은 cockpit(1001)의 /mnt/c 쓰기를 막는다(실기 발견: 재설치 생존용
# /mnt/c 백업이 Permission denied). → automount uid/gid 를 실제 사용자에 정렬해 원천 해소.
COCKPIT_UID="$(id -u -- "$COCKPIT_USER")"
COCKPIT_GID="$(id -g -- "$COCKPIT_USER")"

# ── 3) /etc/wsl.conf (기본 사용자·systemd·상호운용·automount uid 정렬) ────────────────
log "3) /etc/wsl.conf 적용"
if [ -f "$(dirname "$0")/wsl.conf" ]; then
  # 빌더가 같은 디렉터리에 wsl.conf 를 둔 경우 그대로, 사용자명·uid·gid 치환.
  sed -e "s/__COCKPIT_USER__/$COCKPIT_USER/g" \
      -e "s/__COCKPIT_UID__/$COCKPIT_UID/g" \
      -e "s/__COCKPIT_GID__/$COCKPIT_GID/g" \
      "$(dirname "$0")/wsl.conf" > /etc/wsl.conf
else
  cat > /etc/wsl.conf <<EOF
[user]
default=$COCKPIT_USER
[boot]
systemd=true
[interop]
enabled=true
appendWindowsPath=false
[automount]
enabled=true
options=metadata,uid=$COCKPIT_UID,gid=$COCKPIT_GID,umask=022
EOF
fi
chmod 0644 /etc/wsl.conf

# ── 4) cockpit 플러그인 스테이징(읽기용 참조본) ────────────────────
# 이미지 안 고정 경로에 플러그인 트리를 둔다. 사용자는 첫 실행 때
#   /plugin marketplace add <소스>  →  /plugin install cockpit@cc-companion  →  /cockpit-setup
# 을 실행한다. (마켓플레이스 소스가 로컬 경로면 이 스테이징본을 바로 가리킬 수 있음.)
log "4) cockpit 플러그인 스테이징"
STAGE_DIR="/opt/cockpit"
if [ -d "$COCKPIT_PLUGIN_SRC" ]; then
  install -d -m 0755 "$STAGE_DIR"
  cp -a "$COCKPIT_PLUGIN_SRC/." "$STAGE_DIR/"
  chown -R -- "$COCKPIT_USER:$COCKPIT_USER" "$STAGE_DIR"
  log "   스테이징: $STAGE_DIR (소스: $COCKPIT_PLUGIN_SRC)"
else
  warn "플러그인 소스 없음($COCKPIT_PLUGIN_SRC) — 스테이징 건너뜀. 사용자가 마켓플레이스로 직접 추가."
fi

# ── 4.5) 플러그인 완전 사전설치 베이크(v0.1.2-B — 첫 실행 2단계 제거) ────────
# 실측 포맷 정답 = docs/plugin-bake-format.md (2026-07-02 동윤 윈도우 v0.1.0 인스펙트·claude 2.1.186).
# blind 베이크 금지: 조건 미충족이면 ① 의도적 skip(commit 미주입·BAKE=0)=경고 후 2단계 폴백(정직),
# ② 베이크를 시도했는데 입력이 틀림(형식·placeholder·트리 불완전)=die(사일런트 미베이크 출고 방지).
# ⚠ 정체성(F-1): gitCommitSha 는 반드시 **공개 sidoyu/cockpit commit**. 마켓플레이스 클론은 .git 없이
#   트리만 굽는다(빌드가 만든 로컬 git 이력 = 가짜 SHA 라 더 나쁨) — 업데이트 플로우 동작은 라이브 실측 판정.
log "4.5) 플러그인 사전설치 베이크"
_plugins_baked=0
_baked_pver=""
if [ "$COCKPIT_BAKE_PLUGINS" != "1" ]; then
  log "   (COCKPIT_BAKE_PLUGINS=0 — 건너뜀·첫 실행 2단계 경로)"
elif [ -z "$COCKPIT_PLUGIN_COMMIT" ]; then
  warn "COCKPIT_PLUGIN_COMMIT 미설정 — 베이크 건너뜀(첫 실행 2단계 폴백). 발행 빌드는 공개 sidoyu/cockpit commit(40-hex) 주입."
elif ! printf '%s' "$COCKPIT_PLUGIN_COMMIT" | grep -qE '^[0-9a-f]{40}$'; then
  die "COCKPIT_PLUGIN_COMMIT 형식 오류(40-hex 전체 SHA·공개 repo 기준 필요): '$COCKPIT_PLUGIN_COMMIT'"
elif printf '%s' "$COCKPIT_MARKETPLACE" | grep -q 'example\.invalid'; then
  die "베이크 요청됐는데 COCKPIT_MARKETPLACE 가 placeholder($COCKPIT_MARKETPLACE) — 실제 git URL 필요(사일런트 미로드 방지)."
elif [ ! -f "$COCKPIT_MARKETPLACE_SRC/.claude-plugin/marketplace.json" ] || [ ! -f "$COCKPIT_MARKETPLACE_SRC/plugin/.claude-plugin/plugin.json" ]; then
  die "마켓플레이스 트리 불완전($COCKPIT_MARKETPLACE_SRC) — .claude-plugin/marketplace.json + plugin/.claude-plugin/plugin.json 필요."
elif ! command -v python3 >/dev/null 2>&1; then
  die "python3 없음 — 플러그인 상태 JSON 생성 불가(베이크 필수 의존)."
else
  PLUG_DIR="$USER_HOME/.claude/plugins"
  if [ -e "$PLUG_DIR/installed_plugins.json" ]; then
    # 보존(멱등·기존 데이터 미파괴)하되 **의미검증 통과 시에만** 베이크 상태로 간주(Codex 발견6:
    # 손상/부분 상태를 "미리 설치됨"으로 안내하는 오표기 방지). 검증 실패=보존+미베이크 취급(정직).
    _baked_pver="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["plugins"]["cockpit@cc-companion"][0]["version"])' "$PLUG_DIR/installed_plugins.json" 2>/dev/null || echo "")"
    _baked_path="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["plugins"]["cockpit@cc-companion"][0]["installPath"])' "$PLUG_DIR/installed_plugins.json" 2>/dev/null || echo "")"
    if [ -n "$_baked_pver" ] && [ -n "$_baked_path" ] && [ -d "$_baked_path" ] && [ -f "$PLUG_DIR/known_marketplaces.json" ]; then
      log "   installed_plugins.json 이미 존재·유효(v$_baked_pver) — 보존(멱등)"
      _plugins_baked=1
    else
      warn "installed_plugins.json 존재하나 불완전(entry/캐시/known_marketplaces 결손) — 보존하되 미베이크 취급(MOTD=2단계)."
    fi
  else
    _baked_pver="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get("version",""))' "$COCKPIT_MARKETPLACE_SRC/plugin/.claude-plugin/plugin.json")"
    [ -n "$_baked_pver" ] || die "plugin.json 에 version 없음 — 베이크 불가."
    MP_DIR="$PLUG_DIR/marketplaces/cc-companion"
    CACHE_DIR="$PLUG_DIR/cache/cc-companion/cockpit/$_baked_pver"
    # 잔존 부분 상태 제거 후 재생성(Codex 발견4: 대상 dir 이 이미 있으면 `cp -a SRC DEST` 가
    # DEST 안으로 중첩 복사돼 트리가 깨진다). installed_plugins.json 부재 = 미설치 상태이므로
    # 부분 잔존물 제거는 안전한 수렴(사용자 데이터 아님).
    rm -rf "$MP_DIR" "$CACHE_DIR"
    install -d -m 0755 "$MP_DIR" "$CACHE_DIR"
    cp -a "$COCKPIT_MARKETPLACE_SRC/." "$MP_DIR/"          # marketplace 클론 위치(트리 전체)
    cp -a "$COCKPIT_MARKETPLACE_SRC/plugin/." "$CACHE_DIR/" # 설치 캐시 = marketplace 의 plugin/ (실측 레이아웃)
    # 상태 JSON 2종 — 실측 포맷 그대로. 타임스탬프는 SOURCE_DATE_EPOCH(재현 빌드) 우선.
    python3 - "$PLUG_DIR" "$COCKPIT_MARKETPLACE" "$MP_DIR" "$CACHE_DIR" "$_baked_pver" "$COCKPIT_PLUGIN_COMMIT" <<'PYBAKE'
import json, os, sys, datetime
plug, mkt_url, mp_dir, cache_dir, ver, commit = sys.argv[1:7]
epoch = os.environ.get("SOURCE_DATE_EPOCH", "")
ts = (datetime.datetime.fromtimestamp(int(epoch), datetime.timezone.utc)
      if epoch.isdigit() else datetime.datetime.now(datetime.timezone.utc))
iso = ts.strftime("%Y-%m-%dT%H:%M:%S.000Z")
with open(os.path.join(plug, "known_marketplaces.json"), "w", encoding="utf-8") as f:
    json.dump({"cc-companion": {"source": {"source": "git", "url": mkt_url},
                                "installLocation": mp_dir, "lastUpdated": iso}},
              f, ensure_ascii=False, indent=2)
with open(os.path.join(plug, "installed_plugins.json"), "w", encoding="utf-8") as f:
    json.dump({"version": 2, "plugins": {"cockpit@cc-companion": [{
        "scope": "user", "installPath": cache_dir, "version": ver,
        "installedAt": iso, "lastUpdated": iso, "gitCommitSha": commit}]}},
              f, ensure_ascii=False, indent=2)
PYBAKE
    chmod 0644 "$PLUG_DIR/known_marketplaces.json" "$PLUG_DIR/installed_plugins.json"
    chown -R -- "$COCKPIT_USER:$COCKPIT_USER" "$PLUG_DIR"
    _plugins_baked=1
    log "   베이크 완료: cockpit@cc-companion v$_baked_pver (marketplace=$COCKPIT_MARKETPLACE · commit=$(printf '%.7s' "$COCKPIT_PLUGIN_COMMIT")) — 첫 실행 2단계 제거"
  fi
fi

# ── 5) Claude Code CLI(선택, 네트워크 의존) ────────────────────────
log "5) Claude Code CLI 설치(선택)"
if [ "$COCKPIT_INSTALL_CC" = "1" ]; then
  if command -v claude >/dev/null 2>&1; then
    log "   (이미 설치됨 — 보존)"
  elif command -v npm >/dev/null 2>&1; then
    # 공식 배포 채널. CLAUDE_CODE_VERSION 설정 시 그 버전으로 핀(공급망·재현성):
    # 발행 빌드는 핀 필수(publish-gate 가 provenance 의 floating/latest 를 차단), 개발 빌드는 latest 허용.
    # 실패(네트워크 등)해도 이미지 빌드는 계속 — 첫 실행 때 사용자가 설치 가능.
    _cc_pkg="@anthropic-ai/claude-code${CLAUDE_CODE_VERSION:+@${CLAUDE_CODE_VERSION}}"
    [ -z "${CLAUDE_CODE_VERSION:-}" ] && warn "CLAUDE_CODE_VERSION 미설정 — claude-code latest(floating) 설치. 발행 빌드는 핀 필요."
    if npm install -g "$_cc_pkg" >/dev/null 2>&1; then
      log "   설치 완료(npm 글로벌: $_cc_pkg)"
    else
      warn "Claude Code CLI 설치 실패(네트워크?) — 사용자가 첫 실행 시 설치하세요. 이미지 빌드는 계속."
    fi
  else
    warn "npm 없음 — Claude Code CLI 미설치. 사용자 첫 실행 시 설치."
  fi
else
  log "   (COCKPIT_INSTALL_CC=0 — 건너뜀)"
fi
# 로그인(OAuth)은 사용자별이라 절대 굽지 않는다 — 첫 WSL 실행 때 `claude` 로그인.

# ── 5.5) 브라우저 오픈 래퍼(/login OAuth 자동 오픈) — 무조건 설치 ──────────
# appendWindowsPath=false(§3) 라 wslview 가 Windows exe 를 PATH 에서 못 찾을 수 있어
# 폴백 체인(wslview→xdg-open→powershell.exe 절대경로)을 래퍼로 베이크. Claude Code 는
# $BROWSER 존중. URL 을 열기만 하며 외부송신·동의와 무관(OFF 불변식 무영향).
# PRECONFIGURE 게이트 밖: 사용자 선호가 아니라 시스템 배관(0 이어도 /login UX 성립 필요).
log "5.5) cockpit-open-url 래퍼 + BROWSER env"
cat > /usr/local/bin/cockpit-open-url <<'OPENURL'
#!/usr/bin/env bash
# cockpit-open-url — $BROWSER 래퍼: WSL 안에서 URL 을 Windows 기본 브라우저로 연다.
# 체인: wslview → xdg-open → powershell.exe(절대경로·appendWindowsPath=false 전제).
# 전부 실패 시 비0 종료 = 호출측(Claude Code)이 URL 표시 → 수동 복사 폴백 자연 유지.
set -u
url="${1:-}"
[ -n "$url" ] || { echo "usage: cockpit-open-url <http(s)-url>" >&2; exit 2; }
# 스킴+문자 allowlist(bash 정규식·anchored — 개행/제어문자 포함 전체 문자열 검증) —
# 아래 PowerShell 단일인용('$url') 리터럴 안전성의 전제. ' " ` $ 공백 ( ) ; < > | \ 개행
# 전부 거부(OAuth URL 필요 문자는 전부 포함). grep 라인단위 검사는 개행 통과 구멍(Codex 4d).
# 거부 메시지에 URL 미출력(제어문자 터미널 출력 방지) — Claude Code 가 어차피 URL 을 표시한다.
_re='^https?://[A-Za-z0-9._~:/?#@&=%+-]+$'
if ! (export LC_ALL=C; [[ "$url" =~ $_re ]]); then
  echo "[cockpit-open-url] 지원하지 않는 URL 형식/문자 — 화면에 표시된 URL 을 직접 여세요." >&2
  exit 2
fi
# opener 가 존재하되 멈추면 /login 흐름이 막힘 → timeout 가드(부재 시 직접 실행).
_to=""; command -v timeout >/dev/null 2>&1 && _to="timeout 5"
command -v wslview >/dev/null 2>&1 && $_to wslview "$url" >/dev/null 2>&1 && exit 0
# xdg-open 은 비-DE 환경에서 $BROWSER 를 역참조 — BROWSER=본 래퍼라 재귀 위험(Codex 4b) → 제거 후 호출.
command -v xdg-open >/dev/null 2>&1 && $_to env -u BROWSER xdg-open "$url" >/dev/null 2>&1 && exit 0
_PS='/mnt/c/Windows/System32/WindowsPowerShell/v1.0/powershell.exe'
if [ -x "$_PS" ]; then
  # allowlist 통과 URL 만 도달 — 단일인용 리터럴에 ' ` $ 불포함 보장(주입 불가).
  $_to "$_PS" -NoProfile -NonInteractive -Command "Start-Process '$url'" >/dev/null 2>&1 && exit 0
fi
printf '[cockpit-open-url] 브라우저 자동 열기 실패 — 이 URL 을 직접 여세요:\n  %s\n' "$url" >&2
exit 1
OPENURL
chmod 0755 /usr/local/bin/cockpit-open-url
# BROWSER env — 런처(bash -lc)·직접 진입(wsl -d) 모두 로그인 셸이라 profile.d 단일 배치로 커버.
# 시스템 drop-in = provision 산출물이므로 매번 덮어씀(수렴 — stale BROWSER 회귀 차단, Codex 4d).
printf '%s\n' '# cockpit: /login 등 URL 자동 오픈 래퍼(체인: wslview→xdg-open→powershell.exe)' \
              'export BROWSER=/usr/local/bin/cockpit-open-url' > /etc/profile.d/cockpit-browser.sh
chmod 0644 /etc/profile.d/cockpit-browser.sh

# ── 5.6) 대시보드 수명관리 스크립트(옵트인 기동/종료) — 무조건 설치 ────────
# 뷰어 본체는 굽지 않는다(reference-not-vendor — /cockpit-setup 옵트인이 핀 클론).
# 이 스크립트는 거버넌스 레이어의 기동/종료 진입점만: Windows Cockpit-Dashboard.cmd 가
# 부를 결정론적 절대경로(플러그인 캐시 경로는 버전 의존이라 부적합). 자동시작 등록과
# 무관 — 존재만으로 포트 LISTEN 없음(설치≠기동 분리, smoke §6(d) OFF 불변식 유지).
# §5.5 와 같은 heredoc 베이크(sibling 파일 금지 — staged/build 가 provision.sh+wsl.conf 만 전달).
log "5.6) cockpit-dashboard 수명관리 스크립트"
cat > /usr/local/bin/cockpit-dashboard <<'DASHBOARD'
#!/usr/bin/env bash
# cockpit-dashboard — 옵트인 대시보드 서버 수명관리(start/stop/status).
# 설치(뷰어 핀 클론·설정 생성)는 /cockpit-setup 의 install-viewer.sh 담당 — 여기는 기동/종료만.
# 출력 계약(기계 파싱·Cockpit-Dashboard.cmd): stdout 마지막 줄
#   "COCKPIT_DASH_RESULT <STATE> <PORT>"  STATE=STARTED|ALREADY|STOPPED|RUNNING|NOT_INSTALLED|ERROR
# 포트 판정 = python3 socket(외부도구 무의존 — 최소 WSL Ubuntu 엔 ss/lsof 부재 실측). 소유권 =
#   pidfile(+/proc cmdline·starttime 검증) — 우리 수명주기의 단일 진실. orphan(외부 기동)만 ss/lsof/
#   fuser 폴백. 사람용 안내는 stderr(한국어). start/stop 은 mkdir 원자적 락으로 직렬화(더블클릭 레이스
#   차단). flock(exec 9>파일)은 fd 를 명령치환/데몬에 얽어 호출측($()·.cmd for /f)이 영구 hang 하는
#   실기 사고 → fd 없는 mkdir 락으로 교체(실측 확정).
set -u
umask 077

CONF="${CC_DASH_CONF:-$HOME/.config/cockpit/dashboard.env}"
[ -f "$CONF" ] && . "$CONF"
DASH_HOME="${CC_DASH_HOME:-$HOME/claude-logs}"
SERVER="$DASH_HOME/active_server.py"
STATE_DIR="$HOME/.config/cockpit"
mkdir -p "$STATE_DIR"; chmod 700 "$STATE_DIR"
LOCKDIR="$STATE_DIR/dashboard.lock.d"
LOG="$STATE_DIR/dashboard-server.log"
PIDFILE="$STATE_DIR/dashboard.pid"

result() { printf 'COCKPIT_DASH_RESULT %s %s\n' "$1" "${2:-0}"; }
note()   { printf '[cockpit-dashboard] %s\n' "$*" >&2; }

# 포트 = 뷰어 config.json 단일 출처(뷰어는 port env 미존중 — 실측). 파싱 실패=기본 18080.
_port() {
  local p=""
  [ -f "$DASH_HOME/config.json" ] && p=$(python3 -c \
    'import json,sys;print(int(json.load(open(sys.argv[1])).get("port",18080)))' \
    "$DASH_HOME/config.json" 2>/dev/null || true)
  case "$p" in ''|*[!0-9]*) p=18080 ;; esac
  { [ "$p" -ge 1 ] && [ "$p" -le 65535 ]; } || p=18080
  printf '%s' "$p"
}

# 포트 LISTEN 여부 — python3 socket(외부도구 무의존·doctor 와 동일 방식). rc0=열림.
_listening() {
  python3 -c 'import socket,sys
s=socket.socket(); s.settimeout(0.3)
sys.exit(0 if s.connect_ex(("127.0.0.1",int(sys.argv[1])))==0 else 1)' "$1" 2>/dev/null
}

# /proc/PID/cmdline 에 active_server.py 가 있는지(우리 서버 확인·blind kill 금지).
_is_server() {
  [ -r "/proc/$1/cmdline" ] || return 1
  tr '\0' ' ' < "/proc/$1/cmdline" 2>/dev/null | grep -qF 'active_server.py'
}
# /proc/PID/stat 22번째 필드(starttime) — comm 괄호 안 공백 안전 파싱(') ' 뒤 20번째).
_starttime() { sed -e 's/^[^)]*) //' "/proc/$1/stat" 2>/dev/null | awk '{print $20}'; }

# pidfile 이 가리키는 유효한(살아있고 우리 서버인) PID 를 출력 — 아니면 빈 문자열.
_pidfile_pid() {
  local pid
  [ -f "$PIDFILE" ] || return 0
  pid=$(cat "$PIDFILE" 2>/dev/null)
  case "$pid" in ''|*[!0-9]*) return 0 ;; esac
  [ -d "/proc/$pid" ] && _is_server "$pid" && printf '%s' "$pid"
}

# orphan(pidfile 없음/stale) 시 포트 보유 PID 탐색 — ss→lsof→fuser 있으면. active_server.py 만.
_orphan_server_pids() {
  local port="$1" pids="" p
  if command -v ss >/dev/null 2>&1; then
    pids=$(ss -tlnpH "sport = :$port" 2>/dev/null | grep -oE 'pid=[0-9]+' | cut -d= -f2 | sort -u || true)
  fi
  if [ -z "$pids" ] && command -v lsof >/dev/null 2>&1; then
    pids=$(lsof -nP -tiTCP:"$port" -sTCP:LISTEN 2>/dev/null || true)
  fi
  if [ -z "$pids" ] && command -v fuser >/dev/null 2>&1; then
    pids=$(fuser "$port/tcp" 2>/dev/null | tr -s ' ' '\n' | grep -E '^[0-9]+$' || true)
  fi
  for p in $pids; do _is_server "$p" && printf '%s\n' "$p"; done
}

# 우리 서버가 살아있나(pidfile 우선·orphan 폴백). rc0=예.
_server_alive() { [ -n "$(_pidfile_pid)" ] || [ -n "$(_orphan_server_pids "$1")" ]; }

cmd_start() {
  if [ ! -f "$SERVER" ]; then
    note "뷰어 미설치 — Claude Code 안에서 /cockpit-setup 의 대시보드 스텝을 먼저 실행하세요."
    result NOT_INSTALLED 0; return 3
  fi
  local port; port=$(_port)
  if _listening "$port"; then
    if _server_alive "$port"; then
      note "이미 실행 중(포트 $port)."
      # 자가치유(#7): 살아있는 서버는 convert 를 다시 안 돌려 index 가 옛 상태로 굳는다(빈 상태로
      # 뜬 뒤 세션이 쌓인 경우 — ALREADY 는 아래 convert 블록 이전에 반환하므로). stale 판정 없이
      # 항상 백그라운드 재변환 1회: convert 는 jsonl size 대조로 변경분만 재생성(저비용)·setsid -f
      # 로 orphan 해 호출측(.cmd for /f) hang 방지·ALREADY 응답 지연 없음(동기 변환 안 함).
      ( cd "$DASH_HOME" && setsid -f timeout 300 python3 convert_session.py >>"$LOG" 2>&1 ) 2>/dev/null
      chmod 600 "$LOG" 2>/dev/null || true
      result ALREADY "$port"; return 0
    fi
    note "포트 $port 를 무관 프로세스가 사용 중 — 대시보드를 띄울 수 없습니다."
    result ERROR "$port"; return 4
  fi
  # 변환(best-effort): 첫 실행이면 동기 1회로 열자마자 목록 표시 시도, 이후엔 백그라운드 갱신(즉시 열림 우선).
  # 세션이 없으면 convert 는 index.html 을 안 만든다("No sessions to convert"·exit0·실측) — 정상 상태이며
  # 기동을 막지 않는다(서버는 index 없이도 LISTEN·실측). 세션이 생기면 /refresh·다음 start 가 채운다.
  if [ ! -f "$DASH_HOME/index.html" ]; then
    note "세션 목록 변환 시도 중(잠시 걸릴 수 있음)..."
    ( cd "$DASH_HOME" && timeout 300 python3 convert_session.py ) >>"$LOG" 2>&1 || true
    chmod 600 "$LOG" 2>/dev/null || true
  else
    # setsid -f: 백그라운드 convert 를 init 로 orphan(호출 셸이 do_wait 로 안 붙잡게 — 아래 데몬과 동일 이유).
    ( cd "$DASH_HOME" && setsid -f timeout 300 python3 convert_session.py >>"$LOG" 2>&1 ) 2>/dev/null
  fi
  # setsid -f + exec: 내부 bash 가 자신의 PID($$)를 pidfile 에 쓰고 exec 로 python 이 됨 → pidfile=python
  # 실제 PID(세션 분리로 창/호출 셸 종료 후에도 서버 유지). ss/lsof 무의존 소유권 기록.
  # ★ -f(강제 fork, init 로 orphan) 필수: 평범한 setsid 는 데몬이 호출 bash 의 백그라운드 자식이라
  #   bash 가 do_wait 로 데몬 종료를 기다리며 명령치환/.cmd for /f 파이프를 영구 보유 → 호출측 hang
  #   (실기 확정: setsid→hang, setsid -f→3초 반환). -f 로 데몬을 init 자식으로 만들어 bash 가 즉시 종료.
  ( cd "$DASH_HOME" && setsid -f bash -c 'echo $$ > "$1"; exec python3 active_server.py >> "$2" 2>&1' \
      cockpit-dash "$PIDFILE" "$LOG" </dev/null >/dev/null 2>&1 ) 2>/dev/null
  chmod 600 "$LOG" 2>/dev/null || true
  local i=0
  while [ "$i" -lt 30 ]; do _listening "$port" && break; sleep 0.5; i=$((i+1)); done
  chmod 600 "$PIDFILE" 2>/dev/null || true
  if _listening "$port" && _server_alive "$port"; then
    note "기동 완료(포트 $port). 창을 닫으면 꺼집니다."; result STARTED "$port"; return 0
  fi
  note "기동 실패 — $LOG 확인."; result ERROR "$port"; return 4
}

# TERM → (미종료+starttime 동일 시) KILL 승격. PID 재사용 오격 방지(Codex 4d).
_kill_verified() {
  local p="$1" st i
  st=$(_starttime "$p")
  kill -TERM "$p" 2>/dev/null || true
  i=0; while [ "$i" -lt 10 ] && [ -d "/proc/$p" ]; do sleep 0.5; i=$((i+1)); done
  if [ -d "/proc/$p" ] && [ -n "$st" ] && [ "$(_starttime "$p")" = "$st" ]; then
    note "PID $p TERM 미종료 — KILL 승격."; kill -KILL "$p" 2>/dev/null || true; sleep 1
  fi
}

cmd_stop() {
  local port pid pids p; port=$(_port)
  pid=$(_pidfile_pid)
  if [ -n "$pid" ]; then
    _kill_verified "$pid"
  else
    pids=$(_orphan_server_pids "$port")
    if [ -z "$pids" ]; then
      rm -f "$PIDFILE" 2>/dev/null || true
      _listening "$port" && note "포트 $port LISTEN 중이나 대시보드 PID 식별 불가(우리 프로세스 아님/도구 부재) — 수동 확인."
      result STOPPED "$port"; return 0
    fi
    for p in $pids; do _kill_verified "$p"; done
  fi
  rm -f "$PIDFILE" 2>/dev/null || true
  if _listening "$port" && _server_alive "$port"; then
    note "종료 실패 — 포트 $port 가 여전히 LISTEN."; result ERROR "$port"; return 4
  fi
  note "종료 완료(포트 $port)."; result STOPPED "$port"; return 0
}

cmd_status() {
  local port; port=$(_port)
  if _listening "$port" && _server_alive "$port"; then
    result RUNNING "$port"; return 0
  fi
  result STOPPED "$port"; return 1
}

# mkdir 원자적 락(fd 없음 — flock fd 상속 hang 회피). 탈취는 **소유자 PID 생존 여부**로 판정
# (시간 기준 아님 — start 의 락내 동기 convert 가 세션 많으면 10초+ 걸려 살아있는 작업을 오탈취하는
# 문제, Codex 4d). 소유자가 죽었으면 즉시 탈취, 살아있으면 최대 30초 대기(안전 상한).
_acquire_lock() {
  local i=0 owner
  while ! mkdir "$LOCKDIR" 2>/dev/null; do
    owner=$(cat "$LOCKDIR/pid" 2>/dev/null || true)
    if [ -n "$owner" ] && ! kill -0 "$owner" 2>/dev/null; then
      rmdir "$LOCKDIR" 2>/dev/null && continue   # 소유자 사망 = stale → 탈취
    fi
    i=$((i+1)); [ "$i" -ge 60 ] && return 1       # 살아있는 소유자를 60×0.5=30초 기다린 뒤 포기
    sleep 0.5
  done
  echo $$ > "$LOCKDIR/pid" 2>/dev/null || true    # 소유권 기록(다음 경쟁자의 생존 판정용)
  return 0
}
_release_lock() { rm -f "$LOCKDIR/pid" 2>/dev/null; rmdir "$LOCKDIR" 2>/dev/null || true; }

case "${1:-}" in
  start|stop)
    # 이중 더블클릭의 동시 기동/종료 레이스 차단. 데몬은 락 디렉터리를 상속하지 않으므로(fd 아님)
    # 호출측 명령치환·.cmd for /f 가 hang 하지 않는다.
    _acquire_lock || { note "다른 기동/종료 작업이 진행 중 — 잠시 후 다시 시도."; result ERROR 0; exit 6; }
    trap '_release_lock' EXIT
    "cmd_$1"; exit $? ;;
  status) cmd_status; exit $? ;;
  *) note "usage: cockpit-dashboard {start|stop|status}"; result ERROR 0; exit 2 ;;
esac
DASHBOARD
chmod 0755 /usr/local/bin/cockpit-dashboard

# ── 5.7) cockpit-onboard 브리지(설치기 온보딩 → 플러그인 도구) — 무조건 설치 ──
# Windows 설치기(v0.1.8 온보딩 폼)가 WSL 안 플러그인 도구를 부를 **결정론적 절대경로**.
# 플러그인 캐시 경로는 버전 의존(cache/cc-companion/cockpit/<VER>/)이라 설치기가 직접
# glob 하면 인용·stale 캐시 위험 — 여기서 해석·검증 후 exec 한다(설계 §5.2·Codex 4f 누락4).
# stdin 은 그대로 통과(set-extraction-key 의 키 stdin 주입 경로·C2). root 승격 없음(호출 사용자
# 그대로 = wsl 기본 사용자). 존재만으로 어떤 외부송신·포트도 없다(egress OFF 불변식 무영향).
log "5.7) cockpit-onboard 브리지 스크립트"
cat > /usr/local/bin/cockpit-onboard <<'ONBOARD'
#!/usr/bin/env bash
# cockpit-onboard — 설치기(Install-Cockpit.ps1) ↔ 플러그인 브리지.
#   cockpit-onboard setup <args...>    → python3 <plugin>/skills/setup-wizard/setup.py <args...>
#   cockpit-onboard install-dashboard  → bash <plugin>/dashboard/install-viewer.sh
# 플러그인 해석: ①installed_plugins.json 의 installPath ②plugin.json name==cockpit 검증
# ③대상 스크립트 실재 확인 — 전부 통과해야 exec. 폴백 glob 은 최신 버전(sort -V) 1개만.
# 키 원문을 다루지 않는다(있다면 stdin 통과분뿐) — echo/트레이스 금지, set -x 금지.
set -u
IP_JSON="$HOME/.claude/plugins/installed_plugins.json"
CACHE_GLOB="$HOME/.claude/plugins/cache/cc-companion/cockpit"

_die(){ echo "[cockpit-onboard] $1" >&2; exit "${2:-3}"; }

_resolve_plugin(){
  local p=""
  if [ -f "$IP_JSON" ]; then
    p="$(python3 - "$IP_JSON" 2>/dev/null <<'PY'
import json, sys
try:
    entries = json.load(open(sys.argv[1]))["plugins"]["cockpit@cc-companion"]
    print(entries[0].get("installPath", ""))
except Exception:
    pass
PY
)"
  fi
  # 폴백: 캐시 트리에서 최신 버전 1개(stale/깨진 installPath 대비 — 검증은 아래 공통)
  if [ -z "$p" ] || [ ! -d "$p" ]; then
    p="$(ls -d "$CACHE_GLOB"/*/ 2>/dev/null | sort -V | tail -1)"
    p="${p%/}"
  fi
  [ -n "$p" ] && [ -d "$p" ] || _die "cockpit 플러그인을 찾지 못했습니다(사전설치 이미지가 아니거나 손상) — 첫 실행 /cockpit-setup 을 이용하세요."
  # 정체성 검증: plugin.json name == cockpit (엉뚱한 트리 exec 방지)
  python3 - "$p/.claude-plugin/plugin.json" 2>/dev/null <<'PY' || _die "플러그인 정체성 검증 실패($p) — 첫 실행 /cockpit-setup 을 이용하세요."
import json, sys
assert json.load(open(sys.argv[1]))["name"] == "cockpit"
PY
  printf '%s\n' "$p"
}

case "${1:-}" in
  setup)
    shift
    PLUG="$(_resolve_plugin)" || exit 3
    TOOL="$PLUG/skills/setup-wizard/setup.py"
    [ -f "$TOOL" ] || _die "setup.py 가 없습니다: $TOOL"
    exec python3 "$TOOL" "$@"
    ;;
  install-dashboard)
    PLUG="$(_resolve_plugin)" || exit 3
    TOOL="$PLUG/dashboard/install-viewer.sh"
    [ -f "$TOOL" ] || _die "install-viewer.sh 가 없습니다: $TOOL"
    exec bash "$TOOL"
    ;;
  backup)
    # 기억·상태 백업/복원(#9 Uninstall 자동백업·#3 복원). 인자는 backup.py 로 그대로 전달
    #   (없음=백업 생성 · --restore --apply --dir ...=복원). CC_BACKUP_DIR 등 env 는 호출자가 지정.
    shift
    PLUG="$(_resolve_plugin)" || exit 3
    TOOL="$PLUG/hooks/memory/backup.py"
    [ -f "$TOOL" ] || _die "backup.py 가 없습니다: $TOOL"
    exec python3 "$TOOL" "$@"
    ;;
  *)
    echo "usage: cockpit-onboard {setup <args...>|install-dashboard|backup <args...>}" >&2
    exit 2
    ;;
esac
ONBOARD
chmod 0755 /usr/local/bin/cockpit-onboard

# ── 6) 첫 실행 안내문 ──────────────────────────────────────────────
log "6) 첫 실행 안내(MOTD) 작성"
# 플러그인 안내 = 베이크 여부에 따라 분기(4.5 판정). 베이크됐으면 2단계 안내를 쓰지 않는다(혼동 방지).
if [ "$_plugins_baked" = "1" ]; then
  PLUGIN_STEPS="플러그인(cockpit@cc-companion v$_baked_pver)은 **미리 설치돼 있습니다** — 설치 단계 없음:
  /cockpit-setup       # 거버넌스 동의 한 화면 + (원하면) 기억 외부송신 켜기
                       # (설치기 온보딩 폼에서 이미 답했다면 그 결정은 재질문 없이 넘어갑니다)"
else
  PLUGIN_STEPS="플러그인 사용(사전설치 미포함 빌드 — 최초 1회만):
  /plugin marketplace add $COCKPIT_MARKETPLACE
  /plugin install cockpit@cc-companion
  /cockpit-setup       # 거버넌스 동의 한 화면 + (원하면) 기억 외부송신 켜기"
fi
cat > "$USER_HOME/README-first-run.txt" <<EOF
cockpit (cc-companion) — WSL2 골든 이미지
=========================================
편의 설정(자율 진행·추론강도·모델·원격조종·폴더신뢰)은 미리 적용돼 있습니다.
이 중 **원격조종은 이미 켜진 상태**로 아웃바운드 HTTPS 통신을 씁니다(수신측=Anthropic,
신규 제3자 아님·수신 포트 없음 — 아래 '원격조종' 항목 참고).
당신이 추가로 **직접 켜는** 외부송신은 단 하나 — **기억 자동추출의 추가 API 송신**
(세션 본문을 Anthropic API 로 보내 기억을 뽑는 별도 송신, 첫 실행 한 화면)입니다.

첫 실행:
  1) claude 실행 → /login   # Claude Code 로그인(브라우저 OAuth) — 최초 1회.
     브라우저가 자동으로 열립니다(안 열리면 화면에 표시된 URL 을 직접 여세요).
  2) claude 재시작(exit 후 다시 claude) → claude.ai/code 원격조종 활성.
     (최초 실행은 미로그인 상태라 원격 연결이 조용히 꺼진 채 재시도하지 않습니다 —
      로그인 후 한 번 재시작해야 켜집니다.)

$PLUGIN_STEPS

원격조종(claude.ai Code 탭에서 이 세션 잇기): 설정은 이미 켜져 있습니다(remoteControlAtStartup).
  단, 위 '첫 실행 2)'까지 마쳐야(로그인 후 재시작) 실제로 연결됩니다. claude.ai/code 에
  같은 계정으로 들어가면 세션 목록에 나타납니다. 수신 포트를 열지 않고 아웃바운드(나가는)
  통신만 씁니다 — VPN/포트 설정 불필요.

언제든 상태 점검: /cockpit-doctor   ·   거버넌스 경계: /opt/cockpit/GOVERNANCE.md

끄기/지우기:
  • 자동진행 즉시정지:  touch ~/.claude/CC_KILL_SWITCH
  • 원격조종 끄기:      claude /config 에서 "Enable Remote Control for all sessions" → false
  • 이 배포판 통째 삭제(Windows PowerShell):  wsl --unregister cc-cockpit
    (기존 Ubuntu 등 다른 배포판은 건드리지 않습니다.)
EOF
chown -- "$COCKPIT_USER:$COCKPIT_USER" "$USER_HOME/README-first-run.txt"

# ── 6.5) 사용자 사전설정(v0.1.1: 동료는 로그인만 — 동의 한 화면 제외) ─────────
# 동윤님 맥미니 행동키를 이미지에 복제: 원터치 런처·자동업뎃끄기·settings(bypass·effort·
# model·remote-control)·trust·CLAUDE.md(1차 방어)·메모리 템플릿. **egress 동의 마커는
# 굽지 않는다**(첫 실행 게이트). 각 파일은 "없을 때만 생성"으로 기존 데이터 보존.
if [ "$COCKPIT_PRECONFIGURE" = "1" ]; then
  log "6.5) 사용자 사전설정(런처·settings·trust·CLAUDE.md·메모리)"
  CLAUDE_DIR="$USER_HOME/.claude"
  install -d -m 0755 "$CLAUDE_DIR"

  # bypass 는 CLAUDE.md(멈춰 질문 1차 방어)와 **반드시 동반**. 템플릿이 없으면(예: staged 경로에서
  # 플러그인 미스테이징) bypass 를 켜지 않는다 — bypass ON 인데 1차 방어 없는 상태로 출고 금지(Codex 발견1).
  _tmpl="$STAGE_DIR/templates/CLAUDE.md.template"
  _bake_bypass=1
  if [ ! -f "$_tmpl" ]; then
    _bake_bypass=0
    warn "CLAUDE.md 템플릿 부재($_tmpl) — 1차 방어 없이 bypass 미적용(model/effort/remote 만 사전설정). 첫 실행 /cockpit-setup 으로 CLAUDE.md+bypass 함께 적용."
  fi

  # (a) 원터치 런처 — Windows .cmd/.lnk 가 이 스크립트를 호출(검증된 산출물).
  install -d -m 0755 "$USER_HOME/.cockpit"
  if [ ! -e "$USER_HOME/.cockpit/launch.sh" ]; then
    cat > "$USER_HOME/.cockpit/launch.sh" <<'LAUNCH'
#!/usr/bin/env bash
# cockpit 원터치 런처 — Windows 바로가기가 호출(wsl.exe -d cc-cockpit ...).
export LANG=C.UTF-8
export DISABLE_AUTOUPDATER=1   # 자동업뎃 빨간경고 제거(수동 `claude update` 는 막지 않음)
cd "$HOME" 2>/dev/null || cd /
claude
ec=$?
if [ "$ec" -ne 0 ]; then
  echo; echo "[cockpit] claude 종료 코드 $ec"
  read -r -p "닫으려면 Enter..."
fi
# 실패 UX(위 read)는 launch.sh 가 책임지고 **항상 0 으로 종료** → Windows .cmd 의 errorlevel→pause 는
# "wsl/distro 진입 자체 실패"에만 발화(이중 pause 방지·레이어 고정). read 가 EOF/Ctrl-C 로 비0 반환해도 무관.
exit 0
LAUNCH
    chmod 0755 "$USER_HOME/.cockpit/launch.sh"
  fi

  # (b) 자동업뎃 끄기 — 직접 `claude` 입력 경로(런처 미경유)도 커버. 로그인 셸 전역.
  if [ ! -e /etc/profile.d/cockpit.sh ]; then
    printf '%s\n' '# cockpit: 자동업데이트 비활성(빨간 경고 제거). DISABLE_UPDATES 와 달리 수동 update 는 허용.' \
                  'export DISABLE_AUTOUPDATER=1' > /etc/profile.d/cockpit.sh
    chmod 0644 /etc/profile.d/cockpit.sh
  fi

  # (c) settings.json — effort·model·remoteControlAtStartup·agentPushNotifEnabled·respondToBashCommands
  #     는 항상, bypass·skipDangerous 는 _bake_bypass=1(=CLAUDE.md 동반 가능) 일 때만. model 핀은 COCKPIT_MODEL_PIN="" 면 생략
  #     (계정 기본). 개인 permissions.allow 는 미포함.
  if [ ! -e "$CLAUDE_DIR/settings.json" ]; then
    if command -v python3 >/dev/null 2>&1; then
      python3 - "$CLAUDE_DIR/settings.json" "$COCKPIT_MODEL_PIN" "$COCKPIT_EFFORT" "$_bake_bypass" <<'PYSET'
import json, sys
out, model, effort, bake_bypass = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4]
s = {
    "effortLevel": effort,
    "remoteControlAtStartup": True,              # claude.ai Code 탭 연결(아웃바운드 HTTPS·수신포트 없음)
    "agentPushNotifEnabled": True,               # Remote Control 연결 시 작업완료 푸시(인가된 본인 모바일만·신규 포트/egress 없음)
    "respondToBashCommands": False,              # ! bash 출력 자동응답 끔(토큰 절약·기본값 true 를 명시적으로 끔)
}
if bake_bypass == "1":
    s["permissions"] = {"defaultMode": "bypassPermissions"}
    s["skipDangerousModePermissionPrompt"] = True  # bypass 경고("Yes, I accept") 자동 수락
if model:
    s["model"] = model
with open(out, "w", encoding="utf-8") as f:
    json.dump(s, f, ensure_ascii=False, indent=2)
PYSET
      chmod 0644 "$CLAUDE_DIR/settings.json"
    else
      warn "python3 없음 — settings.json 사전설정 건너뜀(첫 실행 /cockpit-setup 으로 적용 가능)."
    fi
  fi

  # (d) trust — 첫 실행 "Is this a project you trust?" 자동 수락(~/.claude.json).
  #     포맷 검증함(실 ~/.claude.json projects[dir].hasTrustDialogAccepted). 최악=다이얼로그 1회.
  if [ ! -e "$USER_HOME/.claude.json" ] && command -v python3 >/dev/null 2>&1; then
    python3 - "$USER_HOME/.claude.json" "$USER_HOME" <<'PYTRUST'
import json, sys, os
out, home = sys.argv[1], sys.argv[2]
data = {"hasCompletedOnboarding": True, "projects": {home: {"hasTrustDialogAccepted": True}}}
with open(out, "w", encoding="utf-8") as f:
    json.dump(data, f, ensure_ascii=False, indent=2)
PYTRUST
    chmod 0644 "$USER_HOME/.claude.json"
  fi

  # (e) CLAUDE.md — 행동 규율(멈춰 질문·deny-list 1차 방어). bypass ON 의 전제라 필수 동반($_tmpl 위에서 판정).
  if [ ! -e "$CLAUDE_DIR/CLAUDE.md" ] && [ -f "$_tmpl" ]; then
    sed "s/{{PRIMARY_LANGUAGE}}/$COCKPIT_PRIMARY_LANGUAGE/g" "$_tmpl" > "$CLAUDE_DIR/CLAUDE.md"
    chmod 0644 "$CLAUDE_DIR/CLAUDE.md"
  fi

  # (f) 메모리 저장소 — 시작 템플릿(빈 인덱스+PROJECT_STATUS·비어있을 때만). cc_paths 기본 = ~/.claude/cc-memory.
  #     example_* 견본은 memory-template/examples/(비복사)에 있어 라이브로 새지 않는다(#4).
  _memsrc="$STAGE_DIR/memory-template"
  _memdst="$CLAUDE_DIR/cc-memory"
  if [ -d "$_memsrc" ] && { [ ! -d "$_memdst" ] || [ -z "$(ls -A "$_memdst" 2>/dev/null)" ]; }; then
    install -d -m 0755 "$_memdst"
    for _f in "$_memsrc"/*.md; do
      [ -f "$_f" ] || continue   # 정규 파일만(디렉터리·특수파일 제외 — setup.py isfile 가드와 등가)
      case "$(basename "$_f")" in example_*) continue ;; esac
      cp -a "$_f" "$_memdst/"
    done
  fi

  # (g) 런타임 상태 디렉터리(빈 채로) — setup_complete 마커는 **굽지 않음**(egress 첫 실행 동의).
  install -d -m 0755 "$CLAUDE_DIR/cc-companion"

  chown -R -- "$COCKPIT_USER:$COCKPIT_USER" "$CLAUDE_DIR" "$USER_HOME/.cockpit" \
              "$USER_HOME/.claude.json" 2>/dev/null || true
  log "   사전설정 완료(egress 마커 미포함·자체호스팅 대시보드 미시작)."
else
  log "6.5) 사전설정 건너뜀(COCKPIT_PRECONFIGURE=0 — 구 OFF-출고 동작)."
fi

# ── 6.6) 플러그인 활성화 키(베이크 시 필수 — cc-cockpit2 라이브 실측 발견 2026-07-02) ──
# 설치 기록(installed_plugins.json)+캐시만으론 로드 안 됨: 실제 "켜짐"은 settings.json 의
# enabledPlugins + extraKnownMarketplaces 가 결정(실 /plugin install 이 기록하는 키 — v0.1.0
# 실기 대조로 확정). 6.5 와 독립 실행(PRECONFIGURE=0 이어도 베이크면 필요) — 기존 settings 는
# 병합(다른 키 보존), 없으면 이 두 키만으로 생성.
if [ "$_plugins_baked" = "1" ]; then
  log "6.6) 플러그인 활성화 키 병합(enabledPlugins·extraKnownMarketplaces)"
  _sj="$USER_HOME/.claude/settings.json"
  install -d -m 0755 "$USER_HOME/.claude"
  python3 - "$_sj" "$COCKPIT_MARKETPLACE" <<'PYEN'
import json, os, sys
p, mkt_url = sys.argv[1], sys.argv[2]
s = {}
if os.path.exists(p):
    with open(p, encoding="utf-8") as f:
        s = json.load(f)
s.setdefault("enabledPlugins", {})["cockpit@cc-companion"] = True
s.setdefault("extraKnownMarketplaces", {})["cc-companion"] = {
    "source": {"source": "git", "url": mkt_url}}
with open(p, "w", encoding="utf-8") as f:
    json.dump(s, f, ensure_ascii=False, indent=2)
PYEN
  chmod 0644 "$_sj"
  chown -- "$COCKPIT_USER:$COCKPIT_USER" "$_sj" 2>/dev/null || true
fi

# ── 7) 빌드 버전 기록(provenance/SBOM 소스 + 이미지 내부 감사) ──────
# 재현성 보강: 무엇이 어떤 버전으로 들어갔는지 이미지 안에 남긴다. build-rootfs.sh 가
# 이를 꺼내 provenance.json 에 병합하고, gen-sbom.sh 가 폴백 SBOM 의 tool_versions 로 쓴다.
log "7) 빌드 버전 기록(build-versions.json)"
install -d -m 0755 /opt/cockpit
jstr() { printf '%s' "${1:-}" | tr -d '"\\' | tr -d '\n'; }   # JSON 값 위생(따옴표/백슬래시 제거)
aptv() { dpkg-query -W -f '${Version}' "$1" 2>/dev/null || echo ""; }
NODE_V="$(command -v node >/dev/null 2>&1 && node --version 2>/dev/null || echo "")"
NPM_V="$(command -v npm >/dev/null 2>&1 && npm --version 2>/dev/null || echo "")"
CLAUDE_V="$(command -v claude >/dev/null 2>&1 && claude --version 2>/dev/null | head -1 || echo "")"
OS_V="$( . /etc/os-release 2>/dev/null; printf '%s' "${PRETTY_NAME:-unknown}" )"
cat > /opt/cockpit/build-versions.json <<EOF
{
  "schema": "cc-companion/build-versions/1",
  "source_date_epoch": "$(jstr "${SOURCE_DATE_EPOCH:-unset}")",
  "os": "$(jstr "$OS_V")",
  "node": "$(jstr "$NODE_V")",
  "npm": "$(jstr "$NPM_V")",
  "claude": "$(jstr "$CLAUDE_V")",
  "claude_code_pin": "$(jstr "${CLAUDE_CODE_VERSION:-}")",
  "apt": {
    "git": "$(jstr "$(aptv git)")",
    "python3": "$(jstr "$(aptv python3)")",
    "curl": "$(jstr "$(aptv curl)")",
    "ca-certificates": "$(jstr "$(aptv ca-certificates)")",
    "nodejs": "$(jstr "$(aptv nodejs)")",
    "npm": "$(jstr "$(aptv npm)")"
  }
}
EOF
chmod 0644 /opt/cockpit/build-versions.json

log "프로비저닝 완료. 사전적용=bypass·effort·model·remote-control·trust(사용자 데이터 미파괴)."
if [ "$_plugins_baked" = "1" ]; then log "  플러그인 사전설치=베이크됨(cockpit@cc-companion v$_baked_pver·공개 commit 정체성)"; else log "  플러그인 사전설치=미베이크(첫 실행 2단계 경로)"; fi
log "  굽지 않음(불변): egress 동의 마커·자체호스팅 대시보드 자동시작·비밀/자격증명."
