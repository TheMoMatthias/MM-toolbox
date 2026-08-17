#requires -Version 5.1
<#
.SYNOPSIS
    Bring back the Claude Code conversations you have SELECTED, each with Remote
    Control attached under its real name.

.DESCRIPTION
    Discovery finds what exists; the registry says what should come back. They are
    deliberately separate -- a directory you untick stays untouched even though it
    is still discoverable, so a finished project stops reopening every morning.

    Run select-sessions.ps1 (or `ccs`) to tick and untick.

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
    .\select-sessions.ps1              # choose which directories are in scope
#>
[CmdletBinding()]
param(
    [switch]$Install,
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
$LnkSelect     = 'Select Claude Sessions.lnk'

# ---------------------------------------------------------------------------
function Invoke-Scan {
    Write-Host ""
    Write-Host "Claude session scan" -ForegroundColor Cyan
    Write-Host ""
    Write-SRLog "---- scan ----"
    $cfg = Get-SRConfig
    $reg = Update-SRRegistry -Config $cfg
    $sel = Get-SRSelected -Registry $reg
    $allS = @(@($reg.directories) | ForEach-Object { @($_.sessions) }).Count
    Write-Host ""
    Write-Host ("  {0} of {1} conversation(s), across {2} project(s), selected for restore" -f @($sel).Count, $allS, @($reg.directories).Count)
    Write-Host "  Choose with: select-sessions.ps1   (or ccs)"
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

    # Refresh first, quietly, so a project you started today is offered today.
    $reg = Update-SRRegistry -Config $cfg -Quiet

    $wanted   = Get-SRSelected -Registry $reg -IgnoreTicks:$All
    $knownDir = @($reg.directories).Count
    $knownSes = @(@($reg.directories) | ForEach-Object { @($_.sessions) }).Count

    # Three distinct states, never one silent green: nothing known, nothing
    # ticked, and nothing restorable are different problems with different fixes.
    if ($knownSes -eq 0) {
        Write-SRFail "no conversations discovered under $SR_Projects. Has claude ever run on this machine?"
        return 1
    }
    if (@($wanted).Count -eq 0) {
        Write-SRFail ("{0} conversation(s) across {1} project(s) known, but NONE is ticked. Run select-sessions.ps1 (or ccs) to choose." -f $knownSes, $knownDir)
        return 1
    }

    # One line per directory that is about to get two or more sessions. They share a
    # single git index, so a bare `git commit` in either takes whatever the other
    # staged -- the mitigation is `git commit -- <paths>`, not avoiding this.
    foreach ($grp in ($wanted | Group-Object -Property Path)) {
        if ($grp.Count -ge 2) {
            # Single-quoted: a backtick is PowerShell's escape character, and a
            # markdown-style one inside a double-quoted string is a parse error.
            Write-SRWarn (('{0}: restoring {1} conversations into ONE working tree - they share a git index, so commit with:  git commit -m msg -- <paths>') -f (Split-Path $grp.Name -Leaf), $grp.Count)
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

    $launched = 0; $skipped = 0; $failed = 0
    $staleDays = [double]$cfg.recencyDays

    foreach ($e in $wanted) {
        $label = Split-Path $e.path -Leaf

        if (-not (Test-Path -LiteralPath $e.path -PathType Container)) {
            Write-SRFail "$label - directory no longer exists: $($e.path)"; $failed++; continue
        }

        # Several conversations can share a directory now, so every line has to name
        # WHICH one -- three consecutive "AlgoTrader - skipped" tell you nothing.
        $title = $e.title
        if ([string]::IsNullOrWhiteSpace($title)) { $title = $label }
        $who = "$label / `"$title`""

        $jsonl = Get-SRTranscriptPath -Dir $e.path -SessionId $e.sessionId
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
            if ($ageDays -gt $staleDays) { Write-Host "         STALE - ticked, but untouched for ${ageDays}d. Untick it in select-sessions.ps1 if it is finished." -ForegroundColor DarkYellow }
            $launched++
            continue
        }

        try {
            $boot = New-SRBootScript -Dir $e.path -SessionId $e.sessionId -Title $title
            Start-SRSession -Dir $e.path -BootScript $boot -Title $title
            Write-SROk "$label -> `"$title`" ($($e.sessionId.Substring(0,8)), $(if($ageDays -ge 1){"${ageDays}d"}else{"${ageHours}h"}))"
            # Your tick wins over the age heuristic -- but staleness is visible,
            # here and in the log, rather than silently overruling you either way.
            if ($ageDays -gt $staleDays) {
                Write-Host "         STALE - ticked, but untouched for ${ageDays}d." -ForegroundColor DarkYellow
                Write-SRLog "         STALE - $label ticked but untouched for ${ageDays}d"
            }
            $launched++
            Start-Sleep -Milliseconds 1200
        } catch {
            Write-SRFail "$label - $($_.Exception.Message)"; $failed++
        }
    }

    Write-Host ""
    Write-Host ("  restored {0}   skipped {1}   failed {2}" -f $launched, $skipped, $failed)
    if ($launched -eq 0) {
        Write-Host "  NOTHING WAS RESTORED - every selected directory was skipped or failed." -ForegroundColor Yellow
    }
    Write-Host ""
    Write-SRLog ("  restored {0}   skipped {1}   failed {2}" -f $launched, $skipped, $failed)

    if ($failed -gt 0) { return 1 }
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
    param([string]$LinkName, [string]$Target, [string]$Arguments, [string]$Description)
    $p = Join-Path ([Environment]::GetFolderPath('Desktop')) $LinkName
    $s = (New-Object -ComObject WScript.Shell).CreateShortcut($p)
    $s.TargetPath       = $Target
    $s.Arguments        = $Arguments
    $s.WorkingDirectory = $SR_Root
    $s.IconLocation     = 'powershell.exe,0'
    $s.Description      = $Description
    $s.Save()
    return $p
}

function Invoke-Install {
    $restore = Join-Path $SR_Root 'restore-sessions.ps1'
    $select  = Join-Path $SR_Root 'select-sessions.ps1'

    Write-Host ""
    Write-Host "Installing" -ForegroundColor Cyan

    $principal = New-ScheduledTaskPrincipal -UserId "$env:USERDOMAIN\$env:USERNAME" -LogonType Interactive -RunLevel Limited
    $settings  = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
                    -ExecutionTimeLimit ([TimeSpan]::FromMinutes(10)) -MultipleInstances IgnoreNew

    # 1) restore, at logon
    $trg = New-ScheduledTaskTrigger -AtLogOn -User "$env:USERDOMAIN\$env:USERNAME"
    $trg.Delay = 'PT45S'
    Register-ScheduledTask -TaskName $TaskRestore -Force -Principal $principal -Settings $settings -Trigger $trg `
        -Action (New-ScheduledTaskAction -Execute 'powershell.exe' -Argument ("-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"{0}`"" -f $restore)) `
        -Description 'Restore selected Claude Code conversations with Remote Control attached.' | Out-Null
    Write-SROk "task '$TaskRestore' - at logon, 45s delay"

    # 2) scan, hourly + at logon. It only refreshes the registry; it launches
    #    nothing, so a new project appears in the picker without any risk.
    $trgLogon  = New-ScheduledTaskTrigger -AtLogOn -User "$env:USERDOMAIN\$env:USERNAME"
    $trgLogon.Delay = 'PT2M'
    $trgHourly = New-ScheduledTaskTrigger -Once -At (Get-Date).Date.AddMinutes(5) `
                    -RepetitionInterval ([TimeSpan]::FromHours(1)) -RepetitionDuration ([TimeSpan]::FromDays(3650))
    Register-ScheduledTask -TaskName $TaskScan -Force -Principal $principal -Settings $settings -Trigger @($trgLogon, $trgHourly) `
        -Action (New-ScheduledTaskAction -Execute 'powershell.exe' -Argument ("-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"{0}`" -Scan" -f $restore)) `
        -Description 'Discover Claude Code project directories. Updates the selection registry only; launches nothing.' | Out-Null
    Write-SROk "task '$TaskScan' - hourly + at logon (scan only, launches nothing)"

    $l1 = New-SRShortcut -LinkName $LnkRestore -Target 'powershell.exe' `
            -Arguments ("-NoProfile -ExecutionPolicy Bypass -File `"{0}`"" -f $restore) -Description 'Restore selected Claude Code conversations'
    Write-SROk "desktop: $LnkRestore"
    $l2 = New-SRShortcut -LinkName $LnkSelect -Target 'powershell.exe' `
            -Arguments ("-NoProfile -ExecutionPolicy Bypass -NoExit -File `"{0}`"" -f $select) -Description 'Choose which directories reopen at logon'
    Write-SROk "desktop: $LnkSelect"

    # Seed the registry so the picker has something to show immediately.
    try {
        $cfg = Get-SRConfig
        $reg = Update-SRRegistry -Config $cfg -Quiet
        $sel = Get-SRSelected -Registry $reg
        $all = @(@($reg.directories) | ForEach-Object { @($_.sessions) }).Count
        Write-SROk ("registry seeded: {0} project(s), {1} conversation(s), {2} ticked" -f @($reg.directories).Count, $all, @($sel).Count)
    } catch {
        Write-SRFail "registry seed failed: $($_.Exception.Message)"
    }

    Write-Host ""
    Write-Host "  Choose what reopens :  select-sessions.ps1   (or ccs, or the desktop button)"
    Write-Host "  Preview a restore   :  restore-sessions.ps1 -DryRun   (or ccr -DryRun)"
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
    foreach ($l in @($LnkRestore, $LnkSelect)) {
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
