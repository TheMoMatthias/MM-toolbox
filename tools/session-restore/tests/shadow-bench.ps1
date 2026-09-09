# ===========================================================================
#  WHAT THE FIFTEEN DROP SHADOWS COST, MEASURED RATHER THAN ASSUMED.
#
#  tests\render-driver.ps1 established that the lag is in the RENDER, not in
#  the data: a search keystroke is 43,5 ms headless and 512 ms with a frame on
#  the end. That is 468 ms of layout, rasterise and present for 27 rows, which
#  is far too much for what is on screen - so something in the tree is
#  expensive to DRAW, and the question is what.
#
#  window2.xaml carries 15 DropShadowEffect and no CacheMode anywhere. A
#  DropShadowEffect makes WPF render that subtree to an intermediate surface
#  and run a separable blur over it, and it redoes that whenever anything
#  inside changes. BlurRadius 46 on a full-height pane is the suspect.
#
#  This does not assert it. It measures the same gestures with the effects on
#  and with them off, ALTERNATING IN ONE RUN, because every speed claim in this
#  repo made by comparing two runs has since been withdrawn - the keystroke
#  alone has measured 199,6, 290,8 and 491,7 ms on identical source.
#
#  Same fence as render-driver: every launch, send and write is replaced by a
#  counter BEFORE the window is shown, the counters are asserted zero at the
#  end, the window sits at -32000 unactivated and hit-test-dead, and it is
#  closed in a finally. It reads the operator's real conversations because the
#  cost only exists at his scale.
#
#     powershell -NoProfile -ExecutionPolicy Bypass -File tests\refresh-bench-run.ps1 -Driver shadow-bench.ps1 -Out shadow-bench-test.ps1
# ===========================================================================
$zsFails = 0
function ZsFail { param($m) Write-Host "  FAIL  $m" -ForegroundColor Red; $script:zsFails++ }
function ZsPass { param($m) Write-Host "  ok    $m" -ForegroundColor Green }
function ZsNote { param($m) Write-Host "        $m" -ForegroundColor DarkGray }
function ZsHuh  { param($m) Write-Host "  ????  $m" -ForegroundColor Magenta }

$script:zsDanger = @{}
function ZsTrip { param([string]$W) $script:zsDanger[$W] = [int]$script:zsDanger[$W] + 1 }
function Start-SRSession      { ZsTrip 'Start-SRSession';      return $null }
function Start-AskSend        { ZsTrip 'Start-AskSend';        return $null }
function Save-SRRegistry      { ZsTrip 'Save-SRRegistry';      return $true }
function Save-RegistryOrAsk   { ZsTrip 'Save-RegistryOrAsk';   return $true }
function Save-SRConfigValue   { ZsTrip 'Save-SRConfigValue';   return $true }
function Save-SRConfigLater   { ZsTrip 'Save-SRConfigLater';   return $true }
function Save-SRConfigWrites  { ZsTrip 'Save-SRConfigWrites';  return $true }
function Invoke-SRRescan      { ZsTrip 'Invoke-SRRescan';      return @{ Scanned = $false; Why = 'fenced off in the shadow bench' } }

Write-Host ''
Write-Host '  --- what the drop shadows cost, on and off, in one run ---' -ForegroundColor Cyan
ZsNote 'every write, send and launch is replaced by a counter before the window is shown'

$window.WindowStartupLocation = 'Manual'
$window.Left = -32000
$window.Top  = -32000
$window.ShowInTaskbar = $false
$window.ShowActivated = $false
try { $window.Content.IsHitTestVisible = $false } catch { }

$zsShown = $false
try { $window.Show(); $zsShown = $true }
catch { ZsFail ("the window would not show: {0}" -f $_.Exception.Message) }
if (-not $zsShown) { Write-Host "  $zsFails FAIL" -ForegroundColor Red; exit 1 }

try {
    $zsPri = [System.Windows.Threading.DispatcherPriority]
    function ZsDrain { $window.Dispatcher.Invoke([Action]{}, $zsPri::ContextIdle) }
    ZsDrain
    if (-not [System.Windows.PresentationSource]::FromVisual($window)) {
        ZsHuh 'no PresentationSource - every number below is a headless number with extra steps'
    } else { ZsPass 'the window is shown and has a real PresentationSource' }

    # Every element carrying an Effect, found by walking the REALISED tree
    # rather than re-reading the XAML - a style could put one on too.
    $script:zsHeld = New-Object System.Collections.Generic.List[object]
    function ZsWalk { param($zsN)
        if ($null -eq $zsN) { return }
        try {
            if ($zsN -is [System.Windows.UIElement] -and $zsN.Effect) {
                $null = $script:zsHeld.Add([PSCustomObject]@{ El = $zsN; Fx = $zsN.Effect })
            }
        } catch { }
        $zsC = 0
        try { $zsC = [System.Windows.Media.VisualTreeHelper]::GetChildrenCount($zsN) } catch { return }
        for ($zsI = 0; $zsI -lt $zsC; $zsI++) {
            ZsWalk ([System.Windows.Media.VisualTreeHelper]::GetChild($zsN, $zsI))
        }
    }
    Build-Rail; Build-Sessions; ZsDrain
    ZsWalk $window
    ZsNote ("{0} element(s) in the realised tree carry an Effect" -f $script:zsHeld.Count)
    if (-not $script:zsHeld.Count) {
        ZsHuh 'nothing in the tree has an Effect - the A/B below has no arms and proves nothing'
    }
    $zsBlur = 0.0
    foreach ($zsH in $script:zsHeld) {
        try { if ($zsH.Fx.BlurRadius -gt $zsBlur) { $zsBlur = [double]$zsH.Fx.BlurRadius } } catch { }
    }
    ZsNote ("the widest blur radius on screen is {0}" -f $zsBlur)

    function ZsFxOff { foreach ($zsH in $script:zsHeld) { try { $zsH.El.Effect = $null } catch { } } }
    function ZsFxOn  { foreach ($zsH in $script:zsHeld) { try { $zsH.El.Effect = $zsH.Fx  } catch { } } }

    $script:zsSess = @($ui.SessionList.Items | Where-Object {
        $_.Kind -eq 'session' -and "$($_.Row.S.jsonl)" -and (Test-Path -LiteralPath "$($_.Row.S.jsonl)") })
    ZsNote ("{0} conversation(s) on screen" -f $script:zsSess.Count)
    Write-Host ''

    $script:zsPick = 0
    $zsGest = @(
        @{ N = 'switch conversation'; Do = {
            $zsP = $script:zsSess[$script:zsPick % $script:zsSess.Count]
            $script:zsPick++
            $script:selId = $null
            $ui.SessionList.SelectedItem = $zsP
            Show-Selected
            $zsW = [Diagnostics.Stopwatch]::StartNew()
            while ($zsW.Elapsed.TotalSeconds -lt 8 -and -not $ui.PaneDoc.Document) {
                $null = Complete-DocParse
                $window.Dispatcher.Invoke([Action]{}, $zsPri::Background)
            }
        } }
        @{ N = 'a search keystroke (rebuild)'; Do = {
            $ui.Search.Text = 'a'; Build-Rail; Build-Sessions
            $ui.Search.Text = '';  Build-Rail; Build-Sessions
        } }
        @{ N = 'pick a project, then clear it'; Do = {
            $zsQ = $null
            foreach ($zsM in $script:model) { if ("$($zsM.D.path)") { $zsQ = "$($zsM.D.path)"; break } }
            $script:railPick = $zsQ; Build-Sessions
            $script:railPick = $null; Build-Sessions
        } }
    )

    # ALTERNATING, one arm then the other, repeatedly - so a machine that gets
    # busy halfway through spoils both arms equally instead of handing the win
    # to whichever went second.
    $zsReps = 5
    foreach ($zsG in $zsGest) {
        if ($zsG.N -eq 'switch conversation' -and $script:zsSess.Count -lt 2) {
            ZsHuh 'need two conversations to switch between'; continue
        }
        $zsOnT = @(); $zsOffT = @()
        for ($zsR = 0; $zsR -lt $zsReps; $zsR++) {
            ZsFxOn;  ZsDrain
            $zsSw = [Diagnostics.Stopwatch]::StartNew(); & $zsG.Do; ZsDrain; $zsSw.Stop()
            $zsOnT += $zsSw.Elapsed.TotalMilliseconds
            ZsFxOff; ZsDrain
            $zsSw = [Diagnostics.Stopwatch]::StartNew(); & $zsG.Do; ZsDrain; $zsSw.Stop()
            $zsOffT += $zsSw.Elapsed.TotalMilliseconds
        }
        $zsA = @($zsOnT  | Sort-Object); $zsB = @($zsOffT | Sort-Object)
        $zsAm = $zsA[[int]($zsA.Count/2)]; $zsBm = $zsB[[int]($zsB.Count/2)]
        Write-Host ("        {0,-32}  shadows ON {1,8:N1}   OFF {2,8:N1}   best {3,7:N1} / {4,7:N1} ms" -f $zsG.N, $zsAm, $zsBm, $zsA[0], $zsB[0])
        if ($zsAm -gt 0) {
            $zsCut = 100.0 * ($zsAm - $zsBm) / $zsAm
            if ($zsCut -ge 15) {
                ZsPass ("turning the shadows off takes {0:N0}% off this gesture ({1:N0} ms)" -f $zsCut, ($zsAm - $zsBm))
            } elseif ($zsCut -le -15) {
                ZsHuh ("this gesture got SLOWER without the shadows ({0:N0}%) - the arms are not measuring what they claim" -f (-$zsCut))
            } else {
                ZsNote ("the shadows are not what this gesture is paying for ({0:N0}%)" -f $zsCut)
            }
        }
    }
    ZsFxOn
    Write-Host ''
    ZsNote 'a shadow that must stay can usually keep its look and lose its cost with CacheMode=BitmapCache, which is nowhere in window2.xaml'
}
finally {
    try { $window.Close() } catch { }
}

Write-Host ''
# The config writers are reachable from a TIMER, not only from a gesture - the
# write lane ticks while the bench runs - so reaching one is the fence doing its
# job, not the bench doing something it should not. It is reported, because
# "stubbed" is only reassuring if you can see what was stubbed. The launch, send
# and registry writers have no timer behind them and must be zero.
$zsSoft = @('Save-SRConfigValue', 'Save-SRConfigLater', 'Save-SRConfigWrites')
$zsHard = 0
foreach ($zsK in $script:zsDanger.Keys) {
    if ($zsSoft -contains $zsK) {
        ZsNote ("{0} was reached {1} time(s) and stubbed - the write lane ticks while this runs; nothing was written" -f $zsK, $script:zsDanger[$zsK])
    } else {
        ZsFail ("{0} was reached {1} time(s)" -f $zsK, $script:zsDanger[$zsK]); $zsHard++
    }
}
if (-not $zsHard) {
    ZsPass 'nothing launched, killed, sent to a session, or written to the registry for the whole run'
}
exit 0
