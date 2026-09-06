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
# real arrange pass and returns Infinity without one, even after Measure/Arrange
# on the window. Where a paragraph's first line starts is Margin.Left +
# TextIndent, which is on the object before anything is drawn.
#
# 🔴 AND THE QUESTION NOW IS A CONTRADICTION, NOT A POSITION. The suite reports
# blocks carrying margin 64,7 and indent -24,7 - the list shape exactly, 22
# gutter + 18 bump + 24,7 hang - whose FIRST RUN CARRIES NO MARKER. Add-ReadProse
# bakes the marker into the body text before it emits anything, so those two
# cannot both be true. This prints every inline of every paragraph that is not
# on the modal position, which settles it without another round of inference.
$combos = @{}
foreach ($blk in $doc.Blocks) {
    if ($blk -isnot [System.Windows.Documents.Paragraph]) { continue }
    $k = '{0}|{1}' -f [Math]::Round([double]$blk.Margin.Left,1), [Math]::Round([double]$blk.TextIndent,1)
    if ($combos.ContainsKey($k)) { $combos[$k]++ } else { $combos[$k] = 1 }
}
$modal = ($combos.GetEnumerator() | Sort-Object -Property Value -Descending | Select-Object -First 1).Key
Write-Host ("  positions: {0}   modal: {1}" -f (($combos.GetEnumerator() | ForEach-Object { '{0}x{1}' -f $_.Value, $_.Key }) -join '  '), $modal) -ForegroundColor Gray
Write-Host ''

$shown = 0
foreach ($blk in $doc.Blocks) {
    if ($blk -isnot [System.Windows.Documents.Paragraph]) { continue }
    $ml = [Math]::Round([double]$blk.Margin.Left,1); $ti = [Math]::Round([double]$blk.TextIndent,1)
    $k = '{0}|{1}' -f $ml, $ti
    if ($k -eq $modal) { continue }
    $inls = @($blk.Inlines)
    if (-not $inls.Count) { continue }
    if ($shown -ge 6) { break }
    $shown++
    Write-Host ("  --- margin {0} indent {1}  ({2} inline(s)) ---" -f $ml, $ti, $inls.Count) -ForegroundColor Yellow
    $q = 0
    foreach ($ii in $inls) {
        $q++
        $tt = ''
        if ($ii -is [System.Windows.Documents.Run]) { $tt = "$($ii.Text)" }
        # 🪤 THE MARKER IS A SPACE-PADDED PREFIX, so a trimmed print would hide
        # exactly the thing being looked for. Delimited, untrimmed.
        if ($tt.Length -gt 40) { $tt = $tt.Substring(0,40) + '...' }
        Write-Host ("      {0}: {1,-22} <{2}>" -f $q, $ii.GetType().Name, $tt)
    }
}
if (-not $shown) { Write-Host '  every paragraph is on the modal position in this parse' -ForegroundColor Green }
exit 0
