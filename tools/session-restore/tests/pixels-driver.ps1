
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
# 🪤 AND ONE FIGURE FROM THIS FILE WAS QUOTED WRONG BY ITS OWN AUTHOR. An
# earlier version of this header reported the optimal-paragraph line breaker as
# "3,7x to 4,8x", full stop. A second lane measured 1,23-1,35x and was right to
# challenge it. A ratio is NOT a portable quantity: anything common to both
# halves of an A/B sits in the numerator and the denominator and drags it toward
# 1, so two honest brackets give two honest ratios. The DELTAS agree (159, 125,
# 74, 25 ms across four measurements on documents of different sizes) and the
# delta is the physical saving. Quote deltas in work orders; quote a ratio only
# beside the method that produced it. Full reconciliation in the A/B block.
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
# The bar is the terminal: a real claude TUI answers an arrow in 6.9 ms
# (bench-term.ps1 / bench-claude.ps1, 2026-09-04), and one frame at 60 Hz is
# 16 ms. Declared up here because the idle watch below uses the same bar the
# gesture table does - they are the same standard asked at two moments.
$PX_BAR = 7.0
$PX_FRAME = 16.0
$pxRuns = 5
try { if ("$($env:SR_PIX_RUNS)".Trim() -and [int]"$($env:SR_PIX_RUNS)" -gt 0) { $pxRuns = [int]"$($env:SR_PIX_RUNS)" } } catch { }

# ===========================================================================
# THE KEYSTROKE PROBE - the operator's complaint, measured directly.
# ===========================================================================
# 🔴 "navigating up and down feels laggy ... whenever I type something, I answer
# a question, I want to go back and forth" IS NOT A GESTURE-COST QUESTION. It is
# "when I press a key, how long before this window answers me", and the answer
# depends on what the UI thread happens to be doing at that instant - which no
# table of gesture costs can show.
#
# A real keystroke arrives from the OS on another thread and is queued at
# DispatcherPriority.Input. So this is a BACKGROUND THREAD that queues an empty
# operation at exactly that priority and times how long the UI thread takes to
# get to it. Nothing above Input can be pre-empted, so if a 400 ms rebuild is
# running the probe waits 400 ms - which is precisely what the operator's finger
# experiences.
#
# 🪤 IT IS C#, NOT A POWERSHELL RUNSPACE, AND THAT IS NOT PREFERENCE. A
# scriptblock marshalled to a delegate belongs to the runspace that created it;
# handing one to another thread's Dispatcher.Invoke is exactly the shape that
# produces a hang or a wrong-thread throw. A compiled Action closure has no
# runspace and no affinity.
#
# 🪤 AND IT MEASURES A KEY THAT DOES NOTHING. A real key would type into a live
# session; this queues an EMPTY action, so it measures the wait and never the
# work, and it can never reach anything the operator owns.
Add-Type -ReferencedAssemblies 'WindowsBase' -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Threading;
using System.Windows.Threading;

public static class SRKeyProbe
{
    public static List<double> Waits = new List<double>();
    private static Dispatcher _d;
    private static volatile bool _run;
    private static Thread _t;

    public static void Start(Dispatcher d, int everyMs)
    {
        _d = d; _run = true;
        Waits = new List<double>();
        _t = new Thread(delegate() {
            while (_run)
            {
                Stopwatch sw = Stopwatch.StartNew();
                try { _d.Invoke(DispatcherPriority.Input, new Action(delegate() { })); }
                catch { }
                sw.Stop();
                lock (Waits) { Waits.Add(sw.Elapsed.TotalMilliseconds); }
                Thread.Sleep(everyMs);
            }
        });
        _t.IsBackground = true;
        _t.Start();
    }

    public static double[] Stop()
    {
        _run = false;
        if (_t != null) { _t.Join(2000); _t = null; }
        lock (Waits) { return Waits.ToArray(); }
    }
}
'@

function Report-PxKeys { param([string]$When, [double[]]$Waits)
    if (-not $Waits -or $Waits.Count -lt 3) { Huh ("no keystroke samples for '{0}' - the probe did not run" -f $When); return }
    $pxKs = @($Waits | Sort-Object)
    $pxKmed = $pxKs[[int]($pxKs.Count / 2)]
    $pxK90 = $pxKs[[int]($pxKs.Count * 0.9)]
    $pxKmax = $pxKs[$pxKs.Count - 1]
    $pxKover = @($pxKs | Where-Object { $_ -gt $PX_BAR }).Count
    Note ("{0}: {1} synthetic keystrokes - median {2:N1} ms, 90th {3:N1} ms, worst {4:N0} ms; {5} of {1} over the 6,9 ms terminal bar ({6:N0}%)" -f `
          $When, $pxKs.Count, $pxKmed, $pxK90, $pxKmax, $pxKover, (100.0 * $pxKover / $pxKs.Count))
}

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
          [string]$Watch = '',                # a note about what should have changed
          # 🔑 WHICH LAYOUT THE `laid` STAMP PAYS FOR, and it is load-bearing
          # rather than a convenience. 'window' is two full Measure/Arrange
          # passes over the whole tree, which is what a gesture that changes a
          # column width really costs. 'pane' is one UpdateLayout of the reading
          # pane alone, which is what isolates the document. Quoting a number
          # from one as if it came from the other is how two lanes end up with
          # a 3x disagreement about the same property - see the reconciliation
          # block further down.
          [string]$Lay = 'window')

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

        switch ($Lay) {
            'pane' {
                # One pass over the reading pane only, at the size it is arranged
                # to on the work surface. perf-driver's LayPane, same reasoning:
                # swapping a document does not re-arrange the session list, so
                # charging the document with the window's layout is a lie.
                $pxPw = [Math]::Max(300.0, $ui.PaneDoc.ActualWidth)
                $pxPh = [Math]::Max(300.0, $ui.PaneDoc.ActualHeight)
                $ui.PaneDoc.Measure((New-Object System.Windows.Size $pxPw, $pxPh))
                $ui.PaneDoc.Arrange((New-Object System.Windows.Rect 0, 0, $pxPw, $pxPh))
                $ui.PaneDoc.UpdateLayout()
            }
            'none'  { }
            default { Lay-Px }
        }
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
    # 🔴 THE BIGGEST FILE IS NOT THE BIGGEST DOCUMENT, AND FOR ONE EVENING THIS
    # HARNESS WAS MEASURING ITSELF.
    #
    # perf-driver picks the largest transcript by BYTES and this copied it. On
    # this machine the largest transcript is THE SESSION RUNNING THE HARNESS, and
    # its last 96 KB is two records - one enormous tool call and one enormous
    # result, which is this file's own output table. So the pane rendered 2 turns
    # and 0 fold blocks, the document extent fell 5.020 -> 1.399 px across the
    # evening as those outputs grew, and the optimal-paragraph A/B collapsed to
    # 0,96x because there was almost no prose left to break lines in. I came
    # within one message of reporting that as a regression in the reading pane.
    #
    # Verified by parsing the four largest transcripts directly: this session
    # yields 2 blocks; the next three yield 27, 25 and 27. The parse was never
    # wrong. The SELECTION was measuring the observer.
    #
    # 🔑 SO IT PICKS BY WHAT THE PANE ACTUALLY HAS TO RENDER. Parse the tails of
    # the largest few and take the one with the most blocks. Six parses at ~30 ms
    # is a rounding error against this run, and it is the difference between
    # profiling a real conversation and profiling this file's own output.
    $pxBig = $pxBySize[0]
    $pxBestN = -1
    foreach ($pxCand in @($pxBySize | Select-Object -First 6)) {
        $pxCj = "$($pxCand.Row.S.jsonl)"
        if (-not $pxCj -or -not (Test-Path -LiteralPath $pxCj)) { continue }
        $pxCb = @()
        # 🪤 Assign, THEN wrap. Get-SRTranscriptBlocks ends in a comma guard, so
        # @(Get-SRTranscriptBlocks ...) is ONE element holding the whole array.
        try { $pxGot0 = Get-SRTranscriptBlocks -JsonlPath $pxCj -MaxRecords 220 -MaxTailBytes $script:tailBytes; $pxCb = @($pxGot0) } catch { }
        if ($pxCb.Count -gt $pxBestN) { $pxBestN = $pxCb.Count; $pxBig = $pxCand }
    }
    $pxOther = @($pxBySize | Where-Object { $_.Id -ne $pxBig.Id })[0]
    $pxKb = 0
    try { $pxKb = (Get-Item -LiteralPath "$($pxBig.Row.S.jsonl)").Length / 1KB } catch { }
    Note ("profiling against '{0}' - {1:N0} KB of transcript, {2} block(s) in the tail." -f $pxBig.Name, $pxKb, $pxBestN)
    Note  'Chosen by BLOCKS IN THE TAIL, not by file size: the largest file here is the session running this harness.'
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
# 🔑 A SYNTHETIC KEYSTROKE EVERY 40 ms FOR THE WHOLE OF THE TABLE BELOW. The
# gesture rows say what each click costs; this says what pressing a key costs
# WHILE the window is doing that work, which is the half of "laggy" a
# per-gesture table cannot express. Compared against the same probe on an idle
# window at the end of the run.
[SRKeyProbe]::Start($window.Dispatcher, 40)

# 🔑 THE PREDICATE FOR "THE CONVERSATION IS ON SCREEN". $script:docPs is the
# PowerShell instance holding the off-thread parse; Complete-DocParse clears it
# after it has built the document. So "docPs is null" means the whole deferred
# chain is home - which is exactly the moment perf-driver never waits for.
$pxDocHome = { -not $script:docPs }

# Whether a sub-agent link was actually present in the profiled conversation's
# tail today. It is a real control with a real cost; whether the operator's
# largest conversation happens to have spawned an agent inside the last 200 KB
# is not something this harness gets to decide, so the inventory says
# NOT PRESENT TODAY rather than failing or quietly claiming coverage.
$pxAgentSeen = $false
$pxFoldSeen = $false

# The device a synthesized mouse event needs. Looked up once, here, rather than
# inside the first block that happens to want it - the agent link needs it too
# and would have found it undefined whenever the fold block found no headers.
$pxDev = $null
try { $pxDev = [System.Windows.Input.Mouse]::PrimaryDevice } catch { }

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
    # 🔴 A BENCH THAT MEASURES FOLDING HAS TO ASK FOR A VIEW THAT FOLDS.
    # The bench above presses Steps SIX times - two full cycles - so it lands
    # back exactly where it started, which on this machine is 'hidden'. Under
    # 'hidden' a run of tool calls is not drawn AT ALL; that is the feature, and
    # it is the operator's own request ("I would expect the background commands
    # to not be shown at all"). So Find-FoldHeaders correctly found nothing, and
    # the harness turned that into "the reading pane has stopped folding",
    # printed the operator's words back as evidence, and failed the inventory
    # for a bench it had itself made impossible.
    #
    # 🪤 THE STATE THE PREVIOUS BENCH LEAVES BEHIND IS AN INPUT TO THIS ONE, and
    # an input nothing here owned. Same shape as the three gui2 assertions that
    # read whichever live conversation happened to sort first: not a wrong
    # answer, an unasked question.
    if ("$($script:toolView)" -ne 'folded') {
        $script:toolView = 'folded'
        Show-Selected -Force
        Lay-Px
    }
    $pxHeads = Find-FoldHeaders
    Note ("{0} foldable block(s) realized in the pane" -f $pxHeads.Count)
    if ($pxHeads.Count) { $pxFoldSeen = $true }
    if (-not $pxHeads.Count) {
        $pxSvF = Get-PaneScroller
        Huh ("NO FOLD BLOCK IN THE PANE AT ALL. The document is {0:N0} px over {1} turn(s). Earlier today this same conversation rendered 4 to 11. Either its tail is now all prose, or the reading pane has stopped folding - and 'I still cannot see the individual steps' is the operator's own words, so this must not be read as a pass." -f `
             $(if ($pxSvF) { $pxSvF.ExtentHeight } else { 0 }), @($script:docTurns).Count)
    } else {
        # Prefer a run block: it is the one holding the individual steps.
        $pxRunHead = @($pxHeads | Where-Object { "$($_.Tag.Kind)" -eq 'run' })
        $pxHead = $(if ($pxRunHead.Count) { $pxRunHead[0] } else { $pxHeads[0] })

        # 🔑 A REAL ROUTED EVENT, because the bug this control had was ABOUT
        # routing: the handler was on MouseLeftButtonUp and the FlowDocument's
        # text editor captured the mouse, so it never fired. Calling
        # Invoke-FoldToggle directly would pass a control that is wired wrong.
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

    # ── HOLDING THE DOWN ARROW ──────────────────────────────────────────────
    # 🔴 "navigating up and down feels laggy" IS THIS, AND IT IS THE WORST
    # GESTURE IN THE TOOL. There is no arrow handler at window level for the
    # sessions column - the ListBox moves the selection itself, which raises
    # SelectionChanged, which is Show-Selected, which is a whole transcript
    # parse and document build. So every row you pass through on the way to the
    # one you want starts a parse and abandons it.
    #
    # Eight rows, back to back, as fast as the code will take them, then the
    # wait for the document that finally survives.
    $null = Measure-Px 'hold the down arrow: step through 8 conversations' `
        {
            for ($pxAi = 0; $pxAi -lt 8; $pxAi++) {
                $pxNext = $ui.SessionList.SelectedIndex + 1
                if ($pxNext -lt @($ui.SessionList.Items).Count) { $ui.SessionList.SelectedIndex = $pxNext }
            }
        } `
        -Settled $pxDocHome `
        -Before { $script:selId = $null; $ui.SessionList.SelectedItem = (Get-PxRow $pxOtherId); Pump-Px } `
        -Runs 3

    # ── LOAD EARLIER ────────────────────────────────────────────────────────
    # The one deliberately expensive gesture, wired twice: an 'L' keypress and a
    # clickable line at the top of the document. Both double the tail.
    $pxTailKeep = $script:tailBytes
    $null = Measure-Px 'load earlier (doubles the transcript tail)' `
        { $script:tailBytes = $script:tailBytes * 2; Update-Document } `
        -Settled $pxDocHome `
        -Before { $script:tailBytes = $pxTailKeep; Pump-Px } -Runs 3
    $script:tailBytes = $pxTailKeep
    $script:docKey = ''
    Update-Document
    $pxW1 = [Diagnostics.Stopwatch]::StartNew()
    while ($script:docPs -and $pxW1.Elapsed.TotalMilliseconds -lt 15000) { Pump-Px; [System.Threading.Thread]::Sleep(1) }

    # ── DRILLING INTO A SUB-AGENT AND BACK OUT ──────────────────────────────
    # 🔴 THE AGENT LINK IS ONE OF THE CONTROLS perf-driver's COVERAGE CHECK
    # CANNOT SEE. It is built in code and wired with
    # `$op.Add_PreviewMouseLeftButtonDown`, and that suite's pattern only
    # recovers a code-built control when the handler is Add_Click AND names a
    # function. So this, the fold header, 'load earlier' and the drill-out
    # button are outside its count entirely - not on its debt list, not in its
    # total. Opening a sub-agent reads a whole second transcript.
    function Find-PxTagged { param([string]$Prop)
        $pxHits = New-Object System.Collections.Generic.List[object]
        $pxSt2 = New-Object System.Collections.Generic.Stack[object]
        $pxSt2.Push($ui.PaneDoc)
        while ($pxSt2.Count) {
            $pxE3 = $pxSt2.Pop()
            $pxTg = $null
            try { $pxTg = $pxE3.Tag } catch { }
            if ($pxTg -and $pxTg.PSObject -and $pxTg.PSObject.Properties[$Prop]) { $null = $pxHits.Add($pxE3) }
            $pxC2 = 0
            try { $pxC2 = [System.Windows.Media.VisualTreeHelper]::GetChildrenCount($pxE3) } catch { }
            for ($pxCj = 0; $pxCj -lt $pxC2; $pxCj++) { $pxSt2.Push([System.Windows.Media.VisualTreeHelper]::GetChild($pxE3, $pxCj)) }
        }
        return ,$pxHits
    }
    $pxAgents = Find-PxTagged 'Sub'
    if ($pxAgents.Count) { $pxAgentSeen = $true }
    if (-not $pxAgents.Count) {
        Note 'no sub-agent link in this conversation tail - the drill-in cannot be measured on this machine today'
    } elseif (-not $pxDev) {
        Huh 'no mouse device - cannot raise a real click on the agent link'
    } else {
        $pxLink = $pxAgents[0]
        $null = Measure-Px 'open a sub-agent transcript (drill in)' `
            {
                $pxE4 = New-Object System.Windows.Input.MouseButtonEventArgs($pxDev, 0, [System.Windows.Input.MouseButton]::Left)
                $pxE4.RoutedEvent = [System.Windows.UIElement]::PreviewMouseLeftButtonDownEvent
                $pxLink.RaiseEvent($pxE4)
            } -Settled $pxDocHome -Runs 2
        if ($script:agentOpen) {
            $null = Measure-Px 'come back out of the sub-agent' { Close-AgentDoc } -Settled $pxDocHome -Runs 2
        } else {
            Huh 'the agent link did not open a sub-agent - the drill-out could not be measured'
        }
        $script:docKey = ''
        Show-Selected -Force
        $pxW3 = [Diagnostics.Stopwatch]::StartNew()
        while ($script:docPs -and $pxW3.Elapsed.TotalMilliseconds -lt 15000) { Pump-Px; [System.Threading.Thread]::Sleep(1) }
        Lay-Px
    }

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
# 🔴 THE DEBOUNCE IS PART OF WHAT THE OPERATOR FEELS. perf-driver's 'search:
# header box (both panes)' calls Build-Rail/Build-Sessions directly, so it
# reports the rebuild and not the wait. A letter typed into this box does not
# change the list for at least one debounce interval by design; whether that
# interval is right is a judgement, but it belongs in the number.
#
# 🪤 THE INTERVAL IS READ, NOT WRITTEN DOWN. This row said "the 180 ms debounce"
# as a literal, and the constant was changed to 90 underneath it - so the table
# went on reporting a number the window had stopped using, in the one place a
# reader would go to check it. Interpolating the live value also means the
# baseline key CHANGES when the interval does, which is correct: a different
# debounce is a different operation, and comparing it against the old key would
# read as a regression or a win that is really a redefinition.
$null = Measure-Px ('type one letter into the search box (includes the {0:N0} ms debounce)' -f $script:searchTimer.Interval.TotalMilliseconds) `
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
# 🔑 AND WHAT THE 200 ms OF HANDLER IN IT ACTUALLY IS. Step-Zoom does three
# things before it returns - rewrite the type scale into the window resources,
# force the sessions list to regenerate, and rebuild the document - and the
# whole-control number cannot say which. Each is timed on its own here, in the
# same run, so the work order names a line rather than a function.
$null = Measure-Px '  of which: Set-SRTypeScale (rewrites the window type resources)' `
    { Set-SRTypeScale -Percent $script:Zoom } -Runs 5
$null = Measure-Px '  of which: SessionList.Items.Refresh() (regenerate every row)' `
    { $ui.SessionList.Items.Refresh() } -Runs 5

# ── THE SETTINGS PANEL ──────────────────────────────────────────────────────
$null = Measure-Px 'open the settings panel' `
    { $ui.PaneSettings.RaiseEvent((New-Object System.Windows.RoutedEventArgs([System.Windows.Controls.Primitives.ButtonBase]::ClickEvent))) } `
    -Before { try { $ui.SetCancel.RaiseEvent((New-Object System.Windows.RoutedEventArgs([System.Windows.Controls.Primitives.ButtonBase]::ClickEvent))) } catch { }; Pump-Px } `
    -Runs 5
try { $ui.SetCancel.RaiseEvent((New-Object System.Windows.RoutedEventArgs([System.Windows.Controls.Primitives.ButtonBase]::ClickEvent))) } catch { }
Pump-Px

# ---------------------------------------------------------------------------
# THE REST OF THE SURFACE. Everything above is a control the operator named;
# these are the rest of the ones that can be pressed without writing anything.
# ---------------------------------------------------------------------------
function Click-Px { param($El)
    $El.RaiseEvent((New-Object System.Windows.RoutedEventArgs([System.Windows.Controls.Primitives.ButtonBase]::ClickEvent)))
}
# The strip controls are TextBlocks wired to mouse events, not Buttons, so they
# take the routed mouse event rather than Click. Same shape as the fold header.
$pxMouse = $null
try { $pxMouse = [System.Windows.Input.Mouse]::PrimaryDevice } catch { }
function Tap-Px { param($El, [string]$Ev)
    if (-not $pxMouse) { return }
    $pxMe = New-Object System.Windows.Input.MouseButtonEventArgs($pxMouse, 0, [System.Windows.Input.MouseButton]::Left)
    switch ($Ev) {
        'up'      { $pxMe.RoutedEvent = [System.Windows.UIElement]::MouseLeftButtonUpEvent }
        'down'    { $pxMe.RoutedEvent = [System.Windows.UIElement]::MouseLeftButtonDownEvent }
        default   { $pxMe.RoutedEvent = [System.Windows.UIElement]::PreviewMouseLeftButtonDownEvent }
    }
    $El.RaiseEvent($pxMe)
}

# 🔴 THREE CONTROLS I HAD WRITTEN OFF AS NOT REACHABLE, AND TWO OF THE THREE
# REASONS WERE WRONG.
#
# I recorded StripList, SkillList and CastList as unreachable on the grounds
# that all three "call Get-ClickedRow on the OriginalSource, so raising the
# event on the container finds no row". That was true of exactly one of them.
#
#   SkillList takes NO ROW AT ALL - `Add_MouseLeftButtonUp({ Complete-Skill })`
#   completes whatever is SELECTED. There was never anything to hit-test.
#   StripList does walk up, but for a DataContext carrying an Id, not for a
#   ListBoxItem - so an ItemsControl's ContentPresenter satisfies it.
#   CastList genuinely needs a ListBoxItem, and gets one: the container comes
#   from ItemContainerGenerator once the list has been laid out.
#
# I generalised from one handler to three without reading the other two, and the
# inventory carried three confident refusals off it. Raising the event on the
# REAL container reaches all three. Defined up here beside Tap-Px because two
# callers below need it and PowerShell resolves a function at call time but only
# after its definition has actually run.
function Tap-PxRow { param($List, [string]$Ev)
    if (-not $pxMouse) { return $false }
    if (-not @($List.Items).Count) { return $false }
    $pxCt = $null
    try { $pxCt = $List.ItemContainerGenerator.ContainerFromIndex(0) } catch { }
    if (-not $pxCt) { return $false }
    $pxRe = New-Object System.Windows.Input.MouseButtonEventArgs($pxMouse, 0, [System.Windows.Input.MouseButton]::Left)
    if ($Ev -eq 'up') { $pxRe.RoutedEvent = [System.Windows.UIElement]::MouseLeftButtonUpEvent }
    else { $pxRe.RoutedEvent = [System.Windows.UIElement]::PreviewMouseLeftButtonDownEvent }
    $pxCt.RaiseEvent($pxRe)
    return $true
}

# --- the two pane strips: sort, filter, fold, clear -------------------------
$null = Measure-Px 'rail strip: change the project sort order' { Tap-Px $ui.RailSort 'down' } -Runs 5
$null = Measure-Px 'rail strip: show only projects with something live' { Tap-Px $ui.RailOnlyLive 'down' } -Runs 4
Tap-Px $ui.RailOnlyLive 'down'; Pump-Px
$null = Measure-Px 'rail strip: show the shelved projects' { Tap-Px $ui.RailShelved 'down' } -Runs 4
Tap-Px $ui.RailShelved 'down'; Pump-Px
$null = Measure-Px 'rail strip: clear the project filter' { Tap-Px $ui.RailClear 'up' } -Runs 5
$null = Measure-Px 'sessions strip: change the sort order' { Tap-Px $ui.ListSort 'down' } -Runs 5
# The dot strip: one dot per conversation waiting on you, and pressing one
# selects it. Its handler walks up from OriginalSource for a DataContext with an
# Id, so it needs a REAL item container - raising on the ItemsControl itself
# finds nothing and returns in 1,4 ms, which is a refusal and not a measurement.
Lay-Px
$pxStripSeen = $false
if (Tap-PxRow $ui.StripList 'up') {
    $pxStripSeen = $true
    $null = Measure-Px 'press a dot on the strip (jumps to what is waiting)' `
        { $null = Tap-PxRow $ui.StripList 'up' } -Settled $pxDocHome -Runs 4
} else {
    # 🪤 NOT A FAILURE AND NOT A REFUSAL. The strip holds one dot per
    # conversation waiting on the operator, and right now none is - which is a
    # statement about the machine this afternoon, not about the control. Same
    # verdict as the sub-agent link: NOT PRESENT TODAY.
    Note ("the dot strip is empty - none of the {0} conversations is waiting on the operator right now, so its press cannot be measured this run" -f $script:model.Count)
}

# --- the permission dropdown ------------------------------------------------
if (@($ui.SetPerm.Items).Count -ge 2) {
    $null = Measure-Px 'change the permission mode in the settings panel' `
        { $ui.SetPerm.SelectedIndex = (($ui.SetPerm.SelectedIndex + 1) % @($ui.SetPerm.Items).Count) } -Runs 5
}

# --- the window frame -------------------------------------------------------
# 🪤 WinClose is NOT here and never will be: it closes the window this suite is
# measuring. Maximise and minimise are state changes and safe.
$pxState = $window.WindowState
$null = Measure-Px 'the maximise glyph' { Click-Px $ui.WinMax } `
    -Before { $window.WindowState = 'Normal'; Pump-Px } -Runs 5
$null = Measure-Px 'the minimise glyph' { Click-Px $ui.WinMin } `
    -Before { $window.WindowState = 'Normal'; Pump-Px } -Runs 5
$window.WindowState = $pxState
Pump-Px

# --- folding a whole column away (also Ctrl+1 / Ctrl+2) ---------------------
$null = Measure-Px 'fold the projects column away (Ctrl+1)' { Invoke-ColumnFold -Which 'rail' } -Runs 5
Invoke-ColumnFold -Which 'rail'; Pump-Px
$null = Measure-Px 'fold the sessions column away (Ctrl+2)' { Invoke-ColumnFold -Which 'list' } -Runs 5
Invoke-ColumnFold -Which 'list'; Pump-Px

# --- the other two search boxes --------------------------------------------
$null = Measure-Px 'type one letter into the PROJECTS search box' `
    { $ui.RailSearch.Text = ($ui.RailSearch.Text + 'a') } `
    -Settled { -not $script:searchTimer.IsEnabled } -Before { $ui.RailSearch.Text = ''; Pump-Px } -Runs 4
$ui.RailSearch.Text = ''; Pump-Px
$null = Measure-Px 'type one letter into the SESSIONS search box' `
    { $ui.ListSearch.Text = ($ui.ListSearch.Text + 'a') } `
    -Settled { -not $script:searchTimer.IsEnabled } -Before { $ui.ListSearch.Text = ''; Pump-Px } -Runs 4
$ui.ListSearch.Text = ''; Pump-Px

# --- the running-shells panel ----------------------------------------------
$null = Measure-Px 'hide or show the running-shells panel' { Click-Px $ui.ShellFold } -Runs 5

# --- send-to-many (opened and closed, never sent) ---------------------------
$null = Measure-Px 'open send-to-many' { Click-Px $ui.Broadcast } `
    -Before { try { Click-Px $ui.CastCancel } catch { }; Pump-Px } -Runs 4
$null = Measure-Px 'type into the send-to-many box' { $ui.CastText.Text = ($ui.CastText.Text + 'a') } -Runs 5
$null = Measure-Px 'fill the morning-compact brief' { Click-Px $ui.CastCompact } -Runs 4
# Ticking a conversation in the send-to-many list. It flips an in-memory set and
# rebuilds that list; nothing is sent, and CastSend is never pressed.
try { Click-Px $ui.Broadcast } catch { }
Pump-Px
Lay-Px
if (Tap-PxRow $ui.CastList 'preview') {
    $null = Measure-Px 'tick a conversation in the send-to-many list' { $null = Tap-PxRow $ui.CastList 'preview' } -Runs 5
} else {
    Huh 'the send-to-many list had no realized row - the tick could not be measured'
}
$script:castPick = @{}
$null = Measure-Px 'close send-to-many' { Click-Px $ui.CastCancel } `
    -Before { try { Click-Px $ui.Broadcast } catch { }; Pump-Px } -Runs 4
try { Click-Px $ui.CastCancel } catch { }
Pump-Px

# --- the skill picker (filters a list; types nothing anywhere) --------------
$null = Measure-Px 'type / into the composer to raise the skill picker' `
    { $ui.SendBox.Text = '/' } -Before { $ui.SendBox.Text = ''; Pump-Px } -Runs 5
$null = Measure-Px 'filter the skill picker one more letter' `
    { $ui.SendBox.Text = '/co' } -Before { $ui.SendBox.Text = '/'; Pump-Px } -Runs 5

Lay-Px
if (@($ui.SkillList.Items).Count) {
    if ($ui.SkillList.SelectedIndex -lt 0) { $ui.SkillList.SelectedIndex = 0 }
    # Tap-Px raises on the control itself, which is all this handler needs.
    $null = Measure-Px 'pick a skill out of the picker (completes the composer text)' `
        { Tap-Px $ui.SkillList 'up' } `
        -Before { $ui.SendBox.Text = '/co'; Pump-Px; if ($ui.SkillList.SelectedIndex -lt 0) { $ui.SkillList.SelectedIndex = 0 } } -Runs 4
} else {
    Huh 'the skill picker listed nothing for "/co" - the pick could not be measured'
}
$ui.SendBox.Text = ''
Pump-Px

# --- the session manager surface -------------------------------------------
$ui.ModeManage.IsChecked = $true
Pump-Px
# 🪤 THE CHIP IS RESET TO A DIFFERENT ONE, NOT TO ITSELF. Resetting to MgrAll
# and then pressing MgrAll raises no Checked event at all - a RadioButton that
# is already on does not fire - so that row read 0,2 ms and measured nothing.
# Same family of fault as the orphan row: a bench that looks fast because the
# gesture never happened.
foreach ($pxChip in @('MgrAll', 'MgrTicked', 'MgrRunning', 'MgrNeeds')) {
    $pxChipEl = $ui[$pxChip]
    $pxResetTo = $(if ($pxChip -eq 'MgrAll') { 'MgrTicked' } else { 'MgrAll' })
    $pxResetEl = $ui[$pxResetTo]
    $null = Measure-Px ("manager filter chip: " + $pxChip) `
        { $pxChipEl.IsChecked = $true } `
        -Before { $pxResetEl.IsChecked = $true; Pump-Px } -Runs 4
}
$ui['MgrAll'].IsChecked = $true
Pump-Px
foreach ($pxHdr in @('HdrName', 'HdrLane', 'HdrSaid', 'HdrAge', 'HdrLogon')) {
    $pxHdrEl = $ui[$pxHdr]
    $null = Measure-Px ("manager sort header: " + $pxHdr) { Tap-Px $pxHdrEl 'down' } -Runs 4
}
$null = Measure-Px 'manager: show the older conversations too' `
    { $script:showOlder = -not $script:showOlder; Build-Manager } -Runs 4
$ui.ModeWork.IsChecked = $true
Pump-Px

# --- resizing: the window, and the two splitters ---------------------------
# A GridSplitter drag ends in a column width change, which is what this sets -
# and a drag is a stream of them, so the cost of ONE is the cost of a frame of
# dragging. The window resize is the same question for the whole surface.
$pxRailW = $ui.RailCol.Width
$pxListW = $ui.ListCol.Width
$null = Measure-Px 'drag the projects splitter one step' `
    { $ui.RailCol.Width = (New-Object System.Windows.GridLength (($ui.RailCol.Width.Value + 6))) } -Runs 6
$null = Measure-Px 'drag the sessions splitter one step' `
    { $ui.ListCol.Width = (New-Object System.Windows.GridLength (($ui.ListCol.Width.Value + 6))) } -Runs 6
$ui.RailCol.Width = $pxRailW
$ui.ListCol.Width = $pxListW

# ── A/B: THE LINE BREAKER ───────────────────────────────────────────────────
# 🔑 A HYPOTHESIS WITH A NUMBER ATTACHED, WHICH IS THE ONLY KIND WORTH SENDING.
#
# Dragging a splitter costs 250-330 ms and its HANDLER is 0,3 ms of that - so it
# is all layout, and the lists are virtualized (VirtualizingPanel.IsVirtualizing
# with Recycling, window2.xaml:884), so it is not them. What is left in that
# column is the reading pane: a FlowDocumentScrollViewer, which does not
# virtualize, holding 5-10 screens of document. Narrowing the column re-flows
# every paragraph in it.
#
# And Build-ReadDocument turns on IsOptimalParagraphEnabled (sessions-window.ps1
# :4043) - WPF's Knuth-Plass breaker, which optimises over the whole paragraph
# instead of filling each line greedily. It is the better-looking option and it
# is documented as the slower one. So: same document, same re-flow, breaker on
# and off, measured back to back. If it is free, the hypothesis is dead and the
# splitter cost is somewhere else; if it is not, this is a one-property change
# with a measured saving.
# 🔴 THE A/B IS PUT BACK ON A KNOWN DOCUMENT FIRST, AND THAT IS A CORRECTION.
#
# The first version measured whatever the pane happened to be showing by the
# time it ran - and by then the search benches, the rail picks and the surface
# switches had moved the selection. So the ratio read 3,7x on one run and 1,65x
# on another, and I had already told the lead the ratio was "a property of the
# code, not the machine". It is not: a re-flow costs what it costs PER SCREEN OF
# DOCUMENT, and those two runs were re-flowing 8,9 screens and 2,9 screens.
#
# Both halves of the A/B were always measured on the SAME document as each
# other, so the comparison was never wrong - but it was not comparable BETWEEN
# runs, which is most of what a recorded number is for. The extent is printed
# with the ratio now, so a reader can never take one without the other.
if ($pxBigId) {
    $script:selId = $null
    $ui.SessionList.SelectedItem = (Get-PxRow $pxBigId)
    $pxW4 = [Diagnostics.Stopwatch]::StartNew()
    while ($script:docPs -and $pxW4.Elapsed.TotalMilliseconds -lt 15000) { Pump-Px; [System.Threading.Thread]::Sleep(1) }
    Lay-Px
}
if ($ui.PaneDoc.Document) {
    $pxSv2 = Get-PaneScroller
    $pxExtent = 0.0
    if ($pxSv2) { $pxExtent = $pxSv2.ExtentHeight }
    $pxOptWas = $ui.PaneDoc.Document.IsOptimalParagraphEnabled
    # Nudging PagePadding by a pixel invalidates the document's measure without
    # changing anything a reader would see - a full re-flow, on demand.
    function Reflow-Px {
        $pxD = $ui.PaneDoc.Document
        $pxPp = $pxD.PagePadding
        $pxD.PagePadding = New-Object System.Windows.Thickness $pxPp.Left, $pxPp.Top, ($pxPp.Right + 1.0), $pxPp.Bottom
    }
    # ── THE RECONCILIATION ──────────────────────────────────────────────────
    # 🔴 TWO LANES MEASURED THIS PROPERTY AND GOT 3,7-4,8x AND 1,23-1,35x. I
    # published the first. Rather than defend it, both methods run here, in one
    # process, over one document, so the disagreement resolves on numbers.
    #
    # What is NOT the difference: construction. My bracket never built a
    # document - it nudges PagePadding on one that is already built. That was
    # the other lane's hypothesis and it is wrong.
    #
    # What IS different: WHICH LAYOUT the stamp pays for. Mine ran Lay-Px - two
    # full Measure/Arrange/UpdateLayout passes over the WHOLE window. The other
    # lane lays out the viewer alone, once. If the optimal-paragraph formatter
    # does not fully cache between two passes, ON pays twice where OFF's second
    # pass is nearly free, and my ratio is inflated by construction of the
    # instrument rather than of the document.
    #
    # Both are reported. Whichever answers the question being asked is the one
    # to quote, and the question decides: "what does a splitter drag cost"
    # wants the window figure, "what does the property cost" wants the pane one.
    #
    # 🔑 AND THE ANSWER, MEASURED 2026-09-05 - THE LAYOUT SCOPE IS NOT IT.
    # Same document, same run: whole-window 38,5 -> 20,3 (1,90x), pane-only
    # 41,9 -> 17,2 (2,43x). Pane-only is the HIGHER ratio, so my two full passes
    # were not inflating anything. The hypothesis I went in with was wrong too.
    #
    # WHAT ACTUALLY EXPLAINS IT: the ratio is not a portable quantity. The other
    # lane's OFF readings are 321 and 355 ms where mine are 17-60; its bracket
    # carries several hundred milliseconds that ON and OFF both pay, and a
    # constant common to both halves lands in the numerator AND the denominator
    # and drags any ratio toward 1. Compare the DELTAS instead and the two lanes
    # agree to within noise on the same order of magnitude:
    #
    #     this lane, 8,9 screens        219 -> 60      delta 159 ms
    #     this lane, 2,8 screens         42 -> 17      delta  25 ms
    #     other lane, 40 blocks       479,7 -> 355,0   delta 125 ms
    #     other lane, 7 large blocks  394,7 -> 321,0   delta  74 ms
    #
    # There was never a factual disagreement. There was a ratio quoted without
    # its denominator. The delta is the physical saving and it is what belongs
    # in a work order; the ratio belongs only next to the method that produced
    # it. Recorded here so the next reader does not re-run this argument.
    $pxOn = Measure-Px 'A/B window: re-flow, optimal paragraph ON (2 full-window layout passes)' `
        { Reflow-Px } -Before { $ui.PaneDoc.Document.IsOptimalParagraphEnabled = $true; Pump-Px } -Runs 7
    $pxOff = Measure-Px 'A/B window: re-flow, optimal paragraph OFF' `
        { Reflow-Px } -Before { $ui.PaneDoc.Document.IsOptimalParagraphEnabled = $false; Pump-Px } -Runs 7
    $pxOnP = Measure-Px 'A/B pane: re-flow, optimal paragraph ON (pane only, one pass)' `
        { Reflow-Px } -Before { $ui.PaneDoc.Document.IsOptimalParagraphEnabled = $true; Pump-Px } -Runs 7 -Lay 'pane'
    $pxOffP = Measure-Px 'A/B pane: re-flow, optimal paragraph OFF' `
        { Reflow-Px } -Before { $ui.PaneDoc.Document.IsOptimalParagraphEnabled = $false; Pump-Px } -Runs 7 -Lay 'pane'
    if ($pxOnP -and $pxOffP -and $pxOffP.Laid -gt 0) {
        Note ("PANE-ONLY, ONE PASS:      {0,6:N1} -> {1,6:N1} ms   delta {2,6:N1} ms   ratio {3:N2}x" -f `
              $pxOnP.Laid, $pxOffP.Laid, ($pxOnP.Laid - $pxOffP.Laid), ($pxOnP.Laid / $pxOffP.Laid))
    }
    $ui.PaneDoc.Document.IsOptimalParagraphEnabled = $pxOptWas
    Pump-Px
    if ($pxOn -and $pxOff) {
        $pxSave = $pxOn.Laid - $pxOff.Laid
        # 🔑 KEPT, NOT JUST PRINTED. The gate at the end of the run needs this
        # number and did not have it - see the note there.
        $script:pxAbScreens = $(if ($pxSv2 -and $pxSv2.ViewportHeight -gt 0) { $pxExtent / $pxSv2.ViewportHeight } else { 0 })
        Note ("the A/B ran over {0:N0} px of document ({1:N1} screens). The saving scales with this - do not compare the ratio between runs without it." -f `
              $pxExtent, $script:pxAbScreens)
        if ($pxSave -gt 5) {
            Note ("WHOLE-WINDOW, TWO PASSES: {0,6:N1} -> {1,6:N1} ms   delta {2,6:N1} ms   ratio {3:N2}x" -f `
                  $pxOn.Laid, $pxOff.Laid, $pxSave, ($pxOn.Laid / [Math]::Max($pxOff.Laid, 0.001)))
            Note  'QUOTE THE DELTA, NOT THE RATIO. The ratio depends on what else is in the bracket - anything'
            Note  'common to both halves lands in numerator AND denominator and pulls it toward 1. That is the'
            Note  'whole of the 3,7x vs 1,3x disagreement between the two lanes; see the block above this one.'
        } else {
            Note ("the line breaker is NOT the cost: {0:N0} ms on vs {1:N0} ms off. That hypothesis is dead - the re-flow is expensive for another reason." -f `
                  $pxOn.Laid, $pxOff.Laid)
        }
    }
}
# 🪤 $window.Width, NOT the layout constant. Assigning to $pxW inside the
# scriptblock would write a LOCAL - a scriptblock invoked with & gets a child
# scope - so the width would never change and the bench would measure nothing.
# What is under test here is the SizeChanged handler, and setting the window's
# own Width raises it whether or not the window is on screen.
$null = Measure-Px 'resize the window by 40 px (the SizeChanged handler)' `
    { $window.Width = 1520.0 } `
    -Before { $window.Width = 1480.0; Pump-Px } -Runs 5
$window.Width = $pxW
Pump-Px

$pxBenchKeys = [SRKeyProbe]::Stop()

# ===========================================================================
# WHERE Build-Sessions SPENDS ITS 350 ms - ATTRIBUTED FROM OUTSIDE THE LIB.
# ===========================================================================
# 🔴 IT IS THE SINGLE MOST EXPENSIVE THING IN THE WINDOW AND IT IS BEHIND MOST
# OF THE TABLE ABOVE. A project pick, every search keystroke, a sort click, a
# band click and the live-writer tick all end in it. So before writing a work
# order that says "make it faster", this says WHICH PART.
#
# 🪤 NO LIB FILE IS TOUCHED. Every helper it calls is wrapped here, timed, and
# unwrapped in the same block. The wrapper's own cost is measured against a
# control so it can be subtracted rather than assumed - about 2.000 calls go
# through it and a stopwatch is not free.
$pxProfile = ("$($env:SR_PIX_PROFILE)".Trim() -eq '1')
if ($pxProfile) {
    Write-Host ''
    Write-Host '--- where Build-Sessions spends it ---'
    $pxHelpers = @('Test-OnSurface', 'Sort-SessionRows', 'Get-Title', 'Get-RowSubAgents',
                   'Get-RowScreenSig', 'Get-AgeTicks', 'Get-AgeLabel', 'Get-CtxBrush',
                   'Get-ProjectLabel', 'Get-Band')
    $pxHT = @{}
    $pxHO = @{}
    foreach ($pxHn in $pxHelpers) {
        if (-not (Test-Path -LiteralPath ("function:" + $pxHn))) { continue }
        $pxHT[$pxHn] = @{ N = 0; Ms = 0.0 }
        $pxHO[$pxHn] = (Get-Item -LiteralPath ("function:" + $pxHn)).ScriptBlock
        $pxHsrc = @"
        `$pxTw = [Diagnostics.Stopwatch]::StartNew()
        try { & `$pxHO['$pxHn'] @args }
        finally { `$pxTw.Stop(); `$pxHT['$pxHn'].N++; `$pxHT['$pxHn'].Ms += `$pxTw.Elapsed.TotalMilliseconds }
"@
        Set-Item -Path ("function:" + $pxHn) -Value ([scriptblock]::Create($pxHsrc))
    }

    $pxBsRuns = 5
    $pxBsBest = [double]::MaxValue
    for ($pxBi2 = 0; $pxBi2 -lt $pxBsRuns; $pxBi2++) {
        $pxBw2 = [Diagnostics.Stopwatch]::StartNew()
        Build-Sessions
        $pxBw2.Stop()
        if ($pxBw2.Elapsed.TotalMilliseconds -lt $pxBsBest) { $pxBsBest = $pxBw2.Elapsed.TotalMilliseconds }
    }
    foreach ($pxHn2 in @($pxHO.Keys)) { Set-Item -Path ("function:" + $pxHn2) -Value $pxHO[$pxHn2] }

    # The control: what a wrapped call costs when the body does nothing. One
    # stopwatch plus a hashtable update, times however many calls were made.
    $pxCtrlN = 0
    foreach ($pxHk in $pxHT.Keys) { $pxCtrlN += $pxHT[$pxHk].N }
    $pxCtrlOne = [double]::MaxValue
    for ($pxCk = 0; $pxCk -lt 7; $pxCk++) {
        $pxCw = [Diagnostics.Stopwatch]::StartNew()
        for ($pxCn = 0; $pxCn -lt 2000; $pxCn++) {
            $pxTw2 = [Diagnostics.Stopwatch]::StartNew(); $pxTw2.Stop()
        }
        $pxCw.Stop()
        if ($pxCw.Elapsed.TotalMilliseconds -lt $pxCtrlOne) { $pxCtrlOne = $pxCw.Elapsed.TotalMilliseconds }
    }
    $pxWrapCost = ($pxCtrlOne / 2000.0) * $pxCtrlN

    Note ("Build-Sessions best of {0}: {1:N0} ms, over {2} conversations in the model." -f `
          $pxBsRuns, $pxBsBest, $script:model.Count)
    Note ("{0} wrapped helper calls in one rebuild; the wrappers themselves cost about {1:N0} ms of the figures below." -f `
          $pxCtrlN, $pxWrapCost)
    $pxAcc2 = 0.0
    foreach ($pxHk2 in @($pxHT.Keys | Sort-Object { -$pxHT[$_].Ms })) {
        if (-not $pxHT[$pxHk2].N) { continue }
        $pxPer = $pxHT[$pxHk2].Ms / $pxBsRuns
        $pxAcc2 += $pxPer
        Note ("  {0,-20} {1,6} call(s)/rebuild {2,8:N1} ms/rebuild  ({3,4:N1}% of it)" -f `
              $pxHk2, [int]($pxHT[$pxHk2].N / $pxBsRuns), $pxPer, (100.0 * $pxPer / [Math]::Max($pxBsBest, 1)))
    }
    Note ("  {0,-20} {1,38:N1} ms/rebuild  ({2,4:N1}% of it)" -f 'EVERYTHING ELSE', ($pxBsBest - $pxAcc2),
          (100.0 * ($pxBsBest - $pxAcc2) / [Math]::Max($pxBsBest, 1)))
    Note  '  "everything else" is the loop itself: one PSCustomObject with ~30 properties per row, most of'
    Note  '  them $(if ...) sub-expressions, built for every conversation on the surface on every rebuild.'
}

# ===========================================================================
# THE INVENTORY. EVERY WIRED HANDLER IN THE WINDOW, ACCOUNTED FOR.
# ===========================================================================
# 🔴 perf-driver HAS A COVERAGE CHECK AND IT CANNOT SEE NINE OF THESE.
#
# Its detector reads the window source for `$ui.X.Add_<event>`, `$ui[..]
# .Add_<event>`, `$window.Add_<event>`, and - for controls built in code - only
# `$something.Add_Click({ param(...) SomeFunction`. That last pattern recovers
# exactly two sites: Invoke-Answer and Invoke-AskMove. It therefore does NOT see
# the fold caption, the sub-agent link, the drill-out button, 'load earlier',
# the inner-scroller wheel handler, the two context-menu factories, the spawn
# dialog's Escape key, or the launch timer - because none of those is an
# Add_Click naming a function.
#
# The comment in that file says widening the pattern fixed exactly this ("the
# fold header, 'load earlier' and the agent links ... had never been timed by
# anything"). It widened the $ui side. The code-built side is still nine sites
# short, and those sites are not on its debt list either, because a control it
# cannot see cannot be counted as owed.
#
# So this map is built from ALL 80 Add_ sites, and every one has a verdict:
# the bench that covers it, or the reason it may not be run.
$PX_SURFACE = @{
    # --- reading pane ---
    'PaneTools'        = 'Steps: cycle the button'
    'PaneZoom'         = 'the text-size control'
    'PaneSettings'     = 'open the settings panel'
    'SetCancel'        = 'open the settings panel (closed in its -Before)'
    'SetPerm'          = 'change the permission mode in the settings panel'
    'PaneDoc'          = 'resize the window by 40 px (its SizeChanged)'
    'ShellFold'        = 'hide or show the running-shells panel'
    'Shell'            = 'resize the window by 40 px (its SizeChanged)'
    'fold caption'     = 'open a folded block of steps / toggle that block again'
    'agent link'       = 'open a sub-agent transcript (drill in)'
    'drill-out button' = 'come back out of the sub-agent'
    'load earlier'     = 'load earlier (doubles the transcript tail)'
    # --- the two columns ---
    'SessionList'      = 'switch to another conversation / hold the down arrow'
    'RailList'         = 'pick a project in the rail'
    'Search'           = 'type one letter into the search box'
    'RailSearch'       = 'type one letter into the PROJECTS search box'
    'ListSearch'       = 'type one letter into the SESSIONS search box'
    'RailSort'         = 'rail strip: change the project sort order'
    'RailOnlyLive'     = 'rail strip: show only projects with something live'
    'RailShelved'      = 'rail strip: show the shelved projects'
    'RailClear'        = 'rail strip: clear the project filter'
    'ListSort'         = 'sessions strip: change the sort order'
    'RailFold'         = 'fold the projects column away (Ctrl+1)'
    'RailOpen'         = 'fold the projects column away (Ctrl+1)'
    'ListFold'         = 'fold the sessions column away (Ctrl+2)'
    'ListOpen'         = 'fold the sessions column away (Ctrl+2)'
    'RailSplit'        = 'drag the projects splitter one step'
    'ListSplit'        = 'drag the sessions splitter one step'
    # --- the manager ---
    'ModeWork'         = 'switch back to the work surface'
    'ModeManage'       = 'switch to the session manager'
    'MgrAll'           = 'manager filter chip: MgrAll'
    'MgrTicked'        = 'manager filter chip: MgrTicked'
    'MgrRunning'       = 'manager filter chip: MgrRunning'
    'MgrNeeds'         = 'manager filter chip: MgrNeeds'
    'HdrName'          = 'manager sort header: HdrName'
    'HdrLane'          = 'manager sort header: HdrLane'
    'HdrSaid'          = 'manager sort header: HdrSaid'
    'HdrAge'           = 'manager sort header: HdrAge'
    'HdrLogon'         = 'manager sort header: HdrLogon'
    # --- send-to-many, composer, frame ---
    'Broadcast'        = 'open send-to-many'
    'CastCancel'       = 'close send-to-many'
    'CastCompact'      = 'fill the morning-compact brief'
    'CastText'         = 'type into the send-to-many box'
    'SendBox'          = 'type / into the composer to raise the skill picker'
    'WinMax'           = 'the maximise glyph'
    'WinMin'           = 'the minimise glyph'
    # 🪤 ' / ' IS THE SEPARATOR THE CHECK SPLITS ON. Commas are not, and this
    # entry used them - so a control that IS covered three times over failed the
    # gate. Written down because the next person adding an entry will reach for
    # a comma too.
    'window keys'      = 'fold the projects column away (Ctrl+1) / fold the sessions column away (Ctrl+2) / load earlier / manager: show the older conversations'
    'window SizeChanged' = 'resize the window by 40 px'

    # --- NOT REACHABLE: the handler refuses without something this harness
    #     cannot synthesize. Distinguished from EXCUSED on purpose: excused
    #     means "would do harm", this means "would measure a refusal".
    # 🔴 THESE THREE WERE MARKED NOT REACHABLE AND TWO OF THE THREE REASONS
    # WERE WRONG - see the note on Tap-PxRow. Raising the event on the real item
    # container reaches all of them. Left in this block, next to the entries
    # that are still genuinely unreachable, so the correction stays visible.
    'StripList'        = 'press a dot on the strip'
    'SkillList'        = 'pick a skill out of the picker'
    'CastList'         = 'tick a conversation in the send-to-many list'
    'inner wheel'      = 'NOT REACHABLE here: the handler is on a ScrollViewer inside an OPEN fold, and needs a real wheel delta routed through it.'
    'SheetB1'          = 'NOT REACHABLE: only exists while a modal confirmation sheet is up, and raising one blocks on a human.'
    'SheetB2'          = 'NOT REACHABLE: as SheetB1.'
    'SheetB3'          = 'NOT REACHABLE: as SheetB1.'
    'spawn Escape'     = 'NOT REACHABLE: belongs to the spawn dialog, whose ShowDialog never returns without a human.'

    # --- EXCUSED: running it would act on the operator's live machine. ---
    'SendBtn'          = 'EXCUSED: types into a live session.'
    'AskFreeSend'      = 'EXCUSED: types an answer into a live session.'
    'AskFree'          = 'EXCUSED: its PreviewKeyDown commits an answer on Enter.'
    'PaneCompact'      = 'EXCUSED: types /compact into a live session.'
    'PaneStop'         = 'EXCUSED: presses Esc in a live session and stops its turn.'
    'PaneGoTo'         = 'EXCUSED: raises a real terminal window.'
    'PaneRelaunch'     = 'EXCUSED: kills and relaunches a conversation.'
    'PaneWorktree'     = 'EXCUSED: opens a modal dialog.'
    'NewSession'       = 'EXCUSED: ShowDialog never returns without a human.'
    'CastSend'         = 'EXCUSED: types into every ticked session at once.'
    'SetApply'         = 'EXCUSED: writes per-session settings and may relaunch.'
    'Rescan'           = 'EXCUSED: saves the registry and rescans.'
    'SaveBtn'          = 'EXCUSED: writes the operator registry.'
    'RelaunchSessions' = 'EXCUSED: kills live claude processes.'
    'OpenNotRunning'   = 'EXCUSED: launches every conversation that is not running.'
    'SignIn'           = 'EXCUSED: opens an interactive sign-in and then relaunches.'
    'ManageList'       = 'EXCUSED: a click on a row can tick a conversation (Set-TickOn), which changes what comes back at logon.'
    'Invoke-Answer'    = 'EXCUSED: sends a decision into a live session.'
    'Invoke-AskMove'   = 'EXCUSED: walks a live round with arrow keys.'
    'manager menu'     = 'EXCUSED: its items launch, kill and rename.'
    'rail menu'        = 'EXCUSED: shelving a project writes the config.'
    'WinClose'         = 'EXCUSED: closes the window this suite is measuring.'
    'launch timer'     = 'EXCUSED: it is the timer that OPENS SESSIONS.'
    # --- lifecycle, not gestures ---
    'window lifecycle' = 'NOT A CONTROL: Closing, Closed, ContentRendered, SourceInitialized, StateChanged.'
}

if (-not $pxAgentSeen) {
    $PX_SURFACE['agent link']       = 'NOT PRESENT TODAY: the profiled conversation tail has no sub-agent block. The control is measurable; it was not on screen.'
    $PX_SURFACE['drill-out button'] = 'NOT PRESENT TODAY: as the agent link - there was nothing to come back out of.'
}
if (-not $pxStripSeen) {
    $PX_SURFACE['StripList']        = 'NOT PRESENT TODAY: the strip holds one dot per conversation waiting on the operator, and none is. Measurable when one is.'
}
# 🔴 AND THE FOLD CAPTION DOES **NOT** GET A TIDY VERDICT WHEN IT IS MISSING.
#
# "no fold block was rendered" has two possible causes and this harness cannot
# tell them apart: a tail that happens to be all prose, or the reading pane
# having stopped folding. Filing it as NOT PRESENT TODAY would make the second
# one look like the first - and the second is the operator's original complaint,
# word for word. So it gets a verdict that stays loud, and the run stays
# inconclusive rather than passing.
if (-not $pxFoldSeen) {
    $PX_SURFACE['fold caption'] = 'COULD NOT BE MEASURED THIS RUN: no fold block was rendered at all. That is either a tail with no tool runs in it or the reading pane no longer folding, and this harness cannot tell which. It is NOT a pass.'
}

$pxMeasuredNames = @{}
foreach ($pxRn in $pxRows.ToArray()) { $pxMeasuredNames[$pxRn.Name] = $true }
$pxCovMeasured = 0; $pxCovExcused = 0; $pxCovUnreach = 0; $pxCovBroken = @()
foreach ($pxKey in $PX_SURFACE.Keys) {
    $pxV = "$($PX_SURFACE[$pxKey])"
    if ($pxV -like 'EXCUSED*') { $pxCovExcused++; continue }
    if ($pxV -like 'NOT REACHABLE*' -or $pxV -like 'NOT A CONTROL*' -or $pxV -like 'NOT PRESENT*') { $pxCovUnreach++; continue }
    $pxCovMeasured++
    # 🔴 AND THE MAP IS CHECKED AGAINST THE TABLE, so it cannot name a bench
    # that does not exist. That is the failure mode of perf-driver's map -
    # nothing there requires the value to be findable, so an entry can name a
    # bench that was renamed or deleted and the map still reads as coverage.
    #
    # 🪤 AN ENTRY MAY NAME SEVERAL BENCHES, separated by ' / ', because one
    # control genuinely has more than one gesture - SessionList is both the
    # click and the arrow. The first version of this took the whole string as
    # one name and failed three honest entries; a check that fails on correct
    # input gets switched off exactly as fast as one that passes on wrong input.
    $pxFound2 = $false
    foreach ($pxAlt in (($pxV -split ' / '))) {
        $pxNeedle = ($pxAlt -split ' \(')[0].Trim()
        if (-not $pxNeedle) { continue }
        foreach ($pxMn in $pxMeasuredNames.Keys) { if ($pxMn -like ('*' + $pxNeedle + '*')) { $pxFound2 = $true; break } }
        if ($pxFound2) { break }
    }
    if (-not $pxFound2 -and -not $pxOnly) { $pxCovBroken += ('{0} -> "{1}"' -f $pxKey, $pxV) }
}
Write-Host ''
Write-Host '=== the surface, accounted for ==='
Write-Host ("  {0} entries: {1} measured, {2} excused (would act on the live machine), {3} not reachable / not a control." -f `
    $PX_SURFACE.Count, $pxCovMeasured, $pxCovExcused, $pxCovUnreach) -ForegroundColor Gray
Write-Host  '  Built from all 80 Add_ handler sites in sessions-window.ps1, including the eleven built in code' -ForegroundColor DarkGray
Write-Host  '  that perf-driver.ps1 cannot see - it recovers a code-built control only when the handler is an' -ForegroundColor DarkGray
Write-Host  '  Add_Click naming a function, which is two of the eleven.' -ForegroundColor DarkGray
if ($pxCovBroken.Count) {
    Fail ("{0} inventory entry(ies) name a bench that did not run: {1}" -f $pxCovBroken.Count, ($pxCovBroken -join '; '))
} elseif (-not $pxOnly) {
    Pass 'every inventory entry that claims a bench names one that actually ran'
}

# ===========================================================================
# WHAT THE WINDOW COSTS WHEN NOBODY TOUCHES IT.
# ===========================================================================
# 🔴 EVERY BENCH IN THIS REPO MEASURES A GESTURE, AND THE OPERATOR DID NOT ONLY
# COMPLAIN ABOUT GESTURES. "navigating up and down feels laggy", "whenever I
# type something ... super laggy" describe a UI thread that is busy with
# something else when the input arrives. No table of gesture costs can show
# that: the gesture is fast and the thread is not free to run it.
#
# So this holds still and watches. It pumps the dispatcher in a tight loop for
# N seconds with NO gesture at all and records the GAP between consecutive
# pumps. A gap is time the UI thread spent inside somebody else's work - a lane
# tick, a rebuild, a sweep collection - and it is exactly the window in which a
# keystroke or a click would sit unanswered. The terminal answers an arrow in
# 6.9 ms; any gap above that is time this window could not have.
#
# Opt-in (-Idle <seconds>) because it costs real wall clock and adds nothing to
# a gesture table.
$pxIdleSecs = 0
try { if ("$($env:SR_PIX_IDLE)".Trim()) { $pxIdleSecs = [int]("$($env:SR_PIX_IDLE)".Trim()) } } catch { }
if ($pxIdleSecs -gt 0) {
    Write-Host ''
    Write-Host ("--- holding still for {0}s: what the window does to itself ---" -f $pxIdleSecs)

    # 🔴 THE FIRST VERSION OF THIS MEASURED ITS OWN SLEEP AND REPORTED 81,7%.
    #
    # It timed the LOOP PERIOD - pump, Thread.Sleep(1), stamp - and called
    # everything over 7 ms a stall. On Windows the default timer resolution is
    # 15,6 ms, so Sleep(1) sleeps up to fifteen; 2.277 iterations over 25 s is
    # 11 ms each, which is the sleep and nothing else. The tell was that it
    # claimed 81,7% of the thread was busy in a run where Build-Sessions,
    # Build-Rail and Update-Document were each called ZERO times. Two readings
    # that contradict each other, and the instrument was the wrong one.
    #
    # What is timed now is the PUMP ITSELF: how long the dispatcher takes to run
    # everything queued above ApplicationIdle. That is UI-thread busy time and
    # nothing else. The sleep sits outside the bracket, where it belongs.
    #
    # 🪤 ITS OWN FLOOR IS MEASURED FIRST, on a queue that is already empty, so
    # the reader is never asked to take "a pump costs about nothing" on trust.
    $pxPumpFloor = [double]::MaxValue
    for ($pxFi = 0; $pxFi -lt 40; $pxFi++) {
        $pxFw = [Diagnostics.Stopwatch]::StartNew()
        Pump-Px
        $pxFw.Stop()
        if ($pxFw.Elapsed.TotalMilliseconds -lt $pxPumpFloor) { $pxPumpFloor = $pxFw.Elapsed.TotalMilliseconds }
    }

    # Counters around what the lane can reach. None of these take parameters, so
    # @args forwarding is exact.
    $pxNames = @('Build-Sessions', 'Build-Rail', 'Update-Document', 'Invoke-WriteLane',
                 'Update-LiveWriters', 'Complete-VitalsSweep', 'Start-VitalsSweep',
                 'Complete-QuietCheck', 'Start-QuietCheck', 'Complete-AskProbe', 'Complete-DocParse')
    $pxTally = @{}
    $pxOrig = @{}
    foreach ($pxNm in $pxNames) {
        if (-not (Test-Path -LiteralPath ("function:" + $pxNm))) { continue }
        $pxTally[$pxNm] = @{ N = 0; Ms = 0.0 }
        $pxOrig[$pxNm] = (Get-Item -LiteralPath ("function:" + $pxNm)).ScriptBlock
        # 🪤 THE COUNTER IS BUILT FROM A STRING, not written out eleven times.
        # A per-name closure over $pxNm would capture the loop variable by
        # reference and file every call under the last name - the exact trap the
        # window's own fold headers carry a comment about.
        $pxWrapSrc = @"
        `$pxTw = [Diagnostics.Stopwatch]::StartNew()
        try { & `$pxOrig['$pxNm'] @args }
        finally { `$pxTw.Stop(); `$pxTally['$pxNm'].N++; `$pxTally['$pxNm'].Ms += `$pxTw.Elapsed.TotalMilliseconds }
"@
        Set-Item -Path ("function:" + $pxNm) -Value ([scriptblock]::Create($pxWrapSrc))
    }

    # 🔑 AND THE SECOND, CONTRADICTABLE READING. The pump timing below says how
    # long the dispatcher spent running queued work; it cannot tell busy from
    # waiting-for-a-message, and the first version of this section got exactly
    # that wrong. The keystroke probe answers the operator's question directly
    # and by a completely different route - a real Input-priority operation from
    # a real background thread - so if the two disagree, one of them is wrong
    # and it is worth knowing which.
    [SRKeyProbe]::Start($window.Dispatcher, 40)

    # 🔑 AND A THIRD READING, BECAUSE THE FIRST TWO DISAGREE. Summed pump time
    # says the thread is busy 87,5% of an idle run; a 13,8 ms median keystroke
    # says it is not. Process CPU time can separate BUSY from WAITING, which is
    # exactly what the pump timing cannot do.
    #
    # 🪤 IT IS THE WHOLE PROCESS, NOT THE UI THREAD. The vitals sweep, the quiet
    # check and the ask probe all run on their own threads inside this process,
    # so this OVER-counts the UI thread by however much they use. It is an upper
    # bound, and an upper bound is enough to kill the 87,5% claim if it comes in
    # low. Reported as what it is.
    $pxProc = [System.Diagnostics.Process]::GetCurrentProcess()
    $pxCpuWas = $pxProc.TotalProcessorTime

    $pxGaps = New-Object System.Collections.Generic.List[double]
    $pxWatch = [Diagnostics.Stopwatch]::StartNew()
    while ($pxWatch.Elapsed.TotalSeconds -lt $pxIdleSecs) {
        $pxPw = [Diagnostics.Stopwatch]::StartNew()
        Pump-Px
        $pxPw.Stop()
        $pxGaps.Add($pxPw.Elapsed.TotalMilliseconds)
        [System.Threading.Thread]::Sleep(1)
    }
    $pxWatch.Stop()
    $pxIdleKeys = [SRKeyProbe]::Stop()

    # Unwrap before anything else runs, so the counters cannot leak into a later
    # measurement.
    foreach ($pxNm2 in @($pxOrig.Keys)) { Set-Item -Path ("function:" + $pxNm2) -Value $pxOrig[$pxNm2] }

    $pxG = $pxGaps.ToArray()
    $pxWall = $pxWatch.Elapsed.TotalMilliseconds
    $pxBusy = 0.0; $pxOver7 = 0; $pxOver50 = 0; $pxOver100 = 0; $pxOver250 = 0; $pxMax = 0.0
    foreach ($pxGg in $pxG) {
        $pxBusy += $pxGg
        if ($pxGg -gt $PX_BAR) { $pxOver7++ }
        if ($pxGg -gt 50)  { $pxOver50++ }
        if ($pxGg -gt 100) { $pxOver100++ }
        if ($pxGg -gt 250) { $pxOver250++ }
        if ($pxGg -gt $pxMax) { $pxMax = $pxGg }
    }
    # 🔑 THE HEADLINE IS THE KEYSTROKE PROBE. It is measured from OUTSIDE the UI
    # thread, at the priority a real key arrives on, so it needs no attribution
    # and no interpretation: this IS the wait.
    Report-PxKeys 'IDLE, nothing touched' $pxIdleKeys
    Note ("{0} pumps over {1:N1}s; an empty pump costs {2:N2} ms." -f `
          $pxG.Count, ($pxWall / 1000.0), $pxPumpFloor)
    Note ("pumps over the 6,9 ms terminal bar: {0}   over 50 ms: {1}   over 100 ms: {2}   over 250 ms: {3}   longest {4:N0} ms" -f `
          $pxOver7, $pxOver50, $pxOver100, $pxOver250, $pxMax)
    Note  'Each long pump is a burst in which a keystroke or a click sits unanswered.'
    # 🔴 THE SUM OF THE PUMPS IS *NOT* REPORTED AS "THE THREAD WAS BUSY N%", AND
    # THE REASON IS THAT TWO READINGS HERE DISAGREE.
    #
    # Summed, the pumps come to 26.267 of 30.004 ms - 87,5% - and the functions
    # wrapped below account for only 5.672 ms of it. A 20-second hole. Either
    # something unattributed is eating the thread, or Dispatcher.Invoke at
    # ApplicationIdle spends part of its wall clock WAITING for a message rather
    # than running work, and this instrument cannot tell those apart.
    #
    # The keystroke probe can, and says the milder thing: a median wait of 13 ms
    # is not what a thread that is busy seven-eighths of the time would produce.
    # So the percentage is withheld rather than printed with a caveat nobody
    # would read, and the number below is what the pumps support without
    # interpretation - how much of the run was spent in bursts long enough to
    # swallow a keypress.
    $pxLongMs = 0.0
    foreach ($pxGg2 in $pxG) { if ($pxGg2 -gt 50) { $pxLongMs += $pxGg2 } }
    Note ("{0:N0} ms of the {1:N0} ms went into bursts longer than 50 ms - measured; what fraction of those is work rather than waiting is NOT established." -f `
          $pxLongMs, $pxWall)
    $pxCpuMs = ($pxProc.TotalProcessorTime - $pxCpuWas).TotalMilliseconds
    Note ("the WHOLE PROCESS - every thread, sweeps and probes included - used {0:N0} ms of CPU in that {1:N0} ms." -f $pxCpuMs, $pxWall)
    Note ("summed pump time was {0:N0} ms. Where the CPU figure is the smaller of the two, the pump was WAITING, not working." -f $pxBusy)
    foreach ($pxK in @($pxTally.Keys | Sort-Object { -$pxTally[$_].Ms })) {
        if (-not $pxTally[$pxK].N) { continue }
        Note ("  {0,-22} {1,5} call(s) {2,8:N0} ms total {3,7:N1} ms each" -f `
              $pxK, $pxTally[$pxK].N, $pxTally[$pxK].Ms, ($pxTally[$pxK].Ms / $pxTally[$pxK].N))
    }
    $pxNever = @($pxTally.Keys | Where-Object { -not $pxTally[$_].N } | Sort-Object)
    if ($pxNever.Count) { Note ("  never called while idle: {0}" -f ($pxNever -join ', ')) }
}

# ===========================================================================
Write-Host ''
Write-Host '=== click to pixels, worst first ==='
# ===========================================================================
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

Report-PxKeys 'WHILE THE BENCHES BELOW RAN' $pxBenchKeys
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
# THE REGRESSION GATE, AND AN HONEST ACCOUNT OF WHAT IT CANNOT GATE.
# ===========================================================================
# 🔴 MOST OF THE TABLE ABOVE CANNOT BE GATED AT ALL, AND SAYING SO IS THE POINT.
#
# 'switch to another conversation' read 1.001, 904, 475, 493, 818, 982 and 702 ms
# on SEVEN runs of identical source. Normalising by the spin does not tame it -
# divided through it is still 26 to 59, a 2,3x spread - because the cost depends
# on the write lane, the vitals sweep, runspace scheduling and whether the
# transcript happened to grow, none of which a CPU loop describes. A threshold
# above 2,3x would be too blunt to catch anything real, and one below it would
# cry wolf. This file already carries the reason that is fatal: a benchmark that
# cries wolf gets muted, and a muted benchmark catches nothing.
#
# 🔑 SO THE GATE COVERS THE QUANTITIES THAT ARE ACTUALLY STABLE, and the rest is
# printed for a human to diff. Three of them:
#
#   1. THE CHEAP ROWS. Everything that came in under 20 ms read 1-6 ms on every
#      run: scrolling, the surface switch, the settings panel, the warm
#      re-select, the window frame. Those are layout-only paths with no disk, no
#      runspace and no lane involvement, and a regression there - somebody
#      putting a file read on the scroll path - is exactly the kind that ships.
#   2. THE IDLE KEYSTROKE MEDIAN. 13,0 / 13,3 / 13,8 ms on three runs; it is a
#      median over ~500 samples, which is why it is steady where a single sample
#      is not.
#   3. THE LINE-BREAKER RATIO. 2,8x to 4,8x over four runs. A ratio between two
#      measurements taken seconds apart cancels the machine almost entirely.
#      This one is a FALSIFICATION guard rather than a speed gate: if it ever
#      reads ~1,0 the A/B has stopped working and the number in the header of
#      this file has stopped being evidence.
#
# 🪤 THE BASELINE IS WRITTEN ONLY WHEN ASKED, NEVER ON A NORMAL RUN. This repo
# has already been bitten by a baseline that widened its own ceiling every time
# it saw a slow run - Build-Sessions drifted 9,36 to 18,06 ms in an afternoon,
# so a genuine 90% regression would have passed in silence. -Record is the only
# thing that writes this file.
$PX_GATE_MAX   = 20.0    # a baseline row at or under this is gated; above it, reported
$PX_GATE_RATIO = 2.50
$PX_GATE_MINMS = 12.0
$pxBasePath = Join-Path $SR_Root 'tests\pixels-baseline.json'
$pxRecord = ("$($env:SR_PIX_RECORD)".Trim() -eq '1')

$pxNow = @{}
foreach ($pxRr in $pxAll) {
    if ($pxRr.Threw -or $pxRr.Stalled) { continue }
    if ($pxRr.Name -like '*empty gesture*') { continue }
    $pxNow[$pxRr.Name] = [Math]::Round($pxRr.Laid / [Math]::Max($pxSpinEnd, 0.001), 6)
}
$pxKeyMed = $null
if ($pxIdleSecs -gt 0 -and $pxIdleKeys -and $pxIdleKeys.Count -ge 20) {
    $pxKs2 = @($pxIdleKeys | Sort-Object)
    $pxKeyMed = $pxKs2[[int]($pxKs2.Count / 2)]
}
$pxAbRatio = $null
if ($pxOn -and $pxOff -and $pxOff.Laid -gt 0) { $pxAbRatio = $pxOn.Laid / $pxOff.Laid }

Write-Host ''
Write-Host '=== did anything get slower? ==='
# 🪤 -Only MAKES EVERY OTHER BASELINE ROW LOOK DELETED. A filtered run must not
# be able to fail the gate, and must not be able to record over it either.
if ($pxOnly) {
    Huh ("-Only '{0}' was set, so most of the table did not run. The regression gate is NOT armed for this run and nothing was recorded." -f $pxOnly)
} elseif ($pxRecord -and ($fails -gt 0 -or $inconclusive -gt 0)) {
    # 🔴 A BASELINE RECORDED FROM A BROKEN RUN IS WORSE THAN NO BASELINE, and
    # this is not hypothetical - it happened on the run that added this guard.
    #
    # Another lane was mid-edit in lib\sessions-window.ps1 while I recorded. The
    # driver splices the LIVE source every run, so it got a half-written window:
    # the reading pane built nothing, the A/B ran over an empty document and
    # recorded "7 ms on vs 6 ms off", and the splitter recorded 8 ms. The very
    # next run, against a whole file, read 204 ms and 141 ms and the gate fired
    # at 35x and 17x - correctly, and about nothing.
    #
    # The run KNEW it was broken: it had a failed Steps assertion and a
    # DocMoved inconclusive in the same output. It recorded anyway, because
    # nothing connected the two. Now it refuses.
    Huh ("this run had {0} failure(s) and {1} inconclusive result(s), so NOTHING was recorded. A baseline taken from a run that already knows it is wrong is a ceiling nobody can see through." -f $fails, $inconclusive)
} elseif ($pxRecord) {
    $pxOut = @{ recordedAt = (Get-Date).ToString('s'); spin = $pxSpinEnd
                note = 'laid-ms per spin-ms. Only rows at or under 20 ms are gated - see the note in pixels-driver.ps1. Written ONLY by -Record.'
                idleKeyMedianMs = $pxKeyMed
                lineBreakerRatio = $pxAbRatio
                rows = $pxNow }
    $pxOut | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $pxBasePath -Encoding utf8
    Note ("recorded {0} row(s) against spin {1:N0} ms. This is the ONLY thing that writes that file." -f $pxNow.Count, $pxSpinEnd)
} elseif (-not (Test-Path -LiteralPath $pxBasePath)) {
    Huh 'no baseline recorded yet - run once with -Record. Until then this run asserts nothing about regressions.'
} else {
    $pxBase = $null
    try { $pxBase = Get-Content -LiteralPath $pxBasePath -Raw | ConvertFrom-Json } catch { }
    if (-not $pxBase) {
        Huh 'the baseline file would not parse - the regression gate is NOT armed for this run.'
    } else {
        $pxGated = 0; $pxReported = 0; $pxNew = @(); $pxGone = @()
        foreach ($pxBn in @($pxBase.rows.PSObject.Properties.Name)) {
            if (-not $pxNow.ContainsKey($pxBn)) { $pxGone += $pxBn }
        }
        foreach ($pxNn in @($pxNow.Keys | Sort-Object)) {
            $pxProp = $pxBase.rows.PSObject.Properties[$pxNn]
            if (-not $pxProp) { $pxNew += $pxNn; continue }
            $pxExp = [double]$pxProp.Value * $pxSpinEnd
            $pxAct = $pxNow[$pxNn] * $pxSpinEnd
            if ($pxExp -gt $PX_GATE_MAX) { $pxReported++; continue }
            $pxGated++
            if ($pxAct -gt ($pxExp * $PX_GATE_RATIO) -and ($pxAct - $pxExp) -gt $PX_GATE_MINMS) {
                Fail ("{0}: {1:N1} ms against {2:N1} expected ({3:N1}x). Both tests cleared - proportionally worse AND worse by more than {4:N0} ms." -f `
                      $pxNn, $pxAct, $pxExp, ($pxAct / [Math]::Max($pxExp, 0.001)), $PX_GATE_MINMS)
            }
        }
        Note ("{0} row(s) gated, {1} reported-only (over the {2:N0} ms line where a single sample stops meaning anything)." -f `
              $pxGated, $pxReported, $PX_GATE_MAX)
        if ($pxNew.Count) { Note ("{0} new row(s), skipped this run: {1}" -f $pxNew.Count, ($pxNew -join ', ')) }
        # 🔴 A BENCH THAT VANISHED IS A FAILURE, NOT A QUIET DIFF. This repo has
        # already had a benchmark that would have scored DELETING the feature it
        # guarded as an improvement. A row in the baseline with nothing to
        # compare it against means somebody removed a bench or renamed it, and
        # either way the surface it covered is now unguarded.
        if ($pxGone.Count) {
            Fail ("{0} baseline row(s) have no bench any more - deleted or renamed, and either way that surface is unguarded now: {1}" -f `
                  $pxGone.Count, ($pxGone -join ', '))
        }
        # The two whole-run figures.
        if ($null -ne $pxKeyMed -and $null -ne $pxBase.idleKeyMedianMs) {
            $pxKeyExp = [double]$pxBase.idleKeyMedianMs
            if ($pxKeyMed -gt ($pxKeyExp * 2.0) -and ($pxKeyMed - $pxKeyExp) -gt 10.0) {
                Fail ("a keystroke at an idle window now waits {0:N1} ms against {1:N1} recorded - the window got busier doing nothing." -f $pxKeyMed, $pxKeyExp)
            } else {
                Note ("idle keystroke median {0:N1} ms against {1:N1} recorded." -f $pxKeyMed, $pxKeyExp)
            }
        } elseif ($pxIdleSecs -le 0) {
            Note 'the idle keystroke median is not gated this run - it needs -Idle.'
        }
        if ($null -ne $pxAbRatio) {
            # 🪤 1,25 AND NOT 1,5. The ratio scales with how much document is
            # loaded - measured 1,65x over 2,9 screens against 3,7x over 8,9 -
            # so a threshold set near the big-document value fails honestly on a
            # small one. This is a "has the A/B stopped separating at all" guard,
            # not a speed gate, and it is set where only ~1,0 trips it.
            # 🔴 AND THE THRESHOLD HAS A FLOOR IT WAS CALIBRATED AGAINST. The
            # note two lines above says "measured 1,65x over 2,9 screens against
            # 3,7x over 8,9" and the Note beside the A/B itself says do not
            # compare the ratio between runs without the document size - and
            # then this compared it anyway. Measured on a run that failed here:
            # 1,24x over 1,7 SCREENS, against a previous run of 2,45x over 6,4.
            # The conversation whose tail happens to be loaded is not something
            # this harness picks, so below the smallest size the threshold was
            # ever calibrated on, the gate cannot tell a collapsed A/B from a
            # short document. It abstains there rather than reporting the
            # fixture as a regression.
            if ($script:pxAbScreens -gt 0 -and $script:pxAbScreens -lt 2.5) {
                Note ("the optimal-paragraph A/B read {0:N2}x over only {1:N1} screens - below the 2,9 screens the 1,25 threshold was calibrated on, so it is not gated this run." -f $pxAbRatio, $script:pxAbScreens)
            } elseif ($pxAbRatio -lt 1.25) {
                Fail ("the optimal-paragraph A/B now reads {0:N2}x over {1:N1} screens. At this value the A/B is no longer demonstrating anything and the figures quoted in this file's header have stopped being evidence." -f $pxAbRatio, $script:pxAbScreens)
            } else {
                Note ("the optimal-paragraph A/B still separates: {0:N2}x over {1:N1} screens." -f $pxAbRatio, $script:pxAbScreens)
            }
        }
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
