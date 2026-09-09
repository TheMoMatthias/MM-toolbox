# ===========================================================================
# spacing-bench - what the reading pane actually puts between two lines, in
# pixels, against what the terminal puts between the same two lines.
#
# READ-ONLY. Builds the shipped window, never shows it, renders one document.
#
# 🔴 IT MEASURES THE RENDERED DOCUMENT, NOT THE SETTINGS. The pane's leading is
# a factor on the font size AND every source line is its own Paragraph with its
# own margin, so the number that matters - baseline to baseline - is neither of
# them and cannot be read off either. Measured 2026-09-09 from a capture of a
# live Windows Terminal: 19,8 px within a paragraph at a ~17 px font, which is
# 1,16 - exactly Cascadia Mono's own LineSpacing, and one blank line (37,5 px)
# between paragraphs.
# ===========================================================================
$ErrorActionPreference = 'Continue'

function SB-Say { param([string]$T) Write-Host $T }

# The terminal's own numbers, measured rather than assumed. Cascadia Mono
# reports LineSpacing 1,1621 em and the capture agrees at 19,8/17,0 = 1,16.
$sbTermRatio = 1.1621

SB-Say ''
SB-Say '=== spacing-bench: what sits between two lines ==='

# A message with several plain source lines in one turn - the shape the
# complaint is about. Deliberately no blank lines: consecutive lines of ONE
# paragraph in the terminal sit exactly one pitch apart.
$sbText = @(
    'The first line of a reply that runs on for a while and keeps going.'
    'The second line of the same reply, immediately after the first one.'
    'A third line, still the same reply, still no blank line between them.'
    'And a fourth, so there are three gaps to average over rather than one.'
) -join "`n"

function Measure-SBPitch {
    param([double]$Lead, [double]$Pad, [double]$Size)
    # Rebuild a document with the candidate settings and measure it.
    $script:readLead = $Lead
    $script:readSize = $Size
    $script:PaneSize = $Size
    $doc = New-Object System.Windows.Documents.FlowDocument
    $doc.PagePadding = New-Object System.Windows.Thickness 0
    $doc.FontFamily = $script:ProseFace
    $doc.FontSize = $Size
    $script:SR_ProsePad = $Pad
    # 🪤 Out-Null. Add-ReadProse emits, so the function's return value became an
    # Object[] of its leavings plus the average, and the format string divided an
    # array. A measurement that cannot be printed is not a measurement.
    Add-ReadProse -Doc $doc -Text $sbText -Brush $Pal.TextHigh -Size $Size -Line $Lead -Kind '' | Out-Null
    $ui.PaneDoc.Document = $doc
    $ui.PaneDoc.Width = 900
    $ui.PaneDoc.Measure((New-Object System.Windows.Size 900, 4000))
    $ui.PaneDoc.Arrange((New-Object System.Windows.Rect 0, 0, 900, 4000))
    $ui.PaneDoc.UpdateLayout()
    $null = [System.Windows.Threading.Dispatcher]::CurrentDispatcher.Invoke(
        [System.Windows.Threading.DispatcherPriority]::Loaded, [action]{})

    # Baseline to baseline, off the document's own text pointers. The rect of
    # the first character of each block is the honest answer; the leading and
    # the margin are both already in it.
    $tops = New-Object System.Collections.Generic.List[double]
    foreach ($blk in $doc.Blocks) {
        $tp = $blk.ContentStart
        if (-not $tp) { continue }
        $r = $null
        try { $r = $tp.GetCharacterRect([System.Windows.Documents.LogicalDirection]::Forward) } catch { continue }
        if ($r -and -not [double]::IsInfinity($r.Top)) { $null = $tops.Add([double]$r.Top) }
    }
    if ($tops.Count -lt 2) { return -1.0 }
    $d = New-Object System.Collections.Generic.List[double]
    for ($i = 1; $i -lt $tops.Count; $i++) { $null = $d.Add($tops[$i] - $tops[$i - 1]) }
    $s = 0.0
    foreach ($x in $d) { $s += $x }
    return [double]($s / $d.Count)
}

$sbLeadWas = $script:readLead
$sbSizeWas = $script:readSize
$sbPaneWas = $script:PaneSize
$sbDocWas  = $ui.PaneDoc.Document
$sbSize = [double]$script:Type.Pane

SB-Say ''
SB-Say ('  the pane draws at {0} px; the terminal measured 1,16 x its own font' -f $sbSize)
SB-Say ('  so the terminal-equivalent pitch here would be {0:N1} px' -f ($sbSize * $sbTermRatio))
SB-Say ('  LIVE SETTING: lead {0:N2}, pad {1:N1}  ({2})' -f $SR_LeadFactor, $SR_ProsePad, "$((Get-SRConfig).lineSpacing)")
SB-Say ''
SB-Say '  lead    pad     pitch      x font   vs terminal'
SB-Say '  ----------------------------------------------'
try {
    foreach ($sbCase in @(
        @{ L = 1.62; P = 3.0; N = 'what it was before 2026-09-09' }
        @{ L = 1.62; P = 0.0; N = 'that leading, margins off' }
        @{ L = 1.50; P = 0.0; N = '' }
        @{ L = 1.45; P = 0.0; N = '' }
        @{ L = 1.40; P = 0.0; N = '' }
        @{ L = 1.35; P = 0.0; N = '' }
        @{ L = 1.33; P = 0.0; N = "the face's own" }
    )) {
        # 🪤 THE LAST ELEMENT, and a cast. A PowerShell function returns everything
        # it emitted, not what it returned, so any stray output turns the answer
        # into an Object[] and the format string divides an array.
        $sbP = [double](@(Measure-SBPitch -Lead ([Math]::Round($sbSize * $sbCase.L, 1)) -Pad $sbCase.P -Size $sbSize))[-1]
        if ($sbP -lt 0) { SB-Say ('  {0,4:N2}  {1,4:N1}    could not measure' -f $sbCase.L, $sbCase.P); continue }
        $sbMark = ''
        if ([Math]::Abs($sbCase.L - $SR_LeadFactor) -lt 0.005 -and [Math]::Abs($sbCase.P - $SR_ProsePad) -lt 0.005) { $sbMark = '   <-- LIVE' }
        SB-Say ('  {0,4:N2}  {1,4:N1}   {2,6:N1} px   {3,5:N2}   {4,5:N2}x  {5}{6}' -f `
                $sbCase.L, $sbCase.P, $sbP, ($sbP / $sbSize), ($sbP / ($sbSize * $sbTermRatio)), $sbCase.N, $sbMark)
    }
} finally {
    $script:SR_ProsePad = 3.0
    $script:readLead = $sbLeadWas
    $script:readSize = $sbSizeWas
    $script:PaneSize = $sbPaneWas
    $ui.PaneDoc.Document = $sbDocWas
}

# 🔴 AND THE PARAGRAPH BREAK, which is what makes pad 0 safe or not. In the
# terminal a paragraph break is ONE BLANK LINE - 37,5 px against 19,8, measured
# from the capture, i.e. exactly 2x the pitch. If a blank source line does not
# produce an empty Paragraph of full height here, then the 3px margin was the
# only thing separating paragraphs and removing it glues them together.
SB-Say ''
SB-Say '--- what a blank line between paragraphs is worth ---'
$sbTwo = "First paragraph, one line only.`n`nSecond paragraph, after one blank line."
function Measure-SBGap {
    param([double]$Lead, [double]$Pad, [double]$Size)
    $script:readLead = $Lead; $script:readSize = $Size; $script:PaneSize = $Size
    $script:SR_ProsePad = $Pad
    $doc = New-Object System.Windows.Documents.FlowDocument
    $doc.PagePadding = New-Object System.Windows.Thickness 0
    $doc.FontFamily = $script:ProseFace
    $doc.FontSize = $Size
    Add-ReadProse -Doc $doc -Text $sbTwo -Brush $Pal.TextHigh -Size $Size -Line $Lead -Kind '' | Out-Null
    $ui.PaneDoc.Document = $doc
    $ui.PaneDoc.Width = 900
    $ui.PaneDoc.Measure((New-Object System.Windows.Size 900, 4000))
    $ui.PaneDoc.Arrange((New-Object System.Windows.Rect 0, 0, 900, 4000))
    $ui.PaneDoc.UpdateLayout()
    $null = [System.Windows.Threading.Dispatcher]::CurrentDispatcher.Invoke(
        [System.Windows.Threading.DispatcherPriority]::Loaded, [action]{})
    $tops = New-Object System.Collections.Generic.List[double]
    foreach ($blk in $doc.Blocks) {
        $tp = $blk.ContentStart
        if (-not $tp) { continue }
        $r = $null
        try { $r = $tp.GetCharacterRect([System.Windows.Documents.LogicalDirection]::Forward) } catch { continue }
        if ($r -and -not [double]::IsInfinity($r.Top)) { $null = $tops.Add([double]$r.Top) }
    }
    if ($tops.Count -lt 2) { return -1.0 }
    return [double]($tops[$tops.Count - 1] - $tops[0])
}
SB-Say ('  blocks a two-paragraph message makes, and the first-to-last drop:')
foreach ($sbG in @(@{ L = 1.62; P = 3.0 }, @{ L = 1.45; P = 0.0 }, @{ L = 1.35; P = 0.0 })) {
    $g = [double](@(Measure-SBGap -Lead ([Math]::Round($sbSize * $sbG.L, 1)) -Pad $sbG.P -Size $sbSize))[-1]
    SB-Say ('  lead {0,4:N2}  pad {1,3:N1}   first to last {2,6:N1} px   ({3,4:N2} x the pitch)' -f `
            $sbG.L, $sbG.P, $g, $(if ($sbSize * $sbG.L -gt 0) { $g / ($sbSize * $sbG.L) } else { 0 }))
}
$script:SR_ProsePad = 3.0
$script:readLead = $sbLeadWas
$script:readSize = $sbSizeWas
$script:PaneSize = $sbPaneWas
$ui.PaneDoc.Document = $sbDocWas

SB-Say ''
SB-Say '=== spacing-bench done ==='
exit 0
