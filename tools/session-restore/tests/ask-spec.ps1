# ===========================================================================
# THE ASK LANE, UNDER TEST.
#
# Standalone and read-only: it dot-sources _common.ps1, reads fixtures out of
# tests\screens, and greps sessions-window.ps1 as text. It never builds the
# window, never starts a session and never sends a key, so it is safe to run on
# a machine full of live work.
#
# 🔴 IT IS WRITTEN TO BE RED. Every assertion below fails against the tree as it
# stands on 2026-09-05, and each one names the fix that turns it green. A spec
# that passed today would be proving nothing - see the standing note in
# gui2-driver.ps1 about three assertions that were green because nothing ran.
#
# Intended to be folded into gui2-driver.ps1's ask block once the work lands;
# kept separate for now so it does not collide with the rail widening.
# ===========================================================================
[CmdletBinding()]
param([switch]$Quiet)

$ErrorActionPreference = 'Continue'
$specRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$repo     = Split-Path -Parent $specRoot
$screens  = Join-Path $specRoot 'screens'
. (Join-Path $repo 'lib\_common.ps1')

$script:pass = 0
$script:fail = 0
$script:cur  = [string][char]0x276F
function Pass { param([string]$m) $script:pass++; if (-not $Quiet) { Write-Host "  [ok]   $m" -ForegroundColor Green } }
function Fail { param([string]$m) $script:fail++; Write-Host "  [FAIL] $m" -ForegroundColor Red }
function Head { param([string]$m) Write-Host ''; Write-Host "== $m" -ForegroundColor Cyan }

function Read-Fixture { param([string]$Name)
    $p = Join-Path $screens $Name
    if (-not (Test-Path -LiteralPath $p)) { return $null }
    return [IO.File]::ReadAllText($p)
}

# ---------------------------------------------------------------------------
# 🔴 A SOURCE ASSERTION MUST READ CODE, NOT PROSE - AND THIS SPEC LEARNED THAT
# THE HARD WAY, TWICE, IN ITS FIRST RUN.
#
#   - The back-off check matched "two in a row" and went green. That text is a
#     full-line COMMENT at sessions-window.ps1:5349, about the two-parsed-empty
#     clear - a different mechanism entirely. The back-off it was supposed to be
#     testing was untouched.
#   - The held-open-reader check would have gone the same way: :10171 carries a
#     comment reading "note on Start-SRScreenServer".
#
# Both are greens that could not go red. Every source assertion below runs on
# the stripped text instead. This file's whole argument is that the codebase
# explains itself in comments, so matching them proves nothing.
# ---------------------------------------------------------------------------
function Get-CodeOnly { param([string]$Src)
    $keep = New-Object System.Collections.Generic.List[string]
    foreach ($ln in @($Src -split "`n")) {
        if ("$ln".TrimStart().StartsWith('#')) { continue }
        $keep.Add($ln) | Out-Null
    }
    return ($keep -join "`n")
}

# ---------------------------------------------------------------------------
# WHAT EACH SCREEN IS.
#
# Menu   - is a live menu actually on this screen?
# Opts   - the option labels the parser must return, pinned where the answer
#          matters. $null means "not pinned here".
# Cursor - where the highlight is, 0-based. -2 means "not pinned".
# ---------------------------------------------------------------------------
$alpha = @('Alpha one', 'Alpha two', 'Alpha three', 'Type something.', 'Chat about this')
$beta  = @('Beta one', 'Beta two', 'Beta three', 'Beta four', 'Type something', 'Chat about this')

$cases = @(
    @{ F = 'round-single-fresh.txt';        Menu = $true;  Opts = $alpha; Cursor = 0
       Why = 'a plain single-select' }
    @{ F = 'round-single-answered.txt';     Menu = $true;  Opts = $null;  Cursor = -2
       Why = 'a single-select returned to' }
    @{ F = 'round-multi-fresh.txt';         Menu = $true;  Opts = $beta;  Cursor = 0
       Why = 'a multi-select' }
    @{ F = 'round-multi-ticked.txt';        Menu = $true;  Opts = $null;  Cursor = -2
       Why = 'a multi-select with boxes ticked' }
    @{ F = 'round-free-empty.txt';          Menu = $true;  Opts = $null;  Cursor = -2
       Why = 'the free-text row, untouched' }
    @{ F = 'round-free-typed.txt';          Menu = $true;  Opts = $null;  Cursor = -2
       Why = 'the free-text row, typed into' }
    @{ F = 'round-free-committed.txt';      Menu = $true;  Opts = $null;  Cursor = -2
       Why = 'the free-text row, committed' }
    @{ F = 'turn-running.txt';              Menu = $false; Opts = $null;  Cursor = -2
       Why = 'a session mid-turn' }
    @{ F = 'turn-done.txt';                 Menu = $false; Opts = $null;  Cursor = -2
       Why = 'a session that has just finished' }

    # ---- the three that go red today -------------------------------------
    @{ F = 'prose-list-with-prompt.txt';    Menu = $false; Opts = $null;  Cursor = -2
       Why = 'REAL CAPTURE: a numbered PROSE list with the input box below it' }
    @{ F = 'caret-list-with-prompt.txt';    Menu = $false; Opts = $null;  Cursor = -2
       Why = "the operator's OWN message, caret on the 1. line, no menu anywhere" }
    @{ F = 'prose-above-menu.txt';          Menu = $true;  Opts = $alpha; Cursor = 0
       Why = 'a real menu with prose numbered above it' }
    @{ F = 'prose-above-menu-arrowed.txt';  Menu = $true;  Opts = $alpha; Cursor = 4
       Why = 'the same, with the highlight arrowed to the last row' }
)

# ===========================================================================
Head 'the parser tells a live menu from a numbered list'
# 🔑 BOTH DIRECTIONS. Prose must stay refused AND a real menu with prose above
# it must be found. Fixing only the first is what the cursor gate did.
# ===========================================================================
foreach ($c in $cases) {
    $t = Read-Fixture $c.F
    if ($null -eq $t) { Fail "fixture missing: $($c.F)"; continue }
    $q = $null
    try { $q = Invoke-SRParseScreenQuestion -Text $t } catch { }
    $got = [bool]($q -and @($q.Options).Count -ge 2 -and [int]$q.CursorAt -ge 0)
    if ($got -ne $c.Menu) {
        Fail ("{0}: expected menu={1}, parser says {2}  ({3})" -f $c.F, $c.Menu, $got, $c.Why)
    } else {
        Pass ("{0}: {1}" -f $c.F, $c.Why)
    }
}

# ===========================================================================
Head 'and it returns the RIGHT options, which is where the danger is'
# 🔴 THE BOOLEAN IS NOT ENOUGH, and prose-above-menu-arrowed.txt is why.
# That screen reports CursorAt = 4 today, which looks entirely correct - the
# highlight really is on the fifth row. What is wrong is WHICH five rows: the
# parser welds three lines of scrollback prose to the menu's last two, so the
# card offers prose as answers and a click computes its arrows against a list
# that is not on screen. Only asserting the labels catches that.
# ===========================================================================
foreach ($c in $cases) {
    if (-not $c.Opts) { continue }
    $t = Read-Fixture $c.F
    if ($null -eq $t) { continue }
    $q = $null
    try { $q = Invoke-SRParseScreenQuestion -Text $t } catch { }
    $got = @()
    if ($q) { $got = @($q.Options) }
    $want = @($c.Opts)
    if (($got -join '|') -ne ($want -join '|')) {
        Fail ("{0}: options are wrong`n           want: {1}`n           got : {2}" -f `
              $c.F, ($want -join ' | '), $(if ($got.Count) { $got -join ' | ' } else { '(none)' }))
    } else {
        Pass ("{0}: the option labels are the menu's own" -f $c.F)
    }
    if ($c.Cursor -ne -2) {
        $gotCur = $(if ($q) { [int]$q.CursorAt } else { -1 })
        if ($gotCur -ne $c.Cursor) {
            Fail ("{0}: cursor is on {1}, expected {2}" -f $c.F, $gotCur, $c.Cursor)
        } else {
            Pass ("{0}: the highlight is on row {1}" -f $c.F, $c.Cursor)
        }
    }
}

# ===========================================================================
Head 'the structural test exists and is its own predicate'
# 🪤 IT CANNOT BE Test-SRQuestionChrome. That helper's box-drawing arm matches
# the menu's OWN free-text editor row - round-single-fresh.txt draws a rule
# between option 4 and option 5 - so reusing it rejects all seven captured
# menus. Measured, twice, on the way to this rule.
# ===========================================================================
$hasPredicate = [bool](Get-Command -Name 'Test-SRLiveMenu' -ErrorAction SilentlyContinue)
if (-not $hasPredicate) {
    Fail 'Test-SRLiveMenu is not defined - the structural test has not landed yet'
} else {
    Pass 'Test-SRLiveMenu is defined'
    foreach ($c in $cases) {
        $t = Read-Fixture $c.F
        if ($null -eq $t) { continue }
        $got = $false
        try { $got = [bool](Test-SRLiveMenu -Text $t) } catch { }
        if ($got -ne $c.Menu) {
            Fail ("Test-SRLiveMenu on {0}: expected {1}, got {2}" -f $c.F, $c.Menu, $got)
        } else {
            Pass ("Test-SRLiveMenu agrees on {0}" -f $c.F)
        }
    }
}

# ===========================================================================
Head 'the band and the card ask ONE question, not two'
# 🔴 THIS ASYMMETRY IS THE OPERATOR'S COMPLAINT. The sweep flagged a row on
# `Options.Count -ge 2` while the card required a cursor, so a row could sit in
# NEEDS YOU and the card say "nothing that looks like a question is on its
# screen" about the same screen. Both sites must reach the same predicate.
# ===========================================================================
$winPath = Join-Path $repo 'lib\sessions-window.ps1'
$comPath = Join-Path $repo 'lib\_common.ps1'
$winSrc  = Get-CodeOnly ([IO.File]::ReadAllText($winPath))
$comSrc  = Get-CodeOnly ([IO.File]::ReadAllText($comPath))
$allSrc  = $winSrc + "`n" + $comSrc

# 🪤 BOTH SITES ARE IN sessions-window.ps1 - SweepJob at :8408 and QuietJob at
# :8553. The first draft of this spec looked for the second one in _common.ps1,
# found nothing, and passed. Searching the pair of files together removes the
# chance of a green earned by looking in the wrong place.
$bare = @([regex]::Matches($allSrc, '@\(\$q\.Options\)\.Count\s+-ge\s+2'))
if ($bare.Count) {
    Fail ('{0} site(s) still decide "is it asking?" on option count alone - the card requires more, so the row and the card can disagree' -f $bare.Count)
} else {
    Pass 'no site decides "is it asking?" on option count alone'
}
# And the positive half: both jobs must reach the shared predicate.
foreach ($job in @('SweepJob', 'QuietJob')) {
    $m = [regex]::Match($winSrc, ('\$script:' + $job + '\s*=\s*\{'))
    if (-not $m.Success) { Fail "could not find `$script:$job"; continue }
    $tail = $winSrc.Substring($m.Index, [Math]::Min(2500, $winSrc.Length - $m.Index))
    if ($tail -match 'Test-SRLiveMenu') {
        Pass "$job reaches the shared predicate"
    } else {
        Fail "$job does not call Test-SRLiveMenu - the band is not asking the card's question"
    }
}

# ===========================================================================
Head 'the process-identity guard is cheap, and compares the right name'
# 🪤 Win32_Process.Name is "claude.exe". Process.ProcessName is "claude", with
# no extension. A straight port that keeps -ne 'claude.exe' refuses EVERY send
# on every path - a total outage from a one-word difference. This asserts the
# behaviour rather than the spelling, so it cannot be satisfied by a comment.
# ===========================================================================
$guard = Get-Command -Name 'Test-SRClaudeProcess' -ErrorAction SilentlyContinue
if (-not $guard) {
    Fail 'Test-SRClaudeProcess is not defined - the guard has not been extracted yet'
} else {
    Pass 'Test-SRClaudeProcess is defined (so the rule can be driven without sending a key)'
    # This process is powershell, never claude: it must be refused.
    $mine = $PID
    $why = ''
    try { $why = Test-SRClaudeProcess -ProcessId $mine } catch { $why = "threw: $($_.Exception.Message)" }
    if (-not $why) {
        Fail "the guard accepted pid $mine, which is powershell - it would type into it"
    } else {
        Pass 'the guard refuses a process that is not claude'
    }
    # A real claude, if one is running, must be accepted. Read-only: this only
    # asks the process table for a name.
    $claude = @(Get-Process -Name 'claude' -ErrorAction SilentlyContinue)
    if (-not $claude.Count) {
        Write-Host '  [skip] no claude process running - cannot prove the accept side' -ForegroundColor DarkYellow
    } else {
        $why2 = 'x'
        try { $why2 = Test-SRClaudeProcess -ProcessId $claude[0].Id } catch { $why2 = "threw: $($_.Exception.Message)" }
        if ($why2) {
            Fail ("the guard refused a real claude (pid {0}): {1}  <- the claude/claude.exe trap" -f $claude[0].Id, $why2)
        } else {
            Pass 'the guard accepts a real claude process'
        }
    }
    # And it must be fast: this is the fix, so the number is the assertion.
    $sw = [Diagnostics.Stopwatch]::StartNew()
    for ($i = 0; $i -lt 20; $i++) { $null = Test-SRClaudeProcess -ProcessId $mine }
    $sw.Stop()
    $per = $sw.Elapsed.TotalMilliseconds / 20
    if ($per -gt 50) {
        Fail ('the guard costs {0:N1} ms per call - the CIM query it replaced was 824-1,367 ms and the bar is 50' -f $per)
    } else {
        Pass ('the guard costs {0:N1} ms per call (was 824-1,367 ms on Get-CimInstance)' -f $per)
    }
}

# ===========================================================================
Head 'no send path still pays a WMI round trip'
# All three are gestures the operator makes: sending a message, answering an
# option, pressing Esc. Each carried the same ~1 s guard.
# ===========================================================================
$wmiHits = [regex]::Matches($comSrc, 'Get-CimInstance\s+Win32_Process\s+-Filter\s+"ProcessId=')
$sendFns = @('Send-SRSessionInput', 'Send-SRQuestionAnswer', 'Send-SRInterrupt')
$lines = @($comSrc -split "`n")
$bad = @()
foreach ($fn in $sendFns) {
    $from = -1
    for ($i = 0; $i -lt $lines.Count; $i++) { if ($lines[$i] -match ('^function\s+' + [regex]::Escape($fn) + '\b')) { $from = $i; break } }
    if ($from -lt 0) { continue }
    $to = $lines.Count - 1
    for ($i = $from + 1; $i -lt $lines.Count; $i++) { if ($lines[$i] -match '^function\s+') { $to = $i - 1; break } }
    $body = ($lines[$from..$to] -join "`n")
    if ($body -match 'Get-CimInstance\s+Win32_Process') { $bad += $fn }
}
if ($bad.Count) {
    Fail ('these send paths still call Get-CimInstance Win32_Process: {0}' -f ($bad -join ', '))
} else {
    Pass 'no send path calls Get-CimInstance Win32_Process'
}

# ===========================================================================
Head 'the job runspaces ask for a held-open reader'
# Connect-SRScreenServer refuses a first start unless SR_ScreenWant is set, and
# only the UI runspace ever set it - so every job paid a full exe spawn per
# read: 115 ms against the UI thread's 9 ms.
# ===========================================================================
foreach ($job in @('AnswerJob', 'AskJob')) {
    $m = [regex]::Match($winSrc, ('\$script:' + $job + '\s*=\s*\{'))
    if (-not $m.Success) { Fail "could not find `$script:$job"; continue }
    $tail = $winSrc.Substring($m.Index, [Math]::Min(2500, $winSrc.Length - $m.Index))
    if ($tail -match 'Start-SRScreenServer') {
        Pass "$job asks for a held-open reader"
    } else {
        Fail "$job never calls Start-SRScreenServer - its screen reads cost ~115 ms instead of ~9 ms"
    }
}

# ===========================================================================
Head 'the ask-lane back-off needs two slow reads in a row'
# 🔑 MEASURED, NOT GUESSED. n=300 served reads round-robin over 30 live
# consoles: p50 5.2, p99 12.5, p99.7 60.8, max 94.7. n=40 on the spawn
# fallback: min 57.9, p50 71.4, max 96.7. The distributions OVERLAP, so no
# threshold separates them - 3 of 300 served reads exceed 40 ms but NO TWO IN A
# ROW do, while every spawn read exceeds it. Hysteresis is the fix; the 40 is
# already right.
# ===========================================================================
$m = [regex]::Match($winSrc, 'function\s+Invoke-AskPoll[\s\S]{0,4000}')
if (-not $m.Success) {
    Fail 'could not find Invoke-AskPoll'
} else {
    $body = $m.Value
    # 🪤 A COUNTER, NOT A PHRASE. The first version of this assertion matched the
    # words "two in a row" and went green off a comment about the clear logic.
    # $winSrc is comment-stripped now, and the pattern is a variable that has to
    # actually exist and be assigned.
    $hasCounter = [bool]($body -match '\$script:askSlowRun\s*=' -or $body -match '\$script:askSlowStreak\s*=')
    if ($hasCounter) {
        Pass 'the back-off counts consecutive slow reads rather than tripping on one'
    } else {
        Fail 'the back-off still trips on a single slow read (56 of 64 trips in the live log were reads under 100 ms, against a 40 ms bar, while served reads are p50 5.2)'
    }
    # The threshold itself stays at 40: the served and spawn distributions
    # overlap (served p99.7 60.8 / max 94.7 vs spawn min 57.9), so raising it
    # would disable the detector rather than sharpen it.
    if ($body -match '-gt\s+40\b') {
        Pass 'the 40 ms threshold is unchanged (no number separates the two distributions; hysteresis is the fix)'
    } else {
        Fail 'the 40 ms threshold moved - measured: raising it to 100-150 ms stops the back-off detecting the spawn fallback at all'
    }
}

# ===========================================================================
Write-Host ''
Write-Host ('  {0} passed, {1} failed' -f $script:pass, $script:fail) -ForegroundColor $(if ($script:fail) { 'Red' } else { 'Green' })
if ($script:fail) {
    Write-Host '  Red is the expected state until the ask-lane work lands - see .state\ask-lane-plan.md' -ForegroundColor DarkGray
}
exit $(if ($script:fail) { 1 } else { 0 })
