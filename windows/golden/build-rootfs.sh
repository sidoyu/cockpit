#!/usr/bin/env bash
# build-rootfs.sh — cockpit WSL **골든 이미지 빌더**(재현·서명 가능한 산출).
#
# 무엇을 만드나: 핀 고정된 베이스 이미지 안에서 provision.sh 를 돌려 파일시스템을
#   `cockpit-wsl.tar`(WSL `--import` 입력) 로 떠서 gzip 압축하고, **SHA-256 + provenance.json**
#   을 함께 낸다. 손으로 tar 뜨지 않는다(수동 tar 금지 — 출처·재현성 깨짐).
#
# 어디서 도나: 리눅스 + 컨테이너 런타임(docker 또는 podman). CI(단계5)가 이 스크립트를 호출한다.
#   로컬에서 수동 검증도 가능. macOS 빌더에서는 컨테이너 런타임이 있어야 한다.
#
# 사용:
#   BASE_IMAGE=ubuntu:24.04@sha256:<digest> ./build-rootfs.sh [OUTDIR]
#   (재현성을 위해 베이스를 반드시 digest 로 핀 고정하세요. 태그만 쓰면 출처가 흔들립니다.)
#
# 환경변수:
#   BASE_IMAGE          베이스 이미지(기본 ubuntu:24.04 — CI 는 digest 핀 권장)
#   PLUGIN_SRC          이미지에 스테이징할 플러그인 트리(기본: 이 repo 의 plugin/ + GOVERNANCE.md)
#   DISTRO_NAME         산출 메타에 기록할 배포판 이름(기본 cc-cockpit)
#   SOURCE_DATE_EPOCH   재현 빌드 타임스탬프(미설정 시 provenance 에 'unset' 기록)
#   COCKPIT_INSTALL_CC  provision 에 전달(기본 1)
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$HERE/../.." && pwd)"
OUTDIR="${1:-$REPO_ROOT/dist/windows}"
# 베이스 이미지 핀 단일 출처: base-image.txt(주석/빈 줄 제외 첫 줄). 환경변수 BASE_IMAGE 가 우선.
DEFAULT_BASE="$(grep -vE '^[[:space:]]*(#|$)' "$HERE/base-image.txt" 2>/dev/null | head -1 || true)"
BASE_IMAGE="${BASE_IMAGE:-${DEFAULT_BASE:-ubuntu:24.04}}"
PLUGIN_SRC="${PLUGIN_SRC:-}"
DISTRO_NAME="${DISTRO_NAME:-cc-cockpit}"
COCKPIT_INSTALL_CC="${COCKPIT_INSTALL_CC:-1}"
# 첫 실행 안내(MOTD)의 마켓플레이스 소스. 발행 빌드는 실제 URL 을 주입해야 한다
# (미주입 시 example.invalid 플레이스홀더 → 단계5 CI 게이트가 발행 전 차단).
COCKPIT_MARKETPLACE="${COCKPIT_MARKETPLACE:-https://example.invalid/cc-companion}"
# 플러그인 사전설치 베이크(v0.1.2-B)의 설치 정체성 commit — **공개 sidoyu/cockpit 기준 40-hex**(F-1:
# private HEAD 금지 — 공개 repo 는 clean 재export·fresh history 라 SHA 가 다르다). 비우면 provision 이
# 베이크를 건너뛰고 첫 실행 2단계 유지(정직 폴백).
COCKPIT_PLUGIN_COMMIT="${COCKPIT_PLUGIN_COMMIT:-}"

log() { printf '[build-rootfs] %s\n' "$*"; }
die() { printf '[build-rootfs][FATAL] %s\n' "$*" >&2; exit 1; }

# ── 런타임 선택 ────────────────────────────────────────────────────
RUNTIME=""
for c in docker podman; do command -v "$c" >/dev/null 2>&1 && { RUNTIME="$c"; break; }; done
[ -n "$RUNTIME" ] || die "docker/podman 둘 다 없음 — 컨테이너 런타임이 필요합니다."
command -v gzip >/dev/null 2>&1 || die "gzip 없음 — 압축에 필요합니다."
sha256() { if command -v sha256sum >/dev/null 2>&1; then sha256sum "$1" | awk '{print $1}'; else shasum -a 256 "$1" | awk '{print $1}'; fi; }
# 게시 포맷 = .tar.gz: WSL `--import` 가 네이티브로 풀고, Windows 측에 별도 zstd 바이너리가
# 필요 없다(.NET GZipStream 폴백도 내장). 비개발자 경로의 신뢰 바이너리 수를 0 으로 유지.

case "$BASE_IMAGE" in
  *@sha256:*) log "베이스 digest 핀 확인: $BASE_IMAGE" ;;
  *) log "⚠ 베이스가 digest 핀이 아님($BASE_IMAGE) — 재현 빌드를 위해 CI 는 @sha256: 로 고정 권장." ;;
esac

mkdir -p "$OUTDIR"
WORK="$(mktemp -d)"
CID="cockpit-build-$$"
# 실패 시에도 임시 디렉터리 + 빌드 컨테이너 잔존 방지(Codex 운영지적 반영).
cleanup() { rm -rf "$WORK"; "$RUNTIME" rm -f "$CID" >/dev/null 2>&1 || true; }
trap cleanup EXIT

# ── 플러그인 스테이징 소스 준비 ────────────────────────────────────
STAGE="$WORK/cockpit-plugin"
mkdir -p "$STAGE"
if [ -n "$PLUGIN_SRC" ]; then
  cp -a "$PLUGIN_SRC/." "$STAGE/"
else
  # 기본: repo 의 plugin/ 본체 + 거버넌스 문서(이미지 안 참조용). docs/handoffs 등 빌드-내부 문서는 제외.
  cp -a "$REPO_ROOT/plugin/." "$STAGE/"
  cp -a "$REPO_ROOT/GOVERNANCE.md" "$STAGE/GOVERNANCE.md"
fi

# ── 마켓플레이스 트리 스테이징(플러그인 사전설치 베이크 소스) ──────
# 공개 sidoyu/cockpit 과 동일 content = `git archive --worktree-attributes HEAD`(clean export —
# .gitattributes export-ignore 로 docs/ 제외 = D 의 공개 재export 와 같은 규칙). .git 은 없음(트리만).
MKT_STAGE="$WORK/cockpit-marketplace"
mkdir -p "$MKT_STAGE"
if git -C "$REPO_ROOT" rev-parse --git-dir >/dev/null 2>&1; then
  git -C "$REPO_ROOT" archive --worktree-attributes HEAD | tar -x -C "$MKT_STAGE"
else
  log "⚠ git repo 아님 — 마켓플레이스 트리 스테이징 불가(플러그인 베이크는 provision 에서 skip 됨)."
fi

# ── 컨테이너에서 provision 실행 → 파일시스템 export ────────────────
# CID 는 스크립트 상단에서 정의(트랩 cleanup 이 참조). 여기서 재정의하지 않는다.
log "베이스 pull: $BASE_IMAGE"
"$RUNTIME" pull "$BASE_IMAGE" >/dev/null

log "provision 실행(컨테이너 내부)"
# 마운트로 provision 자산·플러그인 전달 후 컨테이너 안에서 실행. 네트워크는 CC 설치(npm)에 필요.
"$RUNTIME" run --name "$CID" \
  -e COCKPIT_USER=cockpit \
  -e COCKPIT_PLUGIN_SRC=/tmp/cockpit-plugin \
  -e COCKPIT_INSTALL_CC="$COCKPIT_INSTALL_CC" \
  -e COCKPIT_MARKETPLACE="$COCKPIT_MARKETPLACE" \
  -e COCKPIT_MARKETPLACE_SRC=/tmp/cockpit-marketplace \
  -e COCKPIT_PLUGIN_COMMIT="$COCKPIT_PLUGIN_COMMIT" \
  -e CLAUDE_CODE_VERSION="${CLAUDE_CODE_VERSION:-}" \
  -e SOURCE_DATE_EPOCH="${SOURCE_DATE_EPOCH:-}" \
  -v "$HERE:/tmp/provision:ro" \
  -v "$STAGE:/tmp/cockpit-plugin:ro" \
  -v "$MKT_STAGE:/tmp/cockpit-marketplace:ro" \
  "$BASE_IMAGE" \
  bash -c 'set -e; cp /tmp/provision/provision.sh /root/provision.sh; cp /tmp/provision/wsl.conf /root/wsl.conf; bash /root/provision.sh' \
  || die "provision 실패(컨테이너 로그 확인)"

RAW_TAR="$WORK/cockpit-wsl.tar"
log "파일시스템 export → $RAW_TAR"
"$RUNTIME" export "$CID" -o "$RAW_TAR"
# 버전 기록(provision 이 이미지에 남긴 build-versions.json)을 컨테이너 제거 전에 꺼낸다.
VERS_JSON="$WORK/build-versions.json"
"$RUNTIME" cp "$CID:/opt/cockpit/build-versions.json" "$VERS_JSON" 2>/dev/null || echo '{}' > "$VERS_JSON"
"$RUNTIME" rm -f "$CID" >/dev/null 2>&1 || true

# ── 압축 + 체크섬 ──────────────────────────────────────────────────
OUT_TAR="$OUTDIR/cockpit-wsl.tar.gz"
log "gzip 압축 → $OUT_TAR"
gzip -9 -n -c "$RAW_TAR" > "$OUT_TAR"   # -n: 타임스탬프/이름 미기록 → 재현성

RAW_SHA="$(sha256 "$RAW_TAR")"
GZ_SHA="$(sha256 "$OUT_TAR")"
printf '%s  %s\n' "$GZ_SHA" "cockpit-wsl.tar.gz" > "$OUT_TAR.sha256"

# ── provenance.json ────────────────────────────────────────────────
PLUGIN_COMMIT="$(git -C "$REPO_ROOT" rev-parse --short HEAD 2>/dev/null || echo unknown)"
BASE_DIGEST="$("$RUNTIME" image inspect "$BASE_IMAGE" --format '{{index .RepoDigests 0}}' 2>/dev/null || echo "$BASE_IMAGE")"
VERS_CONTENT="$(cat "$VERS_JSON" 2>/dev/null || echo '{}')"
case "$BASE_IMAGE" in *@sha256:*) BASE_PINNED=true ;; *) BASE_PINNED=false ;; esac
cat > "$OUTDIR/provenance.json" <<EOF
{
  "artifact": "cockpit-wsl.tar.gz",
  "distro_name": "$DISTRO_NAME",
  "base_image": "$BASE_IMAGE",
  "base_image_digest": "$BASE_DIGEST",
  "base_image_pinned": $BASE_PINNED,
  "plugin_commit": "$PLUGIN_COMMIT",
  "private_source_commit": "$PLUGIN_COMMIT",
  "public_marketplace_commit": "${COCKPIT_PLUGIN_COMMIT:-unset}",
  "plugin_preinstall_baked": $([ -n "$COCKPIT_PLUGIN_COMMIT" ] && echo true || echo false),
  "source_date_epoch": "${SOURCE_DATE_EPOCH:-unset}",
  "sha256_tar_gz": "$GZ_SHA",
  "sha256_tar_uncompressed": "$RAW_SHA",
  "builder": "build-rootfs.sh",
  "runtime": "$RUNTIME",
  "versions": $VERS_CONTENT,
  "sbom": "cockpit-wsl.sbom.spdx.json",
  "reproducibility": "베이스 digest 핀 + 버전 기록 수준(완전 bit-for-bit 아님). 남은 갭: apt 패키지(snapshot.ubuntu.com 미고정)와 npm 'claude-code'(레지스트리 latest) 모두 floating → 빌드 시점 따라 패치 버전 변동 가능. 위 versions(node/npm/claude/apt)로 실제 설치본 추적.",
  "note": "SBOM(표준 SPDX)·Authenticode 서명은 CI(단계5)에서 gen-sbom.sh·서명 단계가 첨부."
}
EOF

log "완료:"
log "  이미지     : $OUT_TAR"
log "  SHA-256    : $GZ_SHA"
log "  체크섬파일 : $OUT_TAR.sha256"
log "  provenance : $OUTDIR/provenance.json"
log ""
log ""
log "다음 단계(CI golden-build 가 자동 수행):"
log "  1) scripts/gen-sbom.sh $OUT_TAR   → SBOM(표준 SPDX/폴백)"
log "  2) scripts/smoke-image.sh $OUT_TAR → 불변식 스모크(위험기능 OFF·시크릿 0·구조)"
log "  3) 이 SHA-256 을 \$PinnedSha256 / 웹 다운로드 표에 치환 → scripts/publish-gate.sh 통과 → 서명 채널 게시."
