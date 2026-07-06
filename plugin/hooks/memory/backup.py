#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""cockpit 기억·상태 백업 — 재설치(wsl --unregister) 소실 대비.

배포판을 이미지로 재설치하면 배포판 안의 기억·운영상태가 사라진다(README 경고). 이 스크립트는
그 데이터를 배포판 **밖** 위치로 tar.gz 백업해 둔다. "기억 보존형 이미지 업데이트"(백업→재설치→
복원)의 백업 절반이며, 복원 절반은 아래 --scan/--restore 가 담당한다(마법사 1.5단계에서 안내).

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


# ── 복원(재설치 후 자동 복원 — "기억 보존형 이미지 업데이트"의 나머지 절반) ──────────
# 설계 원칙:
#   - 기본 dry-run: --apply 없이는 아무것도 바꾸지 않고 무엇이 어디로 갈지 보고만 한다.
#   - 비파괴: 기존 대상이 비어있지 않으면 <경로>.pre-restore-<ts> 로 통째 이동(move-aside)해
#     보존한 뒤 복원한다(되돌리기 = 이동 반대로). 삭제는 하지 않는다.
#   - settings.json 은 기본 제외(--include-settings 로만): 새 이미지의 베이크 설정(모델 핀 등)
#     보존이 원칙이고, 구버전 설정을 덮으면 이미지 업데이트 의미가 퇴색한다.
#   - tar 멤버는 화이트리스트 루트 + 경로 검증(절대경로·'..' 거부, 일반 파일/디렉터리만)을
#     통과한 것만 수동 추출한다(extractall 미사용 — 경로탈출 원천 차단).

def _restore_root_map():
    """arcname 루트 → 실제 대상 경로. collect_sources() 와 대칭(단일출처 감각 유지)."""
    return {
        "cc-memory": ("기억", MEMORY_DIR, True),
        "cc-companion": ("상태", STATE_DIR, True),
        "CLAUDE.md": ("CLAUDE.md", CLAUDE_MD, False),
        "settings.json": ("settings.json", SETTINGS, False),
        "claude-logs": ("대시보드", DASH_HOME, True),
    }


def _scan_candidate_dirs():
    """백업이 있을 법한 위치 후보 — 재설치 직후 env 가 사라져도 발견되도록 관례 위치를 훑는다."""
    cands = []
    env_dir = os.environ.get("CC_BACKUP_DIR")
    if env_dir:
        cands.append(realexpand(env_dir))
    cands.append(realexpand("~/cockpit-backups"))
    if is_wsl():
        cands.extend(sorted(glob.glob("/mnt/[a-zA-Z]/Users/*/cockpit-backups")))
    seen, out = set(), []
    for d in cands:
        rp = os.path.realpath(d)
        if rp not in seen:
            seen.add(rp)
            out.append(d)
    return out


def _backups_in(d):
    return sorted(glob.glob(os.path.join(d, PREFIX + "*.tar.gz")))


def do_scan():
    found_any = False
    print("=== 백업 위치 스캔 ===")
    for d in _scan_candidate_dirs():
        bks = _backups_in(d)
        if bks:
            found_any = True
            mt = datetime.datetime.fromtimestamp(os.path.getmtime(bks[-1])).strftime("%Y-%m-%d %H:%M")
            print("  %s — %d개 (최근 %s: %s)" % (d, len(bks), mt, os.path.basename(bks[-1])))
        elif os.path.isdir(d):
            print("  %s — 백업 없음" % d)
    if not found_any:
        print("  발견된 백업 없음. 백업이 다른 위치에 있으면 --dir 로 지정하세요.")
        return 1
    return 0


def _pick_archive(args):
    """--file > --dir 최신 > 스캔(단일 위치면 자동, 복수면 사용자 지정 요구)."""
    if args.file:
        f = realexpand(args.file)
        if not os.path.isfile(f):
            print("백업 파일이 없습니다: %s" % f, file=sys.stderr)
            return None
        return f
    if args.dir:
        bks = _backups_in(realexpand(args.dir))
        if not bks:
            print("해당 위치에 백업이 없습니다: %s" % args.dir, file=sys.stderr)
            return None
        return bks[-1]
    with_backups = [d for d in _scan_candidate_dirs() if _backups_in(d)]
    if not with_backups:
        print("백업을 찾지 못했습니다. --dir 또는 --file 로 지정하세요. (탐색: --scan)", file=sys.stderr)
        return None
    if len(with_backups) > 1:
        print("백업 위치가 여러 곳입니다 — --dir 로 하나를 지정하세요:", file=sys.stderr)
        for d in with_backups:
            print("  - %s" % d, file=sys.stderr)
        return None
    return _backups_in(with_backups[0])[-1]


def _classify_members(tar, include_settings):
    """(복원 목록, 건너뜀 사유 목록). 복원 목록 항목 = (member, 대상 절대경로, 루트라벨)."""
    root_map = _restore_root_map()
    todo, skipped = [], []
    for m in tar.getmembers():
        name = m.name.lstrip("./")
        parts = name.split("/")
        if not name or name.startswith("/") or ".." in parts:
            skipped.append((name, "경로 검증 실패(절대경로/..)"))
            continue
        root, rest = parts[0], "/".join(parts[1:])
        if root not in root_map:
            skipped.append((name, "알 수 없는 루트(이 도구가 만든 백업이 아닐 수 있음)"))
            continue
        label, target_root, is_dir_root = root_map[root]
        if root == "settings.json" and not include_settings:
            skipped.append((name, "settings.json 은 기본 제외(--include-settings)"))
            continue
        if not (m.isfile() or m.isdir()):
            skipped.append((name, "일반 파일/디렉터리가 아님(symlink 등) — 안전상 제외"))
            continue
        if is_dir_root:
            dest = os.path.join(target_root, rest) if rest else target_root
        else:
            if rest:
                skipped.append((name, "단일 파일 루트 밑에 하위 경로 — 형식 불일치"))
                continue
            dest = target_root
        todo.append((m, dest, label))
    return todo, skipped


def _aside_existing(paths, stamp, dry_run, moved):
    """비어있지 않은 기존 대상들을 <경로>.pre-restore-<ts> 로 이동(보존).
    성공한 이동만 moved 에 증분 기록 — 중간 실패 시 호출부가 moved 만 역이동하면 원상복구된다."""
    for p in paths:
        exists = os.path.isdir(p) and os.listdir(p) if os.path.isdir(p) else os.path.isfile(p)
        if not exists:
            continue
        aside = "%s.pre-restore-%s" % (p, stamp)
        if not dry_run:
            os.rename(p, aside)
        moved.append((p, aside))


def do_restore(args):
    arc = _pick_archive(args)
    if not arc:
        return 1
    apply_ = args.apply
    print("=== cockpit 복원 %s ===" % ("" if apply_ else "[DRY-RUN — --apply 로 실행]"))
    print("원본 백업: %s (%s)" % (arc, human(os.path.getsize(arc))))

    try:
        tar = tarfile.open(arc, "r:gz")
    except (tarfile.TarError, OSError) as e:
        print("백업을 열 수 없습니다(손상 가능): %s" % e, file=sys.stderr)
        return 1
    with tar:
        todo, skipped = _classify_members(tar, args.include_settings)
        if not todo:
            print("복원할 항목이 없습니다.", file=sys.stderr)
            for name, why in skipped[:10]:
                print("  건너뜀: %s — %s" % (name, why), file=sys.stderr)
            return 1

        # 루트별 요약
        by_label = {}
        for m, dest, label in todo:
            by_label.setdefault(label, [0])
            if m.isfile():
                by_label[label][0] += 1
        root_map = _restore_root_map()
        print("복원 대상:")
        for root, (label, target_root, _d) in root_map.items():
            if label in by_label:
                print("  - %-12s → %s (파일 %d개)" % (label, target_root, by_label[label][0]))
        for name, why in skipped:
            if "기본 제외" in why or "symlink" in why:
                print("  건너뜀: %s — %s" % (name, why))

        # 기존 데이터 보존(move-aside) + 수동 추출 — 이 두 단계 전체를 하나의 롤백
        # 경계로 감싼다: 어느 지점에서 실패해도 (부분 복원물 → .failed-restore-<ts> 격리,
        # 성공한 aside 만 역이동) 원상복구된다. "기존 데이터가 비활성 상태로 남는" 사고
        # 차단(Codex 발견1 + aside 중간 실패 케이스).
        stamp = datetime.datetime.now().strftime("%Y%m%d-%H%M%S")
        targets = sorted({root_map[k][1] for k in root_map
                          if any(l == root_map[k][0] for l in by_label)})
        pre_existing = {p for p in targets
                        if (os.path.isdir(p) and os.listdir(p)) or os.path.isfile(p)}
        moved = []
        n_files = 0
        try:
            _aside_existing(targets, stamp, dry_run=not apply_, moved=moved)
            for src_p, aside in moved:
                print("  기존 보존%s: %s → %s" % ("" if apply_ else " 예정", src_p, aside))

            if not apply_:
                print("\n[dry-run] 변경 없음. 위 내용대로 실행하려면 --apply 를 추가하세요.")
                return 0

            for m, dest, label in todo:
                if m.isdir():
                    os.makedirs(dest, exist_ok=True)
                    continue
                os.makedirs(os.path.dirname(dest) or "/", exist_ok=True)
                src = tar.extractfile(m)
                if src is None:
                    print("  경고: 읽기 실패 — %s" % m.name, file=sys.stderr)
                    continue
                fd, tmp = tempfile.mkstemp(dir=os.path.dirname(dest), prefix=".restore-")
                try:
                    with os.fdopen(fd, "wb") as out:
                        while True:
                            chunk = src.read(1024 * 1024)
                            if not chunk:
                                break
                            out.write(chunk)
                    os.chmod(tmp, (m.mode & 0o777) or 0o600)
                    os.replace(tmp, dest)
                    n_files += 1
                except Exception:
                    try:
                        os.unlink(tmp)
                    except OSError:
                        pass
                    raise
        except Exception as e:
            if not apply_:
                # dry-run 은 파일시스템을 바꾸지 않으므로(aside 도 미실행) 롤백 없이 보고만.
                print("복원 사전 점검 실패: %s (변경 없음)" % e, file=sys.stderr)
                return 1
            print("복원 실패: %s — 이전 상태로 롤백합니다." % e, file=sys.stderr)
            moved_srcs = {s for s, _ in moved}
            for p in targets:
                # 격리 대상 = 부분 복원물만: aside 가 끝난 경로(현재 내용=추출 잔여물)이거나
                # 원래 없던 경로. aside 전(현재 내용=원본)인 경로는 절대 건드리지 않는다.
                if p not in moved_srcs and p in pre_existing:
                    continue
                try:
                    if os.path.exists(p):
                        os.rename(p, "%s.failed-restore-%s" % (p, stamp))
                except OSError as rb:
                    print("  롤백 경고: 부분 복원물 격리 실패(%s): %s" % (p, rb), file=sys.stderr)
            rb_fail = 0
            for src_p, aside in moved:
                try:
                    os.rename(aside, src_p)
                except OSError as rb:
                    rb_fail = 1
                    print("  롤백 경고: %s → %s 원복 실패(%s) — 데이터는 .pre-restore 경로에 그대로 보존됨(수동 이동 필요)."
                          % (aside, src_p, rb), file=sys.stderr)
            if not rb_fail:
                print("롤백 완료 — 이전 상태 그대로입니다(부분 복원물은 .failed-restore-%s 로 격리)." % stamp, file=sys.stderr)
            return 1

    print("\n복원 완료: 파일 %d개." % n_files)
    if moved:
        print("이전 상태는 .pre-restore-%s 경로에 보존됨(문제 시 이름을 되돌리면 원복)." % stamp)
    print("새 세션을 시작하면 복원된 기억이 주입됩니다. 점검: setup.py doctor")
    return 0


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--dry-run", action="store_true", help="보고만(생성/삭제 안 함)")
    ap.add_argument("--list", action="store_true", help="기존 백업 나열")
    ap.add_argument("--scan", action="store_true", help="백업 위치 후보 탐색(복원용)")
    ap.add_argument("--restore", action="store_true", help="백업에서 복원(기본 dry-run)")
    ap.add_argument("--apply", action="store_true", help="--restore 를 실제 실행")
    ap.add_argument("--file", help="복원할 백업 파일 직접 지정")
    ap.add_argument("--dir", help="백업 위치 디렉터리 지정(최신 파일 사용)")
    ap.add_argument("--include-settings", action="store_true",
                    help="settings.json 도 복원(기본 제외 — 새 이미지 베이크 설정 보존)")
    args = ap.parse_args()
    if args.scan:
        return do_scan()
    if args.restore:
        return do_restore(args)
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
