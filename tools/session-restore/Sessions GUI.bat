@echo off
REM Double-click for the Claude session control panel as a WINDOW: every
REM conversation across every repo, what is live right now, a button to open any
REM of them, and the ticks that decide what comes back at logon.
REM
REM Sessions.bat opens the same screen in a terminal. This one opens it in a
REM window; they read and write the same registry, so either is fine.
setlocal

REM WPF must have a single-threaded apartment. -STA is passed here rather than
REM relied on: powershell.exe defaults to STA, but the script also re-launches
REM itself if some other host ever starts it MTA.
REM
REM start "" detaches, so this console closes at once instead of sitting behind
REM the window for as long as the GUI is open. -WindowStyle Hidden keeps the
REM PowerShell console itself off the screen. Anything that goes wrong is
REM written to .state\restore.log -- that is the file to read if nothing appears.
REM
REM Set SR_GUI_SHOW=1 to run it with the console visible instead, which is how
REM you see a startup error rather than reading the log for it.
if defined SR_GUI_SHOW (
    powershell.exe -STA -NoProfile -ExecutionPolicy Bypass -File "%~dp0sessions-gui.ps1" %*
    echo.
    pause
    exit /b %ERRORLEVEL%
)

start "" powershell.exe -STA -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "%~dp0sessions-gui.ps1" %*
exit /b 0
