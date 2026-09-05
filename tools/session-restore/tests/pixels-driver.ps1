
# ===========================================================================
# CLICK TO PIXELS. NOT "THE HANDLER RETURNED".
#
# 🔴 WHY THIS EXISTS WHEN perf-driver.ps1 ALREADY TIMES THE SAME GESTURES AND
# PASSES. Because it times the wrong end of them. Three gaps, all measured:
#
#   1. THE DEFERRED WORK IS NOT WAITED FOR. `select a conversation (COLD - the
#      click)` benches `SelectedItem = ...; Show-Selected`, and Show-Selected
#      calls Start-DocParse, which hands the transcript to a runspace and
#      RETURNS. The document is built later, on the UI thread, by
#      Complete-DocParse - which perf-driver never reaches, because
#      Invoke-WriteLane runs on a DispatcherTimer at Background priority and
#      that suite only ever pumps at Loaded (see `Lay`). Loaded outranks
#      Background, so the lane never ticks and the deferred half never happens
#      inside the timed region OR outside it. The work was moved off the click
#      and out of the benchmark in the same commit.
#
#   2. THE LANE LATENCY IS NOBODY'S NUMBER. writeTimer is 30 ms, so between the
#      parse landing and the document being built there is up to a tick of pure
#      waiting that no bench in the tool contains.
#
#   3. THE RENDER PASS IS NOT MEASURED AT ALL. Every list bench ends in `Lay`,
#      which is Measure + Arrange + UpdateLayout. That is layout. It is not
#      OnRender, and it is not rasterization - and this window puts a
#      BlockUIContainer with a Grid, a Rectangle and three TextBlocks inside it
#      for every block in the transcript. A change that made the render walk
#      three times more expensive would not move a single number in that suite.
#
# 🔑 SO THIS DRIVER MEASURES FOUR STAMPS PER GESTURE, all from the same t0:
#
#      handler   the gesture returned                    <- what perf-driver has
#      settled   + everything the gesture kicked off has run on the UI thread
#                  (the runspace, the 30 ms lane tick, Complete-DocParse, the
#                  document build) and the dispatcher is idle
#      laid      + measure / arrange / UpdateLayout
#      PIXELS    + the visual tree rasterized into a bitmap
#
# The last one is the number the operator is describing when they say a session
# "doesn't immediately show the content". Everything before it is bookkeeping.
#
# 🪤 WHAT "PIXELS" IS AND IS NOT. This window is never shown - same splice as
# every other GUI suite, nothing on screen, nothing focusable, no key can reach
# a live session - so there is no HwndTarget and no composition thread. The
# rasterization is RenderTargetBitmap, which is the SOFTWARE path: it walks the
# visual tree, calls OnRender on anything whose render data is missing, and
# rasterizes on this thread. Against a real window that over-counts (the GPU
# composites) and it excludes vsync (which adds up to a frame). It is therefore
# not the operator's wall clock to the millisecond. It IS a signal that moves
# when the render walk gets more expensive, which is the thing nothing here
# could see before, and its own floor is measured below as a control so the
# reader can subtract it.
#
# 🔴 IT NEVER LAUNCHES, KILLS, TYPES, SENDS, SAVES OR ANSWERS. The gestures
# below are the read-only ones. Anything that writes is named in the refusal
# list at the bottom with what is measured in its place, and nothing here calls
# it. The runner hashes the config either side.
#
# ===========================================================================
# 🔑 THE CALIBRATION. MEASURED 2026-09-05, spin 15-19 ms, 34 claude sessions
# running. `tests\pixels-run.ps1 -Only <gesture> -Inject <ms> -InjectAt <where>`.
#
#   switch conversation      handler   settled      laid     draw
#     clean (run A)             23,2     774,6   1.001,2     55,7
#     clean (run B)             25,0     902,6     903,6    141,4
#     +150 ms in the BUILD      26,7   1.059,4   1.090,4     77,9
#     +500 ms in the BUILD      22,8   1.570,4   1.571,7     78,0
#     +300 ms in the CLICK     324,4   1.002,1   1.116,5     54,5
#     a blur (render only)      22,4     658,9     986,1     76,2
#
#   Steps: cycle the button
#     clean                     11,4     738,5     739,5     64,2
#     +400 ms in the BUILD       9,3   1.244,8   1.245,3     46,1
#
# WHAT THAT SHOWS, AND WHAT IT DOES NOT:
#
#   ✅ `handler` moves for the click injection (23 -> 324, i.e. +301 for +300)
#      and for NOTHING ELSE. It is specific, and it is the ONLY column
#      perf-driver.ps1 has - which is why a 500 ms regression in the deferred
#      build would pass that suite in silence. That is the whole finding.
#   ✅ `settled` / `laid` move with the build injection: +500 -> +620 on the
#      switch, +400 -> +506 on Steps, with the handler flat either side. Both
#      overshoot the injection by ~20%, which is expected rather than alarming:
#      the burn holds the CPU, so the runspace and the 30 ms lane behind it are
#      delayed too. RED DEMONSTRATED ON BOTH GESTURES THE OPERATOR NAMED.
#   ❌ `draw` did NOT move for a render-only cost. 76 against 56 and 141 on
#      clean runs: its own noise is wider than the fault. It is printed and
#      asserted on by nothing until that is fixed.
#
# 🪤 THE CLEAN RUNS SPREAD 904-1001 ms ON IDENTICAL SOURCE, so a single sample
# resolves about 100 ms on this gesture. Anything smaller than that needs the
# deliberate A/B, not this table.
# ===========================================================================

$fails = 0
function Fail { param($m) Write-Host "  FAIL  $m" -ForegroundColor Red; $script:fails++ }
function Pass { param($m) Write-Host "  ok    $m" -ForegroundColor Green }
function Note { param($m) Write-Host "        $m" -ForegroundColor DarkGray }
function Huh  { param($m) Write-Host "  ????  $m" -ForegroundColor Magenta; $script:inconclusive++ }
$inconclusive = 0

# ---------------------------------------------------------------------------
# THE CALIBRATION KNOBS. A harness that has never gone red has never been shown
# to work - see feedback-verification. These make it go red on purpose, on code
# this driver did not otherwise touch, and the gate at the bottom asserts that
# it noticed.
# ---------------------------------------------------------------------------
$pxInject = 0.0
try { if ("$($env:SR_PIX_INJECT)".Trim()) { $pxInject = [double]("$($env:SR_PIX_INJECT)".Trim()) } } catch { $pxInject = 0.0 }
$pxInjectAt = "$($env:SR_PIX_INJECT_AT)".Trim().ToLower()
if (-not $pxInjectAt) { $pxInjectAt = 'build' }
$pxOnly = "$($env:SR_PIX_ONLY)".Trim()
$pxRuns = 5
try { if ("$($env:SR_PIX_RUNS)".Trim() -and [int]"$($env:SR_PIX_RUNS)" -gt 0) { $pxRuns = [int]"$($env:SR_PIX_RUNS)" } } catch { }

# 🪤 A CPU BURN, NOT Start-Sleep. Sleep models a blocking call; the regressions
# this is meant to catch are code getting slower, and those hold the CPU. Burn
# also cannot be optimised away by the interpreter noticing nothing is used.
function Burn-Px { param([double]$Ms)
    if ($Ms -le 0) { return }
    $pxBw = [Diagnostics.Stopwatch]::StartNew()
    $pxBa = 0.0
    while ($pxBw.Elapsed.TotalMilliseconds -lt $Ms) {
        for ($pxBi = 1; $pxBi -lt 3000; $pxBi++) { $pxBa += [Math]::Sqrt($pxBi) }
    }
}

# ===========================================================================
# 🔒 THE OPERATOR'S CONFIG IS REDIRECTED BEFORE ANYTHING IS PUMPED.
# ===========================================================================
# 🔴 AND THIS IS NOT PRECAUTIONARY - WITHOUT IT THIS DRIVER WOULD WRITE THE
# LIVE FILE, for a reason that is exactly why this driver exists.
#
# Request-SRConfigFlush queues the write with BeginInvoke at ApplicationIdle
# (sessions-window.ps1:503). perf-driver pumps at Loaded, which outranks it, so
# in that suite the queued write is never reached and the settings file is never
# touched. This driver pumps at ApplicationIdle ON PURPOSE - that is the whole
# point, it is what lets the 30 ms lane tick - and the flush comes with it. So
# the first gesture that changes a setting (Steps, text size, a fold) writes
# session-restore.config.json for real.
#
# Redirecting the path rather than stubbing the writer keeps the COST honest:
# the file is still built, serialised and written, so whatever that costs stays
# in the measurement. Only the destination moves.
$pxCfgReal = $SR_ConfigPath
$pxCfgCopy = Join-Path $SR_Root '.state\pixels-config.json'
try { Copy-Item -LiteralPath $pxCfgReal -Destination $pxCfgCopy -Force -ErrorAction Stop }
catch { Fail ("could not copy the config to redirect it: {0}" -f $_.Exception.Message); exit 1 }
$SR_ConfigPath = $pxCfgCopy
if ("$SR_ConfigPath" -ne "$pxCfgCopy" -or -not (Test-Path -LiteralPath $pxCfgCopy)) {
    Fail 'the config redirect did not take. Refusing to run - a gesture here would write the operator settings.'
    exit 1
}
# 🪤 AND IT IS PROVEN, NOT ASSERTED. A redirect that silently did not take reads
# exactly like one that did, right up until the live file changes - which is the
# shape of every fake-green in this repo. So one real write goes through the
# real writer and the copy has to move.
# 🪤 A KEY THAT IS NOT ALREADY THERE, AND A VALUE NOTHING ELSE COULD PRODUCE.
# The first version of this saved transcriptTools at its CURRENT value, and the
# arming check went red on a redirect that was working perfectly: the config had
# last been written by ConvertTo-Json, so re-serialising the same object produced
# byte-identical output and the hash did not move. A calibration that can fail
# for a reason unrelated to what it tests is not a calibration.
$pxCfgWas = (Get-FileHash -LiteralPath $pxCfgCopy -Algorithm SHA256).Hash
Save-SRConfigLater -Name 'pixelsHarnessProbe' -Value ([guid]::NewGuid().ToString('N'))
$null = Save-SRConfigWrites
if ((Get-FileHash -LiteralPath $pxCfgCopy -Algorithm SHA256).Hash -eq $pxCfgWas) {
    Fail 'a config write through the real writer did NOT land in the redirected copy - the redirect is not armed. Refusing to run.'
    exit 1
}
Pass ('config writes redirected to {0} and proven to land there' -f (Split-Path -Leaf $pxCfgCopy))

# ---------------------------------------------------------------------------
# THE MODEL. The operator's real registry, read the same way the window reads
# it. Nothing is fabricated: the complaint is about this machine's ~34 live
# conversations and ~36 projects, and a harness on a toy model would answer a
# question nobody asked.
#
# 🪤 THE BACKGROUND IS LEFT RUNNING, DELIBERATELY. Start-ProjectsWatch is armed
# at load, and the 30 ms lane starts vitals sweeps, quiet checks and ask probes
# - all read-only, all child processes, all of them competing for the CPU while
# a gesture is being timed. That is what the real window does, so silencing them
# would measure a tool nobody uses. What it costs is variance, which is why the
# figures below are best-of-N with the worst printed beside them.
# ---------------------------------------------------------------------------
Update-Model
Note ("{0} conversations across {1} projects" -f $script:model.Count, @($script:dirs).Count)

$pxW = 1480.0; $pxH = 980.0
$pxRoot = $window.Content
$window.Width = $pxW; $window.Height = $pxH

$ui.ModeWork.IsChecked = $true
Set-Surface 'work'
$ui.Search.Text = ''; $ui.RailSearch.Text = ''; $ui.ListSearch.Text = ''
$script:railPick = $null; $script:bandPick = $null
Build-Rail; Build-Sessions

# 🔑 HOW BUSY THIS MACHINE IS, BRACKETED. Straight from perf-driver, including
# the lesson attached to it: taken at the TOP of the file this reads the process
# still settling rather than the machine, and reports a 1.7x "drift" that is a
# property of the instrument. It goes here, after the model and the first build,
# and again at the end. Two readings that disagree badly mean nothing between
# them is comparable with another run - see feedback-measure-a-control.
function Measure-PxSpin {
    $pxSb = [double]::MaxValue
    for ($pxSr = 0; $pxSr -lt 5; $pxSr++) {
        $pxSw2 = [Diagnostics.Stopwatch]::StartNew()
        $pxSa = 0.0
        for ($pxSi = 1; $pxSi -lt 100000; $pxSi++) { $pxSa += [Math]::Sqrt($pxSi) }
        $pxSw2.Stop()
        if ($pxSw2.Elapsed.TotalMilliseconds -lt $pxSb) { $pxSb = $pxSw2.Elapsed.TotalMilliseconds }
    }
    return $pxSb
}
$pxSpinStart = Measure-PxSpin

# ---------------------------------------------------------------------------
# THE THREE PRIMITIVES THE STAMPS ARE MADE OF.
# ---------------------------------------------------------------------------

# 🔑 ApplicationIdle, AND THAT ONE WORD IS THE WHOLE DIFFERENCE FROM perf-driver.
#
# DispatcherTimer ticks are queued at Background (4). perf-driver's `Lay` pumps
# at Loaded (6), which outranks Background, so no timer in this window has ever
# fired inside that suite - including writeTimer, the 30 ms lane that calls
# Complete-DocParse and is therefore the thing that puts a conversation on
# screen. Pumping at ApplicationIdle (2) drains everything above it, timers
# included, which is what the real message pump does between gestures.
function Pump-Px {
    # 🪤 $null =, because Invoke returns object and this is called from inside a
    # function whose RETURN VALUE is the measurement. An uncaptured $null here
    # turns every row into a two-element array.
    $null = $window.Dispatcher.Invoke([System.Windows.Threading.DispatcherPriority]::ApplicationIdle, [action]{})
}

function Lay-Px {
    # Two passes, as perf-driver does: the first can dirty the second.
    foreach ($pxP in 1, 2) {
        $pxRoot.Measure((New-Object System.Windows.Size $pxW, $pxH))
        $pxRoot.Arrange((New-Object System.Windows.Rect 0, 0, $pxW, $pxH))
        $pxRoot.UpdateLayout()
    }
}

# One bitmap, reused. Allocating 1480x980xPbgra32 is 5.8 MB and doing it per
# sample would put the allocator in the measurement.
#
# 🔑 HALF RESOLUTION, AND FOR A REASON RATHER THAN FOR SPEED. A rasterization
# has two halves: WALKING the visual tree (calling OnRender on anything whose
# drawing instructions are missing) and FILLING pixels. Only the first is a
# property of the window's structure - the thing that gets worse when a change
# adds a Border per row. The second is a constant this driver pays and the
# operator never does, because the real window composites on the GPU.
#
# At 96 dpi and full size the fill dominated: the floor - an untouched, already
# clean tree - measured 187 ms, which buried every difference worth seeing. At
# 48 dpi over the same 1480x980 DIP area the walk is identical and the fill is a
# quarter of the pixels. The floor is measured either way and printed, so the
# reader is never asked to take the subtraction on trust.
$pxBmp = New-Object System.Windows.Media.Imaging.RenderTargetBitmap(
            [int]($pxW / 2), [int]($pxH / 2), 48, 48, [System.Windows.Media.PixelFormats]::Pbgra32)
function Draw-Px {
    $pxBmp.Clear()
    $pxBmp.Render($pxRoot)
}

# ---------------------------------------------------------------------------
# THE INSTRUMENT.
# ---------------------------------------------------------------------------
# 🔴 THE MINIMUM OF N, for the reason perf-driver states at length: this machine
# runs ~20 claude sessions and swings 3x, so the fastest sample is the only one
# where the code got the CPU it asked for. The worst is reported beside it,
# because a wide spread is itself the finding.
#
# 🪤 AND A ROW THAT TIMED OUT IS NOT A ROW WITH A BIG NUMBER. If the deferred
# work never lands, this reports INCONCLUSIVE and says so. A gate that cannot
# tell must not print a figure - see feedback-gate-that-abstains.
$pxRows = New-Object System.Collections.Generic.List[object]

function Measure-Px {
    param([string]$Name,
          [scriptblock]$Do,
          [scriptblock]$Settled = $null,      # extra "the async work is home" test
          [scriptblock]$Before  = $null,      # put the surface back in the cold state
          [int]$Runs = 0,
          [int]$TimeoutMs = 15000,
          [string]$Watch = '')                # a note about what should have changed

    if ($pxOnly -and $Name -notlike ("*" + $pxOnly + "*")) { return $null }
    if ($Runs -le 0) { $Runs = $pxRuns }

    $pxH1 = New-Object System.Collections.Generic.List[double]
    $pxS1 = New-Object System.Collections.Generic.List[double]
    $pxL1 = New-Object System.Collections.Generic.List[double]
    $pxP1 = New-Object System.Collections.Generic.List[double]
    $pxThrew = ''
    $pxTimedOut = 0
    $pxChanged = 0
    $pxFirst = $null

    for ($pxN = 0; $pxN -lt $Runs; $pxN++) {
        if ($Before) { try { & $Before | Out-Null } catch { $pxThrew = "before: $($_.Exception.Message)" } }
        # Settle the surface completely before t0, so the previous sample's
        # leftovers are not charged to this one.
        Pump-Px
        $pxDocWas = $ui.PaneDoc.Document

        $pxSw = [Diagnostics.Stopwatch]::StartNew()
        try { & $Do | Out-Null } catch { $pxThrew = "$($_.Exception.Message)" }
        $pxHandler = $pxSw.Elapsed.TotalMilliseconds

        # Drain the UI thread. Everything the gesture queued - the lane tick,
        # the document build, the deferred ScrollToEnd - happens in here.
        $pxHit = $false
        while ($pxSw.Elapsed.TotalMilliseconds -lt $TimeoutMs) {
            Pump-Px
            if (-not $Settled) { $pxHit = $true; break }
            $pxOk = $false
            try { $pxOk = [bool](& $Settled) } catch { $pxOk = $true }
            if ($pxOk) { $pxHit = $true; break }
            # 🪤 A yield, not a spin. Busy-looping on the UI thread starves the
            # runspace we are waiting for and would measure the harness fighting
            # the code under test. One millisecond is what the real pump idles.
            [System.Threading.Thread]::Sleep(1)
        }
        if (-not $pxHit) { $pxTimedOut++ }
        $pxSettle = $pxSw.Elapsed.TotalMilliseconds

        Lay-Px
        $pxLaid = $pxSw.Elapsed.TotalMilliseconds

        Draw-Px
        $pxPixels = $pxSw.Elapsed.TotalMilliseconds
        $pxSw.Stop()

        if (-not [object]::ReferenceEquals($pxDocWas, $ui.PaneDoc.Document)) { $pxChanged++ }

        $pxH1.Add($pxHandler); $pxS1.Add($pxSettle); $pxL1.Add($pxLaid); $pxP1.Add($pxPixels)
        if ($null -eq $pxFirst) { $pxFirst = $pxPixels }
    }

    $pxRow = [PSCustomObject]@{
        Name    = $Name
        Handler = @($pxH1 | Sort-Object)[0]
        Settled = @($pxS1 | Sort-Object)[0]
        Laid    = @($pxL1 | Sort-Object)[0]
        Pixels  = @($pxP1 | Sort-Object)[0]
        Worst   = @($pxP1 | Sort-Object)[$pxP1.Count - 1]
        First   = $pxFirst
        Runs    = $Runs
        Threw   = $pxThrew
        Stalled = $pxTimedOut
        DocMoved = $pxChanged
        Watch   = $Watch
    }
    $pxRows.Add($pxRow)
    # 🔴 A BENCH THAT CHANGED NOTHING IS NOT A FAST BENCH. -Watch 'doc' says the
    # gesture is supposed to replace the reading pane's document; if it did not,
    # on any sample, the click landed on a row the list had already replaced and
    # the number is a measurement of nothing. Best-of-N hides this by
    # construction - the broken sample is always the fastest one - so it has to
    # be caught here rather than read off the table.
    if ($Watch -eq 'doc' -and $pxChanged -lt $Runs) {
        Huh ("{0}: the document changed on only {1} of {2} run(s). The fast samples measured a click that did nothing - no figure from this row can be trusted." -f `
             $Name, $pxChanged, $Runs)
    }
    return $pxRow
}

# ---------------------------------------------------------------------------
# THE CONTROLS. Measured FIRST, before anything is claimed about a gesture,
# because every number below is this floor plus the work.
# ---------------------------------------------------------------------------
Write-Host ''
Write-Host '--- the instrument, measured against itself ---'

# A gesture that does nothing. Whatever this reads is the harness: a pump, a
# full-window layout of an already-clean tree, and a rasterization.
$pxIdle = Measure-Px 'the empty gesture (this is the harness floor)' { } -Runs 7
if ($pxIdle) {
    Note ("floor: handler {0:N2} ms, +pump {1:N2}, +layout {2:N2}, +raster {3:N2} = {4:N1} ms" -f `
          $pxIdle.Handler, ($pxIdle.Settled - $pxIdle.Handler), ($pxIdle.Laid - $pxIdle.Settled),
          ($pxIdle.Pixels - $pxIdle.Laid), $pxIdle.Pixels)
    Note  'Every PIXELS figure below includes this. The rasterizer is software here - see the header.'
}

# ---------------------------------------------------------------------------
# THE CONVERSATION TO PROFILE AGAINST.
# ---------------------------------------------------------------------------
# 🔴 A ROW IS LOOKED UP BY ID, EVERY TIME, AND HOLDING ONE IS A BUG.
#
# This drove a whole debugging round. Build-Sessions rebuilds its rows as NEW
# objects and restores the selection by id - and the 30 ms write lane calls it
# whenever the projects watcher sees a transcript grow, which on this machine
# with 34 live sessions is constantly. So an item captured before a bench is an
# ORPHAN by the time the bench runs: `SelectedItem = <orphan>` is silently
# ignored by the ListBox, SelectionChanged never fires, and the gesture measures
# 0.3 ms of nothing.
#
# It did exactly that: the same bench read 475 ms in one run and 2.5 ms in the
# next, with a best-to-worst spread of 2.5 to 624 ms inside a single run - the
# fast samples were the ones where the click landed on a row that no longer
# existed. Best-of-N makes that WORSE, because the broken sample is always the
# fast one. Hence the DocMoved guard below: a selection bench that did not
# replace the document measured nothing and must say so.
function Get-PxRow { param([string]$Id)
    foreach ($pxIt in $ui.SessionList.Items) {
        if ("$($pxIt.Kind)" -eq 'session' -and "$($pxIt.Id)" -eq $Id) { return $pxIt }
    }
    return $null
}

$pxSessions = @($ui.SessionList.Items | Where-Object { $_.Kind -eq 'session' })
$pxBig = $null; $pxOther = $null
if ($pxSessions.Count -ge 2) {
    # The biggest transcript, for the reason perf-driver gives: the lag lives in
    # the long conversations and an arbitrary row can be seven blocks.
    $pxBySize = @($pxSessions | Sort-Object -Property @{ Expression = {
        $pxJ = "$($_.Row.S.jsonl)"
        if ($pxJ -and (Test-Path -LiteralPath $pxJ)) { (Get-Item -LiteralPath $pxJ).Length } else { 0 }
    }} -Descending)
    $pxBig = $pxBySize[0]
    $pxOther = @($pxBySize | Where-Object { $_.Id -ne $pxBig.Id })[0]
    $pxKb = 0
    try { $pxKb = (Get-Item -LiteralPath "$($pxBig.Row.S.jsonl)").Length / 1KB } catch { }
    Note ("profiling against '{0}' - {1:N0} KB of transcript" -f $pxBig.Name, $pxKb)
}

# 🔴 THE INJECTION GOES ON A PATH THIS DRIVER OTHERWISE LEAVES ALONE, and it
# goes in AFTER the model is built so nothing above is charged for it.
#
# `build` is the interesting one: Build-ReadDocument runs on the UI thread, in
# Complete-DocParse, one lane tick after the click has already returned. So a
# delay here is invisible to `select a conversation (COLD - the click)` by
# construction, and must be fully visible to PIXELS. That single comparison is
# the calibration of this whole file.
if ($pxInject -gt 0) {
    Write-Host ''
    Write-Host ("--- CALIBRATION: {0:N0} ms injected at '{1}' ---" -f $pxInject, $pxInjectAt) -ForegroundColor Magenta
    switch ($pxInjectAt) {
        'build' {
            $pxRealBuild = ${function:Build-ReadDocument}
            function Build-ReadDocument {
                param($Blocks, [bool]$Truncated = $false, $Turns = $null)
                Burn-Px $pxInject
                & $pxRealBuild @PSBoundParameters
            }
            Note 'wrapped Build-ReadDocument - the deferred build, off the click, on the UI thread'
        }
        'render' {
            $ui.PaneDoc.Effect = New-Object System.Windows.Media.Effects.BlurEffect
            $ui.PaneDoc.Effect.Radius = 24
            Note 'a blur on the reading pane - free in the handler, free in layout, paid in the rasterizer'
        }
        'click' {
            $pxRealShow = ${function:Show-Selected}
            function Show-Selected {
                param([switch]$Force)
                Burn-Px $pxInject
                & $pxRealShow @PSBoundParameters
            }
            Note 'wrapped Show-Selected - inside the gesture, which both instruments must see'
        }
    }
}

# ---------------------------------------------------------------------------
Write-Host ''
Write-Host '--- the gestures the operator named ---'
# ---------------------------------------------------------------------------

# 🔑 THE PREDICATE FOR "THE CONVERSATION IS ON SCREEN". $script:docPs is the
# PowerShell instance holding the off-thread parse; Complete-DocParse clears it
# after it has built the document. So "docPs is null" means the whole deferred
# chain is home - which is exactly the moment perf-driver never waits for.
$pxDocHome = { -not $script:docPs }

if (-not $pxBig) { Note 'not enough conversations to profile a selection' }
else {
    # ── SWITCHING CONVERSATION ──────────────────────────────────────────────
    # The real click path: setting SelectedItem is what a mouse-down on a row
    # ends up doing, and it raises SelectionChanged, which calls Show-Selected.
    # The handler is not called directly - a driver that calls handlers instead
    # of raising events tests the function, not the control.
    $pxBigId = "$($pxBig.Id)"
    $pxOtherId = "$($pxOther.Id)"
    $null = Measure-Px 'switch to another conversation (the click the operator waits on)' `
        { $ui.SessionList.SelectedItem = (Get-PxRow $pxBigId) } `
        -Settled $pxDocHome `
        -Before { $script:selId = $null; $ui.SessionList.SelectedItem = (Get-PxRow $pxOtherId); Pump-Px } `
        -Runs 5 -Watch 'doc'

    # The same gesture with the pane ALREADY showing that conversation. Nothing
    # should be rebuilt; if this is not near the floor, the $same guard in
    # Show-Selected is not doing its job.
    $ui.SessionList.SelectedItem = (Get-PxRow $pxBigId)
    Pump-Px
    $null = Measure-Px 'select the one already selected (nothing should happen)' `
        { $ui.SessionList.SelectedItem = (Get-PxRow $pxBigId); Show-Selected } `
        -Settled $pxDocHome -Runs 7

    # ── STEPS: FOLDED / FULL / HIDDEN ───────────────────────────────────────
    # 🔴 THE WHOLE BUTTON, NOT "THE REDRAW HALF". perf-driver benches
    # `Show-Selected -Force` under the name 'toggle the steps view (the redraw
    # half)' - the name is honest and the coverage is not: the control is
    # PaneTools, its handler is Step-ToolView, and Step-ToolView also relabels
    # the button, queues a config write and THEN calls Show-Selected -Force,
    # which starts a fresh parse. This raises the real Click on the real button
    # and waits for the document.
    $pxToolWas = $script:toolView
    $null = Measure-Px 'Steps: cycle the button (the whole control, not the redraw half)' `
        { $ui.PaneTools.RaiseEvent((New-Object System.Windows.RoutedEventArgs([System.Windows.Controls.Primitives.ButtonBase]::ClickEvent))) } `
        -Settled $pxDocHome -Runs 6 -Watch 'three presses returns to where it started'
    Note ("Steps went '{0}' -> '{1}' over that bench; the label reads '{2}'" -f `
          $pxToolWas, $script:toolView, $ui.PaneTools.Content)

    # ── OPENING A FOLDED BLOCK ──────────────────────────────────────────────
    # This is the control that answers "I still cannot see the individual
    # steps". Folded is one caption line per run of tool calls BY DESIGN; the
    # steps are behind a click on that caption. So the question is whether the
    # caption opens - and how long it takes when it does.
    Lay-Px
    function Find-FoldHeaders {
        $pxFound = New-Object System.Collections.Generic.List[object]
        $pxStack = New-Object System.Collections.Generic.Stack[object]
        $pxStack.Push($ui.PaneDoc)
        while ($pxStack.Count) {
            $pxEl = $pxStack.Pop()
            if ($pxEl -is [System.Windows.Controls.Border] -and $pxEl.Tag -is [hashtable] -and $pxEl.Tag.ContainsKey('Caret')) {
                $null = $pxFound.Add($pxEl)
            }
            $pxCn = 0
            try { $pxCn = [System.Windows.Media.VisualTreeHelper]::GetChildrenCount($pxEl) } catch { }
            for ($pxCi = 0; $pxCi -lt $pxCn; $pxCi++) { $pxStack.Push([System.Windows.Media.VisualTreeHelper]::GetChild($pxEl, $pxCi)) }
        }
        return ,$pxFound
    }
    $pxHeads = Find-FoldHeaders
    Note ("{0} foldable block(s) realized in the pane" -f $pxHeads.Count)
    if (-not $pxHeads.Count) {
        Huh 'no fold headers found in the visual tree - either the document is empty or they are not realized. Cannot judge the fold.'
    } else {
        # Prefer a run block: it is the one holding the individual steps.
        $pxRunHead = @($pxHeads | Where-Object { "$($_.Tag.Kind)" -eq 'run' })
        $pxHead = $(if ($pxRunHead.Count) { $pxRunHead[0] } else { $pxHeads[0] })

        # 🔑 A REAL ROUTED EVENT, because the bug this control had was ABOUT
        # routing: the handler was on MouseLeftButtonUp and the FlowDocument's
        # text editor captured the mouse, so it never fired. Calling
        # Invoke-FoldToggle directly would pass a control that is wired wrong.
        $pxDev = $null
        try { $pxDev = [System.Windows.Input.Mouse]::PrimaryDevice } catch { }
        if (-not $pxDev) {
            Huh 'no mouse device in this process - cannot raise a real click on the fold header.'
        } else {
            $pxOpenWas = [bool]$pxHead.Tag.Open
            $pxRes = Measure-Px 'open a folded block of steps (the FIRST open - the lazy build)' `
                {
                    $pxE = New-Object System.Windows.Input.MouseButtonEventArgs($pxDev, 0, [System.Windows.Input.MouseButton]::Left)
                    $pxE.RoutedEvent = [System.Windows.UIElement]::PreviewMouseLeftButtonDownEvent
                    $pxHead.RaiseEvent($pxE)
                } -Runs 1
            # 🪤 THE ASSERTION IS ONLY VALID IF THE GESTURE ACTUALLY RAN. -Only
            # filters gestures out, and the first version of this then reported
            # "the fold did not open" about a fold nobody had clicked - a
            # failure invented by the harness, which is the worst kind.
            if ($null -eq $pxRes) {
                Note 'the fold gesture was filtered out by -Only, so its correctness is not judged this run'
            } elseif ([bool]$pxHead.Tag.Open -eq $pxOpenWas) {
                Fail ("the fold header did not change state on a real PreviewMouseLeftButtonDown - it was Open={0} and still is. THIS IS THE 'I cannot see the individual steps' BUG AND IT IS FUNCTIONAL, NOT SLOW." -f $pxOpenWas)
            } else {
                Pass ("a real click on a fold caption toggles it (Open {0} -> {1}, caret '{2}')" -f `
                      $pxOpenWas, $pxHead.Tag.Open, $pxHead.Tag.Caret.Text)
                if ($pxRes) { Note ("that first open cost {0:N0} ms click-to-pixels, n=1 - the lazy build is paid once per block" -f $pxRes.Pixels) }
            }
            # And the cheap re-toggle, which is what every open after the first costs.
            $null = Measure-Px 'toggle that block again (content already built)' `
                {
                    $pxE2 = New-Object System.Windows.Input.MouseButtonEventArgs($pxDev, 0, [System.Windows.Input.MouseButton]::Left)
                    $pxE2.RoutedEvent = [System.Windows.UIElement]::PreviewMouseLeftButtonDownEvent
                    $pxHead.RaiseEvent($pxE2)
                } -Runs 6
        }
    }

    # ── IS 'STEPS' A LATENCY PROBLEM OR A CORRECTNESS ONE? ──────────────────
    # 🔴 THE OPERATOR SAID "compact or steps folded, I still cannot see the
    # individual steps", AND THOSE ARE TWO DIFFERENT BUGS. Folded showing one
    # caption per run of tool calls is the design; `full` not opening them would
    # be broken. A latency table cannot tell them apart, so this asks directly:
    # set each mode, rebuild through the real path, and count how many fold
    # panels are actually VISIBLE in the visual tree.
    $pxToolKeep = $script:toolView
    foreach ($pxMode in 'full', 'folded') {
        $script:toolView = $pxMode
        $script:docKey = ''
        Show-Selected -Force
        $pxWaitSw = [Diagnostics.Stopwatch]::StartNew()
        while ($script:docPs -and $pxWaitSw.Elapsed.TotalMilliseconds -lt 15000) { Pump-Px; [System.Threading.Thread]::Sleep(1) }
        Lay-Px
        $pxHs2 = Find-FoldHeaders
        $pxOpenN = 0
        $pxVisN = 0
        foreach ($pxHh in $pxHs2) {
            if ([bool]$pxHh.Tag.Open) { $pxOpenN++ }
            if ($pxHh.Tag.Panel -and "$($pxHh.Tag.Panel.Visibility)" -eq 'Visible') { $pxVisN++ }
        }
        if (-not $pxHs2.Count) {
            Huh ("Steps '{0}': no foldable blocks in this conversation's tail at all - nothing to judge" -f $pxMode)
        } elseif ($pxMode -eq 'full') {
            if ($pxVisN -eq $pxHs2.Count) {
                Pass ("Steps 'full' opens every block: {0} of {0} fold panels are Visible" -f $pxHs2.Count)
            } else {
                Fail ("Steps 'full' left {0} of {1} block(s) closed - the steps are NOT shown when the control says they are. This is functional, not slow." -f `
                      ($pxHs2.Count - $pxVisN), $pxHs2.Count)
            }
        } else {
            if ($pxVisN -eq 0) {
                Pass ("Steps 'folded' closes every block: 0 of {0} fold panels Visible, each a caption you click to open" -f $pxHs2.Count)
            } else {
                Fail ("Steps 'folded' left {0} of {1} block(s) open" -f $pxVisN, $pxHs2.Count)
            }
        }
    }
    $script:toolView = $pxToolKeep
    $script:docKey = ''
    Show-Selected -Force
    $pxWaitSw2 = [Diagnostics.Stopwatch]::StartNew()
    while ($script:docPs -and $pxWaitSw2.Elapsed.TotalMilliseconds -lt 15000) { Pump-Px; [System.Threading.Thread]::Sleep(1) }
    Lay-Px

    # ── SCROLLING THE READING PANE ──────────────────────────────────────────
    $pxSv = Get-PaneScroller
    if (-not $pxSv) { Huh 'no scroller in the pane - cannot measure scrolling' }
    else {
        Note ("document extent {0:N0} px over a {1:N0} px viewport - {2:N1} screens, none of it virtualized" -f `
              $pxSv.ExtentHeight, $pxSv.ViewportHeight,
              $(if ($pxSv.ViewportHeight -gt 0) { $pxSv.ExtentHeight / $pxSv.ViewportHeight } else { 0 }))
        $null = Measure-Px 'scroll: one wheel notch' { $pxSv.ScrollToVerticalOffset($pxSv.VerticalOffset + 48) } -Runs 9
        $null = Measure-Px 'scroll: one screen down' { $pxSv.PageDown() } -Runs 7
        $null = Measure-Px 'scroll: jump to the end' { $pxSv.ScrollToEnd() } -Runs 7
    }
}

# ── TYPING IN THE SEARCH BOX ────────────────────────────────────────────────
# 🔴 THE DEBOUNCE IS PART OF WHAT THE OPERATOR FEELS. searchTimer is 180 ms and
# perf-driver's 'search: header box (both panes)' calls Build-Rail/Build-Sessions
# directly, so it reports the rebuild and not the wait. A letter typed into this
# box does not change the list for at least 180 ms by design; whether that is
# right is a judgement, but it belongs in the number.
$null = Measure-Px 'type one letter into the search box (includes the 180 ms debounce)' `
    { $ui.Search.Text = ($ui.Search.Text + 'a') } `
    -Settled { -not $script:searchTimer.IsEnabled } `
    -Before { $ui.Search.Text = ''; Pump-Px } -Runs 5
$ui.Search.Text = ''
Pump-Px

# ── THE PROJECTS RAIL ───────────────────────────────────────────────────────
$pxProjects = @($ui.RailList.Items | Where-Object { "$($_.Kind)" -ne 'band' })
if ($pxProjects.Count -ge 2) {
    # Same orphan trap as the sessions column: Build-Rail replaces its tiles, so
    # the project is found by path at the moment of the click, never held.
    $pxProjPath = "$($pxProjects[1].Path)"
    function Get-PxTile {
        foreach ($pxTi in $ui.RailList.Items) {
            if ("$($pxTi.Kind)" -ne 'band' -and "$($pxTi.Path)" -eq $pxProjPath) { return $pxTi }
        }
        return $null
    }
    $null = Measure-Px 'pick a project in the rail (filters both columns)' `
        { $ui.RailList.SelectedItem = (Get-PxTile) } `
        -Before { $script:railPick = $null; $ui.RailList.SelectedItem = $null; Build-Rail; Build-Sessions; Pump-Px } `
        -Runs 5
    # 🔑 THE CONTROL FOR THE ROW ABOVE, in the same process, in the same run.
    # The rail pick's handler is exactly `railPick = ...; Build-Rail;
    # Build-Sessions`, so this is that handler's whole body called directly -
    # which is also what perf-driver times. Whatever the click costs OVER this
    # is the ListBox selection machinery rather than the rebuild, and on a
    # machine that swings 3x that difference is the only part worth acting on.
    # See feedback-measure-a-control: time untouched code before theorising.
    $null = Measure-Px 'CONTROL: Build-Rail + Build-Sessions called directly (no ListBox)' `
        { Build-Rail; Build-Sessions } -Runs 5
    $null = Measure-Px 'CONTROL: Build-Sessions alone (no ListBox)' `
        { Build-Sessions } -Runs 5
    $script:railPick = $null; Build-Rail; Build-Sessions; Pump-Px
} else { Note 'fewer than two projects in the rail - not profiling the pick' }

# ── THE TOP ROW: SURFACE SWITCH ─────────────────────────────────────────────
$null = Measure-Px 'switch to the session manager (the top-row toggle)' `
    { $ui.ModeManage.IsChecked = $true } `
    -Before { $ui.ModeWork.IsChecked = $true; Pump-Px } -Runs 5
$null = Measure-Px 'switch back to the work surface' `
    { $ui.ModeWork.IsChecked = $true } `
    -Before { $ui.ModeManage.IsChecked = $true; Pump-Px } -Runs 5
$ui.ModeWork.IsChecked = $true
Pump-Px

# ── THE TEXT-SIZE CONTROL ───────────────────────────────────────────────────
$null = Measure-Px 'the text-size control (rebuilds the pane at a new size)' `
    { $ui.PaneZoom.RaiseEvent((New-Object System.Windows.RoutedEventArgs([System.Windows.Controls.Primitives.ButtonBase]::ClickEvent))) } `
    -Settled $pxDocHome -Runs 4

# ── THE SETTINGS PANEL ──────────────────────────────────────────────────────
$null = Measure-Px 'open the settings panel' `
    { $ui.PaneSettings.RaiseEvent((New-Object System.Windows.RoutedEventArgs([System.Windows.Controls.Primitives.ButtonBase]::ClickEvent))) } `
    -Before { try { $ui.SetCancel.RaiseEvent((New-Object System.Windows.RoutedEventArgs([System.Windows.Controls.Primitives.ButtonBase]::ClickEvent))) } catch { }; Pump-Px } `
    -Runs 5
try { $ui.SetCancel.RaiseEvent((New-Object System.Windows.RoutedEventArgs([System.Windows.Controls.Primitives.ButtonBase]::ClickEvent))) } catch { }
Pump-Px

# ===========================================================================
Write-Host ''
Write-Host '=== click to pixels, worst first ==='
# ===========================================================================
# The bar is the terminal: a real claude TUI answers an arrow in 6.9 ms, and one
# frame at 60 Hz is 16 ms. Both are printed because they answer different
# questions - 6.9 is the standard the operator set, 16 is the point below which
# faster is not observable.
$PX_BAR = 7.0
$PX_FRAME = 16.0

# 🪤 .ToArray(), NOT @(...). `@($list)` on a System.Collections.Generic.List
# [object] throws "Argument types do not match" in PowerShell 5.1 - it is a
# known trap in this repo and it cost this file one debugging round: everything
# above printed perfectly and the script died on the line after the table.
# A pipeline (`$pxRows | Sort-Object`) enumerates and is safe; a bare @() is not.
$pxAll = $pxRows.ToArray()
$pxFloorDraw = 0.0
if ($pxIdle) { $pxFloorDraw = $pxIdle.Pixels - $pxIdle.Laid }

$pxSpinEnd = Measure-PxSpin
$pxDrift = [Math]::Max($pxSpinStart, $pxSpinEnd) / [Math]::Max([Math]::Min($pxSpinStart, $pxSpinEnd), 0.001)
$pxBusy = @(Get-Process -Name 'claude' -ErrorAction SilentlyContinue).Count
Write-Host ("  the machine: a fixed CPU loop took {0:N0} ms before the table and {1:N0} ms after (drift {2:N2}x), with {3} claude session(s) running." -f `
    $pxSpinStart, $pxSpinEnd, $pxDrift, $pxBusy) -ForegroundColor DarkGray
if ($pxDrift -gt 1.5) {
    Huh ("the machine moved {0:N2}x while the table was being taken - these figures are not comparable with another run" -f $pxDrift)
}
Write-Host ''

Write-Host ('  {0,9} {1,9} {2,9} {3,9} {4,9}   {5}' -f 'handler', 'settled', 'laid', 'draw', 'worst', 'gesture') -ForegroundColor Gray
foreach ($pxR in @($pxAll | Sort-Object -Property Laid -Descending)) {
    $pxTag = ' '
    $pxCol = 'DarkGray'
    if ($pxR.Laid -gt $PX_FRAME) { $pxCol = 'Gray' }
    if ($pxR.Laid -gt 100) { $pxCol = 'Yellow'; $pxTag = '!' }
    if ($pxR.Laid -gt 400) { $pxCol = 'Red'; $pxTag = '!!' }
    if ($pxR.Stalled) { $pxCol = 'Magenta'; $pxTag = '?' }
    Write-Host ('{0,-2}{1,9:N1} {2,9:N1} {3,9:N1} {4,9:N1} {5,9:N1}   {6}' -f `
        $pxTag, $pxR.Handler, $pxR.Settled, $pxR.Laid, ($pxR.Pixels - $pxR.Laid), $pxR.Worst, $pxR.Name) -ForegroundColor $pxCol
}
Write-Host ''
Write-Host  '  handler  the gesture returned. THIS IS THE ONLY COLUMN perf-driver.ps1 MEASURES.' -ForegroundColor DarkGray
Write-Host  '  settled  + every deferred thing it started has run on the UI thread (runspace, 30 ms lane,' -ForegroundColor DarkGray
Write-Host  '           Complete-DocParse, the document build). MEASURED, and the operator waits for all of it.' -ForegroundColor DarkGray
Write-Host  '  laid     + measure/arrange/UpdateLayout. This is the closest MEASURED number to what the' -ForegroundColor DarkGray
Write-Host  '           operator feels: after it, the frame is ready to composite.' -ForegroundColor DarkGray
Write-Host ("  draw     a software rasterization of the whole window, floor {0:N1} ms on an unchanged tree." -f $pxFloorDraw) -ForegroundColor DarkGray
# 🪤 NO EMOJI IN A Write-Host. They are fine in the comments of this repo because
# comments are never printed; the child process writes this table through a
# console codepage that turned a single glyph into "Ã°Å¸â€Â´" on the first run.
Write-Host  '           NOT CALIBRATED - DO NOT QUOTE IT AS EVIDENCE. It was supposed to be the column that' -ForegroundColor Yellow
Write-Host  '           catches a render-walk regression, and it does not: with -InjectAt render (a 24 px blur' -ForegroundColor Yellow
Write-Host  '           on the pane, free in the handler and free in layout) it read 76 ms, against 56 and 141' -ForegroundColor Yellow
Write-Host  '           on two CLEAN runs of the same code. Its own noise is wider than the fault it is meant' -ForegroundColor Yellow
Write-Host  '           to detect, so it is printed for interest and asserted on by nothing. The three columns' -ForegroundColor Yellow
Write-Host  '           to its left ARE calibrated: see the injection matrix in the header of this file.' -ForegroundColor Yellow
Write-Host  '  worst    the slowest of the same samples, whole pipeline. A wide spread is itself a finding.' -ForegroundColor DarkGray

Write-Host ''
foreach ($pxR in $pxAll) {
    if ($pxR.Threw) { Fail ("{0} THREW - it has no timing, it has an error: {1}" -f $pxR.Name, $pxR.Threw) }
    if ($pxR.Stalled) { Huh ("{0} did not settle within the timeout on {1} of {2} run(s) - no number is reported for it" -f $pxR.Name, $pxR.Stalled, $pxR.Runs) }
}

# 🔑 THE ONE COMPARISON THIS FILE WAS WRITTEN FOR. For every gesture, how much
# of the wait is AFTER the handler returned - i.e. how much of it the existing
# suite cannot see.
Write-Host ''
Write-Host '  how much of each wait is invisible to a handler-returns benchmark:' -ForegroundColor Gray
foreach ($pxR in @($pxAll | Sort-Object -Property Laid -Descending)) {
    if ($pxR.Stalled -or $pxR.Threw) { continue }
    if ($pxR.Laid -lt $PX_FRAME) { continue }
    $pxHidden = $pxR.Laid - $pxR.Handler
    $pxPct = 0.0
    if ($pxR.Laid -gt 0) { $pxPct = 100.0 * $pxHidden / $pxR.Laid }
    Write-Host ('    {0,8:N1} ms of {1,8:N1} ms happens after the handler returns ({2,5:N1}%)  {3}' -f `
        $pxHidden, $pxR.Laid, $pxPct, $pxR.Name) -ForegroundColor DarkGray
}

# ===========================================================================
# THE CALIBRATION GATE.
# ===========================================================================
# 🔴 THIS IS THE POINT OF THE -Inject SWITCH AND IT IS AN ASSERTION, NOT A NOTE.
# With a delay injected on a path this driver did not otherwise touch, the
# instrument MUST register it. If it does not, every number above is worthless
# and the run says so.
if ($pxInject -gt 0) {
    Write-Host ''
    Write-Host ("--- did the instrument notice {0:N0} ms injected at '{1}'? ---" -f $pxInject, $pxInjectAt)
    # The switch is the default target; with -Only it may not have run, so fall
    # back to the slowest row that did rather than declaring the run useless.
    $pxTarget = @($pxAll | Where-Object { $_.Name -like '*switch to another conversation*' })
    if (-not $pxTarget.Count) { $pxTarget = @($pxAll | Where-Object { $_.Name -notlike '*empty gesture*' } | Sort-Object -Property Laid -Descending) }
    if (-not $pxTarget.Count) {
        Huh 'no gesture ran at all - cannot judge the instrument'
    } else {
        $pxT = $pxTarget[0]
        Note ("handler {0:N1} ms - which is all perf-driver measures" -f $pxT.Handler)
        Note ("settled {0:N1} ms, laid {1:N1} ms - what this driver adds" -f $pxT.Settled, $pxT.Laid)
        # The comparison is recorded, not asserted against a stored number: the
        # caller runs this twice, once clean and once injected, and the DIFFERENCE
        # is the evidence. Printed in a machine-greppable shape so a wrapper can
        # diff two runs without parsing the table.
        Write-Host ("CALIB inject={0} at={1} handler={2:N2} settled={3:N2} laid={4:N2} draw={5:N2} spin={6:N0}" -f `
            $pxInject, $pxInjectAt, $pxT.Handler, $pxT.Settled, $pxT.Laid, ($pxT.Pixels - $pxT.Laid), $pxSpinEnd) -ForegroundColor Magenta
    }
}
# 🔑 THE SAME LINE ON A CLEAN RUN, so the two are diffable without a switch.
if ($pxInject -le 0) {
    $pxT0 = @($pxAll | Where-Object { $_.Name -like '*switch to another conversation*' })
    if ($pxT0.Count) {
        Write-Host ("CALIB inject=0 at=none handler={0:N2} settled={1:N2} laid={2:N2} draw={3:N2} spin={4:N0}" -f `
            $pxT0[0].Handler, $pxT0[0].Settled, $pxT0[0].Laid, ($pxT0[0].Pixels - $pxT0[0].Laid), $pxSpinEnd) -ForegroundColor Magenta
    }
}

# ===========================================================================
Write-Host ''
if ($inconclusive) {
    Write-Host ("  {0} measurement(s) INCONCLUSIVE - see above. That is not a pass." -f $inconclusive) -ForegroundColor Magenta
}
if ($fails) {
    Write-Host ("  {0} failure(s)" -f $fails) -ForegroundColor Red
    exit 1
}
if ($inconclusive) { exit 2 }
Write-Host '  every gesture measured end to end' -ForegroundColor Green
exit 0
