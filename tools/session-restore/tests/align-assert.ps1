
# ===========================================================================
# EVERY BLOCK STARTS ON THE TEXT COLUMN, OR IT IS ON A NAMED LIST.
#
# 🔴 THE CHECK THIS REPLACES COULD NOT GO RED. gui2-driver took the FIRST
# prose paragraph and the FIRST rail block and compared those two - and both
# are on the column by construction, so it passed while 14.5% of the blocks in
# the operator's own view drifted. A check that cannot fail is worse than no
# check, because it reads as coverage.
#
# This walks EVERY measurable block and every text element inside every rail
# block. What is allowed to sit off the column is a TABLE OF EXACT (kind,
# shape) PAIRS, not a pattern: a block kind that did not exist when the table
# was written has no row and FAILS, which is the whole point. Nesting offsets
# inside a rail block are derived from the actual ancestor chain - a Grid whose
# first column is one gutter wide, or a panel inset by one gutter - so a new
# nesting that is neither of those also fails.
#
# 🪤 AND AN ALLOWANCE THAT MATCHES NOTHING IS ITSELF A FAILURE. An exemption
# whose kind is still in the document but which no longer matches any block has
# stopped firing, and this file's history is full of checks that quietly
# stopped firing. It goes red rather than being carried forward.
# ===========================================================================
$ErrorActionPreference = 'Continue'
$script:AsFail = 0; $script:AsPass = 0; $script:AsNote = 0
function As-Pass { param([string]$T) $script:AsPass++; Write-Host ("  ok    " + $T) }
function As-Fail { param([string]$T) $script:AsFail++; Write-Host ("  FAIL  " + $T) -ForegroundColor Red }
function As-Note { param([string]$T) $script:AsNote++; Write-Host ("  note  " + $T) -ForegroundColor DarkGray }

# ===========================================================================
# THE ALLOWANCE TABLE. Exact strings, no wildcards, no regex.
#   Kind  - the builder that made the block, from the wrappers below
#   Shape - '', 'bullet', 'numbered' or 'semibold'
#   Off   - symbolic, so it survives a zoom change:
#           '0' | '+gutter' | '-gutter' | '+bump'
# ===========================================================================
$SR_ColumnAllow = @(
    @{ Kind = 'rule';        Shape = '';         Off = '-gutter'
       Why = 'the turn rule is full-bleed from the page padding, one gutter left of all text - deliberate, it is a divider and not a line of text' }
    @{ Kind = 'prose:you';   Shape = 'bullet';   Off = '+bump'
       Why = 'a list is indented as a block by $bump; the block indent is a reason, the ragged wrap inside it is not (checked separately below)' }
    @{ Kind = 'prose:you';   Shape = 'numbered'; Off = '+bump'; Why = 'as above' }
    @{ Kind = 'prose:said';  Shape = 'bullet';   Off = '+bump'; Why = 'as above' }
    @{ Kind = 'prose:said';  Shape = 'numbered'; Off = '+bump'; Why = 'as above' }
    @{ Kind = 'prose:msgin'; Shape = 'bullet';   Off = '+bump'; Why = 'as above' }
    @{ Kind = 'prose:msgin'; Shape = 'numbered'; Off = '+bump'; Why = 'as above' }
)
# $bump is Add-ReadProse's list indent. Named here so the allowance moves with
# it rather than carrying a copy that can drift - this file has been bitten by
# a number written down twice more than once.
$SR_ListBump = 18.0

# --- the builder wrappers, so every block knows what made it ----------------
$script:AS_Rail  = ${function:New-RailBlock}
$script:AS_Gut   = ${function:New-GutterPara}
$script:AS_Prose = ${function:Add-ReadProse}
$script:AS_Label = ${function:Add-ReadLabel}
$script:AS_Rule  = ${function:Add-ReadRule}
function New-RailBlock {
    param($Child, [string]$Kind, [double]$Top = 8, [double]$Bottom = 8,
          [double]$Indent = 0, [switch]$Rail, $Brush)
    $b = & $script:AS_Rail -Child $Child -Kind $Kind -Top $Top -Bottom $Bottom -Indent $Indent -Rail:$Rail -Brush $Brush
    try { $b.Tag = ('rail:{0}' -f $Kind) } catch { }
    return $b
}
function New-GutterPara {
    param([string]$Kind, [double]$Top = 0, [double]$Bottom = 0, [double]$Indent = 0,
          [double]$Line = 0, [switch]$NoMark)
    $p = & $script:AS_Gut -Kind $Kind -Top $Top -Bottom $Bottom -Indent $Indent -Line $Line -NoMark:$NoMark
    try { $p.Tag = ('gutterpara:{0}' -f $Kind) } catch { }
    return $p
}
function Add-ReadProse {
    param($Doc, [string]$Text, $Brush, [double]$Size = 0, [double]$Line = 0,
          [double]$Indent = 0, [string]$Kind = '', $Ground = $null)
    $n0 = $Doc.Blocks.Count
    & $script:AS_Prose -Doc $Doc -Text $Text -Brush $Brush -Size $Size -Line $Line -Indent $Indent -Kind $Kind -Ground $Ground
    $i = 0
    foreach ($b in @($Doc.Blocks)) { if ($i -ge $n0 -and -not $b.Tag) { try { $b.Tag = ('prose:{0}' -f $Kind) } catch { } }; $i++ }
}
function Add-ReadLabel {
    param($Doc, [string]$Text, $Brush, [string]$Trailing = '', $TrailBrush, $When,
          [double]$Size = 0, [double]$Top = 20, [double]$Bottom = 5)
    $n0 = $Doc.Blocks.Count
    & $script:AS_Label -Doc $Doc -Text $Text -Brush $Brush -Trailing $Trailing -TrailBrush $TrailBrush -When $When -Size $Size -Top $Top -Bottom $Bottom
    $i = 0
    foreach ($b in @($Doc.Blocks)) { if ($i -ge $n0 -and -not $b.Tag) { try { $b.Tag = 'label:speaker' } catch { } }; $i++ }
}
function Add-ReadRule {
    param($Doc, $Brush, [double]$Top = 26, [double]$Bottom = 0, [double]$Height = 1)
    $n0 = $Doc.Blocks.Count
    & $script:AS_Rule -Doc $Doc -Brush $Brush -Top $Top -Bottom $Bottom -Height $Height
    $i = 0
    foreach ($b in @($Doc.Blocks)) { if ($i -ge $n0 -and -not $b.Tag) { try { $b.Tag = 'rule' } catch { } }; $i++ }
}

# --- geometry ---------------------------------------------------------------
$LD = [System.Windows.Documents.LogicalDirection]::Forward
function As-RectX { param($ptr) try { return [double]($ptr.GetCharacterRect($LD)).X } catch { } ; return $null }
function As-ElemX { param($el)
    try { return [double](($el.TransformToAncestor($ui.PaneDoc)).Transform((New-Object System.Windows.Point 0, 0))).X } catch { }
    return $null
}
function As-Kids { param($el)
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
# Every word-bearing TextBlock under a rail block, with the nesting offset the
# CONSTRUCTION justifies and whether it is an inline continuation of a line
# that has already been checked.
function As-RailText { param($root, [double]$Gutter)
    $out = New-Object System.Collections.Generic.List[object]
    $stack = New-Object System.Collections.Generic.Stack[object]
    $stack.Push(@{ E = $root; Off = 0.0; Line = $null })
    $seenLine = @{}
    $guard = 0
    while ($stack.Count -and $guard -lt 8000) {
        $guard++
        $it = $stack.Pop(); $e = $it.E; $off = [double]$it.Off; $line = $it.Line
        if ($e -is [System.Windows.Controls.TextBlock]) {
            if ("$($e.Text)".Trim().Length -gt 1) {
                $inline = $false
                if ($line) {
                    $lk = $line.GetHashCode()
                    if ($seenLine.ContainsKey($lk)) { $inline = $true } else { $seenLine[$lk] = $true }
                }
                $out.Add([PSCustomObject]@{ El = $e; Off = $off; Inline = $inline; T = "$($e.Text)" })
            }
            continue
        }
        $kidOff = $off
        # A Grid whose first column is exactly one gutter is the nested marker
        # column Add-RunDetail builds for a result: content in column 1 is one
        # gutter in, by the same construction the top-level rail block uses.
        if ($e -is [System.Windows.Controls.Grid] -and $e.ColumnDefinitions.Count -ge 2) {
            try { if ([Math]::Abs([double]$e.ColumnDefinitions[0].Width.Value - $Gutter) -lt 0.51) { $kidOff = $off + $Gutter } } catch { }
        }
        # A panel inset by exactly one gutter is the same column, expressed as
        # a margin instead of a grid (the background-shell output panel).
        if ($e -is [System.Windows.FrameworkElement]) {
            try { if ([Math]::Abs([double]$e.Margin.Left - $Gutter) -lt 0.51) { $kidOff = $kidOff + $Gutter } } catch { }
        }
        $lineNext = $line
        if ($e -is [System.Windows.Controls.StackPanel] -and "$($e.Orientation)" -eq 'Horizontal') { $lineNext = $e }
        # 🪤 PUSHED IN REVERSE SO THEY POP IN DOCUMENT ORDER. A stack walked
        # forwards visits the LAST child first, which made the trailing summary
        # of a fold header the "first" element of its line and the caption the
        # continuation - so the check was aimed at exactly the wrong one.
        $kk = @(As-Kids $e)
        for ($z = $kk.Count - 1; $z -ge 0; $z--) { $stack.Push(@{ E = $kk[$z]; Off = $kidOff; Line = $lineNext }) }
    }
    return $out
}

# --- the document -----------------------------------------------------------
$projRoot = Join-Path $env:USERPROFILE '.claude\projects'
$n = 6; if ($env:SR_AS_N) { $n = [int]$env:SR_AS_N }
$byProj = Get-ChildItem -LiteralPath $projRoot -Directory -ErrorAction SilentlyContinue | ForEach-Object {
    Get-ChildItem -LiteralPath $_.FullName -Filter *.jsonl -ErrorAction SilentlyContinue |
        Sort-Object Length -Descending | Select-Object -First 1
}
$picks = @($byProj | Sort-Object Length -Descending | Select-Object -First $n -ExpandProperty FullName)
$modes = @('hidden', 'folded', 'full')
if ($env:SR_AS_STEPS) { $modes = @("$env:SR_AS_STEPS" -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ }) }

$W = 1480.0; $H = 980.0
$root = $window.Content
$window.Width = $W; $window.Height = $H
function As-Layout {
    foreach ($pass in 1, 2) {
        $root.Measure((New-Object System.Windows.Size $W, $H))
        $root.Arrange((New-Object System.Windows.Rect 0, 0, $W, $H))
        $root.UpdateLayout()
        [System.Windows.Threading.Dispatcher]::CurrentDispatcher.Invoke(
            [System.Windows.Threading.DispatcherPriority]::Loaded, [action]{})
    }
}

# offending blocks and matched allowances, accumulated across every document
$offend = @{}
$allowHit = @{}
$kindSeen = @{}
$pairSeen = @{}
$wrapBad = @{}
$wrapList = 0
$script:srcIndentN = 0
$measured = 0; $blocksTotal = 0

foreach ($js in $picks) {
    $blocks = @()
    try { $got = Get-SRTranscriptBlocks -JsonlPath $js -MaxRecords 400 -MaxTailBytes $script:tailBytes; $blocks = @($got) } catch { continue }
    if (-not $blocks.Count) { continue }
    # 🔴 THE REAL TRUNCATION FLAG. Passing $false here drew no 'load earlier'
    # control at all, so the one block this check most needed to see was not in
    # any document it measured - a check that cannot fail, inside the check
    # written to replace a check that could not fail.
    $trunc = $false
    try { $trunc = ((Get-Item -LiteralPath $js).Length -gt $script:tailBytes) } catch { }
    foreach ($m in $modes) {
        $script:toolView = $m
        $doc = Build-ReadDocument -Blocks $blocks -Truncated $trunc -Turns @(Get-ReadTurns $blocks)
        $ui.PaneDoc.Document = $doc
        As-Layout
        Set-ReadMeasure -Doc $doc -PadL 44
        As-Layout

        $col = [double]$doc.PagePadding.Left + [double]$script:GutterW
        $gut = [double]$script:GutterW
        # 🪤 A RAIL BLOCK'S OWN GRID IS ALREADY ONE GUTTER. Counting nesting
        # from the text column double-counted it and expected every fold
        # caption at 88. Nesting is counted from the PAGE PADDING, and the
        # outer grid earns the first gutter like any other.
        $railBase = [double]$doc.PagePadding.Left
        foreach ($b in @($doc.Blocks)) {
            $blocksTotal++
            $kind = "$($b.Tag)"; if (-not $kind) { $kind = '(untagged)' }
            $shape = ''
            $x = $null; $sample = ''
            $srcIndent = $false
            if ($b -is [System.Windows.Documents.Paragraph]) {
                # 🪤 THE WHOLE PARAGRAPH, NOT ITS FIRST RUN. Inline code and bold
                # split the text into several Runs, so a numbered item's first
                # Run is often just '1.   ' and the shape test missed it - which
                # showed up as fifteen unexplained blocks at x=84.
                $whole = ''
                foreach ($inl in @($b.Inlines)) {
                    if ($inl -is [System.Windows.Documents.Run]) { $whole += "$($inl.Text)" }
                }
                foreach ($inl in @($b.Inlines)) {
                    if ($inl -is [System.Windows.Documents.Run] -and "$($inl.Text)".Trim().Length -ge 1) {
                        $x = As-RectX $inl.ContentStart
                        if ("$($inl.FontWeight)" -eq 'SemiBold') { $shape = 'semibold' }
                        break
                    }
                }
                $sample = $whole.Trim()
                # 🪤 THE PARAGRAPH'S OWN FIRST CHARACTER, NOT ITS FIRST VISIBLE
                # RUN. A line that starts with spaces and then inline `code`
                # splits into a whitespace Run and a code Run; testing the first
                # NON-BLANK run therefore never saw the spaces, and twelve
                # source-indented lines came out as unexplained failures at
                # x=72 and x=75. A source line that begins with its own spaces
                # starts wherever those spaces end - a property of what was
                # typed, not of the layout. Recorded, never asserted.
                if ($whole -match '^\s') { $srcIndent = $true }
                if ($sample.StartsWith([string][char]0x2022)) { $shape = 'bullet' }
                elseif ($sample -match '^\d+\.\s') { $shape = 'numbered' }
            } elseif ($b -is [System.Windows.Documents.BlockUIContainer]) {
                $tx = @(As-RailText $b.Child $gut)
                foreach ($t in $tx) {
                    if ($t.Inline) { continue }
                    $ex = $railBase + [double]$t.Off
                    $ax = As-ElemX $t.El
                    if ($null -eq $ax) { continue }
                    $measured++
                    if ([Math]::Abs($ax - $ex) -gt 1.5) {
                        $k = ('{0}  [inside]  x={1:N1} expected {2:N1}' -f $kind, $ax, $ex)
                        if (-not $offend.ContainsKey($k)) { $offend[$k] = @{ N = 0; S = "$($t.T)" } }
                        $offend[$k].N++
                    }
                }
                # the caption is the block's own first line; it carries the kind
                $first = @($tx | Where-Object { -not $_.Inline })
                if ($first.Count) { $x = As-ElemX $first[0].El; $sample = "$($first[0].T)" }
                # 🪤 A RULE CARRIES NO TEXT AT ALL, so measuring only word-bearing
                # elements left it unmeasured - and its own allowance then read as
                # "stopped firing". The block's child is the thing on screen.
                else { $x = As-ElemX $b.Child; $sample = '(no text - a rule or a spacer)' }
                # 🪤 AND DO NOT REPORT THE CAPTION TWICE. When the walk above
                # found words, that same element has already been judged against
                # its nesting; repeating it at block level printed every rail
                # defect on two lines with two different explanations.
                if ($first.Count) { $x = $null }
            }
            $kindSeen[$kind] = $true
            if ($null -eq $x) { continue }
            if ($b -is [System.Windows.Documents.Paragraph]) { $measured++ }

            $pairSeen[($kind + '|' + $shape)] = $true
            if ($srcIndent) { $script:srcIndentN++; continue }
            $allow = @($SR_ColumnAllow | Where-Object { $_.Kind -eq $kind -and $_.Shape -eq $shape })
            $expect = $col
            if ($allow.Count) {
                switch ($allow[0].Off) {
                    '+gutter' { $expect = $col + $gut }
                    '-gutter' { $expect = $col - $gut }
                    '+bump'   { $expect = $col + $SR_ListBump }
                    default   { $expect = $col }
                }
            }
            if ([Math]::Abs($x - $expect) -le 1.5) {
                if ($allow.Count) { $allowHit[($allow[0].Kind + '|' + $allow[0].Shape)] = $true }
            } else {
                $k = ('{0}|{1}|x={2:N1}|expected {3:N1}' -f $kind, $shape, $x, $expect)
                if (-not $offend.ContainsKey($k)) { $offend[$k] = @{ N = 0; S = $sample } }
                $offend[$k].N++
            }

            # --- the hanging indent, for anything that wraps -----------------
            if ($b -is [System.Windows.Documents.Paragraph]) {
                $xs = New-Object System.Collections.Generic.List[double]
                $tp = $null
                try { $tp = $b.ContentStart.GetLineStartPosition(0) } catch { }
                $g2 = 0
                while ($tp -and $g2 -lt 300) {
                    $g2++
                    $lx = As-RectX $tp
                    if ($null -ne $lx) { $xs.Add([double]$lx) }
                    $nx = $null
                    try { $nx = $tp.GetLineStartPosition(1) } catch { }
                    if (-not $nx) { break }
                    if ($nx.CompareTo($tp) -le 0) { break }
                    if ($nx.CompareTo($b.ContentEnd) -ge 0) { break }
                    $tp = $nx
                }
                if ($xs.Count -ge 2) {
                    if ($shape -eq 'bullet' -or $shape -eq 'numbered') { $wrapList++ }
                    $x2 = ($xs[1..($xs.Count - 1)] | Measure-Object -Minimum).Minimum
                    if ([Math]::Abs($x2 - $expect) -gt 1.5) {
                        $k = ('{0}|{1}|wrap x={2:N1}|expected {3:N1}' -f $kind, $shape, $x2, $expect)
                        if (-not $wrapBad.ContainsKey($k)) { $wrapBad[$k] = @{ N = 0; S = $sample } }
                        $wrapBad[$k].N++
                    }
                }
            }
        }
    }
}

Write-Host ''
Write-Host ("=== every block on the text column ({0} blocks, {1} measurable text positions) ===" -f $blocksTotal, $measured)
if ($offend.Count -eq 0) {
    As-Pass ('every measurable block starts on the text column or on a named allowance')
} else {
    foreach ($k in ($offend.Keys | Sort-Object { -$offend[$_].N })) {
        As-Fail ('{0}  x{1}   e.g. "{2}"' -f $k, $offend[$k].N, $offend[$k].S)
    }
}
Write-Host ''
Write-Host '=== wrapped lines land on the same column as the first ================='
if ($wrapBad.Count -eq 0) {
    As-Pass 'every wrapped paragraph continues on its own column'
} else {
    foreach ($k in ($wrapBad.Keys | Sort-Object { -$wrapBad[$_].N })) {
        As-Fail ('{0}  x{1}   e.g. "{2}"' -f $k, $wrapBad[$k].N, $wrapBad[$k].S)
    }
}
Write-Host ''
Write-Host '=== every allowance still describes something =========================='
# 🔴 AN ALLOWANCE IS DEAD WHEN ITS SITUATION OCCURRED AND IT WAS NOT NEEDED -
# that means the offset it excuses has gone and the row is now hiding whatever
# replaces it. It is NOT dead merely because this sample contained no example;
# one sample cannot tell "no longer possible" from "not here today", and
# failing on that would be a check that goes red for the wrong reason.
foreach ($a in $SR_ColumnAllow) {
    $key = ($a.Kind + '|' + $a.Shape)
    if ($allowHit.ContainsKey($key)) { As-Pass ('allowance in use: {0} {1} {2}' -f $a.Kind, $a.Shape, $a.Off) }
    elseif ($pairSeen.ContainsKey($key)) {
        As-Fail ('the allowance for "{0}" shape "{1}" was never needed although that exact shape IS in the document - the offset it excuses is gone, so delete the row rather than carry it' -f $a.Kind, $a.Shape)
    } else {
        As-Note ('allowance for "{0}" shape "{1}" not exercised - that shape does not occur in this sample' -f $a.Kind, $a.Shape)
    }
}
if ($script:srcIndentN) {
    As-Note ('{0} paragraph(s) skipped: the source line begins with its own spaces, so where the text starts is a property of what was typed. Reported by tests\align-driver.ps1, not assertable here.' -f $script:srcIndentN)
}
if ($wrapList) {
    As-Note ('{0} wrapped list item(s) could NOT be checked for a hanging indent: the bullet or number is still baked into the text Run, so the wrap and the marker share an x and this check cannot tell them apart. It becomes meaningful the moment the marker is hoisted into a fixed-width box.' -f $wrapList)
}
Write-Host ''
Write-Host ("{0} ok, {1} FAIL, {2} note" -f $script:AsPass, $script:AsFail, $script:AsNote)
exit $(if ($script:AsFail) { 1 } else { 0 })
