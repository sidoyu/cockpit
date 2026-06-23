#!/usr/bin/env bash
# secret-scan.sh — 발행 전 시크릿·개인정보 스캔. git-tracked 파일만 검사.
# 종료코드: 0=깨끗 / 1=치명(시크릿·개인정보) / (warn 은 보고만, 비차단)
#
# 설계: 훅 코드·deny-list 는 시크릿 '패턴'(정규식)을 정당하게 포함한다.
# 그래서 리터럴 키 스캔은 '접두 뒤에 실제 값 문자가 오는' 경우만 매칭한다
# (실제 키 = sk-ant-api03-<실제값>; 정규식 = sk-ant-api03-[A-Za-z...] → '[' 라서 미매칭).
set -u
cd "$(dirname "$0")/.." || exit 2
ROOT="$(pwd)"
SELF="scripts/secret-scan.sh"   # 스캐너 자신은 패턴을 포함하므로 개인정보 스캔 제외
fail=0

# tracked 파일(스캐너 자신 제외). git 없으면 find 폴백. bash 3.2 호환(mapfile 미사용).
FILES=()
if git rev-parse --git-dir >/dev/null 2>&1; then
  while IFS= read -r line; do [ -n "$line" ] && FILES+=("$line"); done < <(git ls-files | grep -v "^$SELF$")
else
  while IFS= read -r line; do [ -n "$line" ] && FILES+=("${line#./}"); done < <(find . -type f -not -path './.git/*' -not -path "./$SELF")
fi

# PUBLISH 모드(발행 게이트용): 발행 트리만 검사 = git archive 가 내보낼 파일만.
# .gitattributes 의 export-ignore 를 단일 출처로 읽어 docs/ 등 빌드-내부 문서를 제외한다.
# (전체 트리 스캔은 기본 모드 — 배포자가 docs 식별자까지 육안 점검하는 용도로 유지.)
if [ "${PUBLISH:-0}" = "1" ]; then
  if ! git rev-parse --git-dir >/dev/null 2>&1; then
    echo "[secret-scan][FATAL] PUBLISH 모드는 git 이 필요합니다(발행 트리 = export-ignore 기준)." >&2
    exit 2
  fi
  PUBFILES=()
  while IFS= read -r line; do
    # 형식: '<path>: export-ignore: set|unspecified|unset' — 'set' 만 발행 제외.
    case "$line" in
      *": export-ignore: set") : ;;
      *": export-ignore: "*)
        p="${line%: export-ignore: *}"
        [ -n "$p" ] && PUBFILES+=("$p")
        ;;
    esac
  done < <(printf '%s\n' "${FILES[@]}" | git check-attr --stdin export-ignore)
  FILES=("${PUBFILES[@]}")
  echo "[secret-scan] PUBLISH 모드 — 발행 트리(export-ignore 제외) 한정 검사."
fi

echo "[secret-scan] ${#FILES[@]} 파일 검사 (스캐너 자신 제외)"

scan() { # label, regex(grep -E), tier(FAIL|WARN), [ci]
  local label="$1" rx="$2" tier="$3" ci="${4:-}"
  local hits flags="-nEI"
  [ "$ci" = "ci" ] && flags="-niEI"
  hits="$(grep $flags "$rx" "${FILES[@]}" 2>/dev/null)"
  if [ -n "$hits" ]; then
    echo ""
    echo "  [$tier] $label:"
    echo "$hits" | sed 's/^/    /' | head -20
    [ "$tier" = "FAIL" ] && fail=1
  fi
}

# ── Tier 1: 개인정보·개인 경로 (어떤 것도 있으면 안 됨) ──
scan "개인 프로젝트 경로(-Users-...)" '\-Users\-[a-z]+' FAIL
# 'sidoyu' = 발행 게시자의 공개 핸들(공개 repo sidoyu/cockpit·author). 발행 결정(2026-06)으로 의도된 공개 값이라 허용.
# 'dyshin'(업무계정 dyshin-maria 포함)·'iamsdy'(개인 이메일 local-part)는 비공개·업무 식별자라 계속 FAIL 차단.
scan "개인 식별자(dyshin/iamsdy)" '\b(dyshin|iamsdy)\b' FAIL
scan "사내명(maria/마리아)" '(\bmaria\b|마리아|maria-baby)' FAIL
scan "개인 Tailscale IP" '\b100\.(80|73)\.[0-9]{1,3}\.[0-9]{1,3}\b' FAIL
scan "개인 이메일" '[a-zA-Z0-9._%+-]+@(gmail|naver|kakao)\.[a-z]+' FAIL
scan "claude-logs/maria-ops 개인 경로" '(claude-logs/summaries|maria-ops-archive)' FAIL

# ── Tier 2: 리터럴 API 키/시크릿 (접두 뒤 실제 값) ──
scan "Anthropic key" 'sk-ant-(api03-)?[A-Za-z0-9_-]{24,}' FAIL
scan "OpenAI project key" 'sk-proj-[A-Za-z0-9_-]{24,}' FAIL
scan "OpenAI legacy key" 'sk-[A-Za-z0-9]{32,}' FAIL
scan "GitHub token" 'gh[pousr]_[A-Za-z0-9]{30,}' FAIL
scan "AWS access key" 'AKIA[A-Z0-9]{16}' FAIL
scan "Google API key" 'AIza[A-Za-z0-9_-]{30,}' FAIL
scan "Slack token" 'xox[baprs]-[A-Za-z0-9-]{12,}' FAIL
scan "Replicate/xAI key" '\b(r8_[A-Za-z0-9]{30,}|xai-[A-Za-z0-9]{20,})\b' FAIL
scan "JWT" '\beyJ[A-Za-z0-9_-]{20,}\.[A-Za-z0-9_-]{20,}' FAIL
scan "Private key block" 'BEGIN (RSA |EC |OPENSSH )?PRIVATE KEY' FAIL
scan "리터럴 UUID(세션/헬스체크 잔존)" '\b[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\b' FAIL

# ── Tier 3: 라벨드 시크릿 추정 (warn — 육안 확인) ──
scan "label=value 시크릿 추정" '(password|passwd|api[_-]?key|secret|token)["'\'' ]*[=:]["'\'' ]*[A-Za-z0-9_/+=-]{16,}' WARN ci

# ── 커밋된 .env ──
ENVS="$(printf '%s\n' "${FILES[@]}" | grep -E '(^|/)\.env($|\.)' )"
if [ -n "$ENVS" ]; then echo ""; echo "  [FAIL] 커밋된 .env 파일:"; echo "$ENVS" | sed 's/^/    /'; fail=1; fi

echo ""
if [ "$fail" -eq 0 ]; then
  echo "[secret-scan] ✓ 통과 — 치명(시크릿·개인정보) 0건. (위 WARN 있으면 육안 확인)"
else
  echo "[secret-scan] ✗ 실패 — 위 FAIL 항목을 제거 후 재실행."
fi
exit $fail
