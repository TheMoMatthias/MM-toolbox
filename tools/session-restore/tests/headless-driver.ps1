
# ===========================================================================
# HEADLESS. The window is BUILT but never SHOWN.
#
# run-tests.ps1 splices sessions-gui.ps1 just before its ShowDialog and appends
# this file. Everything above that line runs: the XAML loads, $ui binds, every
# handler attaches, the registry loads and the first Update-List happens. What
# does not happen is a window appearing on anybody's screen.
#
# WHY THIS EXISTS. Every bug that actually shipped from this subsystem today was
# a code bug, not a pixel bug:
#   - foreach ($c in ...) replacing the palette $C, so every brush came back
#     null and the next repaint threw;
#   - [System.Windows.Data.ItemsControl], a namespace that does not exist, so a
#     button silently did nothing;
#   - Get-Lanes' ",@()" return unwrapped one step too far, so a project label
#     read as every lane name at once.
# Not one of them needed a visible window to catch. They needed the code to RUN.
# The suites that did need a real window were also the ones fighting the
# operator for the mouse, which is the other half of why this is here.
#
# Add_ContentRendered never fires on an unshown window, so no background scan
# starts and no timer touches anything: the state is exactly what this driver
# puts there, which is what makes the assertions deterministic.
# ===========================================================================

$ErrorActionPreference = 'Stop'

$fails = 0
function Fail { param($m) Write-Host "  FAIL  $m" -ForegroundColor Red; $script:fails++ }
function Pass { param($m) Write-Host "  ok    $m" -ForegroundColor Green }
function Note { param($m) Write-Host "        $m" -ForegroundColor DarkGray }

# --- synthetic state --------------------------------------------------------
# The REAL registry is already loaded, so the rows are real rows with real ids;
# only what each conversation is DOING is fabricated. Inventing registry objects
# instead would test a shape this code never actually sees.
$ids = @()
foreach ($d in $script:dirs) {
    foreach ($s in @($d.sessions)) { if ($s.sessionId) { $ids += "$($s.sessionId)" } }
}
if ($ids.Count -lt 6) {
    Write-Host "  only $($ids.Count) conversations in the registry - need at least 6" -ForegroundColor Yellow
    exit 2
}
Note "$($ids.Count) conversations in the registry; staging 6 of them"

# $ProcId, not $Pid: $Pid is a READ-ONLY automatic variable in PowerShell, and a
# parameter of that name kills the whole script with "Cannot overwrite variable
# Pid because it is read-only or constant" before one assertion runs.
function New-Agent {
    param([string]$Status, [string]$WaitingFor = '', [int]$ProcId = 4242, [string]$Kind = 'interactive', [string]$Name)
    return [PSCustomObject]@{
        Status = $Status; WaitingFor = $WaitingFor
        Needs  = (($WaitingFor -ne '') -or ($Status -eq 'blocked'))
        Pid    = $ProcId; Kind = $Kind; Name = $Name; Cwd = 'C:\nowhere'; StartedAt = (Get-Date)
    }
}
function New-Conv {
    param([string]$State, [string]$Detail, [bool]$Stale = $false, [int]$AgeMin = 1)
    return [PSCustomObject]@{
        State = $State; Detail = $Detail; Stale = $Stale
        LastActive = (Get-Date).AddMinutes(-$AgeMin)
        LastPrompt = 'what I asked it'; Title = $null; Mode = 'default'
    }
}

$A = @{}; $C2 = @{}; $S = @{}
# 0: waiting on a permission dialog. Wants a click, not a sentence.
$A[$ids[0].ToLower()] = New-Agent -Status 'waiting' -WaitingFor 'dialog open' -Name 'STAGE-DIALOG'
$C2[$ids[0].ToLower()] = New-Conv -State 'waiting' -Detail 'a dialog is open, it wants an answer' -AgeMin 2
$S[$ids[0].ToLower()] = [PSCustomObject]@{ Said = 'I need to run one command'; Pending = 'Bash(rm -rf /tmp/x)'; PendingTool = 'Bash'; At = (Get-Date).AddMinutes(-2) }

# 1: a BLOCKED BACKGROUND AGENT. No pid, no terminal, cannot be typed into.
$A[$ids[1].ToLower()] = New-Agent -Status 'blocked' -ProcId 0 -Kind 'background' -Name 'STAGE-AGENT'
$C2[$ids[1].ToLower()] = New-Conv -State 'waiting' -Detail 'blocked, needs you' -AgeMin 30
$S[$ids[1].ToLower()] = [PSCustomObject]@{ Said = ''; Pending = ''; PendingTool = ''; At = $null }

# 2: busy.
$A[$ids[2].ToLower()] = New-Agent -Status 'busy' -Name 'STAGE-BUSY'
$C2[$ids[2].ToLower()] = New-Conv -State 'working' -Detail 'running' -AgeMin 1
$S[$ids[2].ToLower()] = [PSCustomObject]@{ Said = 'Running the suite now'; Pending = 'Bash(pytest)'; PendingTool = 'Bash'; At = (Get-Date).AddMinutes(-1) }

# 3: idle, and it HAS said something. This is the case a mtime-only gate lost:
# held by a process, silent at its prompt, therefore "stale".
$A[$ids[3].ToLower()] = New-Agent -Status 'idle' -Name 'STAGE-IDLE'
$C2[$ids[3].ToLower()] = New-Conv -State 'idle' -Detail 'at its prompt, nothing pending' -Stale $true -AgeMin 20
$S[$ids[3].ToLower()] = [PSCustomObject]@{ Said = 'Done and pushed.'; Pending = ''; PendingTool = ''; At = (Get-Date).AddMinutes(-20) }

# 4: NOT RUNNING. Its transcript moved recently, so it is worth showing, but
# nothing is holding it.
#
# The first version of this staged it with no agent and a 4000-minute-old
# transcript and expected the 'quiet' band. It is not in the inbox at all, and
# that is CORRECT: the inbox lists what is running or recently active, not all
# 143 conversations in the registry. Reaching 'quiet' needs liveness evidence
# ($script:live or $script:running) WITHOUT an agent entry -- a conversation
# whose process has gone but whose transcript is still warm. Resolve-SRSession
# State returns Stale=$true whenever there is no agent, which is what stops a
# dead conversation ever being labelled 'working'.
$C2[$ids[4].ToLower()] = New-Conv -State 'idle' -Detail 'was at its prompt' -Stale $true -AgeMin 5

# 5: waiting for input, and NEWER than 0, so ordering inside the band is provable.
$A[$ids[5].ToLower()] = New-Agent -Status 'waiting' -WaitingFor 'input needed' -Name 'STAGE-WAITING'
$C2[$ids[5].ToLower()] = New-Conv -State 'waiting' -Detail 'input needed' -AgeMin 1
$S[$ids[5].ToLower()] = [PSCustomObject]@{ Said = 'Which schema should I use?'; Pending = ''; PendingTool = ''; At = (Get-Date).AddMinutes(-1) }

$script:agents = $A
$script:conv   = $C2
$script:said   = $S
$script:running = @{}
foreach ($k in @($A.Keys)) { if ($A[$k].Pid) { $script:running[$k] = $true } }
# Transcript-moved-recently, which is inferred liveness and separate from a
# process actually holding the id. Session 4 has this and nothing else.
$script:live = @{ $ids[4].ToLower() = $true }

# lastActive drives the sort inside a band, so stage it to match the states.
$byId = @{}
foreach ($d in $script:dirs) { foreach ($s in @($d.sessions)) { if ($s.sessionId) { $byId["$($s.sessionId)".ToLower()] = $s } }}
$byId[$ids[0].ToLower()].lastActive = (Get-Date).AddMinutes(-2).ToString('o')
$byId[$ids[5].ToLower()].lastActive = (Get-Date).AddMinutes(-1).ToString('o')

# --- build it ---------------------------------------------------------------
try { Update-List -ToTop } catch { Fail "Update-List threw: $($_.Exception.Message)" }

# .ToArray(), not @(...). On PowerShell 5.1.26100.9168 the array subexpression
# @() throws "Argument types do not match" against a List[object] -- which is
# exactly what Build-InboxRows returns. Piping and .ToArray() both work.
$rows = $script:inboxRows.ToArray()
if (-not $rows.Count) { Fail 'the inbox built no rows at all'; }
else { Pass "the inbox built $($rows.Count) row(s)" }

function RowFor { param([string]$Id)
    foreach ($r in $rows) { if ($r.Kind -eq 'session' -and "$($r.Session.sessionId)" -ieq $Id) { return $r } }
    return $null
}
function BandOf { param([string]$Id) $r = RowFor $Id; if ($r) { return $r.Band } return '' }

# --- 1. every conversation lands in exactly one band ------------------------
$expect = @{ 0 = 'needs'; 1 = 'needs'; 2 = 'working'; 3 = 'idle'; 4 = 'quiet'; 5 = 'needs' }
foreach ($i in @($expect.Keys | Sort-Object)) {
    $got = BandOf $ids[$i]
    if ($got -eq $expect[$i]) { Pass "staged session $i is in '$got'" }
    else { Fail "staged session $i is in '$got', expected '$($expect[$i])'" }
}

# A partition: no id may appear twice.
$seen = @{}
$dupes = 0
foreach ($r in $rows) {
    if ($r.Kind -ne 'session') { continue }
    $k = "$($r.Session.sessionId)".ToLower()
    if ($seen[$k]) { $dupes++ }
    $seen[$k] = $true
}
if ($dupes -eq 0) { Pass 'no conversation appears in two bands' }
else { Fail "$dupes conversation(s) appear more than once" }

# --- 2. NOTHING renders invisible -------------------------------------------
# The guard inside Update-InboxList throws on a null brush, so reaching here
# already proves a lot -- but assert it directly too, because a guard that stops
# being reached is a guard that stops guarding.
$nullBrush = 0
foreach ($r in $rows) {
    if ($r.Said -and $null -eq $r.SaidBrush) { $nullBrush++ }
    if ($r.Name -and $null -eq $r.NameBrush) { $nullBrush++ }
}
if ($nullBrush -eq 0) { Pass 'every row with text has a brush to draw it with' }
else { Fail "$nullBrush row(s) carry text with no brush - they would render blank" }

# --- 3. the band headings ---------------------------------------------------
$heads = @($rows | Where-Object { $_.Kind -eq 'band' })
if ($heads.Count -ge 3) { Pass "$($heads.Count) band heading(s): $((@($heads | ForEach-Object { $_.Name })) -join ', ')" }
else { Fail "only $($heads.Count) band heading(s)" }
foreach ($h in $heads) {
    if ("$($h.Counts)" -match '^\d+$') { } else { Fail "band '$($h.Name)' has a count of '$($h.Counts)'" }
}
$needsHead = @($heads | Where-Object { $_.Band -eq 'needs' })
if ($needsHead.Count -eq 1 -and [int]$needsHead[0].Counts -eq 3) { Pass 'NEEDS YOU counts exactly the 3 staged' }
elseif ($needsHead.Count -eq 1) { Fail "NEEDS YOU says $($needsHead[0].Counts), expected 3" }
else { Fail 'no NEEDS YOU heading' }

# --- 4. ordering inside a band ----------------------------------------------
$needsRows = @($rows | Where-Object { $_.Kind -eq 'session' -and $_.Band -eq 'needs' })
$firstId = "$($needsRows[0].Session.sessionId)".ToLower()
if ($firstId -eq $ids[5].ToLower()) { Pass 'the newest waiting conversation is first in the band' }
else { Fail "the band leads with $firstId, expected the newer $($ids[5].ToLower())" }

# --- 5. a background agent offers nothing it cannot do ----------------------
$agentRow = RowFor $ids[1]
if (-not $agentRow) { Fail 'the background agent has no row' }
elseif ($agentRow.CanJump) { Fail 'the background agent offers an action it cannot perform' }
elseif ($agentRow.JumpLabel -ne 'agent') { Fail "the background agent's action reads '$($agentRow.JumpLabel)'" }
else { Pass "the background agent is labelled '$($agentRow.JumpLabel)' and disabled" }

# --- 6. a dialog says what it is asking about -------------------------------
$dialogRow = RowFor $ids[0]
if (-not $dialogRow) { Fail 'the dialog session has no row' }
elseif ($dialogRow.Said -match 'rm -rf|wants to run|dialog') { Pass "the dialog row says: '$($dialogRow.Said)'" }
else { Fail "the dialog row says '$($dialogRow.Said)', which does not name what it is asking" }

# --- 7. an idle session still shows what it SAID ----------------------------
$idleRow = RowFor $ids[3]
if ($idleRow -and $idleRow.Said -eq 'Done and pushed.') { Pass 'an idle session shows its last reply, not a placeholder' }
elseif ($idleRow) { Fail "the idle row says '$($idleRow.Said)'" }
else { Fail 'the idle session has no row' }

# --- 8. the project label is ONE lane, not all of them ----------------------
# Get-Lanes returns ",@(...)"; wrapping it one step too far made every row read
# "AlgoTrader / main I7 F2 AN2 I6 ..." with the whole repo concatenated.
$badLabel = @($rows | Where-Object { $_.Kind -eq 'session' -and ("$($_.Project)" -split '\s+').Count -gt 4 })
if ($badLabel.Count -eq 0) { Pass 'every project label names one project and one lane' }
else { Fail "$($badLabel.Count) row(s) have a run-together project label, e.g. '$($badLabel[0].Project)'" }

# --- 9. the views switch without throwing -----------------------------------
foreach ($mode in @('all', 'inbox')) {
    $threw = $null
    try { Set-ViewMode $mode } catch { $threw = $_.Exception.Message }
    if ($threw) { Fail "Set-ViewMode '$mode' threw: $threw"; continue }
    $inbox = ($mode -eq 'inbox')
    $listOk = ($ui.InboxList.Visibility -eq $(if ($inbox) { $V_Show } else { $V_Hide })) -and
              ($ui.RowList.Visibility   -eq $(if ($inbox) { $V_Hide } else { $V_Show }))
    if (-not $listOk) { Fail "'$mode' shows the wrong list"; continue }
    # AND IT MUST HAVE CONTENT. Set-ViewMode swaps Visibility BEFORE it rebuilds,
    # so a rebuild that throws still leaves the right list showing and empty.
    $n = $(if ($inbox) { $script:inboxRows.Count } else { $script:rows.Count })
    if ($n -lt 1) { Fail "'$mode' left an EMPTY list - the rebuild did not happen"; continue }
    # The logon furniture is what used to make Restore a separate view.
    if ($ui.LaunchTicked.Visibility -ne $(if ($inbox) { $V_Hide } else { $V_Show })) {
        Fail "'$mode' has the wrong idea about 'Launch everything ticked'"; continue
    }
    Pass "'$mode' shows the right list, with $n rows, and the right chrome"
}

# The old 'tree' and 'restore' names have to keep landing somewhere sane rather
# than silently doing nothing: Set-ViewMode returns early on an unknown mode,
# and an early return leaves whatever was on screen with no error anywhere.
foreach ($old in @('tree', 'restore')) {
    Set-ViewMode 'inbox'
    Set-ViewMode $old
    if ($script:viewMode -eq 'all') { Pass "the old name '$old' still reaches the All view" }
    else { Fail "Set-ViewMode '$old' left the view as '$($script:viewMode)'" }
}

# --- 9b. THE ALL VIEW IS FLAT, AND IT IS BOUNDED ----------------------------
# It was a tree: 143 conversations rendered as 195 rows because every project
# and every lane took a row of its own, and eleven of the fifteen projects had
# exactly one lane called "main". It was also unbounded - registryWindowDays
# caps what is TRACKED at 30 days and nothing capped what was SHOWN.
Set-ViewMode 'all'
$allRows = @(); foreach ($r in $script:rows) { $allRows += $r }
$kinds = @($allRows | ForEach-Object { $_.Kind } | Sort-Object -Unique)
$bad = @($kinds | Where-Object { $_ -ne 'session' -and $_ -ne 'more' })
if ($bad.Count) { Fail "the All view still builds structural rows: $($bad -join ', ')" }
else { Pass "the All view is flat - only $($kinds -join ' and ') rows" }

$sessionRows = @($allRows | Where-Object { $_.Kind -eq 'session' })
if ($sessionRows.Count -lt $script:totalCount) {
    Pass "the age window shows $($sessionRows.Count) of $($script:totalCount) conversations"
} else {
    Fail "the age window hid nothing: $($sessionRows.Count) rows for $($script:totalCount) conversations"
}

# NOTHING IS HIDDEN SILENTLY. Whatever the window cut has to be on screen as a
# count, and one press has to bring it back.
$moreRow = @($allRows | Where-Object { $_.Kind -eq 'more' })
if (-not $moreRow.Count) { Fail 'the age window cut rows and said nothing about it' }
elseif ("$($moreRow[0].Name)" -notmatch "$($script:olderCount)") {
    Fail "the older-conversations row says '$($moreRow[0].Name)' but $($script:olderCount) were cut"
} else { Pass "it says so on a row of its own: '$($moreRow[0].Name)'" }

$before = $sessionRows.Count
$script:showOlder = $true
Update-List
$after = @($script:rows | Where-Object { $_.Kind -eq 'session' }).Count
if ($after -gt $before) { Pass "'Show older' widens the list ($before -> $after)" }
else { Fail "'Show older' changed nothing ($before -> $after)" }
$script:showOlder = $false
Update-List

# A LIVE conversation is never hidden by age, whatever its timestamp says.
$agedOut = @()
foreach ($d in $script:dirs) {
    foreach ($sn in @($d.sessions)) {
        if (-not $sn.sessionId) { continue }
        if ((Get-InboxBand $sn) -eq 'quiet') { continue }
        $key = "$($d.path)|"
        $hit = @($script:rows | Where-Object { $_.Kind -eq 'session' -and $_.Session.sessionId -eq $sn.sessionId })
        if (-not $hit.Count) { $agedOut += (Get-SessionTitle $sn $d) }
    }
}
if ($agedOut.Count) { Fail "the age window hid $($agedOut.Count) conversation(s) that are not NOT-RUNNING: $($agedOut -join ', ')" }
else { Pass 'nothing that is running was hidden by the age window' }

# --- 9c. the tick belongs to conversations alone ----------------------------
$tickable = @($allRows | Where-Object { $_.TickVisibility -eq $V_Show })
$wrongTick = @($tickable | Where-Object { $_.Kind -ne 'session' })
if ($wrongTick.Count) { Fail "$($wrongTick.Count) non-conversation row(s) still offer a tick" }
elseif (-not $tickable.Count) { Fail 'no row offers a tick at all' }
else { Pass "only conversations carry a tick ($($tickable.Count) of $($allRows.Count) rows)" }

# Shift-click ticks a range, which is what the project and lane checkboxes were
# really for.
# FROM THE CURRENT ROWS, not the snapshot taken before the show-older toggle
# above: Update-List builds NEW Row objects every time, so the old ones are not
# in the list any more and a range between two of them is a range of nothing.
# Set-TickRange degrades to a single tick when it cannot find its endpoints,
# which is the right behaviour and reads exactly like a broken range.
$sessionRows = @($script:rows | Where-Object { $_.Kind -eq 'session' })
$victims = @($sessionRows | Select-Object -First 4)
if ($victims.Count -ge 4) {
    foreach ($v in $victims) { $v.Session.enabled = $false }
    $script:tickAnchor = $victims[0]
    Set-TickRange -Row $victims[3] -Value $true
    $on = @($victims | Where-Object { $_.Session.enabled }).Count
    if ($on -eq 4) { Pass 'shift-click ticks the whole range between anchor and click' }
    else { Fail "a range tick reached $on of 4 conversations" }
    foreach ($v in $victims) { $v.Session.enabled = $false }
}

# --- 10. the palette survived -----------------------------------------------
# The $c/$C collision emptied this table and every brush afterwards was null.
# The table is $Pal now precisely so no loop variable can shadow it again.
$missing = @('TextMax','TextHigh','TextMid','TextLow','TextDim') | Where-Object { -not $Pal[$_] }
if ($missing.Count -eq 0) { Pass 'the palette is still a palette after switching views' }
else { Fail "the palette lost: $($missing -join ', ')" }

# --- 11. a band heading is not an action target -----------------------------
# Back to the inbox first: Update-Selection reads whichever list is SHOWING, and
# the block above leaves the All view up.
Set-ViewMode 'inbox'
$bandRow = @($script:inboxRows.ToArray() | Where-Object { $_.Kind -eq 'band' })[0]
if ($bandRow) {
    $ui.InboxList.SelectedItem = $bandRow
    Update-Selection
    if ("$($ui.SelName.Text)" -eq 'nothing selected') { Pass 'selecting a band heading arms no actions' }
    else { Fail "selecting a band heading set the footer to '$($ui.SelName.Text)'" }
}

# --- 12. the pills announce their counts ------------------------------------
# A Button whose Content is a panel has NO accessible name unless one is set.
$nameProp = [System.Windows.Automation.AutomationProperties]::NameProperty
foreach ($pair in @(@{B=$ui.LivePill;T=$ui.LiveSummary}, @{B=$ui.WaitPill;T=$ui.WaitSummary})) {
    $an = "$($pair.B.GetValue($nameProp))"
    if ($an -and $an -eq $pair.T.Text) { Pass "a pill announces exactly what it shows: '$an'" }
    else { Fail "a pill announces '$an' but shows '$($pair.T.Text)'" }
}

# --- 12b. the pill agrees with the rows underneath it -----------------------
# "12 live now" over a list holding 14 live conversations is not a rounding
# difference, it is two definitions of "live" on one screen -- and it reads as
# the tool failing to recognise sessions, which is how it was reported.
$bandLive = @($script:inboxRows.ToArray() | Where-Object {
    $_.Kind -eq 'session' -and $_.Band -in @('needs','working','idle') }).Count
$pillLive = 0
if ("$($ui.LiveSummary.Text)" -match '^(\d+)') { $pillLive = [int]$Matches[1] }
if ($pillLive -eq $bandLive) { Pass "the 'live now' pill ($pillLive) matches the live bands ($bandLive)" }
else { Fail "the pill says $pillLive live but the bands hold $bandLive" }

# ...and so must the waiting/working pill. Three numbers on one strip, all
# claiming to describe the rows underneath.
function BandCount { param([string]$B)
    return @($script:inboxRows.ToArray() | Where-Object { $_.Kind -eq 'session' -and $_.Band -eq $B }).Count
}
$wt = "$($ui.WaitSummary.Text)"
$pw = 0; $pk = 0
if ($wt -match '^(\d+)\D+(\d+)') { $pw = [int]$Matches[1]; $pk = [int]$Matches[2] }
if ($pw -eq (BandCount 'needs')) { Pass "the 'waiting for you' count ($pw) matches NEEDS YOU" }
else { Fail "the pill says $pw waiting but NEEDS YOU holds $(BandCount 'needs')" }
if ($pk -eq (BandCount 'working')) { Pass "the 'working' count ($pk) matches WORKING" }
else { Fail "the pill says $pk working but WORKING holds $(BandCount 'working')" }

# --- 13. THE FILTERS ACTUALLY FILTER ----------------------------------------
# Every chip carried the right Tag and did nothing at all: the filter sets were
# declared, read, counted, described and cleared -- and never written, because
# no handler was ever attached. Lighting a chip changed the list by zero rows.
Set-ViewMode 'inbox'
$baseline = $script:inboxRows.Count

function ChipSet { param($Chip, [bool]$On)
    $Chip.IsChecked = $On          # raises Checked/Unchecked -> Invoke-ChipToggle
    return $script:inboxRows.Count
}

# A BAND chip must cut the list down to exactly that band.
$n = ChipSet $ui.FbWorking $true
$workRows = @($script:inboxRows.ToArray() | Where-Object { $_.Kind -eq 'session' })
if ($n -eq $baseline) { Fail "ticking 'Working' changed nothing ($n rows before and after)" }
elseif (-not $workRows.Count) { Fail "ticking 'Working' left no conversations at all" }
else {
    $wrong = @($workRows | Where-Object { $_.Band -ne 'working' })
    if ($wrong.Count) { Fail "'Working' let through $($wrong.Count) row(s) in other bands" }
    else { Pass "'Working' filters to $($workRows.Count) working conversation(s) (from $baseline rows)" }
}

# The readout has to agree with what is on screen.
if ((Get-FilterDimensionCount) -eq 1) { Pass 'the readout counts exactly one dimension' }
else { Fail "the readout counts $(Get-FilterDimensionCount) dimensions, expected 1" }

# OR within a dimension: adding 'Idle' must widen, not narrow.
$n2 = ChipSet $ui.FbIdle $true
if ($n2 -gt $n) { Pass "adding 'Idle' widens the list ($n -> $n2), so a dimension ORs" }
else { Fail "adding 'Idle' did not widen the list ($n -> $n2)" }

# Unticking must put it back.
$null = ChipSet $ui.FbIdle $false
$n3 = ChipSet $ui.FbWorking $false
if ($n3 -eq $baseline) { Pass "unticking restores the full list ($n3 rows)" }
else { Fail "unticking left $n3 rows, expected the original $baseline" }

# THE POINT OF THE WHOLE CHANGE. A chip's printed count and the band heading's
# count are the same number, because they are now the same call. The old DOING
# chips said "waiting" over 110 conversations while the band called NEEDS YOU
# held 6, and nothing in the suite could tell.
$labels = @{ FbNeeds = 'needs'; FbWorking = 'working'; FbIdle = 'idle'; FbQuiet = 'quiet' }
$drift = @()
foreach ($cn in @($labels.Keys)) {
    $chip = $ui.$cn
    if (-not $chip) { Fail "chip $cn is not in the markup"; continue }
    # What the chip PRINTS, parsed back off its own face rather than read from
    # the variable that drew it -- otherwise this only proves a hashtable agrees
    # with itself.
    $printed = 0
    if ("$($chip.Content)" -match '(\d+)\s*$') { $printed = [int]$Matches[1] }
    # What the chip SELECTS.
    $got = ChipSet $chip $true
    $sel = @($script:inboxRows.ToArray() | Where-Object { $_.Kind -eq 'session' }).Count
    $null = ChipSet $chip $false
    if ($printed -ne $sel) { $drift += "$cn prints $printed but selects $sel" }
}
if ($drift.Count) { Fail ("a band chip's count disagrees with what it selects: " + ($drift -join '; ')) }
else { Pass 'every band chip selects exactly as many conversations as it prints' }

# A LIT CHIP HAS TO BE READABLE WITHOUT AN ANIMATION HAVING RUN.
#
# The checked state flips Foreground to Ink (#0C0C0C) with a Setter, but the
# pale fill behind it was left to a Storyboard alone -- so with no animation
# clock the label was near-black on a near-black panel and the chip was blank.
# It cost nothing on a real desktop and everything anywhere the clock does not
# tick, which includes every screenshot this suite renders.
#
# Read off the TEMPLATE rather than the style: what matters is the value that is
# actually in effect on the element being drawn.
function FillOpacity { param($Chip)
    # An unshown window has never been through a layout pass, so its controls
    # have no template instance yet and FindName has nothing to find. Ask for
    # one explicitly rather than reading -1 and calling it a failure.
    $null = $Chip.ApplyTemplate()
    $tpl = $Chip.Template
    if (-not $tpl) { return -1 }
    $f = $tpl.FindName('fill', $Chip)
    if (-not $f) { return -1 }
    return $f.Opacity
}
$ui.FbNeeds.IsChecked = $false
$offOp = FillOpacity $ui.FbNeeds
$ui.FbNeeds.IsChecked = $true
$onOp = FillOpacity $ui.FbNeeds
$fg = "$($ui.FbNeeds.Foreground)"
$ui.FbNeeds.IsChecked = $false
if ($onOp -lt 0) { Fail 'the chip template has no fill to check' }
elseif ($onOp -ne 1) { Fail "a lit chip's fill rests at opacity $onOp, so its dark text ($fg) has nothing pale behind it" }
elseif ($offOp -ne 0) { Fail "an unlit chip's fill rests at opacity $offOp, so every chip looks lit" }
else { Pass "a lit chip is opaque ($offOp -> $onOp) without waiting for an animation" }

# A token appears for whatever is filtering, and taking it off undoes it. This
# is the only readout for the text box and the two dropdowns, which filter
# without any chip lighting up.
$null = ChipSet $ui.FbWorking $true
$tokens = @($ui.ActiveTokens.Children)
if ($tokens.Count -eq 1) { Pass 'one active filter shows one token' }
else { Fail "one active filter produced $($tokens.Count) token(s)" }
Remove-Filter 'band:working'
if ($script:inboxRows.Count -eq $baseline -and (Get-FilterDimensionCount) -eq 0) {
    Pass 'dropping the token clears the filter and restores the list'
} else {
    Fail "after dropping the token: $($script:inboxRows.Count) rows (expected $baseline), $(Get-FilterDimensionCount) dimension(s) on"
}
if ($ui.FbWorking.IsChecked) { Fail 'the token was dropped but its chip is still lit' }
else { Pass 'dropping a token unlights the chip that set it' }

# A filter hidden inside the More fold must OPEN the fold. Filtering with no
# visible cause is the failure this prevents.
$ui.MoreFilters.IsChecked = $false
$ui.FilterMore.Visibility = $V_Hide
$null = ChipSet $ui.FaStale $true
if ($ui.FilterMore.Visibility -eq $V_Show) { Pass 'a filter inside More opens the fold that holds it' }
else { Fail 'More stayed folded away while one of its own filters was on' }
$null = ChipSet $ui.FaStale $false

# The pin dimension had one chip in a two-value world: 128 of 143 are pinned, so
# lighting it barely narrowed anything and the useful half was unreachable.
$np = ChipSet $ui.FpPin $true
$nf = ChipSet $ui.FpFree $true
$null = ChipSet $ui.FpPin $false
$only = @($script:inboxRows.ToArray() | Where-Object { $_.Kind -eq 'session' })
$wrongPin = @($only | Where-Object { $_.Session -and $_.Session.pinned })
if ($wrongPin.Count) { Fail "'not pinned' let through $($wrongPin.Count) pinned conversation(s)" }
else { Pass "'not pinned' selects the half that used to be unreachable" }
$null = ChipSet $ui.FpFree $false

# A chip whose rows the inbox normally hides must still work. This is the case
# that would look most broken: 'stale' conversations are excluded from the inbox
# before any filter runs, so without widening, ticking it shows nothing.
$n4 = ChipSet $ui.FaStale $true
$staleRows = @($script:inboxRows.ToArray() | Where-Object { $_.Kind -eq 'session' })
if ($staleRows.Count -ge 1) { Pass "'stale' widens the inbox to $($staleRows.Count) conversation(s) it normally hides" }
else { Fail "'stale' matched nothing - the inbox is filtering rows out before the filter sees them" }
$null = ChipSet $ui.FaStale $false

# Clear-AllFilters was never wired either.
$null = ChipSet $ui.FbWorking $true
Clear-AllFilters
if ($script:inboxRows.Count -eq $baseline -and (Get-FilterDimensionCount) -eq 0) {
    Pass 'Clear all filters empties every dimension and restores the list'
} else {
    Fail "after clearing: $($script:inboxRows.Count) rows (expected $baseline), $(Get-FilterDimensionCount) dimension(s) still on"
}

# --- the picture, with no window on anyone's screen -------------------------
# RenderTargetBitmap draws the visual tree straight to a bitmap. Measure and
# Arrange by hand, because an unshown window has never been through a layout
# pass and would otherwise render at zero size.
if ($env:SR_TEST_SHOT) {
    try {
        Set-ViewMode 'inbox'
        $w = 1480.0; $h = 980.0
        $root = $window.Content

        # PAINT THE BACKGROUND ONTO THE ROOT FIRST.
        #
        # RenderTargetBitmap draws the visual handed to it, and the dark ground
        # belongs to the WINDOW, not to its content. Rendering $window.Content
        # alone gives a transparent bitmap -- which every viewer shows as WHITE,
        # so #F6F6F6 text lands on near-white and the screenshot reads as a
        # broken, washed-out window that looks nothing like the real one.
        $hadBg = $root.Background
        if (-not $hadBg -or $hadBg -eq [System.Windows.Media.Brushes]::Transparent) {
            $root.Background = $(if ($window.Background) { $window.Background } else { $Pal.Ink })
        }
        $root.Measure((New-Object System.Windows.Size $w, $h))
        $root.Arrange((New-Object System.Windows.Rect 0, 0, $w, $h))
        $root.UpdateLayout()
        # A second pass: the ListBox realises its items during the first one, and
        # what it realised has not been arranged yet.
        $root.Measure((New-Object System.Windows.Size $w, $h))
        $root.Arrange((New-Object System.Windows.Rect 0, 0, $w, $h))
        $root.UpdateLayout()

        $rtb = New-Object System.Windows.Media.Imaging.RenderTargetBitmap(
            [int]$w, [int]$h, 96, 96, [System.Windows.Media.PixelFormats]::Pbgra32)
        $rtb.Render($root)
        $enc = New-Object System.Windows.Media.Imaging.PngBitmapEncoder
        $enc.Frames.Add([System.Windows.Media.Imaging.BitmapFrame]::Create($rtb))
        $fs = [System.IO.File]::Create($env:SR_TEST_SHOT)
        try { $enc.Save($fs) } finally { $fs.Dispose() }
        $root.Background = $hadBg
        $len = (Get-Item -LiteralPath $env:SR_TEST_SHOT).Length
        if ($len -gt 5000) { Pass "rendered $([int]$w)x$([int]$h) off-screen to $($env:SR_TEST_SHOT) ($([int]($len/1024)) KB)" }
        else { Fail "the render produced only $len bytes - probably a blank bitmap" }
    } catch {
        Fail "off-screen render failed: $($_.Exception.Message)"
    }
}

Write-Host ''
if ($fails) { Write-Host "$fails FAILURE(S)" -ForegroundColor Red; exit 1 }
Write-Host 'the headless suite holds' -ForegroundColor Green
exit 0
