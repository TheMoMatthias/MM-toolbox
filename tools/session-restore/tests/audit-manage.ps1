# ===========================================================================
# THE 7 ms AUDIT - LANE: the session manager, the settings sheet, the chrome.
#
# Implements tests/audit/CONTRACT.md. Twelve controls, timed against a 7.0 ms
# bar measured off the real claude TUI - not against the 50 ms the existing
# perf gate uses.
#
# SAFETY. Nothing here launches, kills, types, signs in or writes to disk.
#   SetApply  the six pref writes are timed against a JSON CLONE of the
#             session; the real registry row is never touched, and the save
#             itself is never called.
#   SaveBtn   only Get-SRRegistryStamp and the ConvertTo-Json that
#             Save-SRRegistry serialises. Move-Item is never reached.
#   Rescan    only the dirty check and the stamp. Invoke-SRRescan is NOT run.
#   WinClose  never invoked at all.
# Set-TickOn IS run (it is the manager's main gesture and it only mutates
# memory) and every field it touches is captured first and put back after,
# with the restore asserted at the end of the run.
#
# ASCII ONLY, deliberately: run-tests.ps1 reads a driver with Get-Content -Raw
# and no -Encoding, which on PS 5.1 means ANSI for a file without a BOM.
# ===========================================================================

$audBar   = 7.0
$audFrame = 16.0

function Get-AuditVerdict { param([double]$Best)
    if ($Best -le $audBar)   { return 'AT BAR' }
    if ($Best -le $audFrame) { return 'NEAR' }
    return 'OVER'
}

function Measure-Audit {
    param([string]$Label, [scriptblock]$Do, [scriptblock]$Pre = $null, [int]$Runs = 15)
    $audSamples = New-Object System.Collections.Generic.List[double]
    $audThrew = ''
    for ($audN = 0; $audN -lt $Runs; $audN++) {
        if ($Pre) { try { & $Pre | Out-Null } catch { } }
        $audSw = [Diagnostics.Stopwatch]::StartNew()
        try { & $Do | Out-Null } catch { $audThrew = "$($_.Exception.Message)" }
        $audSw.Stop()
        $audSamples.Add($audSw.Elapsed.TotalMilliseconds)
    }
    $audSorted = @($audSamples | Sort-Object)
    $audCount = $audSorted.Count
    $audMedIdx = [int][Math]::Floor(($audCount - 1) / 2)
    $audP90Idx = [int][Math]::Ceiling(0.9 * $audCount) - 1
    if ($audP90Idx -ge $audCount) { $audP90Idx = $audCount - 1 }
    if ($audP90Idx -lt 0) { $audP90Idx = 0 }
    return [PSCustomObject]@{
        Label = $Label
        Best  = $audSorted[0]
        Med   = $audSorted[$audMedIdx]
        P90   = $audSorted[$audP90Idx]
        Worst = $audSorted[$audCount - 1]
        Threw = $audThrew
        Runs  = $audCount
    }
}

# Every measurement prints as it is taken, so a run that dies half way still
# leaves the numbers it did get.
function Probe {
    param([string]$Label, [scriptblock]$Do, [scriptblock]$Pre = $null, [int]$Runs = 15)
    $audR = Measure-Audit -Label $Label -Do $Do -Pre $Pre -Runs $Runs
    if ($audR.Threw) {
        Write-Host ("  THREW                                {0}" -f $Label) -ForegroundColor Red
        Write-Host ("        {0}" -f $audR.Threw) -ForegroundColor Red
    } else {
        $audV = Get-AuditVerdict $audR.Best
        $audC = switch ($audV) { 'AT BAR' { 'Green' } 'NEAR' { 'Yellow' } default { 'Red' } }
        Write-Host ("  {0,8:N2} {1,8:N2} {2,8:N2}  {3,-7} {4}" -f $audR.Best, $audR.Med, $audR.P90, $audV, $Label) -ForegroundColor $audC
    }
    return $audR
}
function Head { param([string]$T)
    Write-Host ''
    Write-Host ("--- {0} " -f $T) -ForegroundColor Cyan
    Write-Host '      best      med      p90  verdict  what was timed' -ForegroundColor DarkGray
}
function Note { param([string]$M) Write-Host ("        {0}" -f $M) -ForegroundColor DarkGray }

function Get-AuditSpin {
    $audSpinBest = [double]::MaxValue
    for ($audRep = 0; $audRep -lt 5; $audRep++) {
        $audSw2 = [Diagnostics.Stopwatch]::StartNew()
        $audAcc = 0.0
        for ($audJ = 1; $audJ -lt 100000; $audJ++) { $audAcc += [Math]::Sqrt($audJ) }
        $audSw2.Stop()
        if ($audSw2.Elapsed.TotalMilliseconds -lt $audSpinBest) { $audSpinBest = $audSw2.Elapsed.TotalMilliseconds }
    }
    return $audSpinBest
}

# ---------------------------------------------------------------------------
Write-Host ''
Write-Host '=== AUDIT LANE: manager, settings, chrome ===' -ForegroundColor Cyan
$audSpin0 = Get-AuditSpin
$audBusy0 = @(Get-Process -Name 'claude' -ErrorAction SilentlyContinue).Count
Note ("the machine at the START: fixed CPU loop {0:N0} ms, {1} claude session(s) running" -f $audSpin0, $audBusy0)

Update-Model
Note ("{0} conversations across {1} projects" -f $script:model.Count, @($script:dirs).Count)

$audW = 1480.0; $audH = 980.0
$audRoot = $window.Content
function Invoke-AuditLay {
    foreach ($audP in 1, 2) {
        $audRoot.Measure((New-Object System.Windows.Size $audW, $audH))
        $audRoot.Arrange((New-Object System.Windows.Rect 0, 0, $audW, $audH))
        $audRoot.UpdateLayout()
        [System.Windows.Threading.Dispatcher]::CurrentDispatcher.Invoke(
            [System.Windows.Threading.DispatcherPriority]::Loaded, [action]{})
    }
}
$ui.ModeWork.IsChecked = $true
Set-Surface 'work'
$ui.Search.Text = ''; $ui.RailSearch.Text = ''; $ui.ListSearch.Text = ''
$script:railPick = $null; $script:bandPick = $null
Build-Rail; Build-Sessions; Invoke-AuditLay

# ===========================================================================
Head 'ModeManage / ModeWork - switching surfaces'
# ===========================================================================
# The lead measured 40 ms one way and 0.1 ms the other. Both directions are
# measured twice here: REPEATED (the same call fifteen times, which is what the
# lead's figure is) and ALTERNATING (each timed call preceded by an untimed
# switch to the other surface, which is what a real toggle is).
$null = Probe 'Set-Surface manage - repeated' { Set-Surface 'manage' }
$null = Probe 'Set-Surface work - repeated'   { Set-Surface 'work' }
$null = Probe 'Set-Surface manage - alternating (a real toggle)' -Pre { Set-Surface 'work' }   -Do { Set-Surface 'manage' }
$null = Probe 'Set-Surface work - alternating (a real toggle)'   -Pre { Set-Surface 'manage' } -Do { Set-Surface 'work' }
# And through the wired handler, which is what the operator actually presses.
$null = Probe 'ModeManage.IsChecked = true (the real Checked handler)' -Pre { $ui.ModeWork.IsChecked = $true }   -Do { $ui.ModeManage.IsChecked = $true }
$null = Probe 'ModeWork.IsChecked = true (the real Checked handler)'   -Pre { $ui.ModeManage.IsChecked = $true } -Do { $ui.ModeWork.IsChecked = $true }

# What each direction is MADE of.
$null = Probe 'inside both: Set-Status (the one line each direction ends with)' { Set-Status 'audit' }
$null = Probe 'inside work: the two Visibility assignments, alternating' -Pre { $ui.ManageSurface.Visibility = $V_Show; $ui.WorkSurface.Visibility = $V_Hide } -Do { $ui.ManageSurface.Visibility = $V_Hide; $ui.WorkSurface.Visibility = $V_Show }
$null = Probe 'inside manage: Build-Manager (warm row cache)' { Build-Manager }
$null = Probe 'inside manage: Build-Manager (COLD row cache - what a tick or a model rebuild leaves)' { $script:mgrItems = @{}; Build-Manager }
Build-Manager

# ===========================================================================
Head 'Build-Manager, taken apart'
# ===========================================================================
$audByProj = @{}
foreach ($audMR in $script:model) {
    $audPK = "$($audMR.D.path)"
    if (-not $audByProj.ContainsKey($audPK)) { $audByProj[$audPK] = New-Object System.Collections.Generic.List[object] }
    $audByProj[$audPK].Add($audMR)
}
$audKeys = @($audByProj.Keys)
Note ("{0} projects, {1} conversations; the manager list currently holds {2} rows" -f $audKeys.Count, $script:model.Count, @($ui.ManageList.ItemsSource).Count)

$null = Probe 'inside: group every conversation by project' {
    $audBy2 = @{}
    foreach ($audG in $script:model) {
        $audGK = "$($audG.D.path)"
        if (-not $audBy2.ContainsKey($audGK)) { $audBy2[$audGK] = New-Object System.Collections.Generic.List[object] }
        $audBy2[$audGK].Add($audG)
    }
}
$null = Probe 'inside: order the projects by their newest conversation (Sort-Object over a scriptblock)' {
    $audOrd = @($audByProj.Keys | Sort-Object {
        $audNew = 0L
        foreach ($audXX in $audByProj[$_]) { if ($audXX.At -gt $audNew) { $audNew = $audXX.At } }
        - $audNew
    })
}
$null = Probe 'inside: Select-ManagerRows for every project (the filter)' {
    foreach ($audK1 in $audKeys) { $null = Select-ManagerRows $audByProj[$audK1] }
}
$null = Probe 'inside: Sort-ManagerRows for every project (the sort)' {
    foreach ($audK2 in $audKeys) { $null = @(Sort-ManagerRows $audByProj[$audK2]) }
}
$null = Probe 'inside: the 7-day window filter over every project' {
    $audCutT = (Get-Date).AddDays(-7).Ticks
    foreach ($audK3 in $audKeys) {
        $null = @($audByProj[$audK3] | Where-Object { $_.At -gt $audCutT })
    }
}
$null = Probe 'inside: Get-AgeTicks for every conversation (row construction)' {
    foreach ($audK4 in $script:model) { $null = Get-AgeTicks $audK4.At }
}
$null = Probe 'inside: Get-ProjectLabel for every project (row construction)' {
    foreach ($audK5 in $audKeys) { $null = Get-ProjectLabel $audK5 }
}
$null = Probe 'inside: the counting passes at the end (armed / shown / total)' {
    $audArmedC = @($script:model | Where-Object { [bool]$_.S.enabled }).Count
    $audShownC = @($ui.ManageList.ItemsSource | Where-Object { $_.Kind -eq 'conv' }).Count
    $audTotalC = @($script:model | Where-Object { -not $_.S.gone }).Count
}
# The re-bind on its own. Two DIFFERENT list objects, alternated, so WPF cannot
# short-circuit on reference equality.
Build-Manager; $audItemsA = $ui.ManageList.ItemsSource
Build-Manager; $audItemsB = $ui.ManageList.ItemsSource
$null = Probe 'inside: assign ManageList.ItemsSource (the re-bind alone)' -Pre { $ui.ManageList.ItemsSource = $audItemsA } -Do { $ui.ManageList.ItemsSource = $audItemsB }
$null = Probe 'Build-Manager AND lay the window out (what the operator waits for)' { Build-Manager; Invoke-AuditLay } -Runs 5

# ===========================================================================
Head 'the two pieces that dominate, split further'
# ===========================================================================
# A CONTROL FIRST. Everything below is a loop over 299 rows, and a loop over
# 299 rows is not free in PowerShell 5.1 whatever is inside it. Without this
# line the per-row costs below cannot be read.
$null = Probe 'control: an EMPTY foreach over all 299 conversations' {
    foreach ($audC1 in $script:model) { }
}
$null = Probe 'control: foreach + one property read ($r.At)' {
    foreach ($audC2 in $script:model) { $null = $audC2.At }
}
$null = Probe 'control: foreach + the string interpolation the grouping does ("$($r.D.path)")' {
    foreach ($audC3 in $script:model) { $null = "$($audC3.D.path)" }
}
# Get-AgeTicks is 2 nested function calls per row. This is what each layer costs.
$null = Probe 'age: foreach + Get-AgeLabel only (ONE function call per row)' {
    foreach ($audC4 in $script:model) { $null = Get-AgeLabel 123456789012 }
}
$null = Probe 'age: foreach + Get-AgeTicks (TWO nested calls per row) - what Build-Manager does' {
    foreach ($audC5 in $script:model) { $null = Get-AgeTicks $audC5.At }
}

# Sort-ManagerRows: Sort-Object driven by a scriptblock key, once per project.
$audMgrKey = $script:MgrKeys[$script:mgrSort]
$null = Probe 'sort: invoking the key scriptblock once per row, NO sorting at all' {
    foreach ($audC6 in $script:model) { $null = & $audMgrKey $audC6 }
}
$null = Probe 'sort: Sort-Object -Property At per project (a property sort, for comparison)' {
    foreach ($audC7 in $audKeys) { $null = @($audByProj[$audC7] | Sort-Object -Property At) }
}
$null = Probe 'sort: Sort-Object { & $key $_ } per project - what Sort-ManagerRows does' {
    foreach ($audC8 in $audKeys) { $null = @($audByProj[$audC8] | Sort-Object { & $audMgrKey $_ }) }
}

# The tail counts, pipeline versus foreach, over the same 299 rows.
$null = Probe 'tail: the two Where-Object passes as written' {
    $null = @($script:model | Where-Object { [bool]$_.S.enabled }).Count
    $null = @($script:model | Where-Object { -not $_.S.gone }).Count
}
$null = Probe 'tail: the same two counts as a single foreach' {
    $audA1 = 0; $audA2 = 0
    foreach ($audC9 in $script:model) {
        if ([bool]$audC9.S.enabled) { $audA1++ }
        if (-not $audC9.S.gone) { $audA2++ }
    }
}

# Does the cost track what is ON SCREEN, or the whole model? Fold everything
# shut - the list becomes 30 project headings - and rebuild.
$audFoldSnap = @{}
foreach ($audFS in $audKeys) { $audFoldSnap[$audFS] = $script:fold[$audFS] }
foreach ($audFS2 in $audKeys) { $script:fold[$audFS2] = $true }
Build-Manager
$null = Probe ("Build-Manager with EVERY project folded shut ({0} rows on screen)" -f @($ui.ManageList.ItemsSource).Count) { Build-Manager }
foreach ($audFS3 in $audKeys) { $script:fold[$audFS3] = $false }
Build-Manager
$null = Probe ("Build-Manager with EVERY project open ({0} rows on screen)" -f @($ui.ManageList.ItemsSource).Count) { Build-Manager }
foreach ($audFS4 in $audKeys) { $script:fold[$audFS4] = $audFoldSnap[$audFS4] }
Build-Manager

# ===========================================================================
Head 'the manager sorts - a column header click'
# ===========================================================================
# The five header labels are wired with Add_MouseLeftButtonDown, which the
# perf-driver coverage regex cannot see. The handler body is
# Update-ManagerHeaders + Build-Manager; both are timed together here.
$audSortWas = $script:mgrSort
$audDescWas = $script:mgrDesc
$null = Probe 'inside: Update-ManagerHeaders alone' { Update-ManagerHeaders }
foreach ($audSK in @('logon', 'name', 'lane', 'said', 'age')) {
    $script:mgrSort = $audSK
    $null = Probe ("sort manager: {0} (header click = Update-ManagerHeaders + Build-Manager)" -f $audSK) {
        Update-ManagerHeaders; Build-Manager
    }
}
$null = Probe 'sort manager: reverse the column you are already on (mgrDesc flip)' {
    $script:mgrDesc = -not $script:mgrDesc; Update-ManagerHeaders; Build-Manager
}
$script:mgrSort = $audSortWas
$script:mgrDesc = $audDescWas
Update-ManagerHeaders; Build-Manager

# ===========================================================================
Head 'the manager filters - a chip click'
# ===========================================================================
$audFilterWas = $script:mgrFilter
foreach ($audFK in @('all', 'ticked', 'running', 'needs')) {
    $script:mgrFilter = $audFK
    Build-Manager
    $audShownN = @($ui.ManageList.ItemsSource | Where-Object { $_.Kind -eq 'conv' }).Count
    $null = Probe ("filter manager: {0} ({1} conversation rows survive)" -f $audFK, $audShownN) {
        $script:mgrFilter = $audFK; Build-Manager
    }
}
$script:mgrFilter = $audFilterWas
$null = Probe 'filter chip through the REAL RadioButton (MgrAll -> MgrTicked)' -Pre { $ui.MgrAll.IsChecked = $true } -Do { $ui.MgrTicked.IsChecked = $true }
$ui.MgrAll.IsChecked = $true
$script:mgrFilter = $audFilterWas
Build-Manager

# ===========================================================================
Head 'ManageList PreviewMouseLeftButtonDown - the three branches'
# ===========================================================================
$ui.ModeManage.IsChecked = $true
Set-Surface 'manage'
Invoke-AuditLay

# the biggest project, which is the fold worth timing
$audBigKey = $null; $audBigN = -1
foreach ($audBK in $audKeys) {
    if ($audByProj[$audBK].Count -gt $audBigN) { $audBigN = $audByProj[$audBK].Count; $audBigKey = $audBK }
}
Note ("the largest project holds {0} conversations" -f $audBigN)
$audFoldWas = $script:fold[$audBigKey]
$null = Probe ("branch project: OPEN the largest fold ({0} conversations appear)" -f $audBigN) -Pre { $script:fold[$audBigKey] = $true;  Build-Manager } -Do  { $script:fold[$audBigKey] = $false; Build-Manager }
$null = Probe 'branch project: SHUT the largest fold' -Pre { $script:fold[$audBigKey] = $false; Build-Manager } -Do  { $script:fold[$audBigKey] = $true;  Build-Manager }
$script:fold[$audBigKey] = $audFoldWas
Build-Manager

$audOlderWas = $script:showOlder
$null = Probe 'branch more: show the older conversations (rebuilds with no age window)' -Pre { $script:showOlder = $false; Build-Manager } -Do  { $script:showOlder = $true;  Build-Manager }
$script:showOlder = $audOlderWas
Build-Manager

# branch conv - Set-TickOn. IT MUTATES THE IN-MEMORY REGISTRY, so everything
# it touches is captured here and restored (and the restore is asserted) below.
$audTickRow = $null
foreach ($audTR in $script:model) { if (-not $audTR.S.gone) { $audTickRow = $audTR; break } }
if ($audTickRow) {
    $audEnWas   = [bool]$audTickRow.S.enabled
    $audPinWas  = $audTickRow.S.pinned
    $audDirWas  = $script:dirty
    $audProjWas = $audTickRow.D.enabled
    $null = Probe 'branch conv: Set-TickOn (drops the row cache, then Build-Manager)' { Set-TickOn $audTickRow }
    Set-Field $audTickRow.S 'enabled' $audEnWas
    Set-Field $audTickRow.S 'pinned'  $audPinWas
    if ($null -ne $audTickRow.D.PSObject.Properties['enabled']) { $audTickRow.D.enabled = $audProjWas }
    $script:dirty = $audDirWas
    $script:mgrItems = @{}
    Build-Manager
    if ([bool]$audTickRow.S.enabled -ne $audEnWas) { Write-Host '  RESTORE FAILED: the tick was not put back' -ForegroundColor Red }
    else { Note 'the tick, the pin, the project flag and the dirty bit were all put back' }
} else { Note 'no conversation available to tick - branch conv not measured' }

# The visual-tree walk every one of those three branches starts with. Needs a
# REALIZED container - and every Build-Manager above replaced ItemsSource, which
# throws the containers away. So the layout pass has to be the last thing that
# happens before the generator is asked.
Invoke-AuditLay
try { $ui.ManageList.UpdateLayout() } catch { }
Note ("ManageList: {0} items, {1:N0} x {2:N0} px, visible={3}" -f `
      $ui.ManageList.Items.Count, $ui.ManageList.ActualWidth, $ui.ManageList.ActualHeight, $ui.ManageList.IsVisible)
$audCont = $null
for ($audCI = 0; $audCI -lt [Math]::Min(20, $ui.ManageList.Items.Count); $audCI++) {
    $audTry = $ui.ManageList.ItemContainerGenerator.ContainerFromIndex($audCI)
    if ($audTry) { $audCont = $audTry; break }
}
if ($audCont) {
    # Walk to the deepest first-child, so the walk back up is a realistic depth.
    $audDeep = $audCont
    $audDepth = 0
    while ($true) {
        $audKids = [System.Windows.Media.VisualTreeHelper]::GetChildrenCount($audDeep)
        if ($audKids -lt 1) { break }
        $audDeep = [System.Windows.Media.VisualTreeHelper]::GetChild($audDeep, 0)
        $audDepth++
        if ($audDepth -gt 40) { break }
    }
    Note ("the click source sits {0} visual levels below its ListBoxItem" -f $audDepth)
    $null = Probe 'inside every branch: Get-ClickedRow (the walk up the visual tree)' { $null = Get-ClickedRow $audDeep }
    $null = Probe 'inside branch conv: Test-ClickedTick' { $null = Test-ClickedTick $audDeep }
    $null = Probe 'ManageList PreviewMouseRightButtonDown: the whole handler body' {
        $audIt2 = Get-ClickedRow $audDeep
        if (-not $audIt2 -or $audIt2.Kind -ne 'conv') {
            $script:manageMenuRow = $null
            $ui.ManageList.ContextMenu.IsOpen = $false
        } else {
            $script:manageMenuRow = $audIt2.Row
            $ui.ManageList.SelectedItem = $audIt2
        }
    }
    $script:manageMenuRow = $null
} else {
    Note 'no ListBoxItem was realized - Get-ClickedRow and the right-click body could not be measured'
}
$null = Probe 'note: New-ManageMenu (built ONCE at load, not per click)' { $null = New-ManageMenu } -Runs 5

# ===========================================================================
Head 'the settings sheet - SetCancel, SetPerm, SetApply'
# ===========================================================================
$ui.ModeWork.IsChecked = $true
Set-Surface 'work'
$audAll = $script:model.ToArray()
$audSelWas = $script:selId
$script:selId = $audAll[0].Id
Show-Settings
if (-not $script:setFor) { Note 'the settings sheet would not open - the rest of this section is unmeasurable' }
$null = Probe 'SetCancel: Hide-Settings + Set-Status (the whole handler)' { Hide-Settings; Set-Status 'nothing changed' }
Show-Settings
$null = Probe 'SetPerm SelectionChanged: Update-PermNote (the whole handler)' { Update-PermNote }
$audPermWas = $ui.SetPerm.SelectedIndex
$null = Probe 'SetPerm: a real SelectedIndex change (fires the wired handler)' -Pre { $ui.SetPerm.SelectedIndex = 0 } -Do { $ui.SetPerm.SelectedIndex = 5 }
$ui.SetPerm.SelectedIndex = $audPermWas

# SetApply, in three pieces. Nothing below writes the real registry.
$audApplyRow = $null
foreach ($audAR in $script:model) { if ($audAR.Id -eq $script:setFor) { $audApplyRow = $audAR; break } }
if ($audApplyRow) {
    $null = Probe 'SetApply step 1: find the row for setFor (a linear scan of the model)' {
        $audFound = $null
        foreach ($audFX in $script:model) { if ($audFX.Id -eq $script:setFor) { $audFound = $audFX; break } }
    }
    $null = Probe 'SetApply step 2: the change-detection pass (Get-SRSessionArgsLabel + Get-Title), twice' {
        $null = (Get-SRSessionArgsLabel $audApplyRow.S) + '|' + (Get-Title $audApplyRow.S $audApplyRow.D).Text
        $null = (Get-SRSessionArgsLabel $audApplyRow.S) + '|' + (Get-Title $audApplyRow.S $audApplyRow.D).Text
    }
    $audClone = ($audApplyRow.S | ConvertTo-Json -Depth 8) | ConvertFrom-Json
    $null = Probe 'SetApply step 3: writing all six prefs (against a CLONE; the real row is untouched)' {
        Set-Field $audClone 'title' 'audit-probe'
        Set-SRSessionPref $audClone 'model'          (Get-DropValue $ui.SetModel)
        Set-SRSessionPref $audClone 'effort'         (Get-DropValue $ui.SetEffort)
        Set-SRSessionPref $audClone 'permissionMode' (Get-DropValue $ui.SetPerm)
        Set-SRSessionPref $audClone 'remoteControl'  ([bool]$ui.SetRemote.IsChecked)
        Set-SRSessionPref $audClone 'hidden'         ([bool]$ui.SetHidden.IsChecked)
        Set-SRSessionPref $audClone 'allowedTools'    (@("$($ui.SetAllow.Text)" -split '\s+' | Where-Object { "$_".Trim() }))
        Set-SRSessionPref $audClone 'disallowedTools' (@("$($ui.SetDeny.Text)"  -split '\s+' | Where-Object { "$_".Trim() }))
    }
} else { Note 'no row matched setFor - SetApply steps 1-3 not measured' }
Hide-Settings
$script:selId = $audSelWas

# ===========================================================================
Head 'SaveBtn and Rescan - the guarded pre-steps'
# ===========================================================================
$null = Probe 'SaveBtn: Get-SRRegistryStamp (the stale check Save-SRRegistry makes first)' { Get-SRRegistryStamp }
$null = Probe 'SaveBtn: the redraw a successful save runs on the manage surface (Build-Manager)' { Build-Manager }
# What Save-SRRegistry spends before Move-Item. NOTHING IS WRITTEN - the JSON is
# built and dropped.
$null = Probe 'SaveBtn: ConvertTo-Json -Depth 8 over the whole registry (built and DISCARDED)' {
    $null = ($script:reg | ConvertTo-Json -Depth 8)
} -Runs 5
$null = Probe 'Rescan: the dirty check + Get-SRRegistryStamp (all it does before the scan)' {
    if ($script:dirty) { $null = 1 }
    $null = Get-SRRegistryStamp
}

# ===========================================================================
Head 'what SetApply and Rescan BOTH run after their disk step'
# ===========================================================================
# Both handlers end with the same three calls. Update-Model and Update-Surface
# are read-only and are timed; Start-LiveProbe starts a runspace and is not.
$null = Probe 'after the write: Update-Model -KeepAgents' { Update-Model -KeepAgents } -Runs 3
$null = Probe 'after the write: Update-Surface' { Update-Surface } -Runs 5
Note 'Start-LiveProbe, the third call both handlers end with, starts a runspace and was not run'

# Update-Model just replaced the model; rebuild what the rest of the run needs.
Update-Model
Build-Rail; Build-Sessions; Build-Manager

# ===========================================================================
Head 'the window chrome - WinMin, WinMax, WinClose'
# ===========================================================================
$audStateWas = $window.WindowState
$null = Probe 'WinMin: set WindowState = Minimized (the whole handler)' -Pre { $window.WindowState = [System.Windows.WindowState]::Normal } -Do  { $window.WindowState = [System.Windows.WindowState]::Minimized }
$window.WindowState = [System.Windows.WindowState]::Normal
$null = Probe 'WinMax: the whole handler (WindowState toggle + Update-MaxGlyph)' -Pre { $window.WindowState = [System.Windows.WindowState]::Normal } -Do  { $window.WindowState = [System.Windows.WindowState]::Maximized; Update-MaxGlyph }
$window.WindowState = [System.Windows.WindowState]::Normal
$null = Probe 'inside WinMax: Update-MaxGlyph alone' { Update-MaxGlyph }
$null = Probe 'inside WinMax: Update-Frame alone (what StateChanged runs)' { Update-Frame }
$null = Probe 'WinMax with the relayout it forces' -Pre { $window.WindowState = [System.Windows.WindowState]::Normal; Invoke-AuditLay } -Do  { $window.WindowState = [System.Windows.WindowState]::Maximized; Update-MaxGlyph; Invoke-AuditLay } -Runs 5
$window.WindowState = $audStateWas
Update-MaxGlyph
Note 'WinClose was NEVER invoked. Its handler is one call to $window.Close(); nothing runs before it.'

# ===========================================================================
Write-Host ''
$audSpin1 = Get-AuditSpin
$audBusy1 = @(Get-Process -Name 'claude' -ErrorAction SilentlyContinue).Count
Write-Host ("  the machine at the END: fixed CPU loop {0:N0} ms ({1:N0} ms at the start), {2} claude session(s) ({3} at the start)." -f $audSpin1, $audSpin0, $audBusy1, $audBusy0) -ForegroundColor DarkGray
Write-Host '  If those moved, the table moved with them.' -ForegroundColor DarkGray

# Leave nothing armed: this window is never shown and never closed, but a dirty
# bit is the one piece of state a later save would act on.
$script:dirty = $false
$script:manageMenuRow = $null
Write-Host ''
Write-Host '=== audit lane complete - nothing was launched, saved or closed ===' -ForegroundColor Cyan
exit 0
