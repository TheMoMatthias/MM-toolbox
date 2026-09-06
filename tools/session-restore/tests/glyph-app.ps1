#requires -Version 5.1
<#
 ==============================================================================
  THE GLYPHS THE WINDOW ITSELF DRAWS, against the faces it declares.

  The transcript sweep (glyph-driver.ps1) answers what arrives in the pane from
  the operator's conversations. This answers the other half, which is easier to
  miss because it is not data: the marker in every gutter, the fold caret, the
  arrows, the thin space that tracks a label - all of them are hard-coded char
  codes in lib\sessions-window.ps1, drawn in $script:PaneFace, and NOT ONE of
  them was ever checked against the face.

  Also calibrates the tofu box properly. glyph-driver used U+0605 as its
  "unassigned" reference and U+0605 turns out to be drawable, so the check
  could not fire. Three genuinely unassigned codepoints are used here and they
  have to agree before any character is called a box.
 ==============================================================================
#>
$ErrorActionPreference = 'Continue'
Add-Type -AssemblyName PresentationCore, PresentationFramework, WindowsBase

$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$lib  = Join-Path (Split-Path -Parent $here) 'lib'
function GSay { param([string]$T) Write-Host $T }

$fontDir = Join-Path $lib 'fonts'
$base = [Uri]('file:///' + $fontDir.Replace('\', '/').TrimEnd('/') + '/')
$fams = [System.Windows.Media.Fonts]::GetFontFamilies($base)
$Manrope = [System.Windows.Media.FontFamily](@($fams | Where-Object { "$($_.Source)" -like '*#Manrope*' })[0])
$Plex    = [System.Windows.Media.FontFamily](@($fams | Where-Object { "$($_.Source)" -like '*#IBM Plex Mono*' })[0])

function Get-Geo { param([int]$Code, $Fam)
    try {
        $tf = New-Object System.Windows.Media.Typeface -ArgumentList $Fam,
                  ([System.Windows.FontStyles]::Normal), ([System.Windows.FontWeights]::Normal),
                  ([System.Windows.FontStretches]::Normal)
        $ft = New-Object System.Windows.Media.FormattedText -ArgumentList @(
                  ([char]::ConvertFromUtf32($Code)), [System.Globalization.CultureInfo]::InvariantCulture,
                  [System.Windows.FlowDirection]::LeftToRight, $tf, 40.0,
                  [System.Windows.Media.Brushes]::Black, 1.0)
        return [PSCustomObject]@{
            Sig = ('{0:N4}/{1:N4}/{2:N4}/{3:N4}' -f $ft.Width, $ft.Extent, $ft.OverhangLeading, $ft.OverhangTrailing)
            W = $ft.Width; Ext = $ft.Extent }
    } catch { return $null }
}
function Has-Glyph { param($Fam, [int]$Code)
    $tf = New-Object System.Windows.Media.Typeface -ArgumentList $Fam,
              ([System.Windows.FontStyles]::Normal), ([System.Windows.FontWeights]::Normal),
              ([System.Windows.FontStretches]::Normal)
    $g = $null
    if (-not $tf.TryGetGlyphTypeface([ref]$g)) { return $false }
    $gi = 0
    return $g.CharacterToGlyphMap.TryGetValue($Code, [ref]$gi)
}

# ---- calibrate the tofu box ------------------------------------------------
GSay '=== TOFU CALIBRATION (three codepoints unassigned in Unicode) =========='
$unassigned = @(0x0378, 0x05EB, 0x2FE0)
$sigs = @{}
foreach ($fn in @(@('Manrope', $Manrope), @('IBM Plex Mono', $Plex))) {
    $seen = @()
    foreach ($u in $unassigned) {
        $g = Get-Geo $u $fn[1]
        GSay ('  {0,-16} U+{1:X4}  adv {2,7:N2}  ink {3,7:N2}   {4}' -f $fn[0], $u, $g.W, $g.Ext, $g.Sig)
        $seen += $g.Sig
    }
    $u0 = @($seen | Sort-Object -Unique)
    if ($u0.Count -eq 1) { GSay ('  -> {0}: all three agree, so this signature IS the .notdef box' -f $fn[0]); $sigs[$fn[0]] = $u0[0] }
    else { GSay ('  -> {0}: the three DISAGREE ({1} signatures) - cannot call anything a box from this' -f $fn[0], $u0.Count) }
}

# ---- the window's own hard-coded glyphs ------------------------------------
# Every char code drawn by lib\sessions-window.ps1 in the reading pane or the
# chrome around it, with what it is for.
$appGlyphs = @(
    @(0x25CF, 'gutter marker - EVERY block in the pane, and the shell/agent dot'),
    @(0x25B8, 'fold caret, closed'),
    @(0x25BE, 'fold caret, open / band caret'),
    @(0x25B4, 'load-earlier caret / manager caret'),
    @(0x25A0, 'running-shell mark'),
    @(0x2190, 'back to the parent conversation'),
    @(0x2192, 'open its conversation'),
    @(0x2022, 'bullet, substituted for a markdown -'),
    @(0x2026, 'ellipsis on a truncated head line'),
    @(0x2009, 'THIN SPACE - Get-TrackedText inserts one between every letter'),
    @(0x00B7, 'separator in the chip row and shell header'),
    @(0x0040, 'at-sign in the sub-agent column (reference: plain ASCII)')
)
GSay ''
GSay '=== THE WINDOW''S OWN GLYPHS vs THE FACES IT DECLARES =================='
GSay ('{0,-8} {1,-3} {2,9} {3,9} {4,10} {5,9}  {6}' -f 'CODE', 'CH', 'Manrope', 'Plex', 'adv@13px', 'ink@13px', 'WHAT IT IS')
GSay ('-' * 122)
foreach ($a in $appGlyphs) {
    $c = [int]$a[0]
    $inM = Has-Glyph $Manrope $c
    $inP = Has-Glyph $Plex $c
    # the pane draws its markers in PaneFace (IBM Plex Mono)
    $g = Get-Geo $c $Plex
    $box = ''
    if ($sigs['IBM Plex Mono'] -and $g -and $g.Sig -eq $sigs['IBM Plex Mono']) { $box = '  <-- DRAWS THE .NOTDEF BOX' }
    GSay ('U+{0:X4}  {1,-3} {2,9} {3,9} {4,10:N2} {5,9:N2}  {6}{7}' -f `
        $c, ([char]::ConvertFromUtf32($c)), $(if ($inM) { 'yes' } else { 'NO' }), $(if ($inP) { 'yes' } else { 'NO' }),
        ($g.W * 13.0 / 40.0), ($g.Ext * 13.0 / 40.0), $a[1], $box)
}

# ---- and what actually draws the ones that are missing ---------------------
$sysFams = @([System.Windows.Media.Fonts]::SystemFontFamilies)
GSay ''
GSay '=== for the missing ones, WHICH installed face WPF actually reaches ===='
foreach ($a in $appGlyphs) {
    $c = [int]$a[0]
    if ((Has-Glyph $Plex $c)) { continue }
    $g0 = Get-Geo $c $Plex
    $hits = @()
    foreach ($f in $sysFams) {
        if (-not (Has-Glyph $f $c)) { continue }
        $gk = Get-Geo $c $f
        if ($gk -and $gk.Sig -eq $g0.Sig) { $hits += "$($f.Source)" }
    }
    GSay ('U+{0:X4}  {1}   -> {2}' -f $c, ([char]::ConvertFromUtf32($c)),
        $(if ($hits.Count) { ($hits[0] + $(if ($hits.Count -gt 1) { " (and $($hits.Count - 1) other families draw it identically)" } else { '' })) } else { 'NOTHING MATCHES - it is a box' }))
}

# ---- how big an emoji is next to the words it sits in ----------------------
GSay ''
GSay '=== an emoji in a 13px line, in the units the line is built from ======='
$mtf = New-Object System.Windows.Media.Typeface -ArgumentList $Manrope,
           ([System.Windows.FontStyles]::Normal), ([System.Windows.FontWeights]::Normal),
           ([System.Windows.FontStretches]::Normal)
$mgt = $null; $null = $mtf.TryGetGlyphTypeface([ref]$mgt)
GSay ("prose at 13px: cap-height {0:N2}px, x-height {1:N2}px, line leading {2}px (SR_LeadFactor 1.62)" -f `
    ($mgt.CapsHeight * 13.0), ($mgt.XHeight * 13.0), (13.0 * 1.62))
GSay ('{0,-8} {1,-3} {2,10} {3,10} {4,14} {5}' -f 'CODE', 'CH', 'adv 13px', 'ink 13px', 'x cap-height', 'x leading')
GSay ('-' * 66)
foreach ($c in @(0x2705, 0x26D4, 0x26A0, 0x1F534, 0x1F511, 0x2696, 0x27A4, 0x2460, 0x25CF)) {
    $g = Get-Geo $c $Manrope
    if (-not $g) { continue }
    GSay ('U+{0:X5} {1,-3} {2,10:N2} {3,10:N2} {4,14:N2} {5,9:N2}' -f $c, ([char]::ConvertFromUtf32($c)),
        ($g.W * 13.0 / 40.0), ($g.Ext * 13.0 / 40.0),
        (($g.Ext * 13.0 / 40.0) / ($mgt.CapsHeight * 13.0)), (($g.Ext * 13.0 / 40.0) / (13.0 * 1.62)))
}
GSay ''
GSay 'done'
exit 0
