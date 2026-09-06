
# ===========================================================================
# THE CONTROL AUDIT, PART TWO: WHERE THE TIME ACTUALLY GOES.
#
# Part one measured every control and produced five numbers nobody could
# explain - a rail pick reading 498 ms in the handler and 1.469 s to the frame,
# against a bench of the same work that reads about 130. A number without a
# cause is not a finding, it is a rumour, so this file exists to name the call
# that owns the milliseconds.
#
# 🔴 THREE RULES THIS FILE IS BUILT ON, ALL OF THEM LEARNED HERE THE HARD WAY.
#
#   1. NOTHING IS PRESSED UNTIL THE SANDBOX IS PROVEN. The operator has ~30 live
#      conversations he cannot relaunch and a registry overwrite in this repo's
#      history already cost him 210. Both writable paths are redirected into
#      .state and each redirect is PROVEN with a real write through the real
#      writer before a single handler runs. If either proof fails this file
#      exits 1 with nothing pressed.
#
#   2. AN INSTRUMENT THAT HAS NEVER GONE RED HAS NEVER BEEN SHOWN TO WORK. The
#      attribution below is a function wrapper, and -Inject makes one wrapped
#      function slow on purpose so the table can be watched moving. Run that
#      before believing any green.
#
#   3. NEVER COMPARE A NUMBER ACROSS RUNS ON THIS MACHINE. Untouched code moved
#      27,3 -> 51,7 ms between two runs here. Every comparison in this file has
#      its control measured in the same run, and the controls are printed.
# ===========================================================================

$zzFails = 0
$zzUnsure = 0
function Fail { param($m) Write-Host "  FAIL  $m" -ForegroundColor Red; $script:zzFails++ }
function Pass { param($m) Write-Host "  ok    $m" -ForegroundColor Green }
function Note { param($m) Write-Host "        $m" -ForegroundColor DarkGray }
function Inconclusive { param($m) Write-Host "  ????  $m" -ForegroundColor Magenta; $script:zzUnsure++ }
function Head { param($m) Write-Host ''; Write-Host ("--- {0} ---" -f $m) -ForegroundColor Cyan }

$zzInject     = 0.0
if ($env:SR_AUD_INJECT) { $zzInject = [double]$env:SR_AUD_INJECT }
$zzInjectInto = "$($env:SR_AUD_INJECT_INTO)"
$zzOnly       = "$($env:SR_AUD_ONLY)"
$zzRuns       = 7
if ($env:SR_AUD_RUNS -and [int]$env:SR_AUD_RUNS -gt 0) { $zzRuns = [int]$env:SR_AUD_RUNS }
function Want { param([string]$Name) return (-not $zzOnly -or "$Name".ToLower().Contains($zzOnly.ToLower())) }

# ===========================================================================
# 0. THE SANDBOX, PROVEN BEFORE ANYTHING IS PRESSED
# ===========================================================================
Head 'the sandbox'
$zzLiveCfg = Join-Path $SR_Root 'session-restore.config.json'
$zzLiveReg = Join-Path $SR_Root 'sessions-registry.json'
function Get-H { param([string]$P)
    try { return (Get-FileHash -LiteralPath $P -Algorithm SHA256 -ErrorAction Stop).Hash } catch { return '' }
}
$zzCfgLiveWas = Get-H $zzLiveCfg
$zzRegLiveWas = Get-H $zzLiveReg
if (-not $zzCfgLiveWas -or -not $zzRegLiveWas) {
    Fail 'could not hash the live config and registry before starting. Refusing to run - the guard would not be armed.'
    exit 1
}

# --- the config ---
$zzCfgCopy = Join-Path $SR_Root '.state\audit-control-config.json'
try { Copy-Item -LiteralPath $zzLiveCfg -Destination $zzCfgCopy -Force -ErrorAction Stop }
catch { Fail ("could not copy the config: {0}" -f $_.Exception.Message); exit 1 }
$SR_ConfigPath = $zzCfgCopy
# 🪤 A KEY THAT IS NOT THERE AND A VALUE NOTHING ELSE COULD PRODUCE. Saving an
# EXISTING key at its CURRENT value re-serialises byte-identically, so the hash
# would not move and this arming check would go red on a redirect that works
# perfectly. A calibration that can fail for a reason unrelated to what it tests
# is not a calibration.
$zzCfgCopyWas = Get-H $zzCfgCopy
Save-SRConfigLater -Name 'auditControlProbe' -Value ([guid]::NewGuid().ToString('N'))
$null = Save-SRConfigWrites
if ((Get-H $zzCfgCopy) -eq $zzCfgCopyWas) {
    Fail 'a config write through the real writer did NOT land in the redirected copy - the redirect is not armed. Refusing to run.'
    exit 1
}
if ((Get-H $zzLiveCfg) -ne $zzCfgLiveWas) {
    Fail 'the LIVE config moved during the arming write. Refusing to run.'
    exit 1
}
Pass 'config writes go to .state\audit-control-config.json - proven by a real write, and the live file did not move'

# --- the registry ---
# 🔴 THE STAMP HAS TO BE RE-TAKEN, AND NOT FOR A REASON ABOUT SAFETY. The stamp
# carries the file's LastWriteTimeUtc, so a fresh COPY always looks stale
# against the stamp this window took off the LIVE file - and Save-SRRegistry
# would then refuse for a reason that has nothing to do with the redirect. The
# refusal would look exactly like the redirect failing.
$zzRegCopy = Join-Path $SR_Root '.state\audit-control-registry.json'
try { Copy-Item -LiteralPath $zzLiveReg -Destination $zzRegCopy -Force -ErrorAction Stop }
catch { Fail ("could not copy the registry: {0}" -f $_.Exception.Message); exit 1 }
$SR_RegistryPath = $zzRegCopy
Set-SRRegistryStamp (Get-SRRegistryStamp)
$zzRegCopyWas = Get-H $zzRegCopy
$zzArmOk = $true
try {
    $zzProbeReg = Get-SRRegistry
    Save-SRRegistry -Registry $zzProbeReg
} catch {
    Fail ("the arming write through Save-SRRegistry threw: {0}" -f $_.Exception.Message)
    $zzArmOk = $false
}
if (-not $zzArmOk) { exit 1 }
if ((Get-H $zzRegCopy) -eq $zzRegCopyWas) {
    Fail 'a registry write through the real writer did NOT land in the redirected copy - the redirect is not armed. Refusing to run.'
    exit 1
}
if ((Get-H $zzLiveReg) -ne $zzRegLiveWas) {
    Fail 'the LIVE registry moved during the arming write. Refusing to run - something is still pointed at it.'
    exit 1
}
Pass 'registry writes go to .state\audit-control-registry.json - proven by a real Save-SRRegistry, and the live file did not move'
# Re-stamp against what is now on disk so the sandboxed registry is not stale
# against itself for the rest of the run.
Set-SRRegistryStamp (Get-SRRegistryStamp)

# 🔴 THE LIVE FILES ARE RE-HASHED AFTER EVERY GESTURE, not only at the end. A
# check that runs once at the bottom tells you which RUN broke the rule; a check
# that runs after each press tells you which PRESS did, and stops before the
# next one.
$zzRegDriftReported = $false
function Assert-LiveStill { param([string]$After)
    if ((Get-H $zzLiveCfg) -ne $zzCfgLiveWas) {
        Fail ("session-restore.config.json CHANGED after '{0}'. STOPPING." -f $After)
        exit 1
    }
    # The registry is written by the operator's own window on its own tick, so a
    # change here cannot be attributed to this run. It is reported once, and it
    # is never treated as a pass.
    if (-not $script:zzRegDriftReported -and (Get-H $zzLiveReg) -ne $zzRegLiveWas) {
        $script:zzRegDriftReported = $true
        Inconclusive ("sessions-registry.json moved (first noticed after '{0}'). Every save path in this process is redirected and that was proven above, and the operator's own window writes this file on its own tick - so this check cannot tell the two apart and does not claim to." -f $After)
    }
}

# ===========================================================================
# THE LAYOUT PUMP, taken from perf-driver.ps1 for the reason recorded there:
# ApplicationIdle drains the DispatcherTimer lane (Background, priority 4),
# which is where the expensive half of a selection now lives. Pumping at Loaded
# would measure the click and skip the work it starts.
# ===========================================================================
$zzW = 1480.0; $zzH = 980.0
$zzRoot = $window.Content
function Lay {
    foreach ($zzP in 1, 2) {
        $zzRoot.Measure((New-Object System.Windows.Size $zzW, $zzH))
        $zzRoot.Arrange((New-Object System.Windows.Rect 0, 0, $zzW, $zzH))
        $zzRoot.UpdateLayout()
        $window.Dispatcher.Invoke(
            [System.Windows.Threading.DispatcherPriority]::ApplicationIdle, [action]{}) | Out-Null
    }
}

# 🔴 THE SETTLE IS PART OF THE FRAME, AND LEAVING IT OUT IS HOW A GESTURE GETS
# REPORTED AS THREE TIMES FASTER THAN IT FEELS.
#
# Selecting a conversation goes through Request-ShowSelected, which DEBOUNCES:
# the first call draws, and every call inside the window only re-arms a 140 ms
# timer. So the draw the operator actually waits for happens after the handler
# has returned AND after two layout passes have completed - outside any
# stopwatch that stops at UpdateLayout. Measured here: pumping ApplicationIdle
# twice does not reach it, because the timer has not elapsed yet.
#
# 140 ms he waits is 140 ms this file owes him. Bounded at 900 ms so a timer
# that never settles cannot hang the run - and if it does not settle, that is
# itself the finding.
function Settle {
    $zzSw = [Diagnostics.Stopwatch]::StartNew()
    while ($script:showTimer.IsEnabled -and $zzSw.ElapsedMilliseconds -lt 900) {
        $window.Dispatcher.Invoke(
            [System.Windows.Threading.DispatcherPriority]::ApplicationIdle, [action]{}) | Out-Null
    }
    Lay
}

# A FIXED WPF WORKLOAD, measured in this run, so every figure below has a
# control that cannot have been optimised by the change under test. Copied in
# shape from perf-driver.ps1's Measure-SRWpfControl and kept in the test file
# for the same reason: nothing in lib\ can reach it.
function Measure-Ctl {
    $zzB = [double]::MaxValue
    for ($zzR = 0; $zzR -lt 5; $zzR++) {
        $zzS = [Diagnostics.Stopwatch]::StartNew()
        $zzSp = New-Object System.Windows.Controls.StackPanel
        for ($zzI = 0; $zzI -lt 100; $zzI++) {
            $zzTb = New-Object System.Windows.Controls.TextBlock
            $zzTb.Text = 'the quick brown fox jumps over the lazy dog and then does it again for measure'
            $zzTb.FontSize = 13.0
            $zzTb.TextWrapping = 'Wrap'
            $null = $zzSp.Children.Add($zzTb)
        }
        $zzSp.Measure((New-Object System.Windows.Size 420, 10000))
        $zzSp.Arrange((New-Object System.Windows.Rect 0, 0, 420, $zzSp.DesiredSize.Height))
        $zzSp.UpdateLayout()
        $zzS.Stop()
        if ($zzS.Elapsed.TotalMilliseconds -lt $zzB) { $zzB = $zzS.Elapsed.TotalMilliseconds }
    }
    return $zzB
}

Update-Model
$ui.ModeWork.IsChecked = $true
Set-Surface 'work'
$ui.Search.Text = ''; $ui.RailSearch.Text = ''; $ui.ListSearch.Text = ''
$script:railPick = $null; $script:bandPick = $null
Build-Rail; Build-Sessions; Lay
Note ("{0} conversations across {1} projects" -f $script:model.Count, @($script:dirs).Count)
$zzCtlStart = Measure-Ctl
Note ("the WPF control workload reads {0:N1} ms at the start of this run" -f $zzCtlStart)

# ===========================================================================
# 1. THE ATTRIBUTION INSTRUMENT
#
# Every named function it is pointed at is replaced by a wrapper that starts a
# stopwatch, calls the original, and books the time. INCLUSIVE time: a wrapped
# function that calls another wrapped function is charged for both, which is
# what makes the table readable as a tree rather than a pile.
#
# 🪤 IT REPLACES THE FUNCTION, IT DOES NOT DECORATE THE CALL SITE - which is the
# whole point. The handlers under test call these by name from inside lib\, a
# file this lane may not touch, so a wrapper at the call site would measure a
# path the operator never takes.
# ===========================================================================
$zzOrigFns = @{}
$zzProfMs  = @{}
$zzProfN   = @{}
$zzProfDep = @{}
$zzDepth   = 0
function Reset-Prof { $script:zzProfMs = @{}; $script:zzProfN = @{}; $script:zzProfDep = @{} }
function Wrap-Fn {
    param([string]$Name, [double]$InjectMs = 0)
    $zzCmd = $null
    try { $zzCmd = Get-Command $Name -CommandType Function -ErrorAction Stop } catch { }
    if (-not $zzCmd) { return $false }
    if ($script:zzOrigFns.ContainsKey($Name)) { return $true }
    $script:zzOrigFns[$Name] = $zzCmd.ScriptBlock
    $zzSleep = ''
    if ($InjectMs -gt 0) {
        # A busy wait, not Start-Sleep: Start-Sleep on the UI thread of a
        # dispatcher-driven run does not cost what it says it does.
        # 🪤 THE BRACES ARE DOUBLED because this is a -f format string, and a
        # literal { } in one is a placeholder the formatter cannot parse. It
        # threw before a single line of output, which reads as the harness being
        # broken rather than as one bad string.
        $zzSleep = ('$zzIw = [Diagnostics.Stopwatch]::StartNew(); while ($zzIw.Elapsed.TotalMilliseconds -lt {0}) {{ }}' -f $InjectMs)
    }
    # 🪤 $args IS SPLATTED, AND THAT IS WHAT CARRIES THE NAMED PARAMETERS. A
    # function with no param() block collects '-Wait' as a plain array element,
    # and splatting an array puts it back through the parameter binder as a
    # parameter name. Verified in the calibration below rather than assumed -
    # if this were wrong, every wrapped call with a named argument would
    # silently lose it and the numbers would describe different work.
    $zzSrc = @"
    `$zzSw = [Diagnostics.Stopwatch]::StartNew()
    `$script:zzDepth = `$script:zzDepth + 1
    if (-not `$script:zzProfDep.ContainsKey('$Name') -or `$script:zzProfDep['$Name'] -gt `$script:zzDepth) {
        `$script:zzProfDep['$Name'] = `$script:zzDepth
    }
    try {
        $zzSleep
        & `$script:zzOrigFns['$Name'] @args
    } finally {
        `$script:zzDepth = `$script:zzDepth - 1
        `$zzSw.Stop()
        if (-not `$script:zzProfMs.ContainsKey('$Name')) { `$script:zzProfMs['$Name'] = 0.0; `$script:zzProfN['$Name'] = 0 }
        `$script:zzProfMs['$Name'] = `$script:zzProfMs['$Name'] + `$zzSw.Elapsed.TotalMilliseconds
        `$script:zzProfN['$Name'] = `$script:zzProfN['$Name'] + 1
    }
"@
    $null = New-Item -Path ("function:\" + $Name) -Value ([scriptblock]::Create($zzSrc)) -Force
    return $true
}
# 🔑 NEUTER A FUNCTION INSTEAD OF WRAPPING IT, AND THE OVERHEAD PROBLEM GOES
# AWAY ENTIRELY.
#
# The wrapper costs ~0,09 ms a call. On a 126-row loop that is ~11 ms added to a
# ~64 ms build - a sixth of the quantity being measured, injected by the
# instrument. Subtracting the mean of it is honest but it does not remove the
# VARIANCE, and the items being attributed here are single-digit milliseconds.
#
# So a per-row helper is measured by REMOVING it: replace it with a constant,
# time the whole rebuild, and the difference is what that helper really cost -
# with no stopwatch anywhere near the loop. Interleaved against the real one so
# both halves eat the same drift, exactly as this repo's own A/Bs are run.
#
# 🪤 A STUB CHANGES BEHAVIOUR AND EVERY ONE OF THEM IS DECLARED BELOW. This
# measures cost, not correctness, and a stub whose side effect changes the row
# count would be measuring something else - so each is chosen to keep the shape
# of the output and its effect is written down beside the number.
function Stub-Fn {
    param([string]$Name, [string]$Body)
    $zzCmd2 = $null
    try { $zzCmd2 = Get-Command $Name -CommandType Function -ErrorAction Stop } catch { }
    if (-not $zzCmd2) { return $false }
    if (-not $script:zzOrigFns.ContainsKey($Name)) { $script:zzOrigFns[$Name] = $zzCmd2.ScriptBlock }
    $null = New-Item -Path ("function:\" + $Name) -Value ([scriptblock]::Create($Body)) -Force
    return $true
}
function Restore-Fn {
    param([string]$Name)
    if (-not $script:zzOrigFns.ContainsKey($Name)) { return }
    $null = New-Item -Path ("function:\" + $Name) -Value $script:zzOrigFns[$Name] -Force
    $script:zzOrigFns.Remove($Name)
}
function Unwrap-All {
    foreach ($zzN in @($script:zzOrigFns.Keys)) {
        $null = New-Item -Path ("function:\" + $zzN) -Value $script:zzOrigFns[$zzN] -Force
    }
    $script:zzOrigFns = @{}
}

# 🔴 THE COARSE SET IS TIMED, THE PER-ROW SET IS ONLY COUNTED, AND MIXING THEM
# WOULD HAVE MADE THIS WHOLE SECTION A MEASUREMENT OF THE INSTRUMENT.
#
# The wrapper costs ~0,14 ms a call (measured below, in this run, every run).
# On Build-Sessions that is nothing - it is called once. On Test-OnSurface,
# Get-Title or New-RailTile, which run once per row over 327 conversations, it
# is hundreds of milliseconds of stopwatch reported as the cost of the window.
# A profiler heavy enough to dominate what it profiles produces numbers that
# look exactly like the ones it was built to find.
#
# So the per-row helpers get a SEPARATE pass whose timings are thrown away and
# whose call COUNTS are the finding - which is what the open question about
# Build-Rail walking every project actually needs.
$zzWatch = @(
    'Build-Rail', 'Build-Sessions', 'Build-Manager', 'Update-Strip',
    'Show-Selected', 'Request-ShowSelected', 'Update-Document', 'Complete-DocParse',
    'Build-ReadDocument', 'Set-ReadDocument', 'Get-ReadTurns', 'Get-SRTranscriptBlocks',
    'Update-SendState', 'Update-RailLabels', 'Update-RailShelved', 'Update-RailSuggest',
    'Update-Model', 'Set-Status', 'Update-QueuePanel', 'Update-AskPanel', 'Get-RailBandCuts'
)
$zzCountOnly = @(
    'Test-OnSurface', 'New-RailTile', 'Test-SRProjectShelved',
    'Get-ProjectLabel', 'Get-Title', 'Get-Band', 'Get-AgeLabel', 'Get-AgeTicks'
)

Head 'calibrating the attribution instrument'
# --- (a) it must survive named parameters -----------------------------------
$zzCalOk = $true
if (Wrap-Fn 'Build-ReadDocument') {
    Reset-Prof
    $zzCalBlocks = @()
    try {
        $zzGotB = Get-SRTranscriptBlocks -JsonlPath "$(@($script:model)[0].S.jsonl)" -MaxRecords 40 -MaxTailBytes 262144
        $zzCalBlocks = @($zzGotB)
    } catch { }
    $zzCalDoc = $null
    try { $zzCalDoc = Build-ReadDocument -Blocks $zzCalBlocks -Truncated $false } catch { $zzCalOk = $false }
    if (-not $zzCalDoc -or $zzCalDoc -isnot [System.Windows.Documents.FlowDocument]) {
        Fail 'a WRAPPED function called with named parameters did not return what the unwrapped one does - the splat is losing arguments and every number below would describe different work.'
        $zzCalOk = $false
    } elseif ([int]$zzProfN['Build-ReadDocument'] -ne 1) {
        Fail ('the wrapper booked {0} call(s) for one invocation' -f [int]$zzProfN['Build-ReadDocument'])
        $zzCalOk = $false
    } else {
        Pass ('a wrapped call keeps its named parameters and is booked once ({0:N1} ms)' -f $zzProfMs['Build-ReadDocument'])
    }
    Unwrap-All
} else { Inconclusive 'Build-ReadDocument could not be wrapped - the parameter calibration did not run' }

# --- (b) it must be able to go red ------------------------------------------
# 40 ms of busy wait injected into a function nothing else in this section
# touches. If the table does not move by ~40 ms the instrument is not
# attributing anything and nothing below is evidence.
$null = Wrap-Fn 'Get-RailBandCuts' 40.0
Reset-Prof
$zzRedSw = [Diagnostics.Stopwatch]::StartNew()
Build-Rail
$zzRedSw.Stop()
$zzRedSaw = [double]$zzProfMs['Get-RailBandCuts']
Unwrap-All
if ($zzRedSaw -lt 35.0) {
    Fail ('the RED calibration did not fire: 40 ms was injected into Get-RailBandCuts and the instrument booked {0:N1} ms. The attribution below cannot be trusted.' -f $zzRedSaw)
} elseif ($zzRedSw.Elapsed.TotalMilliseconds -lt 35.0) {
    Fail ('the injected delay never reached the wall clock ({0:N1} ms for the whole Build-Rail) - the wrapper is not on the call path.' -f $zzRedSw.Elapsed.TotalMilliseconds)
} else {
    Pass ('RED: 40 ms injected into Get-RailBandCuts was booked as {0:N1} ms and moved the whole Build-Rail to {1:N1} ms - the instrument attributes' -f `
          $zzRedSaw, $zzRedSw.Elapsed.TotalMilliseconds)
}
# Put the rail back after the injected run.
Build-Rail; Build-Sessions; Lay

# --- (c) what the wrapper itself costs --------------------------------------
# A per-call overhead of a microsecond is nothing on Build-Sessions and is a
# real number on Test-OnSurface, which is called once per row. Measured rather
# than waved away.
$null = Wrap-Fn 'Get-RailBandCuts'
Reset-Prof
$zzOvA = [Diagnostics.Stopwatch]::StartNew()
for ($zzI = 0; $zzI -lt 2000; $zzI++) { $null = Get-RailBandCuts }
$zzOvA.Stop()
Unwrap-All
$zzOvB = [Diagnostics.Stopwatch]::StartNew()
for ($zzI = 0; $zzI -lt 2000; $zzI++) { $null = Get-RailBandCuts }
$zzOvB.Stop()
$zzOver = ($zzOvA.Elapsed.TotalMilliseconds - $zzOvB.Elapsed.TotalMilliseconds) / 2000.0
Note ('wrapper overhead: {0:N4} ms per call (2.000 calls wrapped {1:N0} ms vs bare {2:N0} ms). Multiply by the call counts below before reading a small row as real.' -f `
      $zzOver, $zzOvA.Elapsed.TotalMilliseconds, $zzOvB.Elapsed.TotalMilliseconds)

Assert-LiveStill 'the calibration'

# ===========================================================================
# 2. D3 - THE FIVE WORST CONTROLS, WITH THE CALL THAT OWNS THE TIME
# ===========================================================================
# 🔴 A GESTURE IS MEASURED AS A GESTURE, NOT AS THE FUNCTIONS IT HAPPENS TO
# CALL. Every previous bench of these controls called Build-Rail and
# Build-Sessions directly. That is not what the operator does: he moves the
# SELECTION, and everything WPF and this window do in response to a selection
# moving is outside a bench written that way. The gap between 130 ms of
# rebuild and 1.469 ms to the frame is exactly the size of what was left out.
$zzGest = New-Object System.Collections.Generic.List[object]
function Add-Gesture {
    param([string]$Name, [scriptblock]$Reset, [scriptblock]$Do, [string]$Note = '')
    $null = $script:zzGest.Add([PSCustomObject]@{ Name = $Name; Reset = $Reset; Do = $Do; Note = $Note })
}

# A real project tile to pick, and one that is NOT the current pick.
$zzTiles = @($ui.RailList.Items | Where-Object { "$($_.Kind)" -ne 'band' -and "$($_.Path)" })
if ($zzTiles.Count -lt 2) {
    Inconclusive 'fewer than two project tiles in the rail - the rail gestures cannot be measured'
} else {
    # 🪤 THE SAME TILE EVERY REPETITION. Picking "whatever is at index 1" from
    # live state is how a harness ends up profiling a different project on every
    # run, and this repo has already been caught doing exactly that with the
    # document subject.
    $zzTile = $zzTiles[0]
    $zzPickPath = "$($zzTile.Path)"
    Note ("the rail gestures all pick '{0}' ({1} conversation(s))" -f $zzTile.Label, $zzTile.Count)

    # 🪤 THE ROW OBJECT IS REBUILT EVERY TIME, so the tile captured before the
    # reset is not in the collection the reset leaves behind - and assigning a
    # SelectedItem that is not in Items sets it to null, fires nothing, and
    # times an empty gesture at 0,2 ms. The reset re-finds it BY PATH and leaves
    # it where the timed block can pick it up without paying for the lookup.
    Add-Gesture 'RailList SelectionChanged (pick a project)' `
        { $script:railPick = $null; $ui.RailList.SelectedItem = $null; Build-Rail; Build-Sessions; Lay
          $script:zzPickNow = @($ui.RailList.Items | Where-Object { "$($_.Path)" -eq $script:zzPickPath })[0] } `
        { $ui.RailList.SelectedItem = $script:zzPickNow } `
        'the real gesture: the SELECTION moves, and the handler is whatever that sets off'

    Add-Gesture 'RailClear (clear the project filter)' `
        { $script:railPick = $script:zzPickPath; Build-Rail; Build-Sessions; Lay } `
        { $zzE = New-Object System.Windows.Input.MouseButtonEventArgs(
                    [System.Windows.Input.Mouse]::PrimaryDevice, 0, [System.Windows.Input.MouseButton]::Left)
          $zzE.RoutedEvent = [System.Windows.UIElement]::MouseLeftButtonUpEvent
          $ui.RailClear.RaiseEvent($zzE) } ''

    Add-Gesture 'RailSort (cycle the rail sort)' `
        { $script:railSort = 'recent'; Update-RailLabels; Build-Rail; Lay } `
        { $zzE = New-Object System.Windows.Input.MouseButtonEventArgs(
                    [System.Windows.Input.Mouse]::PrimaryDevice, 0, [System.Windows.Input.MouseButton]::Left)
          $zzE.RoutedEvent = [System.Windows.UIElement]::MouseLeftButtonDownEvent
          $ui.RailSort.RaiseEvent($zzE) } ''

    Add-Gesture 'RailShelved (show/hide shelved projects)' `
        { $script:railShowShelved = $false; Build-Rail; Lay } `
        { $zzE = New-Object System.Windows.Input.MouseButtonEventArgs(
                    [System.Windows.Input.Mouse]::PrimaryDevice, 0, [System.Windows.Input.MouseButton]::Left)
          $zzE.RoutedEvent = [System.Windows.UIElement]::MouseLeftButtonDownEvent
          $ui.RailShelved.RaiseEvent($zzE) } ''

    Add-Gesture 'RailOnlyLive (all / running)' `
        { $script:railOnlyLive = $false; Update-RailLabels; Build-Rail; Lay } `
        { $zzE = New-Object System.Windows.Input.MouseButtonEventArgs(
                    [System.Windows.Input.Mouse]::PrimaryDevice, 0, [System.Windows.Input.MouseButton]::Left)
          $zzE.RoutedEvent = [System.Windows.UIElement]::MouseLeftButtonDownEvent
          $ui.RailOnlyLive.RaiseEvent($zzE) } ''

    $script:zzPickPath = $zzPickPath
    $script:zzPickNow = $zzTile
}

if ((Want 'd3') -and $zzGest.Count) {
    Head 'D3 - what the five worst controls are actually doing'
    foreach ($zzN in $zzWatch) { $null = Wrap-Fn $zzN }
    Note ("{0} of {1} watched functions were found and wrapped" -f $zzOrigFns.Count, $zzWatch.Count)

    $zzD3 = New-Object System.Collections.Generic.List[object]
    foreach ($zzG in $zzGest) {
        # 🔴 THE PROFILE IS AVERAGED OVER EVERY REPETITION, NOT TAKEN FROM THE
        # FASTEST ONE - AND THAT CHANGED THE ANSWER.
        #
        # These gestures do not do the same work every time. A pick whose
        # currently selected conversation survives the new filter skips the
        # reading pane entirely; one whose selection is filtered out rebuilds
        # the whole document. So "the profile of the best run" is the profile of
        # whichever repetition happened to do the LEAST - it printed
        # Show-Selected at 0,2 ms on one run and 65 ms on the next, from
        # identical source, and reading either as the cost of the gesture is
        # reading the coin toss. The mean over N describes what the operator
        # gets; best and worst are printed beside it so the spread is visible
        # rather than hidden inside a single number.
        $zzBestH = [double]::MaxValue
        $zzBestF = [double]::MaxValue
        $zzWorstH = 0.0
        $zzWorstF = 0.0
        $zzAccMs = @{}; $zzAccN = @{}; $zzAccHand = @{}
        $zzAccSettle = 0.0
        $zzReps = 0
        $zzThrew = ''
        for ($zzR = 0; $zzR -lt $zzRuns; $zzR++) {
            try { & $zzG.Reset } catch { $zzThrew = "reset: $($_.Exception.Message)" ; break }
            Reset-Prof
            $script:zzDepth = 0
            $zzHs = [Diagnostics.Stopwatch]::StartNew()
            try { & $zzG.Do | Out-Null } catch { $zzThrew = "$($_.Exception.Message)" }
            $zzHs.Stop()
            # 🔴 THE PROFILE IS SNAPSHOTTED TWICE, AND IT HAS TO BE. Work the
            # debounce defers runs during the SETTLE, after the handler has
            # returned - so booking it against the handler prints
            # "Complete-DocParse: 56% of the handler" about a function the
            # handler never called. Deferred is not removed, and it is not the
            # handler either; it is the rest of the frame.
            $zzHandMs = @{}; foreach ($zzK in $zzProfMs.Keys) { $zzHandMs[$zzK] = $zzProfMs[$zzK] }
            $zzFs = [Diagnostics.Stopwatch]::StartNew()
            Settle
            $zzFs.Stop()
            $zzH1 = $zzHs.Elapsed.TotalMilliseconds
            $zzF1 = $zzH1 + $zzFs.Elapsed.TotalMilliseconds
            # 🔑 THE FIRST REPETITION, KEPT SEPARATELY. A best-of-N hides the
            # cold pass by construction, and a cold pass is what the operator
            # gets on the first pick after the window opens - JIT, first
            # container generation, a document that has never been built. It is
            # also the most likely explanation for a figure three times this
            # table's that a warm bench cannot reproduce.
            if ($zzR -eq 0) { $zzFirstH = $zzH1; $zzFirstF = $zzF1 }
            if ($zzH1 -lt $zzBestH) { $zzBestH = $zzH1 }
            if ($zzH1 -gt $zzWorstH) { $zzWorstH = $zzH1 }
            if ($zzF1 -lt $zzBestF) { $zzBestF = $zzF1 }
            if ($zzF1 -gt $zzWorstF) { $zzWorstF = $zzF1 }
            $zzReps++
            $zzAccSettle += $zzFs.Elapsed.TotalMilliseconds
            foreach ($zzK in $zzProfMs.Keys) {
                if (-not $zzAccMs.ContainsKey($zzK)) { $zzAccMs[$zzK] = 0.0; $zzAccN[$zzK] = 0.0; $zzAccHand[$zzK] = 0.0 }
                $zzAccMs[$zzK] = $zzAccMs[$zzK] + $zzProfMs[$zzK]
                $zzAccN[$zzK] = $zzAccN[$zzK] + $zzProfN[$zzK]
                if ($zzHandMs.ContainsKey($zzK)) { $zzAccHand[$zzK] = $zzAccHand[$zzK] + $zzHandMs[$zzK] }
            }
        }
        $zzMeanMs = @{}; $zzMeanN = @{}; $zzMeanHand = @{}
        if ($zzReps -gt 0) {
            foreach ($zzK in $zzAccMs.Keys) {
                $zzMeanMs[$zzK] = $zzAccMs[$zzK] / $zzReps
                $zzMeanN[$zzK] = $zzAccN[$zzK] / $zzReps
                $zzMeanHand[$zzK] = $zzAccHand[$zzK] / $zzReps
            }
        }
        $null = $zzD3.Add([PSCustomObject]@{
            Name = $zzG.Name; H = $zzBestH; F = $zzBestF; WH = $zzWorstH; WF = $zzWorstF
            FirstH = $zzFirstH; FirstF = $zzFirstF; Threw = $zzThrew
            ProfMs = $zzMeanMs; ProfN = $zzMeanN; Hand = $zzMeanHand
            SettleMs = $(if ($zzReps) { $zzAccSettle / $zzReps } else { 0 }); Reps = $zzReps; Note = $zzG.Note })
        Assert-LiveStill $zzG.Name
    }
    Unwrap-All

    Write-Host ''
    Write-Host ("  {0,-46} {1,9} {2,9} {3,9} {4,9} {5,9} {6,9}" -f 'gesture', 'hand 1st', 'hand best', 'hand wrst', 'frm 1st', 'frm best', 'frm wrst')
    foreach ($zzD in $zzD3) {
        if ($zzD.Threw) { Write-Host ("  {0,-46} {1}" -f $zzD.Name, ('THREW: ' + $zzD.Threw)) -ForegroundColor Red; continue }
        Write-Host ("  {0,-46} {1,9:N1} {2,9:N1} {3,9:N1} {4,9:N1} {5,9:N1} {6,9:N1}" -f `
                    $zzD.Name, $zzD.FirstH, $zzD.H, $zzD.WH, $zzD.FirstF, $zzD.F, $zzD.WF)
    }
    Note ('best and worst of {0} repetitions. A wide spread here is not noise to be averaged away - these gestures do different amounts of work depending on whether the selected conversation survives the new filter.' -f $zzRuns)
    Write-Host ''
    Write-Host '  and where that time went (inclusive; a nested call is charged to both):'
    foreach ($zzD in $zzD3) {
        if ($zzD.Threw -or -not $zzD.ProfMs) { continue }
        Write-Host ''
        Write-Host ("  {0}   mean over {1} repetition(s)" -f $zzD.Name, $zzD.Reps) -ForegroundColor White
        if ($zzD.Note) { Note $zzD.Note }
        Write-Host ("      {0,-26} {1,9} {2,9}  {3}" -f 'function', 'handler', 'settle', 'calls')
        $zzKeys = @($zzD.ProfMs.Keys | Sort-Object { -$zzD.ProfMs[$_] })
        $zzShown = 0
        foreach ($zzK in $zzKeys) {
            $zzMs = [double]$zzD.ProfMs[$zzK]
            $zzInH = 0.0
            if ($zzD.Hand -and $zzD.Hand.ContainsKey($zzK)) { $zzInH = [double]$zzD.Hand[$zzK] }
            $zzInS = $zzMs - $zzInH
            $zzNn = [double]$zzD.ProfN[$zzK]
            # Below a tenth of a millisecond the wrapper overhead is the reading.
            if ($zzMs -lt 0.15 -and $zzShown -ge 6) { continue }
            Write-Host ("      {0,-26} {1,9:N1} {2,9:N1}  x{3:N1}" -f $zzK, $zzInH, $zzInS, $zzNn)
            $zzShown++
        }
        if (-not $zzShown) { Note 'nothing watched was called - the time is in code this instrument was not pointed at' }
        $zzCalls = 0.0
        foreach ($zzK in $zzKeys) { $zzCalls += [double]$zzD.ProfN[$zzK] }
        Note ("{0} wrapped call(s) in this gesture, so about {1:N1} ms of the handler figure above is the instrument itself" -f $zzCalls, ($zzCalls * $zzOver))
    }

    # -----------------------------------------------------------------------
    # HOW MANY ROWS EACH GESTURE WALKS. Timings discarded - at 0,14 ms a call
    # the wrapper IS the measurement here - but the counts are exactly the
    # question: does the rail rebuild walk every project while the sessions
    # rebuild walks a filtered set?
    # -----------------------------------------------------------------------
    Write-Host ''
    Write-Host '  how many rows each gesture walks (counts only - the timings in this pass are the instrument):'
    foreach ($zzN in $zzCountOnly) { $null = Wrap-Fn $zzN }
    Note ("{0} of {1} per-row helpers were found and counted" -f $zzOrigFns.Count, @($zzCountOnly).Count)
    foreach ($zzG in $zzGest) {
        try { & $zzG.Reset } catch { continue }
        Reset-Prof
        $script:zzDepth = 0
        try { & $zzG.Do | Out-Null } catch { }
        Lay
        $zzLine = @()
        foreach ($zzK in @($zzProfN.Keys | Sort-Object { -$zzProfN[$_] })) {
            $zzLine += ('{0} x{1}' -f $zzK, [int]$zzProfN[$zzK])
        }
        Write-Host ("      {0,-46} {1}" -f $zzG.Name, $(if ($zzLine.Count) { $zzLine -join ',  ' } else { 'none of the per-row helpers were called' }))
    }
    Unwrap-All
    Build-Rail; Build-Sessions; Lay
    Assert-LiveStill 'the counting pass'
}

# ===========================================================================
# 2b. WHY A PICK COSTS MORE THAN A CLEAR - THE ROW COUNT, MEASURED
# ===========================================================================
# 🔴 THE SUSPICION UNDER TEST WAS THAT Build-Rail WALKS ALL 36 PROJECTS WHILE
# Build-Sessions WALKS A FILTERED SET. The call counts above already refute the
# first half - Test-OnSurface is called ZERO times by either, because
# Build-Sessions has it inlined and Build-Rail never had it - and the direction
# of the second half is the wrong way round: narrowing to a project makes the
# sessions column build MORE rows, not fewer.
#
# Build-Sessions filters like this (sessions-window.ps1, the row loop):
#
#     if ($pick) { if ($r.D.path -ne $pick) { continue } }
#     elseif (-not ($r.Live -or $r.Warm -or selected)) { continue }
#
# With NO pick the recency gate throws away everything that is not live, warm or
# selected. With a pick that gate is deliberately SKIPPED - "a pick is the
# operator naming a project; the answer is its conversations" - so a project
# with 125 conversations builds 125 rows where the unfiltered list built ~40.
# That is a deliberate product decision, and it is also the entire reason the
# most expensive gesture in the rail is the one that narrows.
#
# Everything below is measured with its control in the same run.
if ((Want 'd3') -and $zzGest.Count) {
    Head 'why narrowing costs more than clearing'
    function Count-Rows { return @($ui.SessionList.Items | Where-Object { "$($_.Kind)" -eq 'session' }).Count }
    function Time-It { param([scriptblock]$Do, [int]$N = 5)
        $zzB = [double]::MaxValue
        for ($zzI = 0; $zzI -lt $N; $zzI++) {
            $zzS = [Diagnostics.Stopwatch]::StartNew()
            & $Do | Out-Null
            $zzS.Stop()
            if ($zzS.Elapsed.TotalMilliseconds -lt $zzB) { $zzB = $zzS.Elapsed.TotalMilliseconds }
        }
        return $zzB
    }
    # The two projects that make the comparison: the one holding whatever is
    # selected right now, and the biggest one that does not.
    $zzSelRow = @($script:model | Where-Object { "$($_.Id)" -eq "$($script:selId)" })
    $zzSelProj = $(if ($zzSelRow.Count) { "$($zzSelRow[0].D.path)" } else { '' })
    $zzByProj = @{}
    foreach ($zzR2 in $script:model) {
        $zzP = "$($zzR2.D.path)"
        if (-not $zzByProj.ContainsKey($zzP)) { $zzByProj[$zzP] = 0 }
        $zzByProj[$zzP] = $zzByProj[$zzP] + 1
    }
    # 🔴 CHOSEN FROM THE TILES THE RAIL ACTUALLY HAS, NOT FROM THE MODEL. The
    # first version took the biggest OTHER project out of the model, and that
    # project had no tile on the rail - so the "pick" assigned a SelectedItem
    # that was not in Items, WPF silently set it to null, nothing fired, and the
    # row printed 0,3 ms for a gesture that never happened. A harness that can
    # measure nothing and call it fast is worse than no harness.
    $zzRailPaths = @{}
    foreach ($zzT3 in @($ui.RailList.Items)) { if ("$($zzT3.Path)") { $zzRailPaths["$($zzT3.Path)"] = $true } }
    $zzBigOther = ''    # a tile the gesture can actually click
    $zzBigModel = ''    # the biggest other project in the model, tile or not
    foreach ($zzP in @($zzByProj.Keys | Sort-Object { -$zzByProj[$_] })) {
        if ($zzP -eq $zzSelProj) { continue }
        if (-not $zzBigModel) { $zzBigModel = $zzP }
        if (-not $zzBigOther -and $zzRailPaths.ContainsKey($zzP)) { $zzBigOther = $zzP }
    }
    if (-not $zzBigOther) {
        Inconclusive 'no project other than the selected one has a tile on the rail - the two-way gesture comparison cannot be made'
    }
    Note ("selected conversation is in '{0}' ({1}); biggest other project in the model '{2}' ({3}); biggest other WITH A TILE '{4}' ({5})" -f `
          (Get-ProjectLabel $zzSelProj), $zzByProj[$zzSelProj],
          (Get-ProjectLabel $zzBigModel), $zzByProj[$zzBigModel],
          (Get-ProjectLabel $zzBigOther), $zzByProj[$zzBigOther])

    # Build-Sessions on its own, in three states, all in this run.
    $script:railPick = $null
    $zzMsNone = Time-It { Build-Sessions }
    $zzRowsNone = Count-Rows
    $script:railPick = $zzSelProj
    $zzMsSel = Time-It { Build-Sessions }
    $zzRowsSel = Count-Rows
    $script:railPick = $zzBigModel
    $zzMsBig = Time-It { Build-Sessions }
    $zzRowsBig = Count-Rows
    $script:railPick = $null
    Build-Sessions
    Write-Host ''
    Write-Host ("  {0,-52} {1,8} {2,10} {3,12}" -f 'Build-Sessions', 'rows', 'ms', 'ms per row')
    Write-Host ("  {0,-52} {1,8} {2,10:N1} {3,12:N2}" -f 'no project picked (the recency gate applies)', $zzRowsNone, $zzMsNone, $(if ($zzRowsNone) { $zzMsNone / $zzRowsNone } else { 0 }))
    Write-Host ("  {0,-52} {1,8} {2,10:N1} {3,12:N2}" -f ("narrowed to '" + (Get-ProjectLabel $zzSelProj) + "' (gate skipped)"), $zzRowsSel, $zzMsSel, $(if ($zzRowsSel) { $zzMsSel / $zzRowsSel } else { 0 }))
    Write-Host ("  {0,-52} {1,8} {2,10:N1} {3,12:N2}" -f ("narrowed to '" + (Get-ProjectLabel $zzBigModel) + "' (gate skipped)"), $zzRowsBig, $zzMsBig, $(if ($zzRowsBig) { $zzMsBig / $zzRowsBig } else { 0 }))
    Note 'the same function, the same run: the cost tracks the ROW COUNT, and narrowing to a busy project RAISES it because the pick deliberately lifts the live-or-warm gate'

    # And the same thing through the real gesture, both ways round: picking the
    # project the current selection is IN (so the selection survives and no
    # document work happens) and picking one it is NOT in (so the list
    # auto-selects a different conversation and the reading pane rebuilds).
    function Pick-Project { param([string]$P)
        $zzT2 = @($ui.RailList.Items | Where-Object { "$($_.Path)" -eq $P })
        if (-not $zzT2.Count) { return $null }
        $ui.RailList.SelectedItem = $zzT2[0]
        return $zzT2[0]
    }
    $zzWhich = @(
        @{ N = 'pick the project the selection is already in'; P = $zzSelProj }
        @{ N = 'pick a DIFFERENT project (the list re-selects)'; P = $zzBigOther }
    )
    Write-Host ''
    Write-Host ("  {0,-52} {1,10} {2,10} {3,8}" -f 'the real gesture', 'handler ms', 'frame ms', 'rows')
    foreach ($zzWw in $zzWhich) {
        if (-not $zzWw.P) { continue }
        $zzBh = [double]::MaxValue; $zzBf = [double]::MaxValue; $zzRw = 0
        $zzMissed = 0
        for ($zzI = 0; $zzI -lt 5; $zzI++) {
            $script:railPick = $null; $ui.RailList.SelectedItem = $null
            Build-Rail; Build-Sessions; Settle
            $zzS = [Diagnostics.Stopwatch]::StartNew()
            $zzHit = Pick-Project $zzWw.P
            $zzS.Stop()
            # PROVE THE GESTURE HAPPENED. railPick is what the handler sets, and
            # if it did not move then no handler ran and the stopwatch measured
            # an assignment.
            if (-not $zzHit -or "$($script:railPick)" -ne $zzWw.P) { $zzMissed++ }
            $zzS2 = [Diagnostics.Stopwatch]::StartNew()
            Settle
            $zzS2.Stop()
            if ($zzS.Elapsed.TotalMilliseconds -lt $zzBh) { $zzBh = $zzS.Elapsed.TotalMilliseconds }
            if (($zzS.Elapsed.TotalMilliseconds + $zzS2.Elapsed.TotalMilliseconds) -lt $zzBf) {
                $zzBf = $zzS.Elapsed.TotalMilliseconds + $zzS2.Elapsed.TotalMilliseconds
            }
            $zzRw = Count-Rows
        }
        if ($zzMissed) {
            Fail ("'{0}': the pick did not take on {1} of 5 repetitions - railPick never moved, so this row would have been a measurement of nothing" -f $zzWw.N, $zzMissed)
        } else {
            Write-Host ("  {0,-52} {1,10:N1} {2,10:N1} {3,8}" -f $zzWw.N, $zzBh, $zzBf, $zzRw)
        }
    }
    $script:railPick = $null; $ui.RailList.SelectedItem = $null
    Build-Rail; Build-Sessions; Settle
    Note ('the WPF control workload reads {0:N1} ms right here, so these rows can be compared with each other and with nothing else' -f (Measure-Ctl))
    Assert-LiveStill 'the row-count deep dive'
}

# ===========================================================================
# 2c. THE 114 ms GAP - IS THE HANDLER'S Build-Sessions THE SAME CALL?
# ===========================================================================
# 🔴 TWO NUMBERS FOR ONE FUNCTION IN ONE REPORT IS A DEFECT IN THE REPORT.
# The D3 profile put Build-Sessions at 178 ms inside the pick handler; the
# deep dive timed the same function at 64 ms. Before anything is quoted, the
# two have to be measured side by side, in one run, under one statistic - and
# the conditions have to be named, because they are not the same call.
if (Want 'gap') {
    Head 'the same function under both conditions'
    if (-not $zzGest.Count) { Inconclusive 'no rail tile to pick - the gap cannot be measured' }
    else {
        $null = Wrap-Fn 'Build-Sessions'
        $null = Wrap-Fn 'Show-Selected'
        $null = Wrap-Fn 'Request-ShowSelected'
        $null = Wrap-Fn 'Update-Document'
        $zzGapN = 9
        function Run-Gap { param([string]$Which)
            $zzMs2 = New-Object System.Collections.Generic.List[double]
            $zzNest = New-Object System.Collections.Generic.List[double]
            for ($zzI = 0; $zzI -lt $zzGapN; $zzI++) {
                # Same reset either way, so both conditions start from the same
                # place: no pick, the list rebuilt, the selection settled.
                $script:railPick = $null; $ui.RailList.SelectedItem = $null
                Build-Rail; Build-Sessions; Settle
                Reset-Prof
                $script:zzDepth = 0
                if ($Which -eq 'handler') {
                    $zzT4 = @($ui.RailList.Items | Where-Object { "$($_.Path)" -eq $script:zzPickPath })
                    if (-not $zzT4.Count) { continue }
                    $ui.RailList.SelectedItem = $zzT4[0]
                } else {
                    # The deep dive's condition: railPick set by hand, then the
                    # function called directly. No SelectionChanged fires on the
                    # RAIL, so nothing else in the handler runs.
                    $script:railPick = $script:zzPickPath
                    Build-Sessions
                }
                $zzMs2.Add([double]$zzProfMs['Build-Sessions'])
                $zzNest.Add([double]$zzProfMs['Show-Selected'])
            }
            $zzSorted2 = @($zzMs2 | Sort-Object)
            $zzMean2 = 0.0; foreach ($zzV3 in $zzMs2) { $zzMean2 += $zzV3 }
            if ($zzMs2.Count) { $zzMean2 = $zzMean2 / $zzMs2.Count }
            $zzNestMean = 0.0; foreach ($zzV3 in $zzNest) { $zzNestMean += $zzV3 }
            if ($zzNest.Count) { $zzNestMean = $zzNestMean / $zzNest.Count }
            return [PSCustomObject]@{
                Best = $(if ($zzSorted2.Count) { $zzSorted2[0] } else { 0 })
                Worst = $(if ($zzSorted2.Count) { $zzSorted2[$zzSorted2.Count - 1] } else { 0 })
                Mean = $zzMean2; Nested = $zzNestMean; N = $zzMs2.Count }
        }
        # Interleaved, so a machine that changes mid-section changes both.
        $zzGapA = Run-Gap 'handler'
        $zzGapB = Run-Gap 'direct'
        $zzGapA2 = Run-Gap 'handler'
        $zzGapB2 = Run-Gap 'direct'
        Unwrap-All
        Write-Host ''
        Write-Host ("  {0,-52} {1,8} {2,8} {3,8} {4,12}" -f 'Build-Sessions, inclusive', 'best', 'mean', 'worst', 'of which')
        Write-Host ("  {0,-52} {1,8} {2,8} {3,8} {4,12}" -f '', '', '', '', 'Show-Selected')
        foreach ($zzP2 in @(
            @{ N = 'inside the real pick handler, pass 1'; R = $zzGapA }
            @{ N = 'called directly with railPick set, pass 1'; R = $zzGapB }
            @{ N = 'inside the real pick handler, pass 2'; R = $zzGapA2 }
            @{ N = 'called directly with railPick set, pass 2'; R = $zzGapB2 })) {
            Write-Host ("  {0,-52} {1,8:N1} {2,8:N1} {3,8:N1} {4,12:N1}" -f `
                        $zzP2.N, $zzP2.R.Best, $zzP2.R.Mean, $zzP2.R.Worst, $zzP2.R.Nested)
        }
        Note ('n={0} per row, same reset, same run, interleaved. The "of which" column is Show-Selected charged INSIDE Build-Sessions - it gets there through the trailing SelectedItem assignment, which fires SelectionChanged on the sessions list.' -f $zzGapN)
        $script:railPick = $null; $ui.RailList.SelectedItem = $null
        Build-Rail; Build-Sessions; Settle
        Assert-LiveStill 'the gap section'
    }
}

# ===========================================================================
# 2d. WHERE THE PER-ROW COST GOES
# ===========================================================================
if (Want 'rowcost') {
    Head 'where the per-row cost goes'
    if (-not $zzGest.Count) { Inconclusive 'no rail tile to pick - the row cost cannot be attributed' }
    else {
        # Narrowed to the busiest project, which is the state that builds the
        # most rows and therefore the state worth attributing.
        $script:railPick = $script:zzPickPath
        Build-Sessions; Settle
        $zzRowsN = @($ui.SessionList.Items | Where-Object { "$($_.Kind)" -eq 'session' }).Count
        $zzBandsN = @($script:Bands).Count
        Note ("attributing a rebuild of {0} row(s) across {1} band(s); the control workload reads {2:N1} ms here" -f `
              $zzRowsN, $zzBandsN, (Measure-Ctl))

        function Time-Build { param([int]$N = 9)
            $zzB3 = [double]::MaxValue
            for ($zzI = 0; $zzI -lt $N; $zzI++) {
                $zzS8 = [Diagnostics.Stopwatch]::StartNew()
                Build-Sessions
                $zzS8.Stop()
                if ($zzS8.Elapsed.TotalMilliseconds -lt $zzB3) { $zzB3 = $zzS8.Elapsed.TotalMilliseconds }
            }
            return $zzB3
        }
        # 🔴 THE NULL A/B FIRST, AND IT IS THE MOST IMPORTANT LINE IN THIS
        # SECTION. Baseline against baseline, interleaved exactly like every
        # real comparison below. Whatever it reads is the smallest difference
        # this instrument can tell from nothing, and any item under it is
        # reported as unmeasurable rather than as a number.
        $zzNull1 = Time-Build
        $zzNull2 = Time-Build
        $zzNull3 = Time-Build
        $zzNullSpread = [Math]::Abs($zzNull1 - $zzNull2)
        if ([Math]::Abs($zzNull2 - $zzNull3) -gt $zzNullSpread) { $zzNullSpread = [Math]::Abs($zzNull2 - $zzNull3) }
        if ([Math]::Abs($zzNull1 - $zzNull3) -gt $zzNullSpread) { $zzNullSpread = [Math]::Abs($zzNull1 - $zzNull3) }
        $zzBase = [Math]::Min($zzNull1, [Math]::Min($zzNull2, $zzNull3))
        Note ("baseline {0:N1} / {1:N1} / {2:N1} ms for the SAME code - the resolution floor of this instrument is {3:N1} ms, or {4:N3} ms per row" -f `
              $zzNull1, $zzNull2, $zzNull3, $zzNullSpread, ($zzNullSpread / [Math]::Max(1, $zzRowsN)))

        # --- the neuterable calls ------------------------------------------
        $zzAB = @(
            @{ N = 'Get-RowSubAgents';  F = 'Get-RowSubAgents';  B = 'return @()'
               Side = 'the selected conversation loses its nested sub-agent rows (one row''s worth)' }
            @{ N = 'Test-SRQueueFresh'; F = 'Test-SRQueueFresh'; B = 'return $true'
               Side = 'every queue mark draws, so slightly MORE tooltip work - this under-reports the gate' }
            @{ N = 'Get-AgeLabel';      F = 'Get-AgeLabel';      B = "return '2h'"
               Side = 'every row shows the same age string' }
            @{ N = 'Get-CtxBrush';      F = 'Get-CtxBrush';      B = 'return $Pal.Ok'
               Side = 'context bars all one colour' }
            @{ N = 'Sort-SessionRows';  F = 'Sort-SessionRows';  B = 'param($Rows) return @($Rows)'
               Side = 'rows come out unsorted - the ORDER changes, the count does not' }
            @{ N = 'Get-Title';         F = 'Get-Title';         B = "return ([PSCustomObject]@{ Text = 'x'; Derived = `$false })"
               Side = 'every row is titled x; only called when the sessions search box has text' }
        )
        $zzRows2 = New-Object System.Collections.Generic.List[object]
        foreach ($zzA5 in $zzAB) {
            if (-not (Get-Command $zzA5.F -CommandType Function -ErrorAction SilentlyContinue)) {
                $null = $zzRows2.Add([PSCustomObject]@{ N = $zzA5.N; Ms = $null; Side = 'no such function in this build' })
                continue
            }
            $zzWith = Time-Build
            if (-not (Stub-Fn $zzA5.F $zzA5.B)) { continue }
            $zzWithout = Time-Build
            Restore-Fn $zzA5.F
            $zzWith2 = Time-Build
            # Both real halves, so the drift between them is visible.
            $zzReal = [Math]::Min($zzWith, $zzWith2)
            $null = $zzRows2.Add([PSCustomObject]@{
                N = $zzA5.N; Ms = ($zzReal - $zzWithout); Side = $zzA5.Side
                Drift = [Math]::Abs($zzWith - $zzWith2) })
        }

        Write-Host ''
        Write-Host ("  {0,-24} {1,10} {2,10} {3,9}   {4}" -f 'removed from the loop', 'ms saved', 'ms/row', 'verdict', 'what the stub changed')
        foreach ($zzR5 in $zzRows2) {
            if ($null -eq $zzR5.Ms) { Write-Host ("  {0,-24} {1}" -f $zzR5.N, $zzR5.Side); continue }
            $zzVerd = $(if ($zzR5.Ms -gt $zzNullSpread) { 'measured' } else { 'UNDER FLOOR' })
            Write-Host ("  {0,-24} {1,10:N1} {2,10:N3} {3,9}   {4}" -f `
                        $zzR5.N, $zzR5.Ms, ($zzR5.Ms / [Math]::Max(1, $zzRowsN)), $zzVerd, $zzR5.Side)
        }

        # --- the inline work, which cannot be neutered ----------------------
        # 🔴 THIS IS A RECONSTRUCTION, NOT A MEASUREMENT OF THE LOOP, and it is
        # labelled as one. These are expressions inside Build-Sessions, not
        # calls, so there is nothing to replace without editing lib\. Each is
        # run standalone against the REAL data the loop would hand it, timed
        # over many repetitions, and multiplied by the real row count. It says
        # what the operation costs; it does not prove that is where the
        # rebuild's time went. The residual below is the check on it.
        $zzKept = @($ui.SessionList.Items | Where-Object { "$($_.Kind)" -eq 'session' -and $_.Row } | ForEach-Object { $_.Row })
        $zzSaids = @($zzKept | ForEach-Object { "$($_.Said.Said)" } | Where-Object { $_ })
        if (-not $zzSaids.Count) { $zzSaids = @('a said line with   irregular    spacing in it') }
        $zzIds = @($zzKept | ForEach-Object { "$($_.Id)" })
        if (-not $zzIds.Count) { $zzIds = @('none') }
        $zzNowD = Get-Date
        function Time-Op { param([scriptblock]$Do, [int]$Reps)
            $zzB4 = [double]::MaxValue
            for ($zzI = 0; $zzI -lt 5; $zzI++) {
                $zzS9 = [Diagnostics.Stopwatch]::StartNew()
                for ($zzJ = 0; $zzJ -lt $Reps; $zzJ++) { $null = & $Do }
                $zzS9.Stop()
                if ($zzS9.Elapsed.TotalMilliseconds -lt $zzB4) { $zzB4 = $zzS9.Elapsed.TotalMilliseconds }
            }
            return $zzB4 / $Reps
        }
        $zzInline = @()
        $zzInline += @{ N = 'the said-line regex'; Per = (Time-Op {
            $zzX = $script:zzSaids[0]; ("$zzX".Trim() -replace '\s+', ' ') } 400); Times = 1 }
        $zzInline += @{ N = 'screen-sig lookup + TTL'; Per = (Time-Op {
            $zzV5 = $script:rowScreen[$script:zzIds[0]]
            if ($zzV5) { $null = ($script:zzNowD - $zzV5.At).TotalSeconds } } 400); Times = 1 }
        $zzInline += @{ N = 'the ~40-field row object'; Per = (Time-Op {
            $null = [PSCustomObject]@{
                Kind='session'; Id='x'; Row=$null; BandVis=$V_Hide; RowVis=$V_Show; DotVis=$V_Hide
                BandLabel=''; BandCount=''; Accent=$null; QVis=$V_Hide; QText=''; QTip=''; QBrush=$null
                Name='x'; NameWeight='Normal'; NameStyle='Normal'; Age='2h'; Said='x'; BarOpacity=0.85
                CtxVis=$V_Hide; CtxWidth=2.0; CtxBrush=$null; AgentVis=$V_Hide; AgentText=''
                ShellVis=$V_Hide; ShellText=''; SubVis=$V_Hide; SubName=''; SubDesc=''; SubTag=''
                SubAge=''; SubOpacity=1.0; SubTip=''; BandKey=''; BandBg=$null; BandHint=''
                Extra1=''; Extra2=''; Extra3=''; Extra4='' } } 400); Times = 1 }
        $zzInline += @{ N = 'the per-band Where-Object'; Per = (Time-Op {
            $null = @($script:zzKept | Where-Object { $_.Band -eq 'needs' }) } 20); Times = $zzBandsN; PerCall = $true }
        # 🔑 THE SAME CALL, TIMED DIRECTLY, AS A SECOND OPINION ON THE A/B. The
        # remove-and-compare above put Test-SRQueueFresh at 10,8 ms; if calling
        # it 126 times standalone costs about the same, two independent methods
        # agree and the number is worth quoting. If they disagree, neither is.
        $zzQRecs = @($zzKept | ForEach-Object { $_.Q })
        if ($zzQRecs.Count) {
            $script:zzQR = $zzQRecs
            $zzInline += @{ N = 'Test-SRQueueFresh, timed directly'; NoSum = $true; Per = (Time-Op {
                $null = Test-SRQueueFresh -Rec $script:zzQR[0] -Now $script:zzNowD `
                            -MaxHours $SR_QueueStaleHours -MachineMins $SR_QueueMachineStaleMins } 200); Times = 1 }
        }
        # 🔴 AND WHAT A POWERSHELL CALL COSTS WITH NOTHING IN IT. This is the
        # number that decides whether a per-row helper should be inlined: if an
        # EMPTY function costs most of what the real one costs, the body is not
        # the problem and no amount of optimising it will help. It is the same
        # finding the window already recorded for Test-OnSurface - "nearly all
        # of it is per-call overhead; the body it reaches is three property
        # reads" - measured again here rather than quoted.
        function Get-SRAuditNoop { param($A, $B) return $true }
        $zzInline += @{ N = 'an EMPTY function call'; NoSum = $true; Per = (Time-Op {
            $null = Get-SRAuditNoop -A 1 -B 2 } 400); Times = 1 }

        Write-Host ''
        Write-Host ("  {0,-30} {1,12} {2,10}   {3}" -f 'inline work (RECONSTRUCTED)', 'ms each', 'ms total', 'how it scales')
        $zzInlineTotal = 0.0
        foreach ($zzIn in $zzInline) {
            if ($zzIn.PerCall) {
                $zzTot2 = [double]$zzIn.Per * [int]$zzIn.Times
                Write-Host ("  {0,-30} {1,12:N3} {2,10:N1}   once per band over all {3} kept rows" -f $zzIn.N, $zzIn.Per, $zzTot2, $zzRowsN)
            } else {
                $zzTot2 = [double]$zzIn.Per * $zzRowsN
                Write-Host ("  {0,-30} {1,12:N4} {2,10:N1}   {3}" -f $zzIn.N, $zzIn.Per, $zzTot2,
                            $(if ($zzIn.NoSum) { 'CORROBORATION ONLY - not added to the total' } else { "once per row x $zzRowsN" }))
            }
            if (-not $zzIn.NoSum) { $zzInlineTotal += $zzTot2 }
        }

        $zzAttr = 0.0
        foreach ($zzR5 in $zzRows2) { if ($null -ne $zzR5.Ms -and $zzR5.Ms -gt 0) { $zzAttr += $zzR5.Ms } }
        $zzFinal = Time-Build
        Write-Host ''
        Note ("the whole rebuild reads {0:N1} ms for {1} rows ({2:N3} ms per row) in this run" -f $zzFinal, $zzRowsN, ($zzFinal / [Math]::Max(1, $zzRowsN)))
        Note ("removing calls accounted for {0:N1} ms; the reconstructed inline work adds up to {1:N1} ms; residual {2:N1} ms ({3:N0}%)" -f `
              $zzAttr, $zzInlineTotal, ($zzFinal - $zzAttr - $zzInlineTotal),
              (100.0 * ($zzFinal - $zzAttr - $zzInlineTotal) / [Math]::Max(0.001, $zzFinal)))
        Note 'the residual is WPF assigning ItemsSource, the band headings, the List<object> growth, and whatever this section did not think to ask about. It is reported, not explained away.'

        $script:railPick = $null
        Build-Sessions; Settle
        Assert-LiveStill 'the row-cost attribution'
    }
}

# ===========================================================================
# 3. THE TYPING GUARD - EVERY TEXT SURFACE IN THE WINDOW
# ===========================================================================
if (Want 'keys') {
    Head 'the typing guard (window PreviewKeyDown)'
    # --- (a) find every text surface, from the tree, not from a list ----------
    # 🔴 A LIST IS HOW THE GUARD BROKE IN THE FIRST PLACE. It named two boxes and
    # the window had nine. So this does not take the audit's word for how many
    # there are either: it walks the built visual tree and asks each element what
    # it is.
    $zzBoxes = New-Object System.Collections.Generic.List[object]
    function Walk-Text { param($zzEl, [int]$zzD)
        if (-not $zzEl -or $zzD -gt 60) { return }
        if (($zzEl -is [System.Windows.Controls.Primitives.TextBoxBase]) -or
            ($zzEl -is [System.Windows.Controls.PasswordBox])) {
            $null = $script:zzBoxes.Add($zzEl)
        }
        $zzC = 0
        try { $zzC = [System.Windows.Media.VisualTreeHelper]::GetChildrenCount($zzEl) } catch { return }
        for ($zzI = 0; $zzI -lt $zzC; $zzI++) {
            Walk-Text ([System.Windows.Media.VisualTreeHelper]::GetChild($zzEl, $zzI)) ($zzD + 1)
        }
    }
    Lay
    Walk-Text $zzRoot 0
    # The named ones, which is what the operator can actually reach.
    $zzNamedBoxes = @()
    foreach ($zzK in @($ui.Keys)) {
        $zzE2 = $ui[$zzK]
        if (($zzE2 -is [System.Windows.Controls.Primitives.TextBoxBase]) -or
            ($zzE2 -is [System.Windows.Controls.PasswordBox])) { $zzNamedBoxes += $zzK }
    }
    Note ("named text surfaces in the window: {0} - {1}" -f @($zzNamedBoxes).Count, ((@($zzNamedBoxes) | Sort-Object) -join ', '))
    Note ("text surfaces reachable in the laid-out visual tree: {0} (template parts included)" -f $zzBoxes.Count)
    # 🔴 THE GUARD'S OWN PREDICATE, RUN AGAINST EACH REAL CONTROL. This is the
    # half a focus simulation cannot improve on: whatever the window does with
    # focus, the guard decides on the TYPE of the focused element, so every text
    # surface must satisfy the type test or it is unprotected by construction.
    $zzUnguarded = @()
    foreach ($zzK in @($zzNamedBoxes)) {
        $zzE2 = $ui[$zzK]
        $zzIsT = ($zzE2 -is [System.Windows.Controls.Primitives.TextBoxBase]) -or
                 ($zzE2 -is [System.Windows.Controls.PasswordBox])
        if (-not $zzIsT) { $zzUnguarded += $zzK }
    }
    if ($zzUnguarded.Count) {
        Fail ("{0} named text surface(s) satisfy NEITHER half of the guard's type test: {1}" -f $zzUnguarded.Count, ($zzUnguarded -join ', '))
    } else {
        Pass ("all {0} named text surfaces are TextBoxBase or PasswordBox, so the guard's type test covers every one of them" -f @($zzNamedBoxes).Count)
    }
    # 🔑 AND THROUGH THE SHIPPED PREDICATE ITSELF, BOX BY BOX, where the window
    # has one. Re-implementing the type test here would only prove that this
    # file agrees with itself.
    if (Get-Command Test-SRTypingTarget -ErrorAction SilentlyContinue) {
        $zzMissed2 = @()
        foreach ($zzK in @($zzNamedBoxes | Sort-Object)) {
            $zzOk2 = $false
            try { $zzOk2 = [bool](Test-SRTypingTarget $ui[$zzK]) } catch { }
            if (-not $zzOk2) { $zzMissed2 += $zzK }
        }
        # It must also be able to say no, or "yes for all nine" means nothing.
        $zzSaysNo = $true
        try { $zzSaysNo = -not [bool](Test-SRTypingTarget $ui.SessionList) } catch { $zzSaysNo = $false }
        if (-not $zzSaysNo) {
            Fail 'Test-SRTypingTarget returned True for the session LIST - it cannot say no, so its nine Trues are not evidence'
        } elseif ($zzMissed2.Count) {
            Fail ("Test-SRTypingTarget - the shipped predicate - returns False for: {0}. Those boxes are unguarded." -f ($zzMissed2 -join ', '))
        } else {
            Pass ("the shipped predicate Test-SRTypingTarget returns True for all {0} boxes and False for the session list" -f @($zzNamedBoxes).Count)
        }
    } else {
        Note 'this build has no Test-SRTypingTarget function - the guard is still inline, so only the type assertion above applies'
    }

    # --- (b) the matrix, driven through the real delegate --------------------
    # 🔴 KEYBOARD FOCUS NEEDS A PRESENTATIONSOURCE AND THIS WINDOW IS NEVER
    # SHOWN, so Keyboard::FocusedElement cannot be pointed at one of the boxes
    # above. It CAN be pointed at an element of the same TYPE in a hidden source
    # of this driver's own, and the guard reads nothing else about the focused
    # element - it asks what it IS. So the two halves together are the proof:
    # (a) says every real box is one of these types, (b) says the guard refuses
    # every shortcut when the focused element is one of these types.
    #
    # 🪤 AND IT IS CHECKED, NOT ASSUMED. If the focus does not take, the section
    # reports INCONCLUSIVE rather than passing on an unfocused window - which
    # would pass for the wrong reason, since an unfocused window is also the
    # not-typing case.
    $zzKeyFail = 0
    $zzSrc = $null
    try {
        $zzParams = New-Object System.Windows.Interop.HwndSourceParameters('sr-audit-focus')
        $zzParams.Width = 40; $zzParams.Height = 40
        $zzParams.PositionX = -32000; $zzParams.PositionY = -32000
        $zzParams.WindowStyle = 0x00000000
        $zzSrc = New-Object System.Windows.Interop.HwndSource($zzParams)
        $zzHost = New-Object System.Windows.Controls.StackPanel
        $zzSrc.RootVisual = $zzHost
    } catch { $zzSrc = $null }

    function New-KeyArgs { param([string]$K)
        $zzKk = [System.Windows.Input.Key]$K
        $zzA = New-Object System.Windows.Input.KeyEventArgs(
            [System.Windows.Input.Keyboard]::PrimaryDevice,
            [System.Windows.PresentationSource]::FromVisual($zzHost),
            0, $zzKk)
        $zzA.RoutedEvent = [System.Windows.Input.Keyboard]::PreviewKeyDownEvent
        return $zzA
    }
    # The delegate the window actually registered, pulled off the object rather
    # than re-created from the source.
    $zzPkd = @()
    try {
        $zzStoreP = [System.Windows.UIElement].GetProperty('EventHandlersStore',
                        [System.Reflection.BindingFlags]::NonPublic -bor [System.Reflection.BindingFlags]::Instance)
        $zzStore = $zzStoreP.GetValue($window, $null)
        $zzHs2 = $zzStore.GetRoutedEventHandlers([System.Windows.Input.Keyboard]::PreviewKeyDownEvent)
        foreach ($zzHh in @($zzHs2)) { $zzPkd += $zzHh.Handler }
    } catch { }
    if (-not $zzPkd.Count) {
        Inconclusive 'could not read the window''s PreviewKeyDown handlers off the object - the key matrix did not run'
    } elseif (-not $zzSrc) {
        # A KeyEventArgs needs a real PresentationSource. Without one the matrix
        # cannot be driven at all - in EITHER direction - so it is reported as
        # not run rather than as passing.
        Inconclusive 'no hidden HwndSource could be created, so no KeyEventArgs could be built. THE WHOLE KEY MATRIX DID NOT RUN.'
    } else {
        Note ("{0} PreviewKeyDown handler(s) are registered on the window; all of them are driven below" -f $zzPkd.Count)
        # The bare-letter shortcuts, and what proves each one fired.
        $zzShort = @(
            @{ K = 'L';      What = 'load earlier (doubles the tail budget)'; Probe = { $script:tailBytes } }
            @{ K = 'Oem2';   What = '/ focuses the header search';            Probe = { 'n/a' } }
            @{ K = 'Escape'; What = 'escape leaves the box / the list';       Probe = { 'n/a' } }
        )
        # On the manage surface there are three more.
        $zzShortMgr = @(
            @{ K = 'O';     What = 'O toggles showOlder';   Probe = { $script:showOlder } }
            @{ K = 'Space'; What = 'space ticks a row';     Probe = { 'n/a' } }
        )

        function Fire-Key { param([string]$K)
            $zzA = New-KeyArgs $K
            foreach ($zzHh in $zzPkd) { $null = $zzHh.Invoke($window, $zzA) }
            return $zzA
        }

        # --- NOT typing: every shortcut must still work ----------------------
        # This is the half a guard like this most easily breaks, and it is
        # checked FIRST so a guard that swallowed everything cannot pass by
        # simply never firing.
        $null = $ui.SessionList.Focus()
        $zzTailWas = $script:tailBytes
        $zzA1 = Fire-Key 'L'
        if (-not $zzA1.Handled) { Fail 'with focus outside a text box, L was NOT handled - the load-earlier shortcut is dead'; $zzKeyFail++ }
        elseif ($script:tailBytes -ne ($zzTailWas * 2)) { Fail ('L was handled but the tail budget did not double ({0} -> {1})' -f $zzTailWas, $script:tailBytes); $zzKeyFail++ }
        else { Pass ('not typing: L still fires - the tail budget went {0:N0} -> {1:N0}' -f $zzTailWas, $script:tailBytes) }
        $script:tailBytes = $zzTailWas
        Update-Document -Wait

        $zzOldWas = $script:showOlder
        $script:surface = 'manage'
        $zzA2 = Fire-Key 'O'
        $script:surface = 'work'
        if (-not $zzA2.Handled) { Fail 'on the manage surface with focus outside a text box, O was NOT handled - the show-older shortcut is dead'; $zzKeyFail++ }
        elseif ($script:showOlder -eq $zzOldWas) { Fail 'O was handled but showOlder did not move'; $zzKeyFail++ }
        else { Pass ('not typing: O still toggles showOlder ({0} -> {1})' -f $zzOldWas, $script:showOlder) }
        $script:showOlder = $zzOldWas
        Build-Manager

        $zzA3 = Fire-Key 'Oem2'
        if (-not $zzA3.Handled) { Fail 'with focus outside a text box, / was NOT handled - the focus-the-search shortcut is dead'; $zzKeyFail++ }
        else { Pass 'not typing: / is still handled' }

        # --- typing: nothing may be handled ----------------------------------
        if (-not $zzSrc) {
            Inconclusive 'no hidden HwndSource could be created, so keyboard focus could not be pointed at a text surface. THE TYPING HALF OF THIS MATRIX DID NOT RUN - it is not reported as passing.'
        } else {
            # One proxy per DISTINCT runtime type found among the real boxes, so
            # the matrix covers exactly the types the window actually has.
            $zzTypes = @{}
            foreach ($zzK in @($zzNamedBoxes)) { $zzTypes[$ui[$zzK].GetType().FullName] = $zzK }
            Note ("distinct text-surface types in this window: {0}" -f ((@($zzTypes.Keys) | Sort-Object) -join ', '))
            # 🔴 EXERCISE THE ARM NO REAL CONTROL REACHES. Every box in this
            # window is a plain TextBox, so the PasswordBox half of the guard is
            # never touched by anything on screen - which is precisely the half
            # that would rot unnoticed until somebody adds one. It is added to
            # the matrix on purpose.
            $zzTypes['System.Windows.Controls.PasswordBox'] = '(no real control has this type - the guard arm is tested anyway)'
            # And the CONTROL for the whole matrix: focus on something that is
            # NOT a text surface must let every shortcut through. Without this
            # the typing rows could pass because the keys never fire at all.
            $zzTypes['System.Windows.Controls.Button'] = '(the control - shortcuts MUST fire here)'
            foreach ($zzTn in @($zzTypes.Keys | Sort-Object)) {
                $zzProxy = $null
                try {
                    $zzProxy = [Activator]::CreateInstance([type]$zzTn)
                    $zzHost.Children.Clear()
                    $null = $zzHost.Children.Add($zzProxy)
                    $zzHost.Measure((New-Object System.Windows.Size 40, 40))
                    $zzHost.Arrange((New-Object System.Windows.Rect 0, 0, 40, 40))
                    $zzHost.UpdateLayout()
                    $null = $zzProxy.Focus()
                } catch { $zzProxy = $null }
                $zzFe = [System.Windows.Input.Keyboard]::FocusedElement
                if (-not $zzProxy -or -not [object]::ReferenceEquals($zzFe, $zzProxy)) {
                    Inconclusive ("keyboard focus would not settle on a {0} in the hidden source (FocusedElement is {1}) - the typing half did not run for that type" -f `
                                  (Split-Path -Leaf ($zzTn -replace '\.', '\')), $(if ($zzFe) { $zzFe.GetType().Name } else { 'null' }))
                    continue
                }
                # 🔴 SHOW THE GUARD'S OWN INPUTS BEFORE FIRING. When this
                # matrix first went red it was impossible to tell a real defect
                # from a harness that had not actually moved the focus, and the
                # difference is the whole finding. So the three things the guard
                # reads are printed, and the predicate is evaluated here as
                # well - if the predicate is TRUE out here and the shortcut
                # fires anyway, the defect is in the handler; if it is FALSE,
                # the focus did not take and this is INCONCLUSIVE, not a defect.
                $zzFe2 = [System.Windows.Input.Keyboard]::FocusedElement
                $zzPred = $false
                try {
                    if (Get-Command Test-SRTypingTarget -ErrorAction SilentlyContinue) { $zzPred = [bool](Test-SRTypingTarget $zzFe2) }
                    else { $zzPred = ($zzFe2 -is [System.Windows.Controls.Primitives.TextBoxBase]) -or ($zzFe2 -is [System.Windows.Controls.PasswordBox]) }
                } catch { }
                Note ("FocusedElement={0}; the guard's own predicate says typing={1}; Search.IsKeyboardFocusWithin={2}; SendBox.IsKeyboardFocusWithin={3}" -f `
                      $(if ($zzFe2) { $zzFe2.GetType().Name } else { 'null' }), $zzPred,
                      $ui.Search.IsKeyboardFocusWithin, $ui.SendBox.IsKeyboardFocusWithin)
                $zzBad = @()
                $zzTailWas2 = $script:tailBytes
                $zzOldWas2 = $script:showOlder
                foreach ($zzKk in @('L', 'O', 'Oem2', 'Space')) {
                    if ($zzKk -eq 'O' -or $zzKk -eq 'Space') { $script:surface = 'manage' } else { $script:surface = 'work' }
                    $zzAa = Fire-Key $zzKk
                    if ($zzAa.Handled) { $zzBad += $zzKk }
                }
                $script:surface = 'work'
                if ($script:tailBytes -ne $zzTailWas2) { $zzBad += ('L changed the tail budget to {0}' -f $script:tailBytes); $script:tailBytes = $zzTailWas2 }
                if ($script:showOlder -ne $zzOldWas2) { $zzBad += 'O toggled showOlder'; $script:showOlder = $zzOldWas2 }
                # The Button row is the control and reads the opposite way.
                if ($zzTn -eq 'System.Windows.Controls.Button') {
                    if (-not $zzBad.Count) {
                        Fail 'with focus on a BUTTON - not a text surface at all - none of the bare-letter shortcuts fired. The typing rows above would pass for the wrong reason, because the keys are not reaching the handler at all.'
                        $zzKeyFail++
                    } else {
                        Pass ("control: with focus on a Button the shortcuts DO fire ({0}) - so a quiet typing row above means the guard, not a dead key path" -f ($zzBad -join ', '))
                    }
                    continue
                }
                if ($zzBad.Count -and -not $zzPred) {
                    Inconclusive ("with a {0} focused the guard's own predicate still says NOT typing, so the focus did not really move - {1} reached the shortcut handler, and that is a harness limitation rather than a defect in the guard" -f `
                                  (($zzTn -split '\.')[-1]), ($zzBad -join ', '))
                } elseif ($zzBad.Count) {
                    Fail ("with focus on a {0} AND the guard's own predicate returning typing=True, these still reached the shortcut handler: {1}" -f (($zzTn -split '\.')[-1]), ($zzBad -join ', '))
                    $zzKeyFail++
                } else {
                    Pass ("with focus on a {0}, none of L / O / / / space was handled - every one of them reaches the box" -f (($zzTn -split '\.')[-1]))
                }
                # Escape IS wanted while typing, and must still be handled.
                $script:surface = 'work'
                $zzEa = Fire-Key 'Escape'
                if (-not $zzEa.Handled) {
                    Fail ("with focus on a {0}, Escape was not handled - the one shortcut a text field does want is gone" -f (($zzTn -split '\.')[-1]))
                    $zzKeyFail++
                } else {
                    Pass ("with focus on a {0}, Escape is still handled" -f (($zzTn -split '\.')[-1]))
                }
            }
        }
        try { if ($zzSrc) { $zzSrc.Dispose() } } catch { }
    }
    Build-Rail; Build-Sessions; Lay
    Assert-LiveStill 'the typing guard matrix'
}

# ===========================================================================
# 4. THE QUEUE STALENESS GATE
# ===========================================================================
if (Want 'queue') {
    Head 'the queue staleness gate (does a mark vanish, and does "cannot tell" still draw)'
    # 🔴 ASSERTED ON THE BUILT ROW, NOT ON THE PREDICATE. The gate is eight lines
    # inside Build-Sessions and has no function to call, so the only honest test
    # is to put a crafted queue record on a real model row, rebuild the list, and
    # read QVis off the item the list actually built.
    # 🔴 A ROW THE LIST ACTUALLY BUILDS, NOT JUST ONE THE MODEL HOLDS. With no
    # project picked Build-Sessions keeps only what is live, warm or selected -
    # so hanging the probe on an arbitrary model row produced ROW MISSING for
    # every case, and the "a stale mark vanishes" assertion PASSED on it,
    # because a row that is not there also does not draw a mark. That is a
    # green for the wrong reason, on the exact test the section exists for.
    Build-Sessions
    $zzListed = @($ui.SessionList.Items | Where-Object { "$($_.Kind)" -eq 'session' -and $_.Row })
    $zzRow = $(if ($zzListed.Count) { $zzListed[0].Row } else { $null })
    if (-not $zzRow) {
        Inconclusive 'the sessions list built no rows - the gate was not tested'
    } else {
        $zzQWas = $zzRow.Q
        $zzHadQ = $zzRow.PSObject.Properties['Q'] -ne $null
        function Set-Q { param($zzV)
            if ($script:zzHadQ) { $script:zzRow.Q = $zzV }
            else { $script:zzRow | Add-Member -NotePropertyName Q -NotePropertyValue $zzV -Force }
        }
        # 🔴 IT CATCHES, BECAUSE Build-Sessions CAN THROW ON A QUEUE RECORD AND
        # THAT IS ITSELF A FINDING. An unhandled exception here killed the whole
        # section on its fourth case; swallowing it silently would have hidden
        # the defect, and letting it escape hides every case after it.
        function Get-QVis {
            try { Build-Sessions }
            catch { return ('THREW: ' + $_.Exception.Message) }
            $zzIt = @($ui.SessionList.Items | Where-Object { "$($_.Kind)" -eq 'session' -and "$($_.Id)" -eq "$($script:zzRow.Id)" })
            if (-not $zzIt.Count) { return 'ROW MISSING' }
            return "$($zzIt[0].QVis)"
        }
        function New-Q { param([int]$Count, [int]$Mine, $Items)
            return [PSCustomObject]@{ Items = $Items; Count = $Count; Mine = $Mine; Machine = ($Count - $Mine); Ok = $true; LastWrite = (Get-Date) }
        }
        $zzNow = Get-Date
        Note ("SR_QueueStaleHours = {0}" -f $SR_QueueStaleHours)

        # --- the gate as a function, where the window now has one -------------
        # 🔑 CHEAPER AND STRICTER THAN THE ROW TEST, and it reaches cases the
        # row test cannot: Build-Sessions throws on one of them (see below), and
        # a throw hides every assertion after it.
        if (Get-Command Test-SRQueueFresh -ErrorAction SilentlyContinue) {
            function Q-Item { param($At, [bool]$Mine = $true)
                return [PSCustomObject]@{ Text = 'x'; First = 'x'; At = $At; Mine = $Mine }
            }
            $zzN0 = Get-Date
            $zzUnit = @(
                @{ N = 'no record at all';               R = $null;                                          Want = $true }
                @{ N = 'a record with an empty Items';   R = (New-Q 3 1 @());                                Want = $true }
                @{ N = 'a record with a null Items';     R = (New-Q 3 1 $null);                              Want = $true }
                @{ N = 'one item, one second old';       R = (New-Q 1 1 @((Q-Item $zzN0)));                   Want = $true }
                @{ N = 'one item, 61 minutes old';       R = (New-Q 1 1 @((Q-Item $zzN0.AddMinutes(-61))));   Want = $false }
                @{ N = 'one item, 59 minutes old';       R = (New-Q 1 1 @((Q-Item $zzN0.AddMinutes(-59))));   Want = $true }
                @{ N = 'one item with a null date';      R = (New-Q 1 1 @((Q-Item $null)));                   Want = $true }
                @{ N = 'one item with an empty date';    R = (New-Q 1 1 @((Q-Item '')));                      Want = $true }
                @{ N = 'one item with a bad date';       R = (New-Q 1 1 @((Q-Item 'not a date')));            Want = $true }
                @{ N = 'one item dated MinValue';        R = (New-Q 1 1 @((Q-Item ([datetime]::MinValue))));  Want = $true }
                @{ N = 'ancient + undated';              R = (New-Q 2 2 @((Q-Item $zzN0.AddHours(-99)), (Q-Item $null))); Want = $true }
                @{ N = 'ancient + fresh';                R = (New-Q 2 2 @((Q-Item $zzN0.AddHours(-99)), (Q-Item $zzN0))); Want = $true }
                @{ N = 'two ancient';                    R = (New-Q 2 2 @((Q-Item $zzN0.AddHours(-99)), (Q-Item $zzN0.AddHours(-2)))); Want = $false }
                @{ N = 'a date in the FUTURE';           R = (New-Q 1 1 @((Q-Item $zzN0.AddHours(3))));       Want = $true }
            )
            # 🔴 THE TWO-CLOCK CASES, WHICH ARE THE WHOLE POINT OF -MachineMins.
            # Machine traffic is stale in minutes, his own messages keep the
            # hour, and a gate that only ever ran with one clock has never been
            # asked the question the second clock exists for.
            $zzHasMM = $false
            try { $zzHasMM = @((Get-Command Test-SRQueueFresh).Parameters.Keys) -contains 'MachineMins' } catch { }
            if ($zzHasMM) {
                $zzUnit += @(
                    @{ N = 'MACHINE item 90 seconds old';  R = (New-Q 1 0 @((Q-Item $zzN0.AddSeconds(-90) $false)));  Want = $true;  MM = $true }
                    @{ N = 'MACHINE item 3 minutes old';   R = (New-Q 1 0 @((Q-Item $zzN0.AddMinutes(-3) $false)));   Want = $false; MM = $true }
                    @{ N = 'MINE 30 minutes old';          R = (New-Q 1 1 @((Q-Item $zzN0.AddMinutes(-30) $true)));   Want = $true;  MM = $true }
                    @{ N = 'MINE 90 minutes old';          R = (New-Q 1 1 @((Q-Item $zzN0.AddMinutes(-90) $true)));   Want = $false; MM = $true }
                    @{ N = 'stale MACHINE + fresh MINE';   R = (New-Q 2 1 @((Q-Item $zzN0.AddMinutes(-9) $false), (Q-Item $zzN0.AddMinutes(-5) $true))); Want = $true; MM = $true }
                    @{ N = 'stale MACHINE + stale MINE';   R = (New-Q 2 1 @((Q-Item $zzN0.AddMinutes(-9) $false), (Q-Item $zzN0.AddMinutes(-90) $true))); Want = $false; MM = $true }
                    # 🪤 THE CASE THE TWO-CLOCK CHANGE MAKES POSSIBLE AND
                    # NOBODY WOULD THINK TO ASK FOR: a message of HIS, 40
                    # minutes old and still inside its hour, sitting behind
                    # machine traffic that went stale 38 minutes ago. The old
                    # single clock kept the mark. Does the new one?
                    @{ N = 'stale MACHINE + MINE at 40 min'; R = (New-Q 2 1 @((Q-Item $zzN0.AddMinutes(-40) $false), (Q-Item $zzN0.AddMinutes(-40) $true))); Want = $true; MM = $true }
                )
                Note ("SR_QueueMachineStaleMins = {0}; the two-clock cases below pass -MachineMins exactly as the row mark and the panel do" -f $SR_QueueMachineStaleMins)
            } else {
                Note 'this build of Test-SRQueueFresh has no -MachineMins parameter - the two-clock cases did not run'
            }
            $zzUnitBad = 0
            foreach ($zzUu in $zzUnit) {
                $zzGot2 = $null
                try {
                    if ($zzUu.MM) {
                        $zzGot2 = [bool](Test-SRQueueFresh -Rec $zzUu.R -Now $zzN0 -MaxHours $SR_QueueStaleHours -MachineMins $SR_QueueMachineStaleMins)
                    } else {
                        $zzGot2 = [bool](Test-SRQueueFresh -Rec $zzUu.R -Now $zzN0 -MaxHours $SR_QueueStaleHours)
                    }
                }
                catch { Fail ("Test-SRQueueFresh THREW on '{0}': {1}" -f $zzUu.N, $_.Exception.Message); $zzUnitBad++; continue }
                if ($zzGot2 -ne $zzUu.Want) {
                    Fail ("Test-SRQueueFresh('{0}') = {1}, expected {2}{3}" -f $zzUu.N, $zzGot2, $zzUu.Want,
                          $(if ($zzUu.Want) { ' - could-not-tell must never mean hide-it' } else { ' - a stale mark must vanish' }))
                    $zzUnitBad++
                }
            }
            if (-not $zzUnitBad) { Pass ("Test-SRQueueFresh answered all {0} cases correctly, including both directions" -f $zzUnit.Count) }
        } else {
            Note 'this build has no Test-SRQueueFresh - the gate is still inline, so only the built-row assertions below apply'
        }

        # --- calibration: the gate must be able to show AND hide --------------
        Set-Q (New-Q 1 1 @([PSCustomObject]@{ Text = 'x'; First = 'x'; At = $zzNow; Mine = $true }))
        $zzFresh = Get-QVis
        Set-Q (New-Q 1 1 @([PSCustomObject]@{ Text = 'x'; First = 'x'; At = $zzNow.AddHours(-72); Mine = $true }))
        $zzStale = Get-QVis
        if ($zzFresh -ne 'Visible') {
            Fail ("a queue mark one second old did not draw (QVis={0}) - the gate is not measurable, so the rest of this section is NOT run rather than run and reported" -f $zzFresh)
            Set-Q $zzQWas
            Build-Sessions
            $script:zzQueueDead = $true
        } elseif ($zzStale -eq 'Visible') {
            Fail 'a queue mark 72 hours old STILL DRAWS - the staleness gate does not fire at all'
        } else {
            Pass ("calibrated: a one-second-old mark draws ({0}) and a 72-hour-old mark does not ({1}) - the gate moves in both directions" -f $zzFresh, $zzStale)
        }

        if (-not $script:zzQueueDead) {
        # --- the case the OLD gate could never reach -------------------------
        # The first version aged the transcript file, so a live session - which
        # writes constantly - could never trip it. This is that exact case: an
        # ancient ITEM on a row whose file was written a moment ago.
        Set-Q (New-Q 1 1 @([PSCustomObject]@{ Text = 'x'; First = 'x'; At = $zzNow.AddHours(-6); Mine = $true }))
        $zzLiveStale = Get-QVis
        if ($zzLiveStale -eq 'Visible') {
            Fail 'a six-hour-old message on a LIVE conversation still shows a queue mark - the gate is still measuring the file, not the message'
        } else {
            Pass 'a six-hour-old message on a live, actively-written conversation no longer shows a mark'
        }

        # --- "could not tell" must NEVER mean "hide it" ----------------------
        $zzUndated = @(
            @{ N = 'items with a null At';        Q = (New-Q 1 1 @([PSCustomObject]@{ Text = 'x'; First = 'x'; At = $null; Mine = $true })) }
            @{ N = 'items with an empty-string At'; Q = (New-Q 1 1 @([PSCustomObject]@{ Text = 'x'; First = 'x'; At = ''; Mine = $true })) }
            @{ N = 'items with an UNPARSEABLE At'; Q = (New-Q 1 1 @([PSCustomObject]@{ Text = 'x'; First = 'x'; At = 'not a date'; Mine = $true })) }
            @{ N = 'a count with NO items at all'; Q = (New-Q 3 2 @()) }
            @{ N = 'a count with a null Items';     Q = (New-Q 3 2 $null) }
            @{ N = 'one ancient item, one undated'; Q = (New-Q 2 2 @(
                    [PSCustomObject]@{ Text = 'old'; First = 'old'; At = $zzNow.AddHours(-99); Mine = $true },
                    [PSCustomObject]@{ Text = 'new'; First = 'new'; At = $null; Mine = $true })) }
        )
        foreach ($zzU in $zzUndated) {
            Set-Q $zzU.Q
            $zzV = Get-QVis
            if ($zzV.StartsWith('THREW', [StringComparison]::Ordinal)) {
                Fail ("{0}: Build-Sessions THREW. The whole sessions column fails to build, not just the mark. {1}" -f $zzU.N, $zzV)
            } elseif ($zzV -ne 'Visible') {
                Fail ("{0}: the mark was HIDDEN (QVis={1}). Could-not-tell became hide-it, which is the failure this gate was written to avoid." -f $zzU.N, $zzV)
            } else {
                Pass ("{0}: still drawn" -f $zzU.N)
            }
        }
        # 🪤 THE MIXED CASE IS DELIBERATELY LAST AND IT IS A JUDGEMENT, NOT A
        # BUG: one ancient item plus one undated item draws, because the undated
        # one is not evidence of age. One ancient plus one FRESH also draws. One
        # ancient alone does not.
        Set-Q (New-Q 2 2 @(
            [PSCustomObject]@{ Text = 'old'; First = 'old'; At = $zzNow.AddHours(-99); Mine = $true },
            [PSCustomObject]@{ Text = 'new'; First = 'new'; At = $zzNow; Mine = $true }))
        if ((Get-QVis) -ne 'Visible') { Fail 'one ancient item plus one fresh item hid the mark - any item still young must keep the whole mark' }
        else { Pass 'one ancient item plus one fresh item keeps the mark' }
        }

        # --- THE PANEL ABOVE THE COMPOSER, which had no gate at all ----------
        # 🔴 THE ROW MARK AND THE PANEL ARE TWO SURFACES AND ONLY ONE OF THEM
        # WAS EVER TESTED. The panel is the one on screen while he types, so a
        # phantom there is the one he cannot miss - which is exactly where the
        # screenshot came from. It is asserted on the built control, not on the
        # predicate the control is supposed to call.
        if ($ui.QueueBox -and (Get-Command Update-QueuePanel -ErrorAction SilentlyContinue)) {
            $zzSelIt = @($ui.SessionList.Items | Where-Object { "$($_.Kind)" -eq 'session' -and "$($_.Id)" -eq "$($script:zzRow.Id)" })
            if (-not $zzSelIt.Count) {
                Inconclusive 'the probe row is not in the list - the panel could not be tested'
            } else {
                $ui.SessionList.SelectedItem = $zzSelIt[0]
                function Get-PanelVis {
                    # 🪤 THE SIGNATURE CACHE HAS TO BE BROKEN OR THE PANEL
                    # SIMPLY RETURNS. It skips the rebuild when the signature is
                    # unchanged, so a test that does not invalidate it measures
                    # whatever the previous case left on screen - a harness
                    # reading its own last answer back.
                    $script:qSig = 'audit-forced-rebuild'
                    try { Update-QueuePanel } catch { return ('THREW: ' + $_.Exception.Message) }
                    return "$($ui.QueueBox.Visibility)"
                }
                $zzPanel = @(
                    @{ N = 'a message of yours, one second old'; Q = (New-Q 1 1 @([PSCustomObject]@{ Text='x'; First='x'; At=$zzNow; Mine=$true })); Want = 'Visible' }
                    @{ N = 'a message of yours, 90 minutes old'; Q = (New-Q 1 1 @([PSCustomObject]@{ Text='x'; First='x'; At=$zzNow.AddMinutes(-90); Mine=$true })); Want = 'Collapsed' }
                    @{ N = 'machine traffic, 30 seconds old';    Q = (New-Q 1 0 @([PSCustomObject]@{ Text='x'; First='x'; At=$zzNow.AddSeconds(-30); Mine=$false })); Want = 'Visible' }
                    @{ N = 'machine traffic, 5 minutes old';     Q = (New-Q 1 0 @([PSCustomObject]@{ Text='x'; First='x'; At=$zzNow.AddMinutes(-5); Mine=$false })); Want = 'Collapsed' }
                    @{ N = 'an item with no date at all';        Q = (New-Q 1 1 @([PSCustomObject]@{ Text='x'; First='x'; At=$null; Mine=$true })); Want = 'Visible' }
                    @{ N = 'a count with no items';              Q = (New-Q 2 1 @());  Want = 'Visible' }
                    @{ N = 'no queue record at all';             Q = $null;            Want = 'Collapsed' }
                )
                $zzPanelBad = 0
                foreach ($zzPp in $zzPanel) {
                    Set-Q $zzPp.Q
                    $zzGotV = Get-PanelVis
                    if ($zzGotV -ne $zzPp.Want) {
                        Fail ("the queue PANEL, '{0}': Visibility={1}, expected {2}" -f $zzPp.N, $zzGotV, $zzPp.Want)
                        $zzPanelBad++
                    }
                }
                if (-not $zzPanelBad) {
                    Pass ("the queue panel answered all {0} cases correctly - it hides stale traffic on both clocks and still draws when it cannot tell" -f $zzPanel.Count)
                }
            }
        } else {
            Note 'no QueueBox or no Update-QueuePanel in this build - the panel was not tested'
        }

        Set-Q $zzQWas
        Build-Sessions; Lay
    }
    Assert-LiveStill 'the queue gate'
}

# ===========================================================================
# 5. THE CONTROL TABLE - WHAT CARRIES A HANDLER, AND WHAT WAS NEVER PRESSED
# ===========================================================================
if (Want 'table') {
    Head 'every control that carries a handler'
    $zzEvents = @([System.Windows.EventManager]::GetRoutedEvents())
    $zzStoreProp = [System.Windows.UIElement].GetProperty('EventHandlersStore',
                       [System.Reflection.BindingFlags]::NonPublic -bor [System.Reflection.BindingFlags]::Instance)
    function Get-Handlers { param($zzEl)
        $zzOut = @()
        if (-not $zzEl -or $zzEl -isnot [System.Windows.UIElement]) { return $zzOut }
        $zzSt = $null
        try { $zzSt = $script:zzStoreProp.GetValue($zzEl, $null) } catch { return $zzOut }
        if (-not $zzSt) { return $zzOut }
        foreach ($zzRe in $script:zzEvents) {
            $zzHh = $null
            try { $zzHh = $zzSt.GetRoutedEventHandlers($zzRe) } catch { continue }
            if ($zzHh -and @($zzHh).Count) { $zzOut += ('{0}.{1} x{2}' -f $zzRe.OwnerType.Name, $zzRe.Name, @($zzHh).Count) }
        }
        return $zzOut
    }
    # 🔴 THE HANDLER'S OWN SOURCE, RECOVERED FROM THE COMPILED DELEGATE - not
    # grepped out of the file. A source grep has already been caught giving a
    # false pass in this repo: it finds text that may not be the delegate the
    # object is actually carrying. PowerShell compiles an Add_X { ... } into a
    # delegate whose Target holds the ScriptBlock in its Constants, so the text
    # below is the code that will really run when the control is pressed.
    # 🪤 IT RETURNS '' WHEN IT CANNOT FIND THE SCRIPTBLOCK, AND THE FIRST
    # VERSION DID NOT. It fell back to '[compiled] <method name>' - a non-empty
    # string - which then sailed through the danger scan and reported all 64
    # controls as safe to press. A recovery function that answers "I could not
    # read it" with something that looks like an answer turns the one check
    # standing between this audit and a killed conversation into a rubber stamp.
    $zzBind = [System.Reflection.BindingFlags]::Public -bor
              [System.Reflection.BindingFlags]::NonPublic -bor
              [System.Reflection.BindingFlags]::Instance
    function Find-SB { param($zzObj, [int]$zzD)
        if ($null -eq $zzObj -or $zzD -gt 3) { return '' }
        if ($zzObj -is [scriptblock]) { return "$zzObj" }
        if ($zzObj -is [string] -or $zzObj -is [ValueType]) { return '' }
        if ($zzObj -is [System.Collections.IEnumerable]) {
            foreach ($zzIt in $zzObj) {
                $zzR4 = Find-SB $zzIt ($zzD + 1)
                if ($zzR4) { return $zzR4 }
            }
            return ''
        }
        $zzTy = $null
        try { $zzTy = $zzObj.GetType() } catch { return '' }
        foreach ($zzFi in @($zzTy.GetFields($script:zzBind))) {
            $zzV2 = $null
            try { $zzV2 = $zzFi.GetValue($zzObj) } catch { continue }
            $zzR4 = Find-SB $zzV2 ($zzD + 1)
            if ($zzR4) { return $zzR4 }
        }
        foreach ($zzPn in @('Constants', 'ScriptBlock', 'Target')) {
            $zzPi = $null
            try { $zzPi = $zzTy.GetProperty($zzPn, $script:zzBind) } catch { }
            if (-not $zzPi) { continue }
            $zzV2 = $null
            try { $zzV2 = $zzPi.GetValue($zzObj, $null) } catch { continue }
            $zzR4 = Find-SB $zzV2 ($zzD + 1)
            if ($zzR4) { return $zzR4 }
        }
        return ''
    }
    function Get-HandlerSource { param($zzDel)
        $zzT = $null
        try { $zzT = $zzDel.Target } catch { return '' }
        if (-not $zzT) { return '' }
        return (Find-SB $zzT 0)
    }
    function Get-HandlerDelegates { param($zzEl)
        $zzOut = @()
        $zzSt = $null
        try { $zzSt = $script:zzStoreProp.GetValue($zzEl, $null) } catch { return $zzOut }
        if (-not $zzSt) { return $zzOut }
        foreach ($zzRe in $script:zzEvents) {
            $zzHh = $null
            try { $zzHh = $zzSt.GetRoutedEventHandlers($zzRe) } catch { continue }
            foreach ($zzH2 in @($zzHh)) {
                if ($zzH2) { $zzOut += [PSCustomObject]@{ Event = $zzRe.Name; Del = $zzH2.Handler } }
            }
        }
        return $zzOut
    }

    # 🔴 CALIBRATE THE RECOVERY BEFORE TRUSTING ONE VERDICT FROM IT. A handler
    # with a phrase in it that exists nowhere else, registered the same way the
    # window registers its own, and read back off the object.
    $zzProbeBtn = New-Object System.Windows.Controls.Button
    $zzProbeBtn.Add_Click({ $zzUnmistakableCanaryPhrase = 'Start-Process nothing' })
    $zzProbeDs = Get-HandlerDelegates $zzProbeBtn
    $zzProbeSrc = ''
    if (@($zzProbeDs).Count) { $zzProbeSrc = Get-HandlerSource $zzProbeDs[0].Del }
    if ($zzProbeSrc.IndexOf('zzUnmistakableCanaryPhrase', [StringComparison]::Ordinal) -lt 0) {
        Fail ('the handler-source recovery could not read back a handler this driver just registered (got {0} char(s)). Every verdict below would be "could not read the handler", so nothing is pressed.' -f $zzProbeSrc.Length)
        $script:zzRecoveryOk = $false
    } else {
        Pass 'handler-source recovery calibrated: a handler registered here reads back with its own text'
        $script:zzRecoveryOk = $true
    }
    # And it must say NOTHING rather than something when there is no scriptblock.
    $zzNullSrc = Get-HandlerSource ([System.Windows.RoutedEventHandler]{ })
    Note ('(a handler with no recoverable body returns {0} character(s), which is what routes a control to "could not read the handler")' -f $zzNullSrc.Length)

    # WHAT MAKES A CONTROL UNPRESSABLE, in the two categories the report needs.
    # 🪤 THE TEST IS THE HANDLER'S SOURCE, AND IT IS DELIBERATELY BLUNT. A
    # control whose handler merely MENTIONS one of these is left alone. An audit
    # that presses something because a clever test decided the dangerous branch
    # was unreachable is one bad inference away from killing a conversation the
    # operator cannot get back.
    $zzSpawns = @('Start-Process', 'Start-Job', 'wt.exe', 'cmd.exe', 'powershell.exe',
                  'Start-LiveProbe', 'Start-SRScreenServer', 'Get-SRScreenText', 'Invoke-SRScreen',
                  'Open-SRSession', 'Restore-', 'Launch', 'Relaunch', 'Update-Model', 'Start-VitalsSweep')
    $zzWrites = @('Save-SRRegistry', 'Update-SRRegistry', 'Save-SRConfigWrites', 'Set-ProjectShelved',
                  'Stop-Process', 'Send-', 'Submit-', 'Type-', 'Remove-Item', 'Move-Item',
                  'Set-Content', 'Out-File', 'Confirm-Action', 'Show-Sheet', 'Show-Spawn',
                  'ShowDialog', '.Close()', 'WindowState', 'DragMove', 'Stop-SRSession', 'Kill')

    # 🔴 THE SCAN FOLLOWS THE CALLS, BECAUSE ONE LEVEL OF INDIRECTION DEFEATED
    # THE FIRST VERSION COMPLETELY.
    #
    # Scanning only the handler's own text put SaveBtn, SendBtn, AskFreeSend,
    # PaneStop and Broadcast in the PRESSABLE column - the save button, three
    # controls that type into live consoles, and the one that stops a session.
    # None of them names a dangerous call directly; each hands off to a function
    # that does. A safety check that a one-line helper can walk straight past is
    # not a safety check.
    #
    # So the handler's text is scanned, then the body of every FUNCTION IT
    # CALLS, to depth 3, deduplicated. Comments count as matches, deliberately:
    # a false "unsafe" costs one unpressed control and a line in the report,
    # and a false "safe" costs the operator a conversation.
    $zzFnNames = @{}
    foreach ($zzF2 in @(Get-ChildItem function: -ErrorAction SilentlyContinue)) {
        $zzFnNames[$zzF2.Name.ToLower()] = $zzF2.Name
    }
    function Scan-Deep { param([string]$Src)
        $zzSeen = @{}
        $zzHitW = @{}; $zzHitS = @{}
        $zzQ = New-Object System.Collections.Generic.Queue[object]
        $zzQ.Enqueue([PSCustomObject]@{ S = $Src; D = 0 })
        while ($zzQ.Count -gt 0 -and $zzSeen.Count -lt 300) {
            $zzCur = $zzQ.Dequeue()
            $zzS7 = "$($zzCur.S)"
            if (-not $zzS7) { continue }
            foreach ($zzW in $script:zzWrites) { if ($zzS7.IndexOf($zzW, [StringComparison]::OrdinalIgnoreCase) -ge 0) { $zzHitW[$zzW] = $true } }
            foreach ($zzW in $script:zzSpawns) { if ($zzS7.IndexOf($zzW, [StringComparison]::OrdinalIgnoreCase) -ge 0) { $zzHitS[$zzW] = $true } }
            if ($zzCur.D -ge 3) { continue }
            foreach ($zzM2 in [regex]::Matches($zzS7, '(?<![-\w$])([A-Za-z][A-Za-z0-9]*-[A-Za-z][\w]*)')) {
                $zzNm = $zzM2.Groups[1].Value
                $zzLo = $zzNm.ToLower()
                if ($zzSeen.ContainsKey($zzLo)) { continue }
                if (-not $zzFnNames.ContainsKey($zzLo)) { continue }
                $zzSeen[$zzLo] = $true
                $zzSb2 = $null
                try { $zzSb2 = (Get-Command $zzFnNames[$zzLo] -CommandType Function -ErrorAction Stop).ScriptBlock } catch { continue }
                $zzQ.Enqueue([PSCustomObject]@{ S = "$zzSb2"; D = $zzCur.D + 1 })
            }
        }
        return [PSCustomObject]@{ Write = @($zzHitW.Keys); Spawn = @($zzHitS.Keys); Walked = $zzSeen.Count }
    }
    # 🔒 AND A LIST THAT NO ANALYSIS CAN OVERRIDE. Every control the frozen
    # contract names as destructive, plus every button that sends, saves,
    # launches, stops or answers. If the scan ever says one of these is safe,
    # the scan is wrong; this list is what stops that being found out the
    # expensive way.
    $zzNeverPress = @{}
    foreach ($zzNp in @('SaveBtn', 'SendBtn', 'SendBox', 'CastSend', 'CastCompact', 'Broadcast',
                        'AskFreeSend', 'AskReview', 'PaneStop', 'PaneRelaunch', 'PaneGoTo', 'PaneCompact',
                        'PaneWorktree', 'RelaunchSessions', 'OpenNotRunning', 'SignIn', 'NewSession',
                        'Rescan', 'SetApply', 'SetCancel', 'SkillList', 'WinClose', 'WinMin', 'WinMax',
                        'SheetB1', 'SheetB2', 'SheetB3', 'Scrim', 'AskOptions', 'CastList')) {
        $zzNeverPress[$zzNp] = $true
    }

    # WHAT THIS RUN ACTUALLY PRESSED, listed by hand rather than inferred, so
    # the table cannot quietly claim coverage it does not have.
    $zzPressed = @{
        'RailList' = 'D3: SelectionChanged driven by moving the selection'
        'RailClear' = 'D3: MouseLeftButtonUp raised'
        'RailSort' = 'D3: MouseLeftButtonDown raised'
        'RailShelved' = 'D3: MouseLeftButtonDown raised'
        'RailOnlyLive' = 'D3: MouseLeftButtonDown raised'
        'SessionList' = 'D3: SelectionChanged, as a consequence of every rebuild'
    }

    $zzTable = New-Object System.Collections.Generic.List[object]
    foreach ($zzK in @($ui.Keys | Sort-Object)) {
        $zzDs = Get-HandlerDelegates $ui[$zzK]
        if (-not @($zzDs).Count) { continue }
        $zzEvs = @()
        $zzSrcAll = ''
        $zzNoSrc = 0
        foreach ($zzD2 in $zzDs) {
            $zzEvs += $zzD2.Event
            $zzS4 = Get-HandlerSource $zzD2.Del
            if (-not $zzS4) { $zzNoSrc++ } else { $zzSrcAll += "`n" + $zzS4 }
        }
        $zzDeep = Scan-Deep $zzSrcAll
        $zzHitSpawn = @($zzDeep.Spawn)
        $zzHitWrite = @($zzDeep.Write)
        # The handler's OWN text, separately from what it can reach. This is
        # what decides whether it is pressed; the deep scan is what is reported.
        $zzShallowHits = @(@($zzWrites) + @($zzSpawns) | Where-Object { $zzSrcAll.IndexOf($_, [StringComparison]::OrdinalIgnoreCase) -ge 0 })
        $zzVerdict = 'pressable'
        if ($zzNoSrc) { $zzVerdict = 'could not read the handler' }
        if (@($zzHitSpawn).Count) { $zzVerdict = 'spawns a real process' }
        if (@($zzHitWrite).Count) { $zzVerdict = 'writes / irreversible' }
        if ($zzNeverPress.ContainsKey($zzK)) { $zzVerdict = 'writes / irreversible' }
        $null = $zzTable.Add([PSCustomObject]@{
            Name = $zzK; Type = $ui[$zzK].GetType().Name
            Events = ((@($zzEvs) | Select-Object -Unique) -join ', ')
            Verdict = $zzVerdict
            Shallow = (@($zzShallowHits).Count -gt 0 -or $zzNoSrc -gt 0)
            Why = (((@($zzHitWrite) + @($zzHitSpawn)) -join ' ') +
                   $(if (@($zzShallowHits).Count) { '  [in the handler itself: ' + (@($zzShallowHits) -join ' ') + ']' } else { '' }) +
                   $(if ($zzNeverPress.ContainsKey($zzK)) { '  [on the never-press list]' } else { '' })).Trim()
            Pressed = "$($zzPressed[$zzK])"
        })
    }
    Note ("{0} of {1} named elements carry at least one handler" -f $zzTable.Count, @($ui.Keys).Count)
    foreach ($zzGrp in @('pressable', 'spawns a real process', 'writes / irreversible', 'could not read the handler')) {
        $zzRows = @($zzTable | Where-Object { $_.Verdict -eq $zzGrp })
        if (-not $zzRows.Count) { continue }
        Write-Host ''
        Write-Host ("  {0} ({1})" -f $zzGrp.ToUpper(), $zzRows.Count) -ForegroundColor White
        foreach ($zzT in $zzRows) {
            $zzMark = $(if ($zzT.Pressed) { 'PRESSED  ' } else { '         ' })
            Write-Host ("   {0}{1,-18} {2,-20} {3,-46} {4}" -f $zzMark, $zzT.Name, $zzT.Type, $zzT.Events, $zzT.Why)
        }
    }
    $zzNotPressed = @($zzTable | Where-Object { -not $_.Pressed })
    Note ('{0} of {1} controls carrying a handler were NOT pressed by this run. None of them is reported as passing.' -f `
          @($zzNotPressed).Count, $zzTable.Count)

    # -----------------------------------------------------------------------
    # AND THE ONES THAT ARE SAFE TO PRESS ARE PRESSED, because a control nobody
    # measured is the thing this audit exists to stop.
    # -----------------------------------------------------------------------
    Head 'pressing every control whose handler does no harm'
    $zzMouseEv = @{
        'MouseLeftButtonDown'        = [System.Windows.UIElement]::MouseLeftButtonDownEvent
        'MouseLeftButtonUp'          = [System.Windows.UIElement]::MouseLeftButtonUpEvent
        'PreviewMouseLeftButtonDown' = [System.Windows.UIElement]::PreviewMouseLeftButtonDownEvent
        'PreviewMouseLeftButtonUp'   = [System.Windows.UIElement]::PreviewMouseLeftButtonUpEvent
    }
    # =======================================================================
    # 🔒 THE STUB LAYER. Defence in depth, not the gate.
    #
    # The transitive scan above is honest and almost useless on its own: at
    # depth 3 nearly every handler reaches Set-Surface, which reaches
    # Build-Manager, which reaches something that mentions Launch - so 54 of 64
    # controls come back "irreversible" and NOTHING gets measured. Loosening the
    # scan to make the table fuller would be tuning a safety check until it
    # stops objecting, which is the worst possible reason to change one.
    #
    # So the scan stays strict AND the primitives it is afraid of are replaced,
    # in this process only, with recording no-ops. Then pressing a control that
    # the depth-1 read says is harmless cannot become harmful if that read was
    # wrong - the destructive call reaches a stub and is COUNTED instead.
    # A press that trips a stub is reported as a defect, loudly: it means the
    # classification was wrong and the only thing that stopped it was this.
    #
    # 🪤 THE STUBS ARE PROVEN BEFORE THEY ARE RELIED ON. An uncalibrated stub
    # layer is worse than none, because it is trusted.
    # =======================================================================
    $zzTripped = @{}
    $zzStubbed = @('Start-Process', 'Stop-Process', 'Start-Job',
                   'Invoke-Send', 'Send-SRInterrupt', 'Send-SRQuestionAnswer', 'Send-SRSessionInput',
                   'Invoke-AskTyped', 'Invoke-SRAnswerOnScreen', 'Invoke-SRAnswerTypedOnScreen',
                   'Invoke-SRAnswerMultiOnScreen', 'Start-AskSend', 'Complete-AnswerSend',
                   'Invoke-RelaunchOne', 'Start-LaunchQueue', 'Show-Spawn',
                   'Save-SRRegistry', 'Update-SRRegistry', 'Save-RegistryOrAsk', 'Set-ProjectShelved',
                   'Start-LiveProbe', 'Start-VitalsSweep', 'Start-AskProbe', 'Start-SRScreenServer',
                   'Get-SRScreenText', 'Get-SRScreenTextMany', 'Get-SRScreenTextServed',
                   'Show-Sheet', 'Confirm-Action', 'Update-Model')
    foreach ($zzSn in $zzStubbed) {
        if (-not (Get-Command $zzSn -ErrorAction SilentlyContinue)) { continue }
        $zzBody = ("`$script:zzTripped['{0}'] = [int]`$script:zzTripped['{0}'] + 1; return `$null" -f $zzSn)
        $null = New-Item -Path ("function:\" + $zzSn) -Value ([scriptblock]::Create($zzBody)) -Force
    }
    # CALIBRATION: the stub must actually intercept, and it must be visible.
    $zzProcBefore = @(Get-Process -Name 'notepad' -ErrorAction SilentlyContinue).Count
    $null = Start-Process -FilePath 'notepad.exe'
    $zzProcAfter = @(Get-Process -Name 'notepad' -ErrorAction SilentlyContinue).Count
    $zzStubOk = ([int]$zzTripped['Start-Process'] -eq 1 -and $zzProcAfter -eq $zzProcBefore)
    if (-not $zzStubOk) {
        Fail ('the stub layer is NOT armed: a Start-Process call was recorded {0} time(s) and the notepad count went {1} -> {2}. Nothing will be pressed.' -f `
              [int]$zzTripped['Start-Process'], $zzProcBefore, $zzProcAfter)
    } else {
        Pass ('stub layer armed and proven: {0} destructive primitive(s) replaced, and a real Start-Process call started nothing' -f @($zzStubbed).Count)
    }
    $zzTripped = @{}

    $zzRan = New-Object System.Collections.Generic.List[object]
    $zzCanPress = @()
    if (-not $script:zzRecoveryOk) {
        Note 'the source recovery is not calibrated, so NOTHING is pressed here - a control whose handler could not be read is not a control that has been shown to be safe'
    } elseif (-not $zzStubOk) {
        Note 'the stub layer is not armed, so NOTHING is pressed here'
    } else {
        # DEPTH ONE decides what is pressed - the handler's OWN text - with the
        # never-press list and the stub layer behind it. The deep scan stays in
        # the table above as the reason each control is or is not trusted.
        $zzCanPress = @($zzTable | Where-Object {
            -not $_.Pressed -and -not $zzNeverPress.ContainsKey($_.Name) -and -not $_.Shallow })
    }
    foreach ($zzT in $zzCanPress) {
        $zzEvName = ''
        foreach ($zzE3 in @($zzT.Events -split ',\s*')) { if ($zzMouseEv.ContainsKey($zzE3)) { $zzEvName = $zzE3; break } }
        if (-not $zzEvName -and $zzT.Events -match 'Click') { $zzEvName = 'Click' }
        if (-not $zzEvName) { continue }
        $zzBh2 = [double]::MaxValue; $zzBf2 = [double]::MaxValue; $zzErr = ''
        $zzTripped = @{}; $zzTripH = @{}; $zzTripS = @{}
        for ($zzI = 0; $zzI -lt 3; $zzI++) {
            if ($zzEvName -eq 'Click') {
                $zzA4 = New-Object System.Windows.RoutedEventArgs([System.Windows.Controls.Primitives.ButtonBase]::ClickEvent)
            } else {
                $zzA4 = New-Object System.Windows.Input.MouseButtonEventArgs(
                            [System.Windows.Input.Mouse]::PrimaryDevice, 0, [System.Windows.Input.MouseButton]::Left)
                $zzA4.RoutedEvent = $zzMouseEv[$zzEvName]
            }
            $zzS5 = [Diagnostics.Stopwatch]::StartNew()
            try { $ui[$zzT.Name].RaiseEvent($zzA4) } catch { $zzErr = "$($_.Exception.Message)" }
            $zzS5.Stop()
            # 🔴 WHAT THE HANDLER TRIPPED, READ BEFORE THE PUMP RUNS. The first
            # version read the trip counters after Settle and reported that
            # fifteen different controls had all reached Complete-AnswerSend and
            # Start-VitalsSweep - which is not fifteen handlers doing the same
            # surprising thing, it is the ApplicationIdle pump draining the
            # window's own timer lane on every settle. The measuring apparatus
            # was being charged to the thing it measures.
            foreach ($zzTk in @($zzTripped.Keys)) { $zzTripH[$zzTk] = $true }
            $zzTripped = @{}
            $zzS6 = [Diagnostics.Stopwatch]::StartNew()
            Settle
            $zzS6.Stop()
            foreach ($zzTk in @($zzTripped.Keys)) { $zzTripS[$zzTk] = $true }
            $zzTripped = @{}
            if ($zzErr) { break }
            if ($zzS5.Elapsed.TotalMilliseconds -lt $zzBh2) { $zzBh2 = $zzS5.Elapsed.TotalMilliseconds }
            if (($zzS5.Elapsed.TotalMilliseconds + $zzS6.Elapsed.TotalMilliseconds) -lt $zzBf2) {
                $zzBf2 = $zzS5.Elapsed.TotalMilliseconds + $zzS6.Elapsed.TotalMilliseconds
            }
        }
        $null = $zzRan.Add([PSCustomObject]@{ Name = $zzT.Name; Ev = $zzEvName; H = $zzBh2; F = $zzBf2; Err = $zzErr
            Trip = ((@($zzTripH.Keys) | Sort-Object) -join ' ')
            TripS = ((@($zzTripS.Keys) | Sort-Object) -join ' ') })
        Assert-LiveStill ('pressing ' + $zzT.Name)
    }
    Write-Host ("  {0,-20} {1,-30} {2,10} {3,10}" -f 'control', 'event raised', 'handler', 'frame')
    foreach ($zzR3 in $zzRan) {
        if ($zzR3.Err) { Write-Host ("  {0,-20} {1,-30} THREW: {2}" -f $zzR3.Name, $zzR3.Ev, $zzR3.Err) -ForegroundColor Red; continue }
        $zzCol = $(if ($zzR3.F -gt 50.0) { 'Yellow' } else { 'Gray' })
        Write-Host ("  {0,-20} {1,-30} {2,10:N1} {3,10:N1}" -f $zzR3.Name, $zzR3.Ev, $zzR3.H, $zzR3.F) -ForegroundColor $zzCol
    }
    # 🔴 A TRIPPED STUB IS A DEFECT REPORT, NOT A FOOTNOTE. It says the handler
    # this audit read as harmless reached a destructive primitive anyway, and
    # that the only thing between it and the operator's sessions was the layer
    # that was supposed to be redundant.
    foreach ($zzR3 in $zzRan) {
        if ($zzR3.Trip) {
            Fail ("pressing {0} reached {1} - the depth-one read said this handler was harmless and it was WRONG. Only the stub layer stopped it." -f $zzR3.Name, $zzR3.Trip)
        }
    }
    if (-not @($zzRan | Where-Object { $_.Trip }).Count -and $zzRan.Count) {
        Pass ('{0} control(s) pressed and not one HANDLER reached a stubbed primitive' -f $zzRan.Count)
    }
    $zzPumpTrips = @{}
    foreach ($zzR3 in $zzRan) { foreach ($zzTk in @("$($zzR3.TripS)" -split ' ')) { if ($zzTk) { $zzPumpTrips[$zzTk] = $true } } }
    if ($zzPumpTrips.Count) {
        Note ('during the SETTLE - not in any handler - the window''s own timer lane reached {0}. That is the message pump doing what it does between gestures; it is reported so nobody reads it as a handler doing it.' -f `
              ((@($zzPumpTrips.Keys) | Sort-Object) -join ', '))
    }
    Note ('the bar is 7,0 ms (the terminal answering an arrow key) and the gesture budget is 50 ms; rows over the budget are yellow')
    # Put the window back on the work surface whatever the presses did to it.
    $ui.ModeWork.IsChecked = $true
    Set-Surface 'work'
    $script:railPick = $null
    Build-Rail; Build-Sessions; Settle
}

# ===========================================================================
Head 'the operator''s files, re-hashed'
if ((Get-H $zzLiveCfg) -ne $zzCfgLiveWas) { Fail 'session-restore.config.json CHANGED during this run' }
else { Pass 'session-restore.config.json is byte-identical to what it was before this run' }
$zzRegNow = Get-H $zzLiveReg
if (-not $zzRegNow) { Inconclusive 'the live registry could not be re-hashed - that guard is not armed at the end' }
elseif ($zzRegNow -ne $zzRegLiveWas) {
    Inconclusive 'sessions-registry.json moved during this run. Every save path here was redirected and proven, and the operator window writes this file on its own tick, so this check cannot tell the two apart.'
} else { Pass 'sessions-registry.json is byte-identical to what it was before this run' }
$zzCtlEnd = Measure-Ctl
Note ("the WPF control workload: {0:N1} ms at the start, {1:N1} ms at the end ({2:N2}x drift)" -f `
      $zzCtlStart, $zzCtlEnd, $(if ($zzCtlStart -gt 0) { $zzCtlEnd / $zzCtlStart } else { 0 }))
if ($zzCtlStart -gt 0 -and ([Math]::Max($zzCtlEnd / $zzCtlStart, $zzCtlStart / $zzCtlEnd) -gt 1.6)) {
    Inconclusive 'the control moved by more than 1,6x between the two ends of this run - the machine changed while the table was being taken, so the absolute numbers above should not be compared with another run.'
}

Write-Host ''
if ($zzFails) { Write-Host ("{0} FAILURE(S)" -f $zzFails) -ForegroundColor Red; exit 1 }
if ($zzUnsure) { Write-Host ("{0} inconclusive" -f $zzUnsure) -ForegroundColor Magenta; exit 2 }
Write-Host 'audit clean' -ForegroundColor Green
exit 0
