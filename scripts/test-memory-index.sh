#!/usr/bin/env bash
# test-memory-index.sh — rebuild_memory_index.py 내성/규율 회귀 테스트(격리 픽스처).
#
# 왜: `autoMemoryDirectory` 로 cc-memory 를 Claude Code 내장 auto memory 위치로 지정하면
# **하네스가 같은 디렉터리에 직접 파일·색인 줄을 쓴다.** 그 산출물이 cockpit 의 엄격한 색인
# 규약과 어긋날 때 생성기가 hard-fail 하면(훅은 fail-soft) 색인이 조용히 언다.
# 이 테스트는 ①관용 흡수 ②규율(--strict) 보존 ③치명 lint(시크릿) 불변 ④멱등성을 고정한다.
#
# 실행: bash scripts/test-memory-index.sh   (exit 0 = 전부 통과)
set -u

HERE="$(cd "$(dirname "$0")" && pwd)"
REBUILD="$HERE/../plugin/hooks/memory/rebuild_memory_index.py"
PASS=0; FAIL=0
SENTINEL='<!-- MEMORY_INDEX_END · 자동 생성(rebuild_memory_index.py) · 직접 편집 금지 -->'

ok()   { PASS=$((PASS+1)); printf '  ✓ %s\n' "$1"; }
bad()  { FAIL=$((FAIL+1)); printf '  ✗ %s\n' "$1"; [ $# -gt 1 ] && printf '      %s\n' "$2"; }

# 격리 픽스처 하나 생성 → echo 로 디렉터리 반환
mkfix() {
  local d; d="$(mktemp -d)"
  mkdir -p "$d/mem" "$d/state"
  cat > "$d/mem/PROJECT_STATUS.md" <<'EOF'
# PROJECT_STATUS — 현재 권위 상태
(본문)
EOF
  echo "$d"
}

run() {  # run <fixdir> <args...> ; stdout+stderr → $OUT, rc → $RC
  local d="$1"; shift
  OUT="$(CC_MEMORY_DIR="$d/mem" CC_STATE_DIR="$d/state" python3 "$REBUILD" "$@" 2>&1)"
  RC=$?
}

idx() { cat "$1/mem/MEMORY.md"; }

echo "== rebuild_memory_index 내성 테스트 =="

# ── T1: 표준 색인 + 정상 frontmatter → 멱등(변경 없음) ────────────────────────
D="$(mkfix)"
cat > "$D/mem/user_profile.md" <<'EOF'
---
name: user_profile
description: "테스트 사용자"
---
본문
EOF
printf '%s\n%s\n%s\n' \
  '- [PROJECT_STATUS.md](PROJECT_STATUS.md) — 현재 권위 상태' \
  '- [user_profile.md](user_profile.md) — 테스트 사용자' \
  "$SENTINEL" > "$D/mem/MEMORY.md"
run "$D" --check
[ "$RC" = "0" ] && ok "T1 표준 색인 = 드리프트 없음" || bad "T1 표준 색인" "$OUT"
rm -rf "$D"

# ── T2: 하네스형 색인 줄(라벨≠타겟) → fail 하지 않고 정규화 ──────────────────
D="$(mkfix)"
cat > "$D/mem/debugging.md" <<'EOF'
---
name: debugging
description: "빌드 디버깅 요령"
---
본문
EOF
printf '%s\n%s\n%s\n' \
  '- [PROJECT_STATUS.md](PROJECT_STATUS.md) — 현재 권위 상태' \
  '- [Debugging Notes](debugging.md) — 빌드 디버깅 요령' \
  "$SENTINEL" > "$D/mem/MEMORY.md"
run "$D" --apply --no-diff
if [ "$RC" = "0" ] && idx "$D" | grep -q '^- \[debugging.md\](debugging.md) — 빌드 디버깅 요령$'; then
  ok "T2 라벨≠타겟 → 표준형으로 정규화(색인 안 얼음)"
else bad "T2 라벨≠타겟 정규화" "rc=$RC $OUT"; fi
rm -rf "$D"

# ── T3: 구분자 ':' 하네스 변형 → 흡수 ────────────────────────────────────────
D="$(mkfix)"
cat > "$D/mem/api.md" <<'EOF'
---
name: api
description: "API 관례"
---
본문
EOF
printf '%s\n%s\n%s\n' \
  '- [PROJECT_STATUS.md](PROJECT_STATUS.md) — 현재 권위 상태' \
  '- [api.md](api.md): API 관례' \
  "$SENTINEL" > "$D/mem/MEMORY.md"
run "$D" --apply --no-diff
if [ "$RC" = "0" ] && idx "$D" | grep -q '^- \[api.md\](api.md) — API 관례$'; then
  ok "T3 구분자 ':' 흡수"
else bad "T3 구분자 흡수" "rc=$RC $OUT"; fi
rm -rf "$D"

# ── T4: description 없는 하네스 토픽 파일 → 본문에서 도출, 전체 실패 안 함 ────
D="$(mkfix)"
cat > "$D/mem/notes.md" <<'EOF'
# 배포 절차 메모
첫 줄 본문
EOF
printf '%s\n%s\n' '- [PROJECT_STATUS.md](PROJECT_STATUS.md) — 현재 권위 상태' "$SENTINEL" > "$D/mem/MEMORY.md"
run "$D" --apply --no-diff
if [ "$RC" = "0" ] && idx "$D" | grep -q '^- \[notes.md\](notes.md) — 배포 절차 메모$'; then
  ok "T4 description 부재 → 첫 헤딩에서 도출(생성기 계속 진행)"
else bad "T4 description 도출" "rc=$RC $OUT"; fi
# ── T5: 같은 픽스처에 --strict → 규율 보존(치명) ─────────────────────────────
run "$D" --check --strict
[ "$RC" = "2" ] && ok "T5 --strict 는 옛 동작(exit 2) 보존" || bad "T5 --strict 치명" "rc=$RC $OUT"
rm -rf "$D"

# ── T6: 본문 없는 파일 2개 → NO_DESC 충돌을 유일화(unique lint 회피) ──────────
D="$(mkfix)"
printf -- '---\nname: a\n---\n' > "$D/mem/a.md"
printf -- '---\nname: b\n---\n' > "$D/mem/b.md"
printf '%s\n%s\n' '- [PROJECT_STATUS.md](PROJECT_STATUS.md) — 현재 권위 상태' "$SENTINEL" > "$D/mem/MEMORY.md"
run "$D" --apply --no-diff
if [ "$RC" = "0" ] && [ "$(idx "$D" | grep -c '설명 미작성')" = "2" ] \
   && idx "$D" | grep -q '설명 미작성) \[b\]$'; then
  ok "T6 파생 설명 충돌 → 결정적 유일화"
else bad "T6 파생 유일화" "rc=$RC $OUT
$(idx "$D")"; fi
rm -rf "$D"

# ── T7: PROJECT_STATUS 색인 줄 소실(하네스 재기입) → 기본 hook 복구 ──────────
D="$(mkfix)"
printf '%s\n' "$SENTINEL" > "$D/mem/MEMORY.md"
run "$D" --apply --no-diff
if [ "$RC" = "0" ] && idx "$D" | grep -q '^- \[PROJECT_STATUS.md\](PROJECT_STATUS.md) — 현재 권위 상태'; then
  ok "T7 PINNED 색인 줄 소실 → 기본 hook 복구"
else bad "T7 PINNED 복구" "rc=$RC $OUT"; fi
rm -rf "$D"

# ── T8: 시크릿 lint 는 여전히 치명(관용이 보안을 약화시키지 않음) ─────────────
# 가짜 키는 **런타임 조립**한다 — 발행 트리(scripts/ 포함)에 키처럼 보이는 리터럴을 남기지 않기 위해.
D="$(mkfix)"
FAKEKEY="sk-$(head -c 24 /dev/zero | tr '\0' 'a')"
cat > "$D/mem/leak.md" <<EOF
---
name: leak
description: "키는 $FAKEKEY 이다"
---
본문
EOF
printf '%s\n%s\n' '- [PROJECT_STATUS.md](PROJECT_STATUS.md) — 현재 권위 상태' "$SENTINEL" > "$D/mem/MEMORY.md"
run "$D" --check
if [ "$RC" = "2" ] && echo "$OUT" | grep -q "SECRET lint"; then
  ok "T8 시크릿 lint 치명 유지(관용 모드에서도)"
else bad "T8 시크릿 lint" "rc=$RC $OUT"; fi
rm -rf "$D"

# ── T9: 멱등성 — apply 두 번 → 두 번째는 '변경 없음' ────────────────────────
D="$(mkfix)"
cat > "$D/mem/x.md" <<'EOF'
# 그냥 메모
EOF
printf '%s\n%s\n' '- [PROJECT_STATUS.md](PROJECT_STATUS.md) — 현재 권위 상태' "$SENTINEL" > "$D/mem/MEMORY.md"
run "$D" --apply --no-diff
FIRST="$(idx "$D")"
run "$D" --apply --no-diff
if [ "$RC" = "0" ] && echo "$OUT" | grep -q "변경 없음" && [ "$FIRST" = "$(idx "$D")" ]; then
  ok "T9 멱등(도출 hook 도 안정)"
else bad "T9 멱등" "rc=$RC $OUT"; fi
rm -rf "$D"

# ── T10: 파싱 불가한 항목-유사 줄 → 색인에서 제외하되 파일은 재색인(유실 0) ──
D="$(mkfix)"
cat > "$D/mem/keep.md" <<'EOF'
---
name: keep
description: "보존되어야 함"
---
본문
EOF
printf '%s\n%s\n%s\n' \
  '- [PROJECT_STATUS.md](PROJECT_STATUS.md) — 현재 권위 상태' \
  '- [깨진줄(keep.md — 설명' \
  "$SENTINEL" > "$D/mem/MEMORY.md"
run "$D" --apply --no-diff
if [ "$RC" = "0" ] && idx "$D" | grep -q '^- \[keep.md\](keep.md) — 보존되어야 함$'; then
  ok "T10 깨진 색인 줄 → 파일에서 재생성(유실 없음)"
else bad "T10 깨진 줄 복구" "rc=$RC $OUT"; fi
rm -rf "$D"

# ── T11: 공백 있는 합법 표준 색인 줄 → 관용화가 회귀시키지 않는다(hook 보존) ─
D="$(mkfix)"
cat > "$D/mem/my file.md" <<'EOF'
---
name: my file
description: "공백 파일명"
---
본문
EOF
printf '%s\n%s\n%s\n' \
  '- [PROJECT_STATUS.md](PROJECT_STATUS.md) — 현재 권위 상태' \
  '- [my file.md](my file.md) — 공백 파일명' \
  "$SENTINEL" > "$D/mem/MEMORY.md"
run "$D" --check
[ "$RC" = "0" ] && ok "T11 공백 파일명 표준 줄 = 드리프트 없음(ENTRY_RE 우선)" \
                || bad "T11 공백 파일명" "rc=$RC $OUT"
rm -rf "$D"

# ── T12: 헤딩 없는 파일 → 본문 승격 안 함(NO_DESC) ──────────────────────────
D="$(mkfix)"
printf '환자 김OO 연락처 010-1234-5678 관련 메모\n' > "$D/mem/nohead.md"
printf '%s\n%s\n' '- [PROJECT_STATUS.md](PROJECT_STATUS.md) — 현재 권위 상태' "$SENTINEL" > "$D/mem/MEMORY.md"
run "$D" --apply --no-diff
if [ "$RC" = "0" ] && idx "$D" | grep -q 'nohead.md) — (설명 미작성)' \
   && ! idx "$D" | grep -q '010-1234-5678'; then
  ok "T12 헤딩 없는 본문은 색인(=매 세션 로드)으로 승격되지 않음"
else bad "T12 본문 미승격" "rc=$RC
$(idx "$D")"; fi
rm -rf "$D"

# ── T13: 민감해 보이는 헤딩 → 자리표시자로 물러섬(색인도 안 얼음) ───────────
D="$(mkfix)"
printf '# 주민번호 900101-1234567 정리\n본문\n' > "$D/mem/sens.md"
printf '%s\n%s\n' '- [PROJECT_STATUS.md](PROJECT_STATUS.md) — 현재 권위 상태' "$SENTINEL" > "$D/mem/MEMORY.md"
run "$D" --apply --no-diff
if [ "$RC" = "0" ] && ! idx "$D" | grep -q '900101' && idx "$D" | grep -q 'sens.md) — (설명 미작성)'; then
  ok "T13 민감 헤딩 → 자리표시자(색인 미오염·미동결)"
else bad "T13 민감 헤딩" "rc=$RC
$(idx "$D")"; fi
rm -rf "$D"

echo
echo "== 결과: PASS=$PASS FAIL=$FAIL =="
[ "$FAIL" -eq 0 ] || exit 1
