# ===========================================================================
#  WHAT A COLUMN REBUILD IS ACTUALLY PAYING FOR.
#
#  A search keystroke costs 340-512 ms with a frame on the end, and it does
#  FOUR column rebuilds - Build-Rail and Build-Sessions, once for the character
#  and once for clearing it. tests\render-driver.ps1 measures one patched
#  Build-Sessions at 79 ms shown; four of those is the whole keystroke, so the
#  question is not "where does the keystroke go" but "what is in the 79 ms".
#
#  tests\shadow-bench.ps1 already eliminated the 15 DropShadowEffect: 0% off
#  the project pick and the keystroke arm came back SLOWER without them, which
#  means the shadows are below this instrument's floor. So it is not the blur.
#
#  THE QUESTION THIS ANSWERS. Does a rebuild cost what it costs because of the
#  434 conversations it WALKS, or because of the ~27 rows it DRAWS? Those have
#  opposite fixes - a cached walk against a CollectionView - and the two are
#  told apart by shrinking the model and leaving the surface alone.
#
#  Read-only. Nothing is shown, launched, typed into, sent or saved: the model
#  is a script variable, it is copied rather than mutated, and it is put back
#  in a finally.
#
#     powershell -NoProfile -ExecutionPolicy Bypass -File tests\refresh-bench-run.ps1 -Driver rebuild-bench.ps1 -Out rebuild-bench-test.ps1
# ===========================================================================
function ZrNote { param($m) Write-Host "        $m" -ForegroundColor DarkGray }
function ZrPass { param($m) Write-Host "  ok    $m" -ForegroundColor Green }
function ZrHuh  { param($m) Write-Host "  ????  $m" -ForegroundColor Magenta }

Write-Host ''
Write-Host '  --- what a column rebuild is paying for ---' -ForegroundColor Cyan

function ZrMed { param([scriptblock]$Do, [int]$N = 7)
    $zrT = @()
    for ($zrI = 0; $zrI -lt $N; $zrI++) {
        $zrW = [Diagnostics.Stopwatch]::StartNew(); & $Do; $zrW.Stop()
        $zrT += $zrW.Elapsed.TotalMilliseconds
    }
    $zrS = @($zrT | Sort-Object)
    return $zrS[[int]($zrS.Count / 2)]
}

Update-Model
$zrAll = $script:model
ZrNote ("{0} conversations in the model" -f $zrAll.Count)
Build-Sessions
$zrRows = @($ui.SessionList.Items).Count
ZrNote ("{0} items on the sessions column" -f $zrRows)
Write-Host ''

try {
    # ---- 1. the whole thing, as it runs today ------------------------------
    $zrFull  = ZrMed { Build-Sessions }
    $zrRail  = ZrMed { Build-Rail }
    $zrBoth  = ZrMed { Build-Rail; Build-Sessions }
    Write-Host ("        Build-Sessions                          {0,7:N1} ms" -f $zrFull)
    Write-Host ("        Build-Rail                              {0,7:N1} ms" -f $zrRail)
    Write-Host ("        both, which is what ONE keystroke does  {0,7:N1} ms" -f $zrBoth)
    Write-Host ("        a keystroke does it TWICE               {0,7:N1} ms" -f ($zrBoth * 2))
    Write-Host ''

    # ---- 2. the same surface, a tenth of the model -------------------------
    # KEEP THE ROWS THAT ARE ON SCREEN and drop the rest. If the cost follows
    # the model, this collapses; if it follows the surface, it does not move.
    $zrKeep = New-Object System.Collections.Generic.List[object]
    foreach ($zrR in $zrAll) {
        if ($zrR.Live -or $zrR.Warm -or ($script:selId -and $zrR.Id -eq $script:selId)) { $null = $zrKeep.Add($zrR) }
    }
    ZrNote ("{0} of the {1} conversations are the ones the surface actually shows" -f $zrKeep.Count, $zrAll.Count)
    $script:model = $zrKeep
    Build-Sessions
    $zrRows2 = @($ui.SessionList.Items).Count
    $zrCut = ZrMed { Build-Sessions }
    Write-Host ("        Build-Sessions over {0,4} instead of {1,4}  {2,7:N1} ms   ({3} rows drawn, was {4})" -f `
        $zrKeep.Count, $zrAll.Count, $zrCut, $zrRows2, $zrRows)
    if ($zrRows2 -ne $zrRows) {
        ZrHuh 'the surface changed too, so this comparison is not clean - read it as an upper bound'
    }
    if ($zrFull -gt 0) {
        $zrPct = 100.0 * ($zrFull - $zrCut) / $zrFull
        if ($zrPct -ge 25) {
            ZrPass ("{0:N0}% of a rebuild is the WALK over conversations that are not on screen" -f $zrPct)
            ZrNote 'that part is cacheable: the walk only changes when the model changes, not when a letter is typed'
        } else {
            ZrPass ("the walk is not the cost ({0:N0}%) - it is the {1} rows that get built and drawn" -f $zrPct, $zrRows)
            ZrNote 'that part is what a CollectionView filter would remove, by never rebuilding the items at all'
        }
    }
}
finally {
    $script:model = $zrAll
    Build-Rail; Build-Sessions
    ZrNote 'the model is back to every conversation, and both columns are rebuilt from it'
}

Write-Host ''
exit 0
