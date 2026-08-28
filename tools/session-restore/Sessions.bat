@echo off
REM Double-click for the Claude session console: every conversation across every
REM repo, what each one last said, what is waiting on you, and the ticks that
REM decide what comes back at logon.
REM
REM THIS IS THE ENTRY POINT. The others each do one specific job:
REM "Install Session Restore.bat" sets up the logon task, "Restore Sessions.bat"
REM reopens the ticked conversations without showing anything, "Enable Auto
REM Logon.bat" makes the machine sign in by itself.
REM
REM "Sessions.exe" is now the normal way in, and is what the desktop button
REM points at: it hosts the PowerShell runspace itself, so there is no
REM powershell.exe underneath the window, it carries the app's own icon in
REM Alt-Tab and the taskbar, and it opens ONCE however many times you
REM double-click it. Build it with app\build.ps1; the installer already does.
REM
REM "Sessions GUI.vbs" opens the SAME window with no console flash, through
REM powershell.exe, and is the fallback for a machine where the exe will not
REM build or an antivirus has quarantined it.
REM
REM USE THIS FILE WHEN SOMETHING IS WRONG. It is the only route that attaches a
REM console, so set SR_GUI_SHOW=1 and a startup error lands on screen instead of
REM in .state\restore.log. (Sessions.exe honours the same variable and allocates
REM a console for it, but this is the simpler thing to reach for.)
REM
REM It used to run select-sessions.ps1, a terminal panel with its own painter
REM and key loop. The window replaced it: same registry, same guards, same
REM model, and it can do things a console cannot -- read a conversation, reply
REM to it, and reach its real terminal tab.
setlocal

REM WPF must have a single-threaded apartment. -STA is passed explicitly rather
REM than relied on: powershell.exe defaults to STA, but nothing guarantees the
REM host that starts this one does.
if defined SR_GUI_SHOW (
    powershell.exe -STA -NoProfile -ExecutionPolicy Bypass -File "%~dp0lib\sessions-gui.ps1" %*
    echo.
    pause
    exit /b %ERRORLEVEL%
)

REM start "" detaches, so this console closes at once instead of sitting behind
REM the window for as long as it is open. -WindowStyle Hidden keeps the
REM PowerShell console off the screen. Anything that goes wrong is written to
REM .state\restore.log -- that is the file to read if nothing appears.
start "" powershell.exe -STA -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "%~dp0lib\sessions-gui.ps1" %*
exit /b 0
