#!/usr/bin/env bash
# test-import-existing.sh — 기존 기억 이관(import_existing.py) 종단 회귀 테스트(격리 픽스처).
#
# 데이터를 다루는 기능이라 불변식을 기계로 고정한다:
#   ① 소스 무접촉(읽기 전용)  ② dry-run 은 대상 무변경  ③ 삭제 0 · 덮어쓰기 0
#   ④ 저장소별 동명 파일 충돌 해소  ⑤ 색인 재생성 통과  ⑥ 트랜스크립트/자격증명 미복사
#   ⑦ cockpit 운영키(플러그인 활성) 보존 · 회원 model/effort 존중  ⑧ 재실행 멱등
#
# 실행: bash scripts/test-import-existing.sh   (exit 0 = 전부 통과)
set -u

HERE="$(cd "$(dirname "$0")" && pwd)"
IMP="$HERE/../plugin/skills/setup-wizard/import_existing.py"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); printf '  ✓ %s\n' "$1"; }
bad() { FAIL=$((FAIL+1)); printf '  ✗ %s\n' "$1"; [ $# -gt 1 ] && printf '      %s\n' "$2"; }

ROOT="$(mktemp -d)"
trap 'rm -rf "$ROOT"' EXIT
SRC="$ROOT/win/.claude"        # 회원의 기존 환경(바닐라 Windows 사용자 모양)
DST="$ROOT/cockpit"            # cockpit HOME

# ── 소스 픽스처: 저장소 2개에 동명 memory 파일 + 자산 + 자격증명/트랜스크립트(복사 금지 대상) ──
mkdir -p "$SRC/projects/-c-Users-PC-repo-alpha/memory" \
         "$SRC/projects/-c-Users-PC-repo-beta/memory" \
         "$SRC/commands" "$SRC/skills/mine" "$SRC/rules"
cat > "$SRC/projects/-c-Users-PC-repo-alpha/memory/debugging.md" <<'EOF'
---
name: debugging
description: "alpha 저장소 디버깅 요령"
---
alpha 본문
EOF
cat > "$SRC/projects/-c-Users-PC-repo-beta/memory/debugging.md" <<'EOF'
# beta 디버깅 노트
프론트엔드 빌드가 느릴 때
EOF
cat > "$SRC/projects/-c-Users-PC-repo-alpha/memory/MEMORY.md" <<'EOF'
- [Debugging](debugging.md) — alpha 저장소 디버깅 요령
EOF
printf 'JSONL_TRANSCRIPT_SHOULD_NEVER_BE_COPIED\n' > "$SRC/projects/-c-Users-PC-repo-alpha/aaa.jsonl"
printf '{"oauthAccount":"SHOULD_NEVER_BE_COPIED"}\n' > "$SRC/.credentials.json"
printf 'CLAUDE.md 개인 규칙\n\nAlways respond in English.\n' > "$SRC/CLAUDE.md"
printf '/mycmd 도움말\n' > "$SRC/commands/mycmd.md"
printf '# my skill\n' > "$SRC/skills/mine/SKILL.md"
printf '# 개인 규칙\n' > "$SRC/rules/pref.md"
cat > "$SRC/settings.json" <<'EOF'
{
  "model": "claude-sonnet-5",
  "effortLevel": "medium",
  "theme": "dark",
  "hooks": { "SessionStart": [{"hooks":[{"command":"powershell.exe -File C:\\x.ps1"}]}] },
  "permissions": { "allow": ["Bash(rm:*)"], "deny": ["Read(./secrets/**)"], "defaultMode": "acceptEdits" },
  "someUnknownKey": 1
}
EOF
printf '{"mcpServers":{"foo":{"command":"npx"}}}\n' > "$ROOT/win/.claude.json"
SRC_SHA_BEFORE="$(find "$SRC" -type f -exec shasum {} \; | sort | shasum | awk '{print $1}')"

# ── 대상 픽스처: 갓 설치된 cockpit ──
mkdir -p "$DST/.claude/cc-memory" "$DST/.claude/cc-companion"
printf '# PROJECT_STATUS\n본문\n' > "$DST/.claude/cc-memory/PROJECT_STATUS.md"
printf -- '- [PROJECT_STATUS.md](PROJECT_STATUS.md) — 현재 권위 상태\n<!-- MEMORY_INDEX_END · 자동 생성(rebuild_memory_index.py) · 직접 편집 금지 -->\n' \
  > "$DST/.claude/cc-memory/MEMORY.md"
printf '# cockpit 행동 규율\n' > "$DST/.claude/CLAUDE.md"
cat > "$DST/.claude/settings.json" <<'EOF'
{
  "effortLevel": "xhigh",
  "model": "claude-opus-4-8[1m]",
  "autoMemoryDirectory": "~/.claude/cc-memory",
  "enabledPlugins": { "cockpit@cc-companion": true },
  "extraKnownMarketplaces": { "cc-companion": { "source": {"source":"git","url":"https://example.invalid"} } },
  "permissions": { "defaultMode": "bypassPermissions" },
  "skipDangerousModePermissionPrompt": true,
  "remoteControlAtStartup": true
}
EOF

imp() { HOME="$DST" CC_MEMORY_DIR="$DST/.claude/cc-memory" CC_STATE_DIR="$DST/.claude/cc-companion" \
        CC_ARCHIVE_DIR="$DST/.claude/cc-memory-archive" python3 "$IMP" "$@" 2>&1; }

echo "== import_existing 종단 테스트 =="

# ── T1: dry-run 은 대상을 바꾸지 않는다 ──────────────────────────────────────
DST_SHA_BEFORE="$(find "$DST" -type f -exec shasum {} \; | sort | shasum | awk '{print $1}')"
OUT="$(imp plan --source "$SRC")"; RC=$?
if [ "$RC" = "0" ] && [ "$DST_SHA_BEFORE" = "$(find "$DST" -type f -exec shasum {} \; | sort | shasum | awk '{print $1}')" ]; then
  ok "T1 dry-run = 대상 무변경"
else bad "T1 dry-run 무변경" "rc=$RC"; fi

# ── T2: dry-run 이 위험·검토 항목을 표면화 ──────────────────────────────────
if echo "$OUT" | grep -q "언어 지시(영어)" && echo "$OUT" | grep -q "hooks(자동병합 안 함" \
   && echo "$OUT" | grep -q "MCP 서버" && echo "$OUT" | grep -q "credentials.json 은 복사하지 않습니다"; then
  ok "T2 dry-run 이 훅·MCP·자격증명·언어충돌을 명시"
else bad "T2 dry-run 표면화" "$OUT"; fi

# ── T3: apply ────────────────────────────────────────────────────────────────
OUT="$(imp apply --source "$SRC" --no-backup)"; RC=$?
[ "$RC" = "0" ] && ok "T3 apply 성공(rc=0)" || bad "T3 apply" "$OUT"

M="$DST/.claude/cc-memory"

# ── T4: 저장소별 동명 파일 충돌 해소 ────────────────────────────────────────
if [ -f "$M/debugging.md" ] && ls "$M" | grep -q '^repo-beta__debugging.md$'; then
  ok "T4 동명 파일 충돌 → 출처 prefix 로 분리"
else bad "T4 충돌 해소" "$(ls "$M")"; fi

# ── T5: 소스 MEMORY.md 는 색인으로 복사되지 않고 보관함으로 ─────────────────
if ! grep -q "alpha 저장소 디버깅 요령" "$M/MEMORY.md" 2>/dev/null || true; then :; fi
if [ ! -f "$M/MEMORY-1.md" ] && find "$DST/.claude/cc-memory-archive" -name 'MEMORY*.md' | grep -q . ; then
  ok "T5 원본 MEMORY.md = 보관함으로만(색인은 재생성)"
else bad "T5 MEMORY.md 격리" "$(find "$DST/.claude/cc-memory-archive" -type f)"; fi

# ── T6: 색인 재생성 통과 + 새 기억이 색인에 들어감 ──────────────────────────
if grep -q '^- \[debugging.md\](debugging.md) — alpha 저장소 디버깅 요령$' "$M/MEMORY.md" \
   && grep -q 'repo-beta__debugging.md' "$M/MEMORY.md"; then
  ok "T6 색인 재생성 — description 있는 것/도출한 것 모두 등재"
else bad "T6 색인" "$(cat "$M/MEMORY.md")"; fi

# ── T7: 트랜스크립트·자격증명 미복사 ────────────────────────────────────────
if ! find "$DST" -name '*.jsonl' | grep -q . && ! find "$DST" -name '.credentials.json' | grep -q . \
   && ! grep -rq "SHOULD_NEVER_BE_COPIED" "$DST" 2>/dev/null; then
  ok "T7 트랜스크립트·자격증명 미복사"
else bad "T7 미복사" "$(find "$DST" -name '*.jsonl' -o -name '.credentials.json')"; fi

# ── T8: settings — 운영키 보존 · 회원 model/effort 존중 · 훅 미흡수 ─────────
#      + **권한 확대 금지**: allow 는 병합 안 함(deny 는 병합 = 안전을 늘리는 방향)
S="$DST/.claude/settings.json"
V="$(python3 - "$S" <<'PY'
import json,sys
s=json.load(open(sys.argv[1]))
p=s.get("permissions",{})
print("plugins=%s owned_mode=%s model=%s effort=%s theme=%s hooks=%s allow=%s deny=%s unknown=%s" % (
  "cockpit@cc-companion" in s.get("enabledPlugins",{}), p.get("defaultMode"),
  s.get("model"), s.get("effortLevel"), s.get("theme"),
  "hooks" in s, p.get("allow"), p.get("deny"), "someUnknownKey" in s))
PY
)"
if echo "$V" | grep -q "plugins=True" && echo "$V" | grep -q "owned_mode=bypassPermissions" \
   && echo "$V" | grep -q "model=claude-sonnet-5" && echo "$V" | grep -q "effort=medium" \
   && echo "$V" | grep -q "theme=dark" && echo "$V" | grep -q "hooks=False" \
   && echo "$V" | grep -q "unknown=False" && echo "$V" | grep -q "allow=None" \
   && echo "$V" | grep -q "deny=\['Read(./secrets/\*\*)'\]"; then
  ok "T8 settings 딥머지(운영키 보존·회원값 존중·훅/미지키 미흡수·allow 미병합·deny 병합)"
else bad "T8 settings 병합" "$V"; fi

# ── T8b: allow 규칙은 plan 에 노출되고, 명시 플래그로만 병합된다 ────────────
OUT="$(imp plan --source "$SRC")"
if echo "$OUT" | grep -q "병합하지 않았습니다" && echo "$OUT" | grep -q "allow: Bash(rm:\*)"; then
  ok "T8b 권한 허용 규칙은 보고만(이관 ≠ 권한 확대)"
else bad "T8b allow 보고" "$OUT"; fi
OUT="$(imp apply --source "$SRC" --no-backup --accept-permissions-allow)"; RC=$?
if [ "$RC" = "0" ] && python3 -c "
import json,sys
s=json.load(open('$S'))
sys.exit(0 if 'Bash(rm:*)' in (s.get('permissions',{}).get('allow') or []) else 1)"; then
  ok "T8c --accept-permissions-allow 명시 시에만 병합"
else bad "T8c allow 명시 병합" "rc=$RC"; fi

# ── T9: CLAUDE.md 통합 — 원문 보존 + 마커 ───────────────────────────────────
if grep -q "COCKPIT:IMPORTED-CLAUDE-MD:BEGIN" "$DST/.claude/CLAUDE.md" \
   && grep -q "cockpit 행동 규율" "$DST/.claude/CLAUDE.md" \
   && grep -q "Always respond in English." "$DST/.claude/CLAUDE.md"; then
  ok "T9 CLAUDE.md 통합(cockpit 규칙 + 원문 보존 블록)"
else bad "T9 CLAUDE.md 통합" "$(cat "$DST/.claude/CLAUDE.md")"; fi

# ── T10: 개인자산 복사 ──────────────────────────────────────────────────────
if [ -f "$DST/.claude/commands/mycmd.md" ] && [ -f "$DST/.claude/skills/mine/SKILL.md" ] \
   && [ -f "$DST/.claude/rules/pref.md" ]; then
  ok "T10 개인자산(명령어·스킬·규칙) 이관"
else bad "T10 개인자산" "$(find "$DST/.claude" -maxdepth 2 -type d)"; fi

# ── T11: 소스 무접촉(읽기 전용) ─────────────────────────────────────────────
if [ "$SRC_SHA_BEFORE" = "$(find "$SRC" -type f -exec shasum {} \; | sort | shasum | awk '{print $1}')" ]; then
  ok "T11 소스 무접촉(읽기 전용)"
else bad "T11 소스 무접촉"; fi

# ── T12: 재실행 멱등 — 덮어쓰기 0, 중복 파일 0 ──────────────────────────────
N1="$(ls "$M" | wc -l | tr -d ' ')"
MD1="$(shasum "$DST/.claude/CLAUDE.md" | awk '{print $1}')"
OUT="$(imp apply --source "$SRC" --no-backup)"; RC=$?
N2="$(ls "$M" | wc -l | tr -d ' ')"
MD2="$(shasum "$DST/.claude/CLAUDE.md" | awk '{print $1}')"
if [ "$RC" = "0" ] && [ "$N1" = "$N2" ] && [ "$MD1" = "$MD2" ]; then
  ok "T12 재실행 멱등(기억 ${N1}개 유지 · CLAUDE.md 블록 교체만)"
else bad "T12 멱등" "rc=$RC n1=$N1 n2=$N2 md동일=$([ "$MD1" = "$MD2" ] && echo y || echo n)"; fi

# ── T13: 자기 자신을 소스로 지정하면 거부 ──────────────────────────────────
OUT="$(imp plan --source "$DST/.claude")"; RC=$?
if [ "$RC" = "2" ] && echo "$OUT" | grep -q "현재 환경 자신"; then
  ok "T13 자기 자신 소스 거부"
else bad "T13 자기 소스 거부" "rc=$RC $OUT"; fi

# ── T13b: 대소문자만 다른 동명 파일 → 색인 unique lint(치명) 회피 ───────────
# /mnt/c 는 대소문자 무시지만 대상 홈(ext4)은 구분한다. 경계를 넘으며 Debugging.md/debugging.md 가
# 나란히 놓이면 rebuild 의 unique lint(파일명 소문자 비교)가 색인을 얼려버린다.
CASESRC="$ROOT/case/.claude"
mkdir -p "$CASESRC/projects/-repo-gamma/memory"
cat > "$CASESRC/projects/-repo-gamma/memory/Debugging.md" <<'EOF'
---
name: Debugging
description: "대문자 D 로 시작하는 동명 파일"
---
본문
EOF
printf '{}\n' > "$CASESRC/settings.json"
OUT="$(imp apply --source "$CASESRC" --no-backup)"; RC=$?
LOWER_COUNT="$(ls "$M" | tr 'A-Z' 'a-z' | sort | uniq -d | wc -l | tr -d ' ')"
if [ "$RC" = "0" ] && [ "$LOWER_COUNT" = "0" ] && python3 -c "import sys;sys.exit(0)"; then
  ok "T13b 대소문자만 다른 파일명 충돌 회피(색인 안 얼음)"
else bad "T13b 대소문자 충돌" "rc=$RC dup=$LOWER_COUNT
$(ls "$M")"; fi

# ── T13c: CLAUDE.md 원문에 정규식 치환 escape(\1, \g)가 있어도 무손상 ────────
BSSRC="$ROOT/bs/.claude"
mkdir -p "$BSSRC"
printf 'sed 규칙: s/foo/\\1bar/ 그리고 \\g<name> 참조\n' > "$BSSRC/CLAUDE.md"
printf '{}\n' > "$BSSRC/settings.json"
OUT="$(imp apply --source "$BSSRC" --no-backup)"; RC=$?
if [ "$RC" = "0" ] && grep -q 's/foo/\\1bar/' "$DST/.claude/CLAUDE.md"; then
  ok "T13c CLAUDE.md 원문의 백슬래시 escape 무손상"
else bad "T13c 백슬래시 보존" "rc=$RC $(grep -n 'foo' "$DST/.claude/CLAUDE.md" || true)"; fi

# ── T14: adopt-native — 배선 전 고아로 쌓인 내장 auto memory 흡수 ───────────
mkdir -p "$DST/.claude/projects/-home-cockpit/memory"
cat > "$DST/.claude/projects/-home-cockpit/memory/orphan.md" <<'EOF'
---
name: orphan
description: "배선 전에 내장 기억이 여기 쌓였다"
---
본문
EOF
OUT="$(imp adopt-native)"; RC=$?
if [ "$RC" = "0" ] && echo "$OUT" | grep -q "orphan.md" && [ ! -f "$M/orphan.md" ]; then
  ok "T14 adopt-native dry-run(발견만, 대상 무변경)"
else bad "T14 adopt-native dry-run" "rc=$RC $OUT"; fi

# ── T15: adopt-native --apply — 흡수하되 원본 삭제 0 ────────────────────────
OUT="$(imp adopt-native --apply --no-backup)"; RC=$?
if [ "$RC" = "0" ] && [ -f "$M/orphan.md" ] \
   && [ -f "$DST/.claude/projects/-home-cockpit/memory/orphan.md" ] \
   && grep -q 'orphan.md' "$M/MEMORY.md"; then
  ok "T15 adopt-native 흡수 + 원본 보존(삭제 0) + 색인 등재"
else bad "T15 adopt-native apply" "rc=$RC $OUT"; fi

# ── T16: adopt-native 는 cc-memory 자기 자신을 소스로 삼지 않는다 ───────────
OUT="$(imp adopt-native)"; RC=$?
if [ "$RC" = "0" ] && echo "$OUT" | grep -q "동일 내용 이미 있음\|고아 기억 없음"; then
  ok "T16 adopt-native 재실행 멱등(자기 자신 재흡수 안 함)"
else bad "T16 adopt-native 멱등" "rc=$RC $OUT"; fi

# ── T17: 배선이 끊긴 환경에 이관하면 마지막에 경고한다(옮겼는데 안 읽히는 상태) ──
UNW="$ROOT/unwired"
mkdir -p "$UNW/.claude/cc-memory" "$UNW/.claude/cc-companion"
printf '# PROJECT_STATUS\n본문\n' > "$UNW/.claude/cc-memory/PROJECT_STATUS.md"
printf -- '- [PROJECT_STATUS.md](PROJECT_STATUS.md) — 상태\n<!-- MEMORY_INDEX_END · 자동 생성(rebuild_memory_index.py) · 직접 편집 금지 -->\n' > "$UNW/.claude/cc-memory/MEMORY.md"
printf '{"enabledPlugins":{"cockpit@cc-companion":true}}\n' > "$UNW/.claude/settings.json"   # autoMemoryDirectory 없음
OUT="$(HOME="$UNW" CC_MEMORY_DIR="$UNW/.claude/cc-memory" CC_STATE_DIR="$UNW/.claude/cc-companion" \
       CC_ARCHIVE_DIR="$UNW/.claude/cc-memory-archive" python3 "$IMP" apply --source "$SRC" --no-backup 2>&1)"; RC=$?
if [ "$RC" = "0" ] && echo "$OUT" | grep -q "기억 배선이 끊겨 있습니다" && echo "$OUT" | grep -q "wire-auto-memory --apply"; then
  ok "T17 배선 끊긴 환경 → 이관 후 경고 + 고치는 명령 제시"
else bad "T17 배선 경고" "rc=$RC $OUT"; fi

echo
echo "== 결과: PASS=$PASS FAIL=$FAIL =="
[ "$FAIL" -eq 0 ] || exit 1
