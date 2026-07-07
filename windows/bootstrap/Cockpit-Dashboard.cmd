@echo off
rem Cockpit-Dashboard.cmd - web-app window lifecycle for the session dashboard.
rem Double-click = start server in WSL + open an Edge app window; closing the
rem window stops the server (idle-exit inside the viewer is the backstop).
rem ASCII only (cmd parser expects ANSI/OEM; Korean guidance lives in WSL layer).
rem External tools by absolute System32 path (PATH hijack). %errorlevel% is only
rem tested at top level, negatives caught with "neq 0" (wsl.exe returns -1).
title Cockpit Dashboard
setlocal EnableExtensions

rem ---- fixed values (advanced users may edit DISTRO for custom names) ----
set "DISTRO=cc-cockpit"
set "SYS32=%WINDIR%\System32"
set "WSL=%SYS32%\wsl.exe"
if not exist "%WSL%" set "WSL=%WINDIR%\Sysnative\wsl.exe"
set "CURL=%SYS32%\curl.exe"
set "PSEXE=%SYS32%\WindowsPowerShell\v1.0\powershell.exe"
set "FINDSTR=%SYS32%\findstr.exe"
set "TIMEOUTEXE=%SYS32%\timeout.exe"
set "PROFDIR=%LOCALAPPDATA%\Cockpit\DashboardProfile"
set "DASH=/usr/local/bin/cockpit-dashboard"

if not exist "%WSL%" (
  echo [cockpit] FATAL: wsl.exe not found - is WSL installed?
  pause
  exit /b 1
)

rem ---- start the server inside WSL; parse the machine-readable result line.
rem      Contract: last stdout line "COCKPIT_DASH_RESULT <STATE> <PORT>".
rem      wsl.exe's own errors (distro missing) are UTF-16 and never match findstr,
rem      so STATE stays empty and lands in the honest :wslfail path.
set "STATE="
set "PORT="
for /f "tokens=2,3" %%A in ('%WSL% -d %DISTRO% -- bash -lc "%DASH% start" ^| %FINDSTR% /b /c:"COCKPIT_DASH_RESULT "') do (
  set "STATE=%%A"
  set "PORT=%%B"
)
if "%STATE%"=="" goto :wslfail
if "%STATE%"=="NOT_INSTALLED" goto :notinstalled
if "%STATE%"=="ALREADY" goto :portcheck
if "%STATE%"=="STARTED" goto :portcheck
goto :starterror

:portcheck
echo %PORT%| "%FINDSTR%" /r "^[0-9][0-9]*$" >nul
if %errorlevel% neq 0 goto :starterror

rem ---- healthcheck from the Windows side (WSL2 localhost forwarding can lag) ----
set /a HTRIES=0
:health
"%CURL%" -s -o nul --max-time 2 http://127.0.0.1:%PORT%/
if %errorlevel% equ 0 goto :browse
set /a HTRIES+=1
if %HTRIES% geq 15 goto :healthfail
"%TIMEOUTEXE%" /t 1 /nobreak >nul
goto :health

:browse
set "EDGE=%ProgramFiles(x86)%\Microsoft\Edge\Application\msedge.exe"
if not exist "%EDGE%" set "EDGE=%ProgramFiles%\Microsoft\Edge\Application\msedge.exe"
if "%STATE%"=="ALREADY" goto :already

if not exist "%EDGE%" goto :fallback
echo [cockpit] Dashboard on http://127.0.0.1:%PORT%/ - close the window to stop it.
start "" /wait "%EDGE%" --app=http://127.0.0.1:%PORT%/ --user-data-dir="%PROFDIR%"
rem start /wait can return early if Edge hands off to a broker process; poll until
rem no msedge with our dedicated profile remains (window truly closed).
:waitclose
"%PSEXE%" -NoProfile -NonInteractive -Command "if (Get-CimInstance Win32_Process -Filter \"Name='msedge.exe'\" | Where-Object { $_.CommandLine -like '*Cockpit\DashboardProfile*' }) { exit 1 } else { exit 0 }"
if %errorlevel% neq 0 (
  "%TIMEOUTEXE%" /t 2 /nobreak >nul
  goto :waitclose
)
goto :stop

:already
rem Server was already running - open a window but do NOT own its lifecycle
rem (the launcher that started it, or the viewer's idle-exit, stops it).
echo [cockpit] Dashboard already running on http://127.0.0.1:%PORT%/ - opening a window.
echo [cockpit] This launcher will not stop the server (its original launcher or
echo [cockpit] the viewer's idle-exit owns that).
if exist "%EDGE%" (
  start "" "%EDGE%" --app=http://127.0.0.1:%PORT%/ --user-data-dir="%PROFDIR%"
) else (
  start "" http://127.0.0.1:%PORT%/
)
exit /b 0

:fallback
rem No Edge: default browser + explicit stop on keypress; idle-exit is the backstop.
echo [cockpit] Microsoft Edge not found - opening the default browser instead.
echo [cockpit] When you are done, close the browser tab and press any key here
echo [cockpit] to stop the dashboard server.
start "" http://127.0.0.1:%PORT%/
pause >nul
goto :stop

:stop
set "STOPSTATE="
for /f "tokens=2,3" %%A in ('%WSL% -d %DISTRO% -- bash -lc "%DASH% stop" ^| %FINDSTR% /b /c:"COCKPIT_DASH_RESULT "') do set "STOPSTATE=%%A"
"%CURL%" -s -o nul --max-time 2 http://127.0.0.1:%PORT%/
if %errorlevel% equ 0 (
  echo [cockpit] WARNING: port %PORT% still responds after stop. Inside WSL run:
  echo [cockpit]   %DASH% stop   ^(or: bash plugin/dashboard/disable-remote.sh --apply^)
  pause
  exit /b 4
)
if not "%STOPSTATE%"=="STOPPED" (
  echo [cockpit] WARNING: stop reported '%STOPSTATE%' - port is closed, but check
  echo [cockpit] inside WSL with: %DASH% status
  pause
  exit /b 4
)
exit /b 0

:wslfail
echo [cockpit] Could not reach WSL distro '%DISTRO%' - check:  wsl -l -v
echo [cockpit] (custom distro name? edit DISTRO at the top of this file)
pause
exit /b 1

:notinstalled
echo [cockpit] Dashboard viewer is not installed (install did not complete).
echo [cockpit] It is a required component, normally installed automatically at setup.
echo [cockpit] Check your internet connection, then double-click this icon again to
echo [cockpit] retry - or inside Claude Code run /cockpit-setup to reinstall it.
pause
exit /b 3

:starterror
echo [cockpit] Dashboard failed to start (state: %STATE%). Inside WSL check:
echo [cockpit]   %DASH% status   and  ~/.config/cockpit/dashboard-server.log
pause
exit /b 4

:healthfail
echo [cockpit] Server started but http://127.0.0.1:%PORT%/ is not reachable from
echo [cockpit] Windows after 15s. Stopping the server again for a clean state.
%WSL% -d %DISTRO% -- bash -lc "%DASH% stop" >nul 2>nul
pause
exit /b 5
