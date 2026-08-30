# ===========================================================================
# HOW THE TEXT ACTUALLY RENDERS - four settings, the same words, magnified.
#
# By name only (`run-tests.ps1 -Only type`). It asserts nothing: WPF's text
# rendering is a LOOK, and the only honest way to choose between the settings
# is to put them side by side at real size and then at 4x, where the individual
# pixels of the antialiasing are visible.
#
# It exists because "the font looks smooth in a browser and rough in the tool"
# is a real difference with three candidate causes - the formatting mode, the
# rendering mode, and gamma - and window2.xaml already carries a DELIBERATE
# decision on one of them (Grayscale over ClearType, to avoid colour fringing on
# a dark ground). A decision that was reasoned about once should be re-opened
# with evidence, not with a preference.
#
#   SR_TYPE_OUT=<path>
# ===========================================================================

$tyOut = $env:SR_TYPE_OUT
if (-not $tyOut) { $tyOut = Join-Path $SR_StateDir ('design\type-{0}.png' -f (Get-Date -Format 'HHmmss')) }
$tyDir = Split-Path -Parent $tyOut
if ($tyDir -and -not (Test-Path -LiteralPath $tyDir)) { $null = New-Item -ItemType Directory -Path $tyDir -Force }

$tyCombos = @(
    @{ Name = 'Ideal + Grayscale   (what ships today)'; Fmt = 'Ideal';   Ren = 'Grayscale' },
    @{ Name = 'Display + Grayscale';                    Fmt = 'Display'; Ren = 'Grayscale' },
    @{ Name = 'Ideal + ClearType';                      Fmt = 'Ideal';   Ren = 'ClearType' },
    @{ Name = 'Display + ClearType';                    Fmt = 'Display'; Ren = 'ClearType' }
)

function New-TyLine { param([string]$Text, [double]$Size, $Brush, [switch]$Mono, [switch]$Semi)
    $t = New-Object System.Windows.Controls.TextBlock
    $t.Text = $Text
    $t.FontSize = $Size
    $t.Foreground = $Brush
    if ($Mono) { $t.FontFamily = $script:MonoFace } else { $t.FontFamily = $script:UiFace }
    if ($Semi) { $t.FontWeight = $FW_Semi }
    $t.Margin = New-Object System.Windows.Thickness 0, 0, 0, 5
    return $t
}

function New-TySample { param($Combo)
    $sp = New-Object System.Windows.Controls.StackPanel
    $sp.Margin = New-Object System.Windows.Thickness 22, 16, 22, 18
    [System.Windows.Media.TextOptions]::SetTextFormattingMode($sp, $Combo.Fmt)
    [System.Windows.Media.TextOptions]::SetTextRenderingMode($sp, $Combo.Ren)

    $null = $sp.Children.Add((New-TyLine -Text $Combo.Name -Size 10.5 -Brush $Pal.Ask -Semi))
    $null = $sp.Children.Add((New-TyLine -Text 'The A7 half is enforced at the schema level and already being populated.' -Size 16 -Brush $Pal.TextHigh))
    $null = $sp.Children.Add((New-TyLine -Text 'Backfill: route the 9 tools through the door (Recommended)' -Size 13.5 -Brush $Pal.TextMax -Semi))
    $null = $sp.Children.Add((New-TyLine -Text 'I8 has two clauses left unscoped or unbuilt - which do I take now?' -Size 12 -Brush $Pal.TextMid))
    $null = $sp.Children.Add((New-TyLine -Text 'git diff --shortstat HEAD   ref.plane.backfill_tool' -Size 12.5 -Brush $Pal.TextHigh -Mono))
    return $sp
}

$tyStack = New-Object System.Windows.Controls.StackPanel
$tyStack.Background = $window.FindResource('Panel')
foreach ($ty in $tyCombos) {
    $null = $tyStack.Children.Add((New-TySample $ty))
    $sep = New-Object System.Windows.Shapes.Rectangle
    $sep.Height = 1
    $sep.Fill = $window.FindResource('Hairline')
    $null = $tyStack.Children.Add($sep)
}

$tyW = 760.0
$tyStack.Width = $tyW
$tyStack.Measure((New-Object System.Windows.Size $tyW, 2000))
$tyStack.Arrange((New-Object System.Windows.Rect 0, 0, $tyW, $tyStack.DesiredSize.Height))
$tyStack.UpdateLayout()
$tyH = [double]$tyStack.DesiredSize.Height

$tyBmp = New-Object System.Windows.Media.Imaging.RenderTargetBitmap([int]$tyW, [int]$tyH, 96, 96,
        [System.Windows.Media.PixelFormats]::Pbgra32)
$tyBmp.Render($tyStack)

# 🔴 MAGNIFIED WITH NEAREST NEIGHBOUR, and that is the whole point. Rendering
# the SAME text at 4x the font size would change the antialiasing being judged;
# blowing up the RENDERED PIXELS shows the antialiasing that actually shipped.
$tyZoom = 4.0
$tyDv = New-Object System.Windows.Media.DrawingVisual
$tyDc = $tyDv.RenderOpen()
try {
    $tyDc.DrawRectangle($window.FindResource('Ink'), $null, (New-Object System.Windows.Rect 0, 0, ($tyW * 2 + 30), ($tyH * $tyZoom)))
    $tyDc.DrawImage($tyBmp, (New-Object System.Windows.Rect 10, 10, $tyW, $tyH))
    $scaled = New-Object System.Windows.Media.Imaging.TransformedBitmap
    $scaled.BeginInit()
    $scaled.Source = $tyBmp
    $scaled.Transform = New-Object System.Windows.Media.ScaleTransform $tyZoom, $tyZoom
    $scaled.EndInit()
    [System.Windows.Media.RenderOptions]::SetBitmapScalingMode($tyDv, 'NearestNeighbor')
    $tyDc.DrawImage($scaled, (New-Object System.Windows.Rect ($tyW + 20), 10, ($tyW * $tyZoom), ($tyH * $tyZoom)))
} finally { $tyDc.Close() }

$tyFinalW = [int]($tyW + 20 + $tyW * $tyZoom + 10)
$tyFinalH = [int]([Math]::Max($tyH + 20, $tyH * $tyZoom + 20))
$tyRtb = New-Object System.Windows.Media.Imaging.RenderTargetBitmap($tyFinalW, $tyFinalH, 96, 96,
        [System.Windows.Media.PixelFormats]::Pbgra32)
$tyRtb.Render($tyDv)

$tyEnc = New-Object System.Windows.Media.Imaging.PngBitmapEncoder
$tyEnc.Frames.Add([System.Windows.Media.Imaging.BitmapFrame]::Create($tyRtb))
$tyFs = [System.IO.File]::Create($tyOut)
try { $tyEnc.Save($tyFs) } finally { $tyFs.Dispose() }

Write-Host ("  ok    drew {0}  {1}x{2}  ({3} settings, 1:1 left, {4}x right)" -f $tyOut, $tyFinalW, $tyFinalH, $tyCombos.Count, [int]$tyZoom)
exit 0
