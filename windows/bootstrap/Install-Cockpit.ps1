<#
.SYNOPSIS
  cockpit (cc-companion) WSL2 골든 이미지 부트스트랩 — 다운로드 → 검증 → 별도 배포판으로 import.

.DESCRIPTION
  비개발자도 안전하게 따라 할 수 있도록 설계된 설치기. 핵심 안전 속성:
    • `irm … | iex` 류 '받자마자 실행' 패턴 미사용. 받은 파일을 SHA-256 으로 검증한 뒤에만 import 한다.
    • 이미지 해시는 이 스크립트 안에 핀 고정($PinnedSha256). 서버에서 해시를 같이 받아오지 않는다.
      플레이스홀더이거나 사용자가 URL/해시를 오버라이드하면 = 핀-미사용 모드 → -AllowUnpinnedImage 명시 필요(가짜검증 방지).
    • **별도 배포판**(기본 cc-cockpit, 이름은 'cc-' 접두 강제). 기존 Ubuntu 등 다른 WSL 배포판을 건드리지 않는다.
      임의 이름은 -AllowCustomDistroName 고위험 플래그로만 허용.
    • 관리자 권한을 스스로 올리지 않는다. WSL 미설치 시 사용자가 직접 실행할 명령만 안내하고 종료.
    • 편의 설정(bypass·effort·model·원격조종·trust)은 이미지에 사전적용 출고. 단 **외부 송신(egress) 동의**·
      Codex·자체호스팅 대시보드는 OFF — egress 는 첫 실행 /cockpit-setup 동의 한 화면, 나머지는 명시 설정 시에만.

  무결성: 이 배포본은 코드서명 인증서 미보유로 Authenticode 서명이 없다(unsigned).
    무결성은 다운로드한 .ps1·이미지의 SHA-256 을 웹 다운로드 표·이 스크립트의 핀과 대조해 보장한다:
    Get-FileHash .\Install-Cockpit.ps1 -Algorithm SHA256   # 웹 안내의 SHA-256 과 직접 대조
    (이미지 tar.gz 는 스크립트가 import 전에 핀 해시로 자동 대조 — 불일치 시 삭제·중단.)

.PARAMETER ImageUrl       골든 이미지(.tar.gz) URL. 미지정 시 핀 고정 URL. https 만 허용. (오버라이드 = 핀-미사용)
.PARAMETER ImageFile      이미 받아 둔 로컬 이미지 경로. 지정해도 핀 고정 해시로 검증(핀-미사용 아님).
.PARAMETER ExpectedSha256 이미지 기대 SHA-256(64 hex). 미지정 시 핀 고정값. (오버라이드 = 핀-미사용)
.PARAMETER DistroName     import 할 WSL 배포판 이름(기본 cc-cockpit). 'cc-' 접두 강제(아래 -AllowCustomDistroName).
.PARAMETER InstallPath    배포판 디스크 폴더(기본 %LOCALAPPDATA%\<DistroName>).
.PARAMETER Reinstall      같은 이름의 cockpit 배포판을 unregister 후 재설치(확인 프롬프트). 다른 배포판은 절대 미접촉.
.PARAMETER SkipLaunch     설치 후 자동 진입하지 않음.
.PARAMETER NoLauncher     원터치 런처(.cmd + 시작메뉴/바탕화면 바로가기) 생성을 건너뜀.
.PARAMETER AllowUnpinnedImage     핀-미사용(미발행 미리보기 / URL·해시 오버라이드)을 명시 허용(고위험).
.PARAMETER AllowCustomDistroName  'cc-' 접두가 아닌 임의 배포판 이름을 명시 허용(고위험 — 기존 배포판 오접촉 위험).

.EXAMPLE
  powershell -NoProfile -ExecutionPolicy Bypass -File .\Install-Cockpit.ps1
#>
[CmdletBinding()]
param(
  [string]$ImageUrl,
  [string]$ImageFile,
  [string]$ExpectedSha256,
  [ValidatePattern('^[A-Za-z0-9._-]+$')]
  [string]$DistroName = 'cc-cockpit',
  [string]$InstallPath,
  [switch]$Reinstall,
  [switch]$SkipLaunch,
  [switch]$NoLauncher,
  [switch]$AllowUnpinnedImage,
  [switch]$AllowCustomDistroName
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# ── 게시 시 치환되는 핀 고정값(빌드/릴리스 파이프라인이 채움) ──────────────
$PinnedImageUrl = 'https://github.com/sidoyu/cockpit/releases/download/v0.1.2/cockpit-wsl.tar.gz'
$PinnedSha256   = '9b5cc736e52ad37fb731fb9723d829750b558ecf256df7ae9b232606c00a740b'   # cockpit-wsl.tar.gz SHA-256 (golden-build 산출).
$MarketplaceUrl = 'https://github.com/sidoyu/cockpit'                                  # /plugin marketplace add 실주소(게시자 sidoyu·cc-companion).
$PLACEHOLDER_HOSTS = @('example.invalid')

function Info($m){ Write-Host "[cockpit] $m" }
function Warn($m){ Write-Host "[cockpit][warn] $m" -ForegroundColor Yellow }
function Die ($m){ Write-Host "[cockpit][FATAL] $m" -ForegroundColor Red; exit 1 }

Info "cockpit WSL2 부트스트랩 시작 (배포판: $DistroName)"

# ── 배포판 이름 안전(기존 배포판 오접촉 방지) ─────────────────────────────
if ($DistroName -cnotmatch '^cc-[A-Za-z0-9._-]+$' -and -not $AllowCustomDistroName) {
  Die "안전을 위해 배포판 이름은 소문자 'cc-' 로 시작하고 뒤에 1자 이상이어야 합니다(기본 cc-cockpit; 'cc-' 단독 불가). 기존 배포판(예: Ubuntu) 오접촉 방지. 임의 이름이 꼭 필요하면 -AllowCustomDistroName 을 명시(고위험)."
}

# ── 0) TLS 1.2+ 강제(구버전 PowerShell 기본이 취약) ───────────────────────
try {
  [Net.ServicePointManager]::SecurityProtocol = `
    [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
} catch { Warn "TLS 설정 조정 실패(무시 가능): $($_.Exception.Message)" }

# ── 1) 해시·URL 확정 + 핀-미사용 게이트 ───────────────────────────────────
$pinIsReal  = ($PinnedSha256 -match '^[0-9A-Fa-f]{64}$')
# URL·해시 오버라이드는 핀을 벗어난다. -ImageFile(로컬 사본)은 여전히 핀 해시로 검증 → 핀-미사용 아님.
$overriding = ($PSBoundParameters.ContainsKey('ExpectedSha256') -or $PSBoundParameters.ContainsKey('ImageUrl'))

if (-not $ExpectedSha256) { $ExpectedSha256 = $PinnedSha256 }
if (-not $ImageUrl)       { $ImageUrl       = $PinnedImageUrl }

$unpinned = (-not $pinIsReal) -or $overriding
if ($unpinned -and -not $AllowUnpinnedImage) {
  Die @"
이 실행은 핀 고정(스크립트에 박힌 해시) 모델을 벗어납니다:
  • 핀 고정 해시 유효 : $pinIsReal   (미발행 미리보기면 false)
  • URL/해시 오버라이드: $overriding
핀을 벗어난 이미지를 설치하려면 위험을 이해하고 **-AllowUnpinnedImage** 를 명시하세요.
해시 출처(웹 게시값)를 직접 검증하지 않으면 '같은 서버에서 받은 해시'와 다를 바 없습니다.
"@
}
if ($unpinned) { Warn "핀-미사용 모드 — 해시 출처(HTTPS 게시 채널의 SHA-256)를 직접 검증했는지 확인하세요." }

if ($ExpectedSha256 -notmatch '^[0-9A-Fa-f]{64}$') {
  Die "기대 SHA-256 이 64-hex 가 아닙니다(현재: '$ExpectedSha256'). 웹 게시값을 -ExpectedSha256 로 넘기세요."
}

# ── 2) 다운로드 소스 확정 ─────────────────────────────────────────────────
$usingLocal = [bool]$ImageFile
if (-not $usingLocal) {
  $uri = $null
  if (-not [Uri]::TryCreate($ImageUrl, [UriKind]::Absolute, [ref]$uri) -or $uri.Scheme -ne 'https') {
    Die "이미지 URL 은 https 여야 합니다: $ImageUrl"
  }
  if ($PLACEHOLDER_HOSTS -contains $uri.Host) {
    Die "이미지 URL 호스트가 플레이스홀더($($uri.Host))입니다 — 미발행 미리보기. -ImageUrl 로 실제 주소를 넘기세요."
  }
}

# ── 3) 사전 점검: Windows 버전 + WSL2 ─────────────────────────────────────
Info "사전 점검: Windows / WSL2"
$build = [int][Environment]::OSVersion.Version.Build
if ($build -lt 18362) {
  Die "Windows 10 1903(빌드 18362) 이상이 필요합니다(현재 빌드 $build). WSL2 미지원."
}
$wsl = Get-Command wsl.exe -ErrorAction SilentlyContinue
if (-not $wsl) {
  Warn "WSL 이 설치되어 있지 않습니다. 관리자 PowerShell 에서 아래를 직접 실행한 뒤 재부팅하고 이 스크립트를 다시 실행하세요:"
  Write-Host "    wsl --install --no-distribution" -ForegroundColor Cyan
  Die "WSL 미설치 — 스스로 권한을 올리지 않습니다(안전). 위 명령을 직접 실행하세요."
}
$wslVer = (& wsl.exe --version) 2>$null
if (-not $wslVer) {
  Warn "wsl --version 출력이 없음 — 인박스(구) WSL 일 수 있습니다. --import 는 동작하나 최신 store 버전 권장:"
  Write-Host "    wsl --update" -ForegroundColor Cyan
}

# ── 4) 배포판 이름 충돌 가드(기존 배포판 보호) ────────────────────────────
# `wsl -l -q` 는 UTF-16 + NUL 이 섞여 나오므로 정리해서 비교. 조회 실패 시 충돌 가드 신뢰 불가 → 경고.
$existing = @()
$raw = (& wsl.exe -l -q) 2>$null
if ($LASTEXITCODE -ne 0) {
  Warn "wsl -l -q 조회 실패(코드 $LASTEXITCODE) — 기존 배포판 목록을 신뢰할 수 없습니다. import 가 충돌하면 안전하게 실패합니다."
}
$existing = $raw | ForEach-Object { ($_ -replace "`0","").Trim() } | Where-Object { $_ -ne '' }

if ($existing -contains $DistroName) {
  if (-not $Reinstall) {
    Die "배포판 '$DistroName' 이 이미 등록되어 있습니다. 재설치하려면 -Reinstall 을 지정하세요(해당 배포판만 unregister)."
  }
  Warn "재설치 요청 — '$DistroName' 을 unregister 합니다. 이 배포판 안의 데이터는 모두 삭제됩니다."
  $ans = Read-Host "정말 진행하려면 배포판 이름 '$DistroName' 을 그대로 입력하세요"
  if ($ans -ne $DistroName) { Die "확인 불일치 — 중단(아무것도 변경하지 않음)." }
  & wsl.exe --terminate $DistroName 2>$null | Out-Null
  & wsl.exe --unregister $DistroName
  if ($LASTEXITCODE -ne 0) { Die "unregister 실패(코드 $LASTEXITCODE) — 중단." }
  Info "기존 '$DistroName' 제거 완료. (다른 배포판은 건드리지 않았습니다.)"
}

# ── 5) 설치 경로 준비 ─────────────────────────────────────────────────────
if (-not $InstallPath) { $InstallPath = Join-Path $env:LOCALAPPDATA $DistroName }
if (-not (Test-Path $InstallPath)) { New-Item -ItemType Directory -Path $InstallPath -Force | Out-Null }

# ── 6~9) 이미지 확보 → 검증 → import (임시 디렉터리는 finally 에서 정리) ────
$work = Join-Path ([System.IO.Path]::GetTempPath()) ("cockpit-" + [Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $work -Force | Out-Null
$gz = Join-Path $work 'cockpit-wsl.tar.gz'

function Expand-GzipToTar([string]$src, [string]$dst) {
  $in = [System.IO.File]::OpenRead($src)
  try {
    $gzs = New-Object System.IO.Compression.GzipStream($in, [System.IO.Compression.CompressionMode]::Decompress)
    try {
      $out = [System.IO.File]::Create($dst)
      try { $gzs.CopyTo($out) } finally { $out.Dispose() }
    } finally { $gzs.Dispose() }
  } finally { $in.Dispose() }
}

try {
  # 6) 이미지 확보(다운로드 or 로컬)
  if ($usingLocal) {
    if (-not (Test-Path $ImageFile)) { Die "로컬 이미지 파일이 없습니다: $ImageFile" }
    Info "로컬 이미지 사용: $ImageFile"
    Copy-Item $ImageFile $gz -Force
  } else {
    Info "이미지 다운로드: $ImageUrl"
    try { Invoke-WebRequest -Uri $ImageUrl -OutFile $gz -UseBasicParsing }
    catch { Die "다운로드 실패: $($_.Exception.Message)" }
  }

  # 7) SHA-256 검증(import 전에 — 핵심 게이트)
  Info "SHA-256 검증"
  $actual = (Get-FileHash -Path $gz -Algorithm SHA256).Hash.ToLower()
  $expect = $ExpectedSha256.ToLower()
  if ($actual -ne $expect) {
    Die "체크섬 불일치 — 받은 파일을 신뢰할 수 없습니다.`n  기대: $expect`n  실제: $actual`n네트워크 손상 또는 변조 가능성."
  }
  Info "체크섬 일치 ($expect)"

  # 9) wsl --import (별도 배포판). 최신 WSL 은 gzip tar 직접 import; 실패 시 .tar 폴백.
  Info "WSL 배포판 import: $DistroName → $InstallPath"
  & wsl.exe --import $DistroName $InstallPath $gz --version 2
  if ($LASTEXITCODE -ne 0) {
    Warn "gzip tar 직접 import 실패(구 WSL 가능) — .tar 로 풀어 재시도합니다."
    $tar = Join-Path $work 'cockpit-wsl.tar'
    Expand-GzipToTar $gz $tar
    & wsl.exe --import $DistroName $InstallPath $tar --version 2
    if ($LASTEXITCODE -ne 0) { Die "wsl --import 실패(코드 $LASTEXITCODE). wsl --update 후 재시도하세요." }
  }
}
finally {
  Remove-Item $work -Recurse -Force -ErrorAction SilentlyContinue
}

# ── 10) 원터치 런처(.cmd + 시작메뉴/바탕화면 바로가기) ─────────────────────
# 비개발자가 매번 명령을 치지 않도록: 더블클릭 한 번 = claude 실행. 래퍼(.cmd)가 wsl/배포판을
# 호출하고, 시작메뉴(주)·바탕화면(보조) 바로가기가 그 .cmd 를 가리킨다.
function New-CockpitLauncher {
  param([string]$Distro)
  $cockpitDir = Join-Path $env:LOCALAPPDATA 'Cockpit'
  if (-not (Test-Path $cockpitDir)) { New-Item -ItemType Directory -Path $cockpitDir -Force | Out-Null }
  $cmdPath = Join-Path $cockpitDir 'Launch-Cockpit.cmd'

  # 래퍼 .cmd: ① wsl.exe 경로 확정(32비트 부모 대비 Sysnative 폴백) ② **현재 콘솔에서 직접 실행** →
  #   종료코드를 .cmd 가 받아 실패 시 창 유지(pause). 비개발자가 실패 원인을 본다.
  #   (옛 wt.exe detached 분기는 즉시 exit0 라 WSL/claude 실패를 숨겨 제거 — 발견3. Win11 은 기본
  #    터미널이 WT 라 자동 호스팅, Win10 은 conhost; 어느 쪽이든 pause 동작.) launch.sh 가 claude 종료 처리.
  #   배포판명은 **따옴표 없이**(라이브 실측 2026-07-02: cmd.exe 경유 시 이 PC들의 wsl.exe 가
  #   -d "이름" 의 따옴표를 벗기지 않고 이름의 일부로 취급 → WSL_E_DISTRO_NOT_FOUND. PowerShell 은
  #   따옴표를 미리 벗겨 재현 안 됨. 이름은 ^cc-[A-Za-z0-9._-]+$ 검증(공백 불가)이라 무인용이 안전).
  #   실패 가드도 `if errorlevel 1` 이 아니라 %errorlevel% neq 0 — wsl.exe 는 이런 오류에 **음수(-1)**
  #   종료코드를 내는데 errorlevel 1 은 음수를 못 잡아 창이 소리 없이 닫혔다(라이브 실측).
  $launch = '~/.cockpit/launch.sh'
  $cmdLines = @(
    '@echo off',
    'title Claude (cockpit)',
    'setlocal',
    'set "WSL=wsl.exe"',
    'where %WSL% >nul 2>nul || set "WSL=%WINDIR%\Sysnative\wsl.exe"',
    ('%WSL% -d ' + $Distro + ' bash -lc "' + $launch + '"'),
    'if %errorlevel% neq 0 (',
    '  echo(',
    '  echo [cockpit] Launch failed - check WSL/distro state:  wsl -l -v',
    '  pause',
    ')',
    'endlocal'
  )
  # cmd 파서는 ANSI/OEM 기대 → ASCII 로 기록(위 한글 echo 는 콘솔 코드페이지 의존, 비핵심).
  Set-Content -Path $cmdPath -Value $cmdLines -Encoding Ascii
  Info "런처 생성: $cmdPath"

  # 바로가기(.lnk) — 아이콘은 wsl.exe(추후 cockpit 로고로 교체).
  $iconPath = Join-Path $env:SystemRoot 'System32\wsl.exe'
  $made = @()
  try {
    $ws = New-Object -ComObject WScript.Shell
    $targets = @(
      (Join-Path ([Environment]::GetFolderPath('Programs')) 'Claude (cockpit).lnk'),   # 시작메뉴(주)
      (Join-Path ([Environment]::GetFolderPath('Desktop'))  'Claude (cockpit).lnk')    # 바탕화면(보조)
    )
    foreach ($t in $targets) {
      $sc = $ws.CreateShortcut($t)
      $sc.TargetPath       = $cmdPath
      $sc.WorkingDirectory = $cockpitDir
      $sc.IconLocation     = "$iconPath,0"
      $sc.Description       = 'Claude Code (cockpit)'
      $sc.Save()
      $made += $t
    }
  } catch {
    Warn "바로가기 생성 일부 실패(.cmd 는 생성됨): $($_.Exception.Message)"
  }
  foreach ($m in $made) { Info "바로가기 생성: $m" }
  return $cmdPath
}

# ── 11) 안내 ──────────────────────────────────────────────────────────────
Info "설치 완료 ✓  배포판 '$DistroName' 이 준비됐습니다(편의 설정 사전적용)."

$LauncherCmd = $null
if (-not $NoLauncher) {
  try { $LauncherCmd = New-CockpitLauncher -Distro $DistroName }
  catch { Warn "런처 생성 실패(수동 진입 가능): $($_.Exception.Message)" }
}

Write-Host ""
Write-Host "다음 단계:" -ForegroundColor Green
if ($LauncherCmd) {
  Write-Host "  • 바탕화면/시작메뉴의 'Claude (cockpit)' 더블클릭 → claude 가 바로 실행됩니다."
} else {
  Write-Host "  • 진입:  wsl -d $DistroName"
}
Write-Host "  1) claude 로그인(최초 1회, 브라우저 OAuth): 실행 후 /login"
Write-Host "  2) 로그인 후 claude 재시작 → claude.ai/code 원격조종 활성(최초 실행은 미로그인이라 원격이 조용히 꺼져 있음)."
Write-Host "  3) 홈의 README-first-run.txt 를 따르세요 — 플러그인 단계는 이미지가 정확히 안내합니다"
Write-Host "     (v0.1.2+ 사전설치 이미지는 /cockpit-setup 하나, 구 이미지는 /plugin marketplace add $MarketplaceUrl 부터)."
Write-Host ""
Write-Host "통째 삭제(되돌리기):  wsl --unregister $DistroName   # 다른 배포판은 안 건드림" -ForegroundColor Cyan
Write-Host ""

if (-not $SkipLaunch) {
  Info "배포판 진입(홈의 README-first-run.txt 참고). 나가려면 'exit'."
  & wsl.exe -d $DistroName
}
