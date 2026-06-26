# Windows 트랙 — WSL2 골든 이미지 + PowerShell 부트스트랩

> 비개발 동료가 Windows 에서 cockpit(cc-companion) 을 **별도 WSL2 배포판**으로 거의 그대로 설치하는 경로.
> 기존 Ubuntu 등 다른 WSL 배포판을 건드리지 않는다. v0.1.1 부터 편의 설정(bypass·effort·model·원격조종·trust)은
> 동료가 "로그인만" 하도록 **사전적용 출고**하되, **외부 송신(egress) 동의**·Codex·자체호스팅 대시보드는 OFF —
> egress 는 첫 실행 `/cockpit-setup` 동의 한 화면, 나머지는 명시 설정 시에만 켜진다(`scripts/smoke-image.sh` 가 검증).

---

## 왜 이렇게(설계 결정)

| 결정 | 이유 |
|------|------|
| **별도 배포판**(`wsl --import cc-cockpit …`) | 사용자의 기존 Ubuntu/개발 환경 오염 금지. 통째 삭제(`wsl --unregister cc-cockpit`)로 깨끗이 되돌림. |
| **`irm … \| iex` 미사용** | '받자마자 실행'은 비개발자에게 가장 위험. **다운로드 → SHA-256 체크섬 검증 → 명시적 실행** 순서(이 배포본은 코드서명 없음 — 무결성은 체크섬 대조). |
| **이미지 해시를 부트스트랩에 핀 고정** | 서버에서 해시를 같이 받지 않는다(서버 장악 시 둘 다 바뀜). 신뢰는 *스크립트에 박힌 해시*. 핀이 플레이스홀더면 **실행 거부**(가짜 검증 방지). |
| **게시 포맷 = `.tar.gz`** | WSL `--import` 가 네이티브로 풀고, Windows 측에 별도 `zstd` 바이너리가 필요 없다(.NET GZipStream 폴백 내장). 비개발자 경로의 신뢰 바이너리 수 = 0. |
| **자가 권한상승 안 함** | WSL 미설치 시 사용자가 직접 실행할 관리자 명령만 안내하고 종료. 관찰 가능·되돌림 가능. |
| **골든 이미지 = CI 빌드(수동 tar 금지)** | 핀 고정 베이스에서 `provision.sh` 를 돌려 export → 출처·재현성 확보(`provenance.json`). |
| **스테이지드 폴백 제공** | 골든 이미지 다운로드 실패/불신/구형 환경용. 공식 베이스 rootfs 를 검증해 import 후 라이브 프로비저닝. |

---

## 구성 파일

```
windows/
  README.md                         이 문서(설계 + 사용)
  golden/
    provision.sh                    이미지 내부 프로비저닝(deps·기본사용자·wsl.conf·플러그인 스테이징). 위험기능 OFF 강제.
    wsl.conf                        배포판에 구워지는 /etc/wsl.conf(기본 사용자·systemd·interop)
    build-rootfs.sh                 골든 이미지 빌더(컨테이너에서 provision 실행 → tar.gz + sha256 + provenance)
  bootstrap/
    Install-Cockpit.ps1             메인 부트스트랩(다운로드→검증→별도 배포판 import)
    manifest.example.json           릴리스 매니페스트 스키마(게시·감사 단일 출처, 플레이스홀더)
  staged/
    Install-Cockpit-Staged.ps1      폴백(골든 이미지 없이 베이스에서 라이브 프로비저닝)
```

---

## 신뢰 사슬(요약)

1. 사용자가 **HTTPS 웹 안내**(게시 채널)에서 부트스트랩과 이미지의 URL·SHA-256 을 본다. **이 배포본은 코드서명이 없다(unsigned)** — 무결성은 SHA-256 대조로 보장한다.
2. `Install-Cockpit.ps1` 을 받아 **실행 전** 확인:
   - `Get-FileHash .\Install-Cockpit.ps1 -Algorithm SHA256` → 웹의 값과 일치?
   - (`Get-AuthenticodeSignature` 는 이 빌드에서 `NotSigned` 가 정상 — 서명층 없음.)
3. 실행하면 스크립트가 **이미지**를 받아 **핀 고정 SHA-256** 과 대조한 뒤에만 import 한다.
   불일치면 받은 파일을 삭제하고 중단한다.
4. import 는 **별도 배포판**으로만. 기존 배포판은 건드리지 않는다.

> 핀(`$PinnedSha256`)이 플레이스홀더이거나 URL/해시를 오버라이드하면 부트스트랩이 **진행을 거부**한다(가짜검증 방지).
> 강제로 검토하려면 `-AllowUnpinnedImage` + `-ImageUrl`·`-ExpectedSha256` 을 직접 넘긴다.

---

## 사용(배포 후)

### A. 골든 이미지(기본·권장)
```powershell
# 1) 받기(웹 안내의 링크). 2) SHA-256 해시 확인(서명 없음). 3) 실행:
powershell -NoProfile -ExecutionPolicy Bypass -File .\Install-Cockpit.ps1
```
- `-DistroName` 기본 `cc-cockpit` · `-InstallPath` 기본 `%LOCALAPPDATA%\cc-cockpit`
- 같은 이름 배포판이 이미 있으면 `-Reinstall`(확인 프롬프트, **그 배포판만** unregister)

### B. 스테이지드 폴백(골든 실패/불신/구형)
```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\Install-Cockpit-Staged.ps1 `
  -BaseRootfs .\ubuntu-24.04-wsl.rootfs.tar.gz -BaseSha256 <공식 게시 해시>
```
공식 베이스 rootfs(예: Canonical Ubuntu WSL)를 받아 **체크섬 검증** 후 import, 그 안에서 `provision.sh` 실행.

### 사전 준비(사용자 수동 — 자동화 불가)
- WSL2 사용 가능 상태. 미설치 시 부트스트랩이 안내하는 명령을 **관리자 PowerShell** 에서 직접 실행:
  ```powershell
  wsl --install --no-distribution   # 후 재부팅
  wsl --update                      # 최신 store 버전 권장(--import 안정성)
  ```

---

## 끄기 · 되돌리기
- 자동 진행 즉시정지(배포판 안): `touch ~/.claude/CC_KILL_SWITCH`
- 원격/Codex 끄기: `/cockpit-doctor` 안내(원격은 기본 OFF) · `rm ~/.claude/codex_enabled`
- **이 배포판 통째 삭제**: `wsl --unregister cc-cockpit` — 다른 배포판은 그대로.

---

## 빌드(배포자)

```bash
# 컨테이너 런타임(docker/podman) + gzip 필요. 재현성 위해 베이스를 digest 로 핀 고정.
BASE_IMAGE='ubuntu:24.04@sha256:<digest>' SOURCE_DATE_EPOCH=<epoch> \
  windows/golden/build-rootfs.sh dist/windows
# 산출: dist/windows/{cockpit-wsl.tar.gz, .sha256, provenance.json}
# → SHA-256 을 Install-Cockpit.ps1 의 $PinnedSha256 / 웹 다운로드 표에 박고, .ps1 서명 후 게시.
```

`provenance.json` 필드: 베이스 이미지 digest · 플러그인 커밋 · `SOURCE_DATE_EPOCH` · 압축/비압축 SHA-256.
**SBOM·이미지 서명·재현 빌드 로그**는 CI 골든 파이프라인(단계5)에서 첨부한다.

---

## 알려진 한계(의도적·문서화)
- **PowerShell 정적검사 미수행(이 저장소 빌드 환경에 `pwsh` 없음)** — Authenticode 서명·실 Windows 스모크는 발행 전 단계5(CI)에서 수행.
- 재현 빌드는 *베이스 digest 핀 + 버전 기록 + 체크섬* 수준(완전 bit-for-bit 아님; apt 스냅샷 고정은 단계5 과제).
- 골든 이미지에 Claude Code CLI 는 베이크하되 **로그인(OAuth)은 사용자별**이라 굽지 않는다(첫 실행).
