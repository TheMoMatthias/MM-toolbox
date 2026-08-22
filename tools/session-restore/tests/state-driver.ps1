
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

Write-Host ''
if ($fails) { Write-Host ("$fails FAILURE(S)") -ForegroundColor Red; exit 1 }
Write-Host 'all conversation-state tests passed' -ForegroundColor Green
exit 0
