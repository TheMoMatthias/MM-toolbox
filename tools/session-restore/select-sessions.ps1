#requires -Version 5.1
<#
.SYNOPSIS
    Choose which conversations reopen when you log in.

.DESCRIPTION
    Two levels. A PROJECT has a master tick; each CONVERSATION under it has its own.
    Untick a project and nothing in it reopens, however its conversations are set.
    Untick one conversation to drop just that slice.

    A background task rescans hourly, so work you start today appears here on its
    own. A newly discovered conversation arrives ticked if it was active within
    sessionWindowDays, and at most autoTickPerDirectory of them per project -- so a
    repo with sixteen live conversations does not open sixteen tabs.

    Keys:  UP/DOWN move   SPACE toggle   A all   N none   R rescan
           LEFT collapse / RIGHT expand a project
           ENTER save and exit          ESC / Q cancel

.PARAMETER List
    Print the current selection and exit. Also the automatic fallback when there is
    no interactive console.

.PARAMETER Enable
.PARAMETER Disable
    Tick or untick without the picker. Matches a project path OR a conversation
    title/id, case-insensitively.

.EXAMPLE
    .\select-sessions.ps1
    .\select-sessions.ps1 -List
    .\select-sessions.ps1 -Disable E2b-python-312-move
#>
[CmdletBinding()]
param(
    [switch]$List,
    [string[]]$Enable,
    [string[]]$Disable,
    [switch]$NoScan
)

$ErrorActionPreference = 'Stop'

$here = $PSScriptRoot
if (-not $here -and $MyInvocation.MyCommand.Path) { $here = Split-Path -Parent $MyInvocation.MyCommand.Path }
if (-not $here) { $here = (Get-Location).Path }
. (Join-Path $here '_common.ps1')

$cfg = Get-SRConfig
if (-not $NoScan) {
    try { $null = Update-SRRegistry -Config $cfg -Quiet } catch { Write-Warning "scan failed: $($_.Exception.Message)" }
}
$reg  = Get-SRRegistry
$dirs = @($reg.directories | Sort-Object { if (@($_.sessions).Count) { [datetime](@($_.sessions) | Sort-Object { [datetime]$_.lastActive } -Descending)[0].lastActive } else { [datetime]'1970-01-01' } } -Descending)

if ($dirs.Count -eq 0) {
    Write-Host "`n  No projects discovered yet. Run claude in a project once, then re-run this.`n" -ForegroundColor Yellow
    exit 1
}

$staleDays = [double]$cfg.recencyDays

function Get-Age { param($Iso)
    $d = ((Get-Date) - [datetime]$Iso)
    if ($d.TotalDays -ge 1) { return ("{0}d" -f [int]$d.TotalDays) }
    return ("{0}h" -f [int]$d.TotalHours)
}
function Test-Stale { param($Iso) return (((Get-Date) - [datetime]$Iso).TotalDays -gt $staleDays) }

function Get-Counts {
    $on = 0; $tot = 0; $projOn = 0
    foreach ($d in $dirs) {
        if ($d.missing) { continue }
        $s = @($d.sessions)
        $tot += $s.Count
        if ($d.enabled) { $projOn++; $on += @($s | Where-Object { $_.enabled }).Count }
    }
    return [PSCustomObject]@{ Sessions = $on; Total = $tot; Projects = $projOn }
}

function Write-Summary {
    $c = Get-Counts
    Write-Host ""
    Write-Host ("  {0} conversation(s) across {1} project(s) will reopen at logon, out of {2} known." -f $c.Sessions, $c.Projects, $c.Total)
    # Two conversations in one working tree share a git index.
    foreach ($d in $dirs) {
        if ($d.missing -or -not $d.enabled) { continue }
        $n = @(@($d.sessions) | Where-Object { $_.enabled }).Count
        if ($n -ge 2) {
            Write-Host ("     {0}: {1} conversations in ONE working tree - commit with ``git commit -m msg -- <paths>``" -f (Split-Path $d.path -Leaf), $n) -ForegroundColor Yellow
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
                    if ($d.enabled -ne $pair.v) { $d.enabled = $pair.v; $changed++
                        Write-Host ("  project  {0}  {1}" -f $(if($pair.v){'ticked  '}else{'unticked'}), $d.path) -ForegroundColor $(if($pair.v){'Green'}else{'DarkYellow'}) }
                }
                foreach ($s in @($d.sessions)) {
                    if (("$($s.title)" -like "*$pat*") -or ("$($s.sessionId)" -like "*$pat*")) {
                        if ($s.enabled -ne $pair.v) { $s.enabled = $pair.v; $changed++
                            Write-Host ("  session  {0}  {1}  ({2})" -f $(if($pair.v){'ticked  '}else{'unticked'}), $s.title, (Split-Path $d.path -Leaf)) -ForegroundColor $(if($pair.v){'Green'}else{'DarkYellow'}) }
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
        $mark = if ($d.missing) { '[?]' } elseif ($d.enabled) { '[x]' } else { '[ ]' }
        $col  = if ($d.missing) { 'DarkGray' } elseif ($d.enabled) { 'Cyan' } else { 'Gray' }
        $n    = @(@($d.sessions) | Where-Object { $_.enabled }).Count
        Write-Host ("  {0} {1,-26} {2,2}/{3,-2} ticked   {4}" -f $mark, (Split-Path $d.path -Leaf), $n, @($d.sessions).Count, $d.path) -ForegroundColor $col
        foreach ($s in @($d.sessions | Sort-Object { [datetime]$_.lastActive } -Descending)) {
            $sm = if ($s.enabled) { '[x]' } else { '[ ]' }
            $sc = if (-not $d.enabled) { 'DarkGray' } elseif (-not $s.enabled) { 'Gray' } elseif (Test-Stale $s.lastActive) { 'DarkYellow' } else { 'Green' }
            Write-Host ("        {0} {1,-34} {2,5}   {3}" -f $sm, $s.title, (Get-Age $s.lastActive), $s.sessionId.Substring(0,8)) -ForegroundColor $sc
        }
    }
    Write-Summary
    Write-Host "  Change it with:  select-sessions.ps1                       (interactive picker)"
    Write-Host "                   select-sessions.ps1 -Disable E2b-python   (by title, id or path)"
    Write-Host "  Or edit directly: $SR_RegistryPath"
    Write-Host ""
}

if ($List) { Write-PlainList; exit 0 }

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
        $rows += [PSCustomObject]@{ Kind = 'dir'; Dir = $d; Session = $null }
        if (-not $collapsed[$d.path]) {
            foreach ($s in @($d.sessions | Sort-Object { [datetime]$_.lastActive } -Descending)) {
                $rows += [PSCustomObject]@{ Kind = 'session'; Dir = $d; Session = $s }
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

        if ($r.Kind -eq 'dir') {
            $d    = $r.Dir
            $mark = if ($d.missing) { '[?]' } elseif ($d.enabled) { '[x]' } else { '[ ]' }
            $n    = @(@($d.sessions) | Where-Object { $_.enabled }).Count
            $fold = if ($collapsed[$d.path]) { '+' } else { '-' }
            $note = if ($d.missing) { '  MISSING' } elseif ($d.enabled -and $n -ge 2) { "  $n in one tree" } else { '' }
            $col  = if ($i -eq $Cursor) { 'White' } elseif ($d.missing) { 'DarkGray' } elseif ($d.enabled) { 'Cyan' } else { 'Gray' }
            Write-Host ("  {0} {1} {2} {3,-26} {4,2}/{5,-2}{6}" -f $sel, $mark, $fold, (Split-Path $d.path -Leaf), $n, @($d.sessions).Count, $note) -ForegroundColor $col
        } else {
            $d = $r.Dir; $s = $r.Session
            $mark = if ($s.enabled) { '[x]' } else { '[ ]' }
            $note = ''
            if ($d.enabled -and $s.enabled -and (Test-Stale $s.lastActive)) { $note = '  STALE' }
            if (-not $d.enabled) { $note = '  (project off)' }
            $col = if ($i -eq $Cursor) { 'White' } elseif (-not $d.enabled) { 'DarkGray' } elseif (-not $s.enabled) { 'Gray' } elseif (Test-Stale $s.lastActive) { 'DarkYellow' } else { 'Green' }
            Write-Host ("  {0}       {1} {2,-34} {3,5}{4}" -f $sel, $mark, $s.title, (Get-Age $s.lastActive), $note) -ForegroundColor $col
        }
    }
    if ($last -lt $Rows.Count - 1) { Write-Host "      ..." -ForegroundColor DarkGray }

    Write-Host ""
    Write-Host ("  " + $Rows[$Cursor].Dir.path) -ForegroundColor DarkGray
    Write-Host ""
    Write-Host "  UP/DOWN move  SPACE toggle  LEFT/RIGHT fold  A all  N none  R rescan  ENTER save  ESC cancel" -ForegroundColor DarkCyan
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
        'LeftArrow'  { $collapsed[$row.Dir.path] = $true;  $rows = Build-Rows }
        'RightArrow' { $collapsed[$row.Dir.path] = $false; $rows = Build-Rows }
        'Spacebar'   {
            if ($row.Kind -eq 'dir') {
                if (-not $row.Dir.missing) { $row.Dir.enabled = -not $row.Dir.enabled; $dirty = $true }
            } else {
                $row.Session.enabled = -not $row.Session.enabled; $dirty = $true
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
                '[aA]' { foreach ($d in $dirs) { if (-not $d.missing) { $d.enabled = $true;  foreach ($s in @($d.sessions)) { $s.enabled = $true  } } }; $dirty = $true }
                '[nN]' { foreach ($d in $dirs) { if (-not $d.missing) { $d.enabled = $false; foreach ($s in @($d.sessions)) { $s.enabled = $false } } }; $dirty = $true }
                '[qQ]' { Clear-Host; Write-Host "`n  Cancelled.`n" -ForegroundColor Yellow; exit 0 }
                '[rR]' {
                    if ($dirty) { Save-SRRegistry -Registry $reg; $dirty = $false }
                    $null = Update-SRRegistry -Config $cfg -Quiet
                    $reg  = Get-SRRegistry
                    $dirs = @($reg.directories | Sort-Object { if (@($_.sessions).Count) { [datetime](@($_.sessions) | Sort-Object { [datetime]$_.lastActive } -Descending)[0].lastActive } else { [datetime]'1970-01-01' } } -Descending)
                    $rows = Build-Rows
                }
            }
        }
    }
}
