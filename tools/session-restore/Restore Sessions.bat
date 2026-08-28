@echo off
REM Double-click to bring back the Claude conversations you have selected.
REM From a terminal, `ccr` does the same thing with less typing.
setlocal

REM Pause only when double-clicked. When Explorer launches this file, the cmd.exe
REM that runs it carries this script's name in its own command line; started from a
REM terminal it does not, and a pause there would just be in the way.
echo %cmdcmdline% | find /i "%~nx0" >nul
if not errorlevel 1 (set "SR_PAUSE=1") else (set "SR_PAUSE=")

REM The detection cannot tell Explorer apart from a scripted `cmd /c "...bat"`, so
REM anything automating this can set SR_NOPAUSE=1 and never risk a hang.
if defined SR_NOPAUSE set "SR_PAUSE="

powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0lib\restore-sessions.ps1" %*
set SR_EXIT=%ERRORLEVEL%

if defined SR_PAUSE (
    echo.
    pause
)
exit /b %SR_EXIT%
