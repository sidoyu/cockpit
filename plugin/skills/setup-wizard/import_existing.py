#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""import_existing.py — 기존 Claude Code 환경의 기억·개인자산을 cockpit 으로 이관.

**이관은 로컬 파일 복사다. API 키도 외부 송신도 없다.**
(cockpit 의 추출용 API 키는 '앞으로의 새 기억 자동생성'용이며 이 기능과 무관하다.)

왜 필요한가: cockpit 은 별도 WSL 배포판에 **템플릿으로 fresh 시작**한다. 이미 Claude Code 를
쓰며 CLAUDE.md·기억을 쌓아온 사람에겐 그게 업그레이드가 아니라 '평행 환경 추가'가 된다.

무엇을 옮기나 (사실 기반 — 공식 문서 + 실측):
  · 기억      원본 `<src>/projects/<저장소>/memory/*.md` (내장 auto memory, **저장소별로 나뉨**)
              + `<src>/cc-memory/*.md` (이미 cockpit 형태였던 경우)
              → 전부 cockpit 기억 저장소(cc_paths.MEMORY_DIR) **한 곳**으로.
              저장소가 여럿이면 `debugging.md` 같은 흔한 이름이 겹치므로 출처 prefix 를 붙인다.
              색인 `MEMORY.md` 는 **복사하지 않는다** — rebuild_memory_index 가 재생성한다.
  · 개인자산  rules/ commands/ agents/ skills/ output-styles/ themes/ workflows/ keybindings.json
  · CLAUDE.md 3지선다(기본=통합). 어느 쪽이든 원본 백업 → 가역.
  · settings  **allowlist 딥머지**. cockpit 운영키(플러그인 활성·bypass 배선·원격·기억 배선)는
              cockpit 이 이긴다. model/effort 는 요금제 의존이라 회원 값을 존중한다.

무엇을 절대 안 옮기나 (자격증명·런타임 상태·거대 로그):
  `.credentials.json`(OAuth) · `~/.claude.json`(앱상태·기기ID·trust) · `projects/**/*.jsonl`(트랜스크립트)
  · statsig/ shell-snapshots/ todos/ history.jsonl · plugins/(캐시) · cc-companion/(운영 상태)
  hooks·mcpServers 는 **탐지해서 보고만** 한다: 훅 명령은 절대경로 셸 명령이고 원본이 네이티브
  Windows 였다면 `.ps1`/`.cmd` 라 WSL 에서 매 세션 실패한다(win-hooks 가 존재하는 이유).
  MCP 서버는 애초에 settings.json 에 없다(`~/.claude.json` / 프로젝트 `.mcp.json`).

안전 규율(데이터 기능):
  ① dry-run 기본  ② 원본(대상측) 백업 = backup.py 재사용  ③ **삭제 0 · 순수 additive**
  ④ staging 에서 색인 재생성이 통과해야만 실물 배치  ⑤ 심링크 미추종  ⑥ 소스는 읽기 전용
  ⑦ 재실행 멱등(같은 내용 = skip)

사용:
  python3 import_existing.py detect
  python3 import_existing.py plan  [--source PATH] [--claude-md merge|cockpit|mine] [--no-assets]
  python3 import_existing.py apply [동일 옵션]
  python3 import_existing.py adopt-native            # 이 배포판 안의 고아 auto memory 흡수
"""
import sys, os, re, json, time, shutil, hashlib, argparse, subprocess, unicodedata

_HERE = os.path.dirname(os.path.realpath(__file__))
PLUGIN_ROOT = os.path.dirname(os.path.dirname(_HERE))
MEM_HOOKS = os.path.join(PLUGIN_ROOT, "hooks", "memory")
TEMPLATES = os.path.join(PLUGIN_ROOT, "templates")
if MEM_HOOKS not in sys.path:
    sys.path.insert(0, MEM_HOOKS)

import cc_paths                                    # noqa: E402
from rebuild_memory_index import read_desc         # noqa: E402  (단일 출처 — 판정 규칙 중복 금지)

HOME = os.path.expanduser("~")
MEMORY_DIR = cc_paths.MEMORY_DIR
STATE_DIR = cc_paths.STATE_DIR
ARCHIVE_DIR = cc_paths.ARCHIVE_DIR
CLAUDE_MD = os.path.join(HOME, ".claude", "CLAUDE.md")
SETTINGS = os.path.join(HOME, ".claude", "settings.json")
REBUILD = os.path.join(MEM_HOOKS, "rebuild_memory_index.py")
BACKUP = os.path.join(MEM_HOOKS, "backup.py")

OK, WARN, BAD, INFO = "✓", "⚠", "✗", "·"
MAX_MD_BYTES = 512 * 1024          # 이보다 큰 .md 는 기억이 아니라 문서 덤프 — 보관함으로
CMD_EXE = "/mnt/c/Windows/System32/cmd.exe"
WSL_EXE = "/mnt/c/Windows/System32/wsl.exe"

ASSET_DIRS = ["rules", "commands", "agents", "skills", "output-styles", "themes", "workflows"]
ASSET_FILES = ["keybindings.json"]

# settings 딥머지 정책 — 명시 allowlist 만 받는다(모르는 키는 보고만; 조용한 흡수 금지).
USER_WINS_SCALARS = ["model", "effortLevel"]        # 요금제 의존 → 강제하지 않음(타 요금제서 클램프/거부)
COSMETIC_SCALARS = ["theme", "tui", "outputStyle", "spinnerTipsEnabled"]
# permissions: **안전을 늘리는 쪽만** 자동 병합한다. `allow` 는 회원 환경의 느슨한 허용
# (`Bash(rm:*)` 등)을 cockpit 운영환경으로 승격시켜 **이관이 권한 확대**가 된다(Codex 4f).
# → allow 는 기본 보고만, `--accept-permissions-allow` 로 명시 동의했을 때만 병합.
UNION_ARRAYS = [("permissions", "deny"), ("permissions", "ask")]
ALLOW_KEY = ("permissions", "allow")
TOP_UNION_ARRAYS = ["claudeMdExcludes"]
COCKPIT_OWNED = ["enabledPlugins", "extraKnownMarketplaces", "autoMemoryDirectory",
                 "remoteControlAtStartup", "agentPushNotifEnabled", "respondToBashCommands",
                 "skipDangerousModePermissionPrompt", "hooks"]

IMPORT_BEGIN = "<!-- COCKPIT:IMPORTED-CLAUDE-MD:BEGIN -->"
IMPORT_END = "<!-- COCKPIT:IMPORTED-CLAUDE-MD:END -->"
# 사람이 봐야 하는 줄(자동 해소 금지). 휴리스틱임을 정직하게 밝힌다 — 놓칠 수 있다.
REVIEW_PATTERNS = [
    (r'(?i)\b(english|영어로|in\s+english)\b', "언어 지시(영어)"),
    (r'(?i)\b(korean|한국어)\b', "언어 지시(한국어)"),
    (r'(?i)bypass|permissions?\s*[:=]', "권한/bypass 관련 지시"),
    (r'rm\s+-rf|curl[^|\n]*\|\s*(ba)?sh|DROP\s+TABLE', "파괴적 명령 문구"),
]


def _p(mark, msg):
    print("  %s %s" % (mark, msg))


def _sha(path):
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for b in iter(lambda: f.read(65536), b""):
            h.update(b)
    return h.hexdigest()


def _key(name):
    """파일명 충돌 판정 키. `/mnt/c`(대소문자 무시)와 ext4(구분)의 경계를 넘으므로 casefold 하고,
    macOS/iCloud 유래 NFD 한글 파일명과 NFC 를 같은 이름으로 본다(자모 분리 = 다른 바이트열)."""
    return unicodedata.normalize("NFC", name).casefold()


def _slug(key):
    """프로젝트 키(`-mnt-c-Users-PC-repo-foo`) → 짧고 안전한 출처 prefix."""
    parts = [p for p in re.split(r'[-/\\]', key) if p]
    s = "-".join(parts[-2:]) if len(parts) >= 2 else (parts[0] if parts else "src")
    s = re.sub(r'[^A-Za-z0-9._]', '-', s).strip('-') or "src"
    return s[:40]


# ───────────────────────────── 탐지(읽기 전용) ─────────────────────────────
def _win_to_wsl(win):
    """Windows 경로 → WSL 경로. wslpath 우선, 없으면 결정적 변환."""
    try:
        r = subprocess.run(["wslpath", "-u", win], capture_output=True, text=True,
                           timeout=10, stdin=subprocess.DEVNULL)
        p = r.stdout.strip()
        if p:
            return p
    except Exception:
        pass
    m = re.match(r'^([A-Za-z]):[\\/](.*)$', win)
    if not m:
        return None
    return "/mnt/%s/%s" % (m.group(1).lower(), m.group(2).replace("\\", "/"))


def _win_userprofile():
    """현재 Windows 사용자 프로필의 WSL 경로. `/mnt/c/Users/*` 전체 훑기는 하지 않는다
    (타인 프로필 오스캔 위험) — interop 으로 %USERPROFILE% 을 정확히 물어본다.

    인코딩: cmd.exe 는 OEM 코드페이지로 출력한다(한국어 Windows = CP949). 사용자명이 한글이면
    UTF-8 디코드가 깨진다 → 후보 인코딩을 순서대로 시도하고 **실제로 존재하는 경로**를 채택한다
    (존재검사만 하므로 오탐이 파괴적 동작으로 이어지지 않는다)."""
    if not os.path.exists(CMD_EXE):
        return None, "Windows 상호운용(cmd.exe) 없음 — cockpit WSL 배포판 안에서 실행하세요."
    try:
        # `/U` = cmd 가 파이프로 **UTF-16LE** 를 내보낸다(코드페이지 의존 제거). 실패 시 아래 다중 디코드.
        r = subprocess.run([CMD_EXE, "/U", "/c", "echo %USERPROFILE%"], capture_output=True,
                           timeout=20, cwd="/mnt/c", stdin=subprocess.DEVNULL)
        raw = r.stdout if r.returncode == 0 else b""
    except Exception as e:
        return None, "USERPROFILE 조회 실패: %s" % e
    if not raw:
        return None, "USERPROFILE 조회 실패(cmd.exe 비정상 종료)"

    first = None
    for enc in ("utf-16-le", "utf-8", "cp949", "cp932", "cp1252", "latin-1"):
        try:
            txt = raw.decode(enc)
        except Exception:
            continue
        win = next((l.strip() for l in txt.splitlines() if ":" in l and "\\" in l), "")
        if not win or win.startswith("%"):
            continue
        p = _win_to_wsl(win)
        if not p:
            continue
        first = first or p
        if os.path.isdir(p):
            return p, None
    if first:
        return None, "USERPROFILE 경로가 존재하지 않음(문자 인코딩 문제 가능): %s" % first
    return None, "USERPROFILE 값을 읽지 못함"


def _other_distros():
    """다른 WSL 배포판 이름(안내용). MVP 는 여기서 **읽지 않는다** — 홈 경로·uid·권한·용량을
    미리 알 수 없어 사고 표면이 넓다(Codex 4f). 존재만 알리고 수동 경로 지정을 권한다."""
    if not os.path.exists(WSL_EXE):
        return []
    try:
        r = subprocess.run([WSL_EXE, "-l", "-q"], capture_output=True, timeout=25,
                           stdin=subprocess.DEVNULL)
        # wsl.exe 출력은 UTF-16LE 다(NUL 섞임) — 그냥 decode 하면 깨진다.
        txt = r.stdout.decode("utf-16-le", "ignore")
    except Exception:
        return []
    me = os.environ.get("WSL_DISTRO_NAME", "")
    out = []
    for ln in txt.splitlines():
        n = ln.strip().strip("\x00")
        if not n or n == me or n.startswith("cc-"):   # 자기 자신·다른 cockpit 제외(재이관은 backup.py 영역)
            continue
        out.append(n)
    return out


def _looks_like_claude_dir(p):
    if not os.path.isdir(p):
        return False
    for probe in ("CLAUDE.md", "settings.json", "projects", "cc-memory"):
        if os.path.exists(os.path.join(p, probe)):
            return True
    return False


def detect(quiet=False):
    """소스 후보를 찾는다(읽기 전용). 반환 = (자동탐지 경로 or None, 안내 리스트)."""
    notes, found = [], None
    prof, err = _win_userprofile()
    if prof:
        cand = os.path.join(prof, ".claude")
        if _looks_like_claude_dir(cand):
            found = cand
            notes.append((OK, "Windows 사용자 프로필에서 발견: %s" % cand))
        else:
            notes.append((INFO, "Windows 프로필에 기존 Claude Code 설정 없음(%s)" % cand))
    else:
        notes.append((INFO, "Windows 프로필 자동탐지 불가 — %s" % err))

    others = _other_distros()
    if others:
        notes.append((WARN, "다른 WSL 배포판 발견: %s — 자동 이관 대상이 아닙니다. 그 안에서 "
                            "`cp -r ~/.claude /mnt/c/Users/<당신>/claude-backup` 처럼 꺼낸 뒤 "
                            "`--source` 로 지정하세요." % ", ".join(others)))
    if not quiet:
        print("[cockpit import] 소스 탐지\n")
        for m, t in notes:
            _p(m, t)
        if not found:
            _p(INFO, "자동탐지 실패 시: import_existing.py plan --source <경로>")
    return found, notes


# ───────────────────────────── 소스 분류 ─────────────────────────────
def _load_json(p):
    try:
        with open(p, encoding="utf-8") as f:
            d = json.load(f)
        return d if isinstance(d, dict) else None
    except Exception:
        return None


def _memory_dirs(src):
    """(디렉터리, 출처키) 목록. cockpit 형태 + 내장 auto memory(저장소별) + 커스텀 위치."""
    dirs = []
    cc = os.path.join(src, "cc-memory")
    if os.path.isdir(cc):
        dirs.append((cc, "cc"))
    projects = os.path.join(src, "projects")
    if os.path.isdir(projects):
        for pk in sorted(os.listdir(projects)):
            d = os.path.join(projects, pk, "memory")
            if os.path.isdir(d):
                dirs.append((d, pk))
    return dirs


def _custom_auto_memory(src, settings):
    """소스 settings 의 autoMemoryDirectory(커스텀 경로) — 놓치면 '기억 없음' 오판(Codex 발견).

    단, 소스 settings 는 **신뢰할 수 없는 입력**이다. 절대경로를 그대로 따라가면 `--source` 로 준
    범위 밖(예: /etc, 타 사용자 홈)을 스캔하게 된다 → **소스 홈 아래에 있을 때만** 채택하고
    벗어나면 보고만 한다(Codex 4f)."""
    amd = (settings or {}).get("autoMemoryDirectory")
    if not isinstance(amd, str) or not amd:
        return None, None
    src_home = os.path.realpath(os.path.dirname(src))
    cand = os.path.join(src_home, amd[2:]) if amd.startswith("~/") else amd
    cand = os.path.realpath(cand)
    inside = cand == src_home or cand.startswith(src_home + os.sep)
    if inside and os.path.isdir(cand):
        return cand, None
    if not inside:
        return None, ("소스가 홈 밖의 커스텀 기억 위치를 가리킵니다(autoMemoryDirectory=%s) — "
                      "자동으로 읽지 않습니다. 필요하면 그 경로를 --source 로 직접 지정하세요." % amd)
    return None, ("소스가 커스텀 기억 위치를 씁니다(autoMemoryDirectory=%s) — 이 배포판에서 접근 "
                  "불가. 그 폴더를 --source 로 따로 지정하거나 수동 복사하세요." % amd)


def _native_memory_dirs(src):
    """내장 auto memory 만(cc-memory 제외). adopt-native 가 쓴다 — 대상 자신을 소스로 삼지 않기 위해."""
    projects = os.path.join(src, "projects")
    if not os.path.isdir(projects):
        return []
    return [(os.path.join(projects, pk, "memory"), pk)
            for pk in sorted(os.listdir(projects))
            if os.path.isdir(os.path.join(projects, pk, "memory"))]


def _classify_memory(src, dirs_fn=None):
    """반환 (plan_files, archive_files, skipped, warns).
    plan_files = [(원본, 대상파일명, has_desc)] · archive_files = [(원본, 사유)]"""
    settings = _load_json(os.path.join(src, "settings.json"))
    dirs = (dirs_fn or _memory_dirs)(src)
    custom, cwarn = _custom_auto_memory(src, settings) if dirs_fn is None else (None, None)
    warns = []
    if cwarn:
        warns.append(cwarn)
    if custom:
        dirs.append((custom, "custom"))

    existing = {}
    if os.path.isdir(MEMORY_DIR):
        for n in os.listdir(MEMORY_DIR):
            fp = os.path.join(MEMORY_DIR, n)
            if n.endswith(".md") and os.path.isfile(fp):
                existing[n] = _sha(fp)
    # 충돌 판정은 NFC+casefold. 소스가 /mnt/c(대소문자 무시)라도 대상 홈은 ext4(구분)라
    # `Debugging.md` 와 `debugging.md` 가 나란히 놓일 수 있고, 그러면 rebuild 의 unique lint
    # (파일명 소문자 비교·치명)에 걸려 색인이 언다.
    used = set(_key(n) for n in existing)

    plan, archive, skipped = [], [], []
    for d, key in dirs:
        slug = _slug(key)
        for name in sorted(os.listdir(d)):
            sp = os.path.join(d, name)
            if os.path.islink(sp):
                skipped.append((sp, "심링크(미추종 — 경로 탈출 방지)"))
                continue
            if not os.path.isfile(sp):
                continue
            if not name.endswith(".md"):
                skipped.append((sp, "마크다운 아님"))
                continue
            if name == "MEMORY.md":
                archive.append((sp, "색인은 재생성 대상 — 원본은 보관함에만"))
                continue
            if name == "PROJECT_STATUS.md":
                archive.append((sp, "대상 환경의 PROJECT_STATUS 가 권위 — 원본은 보관함에만"))
                continue
            try:
                size = os.path.getsize(sp)
            except OSError as e:
                skipped.append((sp, "읽기 실패: %s" % e))
                continue
            if size > MAX_MD_BYTES:
                archive.append((sp, "%dKB — 기억 한 조각이 아님(보관함으로)" % (size // 1024)))
                continue
            sha = _sha(sp)
            if any(sha == v for v in existing.values()):
                skipped.append((sp, "대상에 동일 내용 이미 있음(멱등)"))
                continue

            dest = name
            if _key(dest) in used:
                dest = "%s__%s" % (slug, name)
            if _key(dest) in used:
                dest = "%s__%s__%s.md" % (slug, name[:-3], sha[:8])
            if _key(dest) in used:
                skipped.append((sp, "대상 파일명 충돌 해소 실패"))
                continue
            used.add(_key(dest))
            desc, err = read_desc(sp)
            plan.append((sp, dest, desc is not None))
    return plan, archive, skipped, warns


def _classify_assets(src):
    """개인 자산 — 대상에 없는 파일만 복사(additive). 심링크·실행파일 표시."""
    add, skip = [], []
    for d in ASSET_DIRS:
        sd = os.path.join(src, d)
        if not os.path.isdir(sd):
            continue
        for root, _dirs, files in os.walk(sd):
            for fn in sorted(files):
                sp = os.path.join(root, fn)
                if os.path.islink(sp):
                    skip.append((sp, "심링크(미추종)"))
                    continue
                rel = os.path.relpath(sp, src)
                dp = os.path.join(HOME, ".claude", rel)
                if os.path.exists(dp):
                    skip.append((sp, "대상에 이미 있음(보존)"))
                    continue
                add.append((sp, dp))
    for fn in ASSET_FILES:
        sp = os.path.join(src, fn)
        if not os.path.isfile(sp) or os.path.islink(sp):
            continue
        dp = os.path.join(HOME, ".claude", fn)
        if os.path.exists(dp):
            skip.append((sp, "대상에 이미 있음(보존)"))
        else:
            add.append((sp, dp))
    return add, skip


def _review_lines(text):
    hits = []
    for i, ln in enumerate(text.splitlines(), 1):
        for pat, label in REVIEW_PATTERNS:
            if re.search(pat, ln):
                hits.append("%d행 %s: %s" % (i, label, ln.strip()[:70]))
                break
    return hits


def _settings_merge(src_settings, dst_settings, accept_allow=False):
    """allowlist 딥머지 → (merged, accepted[], reported[], allow_rules[]).
    cockpit 운영키는 무조건 대상 유지(플러그인 활성키가 빠지면 cockpit 이 사실상 죽는다)."""
    merged = json.loads(json.dumps(dst_settings))   # deep copy
    accepted, reported, allow_rules = [], [], []
    if not src_settings:
        return merged, accepted, reported, allow_rules

    for k in USER_WINS_SCALARS + COSMETIC_SCALARS:
        if k in src_settings:
            merged[k] = src_settings[k]
            accepted.append("%s = %r" % (k, src_settings[k]))
    for k in TOP_UNION_ARRAYS:
        sv, dv = src_settings.get(k), merged.get(k)
        if isinstance(sv, list):
            base = dv if isinstance(dv, list) else []
            out = list(base) + [x for x in sv if x not in base]
            if out != base:
                merged[k] = out
                accepted.append("%s += %d개" % (k, len(out) - len(base)))
    for parent, child in UNION_ARRAYS:
        sv = (src_settings.get(parent) or {}).get(child)
        if not isinstance(sv, list):
            continue
        base = (merged.get(parent) or {}).get(child) or []
        out = list(base) + [x for x in sv if x not in base]
        if out != base:
            merged.setdefault(parent, {})[child] = out
            accepted.append("permissions.%s += %d개(안전을 늘리는 방향)" % (child, len(out) - len(base)))

    # permissions.allow — 기본 미병합(권한 확대 방지). 목록은 그대로 보여준다.
    parent, child = ALLOW_KEY
    sv = (src_settings.get(parent) or {}).get(child)
    if isinstance(sv, list) and sv:
        base = (merged.get(parent) or {}).get(child) or []
        new_rules = [x for x in sv if x not in base]
        allow_rules = new_rules
        if new_rules and accept_allow:
            merged.setdefault(parent, {})[child] = list(base) + new_rules
            accepted.append("permissions.allow += %d개 (--accept-permissions-allow 명시 동의)" % len(new_rules))

    known = set(USER_WINS_SCALARS + COSMETIC_SCALARS + TOP_UNION_ARRAYS + COCKPIT_OWNED
                + ["permissions"])
    for k in sorted(src_settings):
        if k in known:
            continue
        reported.append(k)
    if "hooks" in src_settings:
        reported.append("hooks(자동병합 안 함 — 원본이 Windows 명령이면 WSL 에서 매 세션 실패)")
    for k in COCKPIT_OWNED:
        if k in src_settings and k != "hooks":
            reported.append("%s(cockpit 운영키 — 대상 값 유지)" % k)
    sp = (src_settings.get("permissions") or {})
    if "defaultMode" in sp:
        reported.append("permissions.defaultMode(cockpit 운영키 — 대상 값 유지)")
    return merged, accepted, reported, allow_rules


def _external_notes(src):
    """settings.json 밖의 자산 — 보고만."""
    notes = []
    home = os.path.dirname(src)
    cj = os.path.join(home, ".claude.json")
    d = _load_json(cj)
    if d:
        n = len((d.get("mcpServers") or {}))
        per = sum(len((v or {}).get("mcpServers") or {}) for v in (d.get("projects") or {}).values())
        if n or per:
            notes.append("MCP 서버 %d개(전역) + %d개(프로젝트) 발견 — **자동 이관 안 함**. "
                         "settings.json 이 아니라 ~/.claude.json 에 있고, env 에 시크릿이 섞이거나 "
                         "Windows 명령 경로일 수 있습니다. 새 환경에서 다시 등록하세요." % (n, per))
        notes.append("~/.claude.json 은 복사하지 않습니다(로그인 토큰·기기ID·trust 가 섞인 앱 상태).")
    if os.path.exists(os.path.join(src, ".credentials.json")):
        notes.append(".credentials.json 은 복사하지 않습니다 — 새 환경에서 `/login` 으로 재인증하세요.")
    return notes


# ───────────────────────────── 계획 · 출력 ─────────────────────────────
def _asset_secret_hits(assets):
    """이관될 개인자산 안에 키처럼 보이는 문자열이 있으면 **보고**한다(차단은 않음 — 회원 본인 파일).
    스킬/명령어는 텍스트지만 스크립트를 품을 수 있다."""
    from rebuild_memory_index import SECRET_PATTERNS
    hits = []
    for sp, _dp in assets:
        try:
            if os.path.getsize(sp) > 1024 * 1024:
                continue
            with open(sp, encoding="utf-8", errors="ignore") as f:
                txt = f.read()
        except Exception:
            continue
        for p in SECRET_PATTERNS:
            if re.search(p, txt):
                hits.append(os.path.basename(sp))
                break
    return hits


def build_plan(src, claude_md_mode, want_assets, accept_allow=False):
    if not _looks_like_claude_dir(src):
        return None, "소스가 Claude Code 설정 폴더로 보이지 않습니다: %s" % src
    if os.path.realpath(src) == os.path.realpath(os.path.join(HOME, ".claude")):
        return None, "소스가 현재 환경 자신입니다 — 이관할 것이 없습니다(고아 기억 흡수는 adopt-native)."

    mem, archive, skipped, warns = _classify_memory(src)
    assets, asset_skip = (_classify_assets(src) if want_assets else ([], []))
    src_settings = _load_json(os.path.join(src, "settings.json"))
    dst_settings = _load_json(SETTINGS) or {}
    merged, accepted, reported, allow_rules = _settings_merge(src_settings, dst_settings, accept_allow)
    src_md = os.path.join(src, "CLAUDE.md")
    md_text = ""
    if os.path.isfile(src_md) and not os.path.islink(src_md):
        with open(src_md, encoding="utf-8", errors="replace") as f:
            md_text = f.read()
    return {
        "src": src, "memory": mem, "archive": archive, "skipped": skipped, "warns": warns,
        "assets": assets, "asset_skip": asset_skip, "claude_md_mode": claude_md_mode,
        "claude_md_text": md_text, "review": _review_lines(md_text) if md_text else [],
        "settings_merged": merged, "settings_accepted": accepted, "settings_reported": reported,
        "allow_rules": allow_rules, "accept_allow": accept_allow,
        "asset_secrets": _asset_secret_hits(assets),
        "external": _external_notes(src),
    }, None


def print_plan(pl):
    no_desc = [d for _s, d, ok in pl["memory"] if not ok]
    print("\n[발견]")
    _p(INFO, "소스: %s" % pl["src"])
    _p(INFO, "기억 파일 %d개 · 개인자산 %d개 · CLAUDE.md %s"
       % (len(pl["memory"]), len(pl["assets"]), "있음" if pl["claude_md_text"] else "없음"))

    print("\n[적용예정]")
    for s, d, has in pl["memory"][:20]:
        _p(OK, "%s → cc-memory/%s%s" % (os.path.basename(s), d, "" if has else "  (설명 자동도출)"))
    if len(pl["memory"]) > 20:
        _p(INFO, "… 외 %d개" % (len(pl["memory"]) - 20))
    for s, d in pl["assets"][:10]:
        _p(OK, "%s → %s" % (os.path.relpath(s, pl["src"]), os.path.relpath(d, HOME)))
    if len(pl["assets"]) > 10:
        _p(INFO, "… 외 %d개 자산" % (len(pl["assets"]) - 10))
    mode = {"merge": "통합(cockpit 규칙 + 이전 개인 규칙 섹션)",
            "cockpit": "cockpit 규칙만 유지(원본은 보관함)",
            "mine": "이전 CLAUDE.md 로 교체"}[pl["claude_md_mode"]]
    if pl["claude_md_text"]:
        _p(OK, "CLAUDE.md: %s" % mode)
    for a in pl["settings_accepted"]:
        _p(OK, "settings: %s" % a)

    print("\n[건너뜀]")
    if not pl["skipped"] and not pl["asset_skip"]:
        _p(INFO, "없음")
    for s, why in (pl["skipped"] + pl["asset_skip"])[:12]:
        _p(INFO, "%s — %s" % (os.path.basename(s), why))
    if len(pl["skipped"]) + len(pl["asset_skip"]) > 12:
        _p(INFO, "… 외 %d개" % (len(pl["skipped"]) + len(pl["asset_skip"]) - 12))

    print("\n[충돌·격리(보관함으로만 복사)]")
    if not pl["archive"]:
        _p(INFO, "없음")
    for s, why in pl["archive"]:
        _p(WARN, "%s — %s" % (os.path.basename(s), why))

    print("\n[사용자 선택 필요 · 사람 검토]")
    if pl["review"]:
        _p(WARN, "CLAUDE.md 에 검토가 필요한 줄(휴리스틱 — 놓칠 수 있음):")
        for r in pl["review"][:8]:
            _p(INFO, "  %s" % r)
    if pl["allow_rules"] and not pl["accept_allow"]:
        _p(WARN, "권한 허용 규칙 %d개는 **병합하지 않았습니다**(이관이 권한 확대가 되지 않도록). "
                 "그대로 가져오려면 --accept-permissions-allow:" % len(pl["allow_rules"]))
        for r in pl["allow_rules"][:10]:
            _p(INFO, "  allow: %s" % r)
    if pl["settings_reported"]:
        _p(WARN, "자동 병합하지 않은 settings 키: %s" % ", ".join(pl["settings_reported"][:10]))
    if not pl["review"] and not pl["settings_reported"] and not pl["allow_rules"]:
        _p(INFO, "없음")

    print("\n[위험경고]")
    if no_desc:
        _p(WARN, "description 없는 기억 %d개 — 색인 설명은 문서 제목에서 도출하고, 제목이 없거나 "
                 "민감해 보이면 자리표시자를 씁니다(원문 무손상). 나중에 직접 다듬으면 검색이 좋아집니다."
           % len(no_desc))
    if pl["asset_secrets"]:
        _p(WARN, "이관될 개인자산에 키처럼 보이는 문자열: %s — 옮기기 전에 확인하세요."
           % ", ".join(pl["asset_secrets"][:6]))
    if pl["accept_allow"] and pl["allow_rules"]:
        _p(WARN, "--accept-permissions-allow: 권한 허용 규칙 %d개를 그대로 들여옵니다(권한 확대)."
           % len(pl["allow_rules"]))
    for w in pl["warns"] + pl["external"]:
        _p(WARN, w)
    if pl["claude_md_mode"] == "mine":
        _p(WARN, "'이전 CLAUDE.md 로 교체'를 골랐습니다 — cockpit 의 자동 동작·안전 규율 대부분이 "
                 "설명되지 않은 채로 남습니다(왜 깔았는지 무색해질 수 있음).")
    if not no_desc and not pl["warns"] and not pl["external"] and not pl["asset_secrets"] \
            and pl["claude_md_mode"] != "mine":
        _p(INFO, "없음")

    print("\n[원복위치]")
    _p(INFO, "apply 직전 backup.py 가 기억·상태·CLAUDE.md·settings 를 tar.gz 로 백업합니다"
             "(CC_BACKUP_DIR, 재설치 생존하려면 /mnt/<드라이브>/ 아래여야 함).")
    _p(INFO, "소스(%s)는 **읽기만** 하며 변경하지 않습니다." % pl["src"])
    # 정직하게: 이건 원자적 트랜잭션이 아니다. 다만 모든 단계가 additive·멱등이라 재실행이 이어붙는다.
    _p(INFO, "이관 도중 중단되면 **같은 명령을 다시 실행**하세요(멱등 — 이미 된 것은 건너뜁니다). "
             "되돌리려면 위 백업 tar.gz 를 풉니다. 삭제·덮어쓰기는 하지 않습니다.")


# ───────────────────────────── 적용 ─────────────────────────────
def _run_backup():
    if not os.path.exists(BACKUP):
        return False, "backup.py 없음"
    try:
        r = subprocess.run([sys.executable, BACKUP], capture_output=True, text=True,
                           timeout=600, stdin=subprocess.DEVNULL)
    except Exception as e:
        return False, str(e)
    return (r.returncode == 0), (r.stdout or "") + (r.stderr or "")


def _rebuild(mem_dir, *args):
    env = dict(os.environ, CC_MEMORY_DIR=mem_dir)
    try:
        r = subprocess.run([sys.executable, REBUILD] + list(args), capture_output=True,
                           text=True, timeout=120, env=env, stdin=subprocess.DEVNULL)
    except Exception as e:
        return -1, str(e)
    return r.returncode, (r.stdout or "") + (r.stderr or "")


def _archive(files, ts):
    if not files:
        return
    dst = os.path.join(ARCHIVE_DIR, "imported-%s" % ts)
    os.makedirs(dst, exist_ok=True)
    for sp, _why in files:
        base = os.path.basename(sp)
        tgt = os.path.join(dst, base)
        i = 1
        while os.path.exists(tgt):
            tgt = os.path.join(dst, "%s-%d%s" % (base[:-3], i, ".md"))
            i += 1
        shutil.copy2(sp, tgt)
    _p(OK, "보관함에 원본 복사: %s" % dst)


def _atomic_write(path, text):
    """중간에 죽어도 잘린 파일을 남기지 않는다(CLAUDE.md 는 행동 규율 — 잘리면 안전망이 반쯤 사라짐)."""
    d = os.path.dirname(path)
    os.makedirs(d, exist_ok=True)
    tmp = os.path.join(d, ".%s.import-tmp" % os.path.basename(path))
    try:
        with open(tmp, "w", encoding="utf-8") as f:
            f.write(text)
            f.flush()
            os.fsync(f.fileno())
        os.replace(tmp, path)
    except Exception:
        try:
            os.unlink(tmp)
        except OSError:
            pass
        raise


def _merge_claude_md(mode, src_text):
    if not src_text:
        return
    if mode == "cockpit":
        _p(INFO, "CLAUDE.md: cockpit 규칙 유지(원본은 보관함에 보존됨)")
        return
    if mode == "mine":
        _atomic_write(CLAUDE_MD, src_text)
        _p(OK, "CLAUDE.md: 이전 개인 규칙으로 교체(백업본으로 원복 가능)")
        return
    cur = ""
    if os.path.exists(CLAUDE_MD):
        with open(CLAUDE_MD, encoding="utf-8") as f:
            cur = f.read()
    # 블록에 타임스탬프를 넣지 않는다 — 넣으면 재실행마다 바이트가 달라져 **멱등이 깨진다**
    # (언제 이관했는지는 백업 tar.gz·보관함 디렉터리명이 이미 갖고 있다).
    block = "\n".join([
        IMPORT_BEGIN,
        "",
        "## 이전 개인 규칙 (이관됨 · 원문 보존)",
        "",
        "> 이관 전 환경의 `~/.claude/CLAUDE.md` 원문이다. 위쪽 cockpit 규칙과 충돌하면 **위쪽이 우선**한다.",
        "> 읽어 보고 직접 정리할 것. 이 블록은 다시 import 하면 통째로 교체된다.",
        "",
        src_text.rstrip(),
        "",
        IMPORT_END,
        "",
    ])
    pat = re.compile(re.escape(IMPORT_BEGIN) + r'.*?' + re.escape(IMPORT_END) + r'\n?', re.S)
    new = pat.sub(lambda _m: block, cur) if IMPORT_BEGIN in cur else (cur.rstrip() + "\n\n---\n\n" + block)
    if new == cur:
        _p(OK, "CLAUDE.md: 이미 통합됨 — 변경 없음(멱등)")
        return
    _atomic_write(CLAUDE_MD, new)
    _p(OK, "CLAUDE.md: 통합(구분 섹션으로 원문 흡수 · 재실행 시 그 블록만 교체)")


def apply_plan(pl, do_backup=True):
    ts = time.strftime("%Y%m%d-%H%M%S")
    print("\n[적용 시작] %s" % ts)

    if do_backup:
        ok, out = _run_backup()
        if not ok:
            _p(BAD, "백업 실패 — 적용 중단(원본 보호). %s" % out.strip()[:200])
            return 2
        _p(OK, "백업 완료(backup.py)")
        # 백업이 배포판 **안**에 있으면 재설치(wsl --unregister) 때 함께 사라진다 — 그대로 전달.
        for ln in out.splitlines():
            s = ln.strip().lstrip("⚠").strip()
            if s and ("재설치" in s or "민감정보" in s):
                _p(WARN, s[:160])
    else:
        _p(WARN, "--no-backup 지정 — 테스트 경로")

    # 1) staging 에서 색인 재생성이 통과하는지 먼저 증명(대상 무접촉)
    stage = os.path.join(STATE_DIR, "import-%s" % ts, "staging-memory")
    os.makedirs(stage, exist_ok=True)
    if os.path.isdir(MEMORY_DIR):
        for n in os.listdir(MEMORY_DIR):
            fp = os.path.join(MEMORY_DIR, n)
            if os.path.isfile(fp):
                shutil.copy2(fp, os.path.join(stage, n))
    for sp, dest, _has in pl["memory"]:
        shutil.copy2(sp, os.path.join(stage, dest))
    rc, out = _rebuild(stage, "--apply", "--no-diff", "--sid", "import")
    if rc != 0:
        _p(BAD, "staging 색인 재생성 실패 — 적용 중단(대상 무접촉). staging=%s" % stage)
        print(out.strip()[:800])
        return 2
    _p(OK, "staging 색인 재생성 통과(%d개 신규 기억)" % len(pl["memory"]))

    # 2) 실물 배치 — **staging 에서** 복사한다(원본에서 다시 읽지 않는다).
    #    원본은 /mnt/c 에 있어 plan~apply 사이에 바뀔 수 있고, 그러면 '검증한 것'과 '배치한 것'이
    #    달라진다(TOCTOU, Codex 4f). 덮어쓰기 없음(존재하면 건너뜀).
    os.makedirs(MEMORY_DIR, exist_ok=True)
    placed = 0
    for _sp, dest, _has in pl["memory"]:
        dp = os.path.join(MEMORY_DIR, dest)
        if os.path.exists(dp):
            continue
        shutil.copy2(os.path.join(stage, dest), dp)
        placed += 1
    _p(OK, "기억 %d개 배치(검증된 staging 사본에서 · 덮어쓴 파일 0)" % placed)

    _archive(pl["archive"], ts)

    for sp, dp in pl["assets"]:
        if os.path.exists(dp):
            continue
        os.makedirs(os.path.dirname(dp), exist_ok=True)
        shutil.copy2(sp, dp)
    if pl["assets"]:
        _p(OK, "개인자산 %d개 배치(기존 파일 보존)" % len(pl["assets"]))

    _merge_claude_md(pl["claude_md_mode"], pl["claude_md_text"])

    # 3) settings — allowlist 딥머지
    if pl["settings_accepted"]:
        os.makedirs(os.path.dirname(SETTINGS), exist_ok=True)
        tmp = SETTINGS + ".import-tmp"
        with open(tmp, "w", encoding="utf-8") as f:
            json.dump(pl["settings_merged"], f, ensure_ascii=False, indent=2)
            f.write("\n")
        os.replace(tmp, SETTINGS)
        _p(OK, "settings.json 병합(%d항목)" % len(pl["settings_accepted"]))

    # 4) 검증
    rc, out = _rebuild(MEMORY_DIR, "--apply", "--no-diff", "--sid", "import")
    if rc != 0:
        _p(BAD, "실물 색인 재생성 실패 — 백업본으로 원복하세요. %s" % out.strip()[:300])
        return 2
    rc, _ = _rebuild(MEMORY_DIR, "--check")
    _p(OK if rc == 0 else BAD, "색인 정합 검사: %s" % ("일치" if rc == 0 else "드리프트"))
    s = _load_json(SETTINGS)
    if s is None:
        _p(BAD, "settings.json 이 유효한 JSON 이 아님 — 백업본 확인 필요")
        return 2
    if "enabledPlugins" in pl["settings_merged"] and "enabledPlugins" not in s:
        _p(BAD, "플러그인 활성키 소실 — 백업본 확인 필요")
        return 2
    _p(OK, "settings.json 유효 · cockpit 운영키 보존")

    # 5) 기억 배선 — 이게 끊겨 있으면 옮긴 기억이 **세션에 로드되지 않는다**(옛 버전에서 올라온 환경).
    #    이관의 목적 자체가 무너지므로 조용히 넘기지 않는다.
    cur_amd = (_load_json(SETTINGS) or {}).get("autoMemoryDirectory")
    wired = isinstance(cur_amd, str) and cur_amd and \
        os.path.realpath(os.path.expanduser(cur_amd)) == os.path.realpath(MEMORY_DIR)
    if wired:
        _p(OK, "기억 배선 정상 — 옮긴 기억이 세션 시작에 로드됩니다.")
    else:
        _p(WARN, "기억 배선이 끊겨 있습니다(autoMemoryDirectory=%s). 이대로면 옮긴 기억을 Claude 가 "
                 "보지 못합니다. 고치기: python3 '%s' wire-auto-memory --apply"
           % (cur_amd or "(없음)", os.path.join(_HERE, "setup.py")))

    # staging 은 검증용 사본 — 성공했으면 지운다(실패 시엔 남겨서 원인 추적).
    try:
        shutil.rmtree(os.path.dirname(stage))
    except OSError:
        pass
    print("\n%s 이관 완료. **새 세션**부터 반영됩니다. 확인: setup.py doctor" % OK)
    return 0


# ───────────────────────── 이 배포판 안의 고아 기억 흡수 ─────────────────────────
def adopt_native(apply, do_backup=True):
    """배선(autoMemoryDirectory) 이전에 내장 auto memory 가 ~/.claude/projects/<저장소>/memory/
    로 써 둔 기억을 cockpit 저장소로 흡수한다. 원본은 지우지 않는다(삭제 0).
    배선 후 그 폴더는 더 이상 쓰이지 않으므로 남아 있어도 무해하다."""
    src = os.path.join(HOME, ".claude")
    print("[cockpit adopt-native] %s\n" % ("APPLY" if apply else "DRY-RUN(미리보기)"))
    mem, archive, skipped, _w = _classify_memory(src, dirs_fn=_native_memory_dirs)
    if not mem and not archive:
        _p(OK, "고아 기억 없음 — 흡수할 것이 없습니다.")
        return 0
    for sp, dest, has in mem:
        _p(OK, "%s → cc-memory/%s%s" % (os.path.relpath(sp, src), dest, "" if has else "  (설명 자동도출)"))
    for sp, why in archive:
        _p(WARN, "%s — %s(보관함)" % (os.path.relpath(sp, src), why))
    for sp, why in skipped:
        _p(INFO, "건너뜀 %s — %s" % (os.path.basename(sp), why))
    if not apply:
        print("\n[dry-run] 적용하려면: import_existing.py adopt-native --apply")
        return 0
    pl = {"memory": mem, "archive": archive, "assets": [], "claude_md_mode": "cockpit",
          "claude_md_text": "", "settings_accepted": [], "settings_merged": {}}
    return apply_plan(pl, do_backup=do_backup)


def main():
    ap = argparse.ArgumentParser(description="기존 Claude Code 기억·개인자산을 cockpit 으로 이관")
    sub = ap.add_subparsers(dest="cmd", required=True)
    sub.add_parser("detect", help="소스 후보 탐지(읽기 전용)")
    for name in ("plan", "apply"):
        p = sub.add_parser(name, help="이관 계획 미리보기" if name == "plan" else "이관 실행")
        p.add_argument("--source", default=None, help="소스 .claude 경로(미지정=자동탐지)")
        p.add_argument("--claude-md", choices=["merge", "cockpit", "mine"], default="merge",
                       help="merge=통합(기본) · cockpit=cockpit 규칙만 · mine=이전 규칙으로 교체")
        p.add_argument("--no-assets", action="store_true", help="개인자산(스킬·명령어 등) 제외")
        p.add_argument("--accept-permissions-allow", action="store_true",
                       help="회원의 permissions.allow 규칙까지 병합(기본=미병합. 권한 확대이므로 명시 동의 필요)")
        if name == "apply":
            p.add_argument("--no-backup", action="store_true", help="백업 생략(테스트 전용)")
    an = sub.add_parser("adopt-native", help="이 배포판의 고아 auto memory 를 cc-memory 로 흡수")
    an.add_argument("--apply", action="store_true", help="실제 이동(기본=dry-run)")
    an.add_argument("--no-backup", action="store_true", help="백업 생략(테스트 전용)")
    args = ap.parse_args()

    if args.cmd == "detect":
        detect()
        return 0
    if args.cmd == "adopt-native":
        return adopt_native(args.apply, do_backup=not args.no_backup)

    src = args.source
    if not src:
        src, _ = detect(quiet=True)
        if not src:
            print("✗ 소스를 찾지 못했습니다. `detect` 로 확인하거나 --source 로 지정하세요.")
            return 2
    src = os.path.realpath(os.path.expanduser(src))
    pl, err = build_plan(src, args.claude_md, not args.no_assets, args.accept_permissions_allow)
    if err:
        print("✗ %s" % err)
        return 2
    print("[cockpit import] %s" % ("DRY-RUN(미리보기, 변경 없음)" if args.cmd == "plan" else "APPLY"))
    print_plan(pl)
    if args.cmd == "plan":
        print("\n[dry-run] 적용하려면: import_existing.py apply --source '%s' --claude-md %s%s%s"
              % (src, args.claude_md, " --no-assets" if args.no_assets else "",
                 " --accept-permissions-allow" if args.accept_permissions_allow else ""))
        return 0
    return apply_plan(pl, do_backup=not args.no_backup)


if __name__ == "__main__":
    sys.exit(main())
