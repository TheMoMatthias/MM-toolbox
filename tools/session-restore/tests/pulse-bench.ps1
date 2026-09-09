# ===========================================================================
# pulse-bench - three questions the operator asked, answered with numbers
# rather than with a reading of the code.
#
#   1. WHY IS THE COMPACT BAR NOT ON THE ROW that is compacting?
#   2. WHERE DOES THE STATUS LATENCY ACTUALLY GO, now that the interval is
#      600 ms and the pass was measured at 290?
#   3. WHERE ARE THE GAPS IN THE GROUND behind a pasted message?
#
# READ-ONLY. It builds the shipped window, never shows it, reads consoles the
# same way the sweep already does every second, and touches no session.
# Asserts nothing, always exits 0 - numbers to read, not a gate.
#
#     powershell -NoProfile -ExecutionPolicy Bypass -File tests\refresh-bench-run.ps1 -Driver pulse-bench.ps1 -Out pulse-bench-test.ps1
# ===========================================================================
$ErrorActionPreference = 'Continue'

function PB-Say { param([string]$T) Write-Host $T }
function PB-Ms { param([scriptblock]$B, [int]$N = 1)
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    for ($i = 0; $i -lt $N; $i++) { $null = & $B }
    $sw.Stop()
    return ($sw.Elapsed.TotalMilliseconds / [Math]::Max(1, $N))
}

PB-Say ''
PB-Say '=========================================================='
PB-Say '=== pulse-bench'
PB-Say '=========================================================='

# ===========================================================================
PB-Say ''
PB-Say '--- 1. the compact line, and which row it lands on ---'
# ===========================================================================
# The row draws its compact progress from $scr, the screen record for that row.
# This injects a compacting screen for exactly ONE live row and then asks the
# built column which rows ended up carrying the text. Right answer: one row,
# and it is that row.
$pbLive = @()
foreach ($pbR in $script:model) {
    if ($pbR.Live -and $pbR.A -and $pbR.A.Pid) { $pbLive += $pbR }
}
PB-Say ('  live rows in the model: {0}' -f $pbLive.Count)

if ($pbLive.Count -lt 2) {
    PB-Say '  fewer than two live conversations - the misattribution cannot be shown'
} else {
    # Build once so the row cache is warm and the order is settled, then read
    # the drawn order back off the column itself.
    Clear-SRRowItemCache
    Build-Sessions
    $pbOrder = New-Object System.Collections.Generic.List[string]
    foreach ($pbIt in $script:listItems) {
        if ("$($pbIt.Kind)" -eq 'session') { $null = $pbOrder.Add("$($pbIt.Id)") }
    }
    PB-Say ('  rows drawn in the column: {0}' -f $pbOrder.Count)

    # Pick a drawn, live row that has a row after it - so a misattributed line
    # has somewhere to land where we can see it.
    $pbPick = ''
    $pbNext = ''
    for ($i = 0; $i -lt $pbOrder.Count - 1; $i++) {
        foreach ($pbR in $pbLive) {
            if ("$($pbR.Id)" -eq $pbOrder[$i]) { $pbPick = $pbOrder[$i]; $pbNext = $pbOrder[$i + 1]; break }
        }
        if ($pbPick) { break }
    }
    if (-not $pbPick) {
        PB-Say '  no live row is drawn with another row after it - skipped'
    } else {
        $pbWas = $script:rowScreen["$pbPick"]
        try {
            $script:rowScreen["$pbPick"] = @{
                At = (Get-Date); Shells = 0; Agents = -1; Effort = ''
                TurnSecs = -1; TurnDone = $false; CtxTokens = -1; CtxWindow = -1
                Compacting = $true; CompactPct = 66; CompactSecs = 97
            }
            Clear-SRRowItemCache
            Build-Sessions
            $pbOn = New-Object System.Collections.Generic.List[string]
            foreach ($pbIt in $script:listItems) {
                if ("$($pbIt.Kind)" -ne 'session') { continue }
                if ("$($pbIt.Said)" -match 'compacting') { $null = $pbOn.Add("$($pbIt.Id)") }
            }
            PB-Say ('  injected a compact on : {0}' -f $pbPick)
            PB-Say ('  the row drawn after it: {0}' -f $pbNext)
            PB-Say ('  rows whose line says "compacting": {0}' -f $pbOn.Count)
            foreach ($pbId in $pbOn) {
                $pbWhich = 'SOME OTHER ROW'
                if ("$pbId" -eq "$pbPick") { $pbWhich = 'the row that is compacting  <-- correct' }
                elseif ("$pbId" -eq "$pbNext") { $pbWhich = 'THE ROW AFTER IT  <-- off by one' }
                PB-Say ('    {0}   {1}' -f $pbId, $pbWhich)
            }
            if ($pbOn.Count -eq 1 -and "$($pbOn[0])" -eq "$pbPick") {
                PB-Say '  VERDICT: the compact line is on the row that is compacting.'
            } elseif ($pbOn -contains $pbNext) {
                PB-Say '  VERDICT: OFF BY ONE - $scr is read one statement before it is assigned,'
                PB-Say '           so a row draws the PREVIOUS row''s screen record.'
            } else {
                PB-Say '  VERDICT: the compact line did not draw at all.'
            }
        } finally {
            if ($pbWas) { $script:rowScreen["$pbPick"] = $pbWas } else { $script:rowScreen.Remove("$pbPick") }
            Clear-SRRowItemCache
            Build-Sessions
        }
    }
}

# Does the row ask for a bar at all?
$pbSrc = "$((Get-Command Build-Sessions).ScriptBlock)"
$pbRowBar = ($pbSrc -match 'Get-SRCompactText[^\r\n]*-Bar')
PB-Say ('  the ROW asks Get-SRCompactText for a bar: {0}' -f $pbRowBar)
PB-Say ('  row text today : "{0}"' -f (Get-SRCompactText -Pct 66 -Secs 97))
PB-Say ('  with a bar     : "{0}"' -f (Get-SRCompactText -Pct 66 -Secs 97 -Bar))

# A bar drawn in a face that has no block elements is a row of empty boxes.
# Ask the face, do not assume.
function PB-Covers { param($Family, [int]$Code)
    try {
        foreach ($tf in $Family.GetTypefaces()) {
            $gt = $null
            if (-not $tf.TryGetGlyphTypeface([ref]$gt)) { continue }
            return $gt.CharacterToGlyphMap.ContainsKey($Code)
        }
    } catch { }
    return $false
}
foreach ($pbC in @(0x2588, 0x2591, 0x2593, 0x25AC, 0x2014)) {
    PB-Say ('  U+{0:X4} in the prose face: {1}' -f $pbC, (PB-Covers $script:ProseFace $pbC))
}

# ===========================================================================
PB-Say ''
PB-Say '--- 2. where the status latency goes ---'
# ===========================================================================
$pbPids = New-Object System.Collections.Generic.List[object]
foreach ($pbR in $script:model) {
    if (-not $pbR.Live -or -not $pbR.A -or -not $pbR.A.Pid) { continue }
    if ($pbR.A.Kind -and "$($pbR.A.Kind)" -ne 'interactive') { continue }
    $null = $pbPids.Add([int]$pbR.A.Pid)
}
PB-Say ('  consoles the sweep reads: {0}' -f $pbPids.Count)
PB-Say ('  $SR_SweepEvery = {0} ms' -f $SR_SweepEvery)

if ($pbPids.Count -lt 1) {
    PB-Say '  nothing live - the sweep cost cannot be measured'
} else {
    $pbArr = $pbPids.ToArray()
    # (a) the console read itself, in this process, no runspace, no dot-source.
    $pbRead = PB-Ms { Get-SRScreenTextMany -ProcessIds ([int[]]$pbArr) } 3
    PB-Say ('  a) the console read, all {0} at once      {1,7:N0} ms' -f $pbArr.Count, $pbRead)

    # (b) a fresh runspace opened and _common.ps1 dot-sourced into it - what
    #     every pass pays today before it reads anything.
    $pbDot = PB-Ms {
        $rs = [runspacefactory]::CreateRunspace()
        $rs.ApartmentState = 'MTA'; $rs.ThreadOptions = 'ReuseThread'; $rs.Open()
        $rs.SessionStateProxy.SetVariable('SRHere', $here)
        $ps = [powershell]::Create(); $ps.Runspace = $rs
        $null = $ps.AddScript({ . (Join-Path $SRHere '_common.ps1'); 1 })
        $null = $ps.Invoke()
        $ps.Dispose(); $rs.Close(); $rs.Dispose()
    } 3
    PB-Say ('  b) open a runspace + dot-source _common   {0,7:N0} ms' -f $pbDot)

    # (c) THE COLD PASS - open a runspace, dot-source into it, then do the work
    #     and throw the lot away. What every sweep did before 2026-09-09.
    #
    # 🪤 IT HAS TO PRIME. $script:SweepJob no longer carries the dot-source, so
    #     running it in a bare runspace measures a job that throws on its first
    #     call - which came out FASTER than the warm path and read as a result.
    #     A pass that does nothing is not a fast pass.
    $pbPass = PB-Ms {
        $rs = [runspacefactory]::CreateRunspace()
        $rs.ApartmentState = 'MTA'; $rs.ThreadOptions = 'ReuseThread'; $rs.Open()
        $rs.SessionStateProxy.SetVariable('SRHere', $here)
        $rs.SessionStateProxy.SetVariable('SRSweep', @{ Pids = $pbArr })
        $p0 = [powershell]::Create(); $p0.Runspace = $rs
        $null = $p0.AddScript($script:SweepPrime); $null = $p0.Invoke(); $p0.Dispose()
        $ps = [powershell]::Create(); $ps.Runspace = $rs
        $null = $ps.AddScript($script:SweepJob)
        $null = $ps.Invoke()
        $ps.Dispose(); $rs.Close(); $rs.Dispose()
    } 3
    PB-Say ('  c) a COLD pass: open + dot-source + work  {0,7:N0} ms' -f $pbPass)

    # (d) the same pass in a runspace that dot-sourced ONCE and stayed open.
    #     If b) is most of c), this is the number that matters.
    $pbHot = -1.0
    try {
        $pbRs = [runspacefactory]::CreateRunspace()
        $pbRs.ApartmentState = 'MTA'; $pbRs.ThreadOptions = 'ReuseThread'; $pbRs.Open()
        $pbRs.SessionStateProxy.SetVariable('SRHere', $here)
        $pbPs0 = [powershell]::Create(); $pbPs0.Runspace = $pbRs
        $null = $pbPs0.AddScript($script:SweepPrime)
        $null = $pbPs0.Invoke(); $pbPs0.Dispose()
        # 🔴 THE SAME BODY, NOT A LIGHTER ONE. The first version of this
        # measurement ran Read-SRScreenVitals only and left Test-SRLiveMenu out,
        # which is ~136 ms over 30 screens - so it flattered the warm runspace
        # by removing work rather than by removing the dot-source. It runs
        # $script:SweepJob, which is what the lane runs.
        $pbOne = {
            $pbRs.SessionStateProxy.SetVariable('SRSweep', @{ Pids = $pbArr })
            $ps = [powershell]::Create(); $ps.Runspace = $pbRs
            $null = $ps.AddScript($script:SweepJob)
            $null = $ps.Invoke(); $ps.Dispose()
        }
        # The FIRST warm pass has an empty screen table, so it parses everything.
        $pbFirst = PB-Ms $pbOne 1
        # ...and the ones after it skip whatever has not changed since.
        $pbHot = PB-Ms $pbOne 3
        PB-Say ('  d0) warm runspace, first pass (cache empty) {0,6:N0} ms' -f $pbFirst)
        $pbRs.Close(); $pbRs.Dispose()
    } catch { PB-Say ('  d) hot runspace failed: {0}' -f $_.Exception.Message) }
    if ($pbHot -ge 0) {
        PB-Say ('  d)  warm runspace, steady state            {0,7:N0} ms' -f $pbHot)
        # 🔑 THE ADD-UP CHECK IS AGAINST d0, NOT d. Both c and d0 parse every
        # screen; d skips the ones that have not changed, so it is deliberately
        # NOT the same work and must not be expected to reconcile.
        PB-Say ('     b + d0 = {0,5:N0} against c = {1,5:N0}   (these should agree)' -f ($pbDot + $pbFirst), $pbPass)
        PB-Say ('     the skip is worth {0,5:N0} ms a pass' -f ($pbFirst - $pbHot))
    }

    PB-Say ''
    PB-Say '  what that means for how old a status can be:'
    # The interval is measured from COMPLETION (Complete-VitalsSweep resets
    # $script:sweepAt), so a cycle is the pass plus the interval, and the worst
    # case is a change landing just after a read.
    PB-Say ('    WAS  cold pass, interval from the FINISH:')
    PB-Say ('         {0,5:N0} + {1,4:N0} = {2,5:N0} ms between reads, worst case {3,5:N0} ms' -f `
            $pbPass, $SR_SweepEvery, ($pbPass + $SR_SweepEvery), ($pbPass + $SR_SweepEvery + $pbPass))
    if ($pbHot -ge 0) {
        $pbFromStart = [Math]::Max($SR_SweepEvery, $pbHot)
        PB-Say ('    NOW  warm pass, interval from the START:')
        PB-Say ('         {0,5:N0} ms between reads, worst case {1,5:N0} ms' -f $pbFromStart, ($pbFromStart + $pbHot))
    }
}

# ===========================================================================
PB-Say ''
PB-Say '--- 3. the ground behind a pasted message ---'
# ===========================================================================
# The shape the operator sent back: a lead line, a numbered list, a blank line
# and a closing paragraph. Every source line is its own Paragraph and the
# background is painted per Paragraph, so any difference in Margin.Left between
# two of them is a NOTCH in what is supposed to read as one surface.
$pbText = @(
    'CONSOLE 15-MINUTE LANE CHECK-IN. Run the standing sweep, then report in ONE board.'
    '1. ListAgents - record which of the lanes are live and busy or idle.'
    '2. For any lane that is IDLE, send it ONE short message asking for a status.'
    '3. Report to the operator: per-lane one line, plus a DECISIONS block.'
    ''
    'Keep the whole report short. If nothing has changed, say that in one line.'
) -join "`n"

$pbDocWas = $ui.PaneDoc.Document
try {
    $pbDoc = New-Object System.Windows.Documents.FlowDocument
    $pbDoc.PagePadding = New-Object System.Windows.Thickness 0
    $pbDoc.FontFamily = $script:ProseFace
    $pbDoc.FontSize = [double]$script:Type.Pane
    Add-ReadProse -Doc $pbDoc -Text $pbText -Brush $Pal.TextMax -Size ([double]$script:Type.Pane) `
                  -Line $script:readLead -Kind 'you' -Ground $PalYouGround | Out-Null
    $ui.PaneDoc.Document = $pbDoc
    $ui.PaneDoc.Width = 900
    $ui.PaneDoc.Measure((New-Object System.Windows.Size 900, 4000))
    $ui.PaneDoc.Arrange((New-Object System.Windows.Rect 0, 0, 900, 4000))
    $ui.PaneDoc.UpdateLayout()
    $null = [System.Windows.Threading.Dispatcher]::CurrentDispatcher.Invoke(
        [System.Windows.Threading.DispatcherPriority]::Loaded, [action]{})

    PB-Say '  #   ground  marginL  padT/padB   top      text'
    PB-Say '  ------------------------------------------------------------------'
    $pbN = 0
    $pbLefts = New-Object System.Collections.Generic.List[double]
    $pbNoGround = 0
    foreach ($pbB in $pbDoc.Blocks) {
        $pbN++
        $pbHas = ($null -ne $pbB.Background)
        if (-not $pbHas) { $pbNoGround++ }
        $pbML = 0.0; $pbPT = 0.0; $pbPB = 0.0
        try { $pbML = [double]$pbB.Margin.Left; $pbPT = [double]$pbB.Padding.Top; $pbPB = [double]$pbB.Padding.Bottom } catch { }
        if ($pbHas) { $null = $pbLefts.Add($pbML) }
        $pbTop = -1.0
        try {
            $pbTp = $pbB.ContentStart
            $pbRc = $pbTp.GetCharacterRect([System.Windows.Documents.LogicalDirection]::Forward)
            if ($pbRc -and -not [double]::IsInfinity($pbRc.Top)) { $pbTop = [double]$pbRc.Top }
        } catch { }
        $pbTxt = ''
        try {
            $pbTxt = (New-Object System.Windows.Documents.TextRange $pbB.ContentStart, $pbB.ContentEnd).Text
            $pbTxt = "$pbTxt".Trim()
            if ($pbTxt.Length -gt 34) { $pbTxt = $pbTxt.Substring(0, 33) + '.' }
        } catch { }
        PB-Say ('  {0,-3} {1,-7} {2,7:N1}  {3,4:N1}/{4,-4:N1} {5,7:N1}   {6}' -f `
                $pbN, $(if ($pbHas) { 'yes' } else { 'NO' }), $pbML, $pbPT, $pbPB, $pbTop, $pbTxt)
    }
    PB-Say ''
    if ($pbNoGround -gt 0) {
        PB-Say ('  {0} of {1} blocks carry NO ground - those are holes in the surface.' -f $pbNoGround, $pbN)
    } else {
        PB-Say ('  all {0} blocks carry the ground.' -f $pbN)
    }
    if ($pbLefts.Count -gt 1) {
        $pbMin = $pbLefts[0]; $pbMax = $pbLefts[0]
        foreach ($pbL in $pbLefts) {
            if ($pbL -lt $pbMin) { $pbMin = $pbL }
            if ($pbL -gt $pbMax) { $pbMax = $pbL }
        }
        PB-Say ('  left edge of the ground: {0:N1} px to {1:N1} px  -  a {2:N1} px notch' -f $pbMin, $pbMax, ($pbMax - $pbMin))
        if (($pbMax - $pbMin) -gt 1.0) {
            PB-Say '  VERDICT: the ground is RAGGED. A bullet re-sets Margin.Left, and the'
            PB-Say '           background is painted from the margin edge, so every list item'
            PB-Say '           starts its surface further right than the prose around it.'
        } else {
            PB-Say '  VERDICT: the ground has one left edge.'
        }
    }
} catch {
    PB-Say ('  could not render: {0}' -f $_.Exception.Message)
} finally {
    $ui.PaneDoc.Document = $pbDocWas
}

# And the alternative the operator raised: the prompt orange as the TEXT colour
# instead of a ground behind it.
PB-Say ''
PB-Say ('  the prompt orange (Pal.Out) : {0}' -f $Pal.Out.Color)
PB-Say ('  body text (Pal.TextMax)     : {0}' -f $Pal.TextMax.Color)
PB-Say ('  the ground today            : {0} over the pane' -f $PalYouGround.Color)

PB-Say ''
PB-Say '=== pulse-bench done ==='
exit 0
