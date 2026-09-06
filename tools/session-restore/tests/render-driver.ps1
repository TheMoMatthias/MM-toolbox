# ===========================================================================
#  THE ONE HARNESS THAT ACTUALLY RENDERS.
#
#  Every headless number in this repo says the tool is fast. The switch is
#  85,7 ms best-of, a search keystroke 43-52, Build-Sessions 35,5. Three named
#  causes were measured and all three were wrong: the transcript parse was not
#  the switch, the concurrent probes were not the switch, Build-Sessions was not
#  the keystroke. The operator still reports lag.
#
#  The gap is that no other harness in this repo draws anything. gui2, pixels and
#  the rest splice the window and never show it, so there is no PresentationSource
#  and no compositor - WPF walks the visual tree and rasterises in software, or
#  does not rasterise at all. This one SHOWS the window, so the numbers include
#  layout, render and the frame actually being presented.
#
#  ===========================================================================
#  🔴 WHY A SHOWN WINDOW IS SAFE HERE, AND WHAT MAKES IT SO
#  ===========================================================================
#  A shown session-restore window is a loaded gun: its buttons launch sessions,
#  kill them, type into them and write the registry. Four things together, not
#  any one of them:
#
#    1. EVERY DANGEROUS FUNCTION IS REPLACED BEFORE Show() IS CALLED, by a
#       counter. Start-SRSession, Start-AskSend, Save-SRRegistry,
#       Save-RegistryOrAsk, Save-SRConfigValue/Later/Writes, Invoke-SRRescan.
#       Not "avoided by not clicking them" - replaced, so a timer, a lane or a
#       stray event cannot reach one either.
#    2. THE COUNTERS ARE ASSERTED TO BE ZERO at the end. If anything did reach
#       one, the run says so loudly instead of finishing quietly.
#    3. THE WINDOW IS OFF THE DESKTOP AND CANNOT BE CLICKED - positioned at
#       -32000, ShowActivated false so it never takes focus, ShowInTaskbar
#       false, and IsHitTestVisible false on the root so a real mouse cannot
#       land on it even if it were visible.
#    4. IT IS CLOSED IN A finally, so a throw mid-run does not leave a live
#       window behind.
#
#  It reads the operator's real conversations, exactly as every other harness
#  here does, because the lag only exists at his scale - a fake registry with
#  three rows renders instantly and would answer a question nobody asked.
#  Reading is what the tool does; the writes are what is fenced off.
# ===========================================================================
$fails = 0
function Fail { param($m) Write-Host "  FAIL  $m" -ForegroundColor Red; $script:fails++ }
function Pass { param($m) Write-Host "  ok    $m" -ForegroundColor Green }
function Note { param($m) Write-Host "        $m" -ForegroundColor DarkGray }
function Huh  { param($m) Write-Host "  ????  $m" -ForegroundColor Magenta }

# ---- 1. the fence, before anything is shown --------------------------------
$script:dangerHits = @{}
function Trip { param([string]$W) $script:dangerHits[$W] = [int]$script:dangerHits[$W] + 1 }
function Start-SRSession      { Trip 'Start-SRSession';      return $null }
function Start-AskSend        { Trip 'Start-AskSend';        return $null }
function Save-SRRegistry      { Trip 'Save-SRRegistry';      return $true }
function Save-RegistryOrAsk   { Trip 'Save-RegistryOrAsk';   return $true }
function Save-SRConfigValue   { Trip 'Save-SRConfigValue';   return $true }
function Save-SRConfigLater   { Trip 'Save-SRConfigLater';   return $true }
function Save-SRConfigWrites  { Trip 'Save-SRConfigWrites';  return $true }
function Invoke-SRRescan      { Trip 'Invoke-SRRescan';      return @{ Scanned = $false; Why = 'fenced off in the render harness' } }

Write-Host ''
Write-Host '  --- what the gestures cost with a real frame on the end ---' -ForegroundColor Cyan
Note 'every write, send and launch is replaced by a counter before the window is shown'

# ---- 2. show it, off the desktop, unfocusable -------------------------------
$window.WindowStartupLocation = 'Manual'
$window.Left = -32000
$window.Top  = -32000
$window.ShowInTaskbar = $false
$window.ShowActivated = $false
try { $window.Content.IsHitTestVisible = $false } catch { }

$shown = $false
try {
    $window.Show()
    $shown = $true
} catch {
    Fail ("the window would not show: {0}" -f $_.Exception.Message)
}

if (-not $shown) { Write-Host "  $fails FAIL" -ForegroundColor Red; exit 1 }

try {
    $PRI = [System.Windows.Threading.DispatcherPriority]
    # 🔑 DRAINING TO ContextIdle IS WHAT MAKES THIS A RENDER NUMBER. The
    # dispatcher processes Render and Loaded ABOVE ContextIdle, so a call that
    # returns from ContextIdle has been behind the layout and draw for that
    # frame. A Background drain would return before the frame is composed and
    # would give a headless number with extra steps.
    function Drain { $window.Dispatcher.Invoke([Action]{}, $PRI::ContextIdle) }

    Drain
    if (-not [System.Windows.PresentationSource]::FromVisual($window)) {
        Huh 'the window is shown but has no PresentationSource - this is still measuring the headless path, treat every number below as suspect'
    } else {
        Pass 'the window is shown and has a real PresentationSource - these are render numbers'
    }

    function Time-Gesture { param([string]$Name, [scriptblock]$Do, [int]$N = 5)
        $t = @()
        for ($i = 0; $i -lt $N; $i++) {
            Drain
            $sw = [Diagnostics.Stopwatch]::StartNew()
            & $Do
            Drain
            $sw.Stop()
            $t += $sw.Elapsed.TotalMilliseconds
        }
        $s = @($t | Sort-Object)
        $med = $s[[int]($s.Count/2)]
        Write-Host ("        {0,-34} med {1,7:N1}  min {2,7:N1}  max {3,7:N1} ms" -f $Name, $med, $s[0], $s[$s.Count-1])
        return $med
    }

    Build-Rail; Build-Sessions; Drain
    $sess = @($ui.SessionList.Items | Where-Object {
        $_.Kind -eq 'session' -and "$($_.Row.S.jsonl)" -and (Test-Path -LiteralPath "$($_.Row.S.jsonl)") })
    Note ("{0} conversation(s) on screen" -f $sess.Count)
    Write-Host ''

    $r = @{}

    # ---- the gesture he named ---------------------------------------------
    if ($sess.Count -lt 2) { Huh 'need two conversations to switch between' }
    else {
        $n = 0
        $r.Switch = Time-Gesture 'switch conversation' {
            $pick = $sess[$script:n % $sess.Count]
            $script:n++
            $script:selId = $null
            $ui.SessionList.SelectedItem = $pick
            Show-Selected
            $sw2 = [Diagnostics.Stopwatch]::StartNew()
            while ($sw2.Elapsed.TotalSeconds -lt 8 -and -not $ui.PaneDoc.Document) {
                $null = Complete-DocParse
                $window.Dispatcher.Invoke([Action]{}, $PRI::Background)
            }
        } 6
    }

    # ---- typing ------------------------------------------------------------
    $searchWas = "$($ui.Search.Text)"
    $r.Key = Time-Gesture 'a search keystroke (rebuild)' {
        $ui.Search.Text = 'a'
        Build-Rail; Build-Sessions
        $ui.Search.Text = ''
        Build-Rail; Build-Sessions
    }
    $ui.Search.Text = $searchWas

    # ---- the pane's own controls ------------------------------------------
    $r.Steps = Time-Gesture 'Steps: cycle the tool view' { Step-ToolView; Show-Selected -Force }
    $r.Zoom  = Time-Gesture 'zoom one step'              { Step-Zoom }
    try { Set-SRTypeScale -Percent 100; $ui.PaneZoom.Content = Get-ZoomLabel } catch { }

    $r.Sort  = Time-Gesture 'cycle the sessions sort' {
        $keys = @($script:ListSorts | ForEach-Object { $_.Key })
        $at = [array]::IndexOf($keys, $script:listSort)
        $script:listSort = $keys[($at + 1) % $keys.Count]
        Update-ListSortLabel; Build-Sessions
    }

    $r.Rail = Time-Gesture 'pick a project, then clear it' {
        $p = $null
        foreach ($m in $script:model) { if ("$($m.D.path)") { $p = "$($m.D.path)"; break } }
        $script:railPick = $p; Build-Sessions
        $script:railPick = $null; Build-Sessions
    }

    $r.Surface = Time-Gesture 'switch surface work <-> manage' {
        Set-Surface 'manage'
        Set-Surface 'work'
    }

    # ---- the A/B that decides whether the list patch was worth anything ----
    # 🔴 BOTH ARMS IN ONE RUN, ALTERNATING. The keystroke measured 199,6 ms in
    # one run of this file, 491,7 in another and 290,8 in a third, on identical
    # source - so comparing a number from after the patch against a number from
    # before it can say anything you like. Every speed claim in this repo made
    # that way has since been withdrawn.
    Write-Host ''
    $abOn = @(); $abOff = @()
    foreach ($round in 1..6) {
        foreach ($off in @($false, $true, $true, $false)) {
            $script:listPatchOff = $off
            # Force the next call down the chosen path from a known state.
            if ($off) { $ui.SessionList.ItemsSource = $null }
            $ui.Search.Text = 'a'; Build-Sessions
            Drain
            $sw = [Diagnostics.Stopwatch]::StartNew()
            $ui.Search.Text = ''
            Build-Sessions
            Drain
            $sw.Stop()
            if ($off) { $abOff += $sw.Elapsed.TotalMilliseconds } else { $abOn += $sw.Elapsed.TotalMilliseconds }
        }
    }
    $script:listPatchOff = $false
    $ui.Search.Text = ''; Build-Sessions; Drain

    function MedOf { param($a) $x = @($a | Sort-Object); return $x[[int]($x.Count/2)] }
    $mOn  = MedOf $abOn
    $mOff = MedOf $abOff
    $nOn  = ($abOn  | Measure-Object -Min).Minimum
    $nOff = ($abOff | Measure-Object -Min).Minimum
    Note ("list PATCHED : {0} samples, med {1,7:N1}  best {2,7:N1} ms" -f $abOn.Count, $mOn, $nOn)
    Note ("list REPLACED: {0} samples, med {1,7:N1}  best {2,7:N1} ms" -f $abOff.Count, $mOff, $nOff)
    $dMed = $mOff - $mOn
    $dBest = $nOff - $nOn
    # The minimum is the least noisy statistic: contention only ever makes a
    # sample slower, so the fastest run of each arm is closest to the work.
    if ($dMed -gt 15 -and $dBest -gt 15) {
        Pass ("patching the list instead of replacing it saves {0:N1} ms at the median and {1:N1} ms best-of" -f $dMed, $dBest)
    } elseif ($dMed -lt -15 -or $dBest -lt -15) {
        Fail ("the patch is SLOWER than replacing the list (median {0:N1}, best-of {1:N1}) - it should be reverted" -f (-$dMed), (-$dBest))
    } else {
        Huh ("INCONCLUSIVE: median delta {0:N1} ms, best-of {1:N1} ms - the patch cannot be shown to help, and unproven complexity on the hottest path is not worth keeping" -f $dMed, $dBest)
    }

    # ---- the verdict -------------------------------------------------------
    Write-Host ''
    # 🔴 THE BAR IS THE TERMINAL'S, 6,9 ms, and nothing here will reach it. What
    # matters is which gestures are ORDERS of magnitude over it, and whether the
    # render adds materially to the headless figure beside it.
    $head = @{ Switch = 85.7; Key = 43.5; Steps = $null; Zoom = $null; Sort = $null; Rail = $null; Surface = $null }
    foreach ($k in @('Switch','Key')) {
        if ($null -eq $r[$k] -or $null -eq $head[$k]) { continue }
        $delta = $r[$k] - $head[$k]
        if ($delta -gt ($head[$k] * 0.5)) {
            Pass ("{0}: {1:N1} ms shown against {2:N1} ms headless - the render adds {3:N1} ms, which is where the lag lives" -f $k, $r[$k], $head[$k], $delta)
        } elseif ($delta -lt 0) {
            Huh ("{0}: {1:N1} ms shown is FASTER than the {2:N1} ms headless figure - different machine load, not a finding" -f $k, $r[$k], $head[$k])
        } else {
            Huh ("{0}: {1:N1} ms shown against {2:N1} ms headless - the render adds only {3:N1} ms, so it is NOT the missing cost either" -f $k, $r[$k], $head[$k], $delta)
        }
    }
} finally {
    # ---- 4. never leave a live window behind -------------------------------
    try { $window.Close() } catch { }
}

# ---- 2. the fence is asserted, not assumed ---------------------------------
#
# 🔴 AND THE FIRST RUN PROVED IT WORKS BY CATCHING SOMETHING REAL. Save-SRConfigLater
# was reached ten times and Save-SRConfigWrites once - not a breach, but Step-Zoom
# and Step-ToolView remembering their setting on every single press. Measuring
# those two gestures WOULD have written the operator's live config five times
# each had they not been stubbed. That is exactly what the counter is for, and it
# is why the config writers are fenced even though they are not the dangerous set.
#
# 🪤 SO THE TWO GROUPS ARE JUDGED SEPARATELY. Folding them together would leave
# only two options, both wrong: fail forever on a gesture that legitimately
# saves, or drop config from the fence and let a real stray write through
# unseen.
$FORBIDDEN = @('Start-SRSession','Start-AskSend','Save-SRRegistry','Save-RegistryOrAsk','Invoke-SRRescan')
$EXPECTED  = @('Save-SRConfigValue','Save-SRConfigLater','Save-SRConfigWrites')
Write-Host ''
$breach = 0
foreach ($k in $script:dangerHits.Keys) {
    if ($FORBIDDEN -contains $k) {
        Fail ("{0} was reached {1} time(s) - a shown window launched, sent or wrote the registry" -f $k, $script:dangerHits[$k])
        $breach++
    }
}
if (-not $breach) { Pass 'nothing launched, killed, sent to a session, or written to the registry for the whole run' }
foreach ($k in $script:dangerHits.Keys) {
    if ($EXPECTED -contains $k) {
        Note ("{0} was called {1} time(s) and stubbed - Step-Zoom and Step-ToolView remember their setting on every press, so measuring them repeatedly would have rewritten the operator's config" -f $k, $script:dangerHits[$k])
    }
}

Write-Host ''
if ($fails) { Write-Host "  $fails FAIL" -ForegroundColor Red; exit 1 }
exit 0
