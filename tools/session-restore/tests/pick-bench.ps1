# ===========================================================================
#  WHY PICKING A PROJECT COSTS THREE TIMES WHAT TYPING DOES.
#
#  With the list patched instead of replaced, the shown-window harness makes
#  "pick a project, then clear it" the slowest gesture left at 123-259 ms. The
#  reason it is not the same 63 ms as a keystroke is not the rebuild being
#  slower - it is that a pick SHOWS THE PROJECT ENTIRELY (see Build-Sessions'
#  own note) while the unfiltered list shows only live and warm rows. 42 rows
#  become 128.
#
#  So the question is what a row costs to BUILD, and which part of it. Three
#  suspects have already been named confidently and measured wrong this session
#  - the parse, the probes, Build-Sessions itself - so nothing here is optimised
#  before it is timed.
#
#  🪤 VIRTUALIZATION IS ALREADY ON. window2.xaml:944-945 sets IsVirtualizing
#  with Recycling, so container realisation is bounded by what is visible and is
#  NOT what scales with 128 rows. The per-row work in the loop is.
#
#  READ-ONLY. Builds lists, presses nothing, writes nothing.
# ===========================================================================
function Note { param($m) Write-Host "        $m" -ForegroundColor DarkGray }
function Pass { param($m) Write-Host "  ok    $m" -ForegroundColor Green }
function Huh  { param($m) Write-Host "  ????  $m" -ForegroundColor Magenta }

Write-Host ''
Write-Host '  --- what a picked project costs, and where ---' -ForegroundColor Cyan

function Time-It { param([scriptblock]$B, [int]$N = 5)
    $t = @()
    for ($i = 0; $i -lt $N; $i++) {
        $sw = [Diagnostics.Stopwatch]::StartNew(); & $B; $sw.Stop(); $t += $sw.Elapsed.TotalMilliseconds
    }
    $s = @($t | Sort-Object)
    return $s[[int]($s.Count/2)]
}

$pickWas = $script:railPick
try {
    $script:railPick = $null
    $bare = Time-It { Build-Sessions }
    $bareN = $ui.SessionList.Items.Count

    # the project with the most conversations - the case that actually hurts
    $counts = @{}
    foreach ($m in $script:model) { $p = "$($m.D.path)"; if ($p) { $counts[$p] = [int]$counts[$p] + 1 } }
    $big = $null; $bigN = 0
    foreach ($k in $counts.Keys) { if ($counts[$k] -gt $bigN) { $bigN = $counts[$k]; $big = $k } }
    if (-not $big) { Note 'no project on this machine carries conversations'; exit 0 }

    $script:railPick = $big
    $picked = Time-It { Build-Sessions }
    $pickedN = $ui.SessionList.Items.Count

    Note ("unfiltered : {0,4} items  {1,7:N1} ms" -f $bareN, $bare)
    Note ("picked     : {0,4} items  {1,7:N1} ms   ({2})" -f $pickedN, $picked, (Get-ProjectLabel $big))
    if ($pickedN -gt $bareN -and $bareN -gt 0) {
        $perRowBare = $bare / [Math]::Max(1, $bareN)
        $perRowPick = $picked / [Math]::Max(1, $pickedN)
        Note ("per item   : {0:N2} ms unfiltered, {1:N2} ms picked" -f $perRowBare, $perRowPick)
    }

    # ---- where the per-row time goes ---------------------------------------
    # 🔑 THE HELPERS EACH ROW CALLS, timed over the picked set. Every one of
    # these is invoked once per row inside the build loop, and the audit that
    # produced this window has twice found the INVOCATION to be the cost rather
    # than the body - so they are timed as they are called, not as they read.
    $rowsPick = @($script:model | Where-Object { "$($_.D.path)" -eq $big })
    $n = $rowsPick.Count
    if ($n -lt 4) { Note 'too few rows in that project to break down'; exit 0 }
    Write-Host ''
    Note ("breaking down {0} rows of the picked project:" -f $n)

    $tTitle = Time-It { foreach ($r in $rowsPick) { $null = Get-Title $r.S $r.D } } 3
    $tSubs  = Time-It { foreach ($r in $rowsPick) { $null = Get-RowSubAgents $r } } 3
    $tAge   = Time-It { foreach ($r in $rowsPick) { $null = Get-AgeTicks $r.At } } 3
    $now    = Get-Date
    $tScr   = Time-It { foreach ($r in $rowsPick) { $null = Get-RowScreenSig "$($r.Id)" $now } } 3
    $tSig   = Time-It { foreach ($it in $ui.SessionList.Items) { $null = Get-SRItemSig $it } } 3

    Note ("Get-Title        {0,7:N1} ms" -f $tTitle)
    Note ("Get-RowSubAgents {0,7:N1} ms" -f $tSubs)
    Note ("Get-AgeTicks     {0,7:N1} ms" -f $tAge)
    Note ("Get-RowScreenSig {0,7:N1} ms" -f $tScr)
    Note ("Get-SRItemSig    {0,7:N1} ms   (the signature the in-place patch needs)" -f $tSig)

    $named = $tTitle + $tSubs + $tAge + $tScr + $tSig
    Write-Host ''
    Note ("named helpers account for {0:N1} ms of the {1:N1} ms build" -f $named, $picked)
    # 🪤 A VERDICT THAT NAMES THE LEVER OR ABSTAINS - the rule that has killed
    # three wrong suspects today.
    $worst = @(
        @{ N = 'Get-Title'; T = $tTitle }, @{ N = 'Get-RowSubAgents'; T = $tSubs },
        @{ N = 'Get-AgeTicks'; T = $tAge }, @{ N = 'Get-RowScreenSig'; T = $tScr },
        @{ N = 'Get-SRItemSig'; T = $tSig }
    ) | Sort-Object -Property { $_.T } -Descending | Select-Object -First 1
    if ($named -lt ($picked * 0.25)) {
        Huh ("the named helpers are only {0:N1} ms of {1:N1} - the cost is spread through the loop body itself, and there is no single lever here" -f $named, $picked)
    } elseif ($worst.T -gt ($named * 0.5)) {
        Pass ("{0} is {1:N1} ms, over half of everything named - that is the lever" -f $worst.N, $worst.T)
    } else {
        Huh ("no single helper dominates (worst is {0} at {1:N1} ms of {2:N1} named) - this scales with rows, so the fix is building fewer, not building faster" -f $worst.N, $worst.T, $named)
    }
} finally {
    $script:railPick = $pickWas
    Build-Sessions
}
exit 0
