#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""setup.py — cockpit 첫 실행 설치/점검/롤백 CLI (결정적·멱등·가역).

서브커맨드:
  doctor                    환경·충돌 점검(읽기 전용, 변경 없음)
  install [--dry-run|--apply] [--enable-bypass] [--enable-memory-egress]
                            메모리 디렉터리·CLAUDE.md·(선택)bypass·(선택)egress 설치. 기본 = dry-run.
                            모든 변경은 백업 후 진행 → rollback 으로 되돌림.
  rollback [--latest|--list]  마지막(또는 지정) 백업으로 복원.

설계: 기존 사용자 데이터를 **덮어쓰지 않는다**(비어있을 때만 채움). settings.json 은
  로드→수정→백업→기록(다른 설정 보존). 위험 동작은 **독립 게이트**:
  • bypass(권한 확인 생략)  = --enable-bypass + --i-accept-governance
  • 메모리 외부송신(egress) = --enable-memory-egress + --i-accept-governance
  동의(--i-accept-governance) 만으로는 둘 중 어느 것도 켜지지 않는다(각 기능 플래그가 별도 필수).
경로 규약은 cc_paths(단일 출처) 재사용.
"""
import sys, os, json, shutil, time, argparse, subprocess

PLUGIN_ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.realpath(__file__))))
TEMPLATES = os.path.join(PLUGIN_ROOT, "templates")
MEMORY_TEMPLATE = os.path.join(PLUGIN_ROOT, "memory-template")
MEM_HOOKS = os.path.join(PLUGIN_ROOT, "hooks", "memory")
HOME = os.path.expanduser("~")
CLAUDE_MD = os.path.join(HOME, ".claude", "CLAUDE.md")
SETTINGS = os.path.join(HOME, ".claude", "settings.json")

sys.path.insert(0, MEM_HOOKS)
try:
    import cc_paths
    MEMORY_DIR, STATE_DIR = cc_paths.MEMORY_DIR, cc_paths.STATE_DIR
except Exception:
    MEMORY_DIR = os.path.expanduser(os.environ.get("CC_MEMORY_DIR") or "~/.claude/cc-memory")
    STATE_DIR = os.path.expanduser(os.environ.get("CC_STATE_DIR") or "~/.claude/cc-companion")

KILL_SWITCH = os.path.expanduser(os.environ.get("CC_KILL_SWITCH") or "~/.claude/CC_KILL_SWITCH")
BACKUP_ROOT = os.path.join(STATE_DIR, "setup-backups")

OK, WARN, BAD, INFO = "✓", "⚠", "✗", "·"


def _p(mark, msg):
    print("  %s %s" % (mark, msg))


def _dir_nonempty(d):
    try:
        return os.path.isdir(d) and any(os.scandir(d))
    except OSError:
        return False


def _port_listening(port):
    """로컬에서 해당 포트가 LISTEN 중인지(원격 대시보드 ON 탐지). 크로스플랫폼·읽기전용."""
    import socket
    try:
        with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as s:
            s.settimeout(0.3)
            return s.connect_ex(("127.0.0.1", int(port))) == 0
    except Exception:
        return False


def _conf_value(path, key):
    """설정 파일(KEY=VALUE / export KEY="VALUE")에서 key 값을 안전 파싱(셸 실행 없이). 없으면 None."""
    try:
        with open(path, "r", encoding="utf-8", errors="ignore") as f:
            for line in f:
                line = line.strip()
                if line.startswith("export "):
                    line = line[7:].lstrip()
                if "=" not in line or not line.split("=", 1)[0].strip() == key:
                    continue
                v = line.split("=", 1)[1].strip().strip('"').strip("'")
                # ${KEY:-default} 형태면 default 추출
                if v.startswith("${") and ":-" in v:
                    v = v.split(":-", 1)[1].rstrip("}").strip().strip('"').strip("'")
                return v
    except Exception:
        return None
    return None


def _is_wsl():
    """WSL(Windows Subsystem for Linux) 환경인지 — 메시지 분기용(읽기전용)."""
    if os.environ.get("WSL_DISTRO_NAME") or os.environ.get("WSL_INTEROP"):
        return True
    try:
        with open("/proc/sys/kernel/osrelease", encoding="utf-8") as f:
            return "microsoft" in f.read().lower()
    except OSError:
        return False


def _unit_matches(name):
    low = name.lower()
    return low.endswith((".service", ".timer")) and "cockpit" in low and ("dash" in low or "remote" in low)


def _dash_autostart():
    """원격 대시보드 자동시작 등록 여부 + 메커니즘을 **OS별**로 탐지(읽기전용).
    macOS=launchd plist, Linux/WSL=systemd --user 유닛(systemctl 우선·디렉터리 폴백). 반환 (bool, 설명문자열).
    ⚠ WSL 에선 macOS plist 경로(~/Library/LaunchAgents)가 영영 없으므로 그것만 보면 거짓 OFF 가 된다.
    ⚠ systemd/launchd '유닛' 자동시작만 본다 — cron·.bashrc 류 자동기동은 포트 LISTEN 으로 잡힌다(런타임 신호).
    cockpit 은 기본적으로 어떤 자동시작 단위도 굽지 않으므로 정상 출고 상태에선 (False, '유닛 미등록')."""
    if sys.platform == "darwin":
        plist = os.path.join(HOME, "Library", "LaunchAgents", "com.cockpit.dashboard.plist")
        return (True, "launchd(plist 등록)") if os.path.exists(plist) else (False, "유닛 미등록")
    # Linux/WSL: systemctl --user 우선(모든 unit 경로 포괄), 실패 시 ~/.config/systemd/user 디렉터리 폴백.
    try:
        p = subprocess.run(["systemctl", "--user", "list-unit-files", "--no-legend"],
                           capture_output=True, text=True, timeout=5)
        if p.returncode == 0:
            for line in p.stdout.splitlines():
                parts = line.split()
                if parts and _unit_matches(parts[0]):
                    return True, "systemd --user(%s)" % parts[0]
            return False, "유닛 미등록"   # systemctl 권위 — 폴백 불필요
    except Exception:
        pass
    udir = os.path.expanduser("~/.config/systemd/user")
    try:
        if os.path.isdir(udir):
            for name in os.listdir(udir):
                if _unit_matches(name):
                    return True, "systemd --user(%s)" % name
    except OSError:
        pass
    return False, "유닛 미등록"


# ───────────────────────── doctor ─────────────────────────
def doctor():
    print("[cockpit doctor] 환경·충돌 점검 (읽기 전용)\n")
    print("플러그인 루트: %s" % PLUGIN_ROOT)
    print("메모리 저장소(CC_MEMORY_DIR): %s" % MEMORY_DIR)
    print("런타임 상태(CC_STATE_DIR):    %s\n" % STATE_DIR)

    issues = 0
    # python
    v = sys.version_info
    _p(OK if v >= (3, 8) else BAD, "python3 %d.%d.%d" % (v.major, v.minor, v.micro))
    issues += v < (3, 8)

    # 플러그인 자산
    for label, path in (("CLAUDE.md 템플릿", os.path.join(TEMPLATES, "CLAUDE.md.template")),
                        ("메모리 템플릿", os.path.join(MEMORY_TEMPLATE, "PROJECT_STATUS.md")),
                        ("메모리 훅", os.path.join(MEM_HOOKS, "session_context.py")),
                        ("deny-list", os.path.join(PLUGIN_ROOT, "safety", "deny-list.txt"))):
        ex = os.path.exists(path)
        _p(OK if ex else BAD, "%s: %s" % (label, "있음" if ex else "없음(%s)" % path))
        issues += not ex

    # 메모리 저장소
    if _dir_nonempty(MEMORY_DIR):
        idx = os.path.join(MEMORY_DIR, "MEMORY.md")
        _p(INFO, "메모리 저장소 이미 존재(내용 있음) — 설치 시 보존(덮어쓰지 않음)")
        if os.path.exists(idx):
            rc = _rebuild_check()
            _p(OK if rc == 0 else WARN, "MEMORY.md 인덱스 일관성: %s" %
               ("일치" if rc == 0 else "드리프트(편집 후 자동 재생성 대기 가능)"))
    else:
        _p(INFO, "메모리 저장소 비어있음/없음 — 설치 시 예시 템플릿으로 채움")

    # CLAUDE.md 충돌
    if os.path.exists(CLAUDE_MD):
        _p(WARN, "~/.claude/CLAUDE.md 이미 존재 — 설치 시 백업 후 교체(rollback 가능). 내용 검토 권장")
    else:
        _p(INFO, "~/.claude/CLAUDE.md 없음 — 설치 시 새로 생성")

    # settings / bypass
    mode, has_settings = _settings_mode()
    if has_settings:
        _p(INFO, "settings.json 존재. 현재 권한 모드: %s" % (mode or "기본(ask)"))
    else:
        _p(INFO, "settings.json 없음 — bypass 활성화 시 새로 생성")
    if mode == "bypassPermissions":
        _p(WARN, "bypass(권한 확인 생략) 이미 켜져 있음 — GOVERNANCE.md 경계 준수 필수")

    # extraction key (선택) — Remote Control 은 ANTHROPIC_API_KEY 가 설정돼 있으면 거부되므로,
    # 메모리 추출 키는 ANTHROPIC_API_KEY_FOR_SCRIPTS 로 두는 것을 권장(충돌 회피).
    key_scripts = bool(os.environ.get("ANTHROPIC_API_KEY_FOR_SCRIPTS"))
    key_plain = bool(os.environ.get("ANTHROPIC_API_KEY"))
    has_key = key_scripts or key_plain
    _p(INFO if has_key else WARN, "기억 추출용 키(ANTHROPIC_API_KEY_FOR_SCRIPTS 권장): %s" %
       ("설정됨" if has_key else "없음 — 메모리 자동 추출은 비활성(나머지 기능은 정상)"))
    if key_plain and not key_scripts:
        _p(WARN, "ANTHROPIC_API_KEY 설정됨 — claude.ai Remote Control 과 충돌 가능(키 설정 시 Remote Control 거부). "
                 "추출 키는 ANTHROPIC_API_KEY_FOR_SCRIPTS 로 옮기는 것을 권장.")

    # kill switch
    if os.path.exists(KILL_SWITCH):
        _p(WARN, "긴급정지(kill switch) 활성 상태 — 자동 진행이 차단됨. 해제: rm '%s'" % KILL_SWITCH)
    else:
        _p(OK, "긴급정지 비활성(정상). 경로: %s" % KILL_SWITCH)

    # 보조 검토(Codex) — 활성화 스위치(선택 기능, 기본 비활성)
    codex_switch = os.path.expanduser(os.environ.get("CC_CODEX_ENABLED") or "~/.claude/codex_enabled")
    if os.path.exists(codex_switch):
        _p(WARN, "보조 검토(Codex) 활성 — 켜져 있으면 같은 맥락이 OpenAI 에도 전송(이중 송출). 끄기: rm '%s'" % codex_switch)
    else:
        _p(INFO, "보조 검토(Codex) 비활성(스위치 없음). 켜기: touch '%s'" % codex_switch)

    # 원격 대시보드 — ON/OFF 탐지(선택 기능·기본 비활성·이 패키지에서 가장 위험; GOVERNANCE 6장).
    # 자동시작 탐지는 OS별(_dash_autostart): macOS=launchd plist, Linux/WSL=systemd --user 유닛.
    # (포트 LISTEN 탐지는 socket 이라 크로스플랫폼 — 실제 가동 여부의 1차 신호.)
    dash_conf = os.path.expanduser("~/.config/cockpit/dashboard.env")
    # 포트: 환경변수 → 설정파일(CC_DASH_PORT) → 기본 18080 순.
    port_src = os.environ.get("CC_DASH_PORT") or (os.path.exists(dash_conf) and _conf_value(dash_conf, "CC_DASH_PORT")) or "18080"
    try:
        dash_port = int(port_src)
    except (ValueError, TypeError):
        dash_port = 18080
    autostart, auto_mech = _dash_autostart()
    listening = _port_listening(dash_port)
    if autostart or listening:
        _p(WARN, "원격 대시보드 ON — 자동시작=%s · 포트 %d=%s. 끄기: dashboard/disable-remote.sh --apply (GOVERNANCE 6장)"
           % (auto_mech if autostart else "유닛 미등록", dash_port, "LISTEN" if listening else "닫힘"))
        if listening:
            # 세션 로그(PII 가능)가 브라우저로 열릴 수 있는 노출 경고. WSL 이면 Windows 호스트 localhost 경로를 명시.
            if _is_wsl():
                # WSL2 는 NAT 라 0.0.0.0 바인드라도 기본은 Windows 호스트 localhost 에서 도달(LAN/폰은 추가설정 없이 미도달).
                _p(WARN, "  ↳ 포트 %d LISTEN: WSL 에선 Windows 호스트 localhost:%d 로 세션 로그(민감) 열람 가능. "
                         "공유·회사 PC·화면공유 중 주의 · tailscale serve/funnel·netsh portproxy 로 공개 노출 금지." % (dash_port, dash_port))
            else:
                _p(WARN, "  ↳ 포트 %d LISTEN: localhost/허용 네트워크에서 세션 로그(민감) 열람 가능. "
                         "공유·화면공유 중 주의 · tailscale serve/funnel 등으로 공개 노출 금지." % dash_port)
    else:
        _p(OK, "원격 대시보드 OFF(systemd/launchd 자동시작 유닛 미등록·포트 %d 미개방). 설정 파일: %s"
           % (dash_port, "있음" if os.path.exists(dash_conf) else "없음"))

    print("\n결과: %s" % ("문제 %d건 — 위 ✗ 확인" % issues if issues else "치명 문제 없음. install 진행 가능."))
    return 1 if issues else 0


def _rebuild_check():
    try:
        p = subprocess.run([sys.executable, os.path.join(MEM_HOOKS, "rebuild_memory_index.py"), "--check"],
                           capture_output=True, text=True, timeout=10,
                           env={**os.environ, "CC_MEMORY_DIR": MEMORY_DIR})
        return p.returncode
    except Exception:
        return -1


def _settings_mode():
    if not os.path.exists(SETTINGS):
        return None, False
    try:
        with open(SETTINGS, encoding="utf-8") as f:
            s = json.load(f)
        return (s.get("permissions") or {}).get("defaultMode"), True
    except Exception:
        return None, True


def _files_differ(a, b):
    """두 파일 내용이 다른가(어느 쪽이든 못 읽으면 '다름' 취급 = 보존 측으로 안전)."""
    try:
        with open(a, "rb") as fa, open(b, "rb") as fb:
            return fa.read() != fb.read()
    except Exception:
        return True


# ───────────────────────── install ─────────────────────────
def install(apply, enable_bypass, accepted=False, replace_claude_md=False, enable_egress=False):
    if enable_bypass and not accepted:
        print("✗ --enable-bypass 는 거버넌스 동의가 필요합니다.")
        print("  GOVERNANCE.md(특히 0·2·3장)를 읽고 이해했다면 --i-accept-governance 를 함께 지정하세요.")
        print("  설치 마법사(cockpit-setup 스킬)를 쓰면 동의 절차를 안내합니다.")
        return 2
    if enable_egress and not accepted:
        print("✗ --enable-memory-egress(메모리 자동추출 외부송신)는 거버넌스 동의가 필요합니다.")
        print("  GOVERNANCE.md(특히 §3 외부 송출·§8 동의)를 읽고 이해했다면 --i-accept-governance 를 함께 지정하세요.")
        return 2
    mode_label = "APPLY(실제 변경)" if apply else "DRY-RUN(미리보기, 변경 없음)"
    print("[cockpit install] %s\n" % mode_label)
    # bypass 활성화 전 settings.json 무결성 preflight(손상 파일을 덮어써 설정 유실하는 사고 방지)
    if enable_bypass and apply and os.path.exists(SETTINGS):
        try:
            with open(SETTINGS, encoding="utf-8") as _f:
                _chk = json.load(_f)
            if not isinstance(_chk, dict):
                raise ValueError("최상위가 객체가 아님")
        except Exception as e:
            print("✗ settings.json 파싱 실패(%s) — bypass 활성화 중단(기존 설정 보호)." % e)
            print("  먼저 %s 를 고치거나 백업 후 재시도하세요." % SETTINGS)
            return 2
    # CLAUDE.md 충돌 preflight(부분 적용 전에 차단): 기존 파일이 템플릿과 다르면 명시 플래그
    # 없이는 덮지 않는다 — 이미 Claude Code 를 쓰는 동료의 운영 규칙을 무동의로 교체하는 사고 방지.
    # dry-run 에서도 알려 사용자가 --apply 전에 안다.
    _src_md_pf = os.path.join(TEMPLATES, "CLAUDE.md.template")
    if os.path.exists(CLAUDE_MD) and not replace_claude_md and _files_differ(CLAUDE_MD, _src_md_pf):
        print("✗ 기존 ~/.claude/CLAUDE.md 가 템플릿과 다릅니다 — 기본은 보존(덮어쓰지 않음).")
        print("  교체하려면 --replace-claude-md 추가(교체 전 자동 백업 → rollback 으로 복원 가능),")
        print("  또는 기존 파일을 두고 템플릿 내용을 수동 병합하세요.")
        return 2
    actions, backups, created, created_files = [], {}, [], []
    ts = time.strftime("%Y%m%d-%H%M%S")
    bdir = os.path.join(BACKUP_ROOT, ts)

    def backup(path):
        if os.path.exists(path):
            dst = os.path.join(bdir, os.path.basename(path))
            if apply:
                os.makedirs(bdir, exist_ok=True)
                shutil.copy2(path, dst)
            backups[path] = dst
            return dst
        return None

    # 1) 상태 디렉터리
    if not os.path.isdir(STATE_DIR):
        actions.append("런타임 상태 디렉터리 생성: %s" % STATE_DIR)
        if apply:
            os.makedirs(STATE_DIR, exist_ok=True)
        created.append(STATE_DIR)

    # 2) 메모리 저장소(비어있을 때만 템플릿 복사)
    if _dir_nonempty(MEMORY_DIR):
        actions.append("메모리 저장소 보존(이미 내용 있음): %s" % MEMORY_DIR)
    else:
        actions.append("메모리 저장소를 예시 템플릿으로 초기화: %s" % MEMORY_DIR)
        if apply:
            os.makedirs(MEMORY_DIR, exist_ok=True)
            for nm in os.listdir(MEMORY_TEMPLATE):
                if nm.endswith(".md"):
                    shutil.copy2(os.path.join(MEMORY_TEMPLATE, nm), os.path.join(MEMORY_DIR, nm))
        created.append(MEMORY_DIR + "/*(template)")

    # 3) CLAUDE.md 행동 규율(기존은 백업 후 교체)
    src_md = os.path.join(TEMPLATES, "CLAUDE.md.template")
    md_existed = os.path.exists(CLAUDE_MD)
    if md_existed:
        actions.append("기존 ~/.claude/CLAUDE.md 백업 후 템플릿으로 교체(--replace-claude-md 동의, 플레이스홀더 직접 채우기 필요)")
    else:
        actions.append("~/.claude/CLAUDE.md 생성(행동 규율 템플릿 — 플레이스홀더 직접 채우기 필요)")
    if apply:
        backup(CLAUDE_MD)
        os.makedirs(os.path.dirname(CLAUDE_MD), exist_ok=True)
        shutil.copy2(src_md, CLAUDE_MD)
        if not md_existed:
            created_files.append(CLAUDE_MD)

    # 4) (선택) bypass 활성화
    if enable_bypass:
        settings_existed = os.path.exists(SETTINGS)
        actions.append("⚠ bypass(권한 확인 생략) 활성화 + settings.json 백업 (GOVERNANCE.md 동의 전제)")
        if apply:
            backup(SETTINGS)
            _enable_bypass_settings()
            if not settings_existed:
                created_files.append(SETTINGS)
    else:
        actions.append("bypass 비활성 유지(안전 기본) — 켜려면 --enable-bypass + 동의")

    # 5) egress 동의 마커 = 외부 egress 게이트 단일 신호. 이 파일이 있어야 메모리 자동추출이
    #    세션 본문을 Anthropic API 로 송출한다(extract_pending._egress_consented). 플러그인
    #    defaultEnabled=true 라 설치 직후 Stop hook 이 로드되지만, 이 마커가 없으면 키가 있어도
    #    no-op. v0.1.1 부터 마커는 **--enable-memory-egress + --i-accept-governance** 둘 다
    #    있을 때만 기록한다 — bypass 동의(--i-accept-governance)가 egress 를 자동으로 켜지
    #    않도록 분리(이미지 bypass ON 기본화 시 egress 도 함께 켜지는 사고 방지). enable_egress
    #    는 위 preflight 에서 accepted 를 이미 보장. rollback 이 마커 제거 → egress 다시 OFF.
    #    (API 키 존재 opt-in 과 AND 결합 = 이중 게이트.)
    SETUP_MARKER = os.path.join(STATE_DIR, "setup_complete")
    if enable_egress:
        actions.append("egress 동의 마커 기록(메모리 자동추출 외부송신 활성, --enable-memory-egress + --i-accept-governance): %s" % SETUP_MARKER)
        if apply:
            os.makedirs(STATE_DIR, exist_ok=True)
            with open(SETUP_MARKER, "w", encoding="utf-8") as f:
                f.write("setup complete %s\n" % ts)
            created_files.append(SETUP_MARKER)
    else:
        actions.append("egress(메모리 자동추출 외부송신) 비활성 유지 — 켜려면 --enable-memory-egress + --i-accept-governance(GOVERNANCE §3)")

    # 출력
    for a in actions:
        _p(INFO, a)

    if apply:
        manifest = {"ts": ts, "backups": backups, "created": created,
                    "created_files": created_files, "enabled_bypass": bool(enable_bypass)}
        os.makedirs(bdir, exist_ok=True)
        with open(os.path.join(bdir, "manifest.json"), "w", encoding="utf-8") as f:
            json.dump(manifest, f, ensure_ascii=False, indent=2)
        print("\n%s 설치 완료. 백업·복원 정보: %s" % (OK, bdir))
        print("  되돌리려면:  python3 '%s' rollback --latest" % os.path.realpath(__file__))
        print("  다음: ~/.claude/CLAUDE.md 의 {{...}} 플레이스홀더를 본인 환경으로 채우세요.")
    else:
        # 재실행 안내 = 이번 dry-run 에 **실제로 지정한 플래그를 그대로** 재구성한다.
        # (옛 코드는 --enable-bypass 만 덧붙여, --enable-memory-egress/--i-accept-governance
        #  를 준 dry-run 과 apply 명령이 어긋났다 — 동의·egress 가 조용히 빠지는 부정합.)
        flags = []
        if enable_bypass:     flags.append("--enable-bypass")
        if enable_egress:     flags.append("--enable-memory-egress")
        if accepted:          flags.append("--i-accept-governance")
        if replace_claude_md: flags.append("--replace-claude-md")
        suffix = "".join(" " + f for f in flags)
        print("\n[dry-run] 위 작업을 실제로 적용하려면(이번에 지정한 플래그 그대로):"
              "\n  python3 setup.py install --apply" + suffix)
    return 0


def _enable_bypass_settings():
    s = {}
    if os.path.exists(SETTINGS):
        with open(SETTINGS, encoding="utf-8") as f:
            s = json.load(f)   # 손상 시 예외 → install preflight 이 이미 차단(여기 도달 = 파싱 가능)
        if not isinstance(s, dict):
            s = {}
    perms = s.setdefault("permissions", {})
    perms["defaultMode"] = "bypassPermissions"
    s["skipDangerousModePermissionPrompt"] = True
    tmp = SETTINGS + ".tmp"
    os.makedirs(os.path.dirname(SETTINGS), exist_ok=True)
    with open(tmp, "w", encoding="utf-8") as f:
        json.dump(s, f, ensure_ascii=False, indent=2)
    os.replace(tmp, SETTINGS)


# ───────────────────────── rollback ─────────────────────────
def rollback(which):
    if not os.path.isdir(BACKUP_ROOT):
        print("백업 없음(%s). 되돌릴 설치 기록이 없습니다." % BACKUP_ROOT)
        return 1
    snaps = sorted(d for d in os.listdir(BACKUP_ROOT) if os.path.isdir(os.path.join(BACKUP_ROOT, d)))
    if which == "--list":
        print("설치 백업 스냅샷:")
        for d in snaps:
            print("  %s" % d)
        return 0
    if not snaps:
        print("백업 스냅샷 없음.")
        return 1
    bdir = os.path.join(BACKUP_ROOT, snaps[-1])
    mf = os.path.join(bdir, "manifest.json")
    if not os.path.exists(mf):
        print("manifest 없음: %s" % bdir)
        return 1
    with open(mf, encoding="utf-8") as f:
        m = json.load(f)
    print("[cockpit rollback] 스냅샷 %s 복원\n" % m["ts"])
    # 되돌리기 전에 '현재' 파일을 따로 백업(설치 후 사용자가 채운 CLAUDE.md/settings 유실 방지, Codex 발견)
    pre = os.path.join(BACKUP_ROOT, "pre-rollback-" + time.strftime("%Y%m%d-%H%M%S"))
    saved = []
    for t in list((m.get("backups") or {}).keys()) + list(m.get("created_files") or []):
        if os.path.exists(t):
            os.makedirs(pre, exist_ok=True)
            shutil.copy2(t, os.path.join(pre, os.path.basename(t)))
            saved.append(t)
    if saved:
        print("  · 되돌리기 전 현재 상태 백업: %s\n" % pre)
    for orig, bak in (m.get("backups") or {}).items():
        if os.path.exists(bak):
            shutil.copy2(bak, orig)
            _p(OK, "복원: %s" % orig)
    for cf in (m.get("created_files") or []):
        try:
            if os.path.exists(cf):
                os.remove(cf)
                _p(OK, "제거(설치 시 새로 생성됨): %s" % cf)
        except OSError as e:
            _p(WARN, "제거 실패 %s: %s" % (cf, e))
    print("\n%s 백업된 파일 복원 완료. (생성된 디렉터리/메모리 템플릿은 안전을 위해 수동 삭제: %s)"
          % (OK, ", ".join(m.get("created") or []) or "없음"))
    return 0


def main():
    ap = argparse.ArgumentParser(description="cockpit 설치/점검/롤백")
    sub = ap.add_subparsers(dest="cmd", required=True)
    sub.add_parser("doctor")
    ip = sub.add_parser("install")
    ip.add_argument("--apply", action="store_true", help="실제 변경(기본=dry-run)")
    ip.add_argument("--dry-run", action="store_true", help="미리보기(기본)")
    ip.add_argument("--enable-bypass", action="store_true", help="권한 확인 생략(bypass) 활성화(동의 전제)")
    ip.add_argument("--enable-memory-egress", action="store_true",
                    help="메모리 자동추출의 외부 송신(egress) 활성화(동의 전제) — bypass 와 독립")
    ip.add_argument("--i-accept-governance", action="store_true",
                    help="GOVERNANCE.md 동의 확인 — --enable-bypass / --enable-memory-egress 에 필수")
    ip.add_argument("--replace-claude-md", action="store_true",
                    help="기존 ~/.claude/CLAUDE.md 를 템플릿으로 교체(기본=보존, 교체 전 자동 백업)")
    rb = sub.add_parser("rollback")
    rb.add_argument("--latest", action="store_true")
    rb.add_argument("--list", action="store_true")
    args = ap.parse_args()
    if args.cmd == "doctor":
        return doctor()
    if args.cmd == "install":
        return install(apply=args.apply and not args.dry_run, enable_bypass=args.enable_bypass,
                       accepted=args.i_accept_governance, replace_claude_md=args.replace_claude_md,
                       enable_egress=args.enable_memory_egress)
    if args.cmd == "rollback":
        return rollback("--list" if args.list else "--latest")
    return 1


if __name__ == "__main__":
    sys.exit(main())
