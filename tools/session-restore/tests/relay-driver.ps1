
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

$replica = Join-Path $here 'tests\menu-replica.ps1'
if (-not (Test-Path -LiteralPath $replica)) {
    Fail "menu-replica.ps1 is missing from $(Join-Path $here 'tests')"
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
    param([int]$StartCursor)
    $outFile = Join-Path $relayTmp ('answer-' + [Guid]::NewGuid().ToString('N').Substring(0, 6) + '.txt')
    # MINIMIZED, NOT HIDDEN. -WindowStyle Hidden gives the process no console
    # window, and while the screen BUFFER still exists, the point of this test is
    # to read what a real terminal is showing. Minimized keeps a real console and
    # keeps it off the operator's screen.
    $p = Start-Process -FilePath 'powershell.exe' -PassThru -WindowStyle Minimized -ArgumentList @(
        '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $replica,
        '-Out', $outFile, '-Cursor', "$StartCursor", '-TimeoutSeconds', '60')
    $started.Add($p)
    return [PSCustomObject]@{ Proc = $p; Out = $outFile }
}

# The menu takes a moment to paint. Poll for it rather than sleeping a guess:
# a fixed sleep is either slow or flaky, and on a loaded machine it is both.
function Wait-ForMenu {
    param([int]$ProcessId, [int]$TimeoutMs = 15000)
    $stop = (Get-Date).AddMilliseconds($TimeoutMs)
    while ((Get-Date) -lt $stop) {
        $seen = Get-SRScreenQuestion -ProcessId $ProcessId
        if ($seen -and $seen.Options.Count -ge 2) { return $seen }
        Start-Sleep -Milliseconds 250
    }
    return $null
}

function Wait-ForAnswer {
    param([object]$Proc, [string]$OutFile, [int]$TimeoutMs = 15000)
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
