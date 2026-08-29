# ===========================================================================
# EVERY OPERATION THE OPERATOR CAN CAUSE, TIMED.
#
# The gui2 suite profiles the three paths that were known to hurt. This one
# sweeps the whole surface, because the two worst stalls found so far were both
# in places nobody had thought to measure: a console read on the selection path
# (up to 6 s, and the existing profile stepped around it) and Get-Title running
# three times per row on a six-second timer. A benchmark that only covers what
# you already suspect cannot tell you anything you do not already know.
#
# 🔴 IT NEVER LAUNCHES, KILLS, TYPES OR SAVES. Every destructive operation is
# measured by asking what it WOULD do - Get-TickedPlan, Get-LaunchBlock,
# Build-Cast - never by doing it. Anything it changes it changes back.
#
# 🪤 BUDGETS ARE PER-CLASS AND DELIBERATELY LOOSE. An earlier perf assertion in
# this repo failed on 7 ms against 34 ms of identical code on a busy machine and
# had to be relaxed; a benchmark that cries wolf gets muted, and a muted
# benchmark catches nothing. The classes below are about what a human notices:
#   INSTANT  <  50 ms   a gesture with no perceptible delay
#   QUICK    < 250 ms   a click that feels immediate
#   SLOW     < 1000 ms  noticeable, acceptable only off the click path
#   STALL    >= 1000 ms the window is visibly frozen
# ===========================================================================

$fails = 0
function Fail { param($m) Write-Host "  FAIL  $m" -ForegroundColor Red; $script:fails++ }
function Note { param($m) Write-Host "        $m" -ForegroundColor DarkGray }

# Median of N, not a single sample: one GC or one antivirus scan makes a single
# measurement worthless, and the whole point here is a number worth acting on.
function Bench {
    param([string]$Name, [scriptblock]$Do, [string]$Class = 'QUICK', [int]$Runs = 3)
    $ms = New-Object System.Collections.Generic.List[double]
    for ($i = 0; $i -lt $Runs; $i++) {
        $sw = [Diagnostics.Stopwatch]::StartNew()
        try { & $Do | Out-Null } catch { Note ("  ! $Name threw: " + $_.Exception.Message) }
        $sw.Stop()
        $ms.Add($sw.Elapsed.TotalMilliseconds)
    }
    $sorted = @($ms | Sort-Object)
    $med = $sorted[[int]($sorted.Count / 2)]
    $script:Results.Add([PSCustomObject]@{ Name = $Name; Ms = $med; Class = $Class })
    return $med
}
$script:Results = New-Object System.Collections.Generic.List[object]

$LIMITS = @{ 'INSTANT' = 50.0; 'QUICK' = 250.0; 'SLOW' = 1000.0; 'STALL' = 100000.0 }

Update-Model
Note "$($script:model.Count) conversations across $(@($script:dirs).Count) projects"

$W = 1480.0; $H = 980.0
$root = $window.Content
function Lay {
    foreach ($p in 1, 2) {
        $root.Measure((New-Object System.Windows.Size $W, $H))
        $root.Arrange((New-Object System.Windows.Rect 0, 0, $W, $H))
        $root.UpdateLayout()
        [System.Windows.Threading.Dispatcher]::CurrentDispatcher.Invoke(
            [System.Windows.Threading.DispatcherPriority]::Loaded, [action]{})
    }
}
$ui.ModeWork.IsChecked = $true
Set-Surface 'work'
$ui.Search.Text = ''; $ui.RailSearch.Text = ''; $ui.ListSearch.Text = ''
$script:railPick = $null; $script:bandPick = $null
Build-Rail; Build-Sessions; Lay

# ---------------------------------------------------------------------------
Write-Host ''
Write-Host '--- the model, and the passes that run on a timer ---'
# ---------------------------------------------------------------------------
# Update-Model with NO arguments re-reads the registry and refreshes the agent
# map, which is what the window does when it has nothing handed to it. This is
# the single most expensive thing in the tool and it is why the probe exists.
$null = Bench 'Update-Model (full, hits disk + claude)' { Update-Model } 'SLOW' 2
$null = Bench 'Update-Model (probe handed the work in)' {
    Update-Model -Registry $script:reg -Agents $script:agents -Said @{}
} 'QUICK'
$null = Bench 'Update-ProjectLabels' { Update-ProjectLabels } 'INSTANT'
$null = Bench 'Get-ModelFingerprint (every 6 s)' { Get-ModelFingerprint } 'INSTANT'
$null = Bench 'Update-LiveWriters (every 6 s)' { Update-LiveWriters } 'INSTANT'
$null = Bench 'Invoke-FastPass (every 6 s)' { Invoke-FastPass } 'QUICK'

# ---------------------------------------------------------------------------
Write-Host ''
Write-Host '--- drawing the three lists ---'
# ---------------------------------------------------------------------------
$null = Bench 'Build-Sessions' { Build-Sessions } 'QUICK'
$null = Bench 'Build-Rail' { Build-Rail } 'QUICK'
$null = Bench 'Build-Manager' { Build-Manager } 'QUICK'
$null = Bench 'Set-Surface manage' { Set-Surface 'manage' } 'QUICK'
$null = Bench 'Set-Surface work' { Set-Surface 'work' } 'QUICK'
$null = Bench 'Set-Breakpoint' { Set-Breakpoint } 'INSTANT'
$null = Bench 'Update-Surface' { Update-Surface } 'QUICK'

# ---------------------------------------------------------------------------
Write-Host ''
Write-Host '--- searching, sorting and filtering ---'
# ---------------------------------------------------------------------------
# 🪤 Each of these is a KEYSTROKE, debounced but still on the UI thread.
$null = Bench 'search: header box (both panes)' {
    $ui.Search.Text = 'kernel'; Build-Rail; Build-Sessions
} 'QUICK'
$ui.Search.Text = ''
$null = Bench 'search: rail box only' { $ui.RailSearch.Text = 'algo'; Build-Rail } 'QUICK'
$ui.RailSearch.Text = ''; Build-Rail
$null = Bench 'search: sessions box only' { $ui.ListSearch.Text = 'ker'; Build-Sessions } 'QUICK'
$ui.ListSearch.Text = ''; Build-Sessions

foreach ($k in @('recent', 'name', 'project')) {
    $script:listSort = $k
    $null = Bench "sort sessions: $k" { Build-Sessions } 'QUICK'
}
$script:listSort = 'recent'
foreach ($k in @('recent', 'name', 'waiting', 'busiest')) {
    $script:railSort = $k
    $null = Bench "sort rail: $k" { Build-Rail } 'QUICK'
}
$script:railSort = 'recent'
$mgrSortWas = $script:mgrSort; $mgrDescWas = $script:mgrDesc
foreach ($k in @('logon', 'name', 'lane', 'said', 'age')) {
    $script:mgrSort = $k
    $null = Bench "sort manager: $k" { Build-Manager } 'QUICK'
}
$script:mgrSort = $mgrSortWas; $script:mgrDesc = $mgrDescWas
$mgrFilterWas = $script:mgrFilter
foreach ($k in @('all', 'ticked', 'running', 'needs')) {
    $script:mgrFilter = $k
    $null = Bench "filter manager: $k" { Build-Manager } 'QUICK'
}
$script:mgrFilter = $mgrFilterWas
$bandKeys = @($script:Bands | ForEach-Object { $_.Key })
$script:bandPick = $bandKeys[0]
$null = Bench 'filter sessions by band' { Build-Sessions } 'QUICK'
$script:bandPick = $null
$script:railOnlyLive = $true
$null = Bench 'filter rail to running only' { Build-Rail } 'QUICK'
$script:railOnlyLive = $false
$railPickWas = $script:railPick
$script:railPick = "$(@($script:dirs)[0].path)"
$null = Bench 'filter sessions by project (rail pick)' { Build-Sessions } 'QUICK'
$script:railPick = $railPickWas
Build-Rail; Build-Sessions

# ---------------------------------------------------------------------------
Write-Host ''
Write-Host '--- selecting a conversation, and its transcript ---'
# ---------------------------------------------------------------------------
$sessions = @($ui.SessionList.Items | Where-Object { $_.Kind -eq 'session' })
if ($sessions.Count -lt 2) { Note 'not enough conversations to profile selection' }
else {
    # 🔴 THE COLD PATH IS THE CLICK. $script:selId is what makes a selection
    # "the same one", and an earlier profile measured only the warm path and
    # reported 133 ms for a gesture that was taking seconds.
    $null = Bench 'select a conversation (COLD - the click)' {
        $script:selId = $null
        $ui.SessionList.SelectedItem = $sessions[1]
        Show-Selected
    } 'QUICK'
    $null = Bench 'select the same one again (warm)' { Show-Selected } 'INSTANT'
    $jp = "$($sessions[1].Row.S.jsonl)"
    $null = Bench 'parse the transcript tail' {
        $script:__b = Get-SRTranscriptBlocks -JsonlPath $jp -MaxRecords 220 -MaxTailBytes $script:tailBytes
    } 'QUICK'
    $null = Bench 'compress runs of tool calls' { Compress-ToolRuns $script:__b } 'INSTANT'
    $null = Bench 'build the FlowDocument' { Build-ReadDocument -Blocks $script:__b -Truncated $false } 'QUICK'
    $null = Bench 'Update-Document (parse + build + set)' { Update-Document } 'QUICK'
    $null = Bench 'Move-ToBottom' { Move-ToBottom } 'INSTANT'
    $null = Bench 'Test-AtBottom' { Test-AtBottom } 'INSTANT'
    $null = Bench 'Update-SendState' { Update-SendState } 'INSTANT'
    # 'load earlier' doubles the window - the one deliberate expensive gesture.
    $tw = $script:tailBytes
    $script:tailBytes = $tw * 2
    $null = Bench 'load earlier (double the tail)' { Update-Document } 'SLOW'
    $script:tailBytes = $tw
    Update-Document
}

# ---------------------------------------------------------------------------
Write-Host ''
Write-Host '--- the panels ---'
# ---------------------------------------------------------------------------
$null = Bench 'open the settings panel' { Show-Settings } 'QUICK'
$null = Bench 'close the settings panel' { Hide-Settings } 'INSTANT'
$null = Bench 'build the settings dropdowns' { Build-SettingDrops } 'QUICK'
$null = Bench 'permission note' { Update-PermNote } 'INSTANT'
$null = Bench 'open send-to-many' { Show-Cast } 'QUICK'
$null = Bench 'build the send-to-many list' { Build-Cast } 'QUICK'
Hide-Cast
$null = Bench 'read the skills off disk' { Get-SRSkills } 'SLOW' 1
$ui.SendBox.Text = '/re'
$null = Bench 'filter the skill picker' { Update-SkillPop } 'QUICK'
$ui.SendBox.Text = ''
Close-SkillPop
$fake = [PSCustomObject]@{
    Header = 'it is asking'; Question = 'Which way?'
    Options = @('One', 'Two', 'Three'); Details = @('a', 'b', 'c')
    Footer = 'Enter to confirm'; Multi = $false; Screen = ''
}
$null = Bench 'draw a pending question' { Show-Ask $fake } 'INSTANT'
Show-Ask $null

# ---------------------------------------------------------------------------
Write-Host ''
Write-Host '--- the logon plan, and what the buttons WOULD do ---'
# ---------------------------------------------------------------------------
$null = Bench 'Get-TickedPlan' { Get-TickedPlan } 'QUICK'
$null = Bench 'Limit-ToCap' { Limit-ToCap @($script:model.ToArray()) } 'INSTANT'
$null = Bench 'Get-SelectedRow' { Get-SelectedRow } 'INSTANT'
$row0 = @($script:model.ToArray())[0]
$null = Bench 'Get-LaunchBlock (would it launch?)' { Get-LaunchBlock $row0 } 'INSTANT'
$null = Bench 'Get-Band' { foreach ($r in $script:model) { $null = Get-Band $r } } 'INSTANT'
$null = Bench 'Get-Title for every conversation' {
    foreach ($r in $script:model) { $null = Get-Title $r.S $r.D }
} 'INSTANT'
$null = Bench 'Get-ProjectAccent (cold cache)' {
    $script:accentCache = @{}
    foreach ($d in $script:dirs) { $null = Get-ProjectAccent "$($d.path)" }
} 'INSTANT'

# ---------------------------------------------------------------------------
Write-Host ''
Write-Host '--- the library underneath ---'
# ---------------------------------------------------------------------------
$null = Bench 'Get-SRRegistry (read from disk)' { Get-SRRegistry } 'QUICK' 2
$null = Bench 'Get-SRAgentStatus -Refresh (spawns claude)' { Get-SRAgentStatus -Refresh } 'SLOW' 2
$liveOnes = @($script:model.ToArray() | Where-Object { $_.Live })
if ($liveOnes.Count) {
    $null = Bench "Get-SRLastSaid x$($liveOnes.Count) (what the probe does)" {
        foreach ($r in $liveOnes) { $null = Get-SRLastSaid -JsonlPath $r.S.jsonl }
    } 'SLOW'
}

# ---------------------------------------------------------------------------
Write-Host ''
Write-Host '=== the whole surface, slowest first ==='
# ---------------------------------------------------------------------------
$over = New-Object System.Collections.Generic.List[object]
foreach ($r in @($script:Results | Sort-Object -Property Ms -Descending)) {
    $lim = $LIMITS[$r.Class]
    $flag = ' '
    if ($r.Ms -gt $lim) { $flag = '!'; $over.Add($r) }
    Write-Host ("  {0} {1,8:N1} ms  {2,-8} {3}" -f $flag, $r.Ms, $r.Class, $r.Name) -ForegroundColor $(
        if ($r.Ms -gt $lim) { 'Yellow' } elseif ($r.Ms -gt $lim / 2) { 'Gray' } else { 'DarkGray' })
}

Write-Host ''
if ($over.Count) {
    Write-Host "  $($over.Count) operation(s) over their class budget:" -ForegroundColor Yellow
    foreach ($o in $over) {
        Write-Host ("    {0,8:N1} ms  {1} (budget {2:N0} ms for {3})" -f $o.Ms, $o.Name, $LIMITS[$o.Class], $o.Class)
    }
} else { Write-Host '  everything is inside its class budget' -ForegroundColor Green }

# 🔴 ONLY A STALL FAILS. Everything else is reported and left to judgement -
# see the note at the top about benchmarks that cry wolf.
$stalls = @($script:Results | Where-Object { $_.Ms -ge 1000 -and $_.Class -ne 'SLOW' -and $_.Class -ne 'STALL' })
Write-Host ''
if ($stalls.Count) {
    foreach ($s in $stalls) { Fail ("{0} takes {1:N0} ms - the window is visibly frozen for that long" -f $s.Name, $s.Ms) }
}
if ($fails) { Write-Host "$fails FAILURE(S)" -ForegroundColor Red; exit 1 }
Write-Host 'nothing on the surface stalls the window' -ForegroundColor Green
exit 0
