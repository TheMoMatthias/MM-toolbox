
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

# ===========================================================================
Write-Host ''
Write-Host '--- a typo in the config must not disable a safety limit ---'
# ===========================================================================
# 🔴 maxSessions IS THE CAP THAT STOPS A LOGON OPENING EVERY TICKED
# CONVERSATION AT ONCE. Measured 2026-08-30 on a hand-edited config: 0, -5 and
# null all produced NO CAP - `if ($cap -gt 0)` simply stopped being true - and a
# quoted "twelve" threw out of [int] at restore-sessions.ps1:167, unguarded,
# killing the whole logon restore. A safety limit a typo can disable is not one.
$cfgWas = $SR_ConfigPath
try {
    foreach ($case in @(
        @{ V = '0';          W = 12;   N = 'zero'          },
        @{ V = '-5';         W = 12;   N = 'negative'      },
        @{ V = '"twelve"';   W = 12;   N = 'a quoted word' },
        @{ V = 'null';       W = 12;   N = 'null'          },
        @{ V = '999999';     W = 1000; N = 'far too large' },
        @{ V = '6';          W = 6;    N = 'a real value'  }
    )) {
        $tmpCfg = Join-Path $SR_StateDir ('cfg-' + [Guid]::NewGuid().ToString('N').Substring(0, 8) + '.json')
        Set-Content -LiteralPath $tmpCfg -Value ('{ "maxSessions": ' + $case.V + ' }') -Encoding utf8
        $script:SR_ConfigPath = $tmpCfg
        $got = $null
        try { $got = [int](Get-SRConfig).maxSessions } catch { }
        Remove-Item -LiteralPath $tmpCfg -Force -ErrorAction SilentlyContinue
        if ($got -ne $case.W) { Fail ("maxSessions $($case.N) gave [$got], expected $($case.W)") }
        elseif ($got -le 0)   { Fail ("maxSessions $($case.N) left the cap disabled") }
        else { Pass ("maxSessions $($case.N) -> $got, so the cap still holds") }
    }

    # 🪤 AND AN UNREADABLE CONFIG MUST SAY WHAT TO DO. It threw
    # ConvertFrom-Json's own message, which names a character offset and no file.
    $badCfg = Join-Path $SR_StateDir ('cfgbad-' + [Guid]::NewGuid().ToString('N').Substring(0, 8) + '.json')
    Set-Content -LiteralPath $badCfg -Value '{ not json' -Encoding utf8
    $script:SR_ConfigPath = $badCfg
    $msg = ''
    try { $null = Get-SRConfig } catch { $msg = "$($_.Exception.Message)" }
    Remove-Item -LiteralPath $badCfg -Force -ErrorAction SilentlyContinue
    if ($msg -notmatch 'unreadable' -or $msg -notmatch 'delete') {
        Fail "an unreadable config says [$msg] - it does not name the file or the fix"
    } else { Pass 'an unreadable config names the file and what to do about it' }
} finally { $script:SR_ConfigPath = $cfgWas }

# ===========================================================================
Write-Host ''
Write-Host '--- settings chosen for a conversation that does not exist yet ---'
# ===========================================================================
# 🔴 A BRAND NEW CONVERSATION HAS NO SESSION ID, so the New session dialog
# had nothing to write its settings against and simply forgot them. That was
# harmless while the logon restore ignored settings too; since it honours them,
# a session spawned as opus/plan came back at the next logon as default. A claim
# is that promise written down, redeemed when the scan first sees the session.
$cdir = Join-Path $SR_StateDir ('claim-' + [Guid]::NewGuid().ToString('N').Substring(0, 8))
$null = New-Item -ItemType Directory -Path $cdir -Force
$null = New-Item -ItemType Directory -Path (Join-Path $cdir '.state') -Force
Copy-Item -LiteralPath (Join-Path $SR_LibDir '_common.ps1') -Destination (Join-Path $cdir '_common.ps1')
$cfgSrc3 = Join-Path (Split-Path -Parent $SR_LibDir) 'session-restore.config.json'
if (Test-Path -LiteralPath $cfgSrc3) { Copy-Item -LiteralPath $cfgSrc3 -Destination $cdir }
try {
    $cbody = @'
. (Join-Path $PSScriptRoot '_common.ps1')
Add-SRPrefClaim -Dir 'C:/proj' -Title 'NEW-ONE' -Prefs @{ model='opus'; permissionMode='plan'; remoteControl=$false }
'CLAIMS_AFTER_ADD=' + (@(Get-SRPrefClaims).Count)

# The scan discovering that conversation for the first time.
$row = [PSCustomObject]@{ sessionId='zzz'; title='NEW-ONE'; enabled=$false }
'REDEEMED=' + (Resolve-SRPrefClaim -Session $row -Dir 'C:/proj' -Title 'NEW-ONE')
'MODEL=' + (Get-SRSessionPref $row 'model')
'PERM=' + (Get-SRSessionPref $row 'permissionMode')
'REMOTE_WANTED=' + (Test-SRRemoteWanted $row)
'CLAIMS_AFTER_USE=' + (@(Get-SRPrefClaims).Count)

# Single use: a second conversation with the same name must NOT inherit them.
$row2 = [PSCustomObject]@{ sessionId='yyy'; title='NEW-ONE'; enabled=$false }
'SECOND=' + (Resolve-SRPrefClaim -Session $row2 -Dir 'C:/proj' -Title 'NEW-ONE')

# A claim for a different directory must not match.
Add-SRPrefClaim -Dir 'C:/other' -Title 'NEW-ONE' -Prefs @{ model='haiku' }
$row3 = [PSCustomObject]@{ sessionId='xxx'; title='NEW-ONE'; enabled=$false }
'WRONG_DIR=' + (Resolve-SRPrefClaim -Session $row3 -Dir 'C:/proj' -Title 'NEW-ONE')

# And an old claim expires rather than attaching to something much later.
$stale = @([PSCustomObject]@{ dir='C:/proj'; title='OLD'; at=(Get-Date).AddHours(-3).ToString('o'); prefs=[PSCustomObject]@{ model='opus' } })
($stale | ConvertTo-Json -Depth 6) | Set-Content -LiteralPath $SR_ClaimsPath -Encoding utf8
'STALE_VISIBLE=' + (@(Get-SRPrefClaims).Count)
'@
    Set-Content -LiteralPath (Join-Path $cdir 'scenario.ps1') -Value $cbody -Encoding utf8
    $co = @(& powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $cdir 'scenario.ps1') 2>&1 |
            ForEach-Object { "$_" })
    function Has { param($v) return ($co -contains $v) }
    if (-not (Has 'REDEEMED=True')) { Fail ('the claim was not redeemed: ' + (($co | Select-Object -Last 6) -join ' | ')) }
    elseif (-not ((Has 'MODEL=opus') -and (Has 'PERM=plan'))) { Fail 'the claim was redeemed but the settings did not land' }
    elseif (Has 'REMOTE_WANTED=True') { Fail 'Remote Control was turned off at spawn and did not carry through' }
    else { Pass 'settings chosen at spawn land on the conversation when the scan first sees it' }
    if (-not (Has 'CLAIMS_AFTER_USE=0')) { Fail 'the claim was not consumed - it would attach again' }
    elseif (Has 'SECOND=True') { Fail 'a second conversation with the same name inherited the settings' }
    else { Pass 'a claim is single use, so a later namesake does not inherit it' }
    if (Has 'WRONG_DIR=True') { Fail 'a claim matched a conversation in a different directory' }
    else { Pass 'a claim does not match across directories' }
    if (-not (Has 'STALE_VISIBLE=0')) { Fail 'a three-hour-old claim is still live - it could attach to anything' }
    else { Pass 'a claim expires rather than waiting indefinitely' }
} finally { Remove-Item -LiteralPath $cdir -Recurse -Force -ErrorAction SilentlyContinue }

# ===========================================================================
Write-Host ''
Write-Host '--- a rescan must not discard unsaved ticks ---'
# ===========================================================================
# 🔴 A SCAN READS THE REGISTRY FROM DISK. Anything ticked but not yet saved
# was never on disk, so the scan could not see it, and the caller then re-read
# the file it had just written - replacing the in-memory copy that held those
# ticks. Pressing Rescan with unsaved work threw it away with nothing said.
#
# 🪤 SANDBOXED CHILD, for the same reason as the two-window test: this runs a
# REAL scan, and a scan against the operator's own registry is exactly the
# accident that destroyed it. The child gets its own root and never learns where
# the real one is.
$rdir = Join-Path $SR_StateDir ('rescan-' + [Guid]::NewGuid().ToString('N').Substring(0, 8))
$null = New-Item -ItemType Directory -Path $rdir -Force
$null = New-Item -ItemType Directory -Path (Join-Path $rdir '.state') -Force
Copy-Item -LiteralPath (Join-Path $SR_LibDir '_common.ps1') -Destination (Join-Path $rdir '_common.ps1')
$cfgSrc2 = Join-Path (Split-Path -Parent $SR_LibDir) 'session-restore.config.json'
if (Test-Path -LiteralPath $cfgSrc2) { Copy-Item -LiteralPath $cfgSrc2 -Destination $rdir }
try {
    $body = @'
. (Join-Path $PSScriptRoot '_common.ps1')
$seed = [PSCustomObject]@{ version = 2; lastScan = $null; directories = @(
    [PSCustomObject]@{ path = 'C:/rescan-probe'; enabled = $true; missing = $false; sessions = @(
        [PSCustomObject]@{ sessionId = 'aaa'; title = 'A'; enabled = $false; lastActive = (Get-Date).ToString('o') }) } ) }
Save-SRRegistry -Registry $seed

# The window's state: a tick made in memory and NOT yet saved.
$reg = Get-SRRegistry
$reg.directories[0].sessions[0].enabled = $true

$r = Invoke-SRRescan -Registry $reg -Config (Get-SRConfig) -Dirty $true -Quiet
'SAVED=' + $r.Saved
'SCANNED=' + $r.Scanned
$after = Get-SRRegistry
$keep = @($after.directories | Where-Object { "$($_.path)" -eq 'C:/rescan-probe' })
'TICK_SURVIVED=' + [bool](@($keep[0].sessions | Where-Object { $_.sessionId -eq 'aaa' })[0].enabled)
'@
    Set-Content -LiteralPath (Join-Path $rdir 'scenario.ps1') -Value $body -Encoding utf8
    $out = @(& powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $rdir 'scenario.ps1') 2>&1 |
             ForEach-Object { "$_" })
    if ($out -notcontains 'SAVED=True') {
        Fail ('the rescan did not save the unsaved ticks first: ' + (($out | Select-Object -Last 4) -join ' | '))
    } elseif ($out -notcontains 'TICK_SURVIVED=True') {
        Fail 'a rescan discarded a tick that had not been saved yet'
    } else { Pass 'a rescan saves unsaved ticks first, and they survive it' }

    # 🪤 AND A FAILED SAVE MUST STOP THE SCAN, not let it run over the top.
    # Nothing to point at but the contract, so it is asserted on the shape: a
    # refusal reports Saved false, Scanned false, and says why.
    $body2 = @'
. (Join-Path $PSScriptRoot '_common.ps1')
$reg = Get-SRRegistry
# A stale stamp makes the save refuse - the two-window guard - which is the
# cheapest honest way to make the save fail.
Set-SRRegistryStamp 'definitely-not-the-current-stamp'
[System.IO.File]::AppendAllText($SR_RegistryPath, ' ')   # move the file on
$r = Invoke-SRRescan -Registry $reg -Config (Get-SRConfig) -Dirty $true -Quiet
'SAVED=' + $r.Saved
'SCANNED=' + $r.Scanned
'WHY=' + [bool]("$($r.Why)".Trim())
'@
    Set-Content -LiteralPath (Join-Path $rdir 'scenario2.ps1') -Value $body2 -Encoding utf8
    $out2 = @(& powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $rdir 'scenario2.ps1') 2>&1 |
              ForEach-Object { "$_" })
    if ($out2 -contains 'SCANNED=True') { Fail 'the save failed and the rescan ran anyway - it would discard the ticks' }
    elseif ($out2 -notcontains 'WHY=True') { Fail 'the rescan refused without saying why' }
    else { Pass 'a failed save stops the rescan, and it says why' }
} finally { Remove-Item -LiteralPath $rdir -Recurse -Force -ErrorAction SilentlyContinue }

# ===========================================================================
Write-Host ''
Write-Host '--- the parser, against transcripts that are not well formed ---'
# ===========================================================================
# 🪤 THE MALFORMED CASE IS THE NORMAL CASE HERE. Get-SRLastSaid seeks
# BACKWARDS a fixed number of bytes, so the first line it sees is almost always a
# FRAGMENT of a record - and the file is being appended to by another process
# while it reads, so the last line is regularly half-written. Neither is an edge
# case; both happen on every read of a busy conversation.
#
# These also cover the escalation added on 2026-08-30, which widens the window
# when the tail is all tool traffic. A wrong answer here is silent: the manager
# just shows a blank, or worse, the wrong line.
$pdir = Join-Path $SR_StateDir ('parse-' + [Guid]::NewGuid().ToString('N').Substring(0, 8))
$null = New-Item -ItemType Directory -Path $pdir -Force
try {
    $gd = '{"type":"assistant","timestamp":"2026-08-30T10:00:00Z","message":{"content":[{"type":"text","text":"REAL PROSE"}]}}'
    $tl = '{"type":"assistant","timestamp":"2026-08-30T10:00:01Z","message":{"content":[{"type":"tool_use","name":"Bash","input":{"command":"echo hi"}}]}}'
    $utf8 = New-Object System.Text.UTF8Encoding $false
    $cases = @(
        @{ N = 'a tail that starts mid-record'; T = ('ext":"cut record"}]}}' + "`n" + $gd);            W = 'REAL PROSE' },
        @{ N = 'a half-written last line';      T = ($gd + "`n" + '{"type":"assist');                  W = 'REAL PROSE' },
        @{ N = 'a BOM in the middle';           T = ($gd + "`n" + [char]0xFEFF + $tl);                  W = 'REAL PROSE' },
        @{ N = 'CRLF line endings';             T = ($gd + "`r`n" + $tl + "`r`n");                     W = 'REAL PROSE' },
        @{ N = 'the newest line wins';          T = ($gd + "`n" + ($gd -replace 'REAL PROSE','NEWEST')); W = 'NEWEST' },
        @{ N = 'a user turn is not what it said'; T = ($gd + "`n" + '{"type":"user","message":{"content":[{"type":"text","text":"I TYPED THIS"}]}}'); W = 'REAL PROSE' },
        @{ N = 'nothing but tool traffic';      T = (($tl + "`n") * 40);                                W = '' },
        @{ N = 'not JSON at all';               T = "hello`nworld";                                     W = '' },
        @{ N = 'an empty file';                 T = '';                                                 W = '' }
    )
    foreach ($c in $cases) {
        $fp = Join-Path $pdir ((($c.N) -replace '[^A-Za-z]', '_') + '.jsonl')
        [System.IO.File]::WriteAllText($fp, [string]$c.T, $utf8)
        $r = $null
        try { $r = Get-SRLastSaid -JsonlPath $fp } catch { Fail ("$($c.N) THREW: " + $_.Exception.Message); continue }
        $got = "$($r.Said)".Trim()
        if ($got -ne $c.W) { Fail ("$($c.N): said [$got], expected [$($c.W)]") }
        else { Pass ("$($c.N) -> " + $(if ($got) { "[$got]" } else { 'nothing, correctly' })) }
    }

    # 🔴 THE PENDING TOOL MUST BE THE CURRENT ONE. The escalation reaches
    # further back on a miss, so it can see an OLDER tool_use - reporting a
    # conversation as running something it finished minutes ago.
    $fp = Join-Path $pdir 'pending.jsonl'
    [System.IO.File]::WriteAllText($fp,
        ('{"type":"assistant","message":{"content":[{"type":"tool_use","name":"OLD","input":{"command":"old"}}]}}' + "`n" +
         $gd + "`n" +
         '{"type":"assistant","message":{"content":[{"type":"tool_use","name":"CURRENT","input":{"command":"now"}}]}}'), $utf8)
    $r = Get-SRLastSaid -JsonlPath $fp
    if ("$($r.Pending)" -notlike 'CURRENT*') { Fail "the pending tool is [$($r.Pending)], not the current one" }
    else { Pass 'the pending tool is the current one, not an older one further back' }
} finally { Remove-Item -LiteralPath $pdir -Recurse -Force -ErrorAction SilentlyContinue }

# ===========================================================================
Write-Host ''
Write-Host '--- the logon restore honours per-session settings ---'
# ===========================================================================
# 🔴 THE ONE PATH THAT RUNS WHILE NOBODY IS WATCHING WAS THE ONE IGNORING
# THEM. Get-SRSelected handed the restore only ids and titles, so every
# conversation came back at logon with no model, no effort, no permission mode,
# no tool rules and not hidden - and with Remote Control forced ON, because
# New-SRBootScript defaults it true. Every setting worked when launched from the
# window and was dropped on the automatic path, which is the path the tool
# exists for. Asserted here because a defect on it is invisible until morning.
$probeSess = [PSCustomObject]@{
    sessionId = '11111111-2222-3333-4444-555555555555'; title = 'LOGON-PROBE'
    enabled = $true; lastActive = (Get-Date).ToString('o')
}
$probeDir = [PSCustomObject]@{ path = $env:TEMP; enabled = $true; missing = $false; sessions = @($probeSess) }
$probeReg = [PSCustomObject]@{ version = 2; lastScan = $null; directories = @($probeDir) }
# 🪤 NO @() AROUND IT. Get-SRSelected returns `,@(...)` to stop a
# multi-element result unrolling, so wrapping the call in @() nests it and
# $sel[0] comes back as the inner ARRAY - which reported the Session property
# as missing when it was there. Every real caller assigns it bare; so does this.
$sel = Get-SRSelected -Registry $probeReg -Config (Get-SRConfig)
$sel = @($sel)
if (-not $sel.Count) { Fail 'the probe conversation was not selected at all' }
elseif (-not $sel[0].PSObject.Properties['Session']) {
    Fail 'a selected entry carries no Session - the logon path cannot see any setting'
} else {
    Pass 'a selected entry carries the session, so its settings are reachable at logon'
    $ps = $sel[0].Session
    Set-SRSessionPref $ps 'model' 'opus'
    Set-SRSessionPref $ps 'permissionMode' 'plan'
    Set-SRSessionPref $ps 'remoteControl' $false
    $bp = New-SRBootScript -Dir $env:TEMP -SessionId $sel[0].SessionId -Title 'LOGON-PROBE' `
              -ClaudeArgs (@(Get-SRSessionArgs $ps)) -RemoteControl ([bool](Test-SRRemoteWanted $ps))
    try {
        $ln = @(Get-Content -LiteralPath $bp | Where-Object { $_ -like '*claude*--resume*' })[0]
        $miss = @()
        foreach ($bit in @('--model', 'opus', '--permission-mode', 'plan')) {
            if ("$ln" -notmatch [regex]::Escape($bit)) { $miss += $bit }
        }
        if ($miss.Count) { Fail ('the logon command drops: ' + ($miss -join ', ')) }
        else { Pass 'model, effort and permission mode reach the logon command line' }
        # 🪤 AND THE OFF CASE, or this passes on a builder that always adds
        # everything. Remote Control defaults ON, so OFF is the one worth proving.
        if ("$ln" -match 'remote-control') { Fail 'Remote Control was turned OFF and the logon command still passes it' }
        else { Pass 'a conversation with Remote Control off does not get it at logon' }
    } finally { Remove-Item -LiteralPath $bp -Force -ErrorAction SilentlyContinue }
}

# --- WHAT THE TERMINAL PRINTS THAT THE PANE USED TO SWALLOW ----------------
# 🔴 The reader took `user` and `assistant` records and dropped EVERYTHING else
# on the floor. A compact writes a system record; a hook writes an attachment; a
# notice like "/remote-control is active" is a system record too. The operator
# compacted a session, looked here, and saw nothing happen - because nothing
# was drawn. Hand-built, because a real transcript only contains a compact if
# one happens to have been run inside the tail window, and the fixture also lets
# the SKIPPED kinds be asserted, which a real file cannot.
Write-Host ''
Write-Host '--- a compact, a hook and a notice all reach the reader ---'
$mixPath = Join-Path $env:TEMP ('sr-mixed-{0}.jsonl' -f ([guid]::NewGuid().ToString('N')))
try {
    [System.IO.File]::WriteAllLines($mixPath, @(
        '{"type":"system","subtype":"compact_boundary","compactMetadata":{"trigger":"manual","preTokens":184213},"timestamp":"2026-08-30T14:00:00.000Z","uuid":"a1"}',
        '{"type":"system","subtype":"turn_duration","durationMs":1342784,"timestamp":"2026-08-30T14:00:01.000Z","uuid":"a2"}',
        '{"type":"system","subtype":"informational","content":"/remote-control is active","timestamp":"2026-08-30T14:00:02.000Z","uuid":"a3"}',
        '{"type":"system","subtype":"stop_hook_summary","hookCount":1,"hookInfos":[{"command":"lane position","durationMs":8982}],"hookErrors":[],"timestamp":"2026-08-30T14:00:03.000Z","uuid":"a4"}',
        '{"type":"user","attachment":{"type":"hook_success","hookName":"UserPromptSubmit","content":"the hook said this"},"timestamp":"2026-08-30T14:00:04.000Z","uuid":"a5"}',
        '{"type":"user","attachment":{"type":"file","filename":"C:\\\\x\\\\notes.md","content":{"type":"text","file":{"filePath":"C:\\\\x\\\\notes.md","content":"one\ntwo"}}},"timestamp":"2026-08-30T14:00:05.000Z","uuid":"a6"}',
        '{"type":"user","attachment":{"type":"output_style","content":"noise"},"timestamp":"2026-08-30T14:00:06.000Z","uuid":"a7"}',
        '{"type":"user","attachment":{"type":"total_tokens_reminder","content":"noise"},"timestamp":"2026-08-30T14:00:07.000Z","uuid":"a8"}',
        '{"type":"assistant","message":{"role":"assistant","model":"claude-opus-5","content":[{"type":"text","text":"Back after the compact."}]},"timestamp":"2026-08-30T14:00:08.000Z","uuid":"a9"}'
    ), (New-Object System.Text.UTF8Encoding($false)))

    # Assign, then wrap: @(Get-SRTranscriptBlocks ...) in one step yields ONE
    # element holding every block, because the function comma-guards its return.
    $mixGot = Get-SRTranscriptBlocks -JsonlPath $mixPath -MaxRecords 60 -MaxTailBytes 60000
    $mix = @($mixGot)
    foreach ($want in @(
        @('compact', 'the compact boundary'),
        @('hook',    "the hook's own output"),
        @('file',    'the files a compact re-read'),
        @('said',    'and the reply after it'))) {
        $got = @($mix | Where-Object { $_.Kind -eq $want[0] })
        if (-not $got.Count) { Fail ("{0} never reaches the reader" -f $want[1]) }
        else { Pass ("{0} reaches the reader" -f $want[1]) }
    }
    $notice = @($mix | Where-Object { $_.Kind -eq 'system' -and "$($_.Body)" -like '*remote-control*' })
    if (-not $notice.Count) { Fail 'a system notice is still dropped' }
    else { Pass 'a system notice reaches the reader' }
    $compactBody = "$(@($mix | Where-Object { $_.Kind -eq 'compact' })[0].Body)"
    if ($compactBody -notlike '*184213*') { Fail "the compact says '$compactBody' - it should carry how much it summarised" }
    else { Pass 'the compact says how much it summarised' }

    # 🪤 AND THE NOISE STAYS OUT, or every assertion above would pass on a reader
    # that simply renders every record it sees. output_style and
    # total_tokens_reminder alone run to thousands in a real tail.
    $noise = @($mix | Where-Object { "$($_.Body)" -eq 'noise' })
    if ($noise.Count) { Fail "$($noise.Count) per-turn machinery attachment(s) reached the reader" }
    else { Pass 'per-turn machinery attachments stay out' }
    $dur = @($mix | Where-Object { "$($_.Head)" -like '*turn duration*' })
    if ($dur.Count) { Fail 'turn_duration bookkeeping reached the reader' }
    else { Pass 'turn_duration bookkeeping stays out' }
} finally { Remove-Item -LiteralPath $mixPath -Force -ErrorAction SilentlyContinue }

# --- A TOOL RESULT IS NOT A TURN -------------------------------------------
# The clock reported "3s" on a reply that had been running nine minutes, because
# every tool_result is written as a `user` record and each one reset the turn.
Write-Host ''
Write-Host '--- what counts as a turn you started ---'
foreach ($case in @(
    @{ n = 'a message you typed'; j = '{"type":"user","message":{"role":"user","content":"do the thing"}}'; want = $true },
    @{ n = 'a tool handing back a result'; j = '{"type":"user","toolUseResult":{"stdout":"ok"},"message":{"role":"user","content":[{"type":"tool_result","content":"ok"}]}}'; want = $false },
    @{ n = 'a compact summary'; j = '{"type":"user","isCompactSummary":true,"message":{"role":"user","content":"summary"}}'; want = $false },
    @{ n = "a hook's output"; j = '{"type":"user","attachment":{"type":"hook_success","content":"x"},"message":{"role":"user","content":"x"}}'; want = $false }
)) {
    $rec = $case.j | ConvertFrom-Json
    $got = [bool](Test-SRHumanTurn $rec)
    if ($got -ne $case.want) {
        Fail ("{0}: counted as a turn = {1}, expected {2}" -f $case.n, $got, $case.want)
    } else { Pass ("{0} {1} a turn you started" -f $case.n, $(if ($case.want) { 'is' } else { 'is not' })) }
}

# --- THE MODEL A SESSION IS REALLY REPLYING WITH ---------------------------
# 🔴 `<synthetic>` IS NOT A MODEL. Claude Code writes some assistant records
# itself - "No response requested.", cancellations - and stamps them
# `<synthetic>`. The vitals reader took the LAST model it saw, so one of those
# put "‹synthetic›" in the strip where the model belongs. Found by rendering the
# pane and looking at it: no assertion asked what the model WAS, only that a
# chip existed.
Write-Host ''
Write-Host '--- the model a session is really replying with ---'
$synDir = Join-Path $SR_StateDir ('syn-' + [Guid]::NewGuid().ToString('N').Substring(0, 6))
$null = New-Item -ItemType Directory -Path $synDir -Force
$synJs = Join-Path $synDir 's.jsonl'
try {
    $synRec = @(
        '{"type":"assistant","message":{"model":"claude-opus-5","content":[{"type":"text","text":"real reply"}],"usage":{"input_tokens":1000}}}',
        '{"type":"assistant","message":{"model":"<synthetic>","content":[{"type":"text","text":"No response requested."}]}}'
    ) -join "`n"
    [System.IO.File]::WriteAllText($synJs, $synRec + "`n", (New-Object System.Text.UTF8Encoding($false)))
    $synV = Get-SRSessionVitals -JsonlPath $synJs -NoDiff
    if ("$($synV.Model)" -eq '<synthetic>') {
        Fail 'a synthetic record was taken as the model - the strip would read that back to the operator'
    } elseif ("$($synV.Model)" -ne 'claude-opus-5') {
        Fail "the model read as '$($synV.Model)', expected the real one below the synthetic record"
    } else { Pass 'a synthetic record is skipped and the real model is kept' }
} finally {
    Remove-Item -LiteralPath $synDir -Recurse -Force -ErrorAction SilentlyContinue
}

# --- SUB-AGENTS AND BACKGROUND SHELLS ARE READABLE -------------------------
# 🔴 THE TOOL COULD ONLY EVER COUNT THESE. A sub-agent was an open `Task` id
# and a background shell was a line saying one had started; what either was
# doing was invisible, while the terminal showed all of it. Both turned out to
# be fully on disk, and these assertions are what stops that quietly regressing.
Write-Host ''
Write-Host '--- sub-agents and background shells ---'
$saDir = Join-Path $SR_StateDir ('sa-' + [Guid]::NewGuid().ToString('N').Substring(0, 6))
$null = New-Item -ItemType Directory -Path $saDir -Force
try {
    $saJs = Join-Path $saDir 'sess.jsonl'
    [System.IO.File]::WriteAllText($saJs, '{"type":"user","message":{"role":"user","content":"hi"}}' + "`n", (New-Object System.Text.UTF8Encoding($false)))
    $subs = Join-Path (Join-Path $saDir 'sess') 'subagents'
    $null = New-Item -ItemType Directory -Path $subs -Force

    # A teammate WITH a transcript, and a Task agent WITHOUT one. Both are real
    # states - measured 2026-08-31: 329 of 374 sub-agents on this machine have a
    # transcript and 45 do not - and the one without must not read as an error.
    [System.IO.File]::WriteAllText((Join-Path $subs 'agent-mate-aaa.meta.json'),
        '{"agentType":"gui-builder","description":"Build the window","name":"mate","taskKind":"in_process_teammate","model":"claude-opus-5"}',
        (New-Object System.Text.UTF8Encoding($false)))
    [System.IO.File]::WriteAllText((Join-Path $subs 'agent-mate-aaa.jsonl'),
        '{"type":"user","message":{"role":"user","content":"your brief"}}' + "`n",
        (New-Object System.Text.UTF8Encoding($false)))
    [System.IO.File]::WriteAllText((Join-Path $subs 'agent-probe-bbb.meta.json'),
        '{"agentType":"Explore","description":"Map the surface","toolUseId":"toolu_01ABC","spawnDepth":1}',
        (New-Object System.Text.UTF8Encoding($false)))

    $sa = @(Get-SRSubAgents -JsonlPath $saJs)
    if ($sa.Count -ne 2) { Fail "expected 2 sub-agents, got $($sa.Count)" }
    else { Pass 'both sub-agents are found beside the parent transcript' }

    $mate = @($sa | Where-Object { $_.Label -eq 'mate' })
    if (-not $mate.Count) { Fail 'the teammate was not found by its name' }
    elseif (-not $mate[0].IsTeammate) { Fail 'a teammate did not read as one' }
    elseif (-not $mate[0].HasTranscript) { Fail 'a teammate with a transcript reported none' }
    elseif ("$($mate[0].Description)" -ne 'Build the window') { Fail "the teammate's description was lost: '$($mate[0].Description)'" }
    else { Pass "the teammate carries its description and its transcript is found" }

    # A Task agent has an agentType and NO name, so the label has to fall back.
    $probe = @($sa | Where-Object { $_.AgentType -eq 'Explore' })
    if (-not $probe.Count) { Fail 'the Task sub-agent was not found' }
    elseif ($probe[0].IsTeammate) { Fail 'a Task sub-agent read as a teammate' }
    elseif ($probe[0].HasTranscript) { Fail 'an agent with no .jsonl reported having a transcript' }
    elseif ("$($probe[0].Label)" -ne 'Explore') { Fail "a nameless Task agent did not fall back to its type: '$($probe[0].Label)'" }
    elseif ("$($probe[0].ToolUseId)" -ne 'toolu_01ABC') { Fail 'the toolUseId that ties it to the parent call was lost' }
    else { Pass 'a Task sub-agent with no transcript is reported, not hidden' }

    # A conversation with no subagents directory is the common case and must be
    # cheap and silent, not an error.
    $none = @(Get-SRSubAgents -JsonlPath (Join-Path $saDir 'nothing.jsonl'))
    if ($none.Count -ne 0) { Fail "a session with no sub-agents returned $($none.Count)" }
    else { Pass 'a session with no sub-agents returns nothing rather than throwing' }

    # --- the call that starts a shell nothing else can see ---
    $bgJs = Join-Path $saDir 'bg.jsonl'
    $bgRec = @(
        '{"type":"assistant","message":{"model":"claude-opus-5","content":[{"type":"tool_use","id":"toolu_1","name":"Bash","input":{"command":"echo plain","description":"a normal command"}}]}}',
        '{"type":"user","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"toolu_1","content":"plain"}]}}',
        '{"type":"assistant","message":{"model":"claude-opus-5","content":[{"type":"tool_use","id":"toolu_2","name":"Bash","input":{"command":"sleep 600","description":"Watch for the lane to exit","run_in_background":true}}]}}',
        '{"type":"user","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"toolu_2","content":"Command running in background with ID: bq7x9zzz. Output is being written to: C:\\temp\\bq7x9zzz.output"}]}}',
        '{"type":"assistant","message":{"model":"claude-opus-5","content":[{"type":"tool_use","id":"toolu_3","name":"Task","input":{"description":"Map the touched surface","prompt":"Read every file that renders the pane; report what you find."}}]}}'
    ) -join "`n"
    [System.IO.File]::WriteAllText($bgJs, $bgRec + "`n", (New-Object System.Text.UTF8Encoding($false)))
    # 🪤 ASSIGN, THEN WRAP. Get-SRTranscriptBlocks comma-guards its return, so
    # @(Get-SRTranscriptBlocks ...) in ONE step is a single element holding
    # every block - the trap CONTEXT.md records, and one this very assertion
    # walked into while it was being written.
    $bgGot = Get-SRTranscriptBlocks -JsonlPath $bgJs -MaxRecords 50 -MaxTailBytes 65536
    $bgBl = @($bgGot)
    $tools = @($bgBl | Where-Object { $_.Kind -eq 'tool' })
    $plain = @($tools | Where-Object { $_.Head -eq 'Bash' })
    $bg    = @($tools | Where-Object { $_.Head -eq 'Bash (background)' })
    if (-not $plain.Count) { Fail 'an ordinary Bash call was not read as Bash' }
    elseif ($bg.Count -ne 1) { Fail "expected exactly 1 backgrounded Bash, got $($bg.Count)" }
    elseif ("$($bg[0].Meta)" -ne 'Watch for the lane to exit') { Fail "the shell's description was lost: '$($bg[0].Meta)'" }
    else { Pass 'a backgrounded Bash is named as one and carries its description' }

    # The whole command, not the 150 characters the block builder used to cut it
    # to - the defect that survived every fix made in the pane, because the pane
    # never had the rest of it.
    $longJs = Join-Path $saDir 'long.jsonl'
    $longCmd = 'git -C C:\Users\mauri\Documents\Millwright add ' + ('.millwright/some/quite/long/path/file{0}.json ' * 12 -f 1,2,3,4,5,6,7,8,9,10,11,12)
    $longRec = '{"type":"assistant","message":{"model":"m","content":[{"type":"tool_use","id":"t9","name":"Bash","input":{"command":"' + ($longCmd -replace '\\', '\\\\') + '"}}]}}'
    [System.IO.File]::WriteAllText($longJs, $longRec + "`n", (New-Object System.Text.UTF8Encoding($false)))
    $lGot = Get-SRTranscriptBlocks -JsonlPath $longJs -MaxRecords 50 -MaxTailBytes 65536
    $lBl = @($lGot)
    $lTool = @($lBl | Where-Object { $_.Kind -eq 'tool' })
    if (-not $lTool.Count) { Fail 'the long command produced no tool block' }
    elseif ("$($lTool[0].Body)".Length -lt 400) { Fail "the command was truncated to $("$($lTool[0].Body)".Length) chars - it is $($longCmd.Trim().Length) long" }
    elseif ("$($lTool[0].Body)" -match [string][char]0x2026) { Fail 'the command reached the renderer with an ellipsis in it' }
    else { Pass "a $($longCmd.Trim().Length)-character command reaches the renderer whole" }

    # A Task call carries what it was FOR as well as what it was given.
    $tk = @($tools | Where-Object { $_.Head -eq 'Task' })
    if ($tk.Count -ne 1) { Fail "expected 1 Task call, got $($tk.Count)" }
    elseif ("$($tk[0].Meta)" -ne 'Map the touched surface') { Fail "the Task description was lost: '$($tk[0].Meta)'" }
    elseif ("$($tk[0].Body)" -notmatch 'Read every file') { Fail 'the Task prompt - the instructions - did not reach the block' }
    else { Pass "a Task call carries both its description and the agent's instructions" }

    # --- reading a shell's output while it is still being written ---
    # 🔴 THIS IS THE LOAD-BEARING CLAIM. The shell that owns the file still has
    # it open, so a plain read throws "being used by another process" on exactly
    # the running shell this feature exists to show. FileShare::ReadWrite is
    # what makes it work, and nothing else in the suite would notice if it were
    # dropped.
    $liveOut = Join-Path $saDir 'live.output'
    $held = New-Object System.IO.FileStream($liveOut, [System.IO.FileMode]::Create,
                [System.IO.FileAccess]::Write, [System.IO.FileShare]::Read)
    try {
        $bytes = [System.Text.Encoding]::UTF8.GetBytes("LANE ab-stc EXITED after ~21min`n")
        $held.Write($bytes, 0, $bytes.Length)
        $held.Flush()
        $lo = Get-SRShellOutput -Path $liveOut
        if (-not $lo) { Fail 'the output of a still-running shell could not be read at all' }
        elseif ("$($lo.Text)" -notmatch 'LANE ab-stc EXITED') { Fail "the live output read back wrong: '$($lo.Text)'" }
        else { Pass 'a background shell is read while the shell still holds the file open' }
    } finally { $held.Dispose() }

    # The path builder reaches the filesystem with a WILDCARD in it, so anything
    # not shaped like an id is refused rather than pasted into a glob.
    $guardBad = 0
    foreach ($bad in @('../../etc', 'a\b', 'x*y', '', ('z' * 80))) {
        if ((Get-SRShellOutputPath -SessionId '444f91ed-5a95-4157-a481-de977b7ade7c' -Shell $bad)) { $guardBad++ }
    }
    if ($guardBad) { Fail "$guardBad malformed shell ids were accepted into a filesystem glob" }
    else { Pass 'a malformed shell id is refused before it reaches the filesystem' }

    # And a well-formed id for a session that has no tasks directory is simply
    # nothing - not an error, and not a guess at a path.
    if ((Get-SRShellOutputPath -SessionId 'ffffffff-0000-0000-0000-000000000000' -Shell 'babcdef12')) {
        Fail 'a shell id for an unknown session resolved to a path'
    } else { Pass 'an unknown session resolves to no output file rather than a guess' }
} finally {
    Remove-Item -LiteralPath $saDir -Recurse -Force -ErrorAction SilentlyContinue
}

# --- A QUESTION YOU ANSWERED ------------------------------------------------
# 🔴 IT USED TO ARRIVE AS A TOOL CALL, which is what made it unreadable: the
# argument slot got PowerShell's stringification of the input object
# ("@{question=The pane can't beat the transcript, which...") and the answer
# came back as one run-on line of quoted pairs with any option preview inlined
# behind pipe characters. The record carries the questions and the chosen
# answers as a MAP, so none of that has to be recovered from prose.
Write-Host ''
Write-Host '--- a question you answered ---'
$askDir = Join-Path $SR_StateDir ('askblk-' + [Guid]::NewGuid().ToString('N').Substring(0, 6))
$null = New-Item -ItemType Directory -Path $askDir -Force
$askJs = Join-Path $askDir 'a.jsonl'
try {
    $askRec = @(
        '{"type":"assistant","message":{"content":[{"type":"tool_use","id":"toolu_ASK1","name":"AskUserQuestion","input":{"questions":[{"question":"Which way?","header":"Way","options":[]}]}}]}}',
        ('{"type":"user","message":{"content":[{"type":"tool_result","tool_use_id":"toolu_ASK1","content":"Your questions have been answered: \"Which way?\"=\"Left, firmly\". You can now continue."}]},' +
         '"toolUseResult":{"answers":{"Which way?":"Left, firmly","And then?":"Stop"}}}')
    ) -join "`n"
    [System.IO.File]::WriteAllText($askJs, $askRec + "`n", (New-Object System.Text.UTF8Encoding($false)))
    $askGot = Get-SRTranscriptBlocks -JsonlPath $askJs -MaxRecords 60 -MaxTailBytes 60000
    $askBlocks = @($askGot)
    $asked = @($askBlocks | Where-Object { "$($_.Kind)" -eq 'asked' })
    if (-not $asked.Count) { Fail 'an answered question produced no asked block' }
    else {
        Pass 'an answered question becomes its own block, not a tool call'
        $pairs = @("$($asked[0].Body)" -split "`n" | Where-Object { $_.Trim() })
        if ($pairs.Count -ne 2) { Fail "the block carries $($pairs.Count) question(s), the record has 2" }
        else { Pass 'every question in the round is carried, with its answer' }
        $one = "$($pairs[0])" -split ([string][char]1), 2
        if ("$($one[0])" -ne 'Which way?' -or "$($one[1])" -ne 'Left, firmly') {
            Fail ("the first pair reads '{0}' / '{1}'" -f $one[0], $one[1])
        } else { Pass 'the question and the answer are kept apart, not run into one sentence' }
    }
    # 🪤 AND THE CALL ITSELF IS NOT DRAWN TWICE. The tool_use block was what
    # rendered the "@{question=...}" dump; emitting the answer without dropping
    # it would leave both on screen.
    $askTool = @($askBlocks | Where-Object { "$($_.Head)" -eq 'AskUserQuestion' })
    if ($askTool.Count) { Fail 'the AskUserQuestion call is still drawn as a tool block as well' }
    else { Pass 'and the call it answers is not drawn beside it' }
    if ("$($asked[0].Body)" -match 'have been answered') {
        Fail 'the block is carrying the sentence claude writes back rather than the structured answers'
    } else { Pass 'nothing is recovered from the prose - the map is the source' }
} finally {
    Remove-Item -LiteralPath $askDir -Recurse -Force -ErrorAction SilentlyContinue
}

# --- AND AGAINST REAL RECORDS, NOT ONLY HAND-BUILT ONES --------------------
# 🔴 THIS CARD HAD NEVER BEEN LOOKED AT. Its structure was asserted above from
# fixtures written to match what the parser expects - which proves the parser
# against the fixture and says nothing about whether Claude Code actually writes
# records that shape. It renders outside the visible tail on every live
# conversation tried, so no screenshot had ever contained one either. That is
# exactly the gap that let three defects ship on 2026-08-30.
#
# `asked-round.jsonl` is three ROUNDS lifted verbatim out of a real transcript -
# one single-question, two multi-question - and it is what
# SR_SHOT_JSONL draws to put the card on screen for review.
Write-Host ''
Write-Host '--- the answered-question card, from real records ---'
# 🪤 NOT $PSScriptRoot. The runner SPLICES each driver into a generated harness
# under .state\ and runs THAT, so inside a suite $PSScriptRoot is .state and not
# tests\ - the first version of this looked for the capture beside the harness
# and failed, correctly. $SR_StateDir is the anchor that holds either way: the
# tool root is its parent. The $PSScriptRoot fallback keeps a direct run of the
# driver working.
$askReal = Join-Path (Join-Path (Split-Path $SR_StateDir -Parent) 'tests') 'asked-round.jsonl'
if (-not (Test-Path -LiteralPath $askReal)) { $askReal = Join-Path $PSScriptRoot 'asked-round.jsonl' }
if (-not (Test-Path -LiteralPath $askReal)) {
    Fail "the captured round is missing: $askReal"
} else {
    # 🪤 Assign, then wrap - the comma-guard again.
    $arGot = Get-SRTranscriptBlocks -JsonlPath $askReal -MaxRecords 50 -MaxTailBytes 200000
    $arBl = @($arGot)
    $arAsk = @($arBl | Where-Object { $_.Kind -eq 'asked' })
    if ($arAsk.Count -ne 3) { Fail "expected 3 answered rounds from the capture, got $($arAsk.Count)" }
    else { Pass 'three real answered rounds are recognised as answered rounds' }

    # One line per question, question and answer split by SOH. A round that
    # collapsed to one line would be the old run-on defect coming back.
    $counts = @($arAsk | ForEach-Object { @("$($_.Body)" -split "`n" | Where-Object { $_.Trim() }).Count })
    $want = @(1, 4, 3)
    $sorted = @($counts | Sort-Object)
    $wantSorted = @($want | Sort-Object)
    if (($sorted -join ',') -ne ($wantSorted -join ',')) {
        Fail ("the rounds carried {0} questions, expected {1}" -f ($sorted -join '/'), ($wantSorted -join '/'))
    } else { Pass 'a 1-question round and two multi-question rounds all keep every question' }

    $split = 0
    foreach ($a in $arAsk) {
        foreach ($ln in @("$($a.Body)" -split "`n" | Where-Object { $_.Trim() })) {
            $bits = "$ln" -split ([string][char]1), 2
            if ($bits.Count -ne 2 -or -not "$($bits[0])".Trim() -or -not "$($bits[1])".Trim()) { $split++ }
        }
    }
    if ($split) { Fail "$split real question/answer pairs did not survive as a pair" }
    else { Pass 'every real question keeps its own answer, neither run together nor lost' }
}

# --- WHAT A SESSION SAYS ABOUT ITSELF ON ITS STATUS LINE -------------------
# 🔴 The transcript CANNOT see a running background shell: a Bash call with
# run_in_background gets its tool_result back immediately, carrying the shell
# id, so the "a call nobody answered is still running" test - correct for
# sub-agents - never fires for shells and reported zero of them forever. The
# session already prints the true count; this reads what it prints.
Write-Host ''
Write-Host '--- the counts a session prints about itself ---'
# 🔴 THE MARKER IS WRITTEN FROM ITS CODE POINT, not pasted and not stood in
# for. These cases used an ASCII ">>" placeholder, which was fine while the
# reader scanned the whole screen - and stopped being fine the moment it began
# recognising the STATUS LINE by the glyph claude starts it with, which it now
# must, because scanning everything is how a session came to report 2,100
# shells. A stand-in would have tested a line the tool never sees.
$SRMark = ([string][char]0x23F5) * 2
foreach ($sc in @(
    @{ n = 'one shell and nothing else'
       t = 'auto mode on (shift+tab to cycle) . 1 shell . <- for agents . 1 feedback draft'
       shells = 1; agents = 0; ok = $true },
    @{ n = 'shells and agents together'
       t = 'auto mode on . 3 shells . 2 agents . <- for agents'
       shells = 3; agents = 2; ok = $true },
    @{ n = 'the bare agents hint, which is NOT a count'
       t = 'auto mode on (shift+tab to cycle) . <- for agents'
       shells = 0; agents = 0; ok = $false },
    @{ n = 'a screen with no status line at all'
       t = 'just some output'; shells = 0; agents = 0; ok = $false; bare = $true }
)) {
    # The last case is deliberately NOT a status line, so it keeps no marker.
    $scText = $(if ($sc.bare) { "$($sc.t)" } else { $SRMark + ' ' + $sc.t })
    $got = Read-SRScreenVitals -ScreenText $scText
    if ($got.Shells -ne $sc.shells -or $got.Agents -ne $sc.agents -or [bool]$got.Ok -ne $sc.ok) {
        Fail ("{0}: read shells={1} agents={2} ok={3}, expected {4}/{5}/{6}" -f `
              $sc.n, $got.Shells, $got.Agents, $got.Ok, $sc.shells, $sc.agents, $sc.ok)
    } else { Pass $sc.n }
}
if ((Read-SRScreenVitals -ScreenText $null).Ok) { Fail 'an empty screen still claims to have read counts' }
else { Pass 'an unread screen reports nothing rather than zero' }

Write-Host ''
if ($fails) { Write-Host ("$fails FAILURE(S)") -ForegroundColor Red; exit 1 }
Write-Host 'all conversation-state tests passed' -ForegroundColor Green
exit 0
