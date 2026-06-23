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

git rev-parse --git-dir >/dev/null 2>&1 || { echo "[publish-gate][FATAL] git 저장소가 아닙니다."; exit 2; }

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
      WARN "dist/windows 산출물 없어 핀-해시 일치 미검증(빌드 아티팩트 다운로드 후 재실행 권장)."
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

# ── 2) 웹 프런트도어: example.invalid 0건(미리보기 배너 제거 + 링크 실주소) ──
sec "2) 웹 프런트도어(사용자 노출)"
if [ -f web/index.html ]; then
  n=$(grep -cE "example\.invalid" web/index.html || true)
  if [ "$n" -eq 0 ]; then OK "web/index.html — example.invalid 0건"
  else BLOCK "web/index.html 에 example.invalid ${n}건(미발행 미리보기 배너/링크). 발행 URL 로 치환 + 배너 제거."; fi
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
  WARN "dist/windows/provenance.json 없음(또는 jq 없음) — claude-code 핀 미검증(빌드 아티팩트로 재실행 권장)."
fi

# ── 6) 발행 트리 시크릿 스캔(docs export-ignore 제외) ──
sec "6) 발행 트리 secret-scan(PUBLISH)"
if PUBLISH=1 bash scripts/secret-scan.sh >/tmp/pg_secret.txt 2>&1; then
  OK "발행 트리 시크릿·개인정보 0건"
else
  BLOCK "발행 트리 secret-scan 실패 — /tmp/pg_secret.txt 확인."
  sed 's/^/        /' /tmp/pg_secret.txt | grep -E "FAIL" | head -10
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
