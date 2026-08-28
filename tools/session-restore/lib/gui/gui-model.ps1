#requires -Version 5.1
# ===========================================================================
# THE MODEL
#
# What a conversation IS: liveness, staleness, lanes, the tick, the pin, the seen stamp, the note, and the filter that decides whether a row survives.
#
# DOT-SOURCED BY sessions-gui.ps1, into its own scope, AFTER $window, $Pal and
# $ui exist - everything here reads them at CALL time, never at load time.
#
# Read tools/session-restore/CONTEXT.md before changing anything in here. The
# traps in it are not hypothetical: every one of them shipped.
# ===========================================================================

# ---------------------------------------------------------------------------
# Ported helpers.
#
# These came from select-sessions.ps1, the terminal panel this window replaced,
# and each one used to cite its original by name. THE PANEL IS RETIRED, so those
# citations would point at a file nobody can open. What they were really
# recording is that this behaviour is a PORT rather than an invention, and that
# restore-sessions.ps1 applies the SAME guards at logon - so the window, the
# logon task and the hourly roll can never disagree about what is launchable.
# That is the part worth keeping, and it is said once, here.
# ---------------------------------------------------------------------------

# Ported: Get-Newest. Null-filtered, not just @()-wrapped: a function
# returning an empty array yields $null, and @($null) is an array of ONE $null,
# which sails past a .Count check and then dies in the sort.
function Get-Newest { param($Sessions)
    $s = @(@($Sessions) | Where-Object { $_ })
    if (-not $s.Count) { return [datetime]'1970-01-01' }
    $ordered = @($s | Where-Object { $_.lastActive } | Sort-Object { [datetime]$_.lastActive } -Descending)
    if (-not $ordered.Count) { return [datetime]'1970-01-01' }
    return [datetime]$ordered[0].lastActive
}

# Ported: Get-Visible. Memoised: several passes walk every project.
# Returned UNWRAPPED, so empty arrives as $null and Get-Newest survives it.
function Get-Visible { param($Dir)
    $hit = $script:visCache[[string]$Dir.path]
    if ($null -ne $hit) { return $hit }
    $v = if ($script:showWt) { @($Dir.sessions) } else { @(@($Dir.sessions) | Where-Object { $_.lane -ne 'worktree' }) }
    $script:visCache[[string]$Dir.path] = $v
    return $v
}

function Get-Age { param($Iso)
    $d = ((Get-Date) - [datetime]$Iso)
    if ($d.TotalDays -ge 1) { return ("{0}d" -f [int]$d.TotalDays) }
    return ("{0}h" -f [int]$d.TotalHours)
}
function Test-Stale { param($Iso) return (((Get-Date) - [datetime]$Iso).TotalDays -gt $script:staleDays) }

# Touching a conversation PINS it: the hourly roll then leaves it alone. Without
# this the scan would undo every hand-made choice within the hour and this window
# would be decorative. Ported: Set-Pin / Test-Pinned.
function Set-Pin { param($Session, [bool]$Value)
    if ($null -eq $Session.PSObject.Properties['pinned']) {
        $Session | Add-Member -NotePropertyName pinned -NotePropertyValue $Value -Force
    } else { $Session.pinned = $Value }
}
function Test-Pinned { param($Session) return ([bool]$Session.pinned) }

# ---------------------------------------------------------------------------
# SEEN, and the NOTE.
#
# "I find myself clicking through the tabs to see if there has been any
# progress, and then it is hard to remember where we are." Two different
# problems, and they want two different answers:
#
#   SEEN   is the machine's: has this conversation said anything since I last
#          looked at it. A stamp on the conversation, set when the reading pane
#          actually shows it, and a dot on the row while lastActive is newer.
#          Exactly the unread mark, because it is exactly the unread problem.
#
#   NOTE   is yours: what this one is FOR and where you meant to take it. No
#          amount of reading the transcript recovers that, which is why it
#          outranks the last-said line on the row - a sentence you wrote beats
#          the tail of a transcript.
#
# Both live on the session object in the registry beside `pinned`, so they
# survive a rescan and a restart, and both are written through Add-Member
# because a session discovered before this existed has no such property.
# ---------------------------------------------------------------------------
function Set-SessionField { param($Session, [string]$Name, $Value)
    if ($null -eq $Session.PSObject.Properties[$Name]) {
        $Session | Add-Member -NotePropertyName $Name -NotePropertyValue $Value -Force
    } else { $Session.$Name = $Value }
}

function Get-SessionNote { param($Session)
    if (-not $Session) { return '' }
    return "$($Session.note)"
}

function Set-SessionNote { param($Session, [string]$Text)
    if (-not $Session) { return }
    Set-SessionField $Session 'note' "$Text".Trim()
    $script:dirty = $true
}

# Has it said anything since the pane last showed it?
#
# A CONVERSATION NEVER LOOKED AT IS NOT MOVED. The first version said it was -
# "it has everything still to tell you" - which is defensible and, measured
# against the real registry, put a dot on ELEVEN OF ELEVEN ROWS. A mark that is
# on for everything carries no information at all; it is texture that costs a
# column. The dot means one thing now: you looked at this, and it has spoken
# since. That is rare, which is what makes it worth looking at.
#
# The cost is that the mark is silent until you have opened something, and that
# is the honest state: with no baseline there is no answer to "has this moved",
# and rendering an unknown as a yes is how a signal stops being believed.
function Test-Moved { param($Session)
    if (-not $Session -or -not $Session.lastActive) { return $false }
    $seen = "$($Session.lastSeen)"
    if (-not $seen) { return $false }
    try { return ([datetime]$Session.lastActive -gt [datetime]$seen) } catch { return $false }
}

# Set ONLY where the conversation was actually put on screen. Marking things
# seen because they scrolled past would make the dot mean nothing, which is the
# one way an unread mark can be worse than none.
function Set-Seen { param($Session)
    if (-not $Session) { return }
    Set-SessionField $Session 'lastSeen' ((Get-Date).ToString('o'))
    $script:dirty = $true
}

function Get-LaneName { param($Session)
    if ($Session.lane -eq 'worktree' -and $Session.worktree) { return $Session.worktree }
    return 'main'
}

# main first, then worktree lanes newest-first. Ported: Get-Lanes.
# Returns ,@(...) -- assign it, then wrap. Never pipe the call.
function Get-Lanes { param($Dir)
    $g = @(Get-Visible $Dir) | Group-Object -Property { Get-LaneName $_ }
    $out = @()
    $out += @($g | Where-Object { $_.Name -eq 'main' })
    $out += @($g | Where-Object { $_.Name -ne 'main' } | Sort-Object { Get-Newest $_.Group } -Descending)
    return ,@($out)
}

function Get-SessionCwd { param($Session, $Dir)
    if ($Session.cwd) { return $Session.cwd }
    return $Dir.path
}

# ---------------------------------------------------------------------------
# WHAT TO CALL A PROJECT, given that eight of them are called the same thing.
#
# The roster used to order projects ALPHABETICALLY, and the note defending that
# named the real hazard: `Millwright-experiments\runs\R*\repo` produces eight
# projects whose leaf name is "repo", so any order that is not alphabetical
# scatters eight identical-looking rows down the screen and "where is my repo"
# has eight answers.
#
# Alphabetical order solved the symptom by making the duplicates adjacent. It
# also made the list useless for its actual question -- "where was I working?" --
# which is what the operator asked for. So solve the CAUSE instead: give every
# project a label that is unique on screen, and then order however is useful.
#
# Walk up the path one segment at a time, and only as far as it takes:
#   AlgoTrader                              stays "AlgoTrader"        (unique)
#   ...\runs\R12\repo                       becomes "R12 / repo"      (leaf is not)
#   ...\runs\R08\repo                       becomes "R08 / repo"
# A project whose name is already unique is untouched, so 24 of 26 rows read
# exactly as they did before.
function Update-ProjectLabels {
    $script:projLabel = @{}
    $paths = @($script:dirs | ForEach-Object { [string]$_.path } | Where-Object { $_ })
    if (-not $paths.Count) { return }

    # How many segments each path needs. Start at one and widen only the ones
    # that still collide, so a widened label never drags an unrelated project
    # wider with it.
    $depth = @{}
    foreach ($p in $paths) { $depth[$p] = 1 }

    function Get-Tail { param([string]$Path, [int]$N)
        $parts = @("$Path".TrimEnd('\') -split '\\' | Where-Object { $_ })
        if (-not $parts.Count) { return "$Path" }
        $take = [Math]::Min($N, $parts.Count)
        return (@($parts[($parts.Count - $take)..($parts.Count - 1)]) -join ' / ')
    }

    # Bounded: a path has finitely many segments, and 8 is deeper than any real
    # one here. Without the bound, two paths that are genuinely identical would
    # widen forever.
    for ($round = 0; $round -lt 8; $round++) {
        $byLabel = @{}
        foreach ($p in $paths) {
            $lab = Get-Tail $p $depth[$p]
            if (-not $byLabel.ContainsKey($lab)) { $byLabel[$lab] = New-Object System.Collections.Generic.List[object] }
            $byLabel[$lab].Add($p)
        }
        $widened = $false
        foreach ($kv in $byLabel.GetEnumerator()) {
            if ($kv.Value.Count -le 1) { continue }
            foreach ($p in $kv.Value.ToArray()) {
                $segs = @("$p".TrimEnd('\') -split '\\' | Where-Object { $_ }).Count
                if ($depth[$p] -lt $segs) { $depth[$p] = $depth[$p] + 1; $widened = $true }
            }
        }
        if (-not $widened) { break }
    }

    foreach ($p in $paths) { $script:projLabel[$p.ToLowerInvariant()] = (Get-Tail $p $depth[$p]) }
}

# The label, or the leaf if labels have not been computed yet -- which is the
# case for any caller that runs before the first Set-Registry, and for the
# fixtures a test builds by hand.
function Get-ProjectLabel { param($Dir)
    $p = $(if ($Dir -is [string]) { $Dir } else { [string]$Dir.path })
    if (-not $p) { return '' }
    # THE HOME DIRECTORY IS NOT CALLED "mauri". Its leaf is the account name,
    # which reads like a project nobody remembers creating -- and it is where a
    # conversation lands when it started nowhere in particular, which is the
    # thing the operator wanted to be able to tell apart.
    if ($p.TrimEnd('\') -ieq "$env:USERPROFILE".TrimEnd('\')) { return 'home folder' }
    if ($script:projLabel) {
        $hit = $script:projLabel[$p.ToLowerInvariant()]
        if ($hit) { return $hit }
    }
    return (Split-Path $p -Leaf)
}

# Project and lane as ONE string, which is what the roster's PROJECT / LANE
# column shows and what its heading sorts by. In one place so the column, the
# sort and the inbox's label can never disagree about what a conversation's
# home is called.
function Get-HomeLabel { param($Dir, $LaneName)
    $proj = Get-ProjectLabel $Dir
    $lane = "$LaneName"
    if ($lane -and $lane -ne 'main') { return "$proj / $lane" }
    return $proj
}

# ---------------------------------------------------------------------------
# IS THIS SOMETHING YOU COULD GO BACK TO WORKING IN?
#
# The operator: "I'm oftentimes seeing a lot of untitled conversations or
# conversations that I have simply started in my main Drive directory and not in
# any project directory which I then also shown, which in theory is correct, but
# it kind of makes it a bit difficult for me to understand what projects I need
# to open up."
#
# Correct, and in the way. Two kinds of row are competing for the top of a
# recency-ordered list without being places anyone can work:
#
#   tier 2  THE DIRECTORY IS GONE. Millwright-experiments uns R12 epo holds
#           EIGHTEEN conversations and the folder was deleted. Discovery already
#           refuses them -- their cwd does not resolve -- so not one of them can
#           be launched, ticked or relaunched, ever. Eighteen rows of dead weight
#           in the middle of the list.
#   tier 1  NOT A PROJECT. The home directory is where a conversation started
#           when it started nowhere in particular. Three of them here.
#
# NOTHING IS EXCLUDED. Commit 06391a0 stopped excluding the home directory and
# recovered three conversations of 20-28 MB, and that stands: this is an ORDER,
# not a filter, and every row is still reachable, searchable and tickable. They
# just stop outranking places the operator actually works.
function Get-ProjectTier { param($Dir)
    if (-not $Dir) { return 0 }
    if ($script:projTier) {
        # TrimEnd HERE TOO. Update-ProjectTiers stores the key trimmed, and a
        # registry path that happens to carry a trailing backslash would miss the
        # lookup and come back tier 0 -- silently promoting a deleted folder back
        # to the top of the list.
        $hit = $script:projTier["$($Dir.path)".TrimEnd('\').ToLowerInvariant()]
        if ($null -ne $hit) { return [int]$hit }
    }
    return 0
}

function Update-ProjectTiers {
    $script:projTier = @{}
    $script:projWhy  = @{}
    $homeDir = "$env:USERPROFILE".TrimEnd('\')
    foreach ($d in @($script:dirs)) {
        $p = "$($d.path)".TrimEnd('\')
        $key = $p.ToLowerInvariant()
        $tier = 0; $why = ''
        # Test-Path ONCE PER SCAN, not once per repaint. This runs from
        # Set-Registry; a row painter that touched the disk would hit it 26 times
        # a frame for an answer that cannot change between frames.
        if ([bool]$d.missing -or -not (Test-Path -LiteralPath $p -PathType Container)) {
            $tier = 2; $why = 'folder is gone'
        } elseif ($p -and ($p -ieq $homeDir -or $p -match '^[A-Za-z]:$')) {
            $tier = 1; $why = 'not a project'
        } elseif ($key -like "*\.claude\*") {
            # SCRATCH SPACE IS NOT A PROJECT, and it was sitting near the top of
            # a recency-ordered list because scratch is BUSY by definition.
            # Millwright-agency\.claude\scratch and its spawn-probe subfolder came
            # out as two project rows in the first seven, and one of them was
            # TICKED -- reopening a throwaway session every single morning.
            #
            # 🪤 THIS CANNOT CATCH A WORKTREE LANE, and that is worth stating
            # because it looks like it should. A conversation in
            # AlgoTrader\.claude\worktrees\GOV-1 is not a project at all:
            # Get-SRWorktreeInfo resolves it to the REPO ROOT, and the registry
            # path here is AlgoTrader. GOV-1 is a lane, and lanes never reach
            # this function.
            $tier = 1; $why = 'scratch space'
        }
        $script:projTier[$key] = $tier
        $script:projWhy[$key]  = $why
    }
}

# Why a project was demoted, in the fewest words that are still true. Empty for
# an ordinary project, which is almost all of them.
#
# Stored beside the tier rather than derived FROM it: two different things are
# both "not somewhere you work" without being the same thing, and a header that
# called scratch space "not a project" would be true and useless.
function Get-ProjectTierNote { param($Dir)
    if (-not $Dir) { return '' }
    if ($script:projWhy) {
        $hit = $script:projWhy["$($Dir.path)".TrimEnd('\').ToLowerInvariant()]
        if ($hit) { return $hit }
    }
    return ''
}

# When the project was last worked in: the newest conversation under it. This is
# what the roster orders by, and it deliberately reads the same field the WHEN
# column shows, so the first project on screen is the one whose top row has the
# smallest age.
function Get-DirLastActive { param($Dir)
    $best = [datetime]'1970-01-01'
    foreach ($s in @(Get-Visible $Dir)) {
        if (-not $s.lastActive) { continue }
        try { $at = [datetime]$s.lastActive } catch { continue }
        if ($at -gt $best) { $best = $at }
    }
    return $best
}
# ---------------------------------------------------------------------------
# What a conversation is CALLED, in one place, in strict order of who said so.
#
#   1. title      somebody chose it: -n, a rename, an adopted live agent name.
#   2. autoTitle  claude generated it from what the conversation is about.
#   3. cwd leaf   nothing named it, but it is at least somewhere.
#   4. (untitled) nothing is known.
#
# 🪤 "(untitled)" IS A SENTINEL STORED IN `title`, NOT AN EMPTY FIELD. Discovery
# writes that literal string when a transcript has no customTitle, so the old
# IsNullOrWhiteSpace test never fired and the cwd fallback below had, in
# practice, never run once. 97 of the operator's 204 conversations were called
# "(untitled)" on screen while their own transcripts held a perfectly good name.
#
# Steps 1 and 2 are deliberately not merged: a name that was CHOSEN and a name
# that was GUESSED are different things, the row draws them differently, and
# keeping them in separate fields is what guarantees the guess can never win.
$script:UntitledMark = '(untitled)'

function Test-RealTitle { param([string]$Text)
    return ([bool]"$Text".Trim() -and "$Text".Trim() -ne $script:UntitledMark)
}

function Get-SessionTitle { param($Session, $Dir)
    if (Test-RealTitle $Session.title) { return $Session.title }
    if (Test-RealTitle $Session.autoTitle) { return $Session.autoTitle }
    $leaf = Split-Path (Get-SessionCwd $Session $Dir) -Leaf
    if ("$leaf".Trim()) { return $leaf }
    return $script:UntitledMark
}

# Is the name on the row a guess rather than a choice? The row draws a derived
# name in a lighter weight, because "Diagnose and optimize slow PC performance"
# is claude describing the conversation and "F2-SPINE" is the operator naming it,
# and telling them apart at a glance is the difference between a list you trust
# and one you have to re-read.
function Test-DerivedTitle { param($Session)
    if (-not $Session) { return $false }
    if (Test-RealTitle $Session.title) { return $false }
    return (Test-RealTitle $Session.autoTitle)
}

# Ported: Test-JustLaunched. The optimistic mark expires on the CLOCK,
# not on the next rescan: claude takes seconds to surface in Win32_Process and a
# row that reads idle in that gap invites a second, duplicate tab.
function Test-JustLaunched { param([string]$Id)
    $t = $script:launching[$Id]
    if (-not $t) { return $false }
    if (((Get-Date) - [datetime]$t).TotalSeconds -gt $SR_LaunchGraceSeconds) {
        $script:launching.Remove($Id)
        return $false
    }
    return $true
}

# Ported: Get-SessionState. GONE outranks everything: there is nothing
# to launch, so nothing else about the row matters.
function Get-SessionState { param($Session)
    $id = "$($Session.sessionId)".ToLower()
    if ($Session.gone)         { return 'gone' }
    if ($script:running[$id])  { return 'run' }
    if (Test-JustLaunched $id) { return 'new' }
    if ($script:live[$id])     { return 'act' }
    return ''
}

# The launch guard, with no side effects. This is the ported
# Invoke-LaunchSession -Preview, verbatim in behaviour: every check here is one
# restore-sessions.ps1 already applies, so this window, L in the terminal panel
# and the logon restore can never disagree. Returns $null to mean "it would go",
# otherwise the reason it would not.
function Get-LaunchBlock { param($Session, $Dir)
    $cwd = Get-SessionCwd $Session $Dir
    $id  = "$($Session.sessionId)".ToLower()
    if ($Session.gone) { return "its transcript is gone from disk - it can never be launched" }
    if (-not (Test-Path -LiteralPath $cwd -PathType Container)) { return "directory no longer exists: $cwd" }
    $jsonl = Get-SRTranscriptPath -Dir $cwd -SessionId $Session.sessionId -Recorded $Session.jsonl
    if (-not (Test-Path -LiteralPath $jsonl)) { return "transcript missing for $($Session.sessionId.Substring(0,8)) - press Rescan" }
    if ($script:running[$id])  { return "already open in a running claude.exe" }
    if (Test-JustLaunched $id) { return "already launched a moment ago" }
    if ($script:live[$id])     { return "already live - its transcript was written less than $SR_LiveWindowMinutes min ago" }
    return $null
}

# The cheap half of the guard, for enabling the row's OPEN button on every
# repaint. It skips the two Test-Path calls, which would be 300 file stats across
# the list; the full guard above still runs when the button is actually pressed,
# and it is the one that names the reason.
function Test-RowLaunchable { param($Session)
    switch (Get-SessionState $Session) {
        'gone' { return $false }
        'run'  { return $false }
        'act'  { return $false }
        'new'  { return $false }
    }
    return $true
}

# Ported: Get-LiveInDirectory. What stops a new session being spawned
# onto a tree somebody is already working -- they would share the tree's git index.
#
# DIVERGENCE, deliberate: the original compares $cwd.TrimEnd('') which trims
# whitespace rather than a trailing separator, so `C:\foo` and `C:\foo\` read as
# different trees. This trims '\'.
function Get-LiveInDirectory { param([Parameter(Mandatory)][string]$Dir)
    $out = @()
    foreach ($d in @($script:dirs)) {
        foreach ($s in @($d.sessions)) {
            $cwd = if ($s.cwd) { $s.cwd } else { $d.path }
            if ($cwd -and ($cwd.TrimEnd('\') -ieq $Dir.TrimEnd('\')) -and ((Get-SessionState $s) -in @('run','act','new'))) {
                $out += $s
            }
        }
    }
    return ,@($out)
}

# Ported: Get-RowPath. A lane's path comes from its own sessions: a
# worktree lives somewhere else entirely, not under the project root.
function Get-RowPath { param($Row)
    if ($Row.Kind -ne 'session') { return '' }
    return (Get-SessionCwd $Row.Session $Row.Dir)
}

# Ported: Get-RowSessions. Every session a row covers, newest first.
# Returns ,@(...) -- assign, then wrap. Piping the call hands ForEach-Object the
# whole array as ONE item, which is how a project row once built a single entry
# holding every session at once.
function Get-RowSessions { param($Row)
    if ($Row.Kind -ne 'session') { return ,@() }
    return ,@($Row.Session)
}

# Ported: Invoke-SpawnNew's naming rule, so a session spawned from
# this window and one spawned from the shell are indistinguishable afterwards.
function Resolve-SpawnName { param([string]$Dir, [string]$Name)
    if ([string]::IsNullOrWhiteSpace($Name)) { $Name = (Split-Path $Dir -Leaf) + '-' + (Get-Date -Format 'MMdd-HHmm') }
    $Name = ($Name -replace '\s+', '-').Trim('-')
    if ([string]::IsNullOrWhiteSpace($Name)) { $Name = 'claude-' + (Get-Date -Format 'MMdd-HHmm') }
    return $Name
}

# What _common.ps1 Get-SRConversationState last said about this conversation, or
# $null before the first probe has landed.
# claude's own answer where there is a process to ask, the transcript tail where
# there is not. Measured 2026-08-22 across the 13 live sessions on this machine:
# THE TRANSCRIPT DISAGREED WITH CLAUDE ON SEVEN OF THEM. It called four idle
# sessions "working", one busy session "waiting", and it cannot see a permission
# dialog at all -- a dialog writes nothing to a transcript, so a session sitting
# on one is indistinguishable from a session mid-tool-call. That is the case the
# operator most wants to see, which is why inference lost.
#
# The tail is still the right answer for a conversation that is NOT running:
# there is no process to ask, and a last-known state beats nothing.
function Get-Conv { param($Session)
    if (-not $Session -or -not $Session.sessionId) { return $null }
    $key = "$($Session.sessionId)".ToLower()
    $a = $script:agents[$key]
    $c = $script:conv[$key]
    if (-not $a -and -not $c) { return $null }
    return (Resolve-SRSessionState -Agent $a -Conv $c)
}

# GONE, and worth saying why. Get-ConvBucket partitioned conversations by the
# LAST state their transcript was seen in, and the DOING chips selected on it.
# Measured over the whole registry: 110 of 143 bucketed as 'waiting', because
# every conversation that ever ended on an assistant turn ends up there and
# stays there forever. A chip that selects 77% of everything is
# indistinguishable from a chip that does nothing, which is exactly how it read.
#
# The distinction it was protecting is real and is NOT lost: a conversation's
# last-known state is still shown on its row, prefixed "was", straight out of
# Get-Conv. What is gone is the idea that a filter should select on it. The
# chips now select on Get-InboxBand -- the same four groups the list is headed
# with and the pills count -- so a chip, a band heading and a pill are one
# number by construction rather than three that happen to agree.

# Is anything filtering at all? A fold is IGNORED while it is, because hiding the
# very rows that were searched for is the one thing a filter must never do.
function Test-AnyFilter {
    return [bool]($script:filter -or $script:fProject -or $script:fLane -or
                  $script:fBand.Count -or $script:fLive.Count -or $script:fTick.Count -or
                  $script:fPin.Count -or $script:fAge.Count)
}

# Ported: Test-RowMatch, widened to every dimension this window
# shows. The text box is one clause among several now and composes with the rest.
#
# AND across dimensions, OR within one. An EMPTY dimension does not filter -- so
# "no chips lit" and "every chip lit" mean the same thing, which is what keeps a
# half-set filter from silently hiding rows.
function Test-RowMatch { param($Session, $Dir, $Lane)
    # HIDDEN, and why it is checked before anything else. Hiding is the operator
    # saying "stop showing me this", which outranks every other reason a row might
    # appear -- including a search that would otherwise match it. It is a FLAG, not
    # a deletion: Show hidden brings them all back, because the registry is the only
    # record these conversations have and nothing here is allowed to be final.
    if ([bool]$Session.hidden -and -not $script:showHidden) { return $false }

    # Text. Same fields -Launch matches on, so what you can find here you can
    # also launch by name from the terminal.
    if ($script:filter) {
        $f = $script:filter
        $hit = $false
        # autoTitle IS IN HERE BECAUSE IT IS ON SCREEN. A conversation whose row
        # reads "Fix session history loss in spawned Claude sessions" and which
        # cannot be found by typing "session history" is worse than one with no
        # name at all: the operator can see it, so a search that misses it reads
        # as a broken search rather than a missing field.
        foreach ($hay in @($Session.title, $Session.autoTitle, $Session.sessionId, $Lane, (Split-Path $Dir.path -Leaf), $Dir.path)) {
            if ("$hay" -like "*$f*") { $hit = $true; break }
        }
        if (-not $hit) { return $false }
    }

    if ($script:fProject -and ("$($Dir.path)" -ne $script:fProject)) { return $false }
    if ($script:fLane    -and ("$Lane" -ne $script:fLane))           { return $false }

    # THE BAND. Deliberately the same call Build-InboxRows uses to group the
    # list and Update-Header uses to count the pills, so a chip cannot select a
    # different set from the heading that names it.
    if ($script:fBand.Count -and -not $script:fBand[(Get-InboxBand $Session)]) { return $false }

    if ($script:fLive.Count) {
        # LIVENESS, not state. run / act / new are all "something is holding it";
        # the certain-versus-inferred distinction matters on the row, not here.
        $l = switch (Get-SessionState $Session) {
            'gone'  { 'gone' }
            'run'   { 'live' }
            'act'   { 'live' }
            'new'   { 'live' }
            default { 'notlive' }
        }
        if (-not $script:fLive[$l]) { return $false }
    }

    if ($script:fTick.Count) {
        $t = $(if ($Session.enabled) { 'ticked' } else { 'unticked' })
        if (-not $script:fTick[$t]) { return $false }
    }

    if ($script:fPin.Count) {
        # Two values, like every other dimension. It was one chip in a two-value
        # world: 128 of 143 conversations are pinned -- touching one pins it --
        # so lighting "pinned" selected almost everything and read as broken.
        # The useful half was always the inverse, and it was unreachable.
        $pn = $(if (Test-Pinned $Session) { 'pinned' } else { 'unpinned' })
        if (-not $script:fPin[$pn]) { return $false }
    }

    if ($script:fAge.Count) {
        # The band the tool already understands: recencyDays, the same rule that
        # puts STALE on a row.
        $a = $(if (Test-Stale $Session.lastActive) { 'stale' } else { 'recent' })
        if (-not $script:fAge[$a]) { return $false }
    }

    return $true
}
