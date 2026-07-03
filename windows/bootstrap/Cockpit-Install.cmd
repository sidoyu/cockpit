@echo off
rem Cockpit-Install.cmd - one-click bridge: fetch + verify + run Install-Cockpit.ps1.
rem ASCII only (cmd parser expects ANSI/OEM; Korean guidance lives in the ps1 layer).
rem Every external tool is called by absolute System32 path: a same-folder
rem curl.exe / certutil.exe must never win over the pinned-hash model (PATH hijack).
rem %errorlevel% is only tested at top level, never inside ( ) blocks (parse-time
rem expansion trap), and negative exit codes are caught with "neq 0" (errorlevel 1
rem misses negatives - live-proven on wsl.exe).
title Cockpit Install
setlocal EnableExtensions

rem ---- pinned values (release pipeline substitutes; publish-gate blocks placeholders
rem      and enforces PS1_SHA256 == sha256(Install-Cockpit.ps1) == manifest bootstrap) ----
set "PS1_URL=https://github.com/sidoyu/cockpit/releases/download/v0.1.3/Install-Cockpit.ps1"
set "PS1_SHA256=bfa14bda0dbcc7fe6c089ff69788bf6fafe1bd131fec9c830354479de540ebcf"

set "BASE=%~dp0"
set "PS1=%BASE%Install-Cockpit.ps1"
set "SYS32=%WINDIR%\System32"
set "PSEXE=%SYS32%\WindowsPowerShell\v1.0\powershell.exe"
set "CURL=%SYS32%\curl.exe"
set "CERTUTIL=%SYS32%\certutil.exe"
set "FINDSTR=%SYS32%\findstr.exe"
set "DOWNLOADED="

if not exist "%PSEXE%" (
  echo [cockpit] FATAL: PowerShell not found at %PSEXE%
  pause
  exit /b 1
)

rem ---- placeholder gate: an unpublished preview copy must fail honestly ----
rem Checked by "__" prefix, NOT by comparing to the literal token: release
rem substitution replaces the token everywhere, so a literal comparison would
rem turn into if "<hash>"=="<hash>" after release and always fire (test-proven).
rem A placeholder URL needs no check here: publish-gate blocks it, and at worst
rem it surfaces as an honest download failure that shows the bogus URL.
if "%PS1_SHA256:~0,2%"=="__" goto :placeholder
rem ---- 64-char length gate (hex charset is enforced by publish-gate) ----
if "%PS1_SHA256:~63,1%"=="" goto :badpin
if not "%PS1_SHA256:~64,1%"=="" goto :badpin

if exist "%PS1%" goto :verify

:download
set "DOWNLOADED=1"
echo [cockpit] Downloading Install-Cockpit.ps1 ...
if not exist "%CURL%" goto :dl_iwr
"%CURL%" -fL --retry 2 -o "%PS1%" "%PS1_URL%"
if %errorlevel% equ 0 goto :verify
if exist "%PS1%" del "%PS1%"
echo [cockpit] curl download failed - trying PowerShell fallback...
:dl_iwr
rem URL/path go through environment variables, not -Command string interpolation:
rem special characters in the user profile path must not break PowerShell parsing.
set "COCKPIT_PS1_URL=%PS1_URL%"
set "COCKPIT_PS1_PATH=%PS1%"
"%PSEXE%" -NoProfile -Command "[Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12; Invoke-WebRequest -Uri $env:COCKPIT_PS1_URL -OutFile $env:COCKPIT_PS1_PATH -UseBasicParsing"
if %errorlevel% neq 0 goto :dlfail
goto :verify

:verify
"%CERTUTIL%" -hashfile "%PS1%" SHA256 | "%FINDSTR%" /i /c:"%PS1_SHA256%" >nul
if %errorlevel% neq 0 goto :hashfail
echo [cockpit] Checksum OK. Starting installer...
pushd "%BASE%"
"%PSEXE%" -NoProfile -ExecutionPolicy Bypass -File "%PS1%"
set "RC=%errorlevel%"
popd
if %RC% neq 0 goto :runfail
endlocal
exit /b 0

:placeholder
echo [cockpit] This is an unpublished preview copy - its download pin is not set.
echo [cockpit] Use a released Cockpit-Install.cmd. Run Install-Cockpit.ps1 directly
echo [cockpit] only if you built it or verified its checksum yourself.
pause
exit /b 1

:badpin
echo [cockpit] FATAL: pinned hash is malformed (not 64 chars). Do not use this copy.
pause
exit /b 1

:dlfail
if exist "%PS1%" del "%PS1%"
echo [cockpit] Download failed: %PS1_URL%
echo [cockpit] Check the network connection, proxy settings, or security software
echo [cockpit] blocking downloads, then run this file again.
pause
exit /b 1

:hashfail
if "%DOWNLOADED%"=="1" goto :hashfail_dl
rem Existing local file does not match the pinned version (stale or modified).
rem Keep it aside as .mismatch and fetch a fresh pinned copy. One retry only:
rem after this jump DOWNLOADED=1, so a second mismatch lands in :hashfail_dl.
echo [cockpit] Existing Install-Cockpit.ps1 does not match the pinned version.
echo [cockpit] Keeping it as Install-Cockpit.ps1.mismatch and downloading fresh...
if exist "%PS1%.mismatch" del "%PS1%.mismatch"
ren "%PS1%" "Install-Cockpit.ps1.mismatch"
if %errorlevel% neq 0 goto :renfail
goto :download

:hashfail_dl
del "%PS1%"
echo [cockpit] FATAL: the downloaded file failed checksum verification.
echo [cockpit] The file was deleted. This means network corruption or tampering -
echo [cockpit] do NOT bypass this check. Retry later or from another network.
pause
exit /b 1

:renfail
echo [cockpit] FATAL: could not move the mismatched file aside. Delete or move
echo [cockpit] Install-Cockpit.ps1 out of this folder, then run this file again.
pause
exit /b 1

:runfail
echo(
echo [cockpit] Installer exited with an error (code %RC%). See messages above.
pause
exit /b %RC%
