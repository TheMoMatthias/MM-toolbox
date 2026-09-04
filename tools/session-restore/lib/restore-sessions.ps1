#requires -Version 5.1
<#
.SYNOPSIS
    Bring back the Claude Code conversations you have SELECTED, each with Remote
    Control attached under its real name.

.DESCRIPTION
    Discovery finds what exists; the registry says what should come back. They are
    deliberately separate -- a directory you untick stays untouched even though it
    is still discoverable, so a finished project stops reopening every morning.

    Run Sessions.bat (or `ccs`) to tick and untick.

    WHY THIS EXISTS. Launching a bare `claude` while remoteControlAtStartup is true
    registers a Remote Control session for an EMPTY conversation, so the remote
    title falls to an auto-generated "<hostname>-graceful-unicorn" and a later
    /resume never sends the switched-to conversation's title or history to the
    device. Each abandoned placeholder is a 118-byte transcript with an empty
    bridgeSessionId. The cure is to resume FIRST and name explicitly:

        claude --resume <id> -n "<name>" --remote-control "<name>"

    -n writes a DURABLE custom-title into the conversation (title-precedence rule
    2); --remote-control names only that remote session (rule 1). Both are needed.

    NEW SESSIONS: no hook can set a session title -- all 31 hook events are
    informational or permission-gating -- so the only cure is to never launch a
    bare `claude`. Use -New (or `cc`).

.PARAMETER Scan
    Refresh the registry from disk and exit. Launches nothing. This is what the
    hourly scheduled task runs.

.PARAMETER All
    Ignore the tick list: consider every discovered conversation. The maxSessions
    cap still applies -- without it this opens a tab per conversation, which is 46
    on a machine with a busy repo.

.PARAMETER New
    Start a correctly-named NEW session in the current directory.

.EXAMPLE
    .\restore-sessions.ps1 -DryRun     # what would come back?
    .\restore-sessions.ps1             # bring it back
    .\restore-sessions.ps1 -Scan       # just refresh the registry
    .\Sessions.bat                     # choose which conversations are in scope
#>
[CmdletBinding()]
param(
    [switch]$Install,
    # Opt in to auto-logon as part of installing, rather than through a launcher
    # of its own. Elevates and stores a password, so it is never the default.
    [switch]$AutoLogon,
    [switch]$Uninstall,
    [switch]$Scan,
    [switch]$New,
    [string]$Name,
    [switch]$DryRun,
    [switch]$All,

    # Anything unrecognised is forwarded verbatim to `claude` by -New, so
    # `cc --model opus` works.
    [Parameter(ValueFromRemainingArguments = $true)]
    [string[]]$ClaudeArgs
)

$ErrorActionPreference = 'Stop'

$here = $PSScriptRoot
if (-not $here -and $MyInvocation.MyCommand.Path) { $here = Split-Path -Parent $MyInvocation.MyCommand.Path }
if (-not $here) { $here = (Get-Location).Path }
. (Join-Path $here '_common.ps1')

$TaskRestore   = 'ClaudeSessionRestore'
$TaskScan      = 'ClaudeSessionScan'
$LnkRestore    = 'Restore Claude Sessions.lnk'
$LnkSelect     = 'Claude Sessions.lnk'
# It was called this while the screen only ticked things. Now that the same screen
# also launches, the button is renamed -- and the old one is deleted rather than
# left behind, or the desktop grows two buttons for one panel.
$LnkSelectOld  = 'Select Claude Sessions.lnk'

# ---------------------------------------------------------------------------
function Invoke-Scan {
    Write-Host ""
    Write-Host "Claude session scan" -ForegroundColor Cyan
    Write-Host ""
    Write-SRLog "---- scan ----"
    $cfg = Get-SRConfig
    $reg = Update-SRRegistry -Config $cfg
    $sel = Get-SRSelected -Registry $reg -Config $cfg
    $allS = @(@($reg.directories) | ForEach-Object { @($_.sessions) }).Count
    Write-Host ""
    Write-Host ("  {0} of {1} conversation(s), across {2} project(s), selected for restore" -f @($sel).Count, $allS, @($reg.directories).Count)
    Write-Host "  Choose with: Sessions.bat   (or ccs)"
    Write-Host ""
    return 0
}

function Invoke-Restore {
    Write-Host ""
    Write-Host "Claude session restore" -ForegroundColor Cyan
    if ($DryRun) { Write-Host "DRY RUN - nothing will be launched" -ForegroundColor Yellow }
    if ($All)    { Write-Host "-All - ignoring the tick list and the cap" -ForegroundColor Yellow }
    Write-Host ""
    Write-SRLog ("---- restore ({0}{1}) ----" -f $(if($DryRun){'dry'}else{'live'}), $(if($All){', all'}else{''}))

    $cfg = Get-SRConfig

    # Refresh first so a project you started today is offered today. Announce it:
    # a silent scan leaves the window blank and reads as nothing happening.
    Write-Host "  Scanning conversations..." -NoNewline -ForegroundColor DarkGray
    $swScan = [Diagnostics.Stopwatch]::StartNew()
    $reg = Update-SRRegistry -Config $cfg -Quiet
    $swScan.Stop()
    Write-Host (" {0} ms" -f $swScan.ElapsedMilliseconds) -ForegroundColor DarkGray
    Write-SRLog ("         scan {0} ms" -f $swScan.ElapsedMilliseconds)

    $wanted   = Get-SRSelected -Registry $reg -Config $cfg -IgnoreTicks:$All
    $knownDir = @($reg.directories).Count
    $knownSes = @(@($reg.directories) | ForEach-Object { @($_.sessions) }).Count

    # Three distinct states, never one silent green: nothing known, nothing
    # ticked, and nothing restorable are different problems with different fixes.
    if ($knownSes -eq 0) {
        Write-SRFail "no conversations discovered under $SR_Projects. Has claude ever run on this machine?"
        return 1
    }
    if (@($wanted).Count -eq 0) {
        Write-SRFail ("{0} conversation(s) across {1} project(s) known, but NONE is ticked. Run Sessions.bat (or ccs) to choose." -f $knownSes, $knownDir)
        return 1
    }

    # 🔴 WAIT FOR THE REMOTE BRIDGE BEFORE LAUNCHING A QUEUE. Claude Code counts
    # consecutive bridge failures and suppresses the bridge on the seventh, so a
    # dozen sessions launched a second apart into an auth that is not warm yet
    # burn the whole budget in seven seconds and every session after that comes
    # up unauthorized. That is the daily "authorization has failed". See
    # Wait-SRBridgeReady for the measurement.
    #
    # Not on a dry run: nothing is launched, so there is nothing to protect, and
    # stalling a preview the operator is watching would be its own bug.
    if (-not $DryRun) {
        # 🔴 A FAILED GATE NOW STOPS THE RESTORE. It used to be advisory - the
        # return value was discarded and the queue launched regardless - and
        # that is what produced the morning the operator kept reporting: two
        # dozen sessions up, none of them able to register with Remote Control,
        # all of them needing to be killed and relaunched by hand after a manual
        # sign-in. Launching into a dead token does not save the morning, it is
        # what costs it.
        #
        # 🪤 ONLY AUTH STOPS IT. Bridge suppression on its own is survivable -
        # the sessions come up and work, they simply are not reachable from the
        # phone for a while - so that is still a warning and not a refusal. The
        # difference is that a dead TOKEN makes every launched session useless,
        # and a suppressed bridge does not.
        # 🔴 WARM BY LAUNCHING THE FIRST SESSION, NOT BY GUESSING WHICH COMMAND
        # REFRESHES. There is no `claude auth refresh`, and whether `auth status`
        # refreshes is undocumented - so this no longer DEPENDS on it. What is
        # certain is that a real session refreshes, because that is precisely
        # what all 24 of them were doing every morning and racing each other to
        # do. So: launch ONE, wait until the token is actually live, then
        # release the rest. The warm-up is work that was wanted anyway - no
        # extra call, and above all NO GHOST CONVERSATION, which is what ruled
        # out `claude -p`.
        #
        # 🔴 AND IT IS DECIDED *BEFORE* THE GATE, WHICH IS THE WHOLE FIX.
        # Measured 2026-09-03 in .state\restore.log: with this block sitting
        # AFTER Wait-SRBridgeReady, the gate blocked at 08:26:12 on a dead token
        # ("press Sign in"), slept until the operator signed in 104 s later, and
        # only then did this line run - by which point the token was live, so
        # $warmNeeded came out FALSE and the launch-one-first path did nothing.
        # The code that exists to avoid the sign-in was unreachable except after
        # a five-minute timeout. Deciding here, and telling the gate it need not
        # wait for the token, is what makes it actually run.
        $script:warmNeeded = -not (Test-SRTokenLive)
        if ($script:warmNeeded) {
            $exp0 = Get-SRTokenExpiry
            Write-SRStep ("the access token is not live{0} - refreshing it before anything starts" -f `
                          $(if ($exp0) { " (expired {0:HH:mm})" -f $exp0 } else { '' }))
            # 🔴 THE REFRESH RUNS HERE, IN FRONT OF EVERY GATE, AND DEPENDS ON
            # NOTHING BUT THE CREDENTIALS FILE.
            #
            # It also runs inside Wait-SRBridgeReady, but ONLY behind
            # Test-SRAuthReady - which spawns `claude auth status` and returns
            # false on any non-zero exit, timeout or parse failure. At a boot
            # with two dozen sessions starting that spawn can lose, and then the
            # refresh would never be attempted at all: the gate would block for
            # its full 300 s on "claude does not report a signed-in account
            # yet", fall through, and hand over to the launch-one path that
            # 2026-09-04 already proved does not refresh anything.
            #
            # That is the same shape as the bug fixed the day before - a working
            # mechanism placed behind a gate that can refuse - and `auth status`
            # is the single least trustworthy thing in this whole story: it was
            # the FIRST wrong premise. Invoke-SRTokenRefresh needs only the file
            # on disk, so it is asked first and asked unconditionally.
            $rWhy = 'not attempted'
            try { $rWhy = Invoke-SRTokenRefresh } catch { $rWhy = $_.Exception.Message }
            if (-not $rWhy) {
                $script:warmNeeded = -not (Test-SRTokenLive)
                if (-not $script:warmNeeded) {
                    Write-SROk ("the access token was refreshed directly - good until {0:HH:mm}" -f (Get-SRTokenExpiry))
                }
            } else {
                Write-SRWarn ("could not refresh the token directly ({0}) - falling back to launching one conversation first" -f $rWhy)
            }
        }
        if (-not (Wait-SRBridgeReady -MaxWaitSeconds 300 -TokenMayBeCold:$script:warmNeeded)) {
            if (Test-SRTokenLive) {
                Write-SRWarn 'the remote bridge is not ready - restoring anyway; the sessions will work but may not reach Remote Control for a while'
            }
        }
        # The gate runs Invoke-SRTokenWarm on its way through, and it sometimes
        # works. Re-read rather than assume: warming by launch is only worth
        # doing while the token is still cold.
        if ($script:warmNeeded -and (Test-SRTokenLive)) {
            $script:warmNeeded = $false
            Write-SRLog '  [ok]   the token is live already - launching the full queue'
        }
    } else {
        $sup = Get-SRBridgeSuppression
        if ($sup) { Write-SRWarn ("the remote bridge is suppressed until {0} - a real restore would wait for it" -f $sup.ToString('HH:mm:ss')) }
    }

    # One line per directory that is about to get two or more sessions. They share a
    # single git index, so a bare `git commit` in either takes whatever the other
    # staged -- the mitigation is `git commit -- <paths>`, not avoiding this.
    # Grouped by the SESSION's working directory, so main and each worktree count
    # separately -- which is the point of a worktree: its own tree, its own index.
    foreach ($grp in ($wanted | Group-Object -Property Path)) {
        if ($grp.Count -ge 2) {
            # Single-quoted: a backtick is PowerShell's escape character, and a
            # markdown-style one inside a double-quoted string is a parse error.
            # "will be live", not "restoring": this counts the WANTED set, and some of
            # it is skipped below precisely BECAUSE it is already running. The hazard
            # is how many end up sharing the tree, which is true either way.
            Write-SRWarn (('{0}: {1} conversations will be live in ONE working tree - they share a git index, so commit with:  git commit -m msg -- <paths>') -f (Split-Path $grp.Name -Leaf), $grp.Count)
        }
    }

    # The cap applies to -All too. It used to be exempt, which was harmless while a
    # project could contribute one conversation -- with several it meant `ccr -All`
    # opened 46 real tabs on this machine. Raise maxSessions if you want more; one
    # lever, not two.
    $cap = [int]$cfg.maxSessions
    if ($cap -gt 0 -and @($wanted).Count -gt $cap) {
        $dropped = @($wanted).Count - $cap
        $wanted = @($wanted | Select-Object -First $cap)
        # Never truncate silently: a capped list reads exactly like a complete one.
        Write-SRStep "capped at $cap most recent - $dropped conversation$(if($dropped -eq 1){''}else{'s'}) not restored this run (raise maxSessions in the config if you want more)"
    }

    # 🪤 RESET IT EXPLICITLY. The window calls this in-process, so a
    # $script: variable left true by an earlier run would make the next restore
    # stop after one conversation for no reason at all.
    if (-not $script:warmNeeded) { $script:warmNeeded = $false }
    $launched = 0; $skipped = 0; $failed = 0
    # Position in $wanted, not a count of what launched: the last ENTRY is what
    # decides there is no next tab to make room for, and entries get skipped.
    $idx = 0
    $total = @($wanted).Count
    # Read once, not per iteration: Get-SRConfig is cached but this is a loop
    # whose whole point is now how little time it spends between tabs.
    $script:launchGap = 250
    try { $script:launchGap = [int]$cfg.launchGapMs } catch { $script:launchGap = 250 }
    $staleDays = [double]$cfg.recencyDays
    # Ids we opened a tab for, so it can be PROVED they came up rather than assumed.
    $launchedIds = @()

    foreach ($e in $wanted) {
        $idx++
        # Name the repo AND the lane: "AlgoTrader" and "AlgoTrader/D1" are different
        # working trees, and a bare leaf would render both as their folder name.
        $label = if ($e.Lane -eq 'worktree' -and $e.Worktree) {
            "{0}/{1}" -f (Split-Path $e.Repo -Leaf), $e.Worktree
        } else {
            Split-Path $e.Repo -Leaf
        }

        if (-not (Test-Path -LiteralPath $e.path -PathType Container)) {
            Write-SRFail "$label - directory no longer exists: $($e.path)"; $failed++; continue
        }

        # Several conversations can share a directory now, so every line has to name
        # WHICH one -- three consecutive "AlgoTrader - skipped" tell you nothing.
        $title = $e.title
        if ([string]::IsNullOrWhiteSpace($title)) { $title = $label }
        $who = "$label / `"$title`""

        $jsonl = Get-SRTranscriptPath -Dir $e.path -SessionId $e.sessionId -Recorded $e.Jsonl
        if (-not (Test-Path -LiteralPath $jsonl)) {
            Write-SRFail "$who - transcript missing for session $($e.sessionId); run -Scan"; $failed++; continue
        }

        if (Test-SRProcessRunning -SessionId $e.sessionId) {
            Write-SRSkip "$who - already open in a running claude.exe"
            $skipped++; continue
        }
        if (Test-SRTranscriptLive -JsonlPath $jsonl) {
            Write-SRSkip "$who - already live (transcript written < $SR_LiveWindowMinutes min ago)"
            $skipped++; continue
        }

        $ageDays  = [int]((Get-Date) - [datetime]$e.lastActive).TotalDays
        $ageHours = [int]((Get-Date) - [datetime]$e.lastActive).TotalHours

        if ($DryRun) {
            Write-SROk "$label / `"$title`"   (last active $(if($ageDays -ge 1){"${ageDays}d"}else{"${ageHours}h"}) ago)"
            Write-SRStep "claude --resume $($e.sessionId) -n `"$title`" --remote-control `"$title`""
            Write-SRStep "in $($e.path)"
            if ($ageDays -gt $staleDays) { Write-Host "         STALE - ticked, but untouched for ${ageDays}d. Untick it in Sessions.bat if it is finished." -ForegroundColor DarkYellow }
            $launched++
            continue
        }

        try {
            # 🔴 THE CONVERSATION'S OWN SETTINGS, at the only moment claude can
            # read them. These were absent here: the logon restore built a bare
            # boot script, so a session configured for opus/high/plan with two
            # tool rules and Remote Control OFF came back at every logon as
            # default model, default effort, default permissions, no tool rules
            # and remote ON. It worked from the window and nowhere else.
            $sess = $e.Session
            $args = @(); $remote = $true; $hidden = $false
            if ($sess) {
                try { $args   = @(Get-SRSessionArgs $sess) }   catch { }
                try { $remote = [bool](Test-SRRemoteWanted $sess) } catch { }
                try { $hidden = [bool](Test-SRHiddenWanted $sess) } catch { }
            }
            $boot = New-SRBootScript -Dir $e.path -SessionId $e.sessionId -Title $title `
                        -ClaudeArgs $args -RemoteControl $remote
            if ($hidden) { $null = Start-SRHiddenSession -Dir $e.path -BootScript $boot -Title $title }
            else         { Start-SRSession -Dir $e.path -BootScript $boot -Title $title }
            $launchedIds += $e.sessionId
            Write-SROk "$label -> `"$title`" ($($e.sessionId.Substring(0,8)), $(if($ageDays -ge 1){"${ageDays}d"}else{"${ageHours}h"}))"
            # Your tick wins over the age heuristic -- but staleness is visible,
            # here and in the log, rather than silently overruling you either way.
            if ($ageDays -gt $staleDays) {
                Write-Host "         STALE - ticked, but untouched for ${ageDays}d." -ForegroundColor DarkYellow
                Write-SRLog "         STALE - $label ticked but untouched for ${ageDays}d"
            }
            $launched++

            # 🔴 THE GATE, AND IT IS HERE RATHER THAN BEFORE THE LOOP BECAUSE
            # THE FIRST LAUNCH IS THE THING THAT WARMS IT. Hold the queue until
            # this one has actually refreshed the token, then let the rest go.
            # Without this wait the other 23 start against the same dead token
            # and race exactly as before - the launch alone is not the fix, the
            # WAITING is.
            if ($script:warmNeeded) {
                $warmSw = [Diagnostics.Stopwatch]::StartNew()
                while ($warmSw.Elapsed.TotalSeconds -lt 120 -and -not (Test-SRTokenLive)) {
                    Start-Sleep -Seconds 3
                }
                if (Test-SRTokenLive) {
                    $script:warmNeeded = $false
                    Write-SRLog ('  [ok]   the token went live after {0:N0}s - releasing the other conversations' -f $warmSw.Elapsed.TotalSeconds)
                } else {
                    # 🪤 STOP HERE. One session up and unauthorized is a nuisance;
                    # two dozen is the morning the operator kept having, and every
                    # one of them has to be killed and relaunched by hand.
                    #
                    # 🔑 AND THE ONE ALREADY LAUNCHED IS LEFT RUNNING - decided
                    # 2026-09-02, not an accident of where the return sits. It is
                    # visible in the window, it is one row rather than twenty-four,
                    # and Relaunch already knows how to swap it onto the new login
                    # once the sign-in lands. The alternative is killing a live
                    # claude process from inside a failure handler, which is the
                    # worst possible place to put a destructive path: a bug there
                    # takes down something the operator wanted.
                    $exp = Get-SRTokenExpiry
                    $when = $(if ($exp) { " It expired at {0:HH:mm}." -f $exp } else { '' })
                    Write-SRFail ("STOPPING after 1 conversation: the access token would not refresh.{0} The rest are NOT being launched, because they would come up unauthorized and need relaunching by hand. Press Sign in in the Sessions window (or run: claude auth login), then restore again." -f $when)
                    try {
                        $null = Show-SRDesktopNote -Title 'Claude sessions - not restored' `
                                   -Message 'Your access token could not be refreshed, so the conversations were not reopened. Open Sessions and press Sign in.'
                    } catch { }
                    return 1
                }
            }

            # Breathing room between tabs so Windows Terminal does not race itself.
            # Was 1200 ms, which at the 12-session cap was 14 seconds of pure sleeping
            # at every logon; 500 ms keeps a margin and cuts that to five.
            #
            # 🪤 NOT AFTER THE LAST ONE. The sleep exists to separate this launch from
            # the NEXT launch, so the final one separates a tab from nothing at all -
            # half a second of the logon spent waiting for an event that will not
            # happen. Measured over 28 sessions on 2026-09-03: 500 ms of sleep against
            # ~357 ms of real work per tab, so this loop is 58% sleeping; this only
            # reclaims the last one, because the other 27 are load-bearing.
            if ($idx -lt $total -and $script:launchGap -gt 0) { Start-Sleep -Milliseconds $script:launchGap }
        } catch {
            Write-SRFail "$label - $($_.Exception.Message)"; $failed++
        }
    }

    # VERIFY. Up to here every [ok] means only that wt.exe started -- the tab's
    # child is what actually fails, which is how every tab in one repo could die
    # while this printed success and the scheduled task returned 0.
    $neverCame = @()
    if (-not $DryRun -and $launchedIds.Count) {
        Write-Host ""
        Write-Host ("  Verifying {0} session(s) came up..." -f $launchedIds.Count) -NoNewline -ForegroundColor DarkGray
        $sw = [Diagnostics.Stopwatch]::StartNew()
        $neverCame = Wait-SRSessionsUp -SessionIds $launchedIds
        $sw.Stop()
        Write-Host (" {0:N1}s" -f ($sw.Elapsed.TotalSeconds)) -ForegroundColor DarkGray
        foreach ($id in $neverCame) {
            $who = @($wanted | Where-Object { $_.SessionId -eq $id })[0]
            $nm  = if ($who) { $who.Title } else { $id }
            Write-SRFail ("no claude.exe ever appeared for `"{0}`" ({1}) - the tab opened and died. Read {2}" -f $nm, $id.Substring(0,8), $SR_LogPath)
        }
    }
    $verified = $launched - @($neverCame).Count

    Write-Host ""
    Write-Host ("  restored {0}   verified {1}   skipped {2}   failed {3}" -f $launched, $verified, $skipped, $failed)
    if ($launched -eq 0) {
        Write-Host "  NOTHING WAS RESTORED - every selected directory was skipped or failed." -ForegroundColor Yellow
    }
    if (@($neverCame).Count) {
        Write-Host ("  {0} tab(s) opened but no claude started in them." -f @($neverCame).Count) -ForegroundColor Red
    }
    Write-Host ""
    Write-SRLog ("  restored {0}   verified {1}   skipped {2}   failed {3}" -f $launched, $verified, $skipped, $failed)

    if ($failed -gt 0 -or @($neverCame).Count) { return 1 }
    return 0
}

function Invoke-NewSession {
    $dir   = (Get-Location).Path
    $n     = $Name
    $extra = @()
    if ($ClaudeArgs) { $extra = @($ClaudeArgs) }

    # A leading '-' token is a claude flag, never a session name.
    if ($n -and $n.StartsWith('-')) { $extra = @($n) + $extra; $n = $null }

    if ([string]::IsNullOrWhiteSpace($n)) { $n = (Split-Path $dir -Leaf) + '-' + (Get-Date -Format 'MMdd-HHmm') }
    $n = ($n -replace '\s+', '-').Trim('-')
    if ([string]::IsNullOrWhiteSpace($n)) { $n = 'claude-' + (Get-Date -Format 'MMdd-HHmm') }

    Write-Host ""
    Write-Host "Starting a NEW named session: `"$n`"" -ForegroundColor Cyan
    Write-Host "  in $dir"
    if ($extra.Count -gt 0) { Write-Host ("  forwarding to claude: " + ($extra -join ' ')) }
    Write-Host ""

    $argv = @('-n', $n, '--remote-control', $n) + $extra
    if ($DryRun) {
        Write-SRStep ("claude " + (($argv | ForEach-Object { if ($_ -match '\s') { '"' + $_ + '"' } else { $_ } }) -join ' '))
        return 0
    }

    # Runs in THIS console on purpose - you are already here.
    Clear-SRChildEnv
    & claude @argv
    return 0
}

# ---------------------------------------------------------------------------
function New-SRShortcut {
    param(
        [string]$LinkName, [string]$Target, [string]$Arguments, [string]$Description,
        # The desktop said 'powershell.exe,0' for both buttons, which is how a
        # tool ends up looking like a script no matter what it does. Callers pass
        # Sessions.exe once it has been built.
        [string]$Icon = 'powershell.exe,0'
    )
    $p = Join-Path ([Environment]::GetFolderPath('Desktop')) $LinkName
    $s = (New-Object -ComObject WScript.Shell).CreateShortcut($p)
    $s.TargetPath       = $Target
    $s.Arguments        = $Arguments
    $s.WorkingDirectory = $SR_Root
    $s.IconLocation     = $Icon
    $s.Description      = $Description
    $s.Save()
    return $p
}

function Invoke-Install {
    $restore = Join-Path $SR_Root 'lib\restore-sessions.ps1'

    Write-Host ""
    Write-Host "Installing" -ForegroundColor Cyan

    $principal = New-ScheduledTaskPrincipal -UserId "$env:USERDOMAIN\$env:USERNAME" -LogonType Interactive -RunLevel Limited
    # 20 minutes, not 10: the restore now WAITS for the remote bridge before it
    # launches anything (up to 5 minutes), and a limit that could kill the task
    # mid-wait would turn a slow morning into no sessions at all.
    $settings  = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
                    -ExecutionTimeLimit ([TimeSpan]::FromMinutes(20)) -MultipleInstances IgnoreNew

    # 1) restore, at logon
    $trg = New-ScheduledTaskTrigger -AtLogOn -User "$env:USERDOMAIN\$env:USERNAME"
    # 90 seconds, up from 45. The old delay put the launch queue on top of a
    # bridge whose auth was not warm yet; the wait inside restore-sessions.ps1 is
    # the real guard, and this just stops it being entered every single morning.
    $trg.Delay = 'PT90S'
    Register-ScheduledTask -TaskName $TaskRestore -Force -Principal $principal -Settings $settings -Trigger $trg `
        -Action (New-ScheduledTaskAction -Execute 'powershell.exe' -Argument ("-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"{0}`"" -f $restore)) `
        -Description 'Restore selected Claude Code conversations with Remote Control attached.' | Out-Null
    # Derived from the trigger, never retyped. It said "45s delay" for the first
    # hour after the delay became 90s, which is exactly how a message stops being
    # true without anyone editing it.
    Write-SROk ("task '{0}' - at logon, {1} delay, waits for the remote bridge before launching" -f $TaskRestore, $trg.Delay)

    # 2) scan, hourly + at logon. It only refreshes the registry; it launches
    #    nothing, so a new project appears in the picker without any risk.
    # 🔴 TEN MINUTES, NOT TWO, AND THE GAP IS THE WHOLE REASON. The restore
    # fires at logon+90s and scans the same 391 transcripts this task does; at
    # logon+2m the two were meant to be 30 seconds apart. Measured 2026-09-02,
    # they were not - both logged their header in the SAME SECOND:
    #
    #   07:36:30  ---- scan ----
    #   07:36:30  ---- restore (live) ----
    #   07:37:11  registry lock timed out after 15000ms - proceeding unlocked
    #   07:37:25  scan 29002 ms
    #   07:37:25  [FAIL] FATAL: the registry changed on disk since this window read it
    #
    # Task Scheduler delays are advisory and a booting machine does not honour
    # them to the second, so a 30s design gap is no gap at all. 15,000 ms of
    # that 29-second scan was pure blocked waiting on the registry mutex, and
    # the loser then threw the stamp guard - a full duplicate scan, discarded.
    #
    # 🪤 THE TRIGGER IS KEPT, NOT DROPPED. Deleting it would be simpler and is
    # wrong: the hourly trigger runs at :05 past, so a logon at :06 would leave
    # a new project invisible in the picker for the best part of an hour. Ten
    # minutes clears the restore (which no longer waits on a human for the
    # token - see Wait-SRBridgeReady) with room to spare, and still refreshes
    # the registry while the operator is making coffee.
    $trgLogon  = New-ScheduledTaskTrigger -AtLogOn -User "$env:USERDOMAIN\$env:USERNAME"
    $trgLogon.Delay = 'PT10M'
    $trgHourly = New-ScheduledTaskTrigger -Once -At (Get-Date).Date.AddMinutes(5) `
                    -RepetitionInterval ([TimeSpan]::FromHours(1)) -RepetitionDuration ([TimeSpan]::FromDays(3650))
    Register-ScheduledTask -TaskName $TaskScan -Force -Principal $principal -Settings $settings -Trigger @($trgLogon, $trgHourly) `
        -Action (New-ScheduledTaskAction -Execute 'powershell.exe' -Argument ("-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"{0}`" -Scan" -f $restore)) `
        -Description 'Discover Claude Code project directories. Updates the selection registry only; launches nothing.' | Out-Null
    Write-SROk ("task '{0}' - hourly + at logon with a {1} delay, clear of the restore (scan only, launches nothing)" -f $TaskScan, $trgLogon.Delay)

    # Build the application wrapper. Sessions.exe hosts the PowerShell runspace
    # itself, so the window opens without a powershell.exe underneath it, carries
    # its own icon everywhere Windows shows it, and opens ONCE however many times
    # it is double-clicked. csc.exe ships with the .NET Framework, so this needs
    # nothing fetched.
    #
    # NOT FATAL if it fails. The .bat and .vbs launch routes still work and the
    # shortcut falls back to them -- an install that leaves the machine with no
    # session console at all would be a far worse outcome than one that leaves it
    # with the old-looking one.
    $exe = Join-Path $SR_Root 'Sessions.exe'
    try {
        $null = & (Join-Path $SR_Root 'app\build.ps1') -Quiet
        if (Test-Path -LiteralPath $exe) {
            Write-SROk ("Sessions.exe built ({0} KB)" -f [Math]::Round((Get-Item -LiteralPath $exe).Length / 1KB, 1))
        }
    } catch {
        Write-SRFail "Sessions.exe could not be built: $($_.Exception.Message)"
        # SAY WHICH OF THE TWO THINGS ACTUALLY HAPPENS. A build can fail with a
        # perfectly good exe already sitting there -- most commonly because the
        # app is RUNNING, which build.ps1 refuses rather than half-writing -- and
        # the buttons below are wired from Test-Path, not from whether the build
        # succeeded. Announcing a fallback that is not taken sends the operator
        # looking for a problem that is not there.
        if (Test-Path -LiteralPath $exe) {
            Write-SRSkip "the existing Sessions.exe is kept and the buttons still point at it - close the session window and re-run to rebuild"
        } else {
            Write-SRSkip "there is no Sessions.exe, so the desktop button will use Sessions.bat instead"
        }
    }

    # The desktop buttons point at the app, or at the .bat files when there is no
    # app, so a double-click from Explorer and a double-click on the shortcut take
    # the SAME path -- one launch route, one place to fix anything. The .bat pauses
    # only when it was double-clicked, so the output stays readable.
    $haveExe  = Test-Path -LiteralPath $exe
    $iconFrom = $(if ($haveExe) { "$exe,0" } else { 'powershell.exe,0' })

    # Both buttons are the SAME BINARY when there is one. Restoring is a
    # different action, not a second window, so the app takes -Restore and runs
    # this script instead: no single-instance lock, no splash, and a console --
    # because "Restore Sessions.bat" has always printed what it launched and
    # paused so you could read it, and folding it into the app must not quietly
    # take that away.
    #
    # THE LOGON TASK IS DELIBERATELY NOT MOVED. It still runs
    # restore-sessions.ps1 through powershell.exe. Putting the unattended path
    # behind a freshly compiled unsigned binary, on a machine whose antivirus
    # has quarantined this repo before, risks a logon that silently restores
    # nothing -- and nobody is at the keyboard to see it fail.
    # 🪤 THE NO-EXE FALLBACK TARGETS THE SCRIPT, NOT A WRAPPER. It used to point
    # at 'Restore Sessions.bat', which existed only to run this very file
    # through powershell.exe - one of five launchers in a folder that needs two.
    # The shortcut can invoke powershell directly, so the wrapper is gone and
    # nothing about the fallback is lost.
    $psExe = Join-Path $env:WINDIR 'System32\WindowsPowerShell\v1.0\powershell.exe'
    $restoreArgs = ('-NoProfile -ExecutionPolicy Bypass -File "{0}"' -f (Join-Path $SR_LibDir 'restore-sessions.ps1'))
    $l1 = New-SRShortcut -LinkName $LnkRestore `
            -Target $(if ($haveExe) { $exe } else { $psExe }) `
            -Arguments $(if ($haveExe) { '-Restore' } else { $restoreArgs }) -Icon $iconFrom `
            -Description 'Restore the Claude conversations you have selected'
    Write-SROk ("desktop: $LnkRestore" + $(if ($haveExe) { ' -> Sessions.exe -Restore' } else { ' -> restore-sessions.ps1' }))
    $l2 = New-SRShortcut -LinkName $LnkSelect `
            -Target $(if ($haveExe) { $exe } else { Join-Path $SR_Root 'Sessions.bat' }) `
            -Arguments '' -Icon $iconFrom `
            -Description 'Every conversation across every repo: see what is live, open any of them now, and choose what reopens at logon'
    Write-SROk ("desktop: $LnkSelect" + $(if ($haveExe) { ' -> Sessions.exe' } else { ' -> Sessions.bat' }))
    # 🪤 EVERY BUTTON THIS TOOL HAS EVER MADE IS REMOVED HERE, not just the last
    # one. Found on this machine after the launchers were consolidated: a
    # 'Claude Sessions (window).lnk' still pointing at Sessions GUI.vbs, a file
    # that no longer exists - a dead shortcut on the desktop that the installer
    # had no idea about, because it only ever knew the ONE name it had renamed.
    # A launcher that is deleted has to take its button with it.
    foreach ($stale in @($LnkSelectOld, 'Claude Sessions (window).lnk')) {
        $old = Join-Path ([Environment]::GetFolderPath('Desktop')) $stale
        if (Test-Path -LiteralPath $old) {
            [System.IO.File]::Delete($old)
            Write-SROk "desktop: $stale removed (replaced by '$LnkSelect')"
        }
    }

    # Seed the registry so the picker has something to show immediately.
    try {
        $cfg = Get-SRConfig
        $reg = Update-SRRegistry -Config $cfg -Quiet
        $sel = Get-SRSelected -Registry $reg -Config $cfg
        $all = @(@($reg.directories) | ForEach-Object { @($_.sessions) }).Count
        Write-SROk ("registry seeded: {0} project(s), {1} conversation(s), {2} ticked" -f @($reg.directories).Count, $all, @($sel).Count)
    } catch {
        Write-SRFail "registry seed failed: $($_.Exception.Message)"
    }

    # 🔑 AUTO-LOGON IS PART OF INSTALLING, so it is reported here rather than
    # living in a fourth launcher of its own. It is NOT enabled automatically
    # and never will be by default: it needs elevation and it stores a password
    # in the registry, which is not something an installer may decide on the
    # operator's behalf. -AutoLogon opts in explicitly; without it this says
    # where the machine stands and what the one command is.
    # 🪤 A CHILD PROCESS, NOT `&`. enable-autologon.ps1 ends its branches with
    # `exit 0`, and `&` on a .ps1 does not isolate that - calling it inline would
    # have terminated the INSTALLER the moment it printed the status, half way
    # through, with everything after this line silently skipped. Its own wrapper
    # always invoked it as `powershell.exe -File`, and that is why.
    Write-Host ""
    $alScript = Join-Path $SR_LibDir 'enable-autologon.ps1'
    $alArgs = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $alScript)
    if ($AutoLogon) {
        Write-Host "  auto-logon: enabling (this needs administrator)..."
        try {
            & powershell.exe @alArgs -Elevate -LockAfterLogon
        } catch {
            Write-SRFail "auto-logon could not be enabled: $($_.Exception.Message)"
        }
    } else {
        # 🪤 NOT `catch { }`. The first version swallowed whatever went wrong
        # here and the status simply never appeared - an installer reporting
        # nothing about auto-logon looks identical to one where auto-logon is
        # off. A silent catch on a diagnostic is the defect the diagnostic
        # exists to prevent.
        try {
            $alOut = & powershell.exe @alArgs -Status 2>&1
            if ($LASTEXITCODE -ne 0) {
                Write-SRSkip ("auto-logon status could not be read (exit {0}): {1}" -f $LASTEXITCODE, (@($alOut) -join ' '))
            } else {
                @($alOut) | ForEach-Object { Write-Host "$_" }
            }
        } catch {
            Write-SRSkip ("auto-logon status could not be read: " + $_.Exception.Message)
        }
        Write-Host "  to let the PC sign itself in so the logon restore runs unattended:"
        Write-Host ("    '{0}' -AutoLogon" -f (Join-Path $SR_Root 'Install.bat'))
    }

    Write-Host ""
    Write-Host ("  The control panel   :  double-click '{0}'          (or the desktop button)" -f $(if ($haveExe) { 'Sessions.exe' } else { 'Sessions.bat ' }))
    Write-Host "                         see what is live, L opens any conversation now, S starts a new one,"
    Write-Host "                         and the ticks decide what comes back at logon"
    Write-Host ("  Bring back the ticked:  {0}  (or the desktop button)" -f $(if ($haveExe) { "'Sessions.exe -Restore'" } else { 'the desktop button' }))
    Write-Host "  Open one by name    :  open the panel, then type in the search box and press Open"
    if ($haveExe) {
    Write-Host "  When something is wrong: Sessions.bat runs the same window with a console attached"
    }
    Write-Host "  Preview first       :  restore-sessions.ps1 -DryRun"
    Write-Host "  Everything lives in :  $SR_Root"
    Write-Host ""
    return 0
}

function Invoke-Uninstall {
    Write-Host ""
    Write-Host "Uninstalling" -ForegroundColor Cyan
    foreach ($t in @($TaskRestore, $TaskScan)) {
        if (Get-ScheduledTask -TaskName $t -ErrorAction SilentlyContinue) {
            Unregister-ScheduledTask -TaskName $t -Confirm:$false
            Write-SROk "task '$t' removed"
        } else { Write-SRSkip "task '$t' was not registered" }
    }
    # The legacy name is in the list so an uninstall after an old install still
    # leaves a clean desktop.
    foreach ($l in @($LnkRestore, $LnkSelect, $LnkSelectOld)) {
        $p = Join-Path ([Environment]::GetFolderPath('Desktop')) $l
        if (Test-Path -LiteralPath $p) { [System.IO.File]::Delete($p); Write-SROk "desktop: $l removed" }
        else { Write-SRSkip "desktop: $l was not present" }
    }
    Write-Host ""
    Write-Host "  Your selections in sessions-registry.json were left in place."
    Write-Host ""
    return 0
}

# ---------------------------------------------------------------------------
Clear-SRChildEnv

if ($Install -and $Uninstall) { Write-SRFail "-Install and -Uninstall are mutually exclusive"; exit 1 }

# A fatal throw at logon would otherwise vanish with the hidden window.
try {
    if ($Install)   { exit (Invoke-Install) }
    if ($Uninstall) { exit (Invoke-Uninstall) }
    if ($Scan)      { exit (Invoke-Scan) }
    if ($New)       { exit (Invoke-NewSession) }
    exit (Invoke-Restore)
} catch {
    Write-SRFail ("FATAL: " + $_.Exception.Message)
    Write-SRLog  ("       at " + $_.InvocationInfo.PositionMessage)
    exit 1
}

