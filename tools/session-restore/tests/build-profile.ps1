# ===========================================================================
#  WHERE THE 775 ms OF A CONVERSATION SWITCH ACTUALLY GOES.
#
#  Everything OFF the UI thread was measured first and is cheap: the runspace
#  library load is 13 ms, Get-SRTranscriptBlocks 14-20 ms, Get-ReadTurns 3-7 ms,
#  the collecting lane 30 ms, the click handler itself 23 ms. That is ~90 ms of
#  a gesture the pixels harness times at 775-900 ms to settle, so the remainder
#  is on THIS thread: building the WPF objects, and laying them out.
#
#  This splits those two, because they have different fixes. Build is object
#  construction and is ours; layout is WPF measuring what we handed it, and the
#  only lever on it is handing over less.
#
#  🪤 ASSIGN, THEN WRAP. Get-SRTranscriptBlocks ends with a comma guard, so
#  @(Get-SRTranscriptBlocks ...) is ONE element holding every block. Measured
#  wrong once already today - 1 block where there were 7.
#
#  🔴 READ-ONLY. Parses transcripts and builds documents. Selects nothing,
#  starts no probe, touches no config, no registry, no live session.
# ===========================================================================
$fails = 0
function Fail { param($m) Write-Host "  FAIL  $m" -ForegroundColor Red; $script:fails++ }
function Pass { param($m) Write-Host "  ok    $m" -ForegroundColor Green }
function Note { param($m) Write-Host "        $m" -ForegroundColor DarkGray }

Write-Host ''
Write-Host '  --- what a conversation switch pays, split by phase ---' -ForegroundColor Cyan

$TAIL = $script:TailBase
$proj = Join-Path $env:USERPROFILE '.claude\projects'
$all = @(Get-ChildItem -Path $proj -Filter '*.jsonl' -Recurse -ErrorAction SilentlyContinue |
         Where-Object { $_.Length -gt 20KB } | Sort-Object Length)
if (-not $all.Count) { Fail 'no transcripts to profile'; exit 1 }
Note ("{0} transcripts on this machine; tail budget {1:N0} bytes" -f $all.Count, $TAIL)

# TYPICAL, not biggest - picking by size picks the session doing the picking.
$pick = @(
    @{ N = 'p25'; F = $all[[int]($all.Count*0.25)] }
    @{ N = 'p50'; F = $all[[int]($all.Count*0.50)] }
    @{ N = 'p75'; F = $all[[int]($all.Count*0.75)] }
    @{ N = 'p95'; F = $all[[int]($all.Count*0.95)] }
)

Write-Host ''
Write-Host ('  {0,-5} {1,10} {2,7} {3,7} {4,9} {5,9} {6,9} {7,9}' -f 'which','size','blocks','turns','parse','turns.ms','BUILD','LAYOUT') -ForegroundColor Gray
Write-Host ('  ' + ('-'*74)) -ForegroundColor DarkGray

$buildTimes = @(); $layoutTimes = @(); $parseTimes = @()
foreach ($p in $pick) {
    $f = $p.F
    $parse = 0.0; $turnMs = 0.0; $build = 0.0; $layout = 0.0
    $nb = 0; $nt = 0
    try {
        # warm the file cache so a cold read is not the answer
        $null = Get-SRTranscriptBlocks -JsonlPath $f.FullName -MaxRecords 220 -MaxTailBytes $TAIL

        $sw = [Diagnostics.Stopwatch]::StartNew()
        $got = Get-SRTranscriptBlocks -JsonlPath $f.FullName -MaxRecords 220 -MaxTailBytes $TAIL
        $sw.Stop(); $parse = $sw.Elapsed.TotalMilliseconds
        $blocks = @($got); $nb = $blocks.Count

        $sw = [Diagnostics.Stopwatch]::StartNew()
        $turns = @(Get-ReadTurns $blocks)
        $sw.Stop(); $turnMs = $sw.Elapsed.TotalMilliseconds
        $nt = $turns.Count

        $sw = [Diagnostics.Stopwatch]::StartNew()
        $doc = Build-ReadDocument -Blocks $blocks -Truncated $true -Turns $turns
        $sw.Stop(); $build = $sw.Elapsed.TotalMilliseconds

        # LAYOUT: what WPF spends measuring and arranging what we just handed it.
        # This is the half the operator waits on after the build returns.
        $sw = [Diagnostics.Stopwatch]::StartNew()
        $ui.PaneDoc.Document = $doc
        $ui.PaneDoc.UpdateLayout()
        $sw.Stop(); $layout = $sw.Elapsed.TotalMilliseconds
    } catch {
        Fail ("{0}: {1}" -f $p.N, $_.Exception.Message)
        continue
    }
    $parseTimes += $parse; $buildTimes += $build; $layoutTimes += $layout
    Write-Host ('  {0,-5} {1,10} {2,7} {3,7} {4,9:N1} {5,9:N1} {6,9:N1} {7,9:N1}' -f `
        $p.N, ('{0:N0}KB' -f ($f.Length/1KB)), $nb, $nt, $parse, $turnMs, $build, $layout)
}

Write-Host ''
if ($buildTimes.Count) {
    $mb = ($buildTimes | Measure-Object -Average).Average
    $ml = ($layoutTimes | Measure-Object -Average).Average
    $mp = ($parseTimes | Measure-Object -Average).Average
    Note ('mean parse {0:N1} ms | mean BUILD {1:N1} ms | mean LAYOUT {2:N1} ms' -f $mp, $mb, $ml)
    $onThread = $mb + $ml
    Note ('on the UI thread, per switch: {0:N1} ms' -f $onThread)
    if ($onThread -gt 200) {
        Pass ('the UI-thread half is the cost, as predicted: {0:N1} ms against {1:N1} ms of parse' -f $onThread, $mp)
    } else {
        # 🪤 A THIRD PLACE. If build+layout is small too, the 775 ms is neither
        # half and the next suspect is the dispatcher queue between them.
        Write-Host ('  ????  build+layout is only {0:N1} ms - the wait is in neither half, look at the dispatcher' -f $onThread) -ForegroundColor Magenta
    }
}
Write-Host ''
if ($fails) { Write-Host ("  {0} FAIL" -f $fails) -ForegroundColor Red; exit 1 }
Write-Host '  profile complete' -ForegroundColor Green
exit 0
