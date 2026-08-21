#requires -Version 5.1
<#
.SYNOPSIS
    The session control panel: see every conversation across every repo, launch any
    of them right now, and choose which ones reopen at logon.

.DESCRIPTION
    Three levels. A PROJECT is a repository. Under it sit LANES -- `main` for the
    repo's own tree, and one lane per git worktree. Each conversation has its own
    tick, and the project has a master tick above them all.

    TWO INDEPENDENT THINGS live on this screen, and confusing them is the one way to
    misread it:

      the TICK  [x]   does this reopen automatically at LOGON?
      the KEY    L    open this one NOW, in a new tab, whatever its tick says

    So a conversation you never want at logon is still one keypress away, and
    ticking something does not launch it. Nothing here launches anything until you
    press L or X.

    A background task rescans hourly. Newly discovered conversations arrive ticked
    if they were active within sessionWindowDays -- at most autoTickPerDirectory
    from main and autoTickPerWorktree from each worktree.

    Keys:  UP/DOWN move   SPACE tick+pin   U unpin   LEFT/RIGHT fold   A all  N none
           L launch now   S spawn new      X launch everything ticked
           W worktrees    R rescan         ENTER save   ESC / Q cancel

.PARAMETER List
    Print the current selection and exit. Also the automatic fallback when there is
    no interactive console.

.PARAMETER Enable
.PARAMETER Disable
    Tick or untick without the picker. Matches a project path, a worktree name, or
    a conversation title/id, case-insensitively.

.PARAMETER Launch
    Launch matching conversations NOW and exit, without opening the panel and
    WITHOUT regard to their tick. Same matching as -Enable/-Disable. This is the
    one-liner form of pressing L.

.EXAMPLE
    .\select-sessions.ps1
    .\select-sessions.ps1 -List
    .\select-sessions.ps1 -Disable bounded-contexts
    .\select-sessions.ps1 -Launch RC-WORKFLOW
    .\select-sessions.ps1 -Launch AlgoTrader -DryRun
#>
[CmdletBinding()]
param(
    [switch]$List,
    [string[]]$Enable,
    [string[]]$Disable,

    # Launch now, ignoring ticks entirely. Deliberately NOT a tick operation: the
    # whole point is reaching a conversation you never want back at logon.
    [string[]]$Launch,
    [switch]$DryRun,

    # Turn git-worktree lanes on or off and write it back to the config, so the
    # setting is reachable without hand-editing JSON. W does the same in the picker.
    [ValidateSet('on', 'off')]
    [string]$Worktrees,

    [switch]$NoScan
)

$ErrorActionPreference = 'Stop'

$here = $PSScriptRoot
if (-not $here -and $MyInvocation.MyCommand.Path) { $here = Split-Path -Parent $MyInvocation.MyCommand.Path }
if (-not $here) { $here = (Get-Location).Path }
. (Join-Path $here '_common.ps1')

$cfg = Get-SRConfig

# Applied BEFORE the scan, so turning worktrees on discovers them in the same run
# rather than needing a second pass.
if ($Worktrees) {
    $want = ($Worktrees -eq 'on')
    if ([bool]$cfg.includeWorktrees -eq $want) {
        Write-Host ("  worktrees were already {0}" -f $Worktrees.ToUpper()) -ForegroundColor Yellow
    } else {
        $null = Set-SRIncludeWorktrees -Value $want
        Write-Host ("  worktrees {0}" -f $(if ($want) { 'ON  - a lane under each repo, restorable' } else { 'OFF - hidden and never restored' })) `
            -ForegroundColor $(if ($want) { 'Green' } else { 'DarkYellow' })
    }
    $cfg = Get-SRConfig
}

if (-not $NoScan) {
    # Say something BEFORE the scan. It used to run silently and the window sat
    # blank for the whole of it -- which read as "nothing is happening".
    Write-Host "  Scanning conversations..." -NoNewline -ForegroundColor DarkGray
    $swScan = [Diagnostics.Stopwatch]::StartNew()
    try { $null = Update-SRRegistry -Config $cfg -Quiet } catch { Write-Warning "scan failed: $($_.Exception.Message)" }
    $swScan.Stop()
    Write-Host (" {0} ms" -f $swScan.ElapsedMilliseconds) -ForegroundColor DarkGray
}

$reg     = Get-SRRegistry
$showWt  = [bool]$cfg.includeWorktrees
$staleDays = [double]$cfg.recencyDays

# 🪤 Null-filtered, not just @()-wrapped. A PowerShell function RETURNING an empty
# array yields $null, and `@($null)` is an array of ONE $null -- which sails past a
# .Count check and then dies in the sort as "Cannot index into a null array".
# Measured 2026-08-21, the first time a project ended up with zero conversations.
function Get-Newest { param($Sessions)
    $s = @(@($Sessions) | Where-Object { $_ })
    if (-not $s.Count) { return [datetime]'1970-01-01' }
    $ordered = @($s | Where-Object { $_.lastActive } | Sort-Object { [datetime]$_.lastActive } -Descending)
    if (-not $ordered.Count) { return [datetime]'1970-01-01' }
    return [datetime]$ordered[0].lastActive
}

# Sessions of a project that are currently in scope (worktrees may be switched off).
# Returns them UNWRAPPED -- every caller wraps in @() itself, and a leading comma
# here hands them an array-of-one-array instead, which member-enumerates into
# nonsense rather than failing outright. Empty therefore arrives as $null, which is
# Get-Newest's job to survive.
function Get-Visible { param($Dir)
    if ($showWt) { return @($Dir.sessions) }
    return @(@($Dir.sessions) | Where-Object { $_.lane -ne 'worktree' })
}

$dirs = @($reg.directories | Sort-Object { Get-Newest (Get-Visible $_) } -Descending)

if ($dirs.Count -eq 0) {
    Write-Host "`n  No projects discovered yet. Run claude in a project once, then re-run this.`n" -ForegroundColor Yellow
    exit 1
}

function Get-Age { param($Iso)
    $d = ((Get-Date) - [datetime]$Iso)
    if ($d.TotalDays -ge 1) { return ("{0}d" -f [int]$d.TotalDays) }
    return ("{0}h" -f [int]$d.TotalHours)
}
function Test-Stale { param($Iso) return (((Get-Date) - [datetime]$Iso).TotalDays -gt $staleDays) }

# Touching a conversation PINS it: the hourly roll then leaves it alone. Without
# this the scan would undo every hand-made choice within the hour.
function Set-Pin {
    param($Session, [bool]$Value)
    if ($null -eq $Session.PSObject.Properties['pinned']) {
        $Session | Add-Member -NotePropertyName pinned -NotePropertyValue $Value -Force
    } else { $Session.pinned = $Value }
}
function Test-Pinned { param($Session) return ([bool]$Session.pinned) }

function Get-LaneName { param($Session)
    if ($Session.lane -eq 'worktree' -and $Session.worktree) { return $Session.worktree }
    return 'main'
}

# main first, then worktree lanes newest-first.
function Get-Lanes { param($Dir)
    $g = @(Get-Visible $Dir) | Group-Object -Property { Get-LaneName $_ }
    $out = @()
    $out += @($g | Where-Object { $_.Name -eq 'main' })
    $out += @($g | Where-Object { $_.Name -ne 'main' } | Sort-Object { Get-Newest $_.Group } -Descending)
    return ,@($out)
}

# --- live state and launching ----------------------------------------------
# Probed once into lookup tables, NOT recomputed per row: this screen redraws on
# every keystroke over ~90 rows, and the probes are a WMI round trip (~100 ms) and
# a stat per transcript.
$script:running   = @{}
$script:live      = @{}
$script:launching = @{}
$script:status    = $null
$script:statusCol = 'Gray'

function Set-Status { param([string]$Message, [string]$Color = 'Gray')
    $script:status = $Message; $script:statusCol = $Color
}

# TWO probes, because neither alone is enough -- and this is the same pair the
# logon restore guards with, so L can never disagree with it.
#
#   command line   only sessions carrying `--resume <id>` (or `--session-id`) are
#                  visible, which means the ones THIS tool launched. Measured here:
#                  5 of 9 running claude.exe. The other 3 were bare `claude` with
#                  a conversation picked from /resume afterwards -- no id anywhere.
#   transcript     mtime inside the live window catches those, but only while the
#                  session is actively WRITING. One idle at its prompt looks dead.
#
# So "no mark" means "no evidence it is open", never "definitely closed".
function Update-Running {
    $script:running = Get-SRRunningIds -Refresh
    $script:live    = @{}
    foreach ($d in @($script:dirs)) {
        foreach ($s in @($d.sessions)) {
            $cwd = if ($s.cwd) { $s.cwd } else { $d.path }
            if (Test-SRTranscriptLive -JsonlPath (Get-SRTranscriptPath -Dir $cwd -SessionId $s.sessionId -Recorded $s.jsonl)) {
                $script:live["$($s.sessionId)".ToLower()] = $true
            }
        }
    }
}

# 'run' certain, 'act' probable, 'new' just spawned by us. The last one earns its
# keep: claude takes seconds to surface in Win32_Process, and without it the row
# you just launched still reads as idle and invites a second, duplicate tab.
function Get-SessionState { param($Session)
    $id = "$($Session.sessionId)".ToLower()
    if ($script:running[$id])   { return 'run' }
    if ($script:launching[$id]) { return 'new' }
    if ($script:live[$id])      { return 'act' }
    return ''
}

# The session's OWN working directory. Main and each worktree launch in different
# places, so the project path is only the fallback.
function Get-SessionCwd { param($Session, $Dir)
    if ($Session.cwd) { return $Session.cwd }
    return $Dir.path
}
function Get-SessionTitle { param($Session, $Dir)
    $t = $Session.title
    if ([string]::IsNullOrWhiteSpace($t)) { $t = (Split-Path (Get-SessionCwd $Session $Dir) -Leaf) }
    return $t
}

# Returns $null when it launched (or would), otherwise the reason it did not.
# Every guard here is one restore-sessions.ps1 already applies: one launch path,
# one set of rules, so L and the logon restore can never disagree.
function Invoke-LaunchSession {
    param($Session, $Dir, [switch]$Preview)
    $cwd   = Get-SessionCwd   $Session $Dir
    $title = Get-SessionTitle $Session $Dir
    $id    = "$($Session.sessionId)".ToLower()

    if (-not (Test-Path -LiteralPath $cwd -PathType Container)) { return "directory no longer exists: $cwd" }
    $jsonl = Get-SRTranscriptPath -Dir $cwd -SessionId $Session.sessionId -Recorded $Session.jsonl
    if (-not (Test-Path -LiteralPath $jsonl)) { return "transcript missing for $($Session.sessionId.Substring(0,8)) - press R to rescan" }
    if ($script:running[$id])   { return "already open in a running claude.exe" }
    if ($script:launching[$id]) { return "already launched a moment ago" }
    if ($script:live[$id])      { return "already live - its transcript was written < $SR_LiveWindowMinutes min ago" }
    if ($Preview) { return $null }

    $boot = New-SRBootScript -Dir $cwd -SessionId $Session.sessionId -Title $title
    Start-SRSession -Dir $cwd -BootScript $boot -Title $title
    $script:launching[$id] = $true
    Write-SRLog ("  [ok]   panel launch  {0}  {1}  {2}" -f $title, $Session.sessionId, $cwd)
    return $null
}

function Invoke-SpawnNew {
    param([Parameter(Mandatory)][string]$Dir, [string]$Name)
    if (-not (Test-Path -LiteralPath $Dir -PathType Container)) { return "directory no longer exists: $Dir" }
    # Same naming rule as restore-sessions.ps1 -New, so a session spawned from the
    # panel and one spawned from the shell are indistinguishable afterwards.
    if ([string]::IsNullOrWhiteSpace($Name)) { $Name = (Split-Path $Dir -Leaf) + '-' + (Get-Date -Format 'MMdd-HHmm') }
    $Name = ($Name -replace '\s+', '-').Trim('-')
    if ([string]::IsNullOrWhiteSpace($Name)) { $Name = 'claude-' + (Get-Date -Format 'MMdd-HHmm') }
    $boot = New-SRBootScript -Dir $Dir -Title $Name
    Start-SRSession -Dir $Dir -BootScript $boot -Title $Name
    Write-SRLog ("  [ok]   panel spawn   {0}  {1}" -f $Name, $Dir)
    return $null
}

# First probe. Needs $dirs, so it cannot be an initialiser further up.
Update-Running

function Get-Counts {
    $on = 0; $tot = 0; $projOn = 0
    foreach ($d in $dirs) {
        if ($d.missing) { continue }
        $v = @(Get-Visible $d)
        $tot += $v.Count
        if ($d.enabled) {
            $n = @($v | Where-Object { $_.enabled }).Count
            if ($n -gt 0) { $projOn++ }
            $on += $n
        }
    }
    return [PSCustomObject]@{ Sessions = $on; Total = $tot; Projects = $projOn }
}

function Write-Summary {
    $c = Get-Counts
    $pinned = @(@($dirs) | ForEach-Object { Get-Visible $_ } | Where-Object { $_.pinned }).Count
    Write-Host ""
    Write-Host ("  {0} conversation(s) across {1} project(s) will reopen at logon, out of {2} known." -f $c.Sessions, $c.Projects, $c.Total)
    Write-Host ("  {0} pinned (yours, the roll leaves them alone). Auto: newest {1} from main, {2} from each worktree." -f $pinned, $cfg.autoTickPerDirectory, $cfg.autoTickPerWorktree) -ForegroundColor DarkGray
    if (-not $showWt) {
        Write-Host "  Worktrees are OFF (includeWorktrees=false in the config) - hidden and never restored." -ForegroundColor DarkYellow
    }
    # Two conversations in ONE tree share a git index. Main and each worktree are
    # DIFFERENT trees, so they are counted separately.
    foreach ($d in $dirs) {
        if ($d.missing -or -not $d.enabled) { continue }
        foreach ($lane in (Get-Lanes $d)) {
            $n = @(@($lane.Group) | Where-Object { $_.enabled }).Count
            if ($n -ge 2) {
                Write-Host ("     {0}/{1}: {2} conversations in ONE tree - commit with: git commit -m msg -- <paths>" -f (Split-Path $d.path -Leaf), $lane.Name, $n) -ForegroundColor Yellow
            }
        }
    }
    Write-Host ""
}

# --- non-interactive: -Enable / -Disable -----------------------------------
if ($Enable -or $Disable) {
    $changed = 0
    foreach ($d in $dirs) {
        foreach ($pair in @(@{p=$Enable;v=$true}, @{p=$Disable;v=$false})) {
            foreach ($pat in @($pair.p)) {
                if (-not $pat) { continue }
                if ($d.path -like "*$pat*") {
                    if ($d.enabled -ne $pair.v) {
                        $d.enabled = $pair.v; $changed++
                        Write-Host ("  project  {0}  {1}" -f $(if($pair.v){'ticked  '}else{'unticked'}), $d.path) -ForegroundColor $(if($pair.v){'Green'}else{'DarkYellow'})
                    }
                }
                foreach ($s in (Get-Visible $d)) {
                    $lane = Get-LaneName $s
                    if (("$($s.title)" -like "*$pat*") -or ("$($s.sessionId)" -like "*$pat*") -or ($lane -like "*$pat*")) {
                        if ($s.enabled -ne $pair.v -or -not (Test-Pinned $s)) {
                            $s.enabled = $pair.v; Set-Pin $s $true; $changed++
                            Write-Host ("  session  {0}  {1}  ({2}/{3})  [pinned]" -f $(if($pair.v){'ticked  '}else{'unticked'}), $s.title, (Split-Path $d.path -Leaf), $lane) -ForegroundColor $(if($pair.v){'Green'}else{'DarkYellow'})
                        }
                    }
                }
            }
        }
    }
    if ($changed -eq 0) { Write-Host "  nothing matched - no change" -ForegroundColor Yellow } else { Save-SRRegistry -Registry $reg }
    Write-Summary
    exit 0
}

# --- non-interactive: -Launch ----------------------------------------------
# Ticks are not consulted anywhere in here. That is the whole point: the logon set
# and "what I want open right now" are different questions.
if ($Launch) {
    $hits = @()
    foreach ($d in $dirs) {
        if ($d.missing) { continue }
        foreach ($s in (Get-Visible $d)) {
            $lane = Get-LaneName $s
            foreach ($pat in @($Launch)) {
                if (-not $pat) { continue }
                if (("$($s.title)" -like "*$pat*") -or ("$($s.sessionId)" -like "*$pat*") -or
                    ($lane -like "*$pat*") -or ($d.path -like "*$pat*")) {
                    $hits += [PSCustomObject]@{ S = $s; D = $d }
                    break
                }
            }
        }
    }

    Write-Host ""
    Write-Host "Launch now" -ForegroundColor Cyan
    if ($DryRun) { Write-Host "DRY RUN - nothing will be launched" -ForegroundColor Yellow }
    Write-Host ""

    if (@($hits).Count -eq 0) {
        Write-SRFail ("nothing matched: {0}" -f (@($Launch) -join ', '))
        Write-Host "  -List shows the titles, worktree names and ids that are matched."
        Write-Host ""
        exit 1
    }

    # A loose pattern matches far more than you meant -- '-Launch a' would take the
    # lot. Say the number BEFORE opening that many tabs, not after.
    $hits = @($hits | Sort-Object { [datetime]$_.S.lastActive } -Descending)
    $cap  = [int]$cfg.maxSessions
    if ($cap -gt 0 -and @($hits).Count -gt $cap) {
        Write-SRWarn ("{0} matched, over the maxSessions cap of {1} - taking the {1} most recent" -f @($hits).Count, $cap)
        $hits = @($hits | Select-Object -First $cap)
    }

    $ok = 0; $no = 0
    foreach ($h in $hits) {
        $who = "{0}/{1} / `"{2}`"" -f (Split-Path $h.D.path -Leaf), (Get-LaneName $h.S), (Get-SessionTitle $h.S $h.D)
        $why = Invoke-LaunchSession -Session $h.S -Dir $h.D -Preview:$DryRun
        if ($why) { Write-SRSkip "$who - $why"; $no++ }
        else {
            Write-SROk $who
            $ok++
            # Breathing room so Windows Terminal does not race itself, same as the
            # logon restore.
            if (-not $DryRun) { Start-Sleep -Milliseconds 500 }
        }
    }

    Write-Host ""
    Write-Host ("  {0} {1}   skipped {2}" -f $(if ($DryRun) { 'would launch' } else { 'launched' }), $ok, $no)
    Write-Host ""
    if ($ok -eq 0) { exit 1 }
    exit 0
}

function Write-PlainList {
    Write-Host ""
    Write-Host "Claude sessions" -ForegroundColor Cyan
    Write-Host ""
    foreach ($d in $dirs) {
        $v    = @(Get-Visible $d)
        $mark = if ($d.missing) { '[?]' } elseif ($d.enabled) { '[x]' } else { '[ ]' }
        $col  = if ($d.missing) { 'DarkGray' } elseif ($d.enabled) { 'Cyan' } else { 'Gray' }
        $n    = @($v | Where-Object { $_.enabled }).Count
        Write-Host ("  {0} {1,-26} {2,2}/{3,-3} ticked   {4}" -f $mark, (Split-Path $d.path -Leaf), $n, $v.Count, $d.path) -ForegroundColor $col
        foreach ($lane in (Get-Lanes $d)) {
            $ln = @(@($lane.Group) | Where-Object { $_.enabled }).Count
            $lc = if ($lane.Name -eq 'main') { 'White' } else { 'Magenta' }
            Write-Host ("      {0,-22} {1,2}/{2,-3}" -f $lane.Name, $ln, @($lane.Group).Count) -ForegroundColor $lc
            foreach ($s in (@($lane.Group) | Sort-Object { [datetime]$_.lastActive } -Descending)) {
                $sm = if ($s.enabled) { '[x]' } else { '[ ]' }
                $sp = if (Test-Pinned $s) { '*' } else { ' ' }
                $sc = if (-not $d.enabled) { 'DarkGray' } elseif (-not $s.enabled) { 'Gray' } elseif (Test-Stale $s.lastActive) { 'DarkYellow' } else { 'Green' }
                $sl = switch (Get-SessionState $s) { 'run' { 'LIVE' } 'act' { 'live' } default { '    ' } }
                Write-Host ("        {0}{1} {2,-32} {3,5}  {4}  {5}" -f $sp, $sm, $s.title, (Get-Age $s.lastActive), $sl, $s.sessionId.Substring(0,8)) -ForegroundColor $sc
            }
        }
    }
    Write-Summary
    Write-Host "  Open the panel  :  select-sessions.ps1                      (tick, and launch with L)"
    Write-Host "  Launch one now  :  select-sessions.ps1 -Launch RC-WORKFLOW  (project, worktree, title or id)"
    Write-Host "  Change the ticks:  select-sessions.ps1 -Disable bounded-contexts"
    Write-Host "  Or edit directly:  $SR_RegistryPath"
    Write-Host ""
}

# -Worktrees is a one-shot setting change, so report the result and stop rather than
# dropping into the picker unasked.
if ($List -or $Worktrees) { Write-PlainList; exit 0 }

# Without a real console, ReadKey throws or blocks forever. Degrade to the list
# rather than hanging a scheduled task or a piped invocation.
$interactive = $true
try {
    if (-not [Environment]::UserInteractive)  { $interactive = $false }
    elseif ($null -eq $Host.UI.RawUI)         { $interactive = $false }
    elseif ([Console]::IsInputRedirected)     { $interactive = $false }
} catch { $interactive = $false }

if (-not $interactive) {
    Write-Host "`n  No interactive console - showing the list instead of the picker." -ForegroundColor Yellow
    Write-PlainList
    exit 0
}

# --- interactive picker ----------------------------------------------------
$collapsed = @{}
$cursor = 0
$dirty  = $false

function Build-Rows {
    $rows = @()
    foreach ($d in $dirs) {
        $rows += [PSCustomObject]@{ Kind = 'dir'; Dir = $d; Lane = $null; Key = $d.path; Session = $null }
        if ($collapsed[$d.path]) { continue }
        foreach ($lane in (Get-Lanes $d)) {
            $lkey = "$($d.path)|$($lane.Name)"
            $rows += [PSCustomObject]@{ Kind = 'lane'; Dir = $d; Lane = $lane; Key = $lkey; Session = $null }
            if ($collapsed[$lkey]) { continue }
            foreach ($s in (@($lane.Group) | Sort-Object { [datetime]$_.lastActive } -Descending)) {
                $rows += [PSCustomObject]@{ Kind = 'session'; Dir = $d; Lane = $lane; Key = $lkey; Session = $s }
            }
        }
    }
    return ,@($rows)
}

function Render {
    param($Rows, $Cursor)
    Clear-Host
    $c = Get-Counts
    $liveTotal = @(@($dirs) | ForEach-Object { Get-Visible $_ } | Where-Object { Get-SessionState $_ }).Count
    Write-Host ""
    Write-Host "  Claude sessions" -ForegroundColor Cyan -NoNewline
    Write-Host ("   {0} live now" -f $liveTotal) -ForegroundColor Cyan -NoNewline
    Write-Host ("   |   {0} of {1} ticked to reopen at logon, in {2} project(s)" -f $c.Sessions, $c.Total, $c.Projects) -ForegroundColor Gray
    if (-not $showWt) { Write-Host "  worktrees OFF" -ForegroundColor DarkYellow }
    Write-Host ""

    # Header plus the footer block, which grew when the action keys and the LIVE
    # legend arrived. Under-count it and the top of the list scrolls off.
    $height = 20
    try { $height = [Math]::Max(6, $Host.UI.RawUI.WindowSize.Height - 14) } catch { }
    $first = 0
    if ($Rows.Count -gt $height) { $first = [Math]::Max(0, [Math]::Min($Cursor - [int]($height / 2), $Rows.Count - $height)) }
    $last = [Math]::Min($Rows.Count - 1, $first + $height - 1)

    if ($first -gt 0) { Write-Host "      ..." -ForegroundColor DarkGray }
    for ($i = $first; $i -le $last; $i++) {
        $r   = $Rows[$i]
        $sel = if ($i -eq $Cursor) { '>' } else { ' ' }

        switch ($r.Kind) {
            'dir' {
                $d = $r.Dir
                $v = @(Get-Visible $d)
                $mark = if ($d.missing) { '[?]' } elseif ($d.enabled) { '[x]' } else { '[ ]' }
                $n    = @($v | Where-Object { $_.enabled }).Count
                $fold = if ($collapsed[$d.path]) { '+' } else { '-' }
                # Folded away, a project's live conversations would be invisible.
                $live = @(@($v) | Where-Object { Get-SessionState $_ }).Count
                $note = if ($d.missing) { '  MISSING' } elseif ($live -gt 0) { "  $live live" } else { '' }
                $col  = if ($i -eq $Cursor) { 'White' } elseif ($d.missing) { 'DarkGray' } elseif ($d.enabled) { 'Cyan' } else { 'Gray' }
                Write-Host ("  {0} {1} {2} {3,-26} {4,2}/{5,-3}{6}" -f $sel, $mark, $fold, (Split-Path $d.path -Leaf), $n, $v.Count, $note) -ForegroundColor $col
            }
            'lane' {
                $ln   = @(@($r.Lane.Group) | Where-Object { $_.enabled }).Count
                $fold = if ($collapsed[$r.Key]) { '+' } else { '-' }
                $tag  = if ($r.Lane.Name -eq 'main') { 'main' } else { 'worktree: ' + $r.Lane.Name }
                $warn = if ($r.Dir.enabled -and $ln -ge 2) { "  $ln in one tree" } else { '' }
                $col  = if ($i -eq $Cursor) { 'White' } elseif ($r.Lane.Name -eq 'main') { 'DarkCyan' } else { 'Magenta' }
                Write-Host ("  {0}     {1} {2,-30} {3,2}/{4,-3}{5}" -f $sel, $fold, $tag, $ln, @($r.Lane.Group).Count, $warn) -ForegroundColor $col
            }
            'session' {
                $d = $r.Dir; $s = $r.Session
                $mark = if ($s.enabled) { '[x]' } else { '[ ]' }
                $pin  = if (Test-Pinned $s) { '*' } else { ' ' }
                $note = ''
                if ($d.enabled -and $s.enabled -and (Test-Stale $s.lastActive)) { $note = '  STALE' }
                if (-not $d.enabled) { $note = '  (project off)' }
                $col = if ($i -eq $Cursor) { 'White' } elseif (-not $d.enabled) { 'DarkGray' } elseif (-not $s.enabled) { 'Gray' } elseif (Test-Stale $s.lastActive) { 'DarkYellow' } else { 'Green' }
                # Three writes so LIVE keeps its own colour: the tick tells you what
                # reopens at logon, this tells you what is open NOW, and they must
                # not be readable as one thing.
                Write-Host ("  {0}        {1}{2} {3,-30} {4,5}  " -f $sel, $pin, $mark, $s.title, (Get-Age $s.lastActive)) -ForegroundColor $col -NoNewline
                # Upper case = certain, lower case = inferred. Deliberately not the
                # same word twice: one is a process holding the id, the other is a
                # file that moved recently.
                switch (Get-SessionState $s) {
                    'run'   { Write-Host 'LIVE' -ForegroundColor Cyan     -NoNewline }
                    'act'   { Write-Host 'live' -ForegroundColor DarkCyan -NoNewline }
                    'new'   { Write-Host '..  ' -ForegroundColor DarkCyan -NoNewline }
                    default { Write-Host '    '                           -NoNewline }
                }
                Write-Host $note -ForegroundColor $col
            }
        }
    }
    if ($last -lt $Rows.Count - 1) { Write-Host "      ..." -ForegroundColor DarkGray }

    Write-Host ""
    $cur = $Rows[$Cursor]
    $curPath = if ($cur.Kind -eq 'session' -and $cur.Session.cwd) { $cur.Session.cwd } else { $cur.Dir.path }
    Write-Host ("  " + $curPath) -ForegroundColor DarkGray
    Write-Host ""
    if ($script:status) { Write-Host ("  " + $script:status) -ForegroundColor $script:statusCol }
    Write-Host "  L launch NOW   S spawn new session here   X launch everything ticked" -ForegroundColor Cyan
    Write-Host "  UP/DOWN move  SPACE tick+pin  U unpin  LEFT/RIGHT fold  A all  N none" -ForegroundColor DarkCyan
    Write-Host ("  W worktrees {0}  R rescan  ENTER save  ESC cancel" -f $(if ($showWt) { 'ON (press to hide) ' } else { 'OFF (press to show)' })) -ForegroundColor DarkCyan
    # The one distinction this screen lives or dies on, plus how far to trust LIVE.
    Write-Host "  [x] = reopens at LOGON.  L = open it NOW regardless.  * = pinned, the roll leaves it alone." -ForegroundColor DarkGray
    Write-Host "  LIVE = a claude.exe holds it.  live = its transcript just moved.  Blank is no evidence, not proof." -ForegroundColor DarkGray
}

function Invoke-Rescan {
    if ($script:dirty) { Save-SRRegistry -Registry $script:reg; $script:dirty = $false }
    $null = Update-SRRegistry -Config $script:cfg -Quiet
    $script:reg  = Get-SRRegistry
    $script:dirs = @($script:reg.directories | Sort-Object { Get-Newest (Get-Visible $_) } -Descending)
    # R is also how you ask "what is actually open?" -- and it is the only thing
    # that clears the optimistic '..' marks, once the real processes have appeared.
    Update-Running
    $script:launching = @{}
}

# ReadKey rather than Read-Host: the panel is already in raw-key mode, and a
# stray Enter should not be able to confirm twelve tabs.
function Read-YesNo {
    param([Parameter(Mandatory)][string]$Prompt)
    Write-Host ""
    Write-Host ("  " + $Prompt + "  [y/N] ") -ForegroundColor Yellow -NoNewline
    $k = [Console]::ReadKey($true)
    Write-Host ""
    return ($k.KeyChar -eq 'y' -or $k.KeyChar -eq 'Y')
}

# The directory a row stands for. A lane's path comes from its own sessions --
# a worktree lives somewhere else entirely, not under the project root.
function Get-RowPath {
    param($Row)
    switch ($Row.Kind) {
        'session' { return (Get-SessionCwd $Row.Session $Row.Dir) }
        'lane'    {
            $first = @($Row.Lane.Group)[0]
            if ($first) { return (Get-SessionCwd $first $Row.Dir) }
            return $Row.Dir.path
        }
        default   { return $Row.Dir.path }
    }
}

# Every session a row covers, newest first: one for a session row, the lane's for a
# lane, the whole project for a project row.
function Get-RowSessions {
    param($Row)
    $out = switch ($Row.Kind) {
        'session' { @($Row.Session) }
        'lane'    { @($Row.Lane.Group) }
        default   { @(Get-Visible $Row.Dir) }
    }
    return ,@($out | Sort-Object { [datetime]$_.lastActive } -Descending)
}

# Shared by L and X so both report the same way. Returns nothing; sets the status.
function Invoke-LaunchMany {
    param($Items, [string]$What)
    $ok = 0; $no = 0; $lastWhy = $null
    # Printed under the panel as it goes. Windows Terminal needs breathing room
    # between tabs, so a dozen of these is six seconds -- silent, that reads as a
    # hang, and the screen is cleared on the next redraw anyway.
    if (@($Items).Count -gt 1) { Write-Host "" }
    foreach ($it in $Items) {
        if (@($Items).Count -gt 1) {
            Write-Host ("  opening {0} ..." -f (Get-SessionTitle $it.S $it.D)) -ForegroundColor DarkGray
        }
        $why = Invoke-LaunchSession -Session $it.S -Dir $it.D
        if ($why) { $no++; $lastWhy = $why }
        else      { $ok++; Start-Sleep -Milliseconds 500 }
    }
    if ($ok -gt 0) {
        $msg = "launched $ok $What"
        if ($no -gt 0) { $msg += " - $no skipped ($lastWhy)" }
        Set-Status $msg 'Green'
    } elseif ($no -gt 0) {
        # One skip names its reason; several would be a wall of text on a status
        # line, so the count carries it and the log has the detail.
        Set-Status $(if ($no -eq 1) { "not launched - $lastWhy" } else { "nothing launched - $no skipped, last: $lastWhy" }) 'DarkYellow'
    } else {
        Set-Status "nothing to launch here" 'DarkYellow'
    }
}

$rows = Build-Rows
while ($true) {
    if ($cursor -ge $rows.Count) { $cursor = [Math]::Max(0, $rows.Count - 1) }
    Render -Rows $rows -Cursor $cursor
    $key = [Console]::ReadKey($true)
    $row = $rows[$cursor]

    switch ($key.Key) {
        # Moving clears the last result line: a "launched 1" left hanging over a
        # different row reads as if THAT row was launched.
        'UpArrow'    { if ($cursor -gt 0) { $cursor-- }; $script:status = $null }
        'DownArrow'  { if ($cursor -lt $rows.Count - 1) { $cursor++ }; $script:status = $null }
        'Home'       { $cursor = 0; $script:status = $null }
        'End'        { $cursor = $rows.Count - 1; $script:status = $null }
        'LeftArrow'  { $collapsed[$row.Key] = $true;  $rows = Build-Rows }
        'RightArrow' { $collapsed[$row.Key] = $false; $rows = Build-Rows }
        'Spacebar'   {
            switch ($row.Kind) {
                'dir'  { if (-not $row.Dir.missing) { $row.Dir.enabled = -not $row.Dir.enabled; $dirty = $true } }
                'lane' {
                    # Toggle the whole lane to whatever it is NOT already all-on.
                    $allOn = -not (@($row.Lane.Group) | Where-Object { -not $_.enabled })
                    foreach ($s in @($row.Lane.Group)) { $s.enabled = (-not $allOn); Set-Pin $s $true }
                    $dirty = $true
                }
                'session' { $row.Session.enabled = -not $row.Session.enabled; Set-Pin $row.Session $true; $dirty = $true }
            }
        }
        'Enter' {
            if ($dirty) { Save-SRRegistry -Registry $reg }
            Clear-Host
            Write-Host ""
            Write-Host $(if ($dirty) { "  Saved." } else { "  No changes." }) -ForegroundColor Green
            Write-Summary
            Write-Host "  Registry: $SR_RegistryPath"
            Write-Host ""
            exit 0
        }
        'Escape' {
            Clear-Host
            Write-Host "`n  $(if ($dirty) { 'Cancelled - changes discarded.' } else { 'Cancelled.' })`n" -ForegroundColor Yellow
            exit 0
        }
        default {
            switch -regex ([string]$key.KeyChar) {
                '[aA]' { foreach ($d in $dirs) { if (-not $d.missing) { $d.enabled = $true;  foreach ($s in (Get-Visible $d)) { $s.enabled = $true;  Set-Pin $s $true } } }; $dirty = $true }
                '[nN]' { foreach ($d in $dirs) { if (-not $d.missing) { $d.enabled = $false; foreach ($s in (Get-Visible $d)) { $s.enabled = $false; Set-Pin $s $true } } }; $dirty = $true }
                '[uU]' {
                    # Hand back to the roll. The tick is recomputed by the next scan --
                    # press R to see it now.
                    switch ($row.Kind) {
                        'dir'     { foreach ($s in (Get-Visible $row.Dir)) { Set-Pin $s $false } }
                        'lane'    { foreach ($s in @($row.Lane.Group))     { Set-Pin $s $false } }
                        'session' { Set-Pin $row.Session $false }
                    }
                    $dirty = $true
                }
                '[wW]' {
                    # Flip worktree lanes and persist it. Turning them ON needs a
                    # rescan, because discovery skips them entirely while off.
                    try {
                        $null = Set-SRIncludeWorktrees -Value (-not $script:showWt)
                        $script:cfg    = Get-SRConfig
                        $script:showWt = [bool]$script:cfg.includeWorktrees
                        Invoke-Rescan
                        $rows = Build-Rows
                        $cursor = 0
                    } catch {
                        # Leave the picker usable if the config could not be written.
                        Write-SRLog ("worktree toggle failed: " + $_.Exception.Message)
                    }
                }
                '[lL]' {
                    # Ticks are not consulted. L means "open this now", whether or
                    # not it is part of the logon set -- that is the point of it.
                    $all = @(Get-RowSessions $row | ForEach-Object { [PSCustomObject]@{ S = $_; D = $row.Dir } })
                    $go  = @($all | Where-Object { $null -eq (Invoke-LaunchSession -Session $_.S -Dir $_.D -Preview) })

                    if (@($go).Count -eq 0) {
                        # Name the reason. "Already open" and "transcript missing"
                        # call for completely different reactions.
                        $why = $null
                        if (@($all).Count -eq 1) { $why = Invoke-LaunchSession -Session $all[0].S -Dir $all[0].D -Preview }
                        Set-Status $(if ($why) { "not launched - $why" } else { "nothing to launch here - all of it is open already" }) 'DarkYellow'
                    }
                    elseif (@($go).Count -eq 1) {
                        Invoke-LaunchMany -Items $go -What 'session'
                    }
                    else {
                        # A project row can stand for a dozen conversations, so
                        # anything beyond a single one is confirmed by count first.
                        $cap = [int]$cfg.maxSessions
                        if ($cap -gt 0 -and @($go).Count -gt $cap) { $go = @($go | Select-Object -First $cap) }
                        if (Read-YesNo ("Open {0} conversation(s) from {1} now - that is {0} new tab(s)." -f @($go).Count, (Split-Path (Get-RowPath $row) -Leaf))) {
                            Invoke-LaunchMany -Items $go -What 'sessions'
                        } else { Set-Status 'cancelled' 'DarkYellow' }
                    }
                }
                '[sS]' {
                    $path = Get-RowPath $row
                    Write-Host ""
                    Write-Host ("  New session in " + $path) -ForegroundColor Cyan
                    Write-Host "  Name it, or press ENTER for an automatic one: " -ForegroundColor Cyan -NoNewline
                    $nm  = Read-Host
                    $why = Invoke-SpawnNew -Dir $path -Name $nm
                    if ($why) { Set-Status "not spawned - $why" 'DarkYellow' }
                    else {
                        # It has no session id until claude writes one, so it cannot
                        # appear in the list until the next R.
                        Set-Status ("spawned a new session in " + (Split-Path $path -Leaf) + " - press R once it has settled to see it listed") 'Green'
                    }
                }
                '[xX]' {
                    if ($script:dirty) { Save-SRRegistry -Registry $script:reg; $script:dirty = $false }
                    $all = @()
                    foreach ($d in $dirs) {
                        if ($d.missing -or -not $d.enabled) { continue }
                        foreach ($s in (Get-Visible $d)) {
                            if (-not $s.enabled) { continue }
                            $all += [PSCustomObject]@{ S = $s; D = $d }
                        }
                    }
                    $all = @($all | Sort-Object { [datetime]$_.S.lastActive } -Descending)
                    $go  = @($all | Where-Object { $null -eq (Invoke-LaunchSession -Session $_.S -Dir $_.D -Preview) })

                    # Same cap as the logon restore, and said out loud rather than
                    # applied silently -- a truncated list reads exactly like a
                    # complete one.
                    $cap = [int]$cfg.maxSessions
                    $over = 0
                    if ($cap -gt 0 -and @($go).Count -gt $cap) { $over = @($go).Count - $cap; $go = @($go | Select-Object -First $cap) }

                    if (@($all).Count -eq 0) {
                        Set-Status 'nothing is ticked - SPACE ticks the row under the cursor' 'DarkYellow'
                    } elseif (@($go).Count -eq 0) {
                        Set-Status ("nothing to launch - all {0} ticked conversation(s) are open already" -f @($all).Count) 'DarkYellow'
                    } elseif (Read-YesNo ("Open the {0} ticked conversation(s) that are not open yet.{1}" -f @($go).Count, $(if ($over) { " $over more are over the cap of $cap and will be skipped." } else { '' }))) {
                        Invoke-LaunchMany -Items $go -What 'ticked session(s)'
                    } else { Set-Status 'cancelled' 'DarkYellow' }
                }
                '[qQ]' { Clear-Host; Write-Host "`n  Cancelled.`n" -ForegroundColor Yellow; exit 0 }
                '[rR]' { Invoke-Rescan; $rows = Build-Rows; Set-Status 'rescanned' 'DarkGray' }
            }
        }
    }
    if ($key.Key -notin @('UpArrow','DownArrow','Home','End')) { $rows = Build-Rows }
}
