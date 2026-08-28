# Drive the GUI's list with the four keys nobody exercised: HOME, END, PAGEDOWN,
# PAGEUP. They were declared as "relying on WPF's built-in ListBox behaviour" --
# a reasonable thing to lean on and an unreasonable thing to ship untested, since
# WPF only gives a ListBox those keys if nothing upstream swallows them first, and
# this window has a global key handler.
#
# FIRST ATTEMPT WAS A BROKEN INSTRUMENT, not a broken GUI. It identified the
# selected row by AutomationElement.Name and looked up its index among the list's
# children. Every row's Name is the view-model type name, 'SRGui.Row', so the
# lookup matched child 0 every single time and could not register movement in any
# direction. It reported three failures that were entirely its own.
#
# This version measures two things that cannot collapse like that:
#   RuntimeId          uniquely identifies the selected element, so a change of
#                      selection is visible even when every row prints the same
#   VerticalScrollPercent   moves 0..100 regardless of virtualisation, which the
#                      realised-children count does NOT (only ~19 exist at a time)
# and it verifies keyboard focus is inside the window BEFORE trusting any of it,
# so "nothing happened" cannot be silently misread as "the key does nothing".
Add-Type -AssemblyName UIAutomationClient, UIAutomationTypes, System.Windows.Forms

$here = $PSScriptRoot
if (-not $here -and $MyInvocation.MyCommand.Path) { $here = Split-Path -Parent $MyInvocation.MyCommand.Path }
if (-not $here) { $here = (Get-Location).Path }
$dir = Split-Path -Parent $here
$fails = 0
function Fail { param($m) Write-Host "  FAIL  $m" -ForegroundColor Red; $script:fails++ }
function Pass { param($m) Write-Host "  ok    $m" -ForegroundColor Green }
function Note { param($m) Write-Host "  --    $m" -ForegroundColor DarkGray }

$p = Start-Process -FilePath powershell.exe -PassThru -WindowStyle Hidden `
    -ArgumentList '-STA','-NoProfile','-ExecutionPolicy','Bypass','-File',"`"$dir\sessions-gui.ps1`""
Write-Host "started pid $($p.Id)"

$win = $null
$deadline = [DateTime]::UtcNow.AddSeconds(60)
while ([DateTime]::UtcNow -lt $deadline -and $null -eq $win) {
    Start-Sleep -Milliseconds 800
    $ids = @(Get-CimInstance Win32_Process | Where-Object { $_.CommandLine -like '*sessions-gui.ps1*' } | Select-Object -ExpandProperty ProcessId)
    if (-not $ids) { Write-Host 'GUI process died'; exit 1 }
    foreach ($id in $ids) {
        $cond = New-Object System.Windows.Automation.PropertyCondition(
            [System.Windows.Automation.AutomationElement]::ProcessIdProperty, [int]$id)
        $e = [System.Windows.Automation.AutomationElement]::RootElement.FindFirst(
            [System.Windows.Automation.TreeScope]::Children, $cond)
        if ($e) { $win = $e; break }
    }
}
if (-not $win) { Write-Host 'NO WINDOW'; exit 1 }
$guiPid = $win.Current.ProcessId
Write-Host "window: '$($win.Current.Name)'  pid $guiPid"
Start-Sleep -Seconds 6

# THIS SUITE NEEDS A LIST THAT SCROLLS, so put the window in the All view
# before asserting anything. The window now opens on the INBOX, which lists only
# what is running -- 17 rows that fit on screen without scrolling -- so every
# scroll assertion below reported -1% and END "moved the selection but only
# scrolled to -1%". The keys were fine; the suite was aimed at the wrong list.
$modeCond = New-Object System.Windows.Automation.AndCondition(
    (New-Object System.Windows.Automation.PropertyCondition(
        [System.Windows.Automation.AutomationElement]::NameProperty, 'Session manager')),
    (New-Object System.Windows.Automation.PropertyCondition(
        [System.Windows.Automation.AutomationElement]::ControlTypeProperty,
        [System.Windows.Automation.ControlType]::RadioButton)))
$modeBtn = $win.FindFirst([System.Windows.Automation.TreeScope]::Descendants, $modeCond)
if ($modeBtn) {
    $modeBtn.GetCurrentPattern([System.Windows.Automation.SelectionItemPattern]::Pattern).Select()
    Start-Sleep -Seconds 3
    Write-Host "switched to the All view"
} else {
        # NOT A WARNING - A FAILURE. The button was renamed Projects -> All and this
    # fell back to the inbox, which fits on screen and therefore reports -1% for
    # every scroll assertion. That is EXACTLY the symptom the comment above
    # already describes, reproduced by a silent fallback, and it read as three
    # broken keyboard shortcuts for a day.
    Write-Host "FAIL  no 'Session manager' view button - this suite cannot test scrolling against a list that fits" -ForegroundColor Red
    exit 1
}

$listCond = New-Object System.Windows.Automation.PropertyCondition(
    [System.Windows.Automation.AutomationElement]::ControlTypeProperty,
    [System.Windows.Automation.ControlType]::List)

# THE VISIBLE list, not the first one found. The window now carries two -- the
# inbox and the project tree -- and only one is on screen at a time. FindFirst
# returned the hidden one, and SetFocus on a Collapsed element throws "Target
# element cannot receive focus", which reads like a broken window rather than
# like a test pointed at something nobody can see.
$list = $null
foreach ($l in $win.FindAll([System.Windows.Automation.TreeScope]::Descendants, $listCond)) {
    if (-not $l.Current.IsOffscreen) { $list = $l; break }
}
if (-not $list) { Write-Host 'no list control is on screen'; Stop-Process -Id $guiPid -Force; exit 1 }

function SelId {
    try {
        $sp  = $list.GetCurrentPattern([System.Windows.Automation.SelectionPattern]::Pattern)
        $sel = $sp.Current.GetSelection()
        if ($sel.Count -eq 0) { return 'none' }
        return ($sel[0].GetRuntimeId() -join '.')
    } catch { return 'err' }
}
function Scroll {
    try {
        $sc = $list.GetCurrentPattern([System.Windows.Automation.ScrollPattern]::Pattern)
        return [math]::Round($sc.Current.VerticalScrollPercent, 1)
    } catch { return -1 }
}
function FocusInWindow {
    try { return ([System.Windows.Automation.AutomationElement]::FocusedElement.Current.ProcessId -eq $guiPid) }
    catch { return $false }
}
function Press { param([string]$k) [System.Windows.Forms.SendKeys]::SendWait($k); Start-Sleep -Milliseconds 800 }

$list.SetFocus(); Start-Sleep -Milliseconds 500
$first = $list.FindFirst([System.Windows.Automation.TreeScope]::Children,
    [System.Windows.Automation.Condition]::TrueCondition)
$first.GetCurrentPattern([System.Windows.Automation.SelectionItemPattern]::Pattern).Select()
$list.SetFocus(); Start-Sleep -Milliseconds 500

# Before trusting a single key result: is the keyboard even pointed at this window?
if (-not (FocusInWindow)) {
    Write-Host ''
    Write-Host '  CANNOT TEST: keyboard focus is not inside the GUI window, so SendKeys' -ForegroundColor Yellow
    Write-Host '  is going somewhere else. Any "the key did nothing" result would be a' -ForegroundColor Yellow
    Write-Host '  statement about focus, not about the GUI. Reporting inconclusive.' -ForegroundColor Yellow
    Stop-Process -Id $guiPid -Force -ErrorAction SilentlyContinue
    exit 2
}
Pass 'keyboard focus is inside the GUI window'

# 🪤 FOCUS IS CHECKED ONCE ABOVE, AND FOCUS CAN LEAVE AFTERWARDS. Every
# assertion below reads "the selection did not move", which has two
# explanations and only one of them is a bug: the key did nothing, or the key
# went to a different window. Measured 2026-08-27 -- a sweep reported PAGEDOWN
# and DOWN as FAILURES on a build that had changed neither, in a run whose own
# RIGHT, END and HOME had already passed; two re-runs then gave PASS and
# INCONCLUSIVE. The driver already knows how to say "inconclusive" and was only
# saying it before the first keystroke.
#
# So a key that appears not to have worked re-asks the question it asked at the
# start. A false FAIL here is worse than a false INCONCLUSIVE: it sends somebody
# looking for a regression in code that is fine.
function FailKey {
    param([string]$m)
    if (-not (FocusInWindow)) {
        Write-Host ''
        Write-Host "  CANNOT TEST: focus left the GUI window part-way through, at: $m" -ForegroundColor Yellow
        Write-Host '  SendKeys went somewhere else, so this is a statement about the desktop' -ForegroundColor Yellow
        Write-Host '  and not about the GUI. Reporting inconclusive rather than a failure.' -ForegroundColor Yellow
        Stop-Process -Id $guiPid -Force -ErrorAction SilentlyContinue
        exit 2
    }
    Fail $m
}

# THE ROSTER OPENS FOLDED NOW, which is the whole point of it: 26 project rows on
# one screen instead of two hundred. That is a list which FITS, and this suite
# needs one that SCROLLS -- the comment at the top of this file records exactly
# what happens when it is aimed at a list that fits (every scroll assertion
# reports -1%, and three working keyboard shortcuts read as broken for a day).
#
# So open the first project with RIGHT, the documented fold key, which puts its
# hundred-odd conversations on the list. Two things proven for one keystroke: the
# fold key does what the help says, and everything below has something to scroll.
#
# AFTER THE FOCUS CHECK, deliberately. A key pressed before focus is confirmed
# would report "RIGHT did nothing" when the truth is that the keyboard was
# somewhere else entirely -- which is the trap this file already documents.
# 🪤 COUNT THE VIEWPORT, NOT THE ROWS. The list is VIRTUALIZED, so FindAll over
# its children returns only what is currently realised -- 18, whether the list
# holds 27 rows or 227. A row count cannot see a fold open at all.
# VerticalViewSize is the fraction of the list on screen, so it falls as the list
# grows, and it is computed from the real extent rather than from what has been
# realised.
function ViewSize {
    try { return [math]::Round($list.GetCurrentPattern(
        [System.Windows.Automation.ScrollPattern]::Pattern).Current.VerticalViewSize, 1) }
    catch { return -1 }
}
$vsShut = ViewSize
Press '{RIGHT}'
Start-Sleep -Seconds 1
$vsOpen = ViewSize
if ($vsShut -lt 0 -or $vsOpen -lt 0) {
    Write-Host 'FAIL  the roster list exposes no scroll pattern - nothing below can be measured' -ForegroundColor Red
    Stop-Process -Id $guiPid -Force -ErrorAction SilentlyContinue
    exit 1
}
if ($vsOpen -ge $vsShut) {
    Write-Host "FAIL  RIGHT did not open the group under the cursor - the list still shows $vsOpen% of itself (was $vsShut%)" -ForegroundColor Red
    Stop-Process -Id $guiPid -Force -ErrorAction SilentlyContinue
    exit 1
}
Pass "RIGHT opens the group under the cursor (the list went from showing $vsShut% of itself to $vsOpen%)"
$list.SetFocus(); Start-Sleep -Milliseconds 500

$s0 = SelId; $v0 = Scroll
Note "start          sel=$($s0.Substring(0,[Math]::Min(20,$s0.Length)))  scroll=$v0%"

Press '{END}'
$s1 = SelId; $v1 = Scroll
Note "after END      sel=$($s1.Substring(0,[Math]::Min(20,$s1.Length)))  scroll=$v1%"
if ($s1 -eq $s0) { FailKey 'END did not change the selection' }
elseif ($v1 -lt 90) { FailKey "END moved the selection but only scrolled to $v1%" }
else { Pass "END jumps to the end (scroll $v0% -> $v1%)" }

Press '{HOME}'
$s2 = SelId; $v2 = Scroll
Note "after HOME     sel=$($s2.Substring(0,[Math]::Min(20,$s2.Length)))  scroll=$v2%"
if ($s2 -ne $s0) { FailKey 'HOME did not return to the row END started from' }
elseif ($v2 -gt 1) { FailKey "HOME left the list scrolled to $v2%" }
else { Pass 'HOME jumps back to the top' }

Press '{PGDN}'
$s3 = SelId; $v3 = Scroll
Note "after PGDN     sel=$($s3.Substring(0,[Math]::Min(20,$s3.Length)))  scroll=$v3%"
if ($s3 -eq $s2) { FailKey 'PAGEDOWN did not move the selection' } else { Pass "PAGEDOWN moves down a page (scroll $v2% -> $v3%)" }

Press '{PGUP}'
$s4 = SelId; $v4 = Scroll
Note "after PGUP     sel=$($s4.Substring(0,[Math]::Min(20,$s4.Length)))  scroll=$v4%"
if ($s4 -ne $s2) { FailKey 'PAGEUP did not come back to where PAGEDOWN started' } else { Pass 'PAGEUP comes back' }

Press '{DOWN}'
$s5 = SelId
Press '{DOWN}'
$s6 = SelId
if ($s5 -eq $s4 -or $s6 -eq $s5) { FailKey 'DOWN did not move the selection one row at a time' }
else { Pass 'DOWN moves one row at a time' }

Press '{UP}'
if ((SelId) -ne $s5) { FailKey 'UP did not step back one row' } else { Pass 'UP steps back one row' }

Stop-Process -Id $guiPid -Force -ErrorAction SilentlyContinue
Write-Host ''
if ($fails) { Write-Host "$fails FAILURE(S)" -ForegroundColor Red; exit 1 }
Write-Host 'all keyboard-navigation tests passed' -ForegroundColor Green
exit 0
