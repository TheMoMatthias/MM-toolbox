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
$zzBuild = ZZ-Ms { Build-Sessions }
ZZ-Say ('  Build-Sessions          {0,8:N1} ms   ({1:N2} ms per drawn item)' -f $zzBuild, $(if ($zzItems.Count) { $zzBuild / $zzItems.Count } else { 0 }))
$zzFp = ZZ-Ms { Get-ModelFingerprint }
ZZ-Say ('  Get-ModelFingerprint    {0,8:N1} ms   (the guard that decides whether to repaint)' -f $zzFp)
$zzLW = ZZ-Ms { Update-LiveWriters }
ZZ-Say ('  Update-LiveWriters      {0,8:N1} ms   (the file-stat pass over live rows)' -f $zzLW)
$zzRail = ZZ-Ms { Build-Rail }
ZZ-Say ('  Build-Rail              {0,8:N1} ms   (the projects column)' -f $zzRail)
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
# Everything else is Get-Band over $r.Conv, and only the probe refreshes Conv.
$zzProbeOnly = @('idle -> working', 'working -> done', 'done -> working', 'idle -> done', 'anything -> quiet')
foreach ($zzT in $zzProbeOnly) {
    ZZ-Say ('  {0,-20} the probe only                        : ~{1} s worst case' -f $zzT, ($script:LiveSeconds + 2))
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
    ZZ-Say '  => a window that has just opened draws NO bars at all until a sweep lands.'
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

ZZ-Say ''
ZZ-Say '=== refresh-bench done ==='
exit 0
