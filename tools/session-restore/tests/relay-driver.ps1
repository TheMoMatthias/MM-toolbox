
# ===========================================================================
# THE RELAY, END TO END, AGAINST A LIVE CONSOLE.
#
# This is the assertion that has been missing since the relay shipped. Both
# halves were proven, separately and honestly:
#
#   the parser     against captured screen text (tests\state-driver.ps1)
#   the key send   against a real menu on 2026-08-24, answering "BRAVO",
#                  deliberately NOT the default option
#
# Read the live screen -> find the highlight -> work out the distance -> send
# the arrows -> commit had never run as ONE sequence under test, and every
# earlier attempt to prove it drove a real claude session and fell over on the
# harness rather than on the code: a stray ENTER left in the input buffer
# answered a later menu, a rewritten boot script dropped the CLAUDE_CODE_*
# scrub so there was no transcript at all, quoting errors. Six goes, no answer.
#
# So drive a REPLICA instead. tests\menu-replica.ps1 paints the same characters
# claude paints, in a real console, and moves the same highlight with the same
# keys -- so everything between this test and the answer is the shipped code:
# ReadConsoleOutputCharacterW reading a real screen buffer, the real parser,
# the real WriteConsoleInputW. What it does not prove is that claude's menu
# still looks like the capture; that is what the captured-text fixtures are
# for, and they share the same lines.
#
# THE ONE OUTCOME THAT MATTERS is that a NON-DEFAULT option commits. A relay
# that always answers option 1 passes any test that only asks "did something
# get answered", and answers the wrong question every time.
# ===========================================================================

$ErrorActionPreference = 'Stop'

$fails = 0
function Fail { param($m) Write-Host "  FAIL  $m" -ForegroundColor Red; $script:fails++ }
function Pass { param($m) Write-Host "  ok    $m" -ForegroundColor Green }
function Note { param($m) Write-Host "        $m" -ForegroundColor DarkGray }

# $SR_Root, not $here. The harness sets $here to lib\ (where _common.ps1 now
# lives) and tests\ is a sibling of lib\, not a child of it.
$replica = Join-Path $SR_Root 'tests\menu-replica.ps1'
if (-not (Test-Path -LiteralPath $replica)) {
    Fail "menu-replica.ps1 is missing from $(Join-Path $SR_Root 'tests')"
    Write-Host ''
    Write-Host '1 FAILURE(S)' -ForegroundColor Red
    exit 1
}

$relayTmp = Join-Path $here ('.state\relay-' + [Guid]::NewGuid().ToString('N').Substring(0, 8))
$null = New-Item -ItemType Directory -Path $relayTmp -Force

# Every replica this run started, so the finally can be sure none is left on the
# operator's desktop even if an assertion throws.
$started = New-Object System.Collections.Generic.List[object]

function Start-Replica {
    param([int]$StartCursor, [switch]$Multi, [string]$StatusLine = '')
    $outFile = Join-Path $relayTmp ('answer-' + [Guid]::NewGuid().ToString('N').Substring(0, 6) + '.txt')
    $extra = @()
    if ($Multi) { $extra += '-Multi' }
    # 🪤 QUOTED, because -ArgumentList joins this array with spaces and quotes
    # NOTHING. Passed bare, a status line with spaces arrives as a dozen
    # positional arguments, the replica fails to bind them and never paints -
    # which surfaced as "never showed a menu" and looked like a screen-reading
    # problem rather than an argument-passing one.
    if ($StatusLine) { $extra += @('-StatusLine', ('"' + $StatusLine + '"')) }
    # MINIMIZED, NOT HIDDEN. -WindowStyle Hidden gives the process no console
    # window, and while the screen BUFFER still exists, the point of this test is
    # to read what a real terminal is showing. Minimized keeps a real console and
    # keeps it off the operator's screen.
    $p = Start-Process -FilePath 'powershell.exe' -PassThru -WindowStyle Minimized -ArgumentList (@(
        '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $replica,
        '-Out', $outFile, '-Cursor', "$StartCursor", '-TimeoutSeconds', '180') + $extra)
    $started.Add($p)
    return [PSCustomObject]@{ Proc = $p; Out = $outFile }
}

# The menu takes a moment to paint. Poll for it rather than sleeping a guess:
# a fixed sleep is either slow or flaky, and on a loaded machine it is both.
function Wait-ForMenu {
    # 🪤 GENEROUS ON PURPOSE, AND IT COSTS NOTHING WHEN IT IS NOT NEEDED. This
    # returns the instant a menu is readable, so the budget only matters on a
    # machine that is busy -- and on a busy one it matters a lot: each attempt is
    # a Get-SRScreenText, which spawns a child process with its own 3-second
    # budget and now retries once, so a single attempt can take six seconds
    # before the replica has even finished painting. At 15 s the whole suite
    # failed with "no menu was ever read" the first time the operator's own work
    # got going alongside it -- eleven live sessions and two CI runners.
    #
    # A test that passes on an idle machine and fails on a working one is a test
    # about the machine.
    param([int]$ProcessId, [int]$TimeoutMs = 45000)
    $stop = (Get-Date).AddMilliseconds($TimeoutMs)
    while ((Get-Date) -lt $stop) {
        $seen = Get-SRScreenQuestion -ProcessId $ProcessId
        if ($seen -and $seen.Options.Count -ge 2) { return $seen }
        Start-Sleep -Milliseconds 250
    }
    return $null
}

function Wait-ForAnswer {
    param([object]$Proc, [string]$OutFile, [int]$TimeoutMs = 30000)
    $stop = (Get-Date).AddMilliseconds($TimeoutMs)
    while ((Get-Date) -lt $stop) {
        if (Test-Path -LiteralPath $OutFile) {
            # Written in one call, but read defensively anyway: a zero-byte read
            # of a file mid-write would look like a wrong answer.
            $txt = ''
            try { $txt = [System.IO.File]::ReadAllText($OutFile) } catch { }
            if ("$txt".Trim()) { return "$txt".Trim() }
        }
        if ($Proc.HasExited -and -not (Test-Path -LiteralPath $OutFile)) { return '(exited without answering)' }
        Start-Sleep -Milliseconds 150
    }
    return '(no answer)'
}

try {
    # --- 1. a live console, read and parsed --------------------------------
    Write-Host ''
    Write-Host '--- reading a menu off a live console ---'
    $r1 = Start-Replica -StartCursor 0
    $seen = Wait-ForMenu -ProcessId $r1.Proc.Id
    if (-not $seen) {
        Fail 'no menu was ever read off the replica console - the screen read is not working here'
    } else {
        Pass "the live screen parsed into $($seen.Options.Count) option(s)"
        if ($seen.Options.Count -ne 5) { Fail "expected 5 options, including the two the TUI adds; got $($seen.Options.Count)" }
        else { Pass 'including Type something and Chat about this, which are in no transcript' }
        if ("$($seen.Question)" -notlike '*four migrations*') { Fail "the question read as '$($seen.Question)'" }
        else { Pass 'the question text came back off the buffer, without its box-drawing' }
        if ($seen.CursorAt -ne 0) { Fail "the highlight read as option $($seen.CursorAt + 1), expected 1" }
        else { Pass 'the highlight was read from the screen, not assumed' }

        # --- 2. THE WHOLE POINT: a NON-DEFAULT option commits --------------
        Write-Host ''
        Write-Host '--- answering it, with an option that is not the default ---'
        $why = Invoke-SRAnswerOnScreen -ProcessId ([int]$r1.Proc.Id) -Index 2 -Who 'replica'
        if ($why) { Fail "the relay refused to answer: $why" }
        else {
            $got = Wait-ForAnswer -Proc $r1.Proc -OutFile $r1.Out
            if ($got -like '3|Re-apply only 267/269*') { Pass "option 3 committed, two rows down from the highlight: '$got'" }
            else { Fail "the console committed '$got', expected option 3 - the relay answered the WRONG question" }
        }
    }

    # --- 3. UPWARDS, from a highlight that is not where a fresh menu opens --
    # The reason the screen is read at all. A menu the operator has already
    # arrowed through opens nowhere in particular, and moving DOWN from an
    # assumed option 1 would land past the end.
    Write-Host ''
    Write-Host '--- and from a highlight the operator has already moved ---'
    $r2 = Start-Replica -StartCursor 3
    $seen2 = Wait-ForMenu -ProcessId $r2.Proc.Id
    if (-not $seen2) {
        Fail 'the second replica never showed a menu'
    } elseif ($seen2.CursorAt -ne 3) {
        Fail "the highlight read as option $($seen2.CursorAt + 1), expected 4 - a moved cursor is not being seen"
    } else {
        Pass 'a highlight already on option 4 is read as option 4'
        $why2 = Invoke-SRAnswerOnScreen -ProcessId ([int]$r2.Proc.Id) -Index 1 -Who 'replica'
        if ($why2) { Fail "the relay refused to answer upwards: $why2" }
        else {
            $got2 = Wait-ForAnswer -Proc $r2.Proc -OutFile $r2.Out
            if ($got2 -like '2|Re-apply all four now*') { Pass "option 2 committed, three rows UP: '$got2'" }
            else { Fail "the console committed '$got2', expected option 2" }
        }
    }

    # --- 4. it refuses rather than guessing --------------------------------
    # A console with no menu on it must not be arrowed into. DOWN-DOWN-ENTER at
    # a shell prompt is a command nobody typed.
    Write-Host ''
    Write-Host '--- and it refuses a console that is not asking anything ---'
    $why3 = Invoke-SRAnswerOnScreen -ProcessId $PID -Index 0 -Who 'this test'
    if (-not $why3) { Fail 'the relay answered a console showing no menu at all' }
    else { Pass "refused, and said why: $why3" }

    $why4 = Invoke-SRAnswerOnScreen -ProcessId 0 -Index 0
    if (-not $why4) { Fail 'the relay accepted a process id of 0' }
    else { Pass "a dead process id is refused: $why4" }

    # --- 5. SEVERAL ANSWERS AT ONCE ----------------------------------------
    # 🔒 The SHAPE below is a real capture (2026-08-26). The BEHAVIOUR is not:
    # the captured footer says "Enter to select", which READS as toggle-on-option
    # and commit-on-Submit, and the replica implements that reading. So what these
    # assertions prove is the NAVIGATION -- Submit found by reading the cursor,
    # the right options toggled, an already-ticked option left alone -- and NOT
    # the premise. Nothing in the GUI calls this; see Invoke-SRAnswerMultiOnScreen.
    Write-Host ''
    Write-Host '--- several answers at once (navigation only: the toggle key is not measured) ---'
    $r3 = Start-Replica -StartCursor 0 -Multi
    $seen3 = Wait-ForMenu -ProcessId $r3.Proc.Id
    if (-not $seen3) {
        Fail 'the multi-select replica never showed a menu'
    } else {
        if (-not $seen3.Multi) { Fail 'a menu with a box on every option was not recognised as multi-select' }
        else { Pass 'a box on every option is read as multi-select' }
        if ($seen3.SubmitAt -ne $seen3.Options.Count) { Fail "Submit read as stop $($seen3.SubmitAt), expected $($seen3.Options.Count) - one past the last option" }
        else { Pass "the Submit row is found, one stop past the last option ($($seen3.SubmitAt))" }
        if (@($seen3.Ticked).Count -ne 0) { Fail "$(@($seen3.Ticked).Count) option(s) read as already ticked on a fresh menu" }
        else { Pass 'nothing reads as ticked before anything is ticked' }
        if ("$($seen3.Options[0])" -like '*[[]*') { Fail "the box is still in the label: '$($seen3.Options[0])'" }
        else { Pass "the box is stripped from the label: '$($seen3.Options[0])'" }

        $why5 = Invoke-SRAnswerMultiOnScreen -ProcessId ([int]$r3.Proc.Id) -Indexes @(1, 3) -Who 'replica'
        if ($why5) { Fail "the multi relay refused: $why5" }
        else {
            $got3 = Wait-ForAnswer -Proc $r3.Proc -OutFile $r3.Out
            if ($got3 -eq 'SUBMIT|2,4') { Pass "options 2 and 4 ticked and submitted: '$got3'" }
            else { Fail "the console committed '$got3', expected 'SUBMIT|2,4'" }
        }
    }

    # AN OPTION ALREADY TICKED MUST BE LEFT ALONE. Pressing ENTER on it would
    # turn it back OFF, so a relay that toggles blindly answers the opposite of
    # what it was asked for whenever the operator has already ticked something.
    $r4 = Start-Replica -StartCursor 0 -Multi
    $seen4 = Wait-ForMenu -ProcessId $r4.Proc.Id
    if (-not $seen4) {
        Fail 'the second multi-select replica never showed a menu'
    } else {
        # Tick option 1 by hand first, the way an operator would have.
        $null = [SRCon]::SendKeys([uint32]$r4.Proc.Id, [uint16[]]@(0x0D))
        Start-Sleep -Milliseconds 400
        $mid = Get-SRScreenQuestion -ProcessId ([int]$r4.Proc.Id)
        if (-not $mid -or @($mid.Ticked).Count -ne 1 -or [int]@($mid.Ticked)[0] -ne 0) {
            Fail "after one ENTER the screen reads $(@($mid.Ticked).Count) ticked - the replica or the parser disagrees about the box"
        } else {
            Pass 'a ticked box is read back off the screen as ticked'
            $why6 = Invoke-SRAnswerMultiOnScreen -ProcessId ([int]$r4.Proc.Id) -Indexes @(0, 2) -Who 'replica'
            if ($why6) { Fail "the multi relay refused: $why6" }
            else {
                $got4 = Wait-ForAnswer -Proc $r4.Proc -OutFile $r4.Out
                if ($got4 -eq 'SUBMIT|1,3') { Pass "the already-ticked option was left on, not toggled off: '$got4'" }
                else { Fail "the console committed '$got4', expected 'SUBMIT|1,3'" }
            }
        }
    }

    # And it refuses a single-select menu rather than hunting for a Submit row
    # that is not there.
    $r5 = Start-Replica -StartCursor 0
    $seen5 = Wait-ForMenu -ProcessId $r5.Proc.Id
    if (-not $seen5) { Fail 'the single-select replica never showed a menu' }
    else {
        $why7 = Invoke-SRAnswerMultiOnScreen -ProcessId ([int]$r5.Proc.Id) -Indexes @(0) -Who 'replica'
        if (-not $why7) { Fail 'the multi relay answered a SINGLE-select menu' }
        else { Pass "a single-select menu is refused by the multi path: $why7" }
    }

    # ===========================================================================
    Write-Host ''
    Write-Host '--- the counts a session prints, read off a REAL console ---'
    # ===========================================================================
    # 🔴 THIS IS THE ONLY SOURCE FOR A RUNNING BACKGROUND SHELL. A Bash call with
    # run_in_background gets its tool_result back IMMEDIATELY, carrying the shell
    # id, so the "a call nobody answered is still running" test - which is right
    # for sub-agents - can never fire for a shell. The reader that tried reported
    # zero of them for hours while it was being called working. The session
    # prints the true number on its status line, and the whole chip now rests on
    # this parse, so it is worth proving against a console rather than a string.
    #
    # 🪤 And this was called untestable. It is not: the suite has been spawning a
    # real console and reading its screen since it was written.
    $statusText = '>> auto mode on (shift+tab to cycle) . 2 shells . <- for agents . 1 feedback draft'
    $r6 = Start-Replica -StartCursor 0 -StatusLine $statusText
    $seen6 = Wait-ForMenu -ProcessId $r6.Proc.Id
    if (-not $seen6) { Fail 'the replica with a status line never showed a menu' }
    else {
        $screen6 = Get-SRScreenText -ProcessId ([int]$r6.Proc.Id)
        if (-not $screen6) { Fail 'could not read the screen that was just read for its menu' }
        else {
            $vit = Read-SRScreenVitals -ScreenText $screen6
            if (-not $vit.Ok) { Fail 'the status line was on screen and nothing was read off it' }
            elseif ($vit.Shells -ne 2) { Fail "the screen says 2 shells and the reader saw $($vit.Shells)" }
            else { Pass "2 shells read off a real console's status line" }
            # The bare "<- for agents" hint carries no number and must not be
            # counted as one - the trap that would report an agent on every
            # session that has none.
            if ($vit.Agents -ne 0) { Fail "no agent count was printed and the reader invented $($vit.Agents)" }
            else { Pass 'the bare agents hint is not read as a count' }
            # 🔴 WHICH OF THE TWO THE LINE ACTUALLY PRINTED, separately from Ok.
            # The row marks turn on this: a shell count the line did not print
            # is a true zero and has to clear the mark, while an agent count it
            # did not print means "ask the transcript" - so one flag for each,
            # and Ok cannot answer for both at once.
            if (-not $vit.SawShells) { Fail 'the line printed a shell count and SawShells is false' }
            elseif ($vit.SawAgents) { Fail 'no agent count was printed and SawAgents says one was' }
            else { Pass 'the reader says which of the two figures the line carried' }
        }
    }

    # THE INVERSE, or the two assertions above would pass on a reader that
    # returns 2 for anything: the same replica WITHOUT a status line must report
    # nothing rather than zero, because unread is not the same as none.
    $r7 = Start-Replica -StartCursor 0
    $seen7 = Wait-ForMenu -ProcessId $r7.Proc.Id
    if (-not $seen7) { Fail 'the plain replica never showed a menu' }
    else {
        $screen7 = Get-SRScreenText -ProcessId ([int]$r7.Proc.Id)
        $vit7 = Read-SRScreenVitals -ScreenText $screen7
        if ($vit7.Ok) { Fail "a menu with no status line still reported counts (shells=$($vit7.Shells))" }
        else { Pass 'a console with no status line reports nothing, not zero' }
    }

    # =====================================================================
    # A BATCHED ROUND, AGAINST SCREENS CAPTURED OFF THE REAL THING.
    #
    # 🔴 THESE ARE NOT SYNTHETIC. tests\screens\*.txt were captured on
    # 2026-08-30 by spawning a sandboxed claude, asking it for a real
    # multi-question round and driving the menu with keystrokes - one file per
    # state the round can be in. The replica above proves the CHOREOGRAPHY can
    # drive a console; these prove the PARSER reads what the terminal actually
    # draws, which a replica built from my own understanding never could.
    #
    # Every claim here is a thing that was measured, and each one was wrong or
    # missing in the parser before the capture.
    # =====================================================================
    Write-Host ''
    Write-Host '--- a batched round, off screens captured from a real one ---'
    $shots = Join-Path $SR_Root 'tests\screens'
    function Get-Shot { param([string]$Name)
        $p = Join-Path $shots $Name
        if (-not (Test-Path -LiteralPath $p)) { return $null }
        return (Invoke-SRParseScreenQuestion -Text ([System.IO.File]::ReadAllText($p)))
    }

    $sFresh = Get-Shot 'round-single-fresh.txt'
    if (-not $sFresh) { Fail 'the captured single-select screen did not parse at all' }
    else {
        # The tab bar: one per question, named by its header, none answered yet.
        $names = @(@($sFresh.Tabs) | ForEach-Object { "$($_.Label)" })
        if (($names -join ',') -ne 'Alpha,Beta,Gamma') {
            Fail "the round's tabs read '$($names -join ',')' - the bar names one tab per question"
        } else { Pass 'the tab bar is read as three questions: Alpha, Beta, Gamma' }
        if (@(@($sFresh.Tabs) | Where-Object { $_.Answered }).Count -ne 0) {
            Fail 'a fresh round is reporting an answered question'
        } else { Pass 'nothing is marked answered on a round nobody has touched' }
        # 🔴 The two rows the TUI appends are NOT options. Offering them as
        # buttons is how an empty Type-something gets an ENTER, which declines.
        if ([int]$sFresh.RealCount -ne 3) { Fail "RealCount is $($sFresh.RealCount) - three of the five rows are the real options" }
        else { Pass 'the three real options are told apart from the two rows the TUI adds' }
        if ([int]$sFresh.FreeAt -ne 3 -or [int]$sFresh.ChatAt -ne 4) {
            Fail "the editor row / chat row read as $($sFresh.FreeAt) / $($sFresh.ChatAt), expected 3 / 4"
        } else { Pass 'the type-something and chat-about-this rows are found by position' }
        if ([int]$sFresh.ChosenAt -ne -1) { Fail "an unanswered question claims option $($sFresh.ChosenAt) was chosen" }
        else { Pass 'an unanswered question reports no choice, rather than the first one' }
    }

    # 🔑 A REVISITED ANSWER CARRIES A TRAILING TICK - the only way the screen
    # says what you picked last time.
    $sAns = Get-Shot 'round-single-answered.txt'
    if (-not $sAns) { Fail 'the captured answered screen did not parse' }
    else {
        if ([int]$sAns.ChosenAt -ne 1) { Fail "the answered question reports choice $($sAns.ChosenAt), and the screen shows 'Alpha two'" }
        else { Pass 'coming back to an answered question, the option you chose is read off the tick' }
        if ("$(@($sAns.Options)[1])" -ne 'Alpha two') {
            Fail "the chosen label reads '$(@($sAns.Options)[1])' - the tick is state and must not stay in the label"
        } else { Pass 'the tick is stripped from the label it marks' }
        $done = @(@($sAns.Tabs) | Where-Object { $_.Answered } | ForEach-Object { "$($_.Label)" })
        if (($done -join ',') -ne 'Alpha,Beta') { Fail "the bar says '$($done -join ',')' are answered, expected Alpha,Beta" }
        else { Pass 'the bar reports which questions are done and which are not' }
    }

    $mFresh = Get-Shot 'round-multi-fresh.txt'
    $mTick  = Get-Shot 'round-multi-ticked.txt'
    if (-not $mFresh -or -not $mTick) { Fail 'the captured multi-select screens did not parse' }
    else {
        if (-not $mFresh.Multi) { Fail 'a real multi-select was not read as one' }
        else { Pass 'a real multi-select is recognised by its boxes' }
        # 🔴 'Next', NOT 'Submit'. The commit row is called Next while questions
        # follow it - so matching only 'Submit' found NO row on every
        # multi-select but the last, which is most of them.
        if ([int]$mFresh.SubmitAt -lt 0) { Fail "the commit row was not found - it reads 'Next' while questions follow" }
        else { Pass "the commit row is found whether it says Next or Submit (at $($mFresh.SubmitAt))" }
        if ((@($mTick.Ticked) -join ',') -ne '0,2') { Fail "the ticked boxes read '$(@($mTick.Ticked) -join ',')', the screen shows 1 and 3" }
        else { Pass 'the boxes that are ticked are read back off the screen' }
        if ((@($mFresh.Ticked) -join ',')) { Fail 'an untouched multi-select reports something already ticked' }
        else { Pass 'and an untouched one reports none - so the reading can go both ways' }
    }

    # 🔑 THE EDITOR ROW, IN ITS THREE STATES. Typing REPLACES the row text, so
    # "what is in the box" and "has it been committed" are different questions.
    $fEmpty = Get-Shot 'round-free-empty.txt'
    $fTyped = Get-Shot 'round-free-typed.txt'
    $fDone  = Get-Shot 'round-free-committed.txt'
    if (-not $fEmpty -or -not $fTyped -or -not $fDone) { Fail 'the captured free-text screens did not parse' }
    else {
        if ("$($fEmpty.FreeText)") { Fail "an untouched editor row reports '$($fEmpty.FreeText)' rather than nothing" }
        else { Pass 'an editor row still showing its placeholder holds nothing' }
        if ("$($fTyped.FreeText)" -ne 'my own words here') {
            Fail "the typed row reads '$($fTyped.FreeText)' - typing replaces the row text in place"
        } else { Pass "what was typed is read back off the row: 'my own words here'" }
        # Typed but NOT committed: the text is there and no tick is.
        if ([int]$fTyped.ChosenAt -ne -1) { Fail 'text typed but not committed is being reported as the answer' }
        else { Pass 'typed-but-not-sent is told apart from answered' }
        if ("$($fDone.FreeText)" -ne 'my own words here' -or [int]$fDone.ChosenAt -ne [int]$fDone.FreeAt) {
            Fail "a committed typed answer reads text='$($fDone.FreeText)' chosen=$($fDone.ChosenAt) free=$($fDone.FreeAt)"
        } else { Pass 'a committed typed answer is read back as both the text and the choice' }
    }

    # 🔑 THE SUBMIT TAB IS A REVIEW of the whole round - the one screen that
    # says how every question currently stands.
    $rev = Get-Shot 'round-review.txt'
    if (-not $rev) { Fail 'the captured review screen did not parse' }
    elseif (-not $rev.Review) { Fail 'the review screen was not recognised as one' }
    else {
        if (@($rev.Review.Answers).Count -ne 2) { Fail "the review lists $(@($rev.Review.Answers).Count) answer(s), the screen shows 2" }
        else { Pass 'the review lists every question that has been answered' }
        $multiAns = @(@($rev.Review.Answers) | Where-Object { $_.Question -like 'Which betas*' })
        if (-not $multiAns.Count -or "$($multiAns[0].Answer)" -ne 'Beta three, Beta one') {
            Fail "the multi-select answer reads '$(if ($multiAns.Count) { $multiAns[0].Answer })', the screen shows 'Beta three, Beta one'"
        } else { Pass 'a multi-select answer keeps the comma-joined form the menu shows' }
        if ($rev.Review.Complete) { Fail 'a round with an unanswered question is reported ready to submit' }
        else { Pass 'and it says the round is not finished, because one question is still open' }
    }
} finally {
    foreach ($p in $started) {
        try { if (-not $p.HasExited) { $p.Kill() } } catch { }
    }
    Remove-Item -LiteralPath $relayTmp -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Host ''
if ($fails) { Write-Host "$fails FAILURE(S)" -ForegroundColor Red; exit 1 }
Write-Host 'the relay holds, end to end' -ForegroundColor Green
exit 0
