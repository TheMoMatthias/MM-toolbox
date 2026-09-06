# ===========================================================================
#  THE ONE EXPERIMENT LEFT ON THE SWITCH: IS IT CONTENTION?
#
#  Everything nameable was measured and eliminated: runspace open 8,5 ms, the
#  job's library load 13,3, block read 14-20, turn fold 3-7, the collecting lane
#  30, the click handler 23, Build-ReadDocument 159 (and INVERSELY related to
#  size, so warm-up not work). That is ~162 ms on the UI thread against a 775 ms
#  settle in the pixels harness.
#
#  Two suspects remain and only one is testable here. Show-Selected kicks
#  Start-LiveProbe AND sets askWanted, so up to three runspaces can be opening
#  and dot-sourcing the 426 KB library while the document parse runs. This times
#  the select-to-readable round trip with them on and with them suppressed.
#
#  TRAP: WHAT THIS CANNOT SEE, stated up front so a fast number is not mistaken
#  for an answer. The window is never shown, so there is no render and no vsync;
#  the pixels harness measures a settle this harness has no equivalent of. A
#  null result here does NOT clear contention on the operator's machine, it only
#  says contention is not visible without a render. That is why the verdict
#  below abstains rather than concluding.
#
#  READ-ONLY. Selects conversations, parses transcripts, starts no session.
# ===========================================================================
$fails = 0
function Fail { param($m) Write-Host "  FAIL  $m" -ForegroundColor Red; $script:fails++ }
function Pass { param($m) Write-Host "  ok    $m" -ForegroundColor Green }
function Note { param($m) Write-Host "        $m" -ForegroundColor DarkGray }
function Huh  { param($m) Write-Host "  ????  $m" -ForegroundColor Magenta }

Write-Host ''
Write-Host '  --- is the switch waiting on its own probes? ---' -ForegroundColor Cyan

Build-Sessions
$rows = @($ui.SessionList.Items | Where-Object {
    $_.Kind -eq 'session' -and "$($_.Row.S.jsonl)" -and (Test-Path -LiteralPath "$($_.Row.S.jsonl)") })
if ($rows.Count -lt 4) { Note 'need four conversations with transcripts'; exit 0 }

function Measure-SRSwitch {
    param($Picks, [switch]$NoProbes)
    $orig = ${function:Start-LiveProbe}
    if ($NoProbes) { function Start-LiveProbe { } }
    $times = @()
    try {
        foreach ($p in $Picks) {
            $script:selId = $null
            $ui.PaneDoc.Document = $null
            Clear-SRVitalsCache
            $sw = [Diagnostics.Stopwatch]::StartNew()
            $ui.SessionList.SelectedItem = $p
            Show-Selected
            if ($NoProbes) { $script:askWanted = $false }
            while ($sw.Elapsed.TotalSeconds -lt 10 -and -not $ui.PaneDoc.Document) {
                Start-Sleep -Milliseconds 2
                $null = Complete-DocParse
            }
            $sw.Stop()
            if ($ui.PaneDoc.Document) { $times += $sw.Elapsed.TotalMilliseconds }
        }
    } finally { ${function:Start-LiveProbe} = $orig }
    return ,$times
}

# TRAP: ALTERNATE THE ARMS, do not run all of one then all of the other. A
# machine that gets busier partway through would otherwise hand the whole drift
# to whichever arm ran second, and the ratio would read as a finding.
$picksA = @(); $picksB = @()
$take = [Math]::Min(24, $rows.Count)
for ($i = 0; $i -lt $take; $i++) {
    if ($i % 2 -eq 0) { $picksA += $rows[$i] } else { $picksB += $rows[$i] }
}

# TRAP: EIGHT SAMPLES COULD NOT SETTLE THIS. The first run showed 88,9 ms in the
# right direction on both arms against a 518,7 ms spread, which is a sample-size
# problem wearing the costume of a null result. Both halves of each arm are run
# twice, alternating, so drift lands on both.
$with = @(); $without = @()
foreach ($round in 1..2) {
    $with    += Measure-SRSwitch -Picks $picksA
    $without += Measure-SRSwitch -Picks $picksB -NoProbes
    $with    += Measure-SRSwitch -Picks $picksB
    $without += Measure-SRSwitch -Picks $picksA -NoProbes
}
if ($with.Count -lt 2 -or $without.Count -lt 2) { Huh 'too few completed switches to compare'; exit 0 }

function Med { param($a) $s = @($a | Sort-Object); return $s[[int]($s.Count/2)] }
$mw = Med $with
$mo = Med $without
Note ("with probes:    {0} samples, median {1:N1} ms  (min {2:N1} max {3:N1})" -f $with.Count, $mw, ($with | Measure-Object -Min).Minimum, ($with | Measure-Object -Max).Maximum)
Note ("probes off:     {0} samples, median {1:N1} ms  (min {2:N1} max {3:N1})" -f $without.Count, $mo, ($without | Measure-Object -Min).Minimum, ($without | Measure-Object -Max).Maximum)

$delta = $mw - $mo
Note ("delta: {0:N1} ms" -f $delta)

# KEY: A DELTA, NOT A RATIO. A ratio drags toward 1 because everything common to
# both arms sits in numerator and denominator alike - the reconciliation in
# pixels-driver.ps1 is the worked example. The delta is the physical saving.
#
# TRAP: AND THE SPREAD DECIDES WHETHER THE DELTA MEANS ANYTHING. Clean runs of
# this gesture have been seen 100 ms apart on identical source, so a delta
# inside the observed spread is noise wearing a number.
# KEY: THE MINIMUM IS THE LEAST NOISY STATISTIC HERE. Contention and scheduling
# can only ever make a sample SLOWER, never faster, so the fastest observed run
# of each arm is the closest thing to the work itself. max-min is dominated by
# whichever sample happened to land under a GC or a sweep, which is why judging
# against the full spread refused a delta that was present on both arms.
$minW = ($with | Measure-Object -Min).Minimum
$minO = ($without | Measure-Object -Min).Minimum
$dMin = $minW - $minO
Note ("best-of: with {0:N1} ms vs without {1:N1} ms  -> {2:N1} ms" -f $minW, $minO, $dMin)

if ($dMin -gt 15 -and $delta -gt 15) {
    Pass ("the probes cost the switch {0:N1} ms at the median and {1:N1} ms best-of, in the same direction on both statistics - worth building" -f $delta, $dMin)
} elseif ($dMin -lt -15 -or $delta -lt -15) {
    Huh ("probes-off measured SLOWER (median {0:N1}, best-of {1:N1}), which suppression cannot cause. Noise, not a finding." -f $delta, $dMin)
} else {
    Huh ("INCONCLUSIVE: median delta {0:N1} ms, best-of delta {1:N1} ms - too small to act on. And this harness never renders, so it does not clear the probes on a shown window either." -f $delta, $dMin)
}
Write-Host ''
if ($fails) { exit 1 }
exit 0
