# ===========================================================================
# refresh-bench - what the window costs to keep itself up to date, and how
# long a change takes to reach the screen.
#
# READ-ONLY. It builds the shipped window, never shows it, and never starts a
# timer, a probe or a sweep: every cost here is taken by calling the pass
# directly. Nothing is launched, typed into, sent or saved.
#
# It exists because "it does not refresh naturally" is three separate claims -
# the repaint is slow, the repaint is suppressed, or the source is stale - and
# they need different fixes.
# ===========================================================================
$ErrorActionPreference = 'Continue'

function ZZ-Med { param([double[]]$V)
    $s = @($V | Sort-Object); if (-not $s.Count) { return 0 }
    return [double]$s[[int][math]::Floor($s.Count / 2)]
}
function ZZ-Ms { param($sb, [int]$N = 7)
    $out = New-Object System.Collections.Generic.List[double]
    for ($i = 0; $i -lt $N; $i++) {
        $sw = [Diagnostics.Stopwatch]::StartNew()
        & $sb | Out-Null
        $sw.Stop()
        $null = $out.Add($sw.Elapsed.TotalMilliseconds)
    }
    return (ZZ-Med $out.ToArray())
}
function ZZ-Say { param([string]$T) Write-Host $T }

ZZ-Say ''
ZZ-Say '=== refresh-bench: the cost of staying current ==='

# --- 1. the shape of the machine -------------------------------------------
# The model is a List[object]; @() throws on one in PS 5.1.
$zzRows = New-Object System.Collections.Generic.List[object]
foreach ($zzR in $script:model) { $null = $zzRows.Add($zzR) }
$zzLive  = @($zzRows.ToArray() | Where-Object { $_.Live })
$zzWarm  = @($zzRows.ToArray() | Where-Object { $_.Warm })
$zzItems = @($ui.SessionList.Items)
ZZ-Say ''
ZZ-Say ('--- the machine ---')
ZZ-Say ('  conversations in the model : {0}' -f $zzRows.Count)
ZZ-Say ('  live                       : {0}' -f $zzLive.Count)
ZZ-Say ('  warm (last 24h)            : {0}' -f $zzWarm.Count)
ZZ-Say ('  projects                   : {0}' -f @($script:dirs).Count)
ZZ-Say ('  items drawn in the column  : {0}' -f $zzItems.Count)

# --- 2. what a repaint costs ------------------------------------------------
# Build-Sessions replaces ItemsSource, so every one of these is a full relayout
# of the column AND the loss of the scroll position. It is called by the fast
# pass, the probe, the sweep, the write lane and every click.
ZZ-Say ''
ZZ-Say '--- what one repaint costs (UI thread, blocking) ---'
# 🔴 COLD AND WARM, OR THE CACHE IS MEASURED AGAINST ITSELF. A repeated
# Build-Sessions hits the row cache from the second call on, so timing it alone
# reports the hit path and calls it "the rebuild". Clearing the cache before
# each call is the only way to see what a row that really changed costs.
$zzCold = ZZ-Ms { Clear-SRRowItemCache; Build-Sessions }
$zzBuild = ZZ-Ms { Build-Sessions }
ZZ-Say ('  Build-Sessions COLD     {0,8:N1} ms   (every row rebuilt)' -f $zzCold)
ZZ-Say ('  Build-Sessions WARM     {0,8:N1} ms   ({1:N2} ms per drawn item, nothing moved)' -f $zzBuild, $(if ($zzItems.Count) { $zzBuild / $zzItems.Count } else { 0 }))
$zzFp = ZZ-Ms { Get-ModelFingerprint }
ZZ-Say ('  Get-ModelFingerprint    {0,8:N1} ms   (the guard that decides whether to repaint)' -f $zzFp)
$zzLW = ZZ-Ms { Update-LiveWriters }
ZZ-Say ('  Update-LiveWriters      {0,8:N1} ms   (the file-stat pass over live rows)' -f $zzLW)
$zzRail = ZZ-Ms { Build-Rail }
ZZ-Say ('  Build-Rail              {0,8:N1} ms   (the projects column)' -f $zzRail)
# What the background passes actually pay: Update-Board rebuilds the rail only
# when its fingerprint moved, so the steady state is the fingerprint alone.
$zzBoard = ZZ-Ms { Update-Board }
$zzRfp = ZZ-Ms { Get-SRRailFingerprint }
ZZ-Say ('  Update-Board            {0,8:N1} ms   (both columns, nothing moved)' -f $zzBoard)
ZZ-Say ('  Get-SRRailFingerprint   {0,8:N1} ms   (the guard in front of the rail)' -f $zzRfp)
# Who can rebuild the projects column WITHOUT a gesture. Derived, because the
# answer used to be "nothing" and a bench that says so from memory is no use.
$zzBoardSrc = ''
try { $zzBoardSrc = "$((Get-Command Update-Board).ScriptBlock)" } catch { }
$zzRailBg = @()
foreach ($zzF in @('Invoke-FastPass', 'Complete-LiveProbe', 'Invoke-WriteLane')) {
    $zzB = ''
    try { $zzB = "$((Get-Command $zzF).ScriptBlock)" } catch { continue }
    if ($zzB -match 'Build-Rail' -or ($zzBoardSrc -match 'Build-Rail' -and $zzB -match 'Update-Board')) { $zzRailBg += $zzF }
}
if ($zzRailBg.Count) { ZZ-Say ('    refreshed unattended by  : {0}' -f ($zzRailBg -join ', ')) }
else { ZZ-Say '    refreshed unattended by  : NOTHING - it is only as fresh as your last click' }
$zzMgr = ZZ-Ms { Build-Manager } 3
ZZ-Say ('  Build-Manager           {0,8:N1} ms   (the manage surface)' -f $zzMgr)

# --- 3. the steady-state duty cycle ----------------------------------------
# Every rebuild is a hitch. These are the callers that can fire one without
# anybody touching the window.
ZZ-Say ''
ZZ-Say '--- how often that cost is paid with nobody touching the window ---'
ZZ-Say ('  live probe   every {0,4} s  -> Build-Sessions unconditionally' -f $script:LiveSeconds)
ZZ-Say ('  fast pass    every {0,4} s  -> only if the fingerprint moved' -f $script:FastSeconds)
ZZ-Say ('  vitals sweep every {0,4:N1} s  -> only if a screen figure changed' -f ($SR_SweepEvery / 1000))
ZZ-Say ('  vitals warm  every {0,4:N1} s  -> never repaints (by design)' -f ($SR_VitalsEvery / 1000))
ZZ-Say ('  write lane   every {0,4:N2} s  -> repaints on any live transcript write' -f (0.03))
$zzFloor = (60.0 / $script:LiveSeconds) * $zzBuild
ZZ-Say ('  FLOOR: the probe alone spends {0:N0} ms/min of UI thread on repaints nobody asked for' -f $zzFloor)

# --- 4. how stale a band can be --------------------------------------------
# Which pass can produce which transition. This is the "it does not refresh
# naturally" claim, answered from the code rather than from a feeling.
ZZ-Say ''
ZZ-Say '--- what can move a row, and how long it takes ---'
$zzSrcBand = "$((Get-Command Update-LiveWriters).ScriptBlock)"
$zzWriters = ($zzSrcBand -match "'working'")
ZZ-Say ('  needs   -> working   file growth, on the write lane      : {0}' -f $(if ($zzWriters) { 'yes, ~0.1 s' } else { 'NO' }))
ZZ-Say ('  working -> needs     screen read, on the sweep           : yes, ~{0:N1} s' -f ($SR_SweepEvery / 1000))
ZZ-Say ('  needs   -> not-needs measured absence, on the sweep      : yes, ~{0:N1} s' -f ($SR_SweepEvery / 1000))
# The rest is Get-Band over $r.Conv, which only the probe refreshes - UNLESS the
# sweep's turn clock is wired in, in which case the two the operator actually
# watches for come off the screen instead. Read from the collector rather than
# stated here: a table in a bench that the code has moved past is worse than no
# table, because it reads as a measurement.
$zzSweepSrc = "$((Get-Command Complete-VitalsSweep).ScriptBlock)"
$zzTurn = ($zzSweepSrc -match 'Test-SRTurnVerdict')
$zzSweepS = ($SR_SweepEvery / 1000)
$zzProbeS = ($script:LiveSeconds + 2)
foreach ($zzT in @('idle -> working', 'done -> working', 'working -> done', 'working -> idle')) {
    if ($zzTurn) { ZZ-Say ('  {0,-20} the turn clock, on the sweep          : yes, ~{1:N1} s' -f $zzT, $zzSweepS) }
    else         { ZZ-Say ('  {0,-20} the probe only                        : ~{1} s worst case' -f $zzT, $zzProbeS) }
}
ZZ-Say ('  {0,-20} the probe only                        : ~{1} s worst case' -f 'anything -> quiet', $zzProbeS)
if ($zzTurn) {
    ZZ-Say '  (the turn clock never moves a row out of NEEDS YOU or out of QUIET -'
    ZZ-Say '   see Test-SRTurnVerdict; a menu seen on screen outranks a spinner.)'
}

# --- 5. the context bar ----------------------------------------------------
# The bar a row draws needs a WINDOW figure, and the only source of one is a
# screen the sweep read while the session was running. It is held in memory
# only, so a window that has just opened knows none of them.
ZZ-Say ''
ZZ-Say '--- the context bar, per row ---'
$zzDrawn = @($zzItems | Where-Object { $_.Kind -eq 'session' -and $_.CtxVis -eq $V_Show })
$zzSess  = @($zzItems | Where-Object { $_.Kind -eq 'session' })
ZZ-Say ('  rows on screen                 : {0}' -f $zzSess.Count)
ZZ-Say ('  rows drawing a context bar     : {0}' -f $zzDrawn.Count)
ZZ-Say ('  windows learned from a screen  : {0}   (script:ctxWindowTrue, in memory only)' -f @($script:ctxWindowTrue.Keys).Count)
ZZ-Say ('  vitals cached                  : {0}   (the token count half)' -f @($script:vitalsCache.Keys).Count)
ZZ-Say ('  warm batch size                : {0} rows per pass, newest first' -f $SR_VitalsBatch)
if ($zzSess.Count -and -not $zzDrawn.Count) {
    ZZ-Say '  => before any warm has landed, this window draws no bars at all.'
}

# 🔴 AND NOW WITH THE CACHE WARM, which is the only version of this count that
# can go red. A never-shown window has run no warm pass, so counting bars on it
# measures the harness rather than the row: zero is the right answer either way.
# This drives one real warm - a transcript parse, off-thread, read-only - and
# asks again. Under the rule this replaced the answer stays zero however warm
# the cache is, because that rule required a window read off a live SCREEN.
ZZ-Say ''
ZZ-Say '--- the same count, after one warm pass ---'
$zzWarmSw = [Diagnostics.Stopwatch]::StartNew()
try {
    Start-VitalsWarm
    while ($zzWarmSw.Elapsed.TotalSeconds -lt 30) {
        if (Complete-VitalsWarm) { break }
        Start-Sleep -Milliseconds 100
    }
} catch { ZZ-Say ('  the warm pass would not run: ' + $_.Exception.Message) }
$zzWarmSw.Stop()
Clear-SRRowItemCache
Build-Sessions
$zzItems2 = @($ui.SessionList.Items)
$zzDrawn2 = @($zzItems2 | Where-Object { $_.Kind -eq 'session' -and $_.CtxVis -eq $V_Show })
$zzSess2  = @($zzItems2 | Where-Object { $_.Kind -eq 'session' })
ZZ-Say ('  one warm pass took             : {0:N0} ms' -f $zzWarmSw.Elapsed.TotalMilliseconds)
ZZ-Say ('  vitals cached now              : {0}' -f @($script:vitalsCache.Keys).Count)
ZZ-Say ('  rows drawing a context bar     : {0} of {1}' -f $zzDrawn2.Count, $zzSess2.Count)
if ($zzSess2.Count -and -not $zzDrawn2.Count) {
    ZZ-Say '  => STILL NONE. The bar has no source the transcript can supply.'
}

# 🔴 AND THE SAME COUNT UNDER THE RULE THIS REPLACED, in the same run. Every
# speed or coverage claim in this repo made against a number from a DIFFERENT
# run has since been withdrawn; the old rule is still reachable, so the two are
# measured side by side. It required a window the session had PRINTED, held in
# memory only - so it can only ever answer for conversations this window has
# watched running, and answers zero for everything else however warm the cache.
$zzCtxKeep = (Get-Command Get-SRRowCtx -CommandType Function).ScriptBlock
try {
    Set-Item -Path function:Get-SRRowCtx -Value {
        param($R, $Scr, $Now = $null)
        if ($Scr -and [int]$Scr.CtxWindow -gt 0) { return @{ Tok = [int]$Scr.CtxTokens; Win = [int]$Scr.CtxWindow } }
        $w = $script:ctxWindowTrue["$($R.Id)"]
        if (-not $w -or [int]$w -le 0) { return @{ Tok = 0; Win = 0 } }
        $v = Get-SRVitalsCached $R
        if (-not $v -or [int]$v.Tokens -le 0) { return @{ Tok = 0; Win = 0 } }
        return @{ Tok = [int]$v.Tokens; Win = [int]$w }
    }
    Clear-SRRowItemCache
    Build-Sessions
    $zzOldDrawn = @($ui.SessionList.Items | Where-Object { $_.Kind -eq 'session' -and $_.CtxVis -eq $V_Show })
    ZZ-Say ('  under the old rule, same cache : {0} of {1}' -f $zzOldDrawn.Count, $zzSess2.Count)
} finally {
    Set-Item -Path function:Get-SRRowCtx -Value $zzCtxKeep
    Clear-SRRowItemCache
    Build-Sessions
}

# --- 6. is the fingerprint complete? ---------------------------------------
# A repaint that is suppressed is indistinguishable from a window that has
# stopped watching. The guard must cover everything a row draws.
ZZ-Say ''
ZZ-Say '--- what the repaint guard watches, against what a row draws ---'
$zzFpSrc = "$((Get-Command Get-ModelFingerprint).ScriptBlock)"
$zzCovers = @{}
foreach ($zzF in @('Band', 'Said', 'Id', 'At')) { $zzCovers[$zzF] = [bool]($zzFpSrc -match ('\$r\.' + $zzF + '\b')) }
foreach ($zzF in @('Q', 'Sig', 'T', 'Live', 'Warm')) { $zzCovers[$zzF] = [bool]($zzFpSrc -match ('\$r\.' + $zzF + '\b')) }
foreach ($zzK in @($zzCovers.Keys | Sort-Object)) {
    ZZ-Say ('  {0,-6} {1}' -f $zzK, $(if ($zzCovers[$zzK]) { 'watched' } else { 'NOT watched - a change here cannot trigger a repaint on its own' }))
}
$zzSkip = [bool]($zzFpSrc -match 'continue')
ZZ-Say ('  rows skipped by the guard entirely: {0}' -f $(if ($zzSkip) { 'yes - anything not live, warm or selected' } else { 'no' }))

# --- 7. where the repaint's time actually goes -----------------------------
# Picking one band leaves the filter walk over every conversation exactly as it
# was and builds almost no items, so the difference isolates the per-item cost
# from the per-model cost. That decides which half is worth attacking.
ZZ-Say ''
ZZ-Say '--- inside the repaint ---'
$zzPickWas = $script:bandPick
$zzSmall = 0.0
try {
    $zzBest = 1000000
    foreach ($zzB in $script:Bands) {
        $zzN = @($zzRows.ToArray() | Where-Object { "$($_.Band)" -eq $zzB.Key -and ($_.Live -or $_.Warm) })
        if ($zzN.Count -ge 1 -and $zzN.Count -lt $zzBest) { $zzBest = $zzN.Count; $script:bandPick = $zzB.Key }
    }
    if ($script:bandPick) {
        $zzSmall = ZZ-Ms { Build-Sessions }
        $zzFew = @($ui.SessionList.Items | Where-Object { $_.Kind -eq 'session' }).Count
        ZZ-Say ('  filter walk over {0} conversations, {1} rows built : {2,6:N1} ms' -f $zzRows.Count, $zzFew, $zzSmall)
        ZZ-Say ('  full column, {0} rows built                        : {1,6:N1} ms' -f $zzSess.Count, $zzBuild)
        $zzPer = 0.0
        if (($zzSess.Count - $zzFew) -gt 0) { $zzPer = ($zzBuild - $zzSmall) / ($zzSess.Count - $zzFew) }
        ZZ-Say ('  => per row built  {0,6:N2} ms      per model row (filter) {1,6:N3} ms' -f $zzPer, $(if ($zzRows.Count) { $zzSmall / $zzRows.Count } else { 0 }))
    } else { ZZ-Say '  no band small enough to isolate against' }
} finally { $script:bandPick = $zzPickWas; Build-Sessions }

# --- 8. the source of truth's own latency ----------------------------------
# Every band that only the probe can change waits on this call. It is a process
# spawn, and it is read-only.
ZZ-Say ''
ZZ-Say '--- what the probe waits for ---'
$zzAg = ZZ-Ms { Get-SRAgentStatus -Refresh } 3
ZZ-Say ('  claude agents --json    {0,8:N0} ms   (the probe cannot be faster than this)' -f $zzAg)

# --- 9. what 1.8 ms a row is actually spent on -----------------------------
# Each of these is called once per DRAWN row inside Build-Sessions. Timed over
# the same set of rows the column is currently showing.
ZZ-Say ''
ZZ-Say '--- the per-row loop, item by item (39 rows once through) ---'
$zzDraw = New-Object System.Collections.Generic.List[object]
foreach ($zzI in $ui.SessionList.Items) { if ("$($zzI.Kind)" -eq 'session' -and $zzI.Row) { $null = $zzDraw.Add($zzI.Row) } }
$zzN = $zzDraw.Count
$zzNow = Get-Date
$zzTick = [DateTime]::Now.Ticks
$zzParts = @(
    @{ N = 'Get-RowSubAgents'; B = { foreach ($zzX in $zzDraw) { $null = @(Get-RowSubAgents $zzX) } } }
    @{ N = 'Get-Title';        B = { foreach ($zzX in $zzDraw) { $null = (Get-Title $zzX.S $zzX.D) } } }
    @{ N = 'Get-AgeLabel';     B = { foreach ($zzX in $zzDraw) { $null = (Get-AgeLabel ($zzTick - $zzX.At)) } } }
    @{ N = 'Get-AgeTicks';     B = { foreach ($zzX in $zzDraw) { $null = (Get-AgeTicks $zzX.At $zzTick) } } }
    @{ N = 'brush lookups';    B = { foreach ($zzX in $zzDraw) { $null = $window.FindResource('TextLow') } } }
    @{ N = 'a 40-field row';   B = { foreach ($zzX in $zzDraw) { $null = [PSCustomObject]@{
            Kind='session';Id='x';Row=$zzX;BandKey='';BandVis=$V_Hide;RowVis=$V_Show;DotVis=$V_Show
            BandLabel='';BandCount=0;Accent=$null;BandBg=$null;BandHint='';Name='';Age='';Said=''
            NameWeight='Normal';NameStyle='Normal';BarOpacity=1.0;CtxVis=$V_Hide;CtxWidth=0.0
            AgentVis=$V_Hide;AgentText='';ShellVis=$V_Hide;ShellText='';QVis=$V_Hide;QText='';QTip=''
            QBrush=$null;SubVis=$V_Hide;SubName='';SubDesc='';SubTag='';SubAge='';SubOpacity=1.0
            SubTip='';CtxBrush=$null } } } }
)
foreach ($zzP in $zzParts) {
    $zzT = ZZ-Ms $zzP.B 5
    ZZ-Say ('  {0,-18} {1,7:N1} ms for {2} rows   ({3,5:N2} ms each)' -f $zzP.N, $zzT, $zzN, $(if ($zzN) { $zzT / $zzN } else { 0 }))
}
$zzSortMs = ZZ-Ms { foreach ($zzB2 in $script:Bands) { $null = @(Sort-SessionRows @($zzDraw.ToArray() | Where-Object { $_.Band -eq $zzB2.Key })) } } 5
ZZ-Say ('  {0,-18} {1,7:N1} ms total (all bands)' -f 'Sort-SessionRows', $zzSortMs)

# --- 10. ablation: what Build-Sessions loses when a helper is stubbed -------
# Timing the helpers in isolation accounted for 0,63 ms of a 1,5 ms row, so the
# rest is the loop body itself. An ablation attributes the whole cost instead of
# the part that happens to live behind a named call: stub one helper, rebuild,
# and the difference is what that helper really costs INSIDE the loop.
#
# Every stub is restored in a finally, and the last thing this section does is
# rebuild the column for real.
ZZ-Say ''
ZZ-Say '--- ablation, against the real Build-Sessions ---'
$zzBase = ZZ-Ms { Build-Sessions } 7
ZZ-Say ('  baseline                       {0,7:N1} ms' -f $zzBase)

$zzAbl = @(
    @{ N = 'Get-RowSubAgents'; F = 'Get-RowSubAgents'; S = { param($R) @() } }
    @{ N = 'Get-Title';        F = 'Get-Title';        S = { param($S, $D) [PSCustomObject]@{ Text = 'x'; Tip = 'x'; Auto = $false } } }
    @{ N = 'Get-AgeLabel';     F = 'Get-AgeLabel';     S = { param($T) '1h' } }
    @{ N = 'Get-AgeTicks';     F = 'Get-AgeTicks';     S = { param([long]$Ticks, [long]$Now = 0) [PSCustomObject]@{ Label = '1h'; Fresh = $false; Mins = 60 } } }
    @{ N = 'Sort-SessionRows'; F = 'Sort-SessionRows'; S = { param($Rows) $Rows } }
    @{ N = 'Get-SRVitalsCached'; F = 'Get-SRVitalsCached'; S = { param($R) $null } }
    # The two halves of the patched-list machinery, which cost per ITEM and not
    # per model row: the signature walks ~40 properties, the sync diffs them.
    @{ N = 'Get-SRItemSig'; F = 'Get-SRItemSig'; S = { param($It) '' } }
    @{ N = 'Sync-SRSessionItems'; F = 'Sync-SRSessionItems'; S = { param($Target) } }
    @{ N = 'Get-RowScreenSig'; F = 'Get-RowScreenSig'; S = { param($Id) $null } }
)
foreach ($zzA in $zzAbl) {
    $zzKeep = $null
    try { $zzKeep = (Get-Command $zzA.F -CommandType Function -ErrorAction Stop).ScriptBlock } catch { }
    if (-not $zzKeep) { ZZ-Say ('  {0,-30} not a function here' -f $zzA.N); continue }
    try {
        Set-Item -Path ('function:' + $zzA.F) -Value $zzA.S
        $zzOff = ZZ-Ms { Build-Sessions } 7
        ZZ-Say ('  without {0,-22} {1,7:N1} ms   ({2,6:N1} ms of the rebuild, {3,4:N0}%)' -f `
                $zzA.N, $zzOff, ($zzBase - $zzOff), $(if ($zzBase) { 100 * ($zzBase - $zzOff) / $zzBase } else { 0 }))
    } finally {
        Set-Item -Path ('function:' + $zzA.F) -Value $zzKeep
    }
}
Build-Sessions

# --- 11. the same ablation, on the projects column --------------------------
# It rebuilds every tile every time - there is no per-tile cache - so this is
# where its 30-odd ms actually goes. Same method: stub one, rebuild, subtract.
ZZ-Say ''
ZZ-Say '--- ablation, against the real Build-Rail ---'
$zzRBase = ZZ-Ms { Build-Rail } 7
ZZ-Say ('  baseline                       {0,7:N1} ms' -f $zzRBase)
$zzRAbl = @(
    @{ N = 'New-RailTile';       F = 'New-RailTile';       S = { param([string]$Path, $Kids, [bool]$Picked, $Blank, [string]$Suggest = '')
            [PSCustomObject]@{ Kind='project'; Id=('proj:'+$Path); BandVis=$V_Hide; RowVis=$V_Show
                BandKey=''; BandLabel=''; BandCount=0; BandCaret=''; Path=$Path; Label='x'; Count=0
                State=''; Tip=$null; Accent=$Blank; AccentOpacity=1.0; NeedsVis=$V_Hide
                PickBg=$Blank; PickEdge=$Blank; Fg=$Blank } } }
    @{ N = 'Get-SRItemSig';      F = 'Get-SRItemSig';      S = { param($It) '' } }
    @{ N = 'Sync-SRSessionItems';F = 'Sync-SRSessionItems';S = { param($Target, $Col = $null) } }
    @{ N = 'Get-ProjectLabel';   F = 'Get-ProjectLabel';   S = { param($P) 'x' } }
    @{ N = 'Test-SRProjectShelved'; F = 'Test-SRProjectShelved'; S = { param($Dir) $false } }
    @{ N = 'Get-RailGrouping';   F = 'Get-RailGrouping';   S = $null }
)
foreach ($zzA in $zzRAbl) {
    if (-not $zzA.S) { continue }
    $zzKeep2 = $null
    try { $zzKeep2 = (Get-Command $zzA.F -CommandType Function -ErrorAction Stop).ScriptBlock } catch { }
    if (-not $zzKeep2) { ZZ-Say ('  {0,-30} not a function here' -f $zzA.N); continue }
    try {
        Set-Item -Path ('function:' + $zzA.F) -Value $zzA.S
        $zzROff = ZZ-Ms { Build-Rail } 7
        ZZ-Say ('  without {0,-22} {1,7:N1} ms   ({2,6:N1} ms, {3,4:N0}%)' -f `
                $zzA.N, $zzROff, ($zzRBase - $zzROff), $(if ($zzRBase) { 100 * ($zzRBase - $zzROff) / $zzRBase } else { 0 }))
    } finally { Set-Item -Path ('function:' + $zzA.F) -Value $zzKeep2 }
}
Build-Rail

# --- 12. how long a status actually takes to change -------------------------
# The sweep decides NEEDS YOU and WORKING. Its cadence is one number; the OTHER
# number is how long a pass takes, and the two add up. A one-second interval on
# a pass that takes two seconds is a two-second cadence with a misleading
# constant next to it.
ZZ-Say ''
ZZ-Say '--- what a status change actually waits for ---'
$zzPids = New-Object System.Collections.Generic.List[object]
foreach ($zzR in $script:model) {
    if (-not $zzR.Live -or -not $zzR.A -or -not $zzR.A.Pid) { continue }
    if ($zzR.A.Kind -and "$($zzR.A.Kind)" -ne 'interactive') { continue }
    $null = $zzPids.Add([int]$zzR.A.Pid)
}
ZZ-Say ('  sessions the sweep covers      : {0}' -f $zzPids.Count)
if ($zzPids.Count) {
    $zzSw = [Diagnostics.Stopwatch]::StartNew()
    $zzScreens = @{}
    try { $zzScreens = Get-SRScreenTextMany -ProcessIds ([int[]]$zzPids.ToArray()) } catch { }
    $zzSw.Stop()
    $zzRead = $zzSw.Elapsed.TotalMilliseconds
    ZZ-Say ('  one pass over all of them      : {0,6:N0} ms   ({1} screens back)' -f $zzRead, @($zzScreens.Keys).Count)
    # And the parse the collector runs on what came back.
    $zzSw2 = [Diagnostics.Stopwatch]::StartNew()
    foreach ($zzK in @($zzScreens.Keys)) {
        $null = Read-SRScreenVitals -ScreenText $zzScreens[$zzK]
        $null = Test-SRLiveMenu -Text $zzScreens[$zzK]
    }
    $zzSw2.Stop()
    ZZ-Say ('  parsing what came back         : {0,6:N0} ms' -f $zzSw2.Elapsed.TotalMilliseconds)
    $zzCycle = ($SR_SweepEvery + $zzRead + $zzSw2.Elapsed.TotalMilliseconds)
    ZZ-Say ('  => worst case a status is      : {0,6:N0} ms old  (interval {1} + pass {2:N0} + parse {3:N0})' -f `
            $zzCycle, $SR_SweepEvery, $zzRead, $zzSw2.Elapsed.TotalMilliseconds)
    if ($zzRead -gt $SR_SweepEvery) {
        ZZ-Say '  NOTE: the pass takes longer than the interval, so the interval is not the cadence.'
    }
}

# --- 13. and the same thing END TO END, the way the app pays for it ---------
# 🔴 THE WORK IS NOT THE COST. Section 12 calls Get-SRScreenTextMany in a
# runspace that is already open, with _common.ps1 already loaded. Start-VitalsSweep
# does neither: it creates a runspace, opens it, and the job dot-sources a 435 KB
# _common.ps1 before it reads a single screen - once per pass, every second.
# This drives the real pair and times the whole round trip.
ZZ-Say ''
ZZ-Say '--- the sweep as the window actually runs it ---'
$zzE2E = New-Object System.Collections.Generic.List[double]
for ($zzI = 0; $zzI -lt 3; $zzI++) {
    $script:sweepAt = $null          # clear the cadence gate, not the guard
    $zzSw3 = [Diagnostics.Stopwatch]::StartNew()
    Start-VitalsSweep
    if (-not $script:sweepPs) { ZZ-Say '  the sweep would not start'; break }
    $zzSpin = 0
    while ($zzSpin -lt 400) {
        if (Complete-VitalsSweep) { break }
        if (-not $script:sweepPs) { break }
        Start-Sleep -Milliseconds 25
        $zzSpin++
    }
    $zzSw3.Stop()
    $null = $zzE2E.Add($zzSw3.Elapsed.TotalMilliseconds)
}
if ($zzE2E.Count) {
    $zzArr = @($zzE2E.ToArray() | Sort-Object)
    $zzMed = [double]$zzArr[[int][Math]::Floor($zzArr.Count / 2)]
    ZZ-Say ('  start to collected             : {0,6:N0} ms  (of {1} runs: {2})' -f `
            $zzMed, $zzArr.Count, (($zzArr | ForEach-Object { '{0:N0}' -f $_ }) -join ', '))
    ZZ-Say ('  => a status is really          : {0,6:N0} ms old worst case' -f ($SR_SweepEvery + $zzMed))
}

ZZ-Say ''
ZZ-Say '=== refresh-bench done ==='
exit 0
