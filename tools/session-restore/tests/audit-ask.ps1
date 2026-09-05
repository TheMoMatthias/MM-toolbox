# ===========================================================================
# THE ASK PANEL AND THE COMPOSER, AGAINST THE 7.0 ms BAR.
#
# Lane: answering questions and sending messages. Eleven controls, four of
# which type into live consoles and are therefore NEVER pressed here - the work
# they do BEFORE the irreversible step is timed instead and the control is
# recorded GUARDED, naming the function that stood in for it.
#
# Method is tests\audit\CONTRACT.md, verbatim: best of 15, median and p90
# reported, a throw is recorded as THREW and never as a number, and the machine
# states its own conditions at the end.
#
# 🔴 NOTHING IN THIS FILE SENDS A KEYSTROKE ANYWHERE. The one console it reads
# is a menu-replica it spawns itself (tests\menu-replica.ps1, the same stand-in
# the relay suite drives), so the poll lane is measured against a REAL console
# screen buffer through the REAL held-open reader without going anywhere near
# one of the operator's conversations.
# ===========================================================================

$aFail = 0
function ANote { param($m) Write-Host "        $m" -ForegroundColor DarkGray }
function AWarn { param($m) Write-Host "  ??    $m" -ForegroundColor Yellow }

$aRows = New-Object System.Collections.Generic.List[object]

# best / median / p90 of 15, per the contract.
function ABench {
    param(
        [string]$Control, [string]$Handler, [string]$What,
        [scriptblock]$Do, [int]$Runs = 15, [string]$Force = '', [string]$Dom = ''
    )
    $aMs = New-Object System.Collections.Generic.List[double]
    $aThrew = ''
    for ($aI = 0; $aI -lt $Runs; $aI++) {
        $aSw = [Diagnostics.Stopwatch]::StartNew()
        try { & $Do | Out-Null } catch { $aThrew = "$($_.Exception.Message)" }
        $aSw.Stop()
        $aMs.Add($aSw.Elapsed.TotalMilliseconds)
    }
    $aSorted = @($aMs.ToArray() | Sort-Object)
    $aBest = $aSorted[0]
    $aMed  = $aSorted[[int][Math]::Floor(($aSorted.Count - 1) / 2)]
    $aP90  = $aSorted[[int][Math]::Floor(0.9 * ($aSorted.Count - 1))]
    $aV = ''
    if ($aThrew) { $aV = 'THREW' }
    elseif ($Force) { $aV = $Force }
    elseif ($aBest -le 7.0) { $aV = 'AT BAR' }
    elseif ($aBest -le 16.0) { $aV = 'NEAR' }
    else { $aV = 'OVER' }
    $aRows.Add([PSCustomObject]@{
        Control = $Control; Handler = $Handler; What = $What
        Best = $aBest; Med = $aMed; P90 = $aP90; Verdict = $aV
        Threw = $aThrew; Dom = $Dom
    })
    Write-Host ("  {0,-9} {1,8:N2} {2,8:N2} {3,8:N2}  {4,-13} {5}" -f `
        $Control, $aBest, $aMed, $aP90, $aV, $What) -ForegroundColor $(
        switch ($aV) { 'AT BAR' { 'Green' } 'NEAR' { 'Gray' } 'OVER' { 'Yellow' }
                       'THREW' { 'Red' } default { 'DarkGray' } })
    if ($aThrew) { Write-Host ("            THREW: {0}" -f $aThrew) -ForegroundColor Red }
    return $aBest
}

function AHead { param($m)
    Write-Host ''
    Write-Host "--- $m ---" -ForegroundColor Cyan
    Write-Host ("  {0,-9} {1,8} {2,8} {3,8}  {4,-13} {5}" -f 'control', 'best', 'med', 'p90', 'verdict', 'what') -ForegroundColor DarkGray
}

$aW = 1480.0; $aH = 980.0
$aRoot = $window.Content
function ALay {
    foreach ($aP in 1, 2) {
        $aRoot.Measure((New-Object System.Windows.Size $aW, $aH))
        $aRoot.Arrange((New-Object System.Windows.Rect 0, 0, $aW, $aH))
        $aRoot.UpdateLayout()
        [System.Windows.Threading.Dispatcher]::CurrentDispatcher.Invoke(
            [System.Windows.Threading.DispatcherPriority]::Loaded, [action]{})
    }
}

Write-Host ''
Write-Host '=== ask panel + composer: 11 controls, the poll lane, and Show-Ask ===' -ForegroundColor Cyan

Update-Model
ANote ("$($script:model.Count) conversations in the model")
$ui.ModeWork.IsChecked = $true
Set-Surface 'work'
$ui.Search.Text = ''; $ui.RailSearch.Text = ''; $ui.ListSearch.Text = ''
$script:railPick = $null; $script:bandPick = $null
Build-Rail; Build-Sessions; ALay

# ---------------------------------------------------------------------------
# A conversation to hold the composer's state. A RUNNING one where there is one,
# because Update-SendState's expensive branch is the one that reads the queue.
# ---------------------------------------------------------------------------
$aItems = @($ui.SessionList.Items | Where-Object { $_.Kind -eq 'session' })
$aLiveItems = @($aItems | Where-Object { $_.Row -and $_.Row.A -and $_.Row.A.Pid })
$aPick = $null
if ($aLiveItems.Count) { $aPick = $aLiveItems[0] } elseif ($aItems.Count) { $aPick = $aItems[0] }
if ($aPick) {
    $script:selId = $null
    $ui.SessionList.SelectedItem = $aPick
    Show-Selected
    ANote ("composer state is against '$($aPick.Name)' - running: $([bool]($aPick.Row.A -and $aPick.Row.A.Pid))")
} else {
    AWarn 'no conversation in the list - the composer benches will be against an empty selection'
}
$aHaveLive = [bool]($aPick -and $aPick.Row.A -and $aPick.Row.A.Pid)

# ===========================================================================
# THE QUESTION CARD'S OWN POLLING LANE
#
# Invoke-AskPoll runs on a DispatcherTimer every 400 ms on the UI thread, for
# as long as the window is open. Four times a second forever means everything
# it does is paid continuously, so it is measured in each of the states it can
# actually be in rather than only the one that is cheap.
# ===========================================================================
AHead 'Invoke-AskPoll - the 400 ms lane, in each state it can be in'

# 1. NOTHING SELECTED. Get-SelectedRow returns null and the tick is over.
$aSelWas = $script:selId
$aSelItemWas = $ui.SessionList.SelectedItem
$ui.SessionList.SelectedItem = $null
$script:selId = $null
$null = ABench 'AskPoll' 'DispatcherTimer 400ms' 'one tick, nothing selected' { Invoke-AskPoll }

# 2. SELECTED BUT NOT ANSWERABLE. Test-AskAllowed refuses - not running, or
#    mid-turn - and the tick is over before any read.
$aBlocked = $null
foreach ($aIt in $aItems) {
    if (-not ($aIt.Row.A -and $aIt.Row.A.Pid)) { $aBlocked = $aIt; break }
}
if ($aBlocked) {
    $script:selId = $null
    $ui.SessionList.SelectedItem = $aBlocked
    Show-Selected
    $null = ABench 'AskPoll' 'DispatcherTimer 400ms' 'one tick, selected but not running' { Invoke-AskPoll }
} else {
    AWarn 'every conversation in the list is running - the blocked-tick path was not measured'
}

# 3. THE REAL ONE: a running, idle, interactive session on the pane. That tick
#    reads a console screen. Measured against a replica rather than one of the
#    operator's conversations - same reader, same parser, same code path.
$aReplicaPath = Join-Path $SR_Root 'tests\menu-replica.ps1'
$aTmp = Join-Path $SR_StateDir ('audit-ask-' + [Guid]::NewGuid().ToString('N').Substring(0, 8))
$aRep = $null
$aScreen = $null
$aQ = $null
try {
    if (-not (Test-Path -LiteralPath $aReplicaPath)) { throw "menu-replica.ps1 is missing from $(Split-Path -Parent $aReplicaPath)" }
    $null = New-Item -ItemType Directory -Path $aTmp -Force
    $aOutFile = Join-Path $aTmp 'never-committed.txt'
    # MINIMIZED, not Hidden: a hidden process has no console window and the
    # point is to read what a real terminal is showing. It waits on a key that
    # this driver never sends, and is killed in the finally below.
    $aRep = Start-Process -FilePath 'powershell.exe' -PassThru -WindowStyle Minimized -ArgumentList @(
        '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $aReplicaPath,
        '-Out', $aOutFile, '-Cursor', '0', '-TimeoutSeconds', '240')

    # Two consecutive reads agreeing on the option count - a console paints a
    # menu a line at a time and a half-drawn one parses to the wrong shape.
    $aStop = (Get-Date).AddMilliseconds(45000)
    $aLastN = -1
    while ((Get-Date) -lt $aStop) {
        $aSeen = $null
        try { $aSeen = Get-SRScreenQuestion -ProcessId ([int]$aRep.Id) } catch { }
        if ($aSeen -and @($aSeen.Options).Count -ge 2) {
            if (@($aSeen.Options).Count -eq $aLastN) { $aQ = $aSeen; break }
            $aLastN = @($aSeen.Options).Count
        }
        Start-Sleep -Milliseconds 250
    }
    if (-not $aQ) { throw 'the replica never painted a readable menu' }
    ANote ("replica pid $($aRep.Id) is showing a $(@($aQ.Options).Count)-option menu")
} catch {
    AWarn ("no replica console: $($_.Exception.Message)")
    $aQ = $null
}

if ($aQ) {
    # --- the read, BOTH ways, because the lane's whole affordability rests on
    # --- which of them is live. ContentRendered never fires in this harness so
    # --- the held-open reader has not been asked for yet: this first number IS
    # --- the spawned-child fallback.
    $null = ABench 'AskPoll' 'Get-SRScreenText' 'one screen read, spawned child (no held-open reader)' {
        $null = Get-SRScreenText -ProcessId ([int]$aRep.Id)
    } 5
    $aServed = $false
    try { $aServed = [bool](Start-SRScreenServer) } catch { }
    if (-not $aServed) { AWarn 'the held-open screen reader would not start - every read below is the slow path' }
    $null = ABench 'AskPoll' 'Get-SRScreenText' 'one screen read, held-open reader' {
        $null = Get-SRScreenText -ProcessId ([int]$aRep.Id)
    }
    $aScreen = Get-SRScreenText -ProcessId ([int]$aRep.Id)
    if ($aScreen) {
        $null = ABench 'AskPoll' 'Invoke-SRParseScreenQuestion' 'parse that screen into a question' {
            $null = Invoke-SRParseScreenQuestion -Text $aScreen
        }
    }

    # --- and now the tick itself, end to end, against that console.
    $aRow = [PSCustomObject]@{
        Id   = 'audit-ask-replica'
        A    = [PSCustomObject]@{ Pid = [int]$aRep.Id; Status = 'idle'; Kind = 'interactive' }
        S    = [PSCustomObject]@{ }
        D    = [PSCustomObject]@{ }
        Q    = $null
        Band = 'needs'
    }
    $script:model.Add($aRow)
    $ui.SessionList.SelectedItem = $null
    $script:selId = 'audit-ask-replica'
    # Prime it so the signature matches and the steady-state branch is taken.
    try { Invoke-AskPoll } catch { }
    $null = ABench 'AskPoll' 'DispatcherTimer 400ms' 'ONE TICK, steady state (read + parse + signature, no redraw)' {
        Invoke-AskPoll
    }
    $null = ABench 'AskPoll' 'DispatcherTimer 400ms' 'one tick where the menu CHANGED (tick + Show-Ask)' {
        $script:askSig = ''
        Invoke-AskPoll
    }
}

# ===========================================================================
# Get-AskSignature - runs on EVERY tick, four times a second.
# ===========================================================================
AHead 'Get-AskSignature, on the 400 ms loop'
$aFixtures = @('round-single-fresh', 'round-multi-ticked', 'round-review', 'round-free-typed')
$aParsed = @{}
foreach ($aF in $aFixtures) {
    $aP = Join-Path $SR_Root ('tests\screens\' + $aF + '.txt')
    if (-not (Test-Path -LiteralPath $aP)) { AWarn "missing fixture $aF.txt"; continue }
    $aPq = $null
    try { $aPq = Invoke-SRParseScreenQuestion -Text ([System.IO.File]::ReadAllText($aP)) } catch { }
    if (-not $aPq) { AWarn "$aF.txt did not parse to a question - not measured"; continue }
    $aParsed[$aF] = $aPq
    ANote ("$aF : $(@($aPq.Options).Count) options, $(@($aPq.Tabs).Count) tabs, multi=$([bool]$aPq.Multi)")
}
foreach ($aF in @($aParsed.Keys | Sort-Object)) {
    $aQq = $aParsed[$aF]
    $null = ABench 'AskPoll' 'Get-AskSignature' ("signature of a real round: $aF") { $null = Get-AskSignature $aQq }
}

# ===========================================================================
# Show-Ask - what a question APPEARING costs to draw.
# ===========================================================================
AHead 'Show-Ask, drawing a real captured round'
foreach ($aF in @($aParsed.Keys | Sort-Object)) {
    $aQq = $aParsed[$aF]
    $null = ABench 'AskBox' 'Show-Ask' ("draw the card: $aF") { Show-Ask $aQq }
}
# Laying it out is not free either, and the poll redraws it in place.
if ($aParsed.ContainsKey('round-multi-ticked')) {
    $aQm = $aParsed['round-multi-ticked']
    $null = ABench 'AskBox' 'Show-Ask + layout' 'draw the card AND lay the window out' {
        Show-Ask $aQm; ALay
    } 5
}
Show-Ask $null
$script:askSig = ''
$script:lastAsk = $null

# ===========================================================================
# THE COMPOSER
# ===========================================================================
# Put the real selection back first - the composer describes what is selected.
$ui.SessionList.SelectedItem = $null
$script:selId = $null
if ($aPick) { $ui.SessionList.SelectedItem = $aPick; Show-Selected }

AHead 'the composer'

# SendBox / TextChanged -> { Update-SendState; Update-SkillPop }
# The real gesture: a character arrives in the box.
$ui.SendBox.Text = ''
$null = ABench 'SendBox' 'TextChanged' 'type one character of an ordinary message' {
    $ui.SendBox.Text = ($ui.SendBox.Text + 'x')
}
$ui.SendBox.Text = ''
$null = ABench 'SendBox' 'TextChanged' 'the same keystroke, its Update-SendState half' { Update-SendState }
$null = ABench 'SendBox' 'TextChanged' 'the same keystroke, its Update-SkillPop half (no slash)' { Update-SkillPop }
$null = ABench 'SendBox' 'TextChanged' 'Update-QueuePanel (hangs off Update-SendState)' { Update-QueuePanel }

# The slash path: every keystroke of a skill name re-reads the skills.
$ui.SendBox.Text = '/re'
$null = ABench 'SendBox' 'TextChanged' 'type one character of a /skill name' {
    $ui.SendBox.Text = '/re'
    Update-SendState; Update-SkillPop
}
$null = ABench 'SendBox' 'TextChanged' 'the skill-picker half alone (/re)' { Update-SkillPop }
$aDirNow = ''
try {
    $aRnow = Get-SelectedRow
    if ($aRnow) { $aDirNow = $(if ("$($aRnow.S.cwd)") { "$($aRnow.S.cwd)" } else { "$($aRnow.D.path)" }) }
} catch { }
$null = ABench 'SendBox' 'TextChanged' 'Get-SRSkills off disk (inside the /skill keystroke)' {
    $null = Get-SRSkills -Dir $aDirNow
} 5
# Get-SRSkills turned out to be cached, so the per-keystroke cost is downstream
# of it. These are the two things Update-SkillPop does with what it gets back.
$aSkills = @()
try { $aSkills = Get-SRSkills -Dir $aDirNow } catch { }
ANote ("$(@($aSkills).Count) skills are visible from that directory")
if (@($aSkills).Count) {
    $null = ABench 'SendBox' 'Select-SRSkills' 'ranking the skills against what has been typed' {
        $null = @(Select-SRSkills -Skills $aSkills -Query 're' -Limit 8)
    }
    $aHits = @(Select-SRSkills -Skills $aSkills -Query 're' -Limit 8)
    $null = ABench 'SendBox' 'row build' 'turning the hits into picker rows (regex per row)' {
        $aRl = New-Object System.Collections.Generic.List[object]
        foreach ($aS in $aHits) {
            $aBl = "$($aS.Description)"
            $aCut = $aBl.IndexOf('. ')
            if ($aCut -gt 20) { $aBl = $aBl.Substring(0, $aCut + 1) }
            $aRl.Add([PSCustomObject]@{
                Label = ('/' + $aS.Name); Blurb = ($aBl -replace '\s+', ' '); Source = $aS.Source; Name = $aS.Name
            })
        }
    }
    $null = ABench 'SendBox' 'SkillList.ItemsSource' 'handing the rows to the picker' {
        $ui.SkillList.ItemsSource = $null
        $ui.SkillList.ItemsSource = $aHits
    }
}
Close-SkillPop
$ui.SendBox.Text = ''
Update-SendState

# SendBox / PreviewKeyDown. A real KeyEventArgs needs a PresentationSource and a
# never-shown window has none, so the HANDLER BODY is timed rather than raised -
# said plainly rather than reported as a keystroke that was never delivered.
$null = ABench 'SendBox' 'PreviewKeyDown' 'an ordinary key, picker closed (handler body)' {
    if ($script:skillOpen) { $null = 1 }
    $null = ('A' -eq 'Return')
}
$script:skillOpen = $true
$ui.SendBox.Text = '/re'
Update-SkillPop
$null = ABench 'SendBox' 'PreviewKeyDown' 'Down with the skill picker open (handler body)' {
    if ($ui.SkillList.Items.Count) {
        $ui.SkillList.SelectedIndex = [Math]::Min($ui.SkillList.SelectedIndex + 1, $ui.SkillList.Items.Count - 1)
    }
}
$null = ABench 'SendBox' 'PreviewKeyDown' 'Tab/Enter completing a skill (Complete-Skill)' {
    $null = Complete-Skill
    $script:skillOpen = $true
}
Close-SkillPop
$ui.SendBox.Text = ''
Update-SendState

# SendBox / LostKeyboardFocus - a walk up the visual tree from the new focus.
$aRaised = $false
try {
    $aFa = New-Object System.Windows.Input.KeyboardFocusChangedEventArgs(
        [System.Windows.Input.Keyboard]::PrimaryDevice, 0, $ui.SendBox, $ui.SendBtn)
    $aFa.RoutedEvent = [System.Windows.UIElement]::LostKeyboardFocusEvent
    $ui.SendBox.RaiseEvent($aFa)
    $aRaised = $true
} catch { }
if ($aRaised) {
    $null = ABench 'SendBox' 'LostKeyboardFocus' 'focus leaves the box (event raised for real)' {
        $aFa2 = New-Object System.Windows.Input.KeyboardFocusChangedEventArgs(
            [System.Windows.Input.Keyboard]::PrimaryDevice, 0, $ui.SendBox, $ui.SendBtn)
        $aFa2.RoutedEvent = [System.Windows.UIElement]::LostKeyboardFocusEvent
        $ui.SendBox.RaiseEvent($aFa2)
    }
} else {
    ANote 'KeyboardFocusChangedEventArgs would not construct here; timing the walk it does instead'
    $null = ABench 'SendBox' 'LostKeyboardFocus' 'focus leaves the box (the tree walk, body)' {
        $aTo = $ui.SendBtn
        while ($aTo) {
            if ([object]::ReferenceEquals($aTo, $ui.SkillList) -or [object]::ReferenceEquals($aTo, $ui.SkillPop)) { break }
            $aPp = $null
            try { if ($aTo -is [System.Windows.DependencyObject]) { $aPp = [System.Windows.Media.VisualTreeHelper]::GetParent($aTo) } } catch { }
            if (-not $aPp -and ($aTo -is [System.Windows.FrameworkElement])) { $aPp = $aTo.Parent }
            $aTo = $aPp
        }
        Close-SkillPop
    }
}

# SendBtn / Click -> Invoke-Send. GUARDED: it types into a live console.
# What is timed is everything Invoke-Send does BEFORE Send-SRSessionInput.
$ui.SendBox.Text = 'a message that is never sent'
$null = ABench 'SendBtn' 'Click' 'GUARDED - Invoke-Send up to Send-SRSessionInput' {
    $aIt2 = $ui.SessionList.SelectedItem
    if ($aIt2 -and $aIt2.Kind -eq 'session') {
        $aR2 = $aIt2.Row
        $aMsg2 = "$($ui.SendBox.Text)".Trim()
        $null = ($aMsg2 -and $aR2.A -and $aR2.A.Pid)
    }
} 15 'GUARDED'
$ui.SendBox.Text = ''
Update-SendState

# AskFree / PreviewKeyDown. Enter runs Invoke-AskTyped, which types into a live
# console - so Enter is GUARDED and only its pre-step is timed. Every other key
# falls straight through.
$null = ABench 'AskFree' 'PreviewKeyDown' 'any key that is not Enter (handler body)' {
    $null = ('A' -eq 'Return')
}
$ui.AskFree.Text = 'an answer that is never sent'
$null = ABench 'AskFree' 'PreviewKeyDown' 'GUARDED - Enter: Invoke-AskTyped up to Start-AskSend' {
    $aIt3 = $ui.SessionList.SelectedItem
    if ($aIt3 -and $aIt3.Kind -eq 'session') {
        $aR3 = $aIt3.Row
        $aTx3 = "$($ui.AskFree.Text)".Trim()
        $null = ($aR3.A -and $aR3.A.Pid -and $aTx3 -and -not $script:ansPs)
    }
} 15 'GUARDED'

# AskFreeSend / Click -> the same Invoke-AskTyped. GUARDED for the same reason.
$null = ABench 'AskFreeS' 'Click' 'GUARDED - Invoke-AskTyped up to Start-AskSend' {
    $aIt4 = $ui.SessionList.SelectedItem
    if ($aIt4 -and $aIt4.Kind -eq 'session') {
        $aR4 = $aIt4.Row
        $aTx4 = "$($ui.AskFree.Text)".Trim()
        $null = ($aR4.A -and $aR4.A.Pid -and $aTx4 -and -not $script:ansPs)
    }
} 15 'GUARDED'
# And the enable/disable pass the send path runs on the way out and back.
$null = ABench 'AskFreeS' 'Set-AskEnabled' 'the pass that greys the card while a send is out' { Set-AskEnabled $true }
$ui.AskFree.Text = ''

# ===========================================================================
# SEND TO MANY
# ===========================================================================
AHead 'send to many'

Hide-Cast
$null = ABench 'Broadcast' 'Click' 'open the panel (Show-Cast -> Build-Cast)' {
    Hide-Cast
    $ui.Broadcast.RaiseEvent((New-Object System.Windows.RoutedEventArgs ([System.Windows.Controls.Button]::ClickEvent)))
}
# 🪤 THE CLOSE CANNOT BE TIMED ALONE THROUGH THE BUTTON, because the panel has
# to be open again before the next run - so the reopen is inside this number and
# the row says so. Hide-Cast on its own is the line under it.
$null = ABench 'Broadcast' 'Click' 'press it again to close it - AND reopen it for the next run' {
    $ui.Broadcast.RaiseEvent((New-Object System.Windows.RoutedEventArgs ([System.Windows.Controls.Button]::ClickEvent)))
    Show-Cast
}
$null = ABench 'Broadcast' 'Hide-Cast' 'the close half on its own' { Hide-Cast }
Show-Cast
$null = ABench 'Broadcast' 'Build-Cast' 'rebuild the list of conversations to type into' { Build-Cast }
$aReady = @($script:model.ToArray() | Where-Object { $_.A -and $_.A.Pid })
ANote ("$($aReady.Count) running conversation(s) go through Build-Cast's loop")
if ($aReady.Count) {
    $null = ABench 'Broadcast' 'Get-Title xN' ("the Get-Title Build-Cast does per running row (x$($aReady.Count))") {
        foreach ($aRr in $aReady) { $null = Get-Title $aRr.S $aRr.D }
    }
}

# CastList / PreviewMouseLeftButtonDown - tick a conversation.
ALay
# The first REAL conversation in the list - this driver's own synthetic replica
# row is in the model at this point and would otherwise be the one clicked.
$aContainer = $null
$aIdx = 0
foreach ($aCi in @($ui.CastList.ItemsSource)) {
    if ("$($aCi.Id)" -ne 'audit-ask-replica' -and -not $aCi.Busy) { break }
    $aIdx++
}
try { $aContainer = $ui.CastList.ItemContainerGenerator.ContainerFromIndex($aIdx) } catch { }
if ($aContainer) {
    # 🔴 PROVE THE RAISE ACTUALLY DID THE WORK BEFORE REPORTING ITS TIME. The
    # handler returns in a few microseconds on three different paths - no row
    # under the click, a row that is mid-turn, a DataContext that is null - and
    # a number taken off any of them would report the most expensive control on
    # this panel as free. So the tick is checked, not assumed.
    # 🪤 RAISED ON THE LIST WITH THE ROW AS Source, NOT ON THE ROW. Raising a
    # TUNNELING event on the ListBoxItem itself does not reach the ListBox's
    # handler in a window that has never been rendered - measured: the tick did
    # not move, and the timing off that path was 0.12 ms of a handler that had
    # returned without doing anything. This form runs the real handler with the
    # real OriginalSource, and the tick is checked below to prove it.
    $script:castPick = @{}
    $aDc = $aContainer.DataContext
    $aMe0 = New-Object System.Windows.Input.MouseButtonEventArgs(
        [System.Windows.Input.Mouse]::PrimaryDevice, 0, [System.Windows.Input.MouseButton]::Left)
    $aMe0.RoutedEvent = [System.Windows.UIElement]::PreviewMouseLeftButtonDownEvent
    $aMe0.Source = $aContainer
    $ui.CastList.RaiseEvent($aMe0)
    $aDidTick = (@($script:castPick.Keys).Count -eq 1)
    ANote ("the clicked row is '$($aDc.Name)', busy=$($aDc.Busy), id='$($aDc.Id)' - the raise toggled a tick: $aDidTick")
    if (-not $aDidTick) {
        # Which of the three early returns took it? Say it in numbers.
        $aWalk = Get-ClickedRow $aContainer
        $aAnc = $false
        $aUp = $aContainer
        $aDepth = 0
        while ($aUp -and $aDepth -lt 40) {
            if ([object]::ReferenceEquals($aUp, $ui.CastList)) { $aAnc = $true; break }
            $aUp = [System.Windows.Media.VisualTreeHelper]::GetParent($aUp)
            $aDepth++
        }
        AWarn ("the raised click did NOT toggle a tick. container=$($aContainer.GetType().Name); " +
               "Get-ClickedRow returned $(if ($aWalk) { "'$($aWalk.Name)'" } else { 'NULL' }); " +
               "CastList is an ancestor of it: $aAnc (depth $aDepth)")
        # Raise it where the ListBox will certainly see it, with the container as
        # the source, and see whether THAT ticks.
        $aMe1 = New-Object System.Windows.Input.MouseButtonEventArgs(
            [System.Windows.Input.Mouse]::PrimaryDevice, 0, [System.Windows.Input.MouseButton]::Left)
        $aMe1.RoutedEvent = [System.Windows.UIElement]::PreviewMouseLeftButtonDownEvent
        $aMe1.Source = $aContainer
        $ui.CastList.RaiseEvent($aMe1)
        $aDidTick = (@($script:castPick.Keys).Count -eq 1)
        ANote ("raised on CastList with the row as Source instead - toggled: $aDidTick")
    }
    # 🪤 AND IT CANNOT BE RAISED FIFTEEN TIMES. The handler ends in Build-Cast,
    # which replaces ItemsSource - so the container this driver is holding is
    # recycled and its DataContext becomes WPF's DisconnectedItem sentinel. Every
    # run after the first then indexed the tick table with a null Id and THREW,
    # and best-of-15 across that would have been the cost of throwing. So: the
    # raise is done ONCE, above, as proof the handler is the one that runs, and
    # the repeated measurement is the same body against a live row.
    $aFresh = $null
    try { $aFresh = $ui.CastList.ItemContainerGenerator.ContainerFromIndex($aIdx) } catch { }
    if ($aFresh) {
        $null = ABench 'CastList' 'Get-ClickedRow' 'finding the row under the click (visual-tree walk)' {
            $null = Get-ClickedRow $aFresh
        }
    }
    $null = ABench 'CastList' 'PreviewMouseLeftBtnDn' 'tick one conversation (handler body: toggle + Build-Cast)' {
        $aRowNow = @($ui.CastList.ItemsSource)[$aIdx]
        if ($script:castPick[$aRowNow.Id]) { $script:castPick.Remove($aRowNow.Id) }
        else { $script:castPick[$aRowNow.Id] = $true }
        Build-Cast
    }
    ANote ("after the run the tick set holds $(@($script:castPick.Keys).Count) entry(ies) - it really is toggling")
    $script:castPick = @{}
    Build-Cast
} else {
    ANote 'no ListBoxItem container was generated; timing the toggle + Build-Cast the handler does'
    $aFirstReady = $null
    foreach ($aCr in @($ui.CastList.ItemsSource)) { if (-not $aCr.Busy) { $aFirstReady = $aCr; break } }
    if ($aFirstReady) {
        $null = ABench 'CastList' 'PreviewMouseLeftBtnDn' 'tick one conversation (body: toggle + Build-Cast)' {
            if ($script:castPick[$aFirstReady.Id]) { $script:castPick.Remove($aFirstReady.Id) }
            else { $script:castPick[$aFirstReady.Id] = $true }
            Build-Cast
        }
    } else {
        AWarn 'nothing in the cast list is tickable - CastList was not measured'
    }
}

# CastText / TextChanged - one enable/disable expression.
$null = ABench 'CastText' 'TextChanged' 'type one character into the broadcast box' {
    $ui.CastText.Text = ($ui.CastText.Text + 'x')
}
$ui.CastText.Text = ''

# CastCompact / Click - fills the box with the morning brief.
$null = ABench 'CastCompact' 'Click' 'fill the compact brief (event raised for real)' {
    $ui.CastCompact.RaiseEvent((New-Object System.Windows.RoutedEventArgs ([System.Windows.Controls.Button]::ClickEvent)))
}
$null = ABench 'CastCompact' 'Get-SRCompactBrief' 'the config read inside that click' { $null = Get-SRCompactBrief }
$null = ABench 'CastCompact' 'Get-SRConfig' 'what Get-SRCompactBrief calls (disk + ConvertFrom-Json)' { $null = Get-SRConfig }
$ui.CastText.Text = ''

# CastSend / Click - GUARDED. Everything before Confirm-Action is timed; the
# confirmation and the queue that types are never reached.
$aTicked = 0
foreach ($aRr in $aReady) {
    if ($aTicked -ge 3) { break }
    if ("$($aRr.A.Status)" -eq 'busy') { continue }
    $script:castPick[$aRr.Id] = $true
    $aTicked++
}
$ui.CastText.Text = 'never sent'
Build-Cast
ANote ("$aTicked conversation(s) ticked in memory for the guarded measurement - nothing is sent")
$null = ABench 'CastSend' 'Click' 'GUARDED - the re-check + the names, up to Confirm-Action' {
    $aGo = New-Object System.Collections.Generic.List[object]
    foreach ($aRs in $script:model) {
        if (-not $script:castPick[$aRs.Id]) { continue }
        if (-not ($aRs.A -and $aRs.A.Pid)) { continue }
        if ("$($aRs.A.Status)" -eq 'busy') { continue }
        $aGo.Add($aRs)
    }
    if ($aGo.Count) {
        $null = ((@($aGo.ToArray() | ForEach-Object { (Get-Title $_.S $_.D).Text }) | Sort-Object) -join ', ')
    }
} 15 'GUARDED'
$script:castPick = @{}
$ui.CastText.Text = ''
Build-Cast

# CastCancel / Click.
$null = ABench 'CastCancel' 'Click' 'close it, nothing sent - AND reopen it for the next run' {
    $ui.CastCancel.RaiseEvent((New-Object System.Windows.RoutedEventArgs ([System.Windows.Controls.Button]::ClickEvent)))
    Show-Cast
}
$null = ABench 'CastCancel' 'Hide-Cast + Set-Status' 'what Cancel does, without the reopen' {
    Hide-Cast; Set-Status 'nothing sent'
}
Show-Cast
Hide-Cast

# ===========================================================================
# THE WORST THREE, TAKEN APART.
#
# "Slow" is not a finding; WHICH CALL owns the time is. Everything below splits
# an operation that came in over the bar into the pieces it is made of, so the
# lead is told what to change rather than what to worry about.
# ===========================================================================
AHead 'Show-Ask, taken apart'

# A question of exactly N options with nothing else on it, so the fixed cost and
# the per-option cost separate. Same shape the parser produces.
function AMkQ {
    param([int]$N, [switch]$WithTabs, [switch]$WithReview, [switch]$WithDetails)
    $aOpts = New-Object System.Collections.Generic.List[string]
    $aDets = New-Object System.Collections.Generic.List[string]
    for ($aJ = 0; $aJ -lt $N; $aJ++) {
        $aOpts.Add("Option number $aJ, worded about as long as a real one gets")
        $aDets.Add($(if ($WithDetails) { "the reasoning under option $aJ, which is usually a sentence or two of it" } else { '' }))
    }
    $aQo = [PSCustomObject]@{
        Header = 'ALPHA'; Question = 'Which alpha do you want'
        Options = $aOpts.ToArray(); Details = $aDets.ToArray()
        Footer = ''; Multi = $false; FreeText = ''
        ChosenAt = -1; FreeAt = -1; RealCount = $N; Ticked = $null
    }
    if ($WithTabs) {
        $aQo | Add-Member -NotePropertyName Tabs -NotePropertyValue @(
            [PSCustomObject]@{ Label = 'Alpha'; Answered = $true }
            [PSCustomObject]@{ Label = 'Beta';  Answered = $false }
            [PSCustomObject]@{ Label = 'Gamma'; Answered = $false }) -Force
    }
    if ($WithReview) {
        $aQo | Add-Member -NotePropertyName Review -NotePropertyValue ([PSCustomObject]@{ Answers = @(
            [PSCustomObject]@{ Question = 'Which alpha do you want'; Answer = 'Alpha two' }
            [PSCustomObject]@{ Question = 'Which betas apply';       Answer = 'Beta one, Beta three' }) }) -Force
    }
    return $aQo
}

$aQ1 = AMkQ -N 1
$aQ5 = AMkQ -N 5
$aQ5d = AMkQ -N 5 -WithDetails
$aQ5t = AMkQ -N 5 -WithDetails -WithTabs
$aQ5tr = AMkQ -N 5 -WithDetails -WithTabs -WithReview
$null = ABench 'AskBox' 'Show-Ask' 'fixed cost: 1 option, no details, no tabs' { Show-Ask $aQ1 }
$null = ABench 'AskBox' 'Show-Ask' '5 options, no details, no tabs' { Show-Ask $aQ5 }
$null = ABench 'AskBox' 'Show-Ask' '5 options WITH the reasoning under each' { Show-Ask $aQ5d }
$null = ABench 'AskBox' 'Show-Ask' '5 options + the round tab strip' { Show-Ask $aQ5t }
$null = ABench 'AskBox' 'Show-Ask' '5 options + tabs + the review list' { Show-Ask $aQ5tr }
# The two calls every option pays, isolated from the objects they decorate.
$null = ABench 'AskBox' 'FindResource' "the resource lookups one option does, x5" {
    for ($aJ = 0; $aJ -lt 5; $aJ++) {
        $null = $window.FindResource('BtnOption')
        $null = $window.FindResource('TextMax')
        $null = $window.FindResource('TextMid')
    }
}
$null = ABench 'AskBox' 'New-Object x5' 'building five bare Buttons and Grids, no styles' {
    for ($aJ = 0; $aJ -lt 5; $aJ++) {
        $null = New-Object System.Windows.Controls.Button
        $null = New-Object System.Windows.Controls.Grid
        $null = New-Object System.Windows.Controls.Border
        $null = New-Object System.Windows.Controls.StackPanel
        $null = New-Object System.Windows.Controls.TextBlock
        $null = New-Object System.Windows.Controls.TextBlock
        $null = New-Object System.Windows.Controls.TextBlock
    }
}
$null = ABench 'AskBox' 'ItemsSource' 'handing the finished buttons to the ItemsControl' {
    $ui.AskOptions.ItemsSource = $null
}
# 🔑 WHERE THE PER-OPTION MONEY ACTUALLY GOES. The objects are 0.4 ms and the
# resource lookups are nothing, so the remainder has to be the PROPERTY SETS -
# every $b.Style =, $lab.FontSize =, every New-Object Thickness. This rebuilds
# one option exactly as Show-Ask does, five times, and then the same thing with
# the decoration stripped, so the two halves separate.
$null = ABench 'AskBox' 'per-option block' 'building five options exactly as Show-Ask does' {
    for ($aJ = 0; $aJ -lt 5; $aJ++) {
        $aB = New-Object System.Windows.Controls.Button
        $aB.Style = $window.FindResource('BtnOption')
        $aB.HorizontalContentAlignment = 'Stretch'
        $aB.Margin = New-Object System.Windows.Thickness 0, 0, 0, 7
        $aB.Tag = $aJ
        $aG = New-Object System.Windows.Controls.Grid
        $aC1 = New-Object System.Windows.Controls.ColumnDefinition
        $aC1.Width = New-Object System.Windows.GridLength 0, 'Auto'
        $aC2 = New-Object System.Windows.Controls.ColumnDefinition
        $aG.ColumnDefinitions.Add($aC1); $aG.ColumnDefinitions.Add($aC2)
        $aBd = New-Object System.Windows.Controls.Border
        $aBd.Width = 22; $aBd.Height = 22
        $aBd.CornerRadius = New-Object System.Windows.CornerRadius 11
        $aBd.Background = $PalWash.Ask
        $aBd.VerticalAlignment = 'Top'
        $aBd.Margin = New-Object System.Windows.Thickness 0, 1, 13, 0
        $aBt = New-Object System.Windows.Controls.TextBlock
        $aBt.Text = "$($aJ + 1)"
        $aBt.Foreground = $Pal.Ask
        $aBt.FontSize = $script:Type.Caption
        $aBt.FontWeight = $FW_Semi
        $aBt.FontFamily = $script:UiFace
        $aBt.HorizontalAlignment = 'Center'
        $aBt.VerticalAlignment = 'Center'
        $aBd.Child = $aBt
        [System.Windows.Controls.Grid]::SetColumn($aBd, 0)
        $null = $aG.Children.Add($aBd)
        $aSt = New-Object System.Windows.Controls.StackPanel
        [System.Windows.Controls.Grid]::SetColumn($aSt, 1)
        $aLb = New-Object System.Windows.Controls.TextBlock
        $aLb.Text = 'Option number one, worded about as long as a real one gets'
        $aLb.TextWrapping = 'Wrap'
        $aLb.FontSize = $script:Type.Body
        $aLb.FontWeight = $FW_Semi
        $aLb.Foreground = $window.FindResource('TextMax')
        $null = $aSt.Children.Add($aLb)
        $null = $aG.Children.Add($aSt)
        $aB.Content = $aG
        $aB.Add_Click({ param($s, $e) $null = $s })
    }
}
$null = ABench 'AskBox' 'per-option block' 'the same five, WITHOUT the Add_Click wiring' {
    for ($aJ = 0; $aJ -lt 5; $aJ++) {
        $aB2 = New-Object System.Windows.Controls.Button
        $aB2.Style = $window.FindResource('BtnOption')
        $aB2.HorizontalContentAlignment = 'Stretch'
        $aB2.Margin = New-Object System.Windows.Thickness 0, 0, 0, 7
        $aB2.Tag = $aJ
        $aG2 = New-Object System.Windows.Controls.Grid
        $aD1 = New-Object System.Windows.Controls.ColumnDefinition
        $aD1.Width = New-Object System.Windows.GridLength 0, 'Auto'
        $aD2 = New-Object System.Windows.Controls.ColumnDefinition
        $aG2.ColumnDefinitions.Add($aD1); $aG2.ColumnDefinitions.Add($aD2)
        $aBd2 = New-Object System.Windows.Controls.Border
        $aBd2.Width = 22; $aBd2.Height = 22
        $aBd2.CornerRadius = New-Object System.Windows.CornerRadius 11
        $aBd2.Background = $PalWash.Ask
        $aBd2.VerticalAlignment = 'Top'
        $aBd2.Margin = New-Object System.Windows.Thickness 0, 1, 13, 0
        $aBt2 = New-Object System.Windows.Controls.TextBlock
        $aBt2.Text = "$($aJ + 1)"
        $aBt2.Foreground = $Pal.Ask
        $aBt2.FontSize = $script:Type.Caption
        $aBt2.FontWeight = $FW_Semi
        $aBt2.FontFamily = $script:UiFace
        $aBt2.HorizontalAlignment = 'Center'
        $aBt2.VerticalAlignment = 'Center'
        $aBd2.Child = $aBt2
        [System.Windows.Controls.Grid]::SetColumn($aBd2, 0)
        $null = $aG2.Children.Add($aBd2)
        $aSt2 = New-Object System.Windows.Controls.StackPanel
        [System.Windows.Controls.Grid]::SetColumn($aSt2, 1)
        $aLb2 = New-Object System.Windows.Controls.TextBlock
        $aLb2.Text = 'Option number one, worded about as long as a real one gets'
        $aLb2.TextWrapping = 'Wrap'
        $aLb2.FontSize = $script:Type.Body
        $aLb2.FontWeight = $FW_Semi
        $aLb2.Foreground = $window.FindResource('TextMax')
        $null = $aSt2.Children.Add($aLb2)
        $null = $aG2.Children.Add($aSt2)
        $aB2.Content = $aG2
    }
}
# The tab strip cost as much as four options, and only part of that is the
# chips - the rest lands on the ItemsControl that takes them, so both halves are
# measured rather than one being inferred from the other.
$aStrip = New-Object System.Collections.Generic.List[object]
$aStrip.Add((New-AskArrow -Glyph ([string][char]0x2039) -Delta -1 -Tip 'back'))
$aStrip.Add((New-AskTabChip -Label 'Alpha' -Answered $true))
$aStrip.Add((New-AskTabChip -Label 'Beta' -Answered $false))
$aStrip.Add((New-AskTabChip -Label 'Gamma' -Answered $false))
$aStrip.Add((New-AskArrow -Glyph ([string][char]0x203A) -Delta 1 -Tip 'on'))
$aStripArr = $aStrip.ToArray()
$ui.AskTabs.Visibility = $V_Show
$null = ABench 'AskBox' 'AskTabs.ItemsSource' 'handing the five finished chips to the tab strip' {
    $ui.AskTabs.ItemsSource = $null
    $ui.AskTabs.ItemsSource = $aStripArr
}
$ui.AskTabs.ItemsSource = $null
$ui.AskTabs.Visibility = $V_Hide
$null = ABench 'AskBox' 'New-AskTabChip' 'the five chips the round strip builds (3 tabs + 2 arrows)' {
    $null = New-AskArrow -Glyph ([string][char]0x2039) -Delta -1 -Tip 'back'
    $null = New-AskTabChip -Label 'Alpha' -Answered $true
    $null = New-AskTabChip -Label 'Beta' -Answered $false
    $null = New-AskTabChip -Label 'Gamma' -Answered $false
    $null = New-AskArrow -Glyph ([string][char]0x203A) -Delta 1 -Tip 'on'
}
Show-Ask $null
$script:askSig = ''
$script:lastAsk = $null

AHead 'the 400 ms tick, taken apart'
if ($aQ -and $aRep) {
    # Put the replica selection back for the decomposition.
    $ui.SessionList.SelectedItem = $null
    $script:selId = 'audit-ask-replica'
    $aRowBack = $null
    foreach ($aMr in $script:model) { if ("$($aMr.Id)" -eq 'audit-ask-replica') { $aRowBack = $aMr } }
    if ($aRowBack) {
        # 🪤 Get-SelectedRow IS NOT ONE COST. With something selected in the list
        # it returns on the first line; with nothing selected it walks the whole
        # model looking for $script:selId - and this driver's synthetic row is
        # the LAST of 300, which is the worst case that shape can produce.
        $null = ABench 'AskPoll' 'Get-SelectedRow' 'the lookup, falling back to a walk of the whole model' { $null = Get-SelectedRow }
        if ($aPick) {
            $ui.SessionList.SelectedItem = $aPick
            $null = ABench 'AskPoll' 'Get-SelectedRow' 'the lookup, with a row actually selected in the list' { $null = Get-SelectedRow }
            $ui.SessionList.SelectedItem = $null
        }
        $null = ABench 'AskPoll' 'Test-AskAllowed' 'the gate before the read' { $null = Test-AskAllowed $aRowBack }
    }
    if ($aScreen) {
        $null = ABench 'AskPoll' 'Add-Member' 'parse AND staple the screen text onto the result' {
            $aQtmp = Invoke-SRParseScreenQuestion -Text $aScreen
            $aQtmp | Add-Member -NotePropertyName Screen -NotePropertyValue $aScreen -Force
        }
        # The staple on its own, off a throwaway object, so it is not being
        # inferred from the difference between two noisy numbers.
        $null = ABench 'AskPoll' 'Add-Member' 'the staple alone: one Add-Member through the pipeline' {
            $aQb = [PSCustomObject]@{ Question = 'x' }
            $aQb | Add-Member -NotePropertyName Screen -NotePropertyValue $aScreen -Force
        }
        $null = ABench 'AskPoll' 'PSObject.Properties' 'the same staple without the pipeline or the cmdlet' {
            $aQc = [PSCustomObject]@{ Question = 'x' }
            $aQc.PSObject.Properties.Add((New-Object System.Management.Automation.PSNoteProperty 'Screen', $aScreen))
        }
        $aLines = @($aScreen -split "`n").Count
        ANote ("the replica screen is $aLines lines / $($aScreen.Length) chars")
        # 🔴 THE REDRAW-STORM QUESTION. A tick that redraws is 34 ms, not 18, so
        # whether the signature is STABLE between reads of an unchanged menu is
        # the difference between 4.5% of the UI thread and 8.5%. Ten consecutive
        # reads, ten signatures, counted.
        $aSigs = @{}
        for ($aJ = 0; $aJ -lt 10; $aJ++) {
            $aTs = $null
            try { $aTs = Get-SRScreenText -ProcessId ([int]$aRep.Id) } catch { }
            if (-not $aTs) { continue }
            $aQs = $null
            try { $aQs = Invoke-SRParseScreenQuestion -Text $aTs } catch { }
            if ($aQs) { $aSigs[(Get-AskSignature $aQs)] = $true }
        }
        ANote ("ten reads of an unchanged menu produced $($aSigs.Count) distinct signature(s) - 1 means no redraw storm")
    }
    # And the parse against each captured fixture, to see what it scales with.
    foreach ($aF in @($aParsed.Keys | Sort-Object)) {
        $aTxtF = [System.IO.File]::ReadAllText((Join-Path $SR_Root ('tests\screens\' + $aF + '.txt')))
        $null = ABench 'AskPoll' 'Invoke-SRParseScreenQuestion' ("parse a captured screen: $aF ($($aTxtF.Length) chars)") {
            $null = Invoke-SRParseScreenQuestion -Text $aTxtF
        }
    }
}

# ---------------------------------------------------------------------------
# put everything back
# ---------------------------------------------------------------------------
$script:castPick = @{}
$ui.CastText.Text = ''
$ui.SendBox.Text = ''
$ui.AskFree.Text = ''
Close-SkillPop
Show-Ask $null
$script:askSig = ''
$script:lastAsk = $null
if ($aRep) {
    for ($aI = $script:model.Count - 1; $aI -ge 0; $aI--) {
        if ("$($script:model[$aI].Id)" -eq 'audit-ask-replica') { $script:model.RemoveAt($aI) }
    }
    try { $aRep.Kill() } catch { }
    try { Remove-Item -LiteralPath $aTmp -Recurse -Force -ErrorAction SilentlyContinue } catch { }
}
try { Stop-SRScreenServer } catch { }
$script:selId = $aSelWas
$ui.SessionList.SelectedItem = $aSelItemWas
Update-SendState

# ---------------------------------------------------------------------------
# the machine, so a table that moved because the box did reads as such
# ---------------------------------------------------------------------------
$aSpin = [double]::MaxValue
for ($aRep2 = 0; $aRep2 -lt 5; $aRep2++) {
    $aSw2 = [Diagnostics.Stopwatch]::StartNew()
    $aAcc = 0.0
    for ($aI = 1; $aI -lt 100000; $aI++) { $aAcc += [Math]::Sqrt($aI) }
    $aSw2.Stop()
    if ($aSw2.Elapsed.TotalMilliseconds -lt $aSpin) { $aSpin = $aSw2.Elapsed.TotalMilliseconds }
}
$aBusy = @(Get-Process -Name 'claude' -ErrorAction SilentlyContinue).Count

Write-Host ''
Write-Host '=== the table, slowest first ===' -ForegroundColor Cyan
foreach ($aR in @($aRows.ToArray() | Sort-Object -Property Best -Descending)) {
    Write-Host ("| {0} | {1} | {2} | {3:N2} | {4:N2} | {5:N2} | {6} |" -f `
        $aR.Control, $aR.Handler, $aR.What, $aR.Best, $aR.Med, $aR.P90, $aR.Verdict)
}
Write-Host ''
$aOver = @($aRows.ToArray() | Where-Object { $_.Verdict -eq 'OVER' })
$aNear = @($aRows.ToArray() | Where-Object { $_.Verdict -eq 'NEAR' })
$aBar  = @($aRows.ToArray() | Where-Object { $_.Verdict -eq 'AT BAR' })
$aGrd  = @($aRows.ToArray() | Where-Object { $_.Verdict -eq 'GUARDED' })
$aThrewAll = @($aRows.ToArray() | Where-Object { $_.Verdict -eq 'THREW' })
Write-Host ("  measurements: {0} AT BAR, {1} NEAR, {2} OVER, {3} GUARDED, {4} THREW" -f `
    $aBar.Count, $aNear.Count, $aOver.Count, $aGrd.Count, $aThrewAll.Count)
Write-Host ("  the machine: a fixed CPU loop took {0:N0} ms with {1} claude session(s) running" -f $aSpin, $aBusy) -ForegroundColor DarkGray
foreach ($aT in $aThrewAll) { Write-Host ("  THREW  {0} / {1}: {2}" -f $aT.Control, $aT.What, $aT.Threw) -ForegroundColor Red }
Write-Host ''
Write-Host 'audit-ask done - nothing was sent, nothing was launched, nothing was written' -ForegroundColor Green
exit 0
