#requires -Version 5.1
<#
.SYNOPSIS
    Choose which conversations reopen when you log in.

.DESCRIPTION
    Three levels. A PROJECT is a repository. Under it sit LANES -- `main` for the
    repo's own tree, and one lane per git worktree. Each conversation has its own
    tick, and the project has a master tick above them all.

    Untick the project and nothing in it reopens. Untick a lane's conversations to
    drop that lane. A worktree is a separate tree with its own git index, which is
    why it gets its own lane and its own budget rather than competing with main.

    A background task rescans hourly. Newly discovered conversations arrive ticked
    if they were active within sessionWindowDays -- at most autoTickPerDirectory
    from main and autoTickPerWorktree from each worktree.

    Keys:  UP/DOWN move   SPACE toggle+pin   U unpin   LEFT/RIGHT fold
           A all   N none   R rescan   ENTER save   ESC / Q cancel

.PARAMETER List
    Print the current selection and exit. Also the automatic fallback when there is
    no interactive console.

.PARAMETER Enable
.PARAMETER Disable
    Tick or untick without the picker. Matches a project path, a worktree name, or
    a conversation title/id, case-insensitively.

.EXAMPLE
    .\select-sessions.ps1
    .\select-sessions.ps1 -List
    .\select-sessions.ps1 -Disable bounded-contexts
#>
[CmdletBinding()]
param(
    [switch]$List,
    [string[]]$Enable,
    [string[]]$Disable,

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

function Get-Newest { param($Sessions)
    $s = @($Sessions)
    if (-not $s.Count) { return [datetime]'1970-01-01' }
    return [datetime](($s | Sort-Object { [datetime]$_.lastActive } -Descending)[0].lastActive)
}

# Sessions of a project that are currently in scope (worktrees may be switched off).
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

function Write-PlainList {
    Write-Host ""
    Write-Host "Claude session selection" -ForegroundColor Cyan
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
                Write-Host ("        {0}{1} {2,-32} {3,5}   {4}" -f $sp, $sm, $s.title, (Get-Age $s.lastActive), $s.sessionId.Substring(0,8)) -ForegroundColor $sc
            }
        }
    }
    Write-Summary
    Write-Host "  Change it with:  select-sessions.ps1                       (interactive picker)"
    Write-Host "                   select-sessions.ps1 -Disable bounded-contexts   (project, worktree, title or id)"
    Write-Host "  Or edit directly: $SR_RegistryPath"
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
    Write-Host ""
    Write-Host "  Claude session selection" -ForegroundColor Cyan -NoNewline
    Write-Host ("      {0} of {1} conversations, in {2} project(s), will reopen" -f $c.Sessions, $c.Total, $c.Projects) -ForegroundColor Gray
    if (-not $showWt) { Write-Host "  worktrees OFF" -ForegroundColor DarkYellow }
    Write-Host ""

    $height = 20
    try { $height = [Math]::Max(6, $Host.UI.RawUI.WindowSize.Height - 10) } catch { }
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
                $note = if ($d.missing) { '  MISSING' } else { '' }
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
                Write-Host ("  {0}        {1}{2} {3,-30} {4,5}{5}" -f $sel, $pin, $mark, $s.title, (Get-Age $s.lastActive), $note) -ForegroundColor $col
            }
        }
    }
    if ($last -lt $Rows.Count - 1) { Write-Host "      ..." -ForegroundColor DarkGray }

    Write-Host ""
    $cur = $Rows[$Cursor]
    $curPath = if ($cur.Kind -eq 'session' -and $cur.Session.cwd) { $cur.Session.cwd } else { $cur.Dir.path }
    Write-Host ("  " + $curPath) -ForegroundColor DarkGray
    Write-Host ""
    Write-Host "  UP/DOWN move  SPACE toggle+pin  U unpin  LEFT/RIGHT fold  A all  N none" -ForegroundColor DarkCyan
    Write-Host ("  W worktrees {0}  R rescan  ENTER save  ESC cancel" -f $(if ($showWt) { 'ON (press to hide) ' } else { 'OFF (press to show)' })) -ForegroundColor DarkCyan
    Write-Host "  * = pinned (the roll leaves it alone). Unpinned rows follow the newest few in their lane." -ForegroundColor DarkGray
}

function Invoke-Rescan {
    if ($script:dirty) { Save-SRRegistry -Registry $script:reg; $script:dirty = $false }
    $null = Update-SRRegistry -Config $script:cfg -Quiet
    $script:reg  = Get-SRRegistry
    $script:dirs = @($script:reg.directories | Sort-Object { Get-Newest (Get-Visible $_) } -Descending)
}

$rows = Build-Rows
while ($true) {
    if ($cursor -ge $rows.Count) { $cursor = [Math]::Max(0, $rows.Count - 1) }
    Render -Rows $rows -Cursor $cursor
    $key = [Console]::ReadKey($true)
    $row = $rows[$cursor]

    switch ($key.Key) {
        'UpArrow'    { if ($cursor -gt 0) { $cursor-- } }
        'DownArrow'  { if ($cursor -lt $rows.Count - 1) { $cursor++ } }
        'Home'       { $cursor = 0 }
        'End'        { $cursor = $rows.Count - 1 }
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
                '[qQ]' { Clear-Host; Write-Host "`n  Cancelled.`n" -ForegroundColor Yellow; exit 0 }
                '[rR]' { Invoke-Rescan; $rows = Build-Rows }
            }
        }
    }
    if ($key.Key -notin @('UpArrow','DownArrow','Home','End')) { $rows = Build-Rows }
}
