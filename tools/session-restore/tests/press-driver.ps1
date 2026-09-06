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

# ---- the guards that stand between a click and a SEND ----------------------
# 🔴 THE TABLE WAS WRONG ABOUT THIS ONE AND IT IS THE DANGEROUS DIRECTION.
# CONTROL-TABLE.md said the round-navigation buttons are "not policy-blocked"
# because "Invoke-AskMove only moves the panel - it does not send". It sends:
# Invoke-AskMove calls Start-AskSend -Kind 'move', which types ARROW KEYS into
# the selected conversation's live menu. Pressing that button here would drive a
# picker in one of the operator's sessions.
#
# So the button is NOT pressed. What is proved instead is the three guards that
# stand between the click and the send, with Start-AskSend replaced by a counter
# that must never be reached - which is the assertion that matters, because a
# guard that stopped working would show up as a send, not as a wrong answer.
$origSend = ${function:Start-AskSend}
$script:pressSends = 0
function Start-AskSend { $script:pressSends++; return $null }
$selWas = $ui.SessionList.SelectedItem
$ansWas = $script:ansPs
try {
    $ui.SessionList.SelectedItem = $null
    Invoke-AskMove 1
    if ($script:pressSends -gt 0) { Fail 'Invoke-AskMove sent with NOTHING selected' }
    else { Pass 'Invoke-AskMove sends nothing when no conversation is selected' }

    $dead = @($ui.SessionList.Items | Where-Object {
        $_.Kind -eq 'session' -and -not ($_.Row.A -and $_.Row.A.Pid) })
    if (-not $dead.Count) {
        Note 'COULD NOT BE CHECKED THIS RUN: every conversation on screen is running, so the not-running guard could not be reached. It is NOT a pass.'
    } else {
        $ui.SessionList.SelectedItem = $dead[0]
        Invoke-AskMove 1
        if ($script:pressSends -gt 0) { Fail 'Invoke-AskMove sent into a conversation that is not running' }
        else { Pass 'Invoke-AskMove sends nothing into a conversation that is not running' }
    }

    $live = @($ui.SessionList.Items | Where-Object {
        $_.Kind -eq 'session' -and $_.Row.A -and $_.Row.A.Pid })
    if (-not $live.Count) {
        Note 'COULD NOT BE CHECKED THIS RUN: no running conversation on screen, so the in-flight guard could not be reached. It is NOT a pass.'
    } else {
        # 🪤 A TRUTHY NON-NULL IS ALL THE GUARD READS, and using a real
        # PowerShell here would start one. The guard is `if ($script:ansPs)`.
        $script:ansPs = 'pretend a send is in flight'
        $ui.SessionList.SelectedItem = $live[0]
        Invoke-AskMove 1
        if ($script:pressSends -gt 0) { Fail 'Invoke-AskMove started a second send while one was in flight' }
        else { Pass 'Invoke-AskMove refuses while a send is already in flight' }
    }
} finally {
    $script:ansPs = $ansWas
    ${function:Start-AskSend} = $origSend
    $ui.SessionList.SelectedItem = $selWas
}
if ($script:pressSends -ne 0) { Fail "the guards let $($script:pressSends) send(s) through" }
else { Pass 'no send left the window at any point in this section' }

# ---- RailList right-click: a heading is not a project ----------------------
$script:railMenuDir = 'stale'
$a = New-Object System.Windows.Input.MouseButtonEventArgs(
    [System.Windows.Input.Mouse]::PrimaryDevice, 0, [System.Windows.Input.MouseButton]::Right)
$a.RoutedEvent = [System.Windows.UIElement]::PreviewMouseRightButtonDownEvent
$ui.RailList.RaiseEvent($a)
# Raised on the list itself, so OriginalSource is the list and not a project row
# - which is exactly the case the handler guards: no menu rather than a menu
# whose one item would act on whatever was right-clicked last.
if ("$($script:railMenuDir)" -eq 'stale') {
    Fail 'right-clicking something that is not a project left the previous project armed on the menu'
} else { Pass 'right-clicking a non-project clears the menu target instead of keeping the last one' }

# ---- the sub-agent document: open it, and close it -------------------------
# 🪤 NOT Get-RowSubAgents, AND THAT IS WHY THIS SECTION USED TO ABSTAIN. That
# helper reads $script:subAgents, a cache filled by a BACKGROUND PASS that never
# runs in a spliced window - so it answered "no sub-agents anywhere" on a machine
# holding hundreds of them, and the abstain was my finder rather than the
# controls being unreachable. Get-SRSubAgents reads the meta files itself.
# See [[feedback_cache_under_its_own_view]]: a cache consulted outside the loop
# that fills it reports the state you already had, which here was none.
$subRow = $null; $sub = $null
foreach ($m in $script:model) {
    $jp = "$($m.S.jsonl)"
    if (-not $jp -or -not (Test-Path -LiteralPath $jp)) { continue }
    $ss = @()
    try { $ss = @(Get-SRSubAgents -JsonlPath $jp) } catch { continue }
    foreach ($one in $ss) {
        if ("$($one.Path)" -and (Test-Path -LiteralPath "$($one.Path)")) { $subRow = $m; $sub = $one; break }
    }
    if ($sub) { break }
}
if (-not $sub) {
    Note 'COULD NOT BE CHECKED THIS RUN: no conversation on this machine has a sub-agent with a transcript on disk. It is NOT a pass.'
} else {
    try {
        Show-AgentDoc -Sub $sub -ParentRow $subRow
        if (-not $script:agentOpen) { Fail 'Show-AgentDoc did not mark a sub-agent as open' }
        elseif (-not $ui.PaneDoc.Document) { Fail 'Show-AgentDoc opened a sub-agent and drew no document' }
        else {
            Pass "Show-AgentDoc opens a sub-agent's own transcript"
            Close-AgentDoc
            if ($script:agentOpen) { Fail 'Close-AgentDoc left the sub-agent open' }
            else { Pass 'Close-AgentDoc returns to the conversation that owns it' }
        }
    } catch { Fail ("the sub-agent document threw: {0}" -f $_.Exception.Message) }
}

Write-Host ''
if ($fails) { Write-Host "  $fails FAIL" -ForegroundColor Red; exit 1 }
Write-Host '  every control above was pressed, not read' -ForegroundColor Green
exit 0
