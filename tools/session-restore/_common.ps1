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
function Write-SRWarn { param([string]$m) Write-Host "  [warn] $m" -ForegroundColor Yellow;     Write-SRLog "  [warn] $m" }

function Clear-SRChildEnv {
    foreach ($v in $SR_ChildVars) {
        if (Test-Path "Env:$v") { Remove-Item "Env:$v" -ErrorAction SilentlyContinue }
    }
}

# ---------------------------------------------------------------------------
# Config
# ---------------------------------------------------------------------------
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

function Save-SRRegistry {
    param([Parameter(Mandatory)]$Registry)
    $Registry.lastScan = (Get-Date).ToString('o')
    # Write beside the target then replace: a half-written registry would lose every
    # selection.
    $tmp = "$SR_RegistryPath.tmp"
    ($Registry | ConvertTo-Json -Depth 8) | Set-Content -LiteralPath $tmp -Encoding utf8
    Move-Item -LiteralPath $tmp -Destination $SR_RegistryPath -Force
}

# Refresh the registry from disk. NEVER launches anything.
#
# A newly seen DIRECTORY arrives ticked if it was worked in within recencyDays.
# Within a directory, newly seen SESSIONS arrive ticked if they were active within
# sessionWindowDays -- but at most autoTickPerDirectory of them, newest first, so a
# repo with sixteen live conversations does not open sixteen tabs.
# Nothing is ever deleted: unticking is the operator's job.
function Update-SRRegistry {
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

function Test-SRTranscriptLive {
    param([Parameter(Mandatory)][string]$JsonlPath)
    if (-not (Test-Path -LiteralPath $JsonlPath)) { return $false }
    return (((Get-Date) - (Get-Item -LiteralPath $JsonlPath).LastWriteTime).TotalMinutes -lt $SR_LiveWindowMinutes)
}

function Get-SRTranscriptPath {
    param([Parameter(Mandatory)][string]$Dir, [Parameter(Mandatory)][string]$SessionId)
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

function New-SRBootScript {
    param(
        [Parameter(Mandatory)][string]$Dir,
        [Parameter(Mandatory)][string]$SessionId,
        [Parameter(Mandatory)][string]$Title
    )
    if (-not (Test-Path -LiteralPath $SR_StateDir)) {
        New-Item -ItemType Directory -Path $SR_StateDir -Force | Out-Null
    }
    # The SESSION ID is part of the filename. Keying on the directory alone was fine
    # while only one conversation per tree could be restored; with several it would
    # have had them overwrite each other's boot script mid-launch.
    $slug = ((Split-Path $Dir -Leaf) -replace '[^A-Za-z0-9]', '-')
    $boot = Join-Path $SR_StateDir ("boot-{0}-{1}.ps1" -f $slug, $SessionId.Substring(0, 8))

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
