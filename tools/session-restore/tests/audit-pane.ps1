
# ===========================================================================
# THE 7 ms AUDIT - LANE: THE READING PANE
#
# Twelve controls (the document surface and its header controls), plus the
# pane's known hot spot: building and laying out the FlowDocument.
#
# 🔴 IT NEVER LAUNCHES, KILLS, TYPES, SAVES OR SIGNS IN. PaneRelaunch,
# PaneCompact, PaneGoTo and PaneWorktree are GUARDED: the work each one does
# BEFORE its irreversible step is timed instead, and named in the table.
# Nothing here writes the operator's config - the one disk write on a click
# path (Save-SRConfigValue, inside Step-ToolView and Step-Zoom) is measured
# with the same code against a scratch destination, never the real file.
#
# 🪤 HOW LAYOUT IS MEASURED, AND WHY THE OBVIOUS WAY IS WRONG BOTH DIRECTIONS.
#   - Re-assigning a document WPF has ALREADY laid out measures a cache hit and
#     reports layout as free. Every layout number below is against a document
#     built fresh outside the stopwatch and never yet seen.
#   - Calling $ui.PaneDoc.Measure(w,h) with a size of MY choosing is the other
#     error: it fights the constraint the parent gave the pane, so every call
#     re-lays the whole document and reports ~200 ms for a wheel notch. The
#     window does not do that. UpdateLayout() runs exactly the pending pass the
#     assignment invalidated, at the size the pane actually has, which is what
#     the UI thread blocks on in the real window.
#
# 🔴 AND THE STATE THE PANE IS ACTUALLY IN. The operator's config says
# transcriptTools = "full", so every fold in the document is built OPEN. That is
# not the code default ('folded'), so both are measured and both are labelled -
# a table measured only in the cheap state would describe a window nobody has.
# ===========================================================================

$aBar = 7.0
$aFrame = 16.0

$aRes = New-Object System.Collections.Generic.List[object]
function ANote { param($m) Write-Host "        $m" -ForegroundColor DarkGray }

# best / median / p90 of N. The fastest run is the only sample that got the CPU
# it asked for; median and p90 say how hard it had to fight for it.
function ABench {
    param([string]$Name, [scriptblock]$Do, [int]$Runs = 15, [string]$Kind = 'control',
          [string]$Handler = '', [string]$Does = '', [scriptblock]$Before, [switch]$NoRecord)
    $aMs = New-Object System.Collections.Generic.List[double]
    $aThrew = ''
    for ($aRep = 0; $aRep -lt $Runs; $aRep++) {
        if ($Before) { try { & $Before | Out-Null } catch { } }
        $aSw = [Diagnostics.Stopwatch]::StartNew()
        try { & $Do | Out-Null } catch { $aThrew = "$($_.Exception.Message)" }
        $aSw.Stop()
        $aMs.Add($aSw.Elapsed.TotalMilliseconds)
    }
    $aSorted = @($aMs | Sort-Object)
    $aBest = $aSorted[0]
    $aMed  = $aSorted[[int]([Math]::Floor($aSorted.Count / 2))]
    $aP90  = $aSorted[[Math]::Min($aSorted.Count - 1, [int]([Math]::Ceiling($aSorted.Count * 0.9)) - 1)]
    $aRow = [PSCustomObject]@{
        Name = $Name; Kind = $Kind; Handler = $Handler; Does = $Does
        Best = $aBest; Med = $aMed; P90 = $aP90; Threw = $aThrew; Runs = $Runs
    }
    if (-not $NoRecord) { $aRes.Add($aRow) }
    $aFlag = '    '
    if ($aThrew) { $aFlag = 'ERR ' } elseif ($aBest -gt $aFrame) { $aFlag = 'OVER' } elseif ($aBest -gt $aBar) { $aFlag = 'near' }
    if ($aThrew) {
        Write-Host ("  {0} {1,-58} THREW: {2}" -f $aFlag, $Name, $aThrew) -ForegroundColor Red
    } else {
        Write-Host ("  {0} {1,-58} {2,9:N2} {3,9:N2} {4,9:N2}" -f $aFlag, $Name, $aBest, $aMed, $aP90) -ForegroundColor $(
            if ($aBest -gt $aFrame) { 'Yellow' } elseif ($aBest -gt $aBar) { 'Gray' } else { 'DarkGray' })
    }
    return $aRow
}

Write-Host ''
Write-Host '=== the reading pane, against a 7.0 ms bar ===' -ForegroundColor Cyan
Write-Host ("       {0,-58} {1,9} {2,9} {3,9}" -f 'operation', 'best', 'med', 'p90') -ForegroundColor DarkCyan

# --- the machine, stated up front ------------------------------------------
$aSpinBest = [double]::MaxValue
for ($aRep = 0; $aRep -lt 5; $aRep++) {
    $aSw = [Diagnostics.Stopwatch]::StartNew()
    $aAcc = 0.0
    for ($aI = 1; $aI -lt 100000; $aI++) { $aAcc += [Math]::Sqrt($aI) }
    $aSw.Stop()
    if ($aSw.Elapsed.TotalMilliseconds -lt $aSpinBest) { $aSpinBest = $aSw.Elapsed.TotalMilliseconds }
}
$aBusy = @(Get-Process -Name 'claude' -ErrorAction SilentlyContinue).Count
ANote ("machine: a fixed 100k-sqrt loop takes {0:N0} ms, with {1} claude session(s) running" -f $aSpinBest, $aBusy)

# --- put the window in a real state ----------------------------------------
Update-Model
$aW = 1480.0; $aH = 980.0
$aRoot = $window.Content
function ALayAll {
    foreach ($aP in 1, 2) {
        $aRoot.Measure((New-Object System.Windows.Size $aW, $aH))
        $aRoot.Arrange((New-Object System.Windows.Rect 0, 0, $aW, $aH))
        $aRoot.UpdateLayout()
        [System.Windows.Threading.Dispatcher]::CurrentDispatcher.Invoke(
            [System.Windows.Threading.DispatcherPriority]::Loaded, [action]{})
    }
}
# The pending layout pass the pane owes, at the size the pane actually has.
function ALayPane { $ui.PaneDoc.UpdateLayout() }

$ui.ModeWork.IsChecked = $true
Set-Surface 'work'
$ui.Search.Text = ''; $ui.RailSearch.Text = ''; $ui.ListSearch.Text = ''
$script:railPick = $null; $script:bandPick = $null
Build-Rail; Build-Sessions; ALayAll

$aPaneW = 0.0; $aPaneH = 0.0
try { $aPaneW = [double]$ui.PaneDoc.ActualWidth } catch { }
try { $aPaneH = [double]$ui.PaneDoc.ActualHeight } catch { }
ANote ("the reading pane measures {0:N0} x {1:N0} px in a {2:N0} x {3:N0} window" -f $aPaneW, $aPaneH, $aW, $aH)
ANote ("the config has transcriptTools = '{0}' and zoom = {1}%" -f $script:toolView, $script:Zoom)

# --- the conversation this lane profiles ------------------------------------
# 🔴 NOT THE BIGGEST FILE. The tail is capped at 96 KB, so file size does not
# decide how much document gets built - how many TURNS land inside that cap
# does. Picking by bytes found a 193 KB transcript whose tail folds into NINE
# turns, and "build only the last 6 of 9" is not a question worth answering.
# This parses the tail of the forty largest and takes the one that produces the
# most turns, which is the document the operator actually waits for.
$aSess = @($ui.SessionList.Items | Where-Object { $_.Kind -eq 'session' })
if ($aSess.Count -lt 2) { Write-Host '  not enough conversations to profile the pane' -ForegroundColor Red; exit 1 }
$aBySize = @($aSess | Sort-Object -Property @{ Expression = {
    $aP = "$($_.Row.S.jsonl)"
    if ($aP -and (Test-Path -LiteralPath $aP)) { (Get-Item -LiteralPath $aP).Length } else { 0 }
}} -Descending | Select-Object -First 40)
$aScan = New-Object System.Collections.Generic.List[object]
foreach ($aCand in $aBySize) {
    $aP = "$($aCand.Row.S.jsonl)"
    if (-not $aP -or -not (Test-Path -LiteralPath $aP)) { continue }
    $aBk = @()
    try { $aBk = Get-SRTranscriptBlocks -JsonlPath $aP -MaxRecords 220 -MaxTailBytes $script:tailBytes } catch { continue }
    if (-not @($aBk).Count) { continue }
    $aTn = 0
    try { $aTn = @(Get-ReadTurns $aBk).Count } catch { continue }
    $aScan.Add([PSCustomObject]@{ It = $aCand; Turns = $aTn; Blocks = @($aBk).Count })
}
if (-not $aScan.Count) { Write-Host '  no readable transcript to profile' -ForegroundColor Red; exit 1 }
$aRank2 = @($aScan | Sort-Object -Property Turns -Descending)
$aBig = $aRank2[0].It
$aOther = @($aRank2 | Where-Object { $_.It.Id -ne $aBig.Id })[0].It
$aJp = "$($aBig.Row.S.jsonl)"
$aBytes = 0
try { $aBytes = (Get-Item -LiteralPath $aJp).Length } catch { }
ANote ("scanned the 40 largest transcripts; turn counts run {0} to {1}" -f $aRank2[$aRank2.Count - 1].Turns, $aRank2[0].Turns)
ANote ("profiling '{0}' - {1:N0} KB on disk, {2} blocks in a {3} KB tail" -f `
       $aBig.Name, ($aBytes / 1KB), $aRank2[0].Blocks, ($script:tailBytes / 1KB))

$script:selId = $null
$ui.SessionList.SelectedItem = $aBig
Show-Selected
Update-Document -Wait
ALayAll

$aBlocks = Get-SRTranscriptBlocks -JsonlPath $aJp -MaxRecords 220 -MaxTailBytes $script:tailBytes
$aCfgView = $script:toolView

# ===========================================================================
Write-Host ''
Write-Host '--- the twelve controls ---' -ForegroundColor Cyan
# ===========================================================================

# 1. PaneDoc SizeChanged. The handler is two timer calls; the WORK is deferred
#    240 ms into measureTimer's tick, and that tick can rebuild the whole
#    document. Both are timed - the second is the one that is felt.
$null = ABench 'PaneDoc.SizeChanged (the handler: restart the 240ms timer)' {
    $script:measureTimer.Stop(); $script:measureTimer.Start()
} 15 'control' 'SizeChanged' 'restarts the re-measure timer'
$script:measureTimer.Stop()
$null = ABench 'PaneDoc: the deferred tick when the size BAND held (padding only)' {
    $aD = $ui.PaneDoc.Document
    if ($aD) { Set-ReadMeasure -Doc $aD -PadL 44 }
} 15 'diagnostic' '' 'the measureTimer tick that does not rebuild'

# 2. PaneCompact - GUARDED. Invoke-Compact types /compact into a live session.
$null = ABench 'PaneCompact.Click GUARDED (guard + Set-Status, to Send-SRSessionInput)' {
    $aIt = $ui.SessionList.SelectedItem
    if ($aIt -and $aIt.Kind -eq 'session') {
        $aR = $aIt.Row
        if ($aR.A -and $aR.A.Pid) { Set-Status 'compacting...' }
    }
} 15 'control' 'Click' 'GUARDED: types /compact into a live session'

# 3. PaneGoTo - GUARDED. Raises a real terminal window.
$null = ABench 'PaneGoTo.Click GUARDED (guard + Set-Status, to Invoke-SRJumpToSession)' {
    $aIt = $ui.SessionList.SelectedItem
    if ($aIt -and $aIt.Kind -eq 'session') {
        $aR = $aIt.Row
        if ($aR.A) { Set-Status 'finding its tab...' }
    }
} 15 'control' 'Click' 'GUARDED: raises a real terminal tab'

# 4. PaneRelaunch - GUARDED, AND NEVER PRESSED. It kills a live claude and
#    reopens it. Timed: Get-SelectedRow + Get-Title, everything before
#    Confirm-Action - which is a modal that never returns without a human, so it
#    is not run either.
$null = ABench 'PaneRelaunch.Click GUARDED (Get-SelectedRow + Get-Title, to Confirm-Action)' {
    $aR = Get-SelectedRow
    if ($aR) { $null = (Get-Title $aR.S $aR.D).Text }
} 15 'control' 'Click' 'GUARDED: kills and reopens a live session'

# 5. PaneSettings - measurable in full.
$null = ABench 'PaneSettings.Click (open the settings panel)' { Show-Settings } 15 'control' 'Click' 'opens the per-session settings panel'
$null = ABench 'PaneSettings.Click (close it again)' { Hide-Settings } 15 'control' 'Click' 'closes the settings panel'
Hide-Settings

# 6. PaneTools -> Step-ToolView. Three parts: the label, a synchronous config
#    write, and the redraw. The write is measured with the same code against a
#    scratch destination, never against the operator's config.
$null = ABench 'PaneTools.Click (the redraw half: Show-Selected -Force)' { Show-Selected -Force } 15 'control' 'Click' 'cycles folded/full/hidden and redraws'
$aScratch = Join-Path $env:TEMP ('sr-audit-pane-' + [guid]::NewGuid().ToString('N'))
$null = New-Item -ItemType Directory -Path $aScratch -Force
try {
    $null = ABench 'PaneTools/PaneZoom: the config write ON THE CLICK PATH (scratch dest)' {
        $aRaw = $null
        if (Test-Path -LiteralPath $SR_ConfigPath) {
            try { $aRaw = Get-Content -LiteralPath $SR_ConfigPath -Raw | ConvertFrom-Json } catch { $aRaw = $null }
        }
        if (-not $aRaw) { $aRaw = New-Object PSObject }
        $aJson = $aRaw | ConvertTo-Json -Depth 8
        $aTmp = Join-Path $aScratch ('.config.{0}.tmp' -f ([guid]::NewGuid().ToString('N')))
        [System.IO.File]::WriteAllText($aTmp, $aJson, (New-Object System.Text.UTF8Encoding($false)))
        Move-Item -LiteralPath $aTmp -Destination (Join-Path $aScratch 'config.json') -Force
    } 15 'diagnostic' '' 'Save-SRConfigValue, same operations, scratch destination'

    # 7. PaneZoom -> Step-Zoom. Six window resources rewritten, the list told its
    #    rows changed height, and the document rebuilt. Config write excluded -
    #    it is on the line above.
    $aZoomWas = $script:Zoom
    $null = ABench 'PaneZoom.Click (resources + list refresh + redraw)' {
        Set-SRTypeScale -Percent $(if ($script:Zoom -eq 100) { 110 } else { 100 })
        try { $ui.SessionList.Items.Refresh() } catch { }
        Show-Selected -Force
    } 15 'control' 'Click' 'steps the type scale for the whole window'
    Set-SRTypeScale -Percent $aZoomWas
    try { $ui.SessionList.Items.Refresh() } catch { }
    Show-Selected -Force
} finally {
    Remove-Item -LiteralPath $aScratch -Recurse -Force -ErrorAction SilentlyContinue
}

# 8. PaneWorktree - GUARDED. Show-Spawn is a ShowDialog that never returns
#    without a human.
$null = ABench 'PaneWorktree.Click GUARDED (Get-SelectedRow + path, to Show-Spawn)' {
    $aR = Get-SelectedRow
    $aD = ''
    if ($aR -and $aR.D) { $aD = "$($aR.D.path)" }
    $null = $aD
} 15 'control' 'Click' 'GUARDED: opens the new-session dialog'

# 9. StripList PreviewMouseLeftButtonUp. Three parts: the visual-tree walk that
#    finds which dot was hit, Build-Sessions, and Update-Strip.
$aStripWas = "$($ui.ListStrip.Visibility)"
$ui.ListStrip.Visibility = 'Visible'
Update-Strip
ALayAll
$aStripN = 0
try { $aStripN = @($ui.StripList.ItemsSource).Count } catch { }
ANote ("the strip holds {0} dot(s)" -f $aStripN)
$aHit = $null
try {
    $ui.StripList.UpdateLayout()
    $aCur = $ui.StripList.ItemContainerGenerator.ContainerFromIndex(0)
    while ($aCur) {
        $aCnt = 0
        try { $aCnt = [System.Windows.Media.VisualTreeHelper]::GetChildrenCount($aCur) } catch { }
        if ($aCnt -lt 1) { break }
        $aHit = $aCur
        $aCur = [System.Windows.Media.VisualTreeHelper]::GetChild($aCur, 0)
    }
    if ($aCur) { $aHit = $aCur }
} catch { $aHit = $null }
if ($aHit) {
    $null = ABench 'StripList: part 1, the visual-tree walk that finds the dot' {
        $aEl = $aHit
        $aFound = ''
        while ($aEl) {
            if ($aEl -is [System.Windows.FrameworkElement] -and $aEl.DataContext -and
                $aEl.DataContext.PSObject.Properties['Id']) { $aFound = "$($aEl.DataContext.Id)"; break }
            $aEl = [System.Windows.Media.VisualTreeHelper]::GetParent($aEl)
        }
        $null = $aFound
    } 15 'diagnostic' '' 'the OriginalSource walk in the StripList handler'
} else { ANote 'no realized strip container - the tree walk could not be timed' }
$null = ABench 'StripList: part 2, Update-Strip alone' { Update-Strip } 15 'diagnostic' '' 'rebuilds the dot list from the model'
$aSelWas = "$($script:selId)"
$null = ABench 'StripList: part 3, Build-Sessions alone' { Build-Sessions } 15 'diagnostic' '' 'the sessions list, rebuilt (the list lane owns this)'
$null = ABench 'StripList.PreviewMouseLeftButtonUp (the whole handler)' {
    $script:selId = $aSelWas
    Build-Sessions
    Update-Strip
} 15 'control' 'PreviewMouseLeftButtonUp' 'jumps to the conversation the dot stands for'
$script:selId = $aSelWas
Build-Sessions
$ui.SessionList.SelectedItem = $aBig
Show-Selected -Force
Update-Document -Wait
$ui.ListStrip.Visibility = $aStripWas
ALayAll

# 10. ShellFold Click. Two assignments plus the layout the collapse forces.
$aShellWas = "$($ui.ShellBox.Visibility)"
$aHidWas = $script:shellHidden
$null = ABench 'ShellFold.Click (hide the running-shells panel)' {
    $script:shellHidden = $true
    $ui.ShellBox.Visibility = 'Collapsed'
    ALayPane
} 15 'control' 'Click' 'hides the running-shells panel'
$ui.ShellBox.Visibility = $aShellWas
$script:shellHidden = $aHidWas

# 11. Shell SizeChanged -> Update-ShellClip. Re-cuts the rounded card's clip.
$null = ABench 'Shell.SizeChanged (Update-ShellClip)' { Update-ShellClip } 15 'control' 'SizeChanged' 're-cuts the window card clip on resize'

# 12. SkillList MouseLeftButtonUp -> Complete-Skill + focus. Writing SendBox.Text
#     fires its TextChanged (Update-SendState + Update-SkillPop), which is the
#     real cost. It types into a TEXT BOX, never into a session.
$aSendWas = "$($ui.SendBox.Text)"
$ui.SendBox.Text = '/'
Update-SkillPop
$aSkillN = 0
try { $aSkillN = @($ui.SkillList.ItemsSource).Count } catch { }
ANote ("the skill picker offers {0} row(s)" -f $aSkillN)
if ($aSkillN -gt 0) {
    $ui.SkillList.SelectedIndex = 0
    $null = ABench 'SkillList.MouseLeftButtonUp (complete the skill into the box)' {
        $ui.SkillList.SelectedIndex = 0
        $null = Complete-Skill
    } 15 'control' 'MouseLeftButtonUp' 'writes /name into the send box and closes the picker'
} else {
    ANote 'the skill picker is empty here - Complete-Skill returns false immediately'
    $null = ABench 'SkillList.MouseLeftButtonUp (no skills: the early return)' { $null = Complete-Skill } 15 'control' 'MouseLeftButtonUp' 'writes /name into the send box'
}
Close-SkillPop
$ui.SendBox.Text = $aSendWas
$ui.SkillPop.IsOpen = $false

# ===========================================================================
# THE HOT SPOT. Everything below is run TWICE - once with folds closed (the
# code default) and once with every fold open (what this operator's config
# actually does) - because the two are different documents.
# ===========================================================================
$aReport = New-Object System.Collections.Generic.List[object]

function AProfileDoc {
    param([string]$Label, $Blocks, [bool]$Truncated = $false)

    $aTurnsL = @(Get-ReadTurns $Blocks)
    $aProbe = Build-ReadDocument -Blocks $Blocks -Truncated $Truncated -Turns $aTurnsL
    Write-Host ''
    Write-Host ("--- {0}: {1} turns -> {2} document blocks ---" -f $Label, $aTurnsL.Count, @($aProbe.Blocks).Count) -ForegroundColor Cyan

    $aGT = ABench ("[{0}] Get-ReadTurns (fold tool runs into turns)" -f $Label) { Get-ReadTurns $Blocks } 15 'part' '' 'on the UI thread, after the off-thread parse'
    $aBd = ABench ("[{0}] Build-ReadDocument (construction only)" -f $Label) {
        $null = Build-ReadDocument -Blocks $Blocks -Truncated $Truncated -Turns $aTurnsL
    } 10 'part' '' 'constructs every FlowDocument block'

    # 🪤 A FRESH DOCUMENT EVERY TIME. Built outside the stopwatch; only the
    # assignment and the layout pass it invalidates are inside.
    $aLayMs = New-Object System.Collections.Generic.List[double]
    for ($aRep = 0; $aRep -lt 10; $aRep++) {
        $aFresh = Build-ReadDocument -Blocks $Blocks -Truncated $Truncated -Turns $aTurnsL
        $aSw = [Diagnostics.Stopwatch]::StartNew()
        $ui.PaneDoc.Document = $aFresh
        ALayPane
        $aSw.Stop()
        $aLayMs.Add($aSw.Elapsed.TotalMilliseconds)
    }
    $aLS = @($aLayMs | Sort-Object)
    $aRes.Add([PSCustomObject]@{
        Name = ("[{0}] assign a FRESH document + the layout pass (layout alone)" -f $Label); Kind = 'part'; Handler = ''
        Does = 'WPF measure/arrange over every block'; Best = $aLS[0]; Med = $aLS[5]; P90 = $aLS[8]; Threw = ''; Runs = 10 })
    Write-Host ("  {0} {1,-58} {2,9:N2} {3,9:N2} {4,9:N2}" -f $(if ($aLS[0] -gt $aFrame) { 'OVER' } else { '    ' }),
        ("[{0}] assign a FRESH document + the layout pass" -f $Label), $aLS[0], $aLS[5], $aLS[8]) -ForegroundColor $(
        if ($aLS[0] -gt $aFrame) { 'Yellow' } else { 'DarkGray' })

    $aWhole = ABench ("[{0}] build AND lay out (what the pane pays after a selection)" -f $Label) {
        $ui.PaneDoc.Document = (Build-ReadDocument -Blocks $Blocks -Truncated $Truncated -Turns $aTurnsL)
        ALayPane
    } 10 'part' '' 'the whole deferred cost, on the UI thread'
    ANote ("construction {0:N1} + layout {1:N1} = {2:N1} ms by sum; measured whole {3:N1} ms" -f `
        $aBd.Best, $aLS[0], ($aBd.Best + $aLS[0]), $aWhole.Best)

    # --- Add-ReadTurn, per turn ---------------------------------------------
    # One instrumented build: the document the real builder makes, with a
    # stopwatch around each Add-ReadTurn. Repeated, keeping each turn's BEST.
    $aPer = New-Object 'System.Collections.Generic.Dictionary[int,double]'
    $aPerKind = New-Object 'System.Collections.Generic.Dictionary[int,string]'
    $aPerLen = New-Object 'System.Collections.Generic.Dictionary[int,int]'
    for ($aRep = 0; $aRep -lt 5; $aRep++) {
        $aTmpDoc = New-Object System.Windows.Documents.FlowDocument
        $aTmpDoc.FontFamily = $script:PaneFace
        $aTmpDoc.ColumnWidth = [double]::PositiveInfinity
        Set-ReadMeasure -Doc $aTmpDoc -PadL 44
        $script:docHidden = 0
        for ($aI = 0; $aI -lt $aTurnsL.Count; $aI++) {
            $aSw = [Diagnostics.Stopwatch]::StartNew()
            Add-ReadTurn -Doc $aTmpDoc -Turn $aTurnsL[$aI]
            $aSw.Stop()
            $aV = $aSw.Elapsed.TotalMilliseconds
            if (-not $aPer.ContainsKey($aI) -or $aV -lt $aPer[$aI]) { $aPer[$aI] = $aV }
            $aPerKind[$aI] = "$($aTurnsL[$aI].Kind)"
            $aPerLen[$aI] = "$($aTurnsL[$aI].Body)".Length
        }
    }
    $aSum = 0.0
    foreach ($aI in $aPer.Keys) { $aSum += $aPer[$aI] }
    ANote ("Add-ReadTurn over {0} turns sums to {1:N1} ms (best per turn); Build-ReadDocument reads {2:N1} ms" -f $aTurnsL.Count, $aSum, $aBd.Best)
    Write-Host '  the six most expensive turns:' -ForegroundColor DarkCyan
    foreach ($aI in @($aPer.Keys | Sort-Object -Property { -$aPer[$_] } | Select-Object -First 6)) {
        Write-Host ("    turn {0,3}  {1,-8} {2,7:N2} ms  body {3,7:N0} chars" -f $aI, $aPerKind[$aI], $aPer[$aI], $aPerLen[$aI]) -ForegroundColor DarkGray
    }
    $aByKind = @{}
    foreach ($aI in $aPer.Keys) {
        $aKk = $aPerKind[$aI]
        if (-not $aByKind.ContainsKey($aKk)) { $aByKind[$aKk] = @{ N = 0; Ms = 0.0 } }
        $aByKind[$aKk].N++
        $aByKind[$aKk].Ms += $aPer[$aI]
    }
    Write-Host '  by kind:' -ForegroundColor DarkCyan
    foreach ($aKk in @($aByKind.Keys | Sort-Object -Property { -$aByKind[$_].Ms })) {
        Write-Host ("    {0,-8} {1,4} turn(s)  {2,7:N1} ms total  {3,6:N2} ms each" -f `
            $aKk, $aByKind[$aKk].N, $aByKind[$aKk].Ms, ($aByKind[$aKk].Ms / $aByKind[$aKk].N)) -ForegroundColor DarkGray
    }

    # --- THE FLOOR UNDER EVERY DOCUMENT SWAP --------------------------------
    # 🔴 IF THIS IS BIG, TAIL-FIRST CANNOT WORK. Assigning ANY document to a
    # FlowDocumentScrollViewer re-templates its content host, and that cost does
    # not shrink with the document. An EMPTY document is the floor: whatever it
    # reads is what a first paint can never go below while the fix is "build
    # fewer turns". The third line is the way out if the floor is real - keep
    # ONE document object and mutate its Blocks instead of assigning a new one.
    $aEmptyMs = New-Object System.Collections.Generic.List[double]
    for ($aRep = 0; $aRep -lt 10; $aRep++) {
        $aE = New-Object System.Windows.Documents.FlowDocument
        $aE.FontFamily = $script:PaneFace
        $aE.ColumnWidth = [double]::PositiveInfinity
        Set-ReadMeasure -Doc $aE -PadL 44
        $aSw = [Diagnostics.Stopwatch]::StartNew()
        $ui.PaneDoc.Document = $aE
        ALayPane
        $aSw.Stop()
        $aEmptyMs.Add($aSw.Elapsed.TotalMilliseconds)
    }
    $aES = @($aEmptyMs | Sort-Object)
    $aRes.Add([PSCustomObject]@{
        Name = ("[{0}] THE FLOOR: assign an EMPTY document + layout" -f $Label); Kind = 'part'; Handler = ''
        Does = 'the cost of swapping the Document at all'; Best = $aES[0]; Med = $aES[5]; P90 = $aES[8]; Threw = ''; Runs = 10 })
    Write-Host ("  {0} {1,-58} {2,9:N2} {3,9:N2} {4,9:N2}" -f $(if ($aES[0] -gt $aFrame) { 'OVER' } else { '    ' }),
        ("[{0}] THE FLOOR: assign an EMPTY document + layout" -f $Label), $aES[0], $aES[5], $aES[8]) -ForegroundColor $(
        if ($aES[0] -gt $aFrame) { 'Yellow' } else { 'DarkGray' })

    # The same six turns, but MUTATING the document already in the pane instead
    # of assigning a new one. If this is far under the line above, the floor is
    # the assignment and not the content.
    if ($aTurnsL.Count -gt 6) {
        $aSlice6 = @($aTurnsL[($aTurnsL.Count - 6)..($aTurnsL.Count - 1)])
        $aHost = Build-ReadDocument -Blocks $Blocks -Truncated $Truncated -Turns $aSlice6
        $ui.PaneDoc.Document = $aHost
        ALayPane
        $null = ABench ("[{0}] the same 6 turns by MUTATING the live document (no swap)" -f $Label) {
            $aHost.Blocks.Clear()
            $script:docHidden = 0
            foreach ($aTurnY in $aSlice6) { Add-ReadTurn -Doc $aHost -Turn $aTurnY }
            ALayPane
        } 10 'part' '' 'clear + rebuild in place, then lay out'
    }

    # --- THE QUESTION: what would a tail-first first paint cost? ------------
    Write-Host ("  tail-first: build the last N turns for first paint, fill the rest in later") -ForegroundColor DarkCyan
    $aTF = New-Object System.Collections.Generic.List[object]
    foreach ($aN in @(1, 2, 3, 6, 10, 20)) {
        if ($aTurnsL.Count -le $aN) { continue }
        $aSlice = @($aTurnsL[($aTurnsL.Count - $aN)..($aTurnsL.Count - 1)])
        # Split, so the floor above can be seen inside each number rather than
        # inferred: construction on its own, then the swap + layout it forces.
        $aBn = ABench ("[{0}] last {1} turns: construction alone" -f $Label, $aN) {
            $null = Build-ReadDocument -Blocks $Blocks -Truncated $Truncated -Turns $aSlice
        } 10 'tailfirst' '' '' -NoRecord
        $aRowT = ABench ("[{0}] first paint, last {1} of {2} turns (build + layout)" -f $Label, $aN, $aTurnsL.Count) {
            $ui.PaneDoc.Document = (Build-ReadDocument -Blocks $Blocks -Truncated $Truncated -Turns $aSlice)
            ALayPane
        } 10 'tailfirst' '' '' -NoRecord
        $aTF.Add([PSCustomObject]@{ N = $aN; Build = $aBn.Best; Best = $aRowT.Best; Med = $aRowT.Med; P90 = $aRowT.P90 })
    }

    # And what filling the rest in on later frames costs, chunk by chunk.
    # Blocks are INSERTED at the top of the live document - the only shape "fill
    # in the earlier turns" can take, since a FlowDocument has no prepend helper.
    $aChunk = 6
    $aFillMs = New-Object System.Collections.Generic.List[double]
    if ($aTurnsL.Count -gt $aChunk) {
        for ($aRep = 0; $aRep -lt 3; $aRep++) {
            $aSlice = @($aTurnsL[($aTurnsL.Count - $aChunk)..($aTurnsL.Count - 1)])
            $ui.PaneDoc.Document = (Build-ReadDocument -Blocks $Blocks -Truncated $Truncated -Turns $aSlice)
            ALayPane
            $aLive = $ui.PaneDoc.Document
            $aLeft = $aTurnsL.Count - $aChunk
            $aRepMs = New-Object System.Collections.Generic.List[double]
            while ($aLeft -gt 0) {
                $aTake = [Math]::Min($aChunk, $aLeft)
                $aPiece = @($aTurnsL[($aLeft - $aTake)..($aLeft - 1)])
                $aSw = [Diagnostics.Stopwatch]::StartNew()
                $aStage = New-Object System.Windows.Documents.FlowDocument
                $script:docHidden = 0
                foreach ($aTurnX in $aPiece) { Add-ReadTurn -Doc $aStage -Turn $aTurnX }
                $aMoved = @($aStage.Blocks)
                [array]::Reverse($aMoved)
                foreach ($aBlkX in $aMoved) {
                    $null = $aStage.Blocks.Remove($aBlkX)
                    if ($aLive.Blocks.FirstBlock) { $aLive.Blocks.InsertBefore($aLive.Blocks.FirstBlock, $aBlkX) }
                    else { $aLive.Blocks.Add($aBlkX) }
                }
                ALayPane
                $aSw.Stop()
                $aRepMs.Add($aSw.Elapsed.TotalMilliseconds)
                $aLeft -= $aTake
            }
            if ($aRep -eq 0) { foreach ($aV in $aRepMs) { $aFillMs.Add($aV) } }
            else {
                for ($aI = 0; $aI -lt $aRepMs.Count -and $aI -lt $aFillMs.Count; $aI++) {
                    if ($aRepMs[$aI] -lt $aFillMs[$aI]) { $aFillMs[$aI] = $aRepMs[$aI] }
                }
            }
        }
    }
    if ($aFillMs.Count) {
        $aFS = @($aFillMs | Sort-Object)
        $aFT = 0.0
        foreach ($aV in $aFillMs) { $aFT += $aV }
        ANote ("filling the other {0} turns in {1} frames of {2}: {3:N1} ms cheapest frame, {4:N1} ms dearest, {5:N0} ms in total" -f `
            ($aTurnsL.Count - $aChunk), $aFillMs.Count, $aChunk, $aFS[0], $aFS[$aFS.Count - 1], $aFT)
        ANote ("frames over the 7.0 ms bar while filling in: {0} of {1}" -f @($aFillMs | Where-Object { $_ -gt $aBar }).Count, $aFillMs.Count)
    }

    $aReport.Add([PSCustomObject]@{
        Label = $Label; Turns = $aTurnsL.Count; Blocks = @($aProbe.Blocks).Count
        GetTurns = $aGT.Best; Build = $aBd.Best; Layout = $aLS[0]; Whole = $aWhole.Best
        Floor = $aES[0]
        PerTurnSum = $aSum; TailFirst = $aTF
        FillFrames = $aFillMs.Count
        FillMin = $(if ($aFillMs.Count) { @($aFillMs | Sort-Object)[0] } else { 0 })
        FillMax = $(if ($aFillMs.Count) { @($aFillMs | Sort-Object)[$aFillMs.Count - 1] } else { 0 })
    })
}

$script:toolView = 'folded'
AProfileDoc -Label 'folded' -Blocks $aBlocks
$script:toolView = 'full'
AProfileDoc -Label 'Steps:full' -Blocks $aBlocks
$script:toolView = $aCfgView

# --- load earlier: the tail doubled -----------------------------------------
$aTailWas = $script:tailBytes
$script:tailBytes = $aTailWas * 2
$aBlocks2 = Get-SRTranscriptBlocks -JsonlPath $aJp -MaxRecords 220 -MaxTailBytes $script:tailBytes
ANote ("load earlier: the tail goes {0} KB -> {1} KB" -f ($aTailWas / 1KB), ($script:tailBytes / 1KB))
$script:toolView = 'folded'
AProfileDoc -Label 'load-earlier' -Blocks $aBlocks2 -Truncated $true
$script:toolView = $aCfgView
$script:tailBytes = $aTailWas

# --- scrolling and opening a block: confirm or refute the lead's numbers ----
Write-Host ''
Write-Host '--- scrolling, and opening a background command ---' -ForegroundColor Cyan
$aTurnsC = @(Get-ReadTurns $aBlocks)
$ui.PaneDoc.Document = (Build-ReadDocument -Blocks $aBlocks -Truncated $false -Turns $aTurnsC)
ALayPane
$aSv = Get-PaneScroller
if (-not $aSv) { ANote 'no scroller in the pane - scrolling could not be timed' }
else {
    ANote ("document extent {0:N0} px over a {1:N0} px viewport - {2:N1} screens, none of it virtualized" -f `
        $aSv.ExtentHeight, $aSv.ViewportHeight, $(if ($aSv.ViewportHeight -gt 0) { $aSv.ExtentHeight / $aSv.ViewportHeight } else { 0 }))
    $null = ABench 'scroll: a wheel notch (48 px)' { $aSv.ScrollToVerticalOffset($aSv.VerticalOffset + 48); ALayPane } 15 'part' '' 'the most frequent gesture in the pane'
    $null = ABench 'scroll: one screen down' { $aSv.PageDown(); ALayPane } 15 'part' '' ''
    $null = ABench 'scroll: one screen up'   { $aSv.PageUp(); ALayPane } 15 'part' '' ''
    $null = ABench 'scroll: jump to the end' { $aSv.ScrollToEnd(); ALayPane } 15 'part' '' ''
    $null = ABench 'scroll: jump to the top' { $aSv.ScrollToHome(); ALayPane } 15 'part' '' ''
    $aSv.ScrollToEnd(); ALayPane
}
$aRunTurn = @($aTurnsC | Where-Object { $_.Kind -eq 'run' } | Sort-Object -Property { -@($_.Calls).Count } | Select-Object -First 1)
if ($aRunTurn.Count) {
    ANote ("the fattest run block in this tail holds {0} call(s): {1}" -f @($aRunTurn[0].Calls).Count,
           ((@($aRunTurn[0].Calls) | ForEach-Object { "$($_.Name)/$(if ("$($_.CallKind)") { "$($_.CallKind)" } else { 'run' })" }) -join ', '))
    $null = ABench 'open a background command (the lazy build a click pays)' {
        $aPnl = New-Object System.Windows.Controls.StackPanel
        Build-FoldContent -Kind 'run' -Data $aRunTurn[0].Calls -Panel $aPnl
    } 15 'part' '' 'Build-FoldContent for the biggest run in the tail'
    $aMedRun = @($aTurnsC | Where-Object { $_.Kind -eq 'run' } | Sort-Object -Property { @($_.Calls).Count } | Select-Object -First 1)
    if ($aMedRun.Count) {
        ANote ("the smallest run block holds {0} call(s)" -f @($aMedRun[0].Calls).Count)
        $null = ABench 'open the SMALLEST background command in the tail' {
            $aPnl = New-Object System.Windows.Controls.StackPanel
            Build-FoldContent -Kind 'run' -Data $aMedRun[0].Calls -Panel $aPnl
        } 15 'part' '' 'Build-FoldContent for the smallest run in the tail'
    }
    # --- WHAT A FOLD-OPEN ACTUALLY SPENDS ITS TIME ON -----------------------
    # 🔴 TWO DISK READS LIVE IN THIS CLICK PATH, and both are deliberate:
    # Add-RunDetail re-parses the WHOLE parent transcript for sub-agents when a
    # call is a Task (sessions-window.ps1:3263), and reads a background shell's
    # .output file (sessions-window.ps1:3358). Timed separately so the click
    # cost can be attributed rather than guessed at.
    $aAgentCalls = @()
    $aShellCalls = @()
    foreach ($aTurnZ in @($aTurnsC | Where-Object { $_.Kind -eq 'run' })) {
        foreach ($aCallZ in @($aTurnZ.Calls)) {
            if ("$($aCallZ.CallKind)" -eq 'agent') { $aAgentCalls += $aCallZ }
            if ("$($aCallZ.Shell)") { $aShellCalls += $aCallZ }
        }
    }
    ANote ("in this tail: {0} sub-agent call(s) and {1} background-shell call(s) across the run blocks" -f `
           @($aAgentCalls).Count, @($aShellCalls).Count)
    if (@($aAgentCalls).Count) {
        $null = ABench 'inside a fold-open: Get-SRSubAgents over the parent transcript' {
            $null = @(Get-SRSubAgents -JsonlPath "$($script:docParentPath)")
        } 10 'part' '' 'a whole-transcript re-parse, per Task call, on the click'
        $null = ABench 'open a fold holding ONE sub-agent call' {
            $aPnl = New-Object System.Windows.Controls.StackPanel
            Build-FoldContent -Kind 'run' -Data @($aAgentCalls[0]) -Panel $aPnl
        } 10 'part' '' 'the same click with the transcript re-parse in it'
    }
    if (@($aShellCalls).Count) {
        $null = ABench 'inside a fold-open: FIND + read a background shell.output' {
            $aSp = Get-SRShellOutputPath -SessionId "$($script:docSessionId)" -Shell "$($aShellCalls[0].Shell)"
            if ($aSp) { $null = Get-SRShellOutput -Path $aSp }
        } 10 'part' '' 'disk, on the click'
        # 🔴 SPLIT, BECAUSE THE OBVIOUS CULPRIT IS THE WRONG ONE. Get-SRShellOutputPath
        # globs %TEMP%\claude\*\<session>\tasks\<id>.output (_common.ps1:4835) -
        # a wildcard directory walk of the whole tree - before a single byte of
        # the output file is read.
        $null = ABench 'inside a fold-open: part 1, Get-SRShellOutputPath (the TEMP glob)' {
            $null = Get-SRShellOutputPath -SessionId "$($script:docSessionId)" -Shell "$($aShellCalls[0].Shell)"
        } 10 'part' '' 'a wildcard walk of %TEMP%\claude on every fold-open'
        $aTempRoot = Join-Path $env:TEMP 'claude'
        if (Test-Path -LiteralPath $aTempRoot) {
            $aTempN = 0
            try { $aTempN = @(Get-ChildItem -LiteralPath $aTempRoot -Directory -ErrorAction SilentlyContinue).Count } catch { }
            ANote ("%TEMP%\claude holds {0} directories for that glob to walk" -f $aTempN)
        }
        $aShPath = ''
        try { $aShPath = Get-SRShellOutputPath -SessionId "$($script:docSessionId)" -Shell "$($aShellCalls[0].Shell)" } catch { }
        if ($aShPath -and (Test-Path -LiteralPath $aShPath)) {
            ANote ("that shell.output file is {0:N0} bytes on disk" -f (Get-Item -LiteralPath $aShPath).Length)
            $null = ABench 'inside a fold-open: part 2, Get-SRShellOutput once the path is known' {
                $null = Get-SRShellOutput -Path $aShPath
            } 10 'part' '' 'the read and the ANSI strip'
        }
    }
    $aPlainCalls = @()
    foreach ($aTurnZ in @($aTurnsC | Where-Object { $_.Kind -eq 'run' })) {
        foreach ($aCallZ in @($aTurnZ.Calls)) {
            if ("$($aCallZ.CallKind)" -ne 'agent' -and -not "$($aCallZ.Shell)") { $aPlainCalls += $aCallZ }
        }
    }
    if (@($aPlainCalls).Count) {
        $null = ABench 'open a fold holding ONE ordinary call (no disk in it)' {
            $aPnl = New-Object System.Windows.Controls.StackPanel
            Build-FoldContent -Kind 'run' -Data @($aPlainCalls[0]) -Panel $aPnl
        } 15 'part' '' 'the same click with nothing to read'
    }
} else { ANote 'no tool run in this tail - opening one could not be timed' }

# ===========================================================================
Write-Host ''
Write-Host '--- inside the builder: which primitive owns the construction time ---' -ForegroundColor Cyan
# ===========================================================================
# 🔴 224 ms TO CONSTRUCT 61 BLOCKS IS 3.7 ms PER BLOCK, and a block is a
# handful of WPF objects. Either the objects are dear or PowerShell is the tax,
# and the fix is different in each case - so the primitives get timed rather
# than reasoned about.
$aProse = @($aTurnsC | Where-Object { ($_.Kind -eq 'said' -or $_.Kind -eq 'you' -or $_.Kind -eq 'msgin') } |
            Sort-Object -Property { -"$($_.Body)".Length } | Select-Object -First 1)
if ($aProse.Count) {
    $aPtxt = "$($aProse[0].Body)"
    $aPlines = @($aPtxt -replace "`r", '' -split "`n")
    ANote ("the dearest prose turn is {0:N0} characters over {1} source lines - one Paragraph each" -f $aPtxt.Length, $aPlines.Count)
    $aProseB = ABench 'inside: Add-ReadProse for that one prose turn' {
        $aDd = New-Object System.Windows.Documents.FlowDocument
        Add-ReadProse -Doc $aDd -Text $aPtxt -Brush $Pal.TextHigh -Size $script:readSize -Line $script:readLead -Kind 'said'
    } 15 'part' '' 'a Paragraph per source line'
    if ($aPlines.Count -gt 0) {
        ANote ("that is {0:N2} ms per source line, {1:N1} us per character" -f `
            ($aProseB.Best / $aPlines.Count), ($aProseB.Best * 1000 / [Math]::Max(1, $aPtxt.Length)))
    }
}
# 🔴 THE GUTTER MARK IS A HOSTED UIElement, ONE PER PARAGRAPH. New-GutterMark
# wraps a TextBlock in an InlineUIContainer (sessions-window.ps1:2596), so every
# paragraph in every reply embeds a UIElement in the flow. perf-driver records
# an A/B of exactly this that "measured as noise" - at a controlled count it
# does not.
$null = ABench 'inside: New-GutterMark x100 (TextBlock in an InlineUIContainer)' {
    for ($aQ = 0; $aQ -lt 100; $aQ++) { $null = New-GutterMark -Glyph ' ' -Brush $Pal.TextLow }
} 15 'part' '' 'one per paragraph, every paragraph'
$null = ABench 'inside: New-ReadRun x100 (a plain flow Run - the alternative)' {
    for ($aQ = 0; $aQ -lt 100; $aQ++) { $null = New-ReadRun -Text 'some words in a paragraph' -Brush $Pal.TextHigh -Size 13 }
} 15 'part' '' ''
$null = ABench 'inside: New-Object Paragraph x100 (the raw WPF floor)' {
    for ($aQ = 0; $aQ -lt 100; $aQ++) { $null = New-Object System.Windows.Documents.Paragraph }
} 15 'part' '' 'what 100 objects cost with no code around them'
$null = ABench 'inside: New-Object Thickness x100 (every block sets 2-3)' {
    for ($aQ = 0; $aQ -lt 100; $aQ++) { $null = New-Object System.Windows.Thickness 4, 3, 0, 3 }
} 15 'part' '' ''
$null = ABench 'inside: New-ReadText x100' {
    for ($aQ = 0; $aQ -lt 100; $aQ++) { $null = New-ReadText -Text 'some machine output here' -Brush $Pal.TextMid -Size 12 -Mono -Wrap -Line 16.5 }
} 15 'part' '' ''
$null = ABench 'inside: New-RailBlock x50' {
    for ($aQ = 0; $aQ -lt 50; $aQ++) {
        $aSp2 = New-Object System.Windows.Controls.StackPanel
        $null = New-RailBlock -Child $aSp2 -Kind 'run' -Rail
    }
} 15 'part' '' 'the BlockUIContainer every non-prose block sits in'

# --- put the pane back the way it was ---------------------------------------
Update-Document -Wait
Set-Status 'Work surface: what each conversation last said, and which of them are waiting on you.'

# ===========================================================================
Write-Host ''
Write-Host '=== the reading pane, slowest first ===' -ForegroundColor Cyan
# ===========================================================================
function AVerdict { param($R)
    if ($R.Threw) { return 'THREW' }
    if ($R.Does -like 'GUARDED*') { return 'GUARDED' }
    if ($R.Best -le $aBar) { return 'AT BAR' }
    if ($R.Best -le $aFrame) { return 'NEAR' }
    return 'OVER'
}
foreach ($aR in @($aRes | Sort-Object -Property Best -Descending)) {
    $aV = AVerdict $aR
    Write-Host ("  {0,-8} {1,9:N2} {2,9:N2} {3,9:N2}  {4}" -f $aV, $aR.Best, $aR.Med, $aR.P90, $aR.Name) -ForegroundColor $(
        if ($aV -eq 'OVER') { 'Yellow' } elseif ($aV -eq 'NEAR') { 'Gray' } elseif ($aV -eq 'THREW') { 'Red' } else { 'DarkGray' })
}

Write-Host ''
Write-Host '  --- the document, and the tail-first answer ---' -ForegroundColor Cyan
foreach ($aRp in $aReport) {
    Write-Host ("    {0,-13} {1,3} turns / {2,4} blocks   turns {3,6:N1}  build {4,7:N1}  layout {5,7:N1}  whole {6,7:N1} ms   (swap floor {7:N1})" -f `
        $aRp.Label, $aRp.Turns, $aRp.Blocks, $aRp.GetTurns, $aRp.Build, $aRp.Layout, $aRp.Whole, $aRp.Floor) -ForegroundColor Gray
    foreach ($aTf in $aRp.TailFirst) {
        Write-Host ("        first paint, last {0,3} turns: {1,7:N1} ms  (build {2,6:N1} + swap/layout {3,6:N1})   {4:N1}x cheaper than the whole" -f `
            $aTf.N, $aTf.Best, $aTf.Build, ($aTf.Best - $aTf.Build), $(if ($aTf.Best -gt 0) { $aRp.Whole / $aTf.Best } else { 0 })) -ForegroundColor DarkGray
    }
    if ($aRp.FillFrames) {
        Write-Host ("        then {0} fill-in frame(s) of 6 turns: {1:N1} - {2:N1} ms each" -f $aRp.FillFrames, $aRp.FillMin, $aRp.FillMax) -ForegroundColor DarkGray
    }
}

Write-Host ''
$aControls = @($aRes | Where-Object { $_.Kind -eq 'control' })
$aAt = 0; $aNear = 0; $aOver = 0; $aG = 0; $aThrewN = 0
foreach ($aR in $aControls) {
    switch (AVerdict $aR) {
        'AT BAR'  { $aAt++ }
        'NEAR'    { $aNear++ }
        'OVER'    { $aOver++ }
        'GUARDED' { $aG++ }
        'THREW'   { $aThrewN++ }
    }
}
Write-Host ("  control rows: {0} AT BAR, {1} NEAR, {2} OVER, {3} GUARDED, {4} THREW" -f $aAt, $aNear, $aOver, $aG, $aThrewN) -ForegroundColor Cyan
Write-Host ("  machine: fixed CPU loop {0:N0} ms, {1} claude session(s) running" -f $aSpinBest, $aBusy) -ForegroundColor DarkGray
Write-Host ''
exit 0
