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
