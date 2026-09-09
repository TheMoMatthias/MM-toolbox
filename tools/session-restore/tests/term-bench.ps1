# ===========================================================================
# term-bench - can this window BE the terminal?
#
# Asked for: "we should be able to type and everything we type should also
# correspond to anything we would exactly do as in the terminal... precisely
# what is the terminal without any input lag or delay."
#
# Input is not the question - SRCon::Send already writes real INPUT_RECORDs
# into the session's own console input queue, which is the same queue a
# keyboard writes to. OUTPUT is the question: the screen has to be re-read to
# be seen, and a read is not free. This measures the read, because the read
# is the frame rate.
#
# READ-ONLY. It reads consoles the way the sweep already does. It sends
# NOTHING to any session.
#
#     powershell -NoProfile -ExecutionPolicy Bypass -File tests\refresh-bench-run.ps1 -Driver term-bench.ps1 -Out term-bench-test.ps1
# ===========================================================================
$ErrorActionPreference = 'Continue'
function TB-Say { param([string]$T) Write-Host $T }

TB-Say ''
TB-Say '=== term-bench: what a live terminal view would cost ==='

$tbPick = $null
foreach ($tbR in $script:model) {
    if ($tbR.Live -and $tbR.A -and $tbR.A.Pid -and "$($tbR.A.Kind)" -eq 'interactive') { $tbPick = $tbR; break }
}
if (-not $tbPick) {
    TB-Say '  no live interactive conversation to read - skipped'
    TB-Say '=== term-bench done ==='
    exit 0
}
$tbPid = [int]$tbPick.A.Pid
TB-Say ('  reading pid {0}' -f $tbPid)

# The window asks for a held-open reader at startup; a bench spliced onto it
# has to ask for its own.
$null = Start-SRScreenServer

function TB-Med { param([double[]]$V)
    $s = @($V | Sort-Object)
    if (-not $s.Count) { return -1.0 }
    return [double]$s[[int][Math]::Floor($s.Count / 2)]
}
function TB-Lines { param([string]$T) return @("$T" -split "`n").Count }

# =========================================================================
TB-Say ''
TB-Say '--- 1. is there a scrollback to read at all? ---'
# 🔴 THE ANSWER DECIDES A FEATURE. Rows(pid, back) walks the buffer ABOVE the
# visible top, which is only a place if conhost is holding one. Under ConPTY -
# which is what Windows Terminal drives claude through - the pseudo-console
# buffer is the SIZE OF THE VIEWPORT and the scrollback lives in the terminal
# emulator, where no console API can reach it. Same line count for back=0 and
# back=600 means Window.T was already 0: there is nothing above.
$tbA = Get-SRScreenText -ProcessId $tbPid -Back 0
$tbB = Get-SRScreenText -ProcessId $tbPid -Back 600
TB-Say ('  viewport            : {0,5} lines, {1,6} chars' -f (TB-Lines $tbA), "$tbA".Length)
TB-Say ('  viewport + 600 above: {0,5} lines, {1,6} chars' -f (TB-Lines $tbB), "$tbB".Length)
if ((TB-Lines $tbB) -le (TB-Lines $tbA)) {
    TB-Say '  VERDICT: NO SCROLLBACK IN THE CONSOLE BUFFER. The buffer is the'
    TB-Say '           viewport; whatever has scrolled off belongs to the terminal'
    TB-Say '           emulator and cannot be read through the console API.'
} else {
    TB-Say ('  VERDICT: {0} extra lines are reachable above the viewport.' -f ((TB-Lines $tbB) - (TB-Lines $tbA)))
}

# =========================================================================
TB-Say ''
TB-Say '--- 2. how fast can the view be refreshed? ---'
foreach ($tbCase in @(
    @{ N = 'the viewport, served'; Back = 0 }
    @{ N = 'asking for 600 rows above it'; Back = 600 }
)) {
    $tbRuns = New-Object System.Collections.Generic.List[double]
    for ($i = 0; $i -lt 12; $i++) {
        $sw = [System.Diagnostics.Stopwatch]::StartNew()
        $null = Get-SRScreenText -ProcessId $tbPid -Back ([int]$tbCase.Back)
        $sw.Stop()
        $null = $tbRuns.Add($sw.Elapsed.TotalMilliseconds)
    }
    $tbArr = $tbRuns.ToArray()
    TB-Say ('  {0,-32}  min {1,6:N1}  med {2,6:N1}  max {3,6:N1} ms' -f `
            $tbCase.N, ($tbArr | Measure-Object -Minimum).Minimum, (TB-Med $tbArr), ($tbArr | Measure-Object -Maximum).Maximum)
}

$tbOne = @()
for ($i = 0; $i -lt 12; $i++) {
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $null = Get-SRScreenText -ProcessId $tbPid
    $sw.Stop()
    $tbOne += $sw.Elapsed.TotalMilliseconds
}
$tbR = TB-Med $tbOne
TB-Say ''
TB-Say ('  a served viewport read is {0:N1} ms, so:' -f $tbR)
foreach ($tbHz in @(60, 30, 20, 10)) {
    $tbEvery = 1000.0 / $tbHz
    TB-Say ('    at {0,2} Hz ({1,5:N0} ms) an echo appears within {2,5:N0} ms; the reader is busy {3,4:N0}% of the time' -f `
            $tbHz, $tbEvery, ($tbEvery + $tbR), (100.0 * $tbR / $tbEvery))
}

# =========================================================================
TB-Say ''
TB-Say '--- 3. what cannot be reached, whatever the frame rate ---'
# 🔴 ReadConsoleOutputCharacterW RETURNS CHARACTERS. Colour lives in the
# attribute plane, and the legacy attribute plane is FOUR BITS - claude paints
# 24-bit colour through VT sequences, so the buffer can hand back at best a
# sixteen-colour approximation of it. Worth stating before building rather than
# discovering after: a view on this reader is faithful in TEXT and in CURSOR
# POSITION, and is monochrome.
TB-Say '  colour  : characters only. The attribute plane is 4-bit; claude'
TB-Say '            paints 24-bit over VT. A view on this reader is monochrome.'
TB-Say '  input   : SRCon::Send writes real INPUT_RECORDs into the session''s own'
TB-Say '            console input queue - the same queue a keyboard writes to -'
TB-Say '            so a forwarded keystroke is not an approximation of typing.'

try { Stop-SRScreenServer } catch { }
TB-Say ''
TB-Say '=== term-bench done ==='
exit 0
