#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""setup.py — cockpit 첫 실행 설치/점검/롤백 CLI (결정적·멱등·가역).

서브커맨드:
  doctor                    환경·충돌 점검(읽기 전용, 변경 없음)
  install [--dry-run|--apply] [--enable-bypass] [--enable-memory-egress]
                            메모리 디렉터리·CLAUDE.md·(선택)bypass·(선택)egress 설치. 기본 = dry-run.
                            모든 변경은 백업 후 진행 → rollback 으로 되돌림.
  set-extraction-key [--from-env [VAR]] [--remove] [--allow-nonstandard]
                            메모리 자동추출용 API 키를 0600 키 파일에 등록/제거(선택·BYO·G21).
                            키 원문은 argv 로 받지 않는다(ps 노출 방지) — 대화형 getpass 또는 --from-env.
  apply-installer-onboarding --memory-egress {on,off} [--governance-ack]
                             [--key-registered {yes,no}] [--dashboard {installed,skipped,failed}]
                            Windows 설치기 온보딩 폼의 결정값 적용(v0.1.8·narrow 진입점).
                            install 의 다른 책임(CLAUDE.md·settings·메모리 템플릿)은 일절 미접촉.
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
    EXTRACTION_KEY_FILE = cc_paths.EXTRACTION_KEY_FILE   # 메모리 추출 키 파일(단일 출처, G21)
except Exception:
    MEMORY_DIR = os.path.expanduser(os.environ.get("CC_MEMORY_DIR") or "~/.claude/cc-memory")
    STATE_DIR = os.path.expanduser(os.environ.get("CC_STATE_DIR") or "~/.claude/cc-companion")
    EXTRACTION_KEY_FILE = os.path.realpath(os.path.expanduser(
        os.environ.get("CC_EXTRACTION_KEY_FILE") or "~/.config/cockpit/extraction-key"))

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


def _memory_effectively_empty(d):
    """기억 저장소에 '사용자 기억이 없는가' — 없거나 비었거나, **템플릿 파일만 있고
    전부 동명 템플릿(memory-template)과 바이트 동일**이면 True(부분집합 허용 — 일부만
    남아 있어도 전부 템플릿 원본과 동일하면 사용자 기억 0건으로 본다).
    fresh 이미지는 템플릿 md 를 미리 담아 오므로 단순 비어있음 검사로는 재설치 직후를
    영원히 못 잡는다(v0.1.6 실기 확정) — 복원 안내(§1.5)의 발화 조건은 이 함수를 쓴다.
    판정 불가(권한 등)나 템플릿 외 산출물(하위 디렉터리·심링크·변경 파일)이 있으면
    False = 안내 억제(복원 질문 오발화가 더 해로운 쪽이라 보수적 기본)."""
    try:
        if not os.path.isdir(d):
            return True
        entries = list(os.scandir(d))
        if not entries:
            return True
        tpl_names = set(n for n in os.listdir(MEMORY_TEMPLATE)
                        if n.endswith(".md")) if os.path.isdir(MEMORY_TEMPLATE) else set()
        import filecmp
        for e in entries:
            if not e.is_file(follow_symlinks=False):
                return False
            if e.name not in tpl_names:
                return False
            if not filecmp.cmp(e.path, os.path.join(MEMORY_TEMPLATE, e.name), shallow=False):
                return False
        return True
    except OSError:
        return False


def _restore_candidates():
    """복원 가능한 백업 후보 [(디렉터리, 개수)] — backup.py 의 스캔 로직 재사용(단일출처·
    로컬 glob 만·네트워크 0). sys.path 에 MEM_HOOKS 가 있어 직접 import 한다.
    어떤 실패든 빈 리스트 = 복원 안내 억제(doctor 는 읽기 전용·비치명 유지)."""
    try:
        import backup as _backup
        out = []
        for d in _backup._scan_candidate_dirs():
            n = len(_backup._backups_in(d))
            if n:
                out.append((d, n))
        return out
    except Exception:
        return []


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
def _dur(sec):
    """경과 초 → 사람이 읽는 대략치(정확도보다 감각). None → '?'."""
    if sec is None:
        return "?"
    sec = int(sec)
    if sec < 90:
        return "%d초" % max(sec, 0)
    if sec < 5400:
        return "%d분" % (sec // 60)
    if sec < 172800:
        return "%d시간" % (sec // 3600)
    return "%d일" % (sec // 86400)


def _watcher_status():
    """transcript-watcher(G2) 자가점검 스냅샷(읽기 전용·import 결합 없음, G18).
    경로는 watcher 와 동일하게 STATE_DIR/watcher/ 에서 도출. 반환 dict."""
    wdir = os.path.join(STATE_DIR, "watcher")
    lock = os.path.join(wdir, "watcher.lock")
    log = os.path.join(wdir, "watcher.log")
    findings = os.path.join(wdir, "findings.jsonl")
    STALE = 43_200 + 300   # = transcript_watcher.LOCK_STALE_AGE (MAX_RUNTIME 12h + 300)
    st = {"lock_exists": False, "owner": 0, "age": None, "alive": False,
          "stale": False, "findings_n": 0, "last_detect": None, "log_mtime": None}
    try:
        if os.path.exists(lock):
            st["lock_exists"] = True
            st["age"] = time.time() - os.stat(lock).st_mtime
            try:
                with open(lock) as f:
                    parts = f.read().split()
                st["owner"] = int(parts[0]) if parts else 0
            except Exception:
                st["owner"] = 0
            if st["owner"] > 0:
                try:
                    os.kill(st["owner"], 0)      # POSIX 존재 검사(watcher._pid_alive 미러)
                    st["alive"] = True
                except OSError:
                    st["alive"] = False
                except Exception:
                    st["alive"] = True           # 판정 불가 → 보수적으로 생존
            st["stale"] = st["age"] is not None and st["age"] > STALE
    except Exception:
        pass
    try:
        if os.path.isfile(findings):
            st["last_detect"] = os.stat(findings).st_mtime
            with open(findings, encoding="utf-8", errors="ignore") as f:
                st["findings_n"] = sum(1 for line in f if line.strip())
    except Exception:
        pass
    try:
        if os.path.isfile(log):
            st["log_mtime"] = os.stat(log).st_mtime
    except Exception:
        pass
    return st


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

    # extraction key (선택·G21) — Remote Control 은 ANTHROPIC_API_KEY 가 설정돼 있으면 거부되므로,
    # 메모리 추출 키는 ANTHROPIC_API_KEY_FOR_SCRIPTS(또는 아래 0600 키 파일) 로 두는 것을 권장(충돌 회피).
    key_scripts = bool(os.environ.get("ANTHROPIC_API_KEY_FOR_SCRIPTS"))
    key_plain = bool(os.environ.get("ANTHROPIC_API_KEY"))
    key_file_ok, key_file_perm_warn = _key_file_status()
    has_key = key_scripts or key_plain or key_file_ok
    if has_key:
        src = ("env(_FOR_SCRIPTS)" if key_scripts else
               "env(ANTHROPIC_API_KEY)" if key_plain else
               "키 파일 %s" % EXTRACTION_KEY_FILE)
        _p(INFO, "기억 추출용 키: 설정됨 (출처: %s)" % src)
        if key_file_ok and key_file_perm_warn:
            _p(WARN, "키 파일 권한이 느슨함(%s) — 본인만 읽도록 권장: chmod 600 '%s'"
               % (key_file_perm_warn, EXTRACTION_KEY_FILE))
    else:
        _p(WARN, "기억 추출용 키: 없음 — 메모리 자동 추출은 비활성(나머지 기능은 정상).")
        _p(INFO, "  등록(키는 대화에 남기지 않음): python3 '%s' set-extraction-key" % os.path.realpath(__file__))
        _p(INFO, "  발급(비개발자용): console.anthropic.com 로그인 → API Keys → Create Key → 키 복사(1회만 표시)."
                 " 결제수단/크레딧 등록 필요.")
        _p(INFO, "  ⚠ 과금: API 키는 Claude Max/Pro 정액 구독과 **별개**로 사용량만큼 과금(pay-per-token)."
                 " 추출은 Haiku 로 세션당 극소액(수천 토큰). 사용량 한도(spend limit) 설정 권장.")
    if key_plain and not key_scripts:
        _p(WARN, "ANTHROPIC_API_KEY 설정됨 — claude.ai Remote Control 과 충돌 가능(키 설정 시 Remote Control 거부). "
                 "추출 키는 ANTHROPIC_API_KEY_FOR_SCRIPTS 또는 키 파일(set-extraction-key)로 옮기는 것을 권장.")

    # kill switch
    if os.path.exists(KILL_SWITCH):
        _p(WARN, "긴급정지(kill switch) 활성 상태 — 자동 진행이 차단됨. 해제: rm '%s'" % KILL_SWITCH)
    else:
        _p(OK, "긴급정지 비활성(정상). 경로: %s" % KILL_SWITCH)

    # transcript-watcher(G2·G18/G19) 자가점검 — 기동 여부·lockfile·최근 감지.
    # 미가동은 정상(세션 시작 훅이 기동, 유휴 시 자가종료). stale/좀비 락만 주의.
    ws = _watcher_status()
    if ws["lock_exists"] and ws["stale"]:
        _p(WARN, "transcript-watcher lockfile 이 오래됨(%s 경과) — 죽은 워처의 stale 락일 수 있음. "
                 "다음 세션 시작이 회수·재기동(수동: rm '%s')." % (_dur(ws["age"]), os.path.join(STATE_DIR, "watcher", "watcher.lock")))
    elif ws["lock_exists"] and ws["alive"]:
        _p(OK, "transcript-watcher 가동 중(pid %d · 락 나이 %s)." % (ws["owner"], _dur(ws["age"])))
    elif ws["lock_exists"]:
        _p(WARN, "transcript-watcher lockfile 은 있으나 소유 프로세스(pid %d) 미생존 — 다음 세션 시작이 회수·재기동."
           % ws["owner"])
    else:
        _p(INFO, "transcript-watcher 미가동(락 없음) — 세션 시작 훅이 기동하고 유휴 시 자가 종료(정상).")
    if ws["findings_n"]:
        _p(INFO, "  최근 감지 findings %d건(최종 %s 전) — 다음 세션 시작 컨텍스트에 요약 주입."
           % (ws["findings_n"], _dur(time.time() - ws["last_detect"]) if ws["last_detect"] else "?"))
    elif ws["log_mtime"]:
        _p(INFO, "  감지 findings 0건(최근 세션 차단/미포착 에러 없음) · 로그 최종 갱신 %s 전."
           % _dur(time.time() - ws["log_mtime"]))
    else:
        _p(INFO, "  watcher 로그 없음(아직 미기동/첫 실행 전 — 정상).")

    # 사전조건/환경 안내(G20·doctor측). 능동 네트워크 probe 는 하지 않는다(부작용 회피) — 의존만 고지.
    _p(INFO if _is_wsl() else WARN, "실행 환경: %s" % (
        "WSL2 배포판 안(cockpit 표준)" if _is_wsl()
        else "WSL 아님(플러그인 단독/개발 환경) — 이미지 기반 안내 일부는 해당 없음"))
    _p(INFO, "네트워크 의존(프록시·보안제품이 막으면 해당 기능만 실패, 나머지 정상): "
             "메모리 자동추출=api.anthropic.com · 대시보드 뷰어 설치=github.com · claude 로그인=OAuth 브라우저.")
    _p(INFO, "설치측 사전점검(다중 WSL 배포판·포트 충돌·SmartScreen·프록시 차단)은 설치 .cmd/ps1 계층이 담당 "
             "(windows/README) — 이 doctor 는 배포판 안 런타임 점검용.")

    # 원격 대시보드 — ON/OFF 탐지(선택 기능·기본 비활성·이 패키지에서 가장 위험; GOVERNANCE 6장).
    # 자동시작 탐지는 OS별(_dash_autostart): macOS=launchd plist, Linux/WSL=systemd --user 유닛.
    # (포트 LISTEN 탐지는 socket 이라 크로스플랫폼 — 실제 가동 여부의 1차 신호.)
    dash_conf = os.path.expanduser("~/.config/cockpit/dashboard.env")

    # 뷰어 설치 상태(옵트인·§4-4) — viewer-pin.txt(단일 출처)와 HEAD 대조. 미설치=정상(INFO).
    dash_home = os.path.expanduser(os.environ.get("CC_DASH_HOME")
                or (os.path.exists(dash_conf) and _conf_value(dash_conf, "CC_DASH_HOME")) or "~/claude-logs")
    pin_file = os.path.join(PLUGIN_ROOT, "dashboard", "viewer-pin.txt")
    pin = _conf_value(pin_file, "VIEWER_PIN") if os.path.exists(pin_file) else None
    viewer_cfg = os.path.join(dash_home, "config.json")
    if os.path.isdir(os.path.join(dash_home, ".git")):
        head = None
        try:
            g = subprocess.run(["git", "-C", dash_home, "rev-parse", "HEAD"],
                               capture_output=True, text=True, timeout=5)
            head = g.stdout.strip() if g.returncode == 0 else None
        except Exception:
            pass
        if pin and head == pin:
            _p(OK, "대시보드 뷰어 설치됨 — 핀 일치(%s…): %s" % (pin[:7], dash_home))
        else:
            _p(WARN, "대시보드 뷰어 핀 불일치/판독불가(HEAD=%s·핀=%s) — dashboard/install-viewer.sh 재실행으로 핀 복귀: %s"
               % ((head or "?")[:7], (pin or "?")[:7], dash_home))
    elif os.path.isdir(dash_home):
        _p(WARN, "대시보드 경로가 git 클론이 아님(%s) — 핀 검증 불가(수동 설치본?). 접근통제 자가검증은 README 참조." % dash_home)
    else:
        _p(INFO, "대시보드 뷰어 미설치(옵트인 — /cockpit-setup 대시보드 스텝에서 설치)")

    # 노출 안전(Codex 4d): bind 가 loopback 이 아니면 개인 세션 로그가 네트워크 대역에 열릴 수 있다.
    _bind_srcs = []
    _b = os.environ.get("CC_DASH_BIND") or (os.path.exists(dash_conf) and _conf_value(dash_conf, "CC_DASH_BIND"))
    if _b:
        _bind_srcs.append(("env/dashboard.env", _b))
    if os.path.isfile(viewer_cfg):
        try:
            with open(viewer_cfg, encoding="utf-8") as f:
                _bind_srcs.append(("config.json", str(json.load(f).get("bind", "127.0.0.1"))))
        except Exception:
            pass
    def _is_loopback(v):
        v = (v or "").strip().strip("[]")
        if v in ("localhost", "::1"):
            return True
        try:
            import ipaddress
            return ipaddress.ip_address(v).is_loopback   # 127.0.0.0/8 · ::1
        except ValueError:
            return v.startswith("127.")
    for _src, _bv in _bind_srcs:
        if not _is_loopback(_bv):
            _p(WARN, "대시보드 bind=%s (%s) — loopback 아님: 원격 노출 구성. README '자가검증(필수)' 통과 전 켜지 말 것." % (_bv, _src))

    # 포트: 뷰어 config.json(뷰어가 실제 읽는 단일 출처) → 환경변수/dashboard.env → 기본 18080 순.
    port_src = None
    if os.path.isfile(viewer_cfg):
        try:
            with open(viewer_cfg, encoding="utf-8") as f:
                port_src = json.load(f).get("port")
        except Exception:
            port_src = None
    if not port_src:
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

    # 유지보수 도구 발견성(G5 유틸·G7 백업) — 훅 미배선 수동 도구라 doctor 로 안내.
    backup_dir = os.path.realpath(os.path.expanduser(os.environ.get("CC_BACKUP_DIR") or "~/cockpit-backups"))
    bks = []
    if os.path.isdir(backup_dir):
        bks = sorted(f for f in os.listdir(backup_dir)
                     if f.startswith("cockpit-backup-") and f.endswith(".tar.gz"))
    if bks:
        last = os.path.join(backup_dir, bks[-1])
        when = time.strftime("%Y-%m-%d %H:%M", time.localtime(os.path.getmtime(last)))
        _p(INFO, "기억·상태 백업: %d개(%s) · 최근 %s. 생성: python3 %s/backup.py"
           % (len(bks), backup_dir, when, MEM_HOOKS))
    else:
        _p(INFO, "기억·상태 백업 없음 — 재설치는 배포판 내부 기억을 지웁니다. 재설치 전 권장: "
                 "python3 %s/backup.py (위치=CC_BACKUP_DIR, WSL 은 재설치 생존 위해 /mnt/c/... 권장)" % MEM_HOOKS)
    # 재설치 직후(사용자 기억 0건 = 비었거나 초기 템플릿뿐) **그리고 복원할 백업이 실제로
    # 발견될 때만** 자동 복원 경로 안내(마법사 1.5단계). 두 조건의 AND 인 이유(Codex 4f):
    #  - 단순 비어있음 검사는 템플릿 베이크 이미지에서 영원히 불성립(v0.1.6 실기) → 템플릿 동등 판정.
    #  - 기억-비었음 단독이면 백업이 전혀 없는 신규 설치에서도 "복원할까요?" 오발화.
    #  - 백업-존재 단독이면 건강한 설치에서 doctor 마다 복원 안내(오발화). 스캔은 로컬 glob 만(egress 0).
    if _memory_effectively_empty(MEMORY_DIR):
        cands = _restore_candidates()
        if cands:
            where = " · ".join("%s(%d개)" % (d, n) for d, n in cands[:3])
            _p(INFO, "기억 저장소에 사용자 기억이 없습니다(비었거나 초기 템플릿뿐) + 이전 백업 발견: %s "
                     "— 재설치라면 복원 가능: python3 %s/backup.py --scan → --restore --apply "
                     "(기본 dry-run·기존 데이터는 .pre-restore 로 보존)" % (where, MEM_HOOKS))
    _p(INFO, "메모리 유지보수(수동·report-only): %s 의 diet_suggest·freshness_check·read_report·"
             "build_archive_index·rotate_intent_log" % MEM_HOOKS)

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


# ───────────────────────── 메모리 추출 키(선택·BYO·G21) ─────────────────────────
def _key_file_status():
    """키 파일 상태 → (내용 있음 bool, 권한경고 문자열 또는 None).
    권한경고 = group/other 비트가 켜져 있으면 'rw-r--r--' 류 표기, 아니면 None."""
    try:
        if not os.path.isfile(EXTRACTION_KEY_FILE):
            return False, None
        with open(EXTRACTION_KEY_FILE, encoding="utf-8") as f:
            has_content = bool(f.read().strip())
        mode = os.stat(EXTRACTION_KEY_FILE).st_mode & 0o777
        perm_warn = oct(mode) if (mode & 0o077) else None
        return has_content, perm_warn
    except Exception:
        return False, None


def _write_extraction_key_file(key):
    """키를 0600 으로 원자적 기록(부모 0700). 키 원문은 절대 print 하지 않는다."""
    import tempfile
    d = os.path.dirname(EXTRACTION_KEY_FILE)
    os.makedirs(d, exist_ok=True)
    try:
        os.chmod(d, 0o700)   # 이미 있으면 권한 조여 둠(best-effort)
    except OSError:
        pass
    # mkstemp = 랜덤 이름·O_EXCL·0600 생성 → 고정 tmp 의 기존 파일/symlink 를 추종하지 않음(Codex 4f 발견2 하드닝).
    fd, tmp = tempfile.mkstemp(dir=d, prefix=".ek-")
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as f:
            f.write(key.strip() + "\n")
        os.chmod(tmp, 0o600)   # mkstemp 도 0600 이지만 명시(방어)
        os.replace(tmp, EXTRACTION_KEY_FILE)
    except Exception:
        try:
            os.remove(tmp)
        except OSError:
            pass
        raise
    os.chmod(EXTRACTION_KEY_FILE, 0o600)


def set_extraction_key(from_env=None, remove=False, allow_nonstandard=False):
    """메모리 자동추출용 API 키를 0600 키 파일에 등록/제거.
    입력 경로(우선순위): --remove / --from-env VAR / (대화형 getpass) / (파이프 stdin 한 줄).
    키 원문은 argv 로 받지 않는다(ps 노출 방지) — 대화/트랜스크립트를 통과시키지 않기 위함."""
    if remove:
        try:
            os.remove(EXTRACTION_KEY_FILE)
            _p(OK, "키 파일 제거됨: %s" % EXTRACTION_KEY_FILE)
        except FileNotFoundError:
            _p(INFO, "키 파일이 이미 없음: %s" % EXTRACTION_KEY_FILE)
        except OSError as e:
            _p(BAD, "키 파일 제거 실패: %s" % e)
            return 2
        # 파일 제거만으로 자동추출이 꺼지는 게 아니다 — env 키가 남아 있으면 계속 잡힌다(정직 고지, Codex 4f 발견1).
        if os.environ.get("ANTHROPIC_API_KEY_FOR_SCRIPTS") or os.environ.get("ANTHROPIC_API_KEY"):
            _p(WARN, "환경변수 API 키가 아직 설정돼 있어 추출 키는 여전히 잡힙니다 — 완전 비활성은 그 env 도 unset 하거나 "
                     "egress 마커 제거: rm '%s'" % os.path.join(STATE_DIR, "setup_complete"))
        else:
            _p(INFO, "env API 키도 없음 — 메모리 자동추출은 이제 비활성(수동 기억으로 복귀).")
        return 0

    # 키 수집(원문은 화면·로그에 남기지 않는다)
    key = None
    if from_env is not None:
        # from_env == "" → 기본 변수 자동탐색. 특정 변수명이면 그것만.
        names = [from_env] if from_env else ["ANTHROPIC_API_KEY_FOR_SCRIPTS", "ANTHROPIC_API_KEY"]
        for n in names:
            v = os.environ.get(n, "")
            if v.strip():
                key = v.strip()
                _p(INFO, "환경변수 %s 에서 키를 읽었습니다(값은 표시하지 않음)." % n)
                break
        if not key:
            _p(BAD, "지정한 환경변수에서 키를 찾지 못했습니다: %s" % ", ".join(names))
            return 2
    elif sys.stdin is not None and sys.stdin.isatty():
        import getpass
        try:
            key = getpass.getpass("Anthropic API 키를 붙여넣으세요(화면에 표시되지 않음): ").strip()
        except (EOFError, KeyboardInterrupt):
            print()
            _p(INFO, "취소됨 — 키를 등록하지 않았습니다.")
            return 1
    else:
        # 비대화(파이프) — 한 줄 stdin. 에이전트가 키 원문을 대신 입력하는 경로는 권장하지 않음(대화 노출).
        key = (sys.stdin.readline() if sys.stdin else "").strip()

    if not key:
        _p(BAD, "빈 키입니다 — 등록하지 않았습니다.")
        return 2
    if not key.startswith("sk-ant-") and not allow_nonstandard:
        _p(BAD, "Anthropic 키 형식(sk-ant-…)이 아닙니다. 오타 방지를 위해 등록을 막았습니다.")
        _p(INFO, "  정말 이 값을 쓰려면 --allow-nonstandard 를 붙이세요(값은 여전히 표시하지 않음).")
        return 2
    try:
        _write_extraction_key_file(key)
    except OSError as e:
        _p(BAD, "키 파일 기록 실패: %s" % e)
        return 2
    _p(OK, "키를 0600 권한으로 저장했습니다: %s (값은 표시하지 않음)" % EXTRACTION_KEY_FILE)
    _p(INFO, "다음 세션부터 egress 동의가 있으면 메모리 자동추출이 이 키를 사용합니다.")
    _p(INFO, "해제: python3 '%s' set-extraction-key --remove" % os.path.realpath(__file__))
    return 0


# ─────────────── 설치기 온보딩 적용(v0.1.8·C4 narrow 진입점) ───────────────
INSTALLER_STATE_FILE = os.path.join(STATE_DIR, "installer-onboarding.json")


def apply_installer_onboarding(memory_egress, key_registered, dashboard, governance_ack, source):
    """Windows 설치기 폼의 결정값 적용 — 전용 narrow 진입점(설계 C4).
    install 통째 호출 금지 사유: CLAUDE.md 충돌 preflight·템플릿 교체 책임이 얽혀
    fresh 이미지의 사전 생성 CLAUDE.md 와 충돌한다. 여기서는 딱 두 파일만 다룬다.

    기록 순서 = ①state 원자 기록 ②egress 마커 — 부분 실패가 전부 '자동추출 OFF'
    쪽으로 수렴한다(Codex 4f 차단2): state 실패 = 마커 미기록 → 마법사 전체 질문 /
    마커 실패 = state 만 남음 → 마법사가 불일치(egress=true·마커 부재) 감지·재안내.

    setup_complete 는 여기서도 'egress 동의 게이트'라는 기존 의미 그대로만 기록한다
    (설계 C1 — 온보딩 완료 마커로 재사용 금지·off 면 있어도 제거하지 않음: 재설정은
    마법사 소관)."""
    egress_on = (memory_egress == "on")
    if egress_on and not governance_ack:
        _p(BAD, "--memory-egress on 은 --governance-ack(거버넌스 동의) 없이는 거부합니다"
                " — install 경로의 --i-accept-governance 게이트와 동형.")
        return 2
    state = {
        "schema_version": 1,
        "source": source,
        "created_utc": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
        "governance_ack": bool(governance_ack),
        "memory_egress": egress_on,
        "extraction_key_registered": (key_registered == "yes"),
        "dashboard_viewer": dashboard,
    }
    # 1) state 원자 기록 — 실패 = 즉시 중단(마커 미기록 → 상태 없음 → 마법사 전체 질문 = 안전)
    tmp = INSTALLER_STATE_FILE + ".tmp"
    try:
        os.makedirs(STATE_DIR, exist_ok=True)
        with open(tmp, "w", encoding="utf-8") as f:
            json.dump(state, f, ensure_ascii=False, indent=2)
            f.write("\n")
        os.replace(tmp, INSTALLER_STATE_FILE)
    except OSError as e:
        try:
            os.remove(tmp)
        except OSError:
            pass
        _p(BAD, "설치기 상태 기록 실패(%s) — egress 마커는 기록하지 않았습니다(안전 방향). "
                "첫 실행 /cockpit-setup 이 전체 질문으로 진행합니다." % e)
        return 2
    _p(OK, "설치기 온보딩 상태 기록: %s" % INSTALLER_STATE_FILE)
    # 2) egress 동의 마커(동의 게이트 통과분만·기존 install 경로와 동일 내용·의미)
    if egress_on:
        marker = os.path.join(STATE_DIR, "setup_complete")
        try:
            with open(marker, "w", encoding="utf-8") as f:
                f.write("setup complete %s\n" % time.strftime("%Y%m%d-%H%M%S"))
        except OSError as e:
            _p(WARN, "egress 마커 기록 실패(%s) — 자동추출은 꺼진 상태로 남습니다(안전). "
                     "/cockpit-setup 3.5 단계에서 재시도하세요." % e)
            return 1
        _p(OK, "egress 동의 마커 기록(메모리 자동추출 외부송신 활성): %s" % marker)
        if not state["extraction_key_registered"]:
            _p(WARN, "egress 는 켜졌지만 추출용 API 키 미등록 — 등록 전까지 자동추출은 no-op(수동 기억). "
                     "등록: setup.py set-extraction-key")
    else:
        _p(INFO, "egress(메모리 자동추출 외부송신) 비활성 유지 — 나중에 켜려면 /cockpit-setup 3.5 단계.")
    _p(INFO, "대시보드 뷰어: %s" % dashboard)
    return 0


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

    # 5b) API 키 온보딩(G21·정직 고지) — egress 를 켜도 추출용 키가 없으면 자동추출은 no-op(수동 메모리만).
    #     키 원문이 대화·트랜스크립트를 통과하지 않도록 사용자가 직접 set-extraction-key 로 등록하게 안내.
    if enable_egress:
        _has_key = bool(os.environ.get("ANTHROPIC_API_KEY_FOR_SCRIPTS")
                        or os.environ.get("ANTHROPIC_API_KEY")) or _key_file_status()[0]
        if not _has_key:
            actions.append("⚠ egress 는 켜지만 추출용 API 키 미등록 — 등록 전까지 자동추출은 no-op(수동 메모리). "
                           "등록: setup.py set-extraction-key(키는 대화에 안 남김) · 발급: console.anthropic.com(사용량 과금 주의)")

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
    sk = sub.add_parser("set-extraction-key")
    sk.add_argument("--from-env", nargs="?", const="", default=None, metavar="VAR",
                    help="키 원문 대신 환경변수에서 읽어 저장(기본: ANTHROPIC_API_KEY_FOR_SCRIPTS→ANTHROPIC_API_KEY)")
    sk.add_argument("--remove", action="store_true", help="등록한 키 파일 삭제(자동추출 비활성 복귀)")
    sk.add_argument("--allow-nonstandard", action="store_true", help="sk-ant- 로 시작하지 않는 값도 허용")
    ao = sub.add_parser("apply-installer-onboarding")
    ao.add_argument("--memory-egress", choices=["on", "off"], required=True,
                    help="기억 자동추출 외부송신 — on 은 --governance-ack 필수")
    ao.add_argument("--governance-ack", action="store_true",
                    help="설치기 폼의 거버넌스 동의 체크 통과 신호(--i-accept-governance 와 동형)")
    ao.add_argument("--key-registered", choices=["yes", "no"], default="no",
                    help="설치기의 set-extraction-key 성공 여부(기록용 — 실검증은 키 파일 존재)")
    ao.add_argument("--dashboard", choices=["installed", "skipped", "failed"], default="skipped",
                    help="설치기의 대시보드 뷰어 설치 결과")
    ao.add_argument("--source", choices=["installer"], default="installer",
                    help="결정 출처(폼 명시 제출 경로만 — 무인/취소는 이 명령 자체를 호출하지 않음)")
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
    if args.cmd == "set-extraction-key":
        return set_extraction_key(from_env=args.from_env, remove=args.remove,
                                  allow_nonstandard=args.allow_nonstandard)
    if args.cmd == "apply-installer-onboarding":
        return apply_installer_onboarding(memory_egress=args.memory_egress,
                                          key_registered=args.key_registered,
                                          dashboard=args.dashboard,
                                          governance_ack=args.governance_ack,
                                          source=args.source)
    if args.cmd == "rollback":
        return rollback("--list" if args.list else "--latest")
    return 1


if __name__ == "__main__":
    sys.exit(main())
