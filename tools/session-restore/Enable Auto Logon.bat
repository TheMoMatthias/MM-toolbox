@echo off
REM Double-click to let this PC sign itself in at boot, so the session restore
REM runs without anyone typing a password.
REM
REM It asks for elevation (it writes HKLM and the LSA secret store) and then asks
REM for your Windows password IN THAT WINDOW. The password is verified first, then
REM stored encrypted -- it is never written to the registry in plaintext.
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

REM The elevated command line is built as ONE STRING, deliberately. Passing an
REM array to Start-Process -ArgumentList joins it with spaces and quotes NOTHING,
REM so a toolbox checked out under a path with a space in it would send the
REM elevated shell half a filename. That bug already cost this tool every tab in
REM one repo -- see the ConvertTo-SRArg note in _common.ps1.
REM -NoExit keeps the elevated window open: it prompts for a password, and the
REM result would otherwise scroll away with the window.
powershell.exe -NoProfile -ExecutionPolicy Bypass -Command "$s='%~dp0enable-autologon.ps1'; $x='%*'.Trim(); $c='-NoExit -NoProfile -ExecutionPolicy Bypass -File \"' + $s + '\"'; if ($x) { $c += ' ' + $x }; Start-Process powershell.exe -Verb RunAs -ArgumentList $c"
if errorlevel 1 (
    echo.
    echo [autologon] Elevation was declined or failed - nothing was changed.
    echo.
    pause
)
exit /b %ERRORLEVEL%
