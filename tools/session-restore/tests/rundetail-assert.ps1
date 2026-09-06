
# ===========================================================================
# AN OPENED TOOL CALL IS ONE LINE PLUS ITS RESULT.
#
# The complaint this guards: the terminal states a call and its result in about
# two lines; the pane spent six or seven, because the tool NAME sat on its own
# line and the whole argument wrapped underneath it. Measured on the same
# conversation at the same width, two calls and their results ran to FOURTEEN
# lines in the pane and four in the terminal.
#
# Three assertions, and each one can go red on its own:
#
#   A  the tool NAME starts on the text column, whatever the CallKind. It did
#      not: a mark glyph was prepended as an ordinary Run for agent, shell and
#      msgout calls, putting their name at x=90 against x=66 for every other
#      kind. 24px, measured both ways.
#   B  the head line is ONE line - it must not wrap, or the saving is given
#      straight back. Guards TextTrimming/NoWrap being dropped later.
#   C  a whole call panel fits in a small number of LINE HEIGHTS, for a call
#      whose argument is longer than the measure. This is the assertion that
#      actually reads the complaint; A and B are the two ways it could be
#      satisfied dishonestly.
#
# 🪤 LINE HEIGHTS, NEVER PIXELS. The pane zooms; a budget in px would be right
# at 100% and wrong at 125%, which is the shape of defect this file keeps
# finding. Everything below divides by $script:readLead.
#
# 🪤 $ln IS IDENTIFIED BY ITS MARGIN. Add-RunDetail gives every per-call panel
# `Margin 0,0,0,10` and nothing else in the document uses that value. That is a
# construction detail and it is written down here on purpose: if the builder
# stops using it, this suite finds nothing and must say so rather than pass -
# see the zero-panels guard below.
# ===========================================================================
$ErrorActionPreference = 'Continue'
$script:RdFail = 0; $script:RdPass = 0; $script:RdNote = 0
function Rd-Pass { param([string]$T) $script:RdPass++; Write-Host ("  ok    " + $T) }
function Rd-Fail { param([string]$T) $script:RdFail++; Write-Host ("  FAIL  " + $T) -ForegroundColor Red }
function Rd-Note { param([string]$T) $script:RdNote++; Write-Host ("  note  " + $T) -ForegroundColor DarkGray }

$LD = [System.Windows.Documents.LogicalDirection]::Forward
function Rd-ElemX { param($el)
    try { return [double](($el.TransformToAncestor($ui.PaneDoc)).Transform((New-Object System.Windows.Point 0, 0))).X } catch { }
    return $null
}
function Rd-ElemY { param($el)
    try { return [double](($el.TransformToAncestor($ui.PaneDoc)).Transform((New-Object System.Windows.Point 0, 0))).Y } catch { }
    return $null
}
# 🪤 A TextBlock FILLED FROM Inlines DOES NOT RELIABLY ANSWER .Text, and the
# head line is built from Runs now. Reading only .Text found no name at all on
# the rewritten builder and assertion A passed having measured NOTHING - the
# exact vacuous pass this file exists to replace. Fall back to the inlines.
function Rd-Text { param($tb)
    $t = ''
    try { $t = "$($tb.Text)" } catch { }
    if ($t.Trim()) { return $t }
    try { foreach ($i in $tb.Inlines) { if ($i -is [System.Windows.Documents.Run]) { $t += "$($i.Text)" } } } catch { }
    return $t
}
function Rd-Kids { param($el)
    $out = New-Object System.Collections.Generic.List[object]
    $n = 0
    try { $n = [System.Windows.Media.VisualTreeHelper]::GetChildrenCount($el) } catch { $n = 0 }
    for ($k = 0; $k -lt $n; $k++) { $out.Add([System.Windows.Media.VisualTreeHelper]::GetChild($el, $k)) }
    if ($n -eq 0) {
        try { if ($el.Child) { $out.Add($el.Child) } } catch { }
        try { if ($el.Children) { foreach ($c in $el.Children) { $out.Add($c) } } } catch { }
    }
    return $out
}
function Rd-Walk { param($root)
    $out = New-Object System.Collections.Generic.List[object]
    $st = New-Object System.Collections.Generic.Stack[object]
    $st.Push($root)
    $g = 0
    while ($st.Count -and $g -lt 20000) {
        $g++
        $e = $st.Pop()
        $out.Add($e)
        $kk = @(Rd-Kids $e)
        for ($z = $kk.Count - 1; $z -ge 0; $z--) { $st.Push($kk[$z]) }
    }
    return $out
}

# --- build a document with tool calls in it ---------------------------------
$projRoot = Join-Path $env:USERPROFILE '.claude\projects'
$picks = @()
if ($env:SR_RD_JSONL) { $picks = @("$env:SR_RD_JSONL" -split ';' | Where-Object { $_.Trim() }) }
else {
    $byProj = Get-ChildItem -LiteralPath $projRoot -Directory -ErrorAction SilentlyContinue | ForEach-Object {
        Get-ChildItem -LiteralPath $_.FullName -Filter *.jsonl -ErrorAction SilentlyContinue |
            Sort-Object Length -Descending | Select-Object -First 1
    }
    $picks = @($byProj | Sort-Object Length -Descending | Select-Object -First 8 -ExpandProperty FullName)
}

$W = 1480.0; $H = 980.0
$root = $window.Content
$window.Width = $W; $window.Height = $H
function Rd-Layout {
    foreach ($pass in 1, 2) {
        $root.Measure((New-Object System.Windows.Size $W, $H))
        $root.Arrange((New-Object System.Windows.Rect 0, 0, $W, $H))
        $root.UpdateLayout()
        [System.Windows.Threading.Dispatcher]::CurrentDispatcher.Invoke(
            [System.Windows.Threading.DispatcherPriority]::Loaded, [action]{})
    }
}

$script:toolView = 'full'
$panels = New-Object System.Collections.Generic.List[object]
$col = 0.0
foreach ($js in $picks) {
    $blocks = @()
    try { $got = Get-SRTranscriptBlocks -JsonlPath $js -MaxRecords 400 -MaxTailBytes $script:tailBytes; $blocks = @($got) } catch { continue }
    if (-not $blocks.Count) { continue }
    $doc = Build-ReadDocument -Blocks $blocks -Truncated $false -Turns @(Get-ReadTurns $blocks)
    $ui.PaneDoc.Document = $doc
    Rd-Layout
    Set-ReadMeasure -Doc $doc -PadL 44
    Rd-Layout
    $col = [double]$doc.PagePadding.Left + [double]$script:GutterW
    foreach ($b in @($doc.Blocks)) {
        if (-not ($b -is [System.Windows.Documents.BlockUIContainer])) { continue }
        foreach ($e in (Rd-Walk $b.Child)) {
            if (-not ($e -is [System.Windows.Controls.StackPanel])) { continue }
            try {
                if ([Math]::Abs([double]$e.Margin.Bottom - 10.0) -gt 0.01) { continue }
                if ([Math]::Abs([double]$e.Margin.Left) -gt 0.01) { continue }
                if ([Math]::Abs([double]$e.Margin.Top) -gt 0.01) { continue }
            } catch { continue }
            if ($e.ActualHeight -le 0) { continue }
            $panels.Add($e)
        }
    }
}

$lead = [double]$script:readLead
Write-Host ''
Write-Host ("=== {0} per-call panel(s) found, text column x={1:N1}, line height {2:N1}px ===" -f $panels.Count, $col, $lead)
if ($panels.Count -lt 5) {
    # 🔴 A SUITE THAT FINDS NOTHING MUST SAY SO. If Add-RunDetail stops using
    # Margin 0,0,0,10 this walk collects zero panels and every assertion below
    # passes vacuously - which is the exact shape of the check this file was
    # written to replace.
    Rd-Fail ("only {0} per-call panel(s) found - the walk cannot see them, so nothing below is evidence" -f $panels.Count)
    Write-Host ("{0} ok, {1} FAIL, {2} note" -f $script:RdPass, $script:RdFail, $script:RdNote)
    exit 1
}

# --- A: the tool name starts on the text column -----------------------------
$badX = @{}
$okX = 0
foreach ($p in $panels) {
    # the head is the first horizontal StackPanel in the panel; the NAME is the
    # first text in it with more than one character - a one-glyph child is a
    # marker, and a marker is exactly what must not be pushing the name right.
    $head = @(Rd-Walk $p | Where-Object { $_ -is [System.Windows.Controls.StackPanel] -and "$($_.Orientation)" -eq 'Horizontal' })
    if (-not $head.Count) { continue }
    $tb = @(Rd-Walk $head[0] | Where-Object { $_ -is [System.Windows.Controls.TextBlock] -and (Rd-Text $_).Trim().Length -gt 1 })
    if (-not $tb.Count) { continue }
    $x = Rd-ElemX $tb[0]
    if ($null -eq $x) { continue }
    if ([Math]::Abs($x - $col) -le 1.5) { $okX++ }
    else {
        $k = ('x={0:N1} expected {1:N1}' -f $x, $col)
        if (-not $badX.ContainsKey($k)) { $badX[$k] = @{ N = 0; S = (Rd-Text $tb[0]) } }
        $badX[$k].N++
    }
}
if ($badX.Count -eq 0 -and $okX -lt 5) {
    # 🔴 A PASS THAT MEASURED NOTHING IS A FAILURE. This reported "every tool
    # name starts on the text column (0 calls)" against the rewritten builder
    # and would have certified it on no evidence whatever.
    Rd-Fail ("A: only {0} tool name(s) could be located in {1} panel(s) - the walk cannot see them, so this is not evidence" -f $okX, $panels.Count)
}
elseif ($badX.Count -eq 0) { Rd-Pass ("A: every tool name starts on the text column ({0} calls)" -f $okX) }
else {
    foreach ($k in ($badX.Keys | Sort-Object { -$badX[$_].N })) {
        Rd-Fail ('A: a tool name is off the text column - {0}  x{1}  e.g. "{2}"' -f $k, $badX[$k].N, $badX[$k].S)
    }
}

# --- B: the head line does not wrap -----------------------------------------
$wrapHead = 0
foreach ($p in $panels) {
    $head = @(Rd-Walk $p | Where-Object { $_ -is [System.Windows.Controls.StackPanel] -and "$($_.Orientation)" -eq 'Horizontal' })
    if (-not $head.Count) { continue }
    if ($head[0].ActualHeight -gt ($lead * 1.5)) { $wrapHead++ }
}
if ($wrapHead -eq 0) { Rd-Pass ("B: every call's head line is a single line ({0} calls)" -f $panels.Count) }
else { Rd-Fail ("B: {0} of {1} head lines wrap to more than one line - the name and argument are not fitting on one" -f $wrapHead, $panels.Count) }

# --- C: how much height a call spends BEFORE showing what came back ---------
# 🔴 THE FIRST VERSION OF THIS MEASURED THE WHOLE PANEL AND COULD NEVER GO
# GREEN. A call panel is dominated by its RESULT, which New-BoundedText caps at
# $script:FoldMaxHeight = 460px - about 22 line heights - so every call
# "exceeded" any budget worth setting and the assertion was measuring a
# deliberate bound rather than the defect. What this change touches is the
# space between the top of the call and the top of its result: the name line
# and the argument under it. That is what is measured now.
# 🔑 THREE, NOT TWO, AND THE NUMBER IS MEASURED. Before this change the median
# call spent 13.37 line heights before its result and the worst spent 38.52;
# after it, the worst is 2.23 - a head line plus the description some kinds
# carry. Two would have gone red on a correct render by 0.23 of a line, which
# is a budget tuned to nothing. Three sits clear of both.
$BUDGET = 3.0
$pre = New-Object System.Collections.Generic.List[double]
$tall = New-Object System.Collections.Generic.List[double]
$noRes = 0
foreach ($p in $panels) {
    $py = Rd-ElemY $p
    if ($null -eq $py) { continue }
    # the result is the nested Grid whose first column is one gutter wide -
    # the same construction the alignment sweep keys on
    $rg = @(Rd-Walk $p | Where-Object {
        $_ -is [System.Windows.Controls.Grid] -and $_.ColumnDefinitions.Count -ge 2 -and
        ([Math]::Abs([double]$_.ColumnDefinitions[0].Width.Value - [double]$script:GutterW) -lt 0.51) })
    if (-not $rg.Count) { $noRes++; continue }
    $gy = Rd-ElemY $rg[0]
    if ($null -eq $gy) { continue }
    $h = ($gy - $py) / $lead
    $pre.Add($h)
    if ($h -gt $BUDGET) { $tall.Add($h) }
}
if ($pre.Count -lt 3) {
    Rd-Fail ("C: only {0} call(s) had a result to measure against - not evidence" -f $pre.Count)
} else {
    $st = $pre | Measure-Object -Average -Maximum -Minimum
    Write-Host ("      head-to-result height in line heights: median {0:N2}, mean {1:N2}, max {2:N2}  ({3} call(s) with no result, skipped)" -f `
        (@($pre | Sort-Object)[[int]($pre.Count / 2)]), $st.Average, $st.Maximum, $noRes)
    if ($tall.Count -eq 0) {
        Rd-Pass ("C: every call reaches its result within {0:N0} line heights ({1} calls, worst {2:N2})" -f $BUDGET, $pre.Count, $st.Maximum)
    } else {
        Rd-Fail ("C: {0} of {1} calls spend more than {2:N0} line heights before their result - worst {3:N2}, mean of the offenders {4:N2}" -f `
            $tall.Count, $pre.Count, $BUDGET, $st.Maximum, ($tall | Measure-Object -Average).Average)
    }
}

Write-Host ''
Write-Host ("{0} ok, {1} FAIL, {2} note" -f $script:RdPass, $script:RdFail, $script:RdNote)
exit $(if ($script:RdFail) { 1 } else { 0 })
