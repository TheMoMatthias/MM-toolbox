# ===========================================================================
# THE THREE THINGS A HEADLESS WINDOW CANNOT ANSWER.
#
# Dragging, a real mouse click and a real scroll all need an HWND, and an HWND
# normally means a window on somebody's screen taking their focus.
#
# 🔴 NOTHING HERE ACTIVATES, AND NOTHING MOVES THE CURSOR. ShowActivated=false
# means Windows shows the window without giving it focus; it is parked on a
# non-primary display when there is one, and far off-screen when there is not.
# The drag is verified by ASKING WINDOWS what it thinks the title bar is
# (WM_NCHITTEST), which is a message, not a gesture - no synthetic mouse input
# ever reaches the desktop. That matters: this suite has to be safe to run while
# somebody is playing a game on the other monitor.
# ===========================================================================
$fails = 0
function Fail { param($m) Write-Host "  FAIL  $m" -ForegroundColor Red; $script:fails++ }
function Pass { param($m) Write-Host "  ok    $m" -ForegroundColor Green }
function Note { param($m) Write-Host "        $m" -ForegroundColor DarkGray }

Add-Type -Namespace SRLive -Name W -MemberDefinition @'
[DllImport("user32.dll")] public static extern IntPtr SendMessage(IntPtr h, uint msg, IntPtr wp, IntPtr lp);
[DllImport("user32.dll")] public static extern bool SetWindowPos(IntPtr h, IntPtr after, int x, int y, int cx, int cy, uint flags);
'@

# Park it where it cannot be seen and cannot be focused.
$vx = [System.Windows.SystemParameters]::VirtualScreenLeft
$vy = [System.Windows.SystemParameters]::VirtualScreenTop
$pw = [System.Windows.SystemParameters]::PrimaryScreenWidth
$secondary = $false
# -Place wins when given: the operator knows which screen they are NOT using.
if ($env:SR_PLACE -and $env:SR_PLACE -match '^\s*(-?\d+)\s*,\s*(-?\d+)\s*$') {
    $left = [double]$Matches[1]; $vy = [double]$Matches[2]; $secondary = $true
    Note "placed by -Place at $([int]$left),$([int]$vy), unactivated"
} else {
    if ($vx -lt 0) { $left = $vx + 20; $secondary = $true }        # a display left of primary
    elseif ([System.Windows.SystemParameters]::VirtualScreenWidth -gt $pw + 10) { $left = $pw + 20; $secondary = $true }
    else { $left = -3000.0 }                                       # no second display: off-screen
    Note $(if ($secondary) { "parking the window on the secondary display at x=$([int]$left), unactivated" }
           else { 'no second display - parking the window off-screen entirely' })
}

$window.ShowActivated = $false
$window.WindowStartupLocation = 'Manual'
$window.Left = $left
$window.Top = $vy + 20
$window.Width = 1200; $window.Height = 800
$window.Show()
try {
    $helper = New-Object System.Windows.Interop.WindowInteropHelper $window
    $hwnd = $helper.Handle
    if ($hwnd -eq [IntPtr]::Zero) { Fail 'the window produced no HWND'; return }
    # SWP_NOACTIVATE | SWP_NOZORDER | SWP_NOSIZE - belt and braces on top of
    # ShowActivated, so nothing can steal the foreground.
    $null = [SRLive.W]::SetWindowPos($hwnd, [IntPtr]::Zero, [int]$left, [int]($vy + 20), 0, 0, 0x0010 -bor 0x0004 -bor 0x0001)
    for ($i = 0; $i -lt 3; $i++) {
        $window.Dispatcher.Invoke([System.Windows.Threading.DispatcherPriority]::Loaded, [action]{})
        Start-Sleep -Milliseconds 150
    }

    $src = [System.Windows.Interop.HwndSource]::FromHwnd($hwnd)
    function Screen-Of { param($el, [double]$dx, [double]$dy)
        $p = $el.PointToScreen((New-Object System.Windows.Point $dx, $dy))
        return $p
    }
    function HitTest { param([double]$sx, [double]$sy)
        $lp = [IntPtr](([int]$sy -shl 16) -bor ([int]$sx -band 0xFFFF))
        return [int][SRLive.W]::SendMessage($hwnd, 0x0084, [IntPtr]::Zero, $lp)   # WM_NCHITTEST
    }
    $HTCLIENT = 1; $HTCAPTION = 2

    Write-Host ''
    Write-Host '--- can Windows move this window? ---'
    # A point on the title bar, well away from anything interactive.
    $ptCap = Screen-Of $ui.TitleBar 300 20
    $hit = HitTest $ptCap.X $ptCap.Y
    if ($hit -eq $HTCAPTION) { Pass 'Windows reports the header as CAPTION - it drags, snaps and shakes like any window' }
    elseif ($hit -eq $HTCLIENT) { Fail 'the header reports as CLIENT - the window cannot be dragged at all' }
    else { Fail "the header hit-tests as $hit, neither caption nor client" }

    Write-Host ''
    Write-Host '--- and are the controls ON it still clickable? ---'
    # 🔴 THE OTHER HALF. Making the strip draggable is easy; making it draggable
    # WITHOUT swallowing the clicks on the buttons sitting in it is the part that
    # goes wrong, and it fails silently - the button simply stops responding.
    foreach ($n in @('WinClose', 'WinMax', 'WinMin', 'Rescan', 'NewSession', 'Search')) {
        $el = $ui.$n
        if ($el.ActualWidth -le 0) { Note "$n has no size yet - skipped"; continue }
        $p = Screen-Of $el ($el.ActualWidth / 2) ($el.ActualHeight / 2)
        $h = HitTest $p.X $p.Y
        if ($h -ne $HTCLIENT) { Fail "'$n' hit-tests as $h, not CLIENT - clicking it would drag the window instead" }
    }
    if (-not $fails) { Pass 'every control on the caption reports as CLIENT - they take their own clicks' }

    Write-Host ''
    Write-Host '--- the transcript follows the newest line ---'
    $sv = Get-PaneScroller
    if (-not $sv) { Fail 'no ScrollViewer in the transcript pane' }
    elseif ($sv.ScrollableHeight -le 20) { Note "the selected transcript is shorter than the pane - cannot pose the question here" }
    else {
        $sv.ScrollToEnd(); $window.Dispatcher.Invoke([System.Windows.Threading.DispatcherPriority]::Loaded, [action]{})
        if (-not (Test-AtBottom)) { Fail 'scrolled to the end and it does not believe it is at the end' }
        else { Pass 'at the newest line, it knows it' }
        Update-Document -Wait
        $window.Dispatcher.Invoke([System.Windows.Threading.DispatcherPriority]::Loaded, [action]{})
        Start-Sleep -Milliseconds 200
        $window.Dispatcher.Invoke([System.Windows.Threading.DispatcherPriority]::Loaded, [action]{})
        if (-not (Test-AtBottom)) { Fail 'a refresh while at the bottom did NOT keep us there' }
        else { Pass 'a refresh arriving while you are at the bottom keeps you there' }

        $sv.ScrollToVerticalOffset(0)
        $window.Dispatcher.Invoke([System.Windows.Threading.DispatcherPriority]::Loaded, [action]{})
        Update-Document -Wait
        $window.Dispatcher.Invoke([System.Windows.Threading.DispatcherPriority]::Loaded, [action]{})
        Start-Sleep -Milliseconds 200
        $window.Dispatcher.Invoke([System.Windows.Threading.DispatcherPriority]::Loaded, [action]{})
        if ($sv.VerticalOffset -gt 40) { Fail "a refresh dragged you back down to offset $([int]$sv.VerticalOffset) while you were reading" }
        else { Pass 'scrolled up, a refresh leaves you exactly where you were reading' }
    }

    Write-Host ''
    Write-Host '--- clicking a skill does not tear the picker down ---'
    # The bug: focus moving INTO the popup raised LostKeyboardFocus on the
    # composer, which closed the popup mid-click, so only the keyboard worked.
    $ui.SendBox.Text = '/rea'
    Update-SkillPop
    if (-not $script:skillOpen) { Note 'no skills matched - cannot pose the question' }
    else {
        $ui.SkillPop.IsOpen = $true
        $window.Dispatcher.Invoke([System.Windows.Threading.DispatcherPriority]::Loaded, [action]{})
        $item = $ui.SkillList.ItemContainerGenerator.ContainerFromIndex(0)
        if (-not $item) { Note 'the picker has no realised item to focus - cannot pose the question' }
        else {
            $null = $item.Focus()
            $window.Dispatcher.Invoke([System.Windows.Threading.DispatcherPriority]::Loaded, [action]{})
            if (-not $script:skillOpen) { Fail 'focusing an item CLOSED the picker - a mouse click could never complete' }
            else { Pass 'focus moving into the picker leaves it open, so a click can land' }
            $null = Complete-Skill
            if ($ui.SendBox.Text -notmatch '^/\S+ $') { Fail "completing produced '$($ui.SendBox.Text)'" }
            else { Pass "and completes to '$($ui.SendBox.Text.Trim())'" }
        }
    }
    $ui.SendBox.Text = ''
    Update-SkillPop
} finally {
    try { $window.Hide() } catch { }
    try { $window.Close() } catch { }
}

Write-Host ''
if ($fails) { Write-Host "$fails FAILURE(S)" -ForegroundColor Red; exit 1 }
Write-Host 'the window behaves like a window' -ForegroundColor Green
exit 0
