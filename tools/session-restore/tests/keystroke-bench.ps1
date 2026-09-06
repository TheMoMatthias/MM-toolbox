# ===========================================================================
#  WHAT A SEARCH KEYSTROKE COSTS, AND WHICH HALF OF IT.
#
#  The operator reports input lag while typing. Behind every keystroke in either
#  search box sits the debounce and then Build-Rail + Build-Sessions, which an
#  earlier audit put at 312 ms over ~330 conversations.
#
#  A data/view split was approved on the strength of that number and its first
#  implementation REGRESSED - 152,9 ms bare against ~220 ms "cheap", because the
#  cache was filled by the very path it was meant to accelerate. So this
#  measures the two halves separately BEFORE anything is rebuilt:
#
#    FILTER  - walking $script:model, testing the haystack, banding, sorting
#    BUILD   - constructing the item objects the list binds to
#
#  Those need different fixes. If the filter dominates, the answer is a cheaper
#  predicate or an index. If the item construction dominates, the answer is
#  memoising the per-row object, and the split is worth building. If neither
#  does, the split is the wrong lever again and this says so.
#
#  READ-ONLY. Builds lists, types nothing, selects nothing, starts nothing.
# ===========================================================================
function Note { param($m) Write-Host "        $m" -ForegroundColor DarkGray }
function Pass { param($m) Write-Host "  ok    $m" -ForegroundColor Green }
function Huh  { param($m) Write-Host "  ????  $m" -ForegroundColor Magenta }

Write-Host ''
Write-Host '  --- what a search keystroke actually costs ---' -ForegroundColor Cyan
# 🪝 $script:model IS A List[object] AND @() THROWS ON ONE in PS 5.1 -
# "Argument types do not match", with no line number. .Count directly.
Note ("model holds {0} conversation(s)" -f $script:model.Count)

$searchWas = "$($ui.Search.Text)"
$rows = 0

function Time-It { param([scriptblock]$B, [int]$N = 5)
    $t = @()
    for ($i = 0; $i -lt $N; $i++) {
        $sw = [Diagnostics.Stopwatch]::StartNew()
        & $B
        $sw.Stop(); $t += $sw.Elapsed.TotalMilliseconds
    }
    $s = @($t | Sort-Object)
    return @{ Med = $s[[int]($s.Count/2)]; Min = $s[0]; Max = $s[$s.Count-1] }
}

try {
    # ---- the whole gesture, as the debounce fires it -----------------------
    $ui.Search.Text = ''
    $whole = Time-It { Build-Rail; Build-Sessions }
    $rows = $ui.SessionList.Items.Count
    Note ("Build-Rail + Build-Sessions, no filter : med {0,7:N1}  min {1,7:N1}  max {2,7:N1} ms  ({3} items)" -f $whole.Med, $whole.Min, $whole.Max, $rows)

    $sessOnly = Time-It { Build-Sessions }
    Note ("Build-Sessions alone                   : med {0,7:N1}  min {1,7:N1}  max {2,7:N1} ms" -f $sessOnly.Med, $sessOnly.Min, $sessOnly.Max)

    $railOnly = Time-It { Build-Rail }
    Note ("Build-Rail alone                       : med {0,7:N1}  min {1,7:N1}  max {2,7:N1} ms" -f $railOnly.Med, $railOnly.Min, $railOnly.Max)

    # ---- the FILTER half on its own ---------------------------------------
    # 🔑 THE SAME PREDICATE Build-Sessions USES, lifted out and run alone. Not a
    # similar one: the haystack test and the surface test are copied from the
    # loop verbatim, so what this times is what that loop spends before it
    # constructs a single object.
    $q = 'a'
    $filt = Time-It {
        $keep = New-Object System.Collections.Generic.List[object]
        $pick = "$($script:railPick)"
        foreach ($r in $script:model) {
            if ($pick) { if ("$($r.D.path)" -ne $pick) { continue } }
            elseif (-not ($r.Live -or $r.Warm -or ($script:selId -and $r.Id -eq $script:selId))) { continue }
            if ($q -and "$($r.Hay)" -notlike "*$q*") { continue }
            $keep.Add($r)
        }
    }
    Note ("the filter walk alone (one letter)     : med {0,7:N1}  min {1,7:N1}  max {2,7:N1} ms" -f $filt.Med, $filt.Min, $filt.Max)

    # ---- and a real keystroke, filter set ---------------------------------
    $ui.Search.Text = 'a'
    $withQ = Time-It { Build-Rail; Build-Sessions }
    $qRows = $ui.SessionList.Items.Count
    Note ("the same gesture with one letter typed : med {0,7:N1}  min {1,7:N1}  max {2,7:N1} ms  ({3} items)" -f $withQ.Med, $withQ.Min, $withQ.Max, $qRows)
} finally {
    $ui.Search.Text = $searchWas
    Build-Rail; Build-Sessions
}

Write-Host ''
$build = $sessOnly.Med - $filt.Med
Note ("so of {0:N1} ms in Build-Sessions, the filter walk is {1:N1} and everything after it is {2:N1}" -f $sessOnly.Med, $filt.Med, $build)
# 🪤 A VERDICT THAT NAMES THE LEVER, or abstains. The whole point of measuring
# first is that the last two speed suspects - the parse, then the probes - were
# both wrong, and both were named confidently before anyone timed them.
if ($sessOnly.Med -lt 40) {
    Huh ("Build-Sessions is only {0:N1} ms here - the typing lag is NOT in it on this machine, and a split would be the wrong lever for the third time." -f $sessOnly.Med)
} elseif ($build -gt ($filt.Med * 2)) {
    Pass ("item construction dominates ({0:N1} ms against {1:N1} ms of filtering) - memoising the per-row object is the lever" -f $build, $filt.Med)
} elseif ($filt.Med -gt ($build * 2)) {
    Pass ("the filter walk dominates ({0:N1} ms against {1:N1} ms of construction) - the predicate or an index is the lever, NOT a view split" -f $filt.Med, $build)
} else {
    Huh ("neither half dominates ({0:N1} ms filter, {1:N1} ms construction) - splitting them buys at most the smaller one" -f $filt.Med, $build)
}
exit 0
