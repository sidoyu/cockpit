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
    • 편의 설정(bypass·effort·model·원격조종·trust)은 이미지에 사전적용 출고. **외부 송신(egress) 동의**는
      OFF — 첫 실행 /cockpit-setup 동의 한 화면 또는 설치 폼에서만 켜진다.
    • 세션 대시보드 뷰어는 기본 부속으로 자동 설치(설치≠기동 — 자동시작·포트 개방 없음, 켜기는 아이콘).
      설치 실패(오프라인·프록시)는 비치명 — 설치는 계속되고 완료화면/도우미가 재시도를 안내한다.

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
.PARAMETER NoOnboardingGui 설치 말미 온보딩 폼(기억 자동추출·API 키 입력)을 생략.
                          생략/무인 시 안전 기본값(추출 OFF) — 첫 실행 /cockpit-setup 에서 동일 설정 가능.
                          세션 대시보드는 폼과 무관하게 항상 설치 시도(필수 부속·설치≠기동).
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
  [switch]$NoOnboardingGui,
  [switch]$AllowUnpinnedImage,
  [switch]$AllowCustomDistroName
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# ── 게시 시 치환되는 핀 고정값(빌드/릴리스 파이프라인이 채움) ──────────────
$PinnedImageUrl = 'https://github.com/sidoyu/cockpit/releases/download/v0.1.11/cockpit-wsl.tar.gz'
$PinnedSha256   = '59c1a6437538f1da5ad3ba03d38f49dfab50e91a583f3fa6f0d2af09dad1be66'   # cockpit-wsl.tar.gz SHA-256 (golden-build 산출).
$MarketplaceUrl = 'https://github.com/sidoyu/cockpit'                                  # /plugin marketplace add 실주소(게시자 sidoyu·cc-companion).
$PinnedDashboardCmdUrl    = 'https://github.com/sidoyu/cockpit/releases/download/v0.1.11/Cockpit-Dashboard.cmd'
$PinnedDashboardCmdSha256 = '052176622c5ff9b6dac766da9658530afdc9134b7f5a7ff321cfab3be99b9b39'   # Cockpit-Dashboard.cmd SHA-256 (repo 파일 그대로 자산 업로드 — publish-gate §1d 가 재핀 강제).
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

# ── 9.5) 온보딩 폼(v0.1.8) — 설치 말미 선택 옵션 + API 키 입력 ──────────────
# 설계 = docs/design-v0.1.8.md. 실패 전부 fail-open(Warn + 첫 실행 /cockpit-setup 폴백) —
# import 가 성공한 설치를 온보딩 문제로 중단하지 않는다. 상태 기록(installer-onboarding.json)은
# '동의 체크 + [적용]' 제출시에만(wsl 안 narrow subcommand) — 건너뛰기/창닫기/무인은 미기록 →
# 첫 실행 /cockpit-setup 이 기존대로 전체 질문(안전 방향 수렴).
# 키 전달 = wsl 표준입력 리다이렉트만: argv·env·임시파일·로그 미경유, -u 미지정(기본 사용자).

function Test-OnboardingGuiBlocked {
  # 폼을 띄우면 안 되는 이유 문자열 반환(없으면 $null) — Install.cmd < NUL·CI·원격 등 비대화 감지.
  if ($NoOnboardingGui) { return '-NoOnboardingGui 지정' }
  try { if ([Console]::IsInputRedirected) { return '표준입력 리다이렉트(무인 실행)' } } catch {}
  if (-not [Environment]::UserInteractive) { return '비대화 세션' }
  if ($env:CI) { return 'CI 환경 감지' }
  if ([System.Threading.Thread]::CurrentThread.ApartmentState -ne 'STA') {
    return '비-STA 스레드(WinForms 불가 — Install.cmd 경유 실행은 -STA 자동)'
  }
  try {
    Add-Type -AssemblyName System.Windows.Forms -ErrorAction Stop
    Add-Type -AssemblyName System.Drawing -ErrorAction Stop
  } catch { return "WinForms 로드 실패: $($_.Exception.Message)" }
  return $null
}

function Show-OnboardingForm {
  # 반환: $null = 건너뛰기/창닫기(아무것도 적용·기록하지 않음) / 해시테이블 = 동의 체크 후 [적용].
  # 고지 문구는 마법사 SKILL §0/§3.5/§3.7 베이크분과 동일 수준 유지(동의 질) — bypass 사전적용과
  # 옵션 1 외부송신은 별줄로 분리 표기.
  # $BackupScan(해시테이블 @{Count;Date;Dir;WinPath;OtherUser} 또는 $null): 이 PC 에서 이전 백업이
  #   발견됐을 때만 #3 복원 GroupBox 를 노출한다(없으면 폼은 v0.1.9 와 픽셀 동일 — 공통 경로 무영향).
  param([hashtable]$BackupScan)
  $hasBackup = [bool]$BackupScan
  $rDelta = 0; if ($hasBackup) { $rDelta = 114 }  # 복원 박스(경로+설명, 타프로필 경고 포함 3줄) 높이만큼 하단 밀어냄
  $iDelta = 84    # #2 CLAUDE.md 개인화 GroupBox(역할 1칸만·정적 높이). 옛 3값(기기·토폴로지/경로약칭)은
                  #   저리터러시 사용자에게 불친절 → 폼에서 제거하고 '역할'만 남김(동윤 결정 2026-07-08).
  $restoreChk = $null; $restoreBox = $null        # StrictMode: 미발견 경로에서도 초기화 보장
  $form = New-Object System.Windows.Forms.Form
  $form.Text = 'cockpit 추가 설정'
  $form.FormBorderStyle = 'FixedDialog'
  $form.MaximizeBox = $false; $form.MinimizeBox = $false
  $form.StartPosition = 'CenterScreen'
  $form.ClientSize = New-Object System.Drawing.Size(600, (545 + $rDelta + $iDelta))
  $form.Font = New-Object System.Drawing.Font('Segoe UI', 9)
  $form.TopMost = $true   # 콘솔 뒤에 숨어 '설치가 멈췄다'로 오인되는 것 방지

  $title = New-Object System.Windows.Forms.Label
  $title.Text = '소프트웨어 설치처럼 선택하세요. 지금 건너뛰어도 첫 실행 후 /cockpit-setup 에서 같은 설정이 가능합니다.'
  $title.Location = New-Object System.Drawing.Point(12, 10)
  $title.Size = New-Object System.Drawing.Size(576, 34)
  $form.Controls.Add($title)

  # ① 거버넌스 요지 + 필수 동의(미체크 = 아래 전부 + [적용] 비활성 — 제출 경로는 '체크 후 적용' 유일)
  $govBox = New-Object System.Windows.Forms.GroupBox
  $govBox.Text = '사용 조건 (필수 확인)'
  $govBox.Location = New-Object System.Drawing.Point(12, 48)
  $govBox.Size = New-Object System.Drawing.Size(576, 152)
  $govText = New-Object System.Windows.Forms.Label
  $govText.Text = "- 개인 PC / 비업무 / 비민감 데이터 전용 - 환자정보·개인정보(PII)·기밀 입력 금지`n" +
                  "- 권한 확인 생략(bypass)이 사전적용된 환경 - AI 가 확인 팝업 없이 명령을 실행할 수 있음`n" +
                  "- 아래 옵션 1(기억 보강)을 켜면 세션 종료 시 대화 내용이 Anthropic API 로 외부 송신됨`n" +
                  "- 끄는 법/지우는 법은 설치 후 /cockpit-setup 안내 참조 - 사용의 최종 책임은 본인에게 있음"
  $govText.Location = New-Object System.Drawing.Point(10, 22)
  $govText.Size = New-Object System.Drawing.Size(556, 94)
  $govBox.Controls.Add($govText)
  $govChk = New-Object System.Windows.Forms.CheckBox
  $govChk.Text = '위 내용을 읽고 이해했으며 동의합니다'
  $govChk.Location = New-Object System.Drawing.Point(10, 120)
  $govChk.Size = New-Object System.Drawing.Size(556, 24)
  $govBox.Controls.Add($govChk)
  $form.Controls.Add($govBox)

  # ② 기억 자동추출 옵션 1/2 (기본 = 옵션 2·키 없이)
  $memBox = New-Object System.Windows.Forms.GroupBox
  $memBox.Text = '기억 자동추출'
  $memBox.Location = New-Object System.Drawing.Point(12, 208)
  $memBox.Size = New-Object System.Drawing.Size(576, 236)
  $memBox.Enabled = $false
  $optKey = New-Object System.Windows.Forms.RadioButton
  $optKey.Text = '옵션 1. API 키 입력하고 기억능력 보강하기'
  $optKey.Location = New-Object System.Drawing.Point(10, 22)
  $optKey.Size = New-Object System.Drawing.Size(556, 22)
  $memBox.Controls.Add($optKey)
  # #10 — console.anthropic.com 을 클릭 가능한 LinkLabel 로(LinkClicked → 기본 브라우저).
  # 링크 영역은 런타임 IndexOf 로 계산(하드코딩 인덱스 취약성 회피). 접두 텍스트는 그대로.
  $optKeyNote = New-Object System.Windows.Forms.LinkLabel
  $optKeyNote.Text = "세션이 끝날 때마다 대화를 자동 분석해 기억 후보를 쌓습니다. 본인 Anthropic API 키 필요`n" +
                     "(Claude 구독과 별개 과금) - 세션 1회 최대 약 50원, 보통 10원 안팎. 콘솔에서 사용량 한도`n" +
                     "(spend limit) 설정 권장. 발급: console.anthropic.com > API Keys > Create Key > Billing 등록."
  $optKeyNote.Location = New-Object System.Drawing.Point(28, 46)
  $optKeyNote.Size = New-Object System.Drawing.Size(538, 56)
  $optKeyNote.LinkArea = New-Object System.Windows.Forms.LinkArea(0, 0)   # 기본 링크 없음(아래서 영역 지정)
  $__linkTxt = 'console.anthropic.com'
  $__linkIdx = $optKeyNote.Text.IndexOf($__linkTxt)
  if ($__linkIdx -ge 0) {
    $optKeyNote.LinkArea = New-Object System.Windows.Forms.LinkArea($__linkIdx, $__linkTxt.Length)
  }
  $optKeyNote.add_LinkClicked({
    try { Start-Process 'https://console.anthropic.com/settings/keys' } catch {}
  })
  $memBox.Controls.Add($optKeyNote)
  $keyLabel = New-Object System.Windows.Forms.Label
  $keyLabel.Text = 'Anthropic API 키(sk-ant-...):'
  $keyLabel.Location = New-Object System.Drawing.Point(28, 108)
  $keyLabel.Size = New-Object System.Drawing.Size(180, 20)
  $memBox.Controls.Add($keyLabel)
  $keyBox = New-Object System.Windows.Forms.TextBox
  $keyBox.UseSystemPasswordChar = $true   # 마스킹 입력 — 키 원문은 화면·로그 미표시
  $keyBox.Location = New-Object System.Drawing.Point(210, 105)
  $keyBox.Size = New-Object System.Drawing.Size(350, 24)
  $keyBox.Enabled = $false
  $memBox.Controls.Add($keyBox)
  $keyErr = New-Object System.Windows.Forms.Label
  $keyErr.Text = '키 형식이 sk-ant- 로 시작하지 않습니다 - 다시 확인하세요(비표준 키는 /cockpit-setup 에서만).'
  $keyErr.ForeColor = [System.Drawing.Color]::Firebrick
  $keyErr.Location = New-Object System.Drawing.Point(28, 132)
  $keyErr.Size = New-Object System.Drawing.Size(538, 18)
  $keyErr.Visible = $false
  $memBox.Controls.Add($keyErr)
  $optNoKey = New-Object System.Windows.Forms.RadioButton
  $optNoKey.Text = '옵션 2. API 키 없이 사용하기 (기본)'
  $optNoKey.Location = New-Object System.Drawing.Point(10, 156)
  $optNoKey.Size = New-Object System.Drawing.Size(556, 22)
  $optNoKey.Checked = $true
  $memBox.Controls.Add($optNoKey)
  $optNoKeyNote = New-Object System.Windows.Forms.Label
  $optNoKeyNote.Text = "기억 시스템은 전부 정상 동작하고, '세션 끝나고 자동으로 훑어주는' 부분만 꺼집니다.`n조건·비용 없음 - 이 기능 목적의 추가 외부 송신 없음. 나중에 /cockpit-setup 에서 켤 수 있습니다."
  $optNoKeyNote.Location = New-Object System.Drawing.Point(28, 180)
  $optNoKeyNote.Size = New-Object System.Drawing.Size(538, 40)
  $memBox.Controls.Add($optNoKeyNote)
  $form.Controls.Add($memBox)

  # ②-b 이전 백업 복원(#3 — 이 PC 에서 백업을 발견했을 때만 노출·기본 언체크·거버넌스 동의로 활성).
  #   복원은 사용자 본인의 옛 기억을 되살릴 뿐 외부송신 아님. 이번 설치의 동의·키는 그대로 유지된다
  #   (§9.5 에서 복원→온보딩 apply 순서 = 새 값이 복원값 위에 얹힘·§5.4 #8 carry-forward).
  if ($hasBackup) {
    $restoreBox = New-Object System.Windows.Forms.GroupBox
    $restoreBox.Text = '이전 백업 복원 (선택)'
    $restoreBox.Location = New-Object System.Drawing.Point(12, 452)
    $restoreBox.Size = New-Object System.Drawing.Size(576, 102)
    $restoreBox.Enabled = $false
    # 발견 위치(Windows 경로)를 명시 노출 — 어느 백업을 되살리는지 사용자가 확인(Codex 발견1).
    # 레이아웃은 정적(3줄분): 타프로필 경고가 붙어도 오버플로 안 되게 항상 같은 높이.
    $restoreNote = New-Object System.Windows.Forms.Label
    $restoreNote.Text = ("발견: {0}  (최근 {1} · {2}건)`n복원하면 그때의 기억·CLAUDE.md 를 되살립니다. 이번 설치에서 고른 외부송신 동의·API 키 설정은 그대로 유지됩니다." -f $BackupScan['WinPath'], $BackupScan['Date'], $BackupScan['Count'])
    $restoreNote.Location = New-Object System.Drawing.Point(10, 16)
    $restoreNote.Size = New-Object System.Drawing.Size(556, 54)
    if ($BackupScan['OtherUser']) {
      # 현재 Windows 사용자 폴더의 백업이 아님 — 공유 PC/타 프로필 오복원 방지 경고(붉게).
      $restoreNote.ForeColor = [System.Drawing.Color]::Firebrick
      $restoreNote.Text = "⚠ 이 백업은 현재 Windows 사용자 폴더의 것이 아닙니다 — 본인 백업이 맞는지 위 경로를 확인하세요.`n" + $restoreNote.Text
    }
    $restoreBox.Controls.Add($restoreNote)
    $restoreChk = New-Object System.Windows.Forms.CheckBox
    $restoreChk.Text = '발견한 백업에서 기억 복원하기 (권장 — 기존 사용자 재설치 시)'
    $restoreChk.Location = New-Object System.Drawing.Point(10, 72)
    $restoreChk.Size = New-Object System.Drawing.Size(556, 22)
    $restoreBox.Controls.Add($restoreChk)
    $form.Controls.Add($restoreBox)
  }

  # ②-c CLAUDE.md 개인화 '역할'(#2 — 선택·비우면 스킵→마법사). 거버넌스 동의로 활성(다른 박스와 동일).
  #   베이크된 ~/.claude/CLAUDE.md 의 {{USER_ROLE}} 만 치환한다(setup.py set-claude-identity·§5.3).
  #   옛 기기·토폴로지/경로약칭 2칸은 내부용어라 저리터러시 사용자에게 불친절 → 폼에서 제거(동윤 결정
  #   2026-07-08). 이 칸은 개인정보·시크릿 금지(템플릿 L5) — note 가 1차, setup.py 가 키·IP·이메일·
  #   {{토큰}}·여러줄·과길이를 방어적 2차로 거른다(완벽 PII 탐지는 아님). 값은 argv 로 전달(키가 아님).
  $idBox = New-Object System.Windows.Forms.GroupBox
  $idBox.Text = 'CLAUDE.md 개인화 (선택)'
  $idBox.Location = New-Object System.Drawing.Point(12, (452 + $rDelta))
  $idBox.Size = New-Object System.Drawing.Size(576, 76)
  $idBox.Enabled = $false
  $idNote = New-Object System.Windows.Forms.Label
  $idNote.Text = 'Claude 가 매번 참고할 나의 역할 한 줄(예: 병원 행정직). 잘 모르면 비워도 됩니다 — 나중에 /cockpit-setup. 개인정보·시크릿·IP·계정 금지.'
  $idNote.Location = New-Object System.Drawing.Point(10, 18)
  $idNote.Size = New-Object System.Drawing.Size(556, 18)
  $idBox.Controls.Add($idNote)
  $roleLabel = New-Object System.Windows.Forms.Label
  $roleLabel.Text = '역할:'
  $roleLabel.Location = New-Object System.Drawing.Point(10, 44)
  $roleLabel.Size = New-Object System.Drawing.Size(110, 20)
  $idBox.Controls.Add($roleLabel)
  $roleBox = New-Object System.Windows.Forms.TextBox
  $roleBox.Location = New-Object System.Drawing.Point(124, 41)
  $roleBox.Size = New-Object System.Drawing.Size(442, 24)
  $roleBox.MaxLength = 120
  $idBox.Controls.Add($roleBox)
  $form.Controls.Add($idBox)

  # ③ 세션 대시보드 안내(선택 아님 — 필수설치화·§9.4. 폼 옵트인 제거·설치≠기동 명시만).
  $dashInfo = New-Object System.Windows.Forms.Label
  $dashInfo.Text = "세션 열람 대시보드는 기본 부속으로 자동 설치됩니다(설치≠기동 — 자동시작·포트 개방 없음, " +
                   "켜기 = 바탕화면 'Cockpit Dashboard' 아이콘·창 닫으면 꺼짐). 공유 PC·화면공유 중이면 켜지 마세요."
  $dashInfo.Location = New-Object System.Drawing.Point(12, (452 + $rDelta + $iDelta))
  $dashInfo.Size = New-Object System.Drawing.Size(576, 40)
  $form.Controls.Add($dashInfo)

  $btnApply = New-Object System.Windows.Forms.Button
  $btnApply.Text = '적용하고 계속'
  $btnApply.Location = New-Object System.Drawing.Point(160, (500 + $rDelta + $iDelta))
  $btnApply.Size = New-Object System.Drawing.Size(180, 32)
  $btnApply.Enabled = $false
  $form.Controls.Add($btnApply)
  $btnSkip = New-Object System.Windows.Forms.Button
  $btnSkip.Text = '건너뛰기 (나중에 /cockpit-setup)'
  $btnSkip.Location = New-Object System.Drawing.Point(356, (500 + $rDelta + $iDelta))
  $btnSkip.Size = New-Object System.Drawing.Size(220, 32)
  $form.Controls.Add($btnSkip)
  $form.CancelButton = $btnSkip

  $govChk.add_CheckedChanged({
    $memBox.Enabled = $govChk.Checked
    $btnApply.Enabled = $govChk.Checked
    if ($restoreBox) { $restoreBox.Enabled = $govChk.Checked }
    $idBox.Enabled = $govChk.Checked
  })
  $optKey.add_CheckedChanged({
    $keyBox.Enabled = $optKey.Checked
    if (-not $optKey.Checked) { $keyErr.Visible = $false }
  })
  $btnApply.add_Click({
    if ($optKey.Checked -and -not $keyBox.Text.Trim().StartsWith('sk-ant-')) {
      $keyErr.Visible = $true
      return
    }
    $form.DialogResult = [System.Windows.Forms.DialogResult]::OK
    $form.Close()
  })
  $btnSkip.add_Click({
    $form.DialogResult = [System.Windows.Forms.DialogResult]::Cancel
    $form.Close()
  })

  $dr = $form.ShowDialog()
  $result = $null
  if ($dr -eq [System.Windows.Forms.DialogResult]::OK) {
    # 대시보드는 폼 선택 대상 아님(§9.4 필수설치) — 결과에 Dashboard 키 없음(D3·apply 는 §9.4 실측값 사용).
    # Restore/RestoreDir·ClaudeRole 키는 항상 포함(StrictMode — 호출부가 무조건 참조 가능).
    # ClaudeRole 은 폼에서 비어있으면 빈 문자열 — 호출부(§9.5)가 비면 set-claude-identity 를 호출조차 안 한다.
    $result = @{ Egress = $optKey.Checked; Key = $null; Restore = $false; RestoreDir = $null;
                 ClaudeRole = $roleBox.Text.Trim() }
    if ($optKey.Checked) { $result.Key = $keyBox.Text.Trim() }
    if ($hasBackup -and $restoreChk.Checked) { $result.Restore = $true; $result.RestoreDir = $BackupScan['Dir'] }
  }
  $keyBox.Text = ''   # best-effort 소거(컨트롤 잔존 제거 — .NET string 불변성 한계는 인지)
  $form.Dispose()
  return $result
}

function Invoke-OnboardKeyInject {
  # 키 원문은 wsl 표준입력 한 줄로만 이동. argv·env·임시파일 미경유(아래 Arguments 행에
  # 키 변수 결합 금지 — publish-gate §1f 가 정적 차단). 출력·예외에 키 원문 미기록.
  param([string]$DistroName, [string]$Key)
  $psi = New-Object System.Diagnostics.ProcessStartInfo
  $psi.FileName = 'wsl.exe'
  $psi.UseShellExecute = $false
  $psi.RedirectStandardInput = $true
  $psi.Arguments = '-d ' + $DistroName + ' -- /usr/local/bin/cockpit-onboard setup set-extraction-key'
  $proc = [System.Diagnostics.Process]::Start($psi)
  # LF 명시(WriteLine=CRLF → WSL 쪽에 \r 잔존, 실측 2026-07-06). 수신측 strip 에 의존하지 않는다.
  $proc.StandardInput.Write($Key + "`n")
  $proc.StandardInput.Close()
  if (-not $proc.WaitForExit(60000)) {
    try { $proc.Kill() } catch {}
    $Key = $null
    return 124
  }
  $Key = $null   # best-effort 소거
  return $proc.ExitCode
}

function Invoke-OnboardApply {
  # 적용 순서 = 키 → 상태 기록(마지막 1회) — 상태 기록 실패 시 파일이 안 남고,
  # 파일이 없으면 마법사가 전체 질문으로 폴백(안전 방향). 각 단계 실패는 Warn 후 계속.
  # 대시보드는 §9.4(폼 밖·모든 경로)에서 이미 시도됨(D2·D3) — 여기선 그 실측 결과만 state 에
  # 기록한다(폼 조건부 설치 블록 제거·publish-gate §sec 강제). $DashboardStatus = installed|failed.
  param([string]$DistroName, [hashtable]$Choice, [string]$DashboardStatus)
  $keyReg = 'no'
  if ($Choice.Egress -and $Choice.Key) {
    $rc = Invoke-OnboardKeyInject -DistroName $DistroName -Key $Choice.Key
    $Choice.Key = $null   # best-effort 소거(이후 단계는 키 원문 불필요)
    if ($rc -eq 0) {
      $keyReg = 'yes'
      Info '추출용 API 키 등록 완료(0600 키 파일 — 원문은 화면·로그에 표시되지 않음).'
    } else {
      Warn "키 등록 실패(코드 $rc) — 키 등록 전까지 자동추출은 동작하지 않습니다(no-op). 첫 실행 /cockpit-setup 3.6 단계에서 재등록하세요."
    }
  }
  $dash = if ($DashboardStatus) { $DashboardStatus } else { 'failed' }
  $egress = 'off'; if ($Choice.Egress) { $egress = 'on' }
  & wsl.exe -d $DistroName -- /usr/local/bin/cockpit-onboard setup apply-installer-onboarding --governance-ack --memory-egress $egress --key-registered $keyReg --dashboard $dash --source installer
  # rc 구분(setup.py 계약): 2=state 기록 실패(파일 없음→마법사 전체 질문) / 1=state 성공·egress
  # 마커만 실패(마법사가 불일치 감지→해당 단계 재안내). 뭉뚱그리면 안내가 부정확(Codex 4f).
  if ($LASTEXITCODE -eq 1) {
    Warn "egress 마커 기록만 실패 — 자동추출은 꺼진 상태(안전). 첫 실행 /cockpit-setup 이 해당 단계만 재안내합니다."
  } elseif ($LASTEXITCODE -ne 0) {
    Warn "온보딩 상태 기록 실패(코드 $LASTEXITCODE) — 첫 실행 /cockpit-setup 이 전체 질문으로 진행합니다(안전)."
  }
}

function Get-BackupScan {
  # #3 — 이 PC 의 C:\ 관례 위치에서 이전 cockpit 백업을 탐지(읽기 전용·비파괴). backup.py --scan
  # --porcelain 이 ASCII 기계 출력을 내면 파싱한다. best-effort: 실패·무발견이면 $null(설치 비차단).
  #   porcelain 형식: CBK|<개수>|<epoch>|<YYYY-MM-DD>|<b64경로>  (구분자 '|' 는 base64/숫자/날짜에 없음)
  # 경로는 base64 라 공백·유니코드·드라이브문자도 무손상 왕복 → --restore --dir 로 그대로 되넘긴다.
  # ★ 후보 선택(Codex 발견1 — 공유 PC 안전): 스캔은 /mnt/*/Users/*/cockpit-backups 전 프로필을
  #   훑으므로 '최신 1개 자동선택'은 남의 백업을 복원할 위험이 있다. → **현재 Windows 사용자
  #   프로필 폴더의 백업을 우선** 고르고, 그게 없을 때만 최신 폴백 + OtherUser 플래그(폼이 경고+경로 노출).
  # 반환: @{ Count; Date; Dir; WinPath; OtherUser } | $null.
  # ⚠ hashtable 값 접근은 반드시 bracket(['키']) — dot .Count 는 키가 아니라 항목수를 돌려줌(발견2).
  param([string]$DistroName)
  $out = $null
  try { $out = & wsl.exe -d $DistroName -- /usr/local/bin/cockpit-onboard backup --scan --porcelain 2>&1 }
  catch { return $null }
  if (-not $out) { return $null }
  $rows = @()
  foreach ($line in @($out)) {
    if ([string]$line -match '^\s*CBK\|(\d+)\|(\d+)\|(\d{4}-\d{2}-\d{2})\|([A-Za-z0-9+/=]+)\s*$') {
      $dir = $null
      try { $dir = [System.Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($Matches[4])) } catch { continue }
      if (-not $dir) { continue }
      $rows += , @{ Count = [int]$Matches[1]; Epoch = [long]$Matches[2]; Date = $Matches[3]; Dir = $dir }
    }
  }
  if ($rows.Count -eq 0) { return $null }
  # 현재 Windows 사용자 프로필 폴더명(best-effort). WSL 백업 경로 …/Users/<폴더>/… 와 대조.
  $curUser = $null
  try { $curUser = Split-Path $env:USERPROFILE -Leaf } catch {}
  $pick = $null
  if ($curUser) {
    $needle = [regex]::Escape('/Users/' + $curUser + '/')
    foreach ($r in $rows) {
      if ($r['Dir'] -match $needle -and (-not $pick -or $r['Epoch'] -gt $pick['Epoch'])) { $pick = $r }
    }
  }
  $otherUser = $false
  if (-not $pick) {
    foreach ($r in $rows) { if (-not $pick -or $r['Epoch'] -gt $pick['Epoch']) { $pick = $r } }
    if ($curUser) { $otherUser = $true }   # 현재 사용자 백업이 아님 → 폼이 경고 표시
  }
  # /mnt/c/Users/X/cockpit-backups → C:\Users\X\cockpit-backups (표시 전용·복원엔 원 Dir 사용)
  $win = $pick['Dir']
  if ($pick['Dir'] -match '^/mnt/([a-zA-Z])/(.*)$') { $win = $Matches[1].ToUpper() + ':\' + ($Matches[2] -replace '/', '\') }
  return @{ Count = $pick['Count']; Date = $pick['Date']; Dir = $pick['Dir']; WinPath = $win; OtherUser = $otherUser }
}

function Invoke-OnboardRestore {
  # #3 — 폼에서 '복원' 선택 시: 발견한 백업에서 기억·상태 복원(WSL 브리지 재사용). best-effort·비치명.
  # ★ 호출 순서(§9.5): 복원 → 그다음 온보딩 apply(키·egress 마커). 복원이 STATE_DIR/MEMORY_DIR 를
  #   move-aside 후 옛 내용으로 교체하므로, 새로 넣을 API 키·동의를 복원 뒤에 얹어야 소실되지 않는다
  #   (§5.5 #12 '복원 직후 키 소실' 케이스 회피). backup.py 의 #8 carry-forward 는 상태 2파일을 지킨다.
  param([string]$DistroName, [string]$Dir)
  Info "이전 백업에서 기억 복원 중($Dir)…"
  $rc = -1
  try {
    & wsl.exe -d $DistroName -- /usr/local/bin/cockpit-onboard backup --restore --apply --dir $Dir 2>&1 | Out-Null
    $rc = $LASTEXITCODE
  } catch { $rc = -1 }
  if ($rc -eq 0) {
    Info '기억 복원 완료 — 복원된 내용은 다음 세션부터 반영됩니다(점검: /cockpit-setup 또는 doctor).'
  } else {
    Warn "기억 복원 실패(코드 $rc) — 설치는 정상. 나중에 /cockpit-setup 또는 'cockpit-onboard backup --restore --apply' 로 재시도하세요."
  }
}

function Invoke-OnboardClaudeIdentity {
  # #2 — 폼의 '역할'을 베이크된 ~/.claude/CLAUDE.md 의 {{USER_ROLE}} 플레이스홀더에 치환(narrow 진입점).
  # 빈 값이면 호출조차 안 함(§9.5 가드·setup.py 기본 ""=스킵). 옛 기기·토폴로지/경로약칭 인자는 폼 제거와
  # 함께 삭제(동윤 결정 2026-07-08) — setup.py 는 하위호환으로 --topology/--aliases 를 deprecated no-op 수용.
  # ★ 순서(§9.5): 복원 뒤 → 이 호출 → apply. 복원이 CLAUDE.md 를 옛 것으로 교체하면 그 위에 남은
  #   플레이스홀더만 새 값으로 채운다(이미 채워진 값은 setup.py 가 덮지 않음). best-effort·비치명.
  # 값은 키가 아니라 개인화 문구 → argv 전달. 시크릿/개인정보는 setup.py 가 거른다.
  param([string]$DistroName, [string]$Role)
  if (-not $Role) { return }
  $idArgs = @('-d', $DistroName, '--', '/usr/local/bin/cockpit-onboard', 'setup', 'set-claude-identity', '--role', $Role)
  & wsl.exe @idArgs
  if ($LASTEXITCODE -ne 0) {
    Warn "CLAUDE.md 개인화 반영 실패(코드 $LASTEXITCODE) — 설치는 정상. 첫 실행 /cockpit-setup 에서 채우세요."
  } else {
    Info 'CLAUDE.md 개인화 값 반영 완료(입력한 항목만·빈 칸은 마법사에서 채움).'
  }
}

function Get-DashboardFailHint {
  # INSTALL_VIEWER_FAIL 토큰 → 완료화면용 한국어 원인 추정(단일 지점 매핑·§4.1).
  param([string]$Class)
  switch ($Class) {
    'github-blocked' { return 'GitHub 접근 차단(회사망/방화벽)' }
    'proxy'          { return '프록시 인증/구성' }
    'tls'            { return 'TLS/인증서 검사(보안 제품)' }
    'network'        { return '네트워크 연결(오프라인/DNS/타임아웃)' }
    default          { return '네트워크 또는 GitHub 접근 문제' }
  }
}

function Invoke-DashboardInstall {
  # #1·#15 — 세션 대시보드 필수설치(폼 밖·모든 경로 공통·D2·D3). best-effort·비치명(fail-open).
  # 설치≠기동(D1): install-viewer.sh 는 자동시작·포트 LISTEN 을 하지 않는다(설치만).
  # 반환: @{ Status='installed'|'failed'; Class; Code }. 실패 시 대화형 완료화면 블록은 §11 이
  # 이 반환값으로 출력하고, 무인은 여기서 warn 1줄만(화면 없음). 전 경로 exit 0.
  param([string]$DistroName, [string]$OnboardingBlocked)

  Info '세션 대시보드 설치(필수 부속·네트워크 필요·설치≠기동)…'
  $out = $null
  $rc = -1   # 기본=실패. wsl.exe 가 던지면(미발견 등) stale $LASTEXITCODE(0) 오판 방지.
  try {
    $out = & wsl.exe -d $DistroName -- /usr/local/bin/cockpit-onboard install-dashboard 2>&1
    $rc = $LASTEXITCODE
  } catch {
    $out = $_.Exception.Message
    $rc = -1
  }
  if ($rc -eq 0) {
    Info "세션 대시보드 설치됨(설치≠기동 — 켜기는 바탕화면 'Cockpit Dashboard' 아이콘)."
    return @{ Status = 'installed'; Class = $null; Code = 0 }
  }

  # 실패 분류: install-viewer.sh 가 마지막 줄에 INSTALL_VIEWER_FAIL=<class> emit(trap 폴백=unknown).
  # 토큰 부재 시 unknown 강제(이중 안전). ASCII 토큰이라 wsl 출력 인코딩과 무관.
  $class = 'unknown'
  foreach ($line in @($out)) {
    if ([string]$line -match 'INSTALL_VIEWER_FAIL=([a-z-]+)') { $class = $Matches[1] }
  }
  if ($OnboardingBlocked) {
    # 무인/비대화 — 완료화면 강조 불가(화면 없음) → warn 1줄. #17 cmd·#18 doctor 가 나중 시점 노출.
    Warn "세션 대시보드 설치 실패(코드 $rc·$class) — 비치명. 인터넷 되는 곳에서 바탕화면 'Cockpit Dashboard' 아이콘 재실행 또는 /cockpit-setup 으로 재시도."
  }
  return @{ Status = 'failed'; Class = $class; Code = $rc }
}

# ── 9.3) 온보딩 GUI 가능 여부 "계산만"(폼 show/skip 실행은 §9.5) ─────────────
# $OnboardingBlocked 를 여기서 먼저 계산한다 — §9.4 실패 UX 가 대화형/무인 분기에 이 값을 쓰기
# 때문(Codex GAP3). 계산과 폼 실행 분리: 계산=§9.3, 폼 show/skip=§9.5.
$OnboardingBlocked = $null
try { $OnboardingBlocked = Test-OnboardingGuiBlocked } catch { $OnboardingBlocked = "감지 실패: $($_.Exception.Message)" }

# ── 9.4) 세션 대시보드 필수설치(#1·#15) — 폼 밖·모든 경로 공통(D2·D3·fail-open) ──
# 온보딩 폼(§9.5)의 show/skip 과 무관하게 모든 경로에서 시도(비대화·건너뜀·미동의 포함).
# 실패해도 설치는 계속(비치명·#16). 대시보드 결과는 state 를 강제 생성하지 않는다(D3 — §9.5 폼
# 제출 경로에서만 실측값을 apply 에 전달).
$DashboardResult = @{ Status = 'failed'; Class = 'unknown'; Code = -1 }
try { $DashboardResult = Invoke-DashboardInstall -DistroName $DistroName -OnboardingBlocked $OnboardingBlocked }
catch { Warn "대시보드 설치 처리 오류(설치는 정상): $($_.Exception.Message) — 첫 실행 /cockpit-setup 에서 재시도." }

# ── 9.4b) 이전 백업 스캔(#3) — 모든 경로 공통(읽기 전용·비파괴). 복원 실행은 대화형 동의 시에만(§9.5) ──
# 재설치 사용자면 #9 Uninstall 이 C:\ 관례 위치에 자동백업을 남겼을 수 있다. 발견 시 온보딩 폼이
# 복원 체크박스를 노출한다(무발견=폼 무변화). 무인/비대화는 동의 화면이 없어 복원하지 않는다(안전).
$BackupScan = $null
try { $BackupScan = Get-BackupScan -DistroName $DistroName }
catch { $BackupScan = $null }
if ($BackupScan) { Info "이전 cockpit 백업 발견($($BackupScan['Date']) · $($BackupScan['Count'])건 · $($BackupScan['WinPath'])) — 온보딩 화면에서 복원 여부를 고를 수 있습니다." }

# ── 9.5) 온보딩 폼(v0.1.8 흐름 유지·대시보드 GroupBox 제거) — $OnboardingBlocked 로 분기 ──
if ($OnboardingBlocked) {
  Info "온보딩 화면 생략($OnboardingBlocked) — 안전 기본값(자동추출 OFF). 대시보드는 위에서 이미 시도됨. 첫 실행 /cockpit-setup 에서 동일 설정 가능."
  if ($BackupScan) { Info "이전 백업($($BackupScan['Date']) · $($BackupScan['WinPath']))은 자동 복원하지 않습니다(무인·동의 없음) — 첫 실행 /cockpit-setup 또는 'cockpit-onboard backup --restore --apply' 로 복원하세요." }
} else {
  Info '온보딩 화면 표시(선택 옵션·API 키) — 창에서 선택을 마치면 설치가 이어집니다.'
  try {
    $OnboardingChoice = Show-OnboardingForm -BackupScan $BackupScan
    if ($OnboardingChoice) {
      # ★ 순서: 복원 먼저 → 그다음 apply(키·egress). 복원이 옛 기억으로 교체한 위에 이번 설치의
      #   새 동의·키를 얹어야 소실되지 않는다(§5.5 #12·Invoke-OnboardRestore 주석).
      if ($OnboardingChoice.Restore) {
        try { Invoke-OnboardRestore -DistroName $DistroName -Dir $OnboardingChoice.RestoreDir }
        catch { Warn "복원 처리 오류(설치는 정상): $($_.Exception.Message) — 첫 실행 /cockpit-setup 에서 재시도하세요." }
      }
      # #2 — CLAUDE.md 3값 개인화: 복원 뒤(남은 플레이스홀더에 새 값)·apply 전. best-effort·비치명.
      try { Invoke-OnboardClaudeIdentity -DistroName $DistroName -Role $OnboardingChoice.ClaudeRole }
      catch { Warn "CLAUDE.md 개인화 처리 오류(설치는 정상): $($_.Exception.Message) — 첫 실행 /cockpit-setup 에서 채우세요." }
      Invoke-OnboardApply -DistroName $DistroName -Choice $OnboardingChoice -DashboardStatus $DashboardResult.Status
    }
    else { Info '온보딩 건너뜀 — 첫 실행 /cockpit-setup 에서 같은 설정을 안내합니다.' }
    $OnboardingChoice = $null   # best-effort 소거(키 원문 참조 해제)
  } catch {
    Warn "온보딩 처리 오류(설치는 정상): $($_.Exception.Message) — 첫 실행 /cockpit-setup 에서 설정하세요."
  }
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

# ── 10b) 대시보드 바탕화면 아이콘(기본 부속 · 실패해도 설치는 계속) ─────────
# 더블클릭 = 대시보드 창 열림, 창 닫으면 서버도 꺼짐(Cockpit-Dashboard.cmd 의 창-수명 그대로).
# 뷰어 설치가 실패한 상태(오프라인 등)라도 아이콘은 정직하게 안내한다(.cmd 의 NOT_INSTALLED 경로:
# "인터넷 확인 후 재실행 또는 /cockpit-setup 재시도" 메시지·#17). 자산은 릴리스에서 받고 핀 해시로 검증.
function New-DashboardLauncher {
  param([string]$Distro)
  if ($Distro -ne 'cc-cockpit') {
    Warn "대시보드 아이콘 생략 — Cockpit-Dashboard.cmd 는 기본 배포판(cc-cockpit) 전용입니다(파일 상단 DISTRO 수동 편집으로 사용 가능)."
    return $null
  }
  if ($PinnedDashboardCmdSha256 -notmatch '^[0-9A-Fa-f]{64}$') {
    Warn "대시보드 런처 핀 미설정(미발행 미리보기) — 아이콘 생성 생략."
    return $null
  }
  $dUri = $null
  if (-not [Uri]::TryCreate($PinnedDashboardCmdUrl, [UriKind]::Absolute, [ref]$dUri) -or
      $dUri.Scheme -ne 'https' -or ($PLACEHOLDER_HOSTS -contains $dUri.Host)) {
    Warn "대시보드 런처 URL 이 유효한 https 가 아님 — 아이콘 생성 생략."
    return $null
  }
  $cockpitDir = Join-Path $env:LOCALAPPDATA 'Cockpit'
  if (-not (Test-Path $cockpitDir)) { New-Item -ItemType Directory -Path $cockpitDir -Force | Out-Null }
  $dashCmd = Join-Path $cockpitDir 'Cockpit-Dashboard.cmd'

  $tmp = Join-Path ([System.IO.Path]::GetTempPath()) ("cockpit-dash-" + [Guid]::NewGuid().ToString('N') + ".cmd")
  try { Invoke-WebRequest -Uri $PinnedDashboardCmdUrl -OutFile $tmp -UseBasicParsing }
  catch { Warn "대시보드 런처 다운로드 실패(설치는 계속 — 릴리스 페이지에서 직접 받아도 됩니다): $($_.Exception.Message)"; return $null }
  $dActual = (Get-FileHash -Path $tmp -Algorithm SHA256).Hash.ToLower()
  if ($dActual -ne $PinnedDashboardCmdSha256.ToLower()) {
    Remove-Item $tmp -Force -ErrorAction SilentlyContinue
    Warn "대시보드 런처 체크섬 불일치 — 아이콘 생성 생략(이미지 설치와 무관). 기대=$($PinnedDashboardCmdSha256.ToLower()) 실제=$dActual"
    return $null
  }
  Move-Item $tmp $dashCmd -Force
  Info "대시보드 런처 설치: $dashCmd"

  $iconPath = Join-Path $env:SystemRoot 'System32\wsl.exe'
  try {
    $ws = New-Object -ComObject WScript.Shell
    foreach ($t in @(
        (Join-Path ([Environment]::GetFolderPath('Programs')) 'Cockpit Dashboard.lnk'),
        (Join-Path ([Environment]::GetFolderPath('Desktop'))  'Cockpit Dashboard.lnk'))) {
      $sc = $ws.CreateShortcut($t)
      $sc.TargetPath       = $dashCmd
      $sc.WorkingDirectory = $cockpitDir
      $sc.IconLocation     = "$iconPath,0"
      $sc.Description      = 'Cockpit session dashboard (open = start, close window = stop)'
      $sc.Save()
      Info "바로가기 생성: $t"
    }
  } catch {
    Warn "대시보드 바로가기 생성 일부 실패(.cmd 는 설치됨): $($_.Exception.Message)"
  }
  return $dashCmd
}

# ── 11) 안내 ──────────────────────────────────────────────────────────────
Info "설치 완료 ✓  배포판 '$DistroName' 이 준비됐습니다(편의 설정 사전적용)."

# 11a) 세션 대시보드만 실패 시 완료화면에 명시(#16·§4.1 — 비치명·대화형만 강조).
# 무인 경로는 §9.4 에서 이미 warn 1줄을 냈다(화면 강조 불가) → 여기선 대화형만 블록 출력.
if ($DashboardResult -and $DashboardResult.Status -eq 'failed' -and -not $OnboardingBlocked) {
  $dashHint = Get-DashboardFailHint $DashboardResult.Class
  Write-Host ""
  Write-Host "[cockpit][안내] 세션 대시보드만 아직 설치하지 못했습니다 — 그 외 기능은 전부 정상입니다." -ForegroundColor Yellow
  Write-Host "   원인 추정: $dashHint (코드 $($DashboardResult.Code))"
  Write-Host "   → 인터넷 되는 곳에서 바탕화면 'Cockpit Dashboard' 아이콘을 다시 누르거나,"
  Write-Host "     Claude 안에서 /cockpit-setup 으로 재시도하세요."
  Write-Host ""
}

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
  Write-Host "  • 바탕화면 'Cockpit Dashboard' 더블클릭 → 세션 대시보드(기본 부속·창 닫으면 꺼짐. 설치 실패 상태면 인터넷 확인 후 아이콘 재실행 또는 /cockpit-setup 으로 재시도)."
}
Write-Host "  1) 로그인(최초 1회): claude 화면에서 /login → 브라우저가 열리면 'Claude 구독으로 로그인'(보통 1번) 선택."
Write-Host "  2) 로그인하면 창이 자동으로 한 번 다시 시작되며 사용법을 안내합니다(원격조종도 이때 켜짐 — 수동 재시작 불필요)."
Write-Host "  3) 홈의 README-first-run.txt 를 따르세요 — 플러그인 단계는 이미지가 정확히 안내합니다"
Write-Host "     (v0.1.2+ 사전설치 이미지는 /cockpit-setup 하나, 구 이미지는 /plugin marketplace add $MarketplaceUrl 부터)."
Write-Host ""
Write-Host "통째 삭제(되돌리기):  wsl --unregister $DistroName   # 다른 배포판은 안 건드림" -ForegroundColor Cyan
Write-Host ""

if (-not $SkipLaunch) {
  # #3 — 설치 직후에도 더블클릭 런처(Launch-Cockpit.cmd)와 동일 경로로 진입 = claude 자동실행 +
  #   최초 로그인 안내 + 로그인 후 원샷 재시작(원격조종 활성). 날것 WSL 셸로 떨구지 않는다(저리터러시
  #   막다른 길 제거). launch.sh 부재(비-preconfigure/staged 이미지) 시 claude 직접 실행으로 폴백.
  Info "claude 를 실행합니다 — 최초 1회 로그인 안내는 화면을 따라오세요(나가려면 claude 에서 /exit 또는 Ctrl-D)."
  & wsl.exe -d $DistroName -- bash -lc 'if [ -x "$HOME/.cockpit/launch.sh" ]; then "$HOME/.cockpit/launch.sh"; else claude; fi'
}
