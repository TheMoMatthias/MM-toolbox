@echo off
REM Double-click, or right-click -> Run as administrator, to let this PC sign
REM itself in at boot so the session restore runs with nobody at the keyboard.
REM
REM It opens an ELEVATED WINDOW and asks for your Windows password IN THAT WINDOW.
REM The password is verified against Windows first, then stored encrypted in the
REM LSA secret store -- never in the registry in plaintext.
REM
REM   Enable Auto Logon.bat                  enable it
REM   Enable Auto Logon.bat -LockAfterLogon  enable it, but lock the screen once
REM                                          the sessions are up
REM   Enable Auto Logon.bat -Status          just report the current state
REM   Enable Auto Logon.bat -Disable         undo it, and delete the stored password
setlocal

REM -Status changes nothing and reads keys any user can read, so do not make the
REM UAC prompt a toll gate on simply looking.
echo %* | find /i "-Status" >nul
if not errorlevel 1 (
    powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0enable-autologon.ps1" %*
    echo.
    pause
    exit /b %ERRORLEVEL%
)

REM The script elevates ITSELF (-Elevate), into Windows Terminal where possible.
REM That is deliberate: elevating a bare powershell.exe from a non-interactive
REM parent has repeatedly produced a process with NO CONSOLE, and this script then
REM reaches its password prompt, reads end-of-file, and exits having silently
REM changed nothing -- which is exactly what happened on 2026-08-21. Keeping the
REM window logic in the .ps1 also keeps it out of batch quoting.
REM Already elevated (right-click -> Run as administrator)? It just runs here.
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0enable-autologon.ps1" -Elevate %*
set SR_EXIT=%ERRORLEVEL%

if not "%SR_EXIT%"=="0" (
    echo.
    echo [autologon] Exited with code %SR_EXIT% - nothing was changed.
    echo [autologon] If no window appeared, right-click this file and Run as administrator.
    echo.
    pause
)
exit /b %SR_EXIT%
