<#
.SYNOPSIS
  PowerShell 정적 분석 — 파서 + PSScriptAnalyzer. 단계4 한계(로컬 pwsh 없음) 해소용 CI 게이트.

.DESCRIPTION
  windows/ 와 scripts/ 의 *.ps1 을 (1) PowerShell 언어 파서로 구문 검증하고,
  (2) PSScriptAnalyzer 로 린트한다. 파서 오류 또는 Analyzer 'Error' 심각도 = 실패(exit 1).
  Warning 은 보고만(비차단). Windows PowerShell 5.1(powershell.exe) 과 pwsh(7+) 양쪽에서 동작.

.PARAMETER Paths   검사할 디렉터리(기본: windows, scripts).
.PARAMETER FailOnWarning  Warning 도 실패로 간주(엄격 모드).
#>
[CmdletBinding()]
param(
  [string[]]$Paths = @('windows', 'scripts'),
  [switch]$FailOnWarning
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path $PSScriptRoot -Parent
$fail = 0

function Info($m){ Write-Host "[ps-analyze] $m" }
function Err ($m){ Write-Host "[ps-analyze][ERROR] $m" -ForegroundColor Red }
function Warn($m){ Write-Host "[ps-analyze][warn] $m" -ForegroundColor Yellow }

Info "PSVersion = $($PSVersionTable.PSVersion)  Edition = $($PSVersionTable.PSEdition)"

# ── 검사 대상 수집 ──
$files = @()
foreach ($p in $Paths) {
  $full = Join-Path $repoRoot $p
  if (Test-Path $full) {
    $files += Get-ChildItem -Path $full -Recurse -Filter *.ps1 -File
  }
}
if (-not $files -or $files.Count -eq 0) { Warn "검사할 .ps1 파일이 없습니다."; exit 0 }
Info "$($files.Count) 개 .ps1 검사"

# ── 1) 파서 구문 검증 ──
Info "1) 언어 파서 구문 검증"
foreach ($f in $files) {
  $tokens = $null; $errors = $null
  [System.Management.Automation.Language.Parser]::ParseFile($f.FullName, [ref]$tokens, [ref]$errors) | Out-Null
  if ($errors -and $errors.Count -gt 0) {
    $fail = 1
    Err "$($f.Name): 파서 오류 $($errors.Count)건"
    foreach ($e in $errors) { Write-Host "      L$($e.Extent.StartLineNumber): $($e.Message)" }
  } else {
    Write-Host "  [ok] $($f.Name)"
  }
}

# ── 2) PSScriptAnalyzer ──
Info "2) PSScriptAnalyzer"
if (-not (Get-Module -ListAvailable -Name PSScriptAnalyzer)) {
  Warn "PSScriptAnalyzer 모듈 없음 — 린트 건너뜀(CI 는 사전 설치 권장). 파서 검증만 적용됨."
} else {
  Import-Module PSScriptAnalyzer -ErrorAction Stop
  $totErr = 0; $totWarn = 0
  foreach ($f in $files) {
    $res = Invoke-ScriptAnalyzer -Path $f.FullName -Severity @('Error','Warning') -ErrorAction SilentlyContinue
    $errs  = @($res | Where-Object { $_.Severity -eq 'Error' })
    $warns = @($res | Where-Object { $_.Severity -eq 'Warning' })
    $totErr += $errs.Count; $totWarn += $warns.Count
    if ($errs.Count -gt 0) {
      $fail = 1
      Err "$($f.Name): Analyzer Error $($errs.Count)건"
      foreach ($r in $errs) { Write-Host "      L$($r.Line) $($r.RuleName): $($r.Message)" }
    }
    if ($warns.Count -gt 0) {
      Warn "$($f.Name): Warning $($warns.Count)건"
      foreach ($r in $warns) { Write-Host "      L$($r.Line) $($r.RuleName): $($r.Message)" }
    }
  }
  Info "Analyzer 합계: Error=$totErr Warning=$totWarn"
  if ($FailOnWarning -and $totWarn -gt 0) { $fail = 1; Err "FailOnWarning 모드 — Warning 존재로 실패." }
}

Write-Host ""
if ($fail -eq 0) { Info "OK — 파서/Analyzer Error 0건."; exit 0 }
else { Err "실패 — 위 오류 해소 필요."; exit 1 }
