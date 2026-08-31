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

# 🔴 THE MINIMUM OF N, NOT THE MEDIAN. This measured the median of 3, and on this
# machine that measures the LOAD, not the code: Build-Sessions read 207 ms and
# then 1,436 ms twenty minutes apart with the source untouched, because sixteen
# of the operator's own conversations were running. A median moves with every one
# of them.
#
# The fastest run is the only sample where the code got the CPU it asked for;
# everything above it is contention. That is the number you can act on, it is
# reproducible on a busy machine, and it can only ever UNDER-report a problem -
# if the best of seven is still over budget, the code is genuinely too slow.
#
# The spread is reported alongside it, because a huge gap between best and worst
# is itself a finding: it means the operation is fighting something.
function Bench {
    param([string]$Name, [scriptblock]$Do, [string]$Class = 'QUICK', [int]$Runs = 15)
    $ms = New-Object System.Collections.Generic.List[double]
    $threw = ''
    for ($i = 0; $i -lt $Runs; $i++) {
        $sw = [Diagnostics.Stopwatch]::StartNew()
        try { & $Do | Out-Null } catch { $threw = "$($_.Exception.Message)" }
        $sw.Stop()
        $ms.Add($sw.Elapsed.TotalMilliseconds)
    }
    $sorted = @($ms | Sort-Object)
    $best = $sorted[0]
    $worst = $sorted[$sorted.Count - 1]
    # 🔴 AN OPERATION THAT THREW HAS NO TIMING, IT HAS AN ERROR - and this used to
    # report one as the other. Compress-ToolRuns was renamed out of the window
    # months of edits ago and lives only in the orphaned old file; the bench kept
    # calling it, the exception was swallowed into a note, and the 92 ms cost of
    # THROWING SEVEN TIMES was printed in the table as a performance figure. A
    # benchmark that measures its own failures is worse than no benchmark.
    $script:Results.Add([PSCustomObject]@{ Name = $Name; Ms = $best; Worst = $worst; Class = $Class; Threw = $threw })
    return $best
}
$script:Results = New-Object System.Collections.Generic.List[object]

# GESTURE is the class with teeth. Everything the operator can DO - a click, a
# keystroke, a tab, a button - must return inside 50 ms, because that is the
# contract: no gesture ever waits for work. Anything that reads disk or spawns a
# process belongs off the interaction path, and is measured under the classes
# below as a warning only, since a scan takes the time a scan takes.
$LIMITS = @{ 'GESTURE' = 50.0; 'INSTANT' = 50.0; 'QUICK' = 250.0; 'SLOW' = 1000.0; 'STALL' = 100000.0 }



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
$mFull = Bench 'Update-Model (full, hits disk + claude)' { Update-Model } 'SLOW' 2
# 🔴 AND THE PATH THE OPERATOR ACTUALLY WAITS ON. The full call above is 1,091 ms
# and a thousand of that is `claude agents --json` spawned on the UI thread.
# FOUR gestures paid it - opening the window, Rescan, saving settings, and the
# refresh after a relaunch - and not one of them needed to: the live probe
# refreshes that list in the background anyway, so they reuse what it last
# brought back and kick it to correct them. This is what those four now cost.
$mKeep = Bench 'Update-Model (-KeepAgents: what a gesture pays)' { Update-Model -KeepAgents } 'SLOW' 3
# 🪤 TIERED AS WHAT IT IS. I first filed this as QUICK and it went red at 385 ms
# - the mislabel was mine, not the code's: this rebuilds the whole model over
# 200-odd conversations and was never a 250 ms operation. What matters is that
# it is decisively cheaper than paying for `claude agents --json` inline, so
# THAT is the assertion, and it can still go red if the saving is undone.
# 🪤 THE SAVING IN MILLISECONDS, NOT AS A RATIO. A ratio is a measure of the
# machine here, not of the code: the same pair read 370/924 and 586/965 minutes
# apart, so a 0.6 threshold passed once and failed once with nothing changed.
# What is being claimed is that a gesture no longer spawns claude, and that is
# worth several hundred milliseconds however loaded the box is.
if ($mFull -and $mKeep -and ($mFull - $mKeep) -lt 250) {
    Fail ("skipping the agent refresh saved only {0:N0} ms ({1:N0} against {2:N0}) - is it still spawning claude?" -f ($mFull - $mKeep), $mKeep, $mFull)
} elseif ($mFull -and $mKeep) {
    Note ("a gesture pays {0:N0} ms instead of {1:N0} - the agent list is not refreshed inline" -f $mKeep, $mFull)
}
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
$null = Bench 'Build-Sessions' { Build-Sessions } 'GESTURE'
$null = Bench 'Build-Rail' { Build-Rail } 'GESTURE'
$null = Bench 'Build-Manager' { Build-Manager } 'GESTURE'
$null = Bench 'Set-Surface manage' { Set-Surface 'manage' } 'GESTURE'
$null = Bench 'Set-Surface work' { Set-Surface 'work' } 'GESTURE'
$null = Bench 'Set-Breakpoint' { Set-Breakpoint } 'INSTANT'
$null = Bench 'Update-Surface' { Update-Surface } 'GESTURE'

# ---------------------------------------------------------------------------
Write-Host ''
Write-Host '--- searching, sorting and filtering ---'
# ---------------------------------------------------------------------------
# 🪤 Each of these is a KEYSTROKE, debounced but still on the UI thread.
$null = Bench 'search: header box (both panes)' {
    $ui.Search.Text = 'kernel'; Build-Rail; Build-Sessions
} 'GESTURE'
$ui.Search.Text = ''
$null = Bench 'search: rail box only' { $ui.RailSearch.Text = 'algo'; Build-Rail } 'GESTURE'
$ui.RailSearch.Text = ''; Build-Rail
$null = Bench 'search: sessions box only' { $ui.ListSearch.Text = 'ker'; Build-Sessions } 'GESTURE'
$ui.ListSearch.Text = ''; Build-Sessions

foreach ($k in @('recent', 'name', 'project')) {
    $script:listSort = $k
    $null = Bench "sort sessions: $k" { Build-Sessions } 'GESTURE'
}
$script:listSort = 'recent'
foreach ($k in @('recent', 'name', 'waiting', 'busiest')) {
    $script:railSort = $k
    $null = Bench "sort rail: $k" { Build-Rail } 'GESTURE'
}
$script:railSort = 'recent'
$mgrSortWas = $script:mgrSort; $mgrDescWas = $script:mgrDesc
foreach ($k in @('logon', 'name', 'lane', 'said', 'age')) {
    $script:mgrSort = $k
    $null = Bench "sort manager: $k" { Build-Manager } 'GESTURE'
}
$script:mgrSort = $mgrSortWas; $script:mgrDesc = $mgrDescWas
$mgrFilterWas = $script:mgrFilter
foreach ($k in @('all', 'ticked', 'running', 'needs')) {
    $script:mgrFilter = $k
    $null = Bench "filter manager: $k" { Build-Manager } 'GESTURE'
}
$script:mgrFilter = $mgrFilterWas
$bandKeys = @($script:Bands | ForEach-Object { $_.Key })
$script:bandPick = $bandKeys[0]
$null = Bench 'filter sessions by band' { Build-Sessions } 'GESTURE'
$script:bandPick = $null
$script:railOnlyLive = $true
$null = Bench 'filter rail to running only' { Build-Rail } 'GESTURE'
$script:railOnlyLive = $false
$railPickWas = $script:railPick
$script:railPick = "$(@($script:dirs)[0].path)"
$null = Bench 'filter sessions by project (rail pick)' { Build-Sessions } 'GESTURE'
$script:railPick = $railPickWas
Build-Rail; Build-Sessions

# ---------------------------------------------------------------------------
Write-Host ''
Write-Host '--- selecting a conversation, and its transcript ---'
# ---------------------------------------------------------------------------
$sessions = @($ui.SessionList.Items | Where-Object { $_.Kind -eq 'session' })
# 🔴 PROFILE THE BIGGEST CONVERSATION, NOT WHICHEVER IS SECOND IN THE LIST.
#
# This took $sessions[1] - an arbitrary row - and on one run that was a SEVEN
# BLOCK document. Timing the reading pane against seven blocks says nothing
# about the surface the operator actually complains about, and it is how a suite
# reports comfortable numbers for a window that is visibly slow. The lag lives
# in the long conversations, so the bench belongs there: cost here scales with
# how much transcript is in the tail, and the tail is capped, so the worst case
# is a conversation big enough to fill it.
if ($sessions.Count -ge 2) {
    $bySize = @($sessions | Sort-Object -Property @{ Expression = {
        $p = "$($_.Row.S.jsonl)"
        if ($p -and (Test-Path -LiteralPath $p)) { (Get-Item -LiteralPath $p).Length } else { 0 }
    }} -Descending)
    if (@($bySize).Count) {
        $biggest = $bySize[0]
        $bytes = 0
        try { $bytes = (Get-Item -LiteralPath "$($biggest.Row.S.jsonl)").Length } catch { }
        Note ("profiling against the largest conversation on this machine: '{0}', {1:N0} KB of transcript" -f $biggest.Name, ($bytes / 1KB))
        # Put it second so the existing benches below pick it up unchanged.
        $sessions = @($biggest) + @($sessions | Where-Object { $_.Id -ne $biggest.Id })
        $sessions = @($sessions[0], $sessions[0]) + @($sessions | Select-Object -Skip 1)
    }
}
if ($sessions.Count -lt 2) { Note 'not enough conversations to profile selection' }
else {
    # 🔴 THE COLD PATH IS THE CLICK. $script:selId is what makes a selection
    # "the same one", and an earlier profile measured only the warm path and
    # reported 133 ms for a gesture that was taking seconds.
    $null = Bench 'select a conversation (COLD - the click)' {
        $script:selId = $null
        $ui.SessionList.SelectedItem = $sessions[1]
        Show-Selected
    } 'GESTURE'
    $null = Bench 'select the same one again (warm)' { Show-Selected } 'INSTANT'
    $jp = "$($sessions[1].Row.S.jsonl)"
    $null = Bench 'parse the transcript tail' {
        $script:__b = Get-SRTranscriptBlocks -JsonlPath $jp -MaxRecords 220 -MaxTailBytes $script:tailBytes
    } 'QUICK'
    $null = Bench 'fold runs of tool calls into turns' { Get-ReadTurns $script:__b } 'GESTURE'
    $null = Bench 'build the FlowDocument' { Build-ReadDocument -Blocks $script:__b -Truncated $false } 'GESTURE'
    $null = Bench 'Update-Document (the gesture - kicks the parse)' { Update-Document } 'GESTURE'
    $null = Bench 'Update-Document -Wait (parse + build inline)' { Update-Document -Wait } 'QUICK'
    $null = Bench 'Move-ToBottom' { Move-ToBottom } 'INSTANT'
    $null = Bench 'Test-AtBottom' { Test-AtBottom } 'INSTANT'
    $null = Bench 'Update-SendState' { Update-SendState } 'INSTANT'
    # 'load earlier' doubles the window - the one deliberate expensive gesture.
    $tw = $script:tailBytes
    $script:tailBytes = $tw * 2
    $null = Bench 'load earlier (double the tail)' { Update-Document } 'GESTURE'
    $null = Bench 'load earlier, rendered inline' { Update-Document -Wait } 'SLOW'
    $script:tailBytes = $tw
    Update-Document -Wait
}

# ---------------------------------------------------------------------------
Write-Host ''
Write-Host '--- the document ON SCREEN: layout, scrolling, opening a block ---'
# ---------------------------------------------------------------------------
# 🔴 CONSTRUCTING A FLOWDOCUMENT IS NOT WHAT THE OPERATOR WAITS FOR, and this
# suite was measuring only the construction. A FlowDocument costs its real money
# in WPF's measure/arrange pass, and `FlowDocumentScrollViewer` DOES NOT
# VIRTUALIZE - every block in the conversation is realized whether or not it is
# on screen (the tail budget exists for exactly that reason; see the note beside
# $script:TailBase). So a bench that builds a document and never lays it out can
# report a comfortable number while the window is visibly slow to the person
# using it. That is what was happening: 'build the FlowDocument' was in the
# table all along and the lag was reported anyway.
#
# Scrolling is the same gap seen from the other side. It was never timed at all,
# and it is the single interaction the operator does most.
if ($sessions.Count -ge 2 -and $script:__b) {
    # 🪤 LAY OUT THE PANE, NOT THE WHOLE WINDOW. `Lay` measures and arranges
    # $root - the rail, the session list, the header, everything - and swapping
    # a document does not do that in the real window: WPF invalidates the
    # subtree that changed. Using Lay here charged the document with ~113 ms of
    # unrelated window layout and made the reading pane look three times worse
    # than it is. Measured: document layout alone is ~1 ms; the rest was the
    # session list being re-arranged for a benchmark nobody asked it to.
    function LayPane {
        $ui.PaneDoc.Measure((New-Object System.Windows.Size 900, 600))
        $ui.PaneDoc.Arrange((New-Object System.Windows.Rect 0, 0, 900, 600))
        $ui.PaneDoc.UpdateLayout()
    }
    $null = Bench 'build AND lay out the document (what the click really costs)' {
        $ui.PaneDoc.Document = (Build-ReadDocument -Blocks $script:__b -Truncated $false)
        LayPane
    } 'GESTURE' 5

    $svP = Get-PaneScroller
    if (-not $svP) { Note 'no scroller in the pane yet - cannot profile scrolling' }
    else {
        Note ("document extent {0:N0} px over a {1:N0} px viewport - {2:N1} screens, none of it virtualized" -f `
              $svP.ExtentHeight, $svP.ViewportHeight, $(if ($svP.ViewportHeight -gt 0) { $svP.ExtentHeight / $svP.ViewportHeight } else { 0 }))
        $null = Bench 'scroll: one screen down' { $svP.PageDown(); Lay } 'GESTURE'
        $null = Bench 'scroll: one screen up'   { $svP.PageUp();   Lay } 'GESTURE'
        $null = Bench 'scroll: a wheel notch'   { $svP.ScrollToVerticalOffset($svP.VerticalOffset + 48); Lay } 'GESTURE'
        $null = Bench 'scroll: jump to the end' { $svP.ScrollToEnd(); Lay } 'GESTURE'
        $null = Bench 'scroll: jump to the top' { $svP.ScrollToHome(); Lay } 'GESTURE'
    }

    # Opening a folded block is a control the operator clicks, and it was added
    # in this session with no timing at all. This measures the LAZY BUILD - the
    # work a click pays the first time a block is opened.
    $turnsNow = @(Get-ReadTurns $script:__b)
    $runTurn = @($turnsNow | Where-Object { $_.Kind -eq 'run' } | Select-Object -First 1)
    if ($runTurn.Count) {
        Note ("the run block profiled holds {0} call(s)" -f @($runTurn[0].Calls).Count)
        $null = Bench 'open a run block (the lazy build a click pays)' {
            $pnl = New-Object System.Windows.Controls.StackPanel
            Build-FoldContent -Kind 'run' -Data $runTurn[0].Calls -Panel $pnl
        } 'GESTURE'
    } else { Note 'no tool run in this tail - cannot profile opening one' }

    # 🔴 THE TICK THE OPERATOR ACTUALLY FEELS. A working conversation calls
    # Update-Document every time its transcript grows, and that used to rebuild
    # every block in the document. This is the same content through both paths.
    $abFull = Bench 'a growth tick, REBUILDING the document (the old behaviour)' {
        $script:docKey = ''; $script:docTurns = $null
        Set-ReadDocument -Blocks $script:__b -Truncated $false
    } 'GESTURE' 5
    $abAppend = Bench 'a growth tick, APPENDING the tail (now)' {
        Set-ReadDocument -Blocks $script:__b -Truncated $false
    } 'GESTURE' 5
    if ($abFull -gt 0 -and $abAppend -gt 0) {
        Note ("a growth tick: {0:N0} ms rebuilding, {1:N0} ms appending - {2:N0} ms saved every time a watched session writes" -f `
              $abFull, $abAppend, ($abFull - $abAppend))
    }

    # 🔴 CONSTRUCTION VERSUS LAYOUT, which is what decides where a fix belongs.
    #
    # 🪤 DO NOT MEASURE LAYOUT BY RE-ASSIGNING A DOCUMENT WPF HAS ALREADY LAID
    # OUT. An earlier version of this did, read 1 ms, and concluded layout was
    # free - it was measuring a cache hit. A FRESH document is the only honest
    # measurement, so 'construction alone' is subtracted from the full click
    # rather than layout being timed on its own.
    $abBuildOnly = Bench 'A/B: construction alone (never laid out)' {
        $null = Build-ReadDocument -Blocks $script:__b -Truncated $false
    } 'GESTURE' 5
    $preBuilt = Build-ReadDocument -Blocks $script:__b -Truncated $false
    Note ("of the click: {0:N0} ms constructing objects; the remainder is WPF laying them out" -f $abBuildOnly)
    Note ("blocks in this document: {0}" -f @($preBuilt.Blocks).Count)
    # 🪤 THREE A/Bs LIVED HERE AND ALL THREE MEASURED AS NOISE - the gutter as a
    # hosted element vs a Run (4 ms, then -21 ms), Knuth-Plass on vs off (4 ms,
    # then 25 ms), and a ScrollViewer per result vs none (-58 ms). Each flipped
    # sign between runs on this machine. They are recorded here rather than kept
    # running: an A/B whose result reverses run to run is a measurement of the
    # load, and re-running it would only invite acting on the next reversal.
    # What DID measure consistently is timed below, inside the builder.

    # --- INSIDE THE BUILDER -------------------------------------------------
    # 🔴 Two hypotheses died here already - the hosted gutter element and
    # Knuth-Plass line breaking both measured as NOISE - so this stops guessing
    # at the shape of the cost and times the pieces the builder actually calls.
    $turnsAll = @(Get-ReadTurns $script:__b)
    Note ("turns: {0} ({1} prose, {2} runs)" -f $turnsAll.Count,
          @($turnsAll | Where-Object { $_.Kind -eq 'said' -or $_.Kind -eq 'you' }).Count,
          @($turnsAll | Where-Object { $_.Kind -eq 'run' }).Count)
    $proseT = @($turnsAll | Where-Object { ($_.Kind -eq 'said' -or $_.Kind -eq 'you') -and "$($_.Body)".Length -gt 200 } | Select-Object -First 1)
    if ($proseT.Count) {
        $ptxt = "$($proseT[0].Body)"
        Note ("the prose turn profiled is {0:N0} characters over {1} source lines" -f $ptxt.Length, @($ptxt -split "`n").Count)
        $null = Bench 'inside: Add-ReadProse for ONE prose turn' {
            $dd = New-Object System.Windows.Documents.FlowDocument
            Add-ReadProse -Doc $dd -Text $ptxt -Brush $Pal.TextHigh -Size $script:readSize -Line $script:readLead -Kind 'said'
        } 'GESTURE'
    }
    $null = Bench 'inside: New-SRTint x100 (a brush per rail block)' {
        for ($q = 0; $q -lt 100; $q++) { $null = New-SRTint $Pal.Tool 0.5 }
    } 'GESTURE'
    $null = Bench 'inside: Get-TrackedText x100' {
        for ($q = 0; $q -lt 100; $q++) { $null = Get-TrackedText '3 steps   Edit . PowerShell' }
    } 'GESTURE'
    $null = Bench 'inside: New-ReadText x100' {
        for ($q = 0; $q -lt 100; $q++) { $null = New-ReadText -Text 'some machine output here' -Brush $Pal.TextMid -Size 12 -Mono -Wrap -Line 16.5 }
    } 'GESTURE'
    $null = Bench 'inside: New-RailBlock x50' {
        for ($q = 0; $q -lt 50; $q++) {
            $sp2 = New-Object System.Windows.Controls.StackPanel
            $null = New-RailBlock -Child $sp2 -Kind 'run' -Rail
        }
    } 'GESTURE'
    $null = Bench 'inside: Compress-SRPath x100' {
        for ($q = 0; $q -lt 100; $q++) { $null = Compress-SRPath 'C:\Users\mauri\Documents\MM-toolbox\tools\session-restore\lib\sessions-window.ps1' }
    } 'GESTURE'

    # And the same document with every block OPEN, which is what Steps: full
    # gives the operator and is the heaviest the pane ever gets.
    $tvWas = $script:toolView
    $script:toolView = 'full'
    $null = Bench 'build AND lay out with every block open (Steps: full)' {
        $ui.PaneDoc.Document = (Build-ReadDocument -Blocks $script:__b -Truncated $false)
        Lay
    } 'SLOW' 3
    $script:toolView = $tvWas
    Update-Document -Wait
}

# ---------------------------------------------------------------------------
Write-Host ''
Write-Host '--- the panels ---'
# ---------------------------------------------------------------------------
$null = Bench 'open the settings panel' { Show-Settings } 'GESTURE'
$null = Bench 'close the settings panel' { Hide-Settings } 'INSTANT'
$null = Bench 'build the settings dropdowns' { Build-SettingDrops } 'GESTURE'
$null = Bench 'permission note' { Update-PermNote } 'INSTANT'
$null = Bench 'open send-to-many' { Show-Cast } 'GESTURE'
$null = Bench 'build the send-to-many list' { Build-Cast } 'GESTURE'
Hide-Cast
$null = Bench 'read the skills off disk' { Get-SRSkills } 'SLOW' 1
$ui.SendBox.Text = '/re'
$null = Bench 'filter the skill picker' { Update-SkillPop } 'GESTURE'
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
$null = Bench 'Get-TickedPlan' { Get-TickedPlan } 'GESTURE'
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
Write-Host '--- the gestures nothing was measuring ---'
# ---------------------------------------------------------------------------
# Everything below is a control the operator can press that had no timing at
# all. Several are trivial and that is worth KNOWING rather than assuming - a
# handler nobody measured is exactly where the two worst stalls in this tool
# were found.
$railPickWas2 = $script:railPick
$null = Bench 'pick a project in the rail' {
    $script:railPick = "$(@($script:dirs)[0].path)"
    Build-Rail; Build-Sessions
} 'GESTURE'
$script:railPick = $railPickWas2
Build-Rail; Build-Sessions

$null = Bench 'toggle the steps view (the redraw half)' { Show-Selected -Force } 'GESTURE'
$null = Bench 'the maximise glyph' { Update-MaxGlyph } 'GESTURE'
$null = Bench 'the window frame' { Update-Frame } 'GESTURE'
$null = Bench 'the send-to-many text box' {
    $ui.CastSend.IsEnabled = (@($script:castPick.Keys).Count -gt 0 -and "$($ui.CastText.Text)".Trim().Length -gt 0)
} 'GESTURE'
$null = Bench 'is the registry stale? (what Save checks first)' { Get-SRRegistryStamp } 'GESTURE'
# 🪤 WHAT THE BUTTON DOES, NOT A HARSHER THING I INVENTED. This first measured
# Get-LaunchBlock across all 202 conversations - 227 ms - but the handler calls
# it once per TICKED one, from inside Get-TickedPlan. Benching work the tool
# never performs is the same error as benching a function it no longer has.
$null = Bench 'open everything not running (up to the launch)' {
    $planNow = Get-TickedPlan
    $null = Limit-ToCap $planNow.Fresh
} 'GESTURE'

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
# ---------------------------------------------------------------------------
Write-Host ''
Write-Host '--- is every control the operator can press actually measured? ---'
# ---------------------------------------------------------------------------
# 🔴 "EVERY OPERATION THE OPERATOR CAN CAUSE" WAS A CLAIM IN A COMMENT AND
# NOTHING CHECKED IT. This reads the wired handlers straight out of the window
# source and requires each one to be named here - either against the bench that
# covers it, or with a reason it cannot be run. A control added tomorrow with no
# timing fails this, which is the only way the claim at the top of this file
# stays true.
#
# 🪤 The excused ones are excused for ONE reason only: running them would type
# into a live session, write the operator's registry, raise a terminal or open a
# modal dialog that never returns. Where that is true the work they do BEFORE
# the irreversible step is measured instead, and named below.
$COVERAGE = @{
    'Search'           = 'search: header box'
    'RailSearch'       = 'search: rail box'
    'ListSearch'       = 'search: sessions box'
    'SendBox'          = 'filter the skill picker'
    'CastText'         = 'the send-to-many text box'
    'ModeWork'         = 'Set-Surface work'
    'ModeManage'       = 'Set-Surface manage'
    'SessionList'      = 'select a conversation'
    'RailList'         = 'pick a project in the rail'
    'PaneSettings'     = 'open the settings panel'
    'SetCancel'        = 'close the settings panel'
    'SetPerm'          = 'permission note'
    'PaneTools'        = 'toggle the steps view (the redraw half)'
    'Broadcast'        = 'open send-to-many'
    'CastCancel'       = 'open send-to-many'
    'WinMax'           = 'the maximise glyph'
    'WinMin'           = 'the window frame'
    'WinClose'         = 'the window frame'
    'SaveBtn'          = 'is the registry stale? (what Save checks first)'
    'RelaunchSessions' = 'Get-TickedPlan'
    'OpenNotRunning'   = 'open everything not running (up to the launch)'
    # Excused, with what is measured in their place.
    # 🔴 THE MOST CONSEQUENTIAL CONTROL IN THE WINDOW, and it was outside this
    # check until the pattern was widened to see buttons built in code. Pressing
    # an option sends a decision into a live session, and it cannot be run here
    # for exactly that reason - but what it WAITS on is measured: gui2 times the
    # screen read Send-SRQuestionAnswer performs to find the cursor before a
    # single key leaves, against a real console.
    'Invoke-Answer'    = 'EXCUSED: sends a decision into a live session. gui2 times the screen read it waits on.'
    # The two controls the batched-round panel added. Both drive a REAL menu in
    # a REAL terminal - one walks the round with left/right keys, the other
    # types an answer and commits it - so timing them here would mean answering
    # somebody's open question to make a benchmark. Excused for the same reason
    # Invoke-Answer is, and covered where they can be covered honestly: the
    # relay suite drives both against captured screens and a live replica.
    'Invoke-AskMove'   = 'EXCUSED: walks a live round with arrow keys. relay drives the parse it depends on.'
    'AskFreeSend'      = 'EXCUSED: types an answer into a live session. Same path as SendBtn; relay covers the read.'
    'SendBtn'          = 'EXCUSED: types into a live session. Its gesture is a string trim; the relay suite covers the send itself.'
    'PaneCompact'      = 'EXCUSED: types /compact into a live session. Same path as SendBtn.'
    'CastSend'         = 'EXCUSED: types into every ticked session at once.'
    'SetApply'         = 'EXCUSED: writes per-session settings and may relaunch.'
    'Rescan'           = 'EXCUSED: saves the registry and rescans; its cost IS Update-Model, benched above.'
    'PaneRelaunch'     = 'EXCUSED: kills and relaunches a conversation.'
    'PaneGoTo'         = 'EXCUSED: raises a real terminal window; the jump suite covers it.'
    'NewSession'       = 'EXCUSED: ShowDialog never returns without a human. Its build cost is Build-SettingDrops, benched above.'
    'PaneWorktree'     = 'EXCUSED: opens the same dialog as NewSession.'
}
$srcTxt = Get-Content -LiteralPath (Join-Path $SR_LibDir 'sessions-window.ps1') -Raw -Encoding UTF8
$wired = @([regex]::Matches($srcTxt, '(?m)^\$ui\.([A-Za-z]+)\.Add_(?:Click|SelectionChanged|TextChanged|KeyDown|Checked|MouseDoubleClick)') |
           ForEach-Object { $_.Groups[1].Value } | Sort-Object -Unique)
# 🔴 CONTROLS BUILT IN CODE COUNT TOO, and the pattern above cannot see them.
# The answer buttons in the question panel are created per option and wired with
# `$b.Add_Click({ Invoke-Answer ... })` - so the most consequential control in
# the whole window, the one that sends a decision into a live session, was
# outside a coverage check that reported "30 wired controls" and sounded
# complete. Any handler naming a function is picked up by what it CALLS.
foreach ($m in [regex]::Matches($srcTxt, '\$\w+\.Add_Click\(\{\s*param\([^)]*\)\s*([A-Z][\w-]+)')) {
    $wired += $m.Groups[1].Value
}
$wired = @($wired | Sort-Object -Unique)
$unmeasured = @($wired | Where-Object { -not $COVERAGE.ContainsKey($_) })
if ($unmeasured.Count) {
    Fail ("{0} control(s) the operator can press have no timing at all: {1}" -f $unmeasured.Count, ($unmeasured -join ', '))
} else {
    $excused = @($COVERAGE.Values | Where-Object { "$_" -like 'EXCUSED*' }).Count
    Note ("{0} wired controls: {1} measured, {2} excused with the work they do beforehand measured instead" -f `
          $wired.Count, ($wired.Count - $excused), $excused)
    # 🪤 AND THE MAP MUST NOT ROT EITHER. A name here that no longer exists in
    # the window means the map was edited and the window was not.
    $stale = @($COVERAGE.Keys | Where-Object { $wired -notcontains $_ })
    if ($stale.Count) { Fail ("the coverage map names {0} control(s) the window no longer has: {1}" -f $stale.Count, ($stale -join ', ')) }
    else { Note 'every name in the coverage map is a control that still exists' }
}

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

# 🔴 A GESTURE OVER BUDGET IS A FAILURE, NOT A NOTE.
#
# This used to fail only on an outright stall and warn about everything else,
# and that is how a 1,191 ms click nearly shipped: it was in the table, in
# yellow, and read past. The contract is that nothing the operator DOES waits
# for work, so the things they do are a hard gate and the background stays a
# report. Best-of-seven is what makes that safe on a loaded machine - the number
# being tested is the one where the code got the CPU, so a red here is the code.
Write-Host ''
$brokeIt = @($script:Results | Where-Object { $_.Threw })
foreach ($b in $brokeIt) { Fail ("{0} THREW - it has no timing, it has an error: {1}" -f $b.Name, $b.Threw) }
$slowGestures = @($script:Results | Where-Object { -not $_.Threw -and $_.Class -eq 'GESTURE' -and $_.Ms -gt $LIMITS['GESTURE'] })
# 🔴 A VIOLATION HAS TO BE STABLE TO COUNT. Measured across five runs of this
# suite as the machine got busier, 'build the FlowDocument' read 19.6, 29.3,
# 40.4, 49.9 and 78.8 ms on IDENTICAL source - so a single over-budget reading
# is not evidence about the code. When the best and worst of seven runs differ
# by more than 2.5x the operation was contending for the machine and its best
# sample cannot be trusted either; that is reported, loudly, but it does not
# fail the suite. A stable number over budget is the code, and that does.
foreach ($g in $slowGestures) {
    $spread = 99.0
    if ($g.Ms -gt 0) { $spread = $g.Worst / $g.Ms }
    if ($spread -gt 2.5) {
        Write-Host ("  NOISY {0} read {1:N0} ms best / {2:N0} ms worst - over budget, but this machine is contending" -f $g.Name, $g.Ms, $g.Worst) -ForegroundColor Yellow
    } else {
        Fail ("{0} takes {1:N0} ms at its FASTEST and only {2:N0} ms at its worst - that is the code, not the machine" -f $g.Name, $g.Ms, $g.Worst)
    }
}
$stalls = @($script:Results | Where-Object { $_.Ms -ge 1000 -and $_.Class -ne 'SLOW' -and $_.Class -ne 'STALL' -and $_.Class -ne 'GESTURE' })
if ($stalls.Count) {
    foreach ($s in $stalls) { Fail ("{0} takes {1:N0} ms - the window is visibly frozen for that long" -f $s.Name, $s.Ms) }
}
# A wide spread is not a failure but it IS a finding: it means the operation is
# contending with something rather than simply costing what it costs.
$jumpy = @($script:Results | Where-Object { $_.Worst -gt ($_.Ms * 8) -and $_.Worst -gt 200 })
if ($jumpy.Count) {
    Write-Host ''
    Write-Host '  operations whose worst run was 8x their best - contention, not cost:' -ForegroundColor DarkGray
    foreach ($j in $jumpy) { Note ("{0,8:N0} ms best / {1,8:N0} ms worst   {2}" -f $j.Ms, $j.Worst, $j.Name) }
}
if ($fails) { Write-Host "$fails FAILURE(S)" -ForegroundColor Red; exit 1 }
Write-Host 'nothing on the surface stalls the window' -ForegroundColor Green
exit 0
