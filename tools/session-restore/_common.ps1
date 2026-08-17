#requires -Version 5.1
<#
    Shared internals for session-restore. Dot-sourced by restore-sessions.ps1 and
    select-sessions.ps1 so discovery, the registry and the guards exist ONCE.

    Defines functions and paths only -- it must never do work on load.
#>

# $PSScriptRoot inside a dot-sourced file is THAT file's directory, and it is
# resolved in the body rather than in a param default -- which is empty under
# `powershell.exe -File` and cost a silent morning failure once already.
$SR_Root       = $PSScriptRoot
$SR_Projects   = Join-Path $env:USERPROFILE '.claude\projects'
$SR_StateDir   = Join-Path $SR_Root '.state'
$SR_LogPath    = Join-Path $SR_StateDir 'restore.log'
$SR_ConfigPath = Join-Path $SR_Root 'session-restore.config.json'

# The registry is the OPERATOR'S selection and is NOT disposable, so it lives
# beside the scripts rather than inside .state/ (which holds regenerated junk).
# Gitignored: the paths in it are specific to this machine.
$SR_RegistryPath = Join-Path $SR_Root 'sessions-registry.json'

# A transcript smaller than this is a Remote Control placeholder, not a
# conversation: a lone bridge-session line is 118 bytes.
$SR_MinRealBytes = 5000

# A transcript written this recently is being held by a live session.
$SR_LiveWindowMinutes = 3

# The six variables that mark a process as a CHILD session. A claude started with
# these set writes NO transcript at all and cannot be resumed afterwards.
$SR_ChildVars = @(
    'CLAUDE_CODE_CHILD_SESSION', 'CLAUDE_CODE_SESSION_ID', 'CLAUDECODE',
    'CLAUDE_CODE_ENTRYPOINT', 'CLAUDE_PID', 'CLAUDE_CODE_SSE_PORT'
)

# ---------------------------------------------------------------------------
# Logging. At logon these scripts run hidden, so Write-Host reaches nobody.
# ---------------------------------------------------------------------------
function Write-SRLog {
    param([string]$Message)
    try {
        if (-not (Test-Path -LiteralPath $SR_StateDir)) {
            New-Item -ItemType Directory -Path $SR_StateDir -Force | Out-Null
        }
        Add-Content -LiteralPath $SR_LogPath -Encoding utf8 `
            -Value ("{0}  {1}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Message)
    } catch { }
}

function Write-SRStep { param([string]$m) Write-Host "  $m";                                    Write-SRLog "         $m" }
function Write-SROk   { param([string]$m) Write-Host "  [ok]   $m" -ForegroundColor Green;      Write-SRLog "  [ok]   $m" }
function Write-SRSkip { param([string]$m) Write-Host "  [skip] $m" -ForegroundColor DarkYellow; Write-SRLog "  [skip] $m" }
function Write-SRFail { param([string]$m) Write-Host "  [FAIL] $m" -ForegroundColor Red;        Write-SRLog "  [FAIL] $m" }

function Clear-SRChildEnv {
    foreach ($v in $SR_ChildVars) {
        if (Test-Path "Env:$v") { Remove-Item "Env:$v" -ErrorAction SilentlyContinue }
    }
}

# ---------------------------------------------------------------------------
# Config
# ---------------------------------------------------------------------------
function Get-SRConfig {
    if (-not (Test-Path -LiteralPath $SR_ConfigPath)) {
        throw "config not found: $SR_ConfigPath"
    }
    return (Get-Content -LiteralPath $SR_ConfigPath -Raw | ConvertFrom-Json)
}

# ---------------------------------------------------------------------------
# Reading a conversation
# ---------------------------------------------------------------------------

# The transcript FOLDER name is a lossy encoding of the working directory -- every
# non-alphanumeric character becomes '-', so a space and a backslash are
# indistinguishable and the path cannot be reversed. The transcript records the
# real path in a "cwd" field.
#
# Read the LAST one. A session that moved directories keeps its original cwd at
# the top and exists under BOTH project folders; the last value resolves both
# copies to the same real directory, which the one-per-directory rule then folds.
function Get-SRSessionCwd {
    param([Parameter(Mandatory)][string]$JsonlPath)
    try {
        $tail = Get-Content -LiteralPath $JsonlPath -Tail 400 -ErrorAction Stop
        $line = $tail | Where-Object { $_ -like '*"cwd":*' } | Select-Object -Last 1
        if (-not $line) {
            $head = Get-Content -LiteralPath $JsonlPath -TotalCount 60 -ErrorAction Stop
            $line = $head | Where-Object { $_ -like '*"cwd":*' } | Select-Object -Last 1
        }
        if ($line) {
            $parsed = $line | ConvertFrom-Json
            if ($parsed.cwd) { return [string]$parsed.cwd }
        }
    } catch { }
    return $null
}

# The title set with /rename or -n. Written repeatedly, so the tail suffices and
# a 100 MB transcript is never read end to end.
function Get-SRSessionTitle {
    param([Parameter(Mandatory)][string]$JsonlPath)
    try {
        $tail = Get-Content -LiteralPath $JsonlPath -Tail 400 -ErrorAction Stop
    } catch { return $null }
    $line = $tail | Where-Object { $_ -like '*"type":"custom-title"*' } | Select-Object -Last 1
    if (-not $line) { return $null }
    try {
        $parsed = $line | ConvertFrom-Json
        if ($parsed.customTitle) { return [string]$parsed.customTitle }
    } catch { }
    return $null
}

function Test-SRExcluded {
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)]$Config)

    # The home directory is never a project: Claude Code creates a transcript
    # folder for it the moment anyone runs `claude` from ~.
    if ($Path.TrimEnd('\') -ieq $env:USERPROFILE.TrimEnd('\')) { return $true }

    foreach ($pat in @($Config.excludePatterns)) {
        if ([string]::IsNullOrWhiteSpace($pat)) { continue }
        if ($Path -like ([Environment]::ExpandEnvironmentVariables($pat))) { return $true }
    }
    return $false
}

# ---------------------------------------------------------------------------
# Discovery -- what conversations exist on this machine, right now.
# Returns one row per DIRECTORY, newest first. It launches nothing and it does
# not consult the registry; selection is a separate concern.
# ---------------------------------------------------------------------------
function Get-SRDiscovered {
    param([Parameter(Mandatory)]$Config)

    if (-not (Test-Path -LiteralPath $SR_Projects)) {
        throw "no Claude projects folder at $SR_Projects - has claude ever run on this machine?"
    }

    $found = @()
    foreach ($pdir in (Get-ChildItem -LiteralPath $SR_Projects -Directory -ErrorAction SilentlyContinue)) {
        $newest = Get-ChildItem -LiteralPath $pdir.FullName -Filter *.jsonl -File -ErrorAction SilentlyContinue |
                  Where-Object { $_.Length -ge $SR_MinRealBytes } |
                  Sort-Object LastWriteTime -Descending | Select-Object -First 1
        if (-not $newest) { continue }

        $cwd = Get-SRSessionCwd -JsonlPath $newest.FullName
        if (-not $cwd) { continue }
        if (-not (Test-Path -LiteralPath $cwd -PathType Container)) { continue }
        if (Test-SRExcluded -Path $cwd -Config $Config) { continue }

        $found += [PSCustomObject]@{
            Path       = $cwd.TrimEnd('\')
            SessionId  = $newest.BaseName
            Jsonl      = $newest.FullName
            LastActive = $newest.LastWriteTime
        }
    }

    # One session per working tree: two sessions in one directory share a single
    # git index, and a bare `git commit` in either takes what the other staged.
    return ,@($found |
        Group-Object -Property { $_.Path.ToLowerInvariant() } |
        ForEach-Object { $_.Group | Sort-Object LastActive -Descending | Select-Object -First 1 } |
        Sort-Object LastActive -Descending)
}

# ---------------------------------------------------------------------------
# Registry -- the operator's selection. Discovery says what EXISTS; this says
# what should come back. Keeping them separate is the whole point: a directory
# you untick stays untickled even though it is still discoverable.
# ---------------------------------------------------------------------------
function Get-SRRegistry {
    if (-not (Test-Path -LiteralPath $SR_RegistryPath)) {
        return [PSCustomObject]@{ version = 1; lastScan = $null; entries = @() }
    }
    try {
        $r = Get-Content -LiteralPath $SR_RegistryPath -Raw | ConvertFrom-Json
        if ($null -eq $r.PSObject.Properties['entries']) {
            $r | Add-Member -NotePropertyName entries -NotePropertyValue @() -Force
        }
        return $r
    } catch {
        throw "registry is unreadable ($SR_RegistryPath): $($_.Exception.Message). Delete it to start fresh."
    }
}

function Save-SRRegistry {
    param([Parameter(Mandatory)]$Registry)
    $Registry.lastScan = (Get-Date).ToString('o')
    # Atomic-ish: write beside the target, then replace. A half-written registry
    # would lose every selection.
    $tmp = "$SR_RegistryPath.tmp"
    ($Registry | ConvertTo-Json -Depth 6) | Set-Content -LiteralPath $tmp -Encoding utf8
    Move-Item -LiteralPath $tmp -Destination $SR_RegistryPath -Force
}

# Refresh the registry from what is on disk. NEVER launches anything.
# New directories arrive ticked only if they were active within recencyDays --
# so the tool behaves like it did before out of the box, and you intervene only
# to switch something off.
# Entries are never deleted: unticking is the operator's job, and a directory
# that disappears is marked rather than forgotten.
function Update-SRRegistry {
    param([Parameter(Mandatory)]$Config, [switch]$Quiet)

    $reg   = Get-SRRegistry
    $disc  = Get-SRDiscovered -Config $Config
    $now   = (Get-Date).ToString('o')
    $cutoff = (Get-Date).AddDays(-1 * [double]$Config.recencyDays)

    $byPath = @{}
    foreach ($e in @($reg.entries)) {
        if ($e.path) { $byPath[$e.path.ToLowerInvariant()] = $e }
    }

    $added = 0; $updated = 0
    foreach ($d in $disc) {
        $key = $d.Path.ToLowerInvariant()
        $title = Get-SRSessionTitle -JsonlPath $d.Jsonl
        if (-not $title) { $title = Split-Path $d.Path -Leaf }

        if ($byPath.ContainsKey($key)) {
            $e = $byPath[$key]
            $e.lastActive = $d.LastActive.ToString('o')
            $e.sessionId  = $d.SessionId
            $e.title      = $title
            $e.missing    = $false
            $updated++
        } else {
            $reg.entries += [PSCustomObject]@{
                path       = $d.Path
                enabled    = ($d.LastActive -ge $cutoff)
                firstSeen  = $now
                lastActive = $d.LastActive.ToString('o')
                sessionId  = $d.SessionId
                title      = $title
                missing    = $false
            }
            $added++
            if (-not $Quiet) {
                $state = if ($d.LastActive -ge $cutoff) { 'ticked' } else { 'unticked (older than the window)' }
                Write-SRStep ("new: {0}  -> {1}" -f (Split-Path $d.Path -Leaf), $state)
            }
        }
    }

    # Mark entries whose directory no longer exists, rather than dropping them.
    $seen = @{}
    foreach ($d in $disc) { $seen[$d.Path.ToLowerInvariant()] = $true }
    foreach ($e in @($reg.entries)) {
        if ($e.path -and -not $seen.ContainsKey($e.path.ToLowerInvariant())) {
            $e | Add-Member -NotePropertyName missing -NotePropertyValue $true -Force
        }
    }

    Save-SRRegistry -Registry $reg
    if (-not $Quiet) {
        Write-SRStep ("registry: {0} entr{1}, {2} new, {3} refreshed" -f @($reg.entries).Count, $(if(@($reg.entries).Count -eq 1){'y'}else{'ies'}), $added, $updated)
    }
    return $reg
}

# ---------------------------------------------------------------------------
# Guards
# ---------------------------------------------------------------------------

# The mtime guard only catches a session that is actively WRITING. A session idle
# at its prompt writes nothing. Sessions launched by this tool carry
# `--resume <id>` in their command line, so they are identifiable. Bare-`claude`
# sessions that later /resume'd carry no id -- hence both guards.
function Test-SRProcessRunning {
    param([Parameter(Mandatory)][string]$SessionId)
    $p = Get-CimInstance Win32_Process -Filter "Name='claude.exe'" -ErrorAction SilentlyContinue |
         Where-Object { $_.CommandLine -and $_.CommandLine -like "*$SessionId*" }
    return (@($p).Count -gt 0)
}

function Test-SRTranscriptLive {
    param([Parameter(Mandatory)][string]$JsonlPath)
    if (-not (Test-Path -LiteralPath $JsonlPath)) { return $false }
    return (((Get-Date) - (Get-Item -LiteralPath $JsonlPath).LastWriteTime).TotalMinutes -lt $SR_LiveWindowMinutes)
}

# ---------------------------------------------------------------------------
# Launching
# ---------------------------------------------------------------------------

# Get-Command does NOT find wt.exe: it ships as a WindowsApps execution alias, a
# reparse point often absent from a child shell's PATH and from the thinner PATH
# a scheduled task inherits. Resolving by PATH alone failed here once already.
function Resolve-SRWindowsTerminal {
    $gc = Get-Command wt.exe -ErrorAction SilentlyContinue
    if ($gc -and $gc.Source) { return $gc.Source }
    foreach ($c in @(
        (Join-Path $env:LOCALAPPDATA 'Microsoft\WindowsApps\wt.exe'),
        (Join-Path $env:ProgramFiles 'WindowsApps\wt.exe')
    )) { if (Test-Path -LiteralPath $c) { return $c } }
    $pkg = Get-ChildItem (Join-Path $env:ProgramFiles 'WindowsApps') -Filter 'Microsoft.WindowsTerminal*' `
               -Directory -ErrorAction SilentlyContinue | Sort-Object Name -Descending | Select-Object -First 1
    if ($pkg) {
        $exe = Join-Path $pkg.FullName 'wt.exe'
        if (Test-Path -LiteralPath $exe) { return $exe }
    }
    return $null
}

function New-SRBootScript {
    param(
        [Parameter(Mandatory)][string]$Dir,
        [Parameter(Mandatory)][string]$SessionId,
        [Parameter(Mandatory)][string]$Title
    )
    if (-not (Test-Path -LiteralPath $SR_StateDir)) {
        New-Item -ItemType Directory -Path $SR_StateDir -Force | Out-Null
    }
    $slug = ((Split-Path $Dir -Leaf) -replace '[^A-Za-z0-9]', '-')
    $boot = Join-Path $SR_StateDir "boot-$slug.ps1"

    # Single-quoted here-string: nothing expands here. Placeholders are substituted
    # afterwards, so a title containing $ or a backtick can never be re-parsed as
    # PowerShell. A name must never cross a shell boundary as syntax.
    $body = @'
# Generated by session-restore -- safe to delete.
# Scrub the inherited child-session environment. Without this, claude writes no
# transcript at all and the conversation cannot be resumed afterwards.
foreach ($v in @(__SCRUBVARS__)) {
    if (Test-Path "Env:$v") { Remove-Item "Env:$v" -ErrorAction SilentlyContinue }
}
Set-Location -LiteralPath '__DIR__'
# -n writes a DURABLE custom-title into the conversation (precedence rule 2);
# --remote-control names only THIS remote session (rule 1). Both are needed.
& claude --resume '__SESSION__' -n '__TITLE__' --remote-control '__TITLE__'
'@
    $body = $body.Replace('__SCRUBVARS__', (($SR_ChildVars | ForEach-Object { "'" + $_ + "'" }) -join ','))
    $body = $body.Replace('__DIR__',       $Dir.Replace("'", "''"))
    $body = $body.Replace('__SESSION__',   $SessionId.Replace("'", "''"))
    $body = $body.Replace('__TITLE__',     $Title.Replace("'", "''"))

    Set-Content -LiteralPath $boot -Value $body -Encoding utf8
    return $boot
}

function Start-SRSession {
    param(
        [Parameter(Mandatory)][string]$Dir,
        [Parameter(Mandatory)][string]$BootScript,
        [Parameter(Mandatory)][string]$Title
    )
    $wt = Resolve-SRWindowsTerminal
    if (-not $wt) {
        throw "Windows Terminal (wt.exe) not found. A plain PowerShell window spawned from a non-interactive parent does not reliably give claude a usable console."
    }
    Start-Process -FilePath $wt -ArgumentList @(
        '-w', '0', 'new-tab', '--title', $Title, '-d', $Dir,
        'powershell.exe', '-NoExit', '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $BootScript
    ) | Out-Null
}
