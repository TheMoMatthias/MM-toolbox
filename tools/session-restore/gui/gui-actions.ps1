#requires -Version 5.1
# ===========================================================================
# THE ACTIONS
#
# Doing things TO sessions: broadcasting, confirming, launching, jumping to a terminal, spawning a new one.
#
# DOT-SOURCED BY sessions-gui.ps1, into its own scope, AFTER $window, $Pal and
# $ui exist - everything here reads them at CALL time, never at load time.
#
# Read tools/session-restore/CONTEXT.md before changing anything in here. The
# traps in it are not hypothetical: every one of them shipped.
# ===========================================================================

# BROADCAST. One message, several sessions.
#
# The recipients are chosen HERE and nowhere else. The obvious shortcut would be
# "send to everything ticked", and it is wrong: the tick means "reopen this at
# logon", most ticked conversations are not running, and a set whose name
# describes a different set is how a message ends up in the wrong console.
#
# Two structural guards, both of which are about the fact that this types into
# somebody else's terminal:
#   - only sessions that can actually receive input are offered at all;
#   - a session sitting on a permission dialog is offered but starts UNTICKED
#     and says so, because prose typed at a dialog ANSWERS the dialog.
# ---------------------------------------------------------------------------
function Get-CastCandidates {
    $out = @()
    foreach ($d in $script:dirs) {
        foreach ($sn in @(Get-Visible $d)) {
            if (-not $sn.sessionId) { continue }
            $a = $script:agents["$($sn.sessionId)".ToLower()]
            if (-not $a -or -not $a.Pid -or $a.Kind -ne 'interactive') { continue }
            $cv = Get-Conv $sn
            $out += [PSCustomObject]@{
                Session = $sn
                Name    = (Get-SessionTitle $sn $d)
                Project = (Split-Path $d.path -Leaf)
                Dialog  = [bool]($a.WaitingFor -match 'dialog')
                What    = $(if ($cv) { "$($cv.State)" } else { '' })
            }
        }
    }
    return $out
}

function Update-CastState {
    $chosen = @()
    foreach ($cb in @($ui.CastList.Children)) {
        $box = $cb -as [System.Windows.Controls.CheckBox]
        if ($box -and $box.IsChecked) { $chosen += $box.Tag }
    }
    $script:castTargets = @($chosen)
    $has = ($chosen.Count -gt 0 -and "$($ui.CastBox.Text)".Trim())
    $ui.CastSend.IsEnabled = [bool]$has
    $ui.CastSend.Content = $(if ($chosen.Count) { "Send to $($chosen.Count)" } else { 'Send' })
    # NAME EVERY RECIPIENT. A count is not a confirmation: "send to 6" and
    # "send to these six" are different promises, and only one of them can be
    # checked before the message goes.
    if ($chosen.Count) {
        $names = @($chosen | ForEach-Object { $_.Name })
        $ui.CastWho.Text = "Will be typed into: " + ($names -join ',  ')
    } else {
        $ui.CastWho.Text = 'Nothing ticked, so nothing will be sent.'
    }
}

function Show-Cast {
    $cands = @(Get-CastCandidates)
    $ui.CastList.Children.Clear()
    foreach ($c in $cands) {
        $cb = New-Object System.Windows.Controls.CheckBox
        $cb.Tag = $c
        $cb.Margin = New-Object System.Windows.Thickness 10, 5, 10, 5
        $cb.Foreground = $Pal.TextHigh
        $cb.IsChecked = $false
        $sp = New-Object System.Windows.Controls.StackPanel
        $sp.Orientation = 'Horizontal'
        foreach ($bit in @(
            @{ T = $c.Name;    F = $Pal.TextHigh; S = 12.5 }
            @{ T = $c.Project; F = $Pal.TextDim;  S = 11.5 }
            @{ T = $(if ($c.Dialog) { 'a dialog is open - typing here ANSWERS it' } else { $c.What }); F = $(if ($c.Dialog) { $Pal.TextMax } else { $Pal.TextLow }); S = 11.5 }
        )) {
            if (-not "$($bit.T)") { continue }
            $tb = New-Object System.Windows.Controls.TextBlock
            $tb.Text = "$($bit.T)"
            $tb.Foreground = $bit.F
            $tb.FontSize = $bit.S
            $tb.Margin = New-Object System.Windows.Thickness 0, 0, 14, 0
            $tb.VerticalAlignment = 'Center'
            $null = $sp.Children.Add($tb)
        }
        $cb.Content = $sp
        $cb.SetValue([System.Windows.Automation.AutomationProperties]::NameProperty, "$($c.Name) in $($c.Project)")
        $null = $ui.CastList.Children.Add($cb)
    }
    $ui.CastLead.Text = $(if ($cands.Count) {
        "$($cands.Count) session(s) are running and can be typed into. Tick the ones this should go to."
    } else {
        'Nothing is running that can be typed into. Open a session first.'
    })
    $ui.CastBox.Text = ''
    Update-CastState
    $ui.CastOverlay.Visibility = $V_Show
    $null = $ui.CastBox.Focus()
}

function Close-Cast {
    $ui.CastOverlay.Visibility = $V_Hide
    $script:castTargets = @()
    $null = (Get-ActiveList).Focus()
}

function Invoke-Cast {
    $text = "$($ui.CastBox.Text)".Trim()
    $targets = @($script:castTargets)
    if (-not $text -or -not $targets.Count) { return }

    $names = @($targets | ForEach-Object { $_.Name })
    $dialogs = @($targets | Where-Object { $_.Dialog })
    $warn = ''
    if ($dialogs.Count) {
        $warn = "`n`n$($dialogs.Count) of them are sitting on a permission dialog. What you send ANSWERS THE DIALOG in those, it does not go into the conversation:  " + (@($dialogs | ForEach-Object { $_.Name }) -join ', ')
    }
    $ans = Show-Confirm ("This will be typed into $($targets.Count) session(s):`n`n  " + ($names -join "`n  ") + "`n`nMessage:`n" + $text + $warn) 'Send to several sessions'
    if ($ans -ne [System.Windows.MessageBoxResult]::Yes) { Set-Status 'not sent' 'warn'; return }

    $sent = 0; $failed = @()
    Set-Busy 'sending'
    try {
        foreach ($t in $targets) {
            $sid = "$($t.Session.sessionId)"
            $why = $(if ($t.Dialog) { Send-SRSessionInput -SessionId $sid -Text $text -Force }
                     else           { Send-SRSessionInput -SessionId $sid -Text $text })
            if ($why) { $failed += "$($t.Name): $why" } else { $sent++ }
        }
    } finally { Set-Busy '' }

    Close-Cast
    # PARTIAL FAILURE IS REPORTED, not rounded off. "Sent to 6" when two of them
    # bounced is the kind of quiet lie that costs an afternoon.
    if ($failed.Count) {
        Set-Status ("sent to {0}, FAILED for {1}: {2}" -f $sent, $failed.Count, ($failed -join '; ')) 'bad'
    } else {
        Set-Status ("sent to {0} session(s): {1}" -f $sent, ($names -join ', ')) 'ok'
    }
}

function Show-Confirm { param([string]$Message, [string]$Title)
    return [System.Windows.MessageBox]::Show($window, $Message, $Title,
        [System.Windows.MessageBoxButton]::YesNo, [System.Windows.MessageBoxImage]::Question)
}

# The in-window confirmation. It cannot block, so the decision is carried in
# script scope and acted on by the CfOk handler -- a scriptblock closed over
# these values would find them gone by the time the button is pressed.
function Request-Confirm {
    param([string]$Title, [string]$Message, [string]$Note, [string]$OkLabel, $Items, [string]$What)
    $script:confirmItems = $Items
    $script:confirmWhat  = $What
    $ui.CfTitle.Text   = $Title
    $ui.CfMessage.Text = $Message
    $ui.CfOk.Content   = $OkLabel
    if ($Note) { $ui.CfNote.Text = $Note; $ui.CfNoteBox.Visibility = $V_Show } else { $ui.CfNoteBox.Visibility = $V_Hide }
    $ui.ConfirmOverlay.Visibility = $V_Show
    $null = $ui.CfOk.Focus()
}
function Close-Confirm {
    $ui.ConfirmOverlay.Visibility = $V_Hide
    $script:confirmItems = $null
    $script:confirmWhat  = $null
}

# X. Same cap as the logon restore, and said out loud rather than applied
# silently -- a truncated list reads exactly like a complete one.
function Invoke-LaunchTicked {
    if ($script:dirty) { Save-SRRegistry -Registry $script:reg; $script:dirty = $false; Update-AllTicks }
    $all = @()
    foreach ($d in $script:dirs) {
        if ($d.missing -or -not $d.enabled) { continue }
        foreach ($s in @(Get-Visible $d)) {
            if (-not $s.enabled) { continue }
            $all += [PSCustomObject]@{ S = $s; D = $d }
        }
    }
    $all = @($all | Sort-Object { [datetime]$_.S.lastActive } -Descending)
    $go  = @($all | Where-Object { $null -eq (Get-LaunchBlock -Session $_.S -Dir $_.D) })

    $cap = [int]$script:cfg.maxSessions
    $over = 0
    if ($cap -gt 0 -and $go.Count -gt $cap) { $over = $go.Count - $cap; $go = @($go | Select-Object -First $cap) }

    if ($all.Count -eq 0) {
        Set-Status 'nothing is ticked - the checkbox on the left is what decides' 'warn'
    } elseif ($go.Count -eq 0) {
        Set-Status ("nothing to open - all {0} ticked conversation(s) are open already" -f $all.Count) 'warn'
    } else {
        Request-Confirm -Title ("Open {0} ticked conversations now" -f $go.Count) `
            -Message ("Of the {0} ticked conversation(s), {1} are not open yet. Each one gets its own tab, half a second apart." -f $all.Count, $go.Count) `
            -Note $(if ($over) { "{0} more are ticked but over the maxSessions cap of {1}, so they will be skipped. The cap is in session-restore.config.json." -f $over, $cap } else { '' }) `
            -OkLabel ("Open {0} tabs" -f $go.Count) -Items $go -What 'ticked conversation(s)'
    }
}

# S. The same refusal spawn-claude-session makes, for the same reason: a session
# was once spawned onto a lane a live one had held for 73 minutes.
# GO TO: bring this conversation's real terminal tab to the front. The whole
# point of the inbox is to be the index into 13 tabs spread over 6 terminal
# windows, so the row's action has to actually land you in the conversation --
# not open a rendering of it.
#
# A row whose session is NOT running has no tab, so the same button launches it
# instead. One button, two situations, and the label says which: "Go to" when
# there is something to go to, "Open" when there is not.
function Invoke-RowJump { param($Row)
    # Going to the tab IS looking at it. A dot that survives you reading the
    # conversation in its own terminal is a dot that lies.
    if ($Row -and $Row.Kind -eq 'session') { Set-Seen $Row.Session; Update-RowSeenMarks }
    if (-not $Row -or $Row.Kind -ne 'session') { return }
    $s = $Row.Session
    $key = "$($s.sessionId)".ToLower()
    $a = $script:agents[$key]

    if ($a -and $a.Kind -and $a.Kind -ne 'interactive') {
        Set-Status 'that is a background agent - it has no terminal of its own to jump to' 'warn'
        return
    }
    if (-not $a) {
        # Not running, so there is no tab. Launching it IS how you get to it.
        Invoke-RowLaunch $Row
        return
    }

    Set-Busy 'finding its tab'
    $why = $null
    # The title comes from the agent table the background pass already refreshed,
    # so the jump never has to ask claude and never blocks the click.
    try { $why = Invoke-SRJumpToSession -SessionId $s.sessionId -Title $a.Name -RaiseAnyway } finally { Set-Busy '' }

    if ($why) { Set-Status $why 'warn'; return }
    $note = $script:SR_JumpNote
    if ($note) { Set-Status $note 'warn' }
    else { Set-Status ("went to {0} - its terminal is in front" -f (Get-SessionTitle $s $Row.Dir)) 'ok' }
}

function Invoke-RowSpawn { param($Row)
    if (-not $Row) { return }
    $path = Get-RowPath $Row
    if (-not (Test-Path -LiteralPath $path -PathType Container)) {
        Set-Status "directory no longer exists: $path" 'bad'
        return
    }
    $script:pendingSpawn = $path
    $ui.OvPath.Text = $path
    $busy = Get-LiveInDirectory $path
    if (@($busy).Count) {
        $ui.OvWarn.Text = "ALREADY LIVE IN THIS TREE: " + ((@($busy) | ForEach-Object { '"' + $_.title + '"' }) -join ', ')
        $ui.OvWarnBox.Visibility = $V_Show
        $ui.OvOk.Content = 'Spawn a second one anyway'
    } else {
        $ui.OvWarnBox.Visibility = $V_Hide
        $ui.OvOk.Content = 'Spawn it'
    }
    $ui.OvName.Text = ''
    $ui.Overlay.Visibility = $V_Show
    $null = $ui.OvName.Focus()
}

function Close-Overlay { $ui.Overlay.Visibility = $V_Hide; $script:pendingSpawn = $null; $null = $ui.RowList.Focus() }

function Confirm-Spawn {
    $dir = $script:pendingSpawn
    if (-not $dir) { Close-Overlay; return }
    # Script scope for the same reason Start-Rescan uses it: the completion
    # scriptblock runs long after this function has returned, so a local would
    # read back as $null and the message would name nothing.
    $script:spawnDir  = $dir
    $script:spawnName = Resolve-SpawnName -Dir $dir -Name $ui.OvName.Text
    Close-Overlay
    $started = Start-SRJob -Name 'spawning' -Body $script:SpawnJob -Data @{ Dir = $script:spawnDir; Name = $script:spawnName } -OnDone {
        param($res)
        if ($res -and $res.Ok) {
            # It has no session id until claude writes one, so it cannot appear in
            # the list until the next scan.
            Set-Status ("spawned `"{0}`" in {1} - press Rescan once it has settled to see it listed" -f $script:spawnName, (Split-Path $script:spawnDir -Leaf)) 'ok'
        } else {
            Set-Status ("not spawned - {0}" -f $(if ($res) { $res.Why } else { 'the spawn returned nothing' })) 'bad'
        }
    }
    if (-not $started) { Set-Status 'still busy - one background pass at a time' 'warn' }
}
