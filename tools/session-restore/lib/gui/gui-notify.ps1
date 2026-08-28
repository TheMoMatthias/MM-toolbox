#requires -Version 5.1
# ===========================================================================
# THE NOTIFIER
#
# Reaching the operator when they are not looking: the tray, the toast, the taskbar flash and the NEEDS YOU strip.
#
# DOT-SOURCED BY sessions-gui.ps1, into its own scope, AFTER $window, $Pal and
# $ui exist - everything here reads them at CALL time, never at load time.
#
# Read tools/session-restore/CONTEXT.md before changing anything in here. The
# traps in it are not hypothetical: every one of them shipped.
# ===========================================================================

# ---------------------------------------------------------------------------
# THE TRAY, THE TOAST, AND THE THROTTLE
#
# The point of the whole tool is that you should not have to be looking at it.
# That needs three things and they are separate:
#
#   TRAY      the window can go away without the process going away, so the
#             watching keeps happening while you are doing something else.
#   TOAST     something reaches you when a session stops and waits. Fired ONLY
#             on the transition into waiting, never re-fired for one that has
#             been waiting since you last looked - a notifier that repeats is a
#             notifier you turn off.
#   THROTTLE  hidden, it stops rendering entirely and only keeps asking the one
#             question that could produce a toast. A window nobody is looking at
#             has no business rebuilding 86 rows every six seconds.
#
# ShowBalloonTip rather than Windows.UI.Notifications: on Windows 10 and 11 the
# shell renders a balloon AS a toast, and it needs no AppUserModelID, no shortcut
# in the Start Menu and no WinRT interop from PowerShell 5.1 - three things that
# each fail silently on some machine. Everything here is wrapped: a notifier that
# takes the tool down with it is worse than no notifier.
# ---------------------------------------------------------------------------
$script:tray        = $null
$script:trayCount   = -1
$script:hidden      = $false
$script:toastPrev   = @{}

function Initialize-Tray {
    if ($script:tray) { return }
    try {
        Add-Type -AssemblyName System.Windows.Forms -ErrorAction Stop
        Add-Type -AssemblyName System.Drawing -ErrorAction Stop
    } catch { Write-SRLog "tray unavailable: $($_.Exception.Message)"; return }
    try {
        $ni = New-Object System.Windows.Forms.NotifyIcon
        $ni.Text = 'Claude sessions'
        $ni.Visible = $true
        $ni.Add_MouseClick({ param($sender, $e)
            if ($e.Button -eq [System.Windows.Forms.MouseButtons]::Left) {
                $window.Dispatcher.Invoke([action]{ Show-FromTray })
            }
        })
        $menu = New-Object System.Windows.Forms.ContextMenuStrip
        $null = $menu.Items.Add('Show', $null, { $window.Dispatcher.Invoke([action]{ Show-FromTray }) })
        $null = $menu.Items.Add('Quit', $null, { $window.Dispatcher.Invoke([action]{ $script:reallyClose = $true; $window.Close() }) })
        $ni.ContextMenuStrip = $menu
        $script:tray = $ni
        Update-TrayBadge
    } catch { Write-SRLog "tray failed: $($_.Exception.Message)" }
}

# THE COUNT IS DRAWN, not decorated onto a static icon: a tray icon that always
# looks the same is a tray icon you stop seeing. Redrawn only when the number
# changes - GDI handles are not free and this is called on every probe.
function Update-TrayBadge {
    if (-not $script:tray) { return }
    $wait = @(Get-WaitingNow).Count
    if ($wait -eq $script:trayCount) { return }
    $script:trayCount = $wait
    try {
        $bmp = New-Object System.Drawing.Bitmap 32, 32
        $g = [System.Drawing.Graphics]::FromImage($bmp)
        try {
            $g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
            $g.TextRenderingHint = [System.Drawing.Text.TextRenderingHint]::AntiAlias
            $g.Clear([System.Drawing.Color]::Transparent)
            $back = $(if ($wait) { [System.Drawing.Color]::FromArgb(246, 246, 246) } else { [System.Drawing.Color]::FromArgb(110, 110, 110) })
            $brush = New-Object System.Drawing.SolidBrush $back
            $g.FillEllipse($brush, 1, 1, 30, 30)
            if ($wait -gt 0) {
                $txt = $(if ($wait -gt 9) { '9+' } else { "$wait" })
                $fs = $(if ($wait -gt 9) { 15 } else { 19 })
                $font = New-Object System.Drawing.Font 'Segoe UI', $fs, ([System.Drawing.FontStyle]::Bold), ([System.Drawing.GraphicsUnit]::Pixel)
                $fmt = New-Object System.Drawing.StringFormat
                $fmt.Alignment = 'Center'; $fmt.LineAlignment = 'Center'
                $ink = New-Object System.Drawing.SolidBrush ([System.Drawing.Color]::FromArgb(12, 12, 12))
                $g.DrawString($txt, $font, $ink, (New-Object System.Drawing.RectangleF 0, 1, 32, 31), $fmt)
                $ink.Dispose(); $font.Dispose(); $fmt.Dispose()
            }
            $brush.Dispose()
        } finally { $g.Dispose() }
        $old = $script:tray.Icon
        $script:tray.Icon = [System.Drawing.Icon]::FromHandle($bmp.GetHicon())
        $script:tray.Text = $(if ($wait) { "Claude sessions - $wait waiting for you" } else { 'Claude sessions - nothing waiting' })
        if ($old) { try { $old.Dispose() } catch { } }
        $bmp.Dispose()
    } catch { Write-SRLog "tray badge failed: $($_.Exception.Message)" }
}

# ONLY ON THE TRANSITION. A conversation that has been waiting since before you
# looked away is not news, and re-announcing it is how a notifier gets muted.
function Show-Toast {
    param([string]$Title, [string]$Body)
    if (-not $script:tray) { return }
    try {
        $script:tray.BalloonTipTitle = $Title
        $script:tray.BalloonTipText  = $Body
        $script:tray.BalloonTipIcon  = [System.Windows.Forms.ToolTipIcon]::None
        $script:tray.ShowBalloonTip(8000)
    } catch { Write-SRLog "toast failed: $($_.Exception.Message)" }
}

function Update-Toasts {
    $now = @(Get-WaitingNow)
    $fresh = @($now | Where-Object { -not $script:toastPrev[$_.Id] })
    $next = @{}
    foreach ($x in $now) { $next[$x.Id] = $true }
    $first = ($script:toastPrev.Count -eq 0)
    $script:toastPrev = $next
    # Nothing on the first pass: everything is "new" then, and thirteen toasts
    # at startup is the definition of a notifier nobody keeps on.
    if ($first -or -not $fresh.Count) { return }
    if ($window.IsActive -and -not $script:hidden) { return }
    if ($fresh.Count -eq 1) {
        Show-Toast $fresh[0].Label 'has stopped and is waiting for you'
    } else {
        Show-Toast "$($fresh.Count) sessions are waiting for you" (@($fresh | ForEach-Object { $_.Label }) -join ', ')
    }
}

function Hide-ToTray {
    Initialize-Tray
    if (-not $script:tray) { return }   # no tray, no hiding: a window nobody can get back is a lost window
    $script:hidden = $true
    $window.Hide()
    if ($script:fastTimer) { $script:fastTimer.Stop() }
    Set-Status 'watching from the tray' 'info'
}

function Show-FromTray {
    $script:hidden = $false
    $window.Show()
    $window.WindowState = [System.Windows.WindowState]::Normal
    $null = $window.Activate()
    if ($script:fastTimer) { $script:fastTimer.Start() }
    Update-List
}

function Start-TaskbarFlash {
    try {
        $h = (New-Object System.Windows.Interop.WindowInteropHelper($window)).Handle
        if ($h -ne [IntPtr]::Zero) { [SRGui.Flash]::Start($h) }
    } catch { }
}
function Stop-TaskbarFlash {
    try {
        $h = (New-Object System.Windows.Interop.WindowInteropHelper($window)).Handle
        if ($h -ne [IntPtr]::Zero) { [SRGui.Flash]::Stop($h) }
    } catch { }
}

# --- NEEDS YOU -------------------------------------------------------------
# Which conversations are at their prompt waiting for the operator RIGHT NOW --
# state 'waiting' and not stale. The DOING column already says this per row, but
# only if you happen to be looking at the right row: with ~127 conversations the
# one that wants you is usually somewhere off screen. This is the same
# information, gathered where it cannot be missed.
#
# Deliberately NOT a toast. The operator asked for the quiet version, and a
# window that shouts is a window you end up closing.
$script:needsPrev = @{}

function Get-WaitingNow {
    $out = @()
    foreach ($d in @($script:dirs)) {
        foreach ($s in @(Get-Visible $d)) {
            if (-not $s.sessionId) { continue }
            $cv = Get-Conv $s
            if (-not $cv) { continue }
            # Needs, not merely 'waiting': claude distinguishes a session that
            # is asking for something from one simply sitting at its prompt, and
            # a band that lists all seven idle sessions is a band nobody reads.
            if (-not $cv.Needs) { continue }
            $out += [PSCustomObject]@{
                Id    = "$($s.sessionId)".ToLower()
                Key   = "$($d.path)|$(Get-LaneName $s)|$($s.sessionId)"
                Label = "$(Get-SessionTitle $s $d)"
                Tip   = "$(Get-SessionTitle $s $d) is at its prompt in $($d.path).`n$($cv.Detail)." +
                        $(if ($cv.LastPrompt) { "`nlast prompt: $($cv.LastPrompt)" } else { '' })
            }
        }
    }
    # NO LEADING COMMA, AND THIS ONE COST TWO BUGS AT ONCE.
    #
    # ",@(...)" exists to stop a ONE-element array unrolling to a scalar. What it
    # also does is make @(f) at the call site an array of ONE element holding
    # everything - so it only works if every caller assigns first and wraps
    # second, forever. Update-NeedsBand did. The tray badge and the toaster,
    # written later, did the obvious thing:
    #
    #     $wait = @(Get-WaitingNow).Count     -> always 1, whatever is waiting
    #     $now  = @(Get-WaitingNow)           -> one element whose .Id is null,
    #                                            so nothing was ever "fresh" and
    #                                            no toast ever fired
    #
    # This is the sixth time this pattern has bitten this codebase. The comma is
    # protection against a caller that pipes a bare return; @(...) at the call
    # site is protection against everything, and every caller here already does
    # it. Returning the plain array is right at zero, one and many.
    return $out
}

function Update-NeedsBand {
    # The inbox has NEEDS YOU as its first band, so the strip above the list
    # would be the same names twice on one screen. It belongs to the tree, where
    # a cross-project band genuinely cannot be a node.
    if ($script:viewMode -eq 'inbox') {
        $ui.NeedsBand.Visibility = $V_Hide
        return
    }
    $now = @(Get-WaitingNow)

    if (-not $now.Count) {
        $ui.NeedsBand.Visibility = $V_Hide
        $ui.NeedsList.ItemsSource = $null
        $script:needsPrev = @{}
        return
    }

    $ui.NeedsLabel.Text = $(if ($now.Count -eq 1) { '1 waiting for you' } else { "$($now.Count) waiting for you" })
    $ui.NeedsList.ItemsSource = $now
    $ui.NeedsBand.Visibility = $V_Show

    # Flash only for a conversation that has JUST started waiting. Flashing again
    # for one that has been waiting since the window opened would train the
    # operator to ignore the taskbar, which is the opposite of the point.
    $fresh = @($now | Where-Object { -not $script:needsPrev[$_.Id] })
    $next = @{}
    foreach ($n in $now) { $next[$n.Id] = $true }
    $script:needsPrev = $next
    if ($fresh.Count -and -not $window.IsActive) { Start-TaskbarFlash }
}
