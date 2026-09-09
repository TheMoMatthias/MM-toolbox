# ===========================================================================
# bands-bench - is FINISHED reachable, and can "finished but something is still
# open" be told apart from "finished and done with" WITHOUT a model?
#
# READ-ONLY. Builds the shipped window, never shows it, reads nothing but the
# model the window already built.
#
# 🔴 THE QUESTION IS PRECISION, NOT CLEVERNESS. A band that fires on everything
# says nothing; a band that fires on nothing is not a band. So this prints the
# rate AND the sentences that triggered it, because a keyword list can only be
# judged by reading what it caught.
# ===========================================================================
$ErrorActionPreference = 'Continue'
function BB-Say { param([string]$T) Write-Host $T }

BB-Say ''
BB-Say '=== bands-bench: what the board can tell apart ==='

$bbRows = New-Object System.Collections.Generic.List[object]
foreach ($r in $script:model) { if ($r.Live -or $r.Warm) { $null = $bbRows.Add($r) } }
BB-Say ('  live or warm conversations: {0}' -f $bbRows.Count)

# 🪤 THE PROBE FILLS Said, AND THIS HARNESS NEVER RUNS ONE. Update-Model is
# called -NoSaid at startup and the last-said lines arrive on the background
# probe fifteen seconds later, so a never-shown window has none - and the first
# run of this bench read "0 of 26 rows have any last-said text" and would have
# reported FINISHED as structurally unreachable on that basis. It IS unreachable
# without them; that is a fact about the probe, not about the band. So the bench
# does the probe's own read here, for the same rows, before asking anything.
$bbFilled = 0
foreach ($r in $bbRows) {
    if ($r.Said -and "$($r.Said.Said)".Trim()) { continue }
    $j = "$($r.S.jsonl)"
    if (-not $j) { continue }
    try { $r.Said = Get-SRLastSaid -JsonlPath $j; $bbFilled++ } catch { }
}
BB-Say ('  last-said lines read here  : {0}' -f $bbFilled)

# --- 1. is FINISHED reachable at all? ---------------------------------------
BB-Say ''
BB-Say '--- how the board is divided right now ---'
$bbBands = @{}
foreach ($r in $bbRows) {
    $k = "$($r.Band)"
    if (-not $bbBands.ContainsKey($k)) { $bbBands[$k] = 0 }
    $bbBands[$k] = $bbBands[$k] + 1
}
foreach ($b in $script:Bands) {
    $n = 0
    if ($bbBands.ContainsKey($b.Key)) { $n = $bbBands[$b.Key] }
    BB-Say ('  {0,-10} {1,4}' -f $b.Label, $n)
}
BB-Say ('  the handback threshold is {0} characters' -f $script:HandbackMinChars)

# --- 1b. and with Said present, where would the bands land? -----------------
# 🔴 THE BANDS ABOVE WERE DECIDED BEFORE Said EXISTED. Update-Model runs -NoSaid
# at startup, so every row took Get-Band's 'idle' arm with nothing to hand back
# and landed in IDLE. Re-deriving them now is the only way to tell "FINISHED is
# unreachable" from "FINISHED had not been computed yet".
BB-Say ''
BB-Say '--- where the bands land once the last-said lines are in ---'
$bbAfter = @{}
foreach ($r in $bbRows) {
    $k = "$(Get-Band $r)"
    if (-not $bbAfter.ContainsKey($k)) { $bbAfter[$k] = 0 }
    $bbAfter[$k] = $bbAfter[$k] + 1
}
foreach ($b in $script:Bands) {
    $n = 0
    if ($bbAfter.ContainsKey($b.Key)) { $n = $bbAfter[$b.Key] }
    BB-Say ('  {0,-10} {1,4}' -f $b.Label, $n)
}
# What the resting rule itself says, and why, for the rows that are resting.
$bbPend = 0; $bbShort = 0
foreach ($r in $bbRows) {
    $sd = $r.Said
    if (-not $sd) { continue }
    if ("$($sd.Pending)".Trim()) { $bbPend++ }
    elseif ("$($sd.Said)".Trim().Length -lt $script:HandbackMinChars) { $bbShort++ }
}
BB-Say ('  held out of FINISHED by something pending : {0}' -f $bbPend)
BB-Say ('  held out by a last line under {0} chars     : {1}' -f $script:HandbackMinChars, $bbShort)

# What else the record carries - the detector needs more than a headline.
BB-Say ''
BB-Say '--- what a last-said record actually holds ---'
foreach ($r in $bbRows) {
    if (-not $r.Said) { continue }
    $names = @($r.Said.PSObject.Properties | ForEach-Object { $_.Name })
    BB-Say ('  fields: {0}' -f ($names -join ', '))
    foreach ($n in $names) {
        $v = "$($r.Said.$n)"
        if ($v.Length -gt 90) { $v = $v.Substring(0, 90) + '...' }
        BB-Say ('    {0,-12} [{1,4} chars] {2}' -f $n, "$($r.Said.$n)".Length, ($v -replace '\s+', ' '))
    }
    break
}

# --- 2. what the last-said text actually is ---------------------------------
BB-Say ''
BB-Say '--- what the tool has to work with ---'
$bbSaid = New-Object System.Collections.Generic.List[object]
foreach ($r in $bbRows) {
    $t = ''
    if ($r.Said -and "$($r.Said.Said)".Trim()) { $t = "$($r.Said.Said)".Trim() }
    if ($t) { $null = $bbSaid.Add([PSCustomObject]@{ Id = "$($r.Id)"; Band = "$($r.Band)"; T = $t }) }
}
BB-Say ('  rows with any last-said text : {0} of {1}' -f $bbSaid.Count, $bbRows.Count)
if ($bbSaid.Count) {
    $lens = @($bbSaid | ForEach-Object { $_.T.Length } | Sort-Object)
    BB-Say ('  its length, min/median/max   : {0} / {1} / {2} characters' -f `
            $lens[0], $lens[[int][Math]::Floor($lens.Count / 2)], $lens[$lens.Count - 1])
    $multi = @($bbSaid | Where-Object { $_.T.Contains("`n") }).Count
    BB-Say ('  how many carry more than one line: {0}' -f $multi)
}

# --- 2b. the shipped predicate, against the WHOLE last message ---------------
# 🔴 THE HEADLINE COULD NEVER ANSWER THIS. Section 3 below runs the same shapes
# against Said - one line, 29-160 characters - and scores zero on all 26. The
# text that decides whether something was left open is the rest of the message,
# which is what Said.Full now carries.
BB-Say ''
BB-Say '--- Test-SROpenItems, against the whole last message ---'
$bbFull = New-Object System.Collections.Generic.List[object]
foreach ($r in $bbRows) {
    $f = ''
    if ($r.Said) { $f = "$($r.Said.Full)" }
    if (-not $f.Trim()) { continue }
    $null = $bbFull.Add([PSCustomObject]@{
        Id = "$($r.Id)"; Band = "$($r.Band)"; T = $f; Head = "$($r.Said.Said)"
        Open = [bool](Test-SROpenItems -Text $f); Why = "$(Get-SROpenItemReason -Text $f)"
    })
}
BB-Say ('  rows with a full last message : {0} of {1}' -f $bbFull.Count, $bbRows.Count)
if ($bbFull.Count) {
    $flens = @($bbFull | ForEach-Object { $_.T.Length } | Sort-Object)
    BB-Say ('  its length, min/median/max    : {0} / {1} / {2} characters' -f `
            $flens[0], $flens[[int][Math]::Floor($flens.Count / 2)], $flens[$flens.Count - 1])
    $bbHit = @($bbFull | Where-Object { $_.Open })
    BB-Say ('  left something open           : {0} of {1}  ({2:N1}%)' -f `
            $bbHit.Count, $bbFull.Count, (100.0 * $bbHit.Count / $bbFull.Count))
    BB-Say ''
    BB-Say '  by rule:'
    $byWhy = @{}
    foreach ($x in $bbHit) { if (-not $byWhy.ContainsKey($x.Why)) { $byWhy[$x.Why] = 0 }; $byWhy[$x.Why]++ }
    foreach ($k in @($byWhy.Keys | Sort-Object)) { BB-Say ('    {0,-24} {1}' -f $k, $byWhy[$k]) }
    BB-Say ''
    BB-Say '  CAUGHT - each of these should be worth a minute of attention:'
    $n = 0
    foreach ($x in $bbHit) {
        if ($n -ge 6) { break }
        BB-Say ('    [{0}] {1}' -f $x.Why, ($x.Head -replace '\s+', ' '))
        $n++
    }
    BB-Say ''
    BB-Say '  NOT CAUGHT - each of these should be genuinely done with:'
    $n = 0
    foreach ($x in $bbFull) {
        if ($n -ge 6) { break }
        if ($x.Open) { continue }
        BB-Say ('    {0}' -f ($x.Head -replace '\s+', ' '))
        $n++
    }
}

# --- 3. the candidate detectors ---------------------------------------------
# Each is deterministic, cheap, and reads only text the window already holds.
BB-Say ''
BB-Say '--- candidate signals for "finished, but something is still open" ---'
$bbTests = @(
    @{ N = 'ends with a question mark'
       F = { param($t) $t.TrimEnd().EndsWith('?') } }
    @{ N = 'an unticked checkbox'
       F = { param($t) $t -match '(?m)^\s*[-*]\s*\[\s\]' } }
    @{ N = 'names something still open'
       F = { param($t) $t -match '(?i)\b(still (open|outstanding|to do|need)|remains? (open|outstanding)|outstanding|not (yet )?(started|done|finished|landed)|still (missing|blocked)|blocked on|open (question|item|decision)s?|left to do|next step)\b' } }
    @{ N = 'puts something to you'
       F = { param($t) $t -match '(?i)\b(let me know|tell me (if|whether|which|what)|shall i\b|should i\b|would you like|do you want|your call|up to you|if you(.{0,3})d (rather|prefer)|say the word|confirm (whether|if|that))\b' } }
    @{ N = 'a numbered decision block'
       F = { param($t) $t -match '(?im)^\s*(DECISIONS?|OPEN|TODO|NEXT)\b\s*[:\-]' } }
)
foreach ($tst in $bbTests) {
    $hit = New-Object System.Collections.Generic.List[object]
    foreach ($x in $bbSaid) {
        $ok = $false
        try { $ok = [bool](& $tst.F $x.T) } catch { }
        if ($ok) { $null = $hit.Add($x) }
    }
    $pct = 0.0
    if ($bbSaid.Count) { $pct = 100.0 * $hit.Count / $bbSaid.Count }
    BB-Say ('  {0,-30} {1,4} of {2}  ({3,5:N1}%)' -f $tst.N, $hit.Count, $bbSaid.Count, $pct)
}

# --- 4. the union, which is what a band would actually use ------------------
function Test-BBOpen { param([string]$T)
    foreach ($tst in $script:bbTestsRef) {
        $ok = $false
        try { $ok = [bool](& $tst.F $T) } catch { }
        if ($ok) { return $true }
    }
    return $false
}
$script:bbTestsRef = $bbTests
$bbOpen = New-Object System.Collections.Generic.List[object]
foreach ($x in $bbSaid) { if (Test-BBOpen $x.T) { $null = $bbOpen.Add($x) } }
BB-Say ''
BB-Say ('  ANY of them: {0} of {1} ({2:N1}%)' -f $bbOpen.Count, $bbSaid.Count,
        $(if ($bbSaid.Count) { 100.0 * $bbOpen.Count / $bbSaid.Count } else { 0 }))
BB-Say ''
BB-Say '  what it caught - read these, the rate alone proves nothing:'
$bbShow = 0
foreach ($x in $bbOpen) {
    if ($bbShow -ge 8) { break }
    $one = ($x.T -replace '\s+', ' ')
    if ($one.Length -gt 150) { $one = $one.Substring(0, 150) + '...' }
    BB-Say ('    [{0,-7}] {1}' -f $x.Band, $one)
    $bbShow++
}
BB-Say ''
BB-Say '  and what it did NOT catch, which is where a missed FINISHED hides:'
$bbShow = 0
foreach ($x in $bbSaid) {
    if ($bbShow -ge 8) { break }
    if (Test-BBOpen $x.T) { continue }
    $one = ($x.T -replace '\s+', ' ')
    if ($one.Length -gt 150) { $one = $one.Substring(0, 150) + '...' }
    BB-Say ('    [{0,-7}] {1}' -f $x.Band, $one)
    $bbShow++
}

BB-Say ''
BB-Say '=== bands-bench done ==='
exit 0
