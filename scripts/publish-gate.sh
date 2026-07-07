#!/usr/bin/env bash
# publish-gate.sh — 발행 차단 게이트(단계5). 발행 직전 반드시 통과해야 한다.
#
# 무엇을 막나: 미발행 상태(플레이스홀더·핀 미고정·docs 식별자 노출)로 실수 발행되는 것.
# 어디서 도나: 로컬(배포자 수동) + CI(golden-build 워크플로의 gate 잡). git 필요.
#
# 종료코드: 0=발행 가능 / 1=차단(아래 [BLOCK] 항목 해소 필요) / 2=실행 오류(git 없음 등)
#
# 설계: '무차별 example.invalid 금지'가 아니라 **표적 의미 검사**다.
#   • Install-Cockpit.ps1 의 $PLACEHOLDER_HOSTS=@('example.invalid') 는 *거부 목록*이라 발행 후에도 남는다.
#   • provision.sh/wsl.conf 의 __COCKPIT_USER__ 는 빌드 중 sed 로 치환되는 *런타임 토큰*이지 발행 placeholder 가 아니다.
#   • manifest.example.json 은 *템플릿*(발행 시 manifest.json 으로 생성). README 류는 *치환 지침 문서*.
#   따라서 사용자가 직접 실행/열람하는 산출물의 *기능적* 플레이스홀더만 차단하고, 문서·템플릿은 경고만 한다.
set -u
cd "$(dirname "$0")/.." || exit 2
ROOT="$(pwd)"
block=0
warns=0

BLOCK() { echo "  [BLOCK] $*"; block=1; }
WARN()  { echo "  [warn]  $*"; warns=$((warns+1)); }
OK()    { echo "  [ok]    $*"; }
sec()   { echo ""; echo "── $* ──"; }

# STRICT 모드(PUBLISH_GATE_STRICT=1): 빌드 산출물(dist) 부재로 '검증 생략'되던 WARN 을 BLOCK 으로 승격.
# CI(golden-build)는 산출물을 내려받은 뒤 게이트를 돌리므로 STRICT 로 실행 — 산출물 핸드오프가 조용히
# 깨져도(다운로드 실패 등) 차단된다. 로컬 수동 실행은 기본 비-STRICT(편의). (Codex 4f 발견2 반영.)
STRICT="${PUBLISH_GATE_STRICT:-0}"
SOFT()  { if [ "$STRICT" = "1" ]; then BLOCK "$* [STRICT]"; else WARN "$* (STRICT 모드면 BLOCK)"; fi; }

git rev-parse --git-dir >/dev/null 2>&1 || { echo "[publish-gate][FATAL] git 저장소가 아닙니다."; exit 2; }

# jq 전제(선두 가드): manifest(서명 플래그·핀·URL·해시)를 파싱해 발행 안전을 판정하므로
# jq 없이는 §4 가 false-BLOCK 되고 §1/§1b/§5b 는 검증을 조용히 건너뛴다(반쪽 게이트).
# 둘 다 위험하므로, git 부재와 같은 실행-오류(exit 2)로 조기 차단해 '완전한 게이트'만 판정하게 한다.
command -v jq >/dev/null 2>&1 || { echo "[publish-gate][FATAL] jq 가 필요합니다(manifest 파싱). 설치 후 재실행하세요(mac: brew install jq · ubuntu: apt-get install -y jq)."; exit 2; }

echo "[publish-gate] 발행 차단 게이트 시작 (repo: $ROOT)"

# ── 1) 부트스트랩 핀: $PinnedSha256 실제 64-hex + $PinnedImageUrl 비-플레이스홀더 ──
sec "1) PowerShell 부트스트랩 핀 고정"
PS1="windows/bootstrap/Install-Cockpit.ps1"
if [ -f "$PS1" ]; then
  PINHEX="$(grep -Eo "\\\$PinnedSha256[[:space:]]*=[[:space:]]*'[0-9A-Fa-f]{64}'" "$PS1" | grep -Eo '[0-9A-Fa-f]{64}' | head -1)"
  if [ -n "$PINHEX" ]; then
    OK "\$PinnedSha256 = 실제 64-hex"
    # 핀이 *실제 산출물 해시*와 일치하는지(아티팩트가 있으면). 형태만 맞고 값이 틀린 핀 차단.
    ART_SHA=""
    [ -f dist/windows/cockpit-wsl.tar.gz.sha256 ] && ART_SHA="$(awk '{print $1}' dist/windows/cockpit-wsl.tar.gz.sha256)"
    [ -z "$ART_SHA" ] && [ -f dist/windows/provenance.json ] && command -v jq >/dev/null 2>&1 && ART_SHA="$(jq -r '.sha256_tar_gz // empty' dist/windows/provenance.json)"
    if [ -n "$ART_SHA" ]; then
      if [ "$(printf '%s' "$PINHEX" | tr 'A-Z' 'a-z')" = "$(printf '%s' "$ART_SHA" | tr 'A-Z' 'a-z')" ]; then
        OK "핀 == 산출 tar.gz 해시(일치)"
      else
        BLOCK "핀이 산출 tar.gz 해시와 불일치 — 사용자 다운로드 후 체크섬 실패. pin=$PINHEX art=$ART_SHA"
      fi
    else
      SOFT "dist/windows 산출물 없어 핀-해시 일치 미검증(빌드 아티팩트 다운로드 후 재실행 권장)."
    fi
  else
    BLOCK "\$PinnedSha256 이 64-hex 가 아닙니다(아직 __IMAGE_SHA256__ 플레이스홀더?). build-rootfs 산출 SHA-256 으로 치환하세요."
  fi
  if grep -Eq "\\\$PinnedImageUrl[[:space:]]*=[[:space:]]*'https://example\.invalid" "$PS1"; then
    BLOCK "\$PinnedImageUrl 이 example.invalid 입니다. 실제 게시 URL(https) 로 치환하세요."
  else
    OK "\$PinnedImageUrl = 비-플레이스홀더"
  fi
else
  BLOCK "$PS1 가 없습니다."
fi

# ── 1b) Cockpit-Install.cmd 핀 체인(.cmd ↔ repo ps1 실계산 ↔ manifest bootstrap) ──
# '해시 수기전사 금지' 규율의 기계화: .cmd 에 박힌 PS1_SHA256 을 사람이 옮겨 적지 않고
# 여기서 repo 의 Install-Cockpit.ps1 실계산 해시·manifest 기록과 삼각 대조한다.
# 전제: release 자산 Install-Cockpit.ps1 = repo 파일 그대로 업로드(기존 관행·v0.1.2 실적).
sec "1b) Cockpit-Install.cmd 핀 체인"
CMDF="windows/bootstrap/Cockpit-Install.cmd"
_sha256() { if command -v sha256sum >/dev/null 2>&1; then sha256sum "$1" | awk '{print $1}'; else shasum -a 256 "$1" | awk '{print $1}'; fi; }
if [ -f "$CMDF" ]; then
  CMD_PIN="$(grep -Eo 'PS1_SHA256=[0-9A-Fa-f]{64}"' "$CMDF" | head -1 | tr -d '"' | cut -d= -f2)"
  if [ -n "$CMD_PIN" ]; then
    OK "Cockpit-Install.cmd PS1_SHA256 = 실제 64-hex"
    if [ -f "$PS1" ]; then
      PS1_ACTUAL="$(_sha256 "$PS1" | tr 'A-Z' 'a-z')"
      if [ "$(printf '%s' "$CMD_PIN" | tr 'A-Z' 'a-z')" = "$PS1_ACTUAL" ]; then
        OK ".cmd 핀 == repo Install-Cockpit.ps1 실계산 해시(일치)"
      else
        BLOCK ".cmd 핀이 repo Install-Cockpit.ps1 해시와 불일치 — 사용자 다운로드 후 즉시 검증 실패. pin=$CMD_PIN actual=$PS1_ACTUAL"
      fi
      MB_SHA="$(jq -r '.artifacts.bootstrap.sha256 // empty' windows/bootstrap/manifest.json 2>/dev/null || echo "")"
      if [ -n "$MB_SHA" ]; then
        if [ "$(printf '%s' "$MB_SHA" | tr 'A-Z' 'a-z')" = "$PS1_ACTUAL" ]; then
          OK "manifest bootstrap.sha256 == repo ps1 해시(핀 체인 일치)"
        else
          BLOCK "manifest bootstrap.sha256 이 repo ps1 해시와 불일치 — 핀 체인 갈라짐(manifest 재생성 필요). manifest=$MB_SHA actual=$PS1_ACTUAL"
        fi
      else
        WARN "manifest bootstrap.sha256 미기재/jq 없음 — .cmd↔manifest 체인 미검증."
      fi
    fi
    CMD_URL="$(grep -Eo 'PS1_URL=[^"]*' "$CMDF" | head -1 | tr -d '\r' | cut -d= -f2-)"
    case "$CMD_URL" in
      *example.invalid*) BLOCK "Cockpit-Install.cmd PS1_URL 이 example.invalid — 실제 release 자산 URL 로 치환." ;;
      https://*)
        OK "Cockpit-Install.cmd PS1_URL = https 비-플레이스홀더"
        MB_URL="$(jq -r '.artifacts.bootstrap.url // empty' windows/bootstrap/manifest.json 2>/dev/null || echo "")"
        if [ -n "$MB_URL" ] && [ "$CMD_URL" != "$MB_URL" ]; then
          BLOCK ".cmd PS1_URL 과 manifest bootstrap.url 불일치(태그 갈라짐). cmd=$CMD_URL manifest=$MB_URL"
        elif [ -n "$MB_URL" ]; then
          OK ".cmd PS1_URL == manifest bootstrap.url(태그 체인 일치)"
        fi ;;
      *) BLOCK "Cockpit-Install.cmd PS1_URL 이 https 가 아님: $CMD_URL" ;;
    esac
  else
    BLOCK "Cockpit-Install.cmd PS1_SHA256 이 64-hex 가 아닙니다(아직 __PS1_SHA256__ 플레이스홀더?). repo ps1 해시로 치환하세요."
  fi
else
  BLOCK "$CMDF 없음 — v0.1.3 주 설치 UX(.cmd 더블클릭) 자산 누락. 원클릭 브리지를 포함해 발행하세요."
fi

# Cockpit-Repair.cmd 는 같은 Install-Cockpit.ps1 을 받아 재설치한다 → 핀(PS1_SHA256·PS1_URL)이
# Install.cmd 와 반드시 동일해야 한다. 릴리스 재핀 때 한 쪽만 갱신되는 사고를 여기서 잡는다.
REPAIRF="windows/bootstrap/Cockpit-Repair.cmd"
if [ -f "$REPAIRF" ]; then
  RP_PIN="$(grep -Eo 'PS1_SHA256=[0-9A-Fa-f]{64}"' "$REPAIRF" | head -1 | tr -d '"' | cut -d= -f2)"
  if [ -n "$RP_PIN" ] && [ -f "$PS1" ]; then
    PS1_ACTUAL="$(_sha256 "$PS1" | tr 'A-Z' 'a-z')"
    if [ "$(printf '%s' "$RP_PIN" | tr 'A-Z' 'a-z')" = "$PS1_ACTUAL" ]; then
      OK "Cockpit-Repair.cmd 핀 == repo Install-Cockpit.ps1 실계산 해시(일치)"
    else
      BLOCK "Cockpit-Repair.cmd 핀이 repo Install-Cockpit.ps1 해시와 불일치 — 재설치 시 즉시 검증 실패. Install.cmd 와 함께 재핀하세요. pin=$RP_PIN actual=$PS1_ACTUAL"
    fi
  elif [ -z "$RP_PIN" ]; then
    BLOCK "Cockpit-Repair.cmd PS1_SHA256 이 64-hex 가 아닙니다(아직 __PS1_SHA256__ 플레이스홀더?). repo ps1 해시로 치환하세요."
  fi
  RP_URL="$(grep -Eo 'PS1_URL=[^"]*' "$REPAIRF" | head -1 | tr -d '\r' | cut -d= -f2-)"
  case "$RP_URL" in
    *example.invalid*) BLOCK "Cockpit-Repair.cmd PS1_URL 이 example.invalid — 실제 release 자산 URL 로 치환." ;;
    https://*)
      OK "Cockpit-Repair.cmd PS1_URL = https 비-플레이스홀더"
      MB_URL="$(jq -r '.artifacts.bootstrap.url // empty' windows/bootstrap/manifest.json 2>/dev/null || echo "")"
      # manifest 부재 시(=MB_URL 비어있음) 대조 없이 '일치' 를 주장하지 않는다(Install §1b 와 동일 방어).
      if [ -n "$MB_URL" ] && [ "$RP_URL" != "$MB_URL" ]; then
        BLOCK "Cockpit-Repair.cmd PS1_URL 과 manifest bootstrap.url 불일치(태그 갈라짐·Install.cmd 와 다른 릴리스 가리킴). repair=$RP_URL manifest=$MB_URL"
      elif [ -n "$MB_URL" ]; then
        OK "Cockpit-Repair.cmd PS1_URL == manifest bootstrap.url(태그 체인 일치)"
      fi ;;
    *) BLOCK "Cockpit-Repair.cmd PS1_URL 이 https 가 아님: $RP_URL" ;;
  esac
fi   # $REPAIRF 존재 검사는 §1c 가 담당(광고된 릴리스 자산)

# ── 1c) 더블클릭 .cmd 자산 존재(Dashboard·Repair·Uninstall) ──
# 이 셋은 web 다운로드 표에 광고되는 릴리스 자산이다. Uninstall 은 placeholder 없음(설치된
# distro 만 조작·다운로드 없음)이라 핀 체인 대상이 아니고, Dashboard 핀 체인은 §1d, Repair 핀
# 체인은 §1b, SHA 표 대조는 §2b 가 담당. '존재'는 발행 조건으로 강제(광고했는데 누락=깨진 약속).
sec "1c) 더블클릭 .cmd 자산 존재(Dashboard·Repair·Uninstall)"
for _asset in Cockpit-Dashboard.cmd Cockpit-Repair.cmd Cockpit-Uninstall.cmd; do
  if [ -f "windows/bootstrap/$_asset" ]; then
    OK "$_asset 존재(더블클릭 UX 자산)"
  else
    BLOCK "windows/bootstrap/$_asset 없음 — web 다운로드 표에 광고된 릴리스 자산 누락. 발행 자산에 포함하세요."
  fi
done

# ── 1d) 대시보드 런처 핀 체인(ps1 §10b ↔ repo Cockpit-Dashboard.cmd ↔ manifest dashboard_cmd) ──
# Install-Cockpit.ps1 이 바탕화면 'Cockpit Dashboard' 아이콘용으로 릴리스 자산 Cockpit-Dashboard.cmd
# 를 받아 핀 해시로 검증한다 → ps1 핀·manifest 기록·repo 실계산 3자가 일치해야 한다(§1b 미러).
sec "1d) 대시보드 런처 핀 체인"
DASHF="windows/bootstrap/Cockpit-Dashboard.cmd"
if [ -f "$DASHF" ] && [ -f "$PS1" ]; then
  DASH_ACTUAL="$(_sha256 "$DASHF" | tr 'A-Z' 'a-z')"
  DP_PIN="$(grep -Eo "\\\$PinnedDashboardCmdSha256 *= *'[0-9A-Fa-f]{64}'" "$PS1" | head -1 | grep -Eo '[0-9A-Fa-f]{64}')"
  if [ -n "$DP_PIN" ]; then
    if [ "$(printf '%s' "$DP_PIN" | tr 'A-Z' 'a-z')" = "$DASH_ACTUAL" ]; then
      OK "ps1 \$PinnedDashboardCmdSha256 == repo Cockpit-Dashboard.cmd 실계산(일치)"
    else
      BLOCK "ps1 대시보드 런처 핀이 repo Cockpit-Dashboard.cmd 해시와 불일치 — 아이콘 설치가 체크섬에서 실패한다. Dashboard.cmd 변경 시 ps1 핀도 재핀. pin=$DP_PIN actual=$DASH_ACTUAL"
    fi
  else
    BLOCK "Install-Cockpit.ps1 에 \$PinnedDashboardCmdSha256(64-hex) 이 없음 — §10b 핀 누락/플레이스홀더. repo Dashboard.cmd 해시로 치환하세요."
  fi
  DP_URL="$(grep -Eo "\\\$PinnedDashboardCmdUrl *= *'[^']*'" "$PS1" | head -1 | sed "s/.*'\\(.*\\)'.*/\\1/")"
  case "$DP_URL" in
    "" ) BLOCK "Install-Cockpit.ps1 에 \$PinnedDashboardCmdUrl 이 없음(§10b 미배선?)." ;;
    *example.invalid*) BLOCK "ps1 \$PinnedDashboardCmdUrl 이 example.invalid — 실제 release 자산 URL 로 치환." ;;
    https://*)
      OK "ps1 \$PinnedDashboardCmdUrl = https 비-플레이스홀더"
      MB_URL="$(jq -r '.artifacts.bootstrap.url // empty' windows/bootstrap/manifest.json 2>/dev/null || echo "")"
      if [ -n "$MB_URL" ] && [ "${DP_URL%/*}" != "${MB_URL%/*}" ]; then
        BLOCK "ps1 대시보드 런처 URL 이 bootstrap 과 다른 릴리스 태그를 가리킴(재핀 누락). dash=$DP_URL bootstrap=$MB_URL"
      elif [ -n "$MB_URL" ]; then
        OK "ps1 대시보드 런처 URL == bootstrap 릴리스 태그(체인 일치)"
      fi ;;
    *) BLOCK "ps1 \$PinnedDashboardCmdUrl 이 https 가 아님: $DP_URL" ;;
  esac
  MD_SHA="$(jq -r '.artifacts.dashboard_cmd.sha256 // empty' windows/bootstrap/manifest.json 2>/dev/null || echo "")"
  if [ -n "$MD_SHA" ]; then
    if [ "$(printf '%s' "$MD_SHA" | tr 'A-Z' 'a-z')" = "$DASH_ACTUAL" ]; then
      OK "manifest dashboard_cmd.sha256 == repo 실계산(핀 체인 일치)"
    else
      BLOCK "manifest dashboard_cmd.sha256 이 repo Dashboard.cmd 해시와 불일치 — manifest 재생성 필요. manifest=$MD_SHA actual=$DASH_ACTUAL"
    fi
  else
    WARN "manifest dashboard_cmd.sha256 미기재/jq 없음 — ps1↔manifest 대시보드 체인 미검증(§4 필수필드가 존재는 강제)."
  fi
fi   # $DASHF 존재 BLOCK 은 §1c 담당

# ── 1e) .cmd 블록 내 비인용 괄호(배치 파스 조기종결) 검사 ──
# v0.1.6 실사고: Uninstall.cmd 의 if-블록 안 echo "(if any)." 가 cmd 블록을 조기 종결
# → 바로가기 삭제 미실행+배치 중단. Windows 실행 없이(Linux CI 포함) 소스 수준에서 기계 차단.
# 판정 모델·한계·오탐 이력 = scripts/cmd-paren-gate.py 헤더 단일출처(양/음성 픽스처 검증).
sec "1e) .cmd 블록 내 비인용 괄호(배치 파스 안전)"
if command -v python3 >/dev/null 2>&1; then
  _paren_out="$(python3 scripts/cmd-paren-gate.py windows/bootstrap/*.cmd 2>&1)"; _paren_rc=$?
  if [ "$_paren_rc" -eq 0 ]; then
    OK "windows/bootstrap/*.cmd 블록 내 비인용 괄호 0건"
  else
    echo "$_paren_out"
    BLOCK ".cmd 블록 안 텍스트에 비인용 괄호 — cmd 가 블록을 조기 종결(v0.1.6 Uninstall 실사고 클래스). 괄호 제거/^( ^) 이스케이프/따옴표 보호 후 재실행."
  fi
else
  SOFT "python3 없음 — .cmd 블록 괄호 검사 생략(설치 후 재실행 권장)"
fi

# ── 1f) 설치기 온보딩 정적 불변식(v0.1.8 설계 §7·Codex 4f 차단3/4·누락2) ──
# 온보딩 폼(Install-Cockpit.ps1)의 안전 속성이 소스 수준에서 후퇴하지 않았는지 발행 전에 차단.
sec "1f) 설치기 온보딩 정적 불변식"
if [ -f "$PS1" ]; then
  # ① C1: 설치기는 setup_complete(egress 동의 게이트)를 몰라야 한다 — 문자열 자체 금지.
  if grep -q 'setup_complete' "$PS1"; then
    BLOCK "Install-Cockpit.ps1 에 setup_complete 참조 — egress 동의 게이트를 온보딩 마커로 오용(C1 위반)."
  else
    OK "설치기에 setup_complete 참조 없음(C1)"
  fi
  # ② C2: set-extraction-key 행 = 허용 변수 \$DistroName 뿐(키 변수·env·경로 결합 금지) + --from-env 금지.
  _sek_lines="$(grep -n 'set-extraction-key' "$PS1" || true)"
  if [ -z "$_sek_lines" ]; then
    BLOCK "Install-Cockpit.ps1 에 set-extraction-key 호출 없음 — 온보딩 키 등록 경로 누락."
  else
    # 허용 토큰 = 대입 대상($psi.Arguments)과 검증된 배포판명($DistroName)뿐 — 그 외 $ 는 전부 차단.
    _sek_bad="$(printf '%s\n' "$_sek_lines" | sed -e 's/\$psi\.Arguments//g' -e 's/\$DistroName//g' | grep '\$' || true)"
    if [ -n "$_sek_bad" ]; then
      BLOCK "set-extraction-key 행에 \$DistroName 외 변수 결합 — 키가 argv/명령줄로 샐 수 있음(C2): $_sek_bad"
    else
      OK "set-extraction-key 행 변수 = \$DistroName 뿐(C2)"
    fi
    if printf '%s\n' "$_sek_lines" | grep -q -- '--from-env'; then
      BLOCK "설치기가 set-extraction-key --from-env 사용 — 키를 env 로 옮기는 경로 금지(C2)."
    fi
  fi
  grep -q 'RedirectStandardInput' "$PS1" \
    && OK "키 전달 = 표준입력 리다이렉트(RedirectStandardInput) 존재(C2)" \
    || BLOCK "RedirectStandardInput 부재 — 키 stdin 주입 경로 후퇴(C2)."
  # 키 변수의 출력/파일/env 경유 금지(회귀 클래스 — Codex 4f impl 검토):
  #   허용 키 변수 사용처 = 폼 수집·stdin Write·소거뿐. 출력계 cmdlet/env 대입과의 결합은 전부 차단.
  _key_leak="$(grep -En '(\$Choice\.Key|\$result\.Key|[[:space:]]\$Key\b)' "$PS1" \
    | grep -E 'Write-Host|Write-Output|Set-Content|Add-Content|Out-File|\$env:' || true)"
  if [ -n "$_key_leak" ]; then
    BLOCK "키 변수가 출력/파일/env 경로와 결합 — 키 원문 노출면(C2): $_key_leak"
  else
    OK "키 변수 출력/파일/env 결합 없음(C2)"
  fi
  if grep -Eq '(-u[[:space:]]+(root|0)|--user[[:space:]]+(root|0))' "$PS1"; then
    BLOCK "설치기 wsl 호출에 -u/--user root(또는 0) — 키/상태가 root 소유로 기록되는 사고면(C2)."
  else
    OK "설치기 wsl 호출 -u/--user root 없음(C2)"
  fi
  # ③ C4: 설치기의 install --apply 통째 호출 금지 + narrow subcommand 실재.
  if grep -Eq 'install[[:space:]]+--apply' "$PS1"; then
    BLOCK "설치기가 setup.py install --apply 호출 — narrow 진입점 위반(C4·CLAUDE.md 충돌면)."
  else
    OK "설치기에 install --apply 호출 없음(C4)"
  fi
  grep -q 'add_parser("apply-installer-onboarding")' plugin/skills/setup-wizard/setup.py \
    && OK "setup.py 에 apply-installer-onboarding subcommand 실재(C4)" \
    || BLOCK "setup.py 에 apply-installer-onboarding 없음 — 설치기 적용 경로 깨짐(C4)."
  # ④ C3: 폼·무인 플래그·비대화 감지·-STA 실재(후퇴 시 무인 경로 블로킹/폼 회귀).
  grep -q 'NoOnboardingGui' "$PS1" && grep -q 'IsInputRedirected' "$PS1" && grep -q 'UserInteractive' "$PS1" \
    && OK "무인 플래그+비대화 감지 토큰 존재(C3)" \
    || BLOCK "-NoOnboardingGui/IsInputRedirected/UserInteractive 중 누락 — 무인 경로(Install.cmd < NUL) 블로킹 위험(C3)."
  grep -q 'Show-OnboardingForm' "$PS1" \
    && OK "온보딩 폼 함수 존재" \
    || BLOCK "Show-OnboardingForm 부재 — v0.1.8 온보딩 UX 회귀."
  grep -q -- '-STA' windows/bootstrap/Cockpit-Install.cmd \
    && OK "Cockpit-Install.cmd -STA 존재(C3)" \
    || BLOCK "Cockpit-Install.cmd 에 -STA 없음 — WinForms 폼 아파트먼트 미보장(C3)."
  # ⑤ 마법사 스킵 판정 근거 = installer-onboarding.json 만(SKILL 참조 실재).
  grep -q 'installer-onboarding.json' plugin/skills/setup-wizard/SKILL.md \
    && OK "SKILL.md 스킵 판정 = installer-onboarding.json 참조 실재" \
    || BLOCK "SKILL.md 에 installer-onboarding.json 참조 없음 — 재질문 스킵 로직 누락/오용."
  # ⑥ 베이크 전제(Codex 4f 차단4): 폼 적용은 사전설치 플러그인에 의존 — 베이크 누락 이미지 발행 차단.
  if [ -f windows/bootstrap/manifest.json ]; then
    _baked="$(jq -r '.provenance.plugin_preinstall_baked // empty' windows/bootstrap/manifest.json)"
    if [ "$_baked" = "true" ]; then
      OK "manifest provenance.plugin_preinstall_baked=true(온보딩 적용 전제)"
    else
      BLOCK "manifest provenance.plugin_preinstall_baked != true — 베이크 누락 이미지면 설치기 온보딩 전체 fail-open."
    fi
  fi
else
  BLOCK "$PS1 가 없습니다(§1f)."
fi

# ── 1g) 대시보드 필수설치화 정적 불변식(v0.1.9 설계 §7·#1·#15·#16·#17·D2) ──
# 대시보드 설치가 다시 폼 체크에 갇히면(D2 위반) 무인/미동의/건너뜀 경로가 미설치로 후퇴한다.
sec "1g) 대시보드 필수설치화 불변식(v0.1.9)"
if [ -f "$PS1" ]; then
  # ① #1: 대시보드 설치를 폼 밖 공통 함수(Invoke-DashboardInstall)로 끌어올렸는가.
  grep -q 'function Invoke-DashboardInstall' "$PS1" \
    && OK "Invoke-DashboardInstall(폼 밖 필수설치) 함수 존재(#1)" \
    || BLOCK "Invoke-DashboardInstall 부재 — 대시보드 필수설치화 회귀(#1)."
  # ② #15: 모든 경로 공통 호출(폼 show/skip 분기 밖·§9.4)이 실재하고, 폼 분기(§9.5 `if ($OnboardingBlocked)`)
  #    보다 **앞**에 있어야 한다(위치 검사 — 호출이 GUI 분기 안으로 이동하면 일부 경로 전용으로 후퇴·GAP3).
  _call_ln="$(grep -n 'Invoke-DashboardInstall -DistroName' "$PS1" | head -1 | cut -d: -f1)"
  # 폼 분기는 최상위(col 0) `if ($OnboardingBlocked) {` — 함수 내부(들여쓰기) 동명 분기와 구분(^앵커).
  _form_ln="$(grep -n '^if (\$OnboardingBlocked) {' "$PS1" | head -1 | cut -d: -f1)"
  if [ -z "$_call_ln" ]; then
    BLOCK "Invoke-DashboardInstall 호출 부재 — 필수설치화 미배선(#15)."
  elif [ -n "$_form_ln" ] && [ "$_call_ln" -ge "$_form_ln" ]; then
    BLOCK "Invoke-DashboardInstall 호출(L$_call_ln)이 폼 분기(if(\$OnboardingBlocked) L$_form_ln) 이후/안 — 필수설치화가 일부 경로 전용으로 후퇴(D2/GAP3)."
  else
    OK "Invoke-DashboardInstall 호출이 폼 분기보다 앞(모든 경로 공통·#15·위치검증)"
  fi
  # ③ D2: 대시보드가 폼 선택(\$Choice.Dashboard)에 다시 갇히면 안 된다.
  if grep -q '\$Choice\.Dashboard' "$PS1"; then
    BLOCK "\$Choice.Dashboard 참조 — 대시보드가 다시 폼 체크에 갇힘(D2 위반·필수설치화 후퇴)."
  else
    OK "\$Choice.Dashboard 참조 없음 — 대시보드는 폼과 독립(D2)"
  fi
  # ④ D2: Invoke-OnboardApply 안에 install-dashboard 호출이 없어야(폼 조건부 설치 블록 제거).
  if awk '/^function Invoke-OnboardApply/{f=1} f&&/install-dashboard/{print "HIT"} /^}/{if(f)f=0}' "$PS1" | grep -q HIT; then
    BLOCK "Invoke-OnboardApply 안에 install-dashboard 호출 — 폼 조건부 설치 블록 잔존(D2)."
  else
    OK "Invoke-OnboardApply 에 폼 조건부 대시보드 설치 없음(D2)"
  fi
  # ⑤ #16: install-viewer.sh 실패 분류 토큰+trap 계약(오프라인 실패 UX 의 단일 지점).
  #    주석이 아니라 **실제 emit**(printf 'INSTALL_VIEWER_FAIL=...) + trap 을 검사(GAP2). 파일 부재=BLOCK.
  IV="plugin/dashboard/install-viewer.sh"
  if [ ! -f "$IV" ]; then
    BLOCK "install-viewer.sh 부재($IV) — 대시보드 설치·실패 UX 전체 소스 누락(#16)."
  elif grep -vE '^[[:space:]]*#' "$IV" | grep -q "printf 'INSTALL_VIEWER_FAIL=" \
       && grep -vE '^[[:space:]]*#' "$IV" | grep -qE 'trap .* EXIT'; then
    OK "install-viewer 실패 토큰 실제 emit + trap 계약 존재(#16)"
  else
    BLOCK "install-viewer.sh 에 INSTALL_VIEWER_FAIL 실제 emit/trap 누락(주석 아님) — 오프라인 실패 UX 회귀(#16)."
  fi
else
  BLOCK "$PS1 가 없습니다(§1g)."
fi
# ⑥ #17: Cockpit-Dashboard.cmd 미설치 문구에 opt-in 표현 잔존 금지(필수설치화 반영 강제).
if [ -f "$DASHF" ]; then
  if grep -qiE 'opt[ -]?in' "$DASHF"; then
    BLOCK "Cockpit-Dashboard.cmd 에 'opt in/opt-in' 잔존 — 필수설치화 문구 미반영(#17)."
  else
    OK "Cockpit-Dashboard.cmd 에 opt-in 표현 없음(#17)"
  fi
fi

# ── 2) 웹 프런트도어: example.invalid 0건 + 발행 플레이스홀더 잔존 + .cmd SHA 실측 대조 ──
sec "2) 웹 프런트도어(사용자 노출)"
if [ -f web/index.html ]; then
  n=$(grep -cE "example\.invalid" web/index.html || true)
  if [ "$n" -eq 0 ]; then OK "web/index.html — example.invalid 0건"
  else BLOCK "web/index.html 에 example.invalid ${n}건(미발행 미리보기 배너/링크). 발행 URL 로 치환 + 배너 제거."; fi
  # 2a) 릴리스 플레이스홀더('발행 시 채움') 잔존 차단 — 다운로드 표 .cmd SHA 칸이 미치환이면 여기서 잡힌다.
  if grep -qF "발행 시 채움" web/index.html; then
    BLOCK "web/index.html 에 '발행 시 채움' 플레이스홀더 잔존 — release 자산 실측값(링크·SHA-256)으로 치환."
  else
    OK "web/index.html — '발행 시 채움' 플레이스홀더 0건"
  fi
  # 2b) 다운로드 표 .cmd SHA-256 == repo .cmd 실계산(수기전사·치환순서 오류 차단).
  #     .cmd 는 release 에 repo 파일 그대로 업로드되므로 repo 파일 해시가 곧 자산 해시다.
  #     → 반드시 .cmd 치환(Install/Repair PS1_URL/PS1_SHA256) 확정 '후' 그 해시를 표에 기입해야 통과.
  for _cmd in Cockpit-Install.cmd Cockpit-Dashboard.cmd Cockpit-Repair.cmd Cockpit-Uninstall.cmd; do
    _f="windows/bootstrap/$_cmd"
    [ -f "$_f" ] || continue   # 존재 BLOCK 은 §1b/§1c 담당
    # 체크섬 셀을 안정 앵커 data-artifact="<파일명>" 로 지목한다. 설치 안내 산문·이름 열에도
    # 파일명이 등장하므로 파일명+class 조합 grep 은 취약하다(산문 오탐/열 순서 의존). data-artifact
    # 속성은 체크섬 셀에만 있어 행을 유일하게 특정한다(Codex 4f false-BLOCK 방지 앵커의 강화).
    _n="$(grep -Fc "data-artifact=\"$_cmd\"" web/index.html)"
    if [ "${_n:-0}" -ne 1 ]; then
      BLOCK "web/index.html 에 $_cmd 체크섬 앵커(data-artifact=\"$_cmd\") 가 정확히 1개가 아님(${_n}개) — 0이면 표에 행 추가, 다수면 중복 제거(잘못된 셀의 SHA 통과 방지·Codex 4f 발견3)."
      continue
    fi
    _row="$(grep -F "data-artifact=\"$_cmd\"" web/index.html | head -1)"
    case "$_row" in
      *'class="cksum"'*) : ;;   # 앵커가 실제 체크섬 셀에 있는지(주석/숨김 셀 오탐 방지)
      *) BLOCK "web/index.html $_cmd data-artifact 앵커가 class=\"cksum\" 체크섬 셀이 아님 — 앵커를 다운로드 표 체크섬 셀에 두세요."; continue ;;
    esac
    _webhex="$(printf '%s' "$_row" | grep -Eo '[0-9A-Fa-f]{64}' | head -1)"
    if [ -z "$_webhex" ]; then
      BLOCK "web/index.html $_cmd SHA-256 미기재(발행 시 채움 잔존?) — release 자산 실측 해시로 채우세요."
    else
      _act="$(_sha256 "$_f" | tr 'A-Z' 'a-z')"
      if [ "$(printf '%s' "$_webhex" | tr 'A-Z' 'a-z')" = "$_act" ]; then
        OK "web $_cmd SHA-256 == repo 파일 실계산(일치)"
      else
        BLOCK "web $_cmd SHA-256 이 repo 파일 해시와 불일치(수기전사/치환 순서 오류). .cmd 치환 확정 후 그 해시를 표에 기입. web=$_webhex actual=$_act"
      fi
    fi
    # 2b-2) 다운로드 링크(href) 존재 — SHA 만 채우고 링크 전환을 빠뜨리는 결함 클래스 차단
    #       (v0.1.5 실사고: 표에 SHA 는 있는데 .cmd 4행 href 부재 → 프런트도어에서 다운로드 불가).
    #       파일 전체가 아니라 **해당 표 행(data-artifact 앵커와 같은 줄)** 안에서만 찾는다 —
    #       주석/다른 위치의 링크로 통과하는 우회면 차단(Codex 발견3). 표 행은 한 줄 <tr> 구조.
    _cmd_re="$(printf '%s' "$_cmd" | sed 's/\./\\./g')"
    if printf '%s' "$_row" | grep -Eq "href=\"https://[^\"]*/releases/download/[^\"]+/${_cmd_re}\""; then
      OK "web $_cmd 다운로드 href 존재(표 행 안·release 자산 URL)"
    else
      BLOCK "web/index.html $_cmd 표 행(data-artifact 앵커 줄)에 다운로드 링크(href=…/releases/download/…/$_cmd) 부재 — SHA 만 있고 링크가 없으면 사용자가 받을 수 없다(v0.1.5 실물결함 재발 차단). 그 행에 자산 URL <a href> 를 추가하세요."
    fi
  done
else
  WARN "web/index.html 없음(웹 트랙 미발행?)"
fi

# ── 3) 매니페스트류: maintainer/example.invalid 치환 ──
sec "3) 플러그인·마켓플레이스 매니페스트"
for mf in plugin/.claude-plugin/plugin.json .claude-plugin/marketplace.json; do
  [ -f "$mf" ] || { WARN "$mf 없음"; continue; }
  bad=0
  grep -q "cc-companion maintainer" "$mf" && { BLOCK "$mf — author/owner 가 'cc-companion maintainer' 플레이스홀더. 실제 게시자명으로 교체."; bad=1; }
  grep -qE "example\.invalid" "$mf" && { BLOCK "$mf — homepage/repository 가 example.invalid. 실제 URL 로 교체."; bad=1; }
  [ "$bad" -eq 0 ] && OK "$mf — 플레이스홀더 없음"
done

# ── 4) 릴리스 매니페스트(생성본): __*__ 토큰·서명 플래그 ──
sec "4) 릴리스 매니페스트(생성본)"
REL="windows/bootstrap/manifest.json"   # .example 아님 — 발행 시 CI 가 생성
if [ -f "$REL" ]; then
  if grep -qE "__[A-Z0-9_]+__" "$REL"; then
    BLOCK "$REL 에 __PLACEHOLDER__ 토큰 잔존. build-rootfs/CI 산출값으로 채우세요."
  else OK "$REL — __PLACEHOLDER__ 토큰 0건"; fi
  # 4-필수) 생성본 manifest 필수 필드 존재. 비어 있으면 아래 URL/해시 교차대조가 '조용히 스킵'되어
  #   우회면이 된다(Codex 4f 발견1) → 단일출처 manifest 는 모든 자산 URL·해시를 반드시 담아야 한다.
  _mfmiss=0
  for _jp in \
    .artifacts.image.url .artifacts.image.sha256 \
    .artifacts.bootstrap.url .artifacts.bootstrap.sha256 \
    .artifacts.staged_bootstrap.url .artifacts.staged_bootstrap.sha256 \
    .artifacts.dashboard_cmd.url .artifacts.dashboard_cmd.sha256; do
    _v="$(jq -r "$_jp // empty" "$REL" 2>/dev/null)"
    [ -n "$_v" ] || { BLOCK "manifest.json 필수 필드 누락: $_jp — 자산 URL/해시가 비면 교차검증이 무력화된다. 생성본에 채우세요."; _mfmiss=1; }
  done
  jq -e '(.provenance? // empty) | type == "object"' "$REL" >/dev/null 2>&1 || { BLOCK "manifest.json provenance 객체 누락 — 감사·스키마 정합 대상이 없습니다."; _mfmiss=1; }
  [ "$_mfmiss" -eq 0 ] && OK "manifest.json 필수 필드(자산 URL·해시·provenance) 전부 존재"
  # 4a) image.sha256 삼각대조 — manifest 기록값 == dist 산출 tar.gz 해시(있으면). §1(ps1 핀↔산출물)의
  #     manifest 쪽 레그. dist 아티팩트가 없으면(로컬 dev) WARN(§1 과 동일한 '산출물 없음' 처리).
  M_IMG="$(jq -r '.artifacts.image.sha256 // empty' "$REL")"
  ART_IMG=""
  [ -f dist/windows/cockpit-wsl.tar.gz.sha256 ] && ART_IMG="$(awk '{print $1}' dist/windows/cockpit-wsl.tar.gz.sha256)"
  [ -z "$ART_IMG" ] && [ -f dist/windows/provenance.json ] && ART_IMG="$(jq -r '.sha256_tar_gz // empty' dist/windows/provenance.json)"
  if [ -n "$M_IMG" ] && [ -n "$ART_IMG" ]; then
    if [ "$(printf '%s' "$M_IMG" | tr 'A-Z' 'a-z')" = "$(printf '%s' "$ART_IMG" | tr 'A-Z' 'a-z')" ]; then
      OK "manifest image.sha256 == dist 산출 tar.gz 해시(일치)"
    else
      BLOCK "manifest image.sha256 이 dist 산출 tar.gz 해시와 불일치 — 사용자 다운로드 후 이미지 체크섬 실패. manifest 재생성 필요. manifest=$M_IMG art=$ART_IMG"
    fi
  elif [ -n "$M_IMG" ]; then
    SOFT "dist/windows 이미지 산출물 없어 manifest image.sha256 실측 대조 생략(빌드 아티팩트 다운로드 후 재실행 권장)."
  fi
  # 4b) staged_bootstrap.sha256 삼각대조 — staged ps1 은 repo 파일 그대로 업로드되므로 §1b(부트스트랩)와
  #     같이 repo 실계산과 항상 대조 가능(dist 불요). Install.cmd 재핀 때 staged 재생성 누락을 잡는다.
  M_STG="$(jq -r '.artifacts.staged_bootstrap.sha256 // empty' "$REL")"
  STGF="windows/staged/Install-Cockpit-Staged.ps1"
  if [ -n "$M_STG" ] && [ -f "$STGF" ]; then
    STG_ACTUAL="$(_sha256 "$STGF" | tr 'A-Z' 'a-z')"
    if [ "$(printf '%s' "$M_STG" | tr 'A-Z' 'a-z')" = "$STG_ACTUAL" ]; then
      OK "manifest staged_bootstrap.sha256 == repo staged ps1 실계산(일치)"
    else
      BLOCK "manifest staged_bootstrap.sha256 이 repo staged ps1 해시와 불일치 — manifest 재생성 필요(릴리스 재핀과 함께). manifest=$M_STG actual=$STG_ACTUAL"
    fi
  elif [ -n "$M_STG" ]; then
    WARN "$STGF 없음 — manifest staged 핀 실측 대조 생략."
  fi
  signed=$(jq -r '.artifacts.bootstrap.authenticode.signed // empty' "$REL" 2>/dev/null || echo "")
  thumb=$(jq -r '.artifacts.bootstrap.authenticode.publisher_thumbprint // empty' "$REL" 2>/dev/null || echo "")
  ack=$(jq -r '.artifacts.bootstrap.authenticode.unsigned_acknowledged // empty' "$REL" 2>/dev/null || echo "")
  imgsha=$(jq -r '.artifacts.image.sha256 // empty' "$REL" 2>/dev/null || echo "")
  if [ "$signed" = "true" ]; then
    OK "authenticode.signed = true(서명 모드)"
    case "$thumb" in ""|*__CERT_THUMBPRINT__*) BLOCK "publisher_thumbprint 미설정/플레이스홀더 — 실제 인증서 지문 기입.";; *) OK "publisher_thumbprint 설정됨";; esac
  elif [ "$ack" = "true" ]; then
    # 미서명+체크섬 발행(코드서명 인증서 없음, 사용자 결정 2026-06-23). 무결성은 SHA-256 체크섬 대조로만 보장.
    WARN "부트스트랩 미서명 배포(unsigned_acknowledged=true) — 수령자는 SHA-256 체크섬으로만 검증(서명층 없음). web/README·다운로드 안내에 '서명 없음·체크섬 대조 필수' 명시할 것."
    case "$imgsha" in ""|*__IMAGE_SHA256__*) BLOCK "미서명 모드인데 image.sha256 체크섬 미기재/플레이스홀더 — 무결성 검증 경로 없음. CI 산출 SHA-256 기입.";; *) OK "image.sha256 체크섬 존재 — 무결성 검증 경로 확보";; esac
  else
    BLOCK "authenticode.signed != true 이고 unsigned_acknowledged 도 아님 — 서명(signed:true+지문)하거나, 의도적 미서명이면 manifest 에 unsigned_acknowledged:true + image.sha256 명시(수령자 체크섬 검증 고지)."
  fi
  # 4c) provenance 스키마 정합 — 생성본 manifest.json 과 템플릿 manifest.example.json 의 provenance 키집합
  #     (주석 키 '_*' 제외)이 같아야 한다. 한 쪽이 필드를 더하거나 빼면(예: plugin_commit→private/public 분리)
  #     다른 쪽이 스테일해지는 드리프트를 잡는다. 감사·재생성이 같은 스키마를 신뢰하도록.
  EXF="windows/bootstrap/manifest.example.json"
  if [ -f "$EXF" ]; then
    _provkeys() { jq -r '.provenance | keys | map(select(startswith("_")|not)) | join(",")' "$1" 2>/dev/null; }
    RK="$(_provkeys "$REL")"; EK="$(_provkeys "$EXF")"
    if [ -z "$RK" ] || [ -z "$EK" ]; then
      WARN "provenance 키 추출 실패(JSON 형식 확인) — 스키마 정합 미검증. real=[$RK] example=[$EK]"
    elif [ "$RK" = "$EK" ]; then
      OK "provenance 스키마 정합(manifest ↔ example 키집합 일치): $RK"
    else
      BLOCK "manifest.json ↔ manifest.example.json provenance 스키마 불일치(템플릿·생성본 갈라짐 — 둘 중 하나 갱신). real=[$RK] example=[$EK]"
    fi
  else
    WARN "$EXF 없음 — provenance 스키마 정합 미검증."
  fi
else
  BLOCK "$REL 없음 — 릴리스 매니페스트(서명·해시·URL) 미생성. 발행 전 manifest.example.json 을 기반으로 생성하세요(서명/호스팅 후). 실제 Authenticode 서명 검증은 Windows smoke(ps-gate-smoke -RequireSignature)가 수행."
fi

# ── 5) 베이스 이미지 digest 핀 ──
sec "5) 베이스 이미지 digest 핀"
BIMG="windows/golden/base-image.txt"
if [ -f "$BIMG" ]; then
  val=$(grep -vE '^[[:space:]]*#' "$BIMG" | grep -vE '^[[:space:]]*$' | head -1)
  case "$val" in
    *@sha256:*) OK "base-image = digest 핀($val)";;
    "") BLOCK "$BIMG 에 이미지 값이 없습니다.";;
    *) BLOCK "base-image 가 digest 핀이 아닙니다('$val'). 재현성 위해 ubuntu:24.04@sha256:<digest> 로 고정.";;
  esac
else
  BLOCK "$BIMG 없음 — 베이스 핀 단일 출처가 필요합니다."
fi

# ── 5b) claude-code 공급망 핀(발행 빌드) ──
sec "5b) claude-code 버전 핀(발행 빌드)"
PROV="dist/windows/provenance.json"
if [ -f "$PROV" ] && command -v jq >/dev/null 2>&1; then
  cc_inst="$(jq -r '.versions.claude // empty' "$PROV" 2>/dev/null)"
  cc_pin="$(jq -r '.versions.claude_code_pin // empty' "$PROV" 2>/dev/null)"
  if [ -z "$cc_inst" ]; then
    WARN "provenance 에 claude 미설치 기록 — 핀 검사 생략(CLI 미베이크 빌드?)."
  elif printf '%s' "$cc_pin" | grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z.-]+)?$'; then
    OK "claude-code 핀 고정(exact semver: $cc_pin)"
  else
    BLOCK "claude-code 핀이 정확한 버전이 아님('$cc_pin') — latest/range(^,~,.x,next 등)은 여전히 floating. exact semver(예: 1.2.3)로 CLAUDE_CODE_VERSION 지정."
  fi
else
  SOFT "dist/windows/provenance.json 없음 — claude-code 핀 미검증(빌드 아티팩트로 재실행 권장)."
fi

# ── 6) 발행 트리 시크릿 스캔(docs export-ignore 제외) ──
sec "6) 발행 트리 secret-scan(PUBLISH)"
if PUBLISH=1 bash scripts/secret-scan.sh >/tmp/pg_secret.txt 2>&1; then
  OK "발행 트리 시크릿·개인정보 0건"
else
  BLOCK "발행 트리 secret-scan 실패 — /tmp/pg_secret.txt 확인."
  sed 's/^/        /' /tmp/pg_secret.txt | grep -E "FAIL" | head -10
fi

# ── 6b) 발행 트리 금칙어(Codex 동봉물 잔재) 게이트 ──
# G10 에서 배포판의 Codex 보조검토 연결 지원을 전부 제거했다. 발행 트리(docs export-ignore 제외)에
# 기능/경로 잔재가 다시 스며들면 거버넌스 문구(더 이상 OpenAI 로 데이터 안 감)와 어긋나므로 차단한다.
# 대상: plugin/codex · codex_enabled · codex_call · codex_global_brief · '보조 검토'.
# 제외: bare "Codex"(개발과정 attribution 주석 허용) · OpenAI 키패턴(secret-scan §6 담당) ·
#       docs/(export-ignore) · 이 게이트/스캐너 자신(금칙어 '패턴' 을 정당히 포함).
sec "6b) 발행 트리 금칙어(Codex 잔재)"
_PGB_FILES=()
while IFS= read -r _line; do
  case "$_line" in
    *": export-ignore: set") : ;;                    # 발행 제외(docs)
    *": export-ignore: "*)
      _p="${_line%: export-ignore: *}"
      case "$_p" in
        scripts/publish-gate.sh|scripts/secret-scan.sh|"") : ;;
        *) _PGB_FILES+=("$_p") ;;
      esac ;;
  esac
done < <(git ls-files | git check-attr --stdin export-ignore)
if [ "${#_PGB_FILES[@]}" -eq 0 ]; then
  WARN "발행 트리 파일 목록이 비었습니다 — 금칙어 검사 생략(git 상태 확인)."
else
  _pathhits="$(printf '%s\n' "${_PGB_FILES[@]}" | grep -i -- 'codex' || true)"      # (i) 경로 잔재
  # 정확 토큰 + 흔한 변형(구분자·대소문자·띄어쓰기)까지 — 약간의 개명으로 우회하는 재유입 차단(Codex 4f 발견4).
  # bare "Codex"(attribution) 는 여전히 미매칭(codex 뒤 enabled/call/global brief·plugin 인접·'보조 검토' 필요).
  _conhits="$(grep -nEI -- 'plugins?[/._-]codex|codex[-_.]?enabled|codex[-_.]?call|codex[-_.]?global[-_.]?brief|보조[[:space:]]*검토' "${_PGB_FILES[@]}" 2>/dev/null || true)"  # (ii) 내용 잔재
  if [ -z "$_pathhits" ] && [ -z "$_conhits" ]; then
    OK "발행 트리 금칙어 0건(Codex 기능/경로 잔재 없음)"
  else
    [ -n "$_pathhits" ] && { BLOCK "발행 트리에 codex 경로 파일 잔존(G10 제거 대상 재유입):"; printf '%s\n' "$_pathhits" | sed 's/^/        /' | head -10; }
    [ -n "$_conhits" ]  && { BLOCK "발행 트리에 Codex 동봉물 금칙어 잔존(기능/경로 잔재 — bare Codex attribution 은 제외 대상이나 이 토큰들은 기능 연결):"; printf '%s\n' "$_conhits" | sed 's/^/        /' | head -15; }
  fi
fi

# ── 7) export-ignore 동작: 발행 tarball 에 docs/ 미포함 ──
sec "7) docs/ 발행 트리 제외 검증"
docs_n=$(git archive --worktree-attributes --format=tar HEAD 2>/dev/null | tar -t 2>/dev/null | grep -c "^docs/" || true)
if [ "${docs_n:-1}" -eq 0 ]; then OK "git archive 발행 tarball 에 docs/ 0건"
else BLOCK "발행 tarball 에 docs/ ${docs_n}건 — .gitattributes export-ignore 확인."; fi

# ── 8) 비차단 경고: 문서·라이선스·repo 공개 캐비엇 ──
sec "8) 비차단 점검(육안 확인)"
for d in README.md web/README.md windows/README.md; do
  [ -f "$d" ] && grep -qE "example\.invalid" "$d" && WARN "$d — example.invalid 언급(치환 지침/상태 문구로 추정 — 의도 확인)."
done
[ -f LICENSE ] && grep -q "cc-companion maintainer" LICENSE && WARN "LICENSE 저작권자 = 'cc-companion maintainer'(프로젝트명 의도면 유지 가능)."
WARN "Authenticode 서명 검증은 Linux 에서 불가 — Windows smoke 잡(ps-gate-smoke)에서 Get-AuthenticodeSignature 로 확인."
WARN "repo 공개 발행 시: docs/ 와 git 이력에 빌드-내부 식별자(계정명·SHA·이메일)가 남아 있음 → 공개 repo 면 이력 scrub/제거 필요(릴리스 tarball 은 export-ignore 로 안전)."

# ── 결과 ──
echo ""
echo "────────────────────────────────────────────"
if [ "$block" -eq 0 ]; then
  echo "[publish-gate] ✓ 발행 차단 없음 (경고 ${warns}건 — 육안 확인 후 발행)."
  exit 0
else
  echo "[publish-gate] ✗ 발행 차단 — 위 [BLOCK] 항목을 해소 후 재실행. (경고 ${warns}건)"
  exit 1
fi
