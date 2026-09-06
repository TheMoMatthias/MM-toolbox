#requires -Version 5.1
<#
 ==============================================================================
  WHICH CHARACTERS ACTUALLY ARRIVE IN THE PANE, AND WHICH FACE DRAWS THEM.

  Two questions, and only the second is usually asked:

    1. What non-ASCII characters are really in the operator's transcripts, and
       how often? Counted off the SAME text the pane renders - the tail
       Get-SRTranscriptBlocks hands the document, not the whole file.

    2. For each of those, does the declared face have the glyph, and if not,
       WHAT DRAWS IT? Answered by rendering the character through WPF with the
       app's own Typeface and comparing the resulting outline against the same
       character rendered explicitly in each candidate face. Identical outlines
       mean WPF fell back to that face. A character that comes out identical to
       a deliberately unassigned codepoint is a tofu box.

  No GPU and no window: FormattedText.BuildGeometry is pure outline maths, so
  this runs anywhere. Read-only throughout.

    SR_GL_N=24        how many transcripts to scan
 ==============================================================================
#>
$ErrorActionPreference = 'Continue'
Add-Type -AssemblyName PresentationCore, PresentationFramework, WindowsBase

$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$tool = Split-Path -Parent $here
$lib  = Join-Path $tool 'lib'
. (Join-Path $lib '_common.ps1')

# 🪤 NOT `GL` - that is the built-in alias for Get-Location, and every
# line of this report went to it instead of to the console.
function GSay { param([string]$T) Write-Host $T }

# ---- the faces, loaded exactly the way the window loads them ----------------
$fontDir = Join-Path $lib 'fonts'
$base = [Uri]('file:///' + $fontDir.Replace('\', '/').TrimEnd('/') + '/')
$fams = [System.Windows.Media.Fonts]::GetFontFamilies($base)
$Manrope = [System.Windows.Media.FontFamily](@($fams | Where-Object { "$($_.Source)" -like '*#Manrope*' })[0])
$Plex    = [System.Windows.Media.FontFamily](@($fams | Where-Object { "$($_.Source)" -like '*#IBM Plex Mono*' })[0])
GSay ("prose face: {0}" -f $Manrope.Source)
GSay ("pane  face: {0}" -f $Plex.Source)

$cands = [ordered]@{
    'Manrope(prose)'   = $Manrope
    'IBMPlexMono(pane)' = $Plex
    'Segoe UI'         = [System.Windows.Media.FontFamily]'Segoe UI'
    'Segoe UI Emoji'   = [System.Windows.Media.FontFamily]'Segoe UI Emoji'
    'Segoe UI Symbol'  = [System.Windows.Media.FontFamily]'Segoe UI Symbol'
    'Segoe UI Historic' = [System.Windows.Media.FontFamily]'Segoe UI Historic'
    'Cascadia Mono'    = [System.Windows.Media.FontFamily]'Cascadia Mono'
    'Consolas'         = [System.Windows.Media.FontFamily]'Consolas'
}
$GT = @{}
foreach ($k in $cands.Keys) {
    $tf = New-Object System.Windows.Media.Typeface $cands[$k],
              ([System.Windows.FontStyles]::Normal), ([System.Windows.FontWeights]::Normal),
              ([System.Windows.FontStretches]::Normal)
    $g = $null
    if ($tf.TryGetGlyphTypeface([ref]$g)) { $GT[$k] = $g } else { $GT[$k] = $null }
}

# ---- x-height parity, which is what "the same size" actually means ---------
GSay ''
GSay '=== FACE METRICS at 13px (nominal size is not apparent size) ============'
GSay ('{0,-20} {1,9} {2,9} {3,9} {4,9} {5,9}' -f 'FACE', 'x-height', 'cap-ht', 'ascent', 'descent', 'advance0')
GSay ('-' * 72)
foreach ($k in $cands.Keys) {
    $g = $GT[$k]
    if (-not $g) { GSay ('{0,-20}  NOT AVAILABLE' -f $k); continue }
    $adv = [double]::NaN
    $gi = 0
    if ($g.CharacterToGlyphMap.TryGetValue([int][char]'0', [ref]$gi)) { $adv = $g.AdvanceWidths[$gi] * 13.0 }
    GSay ('{0,-20} {1,9:N2} {2,9:N2} {3,9:N2} {4,9:N2} {5,9:N2}' -f $k,
        ($g.XHeight * 13.0), ($g.CapsHeight * 13.0), ($g.Baseline * 13.0), ($g.Height * 13.0 - $g.Baseline * 13.0), $adv)
}

# ---- what is really in the transcripts the pane draws ----------------------
$projRoot = Join-Path $env:USERPROFILE '.claude\projects'
$n = 24; if ($env:SR_GL_N) { $n = [int]$env:SR_GL_N }
$files = @(Get-ChildItem -LiteralPath $projRoot -Recurse -Filter *.jsonl -ErrorAction SilentlyContinue |
           Sort-Object LastWriteTime -Descending | Select-Object -First $n)
GSay ''
GSay ("=== scanning the RENDERED TAIL of {0} transcripts (96 KB each) =========" -f $files.Count)

$freq = @{}
$total = 0.0
$scanned = 0
foreach ($f in $files) {
    $blocks = @()
    try { $got = Get-SRTranscriptBlocks -JsonlPath $f.FullName -MaxRecords 400 -MaxTailBytes 98304; $blocks = @($got) } catch { continue }
    if (-not $blocks.Count) { continue }
    $scanned++
    $sb = New-Object System.Text.StringBuilder
    foreach ($b in $blocks) {
        foreach ($p in @('Head', 'Body', 'Meta')) {
            try { if ($b.PSObject.Properties[$p]) { $null = $sb.Append("$($b.$p)").Append("`n") } } catch { }
        }
    }
    # 🪤 CODEPOINTS, NOT UTF-16 CODE UNITS. Counting chars reports every
    # emoji as two unassigned "characters" in the surrogate range - which is
    # not a thing any font has a glyph for, so the coverage answer would be
    # NO for a codepoint that was never asked about.
    $str = $sb.ToString()
    for ($i = 0; $i -lt $str.Length; $i++) {
        $c = [int]$str[$i]
        if ([char]::IsHighSurrogate($str[$i]) -and ($i + 1) -lt $str.Length -and [char]::IsLowSurrogate($str[$i + 1])) {
            $c = [char]::ConvertToUtf32($str[$i], $str[$i + 1]); $i++
        }
        $total++
        if ($c -lt 128) { continue }
        if (-not $freq.ContainsKey($c)) { $freq[$c] = 0 }
        $freq[$c]++
    }
}
GSay ("{0} transcripts parsed, {1:N0} characters, {2:N0} of them non-ASCII ({3:N3}%)" -f `
    $scanned, $total, (($freq.Values | Measure-Object -Sum).Sum), (100.0 * ($freq.Values | Measure-Object -Sum).Sum / [Math]::Max(1, $total)))

# ---- does the declared face have the glyph, and what draws it if not -------
$script:geoErr = ''
# 🪤 NOT BuildGeometry(). It is public on FormattedText and PowerShell 5.1
# still reports "cannot find an overload ... argument count 0" for it - proved
# on both the 6-arg and the 7-arg constructor. The measured shape of the drawn
# text is available as ordinary properties instead, and they are enough: two
# renderings that resolve to the SAME physical font agree on all six to the
# last fraction, and two that do not, do not.
function Get-GlyphGeo { param([int]$Code, $Fam)
    try {
        $tf = New-Object System.Windows.Media.Typeface -ArgumentList $Fam,
                  ([System.Windows.FontStyles]::Normal), ([System.Windows.FontWeights]::Normal),
                  ([System.Windows.FontStretches]::Normal)
        $txt = [char]::ConvertFromUtf32($Code)
        $ft = New-Object System.Windows.Media.FormattedText -ArgumentList @(
                  $txt, [System.Globalization.CultureInfo]::InvariantCulture,
                  [System.Windows.FlowDirection]::LeftToRight, $tf, 40.0,
                  [System.Windows.Media.Brushes]::Black, 1.0)
        # GLYPH FIELDS ONLY. Height and Baseline come from the PRIMARY
        # typeface's line box, not from the glyph that was actually drawn, so
        # including them makes every cross-family comparison differ and every
        # fallback read as unresolvable - which is what the first version of
        # this reported for all 44 codepoints.
        $sig = '{0:N4}/{1:N4}/{2:N4}/{3:N4}' -f `
                  $ft.Width, $ft.Extent, $ft.OverhangLeading, $ft.OverhangTrailing
        return [PSCustomObject]@{ Sig = $sig; W = $ft.Width; H = $ft.Height; Y = $ft.Baseline
                                  Ext = $ft.Extent; Empty = ($ft.Width -le 0) }
    } catch { $script:geoErr = $_.Exception.Message; return $null }
}
# The signature of a codepoint unassigned in every font here, so "renders like
# this" means "renders as .notdef".
$TOFU = (Get-GlyphGeo 0x0605 $Manrope)

# ---- every installed family, so a fallback can be NAMED and not guessed ----
$sysFams = @([System.Windows.Media.Fonts]::SystemFontFamilies)
$sysGT = New-Object System.Collections.Generic.List[object]
foreach ($f in $sysFams) {
    $tf = New-Object System.Windows.Media.Typeface -ArgumentList $f,
              ([System.Windows.FontStyles]::Normal), ([System.Windows.FontWeights]::Normal),
              ([System.Windows.FontStretches]::Normal)
    $g = $null
    if ($tf.TryGetGlyphTypeface([ref]$g)) { $sysGT.Add([PSCustomObject]@{ Name = "$($f.Source)"; Fam = $f; GT = $g }) }
}
GSay ("{0} installed font families, {1} with a readable glyph table" -f $sysFams.Count, $sysGT.Count)

function Resolve-Fallback { param([int]$Code, $PrimaryFam)
    $g0 = Get-GlyphGeo $Code $PrimaryFam
    if ($null -eq $g0) { return 'MEASUREMENT FAILED' }
    if ($TOFU -and $g0.Sig -eq $TOFU.Sig) { return 'TOFU (.notdef box)' }
    if ($g0.W -le 0) { return 'zero-width (nothing drawn)' }
    $hits = @()
    foreach ($e in $sysGT) {
        $gi = 0
        if (-not $e.GT.CharacterToGlyphMap.TryGetValue($Code, [ref]$gi)) { continue }
        $gk = Get-GlyphGeo $Code $e.Fam
        if ($gk -and $gk.Sig -eq $g0.Sig) { $hits += $e.Name }
    }
    if (-not $hits.Count) { return ('unresolved (adv {0:N2})' -f $g0.W) }
    return ($hits[0] + $(if ($hits.Count -gt 1) { " (+$($hits.Count - 1) more)" } else { '' }))
}

GSay ''
GSay '=== CLAIM 2: every non-ASCII character in those tails ==================='
GSay ('{0,-8} {1,-3} {2,8} {3,8} {4,7} {5,6}  {6,-32} {7}' -f 'CODE', 'CH', 'COUNT', 'per 10k', 'Manrope', 'Plex', 'WHAT ACTUALLY DRAWS IT', 'BLOCK')
GSay ('-' * 124)
$rank = @($freq.GetEnumerator() | Sort-Object { -$_.Value })
$missProse = 0.0; $missPane = 0.0
$summary = @{}
foreach ($e in $rank) {
    $c = [int]$e.Key; $cnt = [double]$e.Value
    $inM = $false; $inP = $false
    $gi = 0
    if ($GT['Manrope(prose)'] -and $GT['Manrope(prose)'].CharacterToGlyphMap.TryGetValue($c, [ref]$gi)) { $inM = $true }
    $gi = 0
    if ($GT['IBMPlexMono(pane)'] -and $GT['IBMPlexMono(pane)'].CharacterToGlyphMap.TryGetValue($c, [ref]$gi)) { $inP = $true }
    if (-not $inM) { $missProse += $cnt }
    if (-not $inP) { $missPane += $cnt }

    $drawn = 'Manrope (declared)'
    if (-not $inM) { $drawn = Resolve-Fallback -Code $c -PrimaryFam $Manrope }

    $blk = ''
    if ($c -ge 0x2500 -and $c -le 0x257F) { $blk = 'box drawing' }
    elseif ($c -ge 0x2580 -and $c -le 0x259F) { $blk = 'block elements' }
    elseif ($c -ge 0x25A0 -and $c -le 0x25FF) { $blk = 'geometric shapes' }
    elseif ($c -ge 0x2600 -and $c -le 0x26FF) { $blk = 'misc symbols' }
    elseif ($c -ge 0x2700 -and $c -le 0x27BF) { $blk = 'dingbats' }
    elseif ($c -ge 0x2460 -and $c -le 0x24FF) { $blk = 'enclosed alphanumerics' }
    elseif ($c -ge 0x2190 -and $c -le 0x21FF) { $blk = 'arrows' }
    elseif ($c -ge 0x2200 -and $c -le 0x22FF) { $blk = 'math operators' }
    elseif ($c -ge 0x2300 -and $c -le 0x23FF) { $blk = 'misc technical' }
    elseif ($c -ge 0x2000 -and $c -le 0x206F) { $blk = 'general punctuation' }
    elseif ($c -ge 0xFE00 -and $c -le 0xFE0F) { $blk = 'variation selector' }
    elseif ($c -eq 0xFEFF) { $blk = 'zero-width no-break space' }
    elseif ($c -ge 0x1F300 -and $c -le 0x1FAFF) { $blk = 'EMOJI (astral)' }
    elseif ($c -gt 0xFFFF) { $blk = 'astral (non-emoji)' }
    elseif ($c -lt 0x0250) { $blk = 'latin-1 / latin ext' }
    else { $blk = ('U+{0:X4} block' -f ($c -band 0xFF00)) }
    if (-not $summary.ContainsKey($blk)) { $summary[$blk] = @{ N = 0.0; Miss = 0.0; MissP = 0.0; Drawn = @{} } }
    $summary[$blk].N += $cnt
    if (-not $inM) { $summary[$blk].Miss += $cnt; $summary[$blk].Drawn[$drawn] = $true }
    if (-not $inP) { $summary[$blk].MissP += $cnt }

    $disp = ''
    try { $disp = [char]::ConvertFromUtf32($c) } catch { $disp = '..' }
    GSay ('U+{0:X5} {1,-3} {2,8:N0} {3,8:N2} {4,7} {5,6}  {6,-32} {7}' -f `
        $c, $disp, $cnt, (10000.0 * $cnt / $total), $(if ($inM) { 'yes' } else { 'NO' }),
        $(if ($inP) { 'yes' } else { 'NO' }), $drawn, $blk)
}
GSay ("{0} distinct non-ASCII codepoints" -f $rank.Count)
GSay ''
GSay '--- by Unicode block ---'
GSay ('{0,-28} {1,10} {2,9} {3,11} {4,9}  {5}' -f 'BLOCK', 'OCCURS', 'per 10k', 'NOT Manrope', 'NOT Plex', 'FALLS BACK TO')
GSay ('-' * 122)
foreach ($k in ($summary.Keys | Sort-Object { -$summary[$_].N })) {
    $d = (@($summary[$k].Drawn.Keys | Sort-Object) -join ', ')
    if ($d.Length -gt 44) { $d = $d.Substring(0, 43) + '~' }
    GSay ('{0,-28} {1,10:N0} {2,9:N2} {3,11:N0} {4,9:N0}  {5}' -f $k, $summary[$k].N,
        (10000.0 * $summary[$k].N / $total), $summary[$k].Miss, $summary[$k].MissP, $d)
}
GSay ''
GSay ("characters the PROSE face (Manrope) cannot draw: {0:N0}  ({1:N2} per 10k of all pane text)" -f $missProse, (10000.0 * $missProse / $total))
GSay ("characters the PANE face (IBM Plex Mono) cannot draw: {0:N0}  ({1:N2} per 10k)" -f $missPane, (10000.0 * $missPane / $total))

# ==========================================================================
# WOULD DECLARING A FALLBACK IN THE FontFamily STRING CHANGE ANYTHING?
#
# The proposed fix is 'Manrope, Segoe UI Emoji, Segoe UI Symbol'. This builds
# that family for real, against the same loose-folder base uri the window uses,
# and compares what it draws against the bare family. Identical means the fix
# is a no-op: WPF's own fallback already reaches the same physical font and the
# declaration buys nothing.
# ==========================================================================
GSay ''
GSay '=== does a DECLARED fallback change what is drawn? ======================'
$comp = $null
try { $comp = New-Object System.Windows.Media.FontFamily -ArgumentList $base, './#Manrope, Segoe UI Emoji, Segoe UI Symbol, Segoe UI' } catch { GSay ("composite family threw: {0}" -f $_.Exception.Message) }
if ($comp) {
    GSay ("composite family: {0}" -f $comp.Source)
    GSay ('{0,-8} {1,-3} {2,12} {3,12} {4}' -f 'CODE', 'CH', 'bare adv', 'declared', 'VERDICT')
    GSay ('-' * 66)
    $probe2 = @(0x2705, 0x26D4, 0x26A0, 0x2696, 0x27A4, 0x2460, 0x23ED, 0xFE0F, 0x1F534, 0x1FAA4, 0x1F511)
    $changed = 0
    foreach ($c in $probe2) {
        $a = Get-GlyphGeo $c $Manrope
        $b = Get-GlyphGeo $c $comp
        if (-not $a -or -not $b) { continue }
        $v = $(if ($a.Sig -eq $b.Sig) { 'IDENTICAL - the declaration changes nothing' } else { 'DIFFERENT' })
        if ($a.Sig -ne $b.Sig) { $changed++ }
        $disp = ''; try { $disp = [char]::ConvertFromUtf32($c) } catch { }
        GSay ('U+{0:X5} {1,-3} {2,12:N2} {3,12:N2} {4}' -f $c, $disp, $a.W, $b.W, $v)
    }
    GSay ("{0} of {1} probe characters change when the fallback is declared" -f $changed, $probe2.Count)
}

# ---- what a fallback costs in size and baseline ----------------------------
GSay ''
GSay '=== what the fallback face costs, per character (rendered at 40px) ====='
$mgt = $GT['Manrope(prose)']
$nAdv = 0.0
$gi = 0
if ($mgt.CharacterToGlyphMap.TryGetValue([int][char]'n', [ref]$gi)) { $nAdv = $mgt.AdvanceWidths[$gi] * 40.0 }
GSay ("(for scale at 40px: Manrope cap-height {0:N2}px, x-height {1:N2}px, an 'n' advances {2:N2}px)" -f `
    ($mgt.CapsHeight * 40.0), ($mgt.XHeight * 40.0), $nAdv)
GSay ('{0,-8} {1,-3} {2,-22} {3,9} {4,9} {5,9}' -f 'CODE', 'CH', 'FACE', 'advance', 'ink ext', 'baseline')
GSay ('-' * 70)
$probe = @(0x25CF, 0x2192, 0x2705, 0x26D4, 0x1F534, 0x1FAA4, 0x2460, 0x00B7, 0xFE0F)
foreach ($c in $probe) {
    foreach ($k in @('Manrope(prose)', 'IBMPlexMono(pane)', 'Segoe UI Symbol', 'Segoe UI Emoji')) {
        $g = Get-GlyphGeo $c $cands[$k]
        if (-not $g) { continue }
        $disp = ''; try { $disp = [char]::ConvertFromUtf32($c) } catch { }
        GSay ('U+{0:X5} {1,-3} {2,-22} {3,9:N2} {4,9:N2} {5,9:N2}' -f $c, $disp, $k, $g.W, $g.Ext, $g.Y)
    }
    GSay ''
}
GSay 'done'
exit 0
