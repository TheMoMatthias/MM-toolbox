# ===========================================================================
# THE 7 ms AUDIT - META LANE. AUDITING THE INSTRUMENT, NOT THE CONTROLS.
#
# The other four lanes measure controls. This one asks whether the thing that
# was supposed to be watching all of them can see them at all, and measures the
# four LIFECYCLE controls that no lane may ever press.
#
# 🔴 NOTHING HERE LAUNCHES, KILLS, TYPES, SAVES, SIGNS IN OR SHOWS A DIALOG.
# The operator has ~31 live claude sessions they cannot relaunch. Every
# destructive control is measured by timing the work the handler does BEFORE
# the irreversible step, and the report names which function that was.
#
# 🪤 THIS FILE IS APPENDED INTO THE WINDOW'S OWN SCOPE, so every top-level
# assignment writes the scope the GUI keeps state in. Every local here is
# prefixed `au` - no $script: name in sessions-window.ps1 begins with those two
# letters, so the harness guard stays quiet and nothing of the window's is
# shadowed.
# ===========================================================================

$auFails = 0
function AuNote { param($m) Write-Host "        $m" -ForegroundColor DarkGray }
function AuSay  { param($m) Write-Host "  $m" -ForegroundColor Gray }

# Best of 15, median and p90 - the contract's method. An operation that THREW
# has no timing, it has an error, and is recorded as such rather than as the
# cost of throwing.
$auRows = New-Object System.Collections.Generic.List[object]
function AuBench {
    param([string]$Name, [scriptblock]$Do, [string]$Kind = 'MEASURED',
          [string]$What = '', [int]$Runs = 15)
    $auSamples = New-Object System.Collections.Generic.List[double]
    $auThrew = ''
    for ($auI = 0; $auI -lt $Runs; $auI++) {
        $auSw = [Diagnostics.Stopwatch]::StartNew()
        try { & $Do | Out-Null } catch { $auThrew = "$($_.Exception.Message)" }
        $auSw.Stop()
        $auSamples.Add($auSw.Elapsed.TotalMilliseconds)
    }
    $auSorted = @($auSamples | Sort-Object)
    $auBest = $auSorted[0]
    $auMed  = $auSorted[[int][Math]::Floor($auSorted.Count / 2)]
    $auP90  = $auSorted[[int][Math]::Min($auSorted.Count - 1, [Math]::Floor($auSorted.Count * 0.9))]
    $auVerdict = 'AT BAR'
    if ($auThrew)          { $auVerdict = 'THREW' }
    elseif ($Kind -eq 'GUARDED') { $auVerdict = 'GUARDED' }
    elseif ($auBest -gt 16.0)    { $auVerdict = 'OVER' }
    elseif ($auBest -gt 7.0)     { $auVerdict = 'NEAR' }
    $auRows.Add([PSCustomObject]@{
        Name = $Name; Best = $auBest; Med = $auMed; P90 = $auP90
        Kind = $Kind; Verdict = $auVerdict; What = $What; Threw = $auThrew })
    if ($auThrew) {
        Write-Host ("  THREW  {0}: {1}" -f $Name, $auThrew) -ForegroundColor Red
        $script:auFails++
    } else {
        Write-Host ("  {0,-8} {1,8:N2} / {2,8:N2} / {3,8:N2} ms   {4}" -f `
            $auVerdict, $auBest, $auMed, $auP90, $Name) -ForegroundColor $(
            switch ($auVerdict) { 'AT BAR' { 'Green' } 'NEAR' { 'Yellow' } 'OVER' { 'Red' } default { 'Cyan' } })
    }
    return $auBest
}

Update-Model
$auW = 1480.0; $auH = 980.0
$auRoot = $window.Content
foreach ($auP in 1, 2) {
    $auRoot.Measure((New-Object System.Windows.Size $auW, $auH))
    $auRoot.Arrange((New-Object System.Windows.Rect 0, 0, $auW, $auH))
    $auRoot.UpdateLayout()
}
$ui.ModeWork.IsChecked = $true
Set-Surface 'work'
Build-Rail; Build-Sessions

Write-Host ''
Write-Host '=== PART 1 - what the coverage check can and cannot see ===' -ForegroundColor Cyan

$auSrc = Get-Content -LiteralPath (Join-Path $SR_LibDir 'sessions-window.ps1') -Raw -Encoding UTF8

# The map's own regex, character for character (perf-driver.ps1:610). Anchored
# at column 0, and limited to six event kinds.
$auSeen = @([regex]::Matches($auSrc, '(?m)^\$ui\.([A-Za-z]+)\.Add_(?:Click|SelectionChanged|TextChanged|KeyDown|Checked|MouseDoubleClick)') |
            ForEach-Object { $_.Groups[1].Value } | Sort-Object -Unique)
# Every $ui.<name>.Add_<anything>, at any indent.
$auAllDot = @([regex]::Matches($auSrc, '\$ui\.([A-Za-z0-9_]+)\.Add_([A-Za-z]+)'))
$auAll = @($auAllDot | ForEach-Object { $_.Groups[1].Value } | Sort-Object -Unique)
# And the ones wired through the dictionary, $ui[$name], which the map's regex
# cannot express at all.
$auIdx = @([regex]::Matches($auSrc, '(?m)^\s*foreach \(\$\w+ in @\((''[A-Za-z0-9]+''(?:,\s*''[A-Za-z0-9]+'')*)\)\)'))

$auKinds = @{}
foreach ($auM in $auAllDot) {
    $auK = $auM.Groups[2].Value
    if (-not $auKinds.ContainsKey($auK)) { $auKinds[$auK] = 0 }
    $auKinds[$auK] = $auKinds[$auK] + 1
}
AuSay ('$ui.<name> controls carrying a handler: ' + $auAll.Count)
AuSay ("of those, the coverage regex can see:    {0}" -f $auSeen.Count)
$auBlind = @($auAll | Where-Object { $auSeen -notcontains $_ })
AuSay ("silently invisible to it:                {0}  -> {1}" -f $auBlind.Count, ($auBlind -join ', '))
Write-Host ''
AuSay 'handler kinds wired on $ui.<name>, and whether the regex knows the kind:'
foreach ($auK in @($auKinds.Keys | Sort-Object)) {
    $auKnown = @('Click','SelectionChanged','TextChanged','KeyDown','Checked','MouseDoubleClick') -contains $auK
    AuNote ("{0,-28} {1,2}   {2}" -f $auK, $auKinds[$auK], $(if ($auKnown) { 'in the regex' } else { 'NEVER COUNTED' }))
}

Write-Host ''
Write-Host '=== PART 4 - the four lifecycle controls, GUARDED ===' -ForegroundColor Cyan
Write-Host '  (nothing below launches, kills, signs in or opens a dialog)' -ForegroundColor DarkGray
Write-Host '  verdict       best /      med /      p90   operation' -ForegroundColor DarkGray

# --- SignIn -----------------------------------------------------------------
# The handler reads one file's timestamp so it knows what "changed" means
# afterwards, then Start-Process opens a terminal. Everything up to the
# Start-Process is this one call.
$null = AuBench 'SignIn: Get-SRCredStamp (all it does before the terminal)' `
    { Get-SRCredStamp } 'GUARDED' 'one file stat'

# --- OpenNotRunning ---------------------------------------------------------
# 🪤 THE HANDLER CALLS Get-TickedPlan -Adopt, AND -Adopt WRITES: it copies live
# names over recorded ones and sets $script:dirty. So the read-only call is what
# is timed - the adopting one is the same walk plus a string compare per live
# row - and the report says so rather than pretending they are the same call.
$null = AuBench 'OpenNotRunning: Get-TickedPlan (read-only form of the handler''s -Adopt)' `
    { Get-TickedPlan } 'GUARDED' 'the plan walk over the whole model'
$auPlan = Get-TickedPlan
$null = AuBench 'OpenNotRunning: Limit-ToCap on the fresh set' `
    { Limit-ToCap $auPlan.Fresh } 'GUARDED' 'the maxSessions cap'
# What the click actually pays before the confirmation appears: plan, cap, and
# the name of every conversation it would open.
$null = AuBench 'OpenNotRunning: plan + cap + naming every conversation (all of it, up to the confirmation)' {
    $auP2 = Get-TickedPlan
    $auL2 = Limit-ToCap $auP2.Fresh
    $null = (@(@($auL2.Go) | ForEach-Object { (Get-Title $_.S $_.D).Text }) | Sort-Object) -join ', '
} 'GUARDED' 'Get-TickedPlan + Limit-ToCap + Get-Title per row'
$auRow0 = @($script:model.ToArray())[0]
$null = AuBench 'OpenNotRunning: Get-LaunchBlock for one row' `
    { Get-LaunchBlock $auRow0 } 'GUARDED' 'the per-row launchable check'

# --- RelaunchSessions -------------------------------------------------------
# 🔴 THIS ONE KILLS LIVE SESSIONS. Only the plan is timed. The kill path -
# Invoke-RelaunchOne, Start-LaunchQueue - is never entered, not once.
$null = AuBench 'RelaunchSessions: the whole plan, up to the confirmation' {
    $auP3 = Get-TickedPlan
    $auL3 = Limit-ToCap $auP3.Restart
    $auF3 = Limit-ToCap $auP3.Fresh -Already @($auL3.Go).Count
    $null = (@(@($auL3.Go) | ForEach-Object { (Get-Title $_.S $_.D).Text }) | Sort-Object) -join ', '
    $null = (@(@($auF3.Go) | ForEach-Object { (Get-Title $_.S $_.D).Text }) | Sort-Object) -join ', '
    $null = (@(@($auP3.Busy) | ForEach-Object { (Get-Title $_.S $_.D).Text } | Select-Object -First 6)) -join ', '
} 'GUARDED' 'Get-TickedPlan + two Limit-ToCap + Get-Title over restart/fresh/busy'

# --- NewSession -------------------------------------------------------------
# 🔴 ShowDialog NEVER RETURNS WITHOUT A HUMAN, so it is never called. What the
# click pays before the dialog appears is the XAML: read spawn2.xaml off disk,
# parse it, build the visual tree, find seventeen elements and merge the
# window's resource dictionary into it. That is timed here, and it is NOT
# Build-SettingDrops - which the coverage map names as its cost and which is a
# different function, on a different surface, filling three combo boxes on the
# work pane. Both are timed so the difference is on the record.
$auXamlPath = Join-Path $here 'spawn2.xaml'
if (-not (Test-Path -LiteralPath $auXamlPath)) {
    AuNote 'spawn2.xaml is missing - NewSession is UNMEASURABLE here'
} else {
    $null = AuBench 'NewSession: Show-Spawn up to (never including) ShowDialog' {
        $auRdr = New-Object System.Xml.XmlNodeReader ([xml](Get-Content -LiteralPath $auXamlPath -Raw))
        $auWin = [Windows.Markup.XamlReader]::Load($auRdr)
        foreach ($auN in @('SpTitleBar','SpClose','SpDir','SpBrowse','SpDirPath','SpName','SpModel','SpEffort',
                           'SpPerm','SpPermNote','SpRemote','SpHidden','SpWorktree','SpWarn','SpHint',
                           'SpCancel','SpStart')) { $null = $auWin.FindName($auN) }
        $auWin.Resources.MergedDictionaries.Add($window.Resources)
    } 'GUARDED' 'XamlReader.Load of spawn2.xaml + 17 FindName + resource merge' 15
    $null = AuBench 'NewSession: Build-SettingDrops (what the coverage map names instead)' `
        { Build-SettingDrops } 'MEASURED' 'three combo boxes on the WORK pane - a different control'
}

Write-Host ''
Write-Host '=== the gesture cost the map attributes to a screen read ===' -ForegroundColor Cyan
# 🔴 Invoke-Answer, Invoke-AskMove and AskFreeSend all go through Start-AskSend,
# which does NOT do the screen read on the UI thread - it opens a RUNSPACE and
# hands the read to it. So the click does not wait on the read the coverage map
# credits it with; it waits on runspace creation. Nothing measures that. This
# does - and it stops one call short of BeginInvoke, so no answer is ever sent.
$null = AuBench 'Start-AskSend: runspace spin-up (everything before BeginInvoke)' {
    $auRs = [runspacefactory]::CreateRunspace()
    $auRs.ApartmentState = 'MTA'
    $auRs.ThreadOptions = 'ReuseThread'
    $auRs.Open()
    $auRs.SessionStateProxy.SetVariable('SRHere', $here)
    $auRs.SessionStateProxy.SetVariable('SRAns', @{ Kind = 'none'; SessionId = ''; Pid = 0; Index = -1; Delta = 0; Text = '' })
    $auShell = [powershell]::Create()
    $auShell.Runspace = $auRs
    $null = $auShell.AddScript($script:AnswerJob)
    # NEVER BeginInvoke. Torn down instead.
    $auShell.Dispose(); $auRs.Close(); $auRs.Dispose()
} 'MEASURED' 'CreateRunspace + Open + SetVariable x2 + AddScript' 7

Write-Host ''
Write-Host '=== the machine ===' -ForegroundColor Cyan
$auSpin = [double]::MaxValue
for ($auR = 0; $auR -lt 5; $auR++) {
    $auSw2 = [Diagnostics.Stopwatch]::StartNew()
    $auAcc = 0.0
    for ($auJ = 1; $auJ -lt 100000; $auJ++) { $auAcc += [Math]::Sqrt($auJ) }
    $auSw2.Stop()
    if ($auSw2.Elapsed.TotalMilliseconds -lt $auSpin) { $auSpin = $auSw2.Elapsed.TotalMilliseconds }
}
$auBusy = @(Get-Process -Name 'claude' -ErrorAction SilentlyContinue).Count
AuSay ("a fixed 100k-sqrt loop took {0:N0} ms with {1} claude session(s) running" -f $auSpin, $auBusy)

Write-Host ''
Write-Host '=== the table, as the report will carry it ===' -ForegroundColor Cyan
foreach ($auRw in $auRows) {
    Write-Host ("| {0} | {1:N2} | {2:N2} | {3:N2} | {4} | {5} |" -f `
        $auRw.Name, $auRw.Best, $auRw.Med, $auRw.P90, $auRw.Verdict, $auRw.What)
}
Write-Host ''
AuSay ("machine: {0:N0} ms spin, {1} claude" -f $auSpin, $auBusy)
if ($auFails) { Write-Host "$auFails operation(s) THREW" -ForegroundColor Red; exit 1 }
exit 0
