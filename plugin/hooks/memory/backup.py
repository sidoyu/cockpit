#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""cockpit 기억·상태 백업 — 재설치(wsl --unregister) 소실 대비.

배포판을 이미지로 재설치하면 배포판 안의 기억·운영상태가 사라진다(README 경고). 이 스크립트는
그 데이터를 배포판 **밖** 위치로 tar.gz 백업해 둔다. "기억 보존형 이미지 업데이트"(백업→재설치→
복원)의 백업 절반이다. 복원 절반(재설치 흐름 자동 복원)은 후속 설계.

백업 대상:
  - 기억 저장소  cc_paths.MEMORY_DIR (~/.claude/cc-memory)     ← 핵심(재생성 불가)
  - 운영 상태    cc_paths.STATE_DIR  (~/.claude/cc-companion)   ← pending·cwp 감사·analyzed
  - 행동 규율    ~/.claude/CLAUDE.md
  - 설정         ~/.claude/settings.json
  - (옵션) 대시보드 데이터  CC_DASH_HOME(기본 ~/claude-logs)  — CC_BACKUP_INCLUDE_DASHBOARD=1 일 때만,
                 img/(파생물) 제외.

백업 위치(CC_BACKUP_DIR, 기본 ~/cockpit-backups):
  ★ WSL 에서 재설치를 견디려면 **Windows 파일시스템 경로**로 두어야 한다(예:
    CC_BACKUP_DIR=/mnt/c/Users/<당신>/cockpit-backups). 배포판 내부 경로(/mnt/ 밖)면
    재설치 시 백업도 함께 사라지므로 경고한다.

보존: CC_BACKUP_RETENTION(기본 8)개 최근분만 유지(오래된 것 삭제 = 유일한 파괴적 동작·회전만).
실행:
  python3 backup.py            # 백업 생성
  python3 backup.py --dry-run  # 무엇을 백업/회전할지 보고만(생성 안 함)
  python3 backup.py --list     # 기존 백업 나열
"""
import os, sys, re, glob, argparse, datetime, tarfile, tempfile
try:
    import fcntl   # POSIX(WSL·mac) — 동시 실행 직렬화용. 없으면 락 없이 진행(단일 실행 전제).
except ImportError:
    fcntl = None

_HERE = os.path.dirname(os.path.realpath(__file__))
if _HERE not in sys.path:
    sys.path.insert(0, _HERE)
from cc_paths import MEMORY_DIR, STATE_DIR, CLAUDE_MD, realexpand

HOME = os.path.expanduser("~")
SETTINGS = os.path.join(HOME, ".claude", "settings.json")
BACKUP_DIR = realexpand(os.environ.get("CC_BACKUP_DIR") or "~/cockpit-backups")
DASH_HOME = realexpand(os.environ.get("CC_DASH_HOME") or "~/claude-logs")
INCLUDE_DASH = os.environ.get("CC_BACKUP_INCLUDE_DASHBOARD") == "1"
try:
    RETENTION = max(1, int(os.environ.get("CC_BACKUP_RETENTION") or "8"))
except ValueError:
    RETENTION = 8
PREFIX = "cockpit-backup-"


def is_wsl():
    if os.environ.get("WSL_DISTRO_NAME"):
        return True
    try:
        with open("/proc/version", encoding="utf-8", errors="ignore") as f:
            v = f.read().lower()
        return "microsoft" in v or "wsl" in v
    except Exception:
        return False


_WIN_DRIVE_RE = re.compile(r"^/mnt/[A-Za-z](/|$)")


def survives_reinstall(path):
    """WSL 에서 이 경로가 재설치(unregister)를 견디는가 = Windows 드라이브(/mnt/<문자>/) 인가.
    /mnt/wsl 같은 비-드라이브 마운트는 배포판 생명주기와 얽혀 생존 보장 없음 → 제외.
    WSL 아니면(맥 등) 항상 True(별도 재설치 소실 개념 없음)."""
    if not is_wsl():
        return True
    return bool(_WIN_DRIVE_RE.match(path))


def collect_sources():
    """(라벨, 절대경로, arcname) 목록 — 존재하는 것만."""
    srcs = []
    for label, p, arc in (
        ("기억", MEMORY_DIR, "cc-memory"),
        ("상태", STATE_DIR, "cc-companion"),
        ("CLAUDE.md", CLAUDE_MD, "CLAUDE.md"),
        ("settings.json", SETTINGS, "settings.json"),
    ):
        if os.path.exists(p):
            srcs.append((label, p, arc))
    if INCLUDE_DASH and os.path.isdir(DASH_HOME):
        srcs.append(("대시보드", DASH_HOME, "claude-logs"))
    return srcs


def _dash_filter(ti):
    # 대시보드 파생물(img/) 제외 — JSONL 이 master, 재생성 가능
    parts = ti.name.split("/")
    if "img" in parts:
        return None
    return ti


def human(n):
    for u in ("B", "KB", "MB", "GB"):
        if n < 1024 or u == "GB":
            return "%.1f%s" % (n, u)
        n /= 1024.0


def do_list():
    files = sorted(glob.glob(os.path.join(BACKUP_DIR, PREFIX + "*.tar.gz")))
    if not files:
        print("백업 없음 (%s)" % BACKUP_DIR)
        return 0
    print("기존 백업 (%s):" % BACKUP_DIR)
    for f in files:
        sz = os.path.getsize(f)
        mt = datetime.datetime.fromtimestamp(os.path.getmtime(f)).strftime("%Y-%m-%d %H:%M")
        print("  %s  %8s  %s" % (mt, human(sz), os.path.basename(f)))
    return 0


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--dry-run", action="store_true", help="보고만(생성/삭제 안 함)")
    ap.add_argument("--list", action="store_true", help="기존 백업 나열")
    args = ap.parse_args()
    if args.list:
        return do_list()

    srcs = collect_sources()
    if not srcs:
        print("백업 대상 없음 — 기억/상태 저장소가 아직 없습니다(신규 설치 직후일 수 있음).")
        return 0

    # 자기포함 가드: 백업 위치가 백업 대상 트리 안이면 tar 가 자신을 재귀 포함 → 거부(오설정)
    bd = os.path.join(BACKUP_DIR, "")   # 경계 확실히(prefix 오탐 방지)
    for label, p, _ in srcs:
        if os.path.isdir(p) and (BACKUP_DIR == p or bd.startswith(os.path.join(p, ""))):
            print("백업 위치(%s)가 백업 대상 '%s'(%s) 안에 있습니다 — 자기포함 방지를 위해 중단."
                  % (BACKUP_DIR, label, p), file=sys.stderr)
            print("  CC_BACKUP_DIR 를 대상 밖(권장: Windows 경로 /mnt/c/...)으로 지정하세요.", file=sys.stderr)
            return 1

    print("=== cockpit 백업 %s ===" % ("[DRY-RUN]" if args.dry_run else ""))
    print("대상:")
    for label, p, _ in srcs:
        print("  - %-12s %s" % (label, p))
    print("위치: %s (보존 %d개)" % (BACKUP_DIR, RETENTION))
    if not survives_reinstall(BACKUP_DIR):
        print("  ⚠ 이 위치는 WSL 배포판 내부입니다 — 재설치(wsl --unregister) 시 백업도 사라집니다.")
        print("    재설치를 견디려면 Windows 경로로: CC_BACKUP_DIR=/mnt/c/Users/<당신>/cockpit-backups")

    # 회전 대상(생성 후 보존 초과분) 미리 계산해 보고
    existing = sorted(glob.glob(os.path.join(BACKUP_DIR, PREFIX + "*.tar.gz")))
    to_rotate = existing[: max(0, len(existing) + 1 - RETENTION)]   # 이번 생성분 포함 후 오래된 것부터
    if to_rotate:
        print("회전(삭제) 예정 %d개(보존 %d 초과):" % (len(to_rotate), RETENTION))
        for f in to_rotate:
            print("  - %s" % os.path.basename(f))

    if args.dry_run:
        print("\n[dry-run] 생성 예정: %s%s-…-%d.tar.gz" % (PREFIX, datetime.datetime.now().strftime("%Y%m%d-%H%M%S"), os.getpid()))
        return 0

    os.makedirs(BACKUP_DIR, exist_ok=True)
    # 파일명에 microsecond+pid → 같은 초/동시 실행 충돌 회피(기존 백업 덮어쓰기 방지, Codex 발견1)
    stamp = datetime.datetime.now().strftime("%Y%m%d-%H%M%S-%f")
    out = os.path.join(BACKUP_DIR, "%s%s-%d.tar.gz" % (PREFIX, stamp, os.getpid()))

    # 동시 실행 직렬화(생성+회전 임계구역) — 두 프로세스가 tmp 충돌/회전 경합 내지 않게(Codex 발견1)
    lockf = None
    if fcntl is not None:
        try:
            lockf = open(os.path.join(BACKUP_DIR, ".backup.lock"), "w")
            fcntl.flock(lockf, fcntl.LOCK_EX)
        except Exception:
            lockf = None   # 락 실패해도 진행(고유 파일명이 최소 안전망)
    try:
        # tmp = 같은 디렉터리 내 고유명(mkstemp 0600) → 부분 tar 격리 + at-rest 권한(Codex 발견3)
        fd, tmp = tempfile.mkstemp(dir=BACKUP_DIR, prefix=".part-", suffix=".tar.gz")
        os.close(fd)
        try:
            with tarfile.open(tmp, "w:gz") as tar:
                for label, p, arc in srcs:
                    flt = _dash_filter if label == "대시보드" else None
                    tar.add(p, arcname=arc, filter=flt)
            os.replace(tmp, out)   # 원자적 확정: 부분 tar 가 완성본으로 오인되지 않게
        except Exception as e:
            try:
                os.unlink(tmp)
            except OSError:
                pass
            print("백업 실패: %s" % e, file=sys.stderr)
            return 1
        try:
            os.chmod(out, 0o600)   # 민감(기억·설정) at-rest 보호. WSL drvfs 에선 no-op 가능하나 무해.
        except OSError:
            pass

        print("\n생성: %s (%s)" % (out, human(os.path.getsize(out))))
        print("  ⚠ 이 파일엔 기억·설정 등 민감정보가 담깁니다 — 공유·공용 PC 유출 주의(chmod 600 적용·본인 폴더 보관).")

        # 보존 회전(오래된 것부터 삭제·방금 만든 out 은 절대 삭제 안 함)
        others = sorted(f for f in glob.glob(os.path.join(BACKUP_DIR, PREFIX + "*.tar.gz"))
                        if os.path.realpath(f) != os.path.realpath(out))
        removed = 0
        for f in others[: max(0, len(others) + 1 - RETENTION)]:
            try:
                os.remove(f)
                removed += 1
            except OSError:
                pass
        if removed:
            print("회전: 오래된 백업 %d개 삭제(보존 %d개)" % (removed, RETENTION))
    finally:
        if lockf is not None:
            try:
                fcntl.flock(lockf, fcntl.LOCK_UN)
            except Exception:
                pass
            lockf.close()
    return 0


if __name__ == "__main__":
    sys.exit(main())
