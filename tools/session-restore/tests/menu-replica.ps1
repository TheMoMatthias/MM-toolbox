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
    [int]$TimeoutSeconds = 90
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

function Show-Menu {
    Clear-Host
    Write-Host ''
    Write-Host ("$BAR " + $question)
    Write-Host ''
    for ($i = 0; $i -lt $options.Count; $i++) {
        $mark = $(if ($i -eq $sel) { $CUR } else { ' ' })
        Write-Host ("{0} {1}. {2}" -f $mark, ($i + 1), $options[$i].Label)
        if ($options[$i].Desc) { Write-Host ("     " + $options[$i].Desc) }
        Write-Host ''
    }
    Write-Host '  (replica of an AskUserQuestion menu - this is a test fixture)'
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
        'DownArrow' { if ($sel -lt $options.Count - 1) { $sel++ }; Show-Menu }
        'UpArrow'   { if ($sel -gt 0) { $sel-- }; Show-Menu }
        'Enter'     {
            [System.IO.File]::WriteAllText($Out,
                ("{0}|{1}" -f ($sel + 1), $options[$sel].Label),
                (New-Object System.Text.UTF8Encoding($false)))
            exit 0
        }
    }
}
[System.IO.File]::WriteAllText($Out, 'TIMEOUT', (New-Object System.Text.UTF8Encoding($false)))
exit 2
