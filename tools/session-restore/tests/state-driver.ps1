
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

# Worker-only, but a tenfold regression would mean something changed badly. The
# first version cost 17.4 ms each; this budget would have caught it.
if ($each -gt 12) { Fail ("{0:N1} ms per conversation - it was 3.9 when written, and 17.4 before that was fixed" -f $each) }
else { Pass ("{0:N1} ms per conversation" -f $each) }

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
Write-Host ''
if ($fails) { Write-Host ("$fails FAILURE(S)") -ForegroundColor Red; exit 1 }
Write-Host 'all conversation-state tests passed' -ForegroundColor Green
exit 0
