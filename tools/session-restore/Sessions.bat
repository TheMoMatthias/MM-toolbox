@echo off
REM Double-click for the Claude session control panel: every conversation across
REM every repo, what is live right now, L to open any of them, S for a new one,
REM and the ticks that decide what comes back at logon.
REM
REM THIS IS THE ENTRY POINT -- the panel, and the only file here you need for
REM day-to-day use. The others each do one specific job: "Install Session
REM Restore.bat" sets up the logon task, "Restore Sessions.bat" reopens the
REM ticked conversations without showing the panel, "Enable Auto Logon.bat"
REM makes the machine sign in by itself. Nothing else opens this screen.
setlocal

REM Pause only when double-clicked -- see the note in Restore Sessions.bat.
echo %cmdcmdline% | find /i "%~nx0" >nul
if not errorlevel 1 (set "SR_PAUSE=1") else (set "SR_PAUSE=")

REM The detection cannot tell Explorer apart from a scripted `cmd /c "...bat"`, so
REM anything automating this can set SR_NOPAUSE=1 and never risk a hang.
if defined SR_NOPAUSE set "SR_PAUSE="

REM A default 80x25 console shows eleven rows of a list that is often a hundred
REM long. Only resize the window Explorer just made for us -- resizing a terminal
REM the user was already working in would be rude.
if defined SR_PAUSE mode con: cols=118 lines=48 >nul 2>&1

powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0select-sessions.ps1" %*
set SR_EXIT=%ERRORLEVEL%

if defined SR_PAUSE (
    echo.
    pause
)
exit /b %SR_EXIT%
