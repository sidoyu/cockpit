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

rem ---- STEP 0: remove reboot auto-resume leftovers FIRST (best-effort, silent).
rem      Must run before any distro checks: on a half-installed PC (WSL reboot
rem      pending, no distro yet) the backup/unregister steps below fail and never
rem      reach later cleanup - the pending RunOnce would then "reinstall" cockpit
rem      at next logon right after the user chose to remove it (Codex 4, v0.1.14).
"%SYS32%\reg.exe" delete "HKCU\Software\Microsoft\Windows\CurrentVersion\RunOnce" /v CockpitInstallResume /f >nul 2>nul
if exist "%LAUNCHDIR%\Cockpit-Install-Resume.cmd" del /q "%LAUNCHDIR%\Cockpit-Install-Resume.cmd" 2>nul
if exist "%LAUNCHDIR%\Resume-After-Reboot.cmd" del /q "%LAUNCHDIR%\Resume-After-Reboot.cmd" 2>nul

echo(
echo   ============================================================
echo    Cockpit Uninstall
echo   ============================================================
echo(
echo   Target WSL distro:  %DISTRO%   (no other distro is ever touched)
echo(
echo   This permanently DELETES the whole cc-cockpit distro. Before deleting,
echo   this tool first backs up your memories/state to a Windows folder that
echo   survives the delete:
echo       %USERPROFILE%\cockpit-backups
echo   To reinstall later and restore them, run Cockpit-Install.cmd.
echo(
echo   To cancel, just close this window.
echo(

rem ---- STEP 1: derive the /mnt backup path via wslpath - never hand-assemble
rem      it (handles drive letter, spaces, OneDrive redirect, non-C drives). ----
set "WINBK=%USERPROFILE%\cockpit-backups"
set "MNTBK="
rem NOTE(fix): wrap whole backtick cmd in an extra outer quote pair. Without it,
rem for/f mis-strips the leading quote of "%WSL%" and captures nothing (MNTBK empty
rem -> :backupfail: auto-backup silently skipped). Proven on Win/CP949 (SSH A/B).
for /f "usebackq delims=" %%P in (`""%WSL%" -d %DISTRO% -- wslpath -u "%WINBK%" 2^>nul"`) do set "MNTBK=%%P"
if "%MNTBK%"=="" goto :backupfail

rem ---- STEP 2: auto-backup into that Windows folder. Pass the /mnt path via
rem      WSLENV, not a bash string, so spaces or an apostrophe in the profile
rem      path cannot break shell quoting. backup.py returns 0 after the tar is
rem      finalized, or when there is nothing to back up - then no data is at risk.
echo [cockpit] Backing up memories/state to: %WINBK%
set "CC_BACKUP_DIR=%MNTBK%"
set "WSLENV=CC_BACKUP_DIR"
"%WSL%" -d %DISTRO% -- /usr/local/bin/cockpit-onboard backup 1>nul 2>nul
if %errorlevel% neq 0 goto :backupfail

rem ---- STEP 3a: backup step OK -> light yes/no confirmation. Name typing was
rem      only friction; DISTRO is hard-coded so it never guarded the wrong distro.
rem      Message avoids claiming a tar when there was simply nothing to back up.
echo [cockpit] Backup step done. Any saved data is under: %WINBK%
set "ANS="
set /p "ANS=Delete cc-cockpit now? [Y/N]: "
if /i "%ANS%"=="Y" goto :dodelete
goto :cancelled

:dodelete
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
  rem resume path downloads the installer ps1 next to its copy - clean it too, or
  rem the non-recursive rd below never removes the folder.
  if exist "%LAUNCHDIR%\Install-Cockpit.ps1" del /q "%LAUNCHDIR%\Install-Cockpit.ps1" 2>nul
  if exist "%LAUNCHDIR%\Install-Cockpit.ps1.mismatch" del /q "%LAUNCHDIR%\Install-Cockpit.ps1.mismatch" 2>nul
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

:backupfail
rem Backup did not complete (offline path-convert fail, no space, or a broken
rem distro that cannot run the backup). Default is to abort. Deleting anyway is
rem allowed only behind the strong confirmation (distro-name typing), so a user
rem whose distro is too broken to back up can still reinstall.
echo(
echo [cockpit] WARNING: automatic backup did NOT complete.
echo [cockpit] If you delete now, everything inside cc-cockpit is lost with
echo [cockpit] NO backup and cannot be recovered. A broken distro may be unable
echo [cockpit] to back up - deleting is then the only way to reinstall.
echo(
set "ANS="
set /p "ANS=To delete WITHOUT a backup, type the distro name '%DISTRO%' exactly: "
set "ANS_SAFE=%ANS:"=_%"
if not "%ANS_SAFE%"=="%DISTRO%" goto :mismatch
goto :dodelete

:cancelled
echo(
echo [cockpit] Cancelled - nothing was deleted. Your distro and data are intact.
pause
exit /b 1

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
