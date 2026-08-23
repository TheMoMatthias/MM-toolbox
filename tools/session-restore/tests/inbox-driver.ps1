#requires -Version 5.1
<#
    THE INBOX, driven through UI Automation against the real window.

    Behaviour, not pixels. The rendering assertions this project tried before
    were the ones that produced false greens -- most memorably a check that
    found the legend's text in the automation tree and called that "visible",
    when WPF keeps a Collapsed element in the tree flagged IsOffscreen. The
    screenshot disagreed with the test and the screenshot was right.

    So: IsOffscreen, never mere presence. And every assertion here is one that
    can actually go red -- each was watched failing before it was kept.
#>
[CmdletBinding()]
param([switch]$KeepOpen)

$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName UIAutomationClient, UIAutomationTypes

$here = $PSScriptRoot
if (-not $here) { $here = Split-Path -Parent $MyInvocation.MyCommand.Path }
$tool = Split-Path -Parent $here

$fails = 0
function Fail { param($m) Write-Host "  FAIL  $m" -ForegroundColor Red; $script:fails++ }
function Pass { param($m) Write-Host "  ok    $m" -ForegroundColor Green }
function Note { param($m) Write-Host "        $m" -ForegroundColor DarkGray }

# --- start it ---------------------------------------------------------------
$null = Start-Process -FilePath powershell.exe -PassThru -WindowStyle Hidden `
    -ArgumentList '-STA', '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "`"$tool\sessions-gui.ps1`""

$win = $null
$deadline = [DateTime]::UtcNow.AddSeconds(70)
while ([DateTime]::UtcNow -lt $deadline -and -not $win) {
    Start-Sleep -Milliseconds 900
    $ids = @(Get-CimInstance Win32_Process |
             Where-Object { $_.CommandLine -like '*sessions-gui.ps1*' } |
             Select-Object -ExpandProperty ProcessId)
    if (-not $ids) { Write-Host 'THE GUI DIED ON STARTUP' -ForegroundColor Red; exit 1 }
    foreach ($id in $ids) {
        $c = New-Object System.Windows.Automation.PropertyCondition(
            [System.Windows.Automation.AutomationElement]::ProcessIdProperty, [int]$id)
        $e = [System.Windows.Automation.AutomationElement]::RootElement.FindFirst(
            [System.Windows.Automation.TreeScope]::Children, $c)
        if ($e) { $win = $e; break }
    }
}
function Stop-Gui {
    Get-CimInstance Win32_Process |
        Where-Object { $_.CommandLine -like '*sessions-gui.ps1*' } |
        ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
}
if (-not $win) { Write-Host 'NO WINDOW APPEARED' -ForegroundColor Red; exit 1 }

# The opening pass reads every transcript and calls `claude agents --json`.
# Assert against a half-filled window and the failures mean nothing.
Start-Sleep -Seconds 26

function Lists {
    return $win.FindAll([System.Windows.Automation.TreeScope]::Descendants,
        (New-Object System.Windows.Automation.PropertyCondition(
            [System.Windows.Automation.AutomationElement]::ControlTypeProperty,
            [System.Windows.Automation.ControlType]::List)))
}
# The list the operator can actually see. Two exist; exactly one is on screen.
function ShownList {
    foreach ($l in Lists) { if (-not $l.Current.IsOffscreen) { return $l } }
    return $null
}
function RowsOf { param($l)
    if (-not $l) { return @() }
    return @($l.FindAll([System.Windows.Automation.TreeScope]::Children,
        [System.Windows.Automation.Condition]::TrueCondition))
}
function TextOnScreen { param([string]$Pattern)
    $all = $win.FindAll([System.Windows.Automation.TreeScope]::Descendants,
        (New-Object System.Windows.Automation.PropertyCondition(
            [System.Windows.Automation.AutomationElement]::ControlTypeProperty,
            [System.Windows.Automation.ControlType]::Text)))
    foreach ($t in $all) {
        if ("$($t.Current.Name)" -match $Pattern -and -not $t.Current.IsOffscreen) { return $true }
    }
    return $false
}
function ByName { param([string]$Name, $Type)
    $conds = New-Object System.Windows.Automation.AndCondition(
        (New-Object System.Windows.Automation.PropertyCondition(
            [System.Windows.Automation.AutomationElement]::NameProperty, $Name)),
        (New-Object System.Windows.Automation.PropertyCondition(
            [System.Windows.Automation.AutomationElement]::ControlTypeProperty, $Type)))
    return $win.FindFirst([System.Windows.Automation.TreeScope]::Descendants, $conds)
}
function Press { param($El)
    $El.GetCurrentPattern([System.Windows.Automation.InvokePattern]::Pattern).Invoke()
}

try {
    # --- 1. it opens ON the inbox -------------------------------------------
    $all = Lists
    if ($all.Count -ne 2) { Fail "expected 2 lists (tree + inbox), found $($all.Count)" }
    else { Pass 'the window carries both lists' }

    $shown = ShownList
    if (-not $shown) { Fail 'neither list is on screen' }
    $rows = RowsOf $shown
    if ($rows.Count -lt 1) { Fail 'the visible list is empty - nothing to assert against' }
    else { Pass "the visible list has $($rows.Count) row(s)" }

    # Exactly one visible. Two would mean the mode switch is not switching.
    $onScreen = @(Lists | Where-Object { -not $_.Current.IsOffscreen })
    if ($onScreen.Count -eq 1) { Pass 'exactly one list is on screen at a time' }
    else { Fail "$($onScreen.Count) lists are on screen at once" }

    # --- 2. the bands ------------------------------------------------------
    # At least one band must be present: the machine running this test has live
    # sessions by definition, since it is running the test.
    $bands = @('NEEDS YOU', 'WORKING', 'IDLE', 'NOT RUNNING') | Where-Object { TextOnScreen ([regex]::Escape($_)) }
    if ($bands.Count -ge 1) { Pass ("bands on screen: " + ($bands -join ', ')) }
    else { Fail 'no band heading is visible - the inbox is not grouping' }

    # --- 3. the tree's captions are NOT here -------------------------------
    # These name columns the inbox does not have. Their presence over inbox rows
    # is the "generic and unintuitive" complaint in its most literal form.
    foreach ($cap in @('LOGON', 'OPEN\?', 'TICKED')) {
        if (TextOnScreen $cap) { Fail "the tree caption '$cap' is showing over the inbox" }
        else { Pass "'$($cap -replace '\\','')' is not on screen in the inbox" }
    }

    # --- 4. the count pills are real buttons -------------------------------
    # They were Borders holding TextBlocks, which looked pressable and was not.
    $waitBtn = $null
    $btns = $win.FindAll([System.Windows.Automation.TreeScope]::Descendants,
        (New-Object System.Windows.Automation.PropertyCondition(
            [System.Windows.Automation.AutomationElement]::ControlTypeProperty,
            [System.Windows.Automation.ControlType]::Button)))
    foreach ($b in $btns) { if ("$($b.Current.Name)" -match 'waiting for you') { $waitBtn = $b; break } }
    if (-not $waitBtn) { Fail 'the "waiting for you" pill is not a button' }
    else {
        Pass 'the "waiting for you" pill is a button'
        Press $waitBtn
        Start-Sleep -Milliseconds 900
        Pass 'pressing it did not throw'
    }

    # --- 4b. the row action, and what it says it will do --------------------
    # A background agent has no terminal, so its button must be DISABLED rather
    # than present-and-failing. An offer the tool cannot keep is worse than no
    # offer: you press it, nothing happens, and you learn to distrust the row.
    $goTo = 0; $agentBtn = 0; $agentEnabled = 0
    foreach ($b in $btns) {
        $n = "$($b.Current.Name)"
        if ($b.Current.IsOffscreen) { continue }
        if ($n -eq 'Go to' -or $n -eq 'Open') { $goTo++ }
        if ($n -eq 'agent') { $agentBtn++; if ($b.Current.IsEnabled) { $agentEnabled++ } }
    }
    if ($goTo -ge 1) { Pass "$goTo row action button(s) on screen" }
    else { Fail 'no row has an action button' }
    if ($agentBtn -eq 0) { Note 'no background agent is running, so the disabled case is untested here' }
    elseif ($agentEnabled -eq 0) { Pass "$agentBtn background-agent row(s), all with the action disabled" }
    else { Fail "$agentEnabled background-agent row(s) offer an action that cannot work" }

    # --- 5. the view switch actually switches ------------------------------
    $tree = ByName 'All' ([System.Windows.Automation.ControlType]::RadioButton)
    $inbox = ByName 'Inbox' ([System.Windows.Automation.ControlType]::RadioButton)
    # TWO, not three. Restore was retired because it rendered row-for-row
    # identical rows to Projects; asserting that a retired view is still on
    # screen is asserting the duplication is still there.
    $restore = ByName 'Restore' ([System.Windows.Automation.ControlType]::RadioButton)
    if ($restore) { Fail 'the retired Restore view is still on screen' }
    elseif (-not $tree -or -not $inbox) { Fail 'the two view buttons are not both present' }
    else {
        Pass 'Inbox and All are present, and Restore is gone'

        # WHICH list is on screen, by position in the pair, not by identity.
        # Comparing runtime ids inline was a precedence trap: PowerShell parses
        # "$a -join ',' -eq $b -join ','" as "$a -join (',' -eq $b) -join ','",
        # so the comparison never ran and the assertion failed on a switch that
        # had plainly worked -- the LOGON check immediately below passed.
        function ShownIndex {
            $ls = Lists
            for ($i = 0; $i -lt $ls.Count; $i++) { if (-not $ls[$i].Current.IsOffscreen) { return $i } }
            return -1
        }
        $before = ShownIndex
        $tree.GetCurrentPattern([System.Windows.Automation.SelectionItemPattern]::Pattern).Select()
        Start-Sleep -Seconds 3
        $after = ShownIndex
        if ($before -ge 0 -and $after -ge 0 -and $before -ne $after) {
            Pass "switching to All swaps the visible list ($before to $after)"
        } else {
            Fail "switching to All did not change which list is showing (before=$before after=$after)"
        }

        # AND IT MUST HAVE CONTENT. Set-ViewMode swaps Visibility BEFORE it
        # rebuilds, so a rebuild that throws still passes the swap check and
        # leaves an empty list on screen. That is not hypothetical: a $c/$C
        # collision wiped the palette, every repaint threw on a null brush, and
        # this suite went green over a window showing nothing.
        $treeRows = RowsOf (ShownList)
        if ($treeRows.Count -ge 1) { Pass "the All list actually built ($($treeRows.Count) rows)" }
        else { Fail 'switched to All and the list is EMPTY - the rebuild threw' }

        # The status line is where a caught exception surfaces. If it is
        # reporting a failure, something threw whatever the rows look like.
        $bad = $false
        $texts2 = $win.FindAll([System.Windows.Automation.TreeScope]::Descendants,
            (New-Object System.Windows.Automation.PropertyCondition(
                [System.Windows.Automation.AutomationElement]::ControlTypeProperty,
                [System.Windows.Automation.ControlType]::Text)))
        foreach ($t in $texts2) {
            if ("$($t.Current.Name)" -match 'failed|null brush|Unable to find type' -and -not $t.Current.IsOffscreen) {
                Fail "the status line is reporting an error: '$($t.Current.Name)'"; $bad = $true
            }
        }
        if (-not $bad) { Pass 'nothing on screen is reporting an error' }

        # In Projects the tree's captions come BACK. This is the same assertion
        # as 3 with the answer inverted, which is what proves 3 was measuring
        # something real rather than looking for text that is never there.
        if (TextOnScreen 'LOGON') { Pass 'LOGON returns in the All view' }
        else { Fail 'LOGON is missing from the Projects view - assertion 3 proves nothing' }

        # The logon furniture used to be what made Restore a separate view. It
        # lives in All now, so this checks it is up HERE - and, below, that the
        # inbox still hides it. That pair is the whole of what Restore was.
        $launch = $null
        $btns = $win.FindAll([System.Windows.Automation.TreeScope]::Descendants,
            (New-Object System.Windows.Automation.PropertyCondition(
                [System.Windows.Automation.AutomationElement]::ControlTypeProperty,
                [System.Windows.Automation.ControlType]::Button)))
        foreach ($b in $btns) { if ("$($b.Current.Name)" -match 'Launch everything ticked') { $launch = $b; break } }
        if ($launch -and -not $launch.Current.IsOffscreen) { Pass 'All shows "Launch everything ticked"' }
        else { Fail 'All does not show "Launch everything ticked" - the logon furniture did not follow the retired view' }

        $inbox.GetCurrentPattern([System.Windows.Automation.SelectionItemPattern]::Pattern).Select()
        Start-Sleep -Seconds 3
        if ($launch -and $launch.Current.IsOffscreen) { Pass 'the inbox hides "Launch everything ticked"' }
        elseif (-not $launch) { Note 'no launch button to re-check' }
        else { Fail 'the inbox is still showing "Launch everything ticked"' }

        # Back in the inbox, it must have rebuilt too -- the same trap in the
        # other direction.
        $backRows = RowsOf (ShownList)
        if ($backRows.Count -ge 1) { Pass "the inbox rebuilt on the way back ($($backRows.Count) rows)" }
        else { Fail 'switched back to the inbox and the list is EMPTY' }
    }
} finally {
    if (-not $KeepOpen) { Stop-Gui }
}

Write-Host ''
if ($fails) { Write-Host "$fails FAILURE(S)" -ForegroundColor Red; exit 1 }
Write-Host 'the inbox holds' -ForegroundColor Green
exit 0
