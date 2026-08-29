#requires -Version 5.1
<#
    Shared internals for session-restore. Dot-sourced by restore-sessions.ps1 and
    sessions-gui.ps1 so discovery, the registry and the guards exist ONCE.

    Defines functions and paths only -- it must never do work on load.

    REGISTRY v2: directories, each holding its conversations. The directory has a
    master tick and every session under it has its own, so you can switch off a whole
    project or drop a single finished slice.
#>

# $PSScriptRoot inside a dot-sourced file is THAT file's directory, and it is
# resolved in the body rather than in a param default -- which is empty under
# `powershell.exe -File` and cost a silent morning failure once already.
# 🔴 THE SCRIPTS LIVE IN lib\, THE TOOL DOES NOT. Everything the operator owns
# -- .state, the config, and above all sessions-registry.json -- is anchored to
# SR_Root, so leaving it as this file's own directory would have silently moved
# the registry into lib\ the moment the scripts were tidied away, and the next
# scan would have found no selections at all.
$SR_Root       = $PSScriptRoot
if ((Split-Path -Leaf $SR_Root) -eq 'lib') { $SR_Root = Split-Path -Parent $SR_Root }

# WHERE THE SOURCES ARE, which is no longer where the tool is. Anything that has
# to hand a SCRIPT PATH to another process needs this rather than $SR_Root -- and
# getting that wrong is silent, because the child simply fails to dot-source and
# comes back empty. It cost the whole relay: Get-SRScreenText builds a throwaway
# script that dot-sources _common.ps1, and with $SR_Root it pointed at a file
# that is one directory up from where it now lives.
$SR_LibDir     = $PSScriptRoot
$SR_Projects   = Join-Path $env:USERPROFILE '.claude\projects'
$SR_StateDir   = Join-Path $SR_Root '.state'
$SR_LogPath    = Join-Path $SR_StateDir 'restore.log'
$SR_ConfigPath = Join-Path $SR_Root 'session-restore.config.json'

# The registry is the OPERATOR'S selection and is NOT disposable, so it lives beside
# the scripts rather than inside .state/ (which holds regenerated junk). Gitignored:
# the paths in it are specific to this machine.
$SR_RegistryPath = Join-Path $SR_Root 'sessions-registry.json'

# 🔴 THIS WAS A BYTE FLOOR OF 5000, AND IT THREW AWAY REAL CONVERSATIONS.
#
# It was justified by a Remote Control placeholder -- a lone bridge-session line,
# 118 bytes -- and then set FORTY-TWO TIMES higher than the thing it was measuring.
# Measured on the operator's machine 2026-08-24, three transcripts under the floor:
#
#     ece892a8   270 B   1 bridge-session record, NO cwd     <- a real placeholder
#     49674e61 1,544 B   6 records, a cwd, mode, last-prompt <- a real session
#     860df09e 3,191 B  10 records, THREE user messages      <- a real conversation
#
# and it was backwards on top of that: the two real ones were missing from the
# registry while the placeholder was in it. A newly spawned session writes a small
# transcript, which is exactly when the operator looks for it in the window and
# exactly when this hid it. THE TOOL HAS TO FIND EVERY SESSION IT LAUNCHES.
#
# The floor is now only what it was ever supposed to be: below any plausible real
# transcript, and above nothing. What actually separates a placeholder from a
# conversation is SEMANTIC and already enforced a few lines further down -- a
# placeholder has no `cwd`, so Get-SRDiscovered drops it on that test rather than
# on its size. Keep both: the byte test is a cheap skip for the 118-byte case, and
# the cwd test is the one that is actually true.
$SR_MinRealBytes = 200

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
        # HOW MANY DAYS THE GUI'S "All" LIST SHOWS. registryWindowDays bounds
        # what is TRACKED (30); nothing bounded what was SHOWN, so the list ran
        # to 143 conversations of which 51 were between a week and a month old.
        # Nothing is hidden silently: what falls outside is counted on a row at
        # the end of the list, and a search reaches past it regardless.
        @{ k = 'listDays';             v = 7  },
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

    $cwd = $null; $title = $null; $aiTitle = $null
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

        # 🔴 THE NAME WAS ALWAYS IN THIS BUFFER AND NOBODY LOOKED AT IT.
        #
        # claude writes TWO title records: customTitle, which -n and a rename set,
        # and aiTitle, which it generates for every conversation from what the
        # conversation is about. This function read only the first, so a session
        # started without -n was called "(untitled)" forever -- 97 of 204 in the
        # operator's registry, which is what made the roster read as an endless
        # list of nothing.
        #
        # Measured across those 97 on 2026-08-26: 76 carry an aiTitle, 4 a
        # customTitle, 17 neither. Every one of the 76 has its last aiTitle inside
        # the tail ALREADY READ ABOVE, so this costs one more regex over a string
        # in memory and no additional I/O at all.
        #
        # They are kept APART on purpose and merged nowhere near here. customTitle
        # is a name somebody CHOSE; aiTitle is a guess. The guess is allowed to
        # fill an empty label and is never allowed to overwrite a chosen one --
        # see autoTitle in Update-SRRegistryCore, and 087c5f0 for what happens
        # when a derived name is let into the field the operator owns.
        $m = [regex]::Matches($text, '"aiTitle":"(.*?)(?<!\\)"')
        if ($m.Count) { $aiTitle = $m[$m.Count - 1].Groups[1].Value.Replace('\\', '\').Replace('\"', '"') }

        # A transcript may hold its cwd only near the top. If the tail had none, read
        # the whole file -- but ONLY when it is small. Without the size bound this
        # fallback would pull a 100 MB file into memory, reintroducing exactly the
        # unbounded cost this function was rewritten to remove.
        #
        # 🔴 THIS BRIEFLY ALSO CHASED aiTitle, AND IT WAS A PURE COST. The reasoning
        # was sound -- the title record sits at a MEDIAN 14.3% into the file, so on
        # anything over about 2 MB it is nowhere near the tail -- and the measurement
        # disagreed: the registry named exactly 60 conversations with the fallback
        # and exactly 60 without it. Every candidate it could have helped belonged
        # to a project whose folder had been deleted, so discovery refuses them
        # before this function is ever called.
        #
        # What it did do was make an UNCACHED walk read whole files for every
        # conversation that has no aiTitle at all, which is most of them once the
        # ones that have one are cached. That walk consults the agent list at the
        # end, and the agent cache has a FIVE SECOND life -- so the walk got slow
        # enough to evict the very thing the walk was about to read. It cost a
        # correct test its pass and gained nothing measurable.
        #
        # Widen this again only with a measurement in hand.
        $full = (Get-Item -LiteralPath $JsonlPath).Length
        if (-not $cwd -and $take -lt $full -and $full -le 8MB) {
            $all = [System.IO.File]::ReadAllText($JsonlPath)
            $m = [regex]::Matches($all, '"cwd":"(.*?)(?<!\\)"')
            if ($m.Count) { $cwd = $m[$m.Count - 1].Groups[1].Value.Replace('\\', '\').Replace('\"', '"') }
        }
    } catch { }

    return [PSCustomObject]@{ Cwd = $cwd; Title = $title; AiTitle = $aiTitle }
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

    # 🔴 THE HOME DIRECTORY IS A PLACE PEOPLE WORK. This used to return $true here,
    # on the reasoning that Claude Code makes a transcript folder for ~ the moment
    # anyone runs `claude` from it, so ~ 'is never a project'. That was an assumption
    # about how the operator works, and it was wrong.
    #
    # Measured 2026-08-24 across 290 transcripts: FIVE have ~ as their cwd, and three
    # of those are 28 MB, 22 MB and 20 MB. The rule hid three substantial
    # conversations to save two small ones, and none of them had ever appeared in the
    # window. The requirement is not negotiable -- the tool has to find every session
    # it launches -- and five extra rows is not noise worth that.
    #
    # Genuinely empty transcripts are still dropped: a placeholder has no `cwd` at
    # all, which Get-SRDiscovered tests a few lines down. Size and location were
    # always the wrong questions.
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

            $cwd = $null; $title = $null; $autoTitle = $null

            # 🪤 THREE STATES, NOT TWO, AND THE MIGRATION TURNS ON THE THIRD.
            #
            #   $null  nobody has looked yet   -- re-read, and never written back
            #   ''     looked, there is none   -- a real answer; stops the re-read
            #   text   the name
            #
            # Without the empty-string state this was a no-op. The cache is keyed
            # on mtime+length, a repeat scan is nearly all hits by design, and the
            # first scan after autoTitle shipped hit on all 204 -- so it carried
            # forward a $null that had never been read from anything, and named
            # exactly zero conversations. Requiring the field to be PRESENT for a
            # hit re-reads each transcript once, which is the same one-time
            # migration `cwd` above already does for v2 entries, and the 17
            # conversations that genuinely have no aiTitle record that fact rather
            # than being re-read on every scan forever.
            $hit = ($Cache -and $Cache.ContainsKey($f.BaseName) -and
                    $Cache[$f.BaseName].Stamp -eq $stamp -and
                    $null -ne $Cache[$f.BaseName].AutoTitle)
            if ($hit) {
                $cwd       = $Cache[$f.BaseName].Cwd
                $title     = $Cache[$f.BaseName].Title
                $autoTitle = $Cache[$f.BaseName].AutoTitle
            } else {
                $info      = Get-SRSessionInfo -JsonlPath $f.FullName
                $cwd       = $info.Cwd
                $title     = $info.Title
                $autoTitle = "$($info.AiTitle)"   # never $null: we looked
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
                AutoTitle  = $autoTitle
                Stamp      = $stamp
            }
        }
    }

    # 🔴 A SESSION THAT HAS NEVER BEEN PROMPTED HAS NO TRANSCRIPT AT ALL.
    #
    # claude writes the .jsonl on the FIRST MESSAGE, so a window you have just
    # opened and not yet typed into is invisible to a walk over transcripts -- while
    # `claude agents --json` has known about it since it started, with its pid, its
    # cwd and its name. Measured 2026-08-24: a session launched and left at its
    # prompt was reported by the agent list, had no transcript anywhere on disk, and
    # appeared nowhere in the tool.
    #
    # THE SECOND SOURCE. The requirement is that the tool finds every session it
    # launches, and one source cannot meet it: the transcript knows what a
    # conversation SAID, the agent list knows what is RUNNING, and a session can be
    # one without the other. This pass is only ever ADDITIVE -- anything already
    # found on disk keeps its transcript-derived row, because that row knows more.
    #
    # Get-SRAgentStatus returns an empty map when claude cannot be asked, so this
    # degrades to exactly the old behaviour rather than throwing.
    $seenIds = @{}
    foreach ($r in $found) { $seenIds["$($r.SessionId)".ToLower()] = $true }
    foreach ($kv in (Get-SRAgentStatus).GetEnumerator()) {
        $a = $kv.Value
        if (-not $a -or -not $a.Cwd) { continue }
        if ($seenIds[[string]$kv.Key]) { continue }
        $acwd = "$($a.Cwd)".TrimEnd('')
        if (-not (Test-Path -LiteralPath $acwd -PathType Container)) { continue }
        if (Test-SRExcluded -Path $acwd -Config $Config) { continue }
        $awt = Get-SRWorktreeInfo -Path $acwd
        if ($awt.Lane -eq 'worktree' -and -not $Config.includeWorktrees) { continue }
        $found += [PSCustomObject]@{
            RepoRoot   = $awt.RepoRoot
            Lane       = $awt.Lane
            Worktree   = $awt.Worktree
            Cwd        = $acwd
            SessionId  = [string]$kv.Key
            Jsonl      = (Get-SRTranscriptPath -Dir $acwd -SessionId ([string]$kv.Key))
            LastActive = $(if ($a.StartedAt) { $a.StartedAt } else { Get-Date })
            Title      = $(if ($a.Name) { "$($a.Name)" } else { '(untitled)' })
            # A session known only from the agent list has written no transcript,
            # so there is no aiTitle to derive one from yet. Stated rather than
            # left missing: every other row in $found carries this property, and a
            # shape that varies by branch is how a $null becomes an exception
            # somewhere that never expected the difference.
            AutoTitle  = $null
            # Not an mtime+length: there is no file. Keyed on the pid so the row is
            # re-read once the session actually writes something.
            Stamp      = "agent:$($a.Pid)"
        }
    }
    # A session that changed directory mid-life exists under two project folders
    # with the SAME id; keep one row per id, the most recently written.
    # 🪤 A PLAIN ARRAY. This returned ",@(...)" -- the EIGHTH comma-wrapped return in
    # this codebase -- which makes @(Get-SRDiscovered ...) a ONE-ELEMENT array holding
    # every conversation. The one production caller assigns before wrapping and was
    # unaffected, so it sat here harmlessly until a new caller used the obvious form
    # and got a count of 1 out of 189. Assign-then-wrap still works against a plain
    # array, so nothing that was correct becomes incorrect.
    $rows = @($found |
        Group-Object -Property SessionId |
        ForEach-Object { $_.Group | Sort-Object LastActive -Descending | Select-Object -First 1 })
    return $rows
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
                $cache[$cs.sessionId] = @{
                    Cwd = $cs.cwd; Title = $cs.title; Stamp = $cs.stamp
                    # Carried so a cache hit keeps the derived name. A scan is
                    # nearly all cache hits by design, so omitting this would blank
                    # almost every derived name on the very next pass.
                    AutoTitle = $cs.autoTitle
                }
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

                # 🔴 A SCAN MUST NOT RENAME A CONVERSATION TO "(untitled)".
                #
                # This was an unconditional `$s.title = $r.Title`. Discovery emits
                # the sentinel "(untitled)" whenever a transcript carries no
                # customTitle -- so every scan overwrote a name the operator had
                # given the session with the placeholder, unless -n happened to
                # have written a customTitle into the transcript itself. That is
                # the same class of mistake as 087c5f0, where a relaunch undid the
                # operator's own renames, and it is why he reported losing every
                # name after reconnecting remote control.
                #
                # A real discovered title still wins -- renaming a session with -n
                # must still show up here. The sentinel just no longer counts as
                # one.
                if ("$($r.Title)" -and "$($r.Title)" -ne '(untitled)') { $s.title = $r.Title }

                # autoTitle is claude's own generated name, kept in its OWN field so
                # that choosing what to display happens once, at the point of
                # display, and is never a guess that has already overwritten the
                # operator's answer.
                #
                # ONLY WHEN SOMEBODY LOOKED. $null means no transcript was read --
                # a row from the agent list has none -- and writing that back would
                # blank a name derived on an earlier pass, so the row would lose
                # its name the moment the session started running, which is the
                # moment the operator is most likely to be looking at it. An EMPTY
                # STRING is a real answer ("read it, there is no aiTitle") and is
                # stored, because that is what stops the transcript being re-read
                # on every scan from here on.
                if ($null -ne $r.AutoTitle) {
                    if ($null -eq $s.PSObject.Properties['autoTitle']) {
                        $s | Add-Member -NotePropertyName autoTitle -NotePropertyValue $r.AutoTitle -Force
                    } else { $s.autoTitle = $r.AutoTitle }
                }

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
                # claude's own name for the conversation, or $null. Never merged
                # into `title`: that field belongs to whoever named the session.
                autoTitle  = $r.AutoTitle
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
        # 🪤 A TICK INSIDE A SWITCHED-OFF PROJECT CANNOT FIRE, because the restore
        # consults the project before it ever looks at a conversation. Rolling ticks
        # here manufactured exactly the state that cost the operator every AlgoTrader
        # lane on 2026-08-24: 89 pinned conversations in a project that was off, no
        # sign of it on any row, and a logon that restored none of them.
        #
        # 🔑 Ticking BY HAND turns the project on -- Set-RowTick does that deliberately,
        # because that is what the operator meant. The ROLL must not, or a project
        # switched off on purpose would switch itself back on the next time anything
        # in it was touched. So it leaves a disabled project entirely alone rather
        # than writing ticks into it that can never launch.
        if (-not $dir.enabled) { continue }

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

# 🪤 THESE FUNCTIONS RETURN `,@(...)` AND THAT CHANGES HOW YOU MAY CALL THEM.
# The leading comma stops PowerShell unrolling an empty or single-item result into
# $null or a scalar. The cost is that the ONLY safe call shape is:
#
#     $x = Get-Thing ...        # direct assignment, then @($x) wherever you need
#
# NOT `@(Get-Thing ...)` and NOT `Get-Thing ... | ForEach-Object`. Both hand you the
# array wrapped in one more layer. Measured 2026-08-21: `@(Get-LiveInDirectory $p)`
# came back Count 1 for a directory with nothing live, and piping Get-RowSessions
# gave ForEach-Object every session as a single item -- so `L` on a project row
# built one entry holding the whole set. Neither failed loudly; both just did the
# wrong thing.
#
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
                # THE NAME THIS SESSION WILL REOPEN UNDER, and it must not be the
                # placeholder. This feeds --title, -n and the remote-control name
                # prefix, so a session whose title is the "(untitled)" sentinel used
                # to come back as a tab called "(untitled)" and register remotely
                # under the same -- which is exactly the complaint that over twenty
                # reconnected sessions were unidentifiable.
                #
                # A chosen name still wins. This only fills in where there was
                # nothing to show, and claude's own generated title is a far better
                # answer than the placeholder for every one of the 76 conversations
                # measured as having one.
                Title      = $(
                    if ("$($s.title)".Trim() -and "$($s.title)".Trim() -ne '(untitled)') { $s.title }
                    elseif ("$($s.autoTitle)".Trim()) { $s.autoTitle }
                    else { $s.title }
                )
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

# How many claude.exe are running that we CANNOT attribute to a conversation.
# A bare `claude` with a conversation picked from /resume carries neither
# --resume nor --session-id, so nothing on its command line says which one it
# holds. Reporting the number is the honest alternative to pretending LIVE is
# complete: it turns "some sessions are invisible" into a figure you can see.
function Get-SRUnattributedCount {
    param([switch]$Refresh)
    $rx = '[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}'
    $n = 0
    foreach ($cl in (Get-SRClaudeCommandLines -Refresh:$Refresh)) {
        if (-not [regex]::IsMatch($cl, $rx)) { $n++ }
    }
    return $n
}

# Did the tabs we opened actually come up?
#
# 🪤 A launch reported [ok] the moment Start-Process returned, which says only that
# wt.exe STARTED -- not that claude did. Every AlgoTrader tab once died on a quoting
# bug while the restore logged [ok] and the scheduled task returned 0. Success was
# unfalsifiable, which is worse than a failure you can see.
#
# Polls the process table until each id appears or the timeout expires. Returns the
# ids that never showed. Verification only: it launches and fixes nothing.
function Wait-SRSessionsUp {
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][string[]]$SessionIds,
        [int]$TimeoutSec = 75,
        [int]$PollMs = 2000
    )
    $want = @($SessionIds | Where-Object { $_ })
    if (-not $want.Count) { return ,@() }

    $deadline = (Get-Date).AddSeconds($TimeoutSec)
    while ($true) {
        $up = Get-SRRunningIds -Refresh
        $missing = @($want | Where-Object { -not $up[$_.ToLower()] })
        if (-not $missing.Count) { return ,@() }
        if ((Get-Date) -ge $deadline) { return ,@($missing) }
        Start-Sleep -Milliseconds $PollMs
    }
}

function Test-SRTranscriptLive {
    param([Parameter(Mandatory)][string]$JsonlPath)
    if (-not (Test-Path -LiteralPath $JsonlPath)) { return $false }
    return (((Get-Date) - (Get-Item -LiteralPath $JsonlPath).LastWriteTime).TotalMinutes -lt $SR_LiveWindowMinutes)
}

# --- jumping to a session's terminal tab ------------------------------------
# Every session this tool launches is a TAB, because Start-SRSession uses
# "-w 0 new-tab". Measured 2026-08-22: 13 live claude.exe, every one of them a
# descendant of a single WindowsTerminal.exe -- which is precisely the "clicking
# through the tabs to see if anything moved" that this view exists to end.
#
# HOW THE TAB IS FOUND, and one correction worth recording because it changed
# the design twice:
#
#   A first probe concluded "Windows Terminal exposes only the ACTIVE tab to UI
#   Automation" -- 13 tabs open, ControlType.TabItem x1 -- and an entire
#   focus-by-index-then-verify scheme was designed around that. IT WAS WRONG.
#   The probe used RootElement.FindFirst(Children, <pid>), which returns the
#   FIRST window belonging to that process, and one process hosts MANY windows:
#   there are 6 here, with 2, 6, 5, 1, 1 and 1 tabs. It had found a one-tab
#   window and generalised from it.
#
#   Enumerate the windows properly and UIA lists every tab in each, with a
#   working SelectionItemPattern. Selecting a non-active tab switches to it in
#   ~400 ms, measured. So there is no index arithmetic, no `wt focus-tab`, and
#   nothing to guess: find the tab by name, select it, raise its window.
#
# The tab title is what Start-SRSession passed to --title, with a status glyph
# prepended by claude ("*", a half-circle, and so on), so the comparison strips
# leading non-alphanumerics and then matches exactly. Exactly, not "contains":
# "I6" is a prefix of "I6b", and landing in the wrong conversation is the one
# outcome worth writing extra code to avoid.
if (-not ('SRWin' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.Text;
using System.Collections.Generic;
using System.Runtime.InteropServices;
public static class SRWin {
    public delegate bool EnumProc(IntPtr h, IntPtr l);
    [DllImport("user32.dll")] public static extern bool EnumWindows(EnumProc cb, IntPtr l);
    [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
    [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr h);
    [DllImport("user32.dll")] public static extern int GetWindowTextLength(IntPtr h);
    [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr h);
    [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr h, int cmd);
    [DllImport("user32.dll")] public static extern bool IsIconic(IntPtr h);

    // Visible, titled, top-level windows owned by a process. A single
    // WindowsTerminal.exe owns one per terminal window, which is the fact the
    // first probe missed.
    public static IntPtr[] WindowsOf(uint want) {
        List<IntPtr> o = new List<IntPtr>();
        EnumWindows(delegate(IntPtr h, IntPtr l) {
            uint pid; GetWindowThreadProcessId(h, out pid);
            if (pid == want && IsWindowVisible(h) && GetWindowTextLength(h) > 0) o.Add(h);
            return true;
        }, IntPtr.Zero);
        return o.ToArray();
    }

    public static void Raise(IntPtr h) {
        if (IsIconic(h)) ShowWindow(h, 9);   // SW_RESTORE
        SetForegroundWindow(h);
    }
}
'@
}

# Strip the status glyph claude puts in front of a tab title, and any stray
# whitespace, leaving the name the tab was created with.
function Get-SRTabName {
    param([string]$Raw)
    $s = "$Raw"
    # Leading run of anything that is not a letter, digit, '(' or '['. The glyphs
    # vary with what the session is doing and are not a fixed set.
    $s = [regex]::Replace($s, '^[^\p{L}\p{N}\(\[]+', '')
    return $s.Trim()
}

# A TAB TITLE IS NOT STABLE, which is why the cache below exists.
#
# Measured 2026-08-22: this session's tab read '<glyph> RC-WORKFLOW' at one
# moment and plain 'claude' a minute later. A console title belongs to whatever
# is currently attached to the console, so while a session runs a child process
# the tab can be named after that process instead of the conversation. That is
# precisely when you want to jump to it.
#
# So the name is only the way the tab is FOUND THE FIRST TIME. What is kept is
# the UIA element, whose identity survives a rename -- verified by runtime id
# across a re-enumeration. A jump then goes to the tab itself rather than to
# whatever currently happens to carry the right label.
$script:SR_TabIndex = @{}

# Match live tabs against a table of sessionId -> title and remember the
# ELEMENT for each one matched. Cheap to call, ~250-500 ms measured for 16 tabs
# across 6 windows, so it belongs on a slow refresh and never on a click.
function Update-SRTabIndex {
    param([Parameter(Mandatory)][hashtable]$Titles)
    $tabs = Get-SRTerminalTabs
    $tabs = @($tabs)
    if (-not $tabs.Count) { return 0 }
    $n = 0
    foreach ($id in @($Titles.Keys)) {
        $want = "$($Titles[$id])".Trim()
        if (-not $want) { continue }
        $hit = @($tabs | Where-Object { $_.Name -eq $want })
        if (-not $hit.Count) { $hit = @($tabs | Where-Object { $_.Name -ieq $want }) }
        # Exactly one, or it is not an identification. Two tabs sharing a title
        # were measured on this machine, and guessing between two live
        # conversations is the one thing this must not do quietly.
        if ($hit.Count -eq 1) {
            $script:SR_TabIndex["$id".ToLower()] = $hit[0]
            $n++
        }
    }
    return $n
}

# Every Windows Terminal tab on this machine, as {Hwnd, Name, Element}.
# RETURNS ",@(...)": assign it, then wrap. Writing "@(Get-SRTerminalTabs)" in one
# step yields an array of ONE element holding all sixteen tabs, whose .Name is
# then every tab name at once. That is not hypothetical -- it is how the first
# version of jump-driver.ps1 came to report all 16 tabs as the active one.
function Get-SRTerminalTabs {
    $out = New-Object System.Collections.Generic.List[object]
    try {
        Add-Type -AssemblyName UIAutomationClient, UIAutomationTypes -ErrorAction Stop
    } catch {
        Write-SRLog "jump: UI Automation is unavailable - $($_.Exception.Message)"
        return ,@($out.ToArray())
    }
    $procs = @(Get-Process WindowsTerminal -ErrorAction SilentlyContinue)
    foreach ($p in $procs) {
        foreach ($h in [SRWin]::WindowsOf([uint32]$p.Id)) {
            $el = $null
            try { $el = [System.Windows.Automation.AutomationElement]::FromHandle($h) } catch { }
            if (-not $el) { continue }
            $cond = New-Object System.Windows.Automation.PropertyCondition(
                [System.Windows.Automation.AutomationElement]::ControlTypeProperty,
                [System.Windows.Automation.ControlType]::TabItem)
            $tabs = $null
            try { $tabs = $el.FindAll([System.Windows.Automation.TreeScope]::Descendants, $cond) } catch { continue }
            foreach ($t in $tabs) {
                $out.Add([PSCustomObject]@{
                    Hwnd    = $h
                    Raw     = "$($t.Current.Name)"
                    Name    = (Get-SRTabName "$($t.Current.Name)")
                    Element = $t
                })
            }
        }
    }
    return ,@($out.ToArray())
}

# ---------------------------------------------------------------------------
# Close the terminal TABS belonging to sessions that have just been killed.
#
# 🔴 KILLING THE PROCESSES DOES NOT CLOSE THE TAB, and for a long time this tool
# assumed it did. Stop-SRSessions kills claude.exe and then its boot shell, on
# the reasoning that a tab dies with its root process. Measured 2026-08-28 on the
# operator's machine after one relaunch: 40 tabs for 18 live sessions -- every
# one of 14 conversations had TWO tabs, the dead one and the new one, all in a
# single window. The relaunch had honestly reported "closed 15 session(s)"; the
# processes were gone and the tabs were not. The parent kill was additionally
# wrapped in -ErrorAction SilentlyContinue, so a failure there could never be
# seen.
#
# So the tab is closed EXPLICITLY, through the close button UI Automation exposes
# on it, rather than as a hoped-for consequence of killing something else.
#
# 🪤 CALL THIS ONLY BETWEEN THE KILL AND THE RELAUNCH. It matches tabs by TITLE,
# and a title is only unambiguous while the session that owned it is dead: once
# the relaunch has opened a new tab under the same name, this cannot tell them
# apart and would close the new one.
function Close-SRTabsByName {
    param([string[]]$Names)

    $want = @{}
    foreach ($n in @($Names)) { if ("$n".Trim()) { $want["$n".Trim().ToLower()] = $true } }
    if (-not $want.Count) { return 0 }

    try { Add-Type -AssemblyName UIAutomationClient, UIAutomationTypes -ErrorAction Stop }
    catch { Write-SRLog "  [skip] cannot close tabs - UI Automation is unavailable"; return 0 }

    $closed = 0
    # Piped, not @(). Get-SRTerminalTabs returns ,@(...) and @() on that yields a
    # ONE-element array holding the array -- the trap this file documents.
    foreach ($t in (Get-SRTerminalTabs | ForEach-Object { $_ })) {
        if (-not $want.ContainsKey("$($t.Name)".Trim().ToLower())) { continue }
        try {
            $cond = New-Object System.Windows.Automation.PropertyCondition(
                        [System.Windows.Automation.AutomationElement]::ControlTypeProperty,
                        [System.Windows.Automation.ControlType]::Button)
            $btn = $t.Element.FindFirst([System.Windows.Automation.TreeScope]::Descendants, $cond)
            if (-not $btn) { Write-SRLog ("  [skip] tab '{0}' has no close button in its UI tree" -f $t.Name); continue }
            $btn.GetCurrentPattern([System.Windows.Automation.InvokePattern]::Pattern).Invoke()
            $closed++
            # The tab strip re-lays out after each close; without a beat the next
            # element handle is stale and the invoke throws.
            Start-Sleep -Milliseconds 140
        } catch {
            Write-SRLog ("  [skip] tab '{0}' would not close: {1}" -f $t.Name, $_.Exception.Message)
        }
    }
    if ($closed) { Write-SRLog ("  [ok]   closed {0} dead terminal tab(s)" -f $closed) }
    return $closed
}

# ---------------------------------------------------------------------------
# IS IT SAFE TO LAUNCH A QUEUE YET?
#
# 🔴 THE DAILY "AUTHORIZATION HAS FAILED" IS A STAMPEDE, not a broken account.
# Measured 2026-08-28. The logon task fires 45 seconds after sign-in and launches
# the whole ticked set about one per second. Claude Code counts consecutive
# failures of its remote bridge and, on the seventh, writes
# bridgeOauthDeadExpiresAt into ~/.claude.json and stops trying until that time
# passes. Twelve sessions launched into a bridge whose auth is not warm yet burn
# through seven failures in seven seconds -- so every session after that gets
# nothing, and the operator sees "authorization has failed" all morning.
#
# The evidence it is a WINDOW and not a break: on the morning this was measured
# the suppression expired at 07:32, sessions relaunched at 07:40 all registered
# normally (13 of 14 carried a live bridgeSessionId; the fourteenth was sitting
# on an open dialog), and that was an hour BEFORE any re-login. Re-logging in and
# the window simply expiring look identical from the outside, which is why this
# has read as an account problem for so long.
#
# So the restore now WAITS for the bridge instead of racing it.
function Get-SRBridgeSuppression {
    # The time the bridge is suppressed until, or $null when it is not.
    $p = Join-Path $env:USERPROFILE '.claude.json'
    if (-not (Test-Path -LiteralPath $p)) { return $null }
    try {
        $j = Get-Content -LiteralPath $p -Raw | ConvertFrom-Json
        if (-not $j.bridgeOauthDeadExpiresAt) { return $null }
        $t = [DateTimeOffset]::FromUnixTimeMilliseconds([long]$j.bridgeOauthDeadExpiresAt).LocalDateTime
        if ($t -gt (Get-Date)) { return $t }
        return $null
    } catch { return $null }
}

# ---------------------------------------------------------------------------
# RUNNING A CONSOLE PROGRAM WITHOUT GIVING THIS PROCESS A CONSOLE.
#
# 🔴 THIS IS WHY THE APP FLASHED A CONSOLE. Sessions.exe is built /target:winexe
# precisely so no console is ever allocated - but PowerShell's native-command
# pipeline (`& claude ...`) touches the console APIs to set up redirection, and
# in a process that has none, Windows makes one. Measured 2026-08-28: a conhost
# appeared as a child of Sessions.exe about two seconds after the first
# `claude agents --json`, under BOTH windows. The old window only looked clean
# because the suite happened to read the instant before it arrived.
#
# CreateProcess with CREATE_NO_WINDOW and redirected handles - which is what
# .NET's Process gives us here - never allocates one. Same output, no console.
#
# 🪤 ReadToEnd BEFORE WaitForExit, both streams drained. Waiting first deadlocks
# as soon as the child fills a pipe buffer, and `claude agents --json` on a busy
# machine is comfortably big enough to do that.
function Invoke-SRNativeText {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$FilePath,
        [string[]]$Arguments = @(),
        [int]$TimeoutMs = 20000
    )
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $FilePath
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.StandardOutputEncoding = New-Object System.Text.UTF8Encoding($false)
    $psi.StandardErrorEncoding = New-Object System.Text.UTF8Encoding($false)
    # PS 5.1 ships the .NET FRAMEWORK ProcessStartInfo, which has no ArgumentList -
    # only the single Arguments string. Quote by CommandLineToArgvW rules, the same
    # rules New-SRLaunchCommand already follows for wt.exe.
    $psi.Arguments = (@($Arguments) | ForEach-Object {
        if ($_ -match '[\s"]') { '"' + ($_ -replace '(\\*)"', '$1$1\"') + '"' } else { $_ }
    }) -join ' '
    $p = New-Object System.Diagnostics.Process
    $p.StartInfo = $psi
    try {
        $null = $p.Start()
        $so = $p.StandardOutput.ReadToEnd()
        $se = $p.StandardError.ReadToEnd()
        if (-not $p.WaitForExit($TimeoutMs)) {
            try { $p.Kill() } catch { }
            return [PSCustomObject]@{ Out = $so; Err = $se; ExitCode = -1; TimedOut = $true }
        }
        return [PSCustomObject]@{ Out = $so; Err = $se; ExitCode = $p.ExitCode; TimedOut = $false }
    } finally { try { $p.Dispose() } catch { } }
}

function Test-SRAuthReady {
    # `claude auth status` prints JSON and is the account's own answer, rather
    # than this tool guessing from a credentials file it does not own.
    try {
        $exe = Get-Command claude -ErrorAction Stop
        $r = Invoke-SRNativeText -FilePath $exe.Source -Arguments @('auth', 'status')
        if ($r.ExitCode -ne 0) { return $false }
        $j = $r.Out | ConvertFrom-Json -ErrorAction Stop
        return [bool]$j.loggedIn
    } catch { return $false }
}

function Wait-SRBridgeReady {
    param([int]$MaxWaitSeconds = 300)

    $sw = [Diagnostics.Stopwatch]::StartNew()
    $said = $false
    while ($sw.Elapsed.TotalSeconds -lt $MaxWaitSeconds) {
        $sup  = Get-SRBridgeSuppression
        $auth = Test-SRAuthReady
        if (-not $sup -and $auth) {
            if ($said) { Write-SRLog ("  [ok]   the bridge is ready after {0:N0}s of waiting" -f $sw.Elapsed.TotalSeconds) }
            return $true
        }
        if (-not $said) {
            $why = @()
            if ($sup)       { $why += ("the remote bridge is suppressed until {0}" -f $sup.ToString('HH:mm:ss')) }
            if (-not $auth) { $why += 'claude does not report a signed-in account yet' }
            Write-SRLog ("  [wait] holding the restore - {0}" -f ($why -join '; '))
            $said = $true
        }
        Start-Sleep -Seconds 10
    }
    # 🔴 LAUNCH ANYWAY AT THE CAP. Sessions back without Remote Control is a far
    # better morning than no sessions at all, and the cap keeps this well inside
    # the scheduled task's execution limit.
    Write-SRLog ("  [skip] the bridge was still not ready after {0}s - launching regardless" -f $MaxWaitSeconds)
    return $false
}

# Bring a conversation's terminal tab to the front.
# Returns $null when it landed, or a reason string when it did not. A reason is
# always "nothing happened", never "something happened somewhere else".
function Invoke-SRJumpToSession {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$SessionId,
        # The tab title to look for. Pass it when the caller ALREADY knows it --
        # the GUI holds a refreshed agent table from its background pass. Without
        # this the function asks claude itself, and that call is 653 ms measured;
        # on a click handler that is a visibly frozen window.
        [string]$Title,
        # When the tab cannot be identified, still raise the terminal window if
        # exactly one is running, rather than doing nothing at all.
        [switch]$RaiseAnyway
    )

    $want = "$Title".Trim()
    if (-not $want) {
        $key = "$SessionId".ToLower()
        $agents = Get-SRAgentStatus
        $a = $agents[$key]
        if (-not $a) { return 'that conversation is not running - there is no terminal to jump to' }
        if ($a.Kind -and $a.Kind -ne 'interactive') {
            return 'a background agent has no terminal of its own'
        }
        $want = "$($a.Name)".Trim()
    }
    if (-not $want) { return 'that session has no title, so its tab cannot be identified' }

    $script:SR_JumpNote = $null

    $tabs = Get-SRTerminalTabs
    $tabs = @($tabs)
    if (-not $tabs.Count) { return 'no Windows Terminal tabs are visible to the accessibility layer' }

    $hits = @($tabs | Where-Object { $_.Name -eq $want })
    if (-not $hits.Count) {
        # Case-insensitive second pass before giving up: a title is cosmetic and
        # nothing guarantees its case survived a round trip.
        $hits = @($tabs | Where-Object { $_.Name -ieq $want })
    }

    $hit = $null
    if ($hits.Count -eq 1) {
        $hit = $hits[0]
        # Remember it while the title is right, so a jump still works later when
        # a running child process has renamed the tab out from under us.
        $script:SR_TabIndex["$SessionId".ToLower()] = $hit
    }
    elseif ($hits.Count -gt 1) {
        # Two tabs can carry one title: measured, two both called OWN-WEBPAGE.
        # Prefer a remembered element for THIS session, which is unambiguous;
        # only fall back to "the first one, and say so".
        $cached = $script:SR_TabIndex["$SessionId".ToLower()]
        if ($cached -and (@($hits | Where-Object { ($_.Element.GetRuntimeId() -join '-') -eq ($cached.Element.GetRuntimeId() -join '-') }).Count)) {
            $hit = $cached
        } else {
            $hit = $hits[0]
            $script:SR_JumpNote = "$($hits.Count) tabs are called '$want' - went to the first one"
        }
    }
    else {
        # No tab carries that name right now. The title has probably drifted to
        # whatever the session is currently running; the remembered element is
        # still the right tab.
        $cached = $script:SR_TabIndex["$SessionId".ToLower()]
        $alive = $false
        if ($cached) {
            try { $null = $cached.Element.Current.Name; $alive = $true } catch { }
        }
        if ($alive) {
            $hit = $cached
            $script:SR_JumpNote = "no tab is called '$want' just now - went to the tab it was last seen in"
        } else {
            if ($cached) { $script:SR_TabIndex.Remove("$SessionId".ToLower()) }
            if ($RaiseAnyway) {
                $wins = @($tabs | Select-Object -ExpandProperty Hwnd -Unique)
                if ($wins.Count -eq 1) {
                    [SRWin]::Raise($wins[0])
                    return "could not find a tab called '$want' - brought the terminal window forward instead"
                }
            }
            return "no terminal tab is called '$want' - it may be running somewhere other than Windows Terminal"
        }
    }

    try {
        $hit.Element.GetCurrentPattern([System.Windows.Automation.SelectionItemPattern]::Pattern).Select()
    } catch {
        # A dead element throws here. Drop it so the next attempt re-finds by name.
        $script:SR_TabIndex.Remove("$SessionId".ToLower())
        return "that tab refused to activate: $($_.Exception.Message)"
    }
    [SRWin]::Raise($hit.Hwnd)

    # VERIFY. Selecting is a request, and a request that quietly failed would
    # leave the operator typing into whatever tab happened to be in front.
    Start-Sleep -Milliseconds 220
    $ok = $false
    try {
        $sp = $hit.Element.GetCurrentPattern([System.Windows.Automation.SelectionItemPattern]::Pattern)
        $ok = [bool]$sp.Current.IsSelected
    } catch { }
    if (-not $ok) { return "asked for '$want' but the terminal did not switch to it" }

    Write-SRLog ("  [ok]   jumped to {0} ({1})" -f $want, $SessionId)
    return $null
}

# --- typing into a running session ------------------------------------------
# Attach to the target's console and write input records into it. Proven against
# a real claude session in a Windows Terminal tab on 2026-08-22: the injected
# line arrived in that session's transcript as a genuine user message.
#
# This is KEYSTROKE-LEVEL. It lands wherever that session's input goes, which is
# why every guard below exists rather than being defensive padding:
#
#   - the target is identified by PID from claude's own `agents --json`, never
#     by window title or focus, so nothing depends on what is on top;
#   - the pid is RE-VERIFIED as a live claude.exe immediately before writing,
#     because a pid is reusable and a stale one would type into whatever
#     process inherited the number;
#   - a session with a DIALOG open is refused outright. Prose typed at a
#     permission prompt answers the prompt, and that is a decision the operator
#     has to make deliberately;
#   - newlines are stripped. A multi-line paste would submit at the first one
#     and leave the rest typing into whatever came next.
#
# CreateFileW is declared CharSet.Unicode ON PURPOSE. Without it the name
# marshals as ANSI, "CONIN$" never arrives, and the call fails with error 2 --
# which reads exactly like "the console cannot be opened" and cost an hour of
# believing ConPTY was blocking it.
if (-not ('SRCon' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public static class SRCon {
    [DllImport("kernel32.dll", SetLastError=true)] public static extern bool AttachConsole(uint pid);
    [DllImport("kernel32.dll", SetLastError=true)] public static extern bool FreeConsole();
    [DllImport("kernel32.dll")] public static extern IntPtr GetConsoleWindow();
    [DllImport("kernel32.dll", SetLastError=true, CharSet=CharSet.Unicode)]
    public static extern IntPtr CreateFileW(string name, uint access, uint share, IntPtr sa, uint disp, uint flags, IntPtr tmpl);
    [DllImport("kernel32.dll", SetLastError=true)] public static extern bool CloseHandle(IntPtr h);
    [DllImport("kernel32.dll", SetLastError=true)]
    public static extern bool WriteConsoleInputW(IntPtr h, INPUT_RECORD[] buf, uint len, out uint written);
    [DllImport("kernel32.dll", SetLastError=true, CharSet=CharSet.Unicode)]
    public static extern bool ReadConsoleOutputCharacterW(IntPtr h, [Out] char[] buf, uint len, uint coord, out uint read);
    [StructLayout(LayoutKind.Sequential)] public struct COORD { public short X, Y; }
    [StructLayout(LayoutKind.Sequential)] public struct SMALL_RECT { public short L, T, R, B; }
    [StructLayout(LayoutKind.Sequential)] public struct CSBI {
        public COORD Size; public COORD Cursor; public ushort Attrs;
        public SMALL_RECT Window; public COORD MaxSize;
    }
    [DllImport("kernel32.dll", SetLastError=true)]
    public static extern bool GetConsoleScreenBufferInfo(IntPtr h, out CSBI info);

    [StructLayout(LayoutKind.Sequential)]
    public struct INPUT_RECORD {
        public ushort EventType; public ushort pad;
        public bool bKeyDown; public ushort wRepeatCount; public ushort wVirtualKeyCode;
        public ushort wVirtualScanCode; public char UnicodeChar; public uint dwControlKeyState;
    }

    public static IntPtr OpenConIn() {
        return CreateFileW("CONIN$", 0x80000000u | 0x40000000u, 1u | 2u, IntPtr.Zero, 3u, 0u, IntPtr.Zero);
    }

    // 🔴 GIVE THE CALLER ITS OWN CONSOLE BACK.
    //
    // Attaching to another process's console means first FREEING ours, and a
    // process may hold exactly one. Every method here did that and never restored
    // it, so a console-hosted caller was left with no console at all: the test
    // harness died on the NEXT Write-Host with 'The handle is invalid' 0x6, from a
    // line that had nothing to do with any of this. The GUI never noticed because
    // a WPF process has no console to lose.
    //
    // Only for callers that HAD one -- attaching the GUI to whatever console its
    // launcher happens to own would be a new behaviour, not a restoration.
    static void GiveBack(bool had) {
        FreeConsole();
        if (had) AttachConsole(0xFFFFFFFF);   // ATTACH_PARENT_PROCESS
    }

    // Returns the number of records written, or -win32error.
    public static int Send(uint pid, string text, bool enter) {
        bool had = GetConsoleWindow() != IntPtr.Zero;
        FreeConsole();
        if (!AttachConsole(pid)) { GiveBack(had); return -Marshal.GetLastWin32Error(); }
        try {
            IntPtr h = OpenConIn();
            if (h == new IntPtr(-1)) return -Marshal.GetLastWin32Error();
            try {
                int n = text.Length + (enter ? 1 : 0);
                INPUT_RECORD[] r = new INPUT_RECORD[n * 2];
                int i = 0;
                foreach (char c in text) {
                    r[i].EventType = 1; r[i].bKeyDown = true;  r[i].wRepeatCount = 1; r[i].UnicodeChar = c; i++;
                    r[i].EventType = 1; r[i].bKeyDown = false; r[i].wRepeatCount = 1; r[i].UnicodeChar = c; i++;
                }
                if (enter) {
                    r[i].EventType = 1; r[i].bKeyDown = true;  r[i].wRepeatCount = 1; r[i].wVirtualKeyCode = 0x0D; r[i].UnicodeChar = '\r'; i++;
                    r[i].EventType = 1; r[i].bKeyDown = false; r[i].wRepeatCount = 1; r[i].wVirtualKeyCode = 0x0D; r[i].UnicodeChar = '\r';
                }
                uint written;
                if (!WriteConsoleInputW(h, r, (uint)r.Length, out written)) return -Marshal.GetLastWin32Error();
                return (int)written;
            } finally { CloseHandle(h); }
        } finally { GiveBack(had); }
    }

    // KEYS, NOT CHARACTERS. Send() writes UnicodeChar records, which is everything
    // a prompt needs and nothing a MENU needs: claude's AskUserQuestion is chosen
    // with the arrow keys, and an arrow has no character to write. A virtual-key
    // record carries wVirtualKeyCode with UnicodeChar left at 0 -- the console
    // delivers it as a real keypress rather than as text that happens to spell one.
    //
    // The caller passes the codes it wants: 0x26 UP, 0x28 DOWN, 0x20 SPACE,
    // 0x0D ENTER, 0x09 TAB. Down and up are written for each, because a TUI that
    // watches for key-release sees nothing from a half-pair.
    public static int SendKeys(uint pid, ushort[] vks) {
        bool had = GetConsoleWindow() != IntPtr.Zero;
        FreeConsole();
        if (!AttachConsole(pid)) { GiveBack(had); return -Marshal.GetLastWin32Error(); }
        try {
            IntPtr h = OpenConIn();
            if (h == new IntPtr(-1)) return -Marshal.GetLastWin32Error();
            try {
                INPUT_RECORD[] r = new INPUT_RECORD[vks.Length * 2];
                int i = 0;
                foreach (ushort vk in vks) {
                    // ENTER is the one that also needs its character, or a console
                    // reading cooked input never sees the line end.
                    char ch = (vk == 0x0D) ? (char)13 : (char)0;
                    r[i].EventType = 1; r[i].bKeyDown = true;  r[i].wRepeatCount = 1; r[i].wVirtualKeyCode = vk; r[i].UnicodeChar = ch; i++;
                    r[i].EventType = 1; r[i].bKeyDown = false; r[i].wRepeatCount = 1; r[i].wVirtualKeyCode = vk; r[i].UnicodeChar = ch; i++;
                }
                uint written;
                if (!WriteConsoleInputW(h, r, (uint)r.Length, out written)) return -Marshal.GetLastWin32Error();
                return (int)written;
            } finally { CloseHandle(h); }
        } finally { GiveBack(had); }
    }

    // WHAT IS ON THE SCREEN. The only place a PENDING question exists.
    //
    // The transcript cannot answer this: the AskUserQuestion tool_use block is
    // written when the question is ANSWERED, not when it is asked. Measured against
    // a live session with a menu visibly on screen -- zero blocks in the transcript,
    // one the moment it was answered. So the screen is not a fallback here, it is
    // the source.
    //
    // Returns the buffer as text, or a string starting with '!' naming what failed.
    // Read-only: nothing is written to the session.
    // 🔴 REFUSES FROM A CONSOLE-HOSTED PROCESS, and that is not caution, it is the
    // only correct answer.
    //
    // Attaching to another console means freeing your own, and GiveBack cannot
    // really undo that: PowerShell has already CACHED its console handles, so it
    // keeps writing to a handle that is now invalid and dies on the next Write-Host
    // with 'The handle is invalid' 0x6 -- from a line that has nothing to do with
    // any of this. Measured: the test suite failed exactly that way.
    //
    // The GUI is a WPF process with no console of its own, which is the caller this
    // exists for and the one case where the attach costs nothing. Everything else
    // gets a refusal it can read. The PARSER is separate and testable without a
    // console, which is where the judgement lives anyway.
    public static string Screen(uint pid) {
        bool had = false;
        FreeConsole();
        if (!AttachConsole(pid)) { GiveBack(had); return "!attach " + Marshal.GetLastWin32Error(); }
        try {
            IntPtr h = CreateFileW("CONOUT$", 0x80000000u | 0x40000000u, 1u | 2u, IntPtr.Zero, 3u, 0u, IntPtr.Zero);
            if (h == new IntPtr(-1)) return "!conout " + Marshal.GetLastWin32Error();
            try {
                CSBI info;
                if (!GetConsoleScreenBufferInfo(h, out info)) return "!csbi " + Marshal.GetLastWin32Error();
                int w = info.Size.X, rows = info.Size.Y;
                if (w <= 0 || rows <= 0) return "!empty";
                // Only the rows the window is showing. A scrollback of thousands is
                // both slow and wrong: a question that has scrolled off is not one
                // the operator can still answer.
                int top = info.Window.T < 0 ? 0 : info.Window.T;
                int bot = info.Window.B >= rows ? rows - 1 : info.Window.B;
                if (bot < top) { top = 0; bot = rows - 1; }
                System.Text.StringBuilder sb = new System.Text.StringBuilder();
                char[] line = new char[w];
                for (int y = top; y <= bot; y++) {
                    uint got;
                    uint at = ((uint)y << 16);   // packed COORD: low word X, high word Y
                    if (!ReadConsoleOutputCharacterW(h, line, (uint)w, at, out got)) continue;
                    sb.Append(new string(line, 0, (int)got).TrimEnd());
                    sb.Append((char)10);
                }
                return sb.ToString();
            } finally { CloseHandle(h); }
        } finally { GiveBack(had); }
    }
}
'@
}

# Returns $null when the line was delivered, or a reason string when it was not.
# A reason is always a refusal to act, never a partial send.
function Send-SRSessionInput {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$SessionId,
        [Parameter(Mandatory)][string]$Text,
        # Skip the dialog refusal. The caller must have shown the operator what
        # is open and been told to go ahead anyway.
        [switch]$Force
    )

    $body = ($Text -replace "`r`n", ' ' -replace "`r", ' ' -replace "`n", ' ').Trim()
    if (-not $body) { return 'nothing to send' }

    $key = "$SessionId".ToLower()
    $agents = Get-SRAgentStatus -Refresh
    $a = $agents[$key]
    if (-not $a)        { return 'that conversation is not running - open its terminal first' }
    if (-not $a.Pid)    { return 'that session has no process to type into (it is a background agent)' }
    if ($a.Kind -ne 'interactive') { return 'only an interactive session can be typed into' }
    if (-not $Force -and $a.WaitingFor -match 'dialog') {
        return 'a dialog is open in that session - answer it there, or send anyway to type into the dialog'
    }

    # A pid is reusable. Confirm THIS one is still the claude that owns the
    # session before writing anything into its console.
    $proc = $null
    try { $proc = Get-CimInstance Win32_Process -Filter "ProcessId=$($a.Pid)" -ErrorAction Stop } catch { }
    if (-not $proc)                      { return 'that session has exited' }
    if ($proc.Name -ne 'claude.exe')     { return "pid $($a.Pid) is $($proc.Name), not claude.exe - refusing to type into it" }

    # 🔴 THE TEXT AND THE SUBMIT ARE TWO CALLS, and that is not tidiness.
    # Send() wrote the characters and a trailing ENTER in ONE WriteConsoleInput
    # batch, and measured against a live session the text landed in the input box
    # and SAT there: 25 seconds, no transcript movement, until a separate ENTER
    # arrived -- at which point the record count jumped 21 to 28. Every message
    # sent this way could be reported as sent and never submitted.
    #
    # The box needs a beat to finish taking a few hundred characters before it will
    # accept the newline that closes them.
    $n = [SRCon]::Send([uint32]$a.Pid, $body, $false)
    if ($n -ge 0) {
        Start-Sleep -Milliseconds 400
        $n = [SRCon]::SendKeys([uint32]$a.Pid, [uint16[]]@(0x0D))
    }
    if ($n -lt 0) {
        $err = -$n
        Write-SRLog ("send to {0} failed: win32 {1}" -f $a.Name, $err)
        return "could not reach that session's console (win32 error $err)"
    }
    Write-SRLog ("  [ok]   sent {0} char(s) to {1} ({2})" -f $body.Length, $a.Name, $SessionId)
    return $null
}

# ANSWERING ONE, by driving the menu the way a person drives it.
#
# The choreography is measured, not guessed. Against a real claude TUI:
#   * a virtual-key record reaches it at all      -- the folder-trust prompt took ENTER
#   * the cursor starts on option 1               -- a bare ENTER recorded ALPHA, 3 times
#   * ENTER commits whatever is highlighted       -- tool_result: "pick one"="ALPHA"
#   * DOWN moves the cursor                       -- a 2-option prompt EXITED on option 2
# so option n is DOWN (n-1) times, then ENTER.
#
# 🪤 The arrows are only safe because the cursor STARTS at the top. Nothing here
# can see the menu, so if anything has already moved it this sends the wrong
# answer. That is why it refuses unless the session is genuinely waiting, and why
# it is only ever called straight off a freshly-read question.
function Send-SRQuestionAnswer {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$SessionId,
        # 0-based, as the options are indexed on screen.
        [Parameter(Mandatory)][int]$Index,
        [int]$OptionCount = 0
    )
    if ($Index -lt 0) { return 'that is not one of the options' }
    # The caller's count comes from the transcript, which lists only what claude
    # asked for -- the TUI adds 'Type something' and 'Chat about this' on top. The
    # screen is checked below and is the one that governs.
    if ($OptionCount -gt 0 -and $Index -ge $OptionCount) { return 'that is not one of the options' }

    $key = "$SessionId".ToLower()
    $agents = Get-SRAgentStatus -Refresh
    $a = $agents[$key]
    if (-not $a)     { return 'that conversation is not running - open its terminal first' }
    if (-not $a.Pid) { return 'that session has no console to answer in (it is a background agent)' }
    if ($a.Kind -ne 'interactive') { return 'only an interactive session can be answered' }
    # 🔒 IT MUST STILL BE ASKING. If it has moved on, the arrows land in whatever is
    # on screen now -- which could be a prompt, and DOWN-DOWN-ENTER in a prompt is
    # a command nobody typed.
    if ("$($a.Status)" -ne 'waiting') { return 'that session is not waiting for an answer any more' }

    $proc = $null
    try { $proc = Get-CimInstance Win32_Process -Filter "ProcessId=$($a.Pid)" -ErrorAction Stop } catch { }
    if (-not $proc)                  { return 'that session has exited' }
    if ($proc.Name -ne 'claude.exe') { return "pid $($a.Pid) is $($proc.Name), not claude.exe - refusing to type into it" }

    $why = Invoke-SRAnswerOnScreen -ProcessId ([int]$a.Pid) -Index $Index -Who "$($a.Name)"
    return $why
}

# ---------------------------------------------------------------------------
# THE CHOREOGRAPHY, ON ITS OWN, BECAUSE IT IS THE HALF THAT COULD NOT BE TESTED.
#
# Send-SRQuestionAnswer above is welded to a real claude session: it demands an
# agent record, a status of 'waiting', and a process actually called claude.exe.
# Those guards are right and they are why the risky part -- read the live screen,
# work out how far to move, send arrows, commit -- had never once run against a
# live console under test. Both halves were proven SEPARATELY: the parser against
# captured text, the key send against a real menu on 2026-08-24. Never together,
# and that was the last unknown in this feature for three days.
#
# Split out, it can be driven against any console showing a menu, so
# tests\relay-driver.ps1 stands up a replica built from REAL captured screen text
# and proves the whole round trip -- including that a NON-DEFAULT option is the
# one that commits, which is the only outcome a bug here would get wrong quietly.
#
# It deliberately does NOT check what the process is. Its caller does that.
# ---------------------------------------------------------------------------
function Invoke-SRAnswerOnScreen {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][int]$ProcessId,
        # 0-based, as the options are indexed on screen.
        [Parameter(Mandatory)][int]$Index,
        [string]$Who = ''
    )
    if ($ProcessId -le 0) { return 'there is no console to answer in' }
    if ($Index -lt 0) { return 'that is not one of the options' }

    # 🔴 MOVE FROM WHERE THE CURSOR IS, NOT FROM WHERE IT PROBABLY IS.
    #
    # This sent Index x DOWN on the assumption that a menu always opens on option 1.
    # That was measured true for a FRESH menu and is false for any menu the operator
    # has already arrowed through -- and nothing in the transcript can tell the
    # difference, so a wrong assumption silently answered the wrong question.
    # The screen says where the cursor is, so it is read.
    #
    # 🔒 NO CURSOR, NO ARROWS. If the screen cannot be read, or the marker is not on
    # it, this refuses rather than falling back to the old guess. A relay that
    # answers the wrong option is worse than one that says it could not.
    $seen = Get-SRScreenQuestion -ProcessId $ProcessId
    if (-not $seen) { return 'cannot see a question on that session''s screen - answer it in the terminal' }
    if ($seen.CursorAt -lt 0) { return 'cannot tell which option is highlighted - answer it in the terminal' }
    if ($Index -ge $seen.Options.Count) {
        return "that session is showing $($seen.Options.Count) option(s), so option $($Index + 1) is not one of them"
    }

    $keys = New-Object System.Collections.Generic.List[uint16]
    $delta = $Index - [int]$seen.CursorAt
    $step  = $(if ($delta -ge 0) { [uint16]0x28 } else { [uint16]0x26 })   # VK_DOWN / VK_UP
    for ($i = 0; $i -lt [Math]::Abs($delta); $i++) { $null = $keys.Add($step) }
    if ($keys.Count) {
        $n = [SRCon]::SendKeys([uint32]$ProcessId, $keys.ToArray())
        if ($n -lt 0) { return "could not reach that session's console (win32 error $(-$n))" }
        # THE MOVES MUST LAND BEFORE THE COMMIT. Sent in one burst, ENTER can be
        # read before the TUI has repainted the highlight, and the answer is
        # whatever was highlighted when it arrived.
        Start-Sleep -Milliseconds 250
    }
    $n = [SRCon]::SendKeys([uint32]$ProcessId, [uint16[]]@(0x0D))          # VK_RETURN
    if ($n -lt 0) { return "could not reach that session's console (win32 error $(-$n))" }
    Write-SRLog ("  [ok]   answered {0} with option {1} of {2} ({3}), cursor was on {4}" -f $Who, ($Index + 1), $seen.Options.Count, $seen.Options[$Index], ($seen.CursorAt + 1))
    return $null
}

# ---------------------------------------------------------------------------
# SEVERAL ANSWERS AT ONCE.
#
# 🔒 NOT WIRED TO ANYTHING THAT CAN REACH A LIVE SESSION, and that is deliberate.
# The SHAPE of a multi-select menu is measured -- captured off a real one on
# 2026-08-26: ASCII "[ ]" boxes on every option, the same U+276F cursor, an
# unnumbered navigable Submit row under the last option, and a footer reading
# "Enter to select". The BEHAVIOUR is not. That footer READS as "Enter acts on
# the highlighted row: toggle on an option, commit on Submit", and reading is
# not measuring. An attempt to measure it by driving this tool's own session was
# refused by the permission classifier, which is the right call for a background
# process synthesising keystrokes into a live claude.
#
# So this exists, is tested against a replica built from the real capture, and is
# called by NOTHING in the GUI. What the replica proves is the NAVIGATION -- that
# Submit is found by reading the cursor rather than by counting rows, that the
# options asked for are the ones toggled, and that an option already ticked is
# left alone rather than turned off again. What it cannot prove is the premise.
#
# TO FINISH IT: confirm what ENTER does to a real multi-select menu. One
# observation is enough.
# ---------------------------------------------------------------------------
function Invoke-SRAnswerMultiOnScreen {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][int]$ProcessId,
        # 0-based option indices to end up TICKED.
        [Parameter(Mandatory)][int[]]$Indexes,
        [string]$Who = '',
        # Every move re-reads the screen, so a menu that repaints slowly cannot
        # desynchronise the walk. 24 is far more than any real menu needs.
        [int]$MaxMoves = 24
    )
    if ($ProcessId -le 0) { return 'there is no console to answer in' }
    # 🪤 NOT `-not $Indexes`. PowerShell unrolls a ONE-ELEMENT array to its
    # element, so @(0) is 0 is FALSE -- and "@(0)" is how you ask for the FIRST
    # option. The guard fired on the single most likely request there is, and the
    # refusal said "nothing was chosen" about a perfectly good choice. Caught by
    # a test that expected a different refusal and got this one.
    if ($null -eq $Indexes -or @($Indexes).Count -lt 1) { return 'nothing was chosen' }

    $seen = Get-SRScreenQuestion -ProcessId $ProcessId
    if (-not $seen) { return 'cannot see a question on that session''s screen - answer it in the terminal' }
    if (-not $seen.Multi) { return 'that is not a multi-select question' }
    if ($seen.CursorAt -lt 0) { return 'cannot tell which option is highlighted - answer it in the terminal' }
    if ($seen.SubmitAt -lt 0) { return 'that menu has no Submit row, so there is no way to commit it from here' }
    foreach ($ix in $Indexes) {
        if ($ix -lt 0 -or $ix -ge $seen.Options.Count) {
            return "that session is showing $($seen.Options.Count) option(s), so option $($ix + 1) is not one of them"
        }
    }

    # WHAT ACTUALLY NEEDS TOGGLING. An option already ticked is left ALONE:
    # pressing ENTER on it would turn it back off, and the caller asked for it to
    # end up ON. This is why Ticked is parsed at all.
    $already = @{}
    foreach ($t in @($seen.Ticked)) { $already[[int]$t] = $true }
    $todo = New-Object System.Collections.Generic.List[object]
    foreach ($ix in ($Indexes | Sort-Object -Unique)) { if (-not $already[[int]$ix]) { $null = $todo.Add([int]$ix) } }

    function Step-ToStop {
        param([int]$Target, [int]$Pid2, [int]$Budget)
        for ($i = 0; $i -lt $Budget; $i++) {
            $now = Get-SRScreenQuestion -ProcessId $Pid2
            if (-not $now) { return 'the menu went away mid-answer' }
            if ($now.CursorAt -lt 0) { return 'lost sight of the highlight mid-answer' }
            if ([int]$now.CursorAt -eq $Target) { return $null }
            $vk = $(if ($Target -gt [int]$now.CursorAt) { [uint16]0x28 } else { [uint16]0x26 })
            $r = [SRCon]::SendKeys([uint32]$Pid2, [uint16[]]@($vk))
            if ($r -lt 0) { return "could not reach that session's console (win32 error $(-$r))" }
            Start-Sleep -Milliseconds 180
        }
        return 'could not get the highlight where it needed to go'
    }

    foreach ($ix in $todo.ToArray()) {
        $why = Step-ToStop -Target $ix -Pid2 $ProcessId -Budget $MaxMoves
        if ($why) { return $why }
        $r = [SRCon]::SendKeys([uint32]$ProcessId, [uint16[]]@(0x0D))       # toggle, on the inferred reading
        if ($r -lt 0) { return "could not reach that session's console (win32 error $(-$r))" }
        Start-Sleep -Milliseconds 220
    }

    # COMMIT LAST, and only after re-reading: Submit's index is one past the last
    # option, and the menu may have repainted since the first read.
    $final = Get-SRScreenQuestion -ProcessId $ProcessId
    if (-not $final) { return 'the menu went away before it could be submitted' }
    if ($final.SubmitAt -lt 0) { return 'the Submit row disappeared mid-answer' }
    $why = Step-ToStop -Target ([int]$final.SubmitAt) -Pid2 $ProcessId -Budget $MaxMoves
    if ($why) { return $why }
    $r = [SRCon]::SendKeys([uint32]$ProcessId, [uint16[]]@(0x0D))
    if ($r -lt 0) { return "could not reach that session's console (win32 error $(-$r))" }
    Write-SRLog ("  [ok]   answered {0} with {1} of {2} option(s) ticked, then Submit" -f $Who, $Indexes.Count, $final.Options.Count)
    return $null
}
# THE QUESTION AS IT IS ON SCREEN, which is the only place a PENDING one exists.
#
# Get-SRPendingQuestion reads the transcript and can only ever find a question that
# has ALREADY BEEN ANSWERED -- claude writes the AskUserQuestion tool_use block
# when the tool returns, not when it is asked. Measured against a live session with
# a menu visibly on screen: zero blocks in the transcript, one the moment it was
# answered. A window relying on the transcript would tell the operator a session
# was 'waiting' and never once show what it wanted, which is the complaint the
# whole relay exists to answer.
#
# Reading the screen also settles something the transcript cannot: WHERE THE CURSOR
# IS. Everything about sending arrow keys assumed it starts on option 1, and that
# assumption was load-bearing and unverifiable. Here it is simply read.
#
# 🪤 The marker is U+276F, and it is written as a CODE rather than as a literal:
# PowerShell 5.1 reads a BOM-less UTF-8 file as ANSI, so a pasted arrow would
# arrive mojibaked and match nothing.
# READING the screen and PARSING it are split, because only one of them needs a
# live process. The parser is where every judgement lives -- what counts as a menu,
# where the cursor is, which line is the question -- and it is testable against
# captured text. Whether a menu happens to be up while the suite runs is not
# something a test may depend on.
# READING ANOTHER PROCESS'S SCREEN, IN A CHILD THAT IS ABOUT TO DIE.
#
# Attaching to another console means FREEING your own, and that cannot be undone
# from inside PowerShell: the host has already cached its console handles, so it
# goes on writing to one that is now invalid and dies on the next Write-Host with
# 'The handle is invalid' 0x6, from a line that has nothing to do with any of it.
# Measured twice: once in the suite, once in the runner.
#
# AND THE GUI IS NOT EXEMPT. It looked like it was, because a WPF window has no
# console -- but it is STARTED by powershell.exe -WindowStyle Hidden, which has a
# perfectly real console that merely is not shown. Refusing whenever the caller had
# one would have refused in the only place this feature is used.
#
# So the attach happens in a CHILD that exists for one read and exits. Its console
# is destroyed and nobody cares; the caller's is never touched.
#
# The text comes back through a FILE, not stdout: a child that has just freed its
# console is not something to trust a redirected stream to. The file lives beside
# the tool's own state and is deleted in a finally, never in the OS temp directory.
function Get-SRScreenText {
    [CmdletBinding()]
    param([Parameter(Mandatory)][int]$ProcessId)
    if ($ProcessId -le 0) { return $null }
    if (-not (Test-Path -LiteralPath $SR_StateDir)) { return $null }
    $tag = [Guid]::NewGuid().ToString('N').Substring(0, 8)
    $out = Join-Path $SR_StateDir ('screen-' + $tag + '.txt')
    $scr = Join-Path $SR_StateDir ('screen-' + $tag + '.ps1')
    try {
        $Q = [string][char]39
        $common = (Join-Path $SR_LibDir '_common.ps1').Replace($Q, $Q + $Q)
        $outEsc = $out.Replace($Q, $Q + $Q)
        $body = @(
            ('. ' + $Q + $common + $Q),
            ('$t = [SRCon]::Screen([uint32]' + $ProcessId + ')'),
            ('[System.IO.File]::WriteAllText(' + $Q + $outEsc + $Q + ', $t, (New-Object System.Text.UTF8Encoding($false)))')
        ) -join [Environment]::NewLine
        [System.IO.File]::WriteAllText($scr, $body, (New-Object System.Text.UTF8Encoding($false)))
        $p = Start-Process -FilePath 'powershell.exe' -PassThru -WindowStyle Hidden -ArgumentList @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $scr)
        # A read that has not finished in three seconds is not going to be useful:
        # whatever menu it was looking at will have moved on.
        if (-not $p.WaitForExit(3000)) { try { $p.Kill() } catch { }; return $null }
        if (-not (Test-Path -LiteralPath $out)) { return $null }
        $txt = [System.IO.File]::ReadAllText($out)
        if (-not $txt -or $txt.StartsWith('!')) { return $null }
        return $txt
    } catch { return $null }
    finally {
        Remove-Item -LiteralPath $out -Force -ErrorAction SilentlyContinue
        Remove-Item -LiteralPath $scr -Force -ErrorAction SilentlyContinue
    }
}
function Get-SRScreenQuestion {
    [CmdletBinding()]
    param([Parameter(Mandatory)][int]$ProcessId)
    if ($ProcessId -le 0) { return $null }
    $txt = Get-SRScreenText -ProcessId $ProcessId
    # ONE RETRY, because a failed read is not the same as no question.
    #
    # Get-SRScreenText does its work in a child process with a 3-second budget,
    # and on a machine already running several of them that budget is sometimes
    # missed while the menu is still perfectly well on screen. Refusing on the
    # first miss made the relay say "cannot see a question" about a question it
    # could see a second later -- measured once in the relay suite, and it would
    # read as a broken feature rather than as a busy machine.
    #
    # A retry only ever RE-READS. It never assumes, so the guards downstream are
    # exactly as strict as before.
    if (-not $txt) {
        Start-Sleep -Milliseconds 300
        $txt = Get-SRScreenText -ProcessId $ProcessId
    }
    if (-not $txt) { return $null }
    return (Invoke-SRParseScreenQuestion -Text $txt)
}

# Where the QUESTION stops and claude's own furniture begins. The input box is
# drawn in box-drawing characters, and the status line under it carries the model
# and the context meter - none of that is part of what was asked, and letting any
# of it into the footer would put "Model: Opus 5 | [████...]" under the options.
function Test-SRQuestionChrome { param([string]$Line)
    $t = "$Line".Trim()
    if (-not $t) { return $false }
    # A run of box-drawing or dashes is the input box's border.
    if ($t -match ('^[' + [regex]::Escape('-=_' + [string][char]0x2500 + [string][char]0x2502 + [string][char]0x256D + [string][char]0x256E + [string][char]0x2570 + [string][char]0x256F) + ']{6,}')) { return $true }
    if ($t.StartsWith([string][char]0x276F)) { return $true }        # the prompt caret
    if ($t -match '^Model:\s') { return $true }
    if ($t -match '\bshift\+tab to cycle\b') { return $true }
    if ($t -match '^\?\s+for shortcuts') { return $true }
    return $false
}

function Invoke-SRParseScreenQuestion {
    [CmdletBinding()]
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Text)
    $txt = $Text
    if (-not $txt) { return $null }

    $cursor = [char]0x276F
    $lines = @($txt -split "`n")
    $opts = New-Object System.Collections.Generic.List[object]
    # Which screen line each option was found on, so the text belonging to it can
    # be picked up afterwards.
    $optLine = New-Object System.Collections.Generic.List[int]
    $at = -1
    $firstIdx = -1
    # Multi-select state, filled in as the options are read.
    $isMulti = $false
    $ticked = New-Object System.Collections.Generic.List[object]
    for ($i = 0; $i -lt $lines.Count; $i++) {
        $ln = $lines[$i]
        # '  2. BRAVO' or '<cursor> 1. ALPHA'. The label runs to the end of the line;
        # the description sits on the indented lines beneath and is not needed to
        # identify an option.
        $m = [regex]::Match($ln, '^\s*(' + [regex]::Escape($cursor) + ')?\s*(\d{1,2})\.\s+(\S.*)$')
        if (-not $m.Success) { continue }
        $n = [int]$m.Groups[2].Value
        # Numbered from 1 and CONSECUTIVE, or it is prose that happens to start with
        # a digit and a dot -- which a transcript full of numbered lists has plenty of.
        if ($opts.Count -eq 0) {
            if ($n -ne 1) { continue }
            $firstIdx = $i
        } elseif ($n -ne $opts.Count + 1) {
            continue
        }
        if ($m.Groups[1].Success) { $at = $opts.Count }

        # 🔑 A MULTI-SELECT OPTION CARRIES A BOX, AND IT IS ASCII.
        #
        # Captured off a real one on 2026-08-26: "❯ 1. [ ] Finish multi-select
        # answering". Square brackets, not U+25A1 -- a parser tuned to a Unicode
        # box would have matched nothing on the real thing, which is exactly why
        # this waited for a capture instead of being guessed at.
        #
        # The box is stripped from the label, because the label is what gets shown
        # and compared, and "[ ] Environment hygiene sweep" is not what the
        # question asked. Whether it was ticked is kept separately.
        $label = $m.Groups[3].Value.Trim()
        $bm = [regex]::Match($label, '^\[(.?)\]\s*(.*)$')
        if ($bm.Success) {
            $isMulti = $true
            if ("$($bm.Groups[1].Value)".Trim()) { $null = $ticked.Add($opts.Count) }
            $label = $bm.Groups[2].Value.Trim()
        }
        $null = $optLine.Add($i)
        $null = $opts.Add($label)
    }
    # One option is a list of one, which every numbered paragraph also looks like.
    if ($opts.Count -lt 2) { return $null }

    # ===================================================================
    # THE TEXT UNDER THE ANSWERS, which this parser used to throw away.
    #
    # It only ever walked UPWARDS from option 1 to find the question, so
    # everything BELOW the options was discarded before it could reach the
    # window - and that is where the reasoning lives. Choosing between
    # "Recommended" and the rest without it is choosing on the label alone.
    #
    # Two different things live down there and both are wanted:
    #   DETAIL  the indented lines under each option - what that option means
    #   FOOTER  whatever follows the LAST option, before the input box
    #
    # A line belongs to an option while it is indented further than the option
    # number and is not itself an option. The scan for the footer stops at the
    # prompt box, which claude draws in box-drawing characters, and at the status
    # line under it - neither is part of the question.
    # ===================================================================
    $details = New-Object System.Collections.Generic.List[string]
    for ($k = 0; $k -lt $opts.Count; $k++) {
        $from = $optLine[$k] + 1
        $to   = $(if ($k + 1 -lt $opts.Count) { $optLine[$k + 1] - 1 } else { $lines.Count - 1 })
        $buf  = New-Object System.Collections.Generic.List[string]
        for ($i = $from; $i -le $to -and $i -lt $lines.Count; $i++) {
            $raw = "$($lines[$i])"
            if (Test-SRQuestionChrome $raw) { break }
            $t = $raw.Trim()
            if (-not $t) { if ($buf.Count) { break } else { continue } }
            # Indented past the option number, or it is not this option's text.
            if (($raw.Length - $raw.TrimStart().Length) -lt 3) { break }
            $null = $buf.Add($t)
        }
        $null = $details.Add(($buf -join ' '))
    }

    $footer = New-Object System.Collections.Generic.List[string]
    $fFrom = $optLine[$optLine.Count - 1] + 1
    $seenGap = $false
    for ($i = $fFrom; $i -lt $lines.Count; $i++) {
        $raw = "$($lines[$i])"
        if (Test-SRQuestionChrome $raw) { break }
        $t = $raw.Trim()
        if (-not $t) { $seenGap = $true; continue }
        # The last option's own detail is NOT footer - it is already in $details.
        # The footer starts after the blank line that ends it.
        if (-not $seenGap -and ($raw.Length - $raw.TrimStart().Length) -ge 3) { continue }
        $null = $footer.Add($t)
    }

    # THE SUBMIT ROW. Unnumbered, indented, sitting under the last option -- and
    # navigable, so it is a cursor STOP like any option. Its index matters: the
    # relay reaches it by reading the cursor, and needs to know what it is looking
    # for. Only ever present on a multi-select.
    $submitAt = -1
    if ($isMulti) {
        for ($i = $firstIdx; $i -lt $lines.Count; $i++) {
            $onIt = ($lines[$i] -match [regex]::Escape($cursor))
            $bare = ($lines[$i] -replace [regex]::Escape($cursor), '').Trim()
            if ($bare -ne 'Submit') { continue }
            # It is one stop past the last option, because it is navigable.
            $submitAt = $opts.Count
            # AND IT CAN HOLD THE CURSOR. A menu whose highlight is already on
            # Submit reports CursorAt past the last option, and a caller that
            # assumed the cursor was always on an option would compute its
            # distance from the wrong place -- the same mistake, in the same
            # function, that reading the screen exists to prevent.
            if ($onIt) { $at = $submitAt }
            break
        }
    }

    # The question is the last line of prose above the first option. Box-drawing and
    # the header chips are furniture, not the question.
    $q = ''
    for ($i = $firstIdx - 1; $i -ge 0 -and $i -ge $firstIdx - 12; $i--) {
        $cand = ($lines[$i] -replace '^[\s' + [regex]::Escape([string][char]0x2502) + ']+', '').Trim()
        if (-not $cand) { continue }
        if ($cand -match '^[' + [regex]::Escape('-=_' + [string][char]0x2500 + [string][char]0x2502) + ']+$') { continue }
        $q = $cand
        break
    }

    return [PSCustomObject]@{
        Question = $q
        Options  = $opts.ToArray()
        # Parallel to Options: what each one means, off the screen, verbatim.
        # Empty string where an option carried no description.
        Details  = $details.ToArray()
        # Whatever claude wrote after the last option - the note that qualifies
        # the whole question rather than any one answer.
        Footer   = ($footer -join ' ')
        # 0-based, or -1 when no cursor could be seen. A caller that cannot see the
        # cursor must not send arrows on a guess.
        CursorAt = $at
        # Does every option carry a "[ ]" box? Then several answers are wanted and
        # one ENTER on an option is not the end of it.
        Multi    = $isMulti
        # Which options are ALREADY ticked, 0-based. A relay that toggles must
        # know what it is toggling FROM: pressing ENTER on an option that is
        # already ticked turns it OFF.
        Ticked   = $ticked.ToArray()
        # The cursor stop that commits, one past the last option, or -1.
        SubmitAt = $submitAt
        Source   = 'screen'
    }
}
# --- the question a session is waiting on ------------------------------------
# claude asks multiple-choice questions through AskUserQuestion, and until now the
# window could show that a session was waiting without ever showing WHAT it wanted.
# The operator had to go to the terminal to find out, which is most of the reason
# the terminal was still being opened at all.
#
# WHAT A PENDING QUESTION LOOKS LIKE ON DISK, established by measurement rather
# than assumption: an AskUserQuestion tool_use block with NO tool_result carrying
# its id anywhere later in the transcript. Checked against a live session's own
# journal -- 40 tool_use blocks, 18 results, and the one still on screen had none.
#
# The input carries everything needed to draw it, so nothing has to be guessed:
#     questions[] : { question, header, multiSelect, options[] { label, description } }
function Get-SRPendingQuestion {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$JsonlPath,
        # A pending question is by definition at the END, so a bounded tail is not a
        # compromise here -- it is the whole of the evidence. 400 KB covers a very
        # long final turn; the alternative is parsing a 40 MB transcript per session
        # per minute.
        [int]$MaxTailBytes = 409600
    )
    if (-not $JsonlPath -or -not (Test-Path -LiteralPath $JsonlPath)) { return $null }
    $text = ''
    try {
        $fi = Get-Item -LiteralPath $JsonlPath
        if ($fi.Length -eq 0) { return $null }
        # ReadWrite sharing: a live session holds this open for writing, and those
        # are exactly the ones that have a question open.
        $fs = [System.IO.File]::Open($JsonlPath, 'Open', 'Read', 'ReadWrite')
        try {
            $take = [int][Math]::Min($fi.Length, $MaxTailBytes)
            $null = $fs.Seek(-$take, 'End')
            $buf  = New-Object byte[] $take
            $read = $fs.Read($buf, 0, $take)
            $text = [System.Text.Encoding]::UTF8.GetString($buf, 0, $read)
        } finally { $fs.Dispose() }
    } catch { return $null }

    $asked = @{}   # id -> the tool_use input, in the order they appeared
    $order = New-Object System.Collections.Generic.List[string]
    $answered = @{}
    foreach ($ln in ($text -split "`n")) {
        $t = $ln.Trim()
        if (-not $t.StartsWith('{')) { continue }
        # Cheap reject before the expensive parse: ConvertFrom-Json costs ~17 ms a
        # record and most records are neither.
        if ($t -notmatch 'AskUserQuestion' -and $t -notmatch 'tool_result') { continue }
        $r = $null
        try { $r = $t | ConvertFrom-Json } catch { continue }
        $c = $r.message.content
        if ($c -isnot [array]) { continue }
        foreach ($x in $c) {
            if ($x.type -eq 'tool_use' -and $x.name -eq 'AskUserQuestion') {
                $asked[[string]$x.id] = $x.input
                $null = $order.Add([string]$x.id)
            } elseif ($x.type -eq 'tool_result' -and $x.tool_use_id) {
                $answered[[string]$x.tool_use_id] = $true
            }
        }
    }
    if (-not $order.Count) { return $null }

    # The LAST unanswered one. A transcript can carry several asked-and-answered
    # blocks in one tail, and only the final one can still be on screen.
    for ($i = $order.Count - 1; $i -ge 0; $i--) {
        $id = $order[$i]
        if ($answered[$id]) { continue }
        $inp = $asked[$id]
        if (-not $inp -or -not $inp.questions) { continue }
        return [PSCustomObject]@{
            Id        = $id
            Questions = @($inp.questions)
        }
    }
    return $null
}
# --- reading a conversation back out -----------------------------------------
# The transcript is a JSONL of API records, not a conversation. Turning it into
# something readable is mostly deciding what to LEAVE OUT.
#
# Measured across six recent transcripts: text 50, thinking 84, tool_use 129,
# tool_result 130. TOOL TRAFFIC OUTNUMBERS PROSE FIVE TO ONE. Rendering it all
# gives a wall of Bash output with the actual conversation buried in it, which is
# why the terminal collapses tool calls too. Each one becomes a single line here,
# and thinking is folded away, so what is left on screen is what was actually
# said.
#
# ConvertFrom-Json costs ~17 ms a record, so this reads a bounded number of
# records from the END rather than the whole file. A 6 MB transcript would
# otherwise take a minute to open.
function Get-SRTranscriptBlocks {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$JsonlPath,
        # Records, not blocks: one record can carry several content blocks.
        [int]$MaxRecords = 60,
        [int]$MaxTailBytes = 2097152
    )

    $out = New-Object System.Collections.Generic.List[object]
    if (-not $JsonlPath -or -not (Test-Path -LiteralPath $JsonlPath)) { return ,@($out.ToArray()) }

    try {
        $fi = Get-Item -LiteralPath $JsonlPath
        if ($fi.Length -eq 0) { return ,@($out.ToArray()) }
        # ReadWrite sharing: a live session holds this open for writing, and those
        # are exactly the ones worth reading.
        $fs = [System.IO.File]::Open($JsonlPath, 'Open', 'Read', 'ReadWrite')
        try {
            $take = [int][Math]::Min($fi.Length, $MaxTailBytes)
            $null = $fs.Seek(-$take, 'End')
            $buf  = New-Object byte[] $take
            $read = $fs.Read($buf, 0, $take)
            $text = [System.Text.Encoding]::UTF8.GetString($buf, 0, $read)
        } finally { $fs.Dispose() }
    } catch {
        return ,@($out.ToArray())
    }

    $lines = @($text -split "`n" | Where-Object { $_.Trim().StartsWith('{') })
    if (-not $lines.Count) { return ,@($out.ToArray()) }
    $lines = @($lines[[Math]::Max(0, $lines.Count - $MaxRecords)..($lines.Count - 1)])

    function New-Block { param([string]$Kind, [string]$Head, [string]$Body, [string]$Meta)
        return [PSCustomObject]@{ Kind = $Kind; Head = $Head; Body = $Body; Meta = $Meta }
    }

    foreach ($ln in $lines) {
        $r = $null
        try { $r = $ln | ConvertFrom-Json } catch { continue }
        if ($r.type -ne 'user' -and $r.type -ne 'assistant') { continue }
        $m = $r.message
        if (-not $m) { continue }
        $role = [string]$m.role

        $content = $m.content
        if ($content -is [string]) {
            if ("$content".Trim()) { $out.Add((New-Block $(if ($role -eq 'user') { 'you' } else { 'said' }) '' "$content" '')) }
            continue
        }
        foreach ($b in @($content)) {
            if (-not $b -or -not $b.type) { continue }
            switch ($b.type) {
                'text' {
                    $s = "$($b.text)"
                    if ($s.Trim()) { $out.Add((New-Block $(if ($role -eq 'user') { 'you' } else { 'said' }) '' $s '')) }
                }
                'thinking' {
                    $s = "$($b.thinking)"
                    if ($s.Trim()) {
                        $n = @($s -split "`n").Count
                        $out.Add((New-Block 'thinking' "thinking" $s "$n lines"))
                    }
                }
                'tool_use' {
                    # One line. The first meaningful argument is what identifies a
                    # call at a glance -- a command, a path, a pattern -- and the
                    # rest is noise at this altitude.
                    $name = "$($b.name)"
                    $arg  = ''
                    $i = $b.input
                    if ($i) {
                        foreach ($k in @('command','file_path','path','pattern','prompt','description','url','query')) {
                            if ($i.PSObject.Properties[$k] -and $i.$k) { $arg = "$($i.$k)"; break }
                        }
                        if (-not $arg) {
                            $p = @($i.PSObject.Properties | Select-Object -First 1)
                            if ($p.Count) { $arg = "$($p[0].Value)" }
                        }
                    }
                    $arg = ($arg -replace '\s+', ' ').Trim()
                    if ($arg.Length -gt 150) { $arg = $arg.Substring(0, 147) + '...' }
                    $out.Add((New-Block 'tool' $name $arg ''))
                }
                'tool_result' {
                    $s = ''
                    if ($b.content -is [string]) { $s = "$($b.content)" }
                    else {
                        foreach ($c in @($b.content)) { if ($c.type -eq 'text') { $s += "$($c.text)" } }
                    }
                    $s = "$s"
                    $n = @($s -split "`n").Count
                    $err = ($b.PSObject.Properties['is_error'] -and $b.is_error)
                    $out.Add((New-Block 'result' $(if ($err) { 'failed' } else { 'result' }) $s "$n lines"))
                }
            }
        }
    }
    return ,@($out.ToArray())
}

# --- what a conversation LAST SAID ------------------------------------------
# The INBOX row's body. Deliberately a separate, much cheaper reader than
# Get-SRTranscriptBlocks: that one parses a 2 MB tail into every block for the
# reading pane, and running it for every row on a timer is not affordable.
#
# This walks the tail BACKWARDS and stops at the first assistant text it finds,
# so the usual case reads a handful of records rather than sixty.
#
# Two fields, because they answer different questions:
#   Said     the last prose the assistant produced -- "where this conversation
#            got to". Survives the session then running twenty tools.
#   Pending  the last tool_use that came AFTER that prose, i.e. what it is doing
#            or asking for RIGHT NOW. This is what makes a permission dialog
#            legible from the inbox: a dialog writes nothing to the transcript,
#            but the tool_use it is asking about is already recorded.
#
# Only call this for live or recently-active conversations. Decided in the
# 2026-08-22 grill: 117 conversations are tracked and re-reading all of them on
# a timer buys nothing, because a conversation nobody has touched in a week
# cannot have said anything new.
function Get-SRLastSaid {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$JsonlPath,
        [int]$MaxTailBytes = 262144,
        # How many records back to look before giving up. A session that has run
        # a long unbroken chain of tools may genuinely have no prose in the tail.
        [int]$MaxRecords = 120
    )

    $out = [PSCustomObject]@{ Said = ''; Pending = ''; PendingTool = ''; At = $null }
    if (-not $JsonlPath -or -not (Test-Path -LiteralPath $JsonlPath)) { return $out }

    try {
        $fi = Get-Item -LiteralPath $JsonlPath
        if ($fi.Length -eq 0) { return $out }
        $fs = [System.IO.File]::Open($JsonlPath, 'Open', 'Read', 'ReadWrite')
        try {
            $take = [int][Math]::Min($fi.Length, $MaxTailBytes)
            $null = $fs.Seek(-$take, 'End')
            $buf  = New-Object byte[] $take
            $read = $fs.Read($buf, 0, $take)
            $text = [System.Text.Encoding]::UTF8.GetString($buf, 0, $read)
        } finally { $fs.Dispose() }
    } catch { return $out }

    # TrimStart the BOM as well as whitespace. claude's own transcripts have no
    # BOM, but PowerShell 5.1's `Set-Content -Encoding UTF8` writes one, so any
    # fixture written that way loses its FIRST record to this filter -- silently,
    # because a dropped line just looks like a conversation that said nothing.
    # Cost is one extra character in a TrimStart; the confusion it prevents is
    # an hour of reading the wrong function.
    # Trim first, THEN filter, so the trimmed form is what gets parsed: a line
    # that still carries a BOM fails ConvertFrom-Json just as surely as it fails
    # the StartsWith test.
    $lines = @($text -split "`n" |
        ForEach-Object { $_.TrimStart([char]0xFEFF, ' ', "`t") } |
        Where-Object { $_.StartsWith('{') })
    if (-not $lines.Count) { return $out }

    $seen = 0
    for ($i = $lines.Count - 1; $i -ge 0 -and $seen -lt $MaxRecords; $i--) {
        $seen++
        $r = $null
        try { $r = $lines[$i] | ConvertFrom-Json } catch { continue }
        if ($r.type -ne 'assistant') { continue }
        $m = $r.message
        if (-not $m) { continue }

        $content = $m.content
        if ($content -is [string]) {
            if ("$content".Trim()) {
                $out.Said = (Get-SRFirstLine "$content")
                if ($r.timestamp) { try { $out.At = [datetime]$r.timestamp } catch { } }
                return $out
            }
            continue
        }

        # Walk this record's blocks in REVERSE too, so a text block followed by a
        # tool_use in the same record reports the tool as pending rather than
        # losing it.
        $blocks = @($content)
        for ($k = $blocks.Count - 1; $k -ge 0; $k--) {
            $b = $blocks[$k]
            if (-not $b -or -not $b.type) { continue }
            if ($b.type -eq 'tool_use' -and -not $out.Pending) {
                $name = "$($b.name)"
                $arg  = ''
                $inp  = $b.input
                if ($inp) {
                    foreach ($key in @('command','file_path','path','pattern','prompt','description','url','query')) {
                        if ($inp.PSObject.Properties[$key] -and $inp.$key) { $arg = "$($inp.$key)"; break }
                    }
                }
                $arg = ($arg -replace '\s+', ' ').Trim()
                if ($arg.Length -gt 90) { $arg = $arg.Substring(0, 87) + '...' }
                $out.PendingTool = $name
                $out.Pending = $(if ($arg) { "$name($arg)" } else { $name })
            }
            elseif ($b.type -eq 'text' -and "$($b.text)".Trim()) {
                $out.Said = (Get-SRFirstLine "$($b.text)")
                if ($r.timestamp) { try { $out.At = [datetime]$r.timestamp } catch { } }
                return $out
            }
        }
    }
    return $out
}

# One line out of prose that may be many paragraphs, markdown, or a code fence.
# The FIRST meaningful line rather than the first N characters: a leading blank,
# a heading marker or a bullet dash is not what the conversation said.
function Get-SRFirstLine {
    param([string]$Text, [int]$Max = 160)
    $s = "$Text" -replace "`r", ''
    foreach ($ln in ($s -split "`n")) {
        $t = $ln.Trim()
        if (-not $t) { continue }
        if ($t -eq '```' -or $t.StartsWith('```')) { continue }
        # Strip the markdown that carries emphasis rather than meaning.
        $t = $t -replace '^#{1,6}\s+', '' -replace '^[-*]\s+', '' -replace '\*\*', '' -replace '`', ''
        $t = ($t -replace '\s+', ' ').Trim()
        if (-not $t) { continue }
        if ($t.Length -gt $Max) { $t = $t.Substring(0, $Max - 3) + '...' }
        return $t
    }
    return ''
}

# --- what claude itself says about a session --------------------------------
# `claude agents --json` is FIRST-PARTY session state: it needs no TTY, it is
# documented for scripting, and it knows things no amount of transcript reading
# can recover.
#
# It replaces inference for every session that is actually running. Measured on
# 2026-08-22, this machine, 15 live sessions:
#
#   claude agents --json     status 'waiting' / 'idle' / 'busy', plus a
#                            waitingFor of 'input needed' or 'DIALOG OPEN'
#   Get-SRConversationState  called the same session "working, running a tool"
#
# The transcript one was WRONG, and it is wrong in a way it cannot fix: a
# permission dialog writes nothing to the transcript, so a session sitting on a
# dialog looks identical to one mid-tool-call. That is exactly the case the
# operator most wants to see.
#
# The transcript reader stays for conversations that are NOT running -- there is
# no process to ask, and a last-known state is better than nothing.
$script:SR_AgentCache   = $null
$script:SR_AgentCacheAt = $null

function Get-SRAgentStatus {
    [CmdletBinding()]
    param(
        [switch]$Refresh,
        # A spawn plus JSON parse, so it is not free. Callers on a timer pass
        # -Refresh; anything reading it repeatedly within one pass does not.
        [int]$MaxAgeSeconds = 5
    )

    if (-not $Refresh -and $script:SR_AgentCache -and $script:SR_AgentCacheAt -and
        ((Get-Date) - $script:SR_AgentCacheAt).TotalSeconds -lt $MaxAgeSeconds) {
        return $script:SR_AgentCache
    }

    $map = @{}
    try {
        $exe = Get-Command claude -ErrorAction Stop
        # stdout and stderr are kept APART, not merged: a stderr line inside the
        # document would break ConvertFrom-Json, and the failure would look like
        # "claude reports no sessions" rather than like an error. Invoke-SRNativeText
        # separates them by construction - and, being a plain CreateProcess rather
        # than PowerShell's native pipeline, it does not hand this process a console.
        $r = Invoke-SRNativeText -FilePath $exe.Source -Arguments @('agents', '--json')
        if ($r.ExitCode -ne 0 -or -not $r.Out) { throw "claude agents --json exited $($r.ExitCode)" }
        $raw = $r.Out

        # Two traps in three lines, both measured rather than reasoned about.
        #
        # 1. PowerShell's native pipeline hands output back as an ARRAY OF LINES,
        #    and piping that straight into ConvertFrom-Json parses each line on its
        #    own so every one of them fails. Invoke-SRNativeText returns one string,
        #    so the join is now a no-op - kept because it costs nothing and makes
        #    this correct whichever shape arrives.
        # 2. ConvertFrom-Json in PowerShell 5.1 returns a JSON array as a SINGLE
        #    object rather than enumerating it, so `@(... | ConvertFrom-Json)` is
        #    an array of ONE element containing everything -- the same shape as
        #    the ",@()" trap documented above, arrived at from a different
        #    direction. Assign first, then wrap. The symptom was 15 sessions
        #    reported as 0, with "Cannot convert System.Object[] to System.Int64"
        #    in the log from the one iteration over the whole array at once.
        $parsed = ($raw -join "`n") | ConvertFrom-Json
        foreach ($e in @($parsed)) {
            if (-not $e.sessionId) { continue }
            # A background agent reports `state`, an interactive one `status`.
            $st = if ($e.PSObject.Properties['status'] -and $e.status) { [string]$e.status }
                  elseif ($e.PSObject.Properties['state'] -and $e.state) { [string]$e.state }
                  else { '' }
            $wf = if ($e.PSObject.Properties['waitingFor']) { [string]$e.waitingFor } else { '' }

            # 'blocked' is a background agent that cannot proceed without you,
            # which is the same demand on your attention as 'input needed'.
            $needs = ($wf -ne '') -or ($st -eq 'blocked')

            $map["$($e.sessionId)".ToLower()] = [PSCustomObject]@{
                Status    = $st
                WaitingFor= $wf
                Needs     = $needs
                Pid       = $(if ($e.PSObject.Properties['pid']) { [int]$e.pid } else { 0 })
                Kind      = [string]$e.kind
                Name      = [string]$e.name
                Cwd       = [string]$e.cwd
                StartedAt = $(if ($e.startedAt) { [DateTimeOffset]::FromUnixTimeMilliseconds([long]$e.startedAt).LocalDateTime } else { $null })
            }
        }
    } catch {
        # An empty map is honest: it means "claude could not be asked", and every
        # caller falls back to the transcript rather than showing nothing.
        Write-SRLog ("agents --json failed: " + $_.Exception.Message)
        $map = @{}
    }

    $script:SR_AgentCache   = $map
    $script:SR_AgentCacheAt = Get-Date
    return $map
}

# One line of display for a session, preferring what claude says over what the
# transcript implies. $Agent may be $null (not running, or claude unreachable),
# in which case the transcript result is used as-is and marked stale.
function Resolve-SRSessionState {
    param($Agent, $Conv)

    if ($Agent) {
        # 🔴 A NEEDS CLAIM MUST BE CORROBORATED. `claude agents --json` keeps
        # reporting background agents that went `blocked` and were never reaped.
        # Measured 2026-08-23: STRATEGY-PERF-ANALYSIS, state `blocked`, startedAt
        # 33 DAYS earlier, no pid, and no transcript left on disk. It sat in NEEDS
        # YOU -- the band that means ACT ON THIS -- while Send-SRSessionInput
        # refused to type into it for the very reason that made it unactionable.
        # 🔑 The window knew it could not be acted on and filed it under act-on-this.
        #
        # Corroboration is the weakest true thing: either there is a process to
        # type into, or there is a transcript to read. NEITHER, and the claim is a
        # leftover rather than a demand. Note a running background agent reports NO
        # pid, so the pid alone would condemn every one of them -- which is why the
        # transcript is the second half of the test and not an afterthought.
        # 🪤 A Conv OBJECT IS NOT A TRANSCRIPT. Get-SRConversationState returns a
        # result even when the file is gone -- State 'unknown', Detail 'nothing
        # known' -- so [bool]$Conv was true for exactly the case this guard exists
        # to catch. Caught by looking at the screen: STRATEGY-PERF-ANALYSIS still
        # rendered a bright 'waiting' next to its own GONE mark. Something must
        # actually have been READ for the claim to stand.
        $readable = ($Conv -and "$($Conv.State)" -and "$($Conv.State)" -ne 'unknown')
        $backed = (([int]$Agent.Pid -gt 0) -or $readable)
        $stuck  = ([bool]$Agent.Needs -and -not $backed)
        # Stale, deliberately: an unbacked report is the LAST thing that was seen,
        # not something happening now. It costs no new State value -- the row
        # already renders a stale state as "was waiting" in the dim brush, and
        # Get-InboxBand already sends anything stale to the quiet band.
        $out = [PSCustomObject]@{
            State = 'unknown'; Detail = ''; Stale = $stuck
            Needs = ([bool]$Agent.Needs -and $backed)
            Stuck = $stuck
            StuckSince = $(if ($stuck) { $Agent.StartedAt } else { $null })
            Source = 'agent'; Pid = $Agent.Pid; LastPrompt = $null; Title = $null; Mode = $null
        }
        if ($Conv) { $out.LastPrompt = $Conv.LastPrompt; $out.Title = $Conv.Title; $out.Mode = $Conv.Mode }
        switch ($Agent.Status) {
            'busy'    { $out.State = 'working'; $out.Detail = 'running' }
            'blocked' { $out.State = 'waiting'; $out.Detail = 'blocked, needs you' }
            'waiting' {
                $out.State = 'waiting'
                # The distinction the transcript can never make. A dialog wants a
                # CLICK, not a sentence, and telling the two apart is the whole
                # reason this source is better.
                $out.Detail = $(if ($Agent.WaitingFor -match 'dialog') { 'a dialog is open, it wants an answer' }
                                elseif ($Agent.WaitingFor) { $Agent.WaitingFor }
                                else { 'waiting for you' })
            }
            'idle'    { $out.State = 'idle';    $out.Detail = 'at its prompt, nothing pending' }
            default   {
                # An unrecognised status is reported, not silently mapped: claude
                # is free to add one and a guess here would be a lie.
                $out.State = 'unknown'
                $out.Detail = $(if ($Agent.Status) { "claude reports '$($Agent.Status)'" } else { 'running, status unknown' })
            }
        }
        if ($stuck) {
            $since = $(if ($Agent.StartedAt) { $Agent.StartedAt.ToString('d MMM') } else { 'some time ago' })
            $out.Detail = "stuck since $since - nothing is running it, and there is no transcript left to read"
        }
        return $out
    }

    if ($Conv) {
        return [PSCustomObject]@{
            State = $Conv.State; Detail = $Conv.Detail; Stale = $true; Needs = $false
            Stuck = $false; StuckSince = $null
            Source = 'transcript'; Pid = 0
            LastPrompt = $Conv.LastPrompt; Title = $Conv.Title; Mode = $Conv.Mode
        }
    }
    return [PSCustomObject]@{
        State = 'unknown'; Detail = 'nothing known'; Stale = $true; Needs = $false
        Stuck = $false; StuckSince = $null
        Source = 'none'; Pid = 0; LastPrompt = $null; Title = $null; Mode = $null
    }
}

# --- what a conversation is DOING ------------------------------------------
# Liveness answers "is a process holding this conversation". This answers "what
# is that process doing", which is a different question and must never be shown
# as though it were the same one. A conversation can be LIVE and waiting, LIVE
# and working, or long closed and still carry a last-known state.
#
# STATE AND STALENESS ARE SEPARATE, and the first version of this got that wrong:
# it collapsed anything older than the live window into a single 'idle' state,
# which threw away the waiting/working distinction for 110 of 119 conversations
# -- the exact distinction this function exists to provide. State is now always
# what the conversation was last doing, and `Stale` says whether that is current.
# A caller renders "waiting" and "was waiting" from the same two fields.
#
# What the records actually carry, measured on 2026-08-22 across 25 transcripts
# rather than assumed:
#   stop_reason      'tool_use' 466, 'end_turn' 37. That is the whole distinction
#                    between working and waiting: an assistant turn that stopped
#                    to call a tool has not finished, one that stopped at
#                    end_turn has handed back to the operator.
#   isCompactSummary 3 records, alongside compactMetadata -- the compaction step.
#   lastPrompt       on 'last-prompt' records: what the operator last asked.
#   customTitle      operator-set; aiTitle is the generated one. Prefer the former.
#   permission-mode  the mode the session is running under.
#
# It reads the transcript's TAIL and matches on it directly rather than parsing
# every record: ConvertFrom-Json on 40 records per file cost 17 ms EACH, so all
# 119 took 2.07 s -- too slow to sit anywhere near a repaint. Matching the last
# few records instead is roughly twenty times cheaper for the same answer. The
# fields wanted here are flat scalars, which is the one case where matching text
# is defensible; anything structural would have to be parsed properly.
# 15 records was not enough to reach an assistant turn: attachment records
# outnumber assistant ones (658 to 503 in the sample), so a tail of 15 is often
# all bookkeeping. Measured with 15: 23 of 119 came back 'unknown', including 4 of
# the 10 LIVE conversations -- the ones the operator is actually looking at.
$SR_StateTailBytes = 131072
$SR_StateRecords   = 80

function Get-SRConversationState {
    param(
        [Parameter(Mandatory)][string]$JsonlPath,
        [int]$MaxTailBytes = $SR_StateTailBytes
    )

    $out = [PSCustomObject]@{
        State      = 'unknown'
        Detail     = 'no transcript'
        Stale      = $true
        LastActive = $null
        LastPrompt = $null
        Title      = $null
        Mode       = $null
    }
    if (-not $JsonlPath -or -not (Test-Path -LiteralPath $JsonlPath)) { return $out }

    try {
        $fi = Get-Item -LiteralPath $JsonlPath
        $out.LastActive = $fi.LastWriteTime
        $out.Stale = (((Get-Date) - $fi.LastWriteTime).TotalMinutes -ge $SR_LiveWindowMinutes)
        if ($fi.Length -eq 0) { $out.Detail = 'transcript empty'; return $out }

        # ReadWrite sharing: a live session holds this file open for writing, and
        # without it every conversation the operator actually cares about is the
        # one that cannot be read.
        $fs = [System.IO.File]::Open($JsonlPath, 'Open', 'Read', 'ReadWrite')
        try {
            $take = [int][Math]::Min($fi.Length, $MaxTailBytes)
            $null = $fs.Seek(-$take, 'End')
            $buf  = New-Object byte[] $take
            $read = $fs.Read($buf, 0, $take)
            $text = [System.Text.Encoding]::UTF8.GetString($buf, 0, $read)
        } finally { $fs.Dispose() }
    } catch {
        $out.Detail = 'transcript unreadable'
        return $out
    }

    # Whole records only. A mid-file read almost always starts inside one.
    $all = @($text -split "`n" | Where-Object { $_.Trim().StartsWith('{') })
    if (-not $all.Count) { $out.Detail = 'no records in the tail'; return $out }
    $recent = @($all[[Math]::Max(0, $all.Count - $SR_StateRecords)..($all.Count - 1)])
    $blob   = $recent -join "`n"

    if ($m = [regex]::Match($blob, '"customTitle"\s*:\s*"((?:[^"\\]|\\.)*)"')) { if ($m.Success) { $out.Title = $m.Groups[1].Value } }
    if (-not $out.Title -and ($m = [regex]::Match($blob, '"aiTitle"\s*:\s*"((?:[^"\\]|\\.)*)"')) -and $m.Success) { $out.Title = $m.Groups[1].Value }
    if (($m = [regex]::Match($blob, '"mode"\s*:\s*"([a-zA-Z]+)"')) -and $m.Success) { $out.Mode = $m.Groups[1].Value }

    $pm = [regex]::Matches($blob, '"lastPrompt"\s*:\s*"((?:[^"\\]|\\.)*)"')
    if ($pm.Count) {
        $p = $pm[$pm.Count - 1].Groups[1].Value -replace '\\n', ' ' -replace '\\"', '"' -replace '\s+', ' '
        if ($p.Length -gt 120) { $p = $p.Substring(0, 117) + '...' }
        $out.LastPrompt = $p.Trim()
    }

    # Compaction counts only if it is what JUST happened, so look at the last few
    # records rather than anywhere in the tail.
    $tailFew = @($all[[Math]::Max(0, $all.Count - 6)..($all.Count - 1)]) -join "`n"
    if ($tailFew -match '"isCompactSummary"\s*:\s*true' -or $tailFew -match '"compactMetadata"\s*:\s*\{') {
        $out.State  = 'summarising'
        $out.Detail = 'compacting the conversation'
        return $out
    }

    # The last record that is a TURN, not the last line. Attachment, latch and
    # title records are written after a turn ends, so the literal last line is
    # usually bookkeeping and says nothing about who owes whom a reply.
    $last = $null
    for ($i = $recent.Count - 1; $i -ge 0; $i--) {
        if ($recent[$i] -match '"type"\s*:\s*"(user|assistant)"') { $last = $recent[$i]; break }
    }
    if ($null -eq $last) { $last = $recent[$recent.Count - 1] }
    $sm   = [regex]::Matches($blob, '"stop_reason"\s*:\s*"([a-z_]+)"')
    $stop = if ($sm.Count) { $sm[$sm.Count - 1].Groups[1].Value } else { $null }

    # A turn that stopped to call a tool has not finished; one that stopped at
    # end_turn has handed back. If the very last record is the operator's, the
    # session has been given something and has not answered yet.
    if ($last -match '"type"\s*:\s*"user"') {
        $out.State = 'working'; $out.Detail = 'given a prompt, no reply yet'
    } elseif ($stop -eq 'tool_use') {
        $out.State = 'working'; $out.Detail = 'running a tool'
    } elseif ($stop -eq 'end_turn' -or $stop -eq 'stop_sequence') {
        $out.State = 'waiting'; $out.Detail = 'waiting for you'
    } elseif ($stop -eq 'max_tokens') {
        $out.State = 'waiting'; $out.Detail = 'stopped at the token limit'
    } else {
        $out.State = 'unknown'; $out.Detail = 'no assistant turn in the tail'
    }

    # Say it in the past tense when nothing has moved for a while, so a state
    # frozen an hour ago cannot read as something happening now.
    if ($out.Stale -and $out.State -ne 'unknown') { $out.Detail = 'last seen ' + $out.Detail }
    return $out
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
# ===========================================================================
# PER-SESSION SETTINGS — "the control plane".
#
# 🔴 EVERY ONE OF THESE IS A LAUNCH FLAG. claude reads them once, at startup;
# there is no way to change the model, the permission mode or the tool limits of
# a session that is already running. So changing one here does nothing until the
# conversation is relaunched, and the window has to say so rather than let you
# believe a dropdown took effect.
#
# They live on the session record in the registry as `prefs`, which is additive:
# a session written before this existed simply has none, and an older build
# ignores a key it does not know.
# ===========================================================================

# The values claude will actually accept, from `claude --help` on 2026-08-29.
# Validated HERE rather than at the dropdown, because a bad value does not fail
# politely - it fails the launch, and the conversation just never opens.
$SR_PermissionModes = @('acceptEdits', 'auto', 'bypassPermissions', 'manual', 'dontAsk', 'plan')
$SR_EffortLevels    = @('low', 'medium', 'high', 'xhigh', 'max')

function Get-SRSessionPref { param($Session, [string]$Name)
    if (-not $Session) { return $null }
    $p = $Session.prefs
    if (-not $p) { return $null }
    if ($null -eq $p.PSObject.Properties[$Name]) { return $null }
    return $p.$Name
}

function Set-SRSessionPref { param($Session, [string]$Name, $Value)
    if (-not $Session) { return }
    if ($null -eq $Session.PSObject.Properties['prefs'] -or -not $Session.prefs) {
        $Session | Add-Member -NotePropertyName prefs -NotePropertyValue ([PSCustomObject]@{}) -Force
    }
    $p = $Session.prefs
    if ($null -eq $p.PSObject.Properties[$Name]) {
        $p | Add-Member -NotePropertyName $Name -NotePropertyValue $Value -Force
    } else { $p.$Name = $Value }
}

# Remote Control is ON unless a conversation says otherwise - that is what every
# session on this machine has done since the tool shipped, and a settings feature
# must not quietly switch it off for all of them.
function Test-SRRemoteWanted { param($Session)
    $v = Get-SRSessionPref $Session 'remoteControl'
    if ($null -eq $v) { return $true }
    return [bool]$v
}

function Test-SRHiddenWanted { param($Session)
    return [bool](Get-SRSessionPref $Session 'hidden')
}

# A conversation's settings, as claude's own argv.
#
# 🪤 NO LEADING COMMA HERE, and that is deliberate - it is the ",@()" trap read
# backwards. `return ,$arr` exists to stop a MULTI-element array being unrolled,
# but applied to an EMPTY one it emits a one-element array holding the empty
# array, so `@(Get-SRSessionArgs $s).Count` came back as 1 for a conversation
# with no settings at all, and the first real flag landed at index 1 instead of
# 0. Caught by the test written alongside this, not by reading it. Returned
# bare: empty emits nothing (@() -> 0), and every caller either wraps in @() or
# passes it to a [string[]] parameter, both of which are correct on the unrolled
# form.
function Get-SRSessionArgs { param($Session)
    $a = New-Object System.Collections.Generic.List[string]
    $m = "$(Get-SRSessionPref $Session 'model')".Trim()
    if ($m) { $a.Add('--model'); $a.Add($m) }
    $e = "$(Get-SRSessionPref $Session 'effort')".Trim()
    if ($e -and $SR_EffortLevels -contains $e) { $a.Add('--effort'); $a.Add($e) }
    $pm = "$(Get-SRSessionPref $Session 'permissionMode')".Trim()
    if ($pm -and $SR_PermissionModes -contains $pm) { $a.Add('--permission-mode'); $a.Add($pm) }
    foreach ($t in @(Get-SRSessionPref $Session 'allowedTools')) {
        if ("$t".Trim()) { $a.Add('--allowedTools'); $a.Add("$t".Trim()) }
    }
    foreach ($t in @(Get-SRSessionPref $Session 'disallowedTools')) {
        if ("$t".Trim()) { $a.Add('--disallowedTools'); $a.Add("$t".Trim()) }
    }
    return $a.ToArray()
}

# A one-line summary for the row, so the settings are visible without opening
# anything. Empty when a conversation is on all the defaults.
function Get-SRSessionArgsLabel { param($Session)
    $bits = New-Object System.Collections.Generic.List[string]
    $m = "$(Get-SRSessionPref $Session 'model')".Trim();  if ($m)  { $bits.Add($m) }
    $e = "$(Get-SRSessionPref $Session 'effort')".Trim();  if ($e)  { $bits.Add($e) }
    $pm = "$(Get-SRSessionPref $Session 'permissionMode')".Trim(); if ($pm) { $bits.Add($pm) }
    if (-not (Test-SRRemoteWanted $Session)) { $bits.Add('no remote') }
    if (Test-SRHiddenWanted $Session) { $bits.Add('hidden') }
    $n = @(@(Get-SRSessionPref $Session 'allowedTools') + @(Get-SRSessionPref $Session 'disallowedTools') |
           Where-Object { "$_".Trim() }).Count
    if ($n) { $bits.Add("$n tool rule(s)") }
    return (($bits | Where-Object { $_ }) -join '  ·  ')
}

function New-SRBootScript {
    param(
        [Parameter(Mandatory)][string]$Dir,
        [string]$SessionId,
        [Parameter(Mandatory)][string]$Title,
        [string[]]$ClaudeArgs,
        # Remote Control names THIS remote session. Off means the flag is not
        # passed at all, which is different from passing it with an empty name.
        [bool]$RemoteControl = $true
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
# 🔴 THE NAME HAS TO SURVIVE A RE-REGISTRATION, NOT JUST THE LAUNCH.
#
# --remote-control <name> names THIS remote registration and nothing else. Sign in
# to a different account, or drop and re-enable Remote Control by hand, and that
# registration is replaced by one claude names ITSELF -- from
# --remote-control-session-name-prefix, which defaults to the HOSTNAME. Every
# session on the machine then shows up under the same prefix, which is how the
# operator ended up with twenty remote sessions and no way to tell them apart.
#
# Setting the prefix to this conversation's own title fixes the fallback rather
# than the launch: the explicit --remote-control below still wins while it lasts,
# and if it is ever replaced the auto-generated name starts with the title instead
# of the hostname. Purely additive -- it is only ever read when there is no
# explicit name to use.
$env:CLAUDE_REMOTE_CONTROL_SESSION_NAME_PREFIX = '__TITLE__'
# -n writes a DURABLE custom-title into the conversation (precedence rule 2);
# --remote-control names only THIS remote session (rule 1). Both are needed.
__CLAUDELINE__
'@
    # Built out here, then substituted, so every value stays inside a PowerShell
    # single-quoted literal and no title can be re-parsed as syntax.
    $q = { param($v) "'" + ([string]$v).Replace("'", "''") + "'" }
    $parts = @('& claude')
    if ($SessionId) { $parts += @('--resume', (& $q $SessionId)) }
    $parts += @('-n', (& $q $Title))
    if ($RemoteControl) { $parts += @('--remote-control', (& $q $Title)) }
    foreach ($a in @($ClaudeArgs)) { if ($a) { $parts += (& $q $a) } }

    $body = $body.Replace('__SCRUBVARS__',  (($SR_ChildVars | ForEach-Object { "'" + $_ + "'" }) -join ','))
    $body = $body.Replace('__DIR__',        $Dir.Replace("'", "''"))
    $body = $body.Replace('__TITLE__',      $Title.Replace("'", "''"))
    $body = $body.Replace('__CLAUDELINE__', ($parts -join ' '))

    # THE BOOT PATH IS DETERMINISTIC, so anything that freezes that ONE path takes
    # this conversation out of every future restore, silently, forever. On
    # 2026-08-23 an antivirus quarantine did exactly that to
    # boot-MM-toolbox-444f91ed.ps1: the name became unwritable while every other
    # name in the same folder stayed fine. A conversation is worth more than its
    # filename, so take a different one rather than fail the session.
    try {
        Set-Content -LiteralPath $boot -Value $body -Encoding utf8 -ErrorAction Stop
    } catch {
        $alt = ($boot -replace '\.ps1$', '') + '-b.ps1'
        Write-SRWarn ("could not write {0} ({1}) - using {2}" -f (Split-Path $boot -Leaf), $_.Exception.Message.Split([char]10)[0], (Split-Path $alt -Leaf))
        Set-Content -LiteralPath $alt -Value $body -Encoding utf8 -ErrorAction Stop
        $boot = $alt
    }
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

# ===========================================================================
# A HIDDEN SESSION — no window, and it outlives this tool.
#
# The same boot script, run in a console that is never shown, instead of in a
# Windows Terminal tab. `powershell -WindowStyle Hidden` still gets a real
# console: claude needs one, the relay reads one, and the window simply is not
# painted.
#
# 🔑 PROVEN BEFORE IT WAS BUILT (2026-08-29). Against a throwaway `claude --bg`
# session: the hidden console read back through [SRCon]::Screen, keys sent with
# [SRCon]::Send REACHED THE SESSION - confirmed by finding the marker in
# `claude logs`, i.e. asked of claude rather than of the screen it was typed
# into - and killing the viewer left the session running. So hiding costs
# nothing: a hidden conversation is still readable and still answerable.
#
# 🪤 NOT `claude --bg`. That is Claude Code's own background mode and it works,
# but a --bg session can only be reached with `claude attach`, which un-hides it.
# Running the ordinary boot script in an unshown console keeps every existing
# mechanism - resume by session id, the transcript, the relay, Go to terminal -
# working unchanged. The window is the only thing that differs.
function Start-SRHiddenSession {
    param(
        [Parameter(Mandatory)][string]$Dir,
        [Parameter(Mandatory)][string]$BootScript,
        [Parameter(Mandatory)][string]$Title
    )
    if (-not (Test-Path -LiteralPath $Dir -PathType Container)) {
        throw "directory no longer exists: $Dir"
    }
    $p = Start-Process -FilePath 'powershell.exe' -PassThru -WindowStyle Hidden `
            -WorkingDirectory $Dir `
            -ArgumentList @('-NoExit', '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $BootScript)
    Write-SRLog ("  [ok]   hidden session '{0}' started, shell pid {1}" -f $Title, $p.Id)
    return $p.Id
}

# Bring a hidden conversation onto the screen. There is no way to move a console
# between windows, so this opens the conversation in a REAL tab and stops the
# hidden one - same conversation, same transcript, now visible.
function Show-SRHiddenSession {
    param(
        [Parameter(Mandatory)][int]$ProcessId,
        [Parameter(Mandatory)][string]$Dir,
        [Parameter(Mandatory)][string]$BootScript,
        [Parameter(Mandatory)][string]$Title
    )
    # Stop the hidden one FIRST: two claude processes on one conversation would
    # both hold its transcript, and the second would resume a session the first
    # is still writing.
    $proc = $null
    try { $proc = Get-CimInstance Win32_Process -Filter "ProcessId=$ProcessId" -ErrorAction Stop } catch { }
    if ($proc) {
        foreach ($kid in @(Get-CimInstance Win32_Process -Filter "ParentProcessId=$ProcessId" -ErrorAction SilentlyContinue)) {
            if ($kid.Name -eq 'claude.exe') { try { Stop-Process -Id ([int]$kid.ProcessId) -Force -ErrorAction Stop } catch { } }
        }
        try { Stop-Process -Id $ProcessId -Force -ErrorAction Stop } catch { }
        Start-Sleep -Milliseconds 600
    }
    Start-SRSession -Dir $Dir -BootScript $BootScript -Title $Title
}
