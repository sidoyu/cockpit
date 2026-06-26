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
#     굽지 않는 것: ① egress 동의 마커(STATE_DIR/setup_complete) ② Codex 스위치(codex_enabled)
#     ③ 원격 대시보드(자체호스팅 뷰어) 자동시작 ④ 어떤 비밀/자격증명.
#     (claude.ai Code 탭 원격조종 = remoteControlAtStartup, 아웃바운드 HTTPS 전용·수신포트 없음.)
#   • 멱등: 다시 실행해도 안전(이미 있으면 건너뜀). 단 v0.1.1 부터 ~/.claude 사전설정은
#     "비어있을 때만 생성"으로 보존(기존 사용자 데이터 미파괴).
#
# 파라미터(환경변수, 모두 선택 — 기본은 제네릭):
#   COCKPIT_USER          이미지의 기본 비-root 사용자 (기본: cockpit)
#   COCKPIT_PLUGIN_SRC    스테이징할 플러그인 트리 경로 (기본: 빌더가 /tmp/cockpit-plugin 에 둠)
#   COCKPIT_INSTALL_CC    1이면 Claude Code CLI 도 설치 시도 (기본: 1; 네트워크 없으면 경고 후 계속)
#   COCKPIT_MARKETPLACE   /plugin marketplace add 에 쓸 소스 (기본: example.invalid 플레이스홀더)
set -euo pipefail

log()  { printf '[provision] %s\n' "$*"; }
warn() { printf '[provision][warn] %s\n' "$*" >&2; }
die()  { printf '[provision][FATAL] %s\n' "$*" >&2; exit 1; }

[ "$(id -u)" -eq 0 ] || die "root 로 실행해야 합니다(이미지 빌드 컨텍스트)."

COCKPIT_USER="${COCKPIT_USER:-cockpit}"
COCKPIT_PLUGIN_SRC="${COCKPIT_PLUGIN_SRC:-/tmp/cockpit-plugin}"
COCKPIT_INSTALL_CC="${COCKPIT_INSTALL_CC:-1}"
COCKPIT_MARKETPLACE="${COCKPIT_MARKETPLACE:-https://example.invalid/cc-companion}"
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

# ── 3) /etc/wsl.conf (기본 사용자·systemd·상호운용) ────────────────
log "3) /etc/wsl.conf 적용"
if [ -f "$(dirname "$0")/wsl.conf" ]; then
  # 빌더가 같은 디렉터리에 wsl.conf 를 둔 경우 그대로, 사용자명만 치환.
  sed "s/__COCKPIT_USER__/$COCKPIT_USER/g" "$(dirname "$0")/wsl.conf" > /etc/wsl.conf
else
  cat > /etc/wsl.conf <<EOF
[user]
default=$COCKPIT_USER
[boot]
systemd=true
[interop]
enabled=true
appendWindowsPath=false
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

# ── 6) 첫 실행 안내문 ──────────────────────────────────────────────
log "6) 첫 실행 안내(MOTD) 작성"
cat > "$USER_HOME/README-first-run.txt" <<EOF
cockpit (cc-companion) — WSL2 골든 이미지
=========================================
편의 설정(자율 진행·추론강도·모델·원격조종·폴더신뢰)은 미리 적용돼 있습니다.
당신이 직접 켜야 하는 것은 단 하나 — **기억을 외부로 올리는 동의**(첫 실행 한 화면)입니다.

첫 실행:
  1) claude            # Claude Code 로그인(브라우저 OAuth) — 최초 1회. 이후 바로 사용.

플러그인 사용(아직 사전설치 전 단계라 최초 1회만):
  /plugin marketplace add $COCKPIT_MARKETPLACE
  /plugin install cockpit@cc-companion
  /cockpit-setup       # 거버넌스 동의 한 화면 + (원하면) 기억 외부송신 켜기

원격조종(claude.ai Code 탭에서 이 세션 잇기): 이미 켜져 있습니다(remoteControlAtStartup).
  claude.ai/code 에 같은 계정으로 들어가면 세션 목록에 나타납니다. 수신 포트를 열지
  않고 아웃바운드(나가는) 통신만 씁니다 — VPN/포트 설정 불필요.

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
LAUNCH
    chmod 0755 "$USER_HOME/.cockpit/launch.sh"
  fi

  # (b) 자동업뎃 끄기 — 직접 `claude` 입력 경로(런처 미경유)도 커버. 로그인 셸 전역.
  if [ ! -e /etc/profile.d/cockpit.sh ]; then
    printf '%s\n' '# cockpit: 자동업데이트 비활성(빨간 경고 제거). DISABLE_UPDATES 와 달리 수동 update 는 허용.' \
                  'export DISABLE_AUTOUPDATER=1' > /etc/profile.d/cockpit.sh
    chmod 0644 /etc/profile.d/cockpit.sh
  fi

  # (c) settings.json — effort·model·remoteControlAtStartup 는 항상, bypass·skipDangerous 는
  #     _bake_bypass=1(=CLAUDE.md 동반 가능) 일 때만. model 핀은 COCKPIT_MODEL_PIN="" 면 생략
  #     (계정 기본). 개인 permissions.allow 는 미포함.
  if [ ! -e "$CLAUDE_DIR/settings.json" ]; then
    if command -v python3 >/dev/null 2>&1; then
      python3 - "$CLAUDE_DIR/settings.json" "$COCKPIT_MODEL_PIN" "$COCKPIT_EFFORT" "$_bake_bypass" <<'PYSET'
import json, sys
out, model, effort, bake_bypass = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4]
s = {
    "effortLevel": effort,
    "remoteControlAtStartup": True,              # claude.ai Code 탭 연결(아웃바운드 HTTPS·수신포트 없음)
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

  # (f) 메모리 저장소 — 예시 템플릿(비어있을 때만). cc_paths 기본 = ~/.claude/cc-memory.
  _memsrc="$STAGE_DIR/memory-template"
  _memdst="$CLAUDE_DIR/cc-memory"
  if [ -d "$_memsrc" ] && { [ ! -d "$_memdst" ] || [ -z "$(ls -A "$_memdst" 2>/dev/null)" ]; }; then
    install -d -m 0755 "$_memdst"
    for _f in "$_memsrc"/*.md; do [ -e "$_f" ] && cp -a "$_f" "$_memdst/"; done
  fi

  # (g) 런타임 상태 디렉터리(빈 채로) — setup_complete 마커는 **굽지 않음**(egress 첫 실행 동의).
  install -d -m 0755 "$CLAUDE_DIR/cc-companion"

  chown -R -- "$COCKPIT_USER:$COCKPIT_USER" "$CLAUDE_DIR" "$USER_HOME/.cockpit" \
              "$USER_HOME/.claude.json" 2>/dev/null || true
  log "   사전설정 완료(egress 마커 미포함·codex 스위치 미포함·자체호스팅 대시보드 미시작)."
else
  log "6.5) 사전설정 건너뜀(COCKPIT_PRECONFIGURE=0 — 구 OFF-출고 동작)."
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
log "  굽지 않음(불변): egress 동의 마커·Codex 스위치·자체호스팅 대시보드 자동시작·비밀/자격증명."
