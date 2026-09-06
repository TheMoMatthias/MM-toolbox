# ===========================================================================
#  WHY 12 BLOCKS SIT OFF THE TEXT COLUMN.
#
#  The alignment sweep went red the moment the E2E fixture stopped being chosen
#  by file size - the old pick rendered 372 characters and could not fail. Two
#  readings of that red, and they need opposite fixes:
#
#    a) a real misalignment the empty fixture hid, or
#    b) legitimately nested prose the sweep does not exempt. Add-ReadProse takes
#       an $Indent from its caller and the sweep allows only base and base+18.
#
#  So this prints, for every measurable paragraph: rendered first-character X,
#  the Margin.Left it was built with, its TextIndent, and its text. A hanging
#  list item has Margin = X + hang and TextIndent = -hang; nested prose has a
#  larger Margin with TextIndent 0. Those two are distinguishable, which is the
#  whole point of printing all three rather than the one the sweep uses.
#
#  🔴 READ-ONLY. Selects a conversation in a window that is never shown.
# ===========================================================================
Write-Host ''
Write-Host '  --- what the off-column blocks are actually built with ---' -ForegroundColor Cyan

Build-Sessions
$rows = @($ui.SessionList.Items | Where-Object { $_.Kind -eq 'session' -and "$($_.Row.S.jsonl)" -and (Test-Path -LiteralPath "$($_.Row.S.jsonl)") })
if ($rows.Count -lt 2) { Write-Host '  no transcripts'; exit 0 }

# Same pick as the suite now makes: most readable tail, ties on path.
$best = $null; $bestScore = -1; $bestPath = ''
foreach ($e in $rows) {
    $jp = "$($e.Row.S.jsonl)"; $score = 0
    try {
        $got = Get-SRTranscriptBlocks -JsonlPath $jp -MaxRecords 220 -MaxTailBytes $script:TailBase
        foreach ($b in @($got)) { $score += "$($b.Body)".Length }
    } catch { $score = 0 }
    if ($score -gt $bestScore -or ($score -eq $bestScore -and $jp -lt $bestPath)) { $bestScore = $score; $best = $e; $bestPath = $jp }
}
Write-Host ("  fixture: {0}  ({1:N0} body chars in tail)" -f "$($best.Row.T.Text)", $bestScore) -ForegroundColor Gray

$script:selId = $null
$ui.SessionList.SelectedItem = $best
Show-Selected
$sw = [Diagnostics.Stopwatch]::StartNew()
while ($sw.Elapsed.TotalSeconds -lt 10 -and -not $ui.PaneDoc.Document) { Start-Sleep -Milliseconds 5; $null = Complete-DocParse }
# 🪤 UpdateLayout ON THE PANE IS NOT ENOUGH IN AN UNSHOWN WINDOW. Without a
# real measure/arrange pass over the WINDOW, GetCharacterRect hands back
# Infinity for every run - which formats as a number and looks like an answer.
# Measured: every X came out oo before this was added.
$window.Measure((New-Object System.Windows.Size 1600, 1000))
$window.Arrange((New-Object System.Windows.Rect 0, 0, 1600, 1000))
$window.UpdateLayout()
$ui.PaneDoc.UpdateLayout()
$doc = $ui.PaneDoc.Document
if (-not $doc) { Write-Host '  no document'; exit 1 }

Write-Host ''
# 🔑 THE OBJECT MODEL ANSWERS THIS AND LAYOUT DOES NOT. GetCharacterRect needs a
# real arrange pass and returns Infinity without one - measured twice, even
# after Measure/Arrange/UpdateLayout on the window. But where a paragraph's
# FIRST LINE starts is Margin.Left + TextIndent, which is on the object before
# anything is drawn. Same quantity, no layout, no infinities.
$combos = @{}
$total = 0
foreach ($blk in $doc.Blocks) {
    if ($blk -isnot [System.Windows.Documents.Paragraph]) { continue }
    $ml = [double]$blk.Margin.Left
    $ti = [double]$blk.TextIndent
    $first = [Math]::Round($ml + $ti, 1)
    $sample = ''
    foreach ($inl in $blk.Inlines) {
        if ($inl -is [System.Windows.Documents.Run]) { $sample = "$($inl.Text)".Trim(); break }
    }
    if (-not $sample) { continue }
    $total++
    $k = '{0}|{1}|{2}' -f $first, $ml, $ti
    if ($combos.ContainsKey($k)) {
        $combos[$k].N++
        if ($combos[$k].Samples.Count -lt 3) { $null = $combos[$k].Samples.Add($sample) }
    } else {
        $sl = New-Object System.Collections.Generic.List[string]
        $null = $sl.Add($sample)
        $combos[$k] = [PSCustomObject]@{ First = $first; ML = $ml; TI = $ti; N = 1; Samples = $sl }
    }
}
Write-Host ('  {0} paragraph(s) with text, in {1} distinct position(s)' -f $total, $combos.Count) -ForegroundColor Gray
Write-Host ''
Write-Host ('  {0,9} {1,9} {2,9} {3,6}  {4}' -f 'firstline','Margin.L','TextInd','count','sample') -ForegroundColor Gray
Write-Host ('  ' + ('-'*74)) -ForegroundColor DarkGray
foreach ($c in ($combos.Values | Sort-Object -Property N -Descending)) {
    $sm = ($c.Samples -join ' / ')
    if ($sm.Length -gt 34) { $sm = $sm.Substring(0,34) + '..' }
    Write-Host ('  {0,9:N1} {1,9:N1} {2,9:N1} {3,6}  {4}' -f $c.First, $c.ML, $c.TI, $c.N, $sm)
}
Write-Host ''
Write-Host '  The most common firstline IS the column. Anything else is either a' -ForegroundColor DarkGray
Write-Host '  list item (TextInd negative, Margin larger by the hang) or drift.' -ForegroundColor DarkGray
exit 0
