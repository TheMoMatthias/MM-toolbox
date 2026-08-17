#requires -Version 5.1
<#
.SYNOPSIS
    Choose which project directories reopen when you log in.

.DESCRIPTION
    Discovery finds every project you have a Claude conversation in. This is where
    you say which of them should actually come back. Ticked directories are
    restored at logon (and by `ccr`); unticked ones are left alone, however
    discoverable they are.

    A background task rescans hourly, so a project you started today shows up here
    without you doing anything. New directories arrive TICKED if you worked in them
    within the recency window, and unticked if they are older than it.

    Keys:  UP/DOWN move   SPACE toggle   A all   N none   R rescan
           ENTER save and exit           ESC / Q cancel

.PARAMETER List
    Print the current selection and exit, without the interactive picker. Also the
    automatic fallback when there is no interactive console.

.PARAMETER Enable
.PARAMETER Disable
    Tick or untick by path substring, without the picker. Case-insensitive.

.EXAMPLE
    .\select-sessions.ps1
    .\select-sessions.ps1 -List
    .\select-sessions.ps1 -Disable CardTrader
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
$reg = Get-SRRegistry
$entries = @($reg.entries | Sort-Object { [datetime]$_.lastActive } -Descending)

if ($entries.Count -eq 0) {
    Write-Host ""
    Write-Host "No project directories discovered yet." -ForegroundColor Yellow
    Write-Host "  Run claude in a project once, then re-run this script."
    Write-Host ""
    exit 1
}

$staleDays = [double]$cfg.recencyDays

function Get-AgeText {
    param($Entry)
    $d = ((Get-Date) - [datetime]$Entry.lastActive)
    if ($d.TotalDays -ge 1) { return ("{0}d" -f [int]$d.TotalDays) }
    return ("{0}h" -f [int]$d.TotalHours)
}

function Test-Stale { param($Entry) return (((Get-Date) - [datetime]$Entry.lastActive).TotalDays -gt $staleDays) }

function Write-Summary {
    param($Items)
    $on = @($Items | Where-Object { $_.enabled -and -not $_.missing }).Count
    Write-Host ""
    Write-Host ("  {0} of {1} director{2} will reopen at logon." -f $on, $Items.Count, $(if($Items.Count -eq 1){'y'}else{'ies'}))
    $stale = @($Items | Where-Object { $_.enabled -and -not $_.missing -and (Test-Stale $_) })
    if ($stale.Count -gt 0) {
        Write-Host ("  {0} of them {1} not been touched in over {2} days:" -f $stale.Count, $(if($stale.Count -eq 1){'has'}else{'have'}), [int]$staleDays) -ForegroundColor DarkYellow
        foreach ($s in $stale) { Write-Host ("     {0}  ({1})" -f (Split-Path $s.path -Leaf), (Get-AgeText $s)) -ForegroundColor DarkYellow }
        Write-Host "  Your tick wins - they will still reopen. Untick them here if they are finished." -ForegroundColor DarkYellow
    }
    Write-Host ""
}

# --- non-interactive paths -------------------------------------------------
if ($Enable -or $Disable) {
    $changed = 0
    foreach ($e in $entries) {
        foreach ($pat in @($Enable))  { if ($pat -and $e.path -like "*$pat*") { if (-not $e.enabled) { $e.enabled = $true;  $changed++; Write-Host ("  ticked   " + $e.path) -ForegroundColor Green } } }
        foreach ($pat in @($Disable)) { if ($pat -and $e.path -like "*$pat*") { if ($e.enabled)      { $e.enabled = $false; $changed++; Write-Host ("  unticked " + $e.path) -ForegroundColor DarkYellow } } }
    }
    if ($changed -eq 0) { Write-Host "  nothing matched - no change" -ForegroundColor Yellow }
    else { Save-SRRegistry -Registry $reg }
    Write-Summary -Items $entries
    exit 0
}

function Write-PlainList {
    param($Items)
    Write-Host ""
    Write-Host "Claude session selection" -ForegroundColor Cyan
    Write-Host ""
    foreach ($e in $Items) {
        $mark = if ($e.missing) { '[?]' } elseif ($e.enabled) { '[x]' } else { '[ ]' }
        $col  = if ($e.missing) { 'DarkGray' } elseif (-not $e.enabled) { 'Gray' } elseif (Test-Stale $e) { 'DarkYellow' } else { 'Green' }
        Write-Host ("  {0} {1,-24} {2,-26} {3,5}   {4}" -f $mark, (Split-Path $e.path -Leaf), $e.title, (Get-AgeText $e), $e.path) -ForegroundColor $col
    }
    Write-Summary -Items $Items
    Write-Host "  Change it with:  select-sessions.ps1            (interactive picker)"
    Write-Host "                   select-sessions.ps1 -Disable CardTrader"
    Write-Host "  Or edit directly: $SR_RegistryPath"
    Write-Host ""
}

if ($List) { Write-PlainList -Items $entries; exit 0 }

# Without a real console, ReadKey throws or blocks forever. Degrade to the list
# rather than hanging a scheduled task or a piped invocation.
$interactive = $true
try {
    if (-not [Environment]::UserInteractive) { $interactive = $false }
    elseif ($null -eq $Host.UI.RawUI)        { $interactive = $false }
    elseif ([Console]::IsInputRedirected)    { $interactive = $false }
} catch { $interactive = $false }

if (-not $interactive) {
    Write-Host ""
    Write-Host "No interactive console - showing the list instead of the picker." -ForegroundColor Yellow
    Write-PlainList -Items $entries
    exit 0
}

# --- interactive picker ----------------------------------------------------
$cursor = 0
$dirty  = $false

function Render {
    param($Items, $Cursor)
    Clear-Host
    $on = @($Items | Where-Object { $_.enabled -and -not $_.missing }).Count
    Write-Host ""
    Write-Host "  Claude session selection" -ForegroundColor Cyan -NoNewline
    Write-Host ("        {0} of {1} will reopen at logon" -f $on, $Items.Count) -ForegroundColor Gray
    Write-Host ""

    # Viewport, so a long list does not scroll the header off the screen.
    $height = 20
    try { $height = [Math]::Max(6, $Host.UI.RawUI.WindowSize.Height - 9) } catch { }
    $first = 0
    if ($Items.Count -gt $height) {
        $first = [Math]::Max(0, [Math]::Min($Cursor - [int]($height / 2), $Items.Count - $height))
    }
    $last = [Math]::Min($Items.Count - 1, $first + $height - 1)

    if ($first -gt 0) { Write-Host "      ..." -ForegroundColor DarkGray }
    for ($i = $first; $i -le $last; $i++) {
        $e = $Items[$i]
        $sel  = if ($i -eq $Cursor) { '>' } else { ' ' }
        $mark = if ($e.missing) { '[?]' } elseif ($e.enabled) { '[x]' } else { '[ ]' }
        $note = ''
        if ($e.missing)          { $note = '  MISSING - directory is gone' }
        elseif ($e.enabled -and (Test-Stale $e)) { $note = '  STALE' }

        $col = if ($e.missing) { 'DarkGray' } elseif (-not $e.enabled) { 'Gray' } elseif (Test-Stale $e) { 'DarkYellow' } else { 'Green' }
        if ($i -eq $Cursor) { $col = 'White' }

        Write-Host ("  {0} {1} {2,-22} {3,-24} {4,5}{5}" -f $sel, $mark, (Split-Path $e.path -Leaf), $e.title, (Get-AgeText $e), $note) -ForegroundColor $col
    }
    if ($last -lt $Items.Count - 1) { Write-Host "      ..." -ForegroundColor DarkGray }

    Write-Host ""
    Write-Host ("  " + $Items[$Cursor].path) -ForegroundColor DarkGray
    Write-Host ""
    Write-Host "  UP/DOWN move   SPACE toggle   A all   N none   R rescan   ENTER save   ESC cancel" -ForegroundColor DarkCyan
}

while ($true) {
    Render -Items $entries -Cursor $cursor
    $key = [Console]::ReadKey($true)

    switch ($key.Key) {
        'UpArrow'   { if ($cursor -gt 0) { $cursor-- } }
        'DownArrow' { if ($cursor -lt $entries.Count - 1) { $cursor++ } }
        'Home'      { $cursor = 0 }
        'End'       { $cursor = $entries.Count - 1 }
        'Spacebar'  {
            $e = $entries[$cursor]
            if (-not $e.missing) { $e.enabled = -not $e.enabled; $dirty = $true }
        }
        'Enter' {
            if ($dirty) { Save-SRRegistry -Registry $reg }
            Clear-Host
            Write-Host ""
            Write-Host $(if ($dirty) { "  Saved." } else { "  No changes." }) -ForegroundColor Green
            Write-Summary -Items $entries
            Write-Host "  Registry: $SR_RegistryPath"
            Write-Host ""
            exit 0
        }
        'Escape' {
            Clear-Host
            Write-Host ""
            Write-Host $(if ($dirty) { "  Cancelled - changes discarded." } else { "  Cancelled." }) -ForegroundColor Yellow
            Write-Host ""
            exit 0
        }
        default {
            switch ($key.KeyChar) {
                'a' { foreach ($e in $entries) { if (-not $e.missing) { $e.enabled = $true  } }; $dirty = $true }
                'A' { foreach ($e in $entries) { if (-not $e.missing) { $e.enabled = $true  } }; $dirty = $true }
                'n' { foreach ($e in $entries) { if (-not $e.missing) { $e.enabled = $false } }; $dirty = $true }
                'N' { foreach ($e in $entries) { if (-not $e.missing) { $e.enabled = $false } }; $dirty = $true }
                'q' { Clear-Host; Write-Host "`n  Cancelled.`n" -ForegroundColor Yellow; exit 0 }
                'Q' { Clear-Host; Write-Host "`n  Cancelled.`n" -ForegroundColor Yellow; exit 0 }
                'r' {
                    if ($dirty) { Save-SRRegistry -Registry $reg; $dirty = $false }
                    $null = Update-SRRegistry -Config $cfg -Quiet
                    $reg = Get-SRRegistry
                    $entries = @($reg.entries | Sort-Object { [datetime]$_.lastActive } -Descending)
                    if ($cursor -ge $entries.Count) { $cursor = [Math]::Max(0, $entries.Count - 1) }
                }
                'R' {
                    if ($dirty) { Save-SRRegistry -Registry $reg; $dirty = $false }
                    $null = Update-SRRegistry -Config $cfg -Quiet
                    $reg = Get-SRRegistry
                    $entries = @($reg.entries | Sort-Object { [datetime]$_.lastActive } -Descending)
                    if ($cursor -ge $entries.Count) { $cursor = [Math]::Max(0, $entries.Count - 1) }
                }
            }
        }
    }
}
