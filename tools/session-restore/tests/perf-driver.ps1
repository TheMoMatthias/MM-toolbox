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

# ---------------------------------------------------------------------------
# 🔴 A LIST BENCH THAT NEVER LAYS OUT IS MEASURING HALF THE OPERATION.
#
# Build-Sessions, Build-Rail, Build-Manager and every sort/filter/search built on
# them REPLACE ItemsSource AND RETURN. Container generation, template
# instantiation and measure/arrange all happen afterwards, on the next layout
# pass - outside the timed region entirely. So every list figure in this table
# was the cost of building the ITEMS, reported as the cost of the gesture, and
# the operator waits for the frame rather than for the assignment.
#
# 🪤 THE RENAME IS PART OF THE FIX, NOT TIDYING. Adding the layout changes what
# the operation IS, so the old baseline entry no longer describes it and would
# read as a large regression on the next run. SR_PERF_REBASELINE is the wrong
# tool for that - it widens EVERY op's envelope by one run's noise, permanently.
# A renamed op has no baseline key, so it is counted as new and skipped for one
# run, and the old key vanishes on the next trusted write because $newOps is
# populated only from $script:Results. Self-cleaning, and the old figure keeps
# its meaning in git history instead of being silently redefined.
function BenchList {
    param([string]$Name, [scriptblock]$Do, [string]$Class = 'GESTURE', [int]$Runs = 15)
    $body = { & $Do; Lay }.GetNewClosure()
    return Bench ($Name + ' (+ layout)') $body $Class $Runs
}

# GESTURE is the class with teeth. Everything the operator can DO - a click, a
# keystroke, a tab, a button - must return inside 50 ms, because that is the
# contract: no gesture ever waits for work. Anything that reads disk or spawns a
# process belongs off the interaction path, and is measured under the classes
# below as a warning only, since a scan takes the time a scan takes.
$LIMITS = @{ 'GESTURE' = 50.0; 'INSTANT' = 50.0; 'QUICK' = 250.0; 'SLOW' = 1000.0; 'STALL' = 100000.0 }

# ===========================================================================
# 🔴 THE BAR IS MEASURED, AND IT IS NOT 50 ms.
#
# The classes above were written against what a person notices. That was a
# reasonable standard and it is not the one the operator set: "no noticeable
# difference between operating a terminal and operating the tool". So the
# terminal was measured (bench-term.ps1 / bench-claude.ps1, 2026-09-04):
#
#     a bare console app answers a key          1.8 ms
#     the real claude TUI answers an arrow      6.9 ms   <- THE BAR
#     one screen read, held-open reader         9.3 ms
#
# 6.9 is a CEILING rather than a reading: a screen read costs more than that, so
# nothing faster is observable. The TUI repaints inside one read.
#
# 🪤 GESTURE = 50 ms IS SEVEN TIMES THE BAR, which is why this suite could report
# "everything is inside its class budget" about a window with 49 of 79
# gesture/instant operations over the terminal. The budget was not wrong when it
# was written; it is simply not the question being asked any more.
$SR_BAR   = 7.0     # the terminal
$SR_FRAME = 16.0    # one frame at 60fps - below this, faster is unobservable

# 🔴 THE BAR IS REPORTED, NOT GATED ON, AND THAT IS DELIBERATE.
#
# Failing every operation over 7 ms would put this suite permanently red across
# most of the window - and this file already carries the reason that is fatal:
# "a benchmark that cries wolf gets muted, and a muted benchmark catches
# nothing." A gate nobody can ever make green is a gate that gets switched off,
# taking the real regressions with it.
#
# So the two questions are separated. HOW FAR FROM THE TERMINAL is printed for
# every operation, every run, and never fails. WHETHER THIS COMMIT MADE
# SOMETHING SLOWER is the gate, and it is measured against a recorded baseline
# rather than against an absolute.
# ⏸ NOT BUILT YET - THIS IS THE NEXT STEP, RECORDED SO IT IS NOT MISTAKEN FOR
# SOMETHING THAT ALREADY WORKS. The plan, measured and ready to implement:
#
#   * record best-of-N per operation into tests\perf-baseline.json ALONGSIDE the
#     spin-loop figure from the same run;
#   * on a later run, expected = baselineMs * (spinNow / spinBaseline);
#   * fail when actual > expected * ~1.6, which is a regression the machine
#     cannot explain. Generous on purpose: the spin is pure CPU and these
#     operations are WPF, so it is a correction and not a conversion.
#
# 🔴 WHY THIS REPLACES THE EXISTING RULE. The gate below decides "code, not
# machine" from a NARROW best-to-worst spread - and that inference is backwards
# under sustained load: when everything is contended every sample is contended,
# so the floor rises with the ceiling and the spread NARROWS. Measured 2026-09-05:
# it fired on ten operations at once while UNTOUCHED code in the same run had
# moved further than the touched code (sort sessions: project 3.06x, Build-Sessions
# 2.80x, against Build-Manager 2.01x, spin 88 -> 163 ms). The comment further down
# already admits the spread guard cannot see this; the answer was to soften the
# gate rather than to fix the detector. Normalising by the spin fixes it.
# 🪤 $SR_Root, NOT $PSScriptRoot. This driver is SPLICED onto the window source
# by New-GuiHarness and executed from .state, so $PSScriptRoot here is .state -
# and the first version of this quietly wrote the baseline into a scratch
# directory. Deleting tests\perf-baseline.json then did nothing, and the run
# kept comparing against a file that looked like it had been removed.
$SR_BaselinePath = Join-Path $SR_Root 'tests\perf-baseline.json'
# 🔴 SET FROM MEASUREMENT, AFTER TWO GUESSES WERE WRONG.
#
# Against an ENVELOPE baseline (the worst of five healthy runs - see the
# rebaseline note further down), three clean verification runs on identical
# source came in at worst 1.11x, 1.57x and "nothing within 8 ms". 1.60 leaves a
# 2% margin over that, which is one unlucky run away from crying wolf, and this
# file already records what happens to a benchmark that does.
#
# 🪤 BE HONEST ABOUT WHAT THIS BUYS. At 2.0x against the worst healthy run, and
# only when the absolute difference clears 8 ms, this catches something becoming
# GROSSLY slower - a synchronous disk read appearing on a click, a rebuild where
# an append used to be, the 1.3-second Send. It does NOT catch 20% creep, and no
# threshold on a single sample per run could: the underlying spread is 1.5x on
# healthy code. Finer work than that needs the deliberate A/B the audit lanes
# did, not a suite gate.
$SR_RegressAt = 2.00
# 🔴 AND IT MUST ALSO BE SLOWER BY AN AMOUNT ANYONE COULD NOTICE.
#
# A ratio on a small operation is mostly noise. Measured across four runs of this
# suite on IDENTICAL source, the worst ratio seen was 1.39x, then 1.54x, then
# 1.75x - and every one of those was a sub-10 ms operation where the actual
# difference was one or two milliseconds. A threshold set above that spread
# (2.5x, say) would be too blunt to catch anything real; the honest fix is to
# stop judging small operations by ratio at all.
#
# So a regression has to clear BOTH tests: proportionally worse AND worse by at
# least this many milliseconds. Eight is half a frame - below it, nothing that
# happens on a click is perceptible, and the ratio is measuring the machine.
$SR_RegressMinMs = 8.0

# 🔑 HOW BUSY THIS MACHINE IS, MEASURED THE SAME WAY AT BOTH ENDS OF THE RUN.
#
# A fixed CPU workload: whatever it reads, it read for the same reason the table
# did. Taking it only ONCE was a real source of false alarms - the benchmarks
# take minutes, and a single reading at the end describes the machine at the end
# rather than while the work was happening. Bracketing the run gives a mean to
# normalise against and, more usefully, a DRIFT figure: if the two ends disagree
# badly, nothing measured in between can be trusted against a baseline.
function Measure-SRSpin {
    $b = [double]::MaxValue
    for ($rep = 0; $rep -lt 5; $rep++) {
        $sw = [Diagnostics.Stopwatch]::StartNew()
        $acc = 0.0
        for ($i = 1; $i -lt 100000; $i++) { $acc += [Math]::Sqrt($i) }
        $sw.Stop()
        if ($sw.Elapsed.TotalMilliseconds -lt $b) { $b = $sw.Elapsed.TotalMilliseconds }
    }
    return $b
}
# The start reading is NOT taken here - see the note above the first Bench.



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

# 🔴 THE START READING GOES HERE, NOT AT THE TOP OF THE FILE, AND THAT IS WHY
# THE DRIFT CHECK USED TO SUPPRESS EVERY RUN.
#
# The pair exists to answer one question: did the machine change WHILE THE TABLE
# WAS BEING TAKEN? Taken at the top of the script it answered a different one,
# because everything between there and here - loading WPF, building the window,
# Update-Model over 318 conversations, the first layout - lands inside the
# bracket. Background JIT and GC from that start-up inflate the first reading and
# nothing inflates the second, so the "drift" was a property of the instrument
# rather than of the machine, and it repeated:
#
#     16 -> 9 (1,74x)    17 -> 9 (1,95x)
#
# both above the 1.5x trust threshold, on consecutive runs. Random load does not
# repeat like that.
#
# 🪤 AND A CPU WARM-UP DOES NOT FIX IT - measured, not assumed. Burning 200 ms of
# the same sqrt loop before the reading moved it 15 -> 9 (1,71x): unchanged. So
# it is not the clock ramping, it is the process still settling, and the only
# real fix is to stop including the settling in the measurement.
$script:SpinStart = Measure-SRSpin

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
$null = BenchList 'Build-Sessions' { Build-Sessions }
$null = BenchList 'Build-Rail' { Build-Rail }
$null = BenchList 'Build-Manager' { Build-Manager }
# 🔴 BOTH PATHS, OR THE BENCH REWARDS BREAKING THE THING IT WATCHES. This ran
# straight after Bench 'Build-Manager', which CLEARS $script:mgrDirty - so all
# fifteen iterations took the skip path, the rebuild was never once measured,
# and deleting the dirty flag so the manager NEVER rebuilt would have registered
# here as an improvement. The cached path is the one the operator usually gets
# and is worth its own line; the rebuild is the cost the flag exists to avoid,
# and a flag that stops working shows up as the cached line jumping to it.
$null = BenchList 'Set-Surface manage (cached)' { Set-Surface 'manage' }
$null = BenchList 'Set-Surface manage (rebuild)' { $script:mgrDirty = $true; Set-Surface 'manage' }
$null = Bench 'Set-Surface work' { Set-Surface 'work' } 'GESTURE'
$null = Bench 'Set-Breakpoint' { Set-Breakpoint } 'INSTANT'
# 🪤 QUICK, AND THE CALLERS ARE THE ARGUMENT. Update-Surface is Build-Rail plus
# Build-Sessions - both benched separately below and both inside GESTURE - so
# holding their SUM to a single gesture's budget double-counts work already
# gated. And nothing puts it on a 50 ms path: every interactive caller
# (sessions-window.ps1 Rescan, Apply-settings, and the settings sheet) invokes
# it as `Update-Model -KeepAgents; Update-Surface; Start-LiveProbe`, where the
# model refresh alone is ~730 ms. The fourth caller is first paint.
#
# It was measured at 34-68 ms across six runs on the same source as the
# registry grew past 229 conversations, so as a GESTURE it flapped red and
# green with the machine - the precise shape of a benchmark that gets muted.
$null = Bench 'Update-Surface (Rescan / Apply-settings, never a bare click)' { Update-Surface } 'QUICK'

# ---------------------------------------------------------------------------
Write-Host ''
Write-Host '--- searching, sorting and filtering ---'
# ---------------------------------------------------------------------------
# 🪤 Each of these is a KEYSTROKE, debounced but still on the UI thread.
$null = Bench 'search: header box (both panes)' {
    $ui.Search.Text = 'kernel'; Build-Rail; Build-Sessions
} 'GESTURE'
$ui.Search.Text = ''
$null = BenchList 'search: rail box only' { $ui.RailSearch.Text = 'algo'; Build-Rail }
$ui.RailSearch.Text = ''; Build-Rail
$null = BenchList 'search: sessions box only' { $ui.ListSearch.Text = 'ker'; Build-Sessions }
$ui.ListSearch.Text = ''; Build-Sessions

foreach ($k in @('recent', 'name', 'project')) {
    $script:listSort = $k
    $null = BenchList "sort sessions: $k" { Build-Sessions }
}
$script:listSort = 'recent'
foreach ($k in @('recent', 'name', 'waiting', 'busiest')) {
    $script:railSort = $k
    $null = BenchList "sort rail: $k" { Build-Rail }
}
$script:railSort = 'recent'
$mgrSortWas = $script:mgrSort; $mgrDescWas = $script:mgrDesc
foreach ($k in @('logon', 'name', 'lane', 'said', 'age')) {
    $script:mgrSort = $k
    $null = BenchList "sort manager: $k" { Build-Manager }
}
$script:mgrSort = $mgrSortWas; $script:mgrDesc = $mgrDescWas
$mgrFilterWas = $script:mgrFilter
foreach ($k in @('all', 'ticked', 'running', 'needs')) {
    $script:mgrFilter = $k
    $null = BenchList "filter manager: $k" { Build-Manager }
}
$script:mgrFilter = $mgrFilterWas
$bandKeys = @($script:Bands | ForEach-Object { $_.Key })
$script:bandPick = $bandKeys[0]
$null = BenchList 'filter sessions by band' { Build-Sessions }
$script:bandPick = $null
$script:railOnlyLive = $true
$null = BenchList 'filter rail to running only' { Build-Rail }
$script:railOnlyLive = $false
$railPickWas = $script:railPick
$script:railPick = "$(@($script:dirs)[0].path)"
$null = BenchList 'filter sessions by project (rail pick)' { Build-Sessions }
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
    # 🪤 QUICK, NOT GESTURE, AND THE DISTINCTION IS REAL RATHER THAN A DODGE.
    # The parse runs in a runspace, so this is NOT in the click handler - the
    # click returns immediately and Complete-DocParse builds the document one
    # lane tick later. But WPF objects have thread affinity, so the build and
    # the layout DO happen on the UI thread, and the window is unresponsive for
    # this long shortly after the click. It is deferred, not free, which is
    # exactly what QUICK means here. The note below keeps it visible rather than
    # letting a passing class hide it.
    $abClick = Bench 'build AND lay out the document (deferred off the click, still on the UI thread)' {
        $ui.PaneDoc.Document = (Build-ReadDocument -Blocks $script:__b -Truncated $false)
        LayPane
    } 'QUICK' 5
    if ($abClick -gt 100) {
        Note ("the pane is unresponsive for {0:N0} ms shortly after a selection - deferred off the click, but still felt" -f $abClick)
    }

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
    # 🪤 The rebuild is the CONTROL in this comparison, not a path the window
    # takes any more - so it is not a gate. Holding it to the gesture budget
    # would fail the suite for the cost of the thing that was replaced, which
    # says nothing about the code that ships. The APPEND below is the gate.
    $abFull = Bench 'a growth tick, REBUILDING the document (the old behaviour, kept as the control)' {
        $script:docKey = ''; $script:docTurns = $null
        Set-ReadDocument -Blocks $script:__b -Truncated $false
    } 'QUICK' 5
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
    # 🪤 A DIAGNOSTIC, NOT A GESTURE. Nothing the operator presses runs this -
    # it exists to split the click into construction and layout. Holding a
    # measurement to the gesture budget fails the suite for a number that is
    # already reported on the line below it.
    $abBuildOnly = Bench 'A/B: construction alone (never laid out)' {
        $null = Build-ReadDocument -Blocks $script:__b -Truncated $false
    } 'QUICK' 5
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
# The morning compact only fills the box - it reads the config and assigns a
# string - but it is a control the operator can press, so it is timed like one.
$null = Bench 'fill the morning-compact brief' { $ui.CastText.Text = (Get-SRCompactBrief) } 'INSTANT'
$ui.CastText.Text = ''
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
# THE ZOOM, WHICH IS THE MOST EXPENSIVE GESTURE IN THE WINDOW BY CONSTRUCTION:
# it rewrites six window resources (every XAML style re-resolves), tells the
# sessions list its rows changed height, and rebuilds the whole document. It is
# also the one the operator will hold down to find the size they want, so it is
# the one where lag would be felt most. Timed WITHOUT the config write, which is
# a side effect the redraw never waits on.
$zoomWas = $script:Zoom
$null = Bench 'the text-size control (resources + list + redraw)' {
    Set-SRTypeScale -Percent $(if ($script:Zoom -eq 100) { 110 } else { 100 })
    try { $ui.SessionList.Items.Refresh() } catch { }
    Show-Selected -Force
} 'GESTURE'
Set-SRTypeScale -Percent $zoomWas
$null = Bench 'hide the running-shells panel' { $ui.ShellBox.Visibility = 'Collapsed' } 'GESTURE'
$null = Bench 'the maximise glyph' { Update-MaxGlyph } 'GESTURE'
$null = Bench 'the window frame' { Update-Frame } 'GESTURE'
$null = Bench 'the send-to-many text box' {
    $ui.CastSend.IsEnabled = (@($script:castPick.Keys).Count -gt 0 -and "$($ui.CastText.Text)".Trim().Length -gt 0)
} 'GESTURE'
$null = Bench 'is the registry stale? (what Save checks first)' { Get-SRRegistryStamp } 'GESTURE'
# All the Sign in button does before it opens a terminal: read one file's
# timestamp, so it knows what "changed" means afterwards.
$null = Bench 'Get-SRCredStamp (what Sign in costs before the terminal opens)' { Get-SRCredStamp } 'INSTANT'
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
    'PaneZoom'         = 'the text-size control (resources + list + redraw)'
    'ShellFold'        = 'hide the running-shells panel'
    'Broadcast'        = 'open send-to-many'
    'CastCancel'       = 'open send-to-many'
    'CastCompact'      = 'fill the morning-compact brief'
    'WinMax'           = 'the maximise glyph'
    'WinMin'           = 'the window frame'
    'WinClose'         = 'the window frame'
    'SaveBtn'          = 'is the registry stale? (what Save checks first)'
    'RelaunchSessions' = 'Get-TickedPlan'
    # 🔴 EXCUSED, AND FOR THE STRONGEST REASON ON THIS LIST. Pressing it opens
    # a real terminal for an interactive sign-in and then RAISES THE RELAUNCH
    # BUTTON, which kills live claude processes. Running it in a benchmark would
    # sign the operator out of their own machine and restart their work. What it
    # costs before any of that is one file stat - measured below as its own
    # line, which is the only part of it a benchmark may honestly touch.
    'SignIn'           = 'EXCUSED: opens an interactive sign-in and then relaunches. Its gesture cost is Get-SRCredStamp, benched.'
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
# 🔴 THIS PATTERN USED TO SEE 37 OF 88 CONTROLS AND REPORT LIKE IT SAW THEM ALL.
#
# Audited 2026-09-05. It matched `^\$ui\.Name\.Add_` against SIX event kinds, so
# three separate blind spots went unreported for the life of the file:
#
#   1. EVENT KINDS IT DID NOT LIST - MouseLeftButtonUp (6), MouseLeftButtonDown
#      and its preview, PreviewKeyDown (both $window ones, i.e. every keyboard
#      shortcut), SizeChanged, LostKeyboardFocus. That is 19 of 54 $ui wirings,
#      and it is how this UI wires its custom borders: the fold header, "load
#      earlier" and the agent links - the most-pressed control on the reading
#      pane - had never been timed by anything.
#   2. THE $ui[<name>] INDEXER FORM, invisible whatever the event kind, because
#      the pattern requires a dot. Every confirmation sheet, the five manager
#      sort headers and the four filter chips are wired that way.
#   3. THE ^ ANCHOR, which costs nothing today but is latent: one indented
#      wiring and the control vanishes from the check silently.
#
# All three are fixed below. The names it CANNOT recover - an indexer takes an
# expression, not a literal - are counted and reported rather than quietly
# dropped, because "I can see 12 controls here and cannot name them" is a true
# statement and "37 wired controls" was not.
$EVENTS = 'Click|SelectionChanged|TextChanged|KeyDown|PreviewKeyDown|Checked|Unchecked|MouseDoubleClick|' +
          'MouseLeftButtonUp|MouseLeftButtonDown|PreviewMouseLeftButtonUp|PreviewMouseLeftButtonDown|' +
          'PreviewMouseRightButtonDown|SizeChanged|LostKeyboardFocus|GotKeyboardFocus|Loaded'
$wired = @([regex]::Matches($srcTxt, ('\$ui\.([A-Za-z][A-Za-z0-9]*)\.Add_(?:' + $EVENTS + ')')) |
           ForEach-Object { $_.Groups[1].Value } | Sort-Object -Unique)

# Wired through the indexer - real controls, not nameable from here.
# 🪤 THE SUBSCRIPT CAN ITSELF CONTAIN BRACKETS - `$ui[$pair[0]].Add_Checked` is
# the real shape in this window - so `[^\]]+` stops at the INNER bracket and
# matches nothing. One level of nesting is all this needs and all it should take.
$idxSites = @([regex]::Matches($srcTxt, ('\$ui\[(?:[^\[\]]|\[[^\[\]]*\])*\]\.Add_(?:' + $EVENTS + ')')))

# 🔑 AND THEIR NAMES ARE RECOVERABLE AFTER ALL. Every one of these sites is a
# `foreach ($n in @('A','B','C')) { $ui[$n].Add_... }` over LITERAL names - the
# three confirmation-sheet buttons, the five manager sort headers, the four
# filter chips. So counting the SITES (3) under-reports the CONTROLS (12) by
# four times, which is the mistake the first version of this made.
#
# Reading the literals out of the nearest preceding foreach recovers all twelve
# and puts them through the same coverage check as everything else. It is a
# heuristic and is written down as one: a site whose names are not literal will
# contribute nothing here and be counted as unnameable below, which is the
# honest failure direction.
$indexedNames = New-Object System.Collections.Generic.List[string]
foreach ($m in $idxSites) {
    $before = $srcTxt.Substring([Math]::Max(0, $m.Index - 600), [Math]::Min(600, $m.Index))
    $fe = $before.LastIndexOf('foreach (')
    if ($fe -lt 0) { continue }
    foreach ($q in [regex]::Matches($before.Substring($fe), "'([A-Z][A-Za-z0-9]*)'")) {
        $null = $indexedNames.Add($q.Groups[1].Value)
    }
}
$indexedNames = @($indexedNames.ToArray() | Sort-Object -Unique)
$indexed = $idxSites.Count
# They are controls like any other, so they join the list that gets checked.
$wired = @($wired + $indexedNames | Sort-Object -Unique)
# Window-level handlers: the keyboard shortcuts, which belong to no control.
$windowLevel = @([regex]::Matches($srcTxt, ('\$window\.Add_(?:' + $EVENTS + ')'))).Count
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
$unmeasured = @($wired | Where-Object { -not $COVERAGE.ContainsKey($_) } | Sort-Object)
$excused = @($COVERAGE.Values | Where-Object { "$_" -like 'EXCUSED*' }).Count

Note ("{0} nameable controls wired: {1} measured, {2} excused, {3} UNMEASURED." -f `
      $wired.Count, ($wired.Count - $excused - $unmeasured.Count), $excused, $unmeasured.Count)
Note ("of those, {0} came from {1} indexer site(s): {2}" -f `
      $indexedNames.Count, $indexed, ($indexedNames -join ', '))
Note ("plus {0} handler(s) at window level - the keyboard shortcuts, which belong to no control." -f $windowLevel)

# 🔴 THE EXISTING HOLE IS RECORDED, AND IT MAY NOT GROW.
#
# Widening the pattern above turned 37 known controls into far more, most of
# them never measured - and failing on all of them at once would put this suite
# permanently red, which is the "benchmark that cries wolf" this file has warned
# about since it was written. A gate nobody can make green gets switched off,
# and it takes the real checks with it.
#
# So the debt is written down instead. A control that is already unmeasured is
# reported and tolerated; a NEW one is a failure, because that is somebody
# adding a control today and not timing it. And when a debt entry finally gets
# measured it is struck off, so the ratchet only ever turns one way.
$debtPath = Join-Path $SR_Root 'tests\perf-coverage-debt.json'
$debt = @()
if (Test-Path -LiteralPath $debtPath) {
    try { $debt = @((Get-Content -LiteralPath $debtPath -Raw | ConvertFrom-Json).unmeasured) } catch { $debt = @() }
}
if (-not $debt.Count) {
    @{ note = 'Controls wired but never timed. This list may shrink and must never grow - see the gate in perf-driver.ps1.'
       recordedAt = (Get-Date).ToString('s')
       unmeasured = $unmeasured } | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $debtPath -Encoding utf8
    Note ("recorded {0} unmeasured control(s) as the coverage debt; it may shrink from here and not grow" -f $unmeasured.Count)
} else {
    $fresh = @($unmeasured | Where-Object { $debt -notcontains $_ })
    $fixed = @($debt | Where-Object { $unmeasured -notcontains $_ })
    if ($fresh.Count) {
        Fail ("{0} control(s) were added without any timing: {1}" -f $fresh.Count, ($fresh -join ', '))
    } else {
        Note ("no new unmeasured controls; {0} still owed" -f $unmeasured.Count)
    }
    if ($fixed.Count) {
        Note ("{0} control(s) came off the coverage debt: {1}" -f $fixed.Count, ($fixed -join ', '))
        @{ note = 'Controls wired but never timed. This list may shrink and must never grow - see the gate in perf-driver.ps1.'
           recordedAt = (Get-Date).ToString('s')
           unmeasured = $unmeasured } | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $debtPath -Encoding utf8
    }
}

# 🪤 AND THE MAP MUST NOT ROT EITHER. A name here that no longer exists in
# the window means the map was edited and the window was not.
$stale = @($COVERAGE.Keys | Where-Object { $wired -notcontains $_ })
if ($stale.Count) { Fail ("the coverage map names {0} control(s) the window no longer has: {1}" -f $stale.Count, ($stale -join ', ')) }
else { Note 'every name in the coverage map is a control that still exists' }

Write-Host ''
Write-Host '=== the whole surface, slowest first ==='
# ---------------------------------------------------------------------------
# 🔴 HOW BUSY THE MACHINE IS, MEASURED, BECAUSE THE NUMBERS ABOVE ARE NOT
# COMPARABLE WITHOUT IT.
#
# This suite went red twice in one day on changes that were provably innocent.
# Both times the giveaway was untouched code moving with everything else:
# Test-OnSurface read 8.8 ms one hour and 25.9 the next, and Update-Model
# -KeepAgents 149.7 then 399.9, on identical source. Best-of-N does not save
# you - under real contention every sample is contended, so the floor rises with
# the ceiling and the fastest run is simply the least-slowed one.
#
# So the run states its own conditions. This is a pure CPU loop: no disk, no
# processes, no allocation to speak of - the only thing it can measure is how
# much of a core this process is actually getting. The baseline is what it reads
# on this machine with nothing else running.
#
# 🪤 IT REPORTS, IT DOES NOT SCALE THE BUDGETS. Dividing the limits by this
# would let a genuine regression hide behind a busy afternoon, which is the one
# thing a gate must never do. The budgets stay where they are; the reader is
# told what to make of a near miss.
# 🪤 A NUMBER TO COMPARE BETWEEN RUNS, NOT A LOAD FACTOR. The obvious version of
# this divides by an idle baseline and prints "2.9x busy" - and there is no
# honest way to get that baseline on a machine that is never idle. This one is
# also dominated by PowerShell's own loop cost rather than by contention, so a
# ratio built on it would be mostly interpreter and partly truth.
#
# What it is good for is DIFFERENCE. Run the suite twice and this number tells
# you whether the table moved because the code did or because the machine did,
# which is the only question that actually comes up. Recorded here so there is
# something to compare against: 337 ms on 2026-09-04 with 26 claude sessions
# running, on a 4090 machine that reads far lower when it is quiet.
$spinEnd = Measure-SRSpin
# The mean of the two ends, which is the best single description available of
# the machine WHILE the table was being taken.
$spinBest = ($script:SpinStart + $spinEnd) / 2.0
$spinDrift = [Math]::Max($script:SpinStart, $spinEnd) / [Math]::Max([Math]::Min($script:SpinStart, $spinEnd), 0.001)
$spinBusy = @(Get-Process -Name 'claude' -ErrorAction SilentlyContinue).Count
Write-Host ''
Write-Host ("  the machine, for comparing this run against another: a fixed CPU loop took {0:N0} ms" -f $spinBest) -ForegroundColor DarkGray
Write-Host ("  ({0:N0} before the table, {1:N0} after - drift {2:N2}x) with {3} claude session(s) running." -f `
    $script:SpinStart, $spinEnd, $spinDrift, $spinBusy) -ForegroundColor DarkGray
Write-Host  '  If that number moved and the table moved with it, the table moved because of the machine.' -ForegroundColor DarkGray

$over = New-Object System.Collections.Generic.List[object]
$atBar = 0; $nearBar = 0; $overBar = 0
foreach ($r in @($script:Results | Sort-Object -Property Ms -Descending)) {
    $lim = $LIMITS[$r.Class]
    $flag = ' '
    if ($r.Ms -gt $lim) { $flag = '!'; $over.Add($r) }
    # 🔑 DISTANCE FROM THE TERMINAL, ON EVERY ROW. The class budget says whether
    # a person would notice; this says how far it is from the thing the operator
    # actually compares it against. Both are printed because they answer
    # different questions and one of them used to be missing entirely.
    $vs = ''
    if ($r.Class -eq 'GESTURE' -or $r.Class -eq 'INSTANT') {
        if ($r.Ms -le $SR_BAR)        { $vs = 'at bar';  $atBar++ }
        elseif ($r.Ms -le $SR_FRAME)  { $vs = '1 frame'; $nearBar++ }
        else { $vs = ('{0,5:N0}x bar' -f ($r.Ms / $SR_BAR)); $overBar++ }
    }
    Write-Host ("  {0} {1,8:N1} ms  {2,-8} {3,-9} {4}" -f $flag, $r.Ms, $r.Class, $vs, $r.Name) -ForegroundColor $(
        if ($r.Ms -gt $lim) { 'Yellow' } elseif ($r.Ms -gt $lim / 2) { 'Gray' } else { 'DarkGray' })
}

Write-Host ''
Write-Host ("  AGAINST THE TERMINAL ({0:N1} ms): {1} at the bar, {2} inside one frame, {3} over." -f `
    $SR_BAR, $atBar, $nearBar, $overBar) -ForegroundColor $(if ($overBar) { 'Yellow' } else { 'Green' })
Write-Host  '  This line does not fail the suite - see the note on $SR_BAR. It is the standard,' -ForegroundColor DarkGray
Write-Host  '  and the gate below is whether anything got WORSE than it was.' -ForegroundColor DarkGray
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
# ===========================================================================
# 🔴 THE GATE IS "DID THIS COMMIT MAKE SOMETHING SLOWER", NOT "IS THIS UNDER 50 ms".
#
# WHAT WAS HERE BEFORE, AND WHY IT HAD TO GO. The old rule decided "code, not
# machine" from a NARROW best-to-worst spread: a wide spread meant the operation
# was contending and was excused, a narrow one meant the number was real and
# failed. That inference is backwards under sustained load. When the whole
# machine is busy EVERY sample is contended, so the floor rises with the ceiling
# and the spread NARROWS - the exact condition it treats as proof of code.
#
# Measured 2026-09-05, and it is why this was rewritten: the rule fired on TEN
# operations at once, while UNTOUCHED code in the same run had moved further
# than the code that had just changed -
#
#     sort sessions: project   41.7 -> 127.6 ms   3.06x   UNTOUCHED
#     Build-Sessions           37.9 -> 106.1 ms   2.80x   UNTOUCHED
#     Build-Manager            37.3 ->  75.1 ms   2.01x   just edited
#
# with the spin loop going 88 -> 163 ms. The comment this replaces already
# admitted the spread guard could not see this; the answer at the time was to
# SOFTEN the gate rather than fix the detector, which is how a suite ends up
# unable to fail honestly in either direction.
#
# 🔑 THE SPIN LOOP IS THE FIX. It is a fixed CPU workload measured in the SAME
# run, so it says how fast this machine was while these numbers were taken.
# Comparing an operation against a baseline recorded with ITS OWN spin cancels
# the machine out: expected = baseline * (spinNow / spinThen).
#
# 🪤 IT DOES NOT AUTO-RATCHET, AND THE FIRST VERSION OF THIS GATE DID.
#
# That version rewrote the baseline whenever an operation came in faster, to
# "lock in the win". Run it twice on IDENTICAL source and it fails: the baseline
# converges on the luckiest sample ever recorded, and every ordinary run
# afterwards reads as a regression against it. Measured immediately - the second
# run flagged four operations, all untouched, up to 1.89x.
#
# A baseline for a noisy metric has to be a TYPICAL number, not a minimum. So it
# is recorded once and left alone; improvements are reported and deliberately do
# not tighten the gate. SR_PERF_REBASELINE takes the current numbers on purpose.
# ===========================================================================
$softGate = [bool]$env:SR_PERF_SOFT

$baseSpin = 0.0
$baseOps  = @{}
if (Test-Path -LiteralPath $SR_BaselinePath) {
    try {
        $bj = Get-Content -LiteralPath $SR_BaselinePath -Raw | ConvertFrom-Json
        $baseSpin = [double]$bj.spin
        foreach ($p in $bj.ops.PSObject.Properties) { $baseOps[$p.Name] = [double]$p.Value }
    } catch {
        Write-Host ('  [warn] the perf baseline is unreadable, recording a fresh one: ' + $_.Exception.Message) -ForegroundColor Yellow
        $baseSpin = 0.0; $baseOps = @{}
    }
}

# 🪤 NORMALISATION IS A CORRECTION, NOT A CONVERSION. The spin is pure CPU and
# these operations are WPF, disk and interpreter, so the adjustment is only
# trustworthy over a modest range. Far outside it, report and do not fail:
# extrapolating a 4x-busier machine onto a WPF layout is a guess, and a guess
# that fails the build is exactly the wolf-crying this file was written against.
$spinRatio = 1.0
$spinTrust = $false
if ($baseSpin -gt 0 -and $spinBest -gt 0) {
    $spinRatio = $spinBest / $baseSpin
    # 🪤 AND THE RUN HAS TO HAVE BEEN STEADY WHILE IT WAS TAKEN. A run whose two
    # spin readings disagree by more than half was measured across a machine
    # that changed underneath it, so no single normaliser describes it and the
    # early rows and the late rows are not on the same scale.
    $spinTrust = ($spinRatio -ge 0.33 -and $spinRatio -le 3.0 -and $spinDrift -le 1.5)
}

$newOps = @{}
$regressed = New-Object System.Collections.Generic.List[object]
$improved  = 0
$added     = 0
# 🔑 HOW CLOSE THIS RUN CAME, PRINTED WHETHER OR NOT ANYTHING FAILED. Without it
# the only visible states are "green" and "over the line", which says nothing
# about the margin - and the margin is the whole question when the threshold is
# a judgement call. It is also how $SR_RegressAt was set: run the suite
# repeatedly on IDENTICAL source, read this number, and put the threshold above
# the spread the machine produces on its own.
$worstRatio = 0.0
$worstName  = ''

foreach ($r in $script:Results) {
    if ($r.Threw -or $r.Ms -le 0) { continue }
    $norm = $r.Ms / [Math]::Max($spinBest, 0.001)
    if (-not $baseOps.ContainsKey($r.Name)) {
        $newOps[$r.Name] = $norm; $added++
        continue
    }
    $wasNorm  = $baseOps[$r.Name]
    $expected = $wasNorm * $spinBest
    # A floor, because a ratio on a sub-millisecond operation is all noise: 0.1 ms
    # against 0.05 is "twice as slow" and means nothing anyone can perceive.
    if ($expected -lt 2.0 -and $r.Ms -lt 2.0) { $newOps[$r.Name] = $wasNorm; continue }
    # 🪤 ONLY AMONG OPERATIONS THAT COULD ACTUALLY FAIL. Reporting the worst
    # ratio across everything reports the noise floor of the smallest operation
    # in the suite - which is how the first version of this line said "1.75x,
    # threshold 1.60x" about a two-millisecond difference.
    $ratio = $norm / [Math]::Max($wasNorm, 0.000001)
    if (($r.Ms - $expected) -ge $SR_RegressMinMs -and $ratio -gt $worstRatio) {
        $worstRatio = $ratio; $worstName = $r.Name
    }
    if ($norm -gt $wasNorm * $SR_RegressAt -and ($r.Ms - $expected) -ge $SR_RegressMinMs) {
        $regressed.Add([PSCustomObject]@{ Name = $r.Name; Ms = $r.Ms; Expected = $expected; Was = ($wasNorm * $baseSpin) })
        $newOps[$r.Name] = $wasNorm
        continue
    }
    if ($norm -lt $wasNorm) { $improved++ }
    # 🔴 THE ENVELOPE FOLLOWS A SUSTAINED WIN DOWN, AT 10% A RUN, AND NO FASTER.
    #
    # It used to be kept flat forever, and that had a consequence nobody had
    # looked for: an envelope that never lowers cannot notice a landed fix being
    # REVERTED. Proof, from this repo's own history - `git diff 3cffa7e c263dba
    # -- tests/perf-baseline.json` changes only recordedAt and spin, so
    # "Set-Surface manage" still carried the figure it had BEFORE 5b63bfd taught
    # it to skip an 80 ms Build-Manager. Deleting $script:mgrDirty outright would
    # have stayed green.
    #
    # 🪤 AND IT STILL CANNOT CONVERGE ON THE LUCKIEST RUN, which is what killed
    # the first two gate designs. The floor is THIS run's own reading, so a
    # single lucky sample writes back at most 0.9x - and the next ordinary run
    # computes max(was, 0.81 x was) = was and puts it straight back. Only an op
    # that reads below 0.9x the envelope on EVERY run walks it down, which is
    # what "sustained" has to mean. A real 3x win arrives in about eleven runs;
    # noise never moves it more than one step, and never twice.
    $newOps[$r.Name] = [Math]::Max($norm, $wasNorm * 0.9)
}

Write-Host ''
if (-not $baseOps.Count) {
    Write-Host ("  BASELINE RECORDED - {0} operation(s) at a spin of {1:N0} ms. Nothing to compare against yet;" -f $added, $spinBest) -ForegroundColor Cyan
    Write-Host  '  the next run is the first that can catch a regression.' -ForegroundColor DarkGray
} elseif (-not $spinTrust) {
    if ($spinDrift -gt 1.5) {
        Write-Host ("  MACHINE MOVED DURING THE RUN: the spin loop read {0:N0} ms before the table and {1:N0} ms after ({2:N2}x)." -f `
            $script:SpinStart, $spinEnd, $spinDrift) -ForegroundColor Yellow
        Write-Host  '  Early and late rows are not on the same scale, so nothing is failed on this run.' -ForegroundColor DarkGray
    } else {
        Write-Host ("  MACHINE TOO DIFFERENT TO JUDGE: the spin loop reads {0:N0} ms against {1:N0} ms when the baseline" -f $spinBest, $baseSpin) -ForegroundColor Yellow
        Write-Host ("  was recorded ({0:N2}x). The table is printed and nothing is failed - normalising that far is a guess." -f $spinRatio) -ForegroundColor DarkGray
    }
} else {
    Write-Host ("  REGRESSION GATE: machine is {0:N2}x the baseline (spin {1:N0} against {2:N0} ms)." -f $spinRatio, $spinBest, $baseSpin) -ForegroundColor DarkGray
    if ($regressed.Count) {
        foreach ($g in $regressed) {
            $msg = ('{0} is {1:N0} ms where this machine predicts {2:N0} ms ({3:N0} ms when the baseline was taken) - {4:N2}x slower than it was' -f `
                    $g.Name, $g.Ms, $g.Expected, $g.Was, ($g.Ms / [Math]::Max($g.Expected, 0.001)))
            if ($softGate) { Write-Host ('  SLOWER  ' + $msg) -ForegroundColor Yellow }
            else { Fail $msg }
        }
        if ($softGate) {
            Write-Host '  (full-suite run: reported only. Run -Only perf to have a regression fail the suite.)' -ForegroundColor DarkGray
        }
    } else {
        Write-Host ("  nothing got slower. {0} improved, {1} new." -f $improved, $added) -ForegroundColor Green
    }
    if ($worstName) {
        Write-Host ("  closest to the line: {0} at {1:N2}x its baseline (fails above {2:N2}x AND +{3:N0} ms)." -f `
            $worstName, $worstRatio, $SR_RegressAt, $SR_RegressMinMs) -ForegroundColor DarkGray
    } else {
        Write-Host ("  nothing was even {0:N0} ms slower than predicted." -f $SR_RegressMinMs) -ForegroundColor DarkGray
    }
}

# 🔒 THE BASELINE IS ONLY REWRITTEN WHEN IT CAN BE TRUSTED, and never in a way
# that hides a regression: a regressed operation keeps its OLD figure above, so
# writing here records the improvements and the new operations and nothing else.
# SR_PERF_REBASELINE is the escape hatch for a deliberate, accepted slowdown -
# it takes the current numbers as the new truth, which is a thing to do on
# purpose and never by default.
# 🔴 THE BASELINE IS AN ENVELOPE, NOT A READING, AND IT TAKES SEVERAL RUNS.
#
# Two earlier designs failed against measurement, both on IDENTICAL source:
#   1. ratchet to the best-ever value -> converges on the luckiest run, then
#      fails everything afterwards (4 false alarms on the second run);
#   2. one reading + spin normalisation -> still 3 false alarms per run, at up
#      to 2.49x, on 15-60 ms operations.
#
# 🪤 THE SECOND FAILURE IS THE INFORMATIVE ONE. The spin loop was ROCK STEADY
# across those runs - 15, 16, 17, 16 ms - while `search: sessions box only`
# swung 14 -> 34 ms. So the variance in these operations is not CPU contention
# at all; it is GC timing and WPF's own state, which a Math::Sqrt loop cannot
# see and therefore cannot correct for. Normalising harder was never going to
# work, because the normaliser is blind to the thing that moves.
#
# What DOES describe it is the operation's own spread. So rebaselining takes the
# MAX of what it already held and what this run measured: run it a few times on
# healthy code and the baseline grows into the envelope that code produces on
# this machine. The gate then asks "is this outside the envelope", which is a
# question the data can actually answer.
if ($env:SR_PERF_REBASELINE) {
    $widened = 0
    foreach ($r in $script:Results) {
        if ($r.Threw -or $r.Ms -le 0) { continue }
        $n = $r.Ms / [Math]::Max($spinBest, 0.001)
        if ($newOps.ContainsKey($r.Name)) {
            if ($n -gt $newOps[$r.Name]) { $newOps[$r.Name] = $n; $widened++ }
        } else { $newOps[$r.Name] = $n; $widened++ }
    }
    Write-Host ("  SR_PERF_REBASELINE - the envelope was widened for {0} operation(s) by this run." -f $widened) -ForegroundColor Magenta
    Write-Host  '  Run this a few times on healthy code; the baseline is the worst each one honestly does.' -ForegroundColor DarkGray
}
if ($spinTrust -or -not $baseOps.Count -or $env:SR_PERF_REBASELINE) {
    try {
        $payload = [ordered]@{
            recordedAt = (Get-Date).ToString('s')
            spin       = [Math]::Round($spinBest, 3)
            note       = 'ops values are ms-per-spin-ms; expected = value * spinNow. See the gate in perf-driver.ps1.'
            ops        = ([ordered]@{})
        }
        foreach ($k in @($newOps.Keys | Sort-Object)) { $payload.ops[$k] = [Math]::Round($newOps[$k], 6) }
        ($payload | ConvertTo-Json -Depth 5) | Set-Content -LiteralPath $SR_BaselinePath -Encoding utf8
    } catch { Write-Host ('  [warn] could not write the perf baseline: ' + $_.Exception.Message) -ForegroundColor Yellow }
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
# 🔴 A SOFT RUN THAT FOUND REGRESSIONS IS NOT A PASS, and calling it one is how
# four commit messages came to say "all seven suites pass" while meaning nothing
# whatever about speed. The full sweep sets SR_PERF_SOFT so a noisy ride-along
# cannot fail the build - that part is deliberate and stays. What was wrong is
# that the summary then printed `perf PASS` beside the other six, so the sentence
# "all suites passed" read as "and nothing got slower".
#
# Exit 2 is the runner's INCONCLUSIVE: yellow in the summary, not counted as a
# failure. The sweep still passes; it can no longer be quoted as perf evidence.
# 🔴 A RUN THAT COULD NOT TELL MUST NOT SAY "NOTHING GOT SLOWER". Same defect as
# the soft gate above, and it bites more often: this machine runs 25 claude
# sessions, the spin drifted 1.74x on the very run that verified today's fixes,
# and every failure was suppressed while the summary still printed PASS. The
# suppression itself is RIGHT - early and late rows really are not on one scale,
# and failing the build on an extrapolation is the wolf-crying this file exists
# to avoid. What was wrong is calling the silence a pass.
#
# 🪤 IT IS NOT A FAILURE EITHER. Nothing has been shown to be slower; the
# instrument simply had no footing. INCONCLUSIVE is the honest third answer, and
# the run is worth repeating on a quieter machine rather than acting on.
if ($baseOps.Count -and -not $spinTrust) {
    Write-Host 'the regression gate could not assert on this run - the machine moved underneath it, so nothing was compared.' -ForegroundColor Yellow
    exit 2
}
if ($softGate -and $regressed.Count) {
    Write-Host ("{0} operation(s) got slower - reported, not failed. Run -Only perf for the hard gate." -f $regressed.Count) -ForegroundColor Yellow
    exit 2
}
Write-Host 'nothing on the surface stalls the window' -ForegroundColor Green
exit 0
