# ===========================================================================
# THE 7 ms AUDIT - LANE: THE SESSIONS LIST AND THE PROJECT RAIL.
#
# The left-hand navigation: thirteen controls, measured against the 7.0 ms the
# real claude TUI takes to answer an arrow key. See tests/audit/CONTRACT.md.
#
# 🔴 SIX OF THESE THIRTEEN ARE INVISIBLE TO THE EXISTING PERF GATE. Its
# coverage regex (perf-driver.ps1:610) reads Click|SelectionChanged|TextChanged|
# KeyDown|Checked|MouseDoubleClick, and ListFold, ListOpen, RailFold, RailOpen,
# ListSort, RailSort, RailClear and RailOnlyLive are wired with
# MouseLeftButtonUp / MouseLeftButtonDown - so the map never named them and no
# bench ever ran them.
#
# 🔴 WHERE IT CAN, THIS RAISES THE REAL ROUTED EVENT rather than calling the
# body of the handler. A handler reached by hand is a handler whose wiring was
# never tested, and two of the traps this window already carries (ListBoxItem
# swallowing button-down; a heading that cannot be selected) are exactly the
# kind of thing a hand-called body cannot see.
#
# 🪤 FRESH EVENT ARGS PER RAISE, NEVER A REUSED INSTANCE. Every one of these
# handlers ends with $e.Handled = $true, and re-raising the same args object
# means Handled is already true on the second raise - WPF then skips the
# handler and the bench measures an empty route at 0.02 ms. The construction
# cost is measured below as a control so it can be subtracted mentally: it is
# noise against a 7 ms bar.
#
# 🔴 NOTHING HERE LAUNCHES, KILLS, TYPES OR SAVES. The four fold carets DO write
# the operator's config (Invoke-ColumnFold -> Save-SRConfigValue), so they are
# GUARDED: the visible half is timed on the real functions, and the write is
# timed against a COPY of the config in the temp dir with $SR_ConfigPath
# repointed and restored. The operator's own file is never touched.
# ===========================================================================

$aLBar   = 7.0
$aLFrame = 16.0
$aLRes = New-Object System.Collections.Generic.List[object]

function aNote { param($aNm) Write-Host "        $aNm" -ForegroundColor DarkGray }
function aHead { param($aHm) Write-Host ''; Write-Host "--- $aHm ---" -ForegroundColor Cyan }

function aVerdictOf { param([double]$aVb, [string]$aVthrew)
    if ($aVthrew) { return 'THREW' }
    if ($aVb -le $aLBar) { return 'AT BAR' }
    if ($aVb -le $aLFrame) { return 'NEAR' }
    return 'OVER'
}

# Best of 15, per the contract: the fastest run is the only sample that got the
# CPU it asked for. Median and p90 are carried alongside because a control whose
# p90 is ten times its best is contending rather than costing.
function aBench {
    param([string]$aBName, [string]$aBCtl, [string]$aBHandler, [scriptblock]$aBDo, [scriptblock]$aBPre, [int]$aBRuns, [string]$aBForce)
    if ($aBRuns -le 0) { $aBRuns = 15 }
    $aBms = New-Object System.Collections.Generic.List[double]
    $aBthrew = ''
    for ($aBi = 0; $aBi -lt $aBRuns; $aBi++) {
        if ($aBPre) { try { & $aBPre | Out-Null } catch { } }
        $aBsw = [Diagnostics.Stopwatch]::StartNew()
        try { & $aBDo | Out-Null } catch { $aBthrew = "$($_.Exception.Message)" }
        $aBsw.Stop()
        $aBms.Add($aBsw.Elapsed.TotalMilliseconds)
    }
    $aBsorted = @($aBms | Sort-Object)
    $aBbest = [double]$aBsorted[0]
    $aBmed  = [double]$aBsorted[[int][Math]::Floor($aBsorted.Count / 2)]
    $aBp90  = [double]$aBsorted[[int][Math]::Min($aBsorted.Count - 1, [Math]::Ceiling($aBsorted.Count * 0.9) - 1)]
    $aBv = aVerdictOf $aBbest $aBthrew
    if ($aBForce) { $aBv = $aBForce }
    $aLRes.Add([PSCustomObject]@{
        Name = $aBName; Ctl = $aBCtl; Handler = $aBHandler
        Best = $aBbest; Med = $aBmed; P90 = $aBp90; First = [double]$aBms[0]
        Verdict = $aBv; Threw = $aBthrew; Runs = $aBRuns
    })
    $aBcol = 'DarkGray'
    if ($aBv -eq 'OVER' -or $aBv -eq 'THREW') { $aBcol = 'Yellow' } elseif ($aBv -eq 'NEAR') { $aBcol = 'Gray' }
    Write-Host ("  {0,-6} {1,9:N2} {2,9:N2} {3,9:N2}   {4}" -f $aBv, $aBbest, $aBmed, $aBp90, $aBName) -ForegroundColor $aBcol
    if ($aBthrew) { Write-Host ("         THREW: {0}" -f $aBthrew) -ForegroundColor Red }
    return $aBbest
}

function aSpin {
    $aSbest = [double]::MaxValue
    for ($aSr = 0; $aSr -lt 5; $aSr++) {
        $aSsw = [Diagnostics.Stopwatch]::StartNew()
        $aSacc = 0.0
        for ($aSi = 1; $aSi -lt 100000; $aSi++) { $aSacc += [Math]::Sqrt($aSi) }
        $aSsw.Stop()
        if ($aSsw.Elapsed.TotalMilliseconds -lt $aSbest) { $aSbest = $aSsw.Elapsed.TotalMilliseconds }
    }
    return $aSbest
}

# A fresh MouseButtonEventArgs, aimed at one of the events this lane's controls
# are wired with.
#
# 🪤 MouseLeftButtonDown/Up AND THEIR PREVIEWS ARE *DIRECT* ROUTED EVENTS - they
# do not bubble or tunnel. Raising one on a child therefore never reaches an
# ancestor's handler, and a bench built that way would measure an empty route
# and report 0.02 ms for a control it never ran. So:
#   - a handler attached to the element itself (every caret here) is raised
#     directly on that element, which is exactly what the input system does;
#   - the ListBox handler, which needs OriginalSource to be the ROW, is driven
#     through Mouse.PreviewMouseDownEvent - the tunnelling event real input
#     travels on, whose UIElement class handler cracks it into
#     PreviewMouseLeftButtonDown at each element with the row still as
#     OriginalSource.
# Every raise below is verified by its side effect before it is timed.
function aMouseArgs { param([string]$aMKind)
    $aMev = New-Object System.Windows.Input.MouseButtonEventArgs(
        [System.Windows.Input.Mouse]::PrimaryDevice, 0, [System.Windows.Input.MouseButton]::Left)
    if ($aMKind -eq 'up') { $aMev.RoutedEvent = [System.Windows.UIElement]::MouseLeftButtonUpEvent }
    elseif ($aMKind -eq 'pdown') { $aMev.RoutedEvent = [System.Windows.UIElement]::PreviewMouseLeftButtonDownEvent }
    elseif ($aMKind -eq 'tunnel') { $aMev.RoutedEvent = [System.Windows.Input.Mouse]::PreviewMouseDownEvent }
    else { $aMev.RoutedEvent = [System.Windows.UIElement]::MouseLeftButtonDownEvent }
    return $aMev
}
function aClick { param($aCEl, [string]$aCKind)
    $aCEl.RaiseEvent((aMouseArgs $aCKind))
}
function aItem { param([string]$aIid)
    return @($ui.SessionList.Items | Where-Object { "$($_.Id)" -eq $aIid })[0]
}

# ---------------------------------------------------------------------------
# The window, laid out, with the model built - the state every measurement below
# assumes.
# ---------------------------------------------------------------------------
$aLspinStart = aSpin
$aLbusyStart = @(Get-Process -Name 'claude' -ErrorAction SilentlyContinue).Count

Update-Model
$aLwide = 1480.0; $aLhigh = 980.0
$aLroot = $window.Content
function aLay {
    foreach ($aLp in 1, 2) {
        $aLroot.Measure((New-Object System.Windows.Size $aLwide, $aLhigh))
        $aLroot.Arrange((New-Object System.Windows.Rect 0, 0, $aLwide, $aLhigh))
        $aLroot.UpdateLayout()
        [System.Windows.Threading.Dispatcher]::CurrentDispatcher.Invoke(
            [System.Windows.Threading.DispatcherPriority]::Loaded, [action]{})
    }
}
# The sessions column on its own - what WPF actually re-lays out when the list's
# ItemsSource changes. Laying out the whole window would charge the list with the
# rail and the reading pane, which a rebuild does not touch.
function aLayList {
    $ui.ListPane.Measure((New-Object System.Windows.Size 420, 900))
    $ui.ListPane.Arrange((New-Object System.Windows.Rect 0, 0, 420, 900))
    $ui.ListPane.UpdateLayout()
}
function aLayRail {
    $ui.RailPane.Measure((New-Object System.Windows.Size 300, 900))
    $ui.RailPane.Arrange((New-Object System.Windows.Rect 0, 0, 300, 900))
    $ui.RailPane.UpdateLayout()
}

$ui.ModeWork.IsChecked = $true
Set-Surface 'work'
$ui.Search.Text = ''; $ui.RailSearch.Text = ''; $ui.ListSearch.Text = ''
$script:railPick = $null; $script:bandPick = $null; $script:railOnlyLive = $false
# The rail's age bands are a real operator setting and default to everything
# but TODAY folded, so an audit that did not own them would time a rail
# holding whichever projects happened to be touched since midnight.
$script:railBandShut = @{}
$script:listSort = 'recent'; $script:railSort = 'recent'
Build-Rail; Build-Sessions; aLay

$aLall = @($ui.SessionList.Items)
$aLsess = @($aLall | Where-Object { $_.Kind -eq 'session' })
$aLbands = @($aLall | Where-Object { $_.Kind -eq 'band' })
$aLrails = @($ui.RailList.Items | Where-Object { $_.Kind -eq 'project' })
aNote ("{0} conversations across {1} projects; the list holds {2} rows ({3} sessions, {4} headings), the rail {5} projects" -f `
       $script:model.Count, @($script:dirs).Count, $aLall.Count, $aLsess.Count, $aLbands.Count, $aLrails.Count)
aNote ("the machine: a fixed CPU loop took {0:N0} ms with {1} claude session(s) running" -f $aLspinStart, $aLbusyStart)
Write-Host ''
Write-Host ("  {0,-6} {1,9} {2,9} {3,9}   {4}" -f 'verdict', 'best', 'med', 'p90', 'what was measured') -ForegroundColor DarkCyan

# 🔴 THE BIGGEST CONVERSATION, not whichever row is second. Selection cost
# scales with the transcript in the tail, so the row the operator complains
# about is the big one. A small one is measured beside it for contrast.
$aLbig = $null; $aLsmall = $null; $aLbigId = ''; $aLsmallId = ''
if ($aLsess.Count -ge 2) {
    $aLsized = @($aLsess | Sort-Object -Property @{ Expression = {
        $aLjp = "$($_.Row.S.jsonl)"
        if ($aLjp -and (Test-Path -LiteralPath $aLjp)) { (Get-Item -LiteralPath $aLjp).Length } else { 0 }
    }} -Descending)
    $aLbig = $aLsized[0]
    $aLsmall = $aLsized[$aLsized.Count - 1]
    # 🔴 THE ID, NOT THE ITEM. Build-Sessions makes NEW item objects every time,
    # and assigning a ListBox a SelectedItem that is not in its current
    # ItemsSource silently selects nothing - the bench would then time an
    # assignment that fires no handler at all and call the click free.
    $aLbigId = "$($aLbig.Id)"; $aLsmallId = "$($aLsmall.Id)"
    $aLbigKB = 0; $aLsmallKB = 0
    try { $aLbigKB = (Get-Item -LiteralPath "$($aLbig.Row.S.jsonl)").Length / 1KB } catch { }
    try { $aLsmallKB = (Get-Item -LiteralPath "$($aLsmall.Row.S.jsonl)").Length / 1KB } catch { }
    aNote ("selection is profiled against '{0}' ({1:N0} KB of transcript) and '{2}' ({3:N0} KB)" -f `
           $aLbig.Name, $aLbigKB, $aLsmall.Name, $aLsmallKB)
}

# ===========================================================================
aHead 'the two search boxes and the header box - Search / ListSearch / RailSearch, TextChanged'
# ===========================================================================
# 🔑 A KEYSTROKE AND THE REBUILD IT CAUSES ARE TWO DIFFERENT COSTS AND ONLY ONE
# OF THEM IS THE HANDLER. TextChanged stops and restarts a 180 ms timer and
# returns; the rebuild happens on the tick. Both are measured, because the
# operator waits for both - the second one 180 ms later, on the UI thread.
$null = aBench 'Search: the TextChanged handler alone (stop+start the debounce timer)' 'Search' 'TextChanged' `
    { $script:searchTimer.Stop(); $script:searchTimer.Start() } $null 15 ''
$null = aBench 'Search: one keystroke (set .Text, WPF text machinery + the handler)' 'Search' 'TextChanged' `
    { $ui.Search.Text = 'kernel' } { $ui.Search.Text = '' } 15 ''
$ui.Search.Text = ''
$null = aBench 'ListSearch: one keystroke' 'ListSearch' 'TextChanged' `
    { $ui.ListSearch.Text = 'ker' } { $ui.ListSearch.Text = '' } 15 ''
$ui.ListSearch.Text = ''
$null = aBench 'RailSearch: one keystroke' 'RailSearch' 'TextChanged' `
    { $ui.RailSearch.Text = 'algo' } { $ui.RailSearch.Text = '' } 15 ''
$ui.RailSearch.Text = ''
Build-Rail; Build-Sessions

# The tick, which is what the letters actually cost. One timer, one handler, and
# it rebuilds BOTH panes whichever box was typed into.
$ui.Search.Text = 'kernel'
$aLtickHdr = aBench 'the debounced tick after typing in the HEADER box (Build-Rail + Build-Sessions)' 'Search' 'TextChanged' `
    { try { Build-Rail; Build-Sessions } catch { } } $null 15 ''
$ui.Search.Text = ''
Build-Rail; Build-Sessions

$ui.ListSearch.Text = 'ker'
$aLtickList = aBench 'the debounced tick after typing in the SESSIONS box (rebuilds the rail too)' 'ListSearch' 'TextChanged' `
    { try { Build-Rail; Build-Sessions } catch { } } $null 15 ''
$ui.ListSearch.Text = ''
Build-Rail; Build-Sessions

$ui.RailSearch.Text = 'algo'
$aLtickRail = aBench 'the debounced tick after typing in the PROJECTS box (rebuilds the sessions too)' 'RailSearch' 'TextChanged' `
    { try { Build-Rail; Build-Sessions } catch { } } $null 15 ''
$ui.RailSearch.Text = ''
Build-Rail; Build-Sessions

# 🔴 AND THE HALF OF THE TICK THAT CANNOT MATTER. The sessions box does not
# narrow the rail and the projects box does not narrow the list, but one timer
# serves all three boxes and rebuilds both panes every time.
$null = aBench 'of that tick: Build-Rail alone' 'ListSearch' 'TextChanged' { Build-Rail } $null 15 ''
$null = aBench 'of that tick: Build-Sessions alone' 'ListSearch' 'TextChanged' { Build-Sessions } $null 15 ''

# ===========================================================================
aHead 'the sort carets - ListSort / RailSort / RailOnlyLive, MouseLeftButtonDown'
# ===========================================================================
$aLargsCost = aBench 'CONTROL: constructing the event args a raise needs (subtract this)' '-' '-' `
    { aMouseArgs 'down' } $null 15 ''

$aLlistSortWas = $script:listSort
# VERIFY THE RAISE BEFORE TIMING IT. A raise that reaches no handler returns in
# 20 microseconds and looks like the fastest control in the window.
$script:listSort = 'recent'
aClick $ui.ListSort 'down'
aNote ("raise check - ListSort moved 'recent' -> '{0}' (it must not still say recent)" -f $script:listSort)
if ($script:listSort -eq 'recent') { Write-Host '  ListSort DID NOT MOVE - the raise never reached the handler' -ForegroundColor Red }
$script:listSort = $aLlistSortWas
$null = aBench 'ListSort: the caret, real routed event (cycle the key + Build-Sessions)' 'ListSort' 'MouseLeftButtonDown' `
    { aClick $ui.ListSort 'down' } $null 15 ''
foreach ($aLk in @('recent', 'name', 'project')) {
    $script:listSort = $aLk
    $null = aBench ("ListSort: landing on '{0}' (Build-Sessions under that order)" -f $aLk) 'ListSort' 'MouseLeftButtonDown' `
        { Build-Sessions } $null 15 ''
}
$script:listSort = $aLlistSortWas
$null = aBench 'of the sort click: Update-ListSortLabel alone' 'ListSort' 'MouseLeftButtonDown' `
    { Update-ListSortLabel } $null 15 ''

$aLrailSortWas = $script:railSort
$script:railSort = 'recent'
aClick $ui.RailSort 'down'
aNote ("raise check - RailSort moved 'recent' -> '{0}'" -f $script:railSort)
if ($script:railSort -eq 'recent') { Write-Host '  RailSort DID NOT MOVE - the raise never reached the handler' -ForegroundColor Red }
$script:railSort = $aLrailSortWas
$null = aBench 'RailSort: the caret, real routed event (cycle the key + Build-Rail)' 'RailSort' 'MouseLeftButtonDown' `
    { aClick $ui.RailSort 'down' } $null 15 ''
foreach ($aLk2 in @('recent', 'name', 'waiting', 'busiest')) {
    $script:railSort = $aLk2
    $null = aBench ("RailSort: landing on '{0}' (Build-Rail under that order)" -f $aLk2) 'RailSort' 'MouseLeftButtonDown' `
        { Build-Rail } $null 15 ''
}
$script:railSort = $aLrailSortWas
$null = aBench 'of the sort click: Update-RailLabels alone' 'RailSort' 'MouseLeftButtonDown' `
    { Update-RailLabels } $null 15 ''

$aLonlyWas = $script:railOnlyLive
$script:railOnlyLive = $false
aClick $ui.RailOnlyLive 'down'
aNote ("raise check - RailOnlyLive moved false -> {0}" -f $script:railOnlyLive)
if (-not $script:railOnlyLive) { Write-Host '  RailOnlyLive DID NOT TOGGLE - the raise never reached the handler' -ForegroundColor Red }
$script:railOnlyLive = $false
$null = aBench 'RailOnlyLive: all/running toggle, real routed event' 'RailOnlyLive' 'MouseLeftButtonDown' `
    { aClick $ui.RailOnlyLive 'down' } $null 16 ''
$script:railOnlyLive = $aLonlyWas
Update-RailLabels; Build-Rail

# ===========================================================================
aHead 'the rail - RailList SelectionChanged, RailClear MouseLeftButtonUp'
# ===========================================================================
if ($aLrails.Count -ge 1) {
    # 🪤 RE-RESOLVED EVERY TIME, for the same reason the sessions rows are: the
    # handler calls Build-Rail, which replaces every item object in the list.
    $null = aBench 'RailList: pick a project (SelectionChanged -> Build-Rail + Build-Sessions)' 'RailList' 'SelectionChanged' `
        { $ui.RailList.SelectedItem = $script:aLprojCur } `
        { $script:railPick = $null; $ui.RailList.SelectedIndex = -1
          # 🪤 THE FIRST ITEM IS AN AGE-BAND HEADING, and selecting one is
          # deliberately not a project pick - so timing it would measure a
          # gesture that does nothing and the raise check below would read
          # an empty railPick on a correct build.
          $script:aLprojCur = @($ui.RailList.Items | Where-Object { $_.Kind -eq 'project' })[0] } 15 ''
    aNote ("raise check - RailList selection left railPick = '{0}' (it must not be empty)" -f $script:railPick)
    $script:railPick = $null; $ui.RailList.SelectedIndex = -1
    Build-Rail; Build-Sessions

    $script:railPick = "$(@($script:dirs)[0].path)"
    aClick $ui.RailClear 'up'
    aNote ("raise check - RailClear left railPick = '{0}' (it must be empty)" -f $script:railPick)
    if ($script:railPick) { Write-Host '  RailClear DID NOTHING - the raise never reached the handler' -ForegroundColor Red }
    $null = aBench 'RailClear: the x, real routed event (clear the pick + both builds)' 'RailClear' 'MouseLeftButtonUp' `
        { aClick $ui.RailClear 'up' } `
        { $script:railPick = "$(@($script:dirs)[0].path)" } 15 ''
    $script:railPick = $null
    Build-Rail; Build-Sessions
} else {
    aNote 'no projects in the rail - RailList and RailClear cannot be measured'
}

# ===========================================================================
aHead 'the sessions list - PreviewMouseLeftButtonDown (the band headings)'
# ===========================================================================
# 🪤 THIS HANDLER RUNS ON EVERY LEFT-BUTTON-DOWN IN THE LIST, not only on a
# heading - so the row click pays it too, and returns from it. Both are timed.
$script:bandPick = $null
Build-Sessions; aLay
$aLrowC = $null; $aLbandC = $null
$aLnowSess = @($ui.SessionList.Items | Where-Object { $_.Kind -eq 'session' })
$aLnowBand = @($ui.SessionList.Items | Where-Object { $_.Kind -eq 'band' })
if ($aLnowSess.Count) { $aLrowC = $ui.SessionList.ItemContainerGenerator.ContainerFromItem($aLnowSess[0]) }
if ($aLnowBand.Count) { $aLbandC = $ui.SessionList.ItemContainerGenerator.ContainerFromItem($aLnowBand[0]) }

if ($aLrowC) {
    $null = aBench 'SessionList: button-down on a SESSION row (the tunnel tax every click pays)' 'SessionList' 'PreviewMouseLeftButtonDown' `
        { aClick $aLrowC 'tunnel' } $null 15 ''
    $null = aBench 'of that: Get-ClickedRow alone (walk the visual tree to the ListBoxItem)' 'SessionList' 'PreviewMouseLeftButtonDown' `
        { Get-ClickedRow $aLrowC } $null 15 ''
} else {
    aNote 'no realized session container - the row-click tax could not be raised as a real event'
}

if ($aLbandC) {
    # Toggling the band filter rebuilds the list, which throws away the very
    # container the event was raised on - so it is re-resolved every iteration
    # in the untimed Before, and bandPick is put back.
    $script:bandPick = $null
    aClick $aLbandC 'tunnel'
    aNote ("raise check - the heading click left bandPick = '{0}' (it must not be empty)" -f $script:bandPick)
    if (-not $script:bandPick) { Write-Host '  THE HEADING CLICK DID NOTHING - the raise never reached the handler' -ForegroundColor Red }
    $null = aBench 'SessionList: button-down on a BAND HEADING (filter to that band + Build-Sessions + Set-Status)' 'SessionList' 'PreviewMouseLeftButtonDown' `
        { aClick $script:aLbandCur 'tunnel' } `
        { $script:bandPick = $null; Build-Sessions; aLayList
          $script:aLbandCur = $ui.SessionList.ItemContainerGenerator.ContainerFromItem(
              @($ui.SessionList.Items | Where-Object { $_.Kind -eq 'band' })[0]) } 15 ''
    $script:bandPick = $null; Build-Sessions; aLay
} else {
    aNote 'no realized band container - the heading click could not be raised as a real event'
}

# ===========================================================================
aHead 'the sessions list - SelectionChanged, THE most-repeated gesture in the tool'
# ===========================================================================
if (-not $aLbig) { aNote 'not enough conversations to profile selection' }
else {
    # 🔴 COLD IS THE CLICK. $script:selId is what makes a selection "the same
    # one"; clearing it is what makes the next assignment do the work a click on
    # a different conversation does.
    # Proof the assignment fires the handler at all: selId is what Show-Selected
    # writes, and it is cleared before each run.
    $script:selId = $null; $ui.SessionList.SelectedIndex = -1
    $ui.SessionList.SelectedItem = (aItem $aLbigId)
    aNote ("raise check - selecting a row left selId = '{0}' (it must be the row's id)" -f $script:selId)
    if (-not $script:selId) { Write-Host '  SELECTING A ROW DID NOTHING - the item is not in the current ItemsSource' -ForegroundColor Red }

    $null = aBench 'SessionList: COLD select of the BIGGEST conversation (the click itself)' 'SessionList' 'SelectionChanged' `
        { $ui.SessionList.SelectedItem = $script:aLcur } `
        { $script:selId = $null; $ui.SessionList.SelectedIndex = -1; $script:aLcur = (aItem $aLbigId) } 15 ''
    $null = aBench 'SessionList: COLD select of the SMALLEST conversation' 'SessionList' 'SelectionChanged' `
        { $ui.SessionList.SelectedItem = $script:aLcur } `
        { $script:selId = $null; $ui.SessionList.SelectedIndex = -1; $script:aLcur = (aItem $aLsmallId) } 15 ''

    # Warm: the row is already the selected one. SelectionChanged does not fire
    # for a re-assignment of the same item, so this is the handler's body.
    $script:selId = $null
    $ui.SessionList.SelectedItem = (aItem $aLbigId)
    $null = aBench 'SessionList: WARM - the same row again (Show-Selected, the handler body)' 'SessionList' 'SelectionChanged' `
        { Show-Selected } $null 15 ''

    if ($aLbands.Count) {
        # A heading is not a target: the handler steps past it, which re-enters
        # itself and lands a full Show-Selected on the row below.
        $null = aBench 'SessionList: selecting a BAND HEADING (steps past it onto the next row)' 'SessionList' 'SelectionChanged' `
            { $ui.SessionList.SelectedItem = @($ui.SessionList.Items | Where-Object { $_.Kind -eq 'band' })[0] } `
            { $script:selId = $null; $ui.SessionList.SelectedIndex = -1 } 15 ''
    }

    # --- what the cold click is made of ------------------------------------
    $script:selId = $null
    $ui.SessionList.SelectedItem = (aItem $aLbigId)
    $null = aBench 'inside the click: Update-Chips $null (clear the vitals strip)' 'SessionList' 'SelectionChanged' `
        { Update-Chips $null } $null 15 ''
    $null = aBench 'inside the click: Update-SendState' 'SessionList' 'SelectionChanged' `
        { Update-SendState } $null 15 ''
    $null = aBench 'inside the click: Get-SelectedRow' 'SessionList' 'SelectionChanged' `
        { Get-SelectedRow } $null 15 ''
    # 🔴 THE RUNSPACE. Update-Document -> Start-DocParse opens a fresh runspace
    # ON THE UI THREAD on every cold selection, and stops the previous parse
    # first. This is the single biggest thing in the gesture.
    $null = aBench 'inside the click: Update-Document -> Start-DocParse (OPENS A RUNSPACE)' 'SessionList' 'SelectionChanged' `
        { Update-Document } $null 15 ''
    $null = aBench 'CONTROL: opening and closing a bare runspace, nothing else' '-' '-' `
        { $aLrs = [runspacefactory]::CreateRunspace(); $aLrs.ApartmentState = 'MTA'; $aLrs.ThreadOptions = 'ReuseThread'
          $aLrs.Open(); $aLrs.Close(); $aLrs.Dispose() } $null 15 ''
    # 🪤 A DIFFERENT PATH EVERY TIME, or it returns on its first line.
    $aLjA = "$($aLbig.Row.S.jsonl)"; $aLjB = "$($aLsmall.Row.S.jsonl)"
    $null = aBench 'inside the click: Start-TranscriptWatch (a new FileSystemWatcher)' 'SessionList' 'SelectionChanged' `
        { Start-TranscriptWatch $aLjA } { Start-TranscriptWatch $aLjB } 15 ''

    # --- and the document the click TRIGGERS, which is not the click --------
    # The parse is off-thread; the build is not. This is what the UI thread pays
    # one lane-tick after the click returns.
    $script:selId = $null
    $ui.SessionList.SelectedItem = (aItem $aLbigId)
    $aLwaited = 0
    while ($script:docHandle -and -not $script:docHandle.IsCompleted -and $aLwaited -lt 200) {
        [System.Threading.Thread]::Sleep(25); $aLwaited++
    }
    $aLdone = aBench 'AFTER the click: Complete-DocParse (build the FlowDocument, UI thread)' 'SessionList' 'SelectionChanged' `
        { Complete-DocParse } `
        { $script:docKey = ''; $script:docTurns = $null
          Start-DocParse "$($aLbig.Row.S.jsonl)"
          $aLw2 = 0
          while ($script:docHandle -and -not $script:docHandle.IsCompleted -and $aLw2 -lt 200) {
              [System.Threading.Thread]::Sleep(25); $aLw2++ } } 7 ''
    $null = aBench 'AFTER the click: laying the new document out (WPF measure/arrange)' 'SessionList' 'SelectionChanged' `
        { $ui.PaneDoc.Measure((New-Object System.Windows.Size 900, 600))
          $ui.PaneDoc.Arrange((New-Object System.Windows.Rect 0, 0, 900, 600))
          $ui.PaneDoc.UpdateLayout() } $null 7 ''
    Update-Document -Wait
}

# ===========================================================================
aHead 'what a rebuild is made of - the cost every one of the controls above shares'
# ===========================================================================
$null = aBench 'Build-Sessions with the sub-agent cache WARM (the usual case)' '-' '-' `
    { Build-Sessions } $null 15 ''
# 🔴 THE CACHE IS 20 SECONDS OLD AT MOST. Get-RowSubAgents touches the disk once
# per VISIBLE ROW, and the list rebuilds every 2.5 s - so roughly one rebuild in
# eight pays this, and the operator cannot tell which click it will be.
$null = aBench 'Build-Sessions with the sub-agent cache COLD (Get-RowSubAgents hits disk per row)' '-' '-' `
    { Build-Sessions } { $script:subAgents = @{} } 7 ''
$null = aBench 'laying the sessions column out after a rebuild' '-' '-' { aLayList } $null 15 ''
$null = aBench 'laying the projects column out after a rebuild' '-' '-' { aLayRail } $null 15 ''
# 🪤 UPDATE-STRIP RETURNS ON ITS FIRST LINE WHEN THE STRIP IS NOT ON SCREEN, so
# timing it in the normal state measures the guard and not the work. The fold
# caret makes the strip visible and THEN calls it, which is the only state in
# which it does anything.
$aLstripWas = $ui.ListStrip.Visibility
$ui.ListStrip.Visibility = $V_Show
$null = aBench 'Update-Strip with the strip actually on screen (what ListFold pays)' 'ListFold' 'MouseLeftButtonUp' `
    { Update-Strip } $null 15 ''
$ui.ListStrip.Visibility = $aLstripWas

# ===========================================================================
aHead 'INSIDE Build-Sessions - which call owns the 85 ms every control above pays'
# ===========================================================================
$script:railPick = $null; $script:bandPick = $null
$ui.Search.Text = ''; $ui.ListSearch.Text = ''; $ui.RailSearch.Text = ''
Build-Sessions
$aLkeep = New-Object System.Collections.Generic.List[object]
foreach ($aLm in $script:model) { if (Test-OnSurface $aLm) { $aLkeep.Add($aLm) } }
aNote ("the model holds {0} conversations; {1} of them are on this surface" -f $script:model.Count, $aLkeep.Count)
$null = aBench ("part 1: the filter loop - Test-OnSurface over all {0} conversations" -f $script:model.Count) '-' '-' `
    { $aLk2 = New-Object System.Collections.Generic.List[object]
      foreach ($aLm2 in $script:model) { if (Test-OnSurface $aLm2) { $aLk2.Add($aLm2) } } } $null 15 ''
$null = aBench 'part 2: Sort-SessionRows over the kept rows' '-' '-' `
    { Sort-SessionRows $aLkeep } $null 15 ''
$null = aBench ("part 3: Get-RowSubAgents x{0} (cache warm - a hashtable hit per row)" -f $aLkeep.Count) '-' '-' `
    { foreach ($aLm3 in $aLkeep) { $null = Get-RowSubAgents $aLm3 } } $null 15 ''
$null = aBench ("part 4: Get-RowScreenSig x{0}" -f $aLkeep.Count) '-' '-' `
    { foreach ($aLm4 in $aLkeep) { $null = Get-RowScreenSig "$($aLm4.Id)" } } $null 15 ''
$null = aBench ("part 5: Get-AgeTicks x{0}" -f $aLkeep.Count) '-' '-' `
    { foreach ($aLm5 in $aLkeep) { $null = Get-AgeTicks $aLm5.At } } $null 15 ''
$null = aBench ("part 6: Get-CtxBrush x{0}" -f $aLkeep.Count) '-' '-' `
    { foreach ($aLm6 in $aLkeep) { $null = Get-CtxBrush 100000 } } $null 15 ''
$null = aBench 'part 7: assigning ItemsSource (no rebuild, the same list back)' '-' '-' `
    { $ui.SessionList.ItemsSource = $ui.SessionList.ItemsSource } $null 15 ''
Build-Sessions

# ===========================================================================
aHead 'INSIDE Build-Rail - and why the caret costs 30 ms over six projects'
# ===========================================================================
$null = aBench ("Build-Rail part: Get-ProjectLabel x{0} projects" -f @($script:dirs).Count) '-' '-' `
    { foreach ($aLd in $script:dirs) { $null = Get-ProjectLabel "$($aLd.path)" } } $null 15 ''
$null = aBench ("Build-Rail part: Get-ProjectAccent x{0} projects (cache warm)" -f @($script:dirs).Count) '-' '-' `
    { foreach ($aLd2 in $script:dirs) { $null = Get-ProjectAccent "$($aLd2.path)" } } $null 15 ''
$null = aBench 'Build-Rail part: the Sort-Object that orders the projects' '-' '-' `
    { $null = @($script:model | Sort-Object { try { [datetime]$_.S.lastActive } catch { [datetime]0 } }) } $null 7 ''

# ===========================================================================
aHead 'the band click, and the Stop() nobody is counting'
# ===========================================================================
# The heading click measured far worse than the rebuild it performs, and the gap
# is not in Build-Sessions. Start-DocParse STOPS the parse already in flight
# before starting its own, and PowerShell.Stop() blocks the calling thread until
# that pipeline actually stops - so clicking again while a transcript is being
# read pays for the read being abandoned.
if ($aLbig) {
    $null = aBench 'Start-DocParse with NO parse in flight' '-' '-' `
        { Start-DocParse "$($aLbig.Row.S.jsonl)" } `
        { $aLw3 = 0
          while ($script:docHandle -and -not $script:docHandle.IsCompleted -and $aLw3 -lt 200) {
              [System.Threading.Thread]::Sleep(10); $aLw3++ }
          $null = Complete-DocParse } 7 ''
    $null = aBench 'Start-DocParse while the PREVIOUS parse is still running (it calls Stop())' '-' '-' `
        { Start-DocParse "$($aLbig.Row.S.jsonl)" } `
        { Start-DocParse "$($aLbig.Row.S.jsonl)" } 7 ''
    $null = aBench 'Build-Sessions with a band picked (fewer rows, same filter loop)' 'SessionList' 'PreviewMouseLeftButtonDown' `
        { Build-Sessions } { $script:bandPick = 'needs' } 15 ''
    # 🔴 THE SAME HANDLER, CALLED BY HAND FROM THE SAME START STATE. The routed
    # raise is not the cost - a tunnel down the identical route with no work at
    # the end of it (the session-row click above) is 0.9 ms - so if this reads
    # the same as the raise, everything in that quarter of a second is the
    # handler's own body.
    $null = aBench 'the band handler BY HAND from the unfiltered list (bandPick + Build-Sessions + Set-Status)' 'SessionList' 'PreviewMouseLeftButtonDown' `
        { $script:bandPick = 'needs'; Build-Sessions; Set-Status 'showing only needs you' } `
        { $script:bandPick = $null; Build-Sessions } 15 ''
    # 🔑 AND THE HALF OF IT NOBODY BUDGETED FOR. Filtering to one band drops the
    # open conversation out of the list, so Build-Sessions AUTO-SELECTS for you -
    # and an auto-selection goes down the same cold path a click does: a new
    # transcript parse, a new runspace, a new watcher.
    $aLselWas = $script:selId
    $null = aBench 'of that: the rebuild when the selection is DROPPED (auto-select fires a cold Show-Selected)' '-' '-' `
        { Build-Sessions } { $script:bandPick = 'needs'; $script:selId = 'no-such-conversation' } 15 ''
    $null = aBench 'the same rebuild with the selection STILL THERE (no auto-select)' '-' '-' `
        { Build-Sessions } { $script:bandPick = 'needs' } 15 ''
    $script:selId = $aLselWas
    $script:bandPick = $null
    # 🔴 AND THE DIFFERENCE THAT EXPLAINS THE REST OF IT - AND EVERY LIST NUMBER
    # IN THE EXISTING PERF SUITE. A rebuild assigns a new ItemsSource, and what
    # that costs depends on whether WPF currently has containers realized for
    # the old one. perf-driver lays the window out ONCE and then benches
    # Build-Sessions in a loop, so from its second run onward the list it
    # rebuilds has no containers at all - nothing to tear down, nothing to
    # regenerate. On screen the list is realized on every single rebuild. These
    # two lines are the same function over the same rows; only the layout pass
    # in the Before differs.
    $null = aBench 'Build-Sessions with the list REALIZED, as it always is on screen' '-' '-' `
        { Build-Sessions } { aLayList } 15 ''
    $null = aBench 'Build-Sessions with the list NOT realized (what the existing suite measures)' '-' '-' `
        { Build-Sessions } $null 15 ''
    $script:bandPick = $null
    Build-Sessions
    Update-Document -Wait
}

# 🔴 THE ONE THAT IS NOT IN ANY BUDGET: a rebuild that drops the selected row
# re-selects for you, and a re-selection is a COLD selection - transcript parse,
# runspace and all. Typing a letter that filters the open conversation away is
# therefore not a list rebuild, it is a list rebuild plus a click.
if ($aLbig -and $aLsmall -and $aLsess.Count -ge 3) {
    $aLterm = ''
    foreach ($aLc in $aLsess) {
        if ($aLc.Id -eq $aLbig.Id) { continue }
        $aLcand = "$($aLc.Name)".ToLower().Trim()
        if ($aLcand.Length -ge 6 -and "$($aLbig.Name)".ToLower() -notlike "*$($aLcand.Substring(0, 6))*") {
            $aLterm = $aLcand.Substring(0, 6); break
        }
    }
    if ($aLterm) {
        aNote ("the search term that drops the open conversation: '{0}'" -f $aLterm)
        $null = aBench 'the debounced tick when the typed letters DROP the open conversation' 'ListSearch' 'TextChanged' `
            { try { Build-Rail; Build-Sessions } catch { } } `
            { $ui.ListSearch.Text = ''; $script:selId = "$($aLbig.Id)"; Build-Sessions; $ui.ListSearch.Text = $aLterm } 7 ''
        $ui.ListSearch.Text = ''
        $script:selId = "$($aLbig.Id)"
        Build-Rail; Build-Sessions
    } else { aNote 'could not find a search term that excludes the open conversation - that path is unmeasured' }
}

# ===========================================================================
aHead 'the four fold carets - GUARDED (Invoke-ColumnFold writes the config)'
# ===========================================================================
# 🔴 NOT RAISED. RailFold/ListFold/RailOpen/ListOpen all call Invoke-ColumnFold,
# which calls Save-SRConfigValue - a real write to the operator's
# session-restore.config.json. Per the contract the handler is not invoked; what
# it does either side of the write is timed instead.
$aLfoldRailWas = $script:foldRail
$aLfoldListWas = $script:foldList
$aLfoldAppWas  = $script:foldApplied

$null = aBench 'ListFold/RailFold/ListOpen/RailOpen: Get-ColumnFold (the read half)' 'ListFold' 'MouseLeftButtonUp' `
    { Get-ColumnFold } $null 15 ''
# Update-Columns returns immediately when the state has not changed, so the
# Before flips the state that the timed call then applies. Collapsing the
# sessions column also builds the strip; opening it does not.
$null = aBench 'ListFold: Update-Columns COLLAPSING the sessions column (incl. Update-Strip)' 'ListFold' 'MouseLeftButtonUp' `
    { Update-Columns } { $script:foldList = $true; $script:foldApplied = 'xx' } 15 ''
$null = aBench 'ListOpen: Update-Columns OPENING the sessions column again' 'ListOpen' 'MouseLeftButtonUp' `
    { Update-Columns } { $script:foldList = $false; $script:foldApplied = 'xx' } 15 ''
$null = aBench 'RailFold: Update-Columns COLLAPSING the projects column' 'RailFold' 'MouseLeftButtonUp' `
    { Update-Columns } { $script:foldRail = $true; $script:foldApplied = 'xx' } 15 ''
$null = aBench 'RailOpen: Update-Columns OPENING the projects column again' 'RailOpen' 'MouseLeftButtonUp' `
    { Update-Columns } { $script:foldRail = $false; $script:foldApplied = 'xx' } 15 ''

$script:foldRail = $aLfoldRailWas
$script:foldList = $aLfoldListWas
$script:foldApplied = $aLfoldAppWas
Update-Columns
aLay

# The write itself, against a COPY. $SR_ConfigPath is repointed at a temp file
# holding the same JSON, so the same code path runs over the same content and
# the operator's file is never opened for writing.
$aLcfgWas = $SR_ConfigPath
$aLcfgTmp = Join-Path $env:TEMP ('sr-audit-list-{0}.json' -f ([guid]::NewGuid().ToString('N')))
try {
    Copy-Item -LiteralPath $SR_ConfigPath -Destination $aLcfgTmp -Force
    $SR_ConfigPath = $aLcfgTmp
    $null = aBench 'the write the fold carets do: Save-SRConfigValue (measured on a COPY)' 'ListFold' 'MouseLeftButtonUp' `
        { $null = Save-SRConfigValue -Name 'foldSessions' -Value $true } $null 15 ''
} finally {
    $SR_ConfigPath = $aLcfgWas
    Remove-Item -LiteralPath $aLcfgTmp -Force -ErrorAction SilentlyContinue
}
if ("$SR_ConfigPath" -ne "$aLcfgWas") { Write-Host '  the config path was NOT restored' -ForegroundColor Red }
else { aNote ("the config path is back to {0} and was never written" -f $SR_ConfigPath) }

# ===========================================================================
# THE TABLE
# ===========================================================================
$aLspinEnd = aSpin
$aLbusyEnd = @(Get-Process -Name 'claude' -ErrorAction SilentlyContinue).Count
Write-Host ''
Write-Host '=== the lane, slowest first ===' -ForegroundColor Cyan
foreach ($aLr in @($aLRes | Sort-Object -Property Best -Descending)) {
    $aLcol = 'DarkGray'
    if ($aLr.Verdict -eq 'OVER' -or $aLr.Verdict -eq 'THREW') { $aLcol = 'Yellow' } elseif ($aLr.Verdict -eq 'NEAR') { $aLcol = 'Gray' }
    Write-Host ("  {0,-6} {1,9:N2} {2,9:N2} {3,9:N2}   {4}" -f $aLr.Verdict, $aLr.Best, $aLr.Med, $aLr.P90, $aLr.Name) -ForegroundColor $aLcol
}
Write-Host ''
Write-Host '=== markdown ===' -ForegroundColor DarkCyan
# 🪤 NOT @($aLRes). The array subexpression throws "Argument types do not match"
# on a System.Collections.Generic.List[object] under PowerShell 5.1 - the trap
# this repo already documents beside $script:model.Count. It threw here on the
# first run of this driver, after every measurement had been taken.
foreach ($aLr2 in $aLRes) {
    Write-Host ("| {0} | {1} | {2} | {3:N1} | {4:N1} | {5:N1} | {6} | first run {7:N1} |" -f `
        $aLr2.Ctl, $aLr2.Handler, $aLr2.Name, $aLr2.Best, $aLr2.Med, $aLr2.P90, $aLr2.Verdict, $aLr2.First)
}
Write-Host ''
aNote ("the machine at the start: {0:N0} ms / {1} claude sessions. At the end: {2:N0} ms / {3} sessions." -f `
       $aLspinStart, $aLbusyStart, $aLspinEnd, $aLbusyEnd)
$aLatBar = @($aLRes | Where-Object { $_.Verdict -eq 'AT BAR' }).Count
$aLnear  = @($aLRes | Where-Object { $_.Verdict -eq 'NEAR' }).Count
$aLover  = @($aLRes | Where-Object { $_.Verdict -eq 'OVER' }).Count
$aLthrew = @($aLRes | Where-Object { $_.Verdict -eq 'THREW' }).Count
Write-Host ("  measurements: {0} at bar, {1} near, {2} over, {3} threw" -f $aLatBar, $aLnear, $aLover, $aLthrew) -ForegroundColor Cyan
exit 0
