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
        Write-Host $StatusLine
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
        'Enter'     {
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
    }
}
[System.IO.File]::WriteAllText($Out, 'TIMEOUT', (New-Object System.Text.UTF8Encoding($false)))
exit 2
