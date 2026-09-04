#requires -Version 5.1
<#
.SYNOPSIS
    A stand-in for claude's AskUserQuestion menu, in a real console.

.DESCRIPTION
    NOT A MOCK OF THE PARSER. This paints the SAME CHARACTERS claude paints, in a
    real console screen buffer, and drives the same highlight with the same keys
    -- so the relay reads it exactly as it reads the real thing, through
    ReadConsoleOutputCharacterW, with nothing stubbed in between.

    It exists because the relay's two halves had never run together. The parser
    was proven against captured text; the key send was proven against a live menu
    on 2026-08-24. Read-the-screen -> work out the distance -> send arrows ->
    commit had never once run as one sequence under test, and that was the last
    unknown in the feature.

    The menu text is a VERBATIM CAPTURE of a real one (tests\state-driver.ps1
    carries the same lines), including the two options the TUI adds that appear
    in no transcript. Every character the parser keys off -- the cursor marker
    U+276F, the box rule U+2502, the two-space indent, the numbering -- is what
    was actually on screen.

    Keys are read with [Console]::ReadKey, which is what consumes the
    INPUT_RECORDs SRCon.SendKeys writes. DOWN and UP move the highlight; ENTER
    commits and writes "<n>|<label>" to -Out, which is what the test asserts on.

    Written by code, never as a literal: U+276F in a BOM-less UTF-8 file read as
    ANSI by PowerShell 5.1 arrives mojibaked, and the parser would not match it.

.PARAMETER Out
    File to write the committed choice into. "<1-based index>|<label>".

.PARAMETER Cursor
    Which option the highlight STARTS on, 0-based. The whole reason the relay
    reads the screen is that this is not always 0.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$Out,
    [int]$Cursor = 0,
    [int]$TimeoutSeconds = 90,

    # Render the MULTI-SELECT shape instead: an ASCII "[ ]" box in front of every
    # option and an unnumbered Submit row under the last one.
    #
    # 🔴 THE SHAPE IS A REAL CAPTURE. The layout, the ASCII boxes, the cursor
    # marker and the position of Submit were read off a live multi-select menu on
    # 2026-08-26 (scratchpad\multi\menu-213319.txt).
    #
    # 🔒 THE BEHAVIOUR IS NOT MEASURED, and that distinction is the whole point.
    # The captured footer says "Enter to select", which READS as: Enter toggles
    # the highlighted option, Enter on Submit commits. That is what this
    # implements, and a test against it therefore proves the NAVIGATION -- that
    # the relay finds Submit by reading the cursor rather than counting rows, and
    # ticks the options it was asked for -- and proves NOTHING about whether the
    # real TUI toggles on Enter. Until somebody measures that, nothing here may
    # be pointed at a live session.
    [switch]$Multi,

    # A status line to paint under the menu, e.g.
    #   ">> auto mode on (shift+tab to cycle) . 1 shell . <- for agents"
    # Passed rather than hard-coded so a test can assert what it asked for, and
    # so the no-status-line case stays the default - a menu without one must
    # still read exactly as it did before.
    [string]$StatusLine = ''
)

$ErrorActionPreference = 'Stop'

$CUR = [string][char]0x276F   # the highlight marker
$BAR = [string][char]0x2502   # the left rule claude draws the question inside

$question = "R-136's rollback rested on my misreading. What should happen to the four migrations now?"
$options = @(
    @{ Label = 'Record the correction, leave the rollback standing (Recommended)'
       Desc  = 'Amend R-136 with a correction section and file the finding, but do not re-apply.' },
    @{ Label = 'Re-apply all four now'
       Desc  = 'Restores the bitemporal re-key the other lanes want.' },
    @{ Label = 'Re-apply only 267/269 (coinmetrics)'
       Desc  = 'Coinmetrics collapsed 17 to 1 rather than to zero.' },
    @{ Label = 'Type something'; Desc = '' },
    @{ Label = 'Chat about this'; Desc = '' }
)

$sel = [Math]::Max(0, [Math]::Min($Cursor, $options.Count - 1))

# 🔑 "Type something" IS AN INLINE EDITOR, and until now this replica painted it
# as an inert label - so Invoke-SRAnswerTypedOnScreen, the one answer path that
# uses it, had never been driven against a real console at all. Both other paths
# had; this one was proven only against captured screens, which can show what a
# typed row LOOKS like and can never show that the walking, the typing and the
# commit work as one sequence.
#
# 🔴 THE SHAPE IS THE CAPTURE, tests\screens\round-free-typed.txt: once anything
# is typed the row IS that text and the placeholder is gone, which is exactly why
# the parser finds the row by POSITION as well as by name. Painting the text in
# place of the label is therefore the whole of what a replica has to do.
#
# 🔒 The BEHAVIOUR carries the same caveat as -Multi above: that the row accepts
# characters and commits on ENTER is read off the footer and the captures, not
# measured against a live TUI. So this proves the relay's NAVIGATION - that it
# finds the editor row, gets the highlight onto it, and only commits once the row
# reads back what was sent - and proves nothing about the real TUI's key handling.
#
# 🪤 SINGLE-SELECT ONLY, and that is not a shortcut. Under -Multi this same row
# is an ordinary tickable option as far as this fixture is concerned, and the
# relay suite's multi test ticks it BY INDEX - options 2 and 4, where 4 is this
# row. Making it an editor in both shapes would have turned that test's ENTER
# into a commit and broken a passing assertion to add a new one.
$freeIx = -1
if (-not $Multi) {
    for ($i = 0; $i -lt $options.Count; $i++) {
        if ($options[$i].Label -eq 'Type something') { $freeIx = $i; break }
    }
}
$typed = ''

# Multi-select adds one more STOP after the last option: the Submit row. It is
# navigable and unnumbered, exactly as captured.
$ticked = New-Object 'System.Collections.Generic.HashSet[int]'
$submitAt = $options.Count          # the index the cursor is on when Submit is highlighted
$stops = $(if ($Multi) { $options.Count + 1 } else { $options.Count })

function Show-Menu {
    Clear-Host
    Write-Host ''
    Write-Host ("$BAR " + $question)
    Write-Host ''
    for ($i = 0; $i -lt $options.Count; $i++) {
        $mark = $(if ($i -eq $sel) { $CUR } else { ' ' })
        # The editor row holds what has been typed into it, in place of its
        # placeholder - see the note where $typed is declared.
        if ($i -eq $freeIx -and "$typed") {
            Write-Host ("{0} {1}. {2}" -f $mark, ($i + 1), $typed)
            Write-Host ''
            continue
        }
        if ($Multi) {
            # "[ ]" and "[x]", ASCII, as captured. NOT a Unicode box: the real
            # menu uses square brackets, and a parser tuned to U+25A1 would have
            # matched nothing at all on the real thing.
            $box = $(if ($ticked.Contains($i)) { '[x]' } else { '[ ]' })
            Write-Host ("{0} {1}. {2} {3}" -f $mark, ($i + 1), $box, $options[$i].Label)
        } else {
            Write-Host ("{0} {1}. {2}" -f $mark, ($i + 1), $options[$i].Label)
        }
        if ($options[$i].Desc) { Write-Host ("     " + $options[$i].Desc) }
        Write-Host ''
    }
    if ($Multi) {
        $mark = $(if ($sel -eq $submitAt) { $CUR } else { ' ' })
        Write-Host ("{0}    Submit" -f $mark)
        Write-Host ''
    }
    Write-Host '  (replica of an AskUserQuestion menu - this is a test fixture)'
    # THE STATUS LINE, painted the way a real session paints it. It is the only
    # place a running BACKGROUND SHELL can be counted: a Bash call with
    # run_in_background gets its tool_result back immediately, so the transcript
    # can never tell one that is still running from one that finished, and the
    # reader that tried reported zero of them forever. Reading what the session
    # PRINTS is the fix, and this is what lets that be tested against a real
    # console rather than against a string in a fixture.
    if ($StatusLine) {
        Write-Host ''
        # 🔴 PAINTED WITH THE REAL MARKER. The reader no longer scans the whole
        # buffer for "N shells" - it scans the STATUS LINE, because a session
        # whose conversation was about shells got read as having 2,100 of them.
        # A status line is recognised by the glyph claude starts it with, so a
        # replica painting an ASCII stand-in would no longer be a replica of one.
        #
        # The caller still passes plain ASCII (">> auto mode on ...") because an
        # argument makes several hops through Start-Process and PS 5.1's ANSI
        # reading of .ps1 files; the glyph is written HERE, from a code point,
        # where neither can touch it. The stand-in prefix is stripped first.
        $marker = ([string][char]0x23F5) * 2
        $body = "$StatusLine" -replace '^\s*[^\w]+\s*', ''
        Write-Host ($marker + ' ' + $body)
    }
}

Show-Menu

# POLLED, NOT A BARE ReadKey. A blocking read with no deadline leaves a console
# window on the operator's desktop forever if the test dies between launching
# this and answering it.
$deadline = (Get-Date).AddSeconds($TimeoutSeconds)
while ((Get-Date) -lt $deadline) {
    if (-not [Console]::KeyAvailable) { Start-Sleep -Milliseconds 40; continue }
    $k = [Console]::ReadKey($true)
    switch ($k.Key) {
        'DownArrow' { if ($sel -lt $stops - 1) { $sel++ }; Show-Menu }
        'UpArrow'   { if ($sel -gt 0) { $sel-- }; Show-Menu }
        'Backspace' {
            if ($sel -eq $freeIx -and $typed.Length -gt 0) {
                $typed = $typed.Substring(0, $typed.Length - 1)
                Show-Menu
            }
        }
        'Enter'     {
            # 🔴 ENTER ON AN EMPTY EDITOR ROW DECLINES THE ROUND - measured twice
            # by accident during the original capture, and the reason the window
            # never offers that row as an ordinary button. Recorded here so a
            # relay that commits an empty answer fails the test loudly instead of
            # looking like it worked.
            if ($sel -eq $freeIx) {
                $body = $(if ("$typed") { "FREE|$typed" } else { 'DECLINED' })
                [System.IO.File]::WriteAllText($Out, $body,
                    (New-Object System.Text.UTF8Encoding($false)))
                exit 0
            }
            if (-not $Multi) {
                [System.IO.File]::WriteAllText($Out,
                    ("{0}|{1}" -f ($sel + 1), $options[$sel].Label),
                    (New-Object System.Text.UTF8Encoding($false)))
                exit 0
            }
            # MULTI-SELECT, on the inferred reading of "Enter to select": Enter
            # acts on whatever row is highlighted. On an option that means TOGGLE;
            # on Submit it means COMMIT. Inferred, not measured -- see -Multi.
            if ($sel -eq $submitAt) {
                $chosen = @()
                foreach ($i in 0..($options.Count - 1)) { if ($ticked.Contains($i)) { $chosen += ($i + 1) } }
                [System.IO.File]::WriteAllText($Out,
                    ("SUBMIT|" + ($chosen -join ',')),
                    (New-Object System.Text.UTF8Encoding($false)))
                exit 0
            }
            if ($ticked.Contains($sel)) { $null = $ticked.Remove($sel) } else { $null = $ticked.Add($sel) }
            Show-Menu
        }
        default {
            # Typing while the editor row is highlighted replaces the row text.
            # Printable ASCII only - the relay sends characters one at a time
            # through WriteConsoleInputW and nothing here needs to be cleverer.
            if ($sel -eq $freeIx -and $k.KeyChar) {
                $c = [int][char]$k.KeyChar
                if ($c -ge 32 -and $c -lt 127) {
                    $typed = $typed + [string]$k.KeyChar
                    Show-Menu
                }
            }
        }
    }
}
[System.IO.File]::WriteAllText($Out, 'TIMEOUT', (New-Object System.Text.UTF8Encoding($false)))
exit 2
