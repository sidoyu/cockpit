@echo off
rem Cockpit-Repair.cmd - one-click REINSTALL (repair / image update) of the cockpit
rem WSL distro. Mirrors Cockpit-Install.cmd's fetch+verify+pinned-hash chain, then runs
rem Install-Cockpit.ps1 with -Reinstall (unregisters ONLY cc-cockpit, after a type-the-name
rem confirmation inside the ps1). ASCII only (Korean guidance lives in the ps1 / README).
rem WARNING: reinstall re-imports a fresh distro - memories, settings and logs INSIDE the
rem old cc-cockpit distro are permanently lost. Back up anything important first.
rem Every external tool is called by absolute System32 path (PATH-hijack safe). %errorlevel%
rem is only tested at top level, and negative codes are caught with "neq 0" (errorlevel 1
rem misses negatives - live-proven on wsl.exe).
title Cockpit Repair
setlocal EnableExtensions

rem ---- pinned values: MUST equal Cockpit-Install.cmd (same Install-Cockpit.ps1). The release
rem      pipeline must re-pin BOTH .cmd together. publish-gate (section 1b) cross-checks THIS
rem      Repair pin too: PS1_SHA256 == repo ps1 hash and PS1_URL == manifest bootstrap.url. ----
set "PS1_URL=https://github.com/sidoyu/cockpit/releases/download/v0.1.5/Install-Cockpit.ps1"
set "PS1_SHA256=940d3e699254e0051b7d2d0c7b5736b4d3d91b3656e19bf4176e261f9c7b3284"

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

rem ---- placeholder / length gates (same model as Cockpit-Install.cmd) ----
if "%PS1_SHA256:~0,2%"=="__" goto :placeholder
if "%PS1_SHA256:~63,1%"=="" goto :badpin
if not "%PS1_SHA256:~64,1%"=="" goto :badpin

rem ---- data-loss warning: repair = fresh reinstall, distro contents are wiped ----
echo(
echo   ============================================================
echo    Cockpit Repair / Reinstall
echo   ============================================================
echo(
echo   This REINSTALLS the cockpit distro (cc-cockpit).
echo   Everything INSIDE the current cc-cockpit - your memories,
echo   settings and logs - will be permanently deleted, then a fresh
echo   image is imported. Other WSL distros are never touched.
echo(
echo   Back up anything important first. To cancel, just close this window.
echo   The installer will also ask you to re-type the distro name.
echo(
pause

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
set "COCKPIT_PS1_URL=%PS1_URL%"
set "COCKPIT_PS1_PATH=%PS1%"
"%PSEXE%" -NoProfile -Command "[Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12; Invoke-WebRequest -Uri $env:COCKPIT_PS1_URL -OutFile $env:COCKPIT_PS1_PATH -UseBasicParsing"
if %errorlevel% neq 0 goto :dlfail
goto :verify

:verify
"%CERTUTIL%" -hashfile "%PS1%" SHA256 | "%FINDSTR%" /i /c:"%PS1_SHA256%" >nul
if %errorlevel% neq 0 goto :hashfail
echo [cockpit] Checksum OK. Starting reinstall...
pushd "%BASE%"
"%PSEXE%" -NoProfile -ExecutionPolicy Bypass -File "%PS1%" -Reinstall
set "RC=%errorlevel%"
popd
if %RC% neq 0 goto :runfail
endlocal
exit /b 0

:placeholder
echo [cockpit] This is an unpublished preview copy - its download pin is not set.
echo [cockpit] Use a released Cockpit-Repair.cmd.
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
echo [cockpit] Reinstall exited with an error (code %RC%). See messages above.
pause
exit /b %RC%
