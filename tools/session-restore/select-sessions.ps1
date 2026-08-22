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

    Keys:  UP/DOWN move   PGUP/PGDN page   HOME/END ends
           / or F find    SPACE tick+pin   U unpin   LEFT/RIGHT fold   A all  N none
           L launch now   S spawn new      X launch everything ticked
           W worktrees    R rescan         ENTER save   ESC / Q cancel

    The panel repaints IN PLACE rather than clearing: a clear per keystroke pushes
    the old frame into Windows Terminal's scrollback, so every arrow key read as the
    whole list jumping and reloading. The frame is built as lines, its height is
    derived from the chrome actually built rather than a constant, and the viewport
    is sticky -- the marker moves down the list, the list does not move under it.

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
$script:visCache = @{}
function Get-Visible { param($Dir)
    # Memoised. Render, Get-Counts and Build-Rows each walk every project, so an
    # uncached filter ran thousands of pipeline operations per KEYSTROKE -- part of
    # why an arrow key felt like the list reloading. Only R and W change what is
    # visible, and both clear this.
    $hit = $script:visCache[[string]$Dir.path]
    if ($null -ne $hit) { return $hit }
    $v = if ($showWt) { @($Dir.sessions) } else { @(@($Dir.sessions) | Where-Object { $_.lane -ne 'worktree' }) }
    $script:visCache[[string]$Dir.path] = $v
    return $v
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
$script:running      = @{}
$script:live         = @{}
$script:launching    = @{}
# Set by '/'. Narrows the list to matching conversations, carrying their project
# and lane rows along so the tree still reads as a tree.
$script:filter       = $null
# How many running claude.exe we could not attribute to any conversation.
$script:unattributed = 0
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
    $script:running      = Get-SRRunningIds -Refresh
    $script:unattributed = Get-SRUnattributedCount
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
    # GONE outranks everything: there is nothing to launch, so nothing else about
    # this row matters.
    if ($Session.gone)          { return 'gone' }
    if ($script:running[$id])   { return 'run' }
    if (Test-JustLaunched $id)  { return 'new' }
    if ($script:live[$id])      { return 'act' }
    return ''
}

# The optimistic mark expires on the CLOCK, not on the next rescan. R is also how
# you ask "what is open?", and clearing the mark there used to hand back a row that
# claude had not yet surfaced in Win32_Process -- reading as idle, inviting a second
# tab for the session you launched four seconds ago.
function Test-JustLaunched { param([string]$Id)
    $t = $script:launching[$Id]
    if (-not $t) { return $false }
    if (((Get-Date) - [datetime]$t).TotalSeconds -gt $SR_LaunchGraceSeconds) {
        $script:launching.Remove($Id)
        return $false
    }
    return $true
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
    if (Test-JustLaunched $id)  { return "already launched a moment ago" }
    if ($script:live[$id])      { return "already live - its transcript was written < $SR_LiveWindowMinutes min ago" }
    if ($Preview) { return $null }

    $boot = New-SRBootScript -Dir $cwd -SessionId $Session.sessionId -Title $title
    Start-SRSession -Dir $cwd -BootScript $boot -Title $title
    $script:launching[$id] = (Get-Date)
    Write-SRLog ("  [ok]   panel launch  {0}  {1}  {2}" -f $title, $Session.sessionId, $cwd)
    return $null
}

# Conversations that look live in a given working directory. This is what stops S
# from opening a second session onto a tree somebody is already working -- the same
# refusal spawn-claude-session makes, which exists because it happened: a session was
# spawned onto a lane a live one had held for 73 minutes.
function Get-LiveInDirectory {
    param([Parameter(Mandatory)][string]$Dir)
    $out = @()
    foreach ($d in @($script:dirs)) {
        foreach ($s in @($d.sessions)) {
            $cwd = if ($s.cwd) { $s.cwd } else { $d.path }
            if ($cwd -and ($cwd.TrimEnd('') -ieq $Dir.TrimEnd('')) -and ((Get-SessionState $s) -in @('run','act','new'))) {
                $out += $s
            }
        }
    }
    return ,@($out)
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

    $ok = 0; $no = 0; $launchedIds = @()
    foreach ($h in $hits) {
        $who = "{0}/{1} / `"{2}`"" -f (Split-Path $h.D.path -Leaf), (Get-LaneName $h.S), (Get-SessionTitle $h.S $h.D)
        $why = Invoke-LaunchSession -Session $h.S -Dir $h.D -Preview:$DryRun
        if ($why) { Write-SRSkip "$who - $why"; $no++ }
        else {
            Write-SROk $who
            $ok++
            if (-not $DryRun) { $launchedIds += $h.S.sessionId }
            # Breathing room so Windows Terminal does not race itself, same as the
            # logon restore.
            if (-not $DryRun) { Start-Sleep -Milliseconds 500 }
        }
    }

    # A launch reports only that wt.exe started; the tab's child is what fails.
    $never = @()
    if (-not $DryRun -and $launchedIds.Count) {
        Write-Host ""
        Write-Host ("  Verifying {0} session(s) came up..." -f $launchedIds.Count) -NoNewline -ForegroundColor DarkGray
        $never = Wait-SRSessionsUp -SessionIds $launchedIds
        Write-Host " done" -ForegroundColor DarkGray
        foreach ($id in $never) {
            Write-SRFail ("no claude.exe ever appeared for {0} - the tab opened and died. Read {1}" -f $id.Substring(0,8), $SR_LogPath)
        }
    }

    Write-Host ""
    Write-Host ("  {0} {1}   verified {2}   skipped {3}" -f $(if ($DryRun) { 'would launch' } else { 'launched' }), $ok, ($ok - @($never).Count), $no)
    Write-Host ""
    if ($ok -eq 0 -or @($never).Count) { exit 1 }
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
                $sl = switch (Get-SessionState $s) { 'run' { 'LIVE' } 'act' { 'live' } 'gone' { 'GONE' } default { '    ' } }
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

# A conversation matches the filter on its title, its id, its lane or its project.
# Same fields -Launch matches on, so what you can find you can also launch by name.
function Test-RowMatch { param($Session, $Dir, $Lane)
    if (-not $script:filter) { return $true }
    $f = $script:filter
    foreach ($hay in @($Session.title, $Session.sessionId, $Lane, (Split-Path $Dir.path -Leaf), $Dir.path)) {
        if ("$hay" -like "*$f*") { return $true }
    }
    return $false
}

function Build-Rows {
    $rows = @()
    $filtering = [bool]$script:filter
    foreach ($d in $dirs) {
        # While filtering, build the project's rows first and keep the project only
        # if something under it survived -- an empty repo header is just noise.
        $sub = @()
        foreach ($lane in (Get-Lanes $d)) {
            $lkey  = "$($d.path)|$($lane.Name)"
            $kids  = @()
            foreach ($s in (@($lane.Group) | Sort-Object { [datetime]$_.lastActive } -Descending)) {
                if (-not (Test-RowMatch -Session $s -Dir $d -Lane $lane.Name)) { continue }
                $kids += [PSCustomObject]@{ Kind = 'session'; Dir = $d; Lane = $lane; Key = $lkey; Session = $s }
            }
            if ($filtering -and -not $kids.Count) { continue }
            $sub += [PSCustomObject]@{ Kind = 'lane'; Dir = $d; Lane = $lane; Key = $lkey; Session = $null }
            # A fold is the operator's choice about a full list; while filtering it
            # would hide the very rows they searched for, so it is ignored.
            if (-not $filtering -and $collapsed[$lkey]) { continue }
            $sub += $kids
        }
        if ($filtering -and -not $sub.Count) { continue }
        $rows += [PSCustomObject]@{ Kind = 'dir'; Dir = $d; Lane = $null; Key = $d.path; Session = $null }
        if (-not $filtering -and $collapsed[$d.path]) { continue }
        $rows += $sub
    }
    return ,@($rows)
}

# --- painting ---------------------------------------------------------------
# This panel used to Clear-Host on every keystroke. In Windows Terminal a clear
# pushes the old frame up into scrollback instead of repainting in place, so every
# arrow key looked like the whole list jumped and then reloaded -- and because the
# chrome around the list was measured by a hardcoded constant that under-counted it
# by two to four lines, the frame really was taller than the window and really did
# scroll. Both are fixed here: the frame is BUILT as lines, its height is DERIVED
# from the lines actually built, and it is stamped over the previous frame from row
# 0 with every line padded to the window width so nothing shows through. A real
# clear now happens only when something foreign wrote below the panel (a prompt, a
# launch log) or the window was resized -- detected, not guessed.
$script:paintedLines = 0
$script:frameEndRow  = -1
$script:frameSize    = ''
# Rows that fit on screen, set by the frame builder and read by PGUP/PGDN. A sane
# value before the first frame, because a key can arrive before one is drawn.
$script:pageSize     = 10
# Top row of the visible window into $rows. Sticky: it moves only when the cursor
# would leave the window, so DOWN moves the marker and not the list.
$script:first        = 0

function Hide-Caret { try { [Console]::CursorVisible = $false } catch { } }
function Show-Caret { try { [Console]::CursorVisible = $true  } catch { } }

# A line is an array of segments so LIVE can keep its own colour inside a row that
# is otherwise written as one piece.
function New-Seg { param([string]$T, [string]$C = 'Gray') return [PSCustomObject]@{ T = $T; C = $C } }
$script:blankLine = @((New-Seg '' 'Gray'))

function Get-WinSize {
    $w = 120; $h = 30
    try { $s = $Host.UI.RawUI.WindowSize; $w = $s.Width; $h = $s.Height } catch { }
    # Floored only against nonsense. Reporting a window BIGGER than it is would put
    # lines past the bottom edge and scroll it -- the exact failure being fixed --
    # so a genuinely tiny window is told the truth and gets a truncated frame.
    return [PSCustomObject]@{ W = [Math]::Max(24, [int]$w); H = [Math]::Max(4, [int]$h) }
}

function Paint {
    param([object[]]$Lines)
    $sz = Get-WinSize
    # One column short of the edge: filling the last cell wraps the line and costs a
    # row, which is how a frame that fits becomes a frame that scrolls.
    $w  = $sz.W - 1

    # If the cursor is not where the last frame left it, something printed under the
    # panel. If the window changed shape, the old frame is the wrong size. Either
    # way a stamp-over would leave debris, so clear once and repaint clean.
    $moved = $true
    try { $moved = ([Console]::CursorTop -ne $script:frameEndRow) } catch { }
    if ($moved -or $script:frameSize -ne ("{0}x{1}" -f $sz.W, $sz.H)) {
        Clear-Host
        $script:paintedLines = 0
    }
    $script:frameSize = "{0}x{1}" -f $sz.W, $sz.H

    Hide-Caret
    try { [Console]::SetCursorPosition(0, 0) } catch { Clear-Host }

    $n = [Math]::Min($Lines.Count, $sz.H - 1)
    for ($i = 0; $i -lt $n; $i++) {
        $used = 0
        foreach ($seg in $Lines[$i]) {
            if ($used -ge $w) { break }
            $t = [string]$seg.T
            if ($used + $t.Length -gt $w) { $t = $t.Substring(0, $w - $used) }
            if ($t.Length -gt 0) { Write-Host $t -ForegroundColor $seg.C -NoNewline; $used += $t.Length }
        }
        # The padding IS the erase. Without it the tail of a longer previous line
        # survives underneath the new one.
        if ($used -lt $w) { Write-Host (' ' * ($w - $used)) -NoNewline }
        Write-Host ''
    }
    # A frame that shrank would otherwise leave the bottom of the taller one behind.
    for ($i = $n; $i -lt $script:paintedLines; $i++) { Write-Host (' ' * $w) }
    if ($script:paintedLines -gt $n) { try { [Console]::SetCursorPosition(0, $n) } catch { } }
    $script:paintedLines = $n
    try { $script:frameEndRow = [Console]::CursorTop } catch { $script:frameEndRow = -1 }
}

# Builds the whole frame, chrome included, and returns it as lines. Nothing here
# writes to the console -- which is what lets the height be measured before a single
# character is printed.
function Build-Frame {
    param($Rows, $Cursor)
    $sz    = Get-WinSize
    $total = @($Rows).Count
    $lines = New-Object System.Collections.Generic.List[object]
    $foot  = New-Object System.Collections.Generic.List[object]

    # --- header ---
    $c = Get-Counts
    $liveTotal = 0
    foreach ($d in $dirs) {
        foreach ($s in @(Get-Visible $d)) {
            if ((Get-SessionState $s) -in @('run','act','new')) { $liveTotal++ }
        }
    }

    $lines.Add($script:blankLine)
    $title = @(
        (New-Seg '  Claude sessions' 'Cyan'),
        (New-Seg ("   {0} live now" -f $liveTotal) 'Cyan'),
        (New-Seg ("   |   {0} of {1} ticked to reopen at logon, in {2} project(s)" -f $c.Sessions, $c.Total, $c.Projects) 'Gray')
    )
    # The find key on the title line, not buried eighth on a hint line below the
    # fold. With this many conversations it is the key that makes the list usable.
    if (-not $script:filter) { $title += (New-Seg '    [ press / to find ]' 'Yellow') }
    $lines.Add($title)

    if ($script:unattributed -gt 0) {
        # Honest about the blind spot rather than implying LIVE is complete.
        $lines.Add(@((New-Seg ("  {0} running claude.exe cannot be matched to a conversation (started bare, no id on the command line)" -f $script:unattributed) 'DarkYellow')))
    }
    if (-not $showWt) { $lines.Add(@((New-Seg '  worktrees OFF' 'DarkYellow'))) }
    if ($script:filter) {
        $lines.Add(@((New-Seg ("  FILTER '{0}' - showing {1} matching conversation(s).  / or F to change it, ESC to clear it." -f $script:filter, @($Rows | Where-Object { $_.Kind -eq 'session' }).Count) 'Yellow')))
    }
    $lines.Add($script:blankLine)
    $headCount = $lines.Count

    # --- footer, built now so the list height can be derived from it ---
    # The status line keeps its slot whether or not there is a status: a footer that
    # grows and shrinks shifts the whole list by a row as you work.
    #
    # D is how droppable the line is, 0 = never. A short window cannot hold both a
    # list and every line of chrome, and the way that used to resolve itself was the
    # frame overrunning the window and the terminal scrolling the whole thing --
    # exactly the "it jumped and reloaded" symptom. So shed reference text instead,
    # worst first. Measured: at 14 rows the full chrome is 18 lines.
    $cur = if ($Cursor -ge 0 -and $Cursor -lt $total) { $Rows[$Cursor] } else { $null }
    $pathLine = if ($null -eq $cur) {
        @((New-Seg '  nothing matches - / to change the filter, ESC to clear it' 'Yellow'))
    } else {
        $curPath = if ($cur.Kind -eq 'session' -and $cur.Session.cwd) { $cur.Session.cwd } else { $cur.Dir.path }
        @((New-Seg ('  ' + $curPath) 'DarkGray'))
    }
    $statusLine = if ($script:status) { @((New-Seg ('  ' + $script:status) $script:statusCol)) } else { $script:blankLine }

    $footSpec = @(
        [PSCustomObject]@{ D = 3; L = $script:blankLine }
        [PSCustomObject]@{ D = 0; L = $pathLine }
        [PSCustomObject]@{ D = 3; L = $script:blankLine }
        [PSCustomObject]@{ D = 2; L = $statusLine }
        [PSCustomObject]@{ D = 0; L = @((New-Seg '  L launch NOW   S spawn new session here   X launch everything ticked   / find   R rescan' 'Cyan')) }
        [PSCustomObject]@{ D = 1; L = @((New-Seg '  UP/DOWN move   PGUP/PGDN page   HOME/END ends   SPACE tick+pin   U unpin   LEFT/RIGHT fold   A all   N none' 'DarkCyan')) }
        [PSCustomObject]@{ D = 1; L = @((New-Seg ("  W worktrees {0}   ENTER save   ESC quit" -f $(if ($showWt) { 'ON (press to hide) ' } else { 'OFF (press to show)' })) 'DarkCyan')) }
        # The one distinction this screen lives or dies on, plus how far to trust LIVE.
        [PSCustomObject]@{ D = 4; L = @((New-Seg '  [x] = reopens at LOGON.  L = open it NOW regardless.  * = pinned, the roll leaves it alone.' 'DarkGray')) }
        [PSCustomObject]@{ D = 4; L = @((New-Seg '  LIVE = a claude.exe holds it.  live = its transcript just moved.  blank = no evidence, not proof.  GONE = transcript deleted.' 'DarkGray')) }
    )

    # --- how many rows actually fit ---
    # Measured, never assumed. The old constant of 14 under-counted a chrome that
    # reaches 18 once the filter line and the unattributed warning are both up, so
    # the frame was taller than the window and the window scrolled. +2 is the pair
    # of "..." markers, which get a reserved slot each so the list does not shift by
    # a row the moment one appears; -1 keeps the last written line off the final row.
    $minBody = 3
    $budget  = $sz.H - $headCount - 2 - 1
    $cut = 5
    while ($cut -gt 1) {
        if (($budget - @($footSpec | Where-Object { $_.D -lt $cut }).Count) -ge $minBody) { break }
        $cut--
    }
    foreach ($f in @($footSpec | Where-Object { $_.D -lt $cut })) { $foot.Add($f.L) }
    $height = [Math]::Max(1, $budget - $foot.Count)
    # Backstop. A window short enough that even the shed footer does not fit gets
    # its footer trimmed from the bottom until the frame genuinely does. Paint caps
    # at the window height regardless, so nothing can scroll either way -- but a
    # frame that has to be truncated to fit is a frame with lines it never showed.
    while ((($headCount + 2 + $height + $foot.Count) -gt ($sz.H - 1)) -and $foot.Count -gt 0) {
        $foot.RemoveAt($foot.Count - 1)
    }
    # PGUP/PGDN move by exactly what is on screen, so a page turns over rather than
    # jumping some fixed number of rows that has nothing to do with the window.
    $script:pageSize = $height

    # --- sticky viewport ---
    # This used to recentre on the cursor every keystroke, which is why the list
    # slid under you instead of the marker moving down it.
    if ($total -le $height) {
        $script:first = 0
    } else {
        $m = 2
        if ($Cursor -lt $script:first + $m)               { $script:first = $Cursor - $m }
        if ($Cursor -gt $script:first + $height - 1 - $m) { $script:first = $Cursor - $height + 1 + $m }
        $script:first = [Math]::Max(0, [Math]::Min($script:first, $total - $height))
    }
    $first = $script:first
    $last  = [Math]::Min($total - 1, $first + $height - 1)

    if ($first -gt 0) { $lines.Add(@((New-Seg ("      ... {0} more above" -f $first) 'DarkGray'))) }
    else              { $lines.Add($script:blankLine) }

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
                $live = @(@($v) | Where-Object { (Get-SessionState $_) -in @('run','act','new') }).Count
                $note = if ($d.missing) { '  MISSING' } elseif ($live -gt 0) { "  $live live" } else { '' }
                $col  = if ($i -eq $Cursor) { 'White' } elseif ($d.missing) { 'DarkGray' } elseif ($d.enabled) { 'Cyan' } else { 'Gray' }
                $lines.Add(@((New-Seg ("  {0} {1} {2} {3,-26} {4,2}/{5,-3}{6}" -f $sel, $mark, $fold, (Split-Path $d.path -Leaf), $n, $v.Count, $note) $col)))
            }
            'lane' {
                $ln   = @(@($r.Lane.Group) | Where-Object { $_.enabled }).Count
                $fold = if ($collapsed[$r.Key]) { '+' } else { '-' }
                $tag  = if ($r.Lane.Name -eq 'main') { 'main' } else { 'worktree: ' + $r.Lane.Name }
                $warn = if ($r.Dir.enabled -and $ln -ge 2) { "  $ln in one tree" } else { '' }
                $col  = if ($i -eq $Cursor) { 'White' } elseif ($r.Lane.Name -eq 'main') { 'DarkCyan' } else { 'Magenta' }
                $lines.Add(@((New-Seg ("  {0}     {1} {2,-30} {3,2}/{4,-3}{5}" -f $sel, $fold, $tag, $ln, @($r.Lane.Group).Count, $warn) $col)))
            }
            'session' {
                $d = $r.Dir; $s = $r.Session
                $mark = if ($s.enabled) { '[x]' } else { '[ ]' }
                $pin  = if (Test-Pinned $s) { '*' } else { ' ' }
                $note = ''
                if ($d.enabled -and $s.enabled -and (Test-Stale $s.lastActive)) { $note = '  STALE' }
                if (-not $d.enabled) { $note = '  (project off)' }
                $col = if ($i -eq $Cursor) { 'White' } elseif (-not $d.enabled) { 'DarkGray' } elseif (-not $s.enabled) { 'Gray' } elseif (Test-Stale $s.lastActive) { 'DarkYellow' } else { 'Green' }
                # Three segments so LIVE keeps its own colour: the tick tells you what
                # reopens at logon, the mark tells you what is open NOW, and they must
                # not be readable as one thing.
                # Upper case = certain, lower case = inferred. Deliberately not the
                # same word twice: one is a process holding the id, the other is a
                # file that moved recently.
                $stateSeg = switch (Get-SessionState $s) {
                    'run'   { New-Seg 'LIVE' 'Cyan' }
                    'act'   { New-Seg 'live' 'DarkCyan' }
                    'new'   { New-Seg '..  ' 'DarkCyan' }
                    'gone'  { New-Seg 'GONE' 'Red' }
                    default { New-Seg '    ' 'Gray' }
                }
                $lines.Add(@(
                    (New-Seg ("  {0}        {1}{2} {3,-30} {4,5}  " -f $sel, $pin, $mark, $s.title, (Get-Age $s.lastActive)) $col),
                    $stateSeg,
                    (New-Seg $note $col)
                ))
            }
        }
    }
    # Pad the list region to its full height so the footer sits in the same place
    # whether the filter matched ninety rows or none.
    for ($i = ($last - $first + 1); $i -lt $height; $i++) { $lines.Add($script:blankLine) }

    $below = $total - 1 - $last
    if ($below -gt 0) { $lines.Add(@((New-Seg ("      ... {0} more below" -f $below) 'DarkGray'))) }
    else              { $lines.Add($script:blankLine) }

    foreach ($f in $foot) { $lines.Add($f) }
    # Comma-protected: a List returned bare is unrolled by the output stream, and a
    # blank line would be unrolled a second time and VANISH, shifting the frame.
    return ,($lines.ToArray())
}

function Render {
    param($Rows, $Cursor)
    # Assigned, then passed. See the ",@()" note in _common.ps1.
    $frame = Build-Frame -Rows $Rows -Cursor $Cursor
    Paint -Lines $frame
}

function Invoke-Rescan {
    if ($script:dirty) { Save-SRRegistry -Registry $script:reg; $script:dirty = $false }
    $null = Update-SRRegistry -Config $script:cfg -Quiet
    $script:reg  = Get-SRRegistry
    # Before the sort, not after: the cache holds the OLD session objects, and
    # sorting on them would order the new list by the previous scan's timestamps.
    $script:visCache = @{}
    $script:dirs = @($script:reg.directories | Sort-Object { Get-Newest (Get-Visible $_) } -Descending)
    # R is also how you ask "what is actually open?" -- and it is the only thing
    # that clears the optimistic '..' marks, once the real processes have appeared.
    Update-Running
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
# The caret is hidden for the whole run so it does not flicker around the frame as
# it repaints. Ctrl+C would otherwise leave it invisible in a console the launching
# .bat then pauses in, so put it back on the way out however we leave.
try {
while ($true) {
    if ($cursor -ge $rows.Count) { $cursor = [Math]::Max(0, $rows.Count - 1) }
    Render -Rows $rows -Cursor $cursor
    $key = [Console]::ReadKey($true)
    $row = $rows[$cursor]
    # A filter that matches nothing leaves NO rows, so there is no row under the
    # cursor. Everything that acts on one has to bow out here -- without this, S
    # reached Invoke-SpawnNew with a $null -Dir and took the whole panel down on a
    # mandatory-parameter throw.
    if ($null -eq $row -and ("$($key.KeyChar)" -match '[lLsSuU]' -or $key.Key -in @('Spacebar','LeftArrow','RightArrow'))) {
        Set-Status 'no row here - / to change the filter, ESC to clear it' 'DarkYellow'
        continue
    }

    switch ($key.Key) {
        # Moving clears the last result line: a "launched 1" left hanging over a
        # different row reads as if THAT row was launched.
        'UpArrow'    { if ($cursor -gt 0) { $cursor-- }; $script:status = $null }
        'DownArrow'  { if ($cursor -lt $rows.Count - 1) { $cursor++ }; $script:status = $null }
        'Home'       { $cursor = 0; $script:status = $null }
        'End'        { $cursor = $rows.Count - 1; $script:status = $null }
        'PageUp'     { $cursor = [Math]::Max(0, $cursor - $script:pageSize); $script:status = $null }
        'PageDown'   { $cursor = [Math]::Min($rows.Count - 1, $cursor + $script:pageSize); $script:status = $null }
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
            Show-Caret
            Clear-Host
            Write-Host ""
            Write-Host $(if ($dirty) { "  Saved." } else { "  No changes." }) -ForegroundColor Green
            Write-Summary
            Write-Host "  Registry: $SR_RegistryPath"
            Write-Host ""
            exit 0
        }
        'Escape' {
            # A filter is a view, not a change. ESC backs out of the view first --
            # quitting the panel on the same key that narrows it would throw away
            # unsaved ticks for what reads like "undo the search".
            if ($script:filter) {
                $script:filter = $null
                $rows = Build-Rows
                $cursor = 0
                Set-Status 'filter cleared' 'DarkGray'
                continue
            }
            Show-Caret
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
                    # Assigned first, then piped. Piping the call DIRECTLY hands
                    # ForEach-Object the whole array as one item -- see the
                    # ",@()" note in _common.ps1. Measured: on a project row this
                    # produced ONE entry whose .S was every session at once.
                    $rowSessions = Get-RowSessions $row
                    $all = @($rowSessions | ForEach-Object { [PSCustomObject]@{ S = $_; D = $row.Dir } })
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
                    # Two sessions in one working tree share a git index, and a
                    # second one on a lane somebody is working is the failure
                    # spawn-claude-session refuses outright. Warn and let the
                    # operator override -- an override is a visible act.
                    $busy = Get-LiveInDirectory $path
                    if (@($busy).Count) {
                        Write-Host ("  ALREADY LIVE HERE: {0}" -f ((@($busy) | ForEach-Object { '"' + $_.title + '"' }) -join ', ')) -ForegroundColor Red
                        Write-Host "  They share this tree's git index - commit with:  git commit -m msg -- <paths>" -ForegroundColor DarkYellow
                        if (-not (Read-YesNo "Spawn a second session here anyway?")) {
                            Set-Status 'not spawned - a session is already live in that directory' 'DarkYellow'
                            break
                        }
                    }
                    Write-Host "  Name it, or press ENTER for an automatic one: " -ForegroundColor Cyan -NoNewline
                    Show-Caret
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
                # F as well as '/'. The slash is the convention, but it is not a key
                # anyone finds by looking at the screen, and with this many rows the
                # find is the difference between a usable list and a scroll.
                '[/fF]' {
                    Write-Host ""
                    Write-Host ("  Find (title, id, worktree or project){0}: " -f $(if ($script:filter) { " - now '$($script:filter)', ENTER clears" } else { ', ENTER cancels' })) -ForegroundColor Cyan -NoNewline
                    Show-Caret
                    $f = Read-Host
                    $script:filter = if ([string]::IsNullOrWhiteSpace($f)) { $null } else { $f.Trim() }
                    $rows = Build-Rows
                    $cursor = 0
                    if ($script:filter) {
                        $n = @($rows | Where-Object { $_.Kind -eq 'session' }).Count
                        # Say when nothing matched, rather than showing a blank tree
                        # that reads as though everything vanished.
                        Set-Status $(if ($n) { "$n conversation(s) match '$($script:filter)'" } else { "nothing matches '$($script:filter)' - / again to change it" }) $(if ($n) { 'Green' } else { 'DarkYellow' })
                    } else { Set-Status 'filter cleared' 'DarkGray' }
                }
                '[qQ]' { Show-Caret; Clear-Host; Write-Host "`n  Cancelled.`n" -ForegroundColor Yellow; exit 0 }
                '[rR]' { Invoke-Rescan; $rows = Build-Rows; Set-Status 'rescanned' 'DarkGray' }
            }
        }
    }
    if ($key.Key -notin @('UpArrow','DownArrow','Home','End','PageUp','PageDown')) { $rows = Build-Rows }
}
} finally { Show-Caret }
