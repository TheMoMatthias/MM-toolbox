@echo off
REM Double-click to choose which conversations reopen at logon.
REM From a terminal, `ccs` does the same thing with less typing.
setlocal

REM Pause only when double-clicked -- see the note in Restore Sessions.bat.
echo %cmdcmdline% | find /i "%~nx0" >nul
if not errorlevel 1 (set "SR_PAUSE=1") else (set "SR_PAUSE=")

REM The detection cannot tell Explorer apart from a scripted `cmd /c "...bat"`, so
REM anything automating this can set SR_NOPAUSE=1 and never risk a hang.
if defined SR_NOPAUSE set "SR_PAUSE="

powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0select-sessions.ps1" %*
set SR_EXIT=%ERRORLEVEL%

if defined SR_PAUSE (
    echo.
    pause
)
exit /b %SR_EXIT%
