# ===========================================================================
#  WHAT THE CONTEXT STRIP ACTUALLY COSTS, PER SESSION.
#
#  Show-Selected clears the strip on every click and lets the follow tick refill
#  it, on the stated grounds that "reading the vitals costs ~120 ms of JSONL
#  parsing plus a git call". _common.ps1:6444 says the branch comes off the
#  record with no git call, so at least half of that claim is stale - and the
#  operator reports the strip arriving too slowly, which is the cost of the
#  claim being right or the tick being wrong.
#
#  Times Get-SRSessionVitals per session and Update-Chips end to end, so the
#  fix is aimed at whichever half is actually expensive.
#
#  🔴 READ-ONLY. Reads transcripts and paints chips in a window never shown.
# ===========================================================================
Write-Host ''
Write-Host '  --- what the context strip costs ---' -ForegroundColor Cyan

Build-Sessions
$rows = @($script:model | Where-Object { "$($_.S.jsonl)" -and (Test-Path -LiteralPath "$($_.S.jsonl)") })
Write-Host ("  {0} conversation(s) in the model" -f $rows.Count) -ForegroundColor Gray
if ($rows.Count -lt 3) { Write-Host '  too few to measure'; exit 0 }

$take = @($rows | Select-Object -First 12)
$vt = @(); $ct = @(); $okN = 0; $ctxN = 0
foreach ($r in $take) {
    $v = $null
    $sw = [Diagnostics.Stopwatch]::StartNew()
    try { $v = Get-SRSessionVitals -JsonlPath "$($r.S.jsonl)" -Session $r.S -WorkDir "$($r.D.path)" } catch { }
    $sw.Stop(); $vt += $sw.Elapsed.TotalMilliseconds
    if ($v -and $v.Ok) {
        $okN++
        if ([int]$v.Window -gt 0) { $ctxN++ }
    }
    $sw = [Diagnostics.Stopwatch]::StartNew()
    try { Update-Chips $r -Force } catch { }
    $sw.Stop(); $ct += $sw.Elapsed.TotalMilliseconds
}
function St { param($a,$n)
    $s = @($a | Sort-Object)
    "  {0,-26} min {1,7:N1}  med {2,7:N1}  max {3,7:N1} ms" -f $n, $s[0], $s[[int]($s.Count/2)], $s[$s.Count-1]
}
Write-Host ''
Write-Host (St $vt 'Get-SRSessionVitals')
Write-Host (St $ct 'Update-Chips (forced)')
Write-Host ''
Write-Host ("  vitals returned Ok for {0} of {1}; a CONTEXT WINDOW for {2}" -f $okN, $take.Count, $ctxN) -ForegroundColor Gray
# 🪤 THE SECOND NUMBER IS THE ONE THAT MATTERS FOR THE BARS. Ok means the file
# parsed; a Window means the session's own status bar was read. Only the second
# can draw a gauge, and the difference between them is how many rows can never
# show one no matter how fast the read gets.
$sweptN = 0
foreach ($r in $take) { if ($script:rowScreen["$($r.Id)"]) { $sweptN++ } }
Write-Host ("  the vitals sweep has a screen reading cached for {0} of {1}" -f $sweptN, $take.Count) -ForegroundColor Gray
exit 0
