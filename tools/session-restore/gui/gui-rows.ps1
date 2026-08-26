#requires -Version 5.1
# ===========================================================================
# THE ROWS
#
# What a row SHOWS. Building both lists, and filling in every cell of both templates.
#
# DOT-SOURCED BY sessions-gui.ps1, into its own scope, AFTER $window, $Pal and
# $ui exist - everything here reads them at CALL time, never at load time.
#
# Read tools/session-restore/CONTEXT.md before changing anything in here. The
# traps in it are not hypothetical: every one of them shipped.
# ===========================================================================

# ---------------------------------------------------------------------------
# THE INBOX
#
# A FLAT list across every project, ordered by what each conversation wants from
# you. Not a second rendering of the tree: the tree answers "what is in this
# project", and no amount of sorting makes a hierarchy answer "who needs me"
# without being read end to end. That is precisely why the NEEDS YOU band had to
# be bolted on beside the tree rather than built into it.
#
# FOUR BANDS, and every conversation is in exactly one:
#
#   NEEDS YOU   it has stopped and cannot continue without you: waiting for
#               input, sitting on a permission dialog, or a blocked background
#               agent. The only band that is an interruption.
#   WORKING     busy. Nothing to do; shown so you can see progress exists.
#   IDLE        at its prompt with nothing pending. You could pick it up.
#   NOT RUNNING recently active but no longer held by a process.
#
# WHAT IS NOT HERE: the other ~100 conversations in the registry. An inbox of
# 117 rows is a list, not an inbox. Stale conversations live in the Projects and
# Restore views, and typing in the search box widens this list to reach them --
# so nothing is unreachable, it is just not in your face.
# ---------------------------------------------------------------------------
$script:InboxBands = @(
    @{ Key = 'needs';   Label = 'NEEDS YOU';   Tip = 'Stopped and waiting on you: a question, a permission dialog, or a blocked agent.' }
    @{ Key = 'working'; Label = 'WORKING';     Tip = 'Busy right now. Nothing for you to do.' }
    @{ Key = 'idle';    Label = 'IDLE';        Tip = 'At its prompt with nothing pending. Yours to pick up.' }
    @{ Key = 'quiet';   Label = 'NOT RUNNING'; Tip = 'Active recently, but no process is holding it now.' }
)

# Minutes matter in an inbox. Get-Age tops out at hours and days because the tree
# is about which conversations exist, not about what just happened.
function Get-Stamp { param($When)
    if (-not $When) { return '' }
    try { $d = ((Get-Date) - [datetime]$When) } catch { return '' }
    if ($d.TotalSeconds -lt 90)  { return 'now' }
    if ($d.TotalMinutes -lt 60)  { return ("{0}m" -f [int]$d.TotalMinutes) }
    if ($d.TotalHours   -lt 24)  { return ("{0}h" -f [int]$d.TotalHours) }
    return ("{0}d" -f [int]$d.TotalDays)
}

# Which band a conversation belongs in. One function, so the bands provably
# partition: every path returns exactly one key, and 'quiet' is the fallback.
function Get-InboxBand { param($Session)
    $cv = Get-Conv $Session
    if (-not $cv) { return 'quiet' }
    # 🪤 SAY THIS OUT LOUD RATHER THAN LETTING THE STALE TEST CATCH IT BELOW.
    # An agent whose needs-claim could not be corroborated is marked stuck AND
    # stale by Resolve-SRSessionState, so the next line would already send it to
    # quiet -- by accident, and only for as long as those two stay coupled. The
    # band that means ACT ON THIS held a 33-day-dead background agent for exactly
    # this kind of implicit reasoning; the guard is worth its two lines.
    if ($cv.Stuck) { return 'quiet' }
    if ($cv.Needs) { return 'needs' }
    $st = "$($cv.State)"
    if ($cv.Stale) { return 'quiet' }
    if ($st -eq 'working' -or $st -eq 'summarising') { return 'working' }
    if ($st -eq 'idle') { return 'idle' }
    if ($st -eq 'waiting') { return 'needs' }
    return 'quiet'
}

function Build-InboxRows {
    $out = New-Object System.Collections.Generic.List[object]
    # Same project ranking the All view sorts by, so 'project' means one thing.
    $script:dirRank = @{}
    for ($i = 0; $i -lt $script:dirs.Count; $i++) { $script:dirRank[[string]$script:dirs[$i].path] = $i }
    # ANY filter widens the inbox, not just the text box. The inbox normally
    # shows only what is running or recently active -- but if you deliberately
    # ask for "not live" or "stale", the honest answer is the conversations that
    # match, not an empty list. Filtering on a dimension whose rows are excluded
    # before the filter even runs is indistinguishable from a broken filter.
    $searching = Test-AnyFilter

    # Collect first, band second. Sorting inside each band needs the whole set.
    $picked = New-Object System.Collections.Generic.List[object]
    $total = 0
    foreach ($d in $script:dirs) {
        # ASSIGN, THEN WRAP. Get-Lanes returns ",@(...)", so @(Get-Lanes $d) is
        # an array of ONE element containing every lane -- and $lane.Name then
        # evaluates to all the lane names at once. The symptom is a row labelled
        # "AlgoTrader / main I7 F2 AN2 I6 ..." with every worktree in the repo
        # concatenated into one project label. Build-Rows does the same two-step
        # for the same reason.
        $lanes = Get-Lanes $d
        foreach ($lane in @($lanes)) {
            foreach ($s in @($lane.Group)) {
                $total++
                $key = "$($s.sessionId)".ToLower()
                $cv  = Get-Conv $s
                $isLive = [bool]($script:running[$key] -or $script:live[$key])
                $fresh  = ($cv -and -not $cv.Stale)
                # The inbox is about what is happening. A search widens it to
                # everything that matches, so an old conversation is findable
                # here rather than only in another view.
                if (-not $isLive -and -not $fresh -and -not $searching) { continue }
                if (-not (Test-RowMatch -Session $s -Dir $d -Lane $lane.Name)) { continue }
                $picked.Add([PSCustomObject]@{
                    S = $s; D = $d; L = $lane
                    Band = (Get-InboxBand $s)
                    Rank = [int]$script:dirRank[[string]$d.path]
                    At = $(if ($s.lastActive) { [datetime]$s.lastActive } else { [datetime]'1970-01-01' })
                })
            }
        }
    }

    $script:matchCount = $picked.Count
    $script:totalCount = $total

    foreach ($band in $script:InboxBands) {
        # WITHIN the band. The bands are not a sort key and cannot be sorted
        # away - they are what the inbox is - so the stack orders the rows
        # inside each one and NEEDS YOU stays first whatever WHEN is set to.
        $inBand = @(Sort-Picked @($picked | Where-Object { $_.Band -eq $band.Key }))
        if (-not $inBand.Count) { continue }
        $head = New-Row 'band' ("band|" + $band.Key) $null $null $null
        $head.Band = $band.Key
        $head.Name = $band.Label
        $head.Counts = "$($inBand.Count)"
        $head.ConvTip = $band.Tip
        $out.Add($head)
        foreach ($p in $inBand) {
            $r = New-Row 'session' ("$($p.D.path)|$($p.L.Name)|$($p.S.sessionId)") $p.D $p.L $p.S
            $r.Band = $band.Key
            $out.Add($r)
        }
    }
    return ,$out
}

# Everything an inbox row shows. Separate from Update-RowStatic / Update-RowConv
# on purpose: those fill the TREE's cells, and the two views share no bound
# property, so neither can silently redecorate the other.
function Update-InboxRow { param($Row)
    if ($Row.Kind -eq 'band') {
        $Row.RowHeight = 30
        $Row.Indent = New-Object System.Windows.Thickness 22, 10, 0, 0
        $Row.NameBrush = $Pal.TextMid
        $Row.NameWeight = $FW_Semi
        $Row.NameSize = 10.5
        $Row.CountsBrush = $Pal.TextLow
        $Row.CountsVisibility = $V_Show
        $Row.StampBrush = $Pal.TextDim
        return
    }

    $s = $Row.Session
    $key = "$($s.sessionId)".ToLower()
    $cv = Get-Conv $s
    $Row.RowHeight = 30
    $Row.Indent = New-Object System.Windows.Thickness 22, 0, 0, 0
    $Row.CountsVisibility = $V_Hide
    $Row.NameSize = 12.5
    $Row.Name = "$(Get-SessionTitle $s $Row.Dir)"
    # Same rule as the roster: a generated name leans, a chosen one stands up.
    $Row.NameStyle = $(if (Test-DerivedTitle $s) { $Italic } else { $Upright })

    # The project as a LABEL. A worktree lane is named after the worktree, and
    # that distinction matters more than the repo name when two lanes of the same
    # repo are both live.
    $proj = Split-Path $Row.Dir.path -Leaf
    if ($Row.Lane -and $Row.Lane.Name -and $Row.Lane.Name -ne 'main') { $proj = "$proj / $($Row.Lane.Name)" }
    $Row.Project = $proj
    $Row.ProjectVisibility = $V_Show

    $moved = Test-Moved $s
    $Row.MovedVisibility = $(if ($moved) { $V_Show } else { $V_Hide })
    $needs = [bool]($cv -and $cv.Needs)
    # Bold for "wants you", and also for "has said something since you looked" -
    # the same weight for the same reason, which is that both are unfinished
    # business. Read and quiet is the only combination that is not.
    $Row.NameWeight = $(if ($needs -or $moved) { $FW_Semi } else { $FW_Normal })
    $Row.NameBrush  = $(if ($needs) { $Pal.TextMax } elseif ($Row.Band -eq 'quiet') { $Pal.TextMid } else { $Pal.TextHigh })

    # The state glyph, from the same vocabulary the tree uses.
    $Row.ConvGeometry = $null
    $Row.ConvGlyphVisibility = $V_Hide
    $Row.ConvBrush = $Pal.TextDim
    if ($cv) {
        $geom = switch ("$($cv.State)") {
            'waiting'     { $GlyphWaiting }
            'working'     { $GlyphWorking }
            'summarising' { $GlyphSummarising }
            default       { $null }
        }
        if ($geom) {
            $Row.ConvGeometry = $geom
            $Row.ConvGlyphVisibility = $V_Show
            $Row.ConvBrush = $(if ($needs) { $Pal.TextMax } elseif ($cv.Stale) { $Pal.TextDim } else { $Pal.TextMid })
        }
        $Row.ConvTip = "$($cv.State)  -  $($cv.Detail)"
    }

    # THE BODY: what it last said. Falling back, in order, to what it is doing
    # right now, and then to why there is nothing to show -- never to a blank
    # cell, which reads as a bug rather than as an absence.
    $sd = $script:said[$key]
    $text = ''; $tip = ''
    if ($sd -and $sd.Said) {
        $text = $sd.Said
        $tip  = $sd.Said
        if ($sd.Pending) { $tip = $sd.Said + "`n`nnow running:  " + $sd.Pending }
    } elseif ($sd -and $sd.Pending) {
        # Mid-tool-chain with no prose in the tail. What it is DOING is the
        # honest answer, and for a session sitting on a permission dialog it is
        # the thing being asked about.
        $text = $sd.Pending
        $tip  = "No prose in the recent tail. This is the tool call it is on."
    } elseif ($cv -and $cv.Detail) {
        $text = "$($cv.Detail)"
        $tip  = 'Nothing read from the transcript yet.'
    }
    if ($needs -and $cv -and $cv.Detail -match 'dialog') {
        $text = $(if ($sd -and $sd.Pending) { "wants to run:  $($sd.Pending)" } else { 'a dialog is open, it wants an answer' })
        $tip  = 'Answer it in the terminal: a dialog wants a click, not a sentence.'
    }
    # YOUR NOTE OUTRANKS THE TRANSCRIPT. What it last said is a machine's guess
    # at what matters; a note is your own answer to "where were we", and it is
    # the thing that is actually missing when you come back to thirteen tabs.
    # The last-said line is not lost - it moves into the tooltip.
    $note = Get-SessionNote $s
    if ($note) {
        $tip  = $(if ($text) { "your note:  $note`n`nit last said:  $text" } else { "your note:  $note" })
        $text = $note
    }
    $Row.Said = $text
    $Row.SaidTip = $tip
    $Row.SaidVisibility = $(if ($text) { $V_Show } else { $V_Hide })
    # A note is yours, so it is brighter than anything the tool inferred.
    $Row.SaidBrush = $(if ($note) { $Pal.TextHigh } elseif ($needs) { $Pal.TextHigh } elseif ($Row.Band -eq 'quiet') { $Pal.TextDim } else { $Pal.TextMid })

    $when = $(if ($sd -and $sd.At) { $sd.At } elseif ($cv -and $cv.LastActive) { $cv.LastActive } else { $s.lastActive })
    $Row.Stamp = Get-Stamp $when
    $Row.StampBrush = $(if ($needs) { $Pal.TextMid } else { $Pal.TextDim })

    # The action. Increment 2 turns this into a real jump to the terminal tab;
    # until then it opens the conversation the way the tree's Open does, so the
    # button is never a promise the tool cannot keep.
    $a = $script:agents[$key]
    $Row.ActionVisibility = $V_Show
    if ($a -and $a.Kind -ne 'interactive') {
        $Row.JumpLabel = 'agent'
        $Row.CanJump = $false
        $Row.JumpTip = 'A background agent has no terminal of its own, so there is nothing to jump to and nothing to type into.'
    } elseif ($script:running[$key] -or $script:live[$key]) {
        $Row.JumpLabel = 'Go to'
        $Row.CanJump = $true
        $Row.JumpTip = 'Bring this conversation''s terminal to the front.'
    } else {
        $Row.JumpLabel = 'Open'
        $Row.CanJump = (Test-RowLaunchable $s)
        $Row.JumpTip = 'Open this conversation in a new terminal tab.'
    }
}

# Everything about a row that depends on the TICKS: the checkbox, the counts, the
# pin, the name's weight and colour. No file access, so this can run on every
# click without the list feeling heavy.
function Update-RowTicks { param($Row)
    if ($Row.Kind -ne 'session') { return }
    $s = $Row.Session
    $Row.Ticked = [bool]$s.enabled
    $Row.PinVisibility = $(if (Test-Pinned $s) { $V_Show } else { $V_Hide })
    $Row.PinBrush = $Pal.TextDim
    $Row.AgeBrush = $(if (Test-Stale $s.lastActive) { $Pal.TextMid } else { $Pal.TextDim })
    $Row.TickTip = "Reopen this conversation at the next logon. Ticking pins it, so the hourly roll leaves it alone. It does NOT open anything now. Shift-click to tick a range."
    Update-RowName $Row
}

# A conversation's name is where the value ramp does most of its work, and it
# depends on the tick AND on the live probe -- so it is computed in one place
# and called from both refresh paths rather than half-set by each.
#
# Brightest to dimmest, most important first:
#   live now      TextMax   the thing you are most likely to be looking for
#   ticked        TextHigh  comes back at logon
#   ticked, stale TextMid   comes back, but has not been touched in a while
#   not ticked    TextLow   known, not coming back
#   project off   TextDim   its project is switched off, so the tick is moot
#   gone          TextDim + STRUCK THROUGH -- not merely quiet: unlaunchable.
function Update-RowName { param($Row)
    if ($Row.Kind -ne 'session') { return }
    $d = $Row.Dir; $s = $Row.Session

    # Slant first, and outside the 'gone' return below: a conversation whose
    # transcript has been deleted still shows the last name it was known by, and
    # whether that name was chosen or generated is exactly as true then as now.
    $Row.NameStyle = $(if (Test-DerivedTitle $s) { $Italic } else { $Upright })

    $st = Get-SessionState $s
    if ($st -eq 'gone') {
        $Row.NameBrush = $Pal.TextDim
        $Row.NameDecorations = $Strike
        return
    }
    $Row.NameDecorations = $null
    $Row.NameBrush =
        if (-not $d.enabled)             { $Pal.TextDim }
        elseif ($st -in @('run','act','new')) { $Pal.TextMax }
        elseif (-not $s.enabled)         { $Pal.TextLow }
        elseif (Test-Stale $s.lastActive){ $Pal.TextMid }
        else                             { $Pal.TextHigh }
}

# Everything about a row that depends on the PROBES and the clock: the live mark,
# the notes, whether OPEN is available.
function Update-RowLive { param($Row)
    switch ($Row.Kind) {
        'session' {
            $d = $Row.Dir; $s = $Row.Session
            $st = Get-SessionState $s
            # Three channels at once, because one grey against another is not
            # enough on its own: CASE and WEIGHT (LIVE bold-upper is certain,
            # live regular-lower is inferred), the DOT (filled = a process holds
            # the id, hollow = only the transcript moved), and VALUE.
            $Row.StateDecorations = $null
            $Row.DotVisibility = $V_Show
            $Row.GoneMarkVisibility = $V_Hide
            switch ($st) {
                'run'  { $Row.State = 'LIVE'; $Row.StateBrush = $Pal.TextMax; $Row.StateWeight = $FW_Semi
                         $Row.DotFill = $Pal.TextMax; $Row.DotStroke = $Pal.TextMax
                         $Row.StateTip = 'A running claude.exe carries this id on its command line. Certain. Filled mark, upper case.' }
                'act'  { $Row.State = 'live'; $Row.StateBrush = $Pal.TextLow; $Row.StateWeight = $FW_Normal
                         $Row.DotFill = $Clear; $Row.DotStroke = $Pal.TextLow
                         $Row.StateTip = "Its transcript was written in the last $SR_LiveWindowMinutes minutes. Inferred, not certain. Hollow mark, lower case." }
                'new'  { $Row.State = '..';   $Row.StateBrush = $Pal.TextLow; $Row.StateWeight = $FW_Normal
                         $Row.DotFill = $Clear; $Row.DotStroke = $Pal.TextDim
                         $Row.StateTip = 'Just launched from here. claude takes a few seconds to appear in the process table.' }
                # Four independent signals, and the primary one is the drawn X,
                # NOT a line: a struck-through word at 11px is exactly the mark a
                # reviewer already mistook a mono hex id for. The strikethrough on
                # the NAME stays - measured 100% contiguous across the whole run,
                # unmistakable at 12.5px - but it is now corroboration, not the
                # thing GONE rests on.
                'gone' { $Row.State = 'GONE'; $Row.StateBrush = $Pal.TextMid; $Row.StateWeight = $FW_Semi
                         $Row.StateDecorations = $null
                         $Row.DotVisibility = $V_Hide
                         $Row.GoneMarkVisibility = $V_Show
                         $Row.StateTip = 'Its transcript is no longer on disk. It can NEVER be launched, and the roll will not spend a lane budget on it. Marked four ways: the X, the word GONE, the struck-through name, and a dead Open button.' }
                default { $Row.State = ''; $Row.StateBrush = $Pal.TextDim; $Row.StateWeight = $FW_Normal
                          $Row.DotVisibility = $V_Hide
                          $Row.StateTip = 'No evidence it is open - which is not the same as closed. A bare claude that resumed later carries no id, and an idle session writes nothing.' }
            }
            $note = ''
            # Spelled out rather than left to a mark: without colour, "gone" has
            # to say what it means somewhere the operator can read it.
            if ($st -eq 'gone') { $note = 'cannot be launched' }
            elseif ($s.enabled -and -not $d.enabled) { $note = 'project off - will NOT reopen' }
            elseif ($s.enabled -and (Test-Stale $s.lastActive)) { $note = 'STALE' }
            $Row.Note = $note
            $Row.NoteBrush = $(if ($st -eq 'gone') { $Pal.TextMid } else { $Pal.TextLow })
            $Row.CanLaunch = (Test-RowLaunchable $s)
            $Row.LaunchTip = $(if ($Row.CanLaunch) { 'Open this conversation NOW, in its own tab, whatever its tick says.' } else { 'Nothing to open: it already looks live, or its transcript is gone.' })
            Update-RowName $Row
        }
    }
}

# ---------------------------------------------------------------------------
# DOING. What the conversation is actually doing, from _common.ps1
# Get-SRConversationState.
#
# THIS IS NOT LIVENESS AND MUST NEVER READ AS IT. Update-RowLive above answers
# "is a process holding this conversation"; this answers "what is that process
# doing". They are independent: a conversation can be LIVE and waiting, LIVE and
# working, or not live at all and still carry the last state it was seen in.
# They are kept apart in four ways at once -- separate view-model properties so
# the template cannot cross them, a separate column behind its own rule, a
# proportional face against the liveness column's mono, and a vocabulary of
# stroke glyphs against its dots and X.
#
# now versus then. Get-SRConversationState returns the LAST state a conversation
# was seen in plus Stale. Measured 2026-08-22 over all 119 conversations, 113 are
# stale -- so rendering only what is CURRENT would leave 113 rows saying nothing
# and would throw away the very distinction that function exists to keep. The
# word is therefore always the last-known state, and staleness is carried by the
# literal word "was" plus a drop to TextLow. Six bright rows against 113 dim ones
# is exactly the thing the operator asked to be able to see.
# ---------------------------------------------------------------------------
function Update-RowConv { param($Row)
    switch ($Row.Kind) {
        'session' {
            $s = $Row.Session
            # $cv, NOT $c. PowerShell variable names are CASE-INSENSITIVE, so a
            # local $c is the same variable as the palette $C -- assigning to it
            # here replaced the brush table with a conversation-state object for
            # the rest of this function, every $Pal.TextHigh came back $null, and a
            # TextBlock with a null Foreground draws NOTHING. The column was
            # populated and invisible: 'working' was in the row, correctly, and
            # the screen was blank. Only the rollup branch rendered, because it
            # never declares a $c.
            $cv = Get-Conv $s
            $Row.ConvWeight = $FW_Normal
            $Row.ConvGeometry = $null
            $Row.ConvGlyphVisibility = $V_Hide
            $Row.LastPrompt = ''
            $Row.Subtitle = ''
            $Row.SubtitleVisibility = $V_Hide

            if (-not $cv) {
                $Row.Conv = ''
                $Row.ConvBrush = $Pal.TextDim
                $Row.ConvTip = 'Not read yet. The state of every conversation is read on the background pass, alongside the liveness probe.'
                return
            }

            $Row.LastPrompt = "$($cv.LastPrompt)"
            # Only where it earns its place: a conversation with a real title
            # already says what it is, and repeating the prompt beside it is
            # noise. An untitled one says nothing at all without this.
            $named = ("$($Row.Name)".Trim() -and "$($Row.Name)" -notmatch '^\(untitled\)$')
            if (-not $named -and $cv.LastPrompt) {
                $sub = ($cv.LastPrompt -replace '\s+', ' ').Trim()
                if ($sub.Length -gt 96) { $sub = $sub.Substring(0, 93) + '...' }
                $Row.Subtitle = $sub
                $Row.SubtitleVisibility = $V_Show
            } else {
                $Row.Subtitle = ''
                $Row.SubtitleVisibility = $V_Hide
            }
            # 'idle' now comes from claude and means something specific: at its
            # prompt with nothing pending. That is NOT the same as 'waiting',
            # which means it is actively asking you for something.
            $word = switch ("$($cv.State)") {
                'waiting'     { 'waiting' }
                'working'     { 'working' }
                'summarising' { 'summarising' }
                'idle'        { 'idle' }
                default       { '' }
            }
            $geom = switch ("$($cv.State)") {
                'waiting'     { $GlyphWaiting }
                'working'     { $GlyphWorking }
                'summarising' { $GlyphSummarising }
                'idle'        { $null }
                default       { $null }
            }

            if (-not $word) {
                # Blank, exactly as an unknown LIVENESS is blank: no evidence is
                # not a state, and inventing a word for it would be a lie with a
                # glyph on it.
                $Row.Conv = ''
                $Row.ConvBrush = $Pal.TextDim
            } elseif ($cv.Stale) {
                $Row.Conv = 'was ' + $word
                $Row.ConvBrush = $Pal.TextLow
                $Row.ConvGeometry = $geom
                $Row.ConvGlyphVisibility = $V_Show
            } else {
                $Row.Conv = $word
                $Row.ConvGeometry = $geom
                $Row.ConvGlyphVisibility = $V_Show
                # Waiting is the loudest thing this column can say: it is the one
                # state that is asking the operator for something.
                if ($cv.Needs) {
                    # It is asking for something RIGHT NOW -- input, or an answer
                    # to a dialog. Nothing else on this screen outranks that.
                    $Row.ConvBrush = $Pal.TextMax; $Row.ConvWeight = $FW_Semi
                } elseif ("$($cv.State)" -eq 'idle') {
                    # At its prompt but not asking. Present, not urgent.
                    $Row.ConvBrush = $Pal.TextMid
                } else {
                    $Row.ConvBrush = $Pal.TextHigh
                }
            }

            $tip = "DOING (not the same question as OPEN?): $($cv.Detail)."
            if ($cv.Stale) { $tip += "  Nothing has moved for at least $SR_LiveWindowMinutes min, so that is the LAST state it was seen in, not a current one." }
            if ($cv.Mode)  { $tip += "`npermission mode: $($cv.Mode)" }
            if ($cv.Title) { $tip += "`ntranscript title: $($cv.Title)" }
            if ($cv.LastPrompt) { $tip += "`nlast prompt: $($cv.LastPrompt)" }
            $Row.ConvTip = $tip
        }
        default {
            # Nothing but conversations reaches this function now. The rollup
            # that used to live here - "3 waiting" on a folded project - went
            # with the rows it was summarising; the same fact is on the band
            # chips and the summary pills, counted once.
            $Row.Conv = ''
            $Row.ConvBrush = $Pal.TextDim
            $Row.ConvGeometry = $null
            $Row.ConvGlyphVisibility = $V_Hide
            $Row.ConvTip = ''
        }
    }
}

# The parts that never change once a row is built.
function Update-RowStatic { param($Row)
    switch ($Row.Kind) {
        'project' {
            $Row.RowHeight = 32
            $Row.Indent = New-Object System.Windows.Thickness (8, 6, 0, 0)
            $Row.Name = Split-Path $Row.Dir.path -Leaf
            $Row.NameWeight = $FW_Semi
            $Row.NameSize = 13
            $Row.NameBrush = $Pal.TextHigh
            $Row.FoldVisibility = $V_Show
            $Row.FoldAngle = $(if ($script:fold[[string]$Row.Dir.path]) { $FoldAngleClosed } else { $FoldAngleOpen })
            $Row.TickVisibility = $V_Hide
            $Row.ActionVisibility = $V_Hide
            $Row.MoreVisibility = $V_Hide
            $Row.PinVisibility = $V_Hide
            $Row.DotVisibility = $V_Hide
            $Row.GoneMarkVisibility = $V_Hide
            $Row.ConvGlyphVisibility = $V_Hide
            $Row.IdShort = ''; $Row.Age = ''; $Row.State = ''; $Row.Conv = ''
            $Row.Project = ''
            Update-GroupCaption $Row
            $Row.NameTip = $Row.Dir.path
        }
        'lane' {
            $Row.RowHeight = 26
            $Row.Indent = New-Object System.Windows.Thickness (26, 0, 0, 0)
            $Row.Name = $(if ($Row.Lane -and $Row.Lane.Name) { "$($Row.Lane.Name)" } else { 'main' })
            $Row.NameWeight = $FW_Normal
            $Row.NameSize = 11.5
            $Row.NameBrush = $Pal.TextMid
            $Row.FoldVisibility = $V_Show
            $Row.FoldAngle = $(if ($script:fold["$($Row.Dir.path)|$($Row.Lane.Name)"]) { $FoldAngleClosed } else { $FoldAngleOpen })
            $Row.TickVisibility = $V_Hide
            $Row.ActionVisibility = $V_Hide
            $Row.MoreVisibility = $V_Hide
            $Row.PinVisibility = $V_Hide
            $Row.DotVisibility = $V_Hide
            $Row.GoneMarkVisibility = $V_Hide
            $Row.ConvGlyphVisibility = $V_Hide
            $Row.IdShort = ''; $Row.Age = ''; $Row.State = ''; $Row.Conv = ''
            $Row.Project = ''
            Update-GroupCaption $Row
        }
        'session' {
            $Row.RowHeight = 34
            # INDENTED UNDER ITS HEADER. The hierarchy is back, so the indent is
            # back with it -- but only as deep as the header it actually sits
            # under, which is why Depth is set while building rather than assumed:
            # a single-lane project has no lane row, and pretending otherwise
            # would leave a column of conversations floating under nothing.
            $Row.Indent = New-Object System.Windows.Thickness ((10 + 16 * [int]$Row.Depth), 0, 0, 0)
            $Row.Name = Get-SessionTitle $Row.Session $Row.Dir
            $Row.NameWeight = $FW_Normal
            $Row.NameSize = 13.5
            $Row.FoldVisibility = $V_Hide
            $Row.TickVisibility = $V_Show
            $Row.MoreVisibility = $V_Hide
            $Row.ActionVisibility = $V_Show
            $Row.LaunchLabel = 'Open'
            $Row.IdShort = "$($Row.Session.sessionId)".Substring(0, 8)
            # WHERE THE ID COLUMN WENT. Eight hex characters are worth having and
            # are not worth 88 pixels on every row; the footer carries the path
            # for the selected row and this carries the id for any of them.
            $Row.NameTip = "{0}`n{1}" -f $Row.Session.sessionId, (Get-SessionCwd $Row.Session $Row.Dir)
            $Row.MovedVisibility = $(if (Test-Moved $Row.Session) { $V_Show } else { $V_Hide })
            $Row.Age = Get-Age $Row.Session.lastActive
            $Row.Counts = ''
            # PROJECT / LANE, which used to be two rows of hierarchy above this
            # one. Same string the inbox row uses, so the two views name a
            # conversation's home identically.
            $lane = $(if ($Row.Lane) { "$($Row.Lane.Name)" } else { 'main' })
            $proj = Split-Path $Row.Dir.path -Leaf
            $Row.Project = $(if ($lane -and $lane -ne 'main') { "$proj / $lane" } else { $proj })
        }
        'more' {
            $Row.RowHeight = 40
            $Row.Indent = New-Object System.Windows.Thickness (10, 0, 0, 0)
            $Row.TickVisibility = $V_Hide
            $Row.ActionVisibility = $V_Hide
            $Row.MoreVisibility = $V_Show
            $Row.PinVisibility = $V_Hide
            $Row.FoldVisibility = $V_Hide
            $Row.NameBrush = $Pal.TextDim
            $Row.NameWeight = $FW_Normal
            $Row.NameSize = 12.5
            $Row.IdShort = ''
            $Row.Age = ''
            $Row.Project = ''
            $Row.State = ''
            $Row.Conv = ''
            $Row.DotVisibility = $V_Hide
            $Row.GoneMarkVisibility = $V_Hide
            $Row.ConvGlyphVisibility = $V_Hide
            Update-MoreRow $Row
        }
    }
}

# WHAT A GROUP HEADER SAYS, and the one thing it must never leave out.
#
# 🔴 A TICK INSIDE A SWITCHED-OFF PROJECT CANNOT FIRE. On 2026-08-24 the operator
# had 89 pinned conversations under a project whose `enabled` was false, and not a
# row on the screen said so; none of them came back at logon. The count is not
# decoration here -- "12 - 4 armed" and "12 - 4 ticked, project OFF" are different
# facts about tomorrow morning, and the header is the only place either can be said.
function Update-GroupCaption { param($Row)
    $n = [int]$Row.GroupTotal
    $t = [int]$Row.TickCount
    $off = ($Row.Kind -eq 'project' -and $Row.Dir -and -not $Row.Dir.enabled)
    $bits = @("$n")
    if ($t) { $bits += $(if ($off) { "$t ticked, PROJECT OFF" } else { "$t armed" }) }
    elseif ($off) { $bits += 'project off' }
    # 🪤 ASCII ONLY. A middle dot here rendered as "93 Â· 9 armed": PowerShell 5.1
    # reads a BOM-less UTF-8 file as ANSI, so every non-ASCII character in a
    # string literal arrives mojibaked. The comments above survive because
    # nothing prints them.
    $Row.Counts = ($bits -join '  -  ')
    $Row.CountsVisibility = $V_Show
    $Row.CountsBrush = $(if ($off -and $t) { $Pal.TextMax } else { $Pal.TextLow })
}

# The age window, said out loud. A list that quietly stops at seven days is
# indistinguishable from a list that has lost things.
function Update-MoreRow { param($Row)
    if ($Row.Kind -ne 'more') { return }
    if ($script:showOlder) {
        $Row.Name = "showing everything, including conversations older than $([int]$script:listDays) days"
        $Row.MoreLabel = 'Show less'
        $Row.MoreTip = "Go back to the last $([int]$script:listDays) days."
    } else {
        $Row.Name = "{0} older conversation{1} not shown" -f $script:olderCount, $(if ($script:olderCount -eq 1) { '' } else { 's' })
        $Row.MoreLabel = 'Show older'
        $Row.MoreTip = "The list is the last $([int]$script:listDays) days. These are older than that and nothing is holding them. Searching reaches them without this."
    }
}

function Update-AllTicks {
    foreach ($r in $script:rows) { Update-RowTicks $r }
    Update-Header
}
# Liveness and state land on the same background pass, so they refresh together
# -- but they are computed by two functions and written to two sets of
# properties, because they are two different questions and the moment they share
# a code path is the moment one starts standing in for the other.
function Update-AllLive {
    foreach ($r in $script:rows) { Update-RowLive $r; Update-RowConv $r }
    Update-Header
    Update-NeedsBand
    Update-Selection
    # A probe means something may have moved. The seen gate is only worth having
    # if it SHUTS BY ITSELF the moment a session speaks - nobody is going to
    # reselect a row to find out whether their half-typed reply is still aimed
    # at the right thing.
    if ($script:readOpen -and $script:readSession) { Update-SendState }
    Update-TrayBadge
    Update-Toasts
}

# The taskbar button, flashed until the window is looked at. FLASHW_TIMERNOFG
# keeps it flashing until the window comes to the FOREGROUND rather than for a
# fixed count, so it is still flashing when the operator comes back from
# somewhere else -- which is the only case where it is any use.
#
# It is a flash, not a foreground steal. Windows would refuse a foreground steal
# from a background process anyway, and a window that jumps in front of what
# somebody is typing into is a worse bug than the one it is solving.
if (-not ('SRGui.Flash' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
namespace SRGui
{
    public static class Flash
    {
        [StructLayout(LayoutKind.Sequential)]
        private struct FLASHWINFO
        {
            public uint cbSize; public IntPtr hwnd; public uint dwFlags;
            public uint uCount; public uint dwTimeout;
        }
        [DllImport("user32.dll")] private static extern bool FlashWindowEx(ref FLASHWINFO pwfi);

        private const uint FLASHW_TRAY = 2;          // the taskbar button only
        private const uint FLASHW_TIMERNOFG = 12;    // until it comes to the foreground
        private const uint FLASHW_STOP = 0;

        public static void Start(IntPtr hwnd)
        {
            FLASHWINFO fi = new FLASHWINFO();
            fi.cbSize = (uint)Marshal.SizeOf(typeof(FLASHWINFO));
            fi.hwnd = hwnd;
            fi.dwFlags = FLASHW_TRAY | FLASHW_TIMERNOFG;
            fi.uCount = 0;
            fi.dwTimeout = 0;
            FlashWindowEx(ref fi);
        }
        public static void Stop(IntPtr hwnd)
        {
            FLASHWINFO fi = new FLASHWINFO();
            fi.cbSize = (uint)Marshal.SizeOf(typeof(FLASHWINFO));
            fi.hwnd = hwnd;
            fi.dwFlags = FLASHW_STOP;
            FlashWindowEx(ref fi);
        }
    }
}
'@
}
