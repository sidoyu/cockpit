<#
.SYNOPSIS
  Windows 스모크 — 부트스트랩의 안전 게이트가 실제로 발화하는지 + Authenticode 서명 확인.

.DESCRIPTION
  Install-Cockpit.ps1 을 '실패해야 하는' 인자로 호출해, 각 안전 게이트가 WSL 을 건드리기 전에
  exit≠0 으로 차단하는지(+기대 메시지 출력) 검증한다. 이 음성 테스트들은 모두 WSL/Windows-버전
  검사 이전 단계에서 죽으므로, WSL 미설치 러너에서도 안전하게 돈다.
  기본은 powershell.exe(Windows PowerShell 5.1)로 자식 실행 — 단계4 한계(실 5.1 미검증) 해소.

  추가로 부트스트랩 파일의 Authenticode 서명을 점검한다. -RequireSignature 면 Valid 아니면 실패(발행 게이트).

.PARAMETER BootstrapDir   Install-Cockpit.ps1 위치(기본: windows/bootstrap).
.PARAMETER RequireSignature  서명 Valid 를 강제(발행 빌드). 기본은 경고만(개발).
.PARAMETER Pwsh           자식 실행에 쓸 PowerShell(기본 powershell.exe → 5.1).
#>
[CmdletBinding()]
param(
  [string]$BootstrapDir,
  [switch]$RequireSignature,
  [string]$Pwsh = 'powershell.exe'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path $PSScriptRoot -Parent
if (-not $BootstrapDir) { $BootstrapDir = Join-Path $repoRoot 'windows\bootstrap' }
$ps1 = Join-Path $BootstrapDir 'Install-Cockpit.ps1'
$fail = 0

function Info($m){ Write-Host "[ps-gate-smoke] $m" }
function Err ($m){ Write-Host "[ps-gate-smoke][FAIL] $m" -ForegroundColor Red }
function Warn($m){ Write-Host "[ps-gate-smoke][warn] $m" -ForegroundColor Yellow }
function Ok  ($m){ Write-Host "  [ok] $m" -ForegroundColor Green }

Info "PSVersion(현재) = $($PSVersionTable.PSVersion); 자식 실행 = $Pwsh"
if (-not (Test-Path $ps1)) { Err "부트스트랩 없음: $ps1"; exit 1 }

# 자식 PowerShell 사용 가능?
$childOk = $true
try { & $Pwsh -NoProfile -Command '$PSVersionTable.PSVersion.ToString()' | Out-Null } catch { $childOk = $false }
if (-not $childOk) { Warn "$Pwsh 실행 불가 — 현재 셸로 대체."; $Pwsh = (Get-Process -Id $PID).Path }

# ── 1) 안전 게이트 음성 테스트(차단되어야 함) ──
# ⚠ 각 케이스는 *명시 인자*로 게이트를 강제한다 — 발행 시 $PinnedSha256/$PinnedImageUrl 이
#    실제값으로 치환돼도 동일하게 발화하도록(미발행 placeholder 상태에 의존하지 않음).
Info "1) 안전 게이트 음성 테스트(각 케이스는 WSL 접근 전에 차단되어야 함)"
$hex64 = ('a' * 64)
$cases = @(
  # 임의 배포판명 → cc- 접두 강제로 차단
  @{ name='custom-distro-no-flag';     args=@('-DistroName','myubuntu','-SkipLaunch');                                                              expect='cc-' }
  # URL 오버라이드(=핀 이탈)인데 -AllowUnpinnedImage 없음 → 핀-미사용 게이트 차단(핀이 실제값이어도 override 라 발화)
  @{ name='unpinned-override-no-flag'; args=@('-ImageUrl','https://download.example.com/x.tar.gz','-SkipLaunch');                                   expect='핀 고정' }
  # 핀-미사용 허용 후 잘못된 해시 → 64-hex 검증 차단
  @{ name='bad-hex-with-unpinned';     args=@('-AllowUnpinnedImage','-ExpectedSha256','nothex','-SkipLaunch');                                      expect='64-hex' }
  # 명시적으로 example.invalid 호스트 지정 → placeholder 호스트 거부(핀 URL 치환과 무관)
  @{ name='placeholder-host';          args=@('-AllowUnpinnedImage','-ExpectedSha256',$hex64,'-ImageUrl','https://example.invalid/x.tar.gz','-SkipLaunch'); expect='플레이스홀더' }
)
foreach ($c in $cases) {
  $argList = @('-NoProfile','-ExecutionPolicy','Bypass','-File',$ps1) + $c.args
  $out = & $Pwsh @argList 2>&1 | Out-String
  $code = $LASTEXITCODE
  $hit = ($out -match [regex]::Escape($c.expect))
  if ($code -ne 0 -and $hit) {
    Ok "$($c.name): 차단됨(exit=$code, 기대 메시지 '$($c.expect)' 일치)"
  } else {
    $fail = 1
    Err "$($c.name): 게이트 미발화(exit=$code, 메시지일치=$hit). 안전 게이트가 우회되었을 수 있음."
    Write-Host ($out -split "`n" | Select-Object -First 6 | ForEach-Object { "      $_" })
  }
}

# ── 2) Authenticode 서명 점검 ──
Info "2) Authenticode 서명"
$targets = @(@('Install-Cockpit.ps1','Install-Cockpit-Staged.ps1') | ForEach-Object { Join-Path $BootstrapDir $_ } | Where-Object { Test-Path $_ })
# staged 는 ..\staged 에 있을 수 있음
$staged = Join-Path (Split-Path $BootstrapDir -Parent) 'staged\Install-Cockpit-Staged.ps1'
if (Test-Path $staged) { $targets += $staged }
foreach ($t in ($targets | Select-Object -Unique)) {
  $sig = Get-AuthenticodeSignature -FilePath $t
  $name = Split-Path $t -Leaf
  if ($sig.Status -eq 'Valid') {
    Ok "${name}: 서명 Valid (지문 $($sig.SignerCertificate.Thumbprint))"
  } elseif ($RequireSignature) {
    $fail = 1; Err "${name}: 서명 상태 '$($sig.Status)' — 발행 전 Authenticode 서명 필요."
  } else {
    Warn "${name}: 서명 상태 '$($sig.Status)'(미서명 발행은 정상 — 무결성은 SHA-256 핀 대조. 서명 발행은 -RequireSignature 로 강제)."
  }
}

# ── 3) 런처(.cmd) 안전 불변식(정적 소스 검사) ──
# WSL 미설치 러너에서도 도는 정적 검사. 발견3: 런처가 실패를 숨기지 않는지(detached wt.exe 분기
# 부재 + errorlevel→pause 가드). 발견5: 배포판명 strict allowlist. (b)(c)는 2026-07-02 라이브
# 실측으로 재정의 — 상세 각 항목 주석.
Info "3) 런처(.cmd) 안전 불변식(정적)"
$launcherFiles = @($ps1)
$stg = Join-Path (Split-Path $BootstrapDir -Parent) 'staged\Install-Cockpit-Staged.ps1'
if (Test-Path $stg) { $launcherFiles += $stg }
foreach ($lf in $launcherFiles) {
  $name = Split-Path $lf -Leaf
  $src  = Get-Content -Raw $lf
  # (a) detached wt.exe 분기 부재(즉시 exit0 → 실패 숨김 회귀가드)
  if ($src -match 'start\s+""\s+wt') {
    $fail = 1; Err "${name}: detached 'start ”” wt' 분기 잔존 — WSL/claude 실패를 숨길 수 있음(발견3 회귀)."
  } else { Ok "${name}: detached wt.exe 분기 없음(실패 가시성 우회 차단)" }
  # (b) 실패 가시성: %errorlevel% neq 0 가드 + pause 배열요소. `if errorlevel 1` 은 wsl.exe 의
  #     음수(-1) 종료코드를 못 잡아 창이 소리 없이 닫힘(라이브 실측 2026-07-02) — 잔존 자체가 회귀.
  if (($src.Contains('if %errorlevel% neq 0 (')) -and ($src -match "'\s+pause'")) {
    Ok "${name}: 실패 시 %errorlevel% neq 0 → pause 가드 존재"
  } else { $fail = 1; Err "${name}: %errorlevel% neq 0 → pause 가드 누락(발견3·음수코드 라이브 실측)." }
  if ($src.Contains('if errorlevel 1 (')) {
    $fail = 1; Err "${name}: 'if errorlevel 1' 잔존 — wsl 음수 종료코드 미포착(라이브 실측 회귀)."
  } else { Ok "${name}: 음수-미포착 형태('if errorlevel 1') 없음" }
  # (c) .cmd 배포판명 **무인용**(라이브 실측 2026-07-02: cmd 경유 wsl.exe 가 -d "이름" 의 따옴표를
  #     벗기지 않아 WSL_E_DISTRO_NOT_FOUND — 인용이 곧 버그. 이름은 (d) strict allowlist 로 공백
  #     불가라 무인용이 안전. 옛 (c)'인용 필수' 검사를 정반대로 재정의).
  if ($src.Contains('%WSL% -d "')) {
    $fail = 1; Err "${name}: .cmd 배포판명 인용 잔존 — cmd→wsl 따옴표 미탈피로 실행 불가(라이브 실측 회귀)."
  } else { Ok "${name}: .cmd 배포판명 무인용(cmd→wsl 실측 정합)" }
  # (d) 배포판명 strict allowlist(발견5)
  if ($src.Contains('^cc-[A-Za-z0-9._-]+$')) { Ok "${name}: 배포판명 strict allowlist 적용" }
  else { $fail = 1; Err "${name}: 배포판명 allowlist 강화(^cc-[A-Za-z0-9._-]+`$) 누락(발견5)." }
}

Write-Host ""
if ($fail -eq 0) { Info "OK — 안전 게이트 발화 + 서명 점검 + 런처 불변식 통과."; exit 0 }
else { Err "실패 — 위 항목 확인."; exit 1 }
