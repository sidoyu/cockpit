<#
.SYNOPSIS
  cockpit 스테이지드 설치(폴백) — 골든 이미지 없이, 베이스 배포판에서 라이브로 프로비저닝.

.DESCRIPTION
  Install-Cockpit.ps1(골든 이미지) 가 실패하거나, 골든 이미지를 신뢰하지 않거나, 구형 환경일 때의 폴백.
  미리 구운 이미지를 받지 않고, **공식 베이스 rootfs**(예: Canonical Ubuntu WSL rootfs)를 별도 배포판으로
  import 한 뒤 그 안에서 provision.sh 를 직접 실행한다(apt·npm·플러그인은 마켓플레이스로 사용자가 추가).

  골든 경로와 동일 안전 원칙:
    • **별도 배포판**(기본 cc-cockpit, 'cc-' 접두 강제). 기존 배포판 미접촉. 임의 이름은 -AllowCustomDistroName.
    • 관리자 권한 자가상승 없음. WSL 미설치 시 안내만.
    • 베이스 rootfs 는 **체크섬으로 검증**(Canonical 게시값). 미검증은 -AllowUnverifiedBaseRootfs 명시 필요(고위험).
    • provision.sh·wsl.conf 를 base64 로 배포판에 전달 → 골든과 동일 결과(인코딩 안전·자동마운트 설정 동일).
    • 편의 설정(effort·model·원격조종·trust, 플러그인 스테이징 시 bypass)은 사전적용. 외부 송신(egress)·
      자체호스팅 대시보드는 OFF(egress=첫 실행 동의 한 화면). staged 는 플러그인 미스테이징 시 bypass 미적용.

  네트워크 필요(베이스 안에서 apt/npm + 이후 /plugin marketplace add).

.PARAMETER BaseRootfs   공식 베이스 rootfs tar(.gz) 로컬 경로(예: Canonical Ubuntu WSL rootfs).
.PARAMETER BaseSha256   베이스 rootfs 기대 SHA-256(64 hex). 기본적으로 **필수**(아래 -AllowUnverifiedBaseRootfs).
.PARAMETER DistroName   import 배포판 이름(기본 cc-cockpit). 'cc-' 접두 강제.
.PARAMETER InstallPath  배포판 디스크 폴더(기본 %LOCALAPPDATA%\<DistroName>).
.PARAMETER ProvisionScript  provision.sh 경로(기본: ..\golden\provision.sh). wsl.conf 는 그 옆에서 자동 탐색.
.PARAMETER Reinstall    같은 이름의 cockpit 배포판 unregister 후 재설치(확인 프롬프트).
.PARAMETER AllowUnverifiedBaseRootfs  BaseSha256 없이 진행 허용(고위험).
.PARAMETER AllowCustomDistroName      'cc-' 접두가 아닌 임의 이름 허용(고위험).

.EXAMPLE
  powershell -NoProfile -ExecutionPolicy Bypass -File .\Install-Cockpit-Staged.ps1 -BaseRootfs .\ubuntu-24.04-wsl.rootfs.tar.gz -BaseSha256 <hex>
#>
[CmdletBinding()]
param(
  [Parameter(Mandatory=$true)][string]$BaseRootfs,
  [string]$BaseSha256,
  [ValidatePattern('^[A-Za-z0-9._-]+$')]
  [string]$DistroName = 'cc-cockpit',
  [string]$InstallPath,
  [string]$ProvisionScript,
  [switch]$Reinstall,
  [switch]$NoLauncher,
  [switch]$AllowUnverifiedBaseRootfs,
  [switch]$AllowCustomDistroName
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$MarketplaceUrl = 'https://github.com/sidoyu/cockpit'   # /plugin marketplace add 실주소(게시자 sidoyu·cc-companion).

function Info($m){ Write-Host "[cockpit-staged] $m" }
function Warn($m){ Write-Host "[cockpit-staged][warn] $m" -ForegroundColor Yellow }
function Die ($m){ Write-Host "[cockpit-staged][FATAL] $m" -ForegroundColor Red; exit 1 }

# 원터치 런처(.cmd + 시작메뉴/바탕화면 바로가기) — golden 부트스트랩과 동일 동작.
function New-CockpitLauncher {
  param([string]$Distro)
  $cockpitDir = Join-Path $env:LOCALAPPDATA 'Cockpit'
  if (-not (Test-Path $cockpitDir)) { New-Item -ItemType Directory -Path $cockpitDir -Force | Out-Null }
  $cmdPath = Join-Path $cockpitDir 'Launch-Cockpit.cmd'
  # golden 부트스트랩과 동일: 현재 콘솔 직접 실행 + 실패 시 pause(옛 wt.exe detached 분기는 즉시
  # exit0 라 실패를 숨겨 제거 — 발견3). 배포판명 **무인용**(cmd→wsl 따옴표 미탈피 라이브 실측·이름은
  # 엄격 검증돼 공백 불가) + %errorlevel% neq 0(wsl 음수 종료코드도 포착 — 라이브 실측).
  $launch = '~/.cockpit/launch.sh'
  $cmdLines = @(
    '@echo off',
    'title Claude (cockpit)',
    'setlocal',
    # 신뢰 경로 고정(Fable S1-2) — CWD 의 가짜 wsl.exe 방지, golden 런처와 동일 패턴.
    'set "WSL=%WINDIR%\System32\wsl.exe"',
    'if not exist "%WSL%" set "WSL=%WINDIR%\Sysnative\wsl.exe"',
    ('"%WSL%" -d ' + $Distro + ' bash -lc "' + $launch + '"'),
    'if %errorlevel% neq 0 (',
    '  echo(',
    '  echo [cockpit] Launch failed - check WSL/distro state:  wsl -l -v',
    '  pause',
    ')',
    'endlocal'
  )
  Set-Content -Path $cmdPath -Value $cmdLines -Encoding Ascii
  Info "런처 생성: $cmdPath"
  $iconPath = Join-Path $env:SystemRoot 'System32\wsl.exe'
  try {
    $ws = New-Object -ComObject WScript.Shell
    foreach ($t in @(
        (Join-Path ([Environment]::GetFolderPath('Programs')) 'Claude (cockpit).lnk'),
        (Join-Path ([Environment]::GetFolderPath('Desktop'))  'Claude (cockpit).lnk'))) {
      $sc = $ws.CreateShortcut($t)
      $sc.TargetPath = $cmdPath; $sc.WorkingDirectory = $cockpitDir
      $sc.IconLocation = "$iconPath,0"; $sc.Description = 'Claude Code (cockpit)'
      $sc.Save()
      Info "바로가기 생성: $t"
    }
  } catch { Warn "바로가기 생성 일부 실패(.cmd 는 생성됨): $($_.Exception.Message)" }
  return $cmdPath
}

# 대시보드 바탕화면 아이콘 — staged 는 오프라인 설치라 다운로드하지 않고, 이 스크립트 **옆**에
# 함께 스테이지된 Cockpit-Dashboard.cmd 가 있으면 그것을 복사해 아이콘을 만든다(없으면 조용히 생략).
# golden 부트스트랩(10b)과 달리 핀 검증이 없다: staged 는 이미 로컬 신뢰 파일 세트를 전제로 한다.
function New-DashboardLauncher {
  param([string]$Distro)
  if ($Distro -ne 'cc-cockpit') { return $null }   # .cmd 가 기본 배포판 하드코딩(상단 DISTRO 수동 편집용)
  $src = Join-Path $PSScriptRoot 'Cockpit-Dashboard.cmd'
  if (-not (Test-Path $src)) {
    $src = Join-Path (Join-Path (Split-Path $PSScriptRoot -Parent) 'bootstrap') 'Cockpit-Dashboard.cmd'
  }
  if (-not (Test-Path $src)) { return $null }
  $cockpitDir = Join-Path $env:LOCALAPPDATA 'Cockpit'
  if (-not (Test-Path $cockpitDir)) { New-Item -ItemType Directory -Path $cockpitDir -Force | Out-Null }
  $dashCmd = Join-Path $cockpitDir 'Cockpit-Dashboard.cmd'
  Copy-Item $src $dashCmd -Force
  Info "대시보드 런처 설치: $dashCmd"
  $iconPath = Join-Path $env:SystemRoot 'System32\wsl.exe'
  try {
    $ws = New-Object -ComObject WScript.Shell
    foreach ($t in @(
        (Join-Path ([Environment]::GetFolderPath('Programs')) 'Cockpit Dashboard.lnk'),
        (Join-Path ([Environment]::GetFolderPath('Desktop'))  'Cockpit Dashboard.lnk'))) {
      $sc = $ws.CreateShortcut($t)
      $sc.TargetPath = $dashCmd; $sc.WorkingDirectory = $cockpitDir
      $sc.IconLocation = "$iconPath,0"
      $sc.Description = 'Cockpit session dashboard (open = start, close window = stop)'
      $sc.Save()
      Info "바로가기 생성: $t"
    }
  } catch { Warn "대시보드 바로가기 생성 일부 실패(.cmd 는 설치됨): $($_.Exception.Message)" }
  return $dashCmd
}

Info "스테이지드 설치 시작 (배포판: $DistroName)"

# ── 배포판 이름 안전 ──────────────────────────────────────────────────────
if ($DistroName -cnotmatch '^cc-[A-Za-z0-9._-]+$' -and -not $AllowCustomDistroName) {
  Die "배포판 이름은 소문자 'cc-' 로 시작하고 뒤에 1자 이상이어야 합니다('cc-' 단독 불가; 기존 배포판 오접촉 방지). 임의 이름은 -AllowCustomDistroName(고위험)."
}

# ── 0) 입력 점검 ──────────────────────────────────────────────────────────
if (-not (Test-Path $BaseRootfs)) { Die "베이스 rootfs 가 없습니다: $BaseRootfs" }
if (-not $ProvisionScript) {
  $ProvisionScript = Join-Path (Split-Path $PSScriptRoot -Parent) 'golden\provision.sh'
}
if (-not (Test-Path $ProvisionScript)) { Die "provision.sh 를 찾지 못함: $ProvisionScript" }
$WslConf = Join-Path (Split-Path $ProvisionScript -Parent) 'wsl.conf'

# ── 1) 베이스 rootfs 검증(기본 필수) ──────────────────────────────────────
if ($BaseSha256) {
  if ($BaseSha256 -notmatch '^[0-9A-Fa-f]{64}$') { Die "BaseSha256 형식 오류(64-hex): $BaseSha256" }
  Info "베이스 rootfs SHA-256 검증"
  $actual = (Get-FileHash -Path $BaseRootfs -Algorithm SHA256).Hash.ToLower()
  if ($actual -ne $BaseSha256.ToLower()) {
    Die "베이스 체크섬 불일치 — 신뢰 불가.`n  기대: $($BaseSha256.ToLower())`n  실제: $actual"
  }
  Info "베이스 체크섬 일치"
} elseif ($AllowUnverifiedBaseRootfs) {
  Warn "BaseSha256 미지정 + -AllowUnverifiedBaseRootfs — 베이스 무결성을 검증하지 않고 진행합니다(고위험)."
} else {
  Die "BaseSha256 이 필요합니다(공식 게시값으로 베이스 무결성 검증). 정말 미검증으로 진행하려면 -AllowUnverifiedBaseRootfs 를 명시하세요."
}

# ── 2) 사전 점검: Windows / WSL ───────────────────────────────────────────
$build = [int][Environment]::OSVersion.Version.Build
if ($build -lt 18362) { Die "Windows 10 1903(빌드 18362) 이상 필요(현재 $build)." }
# wsl.exe 는 미설치 PC에도 스텁으로 존재(존재≠설치, v0.1.13 실사용 실측). 응답+서비스로 판별하고,
# 네이티브 stderr 리다이렉트의 EAP=Stop NativeCommandError 지뢰(같은 사고)는 Invoke-Wsl 로만 회피.
$env:WSL_UTF8 = '1'   # wsl.exe 메시지 UTF-16 미스디코드 방지(미지원 구버전은 무시)
# 신뢰 경로 고정(Codex P0) — CWD/PATH 의 가짜 wsl.exe 방지. 32비트 호스트는 Sysnative 로.
$sysDir = Join-Path $env:WINDIR 'System32'
if (-not [Environment]::Is64BitProcess -and [Environment]::Is64BitOperatingSystem) { $sysDir = Join-Path $env:WINDIR 'Sysnative' }
$WslExe = Join-Path $sysDir 'wsl.exe'
function Invoke-Wsl([string[]]$WslArgs) {
  $prev = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
  try {
    $raw = & $WslExe @WslArgs 2>&1
    $code = $LASTEXITCODE
    return @{ ok = ($code -eq 0); code = $code
              out = @($raw | ForEach-Object { "$_" -replace "`0",'' } | Where-Object { $_.Trim() -ne '' }) }
  } catch { return @{ ok = $false; code = -1; out = @("$($_.Exception.Message)") } }
  finally { $ErrorActionPreference = $prev }
}
if (-not (Invoke-Wsl @('--status')).ok) {
  # 인박스(구) WSL 은 --status 를 모른다 — 서비스(LxssManager=인박스·WslService=스토어)로 구분.
  if (-not (Get-Service -Name 'WslService','LxssManager' -ErrorAction SilentlyContinue)) {
    Warn "WSL 미설치 — 관리자 PowerShell 에서 직접 실행 후 재부팅하고 재시도:"
    Write-Host "    wsl --install --no-distribution" -ForegroundColor Cyan
    Die "WSL 미설치 — 자가 권한상승 안 함. (원클릭 설치기 Cockpit-Install.cmd 는 이 준비를 자동으로 해줍니다)"
  }
  Warn "구(인박스) WSL 로 보입니다 — --import 는 동작하나 최신 store 버전 권장: wsl --update"
}

# ── 3) 배포판 충돌 가드 ───────────────────────────────────────────────────
$listing = Invoke-Wsl @('-l','-q')
if (-not $listing.ok) { Warn "기존 배포판 목록 확인 불가(코드 $($listing.code)) — 새 WSL(배포판 0개)이면 정상." }
$existing = $listing.out | ForEach-Object { $_.Trim() }
if ($existing -contains $DistroName) {
  if (-not $Reinstall) { Die "배포판 '$DistroName' 이미 존재. 재설치는 -Reinstall." }
  Warn "재설치 — '$DistroName' unregister(데이터 삭제)."
  $ans = Read-Host "확인을 위해 배포판 이름 '$DistroName' 입력"
  if ($ans -ne $DistroName) { Die "확인 불일치 — 중단." }
  Invoke-Wsl @('--terminate', $DistroName) | Out-Null
  & $WslExe --unregister $DistroName
  if ($LASTEXITCODE -ne 0) { Die "unregister 실패(코드 $LASTEXITCODE) — 중단." }
}

# ── 4) 설치 경로 + 베이스 import ──────────────────────────────────────────
if (-not $InstallPath) { $InstallPath = Join-Path $env:LOCALAPPDATA $DistroName }
if (-not (Test-Path $InstallPath)) { New-Item -ItemType Directory -Path $InstallPath -Force | Out-Null }

Info "베이스 import: $DistroName ← $BaseRootfs"
& $WslExe --import $DistroName $InstallPath $BaseRootfs --version 2
if ($LASTEXITCODE -ne 0) { Die "wsl --import 실패(코드 $LASTEXITCODE). wsl --update 후 재시도." }

# ── 5) provision.sh + wsl.conf 를 배포판으로 전달(base64 — 인코딩 안전·추가 도구 불필요) ─
# 로컬 파일을 CRLF→LF 정규화 + UTF-8(BOM 없음) 바이트로 만들어 base64 로 보낸다.
# base64 는 순수 ASCII 라 PowerShell→WSL stdout 인코딩에 깨지지 않는다(한글 MOTD 보존).
function Get-LfBytes([string]$path) {
  $text = ([System.IO.File]::ReadAllText($path)) -replace "`r`n","`n"
  return (New-Object System.Text.UTF8Encoding($false)).GetBytes($text)
}
function Put-ToWsl([byte[]]$bytes, [string]$wslPath) {
  $b64 = [Convert]::ToBase64String($bytes)
  $b64 | & $WslExe -d $DistroName -u root -- bash -c "base64 -d > '$wslPath'"
  if ($LASTEXITCODE -ne 0) { Die "WSL 파일 쓰기 실패: $wslPath" }
}

Info "provision 자산 전달(base64)"
Put-ToWsl (Get-LfBytes $ProvisionScript) '/root/provision.sh'
if (Test-Path $WslConf) {
  Put-ToWsl (Get-LfBytes $WslConf) '/root/wsl.conf'   # provision 의 $(dirname $0)/wsl.conf 가 이걸 사용 → 골든과 동일
} else {
  Warn "wsl.conf 를 찾지 못함($WslConf) — provision 내장 기본 wsl.conf 가 쓰입니다(automount 옵션 차이 가능)."
}

Info "provision.sh 실행(배포판 내부, root)"
& $WslExe -d $DistroName -u root -- env COCKPIT_USER=cockpit COCKPIT_INSTALL_CC=1 bash /root/provision.sh
if ($LASTEXITCODE -ne 0) { Die "provision 실패(코드 $LASTEXITCODE). 배포판 로그 확인." }

# wsl.conf 의 기본 사용자 변경을 반영하려면 배포판 재시작.
Invoke-Wsl @('--terminate', $DistroName) | Out-Null

Info "스테이지드 설치 완료 ✓  (편의 설정 사전적용)"

$LauncherCmd = $null
$DashboardCmd = $null
if (-not $NoLauncher) {
  try { $LauncherCmd = New-CockpitLauncher -Distro $DistroName }
  catch { Warn "런처 생성 실패(수동 진입 가능): $($_.Exception.Message)" }
  try { $DashboardCmd = New-DashboardLauncher -Distro $DistroName }
  catch { Warn "대시보드 아이콘 생성 실패(설치는 정상): $($_.Exception.Message)" }
}

Write-Host ""
Write-Host "다음 단계:" -ForegroundColor Green
if ($LauncherCmd) {
  Write-Host "  • 바탕화면/시작메뉴의 'Claude (cockpit)' 더블클릭 → claude 가 바로 실행됩니다."
} else {
  Write-Host "  • 진입:  wsl -d $DistroName"
}
if ($DashboardCmd) {
  Write-Host "  • 바탕화면 'Cockpit Dashboard' 더블클릭 → 세션 대시보드(선택 기능·/cockpit-setup 옵트인 후 동작·창 닫으면 꺼짐)."
}
Write-Host "  1) 로그인(최초 1회): claude 화면에서 /login → 브라우저에서 'Claude 구독으로 로그인'(보통 1번) 선택."
Write-Host "  2) 로그인하면 창이 자동으로 한 번 다시 시작되며 원격조종이 켜집니다(수동 재시작 불필요. 안 되면 창 닫고 다시 실행)."
Write-Host "  3) /plugin marketplace add $MarketplaceUrl"
Write-Host "  4) /plugin install cockpit@cc-companion"
Write-Host "  5) /cockpit-setup     # 거버넌스 동의 한 화면 + (원하면) 기억 외부송신 켜기"
Write-Host "     (staged 경로는 설치기 온보딩 폼이 없습니다 — 골든 이미지 설치기 v0.1.8+ 전용. 온보딩은 위 /cockpit-setup 이 전담.)"
Write-Host ""
Write-Host "통째 삭제:  wsl --unregister $DistroName   # 다른 배포판은 안 건드림" -ForegroundColor Cyan
