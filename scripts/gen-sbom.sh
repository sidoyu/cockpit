#!/usr/bin/env bash
# gen-sbom.sh — 골든 이미지 SBOM(소프트웨어 부품표) 생성(단계5).
#
# 무엇을: rootfs 안에 무엇이 설치됐는지 목록을 낸다(공급망 감사·취약점 추적·재현성 보강).
# 어떻게: syft 가 있으면 표준 SPDX(JSON)로, 없으면 dpkg DB + build-versions.json 으로
#         '폴백' 목록을 낸다(SPDX 라고 주장하지 않음 — 정직하게 별도 포맷 라벨).
#
# 사용:
#   scripts/gen-sbom.sh <rootfs_dir | image.tar.gz> [OUT]
#   기본 OUT: 입력 옆 cockpit-wsl.sbom.spdx.json(syft) / cockpit-wsl.sbom.fallback.json(폴백)
#
# 종료코드: 0=생성 성공 / 2=실행 오류
set -u
IN="${1:-}"
[ -n "$IN" ] || { echo "사용: $0 <rootfs_dir | image.tar.gz> [OUT]"; exit 2; }

WORK=""
cleanup() { [ -n "$WORK" ] && rm -rf "$WORK"; }
trap cleanup EXIT

# 입력 정규화 → ROOTFS 디렉터리
if [ -d "$IN" ]; then
  ROOTFS="$IN"; OUTDIR="$(cd "$IN" && pwd)/.."
elif [ -f "$IN" ]; then
  WORK="$(mktemp -d)"; tar -xzf "$IN" -C "$WORK" 2>/dev/null || { echo "[gen-sbom][FATAL] tar 추출 실패: $IN"; exit 2; }
  ROOTFS="$WORK"; OUTDIR="$(cd "$(dirname "$IN")" && pwd)"
else
  echo "[gen-sbom][FATAL] 입력이 파일도 디렉터리도 아님: $IN"; exit 2
fi

# ── syft 경로(표준 SPDX) ──────────────────────────────────────────
if command -v syft >/dev/null 2>&1; then
  OUT="${2:-$OUTDIR/cockpit-wsl.sbom.spdx.json}"
  echo "[gen-sbom] syft 발견 — 표준 SPDX 생성: $OUT"
  if syft "dir:$ROOTFS" -o spdx-json > "$OUT" 2>/dev/null; then
    n=$(grep -c '"SPDXID"' "$OUT" 2>/dev/null || echo "?")
    echo "[gen-sbom] ✓ SPDX SBOM 생성(패키지 SPDXID ${n}개): $OUT"
    exit 0
  else
    echo "[gen-sbom][warn] syft 실패 — 폴백으로 전환."
  fi
fi

# ── 폴백 경로(dpkg DB + build-versions.json) ──────────────────────
OUT="${2:-$OUTDIR/cockpit-wsl.sbom.fallback.json}"
echo "[gen-sbom] syft 없음 — 폴백 SBOM 생성(표준 SPDX 아님): $OUT"

# build-versions.json(provision 이 기록 — 핵심 도구 버전)
BV="$ROOTFS/opt/cockpit/build-versions.json"
bv_content="null"
[ -f "$BV" ] && bv_content="$(cat "$BV")"

# dpkg 설치 패키지(이미지에 status DB 보존됨 — apt lists 만 지움)
DPKG="$ROOTFS/var/lib/dpkg/status"
pkgs_json="[]"
if [ -f "$DPKG" ]; then
  # Package/Version 쌍 추출 → JSON 배열. awk 로 stanza 파싱.
  pkgs_json="$(awk '
    /^Package:/ { p=$2 }
    /^Version:/ { v=$2; if (p!="") { printf "%s{\"name\":\"%s\",\"version\":\"%s\"}", (c++? ",":""), p, v; p="" } }
    END { }
  ' "$DPKG")"
  pkgs_json="[${pkgs_json}]"
fi
pkgcount=$(printf '%s' "$pkgs_json" | grep -o '"name"' | wc -l | tr -d ' ')

# SOURCE_DATE_EPOCH(있으면 provenance 와 일치)
sde="${SOURCE_DATE_EPOCH:-unset}"

cat > "$OUT" <<EOF
{
  "_format": "cc-companion/sbom-fallback/1",
  "_note": "syft 미설치 폴백. 표준 SPDX 아님(공급망 도구 호환 X). 발행 빌드는 CI 에 syft 설치해 표준 SPDX 권장.",
  "generated_from": "rootfs dpkg DB + build-versions.json",
  "source_date_epoch": "$sde",
  "tool_versions": $bv_content,
  "dpkg_package_count": $pkgcount,
  "dpkg_packages": $pkgs_json
}
EOF

if command -v jq >/dev/null 2>&1; then
  jq empty "$OUT" 2>/dev/null && echo "[gen-sbom] ✓ 폴백 SBOM(JSON 유효, dpkg ${pkgcount}개): $OUT" || { echo "[gen-sbom][FATAL] 폴백 SBOM JSON 무효"; exit 2; }
else
  echo "[gen-sbom] ✓ 폴백 SBOM 생성(dpkg ${pkgcount}개, jq 없어 유효성 미검증): $OUT"
fi
exit 0
