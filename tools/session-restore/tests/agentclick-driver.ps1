# ===========================================================================
# CLICKING A NESTED SUB-AGENT ROW IN THE SESSIONS COLUMN.
#
# The report: a sub-agent (or a background task) shows nested under its
# conversation, and clicking it does not show its output.
#
# This driver drives the REAL path - Build-Sessions, the SelectionChanged
# handler, Show-Selected, Update-Document, Start-DocParse and the lane that
# calls Complete-DocParse - and reports which stage loses the transcript.
#
# 🔒 It never launches, kills, types into or signs into anything, and both the
# config and the registry are redirected to copies under .state\ and PROVEN
# redirected by a real write before a single gesture is made.
# ===========================================================================

$dgFails = 0
function DgFail { param($m) Write-Host "  FAIL  $m" -ForegroundColor Red; $script:dgFails++ }
function DgPass { param($m) Write-Host "  ok    $m" -ForegroundColor Green }
function DgNote { param($m) Write-Host "        $m" -ForegroundColor DarkGray }
function DgHead { param($m) Write-Host "`n--- $m" -ForegroundColor Cyan }

# ===========================================================================
# 🔒 SAFETY: THE OPERATOR'S CONFIG AND REGISTRY ARE REDIRECTED, AND PROVEN SO.
# ===========================================================================
DgHead 'safety: redirect the config and the registry, and prove both'

$dgCfgReal = $SR_ConfigPath
$dgCfgCopy = Join-Path $SR_Root '.state\agentclick-config.json'
$dgCfgLiveWas = (Get-FileHash -LiteralPath $dgCfgReal -Algorithm SHA256).Hash
Copy-Item -LiteralPath $dgCfgReal -Destination $dgCfgCopy -Force -ErrorAction Stop
$SR_ConfigPath = $dgCfgCopy
if ("$SR_ConfigPath" -ne "$dgCfgCopy") { DgFail 'the config redirect did not take'; exit 1 }
$dgCfgCopyWas = (Get-FileHash -LiteralPath $dgCfgCopy -Algorithm SHA256).Hash
Save-SRConfigLater -Name 'agentClickHarnessProbe' -Value ([guid]::NewGuid().ToString('N'))
$null = Save-SRConfigWrites
if ((Get-FileHash -LiteralPath $dgCfgCopy -Algorithm SHA256).Hash -eq $dgCfgCopyWas) {
    DgFail 'a real config write did NOT land in the copy - the redirect is not armed. Refusing to run.'; exit 1
}
if ((Get-FileHash -LiteralPath $dgCfgReal -Algorithm SHA256).Hash -ne $dgCfgLiveWas) {
    DgFail 'the LIVE config moved. Stopping immediately.'; exit 1
}
DgPass 'config writes land in the copy and the live file did not move'

$dgRegReal = $SR_RegistryPath
$dgRegCopy = Join-Path $SR_Root '.state\agentclick-registry.json'
$dgRegLiveWas = (Get-FileHash -LiteralPath $dgRegReal -Algorithm SHA256).Hash
Copy-Item -LiteralPath $dgRegReal -Destination $dgRegCopy -Force -ErrorAction Stop
$SR_RegistryPath = $dgRegCopy
if ("$SR_RegistryPath" -ne "$dgRegCopy") { DgFail 'the registry redirect did not take'; exit 1 }
# 🪤 Re-stamp against the COPY, or the staleness check refuses the save for a
# reason that has nothing to do with the redirect.
Set-SRRegistryStamp (Get-SRRegistryStamp)
$dgRegCopyWas = (Get-FileHash -LiteralPath $dgRegCopy -Algorithm SHA256).Hash
$dgReg = Get-SRRegistry
Save-SRRegistry -Registry $dgReg
if ((Get-FileHash -LiteralPath $dgRegCopy -Algorithm SHA256).Hash -eq $dgRegCopyWas) {
    DgFail 'a real registry write did NOT land in the copy - the redirect is not armed. Refusing to run.'; exit 1
}
if ((Get-FileHash -LiteralPath $dgRegReal -Algorithm SHA256).Hash -ne $dgRegLiveWas) {
    DgFail 'the LIVE registry moved. Stopping immediately.'; exit 1
}
DgPass 'registry writes land in the copy and the live file did not move'

# ===========================================================================
DgHead 'the model, and a conversation that has sub-agents on disk'
Update-Model
DgNote "$($script:model.Count) conversations"

$W = 1480.0; $H = 980.0
$dgRoot = $window.Content
function DgLay {
    foreach ($dgP in 1, 2) {
        $dgRoot.Measure((New-Object System.Windows.Size $W, $H))
        $dgRoot.Arrange((New-Object System.Windows.Rect 0, 0, $W, $H))
        $dgRoot.UpdateLayout()
        $window.Dispatcher.Invoke([System.Windows.Threading.DispatcherPriority]::ApplicationIdle, [action]{})
    }
}
$script:foldRail = $false
$script:foldList = $false
$script:foldApplied = ''
DgLay

function DgDocText {
    $dgD = $ui.PaneDoc.Document
    if (-not $dgD) { return '' }
    $dgTr = New-Object System.Windows.Documents.TextRange($dgD.ContentStart, $dgD.ContentEnd)
    return "$($dgTr.Text)"
}

# Pump the way the real window does: let real time pass so the 30 ms write lane
# fires, and drain at ApplicationIdle so DispatcherTimer ticks (Background) get
# through. This is the lane that calls Complete-DocParse.
function DgPump { param([int]$Ms = 900)
    $dgSw = [Diagnostics.Stopwatch]::StartNew()
    while ($dgSw.Elapsed.TotalMilliseconds -lt $Ms) {
        Start-Sleep -Milliseconds 15
        $window.Dispatcher.Invoke([System.Windows.Threading.DispatcherPriority]::ApplicationIdle, [action]{})
    }
    $dgSw.Stop()
}

# The conversation with the most sub-agents that actually have a transcript.
# A property of the data, so the run is not a lottery.
$dgBestRow = $null
$dgBestSubs = @()
foreach ($dgM in $script:model) {
    $dgSubs = @()
    try { $dgSubs = @(Get-SRSubAgents -JsonlPath "$($dgM.S.jsonl)") } catch { continue }
    $dgWith = @($dgSubs | Where-Object { $_.HasTranscript -and $_.Bytes -gt 2000 })
    if ($dgWith.Count -gt $dgBestSubs.Count) { $dgBestSubs = $dgWith; $dgBestRow = $dgM }
}
if (-not $dgBestRow) { DgFail 'no conversation on this machine has a sub-agent with a transcript - cannot test'; exit 1 }
DgNote ("parent: {0}" -f $dgBestRow.T.Text)
DgNote ("parent transcript: {0}" -f $dgBestRow.S.jsonl)
DgNote ("{0} sub-agent(s) with a transcript" -f $dgBestSubs.Count)

# 🪤 SEED THE CACHE THE PROBE FILLS. Get-RowSubAgents is a PURE CACHE READ -
# the background probe is the only thing that ever writes $script:subAgents, and
# a never-shown window runs no probe. Without this the list draws no agent rows
# at all and the whole run reads as "the feature does not exist", which is not
# what the operator is seeing. Filed exactly as Complete-LiveProbe files it.
$script:subAgents["$($dgBestRow.Id)"] = @{ At = (Get-Date); List = @(Get-SRSubAgents -JsonlPath "$($dgBestRow.S.jsonl)") }

$dgSub = @($dgBestSubs | Sort-Object -Property Bytes -Descending)[0]
DgNote ("sub-agent under test: '{0}' id={1} bytes={2:N0} live={3}" -f $dgSub.Label, $dgSub.Id, $dgSub.Bytes, $dgSub.Live)
DgNote ("sub-agent transcript: {0}" -f $dgSub.Path)

# ===========================================================================
DgHead 'STAGE 1 - the parent is selected and its document renders'
$script:selId = "$($dgBestRow.Id)"
Build-Sessions
DgLay
$dgParentItem = @($ui.SessionList.Items | Where-Object { $_.Kind -eq 'session' -and "$($_.Id)" -eq "$($dgBestRow.Id)" })
if (-not $dgParentItem.Count) { DgFail 'the parent row is not in the list'; exit 1 }
$ui.PaneDoc.Document = $null
$ui.SessionList.SelectedItem = $dgParentItem[0]
Show-Selected -Force
DgPump 1200
$dgParentText = DgDocText
if ("$dgParentText".Trim().Length -lt 50) { DgFail 'the PARENT document did not render either - the harness is not exercising the real path' }
else { DgPass ("the parent's document rendered, {0:N0} chars" -f $dgParentText.Length) }

# ===========================================================================
DgHead 'STAGE 2 - the sub-agent row exists in the list'
# selId as an agent id is what makes Build-Sessions keep a finished agent's row
# on screen ($pickedSub) - the same path a click through a live row takes once
# the agent goes quiet.
$script:selId = ('agent:' + $dgSub.Id)
Build-Sessions
DgLay
$dgAgentItems = @($ui.SessionList.Items | Where-Object { $_.Kind -eq 'agent' })
DgNote ("{0} agent row(s) in the list" -f $dgAgentItems.Count)
$dgAgentItem = @($dgAgentItems | Where-Object { "$($_.Id)" -eq ('agent:' + $dgSub.Id) })
if (-not $dgAgentItem.Count) { DgFail 'the sub-agent row was not built - cannot go further'; exit 1 }
DgPass ("the sub-agent row is present: '{0}'  [{1}]" -f $dgAgentItem[0].SubName, $dgAgentItem[0].SubTag)

# ===========================================================================
DgHead 'STAGE 3 - clicking it: the whole path, exactly as the window runs it'
$dgSel = $dgAgentItem[0]
# The list already reselected it at the end of Build-Sessions, which is what a
# click does too. Force the draw so nothing is skipped by the $same guard.
$ui.SessionList.SelectedItem = $dgSel
Show-Selected -Force
DgNote ("after Show-Selected: agentOpen={0}  docPath={1}" -f `
    $(if ($script:agentOpen) { 'set' } else { 'null' }), (Split-Path -Leaf "$($script:docPath)"))
DgNote ("Start-DocParse keyed the parse for: {0}" -f "$($script:docFor)")
DgNote ("expected (agent):  {0}|{1}" -f "$($dgSub.Path)".ToLower(), $script:tailBytes)

# Wait for the off-thread parse to land, then ask the lane's own collector.
$dgSw2 = [Diagnostics.Stopwatch]::StartNew()
while ($dgSw2.Elapsed.TotalSeconds -lt 10 -and $script:docHandle -and -not $script:docHandle.IsCompleted) {
    Start-Sleep -Milliseconds 10
}
$dgSw2.Stop()
if (-not $script:docHandle) { DgNote 'no parse handle (already collected, or the inline fallback ran)' }
else { DgNote ("the parse completed in {0:N0} ms; now asking Complete-DocParse for it" -f $dgSw2.Elapsed.TotalMilliseconds) }

# 🔎 THE GUARD, EVALUATED HERE THE SAME WAY Complete-DocParse EVALUATES IT.
$dgIt = $ui.SessionList.SelectedItem
DgNote ("Complete-DocParse guard 1 - SelectedItem.Kind is '{0}'; it returns false unless this is 'session'" -f "$($dgIt.Kind)")
$dgNow = ('{0}|{1}' -f "$($dgIt.Row.S.jsonl)".ToLower(), $script:tailBytes)
DgNote ("Complete-DocParse guard 2 - it would compare")
DgNote ("    now    = {0}" -f $dgNow)
DgNote ("    docFor = {0}" -f "$($script:docFor)")
DgNote ("    equal? {0}" -f ($dgNow -eq "$($script:docFor)"))

$dgTook = Complete-DocParse
DgNote ("Complete-DocParse returned: {0}" -f $dgTook)

DgPump 1200
$dgAgentText = DgDocText

# ===========================================================================
DgHead 'STAGE 4 - what is actually on screen'
DgNote ("PaneName  = '{0}'" -f $ui.PaneName.Text)
DgNote ("PaneState = '{0}'" -f $ui.PaneState.Text)
DgNote ("PaneEmpty visible = {0}; text = '{1}'" -f $ui.PaneEmpty.Visibility,
        ("$($ui.PaneEmpty.Text)" -replace "`r?`n", ' / '))
DgNote ("document chars = {0:N0}" -f "$dgAgentText".Length)

# The honest comparison: is the pane showing the AGENT's words, or still the
# parent's? Take a distinctive slice of each transcript and look for it.
$dgAgentBlocks = @()
try { $dgGotA = Get-SRTranscriptBlocks -JsonlPath "$($dgSub.Path)" -MaxRecords 220 -MaxTailBytes $script:tailBytes; $dgAgentBlocks = @($dgGotA) } catch { }
DgNote ("the agent transcript parses to {0} block(s) on its own" -f $dgAgentBlocks.Count)
$dgProbe = ''
foreach ($dgB in $dgAgentBlocks) {
    if ("$($dgB.Kind)" -ne 'said' -and "$($dgB.Kind)" -ne 'user') { continue }
    foreach ($dgLine in ("$($dgB.Body)" -split "`n")) {
        $dgT = $dgLine.Trim()
        if ($dgT.Length -ge 40) { $dgProbe = $dgT.Substring(0, 40); break }
    }
    if ($dgProbe) { break }
}
if (-not $dgProbe) { DgNote 'no probe text could be lifted from the agent transcript' }
else {
    DgNote ("probe from the AGENT transcript: '{0}'" -f ($dgProbe -replace "`r?`n", ' '))
    if ("$dgAgentText".Contains($dgProbe)) { DgPass 'the pane is showing the SUB-AGENT transcript' }
    else { DgFail 'the pane is NOT showing the sub-agent transcript' }
}
if ("$dgAgentText".Length -gt 0 -and "$dgAgentText" -eq "$dgParentText") {
    DgFail 'the pane is showing the PARENT document, unchanged - the click did nothing'
}

# ===========================================================================
DgHead 'STAGE 5 - a sub-agent with NO transcript on disk (must say so in words)'
$dgNone = $null
foreach ($dgM2 in $script:model) {
    $dgS2 = @()
    try { $dgS2 = @(Get-SRSubAgents -JsonlPath "$($dgM2.S.jsonl)") } catch { continue }
    $dgN2 = @($dgS2 | Where-Object { -not $_.HasTranscript })
    if ($dgN2.Count) {
        $dgNone = @{ Row = $dgM2; Sub = $dgN2[0] }
        $script:subAgents["$($dgM2.Id)"] = @{ At = (Get-Date); List = @($dgS2) }
        break
    }
}
if (-not $dgNone) { DgNote 'no transcript-less sub-agent on this machine - skipping' }
else {
    DgNote ("using '{0}' under '{1}'" -f $dgNone.Sub.Label, $dgNone.Row.T.Text)
    # 🪤 A ROW ONLY REACHES THE $expand TEST IF IT IS LIVE, WARM OR THE PINNED
    # SELECTION - and an agent id pins nothing. Picking the project keeps ALL of
    # its conversations, which is the operator's own gesture, not a fixture.
    $script:railPick = "$($dgNone.Row.D.path)"
    $script:selId = ('agent:' + $dgNone.Sub.Id)
    Build-Sessions
    DgLay
    $dgNoneItem = @($ui.SessionList.Items | Where-Object { "$($_.Id)" -eq ('agent:' + $dgNone.Sub.Id) })
    if (-not $dgNoneItem.Count) { DgNote 'that row was not built (it is not live and not picked) - skipping' }
    else {
        $ui.PaneDoc.Document = $null
        $ui.PaneEmpty.Text = ''
        $ui.SessionList.SelectedItem = $dgNoneItem[0]
        Show-Selected -Force
        DgPump 600
        DgNote ("PaneEmpty visible = {0}" -f $ui.PaneEmpty.Visibility)
        DgNote ("PaneEmpty text    = '{0}'" -f ("$($ui.PaneEmpty.Text)" -replace "`r?`n", ' / '))
        if ("$($ui.PaneEmpty.Text)" -like '*left no transcript*') { DgPass 'the no-transcript message is drawn' }
        else { DgFail 'the no-transcript message is NOT drawn' }
    }
    $script:railPick = $null
}

# ===========================================================================
DgHead 'STAGE 6 - drilling in from a transcript block (Show-AgentDoc), for contrast'
$ui.PaneDoc.Document = $null
Show-AgentDoc $dgSub $dgBestRow
DgPump 400
$dgDrillText = DgDocText
DgNote ("document chars = {0:N0}" -f "$dgDrillText".Length)
if ($dgProbe -and "$dgDrillText".Contains($dgProbe)) { DgPass 'Show-AgentDoc DOES render the sub-agent transcript' }
elseif (-not $dgProbe) { DgNote 'no probe - cannot compare' }
else { DgFail 'Show-AgentDoc did not render the sub-agent transcript either' }
Close-AgentDoc

# ===========================================================================
DgHead 'STAGE 7 - A BACKGROUND SHELL: the run block in the transcript'
# A background Bash never gets a row of its own in the sessions column; the only
# place its output is reachable is the run block in the reading pane, opened.
# So that is what this drives.
$script:railPick = $null
# 🪤 THE SUITE OWNS THE INPUT IT MEASURES. `transcriptTools` is a REAL OPERATOR
# SETTING and it is 'hidden' on this machine - which drops EVERY run block from
# the document, so a shell's output has nowhere to be drawn and this stage would
# read as "the feature does not work" when it had simply not been asked to draw.
# The setting itself is reported separately; this stage tests the drawing.
DgNote ("the operator's transcriptTools setting is '{0}'" -f $script:toolView)
$dgToolWas = $script:toolView
$script:toolView = 'folded'
$dgShRow = $null
$dgShCall = $null
$dgShFallRow = $null
$dgShFallCall = $null
foreach ($dgM3 in $script:model) {
    $dgJ3 = "$($dgM3.S.jsonl)"
    if (-not $dgJ3 -or -not (Test-Path -LiteralPath $dgJ3)) { continue }
    $dgB3 = @()
    try { $dgG3 = Get-SRTranscriptBlocks -JsonlPath $dgJ3 -MaxRecords 220 -MaxTailBytes $script:tailBytes; $dgB3 = @($dgG3) } catch { continue }
    $dgT3 = @()
    try { $dgT3 = @(Get-ReadTurns $dgB3) } catch { continue }
    foreach ($dgTurn in $dgT3) {
        if ("$($dgTurn.Kind)" -ne 'run') { continue }
        foreach ($dgC in @($dgTurn.Calls)) {
            if ("$($dgC.CallKind)" -ne 'shell' -or -not "$($dgC.Shell)") { continue }
            if (-not $dgShFallCall) { $dgShFallRow = $dgM3; $dgShFallCall = $dgC }
            # 🔑 PREFER ONE WHOSE OUTPUT FILE STILL EXISTS. A reaped shell draws
            # a different (and correct) message, so testing only that would
            # never touch the path the report is about.
            $dgP3 = ''
            try { $dgP3 = Get-SRShellOutputPath -SessionId "$($dgM3.Id)" -Shell "$($dgC.Shell)" } catch { }
            if ($dgP3) { $dgShRow = $dgM3; $dgShCall = $dgC; break }
        }
        if ($dgShCall) { break }
    }
    if ($dgShCall) { break }
}
if (-not $dgShCall -and $dgShFallCall) {
    DgNote 'no live output file found for any shell in a visible tail - falling back to a reaped one'
    $dgShRow = $dgShFallRow; $dgShCall = $dgShFallCall
}
if (-not $dgShCall) { DgNote 'no conversation in the visible tail has a background-shell call - skipping' }
else {
    DgNote ("parent: '{0}'  id={1}" -f $dgShRow.T.Text, $dgShRow.Id)
    DgNote ("shell id from the transcript: {0}" -f $dgShCall.Shell)
    $dgShPath = ''
    try { $dgShPath = Get-SRShellOutputPath -SessionId "$($dgShRow.Id)" -Shell "$($dgShCall.Shell)" } catch { }
    DgNote ("Get-SRShellOutputPath -> '{0}'" -f $dgShPath)

    # Render that conversation the way the window does, then open the run block.
    $script:railPick = "$($dgShRow.D.path)"
    $script:selId = "$($dgShRow.Id)"
    Build-Sessions
    DgLay
    $dgShItem = @($ui.SessionList.Items | Where-Object { $_.Kind -eq 'session' -and "$($_.Id)" -eq "$($dgShRow.Id)" })
    if (-not $dgShItem.Count) { DgNote 'that conversation is not in the list - skipping' }
    else {
        $ui.PaneDoc.Document = $null
        $ui.SessionList.SelectedItem = $dgShItem[0]
        Show-Selected -Force
        DgPump 1500
        if (-not $ui.PaneDoc.Document) { DgFail 'the conversation with the shell call did not render at all' }
        else {
            DgNote ("docSessionId while the document is up: '{0}'" -f "$($script:docSessionId)")
            # Find every fold header in the document and open the run blocks.
            $dgHeaders = New-Object System.Collections.Generic.List[object]
            function DgWalk { param($El)
                if (-not $El) { return }
                if ($El -is [System.Windows.Controls.Border] -and $El.Tag -and $El.Tag.Kind) {
                    $null = $script:dgHeadersRef.Add($El); return
                }
                if ($El -is [System.Windows.Controls.Panel]) { foreach ($dgCh in $El.Children) { DgWalk $dgCh } }
                elseif ($El -is [System.Windows.Controls.Border]) { DgWalk $El.Child }
                elseif ($El -is [System.Windows.Controls.ContentControl]) { DgWalk $El.Content }
            }
            $script:dgHeadersRef = $dgHeaders
            foreach ($dgBlk in $ui.PaneDoc.Document.Blocks) {
                if ($dgBlk -is [System.Windows.Documents.BlockUIContainer]) { DgWalk $dgBlk.Child }
            }
            $dgKinds = @{}
            foreach ($dgBlk2 in $ui.PaneDoc.Document.Blocks) {
                $dgKn = $dgBlk2.GetType().Name
                $dgKinds[$dgKn] = [int]$dgKinds[$dgKn] + 1
            }
            DgNote ("toolView = '{0}'; document blocks: {1}" -f $script:toolView,
                    (@($dgKinds.Keys | Sort-Object | ForEach-Object { "$_=$($dgKinds[$_])" }) -join ' '))
            DgNote ("{0} foldable block(s) in the document" -f $dgHeaders.Count)
            $dgOpened = 0
            $dgShellFound = 0
            $dgShellText = ''
            foreach ($dgH in $dgHeaders) {
                if ("$($dgH.Tag.Kind)" -ne 'run') { continue }
                $dgHasShell = $false
                foreach ($dgC2 in @($dgH.Tag.Data)) { if ("$($dgC2.CallKind)" -eq 'shell' -and "$($dgC2.Shell)") { $dgHasShell = $true } }
                if (-not $dgHasShell) { continue }
                $dgShellFound++
                if (-not $dgH.Tag.Open) { Invoke-FoldToggle $dgH; $dgOpened++ }
                # Everything the opened panel now holds, as text.
                $dgTexts = New-Object System.Collections.Generic.List[object]
                $script:dgTextsRef = $dgTexts
                function DgText { param($El)
                    if (-not $El) { return }
                    if ($El -is [System.Windows.Controls.TextBlock]) { $null = $script:dgTextsRef.Add("$($El.Text)"); return }
                    if ($El -is [System.Windows.Controls.Panel]) { foreach ($dgC3 in $El.Children) { DgText $dgC3 } }
                    elseif ($El -is [System.Windows.Controls.Border]) { DgText $El.Child }
                    elseif ($El -is [System.Windows.Controls.ContentControl]) { DgText $El.Content }
                }
                DgText $dgH.Tag.Panel
                $dgShellText = ($dgTexts -join "`n")
                break
            }
            DgNote ("run block(s) carrying a background shell: {0}; opened: {1}" -f $dgShellFound, $dgOpened)
            if (-not $dgShellFound) { DgNote 'the visible tail of this conversation has no shell run block - skipping' }
            else {
                $dgShLine = @($dgShellText -split "`n" | Where-Object { $_ -match 'OUTPUT|CLEANED UP|COULD NOT BE READ|NOTHING PRINTED' })
                DgNote ("the shell section says: '{0}'" -f (@($dgShLine) -join ' / '))
                if ($dgShLine.Count) { DgPass 'the opened run block DOES draw the background shell section' }
                else { DgFail 'the opened run block drew NO background-shell section at all' }
            }
        }
    }
    $script:railPick = $null
}
$script:toolView = $dgToolWas

# ===========================================================================
DgHead 'STAGE 8 - what Steps: hidden costs (the operator IS on hidden)'
if ("$dgToolWas" -ne 'hidden') { DgNote "not on 'hidden' - nothing to say" }
else {
    DgNote 'with transcriptTools=hidden, Add-ReadTurn drops every run block:'
    DgNote '  - a background shell prints its output ONLY inside an opened run block'
    DgNote '  - the "open its conversation ->" link into a sub-agent is built ONLY there'
    DgNote 'so on this machine neither is reachable from the reading pane at all.'
}

# ===========================================================================
Write-Host ''
if ($script:dgFails) { Write-Host ("{0} finding(s)" -f $script:dgFails) -ForegroundColor Yellow }
else { Write-Host 'nothing found' -ForegroundColor Green }
exit 0
