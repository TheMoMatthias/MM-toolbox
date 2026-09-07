# ===========================================================================
#  REPRODUCE THE LAUNCH FAILURE, WHICH EVERY OTHER HARNESS HERE CANNOT SEE.
#
#  The operator gets, on starting the tool:
#
#    Exception calling "ShowDialog" with "0" argument(s): "'#IBM Plex Mono,
#    Cascadia Mono, Consolas, Courier New, Segoe UI Emoji, Segoe UI Symbol' is
#    not a valid value for property 'FontFamily'."
#
#  gui2 is green and render-driver SHOWS the window successfully, because every
#  harness in this repo splices the script at `$null = $window.ShowDialog()` and
#  keeps only what comes before it. The one line none of them run is the one
#  that fails. That is the hole this file exists to close.
#
#  So: same fencing as render-driver - every launch, send and write replaced by
#  a counter BEFORE anything is shown - then ShowDialog for real, with a timer
#  that closes the window a moment later. The exception is caught and printed
#  with its full stack, which is what no other run can produce.
#
#  READ-ONLY. Nothing is launched, killed, typed into, saved or sent.
# ===========================================================================
$script:dangerHits = @{}
function Trip { param([string]$W) $script:dangerHits[$W] = [int]$script:dangerHits[$W] + 1 }
function Start-SRSession      { Trip 'Start-SRSession';      return $null }
function Start-AskSend        { Trip 'Start-AskSend';        return $null }
function Save-SRRegistry      { Trip 'Save-SRRegistry';      return $true }
function Save-RegistryOrAsk   { Trip 'Save-RegistryOrAsk';   return $true }
function Save-SRConfigValue   { Trip 'Save-SRConfigValue';   return $true }
function Save-SRConfigLater   { Trip 'Save-SRConfigLater';   return $true }
function Save-SRConfigWrites  { Trip 'Save-SRConfigWrites';  return $true }
function Set-SRConfigOnDisk   { Trip 'Set-SRConfigOnDisk';   return $true }
function Invoke-SRRescan      { Trip 'Invoke-SRRescan';      return @{ Scanned = $false; Why = 'fenced' } }

Write-Host ''
Write-Host '  --- does the window actually open? ---' -ForegroundColor Cyan

# Off the desktop and unclickable, exactly as render-driver leaves it.
$window.WindowStartupLocation = 'Manual'
$window.Left = -32000
$window.Top  = -32000
$window.ShowInTaskbar = $false
try { $window.Content.IsHitTestVisible = $false } catch { }

# Close it a moment after it opens, so ShowDialog returns instead of blocking.
$t = New-Object System.Windows.Threading.DispatcherTimer
$t.Interval = [TimeSpan]::FromMilliseconds(700)
$t.Add_Tick({
    $t.Stop()
    try { $window.Close() } catch { }
})
$t.Start()

$ok = $false
try {
    $null = $window.ShowDialog()
    $ok = $true
    Write-Host '  ok    the window opened and closed cleanly' -ForegroundColor Green
} catch {
    Write-Host '  FAIL  ShowDialog threw:' -ForegroundColor Red
    Write-Host ("        {0}" -f $_.Exception.Message) -ForegroundColor Red
    # 🔑 THE INNER EXCEPTION IS THE WHOLE POINT. WPF wraps the real failure, and
    # the operator's dialog shows only the outer message - which names the value
    # and not the property, the element or the line that carries it.
    $inner = $_.Exception.InnerException
    $depth = 0
    while ($inner -and $depth -lt 6) {
        Write-Host ("        inner[{0}] {1}: {2}" -f $depth, $inner.GetType().Name, $inner.Message) -ForegroundColor Yellow
        if ($inner -is [System.Windows.Markup.XamlParseException]) {
            Write-Host ("        line {0} pos {1}" -f $inner.LineNumber, $inner.LinePosition) -ForegroundColor Yellow
        }
        $inner = $inner.InnerException
        $depth++
    }
    Write-Host '        --- stack ---' -ForegroundColor DarkGray
    Write-Host ("{0}" -f $_.ScriptStackTrace) -ForegroundColor DarkGray
    Write-Host ("{0}" -f $_.Exception.StackTrace) -ForegroundColor DarkGray
}

# What the faces actually resolved to, printed either way - if the window did
# open, this is still the evidence about the value in the message.
foreach ($k in @('FontPane','FontText','FontMono','FontDisplay','FontSmall')) {
    $v = $null
    try { $v = $window.Resources[$k] } catch { }
    if ($null -eq $v) { try { $v = $window.FindResource($k) } catch { } }
    $src = ''
    $base = ''
    try { $src = "$($v.Source)" } catch { }
    try { $base = "$($v.BaseUri)" } catch { }
    Write-Host ("        {0,-12} type={1,-12} base={2}" -f $k, $(if ($v) { $v.GetType().Name } else { 'null' }), $base)
    Write-Host ("        {0,-12} source={1}" -f '', $src)
}

if ($script:dangerHits.Count) {
    foreach ($k in $script:dangerHits.Keys) {
        Write-Host ("        (fenced) {0} was reached {1} time(s)" -f $k, $script:dangerHits[$k]) -ForegroundColor DarkGray
    }
}
if (-not $ok) { exit 1 }
exit 0
