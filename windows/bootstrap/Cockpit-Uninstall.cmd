@echo off
rem Cockpit-Uninstall.cmd - completely remove the cockpit WSL distro (cc-cockpit).
rem Self-contained (no download). ASCII only (Korean guidance lives in README / web).
rem SAFETY: the distro name is HARD-CODED to cc-cockpit and is never taken from user
rem input except for the confirmation match - this file can never unregister any other
rem distro (e.g. Ubuntu). wsl.exe is called by absolute System32 path. Negative exit
rem codes are caught with "neq 0" (errorlevel 1 misses negatives - live-proven on wsl.exe).
title Cockpit Uninstall
setlocal EnableExtensions

set "DISTRO=cc-cockpit"
set "SYS32=%WINDIR%\System32"
set "WSL=%SYS32%\wsl.exe"
set "PSEXE=%SYS32%\WindowsPowerShell\v1.0\powershell.exe"
set "INSTALLDIR=%LOCALAPPDATA%\%DISTRO%"
set "LAUNCHDIR=%LOCALAPPDATA%\Cockpit"

if not exist "%WSL%" (
  echo [cockpit] FATAL: wsl.exe not found at %WSL% - is WSL installed?
  pause
  exit /b 1
)

echo(
echo   ============================================================
echo    Cockpit Uninstall
echo   ============================================================
echo(
echo   Target WSL distro:  %DISTRO%   (no other distro is ever touched)
echo(
echo   This permanently DELETES the whole cc-cockpit distro. Everything
echo   inside it - your memories, settings and logs - is lost and cannot
echo   be recovered. Back up anything important first.
echo(
echo   To cancel, just close this window.
echo(
set "ANS="
set /p "ANS=To proceed, type the distro name '%DISTRO%' exactly: "
rem neutralize any double-quotes in the input before comparing (cmd parse-safety).
set "ANS_SAFE=%ANS:"=_%"
if not "%ANS_SAFE%"=="%DISTRO%" goto :mismatch

echo(
echo [cockpit] Terminating and unregistering '%DISTRO%' ...
"%WSL%" --terminate %DISTRO% 1>nul 2>nul
"%WSL%" --unregister %DISTRO%
if %errorlevel% neq 0 goto :unregfail

echo [cockpit] Distro '%DISTRO%' removed.

if exist "%INSTALLDIR%" (
  echo [cockpit] Cleaning up default install folder: %INSTALLDIR%
  rd /s /q "%INSTALLDIR%" 2>nul
)
if exist "%INSTALLDIR%" echo [cockpit] WARNING: could not fully remove %INSTALLDIR% - delete it by hand.

rem launcher artifacts: delete ONLY the files we create (never the whole folder -
rem a user may keep their own files in %LOCALAPPDATA%\Cockpit). The bare "rd"
rem below is non-recursive: it removes the folder only if it is empty afterwards.
if exist "%LAUNCHDIR%" (
  echo [cockpit] Cleaning up launcher files in: %LAUNCHDIR%
  if exist "%LAUNCHDIR%\Launch-Cockpit.cmd" del /q "%LAUNCHDIR%\Launch-Cockpit.cmd" 2>nul
  if exist "%LAUNCHDIR%\Cockpit-Dashboard.cmd" del /q "%LAUNCHDIR%\Cockpit-Dashboard.cmd" 2>nul
  if exist "%LAUNCHDIR%\DashboardProfile" rd /s /q "%LAUNCHDIR%\DashboardProfile" 2>nul
  rd "%LAUNCHDIR%" 2>nul
)
rem shortcuts: resolve the real Desktop/Start Menu via PowerShell (OneDrive may
rem redirect Desktop away from %USERPROFILE%\Desktop). Delete a shortcut ONLY if
rem its TargetPath points into our launcher folder - a same-named shortcut the
rem user made for something else is left alone. Best-effort, never fatal.
rem SAFETY - keep every line inside the block below free of unquoted parens: cmd
rem scans block bodies for a bare closing paren, ends the block right there and
rem aborts the whole batch - and this applies to rem comments inside blocks too.
rem Live-proven v0.1.6: the final echo said "if any" in parens and this whole
rem shortcut cleanup never ran. publish-gate 1e / cmd-paren-gate.py now block it.
if exist "%PSEXE%" (
  "%PSEXE%" -NoProfile -NonInteractive -Command "$ws=New-Object -ComObject WScript.Shell; $dir=Join-Path $env:LOCALAPPDATA 'Cockpit'; foreach($n in @('Claude (cockpit).lnk','Cockpit Dashboard.lnk')){foreach($d in @([Environment]::GetFolderPath('Desktop'),[Environment]::GetFolderPath('Programs'))){$p=Join-Path $d $n; if(Test-Path $p){$t=$ws.CreateShortcut($p).TargetPath; if($t -like ($dir+'\*')){Remove-Item $p -Force -ErrorAction SilentlyContinue}}}}" 1>nul 2>nul
  echo [cockpit] Removed cockpit shortcuts from Desktop / Start Menu, if any.
)

echo(
echo [cockpit] Done. If cockpit was installed to a custom folder, remove that folder
echo [cockpit] by hand. If any cockpit shortcut still remains on the Desktop or
echo [cockpit] Start Menu, delete it too. To reinstall, run Cockpit-Install.cmd.
echo(
pause
endlocal
exit /b 0

:mismatch
echo(
echo [cockpit] Input did not match '%DISTRO%' - nothing was deleted.
pause
exit /b 1

:unregfail
echo(
echo [cockpit] Unregister failed (code %errorlevel%). Either '%DISTRO%' is not
echo [cockpit] installed, or WSL is busy. Close every open cockpit window and try
echo [cockpit] again. (No other distro was touched.)
pause
exit /b 1
