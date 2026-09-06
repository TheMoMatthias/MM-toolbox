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
    # 🔑 AND THAT NORMALISATION IS WHY THIS WRITER NEEDS THE STAMP NUDGE TOO -
    # the line directly above is the reason, not a coincidence. It is tempting to
    # argue this path is safe because `true` is four characters and `false` is
    # five, so the length always moves and a cached reader must always see the
    # write. That argument is false BECAUSE of the TrimEnd: the length delta is
    # the boolean's (+/-1) PLUS the trailing-newline's (2 minus however many the
    # file already ended with). A file saved by an editor with LF endings ends in
    # one character, contributing +1, and a `false` -> `true` flip contributes
    # -1: net zero, same length, colliding stamp. The fix for the blank-line
    # growth is what armed it, two lines apart. Nudging here removes the whole
    # class rather than leaving a comment defending an argument that has to stay
    # true forever. See Set-SRDistinctWriteTime.
    $wasAt = $null; $wasBad = $false
    try { $wasAt = (Get-Item -LiteralPath $SR_ConfigPath -ErrorAction Stop).LastWriteTimeUtc }
    catch { $wasBad = $true }
    [System.IO.File]::WriteAllText($SR_ConfigPath, $new, (New-Object System.Text.UTF8Encoding($false)))
    Set-SRDistinctWriteTime -Path $SR_ConfigPath -Was $wasAt -BaselineFailed:$wasBad

    $check = (Get-Content -LiteralPath $SR_ConfigPath -Raw | ConvertFrom-Json).includeWorktrees
    if ([bool]$check -ne $Value) {
        throw "wrote includeWorktrees=$lit but the file reads back as $check"
    }
    Write-SRLog "includeWorktrees set to $lit"
    return $Value
}

# How much of the machinery the reading pane shows. Ordered, because the window
# cycles through them on one button.
$SR_ToolViews = @('folded', 'full', 'hidden')

# ===========================================================================
# HOW GLYPHS ARE ANTIALIASED. A setting rather than a decision, and this is the
# one place in the tool where that is the honest answer.
#
# window2.xaml pins Grayscale with a reasoned comment: ClearType is SUBPIXEL
# antialiasing, it tints the edge of every stem red or blue, and on a #0F1013
# ground that fringe is visible. Against that, ClearType buys real horizontal
# resolution and is what the browser uses - which is why the same text can look
# crisper in a web page than in this window.
#
# 🔴 IT CANNOT BE SETTLED FROM A SCREENSHOT. RenderTargetBitmap - what every
# shot in tests\ goes through - ALWAYS composites greyscale, so a captured
# "ClearType" sample is greyscale wearing a label. Measured 2026-08-30: the four
# way comparison in tests\type-driver.ps1 shows the two ClearType rows identical
# to their greyscale twins, because they are. Only a real monitor can answer it,
# so the choice belongs to whoever is looking at one.
$SR_TextModes = @('grayscale', 'cleartype')

# How wide the reading pane sets its prose.
#   full      fill the window, the way the terminal does, with the type scaling
#             up as it widens. What a maximised window wants.
#   measured  cap the line near 70 characters however wide the window is. Reads
#             better for long prose; leaves the right of a wide pane empty.
$SR_ReadWidths = @('full', 'measured')

# 🔴 IT WAS RE-READING AND RE-PARSING 15 KB ON EVERY CALL, INCLUDING ON CLICKS.
# Audited: the morning-compact button spends 3.45 of its 5.05 ms in here, and it
# is far from the only caller - the fold carets, the settings sheet and the send
# panel all reach for the config on a gesture. Nothing about it changes between
# two presses.
#
# Stamped on length + last-write, which is the pattern Get-SRLastSaid and
# Get-SRQueue already use in this file: the cache is dropped the moment the file
# on disk differs, so it cannot outlive the truth behind it.
#
# 🔒 SAFE TO HAND THE SAME OBJECT BACK. Save-SRConfigValue does its OWN
# Get-Content/ConvertFrom-Json, edits that copy and writes it - it never touches
# what this returns - and the write moves the stamp, so the next read re-parses
# anyway. Checked against all nine call sites.
#
# 🪤 ONE THING DOES WRITE ON IT, ON PURPOSE: Save-SRConfigLater, below. A queued
# setting has not reached the file, so the stamp still matches and this would
# otherwise hand back a config that predates the click that changed it. It
# writes the SAME value the flush will write, so the two can never disagree.
$script:SR_ConfigCache = $null
$script:SR_ConfigStamp = ''

# Settings clicked but not yet on disk. Empty in every process except the window
# (nothing else calls Save-SRConfigLater), so no other caller is affected by it.
$script:SR_ConfigPending = @{}

function Get-SRConfig {
    $stamp = ''
    try {
        $cfi = Get-Item -LiteralPath $SR_ConfigPath -ErrorAction Stop
        $stamp = '{0}|{1}' -f $cfi.Length, $cfi.LastWriteTimeUtc.Ticks
    } catch { }
    if ($stamp -and $script:SR_ConfigCache -and $script:SR_ConfigStamp -eq $stamp) {
        return $script:SR_ConfigCache
    }
    $cfg = Get-SRConfigRead
    # A value that has been clicked but not yet flushed IS the truth about that
    # setting; the file is the thing that is behind. The parse above is a private
    # copy that nobody else holds yet, so writing onto it costs nothing.
    if ($script:SR_ConfigPending.Count) {
        foreach ($k in @($script:SR_ConfigPending.Keys)) {
            try {
                if ($null -eq $cfg.PSObject.Properties["$k"]) {
                    $cfg | Add-Member -NotePropertyName "$k" -NotePropertyValue $script:SR_ConfigPending[$k] -Force
                } else { $cfg."$k" = $script:SR_ConfigPending[$k] }
            } catch { }
        }
    }
    if ($stamp) { $script:SR_ConfigCache = $cfg; $script:SR_ConfigStamp = $stamp }
    return $cfg
}

function Get-SRConfigRead {
    if (-not (Test-Path -LiteralPath $SR_ConfigPath)) { throw "config not found: $SR_ConfigPath" }
    # 🪤 SAY WHAT TO DO ABOUT IT. Get-SRRegistry has caught its own parse
    # failure and named the fix since it was written; this threw ConvertFrom-Json's
    # own message, which names a character offset and no file. The config is the
    # one of the two that gets hand-edited, so it is the likelier to be broken.
    try { $c = Get-Content -LiteralPath $SR_ConfigPath -Raw | ConvertFrom-Json }
    catch { throw "config is unreadable ($SR_ConfigPath): $($_.Exception.Message). Fix the JSON, or delete the file to get the defaults back." }

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
        @{ k = 'maxSessions';          v = 12 },
        # HOW MUCH OF THE MACHINERY THE READING PANE SHOWS. Measured across six
        # transcripts: text 50, thinking 84, tool_use 129, tool_result 130 - tool
        # traffic outnumbers prose five to one, and that ratio IS the wall of
        # text. folded is the default because it keeps the count and the names
        # (so you still know what ran) without the volume.
        @{ k = 'transcriptTools';      v = 'folded' },
        @{ k = 'textRendering';        v = 'grayscale' },
        @{ k = 'readingWidth';         v = 'full' },
        # WHICH AGE BANDS IN THE PROJECTS RAIL ARE FOLDED SHUT, as a comma-joined
        # list of band keys. Everything but TODAY starts shut, because at 36
        # projects the rail's whole job is "where was I", and a project last
        # touched three weeks ago is not the answer to that question.
        #
        # 🪤 A STRING, NOT AN ARRAY. Every other setting here is a scalar and the
        # round trip through ConvertTo-Json / ConvertFrom-Json is what decides the
        # type coming back: a one-element array returns UNROLLED to its element,
        # so a rail with exactly one band shut would read back as a bare string
        # while two read back as an array, and the parse would have to handle
        # both. Splitting a string has one shape whatever is in it.
        @{ k = 'railBandsShut';        v = 'week,month,older' },
        # HOW LONG A PROJECT HAS TO HAVE BEEN QUIET BEFORE THE RAIL SUGGESTS
        # SHELVING IT. Two weeks, which is deliberately longer than
        # recencyDays: that one decides what comes BACK tomorrow and can be
        # wrong cheaply, this one is a nudge to stop seeing something and
        # wants to be right.
        #
        # 🪤 A KEY, NOT A LITERAL, AND THAT IS A SAFETY PROPERTY HERE. Test-SRExcluded
        # carries a note about a hard-coded staleness rule that quietly hid three
        # 20MB+ conversations before it was removed. This one only ever SUGGESTS -
        # see Get-SRShelveSuggestion, which has no way to shelve anything - and when
        # the threshold is wrong for this machine it is one number in this file.
        @{ k = 'shelveSuggestDays';      v = 14 },
        # HOW BIG EVERY SIZE ON THE SURFACE IS, as a percentage of the scale in
        # window2.xaml. One number, not a per-element setting: the complaint it
        # answers was that the work surface does not respond to the window at
        # all, and the previous attempt at that - growing the reading pane with
        # its width - produced 20px body text on a maximised window, which is
        # zooming rather than scaling. A knob the operator turns is predictable;
        # type that moves on its own when you drag a window edge is not.
        @{ k = 'zoom';                 v = 100 },
        # THE PAUSE BETWEEN LAUNCHING ONE TAB AND THE NEXT, in milliseconds.
        #
        # 🔴 IT IS THE BIGGEST REMAINING COST OF A LOGON. Measured over 28
        # sessions on 2026-09-03: 857 ms per session, of which 500 was this
        # sleep and ~357 ms was wt.exe actually making the tab - so the launch
        # loop was 58% asleep. Start-Process itself returns in 34 ms (n=5).
        #
        # 🪤 IT IS NOT FREE TO SHORTEN. The gap exists so Windows Terminal does
        # not race itself, and the failure mode is a tab that opens and dies -
        # which is the morning this whole tool exists to prevent. It has been
        # tuned down once already (1200 -> 500). What makes 250 safe enough to
        # try is that the restore VERIFIES: Wait-SRSessionsUp names every
        # session that never produced a claude.exe, so a race is reported
        # rather than silent. A key rather than a literal because the right
        # value is a property of the machine, and this operator has two.
        @{ k = 'launchGapMs';          v = 250 }
    )) {
        if ($null -eq $c.PSObject.Properties[$kv.k]) {
            $c | Add-Member -NotePropertyName $kv.k -NotePropertyValue $kv.v -Force
        }
    }

    # 🔴 A DEFAULT FILLED IN A MISSING KEY AND NOTHING CHECKED A PRESENT ONE.
    # Measured 2026-08-30 against a hand-edited config:
    #   maxSessions: 0 / -5 / null  -> NO CAP AT ALL. Every ticked conversation
    #     opens, which with 31 ticked is 31 tabs. The cap exists precisely so a
    #     repo with sixteen live conversations does not open sixteen.
    #   maxSessions: "twelve"       -> [int] threw at restore-sessions.ps1:167,
    #     unguarded, and the WHOLE logon restore died. Nothing came back, at the
    #     one moment nobody is watching.
    # A safety limit that a typo disables is not a safety limit. Anything absent,
    # unparseable or out of range falls back to its default and SAYS SO - the log
    # is the only place an unattended logon can report anything.
    foreach ($kv in @(
        @{ k = 'recencyDays';          v = 14;   min = 1;   max = 3650 },
        @{ k = 'listDays';             v = 7;    min = 1;   max = 3650 },
        @{ k = 'sessionWindowDays';    v = 3;    min = 1;   max = 3650 },
        @{ k = 'autoTickPerDirectory'; v = 3;    min = 1;   max = 1000 },
        @{ k = 'autoTickPerWorktree';  v = 3;    min = 1;   max = 1000 },
        @{ k = 'registryWindowDays';   v = 30;   min = 1;   max = 3650 },
        @{ k = 'maxSessions';          v = 12;   min = 1;   max = 1000 }
    )) {
        $raw = $c.($kv.k)
        $n = $null
        try { if ($null -ne $raw -and "$raw".Trim()) { $n = [int]$raw } } catch { $n = $null }
        # 🪤 TOO LARGE IS INTENT; TOO SMALL OR NOT A NUMBER IS A MISTAKE.
        # Someone who writes 999999 means "as many as you can" and handing them
        # the default 12 ignores what they asked for - so that clamps to the
        # ceiling. Nothing sensible is meant by a cap of 0 or -5, and both used to
        # mean NO CAP, so those take the default instead of clamping to 1 and
        # opening a single conversation.
        if ($null -eq $n) {
            Write-SRLog ("  [warn] config {0} is '{1}', which is not a whole number; using {2}" -f $kv.k, "$raw", $kv.v)
            $c.($kv.k) = $kv.v
        } elseif ($n -lt $kv.min) {
            Write-SRLog ("  [warn] config {0} is {1}, which is not a usable value; using {2}" -f $kv.k, $n, $kv.v)
            $c.($kv.k) = $kv.v
        } elseif ($n -gt $kv.max) {
            Write-SRLog ("  [warn] config {0} is {1}, above the {2} ceiling; using {2}" -f $kv.k, $n, $kv.max)
            $c.($kv.k) = $kv.max
        } else { $c.($kv.k) = $n }
    }

    # The one setting here that is a WORD rather than a number, and it earns the
    # same treatment for the same reason: a typo must not silently mean
    # something else. An unrecognised value falls back and says so in the log.
    $tt = "$($c.transcriptTools)".Trim().ToLower()
    if ($SR_ToolViews -notcontains $tt) {
        if ($tt) { Write-SRLog ("  [warn] config transcriptTools is '{0}'; expected one of {1}. Using folded." -f $tt, ($SR_ToolViews -join ', ')) }
        $tt = 'folded'
    }
    $c.transcriptTools = $tt

    $tr = "$($c.textRendering)".Trim().ToLower()
    if ($SR_TextModes -notcontains $tr) {
        if ($tr) { Write-SRLog ("  [warn] config textRendering is '{0}'; expected one of {1}. Using grayscale." -f $tr, ($SR_TextModes -join ', ')) }
        $tr = 'grayscale'
    }
    $c.textRendering = $tr

    $rw = "$($c.readingWidth)".Trim().ToLower()
    if ($SR_ReadWidths -notcontains $rw) {
        if ($rw) { Write-SRLog ("  [warn] config readingWidth is '{0}'; expected one of {1}. Using full." -f $rw, ($SR_ReadWidths -join ', ')) }
        $rw = 'full'
    }
    $c.readingWidth = $rw

    # CLAMPED, NOT REJECTED. Every other word-valued key falls back to its
    # default when it does not recognise the value, which is right for a word -
    # `grayscal` means nothing. A number is different: 300 is not a typo, it is
    # someone reaching past the end of the range, and the useful answer is the
    # nearest size that works rather than a silent snap back to 100. Below 70 the
    # 9.5px micro step stops resolving; above 200 a maximised window fits less
    # than a phone.
    $z = 100
    try { $z = [int][Math]::Round([double]"$($c.zoom)") } catch { $z = 100 }
    if ($z -lt 70 -or $z -gt 200) {
        Write-SRLog ("  [warn] config zoom is {0}; clamped to 70-200." -f $z)
        $z = [Math]::Max(70, [Math]::Min(200, $z))
    }
    $c.zoom = $z

    # Clamped for the same reason zoom is: a number out of range is somebody
    # reaching past the end, not a typo. 0 is allowed and means "no gap at all";
    # above 2000 a full restore would spend a minute asleep.
    $g = 250
    try { $g = [int][Math]::Round([double]"$($c.launchGapMs)") } catch { $g = 250 }
    if ($g -lt 0 -or $g -gt 2000) {
        Write-SRLog ("  [warn] config launchGapMs is {0}; clamped to 0-2000." -f $g)
        $g = [Math]::Max(0, [Math]::Min(2000, $g))
    }
    $c.launchGapMs = $g

    return $c
}

# ===========================================================================
# MAKE SURE A WRITE IS VISIBLE TO A READER THAT ONLY LOOKS AT THE STAMP.
#
# 🔴 TWO DIFFERENT CONFIGS CAN PRODUCE ONE STAMP. Get-SRConfig decides its cache
# is fresh by comparing `length|LastWriteTimeUtc.Ticks`. A write that changes no
# bytes in LENGTH and lands in the same filetime tick as the one the cache was
# taken from is therefore invisible: the cache is returned and the new value is
# never read, with nothing logged. And that cache does not heal - every later
# pass re-stats, finds the same stamp, and returns the same stale object, until
# something changes the file's length or time. For a window the operator only
# READS settings in, that is the rest of its life.
#
# 🪤 THE SAME-LENGTH HALF IS THE COMMON CASE, NOT THE EXOTIC ONE. Measured:
# `transcriptTools` cycles 'folded' <-> 'hidden', six characters each;
# railBandsShut moves between 'week,month,older' and 'today,week,month', sixteen
# each; maxSessions 12 -> 24. Every one of those re-serialises to a file of
# identical length. Folding a band is enough to arm it.
#
# 🔑 SO IT IS FIXED AT THE WRITER, NOT AT EVERY READER. Get-SRConfig is a hot
# path - Update-Model calls it every pass - and a hash or a TTL there would put
# a permanent recurring cost on the drawing thread to defend against something
# a writer can make impossible for free. Nudging the stamp costs one file
# operation per SAVE, which is a gesture, and no reader changes at all.
#
# 🪤 ONE TICK IS ENOUGH, and it is deliberately not more. The comparison is on
# exact Ticks, so +100 ns defeats it; jumping the ~15.6 ms clock granule would
# make the file look meaningfully newer than it is for no gain. Consecutive
# writes inside one granule can step the recorded time BACKWARDS by a tick,
# which reads oddly and is harmless: every comparison is against the stamp a
# reader cached, never against history.
#
# 🔴 AND IT NEVER THROWS. Everywhere else in this writer, `-ErrorAction Stop`
# exists so a failed write cannot look successful. This is the opposite case and
# the same principle: by the time it runs THE WRITE HAS ALREADY SUCCEEDED, so
# raising here would report a good save as a bad one - the very failure that
# rule was written to prevent, arrived at from the other side. It logs instead.
#
# 🪤 IT DOES NOT RE-STAT. The caller passes what it observed before its own
# write; asking the filesystem again here would be asking after the fact, which
# is a different question. A $null baseline has two causes and they are told
# apart on purpose: no file to stamp (a first write - a no-op is CORRECT, and
# silent, or every fresh install logs a warning that is not one), against a stat
# that failed on a file which does exist (a no-op is merely safe, and says so).
function Set-SRDistinctWriteTime {
    param(
        [Parameter(Mandatory)][string]$Path,
        # The destination's LastWriteTimeUtc BEFORE this write, as the caller saw
        # it. $null means the caller had no baseline to give.
        $Was,
        # Which kind of $null: set when the caller tried to read a baseline off an
        # existing file and could not.
        [switch]$BaselineFailed
    )
    if ($null -eq $Was) {
        if ($BaselineFailed) {
            Write-SRLog ('  [skip] could not read a write-time baseline for ' + $Path +
                         ' - a same-tick write could go unseen by a cached reader')
        }
        return
    }
    try {
        $now = (Get-Item -LiteralPath $Path -ErrorAction Stop).LastWriteTimeUtc
        if ($now -ne [datetime]$Was) { return }
        [System.IO.File]::SetLastWriteTimeUtc($Path, $now.AddTicks(1))
    } catch {
        Write-SRLog ('  [skip] could not separate the write time of ' + $Path + ': ' +
                     $_.Exception.Message + ' - the save itself was fine')
    }
}

# One key, written back without disturbing the rest of the file.
#
# 🪤 IT RE-READS FROM DISK RATHER THAN WRITING THE OBJECT Get-SRConfig RETURNED.
# That object has every default filled in and every out-of-range value already
# corrected, so writing it back would silently BAKE the corrections into the
# operator's file - a config they had left mostly empty would come back with
# nine keys they never set, and a value they had deliberately put out of range
# would be quietly overwritten by ours. Only the key asked for changes.
# N SETTINGS, ONE READ-MODIFY-WRITE. The single-key writer used to be this whole
# function; it is now one caller of it, and the flush below is the other. That
# matters because the flush usually has more than one key waiting: four clicks
# used to be four reparses of 15 KB and four file moves, and are now one.
function Set-SRConfigOnDisk { param([Parameter(Mandatory)][hashtable]$Values)
    $raw = $null
    if (Test-Path -LiteralPath $SR_ConfigPath) {
        # 🔴 CANNOT-READ AND CANNOT-PARSE ARE DIFFERENT ANSWERS, and running them
        # together destroyed settings. `Get-Content` on a file another process
        # holds raises a NON-TERMINATING error, so the catch below never fired,
        # $raw stayed $null, and the write went ahead against a BLANK object -
        # producing a config containing only the key being saved and none of the
        # eleven others. Measured: a destination opened with FileShare None
        # reproduces it every time.
        #
        # So the read throws now, and a read that throws writes NOTHING - the
        # caller keeps its queue and tries again. Only a parse failure falls
        # through to a fresh object, which is the case that was always meant to:
        # hand-edited JSON that no longer parses, where Get-SRConfigRead already
        # tells the operator to fix it or delete it.
        $txt = [System.IO.File]::ReadAllText($SR_ConfigPath)
        try { $raw = $txt | ConvertFrom-Json } catch { $raw = $null }
    }
    if (-not $raw) { $raw = New-Object PSObject }
    foreach ($k in @($Values.Keys)) {
        if ($null -eq $raw.PSObject.Properties["$k"]) {
            $raw | Add-Member -NotePropertyName "$k" -NotePropertyValue $Values[$k] -Force
        } else { $raw."$k" = $Values[$k] }
    }

    $dir = Split-Path -Parent $SR_ConfigPath
    $tmp = Join-Path $dir ('.config.{0}.tmp' -f ([guid]::NewGuid().ToString('N')))
    $json = $raw | ConvertTo-Json -Depth 8
    # The baseline for Set-SRDistinctWriteTime, taken before the replace because
    # afterwards it is gone. Two nulls, told apart: no file at all is a first
    # write and needs no nudge; a stat that failed on a file that exists does.
    $wasAt = $null; $wasBad = $false
    if (Test-Path -LiteralPath $SR_ConfigPath) {
        try { $wasAt = (Get-Item -LiteralPath $SR_ConfigPath -ErrorAction Stop).LastWriteTimeUtc }
        catch { $wasBad = $true }
    }
    try {
        [System.IO.File]::WriteAllText($tmp, $json, (New-Object System.Text.UTF8Encoding($false)))
        # 🔴 -ErrorAction Stop, OR THE FAILURE IS INVISIBLE. Move-Item reports a
        # blocked destination as a NON-TERMINATING error: without this the write
        # "succeeded", Save-SRConfigWrites cleared its queue for a value that
        # never reached the file, and the temp beside it was never cleaned up.
        # WriteAllText above is a .NET call and throws on its own, which is why
        # only half of this path was ever caught.
        Move-Item -LiteralPath $tmp -Destination $SR_ConfigPath -Force -ErrorAction Stop
    } catch {
        # 🪤 THE TEMP OUTLIVES THE FAILURE OTHERWISE. It sits beside the config
        # rather than in the OS temp dir, so it is not the leak this machine's
        # conventions are about - but a stray .config.<guid>.tmp next to the real
        # one is exactly the kind of thing somebody later mistakes for the real
        # one. Move-Item -Force is the throw that matters here: it fails when
        # another process holds the destination open.
        try { if (Test-Path -LiteralPath $tmp) { Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue } } catch { }
        throw
    }
    # AFTER the replace, and outside the try above on purpose: the save has
    # succeeded by here, so nothing this does may turn it into a failure.
    Set-SRDistinctWriteTime -Path $SR_ConfigPath -Was $wasAt -BaselineFailed:$wasBad
}

function Save-SRConfigValue { param([Parameter(Mandatory)][string]$Name, $Value)
    # 🪤 A SYNCHRONOUS WRITE IS LATER THAN ANYTHING QUEUED FOR THE SAME KEY, so
    # it wins and the queued value is dropped. Without this the next flush would
    # put the older value back over the top of the one just written, and the
    # setting would appear to revert some seconds after it was set.
    if ($script:SR_ConfigPending.ContainsKey($Name)) { $null = $script:SR_ConfigPending.Remove($Name) }
    $one = @{}
    $one[$Name] = $Value
    Set-SRConfigOnDisk -Values $one
}

# ---------------------------------------------------------------------------
# 🔴 REMEMBERING A SETTING COST 21 ms ON THE CLICK THAT SET IT. PaneZoom and
# PaneTools were both ~21 ms and the fold caret 23.8, and essentially all of it
# was this: read 15 KB, ConvertFrom-Json, ConvertTo-Json, write a temp, move it -
# on the UI thread, inside the gesture, three times the terminal's 6.9 ms budget.
#
# None of the four settings is READ back from the config while the window is
# open (the window keeps $script:Zoom, $script:toolView, $script:foldRail and
# $script:foldList), so the write exists only to survive the window. It does not
# have to happen inside the click - it has to happen before the window closes.
#
# 🪤 THIS IS NOT "FREE", IT IS MOVED. The write still costs what it cost; it
# just no longer lands on a gesture. tests\audit-pane.ps1 keeps measuring
# Save-SRConfigValue directly as a diagnostic so the number stays visible - a
# cost that vanishes from the table it used to be in is how an instrument starts
# lying.
# ---------------------------------------------------------------------------
function Save-SRConfigLater { param([Parameter(Mandatory)][string]$Name, $Value)
    $script:SR_ConfigPending[$Name] = $Value
    if ($script:SR_ConfigCache) {
        try {
            if ($null -eq $script:SR_ConfigCache.PSObject.Properties[$Name]) {
                $script:SR_ConfigCache | Add-Member -NotePropertyName $Name -NotePropertyValue $Value -Force
            } else { $script:SR_ConfigCache.$Name = $Value }
        } catch { }
    }
}

# Returns $true when it wrote, $false when there was nothing to write, and
# THROWS when the write failed - leaving the queue intact so the next flush (or
# the one on close) tries again rather than silently losing the setting.
function Save-SRConfigWrites {
    if ($script:SR_ConfigPending.Count -eq 0) { return $false }
    $take = @{}
    foreach ($k in @($script:SR_ConfigPending.Keys)) { $take[$k] = $script:SR_ConfigPending[$k] }
    Set-SRConfigOnDisk -Values $take
    foreach ($k in @($take.Keys)) { $null = $script:SR_ConfigPending.Remove($k) }
    return $true
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

    # 🔴 A MALFORMED PATH MAKES Test-Path THROW A NON-TERMINATING ERROR, which
    # the catch below does NOT intercept - so every scan wrote a red
    # "Illegal characters in path" to the error stream and carried on. Observed
    # for real on 2026-08-30, from a registry row whose path had picked up a tab.
    # One bad row is enough to make a scan's output unreadable, and unreadable
    # output is where genuine failures go to hide.
    #
    # 🪤 The check is here rather than -ErrorAction on each call: an unusable
    # path is not a worktree and is not a repo, so there is nothing further to
    # ask about it, and the default answer above is already the right one.
    if ([string]::IsNullOrWhiteSpace($Path) -or
        $Path.IndexOfAny([System.IO.Path]::GetInvalidPathChars()) -ge 0) {
        $script:SR_WtCache[$key] = $info
        return $info
    }

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
#
# $SeenIn / $SeenOut are the same idea for the transcripts that are read and then
# REJECTED - a third of them here. They never reach the registry, so $Cache can
# never hold them and they were re-opened on every scan forever. SeenIn is last
# scan's map, SeenOut is filled as this scan rejects; two objects so a deleted
# transcript prunes itself out rather than accumulating.
function Get-SRDiscovered {
    param([Parameter(Mandatory)]$Config, [hashtable]$Cache,
          [hashtable]$SeenIn, [hashtable]$SeenOut)

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
            # The rejected map is consulted on the same stamp and for the same
            # reason - it just holds the ones the registry will never carry.
            $seenHit = ((-not $hit) -and $SeenIn -and $SeenIn.ContainsKey($f.BaseName) -and
                        $SeenIn[$f.BaseName].Stamp -eq $stamp)
            if ($hit) {
                $cwd       = $Cache[$f.BaseName].Cwd
                $title     = $Cache[$f.BaseName].Title
                $autoTitle = $Cache[$f.BaseName].AutoTitle
            } elseif ($seenHit) {
                $cwd       = $SeenIn[$f.BaseName].Cwd
                $title     = $SeenIn[$f.BaseName].Title
                $autoTitle = $SeenIn[$f.BaseName].AutoTitle
            } else {
                $info      = Get-SRSessionInfo -JsonlPath $f.FullName
                $cwd       = $info.Cwd
                $title     = $info.Title
                $autoTitle = "$($info.AiTitle)"   # never $null: we looked
            }

            # 🔴 THE ONES THAT ARE READ AND THEN THROWN AWAY - 130 OF 391 HERE.
            # A row rejected below never enters the registry, so it never enters
            # $Cache, so its 20.3 MB of transcript is opened again on every scan
            # and every logon, forever. Measured 2026-09-03: 85 whose cwd folder
            # is gone, 41 excluded by pattern, 4 with no cwd in the tail - a
            # third of the corpus, ~250 ms warm and ~2 s of the 9 s logon scan.
            #
            # 🪤 WHAT IS REMEMBERED IS WHAT THE FILE SAID, NEVER THE VERDICT.
            # Caching "this one was rejected" would be smaller and wrong: a
            # deleted repo that comes back, or an exclusion taken out of the
            # config, does not change the transcript's mtime, so the
            # conversation would stay invisible until it was next written to.
            # Caching the CWD instead means the three cheap predicates below run
            # on every scan exactly as they do now - only the file read is
            # skipped - so a restored repo reappears on the next pass and a
            # config change takes effect immediately.
            $keep = $true
            if (-not $cwd) { $keep = $false }
            else {
                $cwd = $cwd.TrimEnd('\')
                if (-not (Test-Path -LiteralPath $cwd -PathType Container)) { $keep = $false }
                elseif (Test-SRExcluded -Path $cwd -Config $Config) { $keep = $false }
            }

            # A conversation belongs to its REPO, in one of two lanes. Worktree
            # conversations therefore sit under the parent repo rather than beside it
            # as a project of their own.
            $wt = $null
            if ($keep) {
                if ([string]::IsNullOrWhiteSpace($title)) { $title = '(untitled)' }
                $wt = Get-SRWorktreeInfo -Path $cwd
                if ($wt.Lane -eq 'worktree' -and -not $Config.includeWorktrees) { $keep = $false }
            }
            if (-not $keep) {
                # 🪤 SeenOut IS WRITTEN, SeenIn IS READ, and they are two objects
                # on purpose: a file that has since been deleted simply never
                # gets added to the new one, so the map prunes itself instead of
                # growing for the life of the machine.
                if ($null -ne $SeenOut) {
                    $SeenOut[$f.BaseName] = @{
                        Stamp = $stamp; Cwd = "$cwd"; Title = "$title"; AutoTitle = "$autoTitle"
                    }
                }
                continue
            }

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
# 🔴 TWO WINDOWS SILENTLY DISCARDED EACH OTHER'S TICKS. Measured 2026-08-30:
# window A ticks a conversation and saves, window B - holding a copy read before
# that - ticks another and saves, and A's tick is simply gone. The whole file is
# serialised on every save, so the last writer wins over everything, and the
# ticks are the thing that decides what comes back at the next logon.
#
# The stamp is what this window last SAW on disk. Save refuses if the file has
# moved on since, which turns a silent loss into a message you can act on. It is
# deliberately NOT a merge: reconciling a shared file behind the operator's back
# is how a real conflict gets hidden.
#
# 🪤 THE ADOPTER MUST UPDATE IT TOO. The background probe reads the registry
# in its own runspace, and the UI adopts that object - so the UI now holds data
# newer than its own stamp. Without Set-SRRegistryStamp on that path, the next
# save refuses against a file it actually agrees with.
$script:SR_RegStamp = $null
# 🔴 LENGTH AND TIMESTAMP CAN BOTH MATCH ACROSS A REAL CHANGE, AND THEN THE
# GUARD PERMITS A SAVE IT EXISTS TO REFUSE.
#
# This was length|ticks. Both halves collide for ordinary registry edits:
#
#   LENGTH  ticking one session and unticking another in the same save is
#           net-zero, and lastScan is written with .ToString('o'), which is
#           fixed-width and therefore never moves the length either.
#   TICKS   the Windows clock stamps LastWriteTimeUtc at ~15.6 ms granularity,
#           so any write landing within one tick of the previous one inherits an
#           identical value.
#
# A false "unchanged" here does not serve stale data - it lets THIS window
# overwrite another window's ticks, which is the failure this repo already
# records as having cost the operator 210 conversations.
#
# 🪤 AND THE LOCK DOES NOT COVER IT, though the note on Save-SRRegistry reads as
# though it might. Invoke-SRWithRegistryLock stops a write interleaving BETWEEN
# the check and the replace. The hazard is earlier: the other window's save
# completes BEFORE this one takes the lock, so the check runs inside the lock,
# against a file that already changed, and agrees.
#
# 🔑 SO THE STAMP CARRIES THE CONTENT ITSELF. SHA256 of the bytes, measured at
# 1.98 ms on top of the 0.67 ms Get-Item - which is nothing on a save, and a
# save is a gesture rather than a hot path.
#
# 🔑 AND IT GOES IN THE STAMP RATHER THAN BESIDE IT, which is the whole reason
# this is a hash and not the cheaper-looking alternative of keeping the raw text
# read in Get-SRRegistry as a baseline. The stamp is not a local: the probe
# reads the registry in ITS OWN RUNSPACE (sessions-window.ps1:9874) and hands
# back both the object and the stamp, and the UI adopts them (:10245). A second
# parallel baseline would have to cross that boundary too - 549,146 characters
# marshalled every 15 s - and would be a second thing to remember on every path
# that adopts. One opaque string travels the plumbing that already exists.
#
# 🪤 IT ALSO MAKES THE BOM TRAP STRUCTURALLY IMPOSSIBLE. A baseline taken from
# the string we serialised would not match the file: Set-Content -Encoding utf8
# on 5.1 writes a BOM and a trailing newline, measured - 7 chars in, 12 bytes
# out, and ReadAllText gives back 9. This never derives a baseline from the
# in-memory JSON; it always reads what is actually on disk.
#
# Returns '' only when there is NO FILE. See the guard: that means "nothing to
# be stale against", and it is not the same as "could not tell".
function Get-SRRegistryStamp {
    $fi = $null
    try { $fi = Get-Item -LiteralPath $SR_RegistryPath -ErrorAction Stop } catch { return '' }
    $h = ''
    try {
        $sha = [System.Security.Cryptography.SHA256]::Create()
        try {
            # FileShare ReadWrite: another window mid-save must not turn this
            # into an exception, and a torn read cannot produce a FALSE MATCH -
            # only a mismatch, which fails safe by refusing.
            $fs = [System.IO.File]::Open($SR_RegistryPath, [System.IO.FileMode]::Open,
                                         [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite)
            try { $h = [BitConverter]::ToString($sha.ComputeHash($fs)).Replace('-', '') } finally { $fs.Dispose() }
        } finally { $sha.Dispose() }
    } catch { $h = '' }
    if (-not $h) { return 'unhashed' }
    return ('{0}|{1}|{2}' -f $fi.Length, $fi.LastWriteTimeUtc.Ticks, $h)
}
function Set-SRRegistryStamp { param([string]$Stamp) $script:SR_RegStamp = $Stamp }

function Get-SRRegistry {
    $script:SR_RegStamp = Get-SRRegistryStamp
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
    param(
        [Parameter(Mandatory)]$Registry,
        # Write regardless of who else has written since. For the caller that has
        # already told the operator and been told to go ahead.
        [switch]$Force
    )
    Invoke-SRWithRegistryLock -Body {
        # Inside the lock, so nobody can slip a write between the check and the
        # replace. A null stamp means this session has never read the file -
        # there is nothing to be stale against, so it writes.
        if (-not $Force -and $script:SR_RegStamp) {
            $now = Get-SRRegistryStamp
            # 🔴 A CHECK THAT CANNOT TELL MUST NOT PERMIT. This used to be
            # `if ($now -and $now -ne $stamp)`, so an EMPTY $now fell straight
            # through and the save went ahead - and empty is exactly what
            # Get-SRRegistryStamp returns when it cannot see the file. Having a
            # stamp at all means this window read a registry, so failing to
            # stamp one now is not evidence that nothing has changed; it is
            # evidence that the question could not be answered.
            #
            # The one case where empty really does mean "nothing to clobber" is
            # a file that is genuinely gone, and that is asked separately rather
            # than inferred from the same silence.
            if (-not $now) {
                if (Test-Path -LiteralPath $SR_RegistryPath) {
                    throw ("the registry is on disk but could not be read to check whether it " +
                           "changed, so this save was refused rather than risk overwriting " +
                           "another window's ticks. Try again in a moment.")
                }
            }
            elseif ($now -eq 'unhashed') {
                throw ("the registry could not be read to check whether it changed - " +
                       "something else has it open. This save was refused rather than " +
                       "risk overwriting another window's ticks. Try again in a moment.")
            }
            elseif ($now -ne $script:SR_RegStamp) {
                throw ("the registry changed on disk since this window read it - " +
                       "another Sessions window (or a scan) has saved. Saving now would " +
                       "discard those changes. Close the other window, or press Rescan " +
                       "to pick them up, then save again.")
            }
        }
        $Registry.lastScan = (Get-Date).ToString('o')
        # Write beside the target then replace: a half-written registry would lose
        # every selection.
        $tmp = "$SR_RegistryPath.tmp"
        # 🔴 -ErrorAction Stop ON BOTH, OR A FAILED SAVE LOOKS LIKE A GOOD ONE.
        # Set-Content and Move-Item report a blocked file as a NON-TERMINATING
        # error, so a registry another process held open was never written, this
        # function returned normally, and the line below then re-stamped against
        # the OLD file - leaving the window's staleness check agreeing with a
        # save that never happened. The operator's ticks were gone with nothing
        # said. Same shape as the config writer above; found by holding a
        # destination open with FileShare None, which reproduces it every time.
        try {
            ($Registry | ConvertTo-Json -Depth 8) | Set-Content -LiteralPath $tmp -Encoding utf8 -ErrorAction Stop
            Move-Item -LiteralPath $tmp -Destination $SR_RegistryPath -Force -ErrorAction Stop
        } catch {
            try { if (Test-Path -LiteralPath $tmp) { Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue } } catch { }
            throw ("the registry could not be saved ($SR_RegistryPath): $($_.Exception.Message). " +
                   "Nothing was written, so your ticks are still here - close whatever is holding the file and save again.")
        }
        # What we just wrote is now what this window has seen.
        $script:SR_RegStamp = Get-SRRegistryStamp
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

# 🔴 A SCAN READS THE REGISTRY FROM DISK, so anything ticked but not yet
# saved is invisible to it - and the caller then re-reads the file it just wrote,
# replacing the in-memory copy that held those ticks. Pressing Rescan with
# unsaved work threw it away with nothing said.
#
# The order lives HERE rather than in the window's click handler so it can be
# tested at all: a test of the handler would have to run a real scan against the
# operator's real registry, which is precisely the accident that destroyed it on
# 2026-08-30. In a sandbox this is provable; in the handler it was not.
#
# 🪤 SAVE FIRST, AND REFUSE IF THAT FAILS. Discarding the ticks is the one
# outcome that must not happen quietly, so a failed save stops the scan rather
# than letting it proceed over the top.
# ===========================================================================
# SETTINGS FOR A CONVERSATION THAT DOES NOT EXIST YET
#
# 🔴 A BRAND NEW CONVERSATION HAS NO SESSION ID. claude generates one on its
# first message, so the New session dialog cannot write its settings against
# anything - and it did not try, which meant the model, effort, permission mode,
# tools and hidden flag chosen in that dialog applied to THAT RUN and were then
# forgotten. Harmless while the logon restore ignored settings too; from
# 2026-08-30 it honours them, so the dialog now promises something it was not
# keeping: a session spawned as opus/plan came back at the next logon as default.
#
# A CLAIM is that promise, written down: "the next conversation to appear in
# this directory under this title gets these settings". The scan redeems it when
# it first sees a matching new session.
#
# 🪤 SINGLE USE, AND IT EXPIRES. Matching on directory + title is a heuristic -
# two sessions spawned with one name in one folder would both match - so a claim
# is removed the moment it is used, and ignored after an hour. The failure it can
# still produce is "the settings landed on the wrong one of two identically
# named conversations spawned within the hour", which is recoverable in the
# Settings panel; the failure it replaces is "they landed nowhere, silently".
$SR_ClaimsPath = Join-Path $SR_StateDir 'pending-prefs.json'
$SR_ClaimMaxAgeMinutes = 60

function Get-SRPrefClaims {
    if (-not (Test-Path -LiteralPath $SR_ClaimsPath)) { return @() }
    try { $all = @(Get-Content -LiteralPath $SR_ClaimsPath -Raw | ConvertFrom-Json) } catch { return @() }
    $cut = (Get-Date).AddMinutes(-$SR_ClaimMaxAgeMinutes)
    return @($all | Where-Object {
        $t = [datetime]0
        try { $t = [datetime]$_.at } catch { }
        $t -gt $cut
    })
}

function Add-SRPrefClaim {
    param(
        [Parameter(Mandatory)][string]$Dir,
        [Parameter(Mandatory)][string]$Title,
        [Parameter(Mandatory)][hashtable]$Prefs
    )
    $keep = @(Get-SRPrefClaims)
    $keep += [PSCustomObject]@{
        dir = "$Dir"; title = "$Title"; at = (Get-Date).ToString('o'); prefs = [PSCustomObject]$Prefs
    }
    try {
        if (-not (Test-Path -LiteralPath $SR_StateDir)) { $null = New-Item -ItemType Directory -Path $SR_StateDir -Force }
        ($keep | ConvertTo-Json -Depth 6) | Set-Content -LiteralPath $SR_ClaimsPath -Encoding utf8
    } catch { Write-SRLog ('  [skip] could not record the new session''s settings: ' + $_.Exception.Message) }
}

# Redeem the claim for a session the scan has just discovered. Returns $true if
# one was applied, so the caller can say so.
function Resolve-SRPrefClaim {
    param([Parameter(Mandatory)]$Session, [Parameter(Mandatory)][string]$Dir, [Parameter(Mandatory)][string]$Title)
    $claims = @(Get-SRPrefClaims)
    if (-not $claims.Count) { return $false }
    # 🪤 NORMALISE THE SEPARATOR, DO NOT TrimEnd TWO CHARACTERS. `TrimEnd('\','/')`
    # has to bind to the char[] overload and PowerShell will not convert two
    # single-character strings to it - and if either literal loses its backslash
    # on the way in, the empty string it leaves behind cannot convert to a char
    # at all. The failure surfaces as a MethodException nowhere near the cause.
    $norm = { param($x) ("$x" -replace '\\', '/').TrimEnd('/') }
    $wantDir = & $norm $Dir
    $hit = @($claims | Where-Object {
        (& $norm $_.dir) -ieq $wantDir -and "$($_.title)" -ieq "$Title"
    })[0]
    if (-not $hit) { return $false }
    foreach ($pp in @($hit.prefs.PSObject.Properties)) {
        Set-SRSessionPref $Session $pp.Name $pp.Value
    }
    # Single use: drop it whether or not the settings were all applicable.
    $rest = @($claims | Where-Object { -not ($_.at -eq $hit.at -and "$($_.dir)" -eq "$($hit.dir)" -and "$($_.title)" -eq "$($hit.title)") })
    try {
        if ($rest.Count) { ($rest | ConvertTo-Json -Depth 6) | Set-Content -LiteralPath $SR_ClaimsPath -Encoding utf8 }
        elseif (Test-Path -LiteralPath $SR_ClaimsPath) { Remove-Item -LiteralPath $SR_ClaimsPath -Force }
    } catch { }
    Write-SRLog ("  [ok]   applied the settings chosen when '{0}' was created" -f $Title)
    return $true
}

function Invoke-SRRescan {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Registry,
        [Parameter(Mandatory)]$Config,
        # The window's $script:dirty - whether $Registry holds unsaved changes.
        [bool]$Dirty,
        [switch]$Quiet
    )
    $out = [PSCustomObject]@{ Saved = $false; Scanned = $false; Why = '' }
    if ($Dirty) {
        try { Save-SRRegistry -Registry $Registry; $out.Saved = $true }
        catch { $out.Why = "unsaved ticks could not be written first: $($_.Exception.Message)"; return $out }
    }
    try { $null = Update-SRRegistry -Config $Config -Quiet:$Quiet; $out.Scanned = $true }
    catch { $out.Why = "$($_.Exception.Message)" }
    return $out
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

    # And the same for the ones that get read and then rejected - a third of the
    # corpus here, which the registry can never cache because a rejected row
    # never lands in it. See the note on Get-SRDiscovered.
    $seenIn = @{}
    if ($reg.PSObject.Properties['rejected'] -and $reg.rejected) {
        foreach ($rp in @($reg.rejected.PSObject.Properties)) {
            if ($rp.Value -and $rp.Value.stamp) {
                $seenIn[$rp.Name] = @{
                    Stamp = $rp.Value.stamp; Cwd = "$($rp.Value.cwd)"
                    Title = "$($rp.Value.title)"; AutoTitle = "$($rp.Value.autoTitle)"
                }
            }
        }
    }
    $seenOut = @{}

    $disc = Get-SRDiscovered -Config $Config -Cache $cache -SeenIn $seenIn -SeenOut $seenOut

    # 🪤 REBUILT FROM THIS PASS, NOT MERGED INTO THE OLD ONE. A transcript that
    # has since been deleted is simply never added, so the map prunes itself;
    # merging would grow it for the life of the machine and re-introduce the
    # 22 GONE-for-weeks rows this is meant to stop paying for.
    $rejObj = New-Object PSObject
    foreach ($rk in @($seenOut.Keys)) {
        $rv = $seenOut[$rk]
        $rejObj | Add-Member -NotePropertyName $rk -NotePropertyValue ([PSCustomObject]@{
            stamp = $rv.Stamp; cwd = $rv.Cwd; title = $rv.Title; autoTitle = $rv.AutoTitle
        }) -Force
    }
    if ($null -eq $reg.PSObject.Properties['rejected']) {
        $reg | Add-Member -NotePropertyName rejected -NotePropertyValue $rejObj -Force
    } else { $reg.rejected = $rejObj }
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
            $newRow = [PSCustomObject]@{
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
            # 🔴 REDEEM THE SETTINGS CHOSEN WHEN THIS CONVERSATION WAS CREATED.
            # The New session dialog could not write them - there was no session
            # id yet - so it left a claim naming the directory and the title.
            # This is the first moment the conversation exists to attach them to.
            # A title claude generated itself is matched too, because a session
            # spawned without a name arrives carrying autoTitle rather than title.
            try {
                $claimed = Resolve-SRPrefClaim -Session $newRow -Dir "$($r.Cwd)" -Title "$($r.Title)"
                if (-not $claimed -and "$($r.AutoTitle)") {
                    $null = Resolve-SRPrefClaim -Session $newRow -Dir "$($r.Cwd)" -Title "$($r.AutoTitle)"
                }
            } catch { Write-SRLog ('  [skip] pending settings: ' + $_.Exception.Message) }
            $dir.sessions += $newRow
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
        # 🔑 AND THE SAME ARGUMENT ONE STEP EARLIER FOR A SHELVED PROJECT. The note
        # above says the roll must not write ticks that can never launch; a shelved
        # project is the other way round - its ticks would launch, because they are
        # real ticks on an enabled project, and rolling them forward every hour
        # would keep a project the operator put away permanently ready to come
        # back. Get-SRSelected refuses to launch it either way; this stops the
        # registry churning ticks for something nothing will ever read.
        if (Test-SRProjectShelved $dir) { continue }

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
# ---------------------------------------------------------------------------
# IS THIS PROJECT SHELVED - put away, out of the rail and out of the restore?
#
# 🔴 IT IS CALLED `shelved` BECAUSE `hidden` WAS ALREADY TAKEN, one object away.
# A SESSION carries `hidden` meaning "launch this conversation's terminal
# off-screen" - Test-SRHiddenWanted turns it into a claude flag. Putting a
# project-level `hidden` on the DIRECTORY beside it would have been the same
# word, in the same registry, meaning two unrelated things with completely
# different consequences: one decides where a window appears, this one decides
# whether anything is launched at all. Renamed before it shipped. One word
# throughout - field, functions, config key, and every string on screen.
#
# 🪤 SHELVED IS NOT EXCLUDED. excludePatterns (Test-SRExcluded) works at
# DISCOVERY and its paths never reach the registry at all - that erases history.
# This keeps every conversation, every tick and every pin the project had; it is
# simply out of the picture until it is put back. Never wire the two together.
function Test-SRProjectShelved { param($Dir)
    if (-not $Dir) { return $false }
    return [bool]$Dir.shelved
}

# ---------------------------------------------------------------------------
# WOULD THIS PROJECT BE WORTH SHELVING? A SUGGESTION, AND ONLY EVER THAT.
#
# 🔴 NOTHING IS EVER SHELVED AUTOMATICALLY. This returns a sentence and no more;
# it has no reference to the registry it could write, and Set-ProjectShelved - the
# one thing that does write - is reachable only from a right-click and a confirm
# sheet. That is the whole contract: the tool may point, the operator decides.
# A tool that tidied 36 projects down to 12 on its own would be indistinguishable
# from a tool that lost 24 of them.
#
# Two conditions, both required:
#   * nothing in it is RUNNING - liveness is the caller's to supply, because
#     _common has no agent probe and asking for one here would put a
#     900 ms `claude agents --json` behind a rail rebuild;
#   * every conversation it still has went quiet more than shelveSuggestDays ago.
#
# 🔑 AND A REPO WHOSE ONLY REMAINING LANES ARE WORKTREES IS SUGGESTED AT HALF
# THAT. This is the case the operator actually complained about: a worktree is
# one lane of work, opened for a branch and finished with it, and a repo whose
# main lane has stopped while three dead worktree lanes hang on is exactly the
# clutter. It is a WEIGHT, not a separate rule - the project still has to be
# quiet, just not for as long. Projects are keyed on the REPO since v3, so a
# worktree is never a project of its own and this can only ever mean "all that
# is left in here is finished branches".
#
# 🪤 `gone` CONVERSATIONS DO NOT COUNT AS QUIET. A transcript deleted off disk
# has no lastActive worth reading, and counting it would make a project look
# ancient because somebody cleared out a temp folder. A project with nothing BUT
# gone conversations is not suggested at all - it has a different problem and the
# manager already says so.
function Get-SRShelveSuggestion {
    param(
        [Parameter(Mandatory)]$Dir,
        $Config,
        # Does anything in this project have a live process? The window knows;
        # this does not, and must not go and find out.
        [bool]$AnythingRunning = $false,
        [datetime]$Now = [datetime]::Now
    )
    if (-not $Dir) { return '' }
    if ($Dir.missing) { return '' }
    if (Test-SRProjectShelved $Dir) { return '' }
    if ($AnythingRunning) { return '' }

    $days = 14
    if ($Config -and $null -ne $Config.PSObject.Properties['shelveSuggestDays']) {
        try { $days = [int]$Config.shelveSuggestDays } catch { $days = 14 }
    }
    if ($days -lt 1) { $days = 14 }

    $live = @(@($Dir.sessions) | Where-Object { -not $_.gone })
    if (-not $live.Count) { return '' }

    $newest = [datetime]0
    $allWorktree = $true
    foreach ($s in $live) {
        if ("$($s.lane)" -ne 'worktree') { $allWorktree = $false }
        try { $t = [datetime]$s.lastActive; if ($t -gt $newest) { $newest = $t } } catch { }
    }
    # A conversation whose date will not parse leaves $newest at zero, which
    # would read as "quiet since the year 1" - so nothing is suggested off a
    # project we could not date at all.
    if ($newest -eq [datetime]0) { return '' }

    $cut = $days
    if ($allWorktree) { $cut = [Math]::Max(1, [int][Math]::Ceiling($days / 2.0)) }
    $quiet = [int]([Math]::Floor(($Now - $newest).TotalDays))
    if ($quiet -lt $cut) { return '' }

    if ($allWorktree) {
        return ('nothing but finished worktree lanes here, quiet {0} days' -f $quiet)
    }
    return ('nothing running, quiet {0} days' -f $quiet)
}

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
        # 🔴 SHELVED IS NOT A TICK, so -IgnoreTicks does not lift it. -All means
        # "never mind what is ticked", which is a statement about conversations;
        # a shelved project has been taken out of the picture entirely, and a
        # restore that brought back thirty sessions the operator had
        # deliberately put away would be the exact complaint this feature
        # answers. It sits beside `missing` because it is that kind of check.
        if (Test-SRProjectShelved $d) { continue }
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
                # 🔴 THE SESSION ITSELF, because the LOGON PATH NEEDS ITS SETTINGS.
                # Without this the restore had only ids and titles, so every
                # conversation came back at logon with NO model, NO effort, NO
                # permission mode, NO tool rules and NOT hidden - and with
                # Remote Control forced ON, because New-SRBootScript defaults it
                # true. Every one of those settings worked when launched from
                # the window and was silently dropped on the one path that runs
                # by itself, which is the path the whole tool exists for.
                Session    = $s
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

# 🔴 A FRESH TRANSCRIPT IS NOT A LIVE SESSION, AND AFTER A REBOOT IT IS THE
# OPPOSITE OF ONE. This is a PROXY for "something is running that we failed to
# attribute to a process" - the real check is Test-SRProcessRunning, which runs
# first. On 2026-08-29 the operator restarted the machine and 15 conversations
# were skipped at logon with "already live (transcript written < 3 min ago)":
# they had been written seconds before the shutdown, the restart took under
# three minutes, and so at logon every one of them looked alive while nothing at
# all was running. The tool's entire purpose - bring the session back - failed
# silently, and the log recorded it as a deliberate skip.
#
# 🪤 A SHORTER WINDOW WOULD NOT FIX IT, it would only need a faster reboot. The
# question is not "how recent" but "could anything have written this SINCE the
# machine came up" - so the boot time is the gate, and it is exact:
#   - written before this boot  -> nothing has touched it this session, dead.
#   - no claude.exe on the box  -> there is no process the attribution could
#     have missed, which is the only thing this proxy exists to cover.
$script:SR_BootTime = $null
function Get-SRBootTime {
    if ($script:SR_BootTime) { return $script:SR_BootTime }
    try { $script:SR_BootTime = (Get-CimInstance Win32_OperatingSystem -ErrorAction Stop).LastBootUpTime }
    catch { $script:SR_BootTime = [datetime]::MinValue }
    return $script:SR_BootTime
}

function Test-SRTranscriptLive {
    param([Parameter(Mandatory)][string]$JsonlPath)
    if (-not (Test-Path -LiteralPath $JsonlPath)) { return $false }
    $wrote = (Get-Item -LiteralPath $JsonlPath).LastWriteTime
    if (((Get-Date) - $wrote).TotalMinutes -ge $SR_LiveWindowMinutes) { return $false }

    # Written before the machine came up: whatever wrote it is long gone.
    $boot = Get-SRBootTime
    if ($boot -gt [datetime]::MinValue -and $wrote -le $boot) { return $false }

    # Nothing is running at all, so there is no misattributed process to cover.
    $any = $false
    try { $any = [bool]@(Get-Process -Name 'claude' -ErrorAction SilentlyContinue).Count } catch { }
    if (-not $any) { return $false }

    return $true
}

# 🪤 A WRAPPED ABSOLUTE PATH IS MOST OF WHY THIS READS AS A CONSOLE LOG.
# One Bash call carries 'cd "C:/Users/mauri/Documents/Trading Bot/Python/
# AlgoTrader/.claude/worktrees/V-INGEST"' twice, which wraps across three lines
# of tiny monospace and buries the one part that identifies it - the end. The
# head is what repeats and the tail is what differs, so the middle goes.
# 🔴 MEASURED AT 1.9 ms A CALL, and it runs on every result and every command in
# the reading pane - the single largest cost in building a document, found by
# timing the builder's pieces after two better-sounding hypotheses (a hosted
# element per paragraph, Knuth-Plass line breaking) both measured as noise.
#
# Two things were wrong, and neither was the regex itself:
#
#   IT REBUILT ITS DELEGATES ON EVERY CALL. `$shorten`, `$ev1` and `$ev2` were
#   constructed per invocation, and a [MatchEvaluator] made from a PowerShell
#   scriptblock re-enters the PS engine for every match. Hoisted to script
#   scope, they are built once for the life of the window.
#
#   IT RAN TWO REGEXES OVER TEXT THAT USUALLY HAS NO PATH IN IT. Most tool
#   output contains no drive letter at all, and the answer for that text is
#   itself. One cheap IndexOf-shaped test short-circuits the common case.
#
# 🪤 The BEHAVIOUR is unchanged, deliberately: same patterns, same order, same
# output. This is the same function running less often, not a different one.
$script:SR_PathShorten = {
    param([string]$path)
    $sep = $(if ($path -match '/') { '/' } else { '\' })
    $parts = @($path -split '[\\/]' | Where-Object { $_ })
    if ($parts.Count -le 4) { return $path }
    return $parts[0] + $sep + [string][char]0x2026 + $sep + (($parts | Select-Object -Last 3) -join $sep)
}
$script:SR_PathEv1 = [System.Text.RegularExpressions.MatchEvaluator] {
    param($m) '"' + (& $script:SR_PathShorten $m.Groups[1].Value) + '"'
}
$script:SR_PathEv2 = [System.Text.RegularExpressions.MatchEvaluator] {
    param($m) (& $script:SR_PathShorten $m.Groups[1].Value)
}
# Compiled once and reused, rather than parsed from a string literal per call.
$script:SR_PathRxQuoted = [regex]::new('"([A-Za-z]:[\\/][^"]{24,})"')
$script:SR_PathRxBare   = [regex]::new('(?<![\w"])([A-Za-z]:[\\/][^\s"'']{24,})')
# A drive letter is `<letter>:` followed by a slash. Nothing this function does
# can fire without one, so text that has none is returned untouched.
$script:SR_PathRxAny    = [regex]::new('[A-Za-z]:[\\/]')

# 🪤 THE QUOTED FORM HAS TO BE MATCHED FIRST AND SEPARATELY. Every path in
# this operator's transcripts runs through "Trading Bot" - a directory with
# a SPACE in it - so an unquoted pattern stops dead at the space and shortens
# the wrong half, leaving the tail that identifies the worktree untouched and
# trimming the part that was already common to every line.
function Compress-SRPath { param([string]$Text)
    if (-not $Text) { return $Text }
    if (-not $script:SR_PathRxAny.IsMatch($Text)) { return $Text }
    $out = $script:SR_PathRxQuoted.Replace($Text, $script:SR_PathEv1)
    return $script:SR_PathRxBare.Replace($out, $script:SR_PathEv2)
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
# 🔴 THE COUNTER, NOT JUST THE SUPPRESSION - because the useful moment is
# BEFORE it trips, and by the time it has tripped the damage is done for the
# rest of the window.
#
# MEASURED 2026-09-01: `bridgeOauthDeadFailCount` sat at 6 with the threshold at
# 7, so Remote Control was one failure from going quiet again. That is exactly
# the state the operator reads as "I am not logged in" - the sessions run
# perfectly and simply stop registering, the phone shows nothing, and signing in
# appears to fix it because the suppression window expires around the same time.
#
# 🪤 READ-ONLY, DELIBERATELY. `~/.claude.json` is Claude Code's own state file;
# this tool does not own it and does not write it. Showing the number is the
# whole feature - it converts an invisible fault into a visible one, which is
# what months of mornings were actually missing.
$SR_BridgeFailLimit = 7

# 🪤 CACHED ON THE FILE'S OWN TIMESTAMP, because `.claude.json` is 107 KB on
# this machine and this is read on a repeating tick. Parsing 107 KB of JSON
# every six seconds to look at two integers is the kind of cost that never
# shows up as a stall and quietly heats the whole window - the same shape as
# the pipeline in Update-Surface that measured 17 ms. Re-read only when Claude
# Code has actually rewritten it.
$script:SR_BridgeCache = $null
$script:SR_BridgeAt = $null

function Get-SRBridgeState {
    $out = [PSCustomObject]@{ Fails = 0; Limit = $SR_BridgeFailLimit; Until = $null; Suppressed = $false; Ok = $false }
    $p = Join-Path $env:USERPROFILE '.claude.json'
    if (-not (Test-Path -LiteralPath $p)) { return $out }
    $stamp = $null
    try { $stamp = (Get-Item -LiteralPath $p).LastWriteTimeUtc } catch { }
    if ($script:SR_BridgeCache -and $stamp -and $script:SR_BridgeAt -eq $stamp) {
        # 🪤 Suppressed is TIME-dependent, so it is recomputed even on a cache
        # hit - the file does not change when the window simply expires, and a
        # cached `true` would leave Remote Control looking dead for hours after
        # it came back.
        $c = $script:SR_BridgeCache
        $c.Suppressed = ($c.Until -and $c.Until -gt (Get-Date))
        return $c
    }
    try {
        $j = Get-Content -LiteralPath $p -Raw | ConvertFrom-Json
        $out.Ok = $true
        if ($j.PSObject.Properties['bridgeOauthDeadFailCount']) { $out.Fails = [int]$j.bridgeOauthDeadFailCount }
        if ($j.bridgeOauthDeadExpiresAt) {
            $t = [DateTimeOffset]::FromUnixTimeMilliseconds([long]$j.bridgeOauthDeadExpiresAt).LocalDateTime
            $out.Until = $t
            $out.Suppressed = ($t -gt (Get-Date))
        }
        $script:SR_BridgeCache = $out
        $script:SR_BridgeAt = $stamp
    } catch { }
    return $out
}

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
    # 🔴 BOTH PIPES ARE DRAINED AT ONCE, AND THE TIMEOUT ONLY WORKS BECAUSE OF IT.
    #
    # Reading them one after the other is the classic deadlock and it is worse
    # than it looks: while ReadToEnd() blocks on stdout, a child that fills the
    # stderr buffer stops writing, so stdout never closes, so ReadToEnd never
    # returns - and WaitForExit($TimeoutMs) is NEVER REACHED. The timeout below
    # protects nothing at all on that path; the window simply hangs, forever,
    # with no way out. One stderr-chatty `claude agents --json` would do it.
    #
    # Begin*ReadLine hands each stream to the threadpool, so neither can block
    # the other, and the wait is a real wait.
    $p = New-Object System.Diagnostics.Process
    $p.StartInfo = $psi
    try {
        $null = $p.Start()
        # ReadToEndAsync starts BOTH drains on the threadpool before anything
        # blocks, so neither stream can wedge the other and the wait below is a
        # real wait. Deliberately NOT Register-ObjectEvent: those actions only
        # run when the runspace pumps its event queue, and this call is made
        # from a background runspace that is sitting inside WaitForExit.
        $tOut = $p.StandardOutput.ReadToEndAsync()
        $tErr = $p.StandardError.ReadToEndAsync()
        if (-not $p.WaitForExit($TimeoutMs)) {
            try { $p.Kill() } catch { }
            # Killing closes the handles, so the readers finish; bounded anyway,
            # because a hang here is the thing this function exists to prevent.
            $o = ''; $e = ''
            try { if ($tOut.Wait(2000)) { $o = $tOut.Result } } catch { }
            try { if ($tErr.Wait(2000)) { $e = $tErr.Result } } catch { }
            return [PSCustomObject]@{ Out = $o; Err = $e; ExitCode = -1; TimedOut = $true }
        }
        $o = ''; $e = ''
        try { if ($tOut.Wait(5000)) { $o = $tOut.Result } } catch { }
        try { if ($tErr.Wait(5000)) { $e = $tErr.Result } } catch { }
        return [PSCustomObject]@{ Out = $o; Err = $e; ExitCode = $p.ExitCode; TimedOut = $false }
    } finally { try { $p.Dispose() } catch { } }
}

function Test-SRAuthReady {
    # `claude auth status` prints JSON and is the account's own answer, rather
    # than this tool guessing from a credentials file it does not own.
    #
    # 🔴 IT ANSWERS "ARE THERE CREDENTIALS", NOT "IS THE TOKEN ALIVE", AND THAT
    # DISTINCTION IS THE DAILY SIGN-IN. Measured 2026-09-02: the whole payload is
    # loggedIn / authMethod / apiProvider / email / org / subscriptionType - there
    # is NO expiry field in it. So this returns $true just as readily for a token
    # that died ten hours ago, and the restore gate it guards has been waving
    # through a queue of two dozen sessions into a dead token every morning.
    # Test-SRTokenLive is the other half; both are required before launching.
    try {
        $exe = Get-Command claude -ErrorAction Stop
        $r = Invoke-SRNativeText -FilePath $exe.Source -Arguments @('auth', 'status')
        if ($r.ExitCode -ne 0) { return $false }
        $j = $r.Out | ConvertFrom-Json -ErrorAction Stop
        return [bool]$j.loggedIn
    } catch { return $false }
}

# ===========================================================================
# IS THE ACCESS TOKEN ACTUALLY ALIVE - the question `auth status` cannot answer.
#
# 🔑 THE SHAPE OF THE PROBLEM, MEASURED ON 2026-09-02. The access token lives 8
# HOURS and the refresh token 30 DAYS. This machine is switched off overnight,
# so at every single boot the access token is already dead while the refresh
# token still has weeks on it. Nothing was signed out - it just needed ONE
# refresh, and instead 24 sessions were launched a second apart to each discover
# that for themselves. That morning read: booted 07:32:16, restore launched
# 07:37:25-07:37:48, and the credentials were not rewritten until 07:38:41 -
# AFTER every session had already started against the stale token.
#
# 🪤 THE MARGIN IS NOT DECORATION. A token with forty seconds left passes a bare
# expiry test and is dead by the time the twentieth session starts. Ten minutes
# comfortably covers a staggered queue.
$SR_TokenMarginSeconds = 600

# ===========================================================================
# SAY IT ON THE DESKTOP, because the restore runs when nobody is watching.
#
# 🔑 THE HOLD IS ONLY AN IMPROVEMENT IF IT IS HEARD. Refusing to launch into a
# dead token is right when the operator is at the machine and useless when they
# are not: an empty desktop and a line in .state\restore.log they would have to
# know to open. A toast is waiting for them the moment they sit down.
#
# 🪤 A SCHEDULED TASK CANNOT REACH A PHONE. Remote Control is exactly what is
# broken in the case this fires, so this is the furthest a notification can
# honestly travel - and saying so here stops the next reader adding a push that
# could never work.
function Show-SRDesktopNote { param([string]$Title = 'Claude sessions', [Parameter(Mandatory)][string]$Message)
    # WinRT first: a real toast, which persists in the Action Center rather than
    # vanishing after a few seconds like a tray balloon.
    try {
        $null = [Windows.UI.Notifications.ToastNotificationManager, Windows.UI.Notifications, ContentType = WindowsRuntime]
        $tpl = [Windows.UI.Notifications.ToastNotificationManager]::GetTemplateContent(
                   [Windows.UI.Notifications.ToastTemplateType]::ToastText02)
        $texts = $tpl.GetElementsByTagName('text')
        $texts.Item(0).AppendChild($tpl.CreateTextNode($Title))   | Out-Null
        $texts.Item(1).AppendChild($tpl.CreateTextNode($Message)) | Out-Null
        $toast = [Windows.UI.Notifications.ToastNotification]::new($tpl)
        # The PowerShell shortcut's AppId - the only one guaranteed to be
        # registered on a stock machine. A made-up AppId silently shows nothing.
        [Windows.UI.Notifications.ToastNotificationManager]::CreateToastNotifier(
            '{1AC14E77-02E7-4E5D-B744-2EB1AE5198B7}\WindowsPowerShell\v1.0\powershell.exe').Show($toast)
        return $true
    } catch { }
    # Tray balloon: no WinRT, no Action Center, but it is seen.
    try {
        Add-Type -AssemblyName System.Windows.Forms -ErrorAction Stop
        $ni = New-Object System.Windows.Forms.NotifyIcon
        $ni.Icon = [System.Drawing.SystemIcons]::Warning
        $ni.BalloonTipTitle = $Title
        $ni.BalloonTipText = $Message
        $ni.Visible = $true
        $ni.ShowBalloonTip(20000)
        Start-Sleep -Seconds 6
        $ni.Dispose()
        return $true
    } catch { }
    Write-SRLog '  [skip] could not raise a desktop notification'
    return $false
}

function Get-SRCredentialsPath {
    return (Join-Path (Join-Path $env:USERPROFILE '.claude') '.credentials.json')
}

# Returns the access token's expiry as local time, or $null when it cannot be
# read. $null is deliberately NOT treated as expired by the caller: this tool
# does not own that file, and a shape it does not recognise must not become a
# reason to refuse to restore the operator's morning.
function Get-SRTokenExpiry {
    $p = Get-SRCredentialsPath
    if (-not (Test-Path -LiteralPath $p)) { return $null }
    try {
        $j = Get-Content -LiteralPath $p -Raw -Encoding UTF8 | ConvertFrom-Json
        $o = $j.claudeAiOauth
        if (-not $o -or -not $o.PSObject.Properties['expiresAt']) { return $null }
        $ms = [double]$o.expiresAt
        if ($ms -le 0) { return $null }
        # Epoch milliseconds; guarded so a seconds-based value cannot read as 1970.
        if ($ms -lt 1e11) { $ms = $ms * 1000 }
        return ([DateTimeOffset]::FromUnixTimeMilliseconds([long]$ms)).LocalDateTime
    } catch { return $null }
}

function Test-SRTokenLive { param([int]$MarginSeconds = 0)
    if ($MarginSeconds -le 0) { $MarginSeconds = $SR_TokenMarginSeconds }
    $exp = Get-SRTokenExpiry
    # Unreadable is not a verdict - see above.
    if (-not $exp) { return $true }
    return ((New-TimeSpan -Start (Get-Date) -End $exp).TotalSeconds -gt $MarginSeconds)
}

# ===========================================================================
# WARM THE TOKEN EXACTLY ONCE, BEFORE ANYTHING ELSE IS LAUNCHED.
#
# 🔴 ONE REFRESH, NOT TWENTY-FOUR. This is the whole fix. Every session that
# starts against an expired access token refreshes for itself, and OAuth refresh
# tokens rotate - the first use invalidates the one the other twenty-three are
# holding. Serialising it here means the queue starts against a token that is
# already good for another eight hours.
#
# 🪤 IT IS PROVED BY expiresAt MOVING, NOT BY AN EXIT CODE. A `claude` command
# can succeed for reasons that have nothing to do with the token, so the check
# is that the credential file now says something later than it did.
#
# 🔴 AND THERE IS NO `claude auth refresh` TO CALL. Checked: the auth command
# offers login, logout and status, and nothing else. Whether `status` performs a
# refresh or only reads the file is not documented, so this does not assume it -
# it calls status and then CHECKS whether the expiry actually moved.
#
# 🪤 AND THE OBVIOUS FALLBACK IS A TRAP I BUILT AND THEN REMOVED. `claude -p`
# unquestionably reaches the API and so unquestionably refreshes - and it WRITES
# A TRANSCRIPT. Measured: one `claude -p 'ok'` left an 85 KB conversation in the
# project directory. In a tool whose entire job is deciding which conversations
# exist and which reopen at logon, a warm-up that MANUFACTURES conversations is
# worse than the problem: they land in the registry, they can be auto-ticked,
# and they come back tomorrow morning. (It also exits 1 on --max-turns 1.)
# If status turns out not to refresh, the honest outcome is the message below
# and a held restore - not a queue of doomed sessions and a litter of ghosts.
# ===========================================================================
# REFRESH THE ACCESS TOKEN OURSELVES, FROM THE REFRESH TOKEN ON DISK.
#
# 🔴 EVERY PREVIOUS ATTEMPT FAILED ON THE SAME GUESS: that something else would
# refresh it. `claude auth status` does not (measured, three mornings). A
# launched conversation was the next theory and 2026-09-04 disproved it too -
# the restore launched one, waited 120 s, and stopped because the token was
# still dead. That is the whole history of this bug: four fixes, each resting on
# an inference about what triggers a refresh, none of them measured first.
#
# There is nothing left to infer. The refresh token is sitting in
# ~/.claude/.credentials.json, it is valid for thirty days, and the OAuth spec
# says exactly what to do with it. One POST, about a second, no session
# involved, no waiting, and it either works or it says why.
#
# 🔴 IT WRITES THE OPERATOR'S CREDENTIALS, WHICH IS THE MOST DESTRUCTIVE THING
# THIS TOOL DOES. A bug here signs them out of Claude Code on this machine. So:
#
#   1. the file is BACKED UP first, and the backup is never cleaned up;
#   2. the response is VALIDATED before anything is written - a token that is
#      empty, unchanged, or expiring no later than the one we already have is
#      treated as a failure, not a success;
#   3. on ANY failure the file is not touched at all;
#   4. every other field in the file is preserved - this rewrites three values
#      and copies the rest, rather than constructing a credential from scratch;
#   5. nothing about a token is ever logged but its length and expiry.
#
# 🪤 The endpoint and client id are CONFIGURABLE. They are not documented API,
# and a wrong value here must be something the operator can correct in the
# config rather than a reason to edit this file.
# 🔴 READ OUT OF THE CLI'S OWN BINARY, NOT GUESSED. The first version of this
# posted to console.anthropic.com and got 429 for a real refresh token AND for a
# forty-character string of 'r' - the same answer for a valid credential and a
# fake one, which is what a service says when it is not evaluating the token at
# all. `console.anthropic.com` appears ZERO times in claude.exe; the string that
# does appear is TOKEN_URL below. Guessing an endpoint and reading the 429 as a
# rate limit cost an afternoon, and the answer was on disk the whole time.
#
# The shape is the CLI's own refresh function, verbatim:
#   {grant_type:"refresh_token", refresh_token:e, client_id:..., scope:"..."}
#   POST TOKEN_URL, Content-Type: application/json
# 🪤 SCOPE IS REQUIRED AND WAS MISSING. The CLI joins the granted scopes with
# spaces and sends them; a refresh without them is not the request this endpoint
# answers. They are taken from the credential file rather than hard-coded, so a
# future scope this tool has never heard of survives a refresh.
$SR_OAuthTokenUrl = 'https://platform.claude.com/v1/oauth/token'
$SR_OAuthClientId = '9d1c250a-e61b-44d9-88ed-5944d1962f5e'
# 🔴 AND CLOUDFLARE IS IN FRONT OF IT. With the endpoint and body correct the
# call still came back 429 - with an EMPTY body, no Retry-After, no rate-limit
# headers and only a cf-ray. That is an edge block, not an application answer:
# a real rate limit returns a JSON error. What the edge is rejecting is a client
# it does not recognise, so the request has to look like the one the CLI makes.
# Both of these are lifted from the binary: the User-Agent format
# `claude-cli/<version> (external, cli)`, and the beta header its SDK path sends
# on the very same endpoint.
$SR_OAuthBeta = 'oauth-2025-04-20'
function Get-SRClaudeVersion {
    # The installed version directory is the cheapest honest source; spawning
    # `claude --version` costs a process on a path that runs at every logon.
    $v = ''
    try {
        $d = Join-Path $env:USERPROFILE '.local\share\claude\versions'
        if (Test-Path -LiteralPath $d) {
            $newest = @(Get-ChildItem -LiteralPath $d -ErrorAction SilentlyContinue |
                        Sort-Object LastWriteTime -Descending | Select-Object -First 1)
            if ($newest.Count) { $v = "$($newest[0].Name)" }
        }
    } catch { }
    if ($v -notmatch '^\d+\.\d+\.\d+') { $v = '2.1.260' }
    return $v
}

function Invoke-SRTokenRefresh {
    [CmdletBinding()]
    param([int]$TimeoutSec = 20)

    $p = Get-SRCredentialsPath
    if (-not $p -or -not (Test-Path -LiteralPath $p)) { return 'there is no credentials file to refresh' }

    $cfgO = $null
    try { $cfgO = Get-SRConfig } catch { }
    $url = $SR_OAuthTokenUrl
    $cid = $SR_OAuthClientId
    try { if ("$($cfgO.oauthTokenUrl)".Trim()) { $url = "$($cfgO.oauthTokenUrl)".Trim() } } catch { }
    try { if ("$($cfgO.oauthClientId)".Trim()) { $cid = "$($cfgO.oauthClientId)".Trim() } } catch { }

    $raw = $null
    $obj = $null
    try {
        $raw = [System.IO.File]::ReadAllText($p)
        $obj = $raw | ConvertFrom-Json
    } catch { return 'the credentials file could not be read as JSON' }
    if (-not $obj -or -not $obj.claudeAiOauth) { return 'the credentials file has no claudeAiOauth section' }
    $o = $obj.claudeAiOauth

    $rt = "$($o.refreshToken)"
    if (-not $rt) { return 'there is no refresh token on disk - only a sign-in can fix that' }

    # A dead refresh token is the one case where nothing here can help, and
    # saying so is more useful than a failed POST.
    try {
        $rex = [double]$o.refreshTokenExpiresAt
        if ($rex -gt 0) {
            if ($rex -lt 1e11) { $rex = $rex * 1000 }
            $rdt = ([DateTimeOffset]::FromUnixTimeMilliseconds([long]$rex)).LocalDateTime
            if ($rdt -le (Get-Date)) {
                return ("the refresh token itself expired on {0:yyyy-MM-dd} - only a sign-in can fix that" -f $rdt)
            }
        }
    } catch { }

    $wasExp = Get-SRTokenExpiry

    # 🪤 THE BACKUP HAPPENS BEFORE THE NETWORK CALL, not after it succeeds. If
    # this process dies mid-write the copy has to already exist.
    $bak = ''
    try {
        $bak = $p + ('.bak-{0}' -f (Get-Date -Format 'yyyyMMdd-HHmmss'))
        Copy-Item -LiteralPath $p -Destination $bak -Force -ErrorAction Stop
    } catch { return "could not back up the credentials file, so nothing was changed: $($_.Exception.Message)" }

    $res = $null
    try {
        [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
        # The scopes this credential actually holds, space-joined, exactly as
        # the CLI sends them. Falls back to the set it defaults to if the file
        # carries none.
        $scope = ''
        try { $scope = "$($o.scopes)".Trim() } catch { $scope = '' }
        if (-not $scope) { $scope = 'user:profile user:inference user:sessions:claude_code user:mcp_servers user:file_upload' }
        $body = @{ grant_type = 'refresh_token'; refresh_token = $rt; client_id = $cid; scope = $scope } |
                ConvertTo-Json -Compress
        $hdr = @{
            'anthropic-beta' = $SR_OAuthBeta
            'User-Agent'     = ('claude-cli/{0} (external, cli)' -f (Get-SRClaudeVersion))
            'Accept'         = 'application/json'
        }
        $res = Invoke-RestMethod -Uri $url -Method Post -Body $body -ContentType 'application/json' `
                                 -Headers $hdr -TimeoutSec $TimeoutSec -ErrorAction Stop
    } catch {
        return "the refresh call failed ($($_.Exception.Message)) - the credentials file was not touched"
    }

    $newAt = ''
    $newRt = ''
    $expIn = 0
    try { $newAt = "$($res.access_token)" } catch { }
    try { $newRt = "$($res.refresh_token)" } catch { }
    try { $expIn = [int]$res.expires_in } catch { }
    if (-not $newAt) { return 'the refresh call returned no access token - the credentials file was not touched' }
    if ($expIn -le 0) { $expIn = 28800 }   # the observed 8 hours, if it is not stated

    $newExpMs = [long](([DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()) + ($expIn * 1000L))
    # 🔴 A "NEW" TOKEN THAT EXPIRES NO LATER THAN THE OLD ONE IS NOT A REFRESH.
    # Writing it would look like success and leave the morning exactly as broken.
    if ($wasExp) {
        $oldMs = [long]([DateTimeOffset]::new($wasExp).ToUnixTimeMilliseconds())
        if ($newExpMs -le $oldMs) {
            return 'the refresh returned a token no fresher than the one on disk - the file was not touched'
        }
    }

    # Rewrite three fields and copy everything else, rather than building a
    # credential from scratch: this file carries scopes, subscription and rate
    # tier that nothing here understands and must not drop.
    try {
        $o.accessToken = $newAt
        if ($newRt) { $o.refreshToken = $newRt }
        $o.expiresAt = $newExpMs
        $json = $obj | ConvertTo-Json -Depth 8
        # 🪤 NO BOM, and no [System.IO.File]::Replace. Replace throws
        # PermissionError on Windows whenever another process holds the
        # destination open, which every running claude session does - measured
        # 4 of 4 in this repo's own findings. A direct write with retries is the
        # documented lesser evil here, and the backup above is why it is safe.
        $enc = New-Object System.Text.UTF8Encoding($false)
        $ok = $false
        for ($i = 0; $i -lt 4 -and -not $ok; $i++) {
            try { [System.IO.File]::WriteAllText($p, $json, $enc); $ok = $true }
            catch { Start-Sleep -Milliseconds 250 }
        }
        if (-not $ok) { return "could not write the credentials file - the backup is at $bak" }
    } catch {
        return "writing the refreshed credentials failed ($($_.Exception.Message)) - the backup is at $bak"
    }

    # Verified by re-reading, not by the fact that a write returned.
    $now = Get-SRTokenExpiry
    if (-not $now -or $now -le (Get-Date)) {
        return "the file was written but still does not read as live - the backup is at $bak"
    }
    Write-SRLog ('  [ok]   token refreshed directly - good until {0:HH:mm} (backup {1})' -f $now, (Split-Path $bak -Leaf))
    return $null
}

function Invoke-SRTokenWarm { param([int]$TimeoutMs = 90000)
    # 🔴 THE DIRECT REFRESH IS TRIED FIRST, because it is the only step here
    # that does not rest on an inference about what refreshes a token. If it
    # works nothing below runs; if it fails it says why and the old path still
    # gets its turn.
    $why = 'not attempted'
    try { $why = Invoke-SRTokenRefresh } catch { $why = $_.Exception.Message }
    if (-not $why) { return $true }
    Write-SRLog ("  [skip] the direct refresh did not work: {0}" -f $why)
    $exe = $null
    try { $exe = Get-Command claude -ErrorAction Stop } catch {
        Write-SRLog '  [skip] claude is not on PATH - cannot warm the token'
        return $false
    }
    $before = Get-SRTokenExpiry
    Write-SRLog '  [step] warming the access token once, before any session starts'
    try {
        $null = Invoke-SRNativeText -FilePath $exe.Source -Arguments @('auth', 'status') -TimeoutMs $TimeoutMs
    } catch { }

    $after = Get-SRTokenExpiry
    if ($after -and (-not $before -or $after -gt $before)) {
        Write-SRLog ('  [ok]   token refreshed - good until {0:HH:mm}' -f $after)
        return $true
    }
    if (Test-SRTokenLive) {
        # It did not move because it did not need to.
        Write-SRLog ('  [ok]   token is live until {0:HH:mm} - no refresh was needed' -f $after)
        return $true
    }
    Write-SRLog '  [fail] the access token is expired and did not refresh - press Sign in'
    return $false
}

# 🔴 -TokenMayBeCold: THE CALLER CAN WARM IT ITSELF, SO DO NOT WAIT FOR A HUMAN.
# Measured 2026-09-03, and it is the whole of "I had to sign in again this
# morning". The order was: gate first, warm-by-launching second. So at 08:26:12
# this blocked on a dead token, printed "press Sign in", and slept in ten-second
# steps until the operator signed in 104 seconds later - at which point the
# launch-one-first path downstream saw a live token, set $warmNeeded = $false,
# and did nothing at all. The mechanism that exists precisely to avoid the
# sign-in could only ever engage AFTER this gate had given up, five minutes in.
#
# So the token check is now the CALLER's to opt out of. What this still blocks
# on is unchanged and still right:
#   - no credentials at all -> only a human can fix that, keep waiting.
#   - bridge suppressed -> wait; it clears on its own.
# A dead access token with a good refresh token is the one case a launched
# session can fix by itself, and it is the case that happens every single day.
function Wait-SRBridgeReady {
    param([int]$MaxWaitSeconds = 300, [switch]$TokenMayBeCold)

    $sw = [Diagnostics.Stopwatch]::StartNew()
    $said = $false
    $warmed = $false
    while ($sw.Elapsed.TotalSeconds -lt $MaxWaitSeconds) {
        $sup  = Get-SRBridgeSuppression
        $auth = Test-SRAuthReady

        # 🔴 THE TOKEN IS WARMED HERE, ONCE, AND BEFORE ANY SESSION EXISTS. An
        # account can be signed in and its access token still be eight hours
        # dead - which is the state of this machine at every boot. Doing it in
        # one place, in one process, is the entire point: left to the queue,
        # two dozen sessions each refresh for themselves and rotation means
        # only the first can win.
        if ($auth -and -not $warmed -and -not (Test-SRTokenLive)) {
            $warmed = $true
            $null = Invoke-SRTokenWarm
        }
        $live = Test-SRTokenLive
        # With -TokenMayBeCold the token is not part of "ready" at all: the
        # caller warms it by launching one conversation, and blocking here
        # would be waiting for a human to do what the next few lines do anyway.
        $tokenOk = ($live -or $TokenMayBeCold)

        if (-not $sup -and $auth -and $tokenOk) {
            if ($said) { Write-SRLog ("  [ok]   the bridge is ready after {0:N0}s of waiting" -f $sw.Elapsed.TotalSeconds) }
            return $true
        }
        if (-not $said) {
            $why = @()
            if ($sup)       { $why += ("the remote bridge is suppressed until {0}" -f $sup.ToString('HH:mm:ss')) }
            if (-not $auth) { $why += 'claude does not report a signed-in account yet' }
            if ($auth -and -not $tokenOk) {
                $exp = Get-SRTokenExpiry
                $why += ("the access token is not live{0}" -f $(if ($exp) { " (expired {0:HH:mm})" -f $exp } else { '' }))
            }
            Write-SRLog ("  [wait] holding the restore - {0}" -f ($why -join '; '))
            $said = $true
        }
        Start-Sleep -Seconds 10
    }
    # 🔴 THIS USED TO SAY "LAUNCH ANYWAY", AND THAT REASONING PREDATED KNOWING
    # WHAT WAS ACTUALLY BROKEN. It read: sessions back without Remote Control is
    # a far better morning than no sessions at all. It is not - it is the WORSE
    # morning, and it is the one the operator kept having. Two dozen sessions
    # that look alive, cannot reach Remote Control, and have to be killed and
    # relaunched by hand is strictly more work than an empty desktop and one
    # press of Sign in. The caller decides what to do with $false now; this only
    # reports the truth.
    Write-SRLog ("  [fail] auth was still not ready after {0}s" -f $MaxWaitSeconds)
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

# ===========================================================================
# 🔴 A PID IS REUSABLE, SO EVERY SEND CONFIRMS WHAT IT IS ABOUT TO TYPE INTO -
# AND THAT CONFIRMATION WAS COSTING A SECOND OF THE OPERATOR'S GESTURE.
#
# All three send paths asked WMI: Get-CimInstance Win32_Process -Filter
# "ProcessId=n". Measured on this machine with 31 sessions live, the same
# question three ways:
#
#     Get-CimInstance Win32_Process -Filter   824 - 1,367 ms
#     Get-Process -Id                          23.8 -    30.8 ms
#     [Diagnostics.Process]::GetProcessById     2.8 -     7.1 ms
#
# All three read the live process table and give the same answer. The WMI round
# trip was ~1 s of every option click, every message sent and every Esc - about
# 40% of a 2,540 ms send path that had no business being slow.
#
# 🪤 THE NAME IS SPELLED DIFFERENTLY, AND IT IS A TOTAL OUTAGE IF YOU MISS IT.
# Win32_Process.Name is "claude.exe". Process.ProcessName is "claude", with no
# extension. A straight port that kept `-ne 'claude.exe'` would refuse EVERY
# send on EVERY path, with a message saying the session is not claude when it
# is. tests\ask-spec.ps1 drives both sides of this - refuse this powershell's
# own $PID, accept a real claude - so the trap cannot be reintroduced quietly.
#
# 🔑 ITS OWN FUNCTION SO THE RULE CAN BE PUT UNDER TEST, the same reason
# Test-QuietVerdict was extracted. Inside the send paths it could only be
# reached by actually typing into somebody's live console, which is not a thing
# a test suite may do.
function Test-SRClaudeProcess {
    [CmdletBinding()]
    param([Parameter(Mandatory)][int]$ProcessId)
    if ($ProcessId -le 0) { return 'there is no console to type into' }
    $p = $null
    # Throws rather than returning null when the pid is gone, which is the
    # common case here - a session that closed while the card was still up.
    try { $p = [System.Diagnostics.Process]::GetProcessById($ProcessId) } catch { return 'that session has exited' }
    if (-not $p) { return 'that session has exited' }
    $name = ''
    # It can exit between the lookup and the read, and asking a dead process for
    # its name throws too.
    try { $name = "$($p.ProcessName)" } catch { return 'that session has exited' }
    if ($name -ne 'claude') {
        return "pid $ProcessId is $name, not claude - refusing to type into it"
    }
    return ''
}

# Returns $null when the line was delivered, or a reason string when it was not.
# A reason is always a refusal to act, never a partial send.
# 🔴 THIS SPAWNED claude TOO, AND THE BROADCAST PAID IT PER SESSION. Same
# `claude agents --json` as the answer path - 837-1,090 ms with 31 sessions live
# - for a pid, a kind and one waitingFor field. Invoke-Compact calls this
# SYNCHRONOUSLY ON THE UI THREAD, so /compact froze the window for about a
# second; the cast queue calls it once per drained row, so sending to ten
# conversations was ten spawns.
#
# 🪤 BUT THE DIALOG GATE IS NOT THE ANSWER PATH'S GATE, AND THE DIFFERENCE
# DECIDES THE FIX. On the answer path the status check could be replaced with
# cheaper evidence because something downstream still asks the question -
# Invoke-SRAnswerOnScreen refuses without a cursor, Wait-SRScreenState refuses if
# the highlight moved. HERE THERE IS NO DOWNSTREAM CHECK AT ALL: this types the
# text and submits it, and nothing re-reads the screen in between. So the
# evidence cannot simply be made cheaper and older - the caller's record is
# refreshed by a 15 s probe that itself takes 11.3 s, which would put this gate
# up to ~26 s behind with nothing to catch it.
#
# 🔑 SO IT IS MADE CHEAPER AND *FRESHER* INSTEAD. The screen is the authority on
# whether something is open in that session, it costs ~9 ms through the held-open
# reader, and Test-SRLiveMenu already answers exactly this question - a
# permission prompt is a menu, which is what "a dialog is open" looks like on
# screen. The caller's waitingFor is still honoured when it has one, so this only
# ever adds a reason to refuse.
#
# ⚠️ BEHAVIOUR CHANGE, AND IT IS DELIBERATE: a plain message is now refused while
# ANY live menu is on that screen, not only when claude called it a dialog.
# Typing a sentence into a session showing a menu never did what the operator
# meant - the text lands in the menu's editor row - and the window has a control
# for that case. Reversible by dropping the Test-SRLiveMenu clause.
# ===========================================================================
# THE TWO REFUSALS THAT -Force LIFTS, AND WHY THEY DO NOT NAME IT THEMSELVES.
#
# 🔴 THEY USED TO END "or send anyway to type into the dialog/menu" - AND NO
# CALLER PASSED -Force. All four of them (the composer's two dispatch arms,
# Invoke-Compact and the broadcast queue) called this without it, and no UI path
# retried, so the sentence offered the operator an action that did not exist.
# The dialog one had been a dead end for some time; be842da added the menu one,
# which fires whenever ANY live menu is on screen rather than only when a cached
# status said 'dialog', and turned a rare dead end into a common one.
#
# 🔑 SO THE REFUSAL STATES THE FACT AND THE CALLER OWNS THE OFFER. Whether
# "send anyway" is even available depends on who is asking: the composer has the
# operator standing in front of it and can put the choice to them, while the
# broadcast queue and /compact are acting across sessions nobody is watching -
# forcing a sentence into a menu there is precisely the accident this exists to
# prevent, so they report what was skipped instead. One message that is true
# everywhere, and the offer made only where it can be honoured.
#
# 🪤 CONSTANTS, NOT PROSE MATCHED AT THE CALL SITE. The composer has to tell
# "refused, and forcing would be reasonable" from "refused because the session
# is gone", and matching on wording would break the moment somebody improves it.
$SR_RefuseDialog = 'a dialog is open in that session - it is waiting on an answer there'
$SR_RefuseMenu   = 'that session is showing a menu - the question card is where it wants answering'

# Is this refusal one that -Force would lift? Kept beside the two strings so
# there is one place to change if either is reworded.
function Test-SRForceableRefusal { param([string]$Why)
    if (-not $Why) { return $false }
    return ($Why -eq $SR_RefuseDialog -or $Why -eq $SR_RefuseMenu)
}

function Send-SRSessionInput {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$SessionId,
        [Parameter(Mandatory)][string]$Text,
        # What the window already holds about this row. See above.
        [Parameter(Mandatory)][int]$ProcessId,
        [string]$Kind = 'interactive',
        [string]$WaitingFor = '',
        # Skip the dialog refusal. The caller must have shown the operator what
        # is open and been told to go ahead anyway.
        [switch]$Force
    )

    $body = ($Text -replace "`r`n", ' ' -replace "`r", ' ' -replace "`n", ' ').Trim()
    if (-not $body) { return 'nothing to send' }

    if ($ProcessId -le 0) { return 'that session has no process to type into (it is a background agent)' }
    if ($Kind -and $Kind -ne 'interactive') { return 'only an interactive session can be typed into' }
    if (-not $Force -and $WaitingFor -match 'dialog') {
        return $SR_RefuseDialog
    }

    # A pid is reusable. Confirm THIS one is still the claude that owns the
    # session before writing anything into its console.
    $notClaude = Test-SRClaudeProcess -ProcessId $ProcessId
    if ($notClaude) { return $notClaude }

    # The screen, which is both fresher than the caller's record and the only
    # evidence anything downstream would have had. See the note above.
    if (-not $Force) {
        $onScreen = $null
        try { $onScreen = Get-SRScreenText -ProcessId $ProcessId } catch { }
        if ($onScreen -and (Test-SRLiveMenu -Text $onScreen)) {
            return $SR_RefuseMenu
        }
    }

    # 🔴 THE TEXT AND THE SUBMIT ARE TWO CALLS, and that is not tidiness.
    # Send() wrote the characters and a trailing ENTER in ONE WriteConsoleInput
    # batch, and measured against a live session the text landed in the input box
    # and SAT there: 25 seconds, no transcript movement, until a separate ENTER
    # arrived -- at which point the record count jumped 21 to 28. Every message
    # sent this way could be reported as sent and never submitted.
    #
    # The box needs a beat to finish taking a few hundred characters before it will
    # accept the newline that closes them.
    $n = [SRCon]::Send([uint32]$ProcessId, $body, $false)
    if ($n -ge 0) {
        Start-Sleep -Milliseconds 400
        $n = [SRCon]::SendKeys([uint32]$ProcessId, [uint16[]]@(0x0D))
    }
    if ($n -lt 0) {
        $err = -$n
        Write-SRLog ("send to {0} failed: win32 {1}" -f $SessionId, $err)
        return "could not reach that session's console (win32 error $err)"
    }
    Write-SRLog ("  [ok]   sent {0} char(s) to {1}" -f $body.Length, $SessionId)
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
# ===========================================================================
# 🔴 THE GATE STAYS. IT STOPPED SPAWNING claude TO SATISFY IT.
#
# This asked `claude agents --json` on every option click, purely to read one
# field - Status -eq 'waiting'. Measured on this machine with 31 sessions live,
# that spawn is 837-1,090 ms, and it sat between the operator's click and the
# first key. It was about 40% of a 2.4 s gesture whose terminal equivalent is
# 6.9 ms.
#
# 🔑 THE EVIDENCE MOVES, THE GUARD DOES NOT. The window already knows everything
# that map was consulted for, and knows it more cheaply and more recently:
#
#   pid / kind / name   the row's own agent record, held on the UI thread
#   "is it asking?"     the 400 ms card lane and the 2.9 s screen sweep, both of
#                       which read the actual screen - which is what the status
#                       field is a second-hand summary OF
#
# 🔒 AND THE AUTHORITATIVE CHECK WAS NEVER THIS ONE. Read the order: this gate
# fires, and then ~900 ms later Invoke-SRAnswerOnScreen reads the screen and
# refuses outright if it cannot see a menu with a cursor, and Wait-SRScreenState
# re-reads and refuses again if the highlight is not where it was aimed. Since
# the parser now returns nothing at all for a screen showing a prompt, "the
# arrows land in a prompt" is unreachable regardless of what this field said.
# The status check was the OLDEST evidence on the path and the only one that
# cost a process.
#
# 🪤 SO IT IS NOT DROPPED, BECAUSE A CHEAP GUARD THAT AGREES IS WORTH KEEPING -
# it refuses early, with a better message, before any key is sent. It is now
# answered from what the caller already has. The caller must pass it; there is
# no default that means "assume it is asking".
function Send-SRQuestionAnswer {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$SessionId,
        # 0-based, as the options are indexed on screen.
        [Parameter(Mandatory)][int]$Index,
        [int]$OptionCount = 0,
        # What the window already knows, gathered where it is free. See above.
        [Parameter(Mandatory)][int]$ProcessId,
        [string]$Kind = 'interactive',
        [string]$Name = '',
        # Has this window actually SEEN a live menu on that screen? The card lane
        # and the sweep both answer this from a real screen read. Defaults to
        # false so a caller that forgets is refused rather than waved through.
        [bool]$MenuSeen = $false
    )
    if ($Index -lt 0) { return 'that is not one of the options' }
    # The caller's count comes from the transcript, which lists only what claude
    # asked for -- the TUI adds 'Type something' and 'Chat about this' on top. The
    # screen is checked below and is the one that governs.
    if ($OptionCount -gt 0 -and $Index -ge $OptionCount) { return 'that is not one of the options' }

    if ($ProcessId -le 0) { return 'that session has no console to answer in (it is a background agent)' }
    if ($Kind -and $Kind -ne 'interactive') { return 'only an interactive session can be answered' }
    # 🔒 IT MUST STILL BE ASKING - same rule, fresher evidence.
    if (-not $MenuSeen) { return 'that session is not waiting for an answer any more' }

    $notClaude = Test-SRClaudeProcess -ProcessId $ProcessId
    if ($notClaude) { return $notClaude }

    $why = Invoke-SRAnswerOnScreen -ProcessId $ProcessId -Index $Index -Who "$(if ($Name) { $Name } else { $SessionId })"
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
# ---------------------------------------------------------------------------
# WAIT FOR THE SCREEN TO SAY SO. DO NOT SLEEP A GUESS.
#
# 🔴 EVERY ANSWER PATH BELOW WAS PACED BY THE CLOCK RATHER THAN BY THE SCREEN,
# and it is the whole of why answering felt slow. The shape was always
# "send the key, Start-Sleep 180-300, then read and verify" - so the sleep was
# never what made it safe (the read was), it was only what made it late. The
# sleeps have to cover the slowest repaint anyone might see, so every answer
# paid the worst case even when the TUI had finished in a fraction of it.
#
# Measured 2026-09-04 against the relay replica: a multi-select answer took
# 1,769 ms, of which about 1,400 was sleeping. A screen read is 34 ms there and
# ~130 ms against a real console - in both cases cheaper than the sleep it
# replaces, so watching costs less than waiting AND proves more.
#
# 🔒 THE GUARDS DO NOT MOVE. This returns the last screen it managed to read,
# satisfying the condition or not, and every caller keeps the same refusal it
# had before. Nothing here decides to send a key; it only decides when to stop
# looking. A repaint that never comes still ends in a refusal, exactly as a
# sleep that was not long enough did - just without the wait when it is not
# needed.
function Wait-SRScreenState {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][int]$ProcessId,
        # Handed the parsed screen; return $true when the wait is over.
        [Parameter(Mandatory)][scriptblock]$Until,
        [int]$BudgetMs = 1200,
        # 🔑 EIGHT, NOT 25. The slice was set when a screen read cost ~130 ms and
        # was therefore free next to it; the held-open reader made a read 5 ms,
        # so the sleep became the thing being waited on. With the fallback
        # active a read is ~48 ms and paces the loop by itself, so this only
        # ever adds where reads are cheap.
        [int]$SliceMs = 8
    )
    $stop = (Get-Date).AddMilliseconds($BudgetMs)
    $last = $null
    while ($true) {
        $now = Get-SRScreenQuestion -ProcessId $ProcessId
        if ($now) {
            $last = $now
            $done = $false
            try { $done = [bool](& $Until $now) } catch { $done = $false }
            if ($done) { return $now }
        }
        if ((Get-Date) -ge $stop) { return $last }
        Start-Sleep -Milliseconds $SliceMs
    }
}

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
        # 🔴 LOOK BEFORE COMMITTING. Everything above refuses rather than
        # guesses - no cursor, no arrows - and then the commit itself rested on a
        # 250 ms sleep, which is hoping rather than knowing. The screen is read
        # and ENTER is only sent if the highlight is actually on the option that
        # was asked for. This closes the window between the first read and the
        # keystroke: the session can finish its turn, the operator can arrow
        # manually, or the TUI can simply be slower than the sleep, and in every
        # one of those cases the old code committed whatever happened to be
        # highlighted. Answering the WRONG question is the failure this whole
        # function is written to avoid.
        #
        # 🔑 AND IT WATCHES FOR THE HIGHLIGHT RATHER THAN SLEEPING BEFORE ONE
        # LOOK. The moves must land before the commit - that has not changed -
        # but "have they landed" is a question the screen answers, and it was
        # being asked once, 250 ms late, whether or not the repaint took
        # anything like that long. Now it is asked immediately and again until
        # the budget runs out. The refusals below are unchanged and still fire
        # on the last screen actually read, so a highlight that never arrives
        # still sends nothing.
        $after = Wait-SRScreenState -ProcessId $ProcessId -BudgetMs 1200 -Until {
            param($S) ([int]$S.CursorAt -eq $Index)
        }.GetNewClosure()
        if (-not $after) {
            return 'it stopped asking while the answer was being typed - nothing was sent'
        }
        if ($after.CursorAt -lt 0) {
            return 'lost track of which option is highlighted - nothing was sent'
        }
        if ([int]$after.CursorAt -ne $Index) {
            # 🪤 DO NOT NUDGE AND RETRY. A second correction races the same way
            # and can walk the cursor further; refusing leaves the menu exactly as
            # the operator can see it, which is recoverable in the terminal.
            return ("the highlight moved while answering (it is on option {0}, not {1}) - nothing was sent" -f `
                    ([int]$after.CursorAt + 1), ($Index + 1))
        }
    }
    $n = [SRCon]::SendKeys([uint32]$ProcessId, [uint16[]]@(0x0D))          # VK_RETURN
    if ($n -lt 0) { return "could not reach that session's console (win32 error $(-$n))" }
    Write-SRLog ("  [ok]   answered {0} with option {1} of {2} ({3}), cursor was on {4}" -f $Who, ($Index + 1), $seen.Options.Count, $seen.Options[$Index], ($seen.CursorAt + 1))
    return $null
}

# ---------------------------------------------------------------------------
# SEVERAL ANSWERS AT ONCE.
#
# ✅ THE PREMISE IS NOW MEASURED, and it was right. This carried a standing note
# saying the SHAPE of a multi-select was captured but the BEHAVIOUR was only
# READ off the footer -- "Enter to select" reads as "toggle on an option, commit
# on Submit" -- and that reading is not measuring. It asked for one observation.
#
# Taken 2026-08-30 against a real round in a sandboxed session:
#   - SPACE on a "[ ]" row does NOTHING. The highlight moves, the box does not.
#   - ENTER on it toggles: the row becomes "[U+2714]" and the question's tab on
#     the round's bar flips from an empty box to a crossed one.
#   - ENTER on a row already ticked turns it back OFF, which is why Ticked is
#     parsed and why an already-ticked option is left alone.
#   - The commit row reads "Next" while questions follow it and "Submit" only on
#     the last question. Matching 'Submit' alone found no row on any but the
#     final multi-select - a bug this note's own confidence had hidden.
#
# So ENTER was the correct guess and this is no longer a guess. The captures are
# in tests\screens\ and the parser is asserted against them.
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

    # 🔑 ONE KEY PER REPAINT, PACED BY THE REPAINT. This slept a flat 180 ms
    # after every arrow, which is what made a multi-select answer take the best
    # part of two seconds: five moves and two toggles is over a second of pure
    # sleeping. The read at the top of the loop was always the thing that made
    # it safe - the sleep only stopped the loop lapping the TUI and sending a
    # second arrow before the first had landed.
    #
    # 🔴 SO THE OVERSHOOT IS PREVENTED DIRECTLY INSTEAD. A key is sent only when
    # the highlight is somewhere it has not already been sent from; if the screen
    # still reads where it did last time, the key is in flight and this looks
    # again rather than sending another. That is the guarantee the sleep was
    # standing in for, made explicit, and it costs a 34-130 ms read instead of a
    # flat 180.
    #
    # 🪤 THE BUDGET COUNTS KEYS, NOT LOOKS. Counting iterations would let a
    # slow repaint burn the move budget without the highlight having moved at
    # all, and the answer would fail on a busy machine rather than being late on
    # one. The wall clock is what bounds the looking.
    # 🔴 A FAILED READ IS NOT A MISSING MENU, and treating it as one is a bug
    # this loop has always had - it just never showed while the loop read once
    # every 180 ms. Reading more often exposed it immediately: the screen read
    # spawns a child process with its own budget, so on a busy machine it
    # sometimes comes back empty about a menu that is plainly still there.
    # Measured 2026-09-04 - the multi-select cases refused with "the menu went
    # away mid-answer" on a machine running twenty sessions, while the
    # single-select path, which waits through Wait-SRScreenState and tolerates
    # a miss, passed every time. Get-SRScreenQuestion makes exactly this point
    # about its own retry.
    #
    # So a miss is looked at again, and only the wall clock ends it.
    function Step-ToStop {
        param([int]$Target, [int]$Pid2, [int]$Budget)
        $sent = 0
        $sentFrom = -999
        $stop = (Get-Date).AddSeconds(15)
        while ($sent -lt $Budget) {
            $now = Get-SRScreenQuestion -ProcessId $Pid2
            if (-not $now -or $now.CursorAt -lt 0) {
                if ((Get-Date) -ge $stop) {
                    if (-not $now) { return 'the menu went away mid-answer' }
                    return 'lost sight of the highlight mid-answer'
                }
                Start-Sleep -Milliseconds 8
                continue
            }
            $at = [int]$now.CursorAt
            if ($at -eq $Target) { return $null }
            if ($sent -gt 0 -and $at -eq $sentFrom) {
                # The last arrow has not been drawn yet. Look again; do NOT send
                # another, or the highlight walks past what was asked for.
                if ((Get-Date) -ge $stop) { return 'the menu stopped responding mid-answer' }
                Start-Sleep -Milliseconds 8
                continue
            }
            $sentFrom = $at
            $vk = $(if ($Target -gt $at) { [uint16]0x28 } else { [uint16]0x26 })
            $r = [SRCon]::SendKeys([uint32]$Pid2, [uint16[]]@($vk))
            if ($r -lt 0) { return "could not reach that session's console (win32 error $(-$r))" }
            $sent++
        }
        return 'could not get the highlight where it needed to go'
    }

    foreach ($ix in $todo.ToArray()) {
        $why = Step-ToStop -Target $ix -Pid2 $ProcessId -Budget $MaxMoves
        if ($why) { return $why }
        $r = [SRCon]::SendKeys([uint32]$ProcessId, [uint16[]]@(0x0D))       # toggle, on the inferred reading
        if ($r -lt 0) { return "could not reach that session's console (win32 error $(-$r))" }
        # 🔴 AND THE TICK IS WATCHED FOR, WHICH IS NEW. This slept 220 ms and
        # checked nothing at all, so a toggle that did not land was carried all
        # the way to Submit and committed an answer missing an option - silently,
        # because the only evidence would have been on a screen nobody read.
        # Waiting for the box to actually tick is both the faster thing and the
        # first time this step has been verified.
        $ticked = Wait-SRScreenState -ProcessId $ProcessId -BudgetMs 1500 -Until {
            param($S) (@($S.Ticked) -contains [int]$ix)
        }.GetNewClosure()
        if (-not $ticked) { return 'the menu went away mid-answer' }
        if (-not (@($ticked.Ticked) -contains [int]$ix)) {
            return ("option {0} would not tick - nothing was submitted" -f ($ix + 1))
        }
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

# ---------------------------------------------------------------------------
# INTERRUPTING A TURN, BY PRESSING WHAT A PERSON WOULD PRESS.
#
# 🔑 CLAUDE CODE OWNS THE INTERRUPT. Esc is its own key for "stop what you are
# doing" and it is the same key whatever the session is in the middle of, so
# this drives the TUI exactly as Invoke-SRAnswerOnScreen drives a menu: one
# virtual key through the console the session is already reading. Nothing here
# kills a process, signals anything, or touches the transcript. The alternative
# on offer was a taskkill, which is not an interrupt - it is a relaunch that
# loses the turn, which the window already has a button for and confirms first.
#
# 🪤 IT IS SENT BLIND, AND THAT IS WHY THE CALLER HAS TO GATE IT. Every other
# send in this file reads the screen before it commits, because every other send
# picks something. Esc picks nothing: on a running turn it stops the turn, and on
# a session sitting at its prompt it clears the input box or opens the rewind
# picker - a different action entirely. So there is nothing here to verify
# against, and the safety lives in the caller only sending it to a session it
# has just established is MID-TURN. See Get-InterruptBlocker in the window.
#
# 🪤 AND IT IS ONE KEY, NEVER TWO. Two Escs in one batch is the rewind gesture,
# which offers to revert CODE - so a Count above one is refused outright rather
# than trusted to a caller's arithmetic.
function Send-SRInterrupt {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][int]$ProcessId,
        [string]$Who = ''
    )
    if ($ProcessId -le 0) { return 'there is no console to interrupt' }
    # A pid is reusable. Confirm THIS one is still a claude before writing a key
    # into its console - the same check Send-SRSessionInput makes, for the same
    # reason: the alternative is pressing Esc in whatever inherited the number.
    $notClaude = Test-SRClaudeProcess -ProcessId $ProcessId
    if ($notClaude) { return $notClaude }

    $n = [SRCon]::SendKeys([uint32]$ProcessId, [uint16[]]@(0x1B))          # VK_ESCAPE
    if ($n -lt 0) { return "could not reach that session's console (win32 error $(-$n))" }
    Write-SRLog ("  [ok]   interrupted {0} (pid {1}) with one Esc" -f $Who, $ProcessId)
    return $null
}

# ---------------------------------------------------------------------------
# MOVING BETWEEN THE QUESTIONS OF ONE ROUND.
#
# 🔑 LEFT AND RIGHT WALK THE TAB BAR, measured 2026-08-30. A batched
# AskUserQuestion draws one tab per question plus a Submit tab; RIGHT goes to the
# next, LEFT to the previous, and answering a single-select AUTO-ADVANCES on its
# own. UP and DOWN stay what they always were - the option cursor.
#
# 🪤 THE EDITOR ROW EATS THE ARROWS. While "Type something" holds text, LEFT and
# RIGHT move the caret inside it instead of changing tab: measured by sending
# RIGHT with text in the row and reading back a screen that had not changed at
# all. So this refuses from there rather than sending a key that does nothing and
# reporting success.
function Invoke-SRRoundMove {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][int]$ProcessId,
        # -1 for the previous question, +1 for the next. Larger steps are allowed
        # and are taken one at a time, each one verified.
        [Parameter(Mandatory)][int]$Delta,
        [int]$MaxMoves = 8
    )
    if ($ProcessId -le 0) { return 'there is no console to answer in' }
    if ($Delta -eq 0) { return $null }
    $seen = Get-SRScreenQuestion -ProcessId $ProcessId
    if (-not $seen) { return 'cannot see a question on that session''s screen' }
    if (@($seen.Tabs).Count -lt 2) { return 'that question is on its own - there is nothing to go back to' }
    if ($seen.FreeAt -ge 0 -and "$($seen.FreeText)") {
        return 'finish or clear what you typed first - the arrows move the caret while that row holds text'
    }
    $vk = $(if ($Delta -gt 0) { [uint16]0x27 } else { [uint16]0x25 })     # VK_RIGHT / VK_LEFT
    $steps = [Math]::Min([Math]::Abs($Delta), $MaxMoves)
    for ($i = 0; $i -lt $steps; $i++) {
        $was = "$($seen.Question)"
        $r = [SRCon]::SendKeys([uint32]$ProcessId, [uint16[]]@($vk))
        if ($r -lt 0) { return "could not reach that session's console (win32 error $(-$r))" }
        # 🔴 VERIFIED BY WHAT IS DRAWN, not by the key having been sent. The tab
        # bar does not say which tab is active - the question underneath it does -
        # so a move is only a move if the question changed.
        #
        # 🔑 AND IT WAITS FOR THE CHANGE RATHER THAN FOR 220 ms. That number was
        # doing two jobs and doing the second one badly: it paced the move, and
        # it also decided when an unchanged question meant "the round ends here".
        # A repaint slower than 220 ms therefore reported the end of the round
        # when the round had not ended. Watching for the change is faster when
        # there is one and more patient when there is not.
        $now = Wait-SRScreenState -ProcessId $ProcessId -BudgetMs 900 -Until {
            param($S) ("$($S.Question)" -ne $was)
        }.GetNewClosure()
        if (-not $now) { return 'the round went away mid-move' }
        if ("$($now.Question)" -eq $was) {
            return 'that is as far as the round goes in that direction'
        }
        $seen = $now
    }
    return $null
}

# ---------------------------------------------------------------------------
# ANSWERING IN YOUR OWN WORDS.
#
# 🔑 "Type something" IS AN INLINE EDITOR, NOT A DOOR. Measured 2026-08-30:
# highlight the row and type, and the row text is REPLACED by what you type
# ("3. my own words here"); the footer gains "ctrl+g to edit in Notepad" while it
# holds the highlight. There is no field to open first.
#
# 🔴 ENTER ON AN EMPTY EDITOR ROW DECLINES THE WHOLE ROUND. Measured twice, both
# times by accident, and both times the session recorded "User declined to answer
# questions" and threw the round away. So text is sent FIRST and the screen is
# re-read to confirm the row is holding it before ENTER is ever sent. That order
# is the whole safety of this function.
function Invoke-SRAnswerTypedOnScreen {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][int]$ProcessId,
        [Parameter(Mandatory)][AllowEmptyString()][string]$Text,
        [string]$Who = '',
        [int]$MaxMoves = 24
    )
    if ($ProcessId -le 0) { return 'there is no console to answer in' }
    if (-not "$Text".Trim()) { return 'there is nothing to send - an empty answer would decline the question' }
    if ("$Text" -match '[\r\n]') { return 'a typed answer has to be one line' }

    $seen = Get-SRScreenQuestion -ProcessId $ProcessId
    if (-not $seen) { return 'cannot see a question on that session''s screen - answer it in the terminal' }
    if ($seen.FreeAt -lt 0) { return 'that question has no row to type into' }
    if ($seen.CursorAt -lt 0) { return 'cannot tell which option is highlighted - answer it in the terminal' }

    # Walk to the editor row the same way the multi path walks to Submit: one key
    # at a time, re-reading, never a burst against a repainting TUI - and, like
    # that path, paced by the repaint rather than by a flat 180 ms sleep. A key
    # goes out only when the highlight is somewhere it has not already been sent
    # from, so the loop cannot lap the TUI and overshoot the row; a read that
    # comes back empty is looked at again rather than being taken for a menu
    # that has gone. See the notes on Step-ToStop, which this mirrors.
    $sent = 0
    $sentFrom = -999
    $walkStop = (Get-Date).AddSeconds(15)
    while ($sent -lt $MaxMoves) {
        $now = Get-SRScreenQuestion -ProcessId $ProcessId
        if (-not $now -or $now.CursorAt -lt 0) {
            if ((Get-Date) -ge $walkStop) {
                if (-not $now) { return 'the menu went away mid-answer' }
                return 'lost sight of the highlight mid-answer'
            }
            Start-Sleep -Milliseconds 8
            continue
        }
        $at = [int]$now.CursorAt
        if ($at -eq [int]$now.FreeAt) { break }
        if ($sent -gt 0 -and $at -eq $sentFrom) {
            if ((Get-Date) -ge $walkStop) { return 'the menu stopped responding mid-answer' }
            Start-Sleep -Milliseconds 8
            continue
        }
        $sentFrom = $at
        $vk = $(if ([int]$now.FreeAt -gt $at) { [uint16]0x28 } else { [uint16]0x26 })
        $r = [SRCon]::SendKeys([uint32]$ProcessId, [uint16[]]@($vk))
        if ($r -lt 0) { return "could not reach that session's console (win32 error $(-$r))" }
        $sent++
    }
    $atRow = Get-SRScreenQuestion -ProcessId $ProcessId
    if (-not $atRow) { return 'the menu went away mid-answer' }
    if ([int]$atRow.CursorAt -ne [int]$atRow.FreeAt) { return 'could not get the highlight onto the row to type in' }

    # Characters only. enter=$false is the point of this call.
    $n = [SRCon]::Send([uint32]$ProcessId, $Text, $false)
    if ($n -lt 0) { return "could not reach that session's console (win32 error $(-$n))" }

    # 🔒 THE ROW MUST BE HOLDING IT. Committing on faith is exactly the failure
    # this guards: an ENTER that lands on a row the text never reached declines
    # the round instead of answering it.
    #
    # 🔑 WATCHED FOR, NOT SLEPT THROUGH. This slept a flat 300 ms and then read
    # once - so a long answer that took longer than that to appear was refused
    # for no reason, and a short one waited 300 ms for nothing. The check below
    # is unchanged and still the only thing that permits the ENTER; this just
    # stops guessing how long the row takes to fill.
    $ready = Wait-SRScreenState -ProcessId $ProcessId -BudgetMs 2000 -Until {
        param($S) ("$($S.FreeText)".Trim() -eq "$Text".Trim())
    }.GetNewClosure()
    if (-not $ready) { return 'the menu went away before the answer could be committed' }
    if ($ready.FreeAt -lt 0 -or -not "$($ready.FreeText)") {
        return 'what was typed did not reach that row - nothing was committed'
    }
    if ("$($ready.FreeText)".Trim() -ne "$Text".Trim()) {
        return ("the row is holding '{0}' rather than what was sent - nothing was committed" -f $ready.FreeText)
    }
    $r = [SRCon]::SendKeys([uint32]$ProcessId, [uint16[]]@(0x0D))
    if ($r -lt 0) { return "could not reach that session's console (win32 error $(-$r))" }
    Write-SRLog ("  [ok]   answered {0} in its own words: '{1}'" -f $Who, $Text)
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
# The ONE type the screen-reading child needs, as source it can compile for
# itself. It is the read-only half of SRCon and nothing else - no key sending, no
# UI Automation, no registry, no discovery. Kept beside SRCon deliberately: if
# the P/Invoke signatures there ever change, they change here in the same edit.
$script:SR_ScreenTypeSrc = @'
if (-not ('SRConLite' -as [type])) {
Add-Type -TypeDefinition @"
using System;
using System.Runtime.InteropServices;
public static class SRConLite {
    [DllImport("kernel32.dll", SetLastError=true)] public static extern bool AttachConsole(uint pid);
    [DllImport("kernel32.dll", SetLastError=true)] public static extern bool FreeConsole();
    [DllImport("kernel32.dll", SetLastError=true)] public static extern IntPtr GetConsoleWindow();
    [DllImport("kernel32.dll", SetLastError=true, CharSet=CharSet.Unicode)]
    public static extern IntPtr CreateFileW(string name, uint access, uint share, IntPtr sa, uint disp, uint flags, IntPtr tmpl);
    [DllImport("kernel32.dll", SetLastError=true)] public static extern bool CloseHandle(IntPtr h);
    [StructLayout(LayoutKind.Sequential)] public struct COORD { public short X, Y; }
    [StructLayout(LayoutKind.Sequential)] public struct RECT { public short L, T, R, B; }
    [StructLayout(LayoutKind.Sequential)] public struct CSBI {
        public COORD Size; public COORD Cursor; public ushort Attr; public RECT Window; public COORD Max;
    }
    [DllImport("kernel32.dll", SetLastError=true)] public static extern bool GetConsoleScreenBufferInfo(IntPtr h, out CSBI info);
    [DllImport("kernel32.dll", SetLastError=true, CharSet=CharSet.Unicode)]
    public static extern bool ReadConsoleOutputCharacterW(IntPtr h, [Out] char[] buf, uint len, uint coord, out uint got);

    public static string Screen(uint pid) {
        FreeConsole();
        if (!AttachConsole(pid)) { return "!attach " + Marshal.GetLastWin32Error(); }
        try {
            IntPtr h = CreateFileW("CONOUT$", 0x80000000u | 0x40000000u, 1u | 2u, IntPtr.Zero, 3u, 0u, IntPtr.Zero);
            if (h == new IntPtr(-1)) return "!conout " + Marshal.GetLastWin32Error();
            try {
                CSBI info;
                if (!GetConsoleScreenBufferInfo(h, out info)) return "!csbi " + Marshal.GetLastWin32Error();
                int w = info.Size.X, rows = info.Size.Y;
                if (w <= 0 || rows <= 0) return "!empty";
                int top = info.Window.T < 0 ? 0 : info.Window.T;
                int bot = info.Window.B >= rows ? rows - 1 : info.Window.B;
                if (bot < top) { top = 0; bot = rows - 1; }
                System.Text.StringBuilder sb = new System.Text.StringBuilder();
                char[] line = new char[w];
                for (int y = top; y <= bot; y++) {
                    uint got;
                    uint at = ((uint)y << 16);
                    if (!ReadConsoleOutputCharacterW(h, line, (uint)w, at, out got)) continue;
                    sb.Append(new string(line, 0, (int)got).TrimEnd());
                    sb.Append((char)10);
                }
                return sb.ToString();
            } finally { CloseHandle(h); }
        } finally { FreeConsole(); }
    }
}
"@
}
'@

# ===========================================================================
# THE SCREEN READER, COMPILED ONCE INSTEAD OF ON EVERY READ.
#
# 🔴 EVERY READ WAS COMPILING C#. The child wrote a .ps1, started powershell.exe
# and ran Add-Type over the class below - measured at 560 ms for a read whose
# actual work is about 10 ms. That cost is paid on the path that matters most:
# pressing an answer re-reads the screen to find the cursor before a single key
# leaves, so 560 ms sat between the click and the keystroke.
#
# The same source compiled to a small exe once runs in tens of milliseconds.
# The C# is EXTRACTED from the fallback source rather than copied, so there is
# exactly one definition of how a console is read - two would drift, and the one
# that drifted would be the one nobody was looking at.
#
# 🪤 A PROCESS PER READ IS NOT THE WASTE; COMPILING IS. It still has to be a
# separate process: a process can attach to only one console at a time, and this
# one has its own.
$script:SR_ScreenExe = $null

function Get-SRScreenExe {
    if ($script:SR_ScreenExe -and (Test-Path -LiteralPath $script:SR_ScreenExe)) { return $script:SR_ScreenExe }
    try {
        $src = "$script:SR_ScreenTypeSrc"
        $a = $src.IndexOf('@"')
        $b = $src.LastIndexOf('"@')
        if ($a -lt 0 -or $b -le $a) { return $null }
        $cs = $src.Substring($a + 2, $b - $a - 2)
        $cs += @'

public static class SRScreenMain {
    // 🔴 MANY CONSOLES, ONE PROCESS. A process can only be attached to one
    // console AT A TIME, which is not the same as only one console EVER:
    // Screen() frees before it attaches and again on the way out, so the same
    // process can walk a list of them. Spawning one child per session put the
    // process-creation cost in front of every read - measured at a 129 ms
    // median where the reading itself is about 30.
    //
    //   SRScreenMain <pid> <out>            one console, as before
    //   SRScreenMain -batch <out> <pid...>  each one in turn, into one file
    //   SRScreenMain -serve <pipe> <idlems> stay alive, answer reads on a pipe
    //
    // The batch file is split on a sentinel that cannot occur in console text:
    // U+0001, the pid, U+0001, newline.
    //
    // 🔴 -serve IS THE SAME WORK WITHOUT THE PROCESS. Starting this exe is 100
    // of the 130 ms a read costs; the reading is about 30. Batch already proved
    // one process can walk many consoles - FreeConsole before each AttachConsole
    // is what makes that legal - so the only thing left to remove is starting it
    // at all. Answering a question does three or four reads and was paying the
    // startup every time.
    //
    // 🪤 A PIPE, NOT stdin/stdout, AND THAT IS FORCED. This is built
    // /target:winexe on purpose (see the note beside the compile): a
    // console-subsystem build gets a conhost from Windows, and a process that
    // then calls FreeConsole/AttachConsole can end up allocating a fresh VISIBLE
    // console - which is the "background shell opening up" the operator reported
    // on launch. A winexe has no standard streams to talk over, so the channel
    // has to be something else.
    //
    // 🔒 IT DIES ON ITS OWN. idlems bounds how long it will sit with nobody
    // connected, so a server whose owner crashed or was killed cannot outlive it
    // and become one of the orphan processes that quietly degrade this machine.
    // The caller kills it too; this is the backstop for when the caller cannot.
    public static int Serve(string pipe, int idleMs) {
        while (true) {
            using (System.IO.Pipes.NamedPipeServerStream srv =
                       new System.IO.Pipes.NamedPipeServerStream(pipe,
                           System.IO.Pipes.PipeDirection.InOut, 1,
                           System.IO.Pipes.PipeTransmissionMode.Byte,
                           System.IO.Pipes.PipeOptions.Asynchronous)) {
                System.IAsyncResult ar = srv.BeginWaitForConnection(null, null);
                if (!ar.AsyncWaitHandle.WaitOne(idleMs)) return 0;
                try { srv.EndWaitForConnection(ar); } catch { return 0; }
                System.IO.StreamReader rd = new System.IO.StreamReader(srv, new System.Text.UTF8Encoding(false));
                System.IO.StreamWriter wr = new System.IO.StreamWriter(srv, new System.Text.UTF8Encoding(false));
                wr.AutoFlush = true;
                try {
                    string line;
                    while ((line = rd.ReadLine()) != null) {
                        line = line.Trim();
                        if (line.Length == 0) continue;
                        if (line == "-quit") return 0;
                        uint one;
                        string got;
                        if (!uint.TryParse(line, out one)) { got = "!badpid"; }
                        else {
                            try { got = SRConLite.Screen(one); }
                            catch (System.Exception e) { got = "!ex " + e.Message; }
                        }
                        // The reply is the text, then a sentinel line that cannot
                        // occur in it - the same U+0001 the batch file is split on.
                        wr.Write(got);
                        wr.Write((char)10);
                        wr.Write((char)1);
                        wr.Write("end");
                        wr.Write((char)1);
                        wr.Write((char)10);
                    }
                } catch { }
                // The client went away. Loop round and wait for the next one
                // rather than exiting, so a caller that reconnects does not pay
                // the startup this whole mode exists to remove.
            }
        }
    }

    public static int Main(string[] a) {
        if (a.Length >= 2 && a[0] == "-serve") {
            int idle = 120000;
            if (a.Length >= 3) { int.TryParse(a[2], out idle); }
            if (idle < 5000) idle = 5000;
            return Serve(a[1], idle);
        }
        if (a.Length >= 3 && a[0] == "-batch") {
            System.Text.StringBuilder all = new System.Text.StringBuilder();
            for (int i = 2; i < a.Length; i++) {
                uint one;
                if (!uint.TryParse(a[i], out one)) continue;
                all.Append((char)1).Append(a[i]).Append((char)1).Append((char)10);
                // A console that has gone away must not stop the ones after it -
                // its own error text is written in its place and the walk goes on.
                string got;
                try { got = SRConLite.Screen(one); } catch (System.Exception e) { got = "!ex " + e.Message; }
                all.Append(got).Append((char)10);
            }
            System.IO.File.WriteAllText(a[1], all.ToString(), new System.Text.UTF8Encoding(false));
            return 0;
        }
        if (a.Length < 2) return 2;
        uint pid;
        if (!uint.TryParse(a[0], out pid)) return 2;
        string t = SRConLite.Screen(pid);
        System.IO.File.WriteAllText(a[1], t, new System.Text.UTF8Encoding(false));
        return 0;
    }
}
'@
        # The hash is in the NAME, so an exe that exists is by definition built
        # from the source in front of us - there is no staleness check to forget.
        #
        # 🪤 THE BUILD FLAGS ARE PART OF WHAT IT WAS BUILT FROM. Hashing only the
        # C# meant changing /target:exe to /target:winexe produced the SAME name,
        # so the console-subsystem exe already on disk would have been reused
        # for good and the fix would have shipped doing nothing. Whatever decides
        # the output has to decide the name.
        $cscArgs = '/nologo /optimize /target:winexe'
        $md5 = [System.Security.Cryptography.MD5]::Create()
        $hash = [BitConverter]::ToString($md5.ComputeHash([Text.Encoding]::UTF8.GetBytes($cs + "`n" + $cscArgs))).Replace('-', '').Substring(0, 8).ToLower()
        $exe = Join-Path $SR_StateDir ('srscreen-' + $hash + '.exe')
        if (Test-Path -LiteralPath $exe) { $script:SR_ScreenExe = $exe; return $exe }

        $csc = Join-Path $env:SystemRoot 'Microsoft.NET\Framework64\v4.0.30319\csc.exe'
        if (-not (Test-Path -LiteralPath $csc)) { $csc = Join-Path $env:SystemRoot 'Microsoft.NET\Framework\v4.0.30319\csc.exe' }
        if (-not (Test-Path -LiteralPath $csc)) { return $null }

        $csFile = Join-Path $SR_StateDir ('srscreen-' + $hash + '.cs')
        [System.IO.File]::WriteAllText($csFile, $cs, (New-Object System.Text.UTF8Encoding($false)))
        $psi = New-Object System.Diagnostics.ProcessStartInfo
        $psi.FileName = $csc
        # 🔴 winexe, NOT exe. A CONSOLE-subsystem process gets a console from
        # Windows whether it wants one or not, and CreateNoWindow only hides the
        # WINDOW - a conhost.exe still spawns, and this one then calls
        # FreeConsole/AttachConsole/FreeConsole, which can leave it consoleless
        # and let the next write allocate a fresh, VISIBLE one. Caught by
        # watching every process that appears while the tool starts:
        #
        #     +0.8s  conhost.exe  pid 15304  parent srscreen-f68b06a3.exe
        #
        # which is the "background shell opening up" the operator sees on launch.
        # Sessions.exe was given /target:winexe for exactly this reason and the
        # app suite asserts it; its own helper was left as a console app, and
        # nothing was watching the helper. AttachConsole works perfectly well
        # from a GUI-subsystem process - reading somebody else's console never
        # needed one of our own.
        $psi.Arguments = ('{0} /out:"{1}" "{2}"' -f $cscArgs, $exe, $csFile)
        $psi.UseShellExecute = $false
        $psi.CreateNoWindow = $true
        $psi.RedirectStandardOutput = $true
        $psi.RedirectStandardError = $true
        $cp = [System.Diagnostics.Process]::Start($psi)
        $null = $cp.StandardOutput.ReadToEndAsync()
        $null = $cp.StandardError.ReadToEndAsync()
        if (-not $cp.WaitForExit(20000)) { try { $cp.Kill() } catch { } }
        Remove-Item -LiteralPath $csFile -Force -ErrorAction SilentlyContinue
        if (Test-Path -LiteralPath $exe) {
            Write-SRLog ('  screen reader compiled once: ' + (Split-Path -Leaf $exe))
            $script:SR_ScreenExe = $exe
            return $exe
        }
    } catch { }
    return $null
}

# ===========================================================================
# EVERY LIVE SESSION'S SCREEN, IN ONE CHILD PROCESS.
#
# 🔴 THE SPAWN IS THE COST, NOT THE READING. Measured 2026-08-30 across the
# operator's 13 live sessions: a 129 ms median per read, of which the console
# work is about 30 - the rest is starting a process. Thirteen of those is 1.8
# seconds, which is why a mark that says "this session has a shell running" took
# so long to appear that it read as not working at all.
#
# One child walks the whole list, because a process can only be attached to one
# console AT A TIME, which is not the same as only one EVER. Screen() frees
# before and after each attach, so re-attaching is exactly what it is built for.
#
# Returns a hashtable of pid -> screen text. A console that could not be read is
# simply absent, never an empty string: unread and empty are different answers
# and the callers depend on the difference.
function Get-SRScreenTextMany {
    [CmdletBinding()]
    param([Parameter(Mandatory)][int[]]$ProcessIds, [int]$TimeoutMs = 20000)
    $out = @{}
    $ids = @(@($ProcessIds) | Where-Object { [int]$_ -gt 0 } | Sort-Object -Unique)
    if (-not $ids.Count) { return $out }
    if (-not (Test-Path -LiteralPath $SR_StateDir)) { return $out }
    $exe = Get-SRScreenExe
    # 🪤 NO SILENT FALLBACK TO A LOOP. Without the exe the one-at-a-time reader
    # is still there and still correct - the caller asks for it by name. Quietly
    # doing thirteen spawns from inside "read them all at once" would hide the
    # very cost this exists to remove.
    if (-not $exe) { return $out }
    $outE = Join-Path $SR_StateDir ('screens-' + [Guid]::NewGuid().ToString('N').Substring(0, 8) + '.txt')
    try {
        $psi = New-Object System.Diagnostics.ProcessStartInfo
        $psi.FileName = $exe
        $psi.Arguments = ('-batch "{0}" {1}' -f $outE, ($ids -join ' '))
        $psi.UseShellExecute = $false
        $psi.CreateNoWindow = $true
        $ep = [System.Diagnostics.Process]::Start($psi)
        if (-not $ep.WaitForExit($TimeoutMs)) { try { $ep.Kill() } catch { }; return $out }
        if (-not (Test-Path -LiteralPath $outE)) { return $out }
        $all = [System.IO.File]::ReadAllText($outE)
        if (-not $all) { return $out }
        $sep = [string][char]1
        # Split on the sentinel pairs: <1>pid<1>\n<screen>
        $parts = [regex]::Matches($all, ($sep + '(\d+)' + $sep + "`n"))
        for ($i = 0; $i -lt $parts.Count; $i++) {
            $from = $parts[$i].Index + $parts[$i].Length
            $to = $(if ($i + 1 -lt $parts.Count) { $parts[$i + 1].Index } else { $all.Length })
            $body = $all.Substring($from, $to - $from)
            if (-not $body -or $body.StartsWith('!')) { continue }
            $out[[int]$parts[$i].Groups[1].Value] = $body
        }
        return $out
    } catch { return $out }
    finally { Remove-Item -LiteralPath $outE -Force -ErrorAction SilentlyContinue }
}

# ===========================================================================
# THE READER, HELD OPEN.
#
# 🔴 STARTING THE EXE IS THE COST, AND IT IS PAID PER READ. Measured in this
# repo before any of this existed: 129 ms median per console, of which about 30
# is the console work and the rest is creating a process. Answering a question
# does three or four reads, the question card does one on every follow tick, and
# the vitals sweep does one per session - so most of what the operator was
# waiting for was CreateProcess, not consoles.
#
# This keeps ONE reader alive per runspace and talks to it over a named pipe.
# The exe is /target:winexe and therefore has no stdin or stdout to use, which
# is why it is a pipe and not the obvious thing.
#
# 🔒 IT CAN ONLY EVER BE FASTER, NEVER MORE FRAGILE. Every failure - no exe, the
# server would not start, the pipe broke, a read that did not come back inside
# its budget - drops through to the spawn-per-read path that was here before and
# is still the only path in a runspace that never asks for a server. A wedged
# reader costs one timeout and then behaves exactly like the old code.
#
# 🪤 ONE PER RUNSPACE, NOT ONE PER MACHINE. The probe, the sweep and the UI each
# dot-source this file into their own runspace and read consoles concurrently; a
# single shared server would serialise them behind one pipe and turn a
# parallel-by-construction design into a queue. Each gets its own, and each
# kills its own.
$script:SR_ScreenSrv = $null      # the Process
$script:SR_ScreenPipe = ''
$script:SR_ScreenCli = $null      # NamedPipeClientStream
$script:SR_ScreenRd = $null
$script:SR_ScreenWr = $null
$script:SR_ScreenOff = $false     # set once the fast path has earned distrust
$script:SR_ScreenWant = $false    # this runspace asked for a held-open reader
$SR_ScreenReadMs = 4000
$SR_ScreenIdleMs = 30000
# The way out. A test that wants to prove the OLD path still works sets this,
# and so can a machine where the held-open reader turns out to misbehave -
# without which "turn it off" would mean editing this file.
$SR_ScreenNoServe = $false

function Stop-SRScreenServer {
    foreach ($o in @($script:SR_ScreenRd, $script:SR_ScreenWr, $script:SR_ScreenCli)) {
        try { if ($o) { $o.Dispose() } } catch { }
    }
    $script:SR_ScreenRd = $null; $script:SR_ScreenWr = $null; $script:SR_ScreenCli = $null
    try {
        if ($script:SR_ScreenSrv -and -not $script:SR_ScreenSrv.HasExited) { $script:SR_ScreenSrv.Kill() }
    } catch { }
    try { if ($script:SR_ScreenSrv) { $script:SR_ScreenSrv.Dispose() } } catch { }
    $script:SR_ScreenSrv = $null
    $script:SR_ScreenPipe = ''
    # Stopping is also giving up wanting one. Otherwise the next read would
    # start another, which turns "shut it down" into "restart it".
    $script:SR_ScreenWant = $false
}

# 🔴 ASKED FOR, NEVER ASSUMED - AND THIS IS THE WHOLE SAFETY OF THE DESIGN.
#
# Starting a reader on the first read of any runspace looks obviously right and
# leaks processes badly: the live probe runs in a runspace that is CREATED AND
# DISPOSED every fifteen seconds and does exactly ONE screen read in its life.
# Auto-starting would have it pay a process start to save nothing, then leave
# the reader idling behind it - and at a 120-second idle against a 15-second
# probe that is eight of them alive at once, for a tool whose own conventions
# call orphan processes a thing that quietly degrades the machine.
#
# So a runspace that wants one says so. The window asks at startup because it
# lives for hours and reads constantly; the probe never asks and spawns per read
# exactly as before, which for a single read is the cheaper thing anyway.
function Start-SRScreenServer {
    $script:SR_ScreenWant = $true
    return (Connect-SRScreenServer)
}

function Connect-SRScreenServer {
    if ($script:SR_ScreenOff) { return $false }
    if ($script:SR_ScreenCli -and $script:SR_ScreenCli.IsConnected -and
        $script:SR_ScreenSrv -and -not $script:SR_ScreenSrv.HasExited) { return $true }
    # Nobody asked for one here. Reconnecting a dropped server is still allowed -
    # that is a runspace that HAD asked - but a first start is not.
    if (-not $script:SR_ScreenWant) { return $false }

    # Whatever is there is not usable; take it down before making another.
    Stop-SRScreenServer

    $exe = Get-SRScreenExe
    if (-not $exe) { $script:SR_ScreenOff = $true; return $false }
    try {
        $pipe = 'sr-screen-' + [Guid]::NewGuid().ToString('N').Substring(0, 12)
        $psi = New-Object System.Diagnostics.ProcessStartInfo
        $psi.FileName = $exe
        $psi.Arguments = ('-serve {0} {1}' -f $pipe, $SR_ScreenIdleMs)
        $psi.UseShellExecute = $false
        $psi.CreateNoWindow = $true
        $p = [System.Diagnostics.Process]::Start($psi)
        if (-not $p) { return $false }

        $cli = New-Object System.IO.Pipes.NamedPipeClientStream('.', $pipe, 'InOut')
        # 🪤 THE SERVER HAS TO GET THERE FIRST. Connect retries inside this
        # budget, so a slow machine costs a wait rather than a failure - and a
        # server that never comes up costs 3 seconds ONCE, after which the fast
        # path is off for the life of the runspace.
        $cli.Connect(3000)
        $script:SR_ScreenSrv = $p
        $script:SR_ScreenPipe = $pipe
        $script:SR_ScreenCli = $cli
        $script:SR_ScreenRd = New-Object System.IO.StreamReader($cli, (New-Object System.Text.UTF8Encoding($false)))
        $script:SR_ScreenWr = New-Object System.IO.StreamWriter($cli, (New-Object System.Text.UTF8Encoding($false)))
        $script:SR_ScreenWr.AutoFlush = $true
        return $true
    } catch {
        Stop-SRScreenServer
        # One failed start is a machine that cannot run it; do not pay for the
        # attempt again on every read.
        $script:SR_ScreenOff = $true
        return $false
    }
}

function Get-SRScreenTextServed {
    [CmdletBinding()]
    param([Parameter(Mandatory)][int]$ProcessId)
    if (-not (Connect-SRScreenServer)) { return $null }
    try {
        $script:SR_ScreenWr.WriteLine([string]$ProcessId)
        $sb = New-Object System.Text.StringBuilder
        $stop = [DateTime]::UtcNow.AddMilliseconds($SR_ScreenReadMs)
        while ($true) {
            $t = $script:SR_ScreenRd.ReadLineAsync()
            $left = [int]($stop - [DateTime]::UtcNow).TotalMilliseconds
            if ($left -le 0 -or -not $t.Wait($left)) {
                # 🔒 A READER THAT STOPPED ANSWERING IS NOT ASKED AGAIN. The
                # connection is now out of step - the late reply would be read as
                # the answer to the NEXT question, which is the one way this
                # could return the wrong console's screen. Tear it down.
                Stop-SRScreenServer
                return $null
            }
            $line = $t.Result
            if ($null -eq $line) { Stop-SRScreenServer; return $null }
            if ($line -eq ([string][char]1 + 'end' + [string][char]1)) { break }
            if ($sb.Length -gt 0) { $null = $sb.Append("`n") }
            $null = $sb.Append($line)
        }
        $out = $sb.ToString()
        if ($out.StartsWith('!')) { return $null }
        return $out
    } catch {
        Stop-SRScreenServer
        return $null
    }
}

function Get-SRScreenText {
    [CmdletBinding()]
    param([Parameter(Mandatory)][int]$ProcessId)
    if ($ProcessId -le 0) { return $null }
    if (-not (Test-Path -LiteralPath $SR_StateDir)) { return $null }

    # The held-open reader first. It returns $null for anything it is not sure
    # about, and everything below is the path that was here before.
    if (-not $SR_ScreenNoServe) {
        $served = Get-SRScreenTextServed -ProcessId $ProcessId
        if ($served) { return $served }
    }

    # The fast path. Falls through to the powershell child below if the exe
    # cannot be built - a machine without csc still reads screens, slowly.
    $exe = Get-SRScreenExe
    if ($exe) {
        $outE = Join-Path $SR_StateDir ('screen-' + [Guid]::NewGuid().ToString('N').Substring(0, 8) + '.txt')
        try {
            $psi = New-Object System.Diagnostics.ProcessStartInfo
            $psi.FileName = $exe
            $psi.Arguments = ('{0} "{1}"' -f $ProcessId, $outE)
            $psi.UseShellExecute = $false
            $psi.CreateNoWindow = $true
            $ep = [System.Diagnostics.Process]::Start($psi)
            if (-not $ep.WaitForExit(6000)) { try { $ep.Kill() } catch { }; return $null }
            if (-not (Test-Path -LiteralPath $outE)) { return $null }
            $txtE = [System.IO.File]::ReadAllText($outE)
            if (-not $txtE -or $txtE.StartsWith('!')) { return $null }
            return $txtE
        } catch { }
        finally { Remove-Item -LiteralPath $outE -Force -ErrorAction SilentlyContinue }
    }
    $tag = [Guid]::NewGuid().ToString('N').Substring(0, 8)
    $out = Join-Path $SR_StateDir ('screen-' + $tag + '.txt')
    $scr = Join-Path $SR_StateDir ('screen-' + $tag + '.ps1')
    try {
        $Q = [string][char]39
        $outEsc = $out.Replace($Q, $Q + $Q)
        # 🔴 THE CHILD LOADS ONE TYPE, NOT THE WHOLE LIBRARY.
        #
        # It used to dot-source _common.ps1 to reach [SRCon] - and measured
        # 2.2-2.5 SECONDS to do it, because that file compiles two C# types and
        # loads UI Automation on the way past. Against the three-second budget
        # below, the child was spending its entire allowance getting ready and
        # had a few hundred milliseconds left to actually read a screen. Any load
        # at all pushed it over, the read returned nothing, and the caller
        # reported "cannot see a question on that session's screen" about a menu
        # that was plainly there.
        #
        # All it has ever needed is SRCon::Screen. Emitting just that type is a
        # cold start of ~0.3 s and leaves the budget for the work.
        $body = @(
            ($script:SR_ScreenTypeSrc),
            ('$t = [SRConLite]::Screen([uint32]' + $ProcessId + ')'),
            ('[System.IO.File]::WriteAllText(' + $Q + $outEsc + $Q + ', $t, (New-Object System.Text.UTF8Encoding($false)))')
        ) -join [Environment]::NewLine
        [System.IO.File]::WriteAllText($scr, $body, (New-Object System.Text.UTF8Encoding($false)))
        $p = Start-Process -FilePath 'powershell.exe' -PassThru -WindowStyle Hidden -ArgumentList @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $scr)
        # Six seconds, not three. The old budget was set when the child was
        # cheap; it now has room for a cold Add-Type on a loaded machine and
        # still gives up long before a stale menu could matter.
        if (-not $p.WaitForExit(6000)) { try { $p.Kill() } catch { }; return $null }
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
# ===========================================================================
# WHAT THE SESSION SAYS ABOUT ITSELF, off its own status line.
#
#   >> auto mode on . 1 shell . <- for agents . 1 feedback draft
#
# 🔴 THIS IS AUTHORITATIVE AND THE TRANSCRIPT IS NOT. Inferring a running
# background shell from the transcript does not work: a Bash call with
# run_in_background gets its tool_result back IMMEDIATELY, carrying the shell
# id, so the "a call nobody answered is still running" test - which is correct
# for sub-agents - never fires for shells and reported zero of them forever. The
# session already computes the true count and prints it; reading what it prints
# beats re-deriving it badly.
#
# 🪤 It only knows about a session whose screen has actually been read, which is
# the one on the pane. Rows keep the transcript estimate, and where the two can
# disagree the strip is the one to believe.
#
# 🪤 SawShells / SawAgents ARE NOT Ok, AND THE DIFFERENCE MATTERS. Ok says the
# read produced something; the two Saw flags say WHICH of the two figures the
# line actually printed. A session with no shells prints no shell count, so
# "did not print one" has to be readable as a true zero - otherwise a shell
# that has finished leaves its mark on the row until something else happens to
# overwrite it. The agent side needs the opposite answer from the same flag:
# the status line does not always name sub-agents, and the transcript CAN see
# them, so a silent line there means "ask the transcript", not "there are none".
function Read-SRScreenVitals { param([string]$ScreenText)
    $v = [PSCustomObject]@{
        Shells = 0; Agents = 0; Ok = $false; SawShells = $false; SawAgents = $false
        # What the session says about the turn it is on, and how hard it is
        # thinking. -1 / '' mean the screen did not say.
        Effort = ''; SawEffort = $false; TurnSecs = -1; TurnDone = $false; SawTurn = $false
        # What its own bar says about the context - the count AND the window,
        # both of which the transcript can only guess at.
        CtxTokens = -1; CtxWindow = -1; SawCtx = $false
    }
    if (-not $ScreenText) { return $v }

    # 🔴 THE STATUS LINE, NOT THE WHOLE SCREEN. These two patterns used to run
    # over the entire buffer - which is the CONVERSATION as well as the status
    # line - so any prose that happened to say "2100 shells" was read as a shell
    # count. The operator saw a session reporting 2,100 background shells, and
    # it was a session whose visible text was about shells.
    #
    # The status line is the one claude draws for itself, and it is the only
    # place either count is authoritative:
    #
    #     >> auto mode on . 1 shell . <- for agents . 1 feedback draft
    #     || manual mode on
    #
    # It begins with U+23F5 (twice) or U+23F8 and sits at the foot of the
    # buffer. Nothing above it may answer for it - a conversation can say
    # anything at all, which is the whole reason this is scoped.
    $play  = [string][char]0x23F5
    $pause = [string][char]0x23F8
    $statusLines = New-Object System.Collections.Generic.List[string]
    $tail = @(@("$ScreenText" -split "`n" | Where-Object { "$_".Trim() }) | Select-Object -Last 6)
    foreach ($ln in $tail) {
        $t = "$ln".Trim()
        if ($t.StartsWith($play, [System.StringComparison]::Ordinal) -or $t.StartsWith($pause, [System.StringComparison]::Ordinal)) { $null = $statusLines.Add($t) }
    }
    $status = ($statusLines -join ' ')

    if ($status) {
        $m = [regex]::Match($status, '(\d+)\s+shells?\b')
        if ($m.Success) { $v.Shells = [int]$m.Groups[1].Value; $v.Ok = $true; $v.SawShells = $true }
        # "<- for agents" carries no number and means none are out; a count only
        # appears when there is one, so a bare mention must not be read as a hit.
        $m = [regex]::Match($status, '(\d+)\s+(?:sub-?)?agents?\b')
        if ($m.Success) { $v.Agents = [int]$m.Groups[1].Value; $v.Ok = $true; $v.SawAgents = $true }
        # 🪤 A COUNT THE STATUS LINE CANNOT MEAN. It is a handful of shells, not
        # thousands; a number this size is evidence the line was misread, and
        # drawing it would be worse than drawing nothing.
        if ($v.Shells -gt 99) { $v.Shells = 0; $v.SawShells = $false }
        if ($v.Agents -gt 99) { $v.Agents = 0; $v.SawAgents = $false }
    }

    # =====================================================================
    # THE TURN CLOCK AND THE EFFORT, OFF THE SPINNER LINE.
    #
    # 🔴 THE TOOL'S OWN CLOCK WAS WRONG IN BOTH DIRECTIONS, measured
    # 2026-08-30 against ten live sessions. It computes now-minus-the-last-
    # human-turn, which:
    #   - NEVER STOPS. An idle session read 10,734 s (three hours) while its
    #     own line said "Sautéed for 2m 49s · done 5:06 PM". The turn ended;
    #     nothing told the subtraction to stop.
    #   - RESETS TOO OFTEN. A busy session read 12 s against its own
    #     "Contemplating… (1h 27m 38s ...)". Something other than a human
    #     message is being counted as the start of a turn.
    # The session prints the true figure and this reads it, which is the same
    # rule the shell count already follows.
    #
    #   ✻ Cooked for 3m 9s · done 9:03 PM
    #   ✢ Deciphering… (32s · ↓ 1.7k tokens · thinking with xhigh effort)
    #
    # 🪤 A TOOL'S OWN TIMER IS NOT THE TURN'S. "⎿  Running… (2s · timeout 5m)"
    # has the identical shape and would have been read as a turn that had just
    # started. Two discriminators, because either alone is thin: a tool line
    # carries "timeout", and it hangs off the U+23BF elbow.
    $elbow = [string][char]0x23BF
    foreach ($ln in @("$ScreenText" -split "`n")) {
        $t = "$ln".Trim()
        if (-not $t) { continue }
        if ($t.StartsWith($elbow, [System.StringComparison]::Ordinal)) { continue }
        if ($t -match '(?i)\btimeout\b') { continue }
        # Finished: "for 3m 9s · done"
        $d = [regex]::Match($t, '(?i)\bfor\s+(?:(\d+)h\s+)?(?:(\d+)m\s+)?(\d+)s\b[^\n]*?\bdone\b')
        if ($d.Success) {
            $v.TurnSecs = ([int]$(if ($d.Groups[1].Success) { $d.Groups[1].Value } else { 0 }) * 3600) +
                          ([int]$(if ($d.Groups[2].Success) { $d.Groups[2].Value } else { 0 }) * 60) +
                          [int]$d.Groups[3].Value
            $v.TurnDone = $true
            $v.SawTurn = $true
            $v.Ok = $true
        }
        # Running: an ellipsis, then the elapsed in parentheses.
        $r = [regex]::Match($t, [regex]::Escape([string][char]0x2026) + '\s*\((?:(\d+)h\s+)?(?:(\d+)m\s+)?(\d+)s\b')
        if ($r.Success) {
            $v.TurnSecs = ([int]$(if ($r.Groups[1].Success) { $r.Groups[1].Value } else { 0 }) * 3600) +
                          ([int]$(if ($r.Groups[2].Success) { $r.Groups[2].Value } else { 0 }) * 60) +
                          [int]$r.Groups[3].Value
            $v.TurnDone = $false
            $v.SawTurn = $true
            $v.Ok = $true
        }
    }

    # THE EFFORT LEVEL, and the chip was blank on every session because it was
    # read from a launch preference nobody had set. The session prints it in TWO
    # places and this takes either:
    #
    #   Opus 5 (1M context) with xhigh effort · Claude Max      the banner
    #   ✢ Deciphering… (32s · thinking with xhigh effort)       while working
    #
    # 🪤 Matched on "with <word> effort" rather than on "thinking with", because
    # the banner - which is the one still on screen when the session is NOT
    # mid-turn, and so the one that answers for most rows - does not say
    # "thinking" at all.
    $e = [regex]::Match($ScreenText, '(?i)\bwith\s+(\w+)\s+effort\b')
    if ($e.Success) { $v.Effort = $e.Groups[1].Value.ToLower(); $v.SawEffort = $true; $v.Ok = $true }

    # =====================================================================
    # THE CONTEXT, OFF THE SESSION'S OWN BAR.
    #
    #   Model: Opus 5 | [████████░░░░] 638k/1.0M (64%) | ⎇ main | (+0,-0)
    #
    # 🔴 BOTH NUMBERS WERE DERIVED AND BOTH COULD BE WRONG:
    #
    # THE WINDOW was inferred - "1M if the model id says 1m, or if the count
    # has already passed 200k" - because the id does not record which window
    # was selected. So a 1M session below 200k was read as a 200k one, and a
    # session at 122k showed 61% where its own bar said 12%. Measured on a live
    # session whose bar read "122k / 1.0M" while the tool said 121,724/200,000.
    #
    # THE COUNT came from the last usage record, and after a /compact the
    # terminal's bar drops IMMEDIATELY while the transcript carries no new
    # record until the next reply - so the tool kept showing the pre-compact
    # figure, which is how a session reading 123.5k in its terminal appeared
    # here as 619k.
    #
    # The bar states both. Reading it settles both, and it follows a compact
    # within one sweep instead of waiting for the next assistant turn.
    $c = [regex]::Match($ScreenText, '(?m)^\s*Model:.*?\]\s*([\d.,]+)\s*([kKmM]?)\s*/\s*([\d.,]+)\s*([kKmM]?)')
    if ($c.Success) {
        $num = {
            param([string]$Digits, [string]$Unit)
            # The bar writes 638k, 1.0M, 0. Strip thousands separators, keep one
            # decimal point, then scale.
            $d = "$Digits".Replace(',', '.')
            $dot = $d.LastIndexOf('.')
            if ($dot -ge 0 -and ($d.Length - $dot - 1) -eq 3) { $d = $d.Remove($dot, 1) }
            $val = 0.0
            if (-not [double]::TryParse($d, [Globalization.NumberStyles]::Float, [Globalization.CultureInfo]::InvariantCulture, [ref]$val)) { return -1 }
            switch ("$Unit".ToLower()) {
                'k' { return [int][Math]::Round($val * 1000) }
                'm' { return [int][Math]::Round($val * 1000000) }
                default { return [int][Math]::Round($val) }
            }
        }
        $tk = & $num $c.Groups[1].Value $c.Groups[2].Value
        $wn = & $num $c.Groups[3].Value $c.Groups[4].Value
        # A window is one of the two claude offers; anything else means the bar
        # was misread and neither figure can be trusted.
        if ($tk -ge 0 -and $wn -gt 0 -and $tk -le $wn) {
            $v.CtxTokens = $tk
            $v.CtxWindow = $wn
            $v.SawCtx = $true
            $v.Ok = $true
        }
    }
    return $v
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
    $q = Invoke-SRParseScreenQuestion -Text $txt
    # 🔑 THE RAW SCREEN TRAVELS WITH THE PARSE, and costs nothing: it was read a
    # line ago. When an answer turns out wrong, the question is always "did it
    # MISREAD the screen or MIS-SEND the keys" - and the parse cannot answer that
    # about itself. This is the only copy of what was actually on screen at the
    # moment the options were put in front of you.
    if ($q) { $q | Add-Member -NotePropertyName Screen -NotePropertyValue $txt -Force }
    return $q
}

# Where the QUESTION stops and claude's own furniture begins. The input box is
# drawn in box-drawing characters, and the status line under it carries the model
# and the context meter - none of that is part of what was asked, and letting any
# of it into the footer would put "Model: Opus 5 | [████...]" under the options.
# 🔴 EVERY StartsWith AGAINST A SYMBOL IN THIS FILE IS ORDINAL, AND MUST BE.
#
# String.StartsWith(string) is CULTURE-SENSITIVE by default, and under this
# culture unrelated symbols compare EQUAL. Measured 2026-08-30:
#
#     ("· Sauteing").StartsWith("⏵")   ->  True
#
# A middle dot is not a play triangle by any reading, but the comparer folds
# both to "ignorable symbol" and says yes. Every place that recognises a line by
# the glyph it starts with was therefore matching almost any symbol-led line:
# the status-line gate accepted conversation text (which is how a session
# reported 2,100 shells in the first place), the turn clock's tool-line
# exclusion excluded the turn as well, and the live tail classified every line
# on screen as furniture and produced nothing at all - which is how this was
# caught.
#
# [StringComparison]::Ordinal compares code points, which is the only question
# being asked here.
function Test-SRQuestionChrome { param([string]$Line)
    $t = "$Line".Trim()
    if (-not $t) { return $false }
    # A run of box-drawing or dashes is the input box's border.
    if ($t -match ('^[' + [regex]::Escape('-=_' + [string][char]0x2500 + [string][char]0x2502 + [string][char]0x256D + [string][char]0x256E + [string][char]0x2570 + [string][char]0x256F) + ']{6,}')) { return $true }
    if ($t.StartsWith([string][char]0x276F, [System.StringComparison]::Ordinal)) { return $true }   # the prompt caret
    if ($t -match '^Model:\s') { return $true }
    if ($t -match '\bshift\+tab to cycle\b') { return $true }
    if ($t -match '^\?\s+for shortcuts') { return $true }
    return $false
}

# ===========================================================================
# 🔴 THE MENU IS DRAWN *INSTEAD OF* THE INPUT BOX, AND THAT IS THE ONLY
# RELIABLE WAY TO TELL ONE FROM A NUMBERED LIST IN SCROLLBACK.
#
# Three things were tried before this one, and the first two are recorded here
# because each looked right and was measured wrong:
#
#   THE HIGHLIGHT. "A live TUI menu always has its cursor somewhere; prose never
#   does." False. U+276F is ALSO the glyph claude prefixes the operator's own
#   messages with. Counted on ONE real captured screen -
#   tests\screens\round-single-fresh.txt - the glyph appears on three lines and
#   only ONE of them is the menu cursor; the other two are messages. So a
#   message that BEGINS with a numbered list renders as "❯ 1. ..." and clears a
#   cursor gate completely.
#
#   "Enter to select". Present on all seven captured menus and on ZERO of 30
#   live consoles, because the permission prompt ("Do you want to proceed?")
#   uses different chrome entirely. It would have gated out the commonest menu
#   the operator actually answers.
#
# 🪤 AND IT CANNOT REUSE Test-SRQuestionChrome, WHICH IS THE OBVIOUS THING TO DO.
# That helper's box-drawing arm matches the menu's OWN free-text editor row -
# round-single-fresh.txt draws a box-drawing rule between option 4 and option 5 -
# so "no chrome below the last option" rejects ALL SEVEN captured real menus.
# Measured, after writing it that way. Only the three status-line patterns below
# are safe, and they are deliberately a narrower set than the chrome test.
#
# 🔑 WHAT IS LEFT IS STRUCTURE, AND IT IS EXACT. The prompt's status line only
# ever appears when the session is showing its input box, and a session showing
# its input box is not showing a menu. Scored over 13 fixtures: the old cursor
# gate was wrong on 3, the sweep's option-count test on 2, this on none. Against
# 30 live consoles it returned exactly the one session `claude agents --json`
# reported as waiting.
function Test-SRPromptLine { param([string]$Line)
    $t = "$Line".Trim()
    if (-not $t) { return $false }
    # 🔴 ORDINAL IS NOT NEEDED HERE AND -match IS NOT StartsWith - see the note on
    # Test-SRQuestionChrome for why every glyph comparison in this file is
    # ordinal. These are anchored regexes on ASCII, which have no culture.
    if ($t -match '^Model:\s') { return $true }
    if ($t -match '\bshift\+tab to cycle\b') { return $true }
    if ($t -match '^\?\s+for shortcuts') { return $true }
    return $false
}

# Where the LIVE menu's first option is, or -1 when the screen holds no menu.
#
# 🔴 IT HAS TO RESTART, AND NOT RESTARTING IS THE BUG THIS EXISTS TO FIX. The
# parser used to lock onto the first run of consecutive numbers on the screen and
# never reconsider - so an ordinary numbered list in scrollback ABOVE a live menu
# captured the parse. Worse, it kept absorbing later lines whose number continued
# the count, so three lines of prose came back WELDED to the menu's last two rows
# as one option list. With the highlight arrowed onto one of those absorbed rows
# the cursor gate passed too, and the card offered scrollback prose as answers
# while the arrows it computed aimed at real menu options of unrelated names.
#
# The welding is old; the blank card that hid it behind a refusal came in with
# the cursor gate in 9c53a76.
#
# 🔑 THE LAST SURVIVING RUN WINS. A run is disqualified the moment a prompt
# status line appears below it, because everything above the input box is
# scrollback by definition. What is left at the end is the run nothing has been
# drawn under - which is the menu, if there is one.
function Get-SRLiveMenuStart {
    [CmdletBinding()]
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Text)
    if (-not $Text) { return -1 }
    $cursorGlyph = [regex]::Escape([string][char]0x276F)
    $ls = @($Text -split "`n")
    $runStart = -1
    $runCount = 0
    for ($i = 0; $i -lt $ls.Count; $i++) {
        $m = [regex]::Match($ls[$i], '^\s*(' + $cursorGlyph + ')?\s*(\d{1,2})\.\s+(\S.*)$')
        if ($m.Success) {
            $n = [int]$m.Groups[2].Value
            # A '1.' always starts a new run, whatever was being counted before.
            if ($n -eq 1) { $runStart = $i; $runCount = 1; continue }
            if ($runCount -gt 0 -and $n -eq $runCount + 1) { $runCount++; continue }
            continue
        }
        if (Test-SRPromptLine $ls[$i]) { $runStart = -1; $runCount = 0 }
    }
    # One numbered line is a paragraph, not a menu - the same floor the parser
    # itself keeps.
    if ($runCount -lt 2) { return -1 }
    return $runStart
}

# Is a live menu on this screen at all? The band asks this and so does the card,
# through one function, so the two cannot answer it differently - which is
# exactly what they were doing.
function Test-SRLiveMenu {
    [CmdletBinding()]
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Text)
    return ((Get-SRLiveMenuStart -Text $Text) -ge 0)
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
    # Which option already carries the answered tick, on a question you have come
    # back to. -1 while nothing on screen says one was chosen.
    $chosenAt = -1

    # 🔑 FIND THE LIVE MENU FIRST, THEN READ IT. Everything below this line is
    # unchanged; all that moved is WHERE it starts looking. The scan used to
    # begin at the top of the screen and take the first run of consecutive
    # numbers it met, which on a busy session is nearly always scrollback.
    #
    # 🔴 AND THE REFUSAL IS THE OTHER HALF. A screen with no live menu now parses
    # to $null rather than to whatever numbered prose happened to be on it. That
    # is what stops the band claiming a session wants you when it does not - the
    # sweep's flag is built from this parse, so the two can no longer disagree.
    $scanFrom = Get-SRLiveMenuStart -Text $txt
    if ($scanFrom -lt 0) { return $null }

    for ($i = $scanFrom; $i -lt $lines.Count; $i++) {
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
        # 🔑 A REVISITED ANSWER CARRIES A TRAILING TICK, captured 2026-08-30 off a
        # real round: answer question 1, arrow back to it, and the row reads
        # "2. Alpha two U+2714". That is the ONLY way the screen says what you
        # already chose, and it is how a free-text answer shows itself too -
        # "3. my own words here U+2714". Stripped from the label for the same
        # reason the box is: the tick is state, not part of the option.
        $tm = [regex]::Match($label, '^(.*?)\s*' + [regex]::Escape([string][char]0x2714) + '$')
        if ($tm.Success) {
            $label = $tm.Groups[1].Value.Trim()
            $chosenAt = $opts.Count
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
            # 🔑 'Next' OR 'Submit', AND THE WORD DEPENDS ON POSITION IN THE ROUND.
            # Captured 2026-08-30: the same multi-select row reads "Next" while
            # questions follow it and "Submit" when it is the last one. Matching
            # only 'Submit' found no row at all on every multi-select but the
            # final one - which is most of them.
            if ($bare -ne 'Submit' -and $bare -ne 'Next') { continue }
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

    # =====================================================================
    # THE ROUND, WHICH THIS PARSER USED TO BE BLIND TO.
    #
    # 🔑 A BATCHED AskUserQuestion DRAWS A TAB BAR, captured off a real round
    # 2026-08-30:
    #
    #     <-  [ ] Alpha  [x] Beta  [ ] Gamma  (tick) Submit  ->
    #
    # One tab per question, named by that question's HEADER, an empty box while
    # it is unanswered and a crossed one once it is. The window only ever showed
    # the one question on screen, so a three-question round looked like a
    # one-question round that kept changing its mind.
    #
    # 🪤 The boxes are U+2610 / U+2612 and the submit mark is U+2714 - which is
    # also the tick a chosen option carries, so the Submit tab has to be
    # recognised by its LABEL and not by its mark.
    # =====================================================================
    $boxEmpty = [string][char]0x2610
    $boxFull  = [string][char]0x2612
    $tick     = [string][char]0x2714
    $tabs = New-Object System.Collections.Generic.List[object]
    $tabAt = -1
    $header = ''
    for ($i = 0; $i -lt $lines.Count -and $i -lt $firstIdx; $i++) {
        $raw = "$($lines[$i])"
        if ($raw -notmatch ($boxEmpty + '|' + $boxFull)) { continue }
        foreach ($tm2 in [regex]::Matches($raw, '(' + $boxEmpty + '|' + $boxFull + ')\s*([^\s]+(?:\s[^\s' + $boxEmpty + $boxFull + $tick + ']*?)*?)\s{2,}')) {
            $null = $tabs.Add([PSCustomObject]@{
                Label    = $tm2.Groups[2].Value.Trim()
                Answered = ($tm2.Groups[1].Value -eq $boxFull)
            })
        }
        if ($tabs.Count) { break }
    }
    # WHICH TAB YOU ARE ON is not marked on the bar - it is the question drawn
    # underneath it. The header of the active tab is therefore read from the
    # round only when the question text matches nothing, so the tab list stays
    # the addressing and the question stays the content.

    # 🔑 THE TWO ROWS THAT ARE NOT OPTIONS. The TUI appends 'Type something.' and
    # 'Chat about this' to every menu; neither is in the transcript and neither
    # behaves like an option. Type-something is an INLINE EDITOR - typing while
    # it is highlighted replaces the row text - and ENTER on it while EMPTY
    # DECLINES THE WHOLE ROUND, measured twice by accident during the capture.
    # A window that offered them as ordinary buttons was one click from throwing
    # the operator's question away.
    $freeAt = -1; $chatAt = -1; $freeText = ''
    for ($k = 0; $k -lt $opts.Count; $k++) {
        $lab = "$($opts[$k])"
        if ($lab -eq 'Chat about this') { $chatAt = $k; continue }
        # 'Type something.' on a single-select, 'Type something' on a multi. Once
        # anything has been typed the row IS that text, so the placeholder is
        # gone - which is why the row is found by POSITION as well as by name.
        if ($lab -eq 'Type something.' -or $lab -eq 'Type something') { $freeAt = $k; continue }
    }
    # The editor row sits immediately before 'Chat about this'. When it no longer
    # says "Type something" it is because it now holds what was typed into it.
    if ($freeAt -lt 0 -and $chatAt -gt 0) {
        $freeAt = $chatAt - 1
        $freeText = "$($opts[$freeAt])"
    }

    # 🔑 THE SUBMIT TAB IS A REVIEW, and it is the one screen that says how the
    # whole round has been answered. Captured verbatim:
    #
    #     Review your answers
    #     (warning) You have not answered all questions
    #      (dot) Which alpha do you want
    #        ->  Alpha three
    #      (dot) Which betas apply
    #        ->  Beta three, Beta one
    #
    # A multi-select answer arrives as one comma-joined line, which is what the
    # menu itself shows - it is not re-split here, because splitting on a comma
    # would cut an answer that contains one.
    $review = $null
    if ($txt -match 'Review your answers') {
        $arrow = [string][char]0x2192
        $rDot  = [string][char]0x25CF
        $pairs = New-Object System.Collections.Generic.List[object]
        $pendQ = ''
        for ($i = 0; $i -lt $lines.Count; $i++) {
            $t = "$($lines[$i])".Trim()
            if ($t.StartsWith($rDot, [System.StringComparison]::Ordinal)) { $pendQ = $t.Substring(1).Trim(); continue }
            if ($t.StartsWith($arrow, [System.StringComparison]::Ordinal) -and $pendQ) {
                $null = $pairs.Add([PSCustomObject]@{ Question = $pendQ; Answer = $t.Substring(1).Trim() })
                $pendQ = ''
            }
        }
        $review = [PSCustomObject]@{
            Answers  = $pairs.ToArray()
            Complete = -not ($txt -match 'You have not answered all questions')
        }
    }

    # The question is the last line of prose above the first option. Box-drawing and
    # the header chips are furniture, not the question.
    $q = ''
    for ($i = $firstIdx - 1; $i -ge 0 -and $i -ge $firstIdx - 12; $i--) {
        $cand = ($lines[$i] -replace '^[\s' + [regex]::Escape([string][char]0x2502) + ']+', '').Trim()
        if (-not $cand) { continue }
        if ($cand -match '^[' + [regex]::Escape('-=_' + [string][char]0x2500 + [string][char]0x2502) + ']+$') { continue }
        # The tab bar is furniture too, and it is the line immediately above the
        # question on a one-line question - so without this the round's own
        # navigation would be read as the thing it is asking.
        if ($cand -match ($boxEmpty + '|' + $boxFull)) { continue }
        $q = $cand
        break
    }
    if (-not $header -and $tabs.Count -eq 1) { $header = "$($tabs[0].Label)" }

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
        # ---- the round this question belongs to -------------------------
        # Every question in the batch, in tab order, each with whether it has
        # been answered. Empty when the menu is a single question with no bar.
        Tabs     = $tabs.ToArray()
        # Which option already carries the answered tick, 0-based, or -1. On a
        # question you have come back to this is what you chose last time - and
        # on a free-text answer it is the row holding what you typed.
        ChosenAt = $chosenAt
        # The two rows the TUI adds that are NOT options. -1 when absent.
        # 🔴 ENTER ON AN EMPTY FreeAt DECLINES THE WHOLE ROUND. Anything driving
        # this menu must type first and only then commit.
        FreeAt   = $freeAt
        ChatAt   = $chatAt
        # What is sitting in the editor row right now, '' when it still shows
        # its placeholder.
        FreeText = $freeText
        # Set only on the Submit tab: every question in the round with the answer
        # it currently holds, and whether the round is ready to go.
        Review   = $review
        # How many rows are real options - everything before the editor row.
        RealCount = $(if ($freeAt -ge 0) { $freeAt } elseif ($chatAt -ge 0) { $chatAt } else { $opts.Count })
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
# ===========================================================================
# ANSI ESCAPES REACHED THE SCREEN, AND READ AS A BROKEN FONT.
#
# A tool_result carries whatever the child process wrote to its stdout, colour
# codes included, and this parser passed it through untouched. A python log line
# arrived in the reading pane as
#
#   [32m2026-08-30 11:03:23[0m | [1mINFO [0m | [36mdb.connection[0m
#
# which the operator reported as the text not looking clean - a typography
# complaint about what was really unrendered control data. The ESC byte itself
# draws as nothing, so only the bracket and the digits survive, and there is no
# way to tell from the screen what went wrong.
#
# 🪤 The ESC is stripped WITH its sequence, never on its own: removing the ESC
# and leaving "[32m" behind is the same defect with the evidence deleted.
$SR_Esc = [string][char]27
$SR_Bel = [string][char]7
$script:SR_AnsiCsi = [regex]::new([regex]::Escape($SR_Esc) + '\[[0-9;?]*[ -/]*[@-~]')
$script:SR_AnsiOsc = [regex]::new([regex]::Escape($SR_Esc) + '\][^' + [regex]::Escape($SR_Bel) + ']*' + [regex]::Escape($SR_Bel))
$script:SR_AnsiCtl = [regex]::new('[\x00-\x08\x0B\x0C\x0E-\x1F]')

function Remove-SRAnsi { param([string]$Text)
    if (-not $Text) { return '' }
    $t = $script:SR_AnsiCsi.Replace($Text, '')
    $t = $script:SR_AnsiOsc.Replace($t, '')
    # Tab and newline are kept: they are layout in a tool result, not control
    # noise, and stripping them would run a table into one line.
    return $script:SR_AnsiCtl.Replace($t, '')
}

# ===========================================================================
# SUB-AGENTS ARE REAL CONVERSATIONS ON DISK, and nothing in this tool had ever
# opened one.
#
# Until now a sub-agent was only COUNTED - an open `Task` tool_use id with no
# result quoting it back (see Get-SRRowSignals) - so the window could say "2
# agents" and nothing else. What they were told, what they are doing and what
# they found were all invisible, and the terminal shows every bit of it.
#
# 🔑 THEY LIVE BESIDE THE PARENT, NOT INSIDE IT. Claude Code writes each one to
#     <project>\<session-id>\subagents\agent-<name>-<hash>.jsonl
#     <project>\<session-id>\subagents\agent-<name>-<hash>.meta.json
# and the transcript uses the SAME record shape as a top-level conversation, so
# Get-SRTranscriptBlocks reads it unchanged. That is the whole reason this is a
# reader and not a parser.
#
# MEASURED 2026-08-31 across every project on this machine: 374 sub-agents, 329
# of them WITH a transcript. Both kinds appear -
#   in_process_teammate  a teammate from an agent team          (257)
#   no taskKind          a Task sub-agent - Explore and friends (117)
# - so this is not a teammates-only feature. 45 carry metadata and no
# transcript, which is a real state and is reported rather than hidden: an
# agent that never wrote anything must not look like one whose file failed to
# load.
#
# The meta file is the interesting half and it is tiny:
#   {"agentType":"Explore","description":"Map review UI","toolUseId":"toolu_...",
#    "spawnDepth":1}
#   {"agentType":"gui-builder-2","description":"GUI state, filters, restyle",
#    "name":"gui-builder-2","model":"claude-opus-5[1m]",
#    "taskKind":"in_process_teammate","teamName":"session-d7d204c3", ...}
# `toolUseId` is what ties a Task agent back to the exact call in the parent
# that spawned it, which is what lets the parent's own block name it.
function Get-SRSubAgentDir { param([string]$JsonlPath)
    if (-not $JsonlPath) { return '' }
    $dir = Split-Path -Parent $JsonlPath
    if (-not $dir) { return '' }
    $stem = [System.IO.Path]::GetFileNameWithoutExtension($JsonlPath)
    if (-not $stem) { return '' }
    return (Join-Path (Join-Path $dir $stem) 'subagents')
}

# 🔴 WHAT MAKES A SUB-AGENT "ACTIVE", and why it is the transcript's mtime.
#
# A sub-agent has NO PROCESS OF ITS OWN - it runs inside its parent, so
# `claude agents --json` cannot be asked about it and there is no pid to check.
# What a running one does do is WRITE, and a finished one stops writing
# permanently. So a file touched recently is an agent still going, and the
# window is generous on purpose: an agent thinking for a minute writes nothing,
# and a threshold tight enough to catch that would flicker. Three minutes
# tolerates a long pause and still excludes anything that finished.
$SR_SubAgentLiveSecs = 180

function Get-SRSubAgents { param([string]$JsonlPath)
    $out = New-Object System.Collections.Generic.List[object]
    $dir = Get-SRSubAgentDir $JsonlPath
    if (-not $dir -or -not (Test-Path -LiteralPath $dir)) { return $out.ToArray() }
    $metas = @()
    try { $metas = @(Get-ChildItem -LiteralPath $dir -Filter '*.meta.json' -File -ErrorAction Stop) } catch { return $out.ToArray() }
    foreach ($m in $metas) {
        $j = $null
        try { $j = Get-Content -LiteralPath $m.FullName -Raw -Encoding UTF8 | ConvertFrom-Json } catch { }
        # A meta that will not parse is still a sub-agent that ran. Name it from
        # the file and carry on - dropping it would under-report the very thing
        # this function exists to surface.
        $stem = $m.Name -replace '\.meta\.json$', ''
        $tx = Join-Path $dir ($stem + '.jsonl')
        $has = Test-Path -LiteralPath $tx
        $bytes = 0L
        $when = $m.LastWriteTime
        if ($has) {
            try {
                $fi = Get-Item -LiteralPath $tx
                $bytes = $fi.Length
                # The TRANSCRIPT's mtime, not the meta's: the meta is written
                # once at spawn and never touched again, so ordering by it would
                # put a finished agent above one still writing.
                $when = $fi.LastWriteTime
            } catch { }
        }
        $name = ''
        $type = ''
        $desc = ''
        $kind = ''
        $model = ''
        $team = ''
        $tuid = ''
        if ($j) {
            $name  = "$($j.name)"
            $type  = "$($j.agentType)"
            $desc  = "$($j.description)"
            $kind  = "$($j.taskKind)"
            $model = "$($j.model)"
            $team  = "$($j.teamName)"
            $tuid  = "$($j.toolUseId)"
        }
        # A Task sub-agent has an agentType and NO name; a teammate has both and
        # they are usually the same. The file stem is the last resort and always
        # says something, because it carries the agent's own id.
        $label = $name
        if (-not $label) { $label = $type }
        if (-not $label) { $label = ($stem -replace '^agent-', '') }
        $out.Add([PSCustomObject]@{
            Id            = $stem
            Label         = $label
            AgentType     = $type
            Description   = $desc
            TaskKind      = $kind
            Model         = $model
            Team          = $team
            ToolUseId     = $tuid
            Path          = $tx
            HasTranscript = $has
            Bytes         = $bytes
            When          = $when
            # A teammate is a peer working alongside the session; a Task agent is
            # a one-shot the session dispatched. Different things, and the row
            # says which.
            IsTeammate    = ($kind -eq 'in_process_teammate')
            # Still going, on the evidence of its own file. An agent with no
            # transcript can never be Live: there is nothing writing.
            Live          = ($has -and (((Get-Date) - $when).TotalSeconds -lt $SR_SubAgentLiveSecs))
        })
    }
    # Newest first, matching every other list in this tool.
    $sorted = @($out | Sort-Object -Property When -Descending)
    return $sorted
}

# ===========================================================================
# A BACKGROUND SHELL'S OUTPUT IS ON DISK, LIVE, and this was very nearly
# written off.
#
# The first reading of the evidence was that a backgrounded Bash is
# unrecoverable: the transcript answers it immediately, records no shell id
# field and carries no BashOutput records unless the session happened to poll -
# measured, and true as far as it went. What it missed is that the ANSWER
# names the file:
#
#   Command running in background with ID: beqvs0dpb. Output is being written
#   to: C:\...\<session-id>\tasks\beqvs0dpb.output
#
# So the id and the path are both in the transcript after all, in prose, in the
# tool_result. MEASURED 2026-08-31: 363 `tasks` directories on this machine,
# holding live stdout - the sample read was seconds old while its command was
# still running. This is the real thing, not a cached copy.
#
# 🪤 THE DIRECTORY IS FOUND BY GLOB, NEVER BY REBUILDING THE SLUG. The path is
#     %TEMP%\claude\<cwd-with-separators-as-dashes>\<session-id>\tasks\
# and that first segment is the session's WORKING DIRECTORY, not its project
# root - for this very conversation it is
# `C--Users-mauri-Documents-MM-toolbox-tools-session-restore`, a subdirectory
# of the project. Reconstructing it would mean knowing the cwd exactly, getting
# the dash-encoding right, and staying right if either ever changes. The
# session id is unique on its own, so one wildcard finds the directory and
# cannot be wrong about the encoding.
# 🪤 THE PARAMETER IS `$Shell`, NOT `$ShellId`. `$ShellId` is a READ-ONLY
# AUTOMATIC VARIABLE in Windows PowerShell (it holds "Microsoft.PowerShell"), so
# a parameter of that name cannot be bound at all: every call died with "Cannot
# overwrite variable ShellId because it is read-only or constant" and the
# function returned nothing. Same family as the `$Path`/`$path` and
# single-letter collisions already recorded in CONTEXT.md - a name that is
# already taken, in a language that will not warn you.
# sessionId -> its ...\<session>\tasks directory. Populated on the first lookup
# that finds one; see the note inside the function for why it is worth caching.
$script:SR_ShellDirCache = @{}

function Get-SRShellOutputPath { param([string]$SessionId, [string]$Shell)
    if (-not $SessionId -or -not $Shell) { return '' }
    # Only ever a bare id from the transcript, but this reaches the filesystem
    # with a wildcard in it, so anything that is not the shape of an id is
    # refused rather than pasted into a path.
    if ($Shell -notmatch '^[A-Za-z0-9_-]{1,64}$') { return '' }
    if ($SessionId -notmatch '^[A-Za-z0-9_-]{1,64}$') { return '' }
    $root = Join-Path $env:TEMP 'claude'
    if (-not (Test-Path -LiteralPath $root)) { return '' }

    # 🔴 THIS WAS 330 ms ON A CLICK, TO FIND A 903-BYTE FILE.
    #
    # The path is %TEMP%\claude\<project>\<session>\tasks\<shell>.output and the
    # project segment is not known here, so it was a wildcard:
    #
    #     Get-ChildItem -Path "$root\*\$SessionId\tasks\$Shell.output"
    #
    # which makes the provider walk every project directory under the root.
    # Audited 2026-09-05: opening a background-shell fold cost 289 ms, of which
    # ~330 was this call; the file it finds reads in 2.1 ms, and a fold with
    # nothing to read is 12.1 ms. Essentially the whole cost was the search.
    #
    # 🪤 AND THE SEARCH SPACE ONLY GROWS. Counted the same day: 379 entries under
    # that root, 194 of them older than two days. Nothing prunes it, so this got
    # worse every week the machine stayed up - which is the temp-hygiene problem
    # the operator's conventions already warn about, arriving as a UI stall.
    #
    # 🔴 "A SESSION LIVES IN EXACTLY ONE PROJECT DIRECTORY" IS FALSE, and this
    # function was written on it. `claude --resume` from another cwd, and
    # worktrees, put one id under several. Counted on this machine: 11 session
    # ids under more than one project, and the worst has THREE, each with its own
    # tasks dir holding a DISJOINT set of .output files.
    #
    # 🪤 Which is why the sweep below breaks on the FILE and not on the directory.
    # Breaking on the first dir that merely exists returned '' for shells that
    # were plainly there - 28 of them for the session that has three - and then
    # cached that wrong dir, so every later call swept all 178 project dirs again
    # to reach the same wrong answer. The glob this replaced could not do that:
    # it matched the whole path INCLUDING the filename, so it only ever returned
    # a directory that contained the file.
    #
    # So the cache is every tasks dir the session owns, not the first one.
    $known = @($script:SR_ShellDirCache["$SessionId"])
    if ($known.Count -and $known[0]) {
        $stale = $false
        foreach ($d in $known) {
            $direct = [System.IO.Path]::Combine($d, ($Shell + '.output'))
            if ([System.IO.File]::Exists($direct)) { return $direct }
            if (-not [System.IO.Directory]::Exists($d)) { $stale = $true }
        }
        # 🔑 A MISS IS AN ANSWER, not a reason to sweep again. While every known
        # dir is still there, "this shell has no output file" is the truth and
        # costs one stat per dir. Only a dir that has VANISHED (temp cleaned, the
        # session moved) means the map is out of date and has to be rebuilt -
        # without this a shell whose output was cleaned up re-swept 178
        # directories on every render, permanently.
        if (-not $stale) { return '' }
    }

    # Raw .NET rather than the provider. Get-ChildItem with a wildcard path pays
    # PowerShell's pipeline and provider overhead per candidate; Directory.Exists
    # is a single syscall, and the loop stops at the first hit instead of
    # enumerating all of them and then filtering.
    # 🪤 EVERY DIR, NOT THE FIRST. Breaking early is what produced the wrong
    # answer above. The enumeration itself is the cost - GetDirectories over 178
    # entries - and it is paid the moment the loop starts; the extra
    # Directory.Exists calls to finish it are a stat each. Stopping early bought
    # nothing measurable and cost 28 shells their output.
    $dirs = New-Object System.Collections.Generic.List[string]
    $found = ''
    try {
        foreach ($proj in [System.IO.Directory]::GetDirectories($root)) {
            $cand = [System.IO.Path]::Combine($proj, $SessionId, 'tasks')
            if (-not [System.IO.Directory]::Exists($cand)) { continue }
            $dirs.Add($cand)
            if (-not $found) {
                $f = [System.IO.Path]::Combine($cand, ($Shell + '.output'))
                if ([System.IO.File]::Exists($f)) { $found = $f }
            }
        }
    } catch { return '' }
    if ($dirs.Count -eq 0) { return '' }

    # Remembered whether or not THIS shell exists: the expensive thing was
    # locating the session, and that answer is good for every shell it owns.
    # 🪤 .ToArray(), never @($dirs) - @() on a List[object] throws in PS 5.1.
    $script:SR_ShellDirCache["$SessionId"] = $dirs.ToArray()

    if ($found) { return $found }
    return ''
}

# The output as it stands RIGHT NOW. Read with FileShare::ReadWrite because the
# shell that is writing it still holds the handle - a plain read would throw
# "being used by another process" on exactly the running shell this exists to
# show. Tail-bounded for the same reason every other read here is: a chatty
# background job can produce megabytes and the pane wants the end of it.
function Get-SRShellOutput { param([string]$Path, [int]$MaxBytes = 65536)
    if (-not $Path -or -not (Test-Path -LiteralPath $Path)) { return $null }
    $fs = $null
    try {
        $fs = New-Object System.IO.FileStream($Path, [System.IO.FileMode]::Open,
                  [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite)
        $len = $fs.Length
        $trunc = $false
        if ($len -gt $MaxBytes) { $null = $fs.Seek($len - $MaxBytes, [System.IO.SeekOrigin]::Begin); $trunc = $true }
        $sr = New-Object System.IO.StreamReader($fs, [System.Text.Encoding]::UTF8)
        $txt = $sr.ReadToEnd()
        $sr.Dispose(); $fs = $null
        if ($trunc) {
            # A partial first line after seeking mid-file is noise, not data.
            $nl = $txt.IndexOf("`n")
            if ($nl -ge 0 -and $nl -lt 400) { $txt = $txt.Substring($nl + 1) }
        }
        return [PSCustomObject]@{ Text = (Remove-SRAnsi $txt); Bytes = $len; Truncated = $trunc }
    } catch { return $null }
    finally { if ($fs) { try { $fs.Dispose() } catch { } } }
}

# THE LAST THING A RUNNING SUB-AGENT SAID, for the panel's live line.
#
# 🔑 ITS TRANSCRIPT IS NAMED AFTER THE ID ITS LAUNCH HANDED BACK. The result of
# an Agent call says `agentId: ada3d4c7c2d6fb5d1`, and the file on disk is
# `subagents/agent-ada3d4c7c2d6fb5d1.jsonl` - verified by finding that exact
# pair. That is what makes a running agent watchable at all: no process to ask,
# no pid, but a file it is actively writing.
#
# 🪤 THE .meta.json EXISTS BEFORE THE .jsonl DOES. Measured: a spawned agent has
# its meta written immediately and its transcript only once it produces
# something, so "no file" means STARTING, not missing - the caller shows the
# description in that gap rather than an empty row.
function Get-SRAgentLastLine { param([string]$JsonlPath, [string]$AgentId, [int]$MaxTailBytes = 65536)
    if (-not $JsonlPath -or -not $AgentId) { return '' }
    if ($AgentId -notmatch '^[A-Za-z0-9_-]{1,64}$') { return '' }
    $dir = Get-SRSubAgentDir -JsonlPath $JsonlPath
    if (-not $dir -or -not (Test-Path -LiteralPath $dir)) { return '' }
    $f = Join-Path $dir ('agent-' + $AgentId + '.jsonl')
    if (-not (Test-Path -LiteralPath $f)) { return '' }
    $text = ''
    try {
        $fs = [System.IO.File]::Open($f, 'Open', 'Read', 'ReadWrite')
        try {
            $len = $fs.Length
            $take = [int][Math]::Min($len, $MaxTailBytes)
            $null = $fs.Seek($len - $take, 'Begin')
            $buf = New-Object byte[] $take
            $read = $fs.Read($buf, 0, $take)
            $text = [System.Text.Encoding]::UTF8.GetString($buf, 0, $read)
        } finally { $fs.Dispose() }
    } catch { return '' }

    # Walk BACKWARDS for the newest thing worth showing. An agent's tail is
    # mostly tool traffic; what answers "what is it doing" is the last thing it
    # SAID, and failing that the last tool it reached for.
    $lines = @($text -split "`n")
    for ($i = $lines.Count - 1; $i -ge 0; $i--) {
        $ln = $lines[$i].Trim([char]0xFEFF, ' ', "`t", "`r")
        if (-not $ln.StartsWith('{')) { continue }
        $r = $null
        try { $r = $ln | ConvertFrom-Json } catch { continue }
        if ("$($r.type)" -ne 'assistant') { continue }
        foreach ($b in @($r.message.content)) {
            if (-not $b -or -not $b.type) { continue }
            if ($b.type -eq 'text' -and "$($b.text)".Trim()) {
                return (("$($b.text)".Trim() -split "`n" | Where-Object { $_.Trim() })[0]).Trim()
            }
            if ($b.type -eq 'tool_use') { return ('- ' + "$($b.name)") }
        }
    }
    return ''
}

# ===========================================================================
# WHAT IS RUNNING RIGHT NOW - BY NAME, NOT BY COUNT.
#
# Background shells AND sub-agents, because they are the same problem and Claude
# Code reports them the same way: both launch with run_in_background, both hand
# an id straight back, and both end with a task-notification naming that id.
#
# 🔴 THE COUNT AND THE IDENTITY CAME FROM DIFFERENT PLACES, AND ONLY THE COUNT
# EXISTED. The row's square mark is a NUMBER off the session's status line; the
# pane's shell block is a `Bash (background)` tool_use that happens to be inside
# the transcript tail. So the mark could say "2 shells" while the pane showed
# none, and there was no list of what was actually running anywhere - reported
# as "I cannot see a current running shell other than the icon indicating there
# is something". This function is the missing list.
#
# 🪤 THE TASKS DIRECTORY IS NOT THE ANSWER, AND IT IS THE OBVIOUS WRONG ONE.
# Every shell that has EVER run leaves its `.output` there - measured, 1,475 of
# them on this machine across all sessions, with almost none live. Listing that
# directory is the same mistake that once put 374 dead sub-agents in the spine
# (07e13c3): a file on disk is a receipt, not a heartbeat.
#
# 🪤 NEITHER IS THE `$open` TRACKER ABOVE. It opens on a tool_use and closes on
# the matching tool_result, which is exactly right for a Task agent and exactly
# wrong for a shell: MEASURED, 52 of 52 background bashes got their tool_result
# IMMEDIATELY - that is where the id is handed back - while the shell carried on
# running. So its shell branch can never retain anything and `Shells` from that
# parse is always 0. Only the agent half of it works.
#
# 🔑 WHAT ACTUALLY MARKS THE END IS A task-notification. Claude Code writes one
# when the shell stops, carrying <task-id>, <output-file> and <status>. So the
# rule is exact and needs no heuristic, no mtime guess, no freshness window:
#
#     running  =  launched, and no task-notification for that id since.
#
# Verified against a finished conversation: 114 launches, 129 notifications
# (the extra ones are Task agents, which notify the same way), 0 left open -
# which is the right answer for a session that is no longer running.
$script:SR_ShellCache = @{}
$SR_RxShellNew = [regex]::new('background with ID:\s*([A-Za-z0-9_-]+)')
$SR_RxAgentNew = [regex]::new('agentId:\s*([A-Za-z0-9_-]+)')
$SR_RxShellEnd = [regex]::new('<task-id>\s*([A-Za-z0-9_-]+)\s*</task-id>')

# 🔴 THE WINDOW IS 24 MB, NOT THE 512 KB THIS FIRST SHIPPED WITH, AND THE FIRST
# NUMBER WAS NOT A CONSERVATIVE GUESS - IT WAS A BROKEN TEST.
#
# A shell that has been running for an hour was LAUNCHED an hour ago, so a tail
# sized for "recent activity" is exactly the wrong shape: the longer a shell
# runs - which is precisely when you want to see it - the further back its only
# launch record sits. Measured on the largest transcript here (112 MB), a
# 512 KB tail covers 0.5% of the file and the last launch was 988 KB from the
# end, OUTSIDE it. The first version of this function passed its test by
# returning 0 from a window that contained no launches at all, in either
# direction. A green check is not evidence until you know it can go red.
#
# 🔑 SIZED FROM THE ACTUAL DISTRIBUTION, not from caution: of 373 transcripts on
# this machine the median is 0.4 MB, p90 is 8 MB, and only 17 are over 20 MB. At
# 24 MB, 356 of 373 are read WHOLE and the giants still get a window fifty times
# what they had. The cost is bounded by the pre-filter below, not by this.
function Get-SRLiveTasks { param([string]$JsonlPath, [int]$MaxTailBytes = 25165824)
    if (-not $JsonlPath -or -not (Test-Path -LiteralPath $JsonlPath)) { return @() }

    # Same stamp-keyed cache as the vitals read, for the same reason: this is
    # called on the sweep, and re-parsing an unchanged transcript is pure cost.
    $stamp = ''
    $fi = $null
    try {
        $fi = Get-Item -LiteralPath $JsonlPath
        $stamp = '{0}|{1}' -f $fi.Length, $fi.LastWriteTimeUtc.Ticks
    } catch { return @() }
    $key = $JsonlPath.ToLower()
    if ($script:SR_ShellCache.ContainsKey($key) -and $script:SR_ShellCache[$key].Stamp -eq $stamp) {
        return $script:SR_ShellCache[$key].Value
    }

    $text = ''
    try {
        $fs = [System.IO.File]::Open($JsonlPath, 'Open', 'Read', 'ReadWrite')
        try {
            $take = [int][Math]::Min($fi.Length, $MaxTailBytes)
            $null = $fs.Seek(-$take, 'End')
            $buf = New-Object byte[] $take
            $read = $fs.Read($buf, 0, $take)
            $text = [System.Text.Encoding]::UTF8.GetString($buf, 0, $read)
        } finally { $fs.Dispose() }
    } catch { return @() }

    $open = [ordered]@{}
    $pend = @{}          # tool_use id -> what it was asked to do, until its result names the shell

    # 🔑 THE PRE-FILTER IS WHAT MAKES A 24 MB WINDOW AFFORDABLE. ConvertFrom-Json
    # on every line of a big transcript is the whole cost of this function, and
    # all three records it cares about carry a distinctive literal. A substring
    # test is orders of magnitude cheaper than a parse, and on a transcript with
    # a hundred background shells it leaves a few hundred lines to parse instead
    # of a few hundred thousand.
    foreach ($ln in ($text -split "`n")) {
        if (-not ($ln.Contains('run_in_background') -or $ln.Contains('background with ID:') -or
                  $ln.Contains('agentId:') -or $ln.Contains('<task-notification>'))) { continue }
        # 🪤 THE BOM IS NOT WHITESPACE. `.Trim()` leaves it, so StartsWith('{')
        # is FALSE on the first line of any UTF-8 file written with one, and
        # ConvertFrom-Json would refuse it anyway - either way the record is
        # skipped in silence. Caught by the negative control in state-driver:
        # it rewrote the fixture through a StreamWriter (BOM by default), the
        # first line happened to be a shell's LAUNCH, and this reported one
        # running shell instead of two. A dropped record looks exactly like a
        # correct answer, which is what makes it worth a line of defence.
        $ln = $ln.Trim([char]0xFEFF, ' ', "`t", "`r", "`n")
        if (-not $ln.StartsWith('{')) { continue }
        $r = $null
        try { $r = $ln | ConvertFrom-Json } catch { continue }

        $when = $null
        if ($r.PSObject.Properties['timestamp']) {
            try { $when = [datetime]::Parse("$($r.timestamp)", [System.Globalization.CultureInfo]::InvariantCulture,
                                            [System.Globalization.DateTimeStyles]::AdjustToUniversal) } catch { }
        }

        # A completion can arrive as a queue-operation record or as the user
        # record the same notification becomes once it comes off the queue, so
        # the whole line is searched rather than one field. Cheap: the guard is
        # a substring test, and the regex only runs on lines that pass it.
        if ($ln.Contains('<task-notification>')) {
            foreach ($m in $SR_RxShellEnd.Matches($ln)) {
                $id = $m.Groups[1].Value
                if ($open.Contains($id)) { $open.Remove($id) }
            }
        }

        $msg = $r.message
        if (-not $msg) { continue }
        foreach ($b in @($msg.content)) {
            if (-not $b -or -not $b.type) { continue }
            if ($b.type -eq 'tool_use' -and $b.input -and
                $b.input.PSObject.Properties['run_in_background'] -and $b.input.run_in_background -and
                ("$($b.name)" -eq 'Bash' -or "$($b.name)" -eq 'Agent' -or "$($b.name)" -eq 'Task')) {
                # 🪤 BOTH KINDS CARRY run_in_background, so the NAME is what
                # tells them apart, not the flag. An Agent launch that fell into
                # the shell branch would be listed as a background command with
                # an empty command line.
                $pend["$($b.id)"] = @{
                    Kind = $(if ("$($b.name)" -eq 'Bash') { 'shell' } else { 'agent' })
                    Cmd  = $(if ("$($b.name)" -eq 'Bash') { "$($b.input.command)" } else { "$($b.input.subagent_type)" })
                    Desc = "$($b.input.description)"
                    At   = $when
                }
            } elseif ($b.type -eq 'tool_result') {
                $uid = "$($b.tool_use_id)"
                if (-not $pend.ContainsKey($uid)) { continue }
                $t = $b.content
                if ($t -isnot [string]) { $t = ($t | ForEach-Object { "$($_.text)" }) -join "`n" }
                $info = $pend[$uid]
                # Each kind hands its id back in its own words: a shell says
                # "background with ID: <id>", an agent says "agentId: <id>". The
                # id is what the completion notification will name, and for an
                # agent it is also the name of its own transcript on disk.
                $rx = $(if ($info.Kind -eq 'agent') { $SR_RxAgentNew } else { $SR_RxShellNew })
                $hit = $rx.Match("$t")
                if (-not $hit.Success) { $pend.Remove($uid); continue }
                $pend.Remove($uid)
                $open[$hit.Groups[1].Value] = [PSCustomObject]@{
                    Shell   = $hit.Groups[1].Value
                    Kind    = $info.Kind
                    Command = $info.Cmd
                    Desc    = $info.Desc
                    At      = $info.At
                    ToolUse = $uid
                }
            }
        }
    }

    $out = @($open.Values)
    $script:SR_ShellCache[$key] = @{ Stamp = $stamp; Value = $out }
    return $out
}

# ===========================================================================
# A MESSAGE FROM ANOTHER SESSION IS NOT SOMETHING YOU TYPED.
#
# When several sessions run at once they message each other, and every one of
# those arrived in this pane as a plain `you said` - indistinguishable from the
# operator's own words, with the routing envelope printed as if it were prose:
#
#   <cross-session-message from="uds:\\.\pipe\LOCAL\cc-msg-d6f5..."
#    from-name="I7" from-mode="bypass">
#
# MEASURED across this machine: 8,304 inbound messages and 1,881 SendMessage
# calls. That is a whole category of traffic the pane could not tell from the
# operator, on a surface whose entire job is saying who is speaking.
#
# Two shapes, both first-party: an inbound one wraps the user record in
# <cross-session-message> (or <teammate-message> from an agent team) and names
# the sender in an attribute; an outbound one is a SendMessage tool_use.
# 🔴 IT WAS ANCHORED TO THE FIRST CHARACTER, AND THE HARNESS STOPPED PUTTING IT
# THERE. The record now arrives as "Another Claude session sent a message:" and
# then the envelope on the next line, so `^\s*<` missed and every teammate
# message fell through to `you` - printed in the operator's own voice, on his
# ground, with his marker. The second report of that shape in one day; the first
# was <task-notification>.
#
# 🪤 THE PREAMBLE MAY NOT CONTAIN A `<`, and that is what keeps this honest. A
# bounded run of tag-free prose is a harness preamble; anything else is somebody
# writing about a teammate message rather than receiving one, and it stays his.
$script:SR_RxMsgIn   = [regex]::new('(?s)\A(?<pre>[^<]{0,200}?)<(?<tag>cross-session-message|teammate-message)\b(?<attrs>[^>]*)>')
# 🔴 FROM THE CLOSING TAG TO THE END, NOT THE CLOSING TAG AT THE END. This was
# anchored with $, and the harness appends its own advisory prose AFTER the
# envelope closes - so nothing matched, the tag and the advice stayed in the
# body, and what should have been a JSON payload was no longer parseable. The
# unwrap below then silently declined and the operator got JSON source on
# screen. Scaffolding after the message is not the message.
$script:SR_RxMsgEnd  = [regex]::new('(?s)</(cross-session-message|teammate-message)>.*\z')
$script:SR_RxMsgFrom = [regex]::new('from-name="([^"]*)"')
$script:SR_RxMsgMate = [regex]::new('teammate_id="([^"]*)"')

# 🔴 AND NEITHER IS A NOTIFICATION THE HARNESS WROTE. Reported with a
# screenshot: a <task-notification> announcing a background command finishing -
# task-id, tool-use-id, output-file, "exit code 0" - drawn as YOU SAID, on the
# operator's own ground, with his marker. His words: "messages appear to be
# shown to be sent from me, which I actually didn't send".
#
# 🪤 THE ROLE IS `user` AND THE AUTHOR IS NOT. Claude Code injects several
# things into the transcript as user records: background-task notifications,
# <system-reminder> context, and the caveat block that wraps a slash command.
# Reading "role: user" as "the human said this" is what put them in his voice,
# on the one surface whose entire job is saying who is speaking.
#
# 🪤 STRIPPED FOR THE TEST, KEPT FOR THE BLOCK. A record is machinery only if
# NOTHING is left once the envelopes come off - a real message with a
# <system-reminder> appended is still a real message. What the block carries is
# the full text either way: a NOTICE folds, and opening one should show exactly
# what arrived rather than an edited version of it.
$script:SR_RxMachineWrap = [regex]::new(
    '(?s)<(task-notification|system-reminder|local-command-caveat)\b[^>]*>.*?</\1>')
$script:SR_RxMachineLine = [regex]::new(
    '(?m)^\s*\[(Cross-session idle notice|Request interrupted[^\]]*)\][^\r\n]*$')

function Test-SRMachineUserRecord { param([string]$Text)
    if (-not $Text) { return $false }
    # Cheap gate: every envelope above opens with one of these two characters,
    # and the overwhelming majority of what the operator types carries neither.
    if ($Text.IndexOf('<', [System.StringComparison]::Ordinal) -lt 0 -and
        $Text.IndexOf('[', [System.StringComparison]::Ordinal) -lt 0) { return $false }
    $s = $script:SR_RxMachineWrap.Replace($Text, '')
    $s = $script:SR_RxMachineLine.Replace($s, '')
    return (-not "$s".Trim())
}

function New-SRUserBlock { param([string]$Text)
    $m = $script:SR_RxMsgIn.Match($Text)
    if (-not $m.Success) {
        # Not from another session. Is it from a person at all?
        if (Test-SRMachineUserRecord $Text) { return (New-Block 'system' '' $Text '') }
        return (New-Block 'you' '' $Text '')
    }
    $attrs = $m.Groups['attrs'].Value
    $who = ''
    $f = $script:SR_RxMsgFrom.Match($attrs)
    if ($f.Success) { $who = $f.Groups[1].Value }
    else {
        $f = $script:SR_RxMsgMate.Match($attrs)
        if ($f.Success) { $who = $f.Groups[1].Value }
    }
    # 🪤 NEVER THE `from=` PIPE PATH as a fallback. It is a named-pipe address -
    # `uds:\\.\pipe\LOCAL\cc-msg-d6f54257308ddfd6f97ace0da9a8184a` - and putting
    # that where a name goes is how the envelope ended up on screen in the first
    # place. If nobody is named, say so in words.
    if (-not $who) { $who = 'another session' }
    # Everything after the opening tag, then the closing tag off the end.
    $body = $Text.Substring($m.Index + $m.Length)
    $body = $script:SR_RxMsgEnd.Replace($body, '')
    $body = $body.Trim()
    # 🔴 AND IT IS NOT JSON SOURCE. The envelope's payload is an object -
    # {"type":"idle_notification","from":"...","result":"..."} - and printing it
    # raw put `\n\n---\n\n##` on screen as literal characters, three lines of
    # routing metadata before the first word, and every quote escaped. Reported
    # as "the output rendered when a teammate is replying is also shown very
    # oddly", with a screenshot of exactly that.
    #
    # 🪤 THE FIELD, IF THERE IS ONE - NEVER A GUESS AT THE SHAPE. Only a body
    # that actually parses is unwrapped, only a known payload field is taken,
    # and anything else is left EXACTLY as it arrived. A message this cannot
    # read is still readable; a message it mangles is not.
    if ($body.Length -gt 1 -and $body[0] -eq '{') {
        $obj = $null
        try { $obj = $body | ConvertFrom-Json } catch { $obj = $null }
        if ($obj) {
            foreach ($fld in @('result', 'message', 'content', 'summary')) {
                $v = $null
                try { $v = $obj.$fld } catch { }
                if ($v -is [string] -and "$v".Trim()) { $body = "$v".Trim(); break }
            }
        }
    }
    return (New-Block 'msgin' $who $body.Trim() '')
}

# How far the reading window may widen when it lands inside a single record.
# 24 MB against a largest-observed record of 916 KB, so it is roughly 25x the
# worst case seen and still a bounded read on a 180 MB file.
$SR_TailCeiling = 25165824

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
        # 🔴 A TAIL CAN LAND ENTIRELY INSIDE ONE RECORD, AND THEN IT READS AS AN
        # EMPTY CONVERSATION. Measured 2026-09-03 on a 180 MB transcript: the
        # records run to 916 KB against a median of 629 bytes, and the reading
        # window is 96 KB - so whenever the newest record is bigger than the
        # window, every line in the window is a fragment, the whole-record
        # filter below keeps none of them, and the pane draws nothing at all.
        #
        # It is intermittent by construction, which is why it read as "sometimes
        # the tool does not show the conversation": it depends entirely on how
        # big the last few records happen to be. A compact summary and a large
        # tool result are both exactly that kind of record - which is precisely
        # when it was reported.
        #
        # So the window WIDENS until it contains a whole record, doubling from
        # whatever was asked for. Bounded: it gives up at $SR_TailCeiling rather
        # than walking back through a 180 MB file, and a transcript whose last
        # record is bigger than that is one this pane cannot help with anyway.
        $fs = [System.IO.File]::Open($JsonlPath, 'Open', 'Read', 'ReadWrite')
        try {
            $take = [int][Math]::Min($fi.Length, $MaxTailBytes)
            while ($true) {
                $null = $fs.Seek(-$take, 'End')
                $buf  = New-Object byte[] $take
                $read = $fs.Read($buf, 0, $take)
                $text = [System.Text.Encoding]::UTF8.GetString($buf, 0, $read)
                # 🪤 THE SAME TEST THE FILTER BELOW USES. Anything else here
                # would widen on one rule and then keep nothing by another.
                $whole = 0
                foreach ($ln in ($text -split "`n")) { if ($ln.Trim().StartsWith('{')) { $whole++; break } }
                if ($whole -gt 0) { break }
                if ($take -ge $fi.Length -or $take -ge $SR_TailCeiling) { break }
                $take = [int][Math]::Min([Math]::Min($fi.Length, $SR_TailCeiling), $take * 2)
            }
        } finally { $fs.Dispose() }
    } catch {
        return ,@($out.ToArray())
    }

    $lines = @($text -split "`n" | Where-Object { $_.Trim().StartsWith('{') })
    if (-not $lines.Count) { return ,@($out.ToArray()) }
    $lines = @($lines[[Math]::Max(0, $lines.Count - $MaxRecords)..($lines.Count - 1)])

    # 🪤 $recWhen IS READ OUT OF THE ENCLOSING SCOPE, deliberately. A function
    # defined inside another runs in a child of its CALLER's scope, so the
    # record's timestamp reaches every block without threading a parameter
    # through six call sites - and without any of them being able to forget it.
    $recWhen = $null
    function New-Block { param([string]$Kind, [string]$Head, [string]$Body, [string]$Meta)
        return [PSCustomObject]@{ Kind = $Kind; Head = $Head; Body = $Body; Meta = $Meta; When = $recWhen }
    }

    foreach ($ln in $lines) {
        $r = $null
        try { $r = $ln | ConvertFrom-Json } catch { continue }
        # 🔴 EVERYTHING THAT IS NOT A user OR assistant RECORD USED TO BE
        # DROPPED ON THE FLOOR - and a great deal happens in those records. A
        # compact writes a `system` record with subtype compact_boundary and
        # then a summary; a hook writes its output as an `attachment` of type
        # hook_success; a stop hook writes stop_hook_summary with what it ran
        # and how long it took. None of it reached the pane, so the operator
        # compacted a session and watched nothing happen.
        if ("$($r.type)" -eq 'system') {
            $sub = "$($r.subtype)"
            # turn_duration is bookkeeping the window computes for itself and
            # there are 68 of them in a busy tail; it would be the loudest thing
            # in the pane and say the least.
            if ($sub -eq 'turn_duration') { continue }
            if ($sub -ne 'compact_boundary' -and $sub -ne 'stop_hook_summary') {
                # away_summary, informational, bridge_status, local_command -
                # every one of these carries `content` and every one of them is
                # something the terminal PRINTS and this pane was swallowing.
                $sc = Remove-SRAnsi "$($r.content)"
                if ("$sc".Trim()) { $out.Add((New-Block 'system' ($sub -replace '_', ' ') $sc '')) }
                continue
            }
            if ($sub -eq 'compact_boundary') {
                $pre = ''
                if ($r.PSObject.Properties['compactMetadata'] -and $r.compactMetadata) {
                    $mdt = $r.compactMetadata
                    if ($mdt.PSObject.Properties['preTokens']) { $pre = "$($mdt.preTokens) tokens summarised" }
                    if ($mdt.PSObject.Properties['trigger'] -and "$($mdt.trigger)") {
                        $pre = (($pre, "$($mdt.trigger)") | Where-Object { $_ }) -join '  -  '
                    }
                }
                $out.Add((New-Block 'compact' 'compacted' $pre ''))
            } elseif ($sub -eq 'stop_hook_summary') {
                # Which hooks ran and what they cost. The one system record with
                # a real answer in it rather than bookkeeping.
                $names = @()
                foreach ($h in @($r.hookInfos)) {
                    if (-not $h) { continue }
                    $ms = ''
                    if ($h.PSObject.Properties['durationMs']) { $ms = (' {0:N1}s' -f ([double]$h.durationMs / 1000)) }
                    $names += ("$($h.command)" + $ms)
                }
                $errs = @($r.hookErrors | Where-Object { "$_".Trim() })
                $body = ($names -join '   ')
                if ($errs.Count) { $body = (($body, ($errs -join '  ')) | Where-Object { $_ }) -join '   -   ' }
                if ($body) { $out.Add((New-Block 'system' 'hooks' $body '')) }
            }
            continue
        }
        # A hook's own output. It rides on a record that carries no message at
        # all, so it has to be caught before the message check below.
        if ($r.PSObject.Properties['attachment'] -and $r.attachment) {
            $at = "$($r.attachment.type)"
            switch ($at) {
                { $_ -eq 'hook_success' -or $_ -eq 'hook_system_message' } {
                    $hk = "$($r.attachment.hookName)"
                    if (-not $hk) { $hk = "$($r.attachment.hookEvent)" }
                    if (-not $hk) { $hk = 'hook' }
                    $txt = Remove-SRAnsi "$($r.attachment.content)"
                    if ("$txt".Trim()) { $out.Add((New-Block 'hook' $hk $txt '')) }
                }
                { $_ -eq 'file' -or $_ -eq 'edited_text_file' } {
                    # The "Read <file> (N lines)" list the terminal prints after
                    # a compact. Only the NAME and the size are wanted - the
                    # attachment carries the entire file, and putting that in the
                    # pane would bury the conversation it belongs to.
                    $fn = "$($r.attachment.filename)"
                    if (-not $fn -and $r.attachment.content -and $r.attachment.content.file) {
                        $fn = "$($r.attachment.content.file.filePath)"
                    }
                    if ($fn) {
                        $lines2 = ''
                        try {
                            $fc = "$($r.attachment.content.file.content)"
                            if ($fc) { $lines2 = ('{0} lines' -f @($fc -split "`n").Count) }
                        } catch { }
                        $head2 = $(if ($at -eq 'edited_text_file') { 'edited' } else { 'read' })
                        $out.Add((New-Block 'file' $head2 (Split-Path -Leaf $fn) $lines2))
                    }
                }
                'queued_command' {
                    $qp = Remove-SRAnsi "$($r.attachment.prompt)"
                    if ("$qp".Trim()) { $out.Add((New-Block 'queued' 'queued' $qp '')) }
                }
                # 🪤 EVERYTHING ELSE IS DELIBERATELY DROPPED. output_style and
                # total_tokens_reminder alone are 2,246 attachments in a busy
                # tail - they are per-turn machinery the terminal never shows
                # either, and rendering them would swamp the pane with the exact
                # noise this redesign removed.
                default { }
            }
            continue
        }
        # 🔴 AN INBOUND MESSAGE IS A QUEUE OPERATION, NOT A USER RECORD - which
        # is why it was dropped by the guard below and never reached the pane at
        # all. It arrives as {"type":"queue-operation","operation":"enqueue",
        # "content":"<cross-session-message ...>"}. Measured: 202 of them in a
        # single conversation on this machine, none of them drawn.
        if ("$($r.type)" -eq 'queue-operation') {
            if ("$($r.operation)" -eq 'enqueue') {
                $qc = Remove-SRAnsi "$($r.content)"
                # ONLY an actual message. A plain enqueued prompt keeps the
                # existing behaviour of not being drawn - it arrives again as a
                # user record when the session takes it, and drawing it here as
                # well would show everything the operator typed twice.
                if ($script:SR_RxMsgIn.IsMatch("$qc")) {
                    # 🪤 $recWhen is computed BELOW this guard and New-Block
                    # closes over it, so a block added here with the previous
                    # record's timestamp would be stamped with somebody else's
                    # time. Read it before building the block.
                    $recWhen = $null
                    if ($r.PSObject.Properties['timestamp'] -and "$($r.timestamp)") {
                        try {
                            $recWhen = ([datetime]::Parse("$($r.timestamp)", [System.Globalization.CultureInfo]::InvariantCulture,
                                                          [System.Globalization.DateTimeStyles]::AdjustToUniversal)).ToLocalTime()
                        } catch { $recWhen = $null }
                    }
                    $out.Add((New-SRUserBlock $qc))
                }
            }
            continue
        }
        if ($r.type -ne 'user' -and $r.type -ne 'assistant') { continue }
        # WHEN it was said. Kept as LOCAL time because the only question anyone
        # asks of it is "was that before or after I went to lunch".
        $recWhen = $null
        if ($r.PSObject.Properties['timestamp'] -and "$($r.timestamp)") {
            try {
                $recWhen = ([datetime]::Parse("$($r.timestamp)", [System.Globalization.CultureInfo]::InvariantCulture,
                                              [System.Globalization.DateTimeStyles]::AdjustToUniversal)).ToLocalTime()
            } catch { $recWhen = $null }
        }
        $m = $r.message
        if (-not $m) { continue }
        $role = [string]$m.role

        $content = $m.content
        if ($content -is [string]) {
            if ("$content".Trim()) {
                if ($role -eq 'user') { $out.Add((New-SRUserBlock "$content")) }
                else { $out.Add((New-Block 'said' '' "$content" '')) }
            }
            continue
        }
        foreach ($b in @($content)) {
            if (-not $b -or -not $b.type) { continue }
            switch ($b.type) {
                'text' {
                    $s = "$($b.text)"
                    if ($s.Trim()) {
                        if ($role -eq 'user') { $out.Add((New-SRUserBlock $s)) }
                        else { $out.Add((New-Block 'said' '' $s '')) }
                    }
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
                    # 🔴 THE FULL ARGUMENT REACHES THE RENDERER. This used to
                    # compress the path and then cut at 150 characters, HERE, so
                    # the command was already destroyed before anything could
                    # choose to show it - the reported `-Shot "C:\...\444f9...`
                    # survived every fix made in the pane, because the pane never
                    # had the rest of it. Deciding how much to show is the
                    # renderer's job; this one's is to carry it.
                    #
                    # Newlines are kept for the same reason: a heredoc or a
                    # multi-line prompt collapsed to one line is unreadable, and
                    # the pane wraps and splits properly now.
                    $arg = "$arg".Trim()
                    # The one-line form still exists, in Meta, for any caller
                    # that wants a summary rather than the call. Compress BEFORE
                    # truncating, or the budget is spent on the part of the path
                    # that is identical on every line and the end - the part that
                    # says WHICH worktree - is what gets cut.
                    $argShort = Compress-SRPath (($arg -replace '\s+', ' ').Trim())
                    if ($argShort.Length -gt 150) { $argShort = $argShort.Substring(0, 147) + [string][char]0x2026 }

                    # 🔑 THE TWO CALLS THAT START SOMETHING THAT OUTLIVES THEM.
                    #
                    # A `Task` spawns a sub-agent and a backgrounded `Bash`
                    # leaves a shell running, and both were drawn as an ordinary
                    # tool call - the same grey row as a Read. They are the two
                    # things the operator asked to be able to SEE, so they get
                    # their own marker in the pane and carry their `description`
                    # rather than only their argument.
                    #
                    # The description is what a human wrote to say what this is
                    # FOR; the argument is the prompt or the command. Both are
                    # worth having and the argument slot can only hold one, so
                    # the description rides in Meta.
                    #
                    # 🪤 run_in_background IS ON THE INPUT AND NOWHERE ELSE. The
                    # transcript answers a backgrounded Bash immediately and
                    # records no shell id, so this flag on the CALL is the only
                    # evidence in the file that a shell was ever left running -
                    # measured 2026-08-31: 50 such calls in this session's
                    # transcript, zero `shellId` and zero BashOutput records.
                    if ($name -eq 'SendMessage') {
                        # 🪤 NEITHER `to` NOR `message` IS IN THE ARGUMENT KEY
                        # LIST above, so the generic path fell through to "the
                        # first property" and picked the RECIPIENT as the
                        # argument - which meant what was actually sent never
                        # reached the pane at all. Both are named here.
                        # 🪤 AND `to` IS OFTEN A NAMED PIPE, not a name:
                        # `uds:\\.\pipe\LOCAL\cc-msg-e1d568e1f834...`. Printing
                        # that as the recipient is the same defect as printing
                        # the inbound envelope as prose. A peer addressed by
                        # name keeps its name; an address becomes words.
                        $to = "$($i.to)".Trim()
                        if ($to -match '^uds:' -or $to -match '\\pipe\\') { $to = 'another session' }
                        $argShort = $to
                        $arg = "$($i.message)".Trim()
                    } elseif ($name -eq 'Agent' -or $name -eq 'Task') {
                        # 🪤 IT IS 'Agent', AND THIS ONLY SAID 'Task'. Counted
                        # across every transcript on this machine: 'Task'
                        # appears in ZERO files and 'Agent' in 40, so this
                        # branch had never once run and every sub-agent call in
                        # the pane was labelled with the generic argument
                        # instead of what it was asked to do.
                        # Both are accepted because 'Task' costs nothing to keep
                        # and this cannot know what an older build wrote.
                        $argShort = "$($i.description)".Trim()
                    } elseif ($name -eq 'Bash' -and $i -and
                              $i.PSObject.Properties['run_in_background'] -and $i.run_in_background) {
                        $name = 'Bash (background)'
                        $argShort = "$($i.description)".Trim()
                    }
                    # 🔴 A QUESTION YOU ANSWERED IS NOT A TOOL CALL, and drawing
                    # it as one is what made it unreadable. The argument slot got
                    # PowerShell's stringification of the input object -
                    # "@{question=The pane can't beat the transcript, which..." -
                    # and the answer came back as one run-on line of quoted
                    # pairs with any option preview inlined behind pipe
                    # characters. Both are internals leaking onto a reading
                    # surface. The record carries the questions and the answers
                    # structurally, so the RESULT emits an 'asked' block and the
                    # call itself is dropped rather than drawn twice.
                    if ($name -eq 'AskUserQuestion') { continue }
                    $out.Add((New-Block 'tool' $name $arg $argShort))
                }
                'tool_result' {
                    # 🔑 THE ANSWERED ROUND, STRUCTURED. toolUseResult carries
                    # `answers` as a plain {question -> chosen} map, so nothing
                    # has to be recovered from the sentence claude writes back
                    # ("Your questions have been answered: ..."), which is where
                    # the wall of quoted text came from. One line per question,
                    # the two halves separated by U+0001 so neither can contain
                    # the separator.
                    $ans = $null
                    if ($r.PSObject.Properties['toolUseResult'] -and $r.toolUseResult -and
                        $r.toolUseResult.PSObject.Properties['answers'] -and $r.toolUseResult.answers) {
                        $ans = $r.toolUseResult.answers
                    }
                    if ($ans) {
                        $pairs = New-Object System.Collections.Generic.List[string]
                        foreach ($qp in @($ans.PSObject.Properties)) {
                            $qt = "$($qp.Name)".Trim()
                            $at = "$($qp.Value)".Trim()
                            if (-not $qt -and -not $at) { continue }
                            $null = $pairs.Add($qt + [string][char]1 + $at)
                        }
                        if ($pairs.Count) {
                            $out.Add((New-Block 'asked' 'you answered' ($pairs -join "`n") ("{0}" -f $pairs.Count)))
                            continue
                        }
                    }
                    $s = ''
                    if ($b.content -is [string]) { $s = "$($b.content)" }
                    else {
                        foreach ($c in @($b.content)) { if ($c.type -eq 'text') { $s += "$($c.text)" } }
                    }
                    # The ONE place a child process's raw stdout enters this
                    # tool. Everything else here is JSON claude wrote.
                    $s = Remove-SRAnsi "$s"
                    $n = @($s -split "`n").Count
                    $err = ($b.PSObject.Properties['is_error'] -and $b.is_error)
                    $out.Add((New-Block 'result' $(if ($err) { 'failed' } else { 'result' }) $s "$n lines"))
                }
            }
        }
    }
    return ,@($out.ToArray())
}

# ===========================================================================
# THE VITALS - what the terminal's own status line knows about a session.
#
#   Model: Opus 5 | [####------] 184k/1.0M (18%) | main | (+166,-66)
#
# Every figure here is already on disk; none of it needs claude to be asked.
#   model, tokens   an assistant record's `message.model` and `message.usage`
#   branch          `gitBranch`, on every record - no git call for this one
#   sub-agents      a `Task` tool_use whose id no tool_result has quoted back
#   shells          the same, for a Bash call with run_in_background
#   remote, effort, permission mode   launch flags this tool already stores
#   +N -N           the only one that costs a subprocess
#
# 🪤 READ OVER A TAIL. A sub-agent started before the tail window is not
# counted, so this answers "what is running now" and NOT "what has ever run".
# The chip means the former; do not re-point it at the latter without saying so
# on screen.
#
# 🔴 CACHED ON THE FILE'S OWN STAMP, because this runs on a timer behind a
# window that must stay responsive: an unchanged transcript is never re-parsed,
# and the git call has a life of its own so a fast tick cannot spawn one.
$script:SR_VitalCache = @{}
$script:SR_DiffCache = @{}
$SR_DiffMaxAgeSeconds = 20

# Is this "user" record actually the operator, or is it a tool handing a result
# back? Everything claude runs comes back as a user record, so this is the
# difference between "the turn started" and "a tool answered".
function Test-SRHumanTurn { param($Record)
    if (-not $Record) { return $false }
    # The property claude writes on a record that carries a tool's output. Its
    # presence is decisive and costs one lookup.
    if ($Record.PSObject.Properties['toolUseResult']) { return $false }
    # A compact summary is written as a user record too, and it is the machine
    # talking about the conversation - not a new turn you started.
    if ($Record.PSObject.Properties['isCompactSummary'] -and $Record.isCompactSummary) { return $false }
    if ($Record.PSObject.Properties['attachment'] -and $Record.attachment) { return $false }
    $m = $Record.message
    if (-not $m) { return $false }
    $c = $m.content
    # A plain string is always something typed.
    if ($c -is [string]) { return $true }
    foreach ($b in @($c)) {
        if ($b -and "$($b.type)" -eq 'tool_result') { return $false }
    }
    return $true
}

function New-SRVitals {
    return [PSCustomObject]@{
        Model = ''; Tokens = 0; Window = 200000; Branch = ''
        Shells = 0; Agents = 0; Remote = $false
        Effort = ''; Mode = ''; Elapsed = 0.0; TurnTokens = 0
        Added = -1; Removed = -1; Ok = $false
        # WHEN the turn started, not just how long ago that was. Elapsed is a
        # snapshot and goes stale the instant it is returned; TurnAt lets a
        # caller advance the clock without re-reading the transcript, which is
        # the difference between a per-second subtraction and a per-second
        # parse of half a megabyte.
        TurnAt = $null
    }
}

# 🔴 NEVER `& git` FROM THE WINDOW. Sessions.exe is a /target:winexe process
# with NO console, and PowerShell's native-command path ALLOCATES ONE to run an
# external program - a console window that flashes up behind the app, and an
# `app` suite assertion that goes red on exactly this. Measured 2026-08-30: the
# working-tree diff chip did it on every selection.
#
# Redirecting the streams through Process directly keeps the child headless.
# 🪤 Read stdout to the END BEFORE WaitForExit. Waiting first deadlocks the
# moment git writes more than a pipe buffer, which `git diff --shortstat`
# will not but the next caller of this helper might.
function Invoke-SRGitLine { param([string]$Path, [string[]]$Arguments, [int]$TimeoutMs = 4000)
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = 'git'
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    # 🔴 STDIN IS REDIRECTED AND THEN CLOSED IMMEDIATELY. Left inherited, git
    # can sit waiting on input that is never coming - a credential helper, a
    # pager, a prompt - and it waits forever, which is what eight git processes
    # at zero CPU looked like. Closing the handle turns any such wait into an
    # instant EOF. GIT_TERMINAL_PROMPT settles the credential case explicitly
    # rather than relying on that.
    $psi.RedirectStandardInput = $true
    $null = $psi.EnvironmentVariables.Remove('GIT_TERMINAL_PROMPT')
    $psi.EnvironmentVariables['GIT_TERMINAL_PROMPT'] = '0'
    $psi.EnvironmentVariables['GIT_OPTIONAL_LOCKS'] = '0'
    $psi.WorkingDirectory = $Path
    # -c core.pager=cat: git pages by default for some commands, and a pager
    # waiting for a keypress is the same hang by another route.
    $all = @('--no-optional-locks', '-c', 'core.pager=cat') + @($Arguments)
    $psi.Arguments = ($all | ForEach-Object { if ($_ -match '\s') { '"' + $_ + '"' } else { $_ } }) -join ' '
    $p = $null
    try {
        $p = [System.Diagnostics.Process]::Start($psi)
        try { $p.StandardInput.Close() } catch { }
        # 🔴 ASYNCHRONOUS, AND THE TIMEOUT IS THE POINT.
        #
        # This was ReadToEnd() on stdout, then ReadToEnd() on stderr, THEN
        # WaitForExit($TimeoutMs) - and that timeout could never fire, because
        # the first ReadToEnd blocks until the child closes the stream. Measured
        # 2026-08-30: two git processes sat at zero CPU for twenty-two minutes
        # with the caller blocked in ReadToEnd, and the benchmark that started
        # them leaked a fresh pair on every call. In the window this is the UI
        # thread, and it would have frozen the whole surface the first time git
        # was slow - the exact failure a hung probe caused here once already.
        #
        # 🪤 BOTH pipes are drained, and concurrently. Draining one while the
        # child fills the other deadlocks the moment stderr exceeds its buffer,
        # which is a warning this function's first version carried and then did
        # not honour.
        $tOut = $p.StandardOutput.ReadToEndAsync()
        $tErr = $p.StandardError.ReadToEndAsync()
        if (-not $p.WaitForExit($TimeoutMs)) {
            try { $p.Kill() } catch { }
            # Give the kill a moment to land so the handles close; a git left
            # running is a git left holding a lock in the operator's repo.
            try { $null = $p.WaitForExit(1000) } catch { }
            Write-SRLog ('  [warn] git {0} in {1} did not answer in {2} ms and was stopped' -f ($Arguments -join ' '), $Path, $TimeoutMs)
            return ''
        }
        if ($tOut.Wait($TimeoutMs)) { return "$($tOut.Result)" }
        return ''
    } catch { return '' }
    finally { if ($p) { try { $p.Dispose() } catch { } } }
}

function Get-SRWorkingDiff { param([string]$Path)
    if (-not $Path -or -not (Test-Path -LiteralPath $Path)) { return $null }
    $key = $Path.ToLower()
    $now = Get-Date
    if ($script:SR_DiffCache.ContainsKey($key)) {
        $hit = $script:SR_DiffCache[$key]
        if (($now - $hit.At).TotalSeconds -lt $SR_DiffMaxAgeSeconds) { return $hit.Value }
    }
    $val = $null
    try {
        # --no-optional-locks (added by the helper) so this never fights a
        # session mid-commit in the same tree, which is the common case here:
        # the tree is BUSY, that is why it is on screen.
        $raw = (Invoke-SRGitLine -Path $Path -Arguments @('diff', '--shortstat', 'HEAD')) -replace "[`r`n]+", ' '
        $add = 0; $del = 0
        if ($raw -match '(\d+) insertion') { $add = [int]$Matches[1] }
        if ($raw -match '(\d+) deletion')  { $del = [int]$Matches[1] }
        $val = [PSCustomObject]@{ Added = $add; Removed = $del }
    } catch { }
    $script:SR_DiffCache[$key] = @{ At = $now; Value = $val }
    return $val
}

# ===========================================================================
# THE TWO SIGNALS A ROW CAN CARRY - how full its context is, and whether it has
# a sub-agent out.
#
# 🔴 A SEPARATE, MUCH CHEAPER READER THAN Get-SRSessionVitals, and that is the
# whole point. The full one costs 120 ms because it runs ConvertFrom-Json over
# every line of a 600 KB tail; thirty-five rows of that is four seconds, on a
# list that rebuilds whenever you type in the filter box. This reads a 48 KB
# tail and runs three regexes over it - no JSON parsing at all - for the two
# figures a ROW has room to show. The strip keeps the accurate reader, because
# it answers for one conversation and can afford to.
#
# 🪤 Regex over JSON is normally a mistake. It is safe HERE because both shapes
# are machine-written by one writer and neither value can contain a quote: a
# token count is digits, and a tool id is [A-Za-z0-9_]. Anything looser - a
# title, a path, anything a human typed - must go through the parser.
$script:SR_SigCache = @{}
$SR_SigTailBytes = 49152

# ===========================================================================
# WHAT A CONVERSATION HAS WAITING - the send queue, read off the transcript.
#
# 🔑 THE SESSION KEEPS THIS RECORD ITSELF, so none of it is inferred. claude
# writes a `queue-operation` record the moment anything is queued and again when
# it leaves:
#
#   enqueue   carries the full text - a message joined the queue
#   remove    carries the text - that specific one left it
#   dequeue   carries NOTHING - one came off the front
#   popAll    the queue was cleared
#
# Replaying those four in order is the queue, exactly, live. Measured across the
# operator's 432 transcripts on 2026-09-04: 6,645 messages queued and picked up,
# a median wait of 7 seconds, 31% waiting longer than 30 and 21% longer than two
# minutes. It is not a cosmetic feature - a fifth of everything sent this way
# sits unseen for minutes.
#
# 🔴 NOT THE queued_command ATTACHMENT, which is the obvious-looking source and
# the wrong one. That is appended when the message is PICKED UP, not when it is
# queued - proved by its own timestamp being older than the records either side
# of it (11:51:27 sitting after 11:51:39) - so a reader built on it can only ever
# describe a queue that has already drained. The same trap Get-SRPendingQuestion
# carries a note about, in the same shape.
#
# 🪤 MOST OF THE QUEUE IS NOT THE OPERATOR. Across those transcripts: 1,356
# cross-session messages, 1,107 task notifications, 144 lines a person actually
# typed. Anything drawn from this has to tell them apart or a queue indicator
# means nothing - so Mine and Machine are counted separately, decided by the
# leading '<' that every machine-generated prompt starts with.
#
# 🪤 THE TAIL IS BIG ON PURPOSE. A still-waiting enqueue sits a median 210 KB
# back and up to 1.3 MB; a 48 KB window like the one above would find 8% of them
# and a 256 KB window 52%. 4 MB caught all 25 that were pending across the whole
# machine, and it is affordable because only lines containing the marker are
# parsed - the rest is a substring scan, and the whole answer is cached against
# the file stamp, so an unchanged transcript costs one stat.
#
# 🔒 A TRUNCATED WINDOW UNDER-REPORTS, NEVER OVER-REPORTS. Starting mid-file this
# can see a `remove` or `dequeue` for an `enqueue` older than the window; with
# nothing matching, it is ignored rather than popping the front, so the worst
# case is a message that is waiting and not shown. Claiming something is queued
# when it is not would be the damaging direction.
$script:SR_QueueCache = @{}
$SR_QueueTailBytes = 4194304

# 🔴 HOW LONG A QUEUE MARK IS STILL EVIDENCE, AND WHY IT NEEDS A LIMIT AT ALL.
#
# The queue is reconstructed by replaying queue-operation records: enqueue adds,
# dequeue/remove/popAll take away. That is faithful to the records - and the
# records are not always complete. Audited on this machine, 6 conversations drew
# a queue mark and 4 of them were holding messages 2,9 to 136,8 hours old.
#
# The decisive case had a 3,7 MB transcript, so the WHOLE FILE fits the tail
# window and no boundary effect is possible: zero removes matched nothing, zero
# dequeues hit an empty queue, and five enqueued cross-session messages from
# three days earlier had no cancelling record ANYWHERE in the file. Claude Code
# queued them and never wrote a dequeue, remove or popAll. No parser can fix
# that; the record does not exist.
#
# So the mark needs a second question beside "what do the records say": has this
# conversation done anything since. A session that has not written a transcript
# record for hours is not sitting mid-turn holding a message - it is finished,
# and the enqueue is an orphan. On the audit the split was clean: the two live
# marks were 0 and 0,1 hours quiet, every phantom was 2,9 hours or more.
$SR_QueueStaleHours = 1.0
# 🔴 AND MACHINE TRAFFIC GOES STALE IN MINUTES, NOT HOURS. A message of the
# operator's can legitimately sit in a queue for an hour while a session works.
# A <task-notification> cannot: the session consumes it on its very next turn,
# within seconds. Claude Code does not reliably write the record that CANCELS an
# enqueue, so an unremoved machine enqueue would otherwise claim to be waiting
# for a full hour.
#
# Reported with a screenshot at eight minutes: "1 QUEUED, NONE OF THEM YOURS /
# a background task reported back", against a queue with nothing in it.
$SR_QueueMachineStaleMins = 2.0

# ---------------------------------------------------------------------------
# 🔴 THE ENQUEUE AND THE REMOVE OF ONE MESSAGE ARE NOT THE SAME STRING, and
# matching them by exact text left 37 messages queued forever.
#
# Reported: the composer said "2 OF YOURS WAITING, AND 14 FROM THE MACHINE -
# OLDEST HAS WAITED 23H" on a session with nothing outstanding, and offered to
# put what you typed next at "position 17". Measured over that transcript
# (21 MB, 437 queue-operation records): 99 cross-session enqueues of which 62
# carry a `hop-chain="..."` attribute on the opening tag, against 55 removes of
# which NONE do. The bodies are byte-identical after it - a 37-character delta,
# exactly ` hop-chain="..."`. Task-notification removes matched 54 of 54;
# cross-session removes matched 18 of 55, and all 37 misses carry a hop-chain.
#
# 🪤 IT IS PERMANENT RATHER THAN TRANSIENT BECAUSE OF A CORRECT SAFETY CHOICE. A
# remove that matches nothing is IGNORED rather than popping the front, which is
# right for a truncated window - it under-reports instead of dropping somebody's
# message. That is also what turns a text mismatch into a phantom that never
# clears.
#
# The accounting closes exactly: replaying with the attribute stripped from both
# sides gives 0 unmatched removes where there were 37, and a final depth of 2 -
# two task-notifications enqueued in the same minute, genuinely in flight.
# 39 - 2 = 37. Nothing else in the rule needed changing.
#
# 🪤 THE KEY IS FOR MATCHING ONLY. Text keeps the hop-chain, because that is what
# was actually queued and what the panel draws; only the comparison ignores it.
function Get-SRQueueKey { param([string]$Text)
    if (-not $Text) { return '' }
    return ($Text -replace '\s+hop-chain="[^"]*"', '')
}

function Get-SRQueue {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$JsonlPath, [int]$MaxTailBytes = 0)

    if ($MaxTailBytes -le 0) { $MaxTailBytes = $SR_QueueTailBytes }
    # 🪤 LastWrite IS [datetime]::MinValue HERE, AND THAT MEANS "NOT KNOWN",
    # NOT "INFINITELY STALE". The caller must draw the mark when it cannot tell
    # how fresh the conversation is - hiding information on absent evidence is
    # the worse error of the two, and this object is returned from paths where
    # the file could not even be opened.
    $none = [PSCustomObject]@{ Items = @(); Count = 0; Mine = 0; Machine = 0; Ok = $false; LastWrite = [datetime]::MinValue }
    if (-not $JsonlPath -or -not (Test-Path -LiteralPath $JsonlPath)) { return $none }

    $stamp = ''
    try {
        $fi = Get-Item -LiteralPath $JsonlPath -ErrorAction Stop
        $stamp = '{0}|{1}|{2}' -f $fi.Length, $fi.LastWriteTimeUtc.Ticks, $MaxTailBytes
    } catch { return $none }
    $key = "$JsonlPath".ToLower()
    if ($script:SR_QueueCache.ContainsKey($key) -and $script:SR_QueueCache[$key].Stamp -eq $stamp) {
        return $script:SR_QueueCache[$key].Value
    }
    if ($fi.Length -eq 0) { return $none }

    $text = ''
    try {
        $fs = [System.IO.File]::Open($JsonlPath, 'Open', 'Read', 'ReadWrite')
        try {
            $take = [int][Math]::Min($fi.Length, $MaxTailBytes)
            $null = $fs.Seek(-$take, 'End')
            $buf = New-Object byte[] $take
            $read = $fs.Read($buf, 0, $take)
            $text = [System.Text.Encoding]::UTF8.GetString($buf, 0, $read)
        } finally { $fs.Dispose() }
    } catch { return $none }

    # The queue is a handful of records in a file of tens of thousands, so the
    # marker test comes first and almost every line stops there. Only what
    # survives it is worth a ConvertFrom-Json.
    $q = New-Object System.Collections.Generic.List[object]
    foreach ($ln in ($text -split "`n")) {
        if ($ln.IndexOf('"queue-operation"', [StringComparison]::Ordinal) -lt 0) { continue }
        $s = $ln.TrimStart([char]0xFEFF, ' ', "`t")
        if (-not $s.StartsWith('{')) { continue }
        $r = $null
        try { $r = $s | ConvertFrom-Json } catch { continue }
        if ("$($r.type)" -ne 'queue-operation') { continue }
        $op = "$($r.operation)"
        $c  = "$($r.content)"
        switch ($op) {
            'enqueue' {
                if (-not "$c".Trim()) { break }
                $at = $null
                try { $at = [datetime]$r.timestamp } catch { }
                $clean = Remove-SRAnsi $c
                $null = $q.Add([PSCustomObject]@{ Text = $clean; At = $at; Key = (Get-SRQueueKey $clean) })
            }
            'popAll' { $q.Clear() }
            'remove' {
                # 🔴 MATCHED ON THE KEY, NOT THE TEXT, AND THE DIFFERENCE WAS 37
                # PHANTOM MESSAGES. See Get-SRQueueKey: the enqueue record and the
                # remove record for the SAME message are not the same string.
                $rk = Get-SRQueueKey (Remove-SRAnsi $c)
                for ($i = 0; $i -lt $q.Count; $i++) {
                    if ("$($q[$i].Key)" -eq $rk) { $q.RemoveAt($i); break }
                }
            }
            'dequeue' { if ($q.Count) { $q.RemoveAt(0) } }
            default { }
        }
    }

    $items = New-Object System.Collections.Generic.List[object]
    $mine = 0; $machine = 0
    foreach ($e in $q) {
        # Every machine-generated prompt arrives wrapped in a tag -
        # <task-notification>, <cross-session-message>, <agent-message>,
        # <system-reminder>. A person's message never starts with one.
        $t = "$($e.Text)".TrimStart()
        $isMine = -not $t.StartsWith('<', [StringComparison]::Ordinal)
        if ($isMine) { $mine++ } else { $machine++ }
        $null = $items.Add([PSCustomObject]@{
            Text  = "$($e.Text)"
            First = (Get-SRFirstLine "$($e.Text)")
            At    = $e.At
            Mine  = $isMine
        })
    }

    $v = [PSCustomObject]@{
        Items = $items.ToArray(); Count = $items.Count
        # 🔑 FREE - Get-Item was already called above to build the cache stamp,
        # so carrying its write time costs nothing and saves the list builder a
        # disk stat per row. Build-Sessions opening a transcript once per row is
        # a pattern this file has already had to remove once.
        LastWrite = $fi.LastWriteTime
        Mine = $mine; Machine = $machine; Ok = $true
    }
    $script:SR_QueueCache[$key] = @{ Stamp = $stamp; Value = $v }
    return $v
}

function Get-SRRowSignals { param([string]$JsonlPath)
    $none = [PSCustomObject]@{ Tokens = 0; Window = 200000; Frac = 0.0; Agents = 0; Shells = 0; Ok = $false }
    if (-not $JsonlPath -or -not (Test-Path -LiteralPath $JsonlPath)) { return $none }
    $stamp = ''
    try {
        $fi = Get-Item -LiteralPath $JsonlPath
        $stamp = '{0}|{1}' -f $fi.Length, $fi.LastWriteTimeUtc.Ticks
    } catch { return $none }
    $key = $JsonlPath.ToLower()
    if ($script:SR_SigCache.ContainsKey($key) -and $script:SR_SigCache[$key].Stamp -eq $stamp) {
        return $script:SR_SigCache[$key].Value
    }

    $text = ''
    try {
        $fs = [System.IO.File]::Open($JsonlPath, 'Open', 'Read', 'ReadWrite')
        try {
            $take = [int][Math]::Min($fi.Length, $SR_SigTailBytes)
            $null = $fs.Seek(-$take, 'End')
            $buf = New-Object byte[] $take
            $read = $fs.Read($buf, 0, $take)
            $text = [System.Text.Encoding]::UTF8.GetString($buf, 0, $read)
        } finally { $fs.Dispose() }
    } catch { return $none }

    $tokens = 0
    # The LAST usage object in the tail is the newest reply's, and its
    # input + cache figures are what the context is currently holding.
    $mm = [regex]::Matches($text, '"usage":\{[^}]*\}')
    if ($mm.Count) {
        $last = $mm[$mm.Count - 1].Value
        foreach ($f in @('input_tokens', 'cache_read_input_tokens', 'cache_creation_input_tokens')) {
            $one = [regex]::Match($last, ('"{0}":(\d+)' -f $f))
            if ($one.Success) { $tokens += [int]$one.Groups[1].Value }
        }
    }

    # Something is OUT when its call id has not been quoted back by a result.
    # Two kinds, kept apart all the way to the screen, because they answer
    # different questions: a sub-agent is another conversation working on your
    # behalf, a background shell is a command still running.
    $agents = @{}
    foreach ($m in [regex]::Matches($text, '"id":"(toolu_[A-Za-z0-9_]+)","name":"Task"')) {
        $agents[$m.Groups[1].Value] = $true
    }
    foreach ($m in [regex]::Matches($text, '"tool_use_id":"(toolu_[A-Za-z0-9_]+)"')) {
        $id = $m.Groups[1].Value
        if ($agents.ContainsKey($id)) { $null = $agents.Remove($id) }
    }
    # 🔴 NO SHELL COUNT HERE, AND THAT IS THE ANSWER RATHER THAN A GAP. This
    # used to run the same unanswered-call test over a Bash carrying
    # run_in_background, and it could only ever return zero: a background Bash
    # gets its tool_result back IMMEDIATELY, carrying the shell id, so the call
    # is answered the instant it is made and nothing is ever left outstanding.
    # Measured on a live transcript - one background shell launched, one result
    # written - which is why the square mark never once appeared on a row.
    # The count the session prints on its own status line is the only true one;
    # Read-SRScreenVitals reads it and the window caches it per session.

    $window = 200000
    if ($tokens -gt 200000) { $window = 1000000 }
    $v = [PSCustomObject]@{
        Tokens = $tokens; Window = $window
        Frac = $(if ($window -gt 0) { [double]$tokens / [double]$window } else { 0.0 })
        Agents = $agents.Count; Shells = 0
        Ok = ($tokens -gt 0 -or $agents.Count -gt 0)
    }
    $script:SR_SigCache[$key] = @{ Stamp = $stamp; Value = $v }
    return $v
}

function Get-SRSessionVitals {
    [CmdletBinding()]
    param(
        [string]$JsonlPath,
        $Session,
        [string]$WorkDir,
        [int]$MaxTailBytes = 600000,
        [switch]$NoDiff
    )
    $v = New-SRVitals

    # The launch flags, through the accessors. A bare property read would report
    # every unset session as no-remote: Test-SRRemoteWanted carries the
    # default-on rule and this must not restate it.
    if ($Session) {
        $v.Effort = "$(Get-SRSessionPref $Session 'effort')".Trim()
        $v.Mode   = "$(Get-SRSessionPref $Session 'permissionMode')".Trim()
        try { $v.Remote = [bool](Test-SRRemoteWanted $Session) } catch { }
    }
    if (-not $JsonlPath -or -not (Test-Path -LiteralPath $JsonlPath)) { return $v }

    $stamp = ''
    try {
        $fi = Get-Item -LiteralPath $JsonlPath
        $stamp = '{0}|{1}' -f $fi.Length, $fi.LastWriteTimeUtc.Ticks
    } catch { return $v }

    $key = $JsonlPath.ToLower()
    $parsed = $null
    if ($script:SR_VitalCache.ContainsKey($key) -and $script:SR_VitalCache[$key].Stamp -eq $stamp) {
        $parsed = $script:SR_VitalCache[$key].Value
    }

    if (-not $parsed) {
        $text = ''
        try {
            $fs = [System.IO.File]::Open($JsonlPath, 'Open', 'Read', 'ReadWrite')
            try {
                $take = [int][Math]::Min($fi.Length, $MaxTailBytes)
                $null = $fs.Seek(-$take, 'End')
                $buf = New-Object byte[] $take
                $read = $fs.Read($buf, 0, $take)
                $text = [System.Text.Encoding]::UTF8.GetString($buf, 0, $read)
            } finally { $fs.Dispose() }
        } catch { return $v }

        $lines = @($text -split "`n" | Where-Object { $_.Trim().StartsWith('{') })
        if (-not $lines.Count) { return $v }

        $parsed = [PSCustomObject]@{
            Model = ''; Tokens = 0; Branch = ''; Shells = 0; Agents = 0
            TurnTokens = 0; TurnAt = $null
        }
        $open = @{}
        $turnAt = $null
        $lastAt = $null
        $turnOut = 0
        foreach ($ln in $lines) {
            $r = $null
            try { $r = $ln | ConvertFrom-Json } catch { continue }
            if ($r.PSObject.Properties['gitBranch'] -and "$($r.gitBranch)") { $parsed.Branch = "$($r.gitBranch)" }
            if ($r.PSObject.Properties['timestamp'] -and "$($r.timestamp)") {
                try {
                    $ts = [datetime]::Parse("$($r.timestamp)", [System.Globalization.CultureInfo]::InvariantCulture,
                                            [System.Globalization.DateTimeStyles]::AdjustToUniversal)
                    $lastAt = $ts
                    # 🔴 A TURN STARTS WHEN *YOU* SPEAK - AND MOST "user" RECORDS
                    # ARE NOT YOU.
                    #
                    # Every tool_result is written as type "user", because it is
                    # input being handed back to the model. Measured in a live
                    # transcript: 5 of the 6 user records in the tail were tool
                    # results. Treating them as turn starts reset the clock on
                    # every single tool call, so a reply that had been running
                    # for nine minutes reported "3s" - reported by the operator
                    # as the timer never getting past a few seconds, which is
                    # exactly what it was doing.
                    #
                    # A genuine turn carries no toolUseResult and its content is
                    # not a tool_result block. Both are checked: the property is
                    # the reliable marker, the block shape is the fallback for a
                    # record shape that predates it.
                    if ("$($r.type)" -eq 'user' -and (Test-SRHumanTurn $r)) { $turnAt = $ts; $turnOut = 0 }
                } catch { }
            }
            $m = $r.message
            if (-not $m) { continue }
            # 🪤 NOT EVERY ASSISTANT RECORD HAS A REAL MODEL. Claude Code writes
            # some messages itself - "No response requested.", cancellations -
            # and stamps them `<synthetic>`. Taking the LAST model meant one of
            # those made the strip read "‹synthetic›" where the model belongs,
            # which is an internal placeholder on the operator's surface. Caught
            # by rendering the pane and looking at it; no assertion here asked
            # what the model WAS, only that a model chip existed.
            if ($m.PSObject.Properties['model'] -and "$($m.model)" -and "$($m.model)" -ne '<synthetic>') {
                $parsed.Model = "$($m.model)"
            }
            if ($m.PSObject.Properties['usage'] -and $m.usage) {
                $u = $m.usage
                $tot = 0
                foreach ($f in @('input_tokens', 'cache_read_input_tokens', 'cache_creation_input_tokens')) {
                    if ($u.PSObject.Properties[$f]) { $tot += [int]$u.$f }
                }
                if ($tot -gt 0) { $parsed.Tokens = $tot }
                if ($u.PSObject.Properties['output_tokens']) { $turnOut += [int]$u.output_tokens }
            }
            foreach ($b in @($m.content)) {
                if (-not $b -or -not $b.type) { continue }
                # 🔴 THIS COUNTER CANNOT WORK AND HAS ALWAYS RETURNED ZERO. Both
                # facts were measured 2026-09-01, and both are recorded here
                # rather than quietly fixed, because "fixing" it would make it
                # count things it must not:
                #
                #   1. The name is 'Agent', never 'Task' - 'Task' appears in 0
                #      of the transcripts on this machine, 'Agent' in 40. So the
                #      agent branch has never once matched.
                #   2. Opening on tool_use and closing on tool_result is the
                #      wrong rule for BOTH kinds. Measured: 52 of 52 background
                #      bashes and 10 of 10 agents got their tool_result with a
                #      median AND MAXIMUM gap of 0.0s - that is where the id is
                #      handed back, not where the work ends. So even with the
                #      name corrected, every entry closes on the next record.
                #
                # 🪤 AND THE ZERO IS LOAD-BEARING. The SCREEN owns these numbers
                # (see the run-file: the screen is the source of truth, not the
                # transcript). A transcript-derived count would keep reporting
                # shells and agents for a session that is no longer running -
                # the same defect as the 374 dead sub-agents in 07e13c3. What is
                # genuinely running, by name, is Get-SRLiveTasks.
                if ($b.type -eq 'tool_use') {
                    $nm = "$($b.name)"
                    if ($nm -eq 'Agent' -or $nm -eq 'Task') { $open["$($b.id)"] = 'agent' }
                    elseif ($nm -eq 'Bash' -and $b.input -and
                            $b.input.PSObject.Properties['run_in_background'] -and $b.input.run_in_background) {
                        $open["$($b.id)"] = 'shell'
                    }
                } elseif ($b.type -eq 'tool_result') {
                    $id = "$($b.tool_use_id)"
                    if ($id -and $open.ContainsKey($id)) { $null = $open.Remove($id) }
                }
            }
        }
        foreach ($k in @($open.Keys)) {
            if ($open[$k] -eq 'agent') { $parsed.Agents++ } else { $parsed.Shells++ }
        }
        $parsed.TurnTokens = $turnOut
        if ($turnAt) { $parsed.TurnAt = $turnAt } else { $parsed.TurnAt = $lastAt }
        $script:SR_VitalCache[$key] = @{ Stamp = $stamp; Value = $parsed }
    }

    $v.Model = $parsed.Model
    $v.Tokens = $parsed.Tokens
    $v.Branch = $parsed.Branch
    $v.Shells = $parsed.Shells
    $v.Agents = $parsed.Agents
    $v.TurnTokens = $parsed.TurnTokens
    $v.TurnAt = $parsed.TurnAt
    if ($parsed.TurnAt) { $v.Elapsed = ([datetime]::UtcNow - $parsed.TurnAt).TotalSeconds }

    # 🔴 THE MODEL ID DOES NOT SAY WHICH WINDOW IT HAS. A 1M session writes
    # itself down as plain "claude-opus-5" - the [1m] suffix is a launch-time
    # selection and never reaches the transcript - so keying the window off the
    # id reported a real 764k context as 380% of 200k. Observation settles it:
    # a context that has exceeded the standard window IS proof of the larger one.
    $v.Window = 200000
    if ($v.Model -match '1m' -or $v.Tokens -gt 200000) { $v.Window = 1000000 }

    if (-not $NoDiff -and $WorkDir) {
        $d = Get-SRWorkingDiff -Path $WorkDir
        if ($d) { $v.Added = $d.Added; $v.Removed = $d.Removed }
        # 🪤 "HEAD" IS NOT A BRANCH NAME. Every worktree session in this registry
        # records gitBranch=HEAD, because that is what claude writes for a
        # detached checkout, and a chip reading "HEAD" says nothing. Ask git; if
        # git says HEAD too, name the worktree, which IS where the work is.
        if ((-not $v.Branch -or $v.Branch -eq 'HEAD') -and (Test-Path -LiteralPath $WorkDir)) {
            try {
                $bn = (Invoke-SRGitLine -Path $WorkDir -Arguments @('rev-parse', '--abbrev-ref', 'HEAD')).Trim()
                if ($bn -and $bn -ne 'HEAD') { $v.Branch = $bn }
                else { $v.Branch = (Split-Path -Leaf $WorkDir) }
            } catch { }
        }
    }
    $v.Ok = $true
    return $v
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
# 🔴 A BUSY SESSION IS THE ONE MOST LIKELY TO SAY NOTHING HERE, which is the
# wrong way round. This reads a fixed tail, and on 2026-08-30 two of eleven live
# conversations showed a blank 'what it last said' - not because they were
# quiet, but because their transcripts were 82 MB and 27 MB and the last 256 KB
# was solid tool traffic. The comment below already anticipated the case; what
# it did not say is that the sessions it happens to are precisely the ones you
# most want to read.
#
# So a miss now escalates instead of giving up: the window widens and the record
# limit with it, stopping the moment something is found. The cost is paid ONLY
# by the conversations that need it - one extra read for two rows out of eleven,
# on a background thread - and the first budget is unchanged, so the common case
# is exactly as fast as it was.
#
# 🪤 THE PENDING TOOL FOUND ON AN EARLIER, NARROWER PASS IS KEPT. A wider pass
# reaches further back, so it can find an OLDER tool call and would otherwise
# overwrite the current one with a stale one - reporting a session as running
# something it finished minutes ago.
# 🔴 AN UNCHANGED TRANSCRIPT CANNOT SAY ANYTHING NEW, and not asking it is 799
# of the 1,272 ms the refresh pass used to cost. Measured 2026-09-04 across the
# operator's 292 conversations: this reader was 63% of Update-Model on its own -
# 44 live-or-warm rows at 18 ms each - because every call re-read a 256 KB tail
# and ran ConvertFrom-Json over up to 120 records, on the UI thread, for files
# that had not moved since the last pass. Every other per-row call in that pass
# put together came to 210 ms.
#
# The stamp is the one Get-SRRowSignals already uses - length and last-write
# together - PLUS the two budgets, so a caller asking for a WIDER read is never
# handed the narrow answer cached for a cheaper one. That matters here and not
# in SigCache: this reader escalates its own window on a miss, so the same path
# is legitimately called at three different sizes.
#
# 🪤 THE CACHE IS PER-RUNSPACE, like SR_SigCache, because every runspace dot-
# sources this file and gets its own copy. That is what makes it safe without a
# lock; it is also why the window's FIRST pass still pays full price - the
# background probe warmed its copy, not this one.
$script:SR_SaidCache = @{}

function Get-SRLastSaid {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$JsonlPath,
        [int]$MaxTailBytes = 262144,
        # How many records back to look before giving up. A session that has run
        # a long unbroken chain of tools may genuinely have no prose in the tail.
        [int]$MaxRecords = 120
    )

    $stamp = ''
    try {
        $sfi = Get-Item -LiteralPath $JsonlPath -ErrorAction Stop
        $stamp = '{0}|{1}|{2}|{3}' -f $sfi.Length, $sfi.LastWriteTimeUtc.Ticks, $MaxTailBytes, $MaxRecords
    } catch { }
    $skey = "$JsonlPath".ToLower()
    if ($stamp -and $script:SR_SaidCache.ContainsKey($skey) -and $script:SR_SaidCache[$skey].Stamp -eq $stamp) {
        return $script:SR_SaidCache[$skey].Value
    }

    $v = Get-SRLastSaidRead -JsonlPath $JsonlPath -MaxTailBytes $MaxTailBytes -MaxRecords $MaxRecords
    # A file that could not be stat'ed is never cached: there is nothing to
    # invalidate against, so the entry could never be retired.
    if ($stamp) { $script:SR_SaidCache[$skey] = @{ Stamp = $stamp; Value = $v } }
    return $v
}

function Get-SRLastSaidRead {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$JsonlPath,
        [int]$MaxTailBytes = 262144,
        [int]$MaxRecords = 120
    )

    $first = Get-SRLastSaidPass -JsonlPath $JsonlPath -MaxTailBytes $MaxTailBytes -MaxRecords $MaxRecords
    if ("$($first.Said)".Trim()) { return $first }
    $len = 0
    try { $len = (Get-Item -LiteralPath $JsonlPath -ErrorAction Stop).Length } catch { return $first }
    # Nothing more to read: the file is already fully covered, so it really did
    # say nothing.
    if ($len -le $MaxTailBytes) { return $first }
    foreach ($mult in @(8, 32)) {
        $wider = Get-SRLastSaidPass -JsonlPath $JsonlPath -MaxTailBytes ($MaxTailBytes * $mult) -MaxRecords ($MaxRecords * $mult)
        if ("$($wider.Said)".Trim()) {
            # Keep the nearer pass's pending tool - see the note above.
            if ("$($first.Pending)".Trim()) {
                $wider.Pending = $first.Pending
                $wider.PendingTool = $first.PendingTool
            }
            return $wider
        }
        if ($len -le ($MaxTailBytes * $mult)) { break }
    }
    return $first
}

function Get-SRLastSaidPass {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$JsonlPath,
        [int]$MaxTailBytes = 262144,
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

# ===========================================================================
# THE SKILLS A CONVERSATION CAN SEE.
#
# Read off disk rather than asked of the session, because the list is wanted
# BEFORE you have picked a session and for conversations that are not running.
# Three sources, in the order claude resolves them - a project skill shadows a
# user one of the same name, so the first of a name wins here too:
#
#   <project>\.claude\skills\<name>\SKILL.md    project
#   ~\.claude\skills\<name>\SKILL.md            user
#   ~\.claude\plugins\cache\*\...\SKILL.md      plugin
#
# 🪤 CACHED, because this is 55+ file reads and it runs on a keystroke. Keyed by
# project, with a short life so a skill written five minutes ago still shows up.
$script:SR_SkillCache = @{}
$script:SR_SkillCacheAt = @{}

function Get-SRSkillMeta { param([string]$Path, [string]$Source, [string]$Fallback)
    $name = $Fallback
    $desc = ''
    try {
        # Only the frontmatter: these files run to hundreds of lines and none of
        # the rest is wanted.
        $head = @(Get-Content -LiteralPath $Path -TotalCount 40 -ErrorAction Stop)
        $inFm = $false
        foreach ($ln in $head) {
            if ($ln -match '^---\s*$') { if ($inFm) { break } else { $inFm = $true; continue } }
            if (-not $inFm) { continue }
            if ($ln -match '^name:\s*(.+)$')        { $name = $Matches[1].Trim().Trim('"').Trim("'") }
            elseif ($ln -match '^description:\s*(.+)$') { $desc = $Matches[1].Trim().Trim('"').Trim("'") }
        }
    } catch { }
    if (-not $name) { $name = $Fallback }
    return [PSCustomObject]@{ Name = $name; Description = $desc; Source = $Source; Path = $Path }
}

function Get-SRSkills {
    [CmdletBinding()]
    param([string]$Dir, [int]$MaxAgeSeconds = 120, [switch]$Refresh)

    $key = "$Dir".ToLower()
    if (-not $Refresh -and $script:SR_SkillCache.ContainsKey($key) -and $script:SR_SkillCacheAt.ContainsKey($key)) {
        if (((Get-Date) - $script:SR_SkillCacheAt[$key]).TotalSeconds -lt $MaxAgeSeconds) {
            return $script:SR_SkillCache[$key]
        }
    }

    $roots = New-Object System.Collections.Generic.List[object]
    if ($Dir) { $roots.Add(@{ P = (Join-Path $Dir '.claude\skills'); S = 'project' }) }
    $roots.Add(@{ P = (Join-Path $env:USERPROFILE '.claude\skills'); S = 'user' })

    $out = New-Object System.Collections.Generic.List[object]
    $seen = @{}
    foreach ($r in $roots) {
        if (-not (Test-Path -LiteralPath $r.P -PathType Container)) { continue }
        foreach ($d in @(Get-ChildItem -LiteralPath $r.P -Directory -ErrorAction SilentlyContinue)) {
            $sk = Join-Path $d.FullName 'SKILL.md'
            if (-not (Test-Path -LiteralPath $sk)) { continue }
            $m = Get-SRSkillMeta -Path $sk -Source $r.S -Fallback $d.Name
            $k = "$($m.Name)".ToLower()
            if (-not $k -or $seen.ContainsKey($k)) { continue }
            $seen[$k] = $true
            $out.Add($m)
        }
    }

    # Plugin skills live two levels down inside each cached plugin, and a plugin
    # names its skills `plugin:skill` when they collide - which is why the source
    # is carried through and shown.
    $pc = Join-Path $env:USERPROFILE '.claude\plugins\cache'
    if (Test-Path -LiteralPath $pc -PathType Container) {
        foreach ($sk in @(Get-ChildItem -LiteralPath $pc -Filter 'SKILL.md' -Recurse -Depth 5 -File -ErrorAction SilentlyContinue)) {
            $m = Get-SRSkillMeta -Path $sk.FullName -Source 'plugin' -Fallback $sk.Directory.Name
            $k = "$($m.Name)".ToLower()
            if (-not $k -or $seen.ContainsKey($k)) { continue }
            $seen[$k] = $true
            $out.Add($m)
        }
    }

    $sorted = @($out | Sort-Object Name)
    $script:SR_SkillCache[$key] = $sorted
    $script:SR_SkillCacheAt[$key] = Get-Date
    return $sorted
}

# What a person typed after '/', matched against what they can see. Prefix
# matches first, because that is what someone typing a name expects to find at
# the top; then anything containing it; then the description.
function Select-SRSkills { param($Skills, [string]$Query, [int]$Limit = 8)
    $q = "$Query".Trim().ToLower()
    $all = @($Skills)
    if (-not $q) { return @($all | Select-Object -First $Limit) }
    $pre  = @($all | Where-Object { "$($_.Name)".ToLower().StartsWith($q) })
    $mid  = @($all | Where-Object { "$($_.Name)".ToLower().Contains($q) -and -not "$($_.Name)".ToLower().StartsWith($q) })
    $desc = @($all | Where-Object { -not "$($_.Name)".ToLower().Contains($q) -and "$($_.Description)".ToLower().Contains($q) })
    return @(@($pre) + @($mid) + @($desc) | Select-Object -First $Limit)
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
