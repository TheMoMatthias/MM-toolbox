
# ===========================================================================
# WHERE EVERY BLOCK KIND ACTUALLY STARTS, IN PIXELS.
#
# The reading pane's whole construction rests on one claim: every block kind
# begins its text on the same x. gui2 checks that claim for exactly TWO kinds -
# the FIRST prose paragraph it finds and the FIRST rail block - and passes.
# This measures EVERY block of EVERY kind across several real transcripts,
# labelled by the builder that made it, so a kind that is 18px out cannot hide
# behind a kind that is not.
#
# It never edits lib\. It wraps five builders in the driver's own scope so each
# block carries the name of what made it, then reads the RENDERED geometry back
# off the laid-out document.
#
#   SR_AL_JSONL=<p1;p2>   measure these transcripts instead of auto-picking
#   SR_AL_N=8             how many transcripts to auto-pick
#   SR_AL_SIZE=1480x980   window size for the alignment table
#   SR_AL_STEPS=full      one step mode only (default: folded AND full)
#   SR_AL_WIDTHS=...      widths for the measure sweep
# ===========================================================================
$ErrorActionPreference = 'Continue'
function AL-Say { param([string]$T) Write-Host $T }

# --- which transcripts ------------------------------------------------------
$projRoot = Join-Path $env:USERPROFILE '.claude\projects'
$picks = @()
if ($env:SR_AL_JSONL) {
    $picks = @("$env:SR_AL_JSONL" -split ';' | Where-Object { $_.Trim() })
} else {
    $n = 8; if ($env:SR_AL_N) { $n = [int]$env:SR_AL_N }
    # One per PROJECT, biggest first: several conversations from one project
    # would draw the same handful of block kinds over and over.
    $byProj = Get-ChildItem -LiteralPath $projRoot -Directory -ErrorAction SilentlyContinue | ForEach-Object {
        Get-ChildItem -LiteralPath $_.FullName -Filter *.jsonl -ErrorAction SilentlyContinue |
            Sort-Object Length -Descending | Select-Object -First 1
    }
    $picks = @($byProj | Sort-Object Length -Descending | Select-Object -First $n -ExpandProperty FullName)
}
if (-not $picks.Count) { AL-Say 'FAIL  no transcript found'; exit 1 }

AL-Say ("zoom={0}  GutterW={1}  PaneSize={2}  readLead={3}  readWidth={4}" -f `
    $script:Zoom, $script:GutterW, $script:PaneSize, $script:readLead, $script:readWidth)
AL-Say ("ProseFace={0}   PaneFace={1}" -f $script:ProseFace.Source, $script:PaneFace.Source)
AL-Say ("MonoFace={0}   UiFace={1}" -f $script:MonoFace.Source, $script:UiFace.Source)
AL-Say ("PaneAdvanceEm={0:N4}  ReadMeasureChars={1}  hasManrope={2}  hasPlex={3}" -f `
    $script:PaneAdvanceEm, $script:ReadMeasureChars, $script:hasManrope, $script:hasPlex)

# ===========================================================================
# THE BUILDERS, WRAPPED SO EVERY BLOCK CARRIES ITS PROVENANCE.
# Paragraph and BlockUIContainer both descend from FrameworkContentElement, so
# .Tag is a real property on each. The originals are captured FIRST - a wrapper
# that re-entered itself would recurse forever.
# ===========================================================================
$script:AL_Rail  = ${function:New-RailBlock}
$script:AL_Gut   = ${function:New-GutterPara}
$script:AL_Prose = ${function:Add-ReadProse}
$script:AL_Label = ${function:Add-ReadLabel}
$script:AL_Rule  = ${function:Add-ReadRule}

function New-RailBlock {
    param($Child, [string]$Kind, [double]$Top = 8, [double]$Bottom = 8,
          [double]$Indent = 0, [switch]$Rail, $Brush)
    $b = & $script:AL_Rail -Child $Child -Kind $Kind -Top $Top -Bottom $Bottom `
                           -Indent $Indent -Rail:$Rail -Brush $Brush
    try { $b.Tag = ('rail:{0}' -f $Kind) } catch { }
    return $b
}
function New-GutterPara {
    param([string]$Kind, [double]$Top = 0, [double]$Bottom = 0, [double]$Indent = 0,
          [double]$Line = 0, [switch]$NoMark)
    $p = & $script:AL_Gut -Kind $Kind -Top $Top -Bottom $Bottom -Indent $Indent -Line $Line -NoMark:$NoMark
    try { $p.Tag = ('gutterpara:{0}' -f $Kind) } catch { }
    return $p
}
function Add-ReadProse {
    param($Doc, [string]$Text, $Brush, [double]$Size = 0, [double]$Line = 0,
          [double]$Indent = 0, [string]$Kind = '', $Ground = $null)
    $n0 = $Doc.Blocks.Count
    & $script:AL_Prose -Doc $Doc -Text $Text -Brush $Brush -Size $Size -Line $Line `
                       -Indent $Indent -Kind $Kind -Ground $Ground
    $i = 0
    foreach ($b in @($Doc.Blocks)) {
        if ($i -ge $n0 -and -not $b.Tag) { try { $b.Tag = ('prose:{0}' -f $Kind) } catch { } }
        $i++
    }
}
function Add-ReadLabel {
    param($Doc, [string]$Text, $Brush, [string]$Trailing = '', $TrailBrush, $When,
          [double]$Size = 0, [double]$Top = 20, [double]$Bottom = 5)
    $n0 = $Doc.Blocks.Count
    & $script:AL_Label -Doc $Doc -Text $Text -Brush $Brush -Trailing $Trailing `
                       -TrailBrush $TrailBrush -When $When -Size $Size -Top $Top -Bottom $Bottom
    $i = 0
    foreach ($b in @($Doc.Blocks)) { if ($i -ge $n0 -and -not $b.Tag) { try { $b.Tag = 'label:speaker' } catch { } }; $i++ }
}
function Add-ReadRule {
    param($Doc, $Brush, [double]$Top = 26, [double]$Bottom = 0, [double]$Height = 1)
    $n0 = $Doc.Blocks.Count
    & $script:AL_Rule -Doc $Doc -Brush $Brush -Top $Top -Bottom $Bottom -Height $Height
    $i = 0
    foreach ($b in @($Doc.Blocks)) { if ($i -ge $n0 -and -not $b.Tag) { try { $b.Tag = 'rule' } catch { } }; $i++ }
}

# --- layout helpers ---------------------------------------------------------
$W = 1480.0; $H = 980.0
if ($env:SR_AL_SIZE -and $env:SR_AL_SIZE -match '^(\d+)x(\d+)$') { $W = [double]$Matches[1]; $H = [double]$Matches[2] }
$root = $window.Content
function AL-Layout {
    foreach ($pass in 1, 2) {
        $root.Measure((New-Object System.Windows.Size $script:W, $script:H))
        $root.Arrange((New-Object System.Windows.Rect 0, 0, $script:W, $script:H))
        $root.UpdateLayout()
        [System.Windows.Threading.Dispatcher]::CurrentDispatcher.Invoke(
            [System.Windows.Threading.DispatcherPriority]::Loaded, [action]{})
    }
}
$script:W = $W; $script:H = $H
$window.Width = $W; $window.Height = $H

$LD = [System.Windows.Documents.LogicalDirection]::Forward
function AL-RectX { param($ptr)
    try { $r = $ptr.GetCharacterRect($LD); return [double]$r.X } catch { }
    return $null
}
function AL-ElemX { param($el)
    try { return [double](($el.TransformToAncestor($ui.PaneDoc)).Transform((New-Object System.Windows.Point 0, 0))).X } catch { }
    return $null
}
function AL-TextBlocks { param($el)
    $out = New-Object System.Collections.Generic.List[object]
    $st = New-Object System.Collections.Generic.Stack[object]
    $st.Push($el)
    $guard = 0
    while ($st.Count -and $guard -lt 8000) {
        $guard++
        $e = $st.Pop()
        if ($e -is [System.Windows.Controls.TextBlock]) { $out.Add($e); continue }
        $n = 0
        try { $n = [System.Windows.Media.VisualTreeHelper]::GetChildrenCount($e) } catch { $n = 0 }
        for ($k = $n - 1; $k -ge 0; $k--) { $st.Push([System.Windows.Media.VisualTreeHelper]::GetChild($e, $k)) }
        if ($n -eq 0) {
            try { if ($e.Child) { $st.Push($e.Child) } } catch { }
            try { if ($e.Children) { for ($k = $e.Children.Count - 1; $k -ge 0; $k--) { $st.Push($e.Children[$k]) } } } catch { }
        }
    }
    return $out
}

# --- measure one built document --------------------------------------------
$rows  = New-Object System.Collections.Generic.List[object]
$inv   = @{}
$calibs = New-Object System.Collections.Generic.List[double]
$script:railX = @{}
$script:lead  = @{}
$script:wrapAgg = @{}

function AL-MeasureDoc { param($doc, [string]$DocName, [string]$Mode)
    $idx = -1
    foreach ($b in @($doc.Blocks)) {
        $idx++
        $tag = "$($b.Tag)"; if (-not $tag) { $tag = '(untagged)' }
        $xMark = $null; $xText = $null; $sample = ''; $face = ''; $size = 0.0; $weight = ''
        $ground = $false; $marginL = 0.0; $indent = 0.0

        if ($b -is [System.Windows.Documents.Paragraph]) {
            $marginL = [double]$b.Margin.Left; $indent = [double]$b.TextIndent
            $ground  = ($null -ne $b.Background)
            foreach ($inl in @($b.Inlines)) {
                if ($null -eq $xMark -and $inl -is [System.Windows.Documents.InlineUIContainer]) { $xMark = AL-ElemX $inl.Child }
                if ($null -eq $xText -and $inl -is [System.Windows.Documents.Run] -and "$($inl.Text)".Trim().Length -ge 1) {
                    $xText = AL-RectX $inl.ContentStart
                    $sample = "$($inl.Text)".Trim()
                    $face = "$($inl.FontFamily.Source)"; $size = [double]$inl.FontSize; $weight = "$($inl.FontWeight)"
                }
            }
            if ($null -eq $xMark) { $xMark = $xText }
        } elseif ($b -is [System.Windows.Documents.BlockUIContainer]) {
            $marginL = [double]$b.Margin.Left
            $g = $b.Child
            $a = AL-RectX $b.ContentStart; $c = AL-ElemX $g
            if ($null -ne $a -and $null -ne $c) { $calibs.Add($a - $c) }
            $xs = @()
            foreach ($t in (AL-TextBlocks $g)) {
                $x = AL-ElemX $t
                if ($null -eq $x) { continue }
                $xs += , ([PSCustomObject]@{ X = $x; T = "$($t.Text)"; F = "$($t.FontFamily.Source)"
                                             S = [double]$t.FontSize; W = "$($t.FontWeight)" })
            }
            if ($xs.Count) {
                $xMark = ($xs | Measure-Object -Property X -Minimum).Minimum
                $body = @($xs | Where-Object { "$($_.T)".Trim().Length -gt 1 })
                if ($body.Count) {
                    $xText = [double]$body[0].X; $sample = "$($body[0].T)"
                    $face = $body[0].F; $size = $body[0].S; $weight = $body[0].W
                }
                # 🔴 A RAIL BLOCK IS NOT ONE LINE. Its caption is what the table
                # above reports; the CONTENT under an opened fold is a second
                # column entirely and was never measured. Recorded per x so a
                # body sitting 18px right of its own caption cannot hide.
                foreach ($bx in $body) {
                    $key = ('{0}|{1}' -f $b.Tag, [Math]::Round($bx.X, 0))
                    if (-not $script:railX.ContainsKey($key)) { $script:railX[$key] = @{ N = 0; S = "$($bx.T)" } }
                    $script:railX[$key].N++
                }
            }
            if ($null -eq $xText) { $xText = AL-ElemX $g }
        }
        $shape = ''
        if ($sample.StartsWith([string][char]0x2022)) { $shape = 'bullet' }
        elseif ($sample -match '^\d+\.\s') { $shape = 'numbered' }
        elseif ($weight -eq 'SemiBold') { $shape = 'semibold' }
        if ($ground) { $shape = ($shape + ' ground').Trim() }
        if ($tag -eq 'rail:system' -and $sample -like 'load earlier*') { $tag = 'rail:loadearlier' }
        $rows.Add([PSCustomObject]@{
            Doc = $DocName; Mode = $Mode; I = $idx; Tag = $tag; Shape = $shape
            XMark = $xMark; XText = $xText; MarginL = $marginL; Indent = $indent
            Face = ($face -replace '^.*#', ''); Size = $size; Weight = $weight
            Sample = $(if ($sample.Length -gt 44) { $sample.Substring(0, 44) } else { $sample })
        })
    }
    # font inventory
    $stack = New-Object System.Collections.Generic.Stack[object]
    foreach ($b in @($doc.Blocks)) { $stack.Push(@{ E = $b; Tag = "$($b.Tag)" }) }
    $guard = 0
    while ($stack.Count -and $guard -lt 400000) {
        $guard++
        $it = $stack.Pop(); $e = $it.E; $tg = $it.Tag
        $rec = $null
        if (($e -is [System.Windows.Documents.Run] -or $e -is [System.Windows.Controls.TextBlock]) -and "$($e.Text)".Trim()) {
            $rec = ("$($e.FontFamily.Source)|$($e.FontSize)|$($e.FontWeight)|$($e.FontStyle)" -replace '^.*#', '')
        }
        if ($rec) {
            if (-not $inv.ContainsKey($rec)) { $inv[$rec] = @{ N = 0; Tags = @{} } }
            $inv[$rec].N++; $inv[$rec].Tags[$tg] = $true
        }
        # 🔴 LEADING IS PART OF "UNIFIED" AND IS NOT IN THE FONT INVENTORY. A
        # paragraph carries LineHeight; a TextBlock inside a rail block carries
        # its own, and NaN there means "whatever the face says", which is a
        # different number from the one prose is set on.
        $lh = $null; $ls = ''
        if ($e -is [System.Windows.Documents.Paragraph]) { $lh = $e.LineHeight; $ls = "$($e.LineStackingStrategy)" }
        elseif ($e -is [System.Windows.Controls.TextBlock] -and "$($e.Text)".Trim()) { $lh = $e.LineHeight; $ls = "$($e.LineStackingStrategy)" }
        if ($null -ne $lh) {
            $lk = ('{0}|{1}|{2}' -f $(if ([double]::IsNaN($lh)) { 'auto' } else { ('{0:N1}' -f $lh) }), $ls,
                   $(if ($e -is [System.Windows.Documents.Paragraph]) { 'Paragraph' } else { 'TextBlock' }))
            if (-not $script:lead.ContainsKey($lk)) { $script:lead[$lk] = @{ N = 0; Tags = @{} } }
            $script:lead[$lk].N++; $script:lead[$lk].Tags[$tg] = $true
        }
        foreach ($p in @('Blocks', 'Inlines', 'Children')) {
            try { if ($e.PSObject.Properties[$p] -and $e.$p) { foreach ($k in $e.$p) { $stack.Push(@{ E = $k; Tag = $tg }) } } } catch { }
        }
        try { if ($e.PSObject.Properties['Child'] -and $e.Child) { $stack.Push(@{ E = $e.Child; Tag = $tg }) } } catch { }
    }
    # ---------------------------------------------------------------
    # WHERE LINE 2 OF A WRAPPED PARAGRAPH STARTS.
    #
    # Every table above reads the FIRST character of a block, and a hanging
    # indent is the half of alignment that cannot see. Navigated with
    # TextPointer.GetLineStartPosition, which walks RENDERED lines - an
    # earlier version bucketed character rects by rounded y and produced
    # line-1 values that were plainly impossible (a paragraph "starting" at
    # x=745), because a caret position at a line break reports the END of the
    # line it came from.
    # ---------------------------------------------------------------
    foreach ($b in @($doc.Blocks)) {
        if (-not ($b -is [System.Windows.Documents.Paragraph])) { continue }
        $tag = "$($b.Tag)"; if (-not $tag) { $tag = '(untagged)' }
        $xs = New-Object System.Collections.Generic.List[double]
        $tp = $null
        try { $tp = $b.ContentStart.GetLineStartPosition(0) } catch { }
        $n = 0
        while ($tp -and $n -lt 400) {
            $n++
            $x = AL-RectX $tp
            if ($null -ne $x) { $xs.Add([double]$x) }
            $nx = $null
            try { $nx = $tp.GetLineStartPosition(1) } catch { }
            if (-not $nx) { break }
            if ($nx.CompareTo($tp) -le 0) { break }
            if ($nx.CompareTo($b.ContentEnd) -ge 0) { break }
            $tp = $nx
        }
        if ($xs.Count -lt 2) { continue }
        $x1 = $xs[0]
        $x2 = ($xs[1..($xs.Count - 1)] | Measure-Object -Minimum).Minimum
        $sam = ''
        foreach ($inl in @($b.Inlines)) { if ($inl -is [System.Windows.Documents.Run] -and "$($inl.Text)".Trim()) { $sam = "$($inl.Text)".Trim(); break } }
        $shape = ''
        if ($sam.StartsWith([string][char]0x2022)) { $shape = 'bullet' }
        elseif ($sam -match '^\d+\.\s') { $shape = 'numbered' }
        elseif ($sam -match '^\s') { $shape = 'src-indent' }
        if ($null -ne $b.Background) { $shape = ($shape + ' ground').Trim() }
        $k = ('{0}|{1}|{2}|{3}' -f $tag, $shape, [Math]::Round($x1, 0), [Math]::Round($x2, 0))
        if (-not $script:wrapAgg.ContainsKey($k)) { $script:wrapAgg[$k] = @{ N = 0; L = 0 } }
        $script:wrapAgg[$k].N++; $script:wrapAgg[$k].L += $xs.Count
    }
    
}

# --- the sweep --------------------------------------------------------------
$modes = @('folded', 'full')
if ($env:SR_AL_STEPS) { $modes = @("$env:SR_AL_STEPS" -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ }) }
$lastDoc = $null; $lastName = ''
foreach ($js in $picks) {
    if (-not (Test-Path -LiteralPath $js)) { AL-Say ("  [skip] {0}" -f $js); continue }
    # 🪤 MB, NOT KB, AND NOT WITH GROUP SEPARATORS. This printed "{0:N0} KB",
    # which on a de-DE machine renders 207,647,199 bytes as "202.780 KB" - a
    # dot that reads as a decimal point in English and is a THOUSANDS separator
    # here. That number was carried into another session's notes as 202 KB for
    # a 198 MB file, and the whole diagnosis of that fixture was aimed at the
    # wrong order of magnitude because of it.
    $kb = (Get-Item -LiteralPath $js).Length / 1MB
    $trunc = $false
    try { $trunc = ((Get-Item -LiteralPath $js).Length -gt $script:tailBytes) } catch { }
    $got = $null
    try { $got = Get-SRTranscriptBlocks -JsonlPath $js -MaxRecords 400 -MaxTailBytes $script:tailBytes } catch { AL-Say ("  [skip] parse threw on {0}" -f $js); continue }
    $blocks = @($got)
    foreach ($m in $modes) {
        $script:toolView = $m
        $turns = @(Get-ReadTurns $blocks)
        $doc = Build-ReadDocument -Blocks $blocks -Truncated $trunc -Turns $turns
        $ui.PaneDoc.Document = $doc
        AL-Layout
        Set-ReadMeasure -Doc $doc -PadL 44
        AL-Layout
        AL-MeasureDoc -doc $doc -DocName (Split-Path -Leaf $js) -Mode $m
        AL-Say ("  {0,-42} {1,8:N1} MB  steps={2,-7} blocks={3,4}  turns={4,4}" -f `
            (Split-Path -Leaf $js), $kb, $m, $doc.Blocks.Count, $turns.Count)
        $lastDoc = $doc; $lastName = (Split-Path -Leaf $js)
    }
}

AL-Say ''
if ($calibs.Count) {
    $cs = $calibs | Measure-Object -Average -Minimum -Maximum
    AL-Say ("calibration (TextPointer x minus TransformToAncestor x, same block, n={0}): avg {1:N3}  min {2:N3}  max {3:N3}" -f `
        $calibs.Count, $cs.Average, $cs.Minimum, $cs.Maximum)
} else { AL-Say 'calibration: UNMEASURED' }

AL-Say ''
AL-Say '=== CLAIM 1: where each block kind starts, in px (window 1480x980) ====='
$meas = @($rows | Where-Object { $null -ne $_.XText })
AL-Say ("{0} of {1} blocks measured" -f $meas.Count, $rows.Count)
$grp = $meas | Group-Object { "$($_.Tag)|$($_.Shape)" } | Sort-Object Name
AL-Say ('{0,-26} {1,-14} {2,5} {3,8} {4,8} {5,8} {6,8}  {7}' -f 'BLOCK KIND', 'SHAPE', 'N', 'xText', 'min', 'max', 'xMark', 'SAMPLE')
AL-Say ('-' * 118)
foreach ($g in $grp) {
    $p = $g.Name -split '\|'
    $st = @($g.Group | ForEach-Object { $_.XText }) | Measure-Object -Average -Minimum -Maximum
    $mk = @($g.Group | Where-Object { $null -ne $_.XMark } | ForEach-Object { $_.XMark })
    $mkAvg = $(if ($mk.Count) { ($mk | Measure-Object -Average).Average } else { [double]::NaN })
    AL-Say ('{0,-26} {1,-14} {2,5} {3,8:N1} {4,8:N1} {5,8:N1} {6,8:N1}  {7}' -f `
        $p[0], $p[1], $g.Count, $st.Average, $st.Minimum, $st.Maximum, $mkAvg, $g.Group[0].Sample)
}
AL-Say ''
$modeX = ($meas | Group-Object { [Math]::Round($_.XText, 0) } | Sort-Object Count -Descending | Select-Object -First 1)
AL-Say ("the column most blocks use: x={0} ({1} of {2})" -f $modeX.Name, $modeX.Count, $meas.Count)
$off = @($meas | Where-Object { [Math]::Abs($_.XText - [double]$modeX.Name) -gt 1.5 })
AL-Say ("blocks NOT on it: {0} ({1:N1}%)" -f $off.Count, (100.0 * $off.Count / $meas.Count))
AL-Say ('{0,-26} {1,-14} {2,8} {3,6}  {4}' -f 'BLOCK KIND', 'SHAPE', 'x', 'N', 'SAMPLE')
foreach ($o in ($off | Group-Object { "$($_.Tag)|$($_.Shape)|$([Math]::Round($_.XText,1))" } |
                Sort-Object { -$_.Count })) {
    $p = $o.Name -split '\|'
    AL-Say ('{0,-26} {1,-14} {2,8} {3,6}  {4}' -f $p[0], $p[1], $p[2], $o.Count, $o.Group[0].Sample)
}

AL-Say ''
AL-Say '=== CLAIM 4: every distinct face / size / weight / style actually built =='
AL-Say ('{0,-22} {1,6} {2,10} {3,8} {4,7}   {5}' -f 'FACE', 'SIZE', 'WEIGHT', 'STYLE', 'N', 'WHERE')
AL-Say ('-' * 112)
foreach ($k in ($inv.Keys | Sort-Object)) {
    $p = $k -split '\|'
    $where = (@($inv[$k].Tags.Keys | Sort-Object) -join ' ')
    if ($where.Length -gt 44) { $where = $where.Substring(0, 43) + '~' }
    AL-Say ('{0,-22} {1,6} {2,10} {3,8} {4,7}   {5}' -f $p[0], $p[1], $p[2], $p[3], $inv[$k].N, $where)
}

AL-Say ''
AL-Say '=== CLAIM 1b: every x INSIDE a rail block (caption AND opened body) ===='
AL-Say ('{0,-26} {1,8} {2,8}  {3}' -f 'BLOCK KIND', 'x', 'N', 'SAMPLE')
AL-Say ('-' * 96)
foreach ($k in ($script:railX.Keys | Sort-Object)) {
    $p = $k -split '\|'
    $s = "$($script:railX[$k].S)" -replace "`r?`n", ' '
    if ($s.Length -gt 44) { $s = $s.Substring(0, 44) }
    AL-Say ('{0,-26} {1,8} {2,8}  {3}' -f $p[0], $p[1], $script:railX[$k].N, $s)
}

AL-Say ''
AL-Say '=== CLAIM 1c: WRAPPED lines - where line 2 starts vs line 1 ============'
# 🔴 A HANGING INDENT IS THE HALF OF ALIGNMENT A SINGLE-LINE MEASUREMENT CANNOT
# SEE. Every table above reads the FIRST character of a block. What the eye
# actually follows down a column is where the SECOND line of a wrapped
# paragraph lands - and a bullet whose continuation sits under its own dot
# reads as ragged however well its first line is aligned. Measured by walking
# insertion positions and grouping the rects by y.
AL-Say ('{0,-26} {1,-14} {2,7} {3,9} {4,9} {5,8}' -f 'BLOCK KIND', 'SHAPE', 'LINES', 'x line1', 'x line2+', 'N')
AL-Say ('-' * 80)
$wrapKeys = @($script:wrapAgg.Keys | Where-Object { $script:wrapAgg[$_].N -ge 2 } |
              Sort-Object { -$script:wrapAgg[$_].N })
foreach ($k in $wrapKeys) {
    $p = $k -split '\|'
    AL-Say ('{0,-26} {1,-14} {2,7:N1} {3,9} {4,9} {5,8}' -f $p[0], $p[1],
        ($script:wrapAgg[$k].L / $script:wrapAgg[$k].N), $p[2], $p[3], $script:wrapAgg[$k].N)
}
AL-Say ("  ... and {0} more (x1,x2) pairs seen only once" -f
        @($script:wrapAgg.Keys | Where-Object { $script:wrapAgg[$_].N -lt 2 }).Count)

AL-Say ''
AL-Say '=== CLAIM 4b: leading, by element =====================================';
AL-Say ('{0,8} {1,20} {2,12} {3,7}   {4}' -f 'LINEHT', 'STACKING', 'ELEMENT', 'N', 'WHERE')
AL-Say ('-' * 100)
foreach ($k in ($script:lead.Keys | Sort-Object)) {
    $p = $k -split '\|'
    $where = (@($script:lead[$k].Tags.Keys | Sort-Object) -join ' ')
    if ($where.Length -gt 42) { $where = $where.Substring(0, 41) + '~' }
    AL-Say ('{0,8} {1,20} {2,12} {3,7}   {4}' -f $p[0], $p[1], $p[2], $script:lead[$k].N, $where)
}

AL-Say ''
AL-Say '=== CLAIM 3a: how much of the window the text column uses =============='
AL-Say ("(measured on {0}, steps={1})" -f $lastName, $script:toolView)
$widths = @(1000, 1200, 1480, 1720, 1920, 2200, 2560, 3440)
if ($env:SR_AL_WIDTHS) { $widths = @("$env:SR_AL_WIDTHS" -split ',' | ForEach-Object { [double]$_.Trim() }) }
AL-Say ('{0,8} {1,9} {2,7} {3,7} {4,9} {5,10} {6,9} {7,8}' -f 'WINDOW', 'PANE', 'padL', 'padR', 'COLUMN', 'INK RIGHT', 'UNUSED', '% of win')
AL-Say ('-' * 78)
foreach ($ww in $widths) {
    $script:W = [double]$ww
    $window.Width = $script:W
    AL-Layout
    Set-ReadMeasure -Doc $lastDoc -PadL 44
    AL-Layout
    $pane = [double]$ui.PaneDoc.ActualWidth
    $col = $pane - $lastDoc.PagePadding.Left - $lastDoc.PagePadding.Right
    $inkR = 0.0
    $cand = @($lastDoc.Blocks | Where-Object { $_ -is [System.Windows.Documents.Paragraph] } |
              Sort-Object { -([string]::Join('', @($_.Inlines | ForEach-Object { "$($_.Text)" }))).Length } |
              Select-Object -First 10)
    foreach ($p in $cand) {
        $tp = $p.ContentStart; $steps = 0
        while ($tp -and $steps -lt 900) {
            $steps++
            $x = AL-RectX $tp
            if ($null -ne $x -and $x -gt $inkR) { $inkR = $x }
            $tp = $tp.GetNextInsertionPosition($LD)
            if (-not $tp) { break }
            if ($tp.CompareTo($p.ContentEnd) -ge 0) { break }
        }
    }
    AL-Say ('{0,8:N0} {1,9:N1} {2,7:N0} {3,7:N0} {4,9:N1} {5,10:N1} {6,9:N1} {7,8:N1}' -f `
        $script:W, $pane, $lastDoc.PagePadding.Left, $lastDoc.PagePadding.Right, $col, $inkR, ($pane - $col), (100.0 * $col / $script:W))
}

AL-Say ''
AL-Say 'done'
exit 0
