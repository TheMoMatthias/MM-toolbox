#requires -Version 5.1
<#
.SYNOPSIS
    A console that records what was typed into it. The stand-in a terminal
    forwarding test needs.

.DESCRIPTION
    🔴 NOT A MOCK OF THE SENDER. This is a REAL console with a REAL input
    queue, read with [Console]::ReadKey -- which is what consumes the
    INPUT_RECORDs SRCon::Send and SRCon::SendKeys write. So a test that drives
    it exercises the whole path: resolve the watched conversation, attach to its
    console, write the records, and have something on the other end read them as
    keystrokes.

    It exists because the terminal view sends keys into LIVE conversations, and
    those must never be a test subject. The standing rule in this repo is that
    nothing may type into a session -- not to test, not once, not against what
    somebody believes is a spare. This is the console that CAN be typed into.

    Characters accumulate. ENTER writes what has accumulated to -Out and exits,
    so the caller has a file to assert on rather than a screen to parse.
    ESCAPE writes "<esc>" and exits, so the key path can be proven separately
    from the character path.

.PARAMETER Out
    File to write what was typed into.

.PARAMETER TimeoutSeconds
    Give up and write whatever arrived. A replica that waits forever is a
    process left on the machine when a test fails.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$Out,
    [int]$TimeoutSeconds = 90
)

$ErrorActionPreference = 'Stop'
$sb = New-Object System.Text.StringBuilder
$deadline = (Get-Date).AddSeconds($TimeoutSeconds)

# A console turns Ctrl+C into a termination request unless it is told the
# program wants to READ it. Without this the replica would die on the very key
# it exists to observe, and the test would read "no output" as "not sent".
try { [Console]::TreatControlCAsInput = $true } catch { }

Write-Host 'term-replica: type into me'
try {
    while ((Get-Date) -lt $deadline) {
        if (-not [Console]::KeyAvailable) { Start-Sleep -Milliseconds 20; continue }
        $k = [Console]::ReadKey($true)
        if ($k.Key -eq [ConsoleKey]::Enter) { break }
        if ($k.Key -eq [ConsoleKey]::Escape) { $null = $sb.Append('<esc>'); break }
        # The three chords, recorded as what they are rather than as the letter -
        # a bare 'c' would prove nothing about the control bit having arrived.
        #
        # 🪤 `continue` INSIDE A switch LEAVES THE SWITCH, NOT THE LOOP. The
        # first version of this used one and only worked by accident: the
        # control characters are below 32, so the fall-through happened to
        # append nothing. Written as a lookup and an explicit continue.
        if ($k.Modifiers -band [ConsoleModifiers]::Control) {
            $chordName = ''
            if ("$($k.Key)" -eq 'C') { $chordName = '<ctrl-c>' }
            elseif ("$($k.Key)" -eq 'D') { $chordName = '<ctrl-d>' }
            elseif ("$($k.Key)" -eq 'Z') { $chordName = '<ctrl-z>' }
            if ($chordName) { $null = $sb.Append($chordName); continue }
        }
        if ($k.Key -eq [ConsoleKey]::Tab) { $null = $sb.Append('<tab>'); continue }
        if ($k.Key -eq [ConsoleKey]::DownArrow) { $null = $sb.Append('<down>'); continue }
        if ($k.Key -eq [ConsoleKey]::Backspace) {
            if ($sb.Length -gt 0) { $null = $sb.Remove($sb.Length - 1, 1) }
            continue
        }
        if ($k.KeyChar -and [int]$k.KeyChar -ge 32) { $null = $sb.Append($k.KeyChar) }
    }
} catch { }

[System.IO.File]::WriteAllText($Out, $sb.ToString(), (New-Object System.Text.UTF8Encoding($false)))
exit 0
