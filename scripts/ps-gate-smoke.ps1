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

Write-Host ""
if ($fail -eq 0) { Info "OK — 안전 게이트 발화 + 서명 점검 통과."; exit 0 }
else { Err "실패 — 위 항목 확인."; exit 1 }
