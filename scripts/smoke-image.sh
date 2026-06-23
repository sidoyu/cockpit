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

# ── 6) 위험 기능 OFF 출고 불변식(핵심) ──
sec "6) 위험 기능 OFF 출고 불변식"
# (a) Codex 스위치 미존재
if find "$ROOTFS"/home "$ROOTFS"/root -name 'codex_enabled' 2>/dev/null | grep -q .; then
  FAIL "codex_enabled 스위치가 이미지에 구워짐 — OFF 출고 위반"
else OK "codex_enabled 스위치 없음"; fi
# (b) kill switch 사전생성 안 됨(사용자 동작이어야)
if find "$ROOTFS"/home "$ROOTFS"/root -name 'CC_KILL_SWITCH' 2>/dev/null | grep -q .; then
  WARN "CC_KILL_SWITCH 가 이미지에 존재(사용자 동작이어야 함 — 확인)"
else OK "CC_KILL_SWITCH 사전생성 없음"; fi
# (c) bypass 권한 설정 미적용
BADSET=""
while IFS= read -r s; do
  grep -qiE 'bypassPermissions|"dangerously|acceptEdits.*true' "$s" 2>/dev/null && BADSET="$BADSET ${s#$ROOTFS}"
done < <(find "$ROOTFS"/home "$ROOTFS"/root -path '*/.claude/settings*.json' 2>/dev/null)
[ -z "$BADSET" ] && OK "bypass/위험 권한 설정 미적용" || FAIL "위험 권한 설정 발견:$BADSET"
# (d) 원격 자동시작 없음 — systemd(system/user)·cron·rc.local·shell profile·skel 까지 폭넓게.
#     (Codex 지적: /etc/systemd 이름패턴만으론 user unit·cron·profile·rc.local 경로를 놓침)
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
  bycontent=$(grep -rIlE 'dashboard-run|active_server|cockpit[-_ ]*remote|disable-remote|--host[ =]*0\.0\.0\.0|--bind[ =]*0\.0\.0\.0' "${AUTO_DIRS[@]}" 2>/dev/null || true)
  AUTO_HITS="$(printf '%s\n%s\n' "$byname" "$bycontent" | grep -v '^$' | sort -u)"
fi
[ -z "$AUTO_HITS" ] && OK "원격 자동시작 흔적 없음(systemd·cron·rc·profile·skel)" || FAIL "원격 자동시작 흔적:$(echo "$AUTO_HITS" | sed "s|$ROOTFS||g" | tr '\n' ' ')"

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
