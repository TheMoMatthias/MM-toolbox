# Which STEP of Install-SRPaneFace throws. The function catches its own failure
# and logs one line; that line names the value and not the operation, and the
# same value then reaches ShowDialog uncaught. Read-only.
Write-Host ''
Write-Host '  --- each step of the pane face, one at a time ---' -ForegroundColor Cyan
$dir = Join-Path $here 'fonts'
$base = [Uri]('file:///' + $dir.Replace('\','/').TrimEnd('/') + '/')
function Try-Step { param([string]$N, [scriptblock]$B)
    try { $v = & $B; Write-Host ("  ok    {0}" -f $N) -ForegroundColor Green; return $v }
    catch { Write-Host ("  FAIL  {0}  ->  {1}" -f $N, $_.Exception.Message) -ForegroundColor Red; return $null }
}
$fams = Try-Step 'GetFontFamilies' { [System.Windows.Media.Fonts]::GetFontFamilies($base) }
$fam  = Try-Step 'pick the Plex family' { [System.Windows.Media.FontFamily](@($fams | Where-Object { "$($_.Source)" -like '*#IBM Plex Mono*' })[0]) }
Write-Host ("        picked source = {0}" -f $(if ($fam) { $fam.Source } else { '<null>' }))
$null = Try-Step 'GetTypefaces on it' { @($fam.GetTypefaces()).Count }
$bareStr = '#IBM Plex Mono, Cascadia Mono, Consolas, Courier New, Segoe UI Emoji, Segoe UI Symbol'
$dotStr  = './#IBM Plex Mono, Cascadia Mono, Consolas, Courier New, Segoe UI Emoji, Segoe UI Symbol'
$bare = Try-Step 'construct the BARE composite' { New-Object System.Windows.Media.FontFamily $base, $bareStr }
$dot  = Try-Step 'construct the ./ composite'   { New-Object System.Windows.Media.FontFamily $base, $dotStr }
# The step the log points at: putting it into the resource dictionary the XAML
# already binds to. This is where a value that CONSTRUCTED can still be refused.
$null = Try-Step 'assign BARE to Resources[FontPane]' { $window.Resources['FontPane'] = $bare; 'set' }
$null = Try-Step 'assign BARE to Resources[FontMono]' { $window.Resources['FontMono'] = $bare; 'set' }
$null = Try-Step 'assign ./ to Resources[FontPane]'   { $window.Resources['FontPane'] = $dot;  'set' }
$null = Try-Step 'assign ./ to Resources[FontMono]'   { $window.Resources['FontMono'] = $dot;  'set' }
# And what a real element does with each - the render path ShowDialog reaches.
$null = Try-Step 'assign the SINGLE validated family to Resources[FontPane]' { $window.Resources['FontPane'] = $fam; 'set' }
$null = Try-Step 'and read it back' { "$($window.Resources['FontPane'].Source)" }
Write-Host ("        FontPane is now: {0}" -f "$($window.Resources['FontPane'].Source)")
foreach ($p in @(@{N='BARE';F=$bare}, @{N='./';F=$dot})) {
    $null = Try-Step ("measure a TextBlock in the {0} family" -f $p.N) {
        $tb = New-Object System.Windows.Controls.TextBlock
        $tb.FontFamily = $p.F
        $tb.Text = 'session-restore'
        $tb.Measure((New-Object System.Windows.Size 400, 100))
        $tb.DesiredSize.Width
    }
}
exit 0
