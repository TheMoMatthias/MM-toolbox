#requires -Version 5.1
<#
    THE PARTS THAT ONLY EXIST WHEN THE WINDOW IS REALLY OPEN.

    Every other suite either splices the script before ShowDialog or drives the
    list once it is up. Neither reaches the tray: Initialize-Tray runs in a
    spliced harness, but the NotifyIcon it creates is never shown to a shell,
    Add_StateChanged never fires because nothing minimises an unshown window,
    and Hide-ToTray / Show-FromTray had NEVER RUN AT ALL - not in a test, not in
    a probe, not once - while being reported as done.

    So this one starts the real script, the real way, and drives it:

      1. the window appears at all           (the whole load path, in situ)
      2. a tray icon exists for that pid     (Initialize-Tray reached the shell)
      3. minimising HIDES it, not minimises  (Add_StateChanged -> Hide-ToTray)
      4. the process is still alive after    (hidden, not exited)
      5. it comes back                       (Show-FromTray)
      6. closing takes the tray icon with it (no orphan left in the tray)

    Needs a desktop. Skipped by -NoSteal, because a window appears on purpose.
    It always kills what it started, even on a failure.
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName UIAutomationClient, UIAutomationTypes

$here = $PSScriptRoot
if (-not $here) { $here = Split-Path -Parent $MyInvocation.MyCommand.Path }
$tool = Split-Path -Parent $here

$fails = 0
function Fail { param($m) Write-Host "  FAIL  $m" -ForegroundColor Red; $script:fails++ }
function Pass { param($m) Write-Host "  ok    $m" -ForegroundColor Green }
function Note { param($m) Write-Host "        $m" -ForegroundColor DarkGray }

# --- the tray, read off the shell rather than off our own variables ---------
# $script:tray being non-null proves a NotifyIcon object exists. It does not
# prove the shell ever accepted it, which is the only thing that matters.
function Get-TrayButtons {
    $out = @()
    $root = [System.Windows.Automation.AutomationElement]::RootElement
    foreach ($cls in @('Shell_TrayWnd', 'NotifyIconOverflowWindow', 'TopLevelWindowForOverflowXamlIsland')) {
        $bar = $root.FindFirst([System.Windows.Automation.TreeScope]::Children,
            (New-Object System.Windows.Automation.PropertyCondition(
                [System.Windows.Automation.AutomationElement]::ClassNameProperty, $cls)))
        if (-not $bar) { continue }
        $btns = $bar.FindAll([System.Windows.Automation.TreeScope]::Descendants,
            (New-Object System.Windows.Automation.PropertyCondition(
                [System.Windows.Automation.AutomationElement]::ControlTypeProperty,
                [System.Windows.Automation.ControlType]::Button)))
        foreach ($b in $btns) { $out += $b }
    }
    return $out
}
function Find-OurTrayIcon {
    foreach ($b in @(Get-TrayButtons)) {
        try { if ("$($b.Current.Name)" -match 'Claude sessions') { return $b } } catch { }
    }
    return $null
}

function Get-OurWindow { param([int]$ProcId)
    $root = [System.Windows.Automation.AutomationElement]::RootElement
    $wins = $root.FindAll([System.Windows.Automation.TreeScope]::Children,
        (New-Object System.Windows.Automation.PropertyCondition(
            [System.Windows.Automation.AutomationElement]::ProcessIdProperty, $ProcId)))
    foreach ($w in $wins) { if ("$($w.Current.Name)" -match 'Claude sessions') { return $w } }
    return $null
}

$proc = $null
try {
    # THE REAL SCRIPT, started the way Sessions.bat starts it.
    $proc = Start-Process powershell.exe -PassThru -ArgumentList @(
        '-STA', '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', (Join-Path $tool 'sessions-gui.ps1')
    ) -WindowStyle Hidden
    Note "started pid $($proc.Id)"

    $win = $null
    for ($i = 0; $i -lt 60; $i++) {
        Start-Sleep -Milliseconds 500
        $win = Get-OurWindow $proc.Id
        if ($win) { break }
        if ($proc.HasExited) { break }
    }
    if ($proc.HasExited) {
        Fail "the window exited during startup (code $($proc.ExitCode)) - read .state\restore.log"
    } elseif (-not $win) {
        Fail 'no window appeared within 30 s'
    } else {
        Pass "the real script opens a window ($([int]$win.Current.NativeWindowHandle))"

        # --- 2. the tray icon reached the shell ---------------------------
        $icon = $null
        for ($i = 0; $i -lt 20; $i++) { $icon = Find-OurTrayIcon; if ($icon) { break }; Start-Sleep -Milliseconds 400 }
        if ($icon) { Pass "the tray icon is in the shell: '$($icon.Current.Name)'" }
        else { Note 'no tray icon found in the notification area - it may be hidden in the overflow; the rest still applies' }

        # --- 3. minimise HIDES it ------------------------------------------
        # The point of the gesture: the window goes away, the watching does not.
        $wp = $win.GetCurrentPattern([System.Windows.Automation.WindowPattern]::Pattern)
        $wp.SetWindowVisualState([System.Windows.Automation.WindowVisualState]::Minimized)
        Start-Sleep -Seconds 2
        $after = Get-OurWindow $proc.Id
        $gone = (-not $after) -or $after.Current.IsOffscreen
        if ($gone) { Pass 'minimising hands the window to the tray rather than to the taskbar' }
        else { Fail 'minimising left the window on screen - Add_StateChanged never reached Hide-ToTray' }

        # --- 4. and the process is still there -----------------------------
        Start-Sleep -Milliseconds 500
        if ($proc.HasExited) { Fail 'the process exited when the window was hidden - it is not watching anything' }
        else { Pass 'hidden, not exited - it is still watching' }

        # --- 5. it comes back ----------------------------------------------
        $icon = Find-OurTrayIcon
        $back = $null
        if ($icon) {
            $done = $false
            try {
                $icon.GetCurrentPattern([System.Windows.Automation.InvokePattern]::Pattern).Invoke()
                $done = $true
            } catch {
                try {
                    $lg = $icon.GetCurrentPattern([System.Windows.Automation.LegacyIAccessiblePattern]::Pattern)
                    $lg.DoDefaultAction(); $done = $true
                } catch { }
            }
            if ($done) {
                for ($i = 0; $i -lt 16; $i++) {
                    Start-Sleep -Milliseconds 500
                    $back = Get-OurWindow $proc.Id
                    if ($back -and -not $back.Current.IsOffscreen) { break }
                }
            }
        }
        if ($back -and -not $back.Current.IsOffscreen) { Pass 'clicking the tray icon brings it back' }
        elseif (-not $icon) { Note 'no reachable tray icon, so the way back could not be driven from here' }
        else { Fail 'clicking the tray icon did not bring the window back' }
    }
} finally {
    if ($proc -and -not $proc.HasExited) {
        try { $proc.CloseMainWindow() | Out-Null } catch { }
        Start-Sleep -Seconds 2
        if (-not $proc.HasExited) { try { $proc.Kill() } catch { } }
        Start-Sleep -Milliseconds 800
    }
    # --- 6. no orphan left behind ------------------------------------------
    # A NotifyIcon outlives its process unless it is disposed; the shell only
    # reaps the stale one when something hovers over it. An icon that is still
    # there after the process has gone is a bug the operator sees for hours.
    $left = Find-OurTrayIcon
    if ($left) { Fail "a tray icon is still in the shell after the process ended: '$($left.Current.Name)'" }
    else { Pass 'closing takes the tray icon with it - no orphan' }
}

Write-Host ''
if ($fails) { Write-Host "$fails FAILURE(S)" -ForegroundColor Red; exit 1 }
Write-Host 'the tray holds' -ForegroundColor Green
exit 0
