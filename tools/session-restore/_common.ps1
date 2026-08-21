#requires -Version 5.1
<#
    Shared internals for session-restore. Dot-sourced by restore-sessions.ps1 and
    select-sessions.ps1 so discovery, the registry and the guards exist ONCE.

    Defines functions and paths only -- it must never do work on load.

    REGISTRY v2: directories, each holding its conversations. The directory has a
    master tick and every session under it has its own, so you can switch off a whole
    project or drop a single finished slice.
#>

# $PSScriptRoot inside a dot-sourced file is THAT file's directory, and it is
# resolved in the body rather than in a param default -- which is empty under
# `powershell.exe -File` and cost a silent morning failure once already.
$SR_Root       = $PSScriptRoot
$SR_Projects   = Join-Path $env:USERPROFILE '.claude\projects'
$SR_StateDir   = Join-Path $SR_Root '.state'
$SR_LogPath    = Join-Path $SR_StateDir 'restore.log'
$SR_ConfigPath = Join-Path $SR_Root 'session-restore.config.json'

# The registry is the OPERATOR'S selection and is NOT disposable, so it lives beside
# the scripts rather than inside .state/ (which holds regenerated junk). Gitignored:
# the paths in it are specific to this machine.
$SR_RegistryPath = Join-Path $SR_Root 'sessions-registry.json'

# A transcript smaller than this is a Remote Control placeholder, not a
# conversation: a lone bridge-session line is 118 bytes.
$SR_MinRealBytes = 5000

# A transcript written this recently is being held by a live session.
$SR_LiveWindowMinutes = 3

# How long a just-launched conversation keeps its optimistic mark in the panel.
# claude takes seconds to surface in Win32_Process, and a row that reads idle in
# that gap invites a second, duplicate tab.
$SR_LaunchGraceSeconds = 90

# The six variables that mark a process as a CHILD session. A claude started with
# these set writes NO transcript at all and cannot be resumed afterwards.
$SR_ChildVars = @(
    'CLAUDE_CODE_CHILD_SESSION', 'CLAUDE_CODE_SESSION_ID', 'CLAUDECODE',
    'CLAUDE_CODE_ENTRYPOINT', 'CLAUDE_PID', 'CLAUDE_CODE_SSE_PORT'
)

# ---------------------------------------------------------------------------
# Logging. At logon these scripts run hidden, so Write-Host reaches nobody.
# ---------------------------------------------------------------------------
# Trimmed once per process, not per line: the check is a stat, and a scan writes
# dozens of lines. Unbounded, this grew ~20 KB a day from the hourly task alone --
# slow, but it is the log you read when the tool seems dead, and scrolling a year
# of it to find this morning is its own failure.
$script:SR_LogTrimmed = $false
$SR_LogMaxBytes = 512KB
$SR_LogKeepLines = 2000

function Write-SRLog {
    param([string]$Message)
    try {
        if (-not (Test-Path -LiteralPath $SR_StateDir)) {
            New-Item -ItemType Directory -Path $SR_StateDir -Force | Out-Null
        }
        if (-not $script:SR_LogTrimmed) {
            $script:SR_LogTrimmed = $true
            $f = Get-Item -LiteralPath $SR_LogPath -ErrorAction SilentlyContinue
            if ($f -and $f.Length -gt $SR_LogMaxBytes) {
                $keep = @(Get-Content -LiteralPath $SR_LogPath -Tail $SR_LogKeepLines)
                # Via a temp + replace, so a crash mid-trim cannot leave no log at all.
                $tmp = "$SR_LogPath.tmp"
                Set-Content -LiteralPath $tmp -Value $keep -Encoding utf8
                Move-Item -LiteralPath $tmp -Destination $SR_LogPath -Force
                Add-Content -LiteralPath $SR_LogPath -Encoding utf8 `
                    -Value ("{0}  ---- trimmed to the last {1} lines ----" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $SR_LogKeepLines)
            }
        }
        Add-Content -LiteralPath $SR_LogPath -Encoding utf8 `
            -Value ("{0}  {1}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Message)
    } catch { }
}

function Write-SRStep { param([string]$m) Write-Host "  $m";                                    Write-SRLog "         $m" }
function Write-SROk   { param([string]$m) Write-Host "  [ok]   $m" -ForegroundColor Green;      Write-SRLog "  [ok]   $m" }
function Write-SRSkip { param([string]$m) Write-Host "  [skip] $m" -ForegroundColor DarkYellow; Write-SRLog "  [skip] $m" }
function Write-SRFail { param([string]$m) Write-Host "  [FAIL] $m" -ForegroundColor Red;        Write-SRLog "  [FAIL] $m" }
function Write-SRWarn { param([string]$m) Write-Host "  [warn] $m" -ForegroundColor Yellow;     Write-SRLog "  [warn] $m" }

function Clear-SRChildEnv {
    foreach ($v in $SR_ChildVars) {
        if (Test-Path "Env:$v") { Remove-Item "Env:$v" -ErrorAction SilentlyContinue }
    }
}

# ---------------------------------------------------------------------------
# Config
# ---------------------------------------------------------------------------
# Flip includeWorktrees in the config file.
#
# Deliberately a targeted text replacement rather than ConvertTo-Json round-tripping
# the parsed object: the config is mostly a hand-laid-out _README block, and
# re-serialising it would reflow every line of documentation to change one boolean.
#
# 🪤 The _README also contains the WORD includeWorktrees. The pattern requires the
# quoted key followed by a colon, which the prose form never is -- and the result is
# verified by re-reading, so a miss cannot pass silently.
function Set-SRIncludeWorktrees {
    param([Parameter(Mandatory)][bool]$Value)

    $raw = Get-Content -LiteralPath $SR_ConfigPath -Raw
    $lit = $Value.ToString().ToLowerInvariant()
    $new = [regex]::Replace($raw, '("includeWorktrees"\s*:\s*)(?:true|false)', ('${1}' + $lit))

    if ($new -eq $raw -and -not ($raw -match '"includeWorktrees"\s*:\s*' + $lit)) {
        throw "could not find an `"includeWorktrees`" key to set in $SR_ConfigPath"
    }

    # WriteAllText, not Set-Content: Set-Content appends a trailing newline on every
    # write, so each toggle grew the file by a blank line. Normalise the ending and
    # write exactly that. UTF8 without a BOM, matching how the file was authored.
    $new = $new.TrimEnd("`r", "`n") + "`r`n"
    [System.IO.File]::WriteAllText($SR_ConfigPath, $new, (New-Object System.Text.UTF8Encoding($false)))

    $check = (Get-Content -LiteralPath $SR_ConfigPath -Raw | ConvertFrom-Json).includeWorktrees
    if ([bool]$check -ne $Value) {
        throw "wrote includeWorktrees=$lit but the file reads back as $check"
    }
    Write-SRLog "includeWorktrees set to $lit"
    return $Value
}

function Get-SRConfig {
    if (-not (Test-Path -LiteralPath $SR_ConfigPath)) { throw "config not found: $SR_ConfigPath" }
    $c = Get-Content -LiteralPath $SR_ConfigPath -Raw | ConvertFrom-Json

    # Defaults for keys added after a config was first written, so an older config
    # keeps working instead of silently behaving as if the value were zero.
    foreach ($kv in @(
        @{ k = 'recencyDays';          v = 14 },
        @{ k = 'sessionWindowDays';    v = 3  },
        @{ k = 'autoTickPerDirectory'; v = 3  },
        @{ k = 'autoTickPerWorktree';  v = 3  },
        @{ k = 'includeWorktrees';     v = $true },
        @{ k = 'registryWindowDays';   v = 30 },
        @{ k = 'maxSessions';          v = 12 }
    )) {
        if ($null -eq $c.PSObject.Properties[$kv.k]) {
            $c | Add-Member -NotePropertyName $kv.k -NotePropertyValue $kv.v -Force
        }
    }
    return $c
}

# ---------------------------------------------------------------------------
# Reading a conversation.
#
# 🪤 THIS USED TO USE `Get-Content -Tail 400` + ConvertFrom-Json AND IT COST 110
# SECONDS ACROSS 87 TRANSCRIPTS. The cost tracked MAX LINE LENGTH, not file size:
# a 0.9 MB transcript with a 736 KB line took 30 s while a 97 MB one with short
# lines took 2.4 s. Two reasons -- with fewer than 400 lines `-Tail 400` walks the
# entire file backwards, and ConvertFrom-Json on a multi-megabyte line is brutal.
#
# Seeking to the last N bytes and running two regexes is bounded work whatever the
# file looks like. MEASURED: 110,322 ms -> 141 ms over the same 87 files, a 782x
# speedup, with ZERO disagreements in the extracted cwd/title.
# ---------------------------------------------------------------------------
$SR_TailBytes = 262144

function Get-SRSessionInfo {
    param([Parameter(Mandatory)][string]$JsonlPath)

    $cwd = $null; $title = $null
    try {
        # FileShare ReadWrite: a live session is appending to this file right now.
        $fs = [System.IO.File]::Open($JsonlPath, 'Open', 'Read', 'ReadWrite')
        try {
            $take = [int][Math]::Min($fs.Length, $SR_TailBytes)
            $null = $fs.Seek(-$take, 'End')
            $buf  = New-Object byte[] $take
            $read = $fs.Read($buf, 0, $take)
            $text = [System.Text.Encoding]::UTF8.GetString($buf, 0, $read)
        } finally { $fs.Dispose() }

        # LAST match wins, as before. A session that moved directories keeps its
        # original cwd at the top and exists under BOTH project folders; taking the
        # last value resolves both copies to the same real directory.
        $m = [regex]::Matches($text, '"cwd":"(.*?)(?<!\\)"')
        if ($m.Count) { $cwd = $m[$m.Count - 1].Groups[1].Value.Replace('\\', '\').Replace('\"', '"') }
        $m = [regex]::Matches($text, '"customTitle":"(.*?)(?<!\\)"')
        if ($m.Count) { $title = $m[$m.Count - 1].Groups[1].Value.Replace('\\', '\').Replace('\"', '"') }

        # A transcript may hold its cwd only near the top. If the tail had none, read
        # the whole file -- but ONLY when it is small. Without the size bound this
        # fallback would pull a 100 MB file into memory, reintroducing exactly the
        # unbounded cost this function was rewritten to remove.
        $full = (Get-Item -LiteralPath $JsonlPath).Length
        if (-not $cwd -and $take -lt $full -and $full -le 8MB) {
            $all = [System.IO.File]::ReadAllText($JsonlPath)
            $m = [regex]::Matches($all, '"cwd":"(.*?)(?<!\\)"')
            if ($m.Count) { $cwd = $m[$m.Count - 1].Groups[1].Value.Replace('\\', '\').Replace('\"', '"') }
        }
    } catch { }

    return [PSCustomObject]@{ Cwd = $cwd; Title = $title }
}

# Win32_Process is a WMI round trip costing ~100 ms. Asking once per conversation
# meant a dozen of them per restore; ask once and reuse.
$script:SR_ProcCache = $null
function Get-SRClaudeCommandLines {
    param([switch]$Refresh)
    if ($Refresh -or $null -eq $script:SR_ProcCache) {
        $script:SR_ProcCache = @(
            Get-CimInstance Win32_Process -Filter "Name='claude.exe'" -ErrorAction SilentlyContinue |
                ForEach-Object { $_.CommandLine } | Where-Object { $_ }
        )
    }
    return $script:SR_ProcCache
}

# A linked git worktree has a `.git` FILE (not a directory) whose first line reads
# `gitdir: <repo>/.git/worktrees/<name>`. That is the definitive marker -- it works
# wherever the worktree lives, unlike matching on a path pattern, and it hands back
# the parent repo for free.
#
# 🪤 Do NOT go back to excluding worktrees. That was tried, on the reasoning that two
# sessions in one tree share a git index -- which is backwards: a worktree has its
# OWN index, and "one worktree per lane" is the MITIGATION for that hazard. The
# exclusion hid a live session and no amount of rescanning could surface it.
$script:SR_WtCache = @{}
function Get-SRWorktreeInfo {
    param([Parameter(Mandatory)][string]$Path)

    $key = $Path.ToLowerInvariant()
    if ($script:SR_WtCache.ContainsKey($key)) { return $script:SR_WtCache[$key] }

    $info = [PSCustomObject]@{ RepoRoot = $Path; Lane = 'main'; Worktree = $null }
    try {
        $dotGit = Join-Path $Path '.git'
        if (Test-Path -LiteralPath $dotGit -PathType Leaf) {
            $first = Get-Content -LiteralPath $dotGit -TotalCount 1 -ErrorAction Stop
            if ($first -match '^\s*gitdir:\s*(.+?)\s*$') {
                # <repo>\.git\worktrees\<name>  ->  name, and <repo> three levels up.
                $gitdir = $Matches[1]
                $name   = Split-Path $gitdir -Leaf
                $up     = Split-Path (Split-Path (Split-Path $gitdir -Parent) -Parent) -Parent
                if ($name -and $up -and (Test-Path -LiteralPath $up -PathType Container)) {
                    $info = [PSCustomObject]@{ RepoRoot = $up.TrimEnd('\'); Lane = 'worktree'; Worktree = $name }
                }
            }
        }
        else {
            # 🪤 RepoRoot used to be $Path itself on the main lane, which made EVERY
            # SUBFOLDER its own "project". Not exotic: the Bash tool's cwd persists
            # between calls, so a session that cd's into a subdirectory writes that
            # cwd into its own transcript and the next scan files it as a new repo.
            # Measured 2026-08-21: this conversation appeared twice, once under
            # MM-toolbox and once under MM-toolbox\tools\session-restore.
            # "A PROJECT is a repository" is the tool's own model -- so walk up to
            # the repo root, exactly as the worktree branch above already does. The
            # session's `cwd` is untouched, so it still relaunches where it was.
            $walk = $Path
            while ($walk) {
                if (Test-Path -LiteralPath (Join-Path $walk '.git') -PathType Container) {
                    $info = [PSCustomObject]@{ RepoRoot = $walk.TrimEnd('\'); Lane = 'main'; Worktree = $null }
                    break
                }
                # Never walk past the home directory: a stray ~\.git would otherwise
                # swallow every project on the machine into one row.
                if ($walk.TrimEnd('\') -ieq $env:USERPROFILE.TrimEnd('\')) { break }
                $parent = Split-Path $walk -Parent
                if (-not $parent -or $parent -eq $walk) { break }
                $walk = $parent
            }
        }
    } catch { }

    $script:SR_WtCache[$key] = $info
    return $info
}

function Test-SRExcluded {
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)]$Config)

    # The home directory is never a project: Claude Code creates a transcript folder
    # for it the moment anyone runs `claude` from ~.
    if ($Path.TrimEnd('\') -ieq $env:USERPROFILE.TrimEnd('\')) { return $true }
    foreach ($pat in @($Config.excludePatterns)) {
        if ([string]::IsNullOrWhiteSpace($pat)) { continue }
        if ($Path -like ([Environment]::ExpandEnvironmentVariables($pat))) { return $true }
    }
    return $false
}

# ---------------------------------------------------------------------------
# Discovery -- EVERY real conversation, grouped by its working directory.
# Launches nothing and does not consult the registry; selection is separate.
# ---------------------------------------------------------------------------
# $Cache maps sessionId -> @{ Path; Title; Stamp }. A transcript whose stamp
# (mtime + length) is unchanged since the last scan is not read at all -- the
# hourly job then costs a directory listing rather than 87 file reads.
function Get-SRDiscovered {
    param([Parameter(Mandatory)]$Config, [hashtable]$Cache)

    if (-not (Test-Path -LiteralPath $SR_Projects)) {
        throw "no Claude projects folder at $SR_Projects - has claude ever run on this machine?"
    }

    # Transcripts older than this are not tracked at all. Without a bound, every
    # historical conversation on the machine would be tail-read on every scan.
    $regCutoff = (Get-Date).AddDays(-1 * [double]$Config.registryWindowDays)
    $found = @()

    foreach ($pdir in (Get-ChildItem -LiteralPath $SR_Projects -Directory -ErrorAction SilentlyContinue)) {
        $files = Get-ChildItem -LiteralPath $pdir.FullName -Filter *.jsonl -File -ErrorAction SilentlyContinue |
                 Where-Object { $_.Length -ge $SR_MinRealBytes -and $_.LastWriteTime -ge $regCutoff }
        foreach ($f in $files) {
            $stamp = "{0}:{1}" -f $f.LastWriteTimeUtc.Ticks, $f.Length

            $cwd = $null; $title = $null
            if ($Cache -and $Cache.ContainsKey($f.BaseName) -and $Cache[$f.BaseName].Stamp -eq $stamp) {
                $cwd   = $Cache[$f.BaseName].Cwd
                $title = $Cache[$f.BaseName].Title
            } else {
                $info  = Get-SRSessionInfo -JsonlPath $f.FullName
                $cwd   = $info.Cwd
                $title = $info.Title
            }

            if (-not $cwd) { continue }
            $cwd = $cwd.TrimEnd('\')
            if (-not (Test-Path -LiteralPath $cwd -PathType Container)) { continue }
            if (Test-SRExcluded -Path $cwd -Config $Config) { continue }
            if ([string]::IsNullOrWhiteSpace($title)) { $title = '(untitled)' }

            # A conversation belongs to its REPO, in one of two lanes. Worktree
            # conversations therefore sit under the parent repo rather than beside it
            # as a project of their own.
            $wt = Get-SRWorktreeInfo -Path $cwd
            if ($wt.Lane -eq 'worktree' -and -not $Config.includeWorktrees) { continue }

            $found += [PSCustomObject]@{
                RepoRoot   = $wt.RepoRoot
                Lane       = $wt.Lane
                Worktree   = $wt.Worktree
                Cwd        = $cwd
                SessionId  = $f.BaseName
                Jsonl      = $f.FullName
                LastActive = $f.LastWriteTime
                Title      = $title
                Stamp      = $stamp
            }
        }
    }

    # A session that changed directory mid-life exists under two project folders
    # with the SAME id; keep one row per id, the most recently written.
    return ,@($found |
        Group-Object -Property SessionId |
        ForEach-Object { $_.Group | Sort-Object LastActive -Descending | Select-Object -First 1 })
}

# ---------------------------------------------------------------------------
# Registry v2 -- directories, each holding its conversations.
# ---------------------------------------------------------------------------
function Get-SRRegistry {
    if (-not (Test-Path -LiteralPath $SR_RegistryPath)) {
        return [PSCustomObject]@{ version = 2; lastScan = $null; directories = @() }
    }
    try {
        $r = Get-Content -LiteralPath $SR_RegistryPath -Raw | ConvertFrom-Json
    } catch {
        throw "registry is unreadable ($SR_RegistryPath): $($_.Exception.Message). Delete it to start fresh."
    }

    # Migrate v1 (one flat entry per directory, carrying a single sessionId) rather
    # than discarding the operator's ticks.
    if ($null -ne $r.PSObject.Properties['entries'] -and $null -eq $r.PSObject.Properties['directories']) {
        $dirs = @()
        foreach ($e in @($r.entries)) {
            $sessions = @()
            if ($e.sessionId) {
                $sessions += [PSCustomObject]@{
                    sessionId  = $e.sessionId
                    title      = $e.title
                    enabled    = $true
                    lastActive = $e.lastActive
                    firstSeen  = $e.firstSeen
                }
            }
            $dirs += [PSCustomObject]@{
                path      = $e.path
                enabled   = [bool]$e.enabled
                firstSeen = $e.firstSeen
                missing   = [bool]$e.missing
                sessions  = $sessions
            }
        }
        $r = [PSCustomObject]@{ version = 2; lastScan = $r.lastScan; directories = $dirs }
        Write-SRLog "registry migrated v1 -> v2 ($(@($dirs).Count) directories)"
    }

    if ($null -eq $r.PSObject.Properties['directories']) {
        $r | Add-Member -NotePropertyName directories -NotePropertyValue @() -Force
    }

    # v2 -> v3: a project was keyed on the WORKING DIRECTORY, so each worktree was a
    # project of its own. v3 keys on the REPO and puts worktree conversations in a
    # second lane beneath it. Re-parent rather than rediscover: a fresh scan would
    # re-add these sessions as new and unticked, silently discarding every tick and
    # pin attached to them.
    if ([int]$r.version -lt 3) {
        $byRepo = @{}
        $keep   = @()
        foreach ($d in @($r.directories)) {
            if (-not $d.path) { continue }
            $wt = Get-SRWorktreeInfo -Path $d.path
            foreach ($s in @($d.sessions)) {
                foreach ($kv in @(
                    @{ n = 'cwd';      v = $d.path },
                    @{ n = 'lane';     v = $wt.Lane },
                    @{ n = 'worktree'; v = $wt.Worktree }
                )) {
                    if ($null -eq $s.PSObject.Properties[$kv.n]) {
                        $s | Add-Member -NotePropertyName $kv.n -NotePropertyValue $kv.v -Force
                    }
                }
            }

            $k = $wt.RepoRoot.ToLowerInvariant()
            if ($byRepo.ContainsKey($k)) {
                # Merge into the repo entry. A project that was ticked in either form
                # stays ticked -- never silently switch something off in a migration.
                $t = $byRepo[$k]
                $t.sessions = @($t.sessions) + @($d.sessions)
                if ($d.enabled) { $t.enabled = $true }
            } else {
                $d.path = $wt.RepoRoot
                $byRepo[$k] = $d
                $keep += $d
            }
        }
        $r = [PSCustomObject]@{ version = 3; lastScan = $r.lastScan; directories = $keep }
        Write-SRLog ("registry migrated v2 -> v3 ({0} project(s) after re-parenting worktrees)" -f @($keep).Count)
    }

    return $r
}

# 🪤 The registry is READ-MODIFY-WRITTEN by more than one process. The hourly
# ClaudeSessionScan task, a restore, and the panel all do it, and they overlap
# routinely -- the panel scans every time you open it. Without a lock the classic
# lost update applies: the scan reads, you tick something and save, the scan writes
# its copy back, and your tick is gone with nothing reported. Atomic replace does
# not help; it makes the LAST writer win cleanly rather than making both survive.
#
# A named mutex is re-entrant for the same thread, so Update-SRRegistry can hold it
# across its whole read-modify-write while Save-SRRegistry takes it again inside.
# Local\ (not Global\) -- this is per-user state and Global needs privileges.
$SR_RegistryMutexName = 'Local\MMToolbox.SessionRestore.Registry'

function Invoke-SRWithRegistryLock {
    param([Parameter(Mandatory)][scriptblock]$Body, [int]$TimeoutMs = 15000)
    $mutex = New-Object System.Threading.Mutex($false, $SR_RegistryMutexName)
    $held  = $false
    try {
        try { $held = $mutex.WaitOne($TimeoutMs) }
        catch [System.Threading.AbandonedMutexException] {
            # A previous holder died without releasing. We now own it; the registry
            # itself is fine because every write is an atomic replace.
            $held = $true
            Write-SRLog "registry lock was abandoned by a dead process - taken over"
        }
        if (-not $held) {
            # Fail OPEN rather than lose the operator's work. Fifteen seconds is far
            # longer than any scan takes, so this means something is wedged.
            Write-SRLog "registry lock timed out after ${TimeoutMs}ms - proceeding unlocked"
        }
        return (& $Body)
    } finally {
        if ($held) { $mutex.ReleaseMutex() }
        $mutex.Dispose()
    }
}

function Save-SRRegistry {
    param([Parameter(Mandatory)]$Registry)
    Invoke-SRWithRegistryLock -Body {
        $Registry.lastScan = (Get-Date).ToString('o')
        # Write beside the target then replace: a half-written registry would lose
        # every selection.
        $tmp = "$SR_RegistryPath.tmp"
        ($Registry | ConvertTo-Json -Depth 8) | Set-Content -LiteralPath $tmp -Encoding utf8
        Move-Item -LiteralPath $tmp -Destination $SR_RegistryPath -Force
    }
}

# Refresh the registry from disk. NEVER launches anything.
#
# A newly seen DIRECTORY arrives ticked if it was worked in within recencyDays.
# Within a directory, newly seen SESSIONS arrive ticked if they were active within
# sessionWindowDays -- but at most autoTickPerDirectory of them, newest first, so a
# repo with sixteen live conversations does not open sixteen tabs.
# Nothing is ever deleted: unticking is the operator's job.
#
# The lock spans the WHOLE read-modify-write, not just the write. Save-SRRegistry
# takes it again inside; a named mutex is re-entrant on one thread, so that nests
# safely. A thin wrapper rather than an indented body, so the diff that added
# locking stayed readable.
function Update-SRRegistry {
    param([Parameter(Mandatory)]$Config, [switch]$Quiet)
    return (Invoke-SRWithRegistryLock -Body { Update-SRRegistryCore -Config $Config -Quiet:$Quiet })
}

function Update-SRRegistryCore {
    param([Parameter(Mandatory)]$Config, [switch]$Quiet)

    $reg = Get-SRRegistry

    # Feed the previous scan's results back in. A transcript whose mtime and length
    # are unchanged does not get opened at all, so a repeat scan is nearly free --
    # which matters because this runs every hour.
    $cache = @{}
    foreach ($cd in @($reg.directories)) {
        foreach ($cs in @($cd.sessions)) {
            # cwd is required for a hit: a v2 entry has none, so it is re-read once
            # and cached from then on.
            if ($cs.sessionId -and $cs.stamp -and $cs.cwd) {
                $cache[$cs.sessionId] = @{ Cwd = $cs.cwd; Title = $cs.title; Stamp = $cs.stamp }
            }
        }
    }

    $disc = Get-SRDiscovered -Config $Config -Cache $cache
    $now  = (Get-Date).ToString('o')
    $dirCutoff  = (Get-Date).AddDays(-1 * [double]$Config.recencyDays)
    $sessCutoff = (Get-Date).AddDays(-1 * [double]$Config.sessionWindowDays)
    $autoTick   = [int]$Config.autoTickPerDirectory
    $autoTickWt = [int]$Config.autoTickPerWorktree

    $byDir = @{}
    foreach ($d in @($reg.directories)) { if ($d.path) { $byDir[$d.path.ToLowerInvariant()] = $d } }

    # A conversation belongs to exactly ONE project. Its home can legitimately change
    # -- it moves into a worktree, or an earlier scan filed it under a subfolder
    # before RepoRoot learned to walk up to the repo -- and registry entries are
    # never deleted, so without this the old row lingers forever: the same
    # conversation listed twice, one copy pointing at a project it has left.
    #
    # Collapse first, re-home second. Doing only the re-home appends the incoming
    # row to a project that may ALREADY hold one for that id, which turns a
    # cross-project duplicate into a same-project duplicate -- measured, exactly
    # that happened on the first attempt.
    $rowsById = @{}
    foreach ($d in @($reg.directories)) {
        foreach ($s in @($d.sessions)) {
            if (-not $s.sessionId) { continue }
            if (-not $rowsById.ContainsKey($s.sessionId)) { $rowsById[$s.sessionId] = @() }
            $rowsById[$s.sessionId] += $s
        }
    }
    $winnerOf = @{}
    $dupRows  = 0
    foreach ($id in @($rowsById.Keys)) {
        $all = @($rowsById[$id])
        if ($all.Count -eq 1) { $winnerOf[$id] = $all[0]; continue }
        # A PINNED row is an operator decision; an unpinned one is whatever the roll
        # last computed. So a single pinned copy wins outright and keeps its tick
        # VERBATIM -- including an unticked one.
        #
        # 🪤 Do NOT simply OR the ticks together here. Measured 2026-08-21: this
        # conversation was deliberately pinned-and-UNticked, its phantom duplicate
        # had been auto-ticked by the roll, and OR-ing silently overrode the
        # deliberate choice. Merging is only right between rows of equal standing.
        $pinned = @($all | Where-Object { $_.pinned })
        if (@($pinned).Count -eq 1) {
            $w = $pinned[0]
        } else {
            $w = @($all | Sort-Object { [datetime]$_.lastActive } -Descending)[0]
            # Equal standing: several pins, or none. Now a tick anywhere counts,
            # since losing one would silently drop a conversation from the restore.
            foreach ($o in $all) {
                if ([object]::ReferenceEquals($o, $w)) { continue }
                if ($o.enabled -and $null -ne $w.PSObject.Properties['enabled']) { $w.enabled = $true }
                if ($o.pinned) {
                    if ($null -eq $w.PSObject.Properties['pinned']) { $w | Add-Member -NotePropertyName pinned -NotePropertyValue $true -Force }
                    else { $w.pinned = $true }
                }
            }
        }
        $dupRows += (@($all).Count - 1)
        $winnerOf[$id] = $w
    }
    if ($dupRows -gt 0) {
        foreach ($d in @($reg.directories)) {
            $d.sessions = @(@($d.sessions) | Where-Object {
                (-not $_.sessionId) -or [object]::ReferenceEquals($winnerOf[$_.sessionId], $_)
            })
        }
        if (-not $Quiet) { Write-SRStep ("collapsed {0} duplicate conversation row(s) - one project per conversation" -f $dupRows) }
    }

    $ownerOf = @{}
    foreach ($d in @($reg.directories)) {
        foreach ($s in @($d.sessions)) { if ($s.sessionId) { $ownerOf[$s.sessionId] = $d } }
    }

    # Flag conversations whose transcript is no longer on disk. They are NOT deleted
    # -- a registry row carries the operator's tick, and deleting it is not the
    # scan's call -- but they can never be launched, so the panel has to SAY so
    # rather than offering a row that always refuses. Measured here: 5 of 98.
    # Done before the roll, so the auto-tick does not spend a lane's budget on a
    # conversation that cannot come back.
    $goneCount = 0
    foreach ($d in @($reg.directories)) {
        foreach ($s in @($d.sessions)) {
            if (-not $s.sessionId) { continue }
            $gcwd   = if ($s.cwd) { $s.cwd } else { $d.path }
            $isGone = -not (Test-Path -LiteralPath (Get-SRTranscriptPath -Dir $gcwd -SessionId $s.sessionId -Recorded $s.jsonl))
            if ($null -eq $s.PSObject.Properties['gone']) {
                $s | Add-Member -NotePropertyName gone -NotePropertyValue $isGone -Force
            } else { $s.gone = $isGone }
            if ($isGone) { $goneCount++ }
        }
    }
    if ($goneCount -and -not $Quiet) {
        Write-SRStep ("{0} conversation(s) have no transcript left on disk - shown as GONE, never launched" -f $goneCount)
    }

    $newDirs = 0; $newSessions = 0; $rolled = 0
    # Group by REPO, not by working directory: a worktree's conversations belong to
    # their parent repo, in the 'worktree' lane, rather than beside it as a project
    # of their own.
    $groups = $disc | Group-Object -Property { $_.RepoRoot.ToLowerInvariant() }

    foreach ($g in $groups) {
        $rows    = @($g.Group | Sort-Object LastActive -Descending)
        $dirPath = $rows[0].RepoRoot
        $key     = $g.Name

        if (-not $byDir.ContainsKey($key)) {
            $newest = $rows[0].LastActive
            $dir = [PSCustomObject]@{
                path      = $dirPath
                enabled   = ($newest -ge $dirCutoff)
                firstSeen = $now
                missing   = $false
                sessions  = @()
            }
            $reg.directories += $dir
            $byDir[$key] = $dir
            $newDirs++
            if (-not $Quiet) {
                Write-SRStep ("new project: {0} -> {1}" -f (Split-Path $dirPath -Leaf), $(if ($newest -ge $dirCutoff) { 'ticked' } else { 'unticked (older than recencyDays)' }))
            }
        }
        $dir = $byDir[$key]
        $dir.missing = $false

        # Re-home anything that used to live elsewhere, BEFORE $known is built, so
        # the moved row is the one that gets refreshed rather than a second copy.
        foreach ($r in $rows) {
            $prev = $ownerOf[$r.SessionId]
            if (-not $prev -or [object]::ReferenceEquals($prev, $dir)) { continue }
            $moved = @(@($prev.sessions) | Where-Object { $_.sessionId -eq $r.SessionId })[0]
            $prev.sessions = @(@($prev.sessions) | Where-Object { $_.sessionId -ne $r.SessionId })
            if ($moved) {
                $dir.sessions = @(@($dir.sessions) + $moved)
                $ownerOf[$r.SessionId] = $dir
                if (-not $Quiet) {
                    Write-SRStep ("moved: `"{0}`" {1} -> {2}" -f $moved.title, (Split-Path $prev.path -Leaf), (Split-Path $dir.path -Leaf))
                }
            }
        }

        $known = @{}
        foreach ($s in @($dir.sessions)) {
            if (-not $s.sessionId) { continue }
            # `pinned` arrives with this version; absent means auto-managed.
            if ($null -eq $s.PSObject.Properties['pinned']) {
                $s | Add-Member -NotePropertyName pinned -NotePropertyValue $false -Force
            }
            $known[$s.sessionId] = $s
        }

        foreach ($r in $rows) {
            if ($known.ContainsKey($r.SessionId)) {
                $s = $known[$r.SessionId]
                $s.lastActive = $r.LastActive.ToString('o')
                $s.title      = $r.Title
                # cwd/lane/worktree can all change under a session (it can be moved
                # into a worktree), so refresh them rather than trusting first sight.
                foreach ($kv in @(
                    @{ n = 'stamp';    v = $r.Stamp },
                    @{ n = 'cwd';      v = $r.Cwd },
                    @{ n = 'jsonl';    v = $r.Jsonl },
                    @{ n = 'lane';     v = $r.Lane },
                    @{ n = 'worktree'; v = $r.Worktree }
                )) {
                    if ($null -eq $s.PSObject.Properties[$kv.n]) {
                        $s | Add-Member -NotePropertyName $kv.n -NotePropertyValue $kv.v -Force
                    } else { $s.($kv.n) = $kv.v }
                }
                continue
            }
            # New conversations start auto-managed and unticked; the roll below
            # decides, so the rule lives in exactly one place.
            $dir.sessions += [PSCustomObject]@{
                sessionId  = $r.SessionId
                title      = $r.Title
                enabled    = $false
                pinned     = $false
                lastActive = $r.LastActive.ToString('o')
                firstSeen  = $now
                stamp      = $r.Stamp
                cwd        = $r.Cwd
                # Discovery walks real files, so a brand-new row's transcript exists
                # by construction.
                gone       = $false
                # The transcript's REAL path, as found on disk. Deriving it from cwd
                # later is wrong for any session that changed directory -- see
                # Get-SRTranscriptPath.
                jsonl      = $r.Jsonl
                lane       = $r.Lane
                worktree   = $r.Worktree
            }
            $newSessions++
        }

        # ROLLING AUTO-TICK, recomputed on every scan so the ticked set follows the
        # work rather than freezing at first discovery. Go back to an old slice and
        # it re-ticks itself; move on and it drops out.
        #
        # PINNED conversations -- the ones you touched in the picker -- are never
        # changed here. A pinned-and-ticked one spends part of the per-project
        # ceiling, so the total stays bounded whichever way it was set.
        # ...and it runs PER LANE GROUP. The main tree gets its own budget and so does
        # EACH worktree, because a worktree is a separate lane of work with its own
        # git index -- three from main plus three from every active lane, rather than
        # three for the whole repo where one busy lane would crowd out the others.
        $ordered = @($dir.sessions | Sort-Object { [datetime]$_.lastActive } -Descending)
        $laneGroups = $ordered | Group-Object -Property {
            if ($_.lane -eq 'worktree' -and $_.worktree) { 'wt:' + $_.worktree } else { 'main' }
        }

        foreach ($lg in $laneGroups) {
            $cap      = if ($lg.Name -eq 'main') { $autoTick } else { $autoTickWt }
            $members  = @($lg.Group)   # already newest-first, Group-Object keeps order
            $pinnedOn = @($members | Where-Object { $_.pinned -and $_.enabled }).Count
            $budget   = [Math]::Max(0, $cap - $pinnedOn)
            $taken    = 0
            $laneName = if ($lg.Name -eq 'main') { 'main' } else { $lg.Name.Substring(3) }

            foreach ($s in $members) {
                if ($s.pinned) { continue }
                # No transcript, no restore. Leave whatever tick it carries alone --
                # overriding the operator is not the roll's job -- but do not let it
                # consume budget a launchable conversation could use.
                if ($s.gone) { continue }
                $want = ((([datetime]$s.lastActive) -ge $sessCutoff) -and ($taken -lt $budget))
                if ($want) { $taken++ }
                if ([bool]$s.enabled -ne $want) {
                    $rolled++
                    if (-not $Quiet) {
                        Write-SRStep ("{0}/{1}: {2} -> {3}" -f (Split-Path $dir.path -Leaf), $laneName, $s.title, $(if ($want) { "ticked (newest $cap in this lane)" } else { 'unticked (fell out)' }))
                    }
                }
                $s.enabled = $want
            }
        }
    }

    # Mark directories whose path is gone, rather than dropping them.
    $seen = @{}
    # A project is keyed on its REPO root, so presence is judged on RepoRoot. This
    # read `.Path` until v3 renamed the field, and a discovery row's missing property
    # came back as $null -- which is how a rename turns into a null method call.
    foreach ($d in $disc) { if ($d.RepoRoot) { $seen[$d.RepoRoot.ToLowerInvariant()] = $true } }
    foreach ($d in @($reg.directories)) {
        if ($d.path -and -not $seen.ContainsKey($d.path.ToLowerInvariant())) {
            $d | Add-Member -NotePropertyName missing -NotePropertyValue $true -Force
        }
    }

    # Drop a project that this scan did not see AND that holds no conversations. It
    # can only be a husk -- a subfolder filed as a project before RepoRoot walked up,
    # or a project whose conversations have all been re-homed. It restores nothing,
    # and leaving it makes the panel list a repo with 0/0 forever.
    # Deliberately narrow: a project that still holds conversations keeps its row and
    # its tick, however missing it looks, because that tick is an operator decision.
    # Generated boot scripts are regenerated on demand, so an old one is pure litter.
    # The per-session ones (boot-<slug>-<id>.ps1) reuse their name and are bounded by
    # the number of conversations ever launched; the new-session ones carry a
    # timestamp and so would accumulate FOREVER, one per press of S.
    try {
        $nowDt = Get-Date
        foreach ($f in @(Get-ChildItem -LiteralPath $SR_StateDir -Filter 'boot-*.ps1' -File -ErrorAction SilentlyContinue)) {
            # A new-session script is consumed seconds after it is written.
            $maxAge = if ($f.Name -like 'boot-new-*') { 1 } else { 30 }
            if (($nowDt - $f.LastWriteTime).TotalDays -gt $maxAge) {
                Remove-Item -LiteralPath $f.FullName -Force -ErrorAction SilentlyContinue
            }
        }
    } catch { }

    $husks = @(@($reg.directories) | Where-Object { $_.missing -and -not @(@($_.sessions) | Where-Object { $_ }).Count })
    if ($husks.Count) {
        $reg.directories = @(@($reg.directories) | Where-Object { -not ($husks -contains $_) })
        if (-not $Quiet) {
            foreach ($h in $husks) { Write-SRStep ("dropped empty project: {0}" -f $h.path) }
        }
    }

    Save-SRRegistry -Registry $reg
    if (-not $Quiet) {
        $nd = @($reg.directories).Count
        $ns = @(@($reg.directories) | ForEach-Object { @($_.sessions) }).Count
        $np = @(@($reg.directories) | ForEach-Object { @($_.sessions) } | Where-Object { $_.pinned }).Count
        Write-SRStep ("registry: {0} project(s), {1} conversation(s) ({2} pinned); {3} new project(s), {4} new conversation(s), {5} auto-tick change(s)" -f $nd, $ns, $np, $newDirs, $newSessions, $rolled)
    }
    return $reg
}

# The flat list of what should actually reopen: enabled sessions inside enabled,
# present directories. Newest first.
function Get-SRSelected {
    param([Parameter(Mandatory)]$Registry, $Config, [switch]$IgnoreTicks)

    # Turning worktrees off must also silence what is ALREADY in the registry.
    # Entries are never deleted, so without this a session recorded while the toggle
    # was on would keep reopening after you switched it off.
    $wtOff = ($Config -and -not $Config.includeWorktrees)

    $out = @()
    foreach ($d in @($Registry.directories)) {
        if ($d.missing) { continue }
        if (-not $IgnoreTicks -and -not $d.enabled) { continue }
        foreach ($s in @($d.sessions)) {
            if ($wtOff -and $s.lane -eq 'worktree') { continue }
            if ($s.gone) { continue }
            if (-not $IgnoreTicks -and -not $s.enabled) { continue }
            # Path is the SESSION's own working directory, not the project root:
            # main and each worktree launch in different places.
            $cwd = if ($s.cwd) { $s.cwd } else { $d.path }
            $out += [PSCustomObject]@{
                Path       = $cwd
                Repo       = $d.path
                Lane       = $(if ($s.lane) { $s.lane } else { 'main' })
                Worktree   = $s.worktree
                SessionId  = $s.sessionId
                Title      = $s.title
                # The transcript as the scan actually found it. Callers must not
                # re-derive this from Path -- see Get-SRTranscriptPath.
                Jsonl      = $s.jsonl
                LastActive = [datetime]$s.lastActive
            }
        }
    }
    return ,@($out | Sort-Object LastActive -Descending)
}

# ---------------------------------------------------------------------------
# Guards
# ---------------------------------------------------------------------------

# The mtime guard only catches a session that is actively WRITING. A session idle at
# its prompt writes nothing. Sessions launched by this tool carry `--resume <id>` in
# their command line, so they are identifiable. Bare-`claude` sessions that later
# /resume'd carry no id -- hence both guards.
function Test-SRProcessRunning {
    param([Parameter(Mandatory)][string]$SessionId)
    foreach ($cl in (Get-SRClaudeCommandLines)) {
        if ($cl -like "*$SessionId*") { return $true }
    }
    return $false
}

# The same probe as a lookup table, for a UI that has to state the live/not-live of
# every row on every redraw. Test-SRProcessRunning is a substring scan per call --
# fine for a dozen launches in a row, wrong for 75 rows times every keystroke.
# Only sessions this tool launched carry their id on the command line, so a
# conversation someone /resume'd inside a bare `claude` still reads as not running.
function Get-SRRunningIds {
    param([switch]$Refresh)
    $ids = @{}
    $rx  = '[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}'
    foreach ($cl in (Get-SRClaudeCommandLines -Refresh:$Refresh)) {
        foreach ($m in [regex]::Matches($cl, $rx)) { $ids[$m.Value.ToLower()] = $true }
    }
    return $ids
}

function Test-SRTranscriptLive {
    param([Parameter(Mandatory)][string]$JsonlPath)
    if (-not (Test-Path -LiteralPath $JsonlPath)) { return $false }
    return (((Get-Date) - (Get-Item -LiteralPath $JsonlPath).LastWriteTime).TotalMinutes -lt $SR_LiveWindowMinutes)
}

# 🪤 Claude Code files a transcript under the directory the session was CREATED in
# and never moves it afterwards. Deriving the folder from the session's CURRENT cwd
# is therefore wrong for any conversation that changed directory mid-life -- and
# that is not exotic: the Bash tool's cwd persists between calls, so a session that
# cd's into a subfolder gets a new cwd written into its own transcript.
# Measured 2026-08-21: this very conversation resolved to
#   ...\C--Users-mauri-Documents-MM-toolbox-tools-session-restore\<id>.jsonl
# which does not exist, so the restore refused it as "transcript missing" and it had
# quietly stopped being restorable. The scan already knows the real path; prefer it,
# and keep the derivation only for registry rows written before `jsonl` existed.
function Get-SRTranscriptPath {
    param(
        [Parameter(Mandatory)][string]$Dir,
        [Parameter(Mandatory)][string]$SessionId,
        [string]$Recorded
    )
    # The recorded path must actually BELONG to this session. Trusting it on
    # existence alone would let a stale row vouch for someone else's transcript, and
    # the caller would then launch `--resume <id>` having verified the wrong file --
    # a guard that passes and a resume that fails.
    if ($Recorded -and
        ([System.IO.Path]::GetFileNameWithoutExtension($Recorded) -ieq $SessionId) -and
        (Test-Path -LiteralPath $Recorded)) { return $Recorded }
    return (Join-Path (Join-Path $SR_Projects (($Dir -replace '[^A-Za-z0-9]', '-'))) "$SessionId.jsonl")
}

# ---------------------------------------------------------------------------
# Launching
# ---------------------------------------------------------------------------

# Get-Command does NOT find wt.exe: it ships as a WindowsApps execution alias, a
# reparse point often absent from a child shell's PATH and from the thinner PATH a
# scheduled task inherits. Resolving by PATH alone failed here once already.
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

# Omit -SessionId to boot a NEW conversation instead of resuming one. Both cases
# have to go through here: a bare `claude` registers Remote Control against an
# EMPTY conversation and the device then shows "<hostname>-graceful-unicorn"
# forever, so -n / --remote-control are not optional on either path.
function New-SRBootScript {
    param(
        [Parameter(Mandatory)][string]$Dir,
        [string]$SessionId,
        [Parameter(Mandatory)][string]$Title,
        [string[]]$ClaudeArgs
    )
    if (-not (Test-Path -LiteralPath $SR_StateDir)) {
        New-Item -ItemType Directory -Path $SR_StateDir -Force | Out-Null
    }
    # The SESSION ID is part of the filename. Keying on the directory alone was fine
    # while only one conversation per tree could be restored; with several it would
    # have had them overwrite each other's boot script mid-launch.
    $slug = ((Split-Path $Dir -Leaf) -replace '[^A-Za-z0-9]', '-')
    if ($SessionId) {
        $boot = Join-Path $SR_StateDir ("boot-{0}-{1}.ps1" -f $slug, $SessionId.Substring(0, 8))
    } else {
        # A new session has no id yet, so there is nothing stable to key on. The
        # clock keeps two rapid-fire spawns in the same directory apart.
        $boot = Join-Path $SR_StateDir ("boot-new-{0}-{1}.ps1" -f $slug, (Get-Date -Format 'MMdd-HHmmss-fff'))
    }

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
__CLAUDELINE__
'@
    # Built out here, then substituted, so every value stays inside a PowerShell
    # single-quoted literal and no title can be re-parsed as syntax.
    $q = { param($v) "'" + ([string]$v).Replace("'", "''") + "'" }
    $parts = @('& claude')
    if ($SessionId) { $parts += @('--resume', (& $q $SessionId)) }
    $parts += @('-n', (& $q $Title), '--remote-control', (& $q $Title))
    foreach ($a in @($ClaudeArgs)) { if ($a) { $parts += (& $q $a) } }

    $body = $body.Replace('__SCRUBVARS__',  (($SR_ChildVars | ForEach-Object { "'" + $_ + "'" }) -join ','))
    $body = $body.Replace('__DIR__',        $Dir.Replace("'", "''"))
    $body = $body.Replace('__TITLE__',      $Title.Replace("'", "''"))
    $body = $body.Replace('__CLAUDELINE__', ($parts -join ' '))

    Set-Content -LiteralPath $boot -Value $body -Encoding utf8
    return $boot
}

# 🪤 `Start-Process -ArgumentList @(...)` JOINS THE ARRAY WITH SPACES AND QUOTES
# NOTHING. Measured 2026-08-18 by dumping the receiver's argv: a directory under
# "Trading Bot" arrived as
#     -d  [C:\Users\mauri\Documents\Trading]  +  a stray [Bot\Python\...\D2]
# so wt.exe took the fragment as the command to RUN and every AlgoTrader tab died
# with 0x80070002 while space-free repos launched fine. 🔑 The tell in that error is
# that the failing command line starts MID-PATH.
# A single STRING is forwarded verbatim instead, so quote each argument ourselves.
function ConvertTo-SRArg {
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Value)
    # CommandLineToArgvW rules, which is how both wt.exe and powershell.exe build
    # their argv: a backslash is literal EXCEPT in the run immediately preceding a
    # quote (the closing one included), where each must be doubled; an embedded
    # quote becomes \".
    $e = [regex]::Replace($Value, '(\\*)"', '$1$1\"')
    $e = [regex]::Replace($e,     '(\\+)$', '$1$1')
    return '"' + $e + '"'
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
    # wt splits its OWN argv on a bare ';' to begin a second command, and quoting
    # does not take that away. ';' is legal in a Windows path but effectively never
    # present -- so refuse rather than launch something nobody asked for. A title is
    # cosmetic, so that one is sanitised instead of thrown on.
    foreach ($p in @($Dir, $BootScript)) {
        if ($p -like '*;*') { throw "Refusing to launch: ';' in a path is a command separator to wt.exe -- $p" }
    }
    $cmdline = @(
        '-w', '0', 'new-tab',
        '--title', (ConvertTo-SRArg ($Title -replace ';', ',')),
        '-d',      (ConvertTo-SRArg $Dir),
        'powershell.exe', '-NoExit', '-NoProfile', '-ExecutionPolicy', 'Bypass',
        '-File',   (ConvertTo-SRArg $BootScript)
    ) -join ' '
    Start-Process -FilePath $wt -ArgumentList $cmdline | Out-Null
}
