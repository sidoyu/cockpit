#!/usr/bin/env bash
# smoke-image.sh — 골든 이미지(WSL rootfs) 스모크 검증(단계5).
#
# 무엇을 검사하나: build-rootfs.sh 산출(.tar.gz) 또는 추출된 rootfs 디렉터리가
#   provision.sh 의 안전 불변식을 충족하는지. "import/unregister dry" = Linux 에선 실제
#   `wsl --import` 가 불가하므로 (1) tar 가 import 가능한 형태인지 구조 검증 +
#   (2) 추출된 파일시스템의 불변식 검증으로 대체한다. 실제 import/unregister 라이프사이클은
#   Windows smoke 잡(ps-gate-smoke)·배포자 실기에서 수행(설계상 환경 분리).
#
# 사용:
#   scripts/smoke-image.sh dist/windows/cockpit-wsl.tar.gz          # 빌드 산출 검증
#   scripts/smoke-image.sh <추출된_rootfs_디렉터리>                  # 이미 푼 트리 검증(CI/셀프테스트)
#   PUBLISH=1 scripts/smoke-image.sh <...>                          # 발행 모드(마켓플레이스 placeholder 도 차단)
#
# 종료코드: 0=통과 / 1=불변식 위반 / 2=실행 오류
set -u
fail=0; warns=0
FAIL() { echo "  [FAIL] $*"; fail=1; }
WARN() { echo "  [warn] $*"; warns=$((warns+1)); }
OK()   { echo "  [ok]   $*"; }
sec()  { echo ""; echo "── $* ──"; }

TARGET="${1:-}"
[ -n "$TARGET" ] || { echo "사용: $0 <image.tar.gz | rootfs_dir> [--publish]"; exit 2; }
[ "${2:-}" = "--publish" ] && PUBLISH=1
PUBLISH="${PUBLISH:-0}"

sha256() { if command -v sha256sum >/dev/null 2>&1; then sha256sum "$1" | awk '{print $1}'; else shasum -a 256 "$1" | awk '{print $1}'; fi; }

WORK=""
cleanup() { [ -n "$WORK" ] && rm -rf "$WORK"; }
trap cleanup EXIT

echo "[smoke-image] 대상: $TARGET (PUBLISH=$PUBLISH)"

# ── 0) 입력 분류: tar.gz 면 무결성·체크섬·추출 / 디렉터리면 그대로 ──
ROOTFS=""
if [ -d "$TARGET" ]; then
  ROOTFS="$TARGET"
  OK "추출된 rootfs 디렉터리 사용"
elif [ -f "$TARGET" ]; then
  sec "0) tar.gz 무결성·체크섬·import 형태"
  case "$TARGET" in
    *.gz) gzip -t "$TARGET" 2>/dev/null && OK "gzip 무결성 OK" || FAIL "gzip 손상";;
    *) WARN "확장자가 .gz 아님 — gzip 검사 생략";;
  esac
  # 체크섬: 옆 .sha256 또는 provenance.json 과 대조
  bdir="$(cd "$(dirname "$TARGET")" && pwd)"; base="$(basename "$TARGET")"
  if [ -f "$TARGET.sha256" ]; then
    want=$(awk '{print $1}' "$TARGET.sha256"); got=$(sha256 "$TARGET")
    [ "$want" = "$got" ] && OK "체크섬 일치($got)" || FAIL "체크섬 불일치 want=$want got=$got"
  elif [ -f "$bdir/provenance.json" ] && command -v jq >/dev/null 2>&1; then
    want=$(jq -r '.sha256_tar_gz // empty' "$bdir/provenance.json"); got=$(sha256 "$TARGET")
    [ -n "$want" ] && { [ "$want" = "$got" ] && OK "provenance 체크섬 일치" || FAIL "provenance 체크섬 불일치 want=$want got=$got"; } || WARN "provenance 에 sha256_tar_gz 없음"
  else
    WARN "체크섬 파일(.sha256/provenance) 없음 — 무결성 대조 생략"
  fi
  # import 형태: 단일 rootfs tar 인지(루트에 FHS 디렉터리). 추출.
  WORK="$(mktemp -d)"
  if tar -xzf "$TARGET" -C "$WORK" 2>/dev/null; then OK "tar 추출 OK(import 가능 형태)"; else FAIL "tar 추출 실패 — import 불가 형태"; echo "[smoke-image] 추출 실패로 중단"; exit 1; fi
  ROOTFS="$WORK"
else
  echo "[smoke-image][FATAL] 대상이 파일도 디렉터리도 아님: $TARGET"; exit 2
fi

# FHS 루트 구조(wsl --import 입력 적격)
sec "1) rootfs 구조(import 적격)"
miss=""
for d in bin etc usr lib; do [ -e "$ROOTFS/$d" ] || miss="$miss $d"; done
[ -z "$miss" ] && OK "루트 FHS 디렉터리 존재(bin etc usr lib)" || FAIL "루트에 FHS 디렉터리 누락:$miss — rootfs tar 아님"

# ── 2) wsl.conf: 기본 사용자 + systemd ──
sec "2) /etc/wsl.conf"
WC="$ROOTFS/etc/wsl.conf"
if [ -f "$WC" ]; then
  grep -qE '^[[:space:]]*default[[:space:]]*=[[:space:]]*[a-z_]' "$WC" && OK "기본 사용자 설정됨" || FAIL "wsl.conf 에 default 사용자 없음(혹은 __COCKPIT_USER__ 미치환)"
  grep -q '__COCKPIT_USER__' "$WC" && FAIL "wsl.conf 에 __COCKPIT_USER__ 토큰 미치환 잔존"
  grep -qE '__COCKPIT_(UID|GID)__' "$WC" && FAIL "wsl.conf 에 __COCKPIT_UID__/__COCKPIT_GID__ 토큰 미치환 잔존"
  # automount uid == 기본 사용자 실제 uid (실기 발견: 불일치면 cockpit 이 /mnt/c 에 못 써 재설치 생존 백업 실패)
  _du="$(grep -E '^[[:space:]]*default[[:space:]]*=' "$WC" | head -1 | sed -E 's/.*=[[:space:]]*//; s/[[:space:]]*$//')"
  _optline="$(grep -E '^[[:space:]]*options[[:space:]]*=' "$WC" | head -1)"
  _amuid="$(printf '%s' "$_optline" | grep -oE 'uid=[0-9]+' | head -1 | cut -d= -f2)"
  _amgid="$(printf '%s' "$_optline" | grep -oE 'gid=[0-9]+' | head -1 | cut -d= -f2)"
  _pwuid="$(grep -E "^${_du}:" "$ROOTFS/etc/passwd" 2>/dev/null | cut -d: -f3)"
  _pwgid="$(grep -E "^${_du}:" "$ROOTFS/etc/passwd" 2>/dev/null | cut -d: -f4)"
  if [ -n "$_amuid" ] && [ -n "$_pwuid" ]; then
    [ "$_amuid" = "$_pwuid" ] && OK "automount uid($_amuid) == 기본 사용자 '$_du' uid(정렬됨 · /mnt/c 쓰기 가능)" || FAIL "automount uid($_amuid) != 기본 사용자 '$_du' uid($_pwuid) — cockpit 이 /mnt/c 에 못 씀(재설치 생존 백업 실패)"
  else
    WARN "automount uid 확인 불가(automount 미설정이면 WSL 기본 uid=1000 → 사용자 uid≠1000 시 /mnt/c 쓰기 차단 위험)"
  fi
  if [ -n "$_amgid" ] && [ -n "$_pwgid" ]; then
    [ "$_amgid" = "$_pwgid" ] && OK "automount gid($_amgid) == 기본 사용자 '$_du' gid(정렬됨)" || FAIL "automount gid($_amgid) != 기본 사용자 '$_du' gid($_pwgid) — /mnt/c 그룹 소유 불일치"
  fi
  grep -qE 'systemd[[:space:]]*=[[:space:]]*true' "$WC" && OK "systemd=true" || WARN "systemd=true 아님(의도면 무시)"
else
  FAIL "/etc/wsl.conf 없음 — 기본 사용자·systemd 미설정"
fi

# ── 3) 플러그인 스테이징 + 거버넌스 ──
sec "3) 플러그인 스테이징(/opt/cockpit)"
if [ -d "$ROOTFS/opt/cockpit" ]; then
  OK "/opt/cockpit 존재"
  [ -f "$ROOTFS/opt/cockpit/GOVERNANCE.md" ] && OK "GOVERNANCE.md 스테이징됨" || WARN "GOVERNANCE.md 미발견(스테이징 소스 확인)"
else
  WARN "/opt/cockpit 없음 — 플러그인 미스테이징(마켓플레이스 직접 추가 경로면 허용)"
fi

# ── 4) 첫 실행 안내 + 사용자 홈 ──
sec "4) 첫 실행 안내(README-first-run.txt)"
README="$(ls "$ROOTFS"/home/*/README-first-run.txt 2>/dev/null | head -1 || true)"
if [ -n "$README" ]; then
  OK "발견: ${README#$ROOTFS}"
  if grep -qE "example\.invalid" "$README"; then
    if [ "$PUBLISH" = "1" ]; then FAIL "README-first-run.txt 에 example.invalid — COCKPIT_MARKETPLACE 실주소 미주입(발행 차단)."
    else WARN "README-first-run.txt 에 example.invalid(개발 빌드 기본값 — 발행 빌드는 실주소 주입 필요)."; fi
  else OK "마켓플레이스 주소 비-플레이스홀더"; fi
else
  FAIL "어떤 사용자 홈에도 README-first-run.txt 없음 — provision MOTD 단계 누락"
fi

# ── 5) sudoers 멱등 산출 ──
sec "5) sudoers"
SD="$ROOTFS/etc/sudoers.d/90-cockpit"
if [ -f "$SD" ]; then
  grep -q "NOPASSWD" "$SD" && OK "90-cockpit NOPASSWD 존재" || WARN "90-cockpit 에 NOPASSWD 없음"
  perm=$(stat -f '%Lp' "$SD" 2>/dev/null || stat -c '%a' "$SD" 2>/dev/null || echo "?")
  [ "$perm" = "440" ] && OK "권한 0440" || WARN "sudoers 권한이 0440 아님($perm) — 추출 FS 가 보존 못했을 수 있음"
else
  WARN "/etc/sudoers.d/90-cockpit 없음(커스텀 베이스면 가능)"
fi

# ── 6) 출고 불변식(핵심) ──
# v0.1.1: 편의 설정(bypass·effort·model·remote-control·trust)은 **의도된 사전적용**.
# 동의 무결성은 "외부 송신(egress) 동의 마커가 굽히지 않음"으로 보장한다(아래 (e)).
# 끝까지 OFF 유지 불변식 = ① egress 마커 ② 자체호스팅 대시보드 자동시작 ③ 비밀.
sec "6) 출고 불변식(egress 동의·자체호스팅 대시보드 OFF 유지)"
# (b) kill switch 사전생성 안 됨(사용자 동작이어야)
if find "$ROOTFS"/home "$ROOTFS"/root -name 'CC_KILL_SWITCH' 2>/dev/null | grep -q .; then
  WARN "CC_KILL_SWITCH 가 이미지에 존재(사용자 동작이어야 함 — 확인)"
else OK "CC_KILL_SWITCH 사전생성 없음"; fi
# (c) settings.json 사전적용 프로필 — v0.1.1: bypass·effort·model·remoteControl 은 의도된
#     사전적용(동의 무결성은 (e) egress 마커 부재로 보장). bypass 존재 자체는 FAIL 아님. 단
#     **굽힌 값이 실제로 기대치와 일치하는지** 의미 검증한다(발견1: 문자열 grep 만으론 드리프트
#     무방비). 핵심=실제 JSON 파싱 — jq → python3, 둘 다 없으면 FAIL(grep 폴백 금지).
#     + (발견4) bypass ON ⟹ CLAUDE.md(1차 방어) 동반 불변식.
EXPECT_MODEL="${EXPECT_MODEL-claude-opus-4-8[1m]}"  # 굽는 source-of-truth(provision COCKPIT_MODEL_PIN 기본). ""=미핀 기대.
_JSON_TOOL=""
if command -v jq >/dev/null 2>&1; then _JSON_TOOL=jq
elif command -v python3 >/dev/null 2>&1; then _JSON_TOOL=py; fi
# json_get <file> <key...> → 스칼라(bool=true/false) / "__MISS__"(키없음·파싱실패) / "__NOTOOL__"(파서없음)
#   숫자-only 키는 배열 인덱스로 해석(§6f installed_plugins 의 plugins.<id>[0].<field> 접근용).
json_get() {
  local f="$1"; shift
  if [ "$_JSON_TOOL" = jq ]; then
    local arr; arr=$(printf '%s\n' "$@" | jq -R 'if test("^[0-9]+$") then tonumber else . end' | jq -cs .)
    jq -r --argjson p "$arr" 'getpath($p) | if . == null then "__MISS__" else tostring end' "$f" 2>/dev/null || printf '__MISS__'
  elif [ "$_JSON_TOOL" = py ]; then
    python3 - "$f" "$@" <<'PY' 2>/dev/null || printf '__MISS__'
import json,sys
f=sys.argv[1]; keys=sys.argv[2:]
try: cur=json.load(open(f,encoding="utf-8"))
except Exception: print("__MISS__"); sys.exit(0)
for k in keys:
    if isinstance(cur,dict) and k in cur: cur=cur[k]
    elif isinstance(cur,list) and k.isdigit() and int(k)<len(cur): cur=cur[int(k)]
    else: print("__MISS__"); sys.exit(0)
print("true" if cur is True else "false" if cur is False else ("__MISS__" if cur is None else cur))
PY
  else
    printf '__NOTOOL__'
  fi
}
json_valid() {  # 0=유효 JSON / 1=손상 / 2=파서없음
  if [ "$_JSON_TOOL" = jq ]; then jq empty "$1" >/dev/null 2>&1
  elif [ "$_JSON_TOOL" = py ]; then python3 -c 'import json,sys; json.load(open(sys.argv[1],encoding="utf-8"))' "$1" >/dev/null 2>&1
  else return 2; fi
}
PROFILE=""
while IFS= read -r s; do
  [ -e "$s" ] || continue
  rel="${s#$ROOTFS}"
  # (Codex) 손상 settings 무표식 통과 방지: 파서 있으면 먼저 parse 유효성 검사(손상=FAIL).
  #   키워드 없는 손상 파일이 is_profile=0 으로 빠져 "프로필 없음" OK 되는 구멍을 막는다.
  if [ -n "$_JSON_TOOL" ] && ! json_valid "$s"; then
    FAIL "settings JSON 파싱 실패(손상) — $rel"; PROFILE="$PROFILE $rel"; continue
  fi
  has_bypass=0; grep -qiE 'bypassPermissions' "$s" 2>/dev/null && has_bypass=1
  is_profile=0; [ "$has_bypass" = "1" ] && is_profile=1
  grep -qiE 'remoteControlAtStartup|effortLevel|agentPushNotifEnabled|respondToBashCommands' "$s" 2>/dev/null && is_profile=1
  [ "$is_profile" = "1" ] || continue
  PROFILE="$PROFILE $rel"
  if [ "$(json_get "$s" effortLevel)" = "__NOTOOL__" ]; then
    FAIL "JSON 파서(jq/python3) 없음 — settings 의미검증 불가($rel). 검증환경에 jq 또는 python3 필요."
    continue
  fi
  # 항상 굽는 키: effortLevel(유효값) · remoteControlAtStartup(true) · agentPushNotifEnabled(true) ·
  #             respondToBashCommands(false) · model(있으면 기대핀 정확일치)
  eff=$(json_get "$s" effortLevel)
  case "$eff" in
    low|medium|high|xhigh|max) OK "effortLevel=$eff ($rel)";;
    __MISS__) FAIL "effortLevel 누락 — 사전적용 미반영($rel)";;
    *) FAIL "effortLevel 값 이상('$eff') — 오염/드리프트 의심($rel)";;
  esac
  rc=$(json_get "$s" remoteControlAtStartup)
  [ "$rc" = "true" ] && OK "remoteControlAtStartup=true ($rel)" \
                     || FAIL "remoteControlAtStartup 가 true 아님('$rc') — 원격조종 사전 ON 미반영($rel)"
  apn=$(json_get "$s" agentPushNotifEnabled)
  [ "$apn" = "true" ] && OK "agentPushNotifEnabled=true ($rel)" \
                      || FAIL "agentPushNotifEnabled 가 true 아님('$apn') — 모바일 완료푸시 사전 ON 미반영($rel)"
  rbc=$(json_get "$s" respondToBashCommands)
  [ "$rbc" = "false" ] && OK "respondToBashCommands=false ($rel)" \
                       || FAIL "respondToBashCommands 가 false 아님('$rbc') — ! 자동응답 끔 미반영($rel)"
  mdl=$(json_get "$s" model)
  if [ -n "$EXPECT_MODEL" ]; then
    [ "$mdl" = "$EXPECT_MODEL" ] && OK "model 핀 일치($mdl) ($rel)" \
       || FAIL "model 핀 불일치 — 기대 '$EXPECT_MODEL' / 실제 '$mdl'($rel). EXPECT_MODEL 로 조정 가능."
  else
    [ "$mdl" = "__MISS__" ] && OK "model 미핀(EXPECT_MODEL='' 기대 일치) ($rel)" \
       || WARN "model 이 핀됨('$mdl') 인데 EXPECT_MODEL='' — 의도 확인."
  fi
  if [ "$has_bypass" = "1" ]; then
    dm=$(json_get "$s" permissions defaultMode)
    [ "$dm" = "bypassPermissions" ] && OK "permissions.defaultMode=bypassPermissions ($rel)" \
       || FAIL "bypass 프로필인데 permissions.defaultMode 가 '$dm'($rel)"
    sk=$(json_get "$s" skipDangerousModePermissionPrompt)
    [ "$sk" = "true" ] && OK "skipDangerousModePermissionPrompt=true ($rel)" \
       || FAIL "bypass 인데 skipDangerousModePermissionPrompt 가 true 아님('$sk')($rel)"
    # (발견4) bypass ON ⟹ CLAUDE.md(멈춰질문·deny 1차 방어) 동반 필수. staged 템플릿부재 회귀 차단.
    cmd_md="$(dirname "$s")/CLAUDE.md"
    if [ ! -f "$cmd_md" ]; then
      FAIL "bypass ON 인데 CLAUDE.md 없음(${cmd_md#$ROOTFS}) — 1차 방어 누락(provision _bake_bypass 불변식 위반)."
    else
      if grep -q '멈춰 질문' "$cmd_md" 2>/dev/null || grep -q '작업 규율' "$cmd_md" 2>/dev/null; then
        OK "CLAUDE.md 1차 방어 동반 + 가드레일 본문 존재(${cmd_md#$ROOTFS})"
      else
        FAIL "CLAUDE.md 존재하나 가드레일 본문(멈춰 질문/작업 규율) 없음 — 잘림/오치환 의심(${cmd_md#$ROOTFS})."
      fi
      # provision 이 치환하는 토큰만 검사(나머지 {{...}} 3종은 사용자 채움 — false-fail 금지).
      if grep -q '{{PRIMARY_LANGUAGE}}' "$cmd_md" 2>/dev/null; then
        FAIL "CLAUDE.md 에 {{PRIMARY_LANGUAGE}} 미치환 잔존 — provision sed 실패(${cmd_md#$ROOTFS})."
      else
        OK "CLAUDE.md PRIMARY_LANGUAGE 치환 완료(${cmd_md#$ROOTFS})"
      fi
    fi
  fi
done < <(find "$ROOTFS"/home "$ROOTFS"/root -path '*/.claude/settings*.json' 2>/dev/null)
[ -n "$PROFILE" ] && OK "settings 사전적용 프로필 검증 대상:$PROFILE" \
                  || OK "settings 사전적용 프로필 없음(PRECONFIGURE=0/구버전 — 검증 skip)"
# (발견1) 최소버전: remoteControlAtStartup 은 claude 2.1.119+ 필요. build-versions.json 과 대조.
BV="$ROOTFS/opt/cockpit/build-versions.json"
if [ -n "$PROFILE" ] && [ -f "$BV" ]; then
  cver=$(json_get "$BV" claude); cver="${cver%% *}"   # "2.1.186 (Claude Code)" → 2.1.186
  # 엄격 추출(Codex): prerelease 접미사('2.1.119-beta')는 통과시키지 않고 WARN(파싱불가)로 처리.
  if printf '%s' "$cver" | grep -qE '^[0-9]+\.[0-9]+\.[0-9]+$'; then
    awk -v v="$cver" 'BEGIN{split(v,a,".");maj=a[1]+0;min=a[2]+0;pat=a[3]+0;
      exit ((maj>2)||(maj==2&&min>1)||(maj==2&&min==1&&pat>=119))?0:1 }' \
      && OK "claude 버전 $cver ≥ 2.1.119(remoteControlAtStartup 지원)" \
      || FAIL "claude 버전 $cver < 2.1.119 — remoteControlAtStartup 미지원(사전적용 무효)."
  else
    WARN "build-versions.json claude 버전 파싱 불가('$cver') — 최소버전 대조 생략."
  fi
elif [ -n "$PROFILE" ]; then
  WARN "build-versions.json 없음 — remoteControlAtStartup 최소버전(2.1.119) 대조 생략."
fi
# (e) egress 동의 마커 미베이크(핵심 불변식) — 구워지면 첫 실행 동의 없이 외부송신 활성화.
if find "$ROOTFS"/home "$ROOTFS"/root -path '*/cc-companion/setup_complete' 2>/dev/null | grep -q .; then
  FAIL "egress 동의 마커(setup_complete)가 이미지에 구워짐 — 동의 무결성 위반(무동의 외부송신)."
else OK "egress 동의 마커 미베이크(첫 실행 동의 게이트 유지)"; fi
# (f) 플러그인 사전설치 베이크(v0.1.2-B) — 있으면 의미검증(합동점검 F-3), 없으면 정직 폴백 OK.
#     실측 포맷 정답 = docs/plugin-bake-format.md. 검증: ①marketplace 등록(공개 URL 정규화·클론 트리
#     실재) ②설치 정체성(installPath 실재·version 캐시 일치·gitCommitSha=40-hex 공개 commit)
#     ③bypass 백스톱 즉시활성(로드되는 캐시 경로의 hooks.json 이 bypass_guard.py 배선+파일 실재)
#     ④private 식별자 0. EXPECT_MARKETPLACE/EXPECT_PLUGIN_COMMIT 로 기대값 주입(CI가 빌드 입력 전달).
EXPECT_MARKETPLACE="${EXPECT_MARKETPLACE-https://github.com/sidoyu/cockpit.git}"
EXPECT_PLUGIN_COMMIT="${EXPECT_PLUGIN_COMMIT-}"
IPJ_LIST="$(find "$ROOTFS"/home "$ROOTFS"/root -path '*/.claude/plugins/installed_plugins.json' 2>/dev/null || true)"
if [ -z "$IPJ_LIST" ]; then
  # 발행 모드에선 차단 승격(Codex): v0.1.2 결정=B 포함 발행 — plugin_commit 미주입 실수로
  # "2단계 남은 이미지"가 그대로 발행되는 사일런트 경로를 막는다. 개발 빌드는 정직 폴백 OK.
  if [ "$PUBLISH" = "1" ]; then
    FAIL "플러그인 사전설치 미베이크 — 발행 이미지는 베이크 필수(golden-build 에 plugin_commit 주입. 의도적 미베이크 발행이면 이 게이트를 재검토)."
  else
    OK "플러그인 사전설치 미베이크(첫 실행 2단계 경로 — 개발 빌드 정직 폴백)"
  fi
else
  while IFS= read -r ipj; do
    [ -n "$ipj" ] || continue
    pdir="$(dirname "$ipj")"; rel="${ipj#$ROOTFS}"
    if [ -z "$_JSON_TOOL" ]; then FAIL "JSON 파서(jq/python3) 없음 — 플러그인 베이크 의미검증 불가($rel)"; continue; fi
    json_valid "$ipj" || { FAIL "installed_plugins.json 파싱 실패(손상) — $rel"; continue; }
    # 스키마 상수(Codex): version=2 · cockpit entry 정확 1개(index 1 은 없어야) · scope=user.
    [ "$(json_get "$ipj" version)" = "2" ] && OK "installed_plugins schema version=2" \
      || FAIL "installed_plugins version 이 2 아님('$(json_get "$ipj" version)')($rel)"
    [ "$(json_get "$ipj" plugins cockpit@cc-companion 1 installPath)" = "__MISS__" ] \
      && OK "cockpit entry 단일(중복 설치 없음)" || FAIL "cockpit@cc-companion entry 가 2개 이상($rel)"
    [ "$(json_get "$ipj" plugins cockpit@cc-companion 0 scope)" = "user" ] && OK "scope=user" \
      || FAIL "scope 가 user 아님('$(json_get "$ipj" plugins cockpit@cc-companion 0 scope)')($rel)"
    # 경로 경계(Codex): 상태 JSON 이 가리키는 경로는 이 plugins 디렉터리 밑 **정확한 형태**여야 한다
    # (홈 밖/../ 위조 차단 — 기대값 = provision 산출 형태와 동일).
    PLUGROOT="${pdir#$ROOTFS}"   # = /home/<user>/.claude/plugins
    # ① marketplace 등록 — 반쪽 베이크(installed 만) 차단 + 공개 URL·source 종류·클론 트리 실재.
    kmj="$pdir/known_marketplaces.json"
    if [ ! -f "$kmj" ]; then
      FAIL "known_marketplaces.json 없음(installed 만 존재 — 반쪽 베이크)(${kmj#$ROOTFS})"
    elif ! json_valid "$kmj"; then
      FAIL "known_marketplaces.json 파싱 실패(손상)(${kmj#$ROOTFS})"
    else
      [ "$(json_get "$kmj" cc-companion source source)" = "git" ] && OK "marketplace source 종류=git" \
        || FAIL "marketplace source 종류가 git 아님('$(json_get "$kmj" cc-companion source source)')"
      murl=$(json_get "$kmj" cc-companion source url)
      [ "$murl" = "$EXPECT_MARKETPLACE" ] && OK "marketplace URL 일치($murl)" \
        || FAIL "marketplace URL 불일치 — 기대 '$EXPECT_MARKETPLACE' / 실제 '$murl'(EXPECT_MARKETPLACE 로 조정 가능)"
      mloc=$(json_get "$kmj" cc-companion installLocation)
      [ "$mloc" = "$PLUGROOT/marketplaces/cc-companion" ] && OK "installLocation 경로 정형($mloc)" \
        || FAIL "installLocation 경로 이형 — 기대 '$PLUGROOT/marketplaces/cc-companion' / 실제 '$mloc'(홈 밖/위조 차단)"
      if [ "$mloc" != "__MISS__" ] && [ -f "$ROOTFS$mloc/.claude-plugin/marketplace.json" ]; then
        OK "marketplace 클론 트리 실재($mloc)"
      else FAIL "marketplace installLocation 트리 없음/불완전('$mloc')"; fi
    fi
    # ② 설치 정체성 — installPath 정형+실재 · version 캐시 일치 · 캐시==마켓 plugin/ 내용 동일 · commit.
    ipath=$(json_get "$ipj" plugins cockpit@cc-companion 0 installPath)
    iver=$(json_get "$ipj" plugins cockpit@cc-companion 0 version)
    isha=$(json_get "$ipj" plugins cockpit@cc-companion 0 gitCommitSha)
    [ "$ipath" = "$PLUGROOT/cache/cc-companion/cockpit/$iver" ] && OK "installPath 경로 정형($ipath)" \
      || FAIL "installPath 경로 이형 — 기대 '$PLUGROOT/cache/cc-companion/cockpit/$iver' / 실제 '$ipath'"
    if [ "$ipath" = "__MISS__" ] || [ ! -d "$ROOTFS$ipath" ]; then
      FAIL "installPath 없음/캐시 부재('$ipath') — 사일런트 미로드 위험($rel)"
    else
      OK "설치 캐시 실재($ipath)"
      cver=$(json_get "$ROOTFS$ipath/.claude-plugin/plugin.json" version)
      [ "$iver" != "__MISS__" ] && [ "$iver" = "$cver" ] && OK "version 일치($iver == 캐시 plugin.json)" \
        || FAIL "version 불일치 — installed '$iver' / 캐시 plugin.json '$cver'"
      # 내용 동일성(Codex): 로드되는 캐시 == marketplace 클론의 plugin/ (드리프트=엇갈린 코드 로드).
      if [ "${mloc:-__MISS__}" != "__MISS__" ] && [ -d "$ROOTFS$mloc/plugin" ]; then
        if diff -qr "$ROOTFS$mloc/plugin" "$ROOTFS$ipath" >/dev/null 2>&1; then
          OK "캐시 내용 == marketplace plugin/ (드리프트 없음)"
        else FAIL "캐시 내용 ≠ marketplace plugin/ — 설치본/클론 드리프트(diff -qr)"; fi
      fi
      # ③ bypass 백스톱 즉시활성 — Claude 가 로드하는 경로(installPath)의 hooks 배선을 검증.
      hj="$ROOTFS$ipath/hooks/hooks.json"
      if [ -f "$hj" ] && json_valid "$hj" && grep -q 'bypass_guard\.py' "$hj" 2>/dev/null \
         && [ -f "$ROOTFS$ipath/safety/bypass_guard.py" ]; then
        OK "bypass 백스톱 배선(hooks.json→safety/bypass_guard.py) — 설치 직후 활성"
      else FAIL "bypass 백스톱 배선 불완전 — hooks.json/bypass_guard.py 확인($ipath)"; fi
    fi
    if printf '%s' "$isha" | grep -qE '^[0-9a-f]{40}$'; then
      if [ -n "$EXPECT_PLUGIN_COMMIT" ]; then
        [ "$isha" = "$EXPECT_PLUGIN_COMMIT" ] && OK "gitCommitSha 기대 일치($(printf '%.7s' "$isha"))" \
          || FAIL "gitCommitSha 불일치 — 기대 '$EXPECT_PLUGIN_COMMIT' / 실제 '$isha'"
      else
        OK "gitCommitSha 형식 OK($(printf '%.7s' "$isha")) — ⚠ 공개 repo commit 인지 발행자가 대조(EXPECT_PLUGIN_COMMIT 미주입)"
      fi
    else FAIL "gitCommitSha 형식 오류('$isha') — 40-hex 전체 SHA(공개 repo 기준) 필요(F-1)"; fi
    # ⑤ 활성화 키(cc-cockpit2 라이브 실측 2026-07-02): 설치기록+캐시만으론 **미로드** —
    #    settings.json 의 enabledPlugins + extraKnownMarketplaces 가 실제 "켜짐"을 결정
    #    (실 /plugin install 이 기록하는 키 — v0.1.0 실기 대조로 확정).
    sj="$(dirname "$pdir")/settings.json"
    if [ ! -f "$sj" ]; then
      FAIL "settings.json 없음 — enabledPlugins 부재로 베이크 플러그인 미로드(${sj#$ROOTFS})"
    else
      [ "$(json_get "$sj" enabledPlugins cockpit@cc-companion)" = "true" ] \
        && OK "enabledPlugins.cockpit@cc-companion=true(활성화 키)" \
        || FAIL "enabledPlugins 에 cockpit@cc-companion=true 없음 — 베이크돼도 미로드(라이브 실측)($rel)"
      ekurl=$(json_get "$sj" extraKnownMarketplaces cc-companion source url)
      [ "$ekurl" = "$EXPECT_MARKETPLACE" ] && OK "extraKnownMarketplaces URL 일치($ekurl)" \
        || FAIL "extraKnownMarketplaces cc-companion url 불일치 — 기대 '$EXPECT_MARKETPLACE' / 실제 '$ekurl'"
    fi
    # ④ 베이크 트리에 private 식별자 0 — 상태 JSON + 클론/캐시 전체(발행트리 secret-scan 과 별개 심층방어).
    #    패턴을 리터럴로 두면 발행트리 secret-scan 이 이 파일 자체를 자기검출(FAIL)한다 → 스캐너의
    #    "자신 제외"와 같은 이유로 조각 결합 구성(검출력 동일·회피 아님 — CI 실측 발견 2026-07-02).
    _priv_re="$(printf '%s%s|%s%s|%s%s' 'cc-env' '-pack' 'dy' 'shin' 'iam' 'sdy')"
    #    베이크 클론엔 공개 repo 의 secret-scan.sh(검출 패턴 보유·정당 발행물)가 포함 → 발행 스캐너의
    #    자기 제외와 동일하게 제외(CI 실측 2차 발견). 그 외 파일은 전부 검사.
    PRIV_HITS=$(grep -rIlE --exclude='secret-scan.sh' "$_priv_re" "$pdir" 2>/dev/null || true)
    [ -z "$PRIV_HITS" ] && OK "베이크 트리 private 식별자 0건" \
      || FAIL "베이크 트리에 private 식별자:$(echo "$PRIV_HITS" | sed "s|$ROOTFS||g" | tr '\n' ' ')"
  done <<< "$IPJ_LIST"
fi
# (d) 원격 자동시작 + 공개 라우팅 없음 — systemd(system/user)·cron·rc.local·shell profile·skel 까지 폭넓게.
#     주의: claude.ai Remote Control(settings remoteControlAtStartup)은 수신 포트·데몬이 없는
#     아웃바운드 폴링이라 여기 패턴에 안 걸린다. 본 검사는 **자체호스팅 대시보드** 자동시작 한정.
#     (Codex 지적: /etc/systemd 이름패턴만으론 user unit·cron·profile·rc.local 경로를 놓침)
#     (C/Codex 4d-E: allowlist 를 우회하는 공개 라우팅 — tailscale serve/funnel·netsh portproxy — 이
#      자동시작 위치에 구워졌는지도 본다. 스캔은 AUTO_DIRS(자동시작 위치) 한정 = 자동시작 위치 내 보수적
#      탐지. staged 플러그인 문서(/opt/cockpit)는 AUTO_DIRS 밖이라 금지문구 오탐은 없다.)
AUTO_DIRS=()
for d in etc/systemd etc/rc.local etc/cron.d etc/cron.daily etc/cron.hourly etc/cron.weekly \
         var/spool/cron etc/profile.d etc/skel etc/xdg/autostart; do
  [ -e "$ROOTFS/$d" ] && AUTO_DIRS+=("$ROOTFS/$d")
done
while IFS= read -r p; do [ -e "$p" ] && AUTO_DIRS+=("$p"); done < <(
  find "$ROOTFS"/home "$ROOTFS"/root -maxdepth 4 \
    \( -path '*/.config/systemd/*' -o -name '.bashrc' -o -name '.bash_profile' -o -name '.profile' -o -name '.zshrc' \) 2>/dev/null
)
AUTO_HITS=""
if [ "${#AUTO_DIRS[@]}" -gt 0 ]; then
  # 파일명 패턴(빈 unit 대비) + 내용 패턴(원격 서버 기동) 둘 다.
  byname=$(find "${AUTO_DIRS[@]}" \( -iname '*dashboard*' -o -iname '*cockpit*remote*' \) 2>/dev/null || true)
  bycontent=$(grep -rIlE 'dashboard-run|active_server|cockpit[-_ ]*remote|disable-remote|--host[ =]*0\.0\.0\.0|--bind[ =]*0\.0\.0\.0|tailscale.*(funnel|serve)|portproxy' "${AUTO_DIRS[@]}" 2>/dev/null || true)
  AUTO_HITS="$(printf '%s\n%s\n' "$byname" "$bycontent" | grep -v '^$' | sort -u)"
fi
[ -z "$AUTO_HITS" ] && OK "원격 자동시작·공개라우팅 흔적 없음(systemd·cron·rc·profile·skel·funnel/serve/portproxy)" || FAIL "원격 자동시작/공개라우팅 흔적:$(echo "$AUTO_HITS" | sed "s|$ROOTFS||g" | tr '\n' ' ')"

# ── 7) 베이크된 시크릿·자격증명 0건 ──
sec "7) 베이크된 시크릿·개인정보 0건"
SCANDIRS=()
for d in opt/cockpit home root etc/profile.d etc/skel; do [ -e "$ROOTFS/$d" ] && SCANDIRS+=("$ROOTFS/$d"); done
if [ "${#SCANDIRS[@]}" -eq 0 ]; then
  WARN "스캔 대상 디렉터리 없음 — 시크릿 검사 생략"
else
  # 자격증명 파일
  CREDS=$(find "${SCANDIRS[@]}" \( -name '.credentials.json' -o -name 'auth.json' -o -name '.env' -o -name '*.pem' -o -name 'id_rsa' \) 2>/dev/null || true)
  [ -z "$CREDS" ] && OK "자격증명 파일 없음" || FAIL "자격증명 파일 발견:$(echo "$CREDS" | sed "s|$ROOTFS||g" | tr '\n' ' ')"
  # 키 패턴(텍스트 파일 한정 — 바이너리 오탐 회피)
  KEYHITS=$(grep -rIlE 'sk-ant-(api03-)?[A-Za-z0-9_-]{24,}|sk-proj-[A-Za-z0-9_-]{24,}|gh[pousr]_[A-Za-z0-9]{30,}|AKIA[A-Z0-9]{16}|AIza[A-Za-z0-9_-]{30,}|xox[baprs]-[A-Za-z0-9-]{12,}' "${SCANDIRS[@]}" 2>/dev/null || true)
  [ -z "$KEYHITS" ] && OK "API 키 패턴 0건" || FAIL "키 패턴 발견:$(echo "$KEYHITS" | sed "s|$ROOTFS||g" | tr '\n' ' ')"
fi

# ── 8) 도구 존재(claude/node) + 버전기록 ──
sec "8) 도구·버전 기록"
if [ -e "$ROOTFS/usr/bin/node" ] || find "$ROOTFS"/usr -name 'node' 2>/dev/null | grep -q .; then OK "node 설치됨"; else WARN "node 미발견(베이스/네트워크 의존)"; fi
if find "$ROOTFS"/usr "$ROOTFS"/home -path '*claude*' -name 'cli.js' 2>/dev/null | grep -q . || find "$ROOTFS"/usr/bin -name 'claude' 2>/dev/null | grep -q .; then OK "claude CLI 흔적 발견"; else WARN "claude CLI 미발견(빌드 시 네트워크 없으면 첫 실행 설치)"; fi
if [ -f "$ROOTFS/opt/cockpit/build-versions.json" ]; then OK "build-versions.json(버전 기록) 존재"; else WARN "build-versions.json 없음(구 이미지 또는 provision 버전기록 단계 미적용)"; fi
# cockpit-open-url 래퍼(provision §5.5 무조건 설치) — 누락=사일런트 /login UX 회귀 차단(FAIL).
OU="$ROOTFS/usr/local/bin/cockpit-open-url"
if [ -f "$OU" ]; then
  [ -x "$OU" ] && OK "cockpit-open-url 래퍼 존재(+x)" || FAIL "cockpit-open-url 실행비트 없음 — chmod 회귀"
else
  FAIL "cockpit-open-url 래퍼 없음 — provision §5.5 회귀"
fi
grep -q '^export BROWSER=/usr/local/bin/cockpit-open-url' "$ROOTFS/etc/profile.d/cockpit-browser.sh" 2>/dev/null \
  && OK "BROWSER env 배선(profile.d/cockpit-browser.sh)" \
  || FAIL "cockpit-browser.sh 없음/미배선 — BROWSER env 회귀"
# 래퍼 핵심 불변식 3종(내용 회귀 — 존재검사만으론 grep-allowlist/timeout/PS인용 후퇴 미탐, Codex 4b).
if [ -f "$OU" ]; then
  grep -qF "_re='^https?://" "$OU" && OK "래퍼 allowlist 정규식(anchored) 존재" \
    || FAIL "래퍼 allowlist 정규식 회귀(grep 방식=개행 통과 구멍)"
  grep -qF 'timeout 5' "$OU" && OK "래퍼 opener timeout 가드 존재" || FAIL "래퍼 timeout 가드 회귀"
  grep -qF "Start-Process '\$url'" "$OU" && OK "래퍼 PS 단일인용 리터럴 호출" || FAIL "래퍼 PS 인용 방식 회귀(주입면)"
fi
# BROWSER 를 정의하는 profile.d 가 cockpit-browser.sh 단일인지(후행 override 오염 탐지, Codex 4b).
_bdup=$(grep -lE '(^|[[:space:]])(export[[:space:]]+)?BROWSER=' "$ROOTFS"/etc/profile.d/*.sh 2>/dev/null | grep -v 'cockpit-browser\.sh' || true)
[ -z "$_bdup" ] && OK "profile.d BROWSER 정의 단일(cockpit-browser.sh)" \
  || FAIL "profile.d 에 BROWSER 중복 정의:$(echo "$_bdup" | sed "s|$ROOTFS||g" | tr '\n' ' ')"

# ── 8b) 원터치 런처 launch.sh(#3 설치후 UX — claude 자동실행 + 로그인후 원샷 재시작). ──
# PRECONFIGURE 게이트 안(§(a))이라 사전설정 이미지에만 존재 → 있으면 핵심 불변식을 FAIL 로 검사,
# 없으면 skip(PRECONFIGURE=0/구버전). 존재검사만으론 로그인감지·원샷마커·intro 재시작·항상0종료 회귀
# 미탐(Codex 4f 발견1) → 각 라인 grep.
sec "8b) launch.sh(#3 설치후 UX·로그인후 원샷 재시작)"
LSH=$(find "$ROOTFS"/home -path '*/.cockpit/launch.sh' 2>/dev/null | head -1)
if [ -n "$LSH" ] && [ -f "$LSH" ]; then
  [ -x "$LSH" ] && OK "launch.sh 존재(+x)" || FAIL "launch.sh 실행비트 없음 — chmod 회귀"
  grep -qF '.credentials.json' "$LSH" && OK "launch.sh 로그인 감지(.credentials.json)" || FAIL "launch.sh 로그인 감지 회귀"
  grep -qF 'first-login-restart-done' "$LSH" && OK "launch.sh 원샷 재시작 마커" || FAIL "launch.sh 원샷 마커 회귀(무한재시작 위험)"
  grep -qF 'CLAUDE_CONFIG_DIR' "$LSH" && OK "launch.sh CLAUDE_CONFIG_DIR 존중" || FAIL "launch.sh CLAUDE_CONFIG_DIR 미존중 회귀"
  grep -qF 'claude "$_intro"' "$LSH" && OK "launch.sh 로그인후 인사 프롬프트 재시작(intro)" || FAIL "launch.sh intro 재시작 회귀"
  grep -qF 'cockpit-open-url' "$LSH" && OK "launch.sh BROWSER 폴백" || FAIL "launch.sh BROWSER 폴백 회귀"
  grep -qE '^exit 0$' "$LSH" && OK "launch.sh 항상 0 종료 계약(.cmd errorlevel 레이어 고정)" || FAIL "launch.sh exit 0 계약 회귀"
else
  OK "launch.sh 없음(PRECONFIGURE=0/구버전 — 검증 skip)"
fi

# ── 9) 대시보드 수명관리 스크립트(provision §5.6 무조건 설치) ──
# 뷰어 본체는 굽지 않지만(reference-not-vendor·§6(d) 자동시작 OFF 불변식 유지), 기동/종료
# 진입점 cockpit-dashboard 는 무조건 베이크. 누락·핵심 불변식 후퇴=사일런트 회귀 차단(FAIL).
sec "9) 대시보드 수명관리 스크립트(cockpit-dashboard)"
CD="$ROOTFS/usr/local/bin/cockpit-dashboard"
if [ -f "$CD" ]; then
  [ -x "$CD" ] && OK "cockpit-dashboard 존재(+x)" || FAIL "cockpit-dashboard 실행비트 없음 — chmod 회귀"
  # 내용 불변식(존재검사만으론 안전 후퇴 미탐):
  #  ① blind kill 금지 — cmdline(active_server.py) 검증 후에만 신호
  grep -qF '_is_server' "$CD" && grep -qF 'active_server.py' "$CD" \
    && OK "cockpit-dashboard cmdline 검증(blind kill 금지)" \
    || FAIL "cockpit-dashboard cmdline 검증 회귀 — 무관 프로세스 오종료 위험"
  #  ② 포트 판정 python socket(외부도구 무의존 — ss/lsof 부재 이미지 대응)
  grep -qF 'connect_ex' "$CD" && OK "cockpit-dashboard 포트 판정=python socket(무의존)" \
    || FAIL "cockpit-dashboard 포트 판정 회귀 — ss 하드의존 복귀(최소 이미지서 전면 ERROR)"
  #  ③ pidfile 소유권 기록(setsid -f + exec 로 python 실PID). -f 필수(평범 setsid=호출측 hang).
  grep -qF 'PIDFILE' "$CD" && grep -qF 'exec python3 active_server.py' "$CD" && grep -qF 'setsid -f' "$CD" \
    && OK "cockpit-dashboard pidfile 소유권(setsid -f + exec)" \
    || FAIL "cockpit-dashboard pidfile/detach 회귀 — setsid -f 누락 시 호출측(.cmd for /f) hang"
  #  ④ mkdir 원자적 락 직렬화 — 더블클릭 레이스 차단(flock fd 상속 hang 회피)
  grep -qF '_acquire_lock' "$CD" && grep -qF 'mkdir "$LOCKDIR"' "$CD" \
    && OK "cockpit-dashboard mkdir 락 직렬화 존재" \
    || FAIL "cockpit-dashboard 락 회귀 — 동시 기동 레이스(flock 복귀 시 호출측 hang)"
  #  ⑤ umask 077 — 민감 로그/설정 권한
  grep -qE '^umask 077' "$CD" && OK "cockpit-dashboard umask 077 존재" \
    || FAIL "cockpit-dashboard umask 회귀 — 민감 로그 권한 느슨"
  #  ⑥ 기계 파싱 출력 계약(.cmd 가 의존)
  grep -qF 'COCKPIT_DASH_RESULT' "$CD" && OK "cockpit-dashboard 출력 계약(COCKPIT_DASH_RESULT) 존재" \
    || FAIL "cockpit-dashboard 출력 계약 회귀 — Cockpit-Dashboard.cmd 파싱 깨짐"
else
  FAIL "cockpit-dashboard 없음 — provision §5.6 회귀"
fi
# 뷰어 본체 미베이크 확인(reference-not-vendor — active_server.py 가 이미지에 구워지면 위반).
_baked_viewer=$(find "$ROOTFS"/usr/local/bin "$ROOTFS"/opt/cockpit -name 'active_server.py' 2>/dev/null || true)
[ -z "$_baked_viewer" ] && OK "뷰어 본체 미베이크(reference-not-vendor 유지)" \
  || FAIL "뷰어 본체가 이미지에 구워짐:$(echo "$_baked_viewer" | sed "s|$ROOTFS||g" | tr '\n' ' ') — 옵트인 클론 원칙 위반"

# ── 9b) cockpit-onboard 브리지(provision §5.7 무조건 설치·v0.1.8 설계 §7) ──
# Windows 설치기 온보딩 폼의 WSL 진입점. 누락/후퇴 = 설치기 온보딩 전체 사일런트 fail-open.
sec "9b) cockpit-onboard 브리지(설치기 온보딩)"
CO="$ROOTFS/usr/local/bin/cockpit-onboard"
if [ -f "$CO" ]; then
  [ -x "$CO" ] && OK "cockpit-onboard 존재(+x)" || FAIL "cockpit-onboard 실행비트 없음 — chmod 회귀"
  #  ① installed_plugins.json 우선 해석 + plugin.json 정체성 검증(stale/엉뚱 트리 exec 방지)
  grep -qF 'installed_plugins.json' "$CO" && grep -qF '"cockpit"' "$CO" \
    && OK "cockpit-onboard 플러그인 해석·정체성 검증 존재" \
    || FAIL "cockpit-onboard 해석/정체성 검증 회귀 — stale 캐시 exec 위험"
  #  ② 키 노출 금지 — xtrace 부재(stdin 통과 경로에 set -x 섞이면 키가 로그에 뜸). 주석 제외.
  grep -vE '^[[:space:]]*#' "$CO" | grep -qE '(^|[[:space:]])set -x' \
    && FAIL "cockpit-onboard 에 set -x — 키 stdin 경로 노출 위험" \
    || OK "cockpit-onboard xtrace 없음(키 stdin 경로 안전)"
  #  ③ 포워드 대상 2종(setup.py·install-viewer.sh) exec
  grep -qF 'skills/setup-wizard/setup.py' "$CO" && grep -qF 'dashboard/install-viewer.sh' "$CO" \
    && OK "cockpit-onboard 포워드 대상 2종 존재" \
    || FAIL "cockpit-onboard 포워드 대상 회귀"
else
  FAIL "cockpit-onboard 없음 — provision §5.7 회귀(설치기 온보딩 전체 fail-open)"
fi
# 기능 왕복(호스트 실행 — setup.py 의 해당 경로는 순수 python·CC_* env 격리):
#  apply-installer-onboarding(state 기록+동의 게이트) + set-extraction-key stdin(키 값이
#  stdout/stderr 에 미출력 + 키 파일 0600). 검사 범위 주의: 여기는 stdin 경로의 무노출·권한만 —
#  ps1 쪽 argv 금지 = publish-gate §1f(정적), 실 wsl 프로세스 /proc cmdline·env 부재 = Windows
#  실기 매트릭스 소관(이 스모크는 rootfs 오프라인 검사라 실 프로세스가 없다).
_SETUP_PY="$(ls -d "$ROOTFS"/home/*/.claude/plugins/cache/cc-companion/cockpit/*/skills/setup-wizard/setup.py 2>/dev/null | sort -V | tail -1 || true)"
[ -n "$_SETUP_PY" ] || _SETUP_PY="$(ls "$ROOTFS"/opt/cockpit/plugin/skills/setup-wizard/setup.py 2>/dev/null | head -1 || true)"
if [ -n "$_SETUP_PY" ] && command -v python3 >/dev/null 2>&1; then
  _OTMP="$(mktemp -d)"
  _orc=0
  # ① 동의 없는 egress on = 거부(rc2·아무 파일도 미기록)
  CC_STATE_DIR="$_OTMP/state" CC_MEMORY_DIR="$_OTMP/mem" CC_EXTRACTION_KEY_FILE="$_OTMP/key/extraction-key" \
    python3 "$_SETUP_PY" apply-installer-onboarding --memory-egress on >/dev/null 2>&1 && _orc=1
  [ ! -e "$_OTMP/state/setup_complete" ] || _orc=1
  # ② 동의+egress on = state(스키마 v1)+마커 기록
  CC_STATE_DIR="$_OTMP/state" CC_MEMORY_DIR="$_OTMP/mem" CC_EXTRACTION_KEY_FILE="$_OTMP/key/extraction-key" \
    python3 "$_SETUP_PY" apply-installer-onboarding --memory-egress on --governance-ack --key-registered yes --dashboard installed >/dev/null 2>&1 || _orc=1
  python3 - "$_OTMP/state/installer-onboarding.json" >/dev/null 2>&1 <<'PY' || _orc=1
import json, sys
d = json.load(open(sys.argv[1]))
assert d["schema_version"] == 1 and d["source"] == "installer" and d["memory_egress"] is True
PY
  [ -f "$_OTMP/state/setup_complete" ] || _orc=1
  [ "$_orc" -eq 0 ] && OK "apply-installer-onboarding 왕복(동의 게이트·state 스키마·마커)" \
    || FAIL "apply-installer-onboarding 왕복 실패 — 동의 게이트/state 스키마/마커 회귀"
  # ③ 키 stdin 왕복: 가짜 키가 출력에 안 뜨고 0600 파일로만 남는가
  _fake="sk-ant-smoke-$(date +%s)-fake"
  _kout="$(printf '%s\n' "$_fake" | CC_STATE_DIR="$_OTMP/state" CC_MEMORY_DIR="$_OTMP/mem" \
    CC_EXTRACTION_KEY_FILE="$_OTMP/key/extraction-key" python3 "$_SETUP_PY" set-extraction-key 2>&1 || true)"
  _krc=0
  printf '%s' "$_kout" | grep -qF "$_fake" && _krc=1
  [ "$(cat "$_OTMP/key/extraction-key" 2>/dev/null)" = "$_fake" ] || _krc=1
  case "$(stat -c '%a' "$_OTMP/key/extraction-key" 2>/dev/null || stat -f '%Lp' "$_OTMP/key/extraction-key" 2>/dev/null)" in
    600) : ;; *) _krc=1 ;;
  esac
  [ "$_krc" -eq 0 ] && OK "set-extraction-key stdin 왕복(출력 무노출·0600)" \
    || FAIL "set-extraction-key stdin 왕복 실패 — 키 노출/권한/기록 회귀"
  rm -rf "$_OTMP"
else
  WARN "setup.py 미발견 또는 python3 없음 — 온보딩 기능 왕복 생략(정적 검사만 수행)"
fi

# ── 9c) install-viewer 실패 UX 토큰 계약(#13a·v0.1.9 설계 §7) ──
# 오프라인/프록시/차단 실패 시 install-viewer.sh 가 stderr 마지막 줄에 INSTALL_VIEWER_FAIL=<class>
# 를 반드시 emit(git 실패 분류 + die/set -e 는 trap 폴백=unknown) → ps1 Invoke-DashboardInstall 이
# 한국어 완료화면으로 매핑(#16). 토큰이 사라지면 오프라인 대시보드 UX 가 사일런트로 후퇴한다.
sec "9c) install-viewer 실패 토큰 계약(#13a)"
_IV="$(ls "$ROOTFS"/home/*/.claude/plugins/cache/cc-companion/cockpit/*/dashboard/install-viewer.sh 2>/dev/null | sort -V | tail -1 || true)"
[ -n "$_IV" ] || _IV="$(ls "$ROOTFS"/opt/cockpit/plugin/dashboard/install-viewer.sh 2>/dev/null | head -1 || true)"
[ -n "$_IV" ] || _IV="plugin/dashboard/install-viewer.sh"   # repo 폴백(소스 계약 검증)
if [ -f "$_IV" ] && command -v git >/dev/null 2>&1 && command -v python3 >/dev/null 2>&1; then
  _ivrc=0
  _ivt="$(mktemp -d)"
  cp "$_IV" "$_ivt/install-viewer.sh"
  # 프록시/보안제품 환경에서 git 이 자격증명 프롬프트로 걸리는 것 방지 + 있으면 timeout 백스톱(NIT).
  # env 는 리터럴 할당-프리픽스로(배열 확장은 bash 가 할당으로 인식 못 하고 명령어로 취급).
  command -v timeout >/dev/null 2>&1 && _TO="timeout 30" || _TO=""
  # (a) 분류 경로: 도달불가 호스트(.invalid = 예약 TLD, 네트워크 상태 무관 즉시 실패) → 클론 실패 →
  #     rc≠0 + 토큰(network/unknown 등). 어떤 클래스든 토큰 존재가 계약.
  printf 'VIEWER_REPO_URL=https://cockpit-smoke.invalid/x.git\nVIEWER_PIN=%040d\n' 0 > "$_ivt/viewer-pin.txt"
  _out="$(HOME="$_ivt" CC_DASH_HOME="$_ivt/home_a" CC_DASH_CONF="$_ivt/none.env" GIT_TERMINAL_PROMPT=0 $_TO bash "$_ivt/install-viewer.sh" 2>&1)"; _r=$?
  [ "$_r" -ne 0 ] || _ivrc=1
  printf '%s\n' "$_out" | tail -1 | grep -q 'INSTALL_VIEWER_FAIL=' || _ivrc=1
  # (b) trap 폴백: 형식 오류 핀(early die·클론 도달 전) → 토큰 unknown 보장.
  printf 'VIEWER_REPO_URL=https://cockpit-smoke.invalid/x.git\nVIEWER_PIN=not-hex\n' > "$_ivt/viewer-pin.txt"
  _out2="$(HOME="$_ivt" CC_DASH_HOME="$_ivt/home_b" CC_DASH_CONF="$_ivt/none.env" GIT_TERMINAL_PROMPT=0 $_TO bash "$_ivt/install-viewer.sh" 2>&1)"; _r2=$?
  [ "$_r2" -ne 0 ] || _ivrc=1
  printf '%s\n' "$_out2" | tail -1 | grep -q 'INSTALL_VIEWER_FAIL=unknown' || _ivrc=1
  rm -rf "$_ivt"
  [ "$_ivrc" -eq 0 ] && OK "install-viewer 실패 토큰 계약(분류 rc≠0 + trap 폴백 unknown·#16)" \
    || FAIL "install-viewer 실패 토큰 회귀 — 오프라인 대시보드 UX 사일런트 후퇴(#16/#13a)"
else
  WARN "install-viewer.sh 미발견 또는 git/python3 없음 — 실패 토큰 계약 검사 생략"
fi

# ── 결과 ──
echo ""
echo "────────────────────────────────────────────"
if [ "$fail" -eq 0 ]; then
  echo "[smoke-image] ✓ 스모크 통과 (경고 ${warns}건). 실제 wsl --import/--unregister 는 Windows smoke·배포자 실기에서 확인."
  exit 0
else
  echo "[smoke-image] ✗ 스모크 실패 — 위 [FAIL] 해소 필요. (경고 ${warns}건)"
  exit 1
fi
