
# ------------------------------------------------- conversation-state driver
# Get-SRConversationState reads a transcript tail and says what a conversation
# was last doing. Two halves here, and the first matters more:
#
#   FIXTURES  hand-built transcripts with a known ending, so each state can be
#             forced and the assertion can actually fail. Testing only against
#             the real registry would mean the suite passes or fails depending
#             on what the operator happened to be running.
#   REALITY   the same function over every real conversation, guarding the two
#             things that went wrong while writing it: cost, and how often it
#             gives up and says 'unknown'.
$fails = 0
function Fail { param($m) Write-Host ("  FAIL  " + $m) -ForegroundColor Red; $script:fails++ }
function Pass { param($m) Write-Host ("  ok    " + $m) -ForegroundColor Green }

# --- fixtures ---------------------------------------------------------------
$tmp = Join-Path $here ('.state\state-fixtures-' + [Guid]::NewGuid().ToString('N').Substring(0, 8))
$null = New-Item -ItemType Directory -Path $tmp -Force
try {
    function New-Fixture { param([string]$Name, [string[]]$Records)
        $p = Join-Path $tmp ($Name + '.jsonl')
        [System.IO.File]::WriteAllLines($p, $Records, (New-Object System.Text.UTF8Encoding($false)))
        return $p
    }
    # Bookkeeping padding, because a real tail is mostly this: attachment records
    # outnumber assistant ones 658 to 503, which is what made a short tail read
    # as 'unknown' for 4 of the 10 live conversations.
    $noise = @()
    for ($i = 0; $i -lt 30; $i++) { $noise += '{"type":"attachment","uuid":"n' + $i + '"}' }

    $turnWait = '{"type":"assistant","message":{"role":"assistant","stop_reason":"end_turn","content":[{"type":"text"}]}}'
    $turnWork = '{"type":"assistant","message":{"role":"assistant","stop_reason":"tool_use","content":[{"type":"tool_use"}]}}'

    $cases = @(
        @{ N = 'waiting';     R = @($noise + $turnWait + $noise);                                 Want = 'waiting' }
        @{ N = 'working';     R = @($noise + $turnWork + $noise);                                 Want = 'working' }
        @{ N = 'userlast';    R = @($noise + $turnWait + '{"type":"user","message":{"role":"user"}}'); Want = 'working' }
        @{ N = 'summarising'; R = @($noise + $turnWait + '{"type":"user","isCompactSummary":true}'); Want = 'summarising' }
        @{ N = 'nobody';      R = @($noise);                                                      Want = 'unknown' }
        @{ N = 'empty';       R = @();                                                            Want = 'unknown' }
    )
    foreach ($c in $cases) {
        $p  = New-Fixture -Name $c.N -Records $c.R
        $st = Get-SRConversationState -JsonlPath $p
        if ($st.State -ne $c.Want) { Fail ("fixture '{0}' -> '{1}', expected '{2}' ({3})" -f $c.N, $st.State, $c.Want, $st.Detail) }
        else { Pass ("fixture '{0}' -> {1,-12} {2}" -f $c.N, $st.State, $st.Detail) }
    }

    # A tail of pure bookkeeping must still find the turn underneath it. This is
    # the specific regression that took 'unknown' from 23 down to 7.
    # @(<string> + <array>) is STRING concatenation in PowerShell -- the whole
    # array is flattened into one giant line and written as a single record. The
    # first version of this fixture did exactly that, so the turn was on the same
    # line as the noise and the assertion passed without ever testing a buried
    # turn. Wrap the leading string so it is array + array.
    $deep = New-Fixture -Name 'deepturn' -Records @(@($turnWork) + $noise + $noise)
    $st = Get-SRConversationState -JsonlPath $deep
    if ($st.State -ne 'working') { Fail "a turn buried under 60 bookkeeping records was missed ('$($st.State)')" }
    else { Pass 'finds a turn buried under 60 bookkeeping records' }

    # Fields the GUI binds to. A renamed or dropped field breaks it at RUNTIME,
    # silently, because PowerShell returns $null for a property that is not there.
    $st = Get-SRConversationState -JsonlPath (Join-Path $tmp 'waiting.jsonl')
    $want = @('State', 'Detail', 'Stale', 'LastActive', 'LastPrompt', 'Title', 'Mode')
    $have = @($st.PSObject.Properties.Name)
    $missing = @($want | Where-Object { $_ -notin $have })
    if ($missing.Count) { Fail ("contract fields missing: " + ($missing -join ', ')) }
    else { Pass ("all 7 contract fields present: " + ($want -join ', ')) }
    if ($st.Stale -isnot [bool]) { Fail 'Stale is not a boolean' } else { Pass 'Stale is a boolean' }

    # A missing file is a normal outcome, not an exception.
    $st = Get-SRConversationState -JsonlPath (Join-Path $tmp 'does-not-exist.jsonl')
    if ($st.State -ne 'unknown') { Fail "a missing transcript gave '$($st.State)', expected 'unknown'" }
    else { Pass 'a missing transcript returns unknown rather than throwing' }
}
finally {
    # Never leave a temp directory behind, whatever happened above.
    Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue
}

# --- reality ----------------------------------------------------------------
$reg = Get-SRRegistry
$paths = @()
foreach ($d in $reg.directories) {
    foreach ($s in @($d.sessions)) {
        $paths += [PSCustomObject]@{
            Id = "$($s.sessionId)".ToLower()
            J  = (Get-SRTranscriptPath -Dir $(if ($s.cwd) { $s.cwd } else { $d.path }) -SessionId $s.sessionId -Recorded $s.jsonl)
        }
    }
}
if ($paths.Count -lt 20) { Fail "only $($paths.Count) conversations - not enough to judge the real-world numbers" }

$sw = [Diagnostics.Stopwatch]::StartNew()
$states = @($paths | ForEach-Object { Get-SRConversationState -JsonlPath $_.J })
$sw.Stop()
$each = $sw.Elapsed.TotalMilliseconds / [Math]::Max(1, $paths.Count)
Write-Host ("  --    {0} conversations in {1:N0} ms ({2:N1} ms each)" -f $paths.Count, $sw.Elapsed.TotalMilliseconds, $each)

# 🔴 THIS GUARDS A REGRESSION, NOT A MACHINE, and at 12 ms it was doing the
# second. Get-SRConversationState opens a file per conversation, so its cost is
# the DISK - measured on this machine across one day: 7.2 ms idle, 9.8 ms while
# the suite ran, 14.9 ms with a game running, 27.2 ms and 34.4 ms inside a full
# sweep where the other suites are hammering the same disk. Every one of those
# was the same code. A threshold inside that spread fails for reasons the code
# cannot control, and a test that cries wolf gets its result ignored - which is
# worse than not having it, because the run it finally means something in is the
# one nobody reads.
#
# It was written to catch a TENFOLD regression (17.4 ms when the first version
# was fixed, 3.9 ms after). So it fails at tenfold and reports everything else.
# The number is always printed above: drift is visible without being fatal.
if ($each -gt 39) {
    Fail ("{0:N1} ms per conversation - a TENFOLD regression on the 3.9 ms this was written at" -f $each)
} elseif ($each -gt 12) {
    Write-Host ("        {0:N1} ms per conversation - above the 12 ms it idles at, but this machine is busy; only a tenfold regression fails" -f $each) -ForegroundColor DarkGray
    Pass ("{0:N1} ms per conversation, inside the tenfold guard" -f $each)
} else {
    Pass ("{0:N1} ms per conversation" -f $each)
}

# 'idle' was deliberately removed from the contract. If it comes back, the
# waiting/working distinction has been collapsed again for most of the list.
$idle = @($states | Where-Object { $_.State -eq 'idle' })
if ($idle.Count) { Fail "$($idle.Count) rows returned 'idle' - that state was removed on purpose; staleness belongs in Stale" }
else { Pass "no row returns 'idle' - state and staleness stayed separate" }

$byState = $states | Group-Object State | Sort-Object Count -Descending
Write-Host ("  --    " + (($byState | ForEach-Object { "{0} {1}" -f $_.Name, $_.Count }) -join '   '))

# 'unknown' is honest, but it is also useless, and the LIVE conversations are the
# only ones anybody is looking at. It was 4 of 10 before the tail was widened.
$run = Get-SRRunningIds -Refresh
$live = @(); for ($i = 0; $i -lt $paths.Count; $i++) { if ($run[$paths[$i].Id]) { $live += $states[$i] } }
if (-not $live.Count) {
    Write-Host '  --    no conversations are live right now, so the unknown-rate guard is inconclusive' -ForegroundColor DarkGray
} else {
    $unk = @($live | Where-Object { $_.State -eq 'unknown' }).Count
    $ratio = $unk / $live.Count
    Write-Host ("  --    live conversations: {0}, unknown: {1}" -f $live.Count, $unk)
    if ($ratio -gt 0.34) { Fail ("{0} of {1} LIVE conversations are 'unknown' - the tail is too short again" -f $unk, $live.Count) }
    else { Pass ("{0} of {1} live conversations unknown" -f $unk, $live.Count) }
}

# --- a needs-claim must be corroborated -------------------------------------
# `claude agents --json` keeps reporting background agents that went `blocked`
# and were never reaped. On 2026-08-23 STRATEGY-PERF-ANALYSIS sat at the top of
# NEEDS YOU: state `blocked`, startedAt 33 days earlier, NO pid, and no
# transcript left on disk. The band that means ACT ON THIS held the one thing on
# the machine that could not be acted on -- Send-SRSessionInput refuses a
# background agent for the very reason that made it unactionable.
#
# The records below are verbatim from that agent list, so this fails for the real
# reason rather than a reconstructed one.
Write-Host ''
Write-Host '--- a needs-claim must be corroborated ---'

$stuckAgent = [PSCustomObject]@{
    Status='blocked'; WaitingFor=''; Needs=$true; Pid=0; Kind='background'
    Name='STRATEGY-PERF-ANALYSIS'; Cwd='C:/x'
    StartedAt=[DateTimeOffset]::FromUnixTimeMilliseconds(1783972903099).LocalDateTime
}
$liveAgent = [PSCustomObject]@{
    Status='waiting'; WaitingFor='dialog open'; Needs=$true; Pid=31316; Kind='interactive'
    Name='OWN-WEBPAGE'; Cwd='C:/x'; StartedAt=(Get-Date).AddMinutes(-5)
}
# A RUNNING background agent reports no pid either. The pid alone would condemn
# every one of them, which is why the transcript is the second half of the test.
$bgAgent = [PSCustomObject]@{
    Status='blocked'; WaitingFor=''; Needs=$true; Pid=0; Kind='background'
    Name='LIVE-BG'; Cwd='C:/x'; StartedAt=(Get-Date).AddMinutes(-3)
}
$aConv = [PSCustomObject]@{ State='waiting'; Detail='waiting for you'; LastPrompt='x'; Title='t'; Mode='' }

$sk = Resolve-SRSessionState -Agent $stuckAgent -Conv $null
if ($sk.Needs)      { Fail 'an agent with no pid and no transcript still claims to need you' }
else                { Pass 'a needs-claim with neither a process nor a transcript is refused' }
if (-not $sk.Stuck) { Fail 'the uncorroborated claim was not marked stuck' }
else                { Pass 'it is marked stuck instead of demanding' }
if (-not $sk.Stale) { Fail 'a stuck report is not current and must read as stale' }
else                { Pass 'it reads as the last thing seen, not something happening now' }
if ($sk.Detail -notlike '*stuck since*') { Fail "the row does not say why it is dim: '$($sk.Detail)'" }
else { Pass "it says why: '$($sk.Detail)'" }

$lv = Resolve-SRSessionState -Agent $liveAgent -Conv $aConv
if (-not $lv.Needs) { Fail 'a real waiting session with a pid lost its needs-claim' }
else                { Pass 'a session with a pid still needs you' }
if ($lv.Stuck)      { Fail 'a live session was condemned as stuck' }
else                { Pass 'a live session is not stuck' }

$bg = Resolve-SRSessionState -Agent $bgAgent -Conv $aConv
if (-not $bg.Needs) { Fail 'a running background agent was refused for having no pid - the transcript backs it' }
else                { Pass 'a background agent backed by a transcript still needs you' }
# --- a question a session is waiting on -------------------------------------
# A pending AskUserQuestion is a tool_use with NO tool_result carrying its id.
# Hand-built here so the assertion can fail: reading the operator's live
# transcripts would pass or fail depending on what happened to be on screen.
Write-Host ''
Write-Host '--- the question a session is waiting on ---'
$qtmp = Join-Path $here ('.state\q-fixtures-' + [Guid]::NewGuid().ToString('N').Substring(0, 8))
$null = New-Item -ItemType Directory -Path $qtmp -Force
try {
    function New-QFixture { param([string]$Name, [string[]]$Records)
        $fp = Join-Path $qtmp ($Name + '.jsonl')
        [System.IO.File]::WriteAllLines($fp, $Records, (New-Object System.Text.UTF8Encoding($false)))
        return $fp
    }
    $ask = '{"type":"assistant","message":{"content":[{"type":"tool_use","id":"tu_1","name":"AskUserQuestion","input":{"questions":[{"question":"pick one","header":"PROBE","multiSelect":false,"options":[{"label":"ALPHA","description":"a"},{"label":"BRAVO","description":"b"},{"label":"CHARLIE","description":"c"}]}]}}]}}'
    $res = '{"type":"user","message":{"content":[{"type":"tool_result","tool_use_id":"tu_1","content":"answered"}]}}'
    $noise = '{"type":"attachment","uuid":"n1"}'

    $pend = Get-SRPendingQuestion -JsonlPath (New-QFixture 'pending' @($noise, $ask, $noise))
    if (-not $pend) { Fail 'a pending question was not detected' }
    elseif ("$($pend.Id)" -ne 'tu_1') { Fail "detected the wrong tool_use id: $($pend.Id)" }
    else {
        $opts = @($pend.Questions[0].options | ForEach-Object { $_.label })
        if (($opts -join ',') -ne 'ALPHA,BRAVO,CHARLIE') { Fail "options came back as: $($opts -join ',')" }
        else { Pass "a pending question is detected with its $($opts.Count) options" }
        if ("$($pend.Questions[0].header)" -ne 'PROBE') { Fail 'the header did not survive' }
        else { Pass 'the header and the question text survive' }
    }

    $done = Get-SRPendingQuestion -JsonlPath (New-QFixture 'answered' @($noise, $ask, $res, $noise))
    if ($done) { Fail 'an ANSWERED question was reported as pending - the tool_result was ignored' }
    else { Pass 'an answered question is not pending' }

    # Asked, answered, then asked again: only the second one is still open, and a
    # naive last-match search would return the first.
    $ask2 = $ask.Replace('tu_1', 'tu_2').Replace('pick one', 'second question')
    $again = Get-SRPendingQuestion -JsonlPath (New-QFixture 'again' @($ask, $res, $ask2))
    if (-not $again) { Fail 'the second question was not detected' }
    elseif ("$($again.Id)" -ne 'tu_2') { Fail "returned $($again.Id), not the still-open one" }
    else { Pass 'with one answered and one open, the OPEN one is returned' }

    $none = Get-SRPendingQuestion -JsonlPath (New-QFixture 'none' @($noise, $noise))
    if ($none) { Fail 'a transcript with no question reported one' }
    else { Pass 'a transcript with no question reports none' }

    if ($null -ne (Get-SRPendingQuestion -JsonlPath (Join-Path $qtmp 'no-such-file.jsonl'))) {
        Fail 'a missing transcript did not return null'
    } else { Pass 'a missing transcript returns null rather than throwing' }
} finally {
    Remove-Item -LiteralPath $qtmp -Recurse -Force -ErrorAction SilentlyContinue
}
# --- THE TOOL HAS TO FIND EVERY SESSION IT LAUNCHES -------------------------
# Two rules once conspired to hide 13 real conversations, and both looked
# reasonable in isolation. These assertions are about the DECISIONS, because that
# is where the bug was -- the code did exactly what it said it did.
Write-Host ''
Write-Host '--- discovery hides nothing real ---'

# 1. THE BYTE FLOOR, justified by a 118-byte Remote Control placeholder and then
# set to 5000 -- forty-two times higher. A real conversation carrying three user
# messages measured 3,191 bytes and was invisible; a freshly spawned session is
# smaller still, which is exactly when someone looks for it.
if ($SR_MinRealBytes -gt 1000) {
    Fail "SR_MinRealBytes is $SR_MinRealBytes - a real 3,191-byte conversation was hidden by a floor of 5000"
} else { Pass "the size floor is $SR_MinRealBytes bytes, below any real transcript" }

# 2. THE HOME DIRECTORY, excluded because it 'is never a project'. Measured across
# 290 transcripts: five live there and three of them are over 20 MB. Where someone
# works is not the tool's to assume.
$cfgNow = Get-SRConfig
if (Test-SRExcluded -Path $env:USERPROFILE -Config $cfgNow) {
    Fail 'the home directory is excluded - three conversations over 20 MB lived there'
} else { Pass 'a session started from the home directory is discoverable' }

# ...and the exclusions that ARE right still hold, or the trade went too far.
$tempish = Join-Path $env:TEMP 'claude'
if (-not (Test-SRExcluded -Path $tempish -Config $cfgNow)) {
    Fail "a temp path ($tempish) is no longer excluded - the fix went too wide"
} else { Pass 'temp paths are still excluded' }

# --- A CONVERSATION NOBODY NAMED STILL HAS A NAME ---------------------------
# claude writes TWO title records. customTitle is what -n and a rename set;
# aiTitle is the one it generates from what the conversation is about. This
# function read only the first, so 97 of the operator's 204 conversations were
# called "(untitled)" on screen while their own transcripts held a good name.
#
# The two must come back SEPARATELY. A name somebody chose and a name that was
# guessed are treated differently everywhere downstream -- the guess is drawn in
# italic, it never reaches the `title` field, and it loses every tie -- and all
# of that rests on this function not merging them here.
Write-Host ''
Write-Host '--- a conversation nobody named still has a name ---'
$ttmp = Join-Path $here ('.state\title-fixtures-' + [Guid]::NewGuid().ToString('N').Substring(0, 8))
$null = New-Item -ItemType Directory -Path $ttmp -Force
try {
    $cwdRec = '{"type":"user","cwd":"' + ($here -replace '\\', '\\') + '"}'
    $pad = @()
    for ($i = 0; $i -lt 40; $i++) { $pad += '{"type":"attachment","uuid":"p' + $i + '"}' }

    function New-TitleFixture { param([string]$Name, [string[]]$Records)
        $p = Join-Path $ttmp ($Name + '.jsonl')
        [System.IO.File]::WriteAllLines($p, $Records, (New-Object System.Text.UTF8Encoding($false)))
        return $p
    }

    # 1. Generated only: the case that covers 76 of the operator's 97.
    # 🪤 THE ARGUMENT MUST BE PARENTHESISED. `New-TitleFixture 'ai' @($a) + $b`
    # parses as a CALL taking @($a), whose result is then added to $b and echoed
    # to the host -- so the fixture is written with one record in it and the test
    # fails for a reason that has nothing to do with what it is testing.
    $fAi = New-TitleFixture 'ai' (@($cwdRec) + $pad + @('{"type":"summary","aiTitle":"Diagnose a slow disk"}') + $pad)
    $iAi = Get-SRSessionInfo -JsonlPath $fAi
    if ("$($iAi.AiTitle)" -eq 'Diagnose a slow disk') { Pass "the generated name is read: '$($iAi.AiTitle)'" }
    else { Fail "aiTitle came back as '$($iAi.AiTitle)' - a conversation nobody named stays '(untitled)'" }
    if (-not "$($iAi.Title)") { Pass 'and it is NOT reported as a chosen name' }
    else { Fail "aiTitle leaked into Title as '$($iAi.Title)' - a guess would outrank -n" }

    # 2. Both present. The chosen one must survive alongside, not replace or be
    #    replaced: whichever wins is decided at the point of display, not here.
    $fBoth = New-TitleFixture 'both' (@($cwdRec) + $pad +
        @('{"type":"summary","aiTitle":"Some generated words"}',
          '{"type":"summary","customTitle":"F2-SPINE"}') + $pad)
    $iBoth = Get-SRSessionInfo -JsonlPath $fBoth
    if ("$($iBoth.Title)" -eq 'F2-SPINE') { Pass 'a chosen name is still read as the chosen name' }
    else { Fail "customTitle came back as '$($iBoth.Title)' - a rename would be lost" }
    if ("$($iBoth.AiTitle)" -eq 'Some generated words') { Pass 'and the generated one is kept beside it, not merged' }
    else { Fail "aiTitle came back as '$($iBoth.AiTitle)' when a customTitle was also present" }

    # 3. 🔴 THE MEASURED LIMIT, ASSERTED AS A LIMIT.
    #
    #    A title above the tail is NOT found, and that is deliberate. The record
    #    sits at a MEDIAN 14.3% into the file, so reading the whole file would
    #    catch more of them in principle -- and it was tried, and measured, and
    #    it caught exactly NONE: the registry named 60 conversations with a
    #    whole-file fallback and 60 without it, because every conversation it
    #    could have helped belongs to a project whose folder has been deleted and
    #    which discovery refuses before this function is reached.
    #
    #    What it did cost was an uncached walk reading whole files for every
    #    conversation with no aiTitle at all, which pushed that walk past the
    #    FIVE SECOND life of the agent cache it consults at the end -- breaking a
    #    correct test about something else entirely.
    #
    #    So the contract is: the tail, and only the tail. This pins it, so that
    #    widening it again is a deliberate act with a measurement attached rather
    #    than an accident.
    $bulk = @()
    $filler = '{"type":"attachment","uuid":"' + ('x' * 900) + '"}'
    for ($i = 0; $i -lt 400; $i++) { $bulk += $filler }
    $fTop = New-TitleFixture 'top' (@($cwdRec, '{"type":"summary","aiTitle":"Named at the very top"}') + $bulk)
    $topLen = (Get-Item -LiteralPath $fTop).Length
    $iTop = Get-SRSessionInfo -JsonlPath $fTop
    if ($topLen -le $SR_TailBytes) {
        Fail "the fixture is only $topLen bytes - it does not exceed the $SR_TailBytes-byte tail, so it proves nothing"
    } elseif ("$($iTop.AiTitle)") {
        Fail "a title $([int]($topLen/1KB)) KB above the tail came back as '$($iTop.AiTitle)' - something is reading past the tail again, and that was measured to cost a whole-file read per nameless conversation for zero extra names"
    } else {
        Pass "a title above the $([int]($SR_TailBytes/1KB)) KB tail is knowingly NOT found - the tail is the whole contract"
    }

    # 4. Nothing at all. It must say so plainly rather than inventing something:
    #    21 of the operator's conversations genuinely have no generated title.
    $fNone = New-TitleFixture 'none' (@($cwdRec) + $pad)
    $iNone = Get-SRSessionInfo -JsonlPath $fNone
    if (-not "$($iNone.AiTitle)" -and -not "$($iNone.Title)") { Pass 'a transcript with neither reports neither' }
    else { Fail "invented a name from nothing: Title '$($iNone.Title)', AiTitle '$($iNone.AiTitle)'" }
} finally {
    Remove-Item -LiteralPath $ttmp -Recurse -Force -ErrorAction SilentlyContinue
}

# --- WHAT A SESSION REOPENS UNDER ------------------------------------------
# Get-SRSelected feeds --title, -n and the remote-control name prefix. A session
# whose title is the "(untitled)" sentinel used to come back as a tab called
# "(untitled)" and register remotely under the same -- which is precisely the
# complaint that twenty-odd reconnected sessions were unidentifiable.
$selReg = [PSCustomObject]@{
    version = 2; lastScan = $null
    directories = @(
        [PSCustomObject]@{
            path = $here; enabled = $true; missing = $false
            sessions = @(
                [PSCustomObject]@{ sessionId = 'aaaa1111'; title = 'CHOSEN'; autoTitle = 'generated words'
                                   enabled = $true; pinned = $true; gone = $false; lane = 'main'
                                   cwd = $here; jsonl = 'x'; lastActive = (Get-Date).ToString('o') },
                [PSCustomObject]@{ sessionId = 'bbbb2222'; title = '(untitled)'; autoTitle = 'Fix the slow disk'
                                   enabled = $true; pinned = $true; gone = $false; lane = 'main'
                                   cwd = $here; jsonl = 'x'; lastActive = (Get-Date).ToString('o') },
                [PSCustomObject]@{ sessionId = 'cccc3333'; title = '(untitled)'; autoTitle = ''
                                   enabled = $true; pinned = $true; gone = $false; lane = 'main'
                                   cwd = $here; jsonl = 'x'; lastActive = (Get-Date).ToString('o') }
            )
        }
    )
}
$sel = Get-SRSelected -Registry $selReg -Config $cfgNow
$byId = @{}
foreach ($row in @($sel)) { $byId["$($row.SessionId)"] = $row }
if ("$($byId['aaaa1111'].Title)" -eq 'CHOSEN') { Pass 'a chosen name is what the session reopens under' }
else { Fail "reopens as '$($byId['aaaa1111'].Title)' - a generated name outranked one somebody chose" }
if ("$($byId['bbbb2222'].Title)" -eq 'Fix the slow disk') { Pass 'a nameless session reopens under its generated name, not "(untitled)"' }
else { Fail "reopens as '$($byId['bbbb2222'].Title)' - the tab and the remote registration are both unidentifiable" }
if ("$($byId['cccc3333'].Title)" -eq '(untitled)') { Pass 'with nothing to go on it still reopens, under the placeholder' }
else { Fail "reopens as '$($byId['cccc3333'].Title)' - a session with no name at all must still launch" }
# --- A SESSION THAT HAS NEVER BEEN PROMPTED --------------------------------
# claude writes the transcript on the FIRST MESSAGE, so a window just opened and
# not yet typed into has no .jsonl anywhere -- and a walk over transcripts cannot
# see it however carefully it walks. The agent list has known about it since it
# started. Discovery reads both, and this proves the second source is wired.
Write-Host ''
Write-Host '--- a launched session with no transcript yet ---'
$ghostId = 'ffffffff-0000-1111-2222-333333333333'
$savedCache = $script:SR_AgentCache
$savedAt    = $script:SR_AgentCacheAt
try {
    # Seed the agent cache with a session that is RUNNING and has written nothing.
    # Its cwd is this repo, which exists and is not excluded.
    $ghostCwd = Split-Path $here -Parent
    $script:SR_AgentCache = @{
        $ghostId = [PSCustomObject]@{
            Status = 'idle'; WaitingFor = ''; Needs = $false; Pid = 999999
            Kind = 'interactive'; Name = 'GHOST'; Cwd = $ghostCwd; StartedAt = (Get-Date)
        }
    }
    $script:SR_AgentCacheAt = Get-Date

    $cfgNow2 = Get-SRConfig
    # 🪤 WITH A CACHE, THE WAY PRODUCTION CALLS IT.
    #
    # This passed no cache, so the walk re-read every transcript on the machine --
    # and Get-SRDiscovered consults the agent list at the END of that walk, while
    # the agent cache seeded above lives for FIVE SECONDS. A walk slower than that
    # evicted the ghost before anything looked for it, and the suite reported "the
    # tool cannot find what it launched" about a tool that finds it perfectly well.
    #
    # It is also just wrong as a test: every real caller passes the previous scan's
    # results, which is what makes a repeat scan nearly free. Testing the one shape
    # production never uses measured the wrong thing slowly.
    $ghostCache = @{}
    foreach ($cd in @($reg.directories)) {
        foreach ($cs in @($cd.sessions)) {
            if ($cs.sessionId -and $cs.stamp -and $cs.cwd) {
                $ghostCache[$cs.sessionId] = @{ Cwd = $cs.cwd; Title = $cs.title; Stamp = $cs.stamp; AutoTitle = $cs.autoTitle }
            }
        }
    }
    # ASSIGN, THEN WRAP -- the house rule, and it is correct against either shape.
    $discRaw = Get-SRDiscovered -Config $cfgNow2 -Cache $ghostCache
    $disc = @($discRaw)
    $ghost = @($disc | Where-Object { "$($_.SessionId)".ToLower() -eq $ghostId })
    if (-not $ghost.Count) {
        Fail 'a running session with no transcript was not discovered - the tool cannot find what it launched'
    } else {
        Pass 'a running session with no transcript is discovered from the agent list'
        if ("$($ghost[0].Title)" -ne 'GHOST') { Fail "it came back titled '$($ghost[0].Title)', not its agent name" }
        else { Pass 'it carries the name claude reports for it' }
    }
} finally {
    $script:SR_AgentCache   = $savedCache
    $script:SR_AgentCacheAt = $savedAt
}
# --- A REMOTE NAME MUST SURVIVE A RE-REGISTRATION ---------------------------
# --remote-control <name> names one registration. Sign in to another account, or
# re-enable Remote Control by hand, and claude names the new registration ITSELF
# from a prefix that defaults to the HOSTNAME -- so every session on the machine
# arrives in the app under the same one. The operator had twenty and could not
# tell them apart.
Write-Host ''
Write-Host '--- the remote name survives a re-registration ---'
$bootTitle = "Q-lane's test"   # an apostrophe, because it goes into a quoted literal
$bootPath = New-SRBootScript -Dir $here -SessionId '11111111-2222-3333-4444-555555555555' -Title $bootTitle
try {
    $boot = Get-Content -LiteralPath $bootPath -Raw
    if ($boot -notmatch 'CLAUDE_REMOTE_CONTROL_SESSION_NAME_PREFIX') {
        Fail 'the boot script does not set the remote-control name prefix - a re-registration would fall back to the hostname'
    } else { Pass 'the boot script sets the remote-control name prefix' }
    # The prefix has to be THIS conversation's title, or it is just a different
    # thing that is the same for every session.
    if ($boot -notmatch [regex]::Escape("PREFIX = 'Q-lane''s test'")) {
        Fail 'the prefix is not the session title, correctly quoted'
    } else { Pass 'the prefix is the session title, with the quote escaped' }
    # And the explicit name still goes on the command, because it is what wins
    # while the registration lasts.
    if ($boot -notmatch '--remote-control') { Fail 'the launch no longer names the remote session explicitly' }
    else { Pass 'the explicit --remote-control name is still passed' }
} finally {
    Remove-Item -LiteralPath $bootPath -Force -ErrorAction SilentlyContinue
}

# --- PER-SESSION SETTINGS BECOME LAUNCH FLAGS ------------------------------
# 🔴 THE DEFAULT IS THE DANGEROUS CASE. --remote-control used to be hard-coded on
# every launch; it is now conditional so a conversation can turn it off. If the
# default ever flips, Remote Control silently switches off for all twenty-odd
# sessions on this machine and nothing announces it.
Write-Host ''
Write-Host '--- a conversation carries its own launch flags ---'
$plain = [PSCustomObject]@{ sessionId = '11111111-2222-3333-4444-555555555555'; title = 'plain' }
if (-not (Test-SRRemoteWanted $plain)) {
    Fail 'a conversation with no settings does NOT want Remote Control - every existing session would lose it'
} else { Pass 'Remote Control is on unless a conversation says otherwise' }
if (@(Get-SRSessionArgs $plain).Count -ne 0) {
    Fail "a conversation with no settings produced flags: $((Get-SRSessionArgs $plain) -join ' ')"
} else { Pass 'a conversation with no settings adds no flags at all' }

Set-SRSessionPref $plain 'model' 'opus'
Set-SRSessionPref $plain 'effort' 'high'
Set-SRSessionPref $plain 'permissionMode' 'plan'
$fl = @(Get-SRSessionArgs $plain)
foreach ($pair in @(@('--model','opus'), @('--effort','high'), @('--permission-mode','plan'))) {
    $i = [array]::IndexOf($fl, $pair[0])
    if ($i -lt 0) { Fail "$($pair[0]) is not passed" }
    elseif ($fl[$i + 1] -ne $pair[1]) { Fail "$($pair[0]) got '$($fl[$i + 1])', expected '$($pair[1])'" }
    else { Pass "$($pair[0]) $($pair[1]) reaches the command line" }
}

# A value claude would reject must never reach the command line: it does not fail
# politely, it fails the LAUNCH, and the conversation simply never opens.
Set-SRSessionPref $plain 'permissionMode' 'nonsense'
Set-SRSessionPref $plain 'effort' 'ludicrous'
$fl2 = @(Get-SRSessionArgs $plain)
if ($fl2 -contains 'nonsense' -or $fl2 -contains 'ludicrous') {
    Fail "a value claude cannot accept reached the command line: $($fl2 -join ' ')"
} else { Pass 'a permission mode or effort claude would reject is dropped, not passed on' }

# And Remote Control off means the flag is ABSENT, not present-and-empty.
Set-SRSessionPref $plain 'remoteControl' $false
if (Test-SRRemoteWanted $plain) { Fail 'turning Remote Control off did not take' }
else { Pass 'Remote Control can be turned off for one conversation' }
$bp2 = New-SRBootScript -Dir $here -SessionId $plain.sessionId -Title 'no-remote' -RemoteControl $false
try {
    # 🪤 MATCH THE COMMAND LINE, NOT THE FILE. The boot script explains
    # --remote-control in a comment, so a plain -match on the whole file is
    # satisfied by the prose and would pass however the code behaved. Only the
    # '& claude ...' line decides anything.
    $b2 = @(Get-Content -LiteralPath $bp2) | Where-Object { $_ -match '^&\s*claude\b' }
    if (-not $b2) { Fail 'the boot script has no claude command line at all' }
    elseif ($b2 -match '--remote-control') { Fail "the flag is still on the command line with Remote Control off: $b2" }
    else { Pass 'with Remote Control off the flag is absent from the command, not empty' }
} finally { Remove-Item -LiteralPath $bp2 -Force -ErrorAction SilentlyContinue }

# And the inverse, so the check above is known to be capable of failing.
$bp3 = New-SRBootScript -Dir $here -SessionId $plain.sessionId -Title 'yes-remote' -RemoteControl $true
try {
    $b3 = @(Get-Content -LiteralPath $bp3) | Where-Object { $_ -match '^&\s*claude\b' }
    if ($b3 -notmatch '--remote-control') { Fail 'Remote Control ON did not put the flag on the command line' }
    else { Pass 'and with it on the flag IS there - the check above can go red' }
} finally { Remove-Item -LiteralPath $bp3 -Force -ErrorAction SilentlyContinue }
# --- THE SCREEN IS THE ONLY PLACE A PENDING QUESTION EXISTS -----------------
# claude writes the AskUserQuestion tool_use block when the tool RETURNS, not when
# it is asked. Measured against a live session with a menu visibly on screen: zero
# blocks in the transcript, one the moment it was answered. A window reading the
# transcript would say 'waiting' forever and never show what was wanted.
#
# The parser is exercised here rather than against a live session, because whether
# a menu happens to be up when the suite runs is not something a test may depend on.
# The fixture below is REAL screen text, captured from one of the operator's own
# sessions on 2026-08-24.
Write-Host ''
Write-Host '--- reading a question off the screen ---'
$CUR = [string][char]0x276F   # the cursor marker, by code: a literal would mojibake
$BAR = [string][char]0x2502

$screen = @(
    ''
    "$BAR R-136's rollback rested on my misreading. What should happen to the four migrations now?"
    ''
    "$CUR 1. Record the correction, leave the rollback standing (Recommended)"
    '     Amend R-136 with a correction section and file the finding, but do not re-apply.'
    ''
    '  2. Re-apply all four now'
    '     Restores the bitemporal re-key the other lanes want.'
    ''
    '  3. Re-apply only 267/269 (coinmetrics)'
    '     Coinmetrics collapsed 17 to 1 rather than to zero.'
    ''
    '  4. Type something'
    '  5. Chat about this'
) -join "`n"

# The parser is the half that can be tested without a console, so it is tested
# directly. Screen() itself is proven by the live probe, not here.
$parsed = Invoke-SRParseScreenQuestion -Text $screen
if (-not $parsed) { Fail 'a menu on screen was not recognised at all' }
else {
    if ($parsed.Options.Count -ne 5) { Fail "read $($parsed.Options.Count) option(s), expected 5" }
    else { Pass 'all five options are read, including Type something and Chat about this' }
    # 🔑 THE TRANSCRIPT WOULD HAVE SAID THREE. Those last two are added by the TUI
    # and appear in no tool input, so anything counting options from the transcript
    # is wrong about the menu it is driving.
    if ("$($parsed.Options[0])" -notlike 'Record the correction*') { Fail "option 1 read as '$($parsed.Options[0])'" }
    else { Pass 'the first option keeps its full label' }
    if ($parsed.CursorAt -ne 0) { Fail "the cursor was read as option $($parsed.CursorAt + 1), expected 1" }
    else { Pass 'the cursor position is read from the screen rather than assumed' }
    if ("$($parsed.Question)" -notlike '*four migrations*') { Fail "the question read as '$($parsed.Question)'" }
    else { Pass 'the question text is recovered without its box-drawing' }

    # --- THE TEXT UNDER THE ANSWERS ----------------------------------------
    # The parser used to walk UPWARDS only, so everything below option 1 was
    # discarded before it could reach the window - and that is where the
    # reasoning lives. Choosing between "Recommended" and the rest on the label
    # alone is choosing on a quarter of what was written.
    if (@($parsed.Details).Count -ne @($parsed.Options).Count) {
        Fail "$(@($parsed.Details).Count) detail(s) for $(@($parsed.Options).Count) option(s) - they must stay parallel or a detail lands under the wrong answer"
    } else { Pass 'every option has a detail slot, in step with the options' }

    if ("$($parsed.Details[0])" -notlike '*Amend R-136*') {
        Fail "option 1's detail read as '$($parsed.Details[0])'"
    } else { Pass "option 1 carries its own explanation: 'Amend R-136 with a correction section...'" }

    if ("$($parsed.Details[1])" -notlike '*bitemporal re-key*') {
        Fail "option 2's detail read as '$($parsed.Details[1])'"
    } else { Pass 'option 2 carries its own explanation, not option 1s' }

    # An option with nothing under it must come back EMPTY rather than borrowing
    # the next option's text - that would attach reasoning to the wrong answer,
    # which is worse than showing none.
    if ("$($parsed.Details[3])".Trim()) {
        Fail "option 4 ('Type something') invented a detail: '$($parsed.Details[3])'"
    } else { Pass 'an option with no explanation gets an empty one, not its neighbour s' }

    # None of claude's own furniture may leak in.
    $leak = @(@($parsed.Details) + @($parsed.Footer) | Where-Object { "$_" -match 'Model:|shift\+tab' })
    if ($leak.Count) { Fail "claude's status line leaked into the question: '$($leak[0])'" }
    else { Pass 'the input box and status line are not mistaken for question text' }
}

# --- AND THE FOOTER, WHICH IS A DIFFERENT THING ----------------------------
# A note after the LAST option qualifies the whole question rather than any one
# answer, so it cannot be stored against an option.
Write-Host ''
Write-Host '--- the note under the whole question ---'
$withFooter = @(
    ''
    "$BAR Which lane should take the repair?"
    ''
    "$CUR 1. F2-SPINE"
    '     It already owns the spine.'
    ''
    '  2. KERNEL-4'
    '     Idle since this morning.'
    ''
    'Either way the gate re-runs before anything lands.'
    ''
    '  ' + ([string][char]0x2500) * 40
    "$([string][char]0x276F) "
    '  Model: Opus 5 | shift+tab to cycle'
) -join "`n"
$pf = Invoke-SRParseScreenQuestion -Text $withFooter
if (-not $pf) { Fail 'the menu with a trailing note was not recognised at all' }
else {
    if (@($pf.Options).Count -ne 2) { Fail "read $(@($pf.Options).Count) option(s), expected 2" }
    else { Pass 'the trailing note did not get counted as an option' }
    if ("$($pf.Footer)" -notlike '*gate re-runs*') { Fail "the footer read as '$($pf.Footer)'" }
    else { Pass "the note under the whole question is kept: 'Either way the gate re-runs...'" }
    if ("$($pf.Footer)" -match 'Model:|2500|shift\+tab') { Fail "the footer swallowed claude's chrome: '$($pf.Footer)'" }
    else { Pass 'the footer stops at the input box' }
    if ("$($pf.Details[1])" -like '*gate re-runs*') { Fail 'the whole-question note was filed under option 2' }
    else { Pass 'a whole-question note is not attached to the last option' }
}

# --- A REAL MULTI-SELECT MENU, CAPTURED ------------------------------------
# 🔑 THESE ARE THE ACTUAL BYTES. Read off a live multi-select menu in this tool's
# own session on 2026-08-26 by attaching to its console, and it settled three
# things that had been guessed at for days:
#
#   the box is ASCII "[ ]"      not U+25A1. A parser tuned to a Unicode box would
#                               have matched NOTHING on the real thing.
#   the cursor is the same      U+276F, exactly as on a single-select menu.
#   there is a Submit row       unnumbered, indented, under the last option, and
#                               navigable -- so it is a cursor stop.
#
# The whole feature waited on this capture rather than being guessed at, and this
# fixture is why the guess is no longer necessary.
$multi = @(
    ''
    "$BAR The signed plan is complete. Which of these should I pick up next?"
    "$BAR (Pick as many as you want.)"
    ''
    "$CUR 1. [ ] Finish multi-select answering"
    '  Right now a question that takes several answers is shown but not clickable.'
    '  2. [ ] Environment hygiene sweep'
    '  Clear OS-temp entries older than two days and prune stale shell snapshots.'
    '  3. [ ] Polish the roster visually'
    '  4. [ ] Audit today''s changes for interaction bugs'
    '  5. [ ] Type something'
    '     Submit'
    ('-' * 40)
    '  6. Chat about this'
    ''
    'Enter to select   up/down to navigate   Esc to cancel'
) -join "`n"

$pm = Invoke-SRParseScreenQuestion -Text $multi
if (-not $pm) { Fail 'a real multi-select menu was not recognised at all' }
else {
    if (-not $pm.Multi) { Fail 'the captured menu was not recognised as multi-select' }
    else { Pass 'a real multi-select menu is recognised by its boxes' }
    if ($pm.Options.Count -ne 6) { Fail "read $($pm.Options.Count) option(s), expected 6" }
    else { Pass 'all six options are read, Chat about this included' }
    # THE BOX MUST NOT END UP IN THE LABEL. The label is what gets shown and
    # compared, and "[ ] Environment hygiene sweep" is not what was asked.
    if ("$($pm.Options[1])" -ne 'Environment hygiene sweep') { Fail "option 2 read as '$($pm.Options[1])'" }
    else { Pass "the box is stripped from the label: '$($pm.Options[1])'" }
    if ($pm.SubmitAt -ne 6) { Fail "Submit read as stop $($pm.SubmitAt), expected 6 - one past the last option" }
    else { Pass 'the Submit row is one cursor stop past the last option' }
    if (@($pm.Ticked).Count -ne 0) { Fail "$(@($pm.Ticked).Count) option(s) read as ticked on a menu where none are" }
    else { Pass 'an empty box does not read as ticked' }
    if ($pm.CursorAt -ne 0) { Fail "the highlight read as option $($pm.CursorAt + 1), expected 1" }
    else { Pass 'the highlight is read from a multi-select menu too' }
}

# ...and with two of them ticked, which is the state nobody had captured.
$multiOn = $multi.Replace('1. [ ] Finish', '1. [x] Finish').Replace('3. [ ] Polish', '3. [x] Polish')
$pm2 = Invoke-SRParseScreenQuestion -Text $multiOn
if (-not $pm2) { Fail 'a multi-select menu with ticks was not recognised' }
elseif (@($pm2.Ticked).Count -ne 2) { Fail "read $(@($pm2.Ticked).Count) ticked option(s), expected 2" }
elseif ([int]@($pm2.Ticked)[0] -ne 0 -or [int]@($pm2.Ticked)[1] -ne 2) { Fail "ticked options read as $((@($pm2.Ticked)) -join ', '), expected 0, 2" }
else { Pass 'a ticked box is read back as ticked, by index' }

# A SINGLE-SELECT MENU MUST NOT LOOK MULTI. Everything downstream branches on
# this, and getting it wrong would send a relay hunting for a Submit row that
# does not exist.
$pmSingle = Invoke-SRParseScreenQuestion -Text $screen
if ($pmSingle.Multi) { Fail 'a single-select menu was read as multi-select' }
elseif ($pmSingle.SubmitAt -ne -1) { Fail "a single-select menu reported a Submit row at $($pmSingle.SubmitAt)" }
else { Pass 'a menu with no boxes is not multi-select, and has no Submit row' }

# A CURSOR ON A LATER OPTION. The whole point of reading it is that it is not
# always option 1 -- a menu the operator has already arrowed through is exactly
# when a wrong assumption sends the wrong answer.
$moved = ($screen -replace [regex]::Escape($CUR + ' 1.'), '  1.') -replace '  2\.', ($CUR + ' 2.')
$p2 = Invoke-SRParseScreenQuestion -Text $moved
if (-not $p2) { Fail 'the menu stopped parsing when the cursor moved' }
elseif ($p2.CursorAt -ne 1) { Fail "the moved cursor was read as option $($p2.CursorAt + 1), expected 2" }
else { Pass 'a cursor already moved to option 2 is read as option 2' }

# NUMBERED PROSE IS NOT A MENU. A transcript on screen is full of numbered lists,
# and treating one as a menu would offer the operator buttons that answer nothing.
$prose = @('Some output:', '  1. first thing', 'unrelated line', '  7. seventh thing') -join "`n"
if (Invoke-SRParseScreenQuestion -Text $prose) { Fail 'numbered prose was read as a menu' }
else { Pass 'numbered prose that is not consecutive is not a menu' }

$single = @('  1. only one option') -join "`n"
if (Invoke-SRParseScreenQuestion -Text $single) { Fail 'a single numbered line was read as a menu' }
else { Pass 'one numbered line is not a menu' }
# ===========================================================================
Write-Host ''
Write-Host '--- two windows must not discard each other''s ticks ---'
# ===========================================================================
# 🔴 MEASURED, NOT SUPPOSED. Window A ticks a conversation and saves; window
# B, holding a copy read before that, ticks another and saves - and A's tick was
# simply gone. The whole file is serialised on every save, so the last writer
# won over everything, and the ticks decide what comes back at the next logon.
#
# 🔴 IT RUNS IN A SANDBOXED CHILD PROCESS, AND THAT IS NOT TIDINESS. A first
# version of this seeded a two-conversation registry through Save-SRRegistry -
# which writes $SR_RegistryPath, the OPERATOR'S REAL REGISTRY - and restored it
# in a finally. A run that died before the finally left the operator with two
# conversations instead of two hundred and their tick set gone. A test that can
# reach live data will eventually destroy it, however careful the finally is, so
# this one CANNOT: the child gets its own root, its own .state, and never learns
# where the real one lives.
#
# 🪤 The stamp is per-session-state, so this also cannot be posed by reading
# twice in ONE process - the second read overwrites the first's stamp and the
# save is correctly allowed. Two windows are two PROCESSES.
# 🪤 NOT UNDER $tmp. That directory is removed early, at the end of the very
# first fixture section, so creating a sandbox inside it here RE-CREATES it and
# nothing ever removes it again - a directory left behind on every single run.
# Its own root, and its own cleanup at the end of this block.
$sandRoot = Join-Path $SR_StateDir ('twowin-' + [Guid]::NewGuid().ToString('N').Substring(0, 8))
$null = New-Item -ItemType Directory -Path $sandRoot -Force
$null = New-Item -ItemType Directory -Path (Join-Path $sandRoot '.state') -Force
Copy-Item -LiteralPath (Join-Path $SR_LibDir '_common.ps1') -Destination (Join-Path $sandRoot '_common.ps1')
$cfgSrc = Join-Path (Split-Path -Parent $SR_LibDir) 'session-restore.config.json'
if (Test-Path -LiteralPath $cfgSrc) { Copy-Item -LiteralPath $cfgSrc -Destination $sandRoot }

$scenario = @'
. (Join-Path $PSScriptRoot '_common.ps1')
$seed = [PSCustomObject]@{ version = 2; lastScan = $null; directories = @(
    [PSCustomObject]@{ path = 'C:/probe'; enabled = $true; missing = $false; sessions = @(
        [PSCustomObject]@{ sessionId = 'aaa'; title = 'A'; enabled = $false; lastActive = (Get-Date).ToString('o') },
        [PSCustomObject]@{ sessionId = 'bbb'; title = 'B'; enabled = $false; lastActive = (Get-Date).ToString('o') }) } ) }
Save-SRRegistry -Registry $seed
$stampA = Get-SRRegistryStamp

# Window B reads, ticks 'B' and saves. The ordinary path.
$b = Get-SRRegistry
$b.directories[0].sessions[1].enabled = $true
Save-SRRegistry -Registry $b

# Window A, still holding the stamp from before B wrote, tries to save.
$a = Get-SRRegistry
Set-SRRegistryStamp $stampA
$a.directories[0].sessions[0].enabled = $true
try { Save-SRRegistry -Registry $a; 'A_SAVED' } catch { 'A_REFUSED' }
$f = Get-SRRegistry
'B_KEPT=' + [bool]$f.directories[0].sessions[1].enabled

# A normal save after re-reading must still work, or this is a tool that cannot save.
$c = Get-SRRegistry
$c.directories[0].sessions[0].enabled = $true
try { Save-SRRegistry -Registry $c; 'NORMAL_OK' } catch { 'NORMAL_REFUSED' }

# -Force is the deliberate override.
Set-SRRegistryStamp 'not-the-current-stamp'
try { Save-SRRegistry -Registry $c -Force; 'FORCE_OK' } catch { 'FORCE_REFUSED' }
'@
Set-Content -LiteralPath (Join-Path $sandRoot 'scenario.ps1') -Value $scenario -Encoding utf8
$res = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $sandRoot 'scenario.ps1') 2>&1
$res = @($res | ForEach-Object { "$_" })

if ($res -notcontains 'A_REFUSED') {
    Fail ('a stale window was allowed to save over the other''s ticks: ' + (($res | Select-Object -Last 5) -join ' | '))
} elseif ($res -notcontains 'B_KEPT=True') {
    Fail 'the other window''s tick was lost anyway'
} else { Pass 'a stale window is refused rather than silently discarding the other''s ticks' }
if ($res -notcontains 'NORMAL_OK') { Fail 'a normal save after re-reading was refused - the check is too strict' }
else { Pass 'a normal save, after re-reading, still goes through' }
if ($res -notcontains 'FORCE_OK') { Fail '-Force did not override the staleness check' }
else { Pass '-Force overrides it, for a caller that has already asked' }
Remove-Item -LiteralPath $sandRoot -Recurse -Force -ErrorAction SilentlyContinue

Write-Host ''
if ($fails) { Write-Host ("$fails FAILURE(S)") -ForegroundColor Red; exit 1 }
Write-Host 'all conversation-state tests passed' -ForegroundColor Green
exit 0
