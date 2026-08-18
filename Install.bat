@echo off
REM Double-click to install MM-toolbox: skills and agents linked into ~/.claude,
REM the two session-restore scheduled tasks registered (logon restore + hourly
REM scan), the desktop buttons created, and cc/ccr/ccs added to your profile.
REM
REM Safe to run again -- install.ps1 is idempotent, so this is also how you APPLY
REM AN UPDATE after `git pull`.
REM
REM From a terminal, `.\install.ps1` does the same thing and takes the same
REM switches (-Force, -NoSessionRestore, -ClaudeHome <path>); this file passes
REM anything you give it straight through.
setlocal

REM Pause only when double-clicked. When Explorer launches this file, the cmd.exe
REM that runs it carries this script's name in its own command line; started from a
REM terminal it does not, and a pause there would just be in the way.
echo %cmdcmdline% | find /i "%~nx0" >nul
if not errorlevel 1 (set "MM_PAUSE=1") else (set "MM_PAUSE=")

REM The detection cannot tell Explorer apart from a scripted `cmd /c "...bat"`, so
REM anything automating this can set SR_NOPAUSE=1 and never risk a hang.
if defined SR_NOPAUSE set "MM_PAUSE="

powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0install.ps1" %*
set MM_EXIT=%ERRORLEVEL%

if not "%MM_EXIT%"=="0" (
    echo.
    echo [install] FAILED with exit code %MM_EXIT% - the error is printed above.
    echo [install] If it mentions a symlink or access being denied: turn on Windows
    echo [install] Developer Mode, or right-click this file and Run as administrator.
)

if defined MM_PAUSE (
    echo.
    pause
)
exit /b %MM_EXIT%
