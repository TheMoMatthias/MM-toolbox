' Double-click THIS for the session window. Nothing flashes.
'
' "Sessions GUI.bat" opened two windows before the app appeared: cmd.exe has to
' create a console to run a batch file at all, and the PowerShell it starts gets
' its own before -WindowStyle Hidden can take effect. Both are gone by the time
' you see the app, which is exactly what makes it look broken.
'
' A .vbs is opened by wscript.exe, which has no console of its own, and Run with
' a window style of 0 starts PowerShell hidden from the outset. Nothing is ever
' drawn. The last argument is False, so this script exits immediately instead of
' waiting for the app to close.
'
' The .bat is kept for the terminal: it is how you run the GUI with a console
' attached (SR_GUI_SHOW=1) and see a startup error rather than reading the log
' for it. Use this file for normal use and that one when something is wrong.

Option Explicit

Dim fso, shell, here, ps1, cmd, args, i

Set fso   = CreateObject("Scripting.FileSystemObject")
Set shell = CreateObject("WScript.Shell")

' Resolve next to this file, so the folder can be moved or renamed freely.
here = fso.GetParentFolderName(WScript.ScriptFullName)
ps1  = fso.BuildPath(here, "sessions-gui.ps1")

If Not fso.FileExists(ps1) Then
    MsgBox "sessions-gui.ps1 is not next to this launcher." & vbCrLf & vbCrLf & _
           "Looked in:" & vbCrLf & here, vbExclamation, "Claude sessions"
    WScript.Quit 1
End If

' Anything passed to the launcher is forwarded, so "Sessions GUI.vbs" -NoScan
' behaves like the script does.
args = ""
For i = 0 To WScript.Arguments.Count - 1
    args = args & " " & WScript.Arguments(i)
Next

' -STA because WPF requires a single-threaded apartment.
cmd = "powershell.exe -STA -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File """ & ps1 & """" & args

' 0 = hidden, False = do not wait.
shell.Run cmd, 0, False
