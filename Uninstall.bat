@echo off
REM Double-click to remove MM-toolbox's links, both scheduled tasks and both
REM desktop buttons. Your session SELECTIONS (sessions-registry.json) and the repo
REM itself are left alone.
setlocal

echo %cmdcmdline% | find /i "%~nx0" >nul
if not errorlevel 1 (set "MM_PAUSE=1") else (set "MM_PAUSE=")
if defined SR_NOPAUSE set "MM_PAUSE="

powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0uninstall.ps1" %*
set MM_EXIT=%ERRORLEVEL%

if defined MM_PAUSE (
    echo.
    pause
)
exit /b %MM_EXIT%
