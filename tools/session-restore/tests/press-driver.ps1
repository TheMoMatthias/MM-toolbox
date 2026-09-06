# ===========================================================================
#  THE CONTROLS THAT WERE READ AND NEVER PRESSED.
#
#  CONTROL-TABLE.md 18 names a group with zero coverage anywhere: RailSort,
#  ListSort, RailOnlyLive, RailClear, PaneZoom, CastCancel, SetCancel. Each is
#  short and branch-light, which is why they read as correct - and ShellFold was
#  in exactly that group and turned out BROKEN. Short and readable is not
#  evidence.
#
#  KEY: THESE ARE REAL EVENTS ON THE REAL ELEMENTS, not the handler bodies
#  copied into the test. A copy asserts that I can transcribe PowerShell;
#  RaiseEvent asserts that the control the operator clicks moves the state it
#  claims to. MouseButtonEventArgs needs a MouseDevice and Mouse.PrimaryDevice
#  exists without a window, so this works headless where synthesised INPUT does
#  not - which is why seven other rows in that table stay unreachable.
#
#  WHAT IS DELIBERATELY NOT PRESSED, and why:
#    Rescan  - its handler calls Save-RegistryOrAsk when $script:dirty, which
#              WRITES the operator's registry. A registry overwrite in this
#              repo's history cost 210 conversations. It is policy-blocked, not
#              unproven, and the table should say so.
#    PaneZoom's config write - Step-Zoom calls Save-SRConfigLater against the
#              operator's LIVE session-restore.config.json. The button IS
#              pressed; the write is stubbed for the duration and the zoom put
#              back. Pressing a control must not change his settings.
#
#  Nothing here launches, kills, types into, saves to, sends to or signs into a
#  session.
# ===========================================================================
$fails = 0
function Fail { param($m) Write-Host "  FAIL  $m" -ForegroundColor Red; $script:fails++ }
function Pass { param($m) Write-Host "  ok    $m" -ForegroundColor Green }
function Note { param($m) Write-Host "        $m" -ForegroundColor DarkGray }

function Send-SRMouseDown { param($El)
    $a = New-Object System.Windows.Input.MouseButtonEventArgs(
        [System.Windows.Input.Mouse]::PrimaryDevice, 0, [System.Windows.Input.MouseButton]::Left)
    $a.RoutedEvent = [System.Windows.UIElement]::MouseLeftButtonDownEvent
    $El.RaiseEvent($a)
}
function Send-SRMouseUp { param($El)
    $a = New-Object System.Windows.Input.MouseButtonEventArgs(
        [System.Windows.Input.Mouse]::PrimaryDevice, 0, [System.Windows.Input.MouseButton]::Left)
    $a.RoutedEvent = [System.Windows.UIElement]::MouseLeftButtonUpEvent
    $El.RaiseEvent($a)
}
function Send-SRClick { param($El)
    $El.RaiseEvent((New-Object System.Windows.RoutedEventArgs(
        [System.Windows.Controls.Primitives.ButtonBase]::ClickEvent)))
}

Write-Host ''
Write-Host '  --- the controls that had never been pressed ---' -ForegroundColor Cyan
Build-Rail
Build-Sessions

# ---- RailSort: cycles, wraps, and moves its own label ----------------------
$was = "$($script:railSort)"; $wasLbl = "$($ui.RailSort.Text)"
$keys = @($script:RailSorts | ForEach-Object { $_.Key })
Send-SRMouseDown $ui.RailSort
if ("$($script:railSort)" -eq $was) { Fail "RailSort did not move: still '$was'" }
else {
    $expect = $keys[(([array]::IndexOf($keys, $was)) + 1) % $keys.Count]
    if ("$($script:railSort)" -ne "$expect") { Fail "RailSort went to '$($script:railSort)', not the next key '$expect'" }
    elseif ("$($ui.RailSort.Text)" -eq $wasLbl) { Fail 'RailSort moved the order and left the label reading the old one' }
    else { Pass "RailSort cycles '$was' -> '$($script:railSort)' and re-labels" }
}
# TRAP: AND IT MUST COME BACK ROUND. The wrap is the one arithmetic in it, and
# the audit noted IndexOf returns -1 for an unknown key so it self-heals rather
# than throwing - which means a broken wrap would never announce itself.
$afterOne = "$($script:railSort)"
for ($i = 0; $i -lt $keys.Count; $i++) { Send-SRMouseDown $ui.RailSort }
if ("$($script:railSort)" -ne $afterOne) {
    Fail "RailSort does not return to '$afterOne' after a full cycle - the wrap is wrong"
} else { Pass ("RailSort wraps: {0} presses return to the same key" -f $keys.Count) }
$script:railSort = $was; Update-RailLabels

# ---- RailOnlyLive: a boolean that must actually flip -----------------------
$was = [bool]$script:railOnlyLive
Send-SRMouseDown $ui.RailOnlyLive
if ([bool]$script:railOnlyLive -eq $was) { Fail 'RailOnlyLive did not flip' }
else {
    Send-SRMouseDown $ui.RailOnlyLive
    if ([bool]$script:railOnlyLive -ne $was) { Fail 'RailOnlyLive does not flip back - it is not a toggle' }
    else { Pass 'RailOnlyLive toggles both ways' }
}

# ---- RailShelved -----------------------------------------------------------
$was = [bool]$script:railShowShelved
Send-SRMouseDown $ui.RailShelved
if ([bool]$script:railShowShelved -eq $was) { Fail 'RailShelved did not flip' }
else {
    Send-SRMouseDown $ui.RailShelved
    if ([bool]$script:railShowShelved -ne $was) { Fail 'RailShelved does not flip back' }
    else { Pass 'RailShelved toggles both ways' }
}

# ---- ListSort --------------------------------------------------------------
$was = "$($script:listSort)"; $wasLbl = "$($ui.ListSort.Text)"
$lkeys = @($script:ListSorts | ForEach-Object { $_.Key })
Send-SRMouseDown $ui.ListSort
if ("$($script:listSort)" -eq $was) { Fail "ListSort did not move: still '$was'" }
else {
    $expect = $lkeys[(([array]::IndexOf($lkeys, $was)) + 1) % $lkeys.Count]
    if ("$($script:listSort)" -ne "$expect") { Fail "ListSort went to '$($script:listSort)', not '$expect'" }
    elseif ("$($ui.ListSort.Text)" -eq $wasLbl) { Fail 'ListSort moved the order and left the label behind' }
    else { Pass "ListSort cycles '$was' -> '$($script:listSort)' and re-labels" }
}
$script:listSort = $was; Update-ListSortLabel; Build-Sessions

# ---- RailClear: the filter is gone, which is NOT "the list got bigger" -----
# KEY: ASSERTING railPick IS NULL WOULD PASS ON A HANDLER THAT ONLY DID THAT.
# The point of the control is the OTHER projects coming back, so the number of
# distinct projects on screen is the assertion and the flag is corroboration.
#
# TRAP: AND IT IS NOT A ROW COUNT. My first version asserted the list widens and
# went red at 128 -> 42 with the control working perfectly. Build-Sessions shows
# a picked project ENTIRELY (see its note: "FILTERING TO A PROJECT SHOWS THAT
# PROJECT, ALL OF IT") while the unfiltered list shows only live and warm rows -
# so clearing a filter on a large project legitimately shows FEWER rows. The
# test encoded my expectation instead of the rule the code states.
$pick = $null
foreach ($m in $script:model) { if ("$($m.D.path)") { $pick = "$($m.D.path)"; break } }
if (-not $pick) {
    Note 'COULD NOT BE CHECKED THIS RUN: no conversation carries a project path, so no filter could be set. It is NOT a pass.'
} else {
    $script:railPick = $pick
    Build-Sessions
    $projOf = {
        param($items)
        $seen = @{}
        foreach ($it in $items) {
            if ("$($it.Kind)" -ne 'session') { continue }
            $seen["$($it.Row.D.path)"] = $true
        }
        return $seen.Keys.Count
    }
    $narrowP = & $projOf $ui.SessionList.Items
    Send-SRMouseUp $ui.RailClear
    $wideP = & $projOf $ui.SessionList.Items
    if ($script:railPick) { Fail 'RailClear left the project filter set' }
    elseif ($narrowP -ne 1) {
        Note "COULD NOT BE CHECKED THIS RUN: the filtered list already spanned $narrowP projects, so the filter was not actually narrowing. It is NOT a pass."
    } elseif ($wideP -le 1) {
        Fail "RailClear dropped the flag but the list still shows only $wideP project(s)"
    } else { Pass "RailClear drops the filter: 1 project -> $wideP projects on screen" }
}

# ---- PaneZoom: pressed, but never against his config -----------------------
$zoomWas = $script:Zoom
$origSave = ${function:Save-SRConfigLater}
$script:pressSaves = 0
function Save-SRConfigLater { param($Name, $Value) $script:pressSaves++ }
try {
    $lblWas = "$($ui.PaneZoom.Content)"
    Send-SRClick $ui.PaneZoom
    if ($script:Zoom -eq $zoomWas) { Fail "PaneZoom did not change the zoom: still $zoomWas" }
    elseif ("$($ui.PaneZoom.Content)" -eq $lblWas) { Fail 'PaneZoom changed the zoom and left the label reading the old value' }
    else {
        Pass "PaneZoom steps $zoomWas% -> $($script:Zoom)% and re-labels"
        if ($script:pressSaves -lt 1) { Fail 'PaneZoom changed the zoom without asking for it to be remembered' }
        else { Pass 'PaneZoom asks for the setting to be remembered' }
    }
    $seen = @($script:Zoom)
    for ($i = 0; $i -lt $SR_ZoomSteps.Count; $i++) { Send-SRClick $ui.PaneZoom; $seen += $script:Zoom }
    if ($seen -notcontains $zoomWas) { Fail "PaneZoom never returns to $zoomWas% - the cycle does not wrap" }
    else { Pass "PaneZoom wraps through all $($SR_ZoomSteps.Count) steps" }
} finally {
    ${function:Save-SRConfigLater} = $origSave
    try { Set-SRTypeScale -Percent $zoomWas; $ui.PaneZoom.Content = Get-ZoomLabel } catch { }
}
if ($script:Zoom -ne $zoomWas) { Fail "the zoom was left at $($script:Zoom)% instead of the operator's $zoomWas%" }
else { Pass "the operator's zoom is back at $zoomWas%" }

# ---- SetCancel / CastCancel: close, and change nothing ---------------------
$ui.SettingsBox.Visibility = $V_Show
$script:setFor = 'something'
Send-SRClick $ui.SetCancel
if ($ui.SettingsBox.Visibility -eq $V_Show) { Fail 'SetCancel left the settings panel open' }
elseif ($script:setFor) { Fail 'SetCancel closed the panel but left it still pointed at a session' }
else { Pass 'SetCancel closes the settings panel and forgets the session' }

$ui.CastBox.Visibility = $V_Show
Send-SRClick $ui.CastCancel
if ($ui.CastBox.Visibility -eq $V_Show) { Fail 'CastCancel left the send-to-many panel open' }
else { Pass 'CastCancel closes the send-to-many panel' }

Write-Host ''
if ($fails) { Write-Host "  $fails FAIL" -ForegroundColor Red; exit 1 }
Write-Host '  every control above was pressed, not read' -ForegroundColor Green
exit 0
