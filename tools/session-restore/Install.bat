@echo off
REM Double-click to install THIS TOOL on this machine. Installs exactly four
REM things and nothing else:
REM
REM   1. scheduled task ClaudeSessionRestore  - at logon, 45s delay, reopens what
REM                                             you have ticked. Runs the .ps1
REM                                             through powershell.exe and NOT the
REM                                             app, deliberately: the unattended
REM                                             path stays off a freshly compiled
REM                                             unsigned binary
REM   2. scheduled task ClaudeSessionScan     - hourly + at logon, SCAN ONLY, so a
REM                                             new project shows up in the picker
REM                                             without ever launching anything
REM   3. Sessions.exe                         - the app itself, compiled here from
REM                                             app\SessionsHost.cs by app\build.ps1
REM                                             using csc.exe, which ships with the
REM                                             .NET Framework. Nothing is fetched,
REM                                             and a failure here is NOT fatal
REM   4. two desktop buttons                  - both pointing at Sessions.exe, one
REM                                             of them with -Restore, both carrying
REM                                             its icon
REM
REM ...then seeds the registry so the picker has something to show immediately,
REM and reports whether the machine is set to sign itself in.
REM
REM   Install.bat              install / repair, and report the auto-logon state
REM   Install.bat -AutoLogon   also enable auto-logon, so the logon restore runs
REM                            with nobody at the keyboard. Elevates, and stores
REM                            a password in the registry -- which is exactly why
REM                            it is opt-in and never the default.
REM
REM THERE ARE EXACTLY TWO FILES HERE, and this is one of them. Sessions.bat opens
REM the tool; this installs it. There used to be FIVE -- a separate restore
REM launcher, an auto-logon launcher and a .vbs -- and every one was a thin
REM wrapper around a script in lib\ that something else could call directly. The
REM scheduled tasks never went through any of them: they run
REM lib\restore-sessions.ps1 themselves, which is why removing the wrappers
REM changed nothing about the unattended path.
REM
REM It does NOT touch your PowerShell profile and does NOT install the cc/ccr/ccs
REM shell functions -- those come only from the repo-wide install.ps1.
REM
REM Safe to run again: the tasks are re-registered with -Force and the buttons are
REM rewritten, so this is also how you REPAIR a broken install or point the tasks
REM at a moved checkout.
REM
REM To remove all of it:  restore-sessions.ps1 -Uninstall
setlocal

REM Pause only when double-clicked. When Explorer launches this file, the cmd.exe
REM that runs it carries this script's name in its own command line; started from a
REM terminal it does not, and a pause there would just be in the way.
echo %cmdcmdline% | find /i "%~nx0" >nul
if not errorlevel 1 (set "SR_PAUSE=1") else (set "SR_PAUSE=")

REM The detection cannot tell Explorer apart from a scripted `cmd /c "...bat"`, so
REM anything automating this can set SR_NOPAUSE=1 and never risk a hang.
if defined SR_NOPAUSE set "SR_PAUSE="

powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0lib\restore-sessions.ps1" -Install %*
set SR_EXIT=%ERRORLEVEL%

if not "%SR_EXIT%"=="0" (
    echo.
    echo [install] FAILED with exit code %SR_EXIT% - the error is printed above.
)

if defined SR_PAUSE (
    echo.
    pause
)
exit /b %SR_EXIT%
