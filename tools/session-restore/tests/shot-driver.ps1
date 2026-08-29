# ===========================================================================
# THE REAL WINDOW, DRAWN TO A PNG, NEVER SHOWN.
#
# By name only (`run-tests.ps1 -Only shot`) and deliberately not part of "all
# suites passed": it renders the operator's own conversations at real density,
# which is where every clipped pill, mojibaked caption and column that quietly
# echoes its neighbour has actually hidden. A layout change is looked at, not
# asserted.
#
#   SR_SHOT_SURFACE=manage   draw the session manager instead of the work surface
#   SR_SHOT_SIZE=1200x800    draw at another size, to see the adaptive breakpoints
#   SR_SHOT_OUT=<path>       where to write it
#
# 🪤 RENDER THE CONTENT, NOT THE WINDOW, AND PAINT THE GROUND FIRST. A Window
# that has never been shown has no rendered visual root, so RenderTargetBitmap
# over it comes back blank; and the dark background belongs to the WINDOW, so
# the content alone renders transparent - which every viewer shows as white.
# ===========================================================================
$W = 1480.0; $H = 980.0
if ($env:SR_SHOT_SIZE -and $env:SR_SHOT_SIZE -match '^(\d+)x(\d+)$') {
    $W = [double]$Matches[1]; $H = [double]$Matches[2]
}
$out = $env:SR_SHOT_OUT
if (-not $out) { $out = Join-Path $SR_StateDir ('shots\{0}.png' -f (Get-Date -Format 'yyyyMMdd-HHmmss')) }

if ($env:SR_SHOT_SURFACE -eq 'manage') { $ui.ModeManage.IsChecked = $true; Set-Surface 'manage' }

$window.Width = $W; $window.Height = $H
$root = $window.Content
if (-not $root.Background -or $root.Background -eq [System.Windows.Media.Brushes]::Transparent) {
    $root.Background = $window.Background
}
foreach ($pass in 1, 2) {
    $root.Measure((New-Object System.Windows.Size $W, $H))
    $root.Arrange((New-Object System.Windows.Rect 0, 0, $W, $H))
    $root.UpdateLayout()
    [System.Windows.Threading.Dispatcher]::CurrentDispatcher.Invoke(
        [System.Windows.Threading.DispatcherPriority]::Loaded, [action]{})
}

$dir = Split-Path -Parent $out
if ($dir -and -not (Test-Path -LiteralPath $dir)) { $null = New-Item -ItemType Directory -Path $dir -Force }
$rtb = New-Object System.Windows.Media.Imaging.RenderTargetBitmap([int]$W, [int]$H, 96, 96,
        [System.Windows.Media.PixelFormats]::Pbgra32)
$rtb.Render($root)
$enc = New-Object System.Windows.Media.Imaging.PngBitmapEncoder
$enc.Frames.Add([System.Windows.Media.Imaging.BitmapFrame]::Create($rtb))
$fs = [System.IO.File]::Create($out)
try { $enc.Save($fs) } finally { $fs.Dispose() }

Write-Host ("  ok    drew {0}  {1}x{2}" -f $out, [int]$W, [int]$H)
Write-Host ("        surface={0}  rail={1}  list={2}  rows={3}" -f `
    $script:surface, $ui.RailCol.Width.Value, $ui.ListCol.Width.Value, @($ui.SessionList.Items).Count)
exit 0
