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
                Project = (Get-ProjectLabel $d)
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
    # 🔴 THE KILL LIST DIES WITH THE DIALOG, and it is cleared HERE rather than only
    # in the handler that uses it. Cancel a relaunch, then confirm an ordinary
    # launch, and a kill list left lying in script scope would close sessions
    # nobody agreed to close -- the dialog would say 'open' and the tool would kill.
    # One function clears it, and every exit from the dialog goes through it.
    $script:confirmKill  = $null
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

# ---------------------------------------------------------------------------
# RELAUNCH: close the ticked sessions and open them again.
#
# WHY THIS EXISTS. When the login token expires, every already-running session
# sits at its own login prompt, and signing in once does NOT reach them: claude
# reads the credential at STARTUP. The operator signed in and then had to sign in
# again in every conversation by hand. A running process cannot be told to
# re-read; only a new one picks the new token up. So the fix is genuinely a
# restart, and the button exists because doing it by hand is the whole morning.
#
# 🔴 THIS KILLS LIVE PROCESSES. Three rules make that safe enough to put on a
# button, and none of them are optional:
#   1. only what is TICKED -- the set the logon restore would have opened, so it
#      mirrors a fresh logon and leaves anything started by hand alone
#   2. never a session that is MID-TURN. A kill loses the reply being written.
#      The transcript survives and it resumes, but the in-flight turn does not.
#   3. every skip is NAMED. A relaunch that silently passed over half the list
#      would leave the operator believing the token problem was fixed.
function Get-RelaunchPlan {
    $restart = @(); $busy = @(); $fresh = @(); $blocked = @()
    foreach ($d in $script:dirs) {
        if ($d.missing -or -not $d.enabled) { continue }
        foreach ($s in @(Get-Visible $d)) {
            if (-not $s.enabled) { continue }
            $id = "$($s.sessionId)".ToLower()
            $a  = $script:agents[$id]
            # 🔴 THE LIVE NAME OUTRANKS THE REGISTRY, and getting this wrong UNDOES the
            # operator's own work. A session renamed by hand reports the new name
            # through `claude agents --json` while the registry still holds whatever
            # discovery last read -- measured 2026-08-24: `skill-adjustment` live
            # against `(untitled)` recorded. Relaunching from the registry would have
            # passed the stale title to -n and renamed it BACK, silently, as part of
            # an action the operator pressed to FIX names.
            #
            # claude is the authority on what a running conversation is called. The
            # registry learns from it here, so the relaunch, the row and the saved
            # title all agree afterwards. Only for RUNNING sessions, and never toward
            # an empty or placeholder name.
            if ($a -and "$($a.Name)" -and "$($a.Name)" -ne '(untitled)' -and "$($a.Name)" -ne "$($s.title)") {
                Write-SRLog ("  [ok]   adopting the live name '{0}' over the recorded '{1}'" -f $a.Name, $s.title)
                Set-SessionField $s 'title' "$($a.Name)"
                $script:dirty = $true
            }
            $it = [PSCustomObject]@{ S = $s; D = $d; Pid = $(if ($a) { [int]$a.Pid } else { 0 }) }
            if ($a -and $a.Pid) {
                # 'busy' is claude's own word for a turn in progress. Anything
                # else that is running -- idle, waiting, at a login prompt -- is
                # safe to take.
                if ("$($a.Status)" -eq 'busy') { $busy += $it } else { $restart += $it }
            } else {
                # Not running. It still belongs in the relaunch: after a token
                # expiry the operator wants the whole ticked set up and signed in.
                $why = Get-LaunchBlock -Session $s -Dir $d
                if ($why) { $blocked += $it } else { $fresh += $it }
            }
        }
    }
    return [PSCustomObject]@{ Restart = @($restart); Busy = @($busy); Fresh = @($fresh); Blocked = @($blocked) }
}

function Invoke-RelaunchTicked {
    if ($script:dirty) { Save-SRRegistry -Registry $script:reg; $script:dirty = $false; Update-AllTicks }
    $plan = Get-RelaunchPlan
    # 🔴 RELAUNCH RESTARTS; IT DOES NOT OPEN. This took Restart + Fresh, which on the
    # operator's machine meant restarting 12 running conversations AND opening 17
    # more that happened to be ticked -- 29 tabs from a button pressed to fix the
    # names on the 12. Opening the rest is what `Launch everything ticked` is for,
    # and pressing both gives the whole ticked set up and signed in.
    #
    # It stays inside the ticked set either way, which is the rule that was agreed;
    # what changed is that being TICKED is no longer sufficient, it also has to be
    # RUNNING. A conversation that is not running has no stale token and no stale
    # remote registration -- there is nothing about it to fix.
    $go = @($plan.Restart | Sort-Object { [datetime]$_.S.lastActive } -Descending)

    $cap = [int]$script:cfg.maxSessions
    $over = 0
    if ($cap -gt 0 -and $go.Count -gt $cap) { $over = $go.Count - $cap; $go = @($go | Select-Object -First $cap) }

    if (-not $go.Count) {
        Set-Status 'nothing to relaunch - no ticked conversation is running, or every one that is is mid-turn' 'warn'
        return
    }

    # WHAT IT WILL CLOSE, counted separately from what it will merely open. Those
    # are different promises and only one of them can lose work.
    $kill = @($go | Where-Object { $_.Pid -gt 0 })
    $note = @()
    if (@($plan.Busy).Count) {
        $names = (@($plan.Busy) | ForEach-Object { Get-SessionTitle $_.S $_.D } | Select-Object -First 6) -join ', '
        $more = $(if (@($plan.Busy).Count -gt 6) { " and $(@($plan.Busy).Count - 6) more" } else { '' })
        $note += "{0} are mid-turn and will be LEFT ALONE: {1}{2}. They keep the old token - run this again once they finish." -f @($plan.Busy).Count, $names, $more
    }
    # NOT a skip, and said as such: these are simply not running, so a relaunch has
    # nothing to do to them. Naming the button that DOES open them stops this
    # reading as something withheld.
    if (@($plan.Fresh).Count) { $note += "{0} more are ticked but not running - use 'Launch everything ticked' to open those." -f @($plan.Fresh).Count }
    if ($over) { $note += "{0} more are ticked but over the maxSessions cap of {1}, so they are skipped." -f $over, $cap }

    # 🔴 NAME WHAT WILL BE CLOSED. The dialog carried the list and showed a COUNT,
    # which is the wrong half: this closes live processes, and one of them may be
    # the conversation the operator is talking to right now. A number cannot be
    # checked against that; a list can.
    $closing = (@($go) | ForEach-Object { Get-SessionTitle $_.S $_.D } | Sort-Object) -join ', '
    $note = @("Closing: $closing") + $note

    $script:confirmKill = $kill
    Request-Confirm -Title ("Restart {0} running conversations" -f $go.Count) `
        -Message ("Each one is CLOSED and then opened again. Use this after signing in, or after reconnecting Remote Control: a running session reads your login AND its remote name at startup, so neither can be picked up without a restart." ) `
        -Note (($note -join '  ') ) `
        -OkLabel ("Restart {0}" -f $go.Count) -Items $go -What 'ticked conversation(s)'
}

# The kill half. Called from the confirmation, never directly.
#
# 🪤 KILLING claude.exe LEAVES ITS TAB BEHIND. The tab runs
# `powershell -NoExit -File <boot>.ps1`, which invokes claude; kill the child and
# the shell returns to a prompt and the tab lingers empty. Over a few relaunches
# that is a screen full of dead tabs. So the boot shell goes too -- but ONLY when
# its command line names a boot script this tool generated, because killing a
# parent on any weaker evidence could close a terminal the operator is using.
function Stop-SRSessions { param($Items)
    $killed = 0
    $script:relaunchLate = @()
    foreach ($it in @($Items)) {
        $procId = [int]$it.Pid
        if ($procId -le 0) { continue }
        $proc = $null
        try { $proc = Get-CimInstance Win32_Process -Filter "ProcessId=$procId" -ErrorAction Stop } catch { }
        # A pid is reusable: confirm THIS one is still the claude that owns the
        # session before killing anything. The same guard Send-SRSessionInput makes.
        if (-not $proc -or $proc.Name -ne 'claude.exe') { continue }
        # 🔴 RE-CHECK MID-TURN AT THE MOMENT OF THE KILL. The plan is built when the
        # button is pressed and the kill happens when the dialog is confirmed, so a
        # session that was idle while the operator read the list and started working
        # while he decided would have been killed on the strength of a stale status.
        # The whole promise of this button is that it does not take a session
        # mid-turn, and a promise checked only at plan time is not that promise.
        $now = $null
        try { $now = (Get-SRAgentStatus -Refresh)["$($it.S.sessionId)".ToLower()] } catch { }
        if ($now -and "$($now.Status)" -eq 'busy') {
            Write-SRLog ("  [skip] {0} started working while the dialog was open - left alone" -f $now.Name)
            $script:relaunchLate += "$($now.Name)"
            continue
        }
        $parent = $null
        try { $parent = Get-CimInstance Win32_Process -Filter "ProcessId=$($proc.ParentProcessId)" -ErrorAction Stop } catch { }
        try { Stop-Process -Id $procId -Force -ErrorAction Stop; $killed++ } catch { continue }
        if ($parent -and $parent.Name -eq 'powershell.exe' -and "$($parent.CommandLine)" -like '*.state*boot-*') {
            try { Stop-Process -Id ([int]$parent.ProcessId) -Force -ErrorAction SilentlyContinue } catch { }
        }
    }
    if ($killed) {
        Write-SRLog ("  [ok]   closed {0} session(s) for a relaunch" -f $killed)
        # The launch that follows opens fresh tabs; give the console host a beat to
        # release the pids so the new ones are not fighting the old for the window.
        Start-Sleep -Milliseconds 700
    }
    return $killed
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
