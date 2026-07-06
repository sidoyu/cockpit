#!/usr/bin/env bash
# pin-freshness.sh — 핀 노후화 리포트 (유지보수자 전용 · report-only · exit 0 고정)
#
# 배포판은 회원 쪽 업데이트 감시를 두지 않는 대신(격차표 G8: 이미지 버전 핀이 역할 대체),
# 유지보수자가 "핀이 낡았는가 = 새 릴리스를 준비할 때인가"를 이 스크립트로 점검한다.
# 릴리스 착수 시 1회 실행 권장(RELEASE runbook "모든 릴리스 공통 추가 단계" §3).
#
# 원칙:
#   - report-only: 아무것도 변경하지 않고 종료코드 항상 0(발행 차단은 publish-gate 의 몫).
#   - 네트워크는 best-effort: 오프라인/차단이면 해당 항목만 "확인 불가"로 표시하고 계속.
#   - 회원 배포물 아님: 이 스크립트는 저장소 유지보수 도구다(이미지·플러그인에 미포함).
set -u
cd "$(cd "$(dirname "$0")/.." && pwd)"

say()  { printf '%s\n' "$*"; }
item() { printf '  %-14s %s\n' "$1" "$2"; }

CURL="curl -fsS --max-time 10"
MANIFEST=windows/bootstrap/manifest.json
BASEIMG_FILE=windows/golden/base-image.txt

say "=== cockpit 핀 신선도 리포트 ($(date '+%Y-%m-%d %H:%M')) ==="

# ── 1) Claude Code 핀 vs npm 최신 ─────────────────────────────────────────
PINNED_CC=""
if [ -f "$MANIFEST" ] && command -v jq >/dev/null 2>&1; then
  PINNED_CC="$(jq -r '.provenance.claude_code_pin // empty' "$MANIFEST" 2>/dev/null)"
fi
[ -n "$PINNED_CC" ] || PINNED_CC="$(grep -o '"claude_code_pin"[^,}]*' "$MANIFEST" 2>/dev/null | grep -o '[0-9][0-9.]*' | head -1)"
LATEST_CC="$($CURL https://registry.npmjs.org/@anthropic-ai/claude-code/latest 2>/dev/null | grep -o '"version":"[^"]*"' | head -1 | cut -d'"' -f4)"
say ""
say "1) Claude Code (@anthropic-ai/claude-code)"
item "핀(이미지)" "${PINNED_CC:-확인 불가(manifest 없음)}"
if [ -n "$LATEST_CC" ]; then
  item "npm 최신" "$LATEST_CC"
  if [ -n "$PINNED_CC" ] && [ "$PINNED_CC" != "$LATEST_CC" ]; then
    item "판정" "⚠ 핀이 최신과 다름 — 변경 규모는 upstream CHANGELOG 확인 후 릴리스 범위 결정"
  else
    item "판정" "핀 = 최신"
  fi
else
  item "npm 최신" "확인 불가(오프라인/차단) — 수동: npm view @anthropic-ai/claude-code version"
fi

# ── 2) 마지막 재핀(=릴리스 준비) 경과일 ───────────────────────────────────
say ""
say "2) 마지막 재핀 경과"
if command -v git >/dev/null 2>&1 && [ -f "$MANIFEST" ]; then
  LAST_TS="$(git log -1 --format=%ct -- "$MANIFEST" 2>/dev/null)"
  if [ -n "$LAST_TS" ]; then
    NOW_TS="$(date +%s)"
    DAYS=$(( (NOW_TS - LAST_TS) / 86400 ))
    item "manifest 갱신" "$(git log -1 --format=%cd --date=format:%Y-%m-%d -- "$MANIFEST") (${DAYS}일 전)"
    if [ "$DAYS" -ge 90 ]; then item "판정" "⚠ 90일 이상 경과 — 보안 패치 누적 가능성, 재빌드 검토 권장"
    elif [ "$DAYS" -ge 45 ]; then item "판정" "참고: 45일 이상 경과"
    else item "판정" "최근 재핀"
    fi
  else
    item "manifest 갱신" "git 이력 없음"
  fi
else
  item "manifest 갱신" "확인 불가(git/manifest 없음)"
fi

# ── 3) 베이스 이미지 digest vs Docker Hub 현재 태그 ───────────────────────
say ""
say "3) 베이스 이미지 (ubuntu:24.04 digest 핀)"
PIN_LINE="$(grep -E '^[a-z0-9.:/-]+@sha256:[0-9a-f]{64}$' "$BASEIMG_FILE" 2>/dev/null | tail -1)"
PIN_DIGEST="${PIN_LINE##*@}"
item "핀(digest)" "${PIN_DIGEST:-확인 불가(base-image.txt 핀 없음)}"
HUB_DIGEST="$($CURL 'https://hub.docker.com/v2/repositories/library/ubuntu/tags/24.04' 2>/dev/null | grep -o '"digest":"sha256:[0-9a-f]*"' | head -1 | cut -d'"' -f4)"
if [ -n "$HUB_DIGEST" ]; then
  item "Hub 현재" "$HUB_DIGEST"
  if [ -n "$PIN_DIGEST" ] && [ "$PIN_DIGEST" != "$HUB_DIGEST" ]; then
    item "판정" "⚠ 태그의 현재 digest 와 다름(베이스 이미지 업데이트 있었음) — 다음 재빌드 시 base-image.txt 재핀"
  else
    item "판정" "핀 = 현재 태그 digest"
  fi
else
  item "Hub 현재" "확인 불가(오프라인/차단) — 수동: docker pull ubuntu:24.04 && docker inspect"
fi

say ""
say "판단·릴리스 결정은 사람 몫(이 리포트는 사실만). 재빌드 절차 = docs/RELEASE-v0.1.3-runbook.md"
exit 0
