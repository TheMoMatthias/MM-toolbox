
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

# STOP THE CLOCKS BEFORE STAGING ANYTHING.
#
# The prefix starts a 60-second liveTimer and a poll timer. The comment at the
# top of this file says the state is exactly what this driver puts there - and
# that was true only while the suite ran in under a minute. It grew past that,
# a real probe fired mid-run, Set-ProbeResult replaced $script:agents,
# $script:live and $script:running wholesale, and the staged NOT RUNNING
# conversation vanished from the inbox: 10 rows became 8, silently, with every
# assertion still green because each one re-measured the moved baseline.
#
# A fixture that decays on a wall clock is worse than no fixture: it fails
# differently on a slow machine.
foreach ($t in @($script:liveTimer, $script:pollTimer, $script:searchTimer, $script:readTimer)) {
    if ($t) { $t.Stop() }
}

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

# NAMED, NOT LETTERED. These were $A, $C2 and $S. PowerShell variable names are
# case-insensitive and its scoping walks the CALL STACK, so a "$a" in any loop
# anywhere below is the same variable as $A - and one in a sort assertion
# replaced the whole staged agent table with a row object, 400 lines away, with
# an error that named neither. The same collision class as the $c/$C one that
# emptied the palette; killing it by naming rather than by care.
$StagedAgents = @{}; $StagedConv = @{}; $StagedSaid = @{}
# 0: waiting on a permission dialog. Wants a click, not a sentence.
$StagedAgents[$ids[0].ToLower()] = New-Agent -Status 'waiting' -WaitingFor 'dialog open' -Name 'STAGE-DIALOG'
$StagedConv[$ids[0].ToLower()] = New-Conv -State 'waiting' -Detail 'a dialog is open, it wants an answer' -AgeMin 2
$StagedSaid[$ids[0].ToLower()] = [PSCustomObject]@{ Said = 'I need to run one command'; Pending = 'Bash(rm -rf /tmp/x)'; PendingTool = 'Bash'; At = (Get-Date).AddMinutes(-2) }

# 1: a BLOCKED BACKGROUND AGENT. No pid, no terminal, cannot be typed into.
$StagedAgents[$ids[1].ToLower()] = New-Agent -Status 'blocked' -ProcId 0 -Kind 'background' -Name 'STAGE-AGENT'
$StagedConv[$ids[1].ToLower()] = New-Conv -State 'waiting' -Detail 'blocked, needs you' -AgeMin 30
$StagedSaid[$ids[1].ToLower()] = [PSCustomObject]@{ Said = ''; Pending = ''; PendingTool = ''; At = $null }

# 2: busy.
$StagedAgents[$ids[2].ToLower()] = New-Agent -Status 'busy' -Name 'STAGE-BUSY'
$StagedConv[$ids[2].ToLower()] = New-Conv -State 'working' -Detail 'running' -AgeMin 1
$StagedSaid[$ids[2].ToLower()] = [PSCustomObject]@{ Said = 'Running the suite now'; Pending = 'Bash(pytest)'; PendingTool = 'Bash'; At = (Get-Date).AddMinutes(-1) }

# 3: idle, and it HAS said something. This is the case a mtime-only gate lost:
# held by a process, silent at its prompt, therefore "stale".
$StagedAgents[$ids[3].ToLower()] = New-Agent -Status 'idle' -Name 'STAGE-IDLE'
$StagedConv[$ids[3].ToLower()] = New-Conv -State 'idle' -Detail 'at its prompt, nothing pending' -Stale $true -AgeMin 20
$StagedSaid[$ids[3].ToLower()] = [PSCustomObject]@{ Said = 'Done and pushed.'; Pending = ''; PendingTool = ''; At = (Get-Date).AddMinutes(-20) }

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
$StagedConv[$ids[4].ToLower()] = New-Conv -State 'idle' -Detail 'was at its prompt' -Stale $true -AgeMin 5

# 5: waiting for input, and NEWER than 0, so ordering inside the band is provable.
$StagedAgents[$ids[5].ToLower()] = New-Agent -Status 'waiting' -WaitingFor 'input needed' -Name 'STAGE-WAITING'
$StagedConv[$ids[5].ToLower()] = New-Conv -State 'waiting' -Detail 'input needed' -AgeMin 1
$StagedSaid[$ids[5].ToLower()] = [PSCustomObject]@{ Said = 'Which schema should I use?'; Pending = ''; PendingTool = ''; At = (Get-Date).AddMinutes(-1) }

$script:agents = $StagedAgents
$script:conv   = $StagedConv
$script:said   = $StagedSaid
$script:running = @{}
foreach ($k in @($StagedAgents.Keys)) { if ($StagedAgents[$k].Pid) { $script:running[$k] = $true } }
# Transcript-moved-recently, which is inferred liveness and separate from a
# process actually holding the id. Session 4 has this and nothing else.
$script:live = @{ $ids[4].ToLower() = $true }

# lastActive drives the sort inside a band, so stage it to match the states.
$stagedById = @{}
foreach ($d in $script:dirs) { foreach ($s in @($d.sessions)) { if ($s.sessionId) { $stagedById["$($s.sessionId)".ToLower()] = $s } }}
$stagedById[$ids[0].ToLower()].lastActive = (Get-Date).AddMinutes(-2).ToString('o')
$stagedById[$ids[5].ToLower()].lastActive = (Get-Date).AddMinutes(-1).ToString('o')

# --- build it ---------------------------------------------------------------
try { Update-List -ToTop } catch { Fail "Update-List threw: $($_.Exception.Message)" }

# .ToArray(), not @(...). On PowerShell 5.1.26100.9168 the array subexpression
# @() throws "Argument types do not match" against a List[object] -- which is
# exactly what Build-InboxRows returns. Piping and .ToArray() both work.
$builtRows = $script:inboxRows.ToArray()
if (-not $builtRows.Count) { Fail 'the inbox built no rows at all'; }
else { Pass "the inbox built $($builtRows.Count) row(s)" }

function RowFor { param([string]$Id)
    foreach ($r in $builtRows) { if ($r.Kind -eq 'session' -and "$($r.Session.sessionId)" -ieq $Id) { return $r } }
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
foreach ($r in $builtRows) {
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
foreach ($r in $builtRows) {
    if ($r.Said -and $null -eq $r.SaidBrush) { $nullBrush++ }
    if ($r.Name -and $null -eq $r.NameBrush) { $nullBrush++ }
}
if ($nullBrush -eq 0) { Pass 'every row with text has a brush to draw it with' }
else { Fail "$nullBrush row(s) carry text with no brush - they would render blank" }

# --- 3. the band headings ---------------------------------------------------
$heads = @($builtRows | Where-Object { $_.Kind -eq 'band' })
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
$needsRows = @($builtRows | Where-Object { $_.Kind -eq 'session' -and $_.Band -eq 'needs' })
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
$badLabel = @($builtRows | Where-Object { $_.Kind -eq 'session' -and ("$($_.Project)" -split '\s+').Count -gt 4 })
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
# 🔴 THIS ASSERTION USED TO SAY THE OPPOSITE, and the reversal was deliberate.
# The tree was retired because 143 conversations became 195 rows with eleven of
# fifteen projects carrying a lane row called "main" that said nothing. The
# operator asked for the grouping back once the registry reached 173
# conversations across 21 projects -- but the ORIGINAL complaint still has to
# hold, so a lane row is emitted ONLY where a project really has more than one.
$projRows = @($allRows | Where-Object { $_.Kind -eq 'project' })
$laneRows = @($allRows | Where-Object { $_.Kind -eq 'lane' })
if (-not $projRows.Count) { Fail 'the roster builds no project rows - it is not grouping' }
else { Pass "the roster groups into $($projRows.Count) project row(s)" }

# The trap the tree died of: a lane row under a project that has exactly one.
$soloLane = 0
foreach ($pr in $projRows) {
    $mine = @($laneRows | Where-Object { $_.Dir -eq $pr.Dir })
    if ($mine.Count -eq 1) { $soloLane++ }
}
if ($soloLane) { Fail "$soloLane project(s) carry a single lane row - a row that says nothing under a row that says the same thing" }
else { Pass 'no project carries a lone lane row' }

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

# --- 10b. THE SORT KEY STACK ------------------------------------------------
# A tree could only ever sort within a lane, so "the youngest across every
# project" was not expressible at all. These check the ORDER OF THE ROWS, not
# the state of the sort variables: a stack that is set correctly and never
# applied looks identical from the variables.
Set-ViewMode 'all'
function AllSessions { $o = @(); foreach ($r in $script:rows) { if ($r.Kind -eq 'session') { $o += $r } }; return $o }

# The default has to be what the tree showed, or the flattening moved the list
# under the operator for no reason.
Set-SortKeys 'all' @($script:SortDefault['all'] | ForEach-Object { @{ Key = $_.Key; Desc = $_.Desc } })
Update-List -ToTop
$def = AllSessions
# Grouped by the STRING THE COLUMN SHOWS, which is what a heading called
# "PROJECT / LANE" has to sort by, and newest-first inside each group.
$outOfOrder = 0; $notGrouped = 0
$seen = @{}
$prev = $null
for ($i = 0; $i -lt $def.Count; $i++) {
    # 🪤 KEYED ON THE PROJECT ITSELF, not on the label. Eight projects are called
    # "repo" (Millwright-experiments uns\R* epo); grouping by the displayed
    # string would call two different repositories one group and pass while the
    # screen showed nonsense.
    $lbl = "$($def[$i].Dir.path)|$(if ($def[$i].Lane) { $def[$i].Lane.Name } else { '' })"
    if ($lbl -ne $prev) {
        # A label coming back after another one appeared in between means the
        # grouping broke, which no amount of within-group order would show.
        if ($seen.ContainsKey($lbl)) { $notGrouped++ }
        $seen[$lbl] = $true
        $prev = $lbl
    } elseif ([datetime]$def[$i - 1].Session.lastActive -lt [datetime]$def[$i].Session.lastActive) {
        $outOfOrder++
    }
}
if ($notGrouped) { Fail "$notGrouped group(s) appear in more than one run - the rows are not grouped" }
elseif ($outOfOrder) { Fail "$outOfOrder row(s) are older than the row above them inside one project" }
else { Pass "the default order is project A-Z then newest first ($($seen.Count) groups)" }

# ONE KEY: newest across EVERYTHING, which is the thing a tree could not do.
Invoke-SortHead -Key 'when' -Add $false
$byWhen = AllSessions
# 🔴 WITHIN A GROUP, NOT ACROSS EVERYTHING. Sorting newest-first across every
# project was a real capability of the flat list and the grouping costs it --
# the operator was offered "grouped by default, flat when you sort" and chose
# "grouping replaces it" anyway. So the contract is that a sort orders the rows
# INSIDE each group, and this asserts that rather than pretending otherwise.
$bad = 0
for ($i = 1; $i -lt $byWhen.Count; $i++) {
    $sameGroup = ($byWhen[$i - 1].Dir -eq $byWhen[$i].Dir -and "$($byWhen[$i - 1].Lane.Name)" -eq "$($byWhen[$i].Lane.Name)")
    if (-not $sameGroup) { continue }
    if ([datetime]$byWhen[$i - 1].Session.lastActive -lt [datetime]$byWhen[$i].Session.lastActive) { $bad++ }
}
if ($bad) { Fail "sorting by WHEN left $bad row(s) out of order inside their group" }
elseif ($byWhen.Count -lt 2) { Fail 'not enough rows to prove an order' }
else { Pass "WHEN sorts $($byWhen.Count) conversations newest-first inside each group" }

# Clicking the same heading again reverses it.
Invoke-SortHead -Key 'when' -Add $false
$rev = AllSessions
$bad = 0
for ($i = 1; $i -lt $rev.Count; $i++) {
    $sameGroup = ($rev[$i - 1].Dir -eq $rev[$i].Dir -and "$($rev[$i - 1].Lane.Name)" -eq "$($rev[$i].Lane.Name)")
    if (-not $sameGroup) { continue }
    if ([datetime]$rev[$i - 1].Session.lastActive -gt [datetime]$rev[$i].Session.lastActive) { $bad++ }
}
if ($bad) { Fail "clicking WHEN twice left $bad row(s) out of order the other way" }
else { Pass 'clicking the same heading again reverses it' }

# TWO KEYS: shift-click stacks rather than replaces. "By what it needs, then
# newest" is the case the whole mechanic exists for.
Invoke-SortHead -Key 'state' -Add $false
Invoke-SortHead -Key 'when'  -Add $true
if (@(Get-SortKeys 'all').Count -ne 2) { Fail "shift-click produced $(@(Get-SortKeys 'all').Count) key(s), expected 2" }
else {
    $two = AllSessions
    $bad = 0
    for ($i = 1; $i -lt $two.Count; $i++) {
        $sameGroup = ($two[$i - 1].Dir -eq $two[$i].Dir -and "$($two[$i - 1].Lane.Name)" -eq "$($two[$i].Lane.Name)")
        if (-not $sameGroup) { continue }
        $ra = [int]$script:BandOrder[(Get-InboxBand $two[$i - 1].Session)]
        $rb = [int]$script:BandOrder[(Get-InboxBand $two[$i].Session)]
        if ($ra -gt $rb) { $bad++; continue }
        if ($ra -eq $rb -and [datetime]$two[$i - 1].Session.lastActive -lt [datetime]$two[$i].Session.lastActive) { $bad++ }
    }
    if ($bad) { Fail "state-then-newest left $bad row(s) out of order" }
    else { Pass 'shift-click stacks: state first, newest within each' }
}

# The headings ARE the readout. A stack nobody can see is a stack nobody trusts.
$heads = @(Get-SortHeadControls)
if (-not $heads.Count) { Fail 'no sortable column headings were found at all' }
else {
    $marked = @($heads | Where-Object { "$($_.Content)" -match [regex]::Escape($script:SortUp) -or "$($_.Content)" -match [regex]::Escape($script:SortDown) })
    # Two keys, and each heading exists in BOTH bars, so 'when' is marked twice.
    $keysMarked = @($marked | ForEach-Object { "$($_.Tag)" } | Sort-Object -Unique)
    if ($keysMarked.Count -ne 2) { Fail "the headings mark $($keysMarked.Count) sorted column(s), expected 2: $($keysMarked -join ', ')" }
    elseif (-not (@($marked | Where-Object { "$($_.Content)" -match '2$' }).Count)) { Fail 'nothing on the headings says which key is second' }
    else { Pass "the headings show the stack: $(($marked | ForEach-Object { $_.Content }) -join '  ')" }
}

# An UNSORTED column must carry no arrow, or the arrow means nothing.
$plain = @($heads | Where-Object { "$($_.Tag)" -eq 'name' })
if ($plain.Count -and ("$($plain[0].Content)" -match [regex]::Escape($script:SortUp) -or "$($plain[0].Content)" -match [regex]::Escape($script:SortDown))) {
    Fail "an unsorted heading carries an arrow: '$($plain[0].Content)'"
} else { Pass 'an unsorted heading carries no arrow' }

# THE TWO LISTS DO NOT SHARE A SORT. All was sorted by STATE then WHEN above;
# the inbox has no STATE heading, so a shared stack put "WHEN v2" on its bar
# with no "^1" anywhere - a rank digit pointing at a key the operator can
# neither see nor unset.
Set-ViewMode 'inbox'
$inboxKeys = @(Get-SortKeys 'inbox')
$allKeys   = @(Get-SortKeys 'all')
if ($allKeys.Count -ne 2) { Fail "the All view lost its sort when the view changed ($($allKeys.Count) key(s))" }
elseif ($inboxKeys.Count -ne 1) { Fail "the inbox inherited the All view's stack ($($inboxKeys.Count) key(s))" }
else { Pass 'each list keeps its own sort across a view switch' }

# And no heading anywhere may claim a rank its own bar cannot account for.
$orphan = @()
foreach ($btn in @(Get-SortHeadControls)) {
    $c = "$($btn.Content)"
    if ($c -notmatch '(\d)$') { continue }
    $rank = [int]$Matches[1]
    $inInbox = ($ui.InboxHead -and $btn.Parent -eq $ui.InboxHead.Child)
    $bar = @(Get-SortHeadControls | Where-Object { ($ui.InboxHead -and $_.Parent -eq $ui.InboxHead.Child) -eq $inInbox })
    $marked = @($bar | Where-Object { "$($_.Content)" -match '\d$' }).Count
    if ($rank -gt $marked) { $orphan += "$c (rank $rank of $marked shown in its own bar)" }
}
if ($orphan.Count) { Fail ("a heading claims a rank nothing beside it accounts for: " + ($orphan -join '; ')) }
else { Pass 'no heading shows a rank digit its own bar cannot account for' }

# THE BANDS ARE NOT SORTABLE AWAY. They are what the inbox is; a sort orders
# rows WITHIN one. If WHEN could dissolve them, NEEDS YOU would stop being first
# and the inbox would silently become a list.
Set-ViewMode 'inbox'
Invoke-SortHead -Key 'when' -Add $false
$ib = @(); foreach ($r in $script:inboxRows) { $ib += $r }
$headsSeen = @($ib | Where-Object { $_.Kind -eq 'band' })
if ($headsSeen.Count -lt 2) { Fail "sorting the inbox by WHEN left $($headsSeen.Count) band heading(s)" }
elseif ("$($headsSeen[0].Name)" -ne 'NEEDS YOU') { Fail "after sorting, the first band is '$($headsSeen[0].Name)'" }
else { Pass 'sorting the inbox reorders within the bands and NEEDS YOU stays first' }

# Put it back so nothing downstream inherits a sort.
Set-SortKeys 'all' @($script:SortDefault['all'] | ForEach-Object { @{ Key = $_.Key; Desc = $_.Desc } })
Update-List -ToTop

# --- 10c. THE READING PANE IS A SPLIT, NOT A REPLACEMENT --------------------
# It used to live in the SAME grid row as the list and hide it, so opening a
# conversation cost you your place in the list you opened it from. These check
# the LIST IS STILL UP, which is the whole point, rather than merely that the
# pane appeared.
Set-ViewMode 'inbox'
$readable = @($script:inboxRows.ToArray() | Where-Object { $_.Kind -eq 'session' })[0]
if (-not $readable) { Fail 'no conversation to read' }
else {
    $listWas = $ui.InboxList.Visibility
    Show-ReadPane $readable
    if ($ui.ReadPane.Visibility -ne $V_Show) { Fail 'the reading pane did not open' }
    elseif ($ui.InboxList.Visibility -ne $listWas) { Fail 'opening the pane took the list off screen' }
    elseif ($ui.ReadRow.Height.Value -le 0) { Fail 'the pane opened into a row with no height' }
    elseif ($ui.ReadSplit.Visibility -ne $V_Show) { Fail 'the pane is open with no splitter to resize it' }
    else { Pass "the pane opens BESIDE the list, $([int]$ui.ReadRow.Height.Value)px tall, list still up" }

    # A dragged split is remembered. Snapping back to the default on every open
    # is the thing that makes a resizable pane not worth resizing.
    $ui.ReadRow.Height = New-Object System.Windows.GridLength 260
    Hide-ReadPane
    if ($ui.ReadRow.Height.Value -ne 0) { Fail 'closing the pane left the row taking up space' }
    elseif ($ui.ReadSplit.Visibility -ne $V_Hide) { Fail 'the splitter is still there with nothing to split' }
    else { Pass 'closing gives the room back to the list' }
    Show-ReadPane $readable
    if ([int]$ui.ReadRow.Height.Value -eq 260) { Pass 'it reopens at the size you dragged it to' }
    else { Fail "it reopened at $([int]$ui.ReadRow.Height.Value)px, not the 260 it was left at" }

    # Hide-ReadPane used to force RowList visible on the way out. In the inbox
    # that leaves the All view's list realised underneath the inbox's own - two
    # lists in one grid row, one of them invisible only because of z-order.
    Hide-ReadPane
    if ($ui.RowList.Visibility -eq $V_Show) { Fail 'closing the pane from the inbox turned the All list back on' }
    else { Pass 'closing the pane leaves the view switch in charge of which list is up' }
}

# --- 10d. THE SEEN GATE -----------------------------------------------------
# A tool that can type into thirteen consoles must not make it easy to reply to
# something the session has already moved past. The composer is DEAD until what
# is on screen is what that conversation last said - a warning would not do,
# because a stale document renders identically to a current one.
Set-ViewMode 'inbox'
$liveRow = @($script:inboxRows.ToArray() | Where-Object {
    $_.Kind -eq 'session' -and $script:agents["$($_.Session.sessionId)".ToLower()] -and
    $script:agents["$($_.Session.sessionId)".ToLower()].Pid -and
    $script:agents["$($_.Session.sessionId)".ToLower()].Kind -eq 'interactive'
})[0]
if (-not $liveRow) { Fail 'no running interactive conversation staged to test the composer' }
else {
    $script:readSession = $liveRow.Session
    $script:readDir     = $liveRow.Dir
    # Nothing read yet.
    $script:readShownFor = $null
    $script:readShownAt  = $null
    Update-SendState
    if ($ui.SendBox.IsEnabled) { Fail 'the composer is live before the conversation has been read' }
    else { Pass "the composer is closed until it has been read: '$($ui.SendNote.Text)'" }

    # READ IT THE WAY THE TOOL DOES. Setting the stamp by hand proved the gate's
    # arithmetic and nothing about the path the operator actually takes - and
    # the real path was broken: Show-ReadPane judged the gate BEFORE the read
    # that stamps it, so the composer opened for nobody, ever, and this
    # assertion was green throughout.
    Show-ReadPane $liveRow
    if (-not $ui.SendBox.IsEnabled) { Fail "opening a conversation left the composer shut: '$($ui.SendNote.Text)'" }
    else { Pass 'opening a conversation opens its composer' }

    # And the arithmetic, separately.
    $script:readShownFor = "$($liveRow.Session.sessionId)"
    $script:readShownAt  = (Get-Date).AddSeconds(5)   # newer than the file
    Update-SendState
    if (-not $ui.SendBox.IsEnabled) { Fail "the composer stayed closed after reading: '$($ui.SendNote.Text)'" }
    else { Pass 'the composer opens once what is on screen is what it last said' }

    # Now the transcript moves under it.
    $script:readShownAt = (Get-Date).AddDays(-30)
    Update-SendState
    if ($ui.SendBox.IsEnabled) { Fail 'the composer stayed open after the conversation moved on' }
    elseif ("$($ui.SendNote.Text)" -notmatch 'said something') { Fail "it closed but did not say why: '$($ui.SendNote.Text)'" }
    else { Pass 'it closes again the moment the conversation says something new' }

    # A conversation with no console cannot be typed into at all, gate or no gate.
    $dead = @($script:inboxRows.ToArray() | Where-Object {
        $_.Kind -eq 'session' -and -not $script:agents["$($_.Session.sessionId)".ToLower()]
    })[0]
    if ($dead) {
        $script:readSession = $dead.Session; $script:readDir = $dead.Dir
        $script:readShownFor = "$($dead.Session.sessionId)"; $script:readShownAt = (Get-Date).AddSeconds(5)
        Update-SendState
        if ($ui.SendBox.IsEnabled) { Fail 'the composer is live for a conversation with no console' }
        else { Pass 'no console, no composer' }
    }
    $script:readSession = $null
}

# --- 10e. BROADCAST ---------------------------------------------------------
# Recipients are chosen in the overlay, never taken from the logon ticks: the
# tick means "reopen at logon", most ticked conversations are not running, and a
# set whose name describes a different set is how a message reaches the wrong
# console.
$cands = @(Get-CastCandidates)
$unreachable = @($cands | Where-Object {
    $a = $script:agents["$($_.Session.sessionId)".ToLower()]
    -not $a -or -not $a.Pid -or $a.Kind -ne 'interactive'
})
if ($unreachable.Count) { Fail "$($unreachable.Count) candidate(s) cannot actually be typed into" }
elseif (-not $cands.Count) { Fail 'no broadcast candidates at all' }
else { Pass "broadcast offers only the $($cands.Count) session(s) that can receive input" }

# The blocked BACKGROUND agent has no console and must not be offered, however
# much it looks like a live session in the list.
$bg = @($cands | Where-Object { $_.Name -eq 'STAGE-AGENT' })
if ($bg.Count) { Fail 'the background agent is offered as a broadcast recipient' }
else { Pass 'a background agent is not offered - there is nothing to type into' }

Show-Cast
$boxes = @($ui.CastList.Children)
if ($boxes.Count -ne $cands.Count) { Fail "the overlay lists $($boxes.Count) recipient(s) for $($cands.Count) candidate(s)" }
elseif (@($boxes | Where-Object { $_.IsChecked }).Count) { Fail 'a recipient is ticked before anyone chose it' }
else { Pass "the overlay opens with $($boxes.Count) recipients and NONE of them ticked" }

if ($ui.CastSend.IsEnabled) { Fail 'Send is live with no recipients and no message' }
else { Pass 'Send is dead until there is both a message and a recipient' }

# Message but no recipient: still dead.
$ui.CastBox.Text = 'status?'
Update-CastState
if ($ui.CastSend.IsEnabled) { Fail 'Send is live with a message but no recipients' }
else { Pass 'a message with nobody to send it to does not arm Send' }

# Two recipients: armed, and NAMED. A count is not a confirmation.
$boxes[0].IsChecked = $true
$boxes[1].IsChecked = $true
Update-CastState
$want = @($boxes[0].Tag.Name, $boxes[1].Tag.Name)
$missing = @($want | Where-Object { "$($ui.CastWho.Text)" -notmatch [regex]::Escape($_) })
if (-not $ui.CastSend.IsEnabled) { Fail 'Send stayed dead with two recipients and a message' }
elseif ($missing.Count) { Fail "the confirmation does not name: $($missing -join ', ')" }
elseif ("$($ui.CastSend.Content)" -notmatch '2') { Fail "the button says '$($ui.CastSend.Content)' for two recipients" }
else { Pass "every recipient is named before anything is sent: '$($ui.CastWho.Text)'" }

# A session sitting on a permission dialog is offered but starts UNTICKED and
# says what typing there would do, because prose at a dialog ANSWERS the dialog.
$dlg = @($boxes | Where-Object { $_.Tag.Dialog })
if (-not $dlg.Count) { Fail 'no dialog-blocked session staged among the candidates' }
else {
    $saidText = ''
    foreach ($t in $dlg[0].Content.Children) { $saidText += "$($t.Text) " }
    if ($saidText -notmatch 'ANSWERS') { Fail "the dialog recipient does not say what typing there would do: '$saidText'" }
    else { Pass 'a dialog-blocked recipient says that typing there answers the dialog' }
}
Close-Cast

# --- 10g. SEEN, AND THE NOTE ------------------------------------------------
# "I click through the tabs to see if there has been any progress, and then it
# is hard to remember where we are." Two problems: one the machine can answer
# (has it said anything since I looked) and one only the operator can (what was
# this for). These check both, and RESTORE what they touch - the registry here
# is the operator's real one.
Set-ViewMode 'inbox'
$victim = @($script:inboxRows.ToArray() | Where-Object { $_.Kind -eq 'session' })[0]
if (-not $victim) { Fail 'no conversation to mark seen' }
else {
    $sess = $victim.Session
    $wasSeen = "$($sess.lastSeen)"
    $wasNote = "$($sess.note)"
    try {
        # NEVER LOOKED AT IS NOT MOVED. With no baseline there is no answer to
        # "has this said anything since", and rendering an unknown as a yes put
        # a dot on eleven of eleven rows - a mark that is on for everything.
        Set-SessionField $sess 'lastSeen' ''
        if (Test-Moved $sess) { Fail 'a conversation with no baseline is marked moved, so the mark means nothing' }
        else { Pass 'no baseline, no mark' }

        # Seen, and then nothing has happened.
        Set-SessionField $sess 'lastSeen' ((Get-Date).AddYears(1).ToString('o'))
        if (Test-Moved $sess) { Fail 'a conversation seen after its last activity is still marked moved' }
        else { Pass 'reading it clears the mark' }

        # Seen, and then it spoke again.
        Set-SessionField $sess 'lastSeen' ((Get-Date).AddYears(-1).ToString('o'))
        if (-not (Test-Moved $sess)) { Fail 'a conversation that spoke after you looked is not marked moved' }
        else { Pass 'it comes back the moment the conversation says something new' }

        # The MARK follows the model without a rebuild - a rebuild while the
        # operator is reading would move the list out from under them.
        Update-RowSeenMarks
        $mine = @($script:inboxRows.ToArray() | Where-Object { $_.Kind -eq 'session' -and "$($_.Session.sessionId)" -eq "$($sess.sessionId)" })[0]
        if (-not $mine -or $mine.MovedVisibility -ne $V_Show) { Fail 'the row does not show the moved mark' }
        else { Pass 'the mark is on the row, without rebuilding the list' }

        # THE NOTE OUTRANKS THE LAST-SAID LINE, and the last-said is not lost.
        $before = "$($mine.Said)"
        Set-SessionNote $sess 'waiting on the migration to finish, then re-run G10'
        Update-InboxRow $mine
        if ("$($mine.Said)" -ne 'waiting on the migration to finish, then re-run G10') {
            Fail "the note did not reach the row: '$($mine.Said)'"
        } elseif ($before -and "$($mine.SaidTip)" -notmatch [regex]::Escape($before)) {
            Fail 'the note replaced what it last said and threw it away'
        } else { Pass 'your note outranks the transcript on the row, and the transcript moves into the tooltip' }

        Set-SessionNote $sess ''
        Update-InboxRow $mine
        if ("$($mine.Said)" -ne $before) { Fail "clearing the note did not restore what it last said: '$($mine.Said)'" }
        else { Pass 'clearing the note gives the last-said line back' }
    } finally {
        # THE REGISTRY HERE IS THE OPERATOR'S REAL ONE. A suite that leaves a
        # note behind has changed their data, which is the same class of mistake
        # as the run that left includeWorktrees false in their config.
        Set-SessionField $sess 'lastSeen' $wasSeen
        Set-SessionField $sess 'note' $wasNote
        Update-RowSeenMarks
    }
}

# --- 10h. THE NOTIFIER, AND THE TWO SPEEDS ----------------------------------
# A notifier that repeats is a notifier you turn off, so the only thing worth
# asserting about it is WHEN IT STAYS QUIET. Show-Toast is replaced with a
# recorder rather than mocked at the NotifyIcon: the decision being tested is
# "should anything be announced", which is entirely above the shell.
$script:toastLog = @()
function Show-Toast { param([string]$Title, [string]$Body) $script:toastLog += "$Title|$Body" }

$script:toastPrev = @{}
$script:hidden = $true          # so IsActive does not suppress it
$script:toastLog = @()
Update-Toasts
if ($script:toastLog.Count) {
    Fail "the first pass announced $($script:toastLog.Count) session(s) - everything is 'new' at startup and thirteen toasts is how a notifier gets muted"
} else { Pass 'the first pass announces nothing, however many are already waiting' }

# Nothing has changed since: still quiet.
$script:toastLog = @()
Update-Toasts
if ($script:toastLog.Count) { Fail 'it re-announced conversations that were already waiting' }
else { Pass 'a conversation that was already waiting is not news' }

# One NEW one. This is the only case that should ever reach the shell.
$fresh = $ids[3].ToLower()      # the staged idle session
$StagedAgents[$fresh] = New-Agent -Status 'waiting' -WaitingFor 'input needed' -Name 'STAGE-NEWWAIT'
$StagedConv[$fresh]   = New-Conv -State 'waiting' -Detail 'input needed' -AgeMin 1
$script:agents = $StagedAgents
$script:conv   = $StagedConv
$script:toastLog = @()
Update-Toasts
# NAMED THE WAY THE ROW NAMES IT. The agent's own name ('STAGE-NEWWAIT') is an
# internal label; a toast that used it would name something the operator cannot
# find in the list. Get-WaitingNow uses the conversation title, and so must this.
$freshTitle = "$(Get-SessionTitle $stagedById[$fresh] $script:dirOf[$fresh])"
if ($script:toastLog.Count -ne 1) { Fail "a session that has just started waiting produced $($script:toastLog.Count) toast(s)" }
elseif ("$($script:toastLog[0])" -notmatch [regex]::Escape($freshTitle)) { Fail "the toast says '$($script:toastLog[0])' but the row is called '$freshTitle'" }
else { Pass "only the one that just started waiting is announced, by the name on its row: '$($script:toastLog[0])'" }

# And not again.
$script:toastLog = @()
Update-Toasts
if ($script:toastLog.Count) { Fail 'the same session was announced twice' }
else { Pass 'it is announced once, not until it is dealt with' }

# Put the fixture back.
$StagedAgents[$fresh] = New-Agent -Status 'idle' -Name 'STAGE-IDLE'
$StagedConv[$fresh]   = New-Conv -State 'idle' -Detail 'at its prompt, nothing pending' -Stale $true -AgeMin 20
$script:agents = $StagedAgents
$script:conv   = $StagedConv
$script:hidden = $false

# THE BADGE COUNTS WHAT IS WAITING, and it counted 1 forever: Get-WaitingNow
# returned ",@(...)", so "@(Get-WaitingNow).Count" was the length of a
# one-element array holding everything. Asserted against the band, which is the
# same set by construction.
$bandWait = @($script:inboxRows.ToArray() | Where-Object { $_.Kind -eq 'session' -and $_.Band -eq 'needs' }).Count
$fnWait = @(Get-WaitingNow).Count
if ($fnWait -ne $bandWait) { Fail "Get-WaitingNow reports $fnWait but NEEDS YOU holds $bandWait" }
else { Pass "the waiting count is a count ($fnWait), not the length of a wrapper" }

# --- the fast pass ----------------------------------------------------------
# Six seconds of file stats against 653 ms of `claude agents --json`: the two
# questions cost three orders of magnitude apart, so they run at two speeds. The
# fast one answers "has anything moved" and MUST NOT answer "what is it doing" -
# a tool that infers state from a file timestamp disagrees with itself between
# its own refresh rates.
$fastVictim = $null
foreach ($k in @($script:running.Keys)) { if ($script:byId[$k]) { $fastVictim = $k; break } }
if (-not $fastVictim) { Fail 'no running conversation indexed for the fast pass' }
else {
    $sessF = $script:byId[$fastVictim]
    $wasActive = "$($sessF.lastActive)"
    $wasState  = "$((Get-Conv $sessF).State)"
    try {
        # First sighting records the mtime and claims nothing: with no previous
        # reading there is no movement to report, only a baseline to take.
        $script:mtimes = @{}
        Invoke-FastPass
        if ("$($sessF.lastActive)" -ne $wasActive) { Fail 'the first fast pass reported movement it had no baseline for' }
        else { Pass 'the first fast pass takes a baseline and reports nothing' }

        # Now pretend the last reading was old. The file is newer, so it moved.
        # FROM A SENTINEL. The registry's lastActive is ALREADY derived from the
        # transcript's mtime, so "did lastActive change" compares a value with
        # itself and passes whether the pass ran or not. The sentinel makes the
        # write unmistakable - the first version of this assertion could not
        # have failed for the right reason.
        $sentinel = (Get-Date).AddYears(-5).ToString('o')
        $sessF.lastActive = $sentinel
        $script:mtimes[$fastVictim] = (Get-Date).AddDays(-30)
        Invoke-FastPass
        if ("$($sessF.lastActive)" -eq $sentinel) { Fail 'the fast pass did not notice a transcript that had moved' }
        else { Pass 'the fast pass notices a transcript that moved, without a probe' }

        # AND IT DID NOT TOUCH WHAT THE SESSION IS DOING.
        if ("$((Get-Conv $sessF).State)" -ne $wasState) {
            Fail "the fast pass changed what the session is doing ($wasState -> $((Get-Conv $sessF).State)) - only the slow probe may do that"
        } else { Pass 'the fast pass never changes what a session is doing' }

        # HIDDEN, IT DOES NOTHING AT ALL. A window nobody is looking at has no
        # business rebuilding 86 rows every six seconds.
        $sessF.lastActive = $sentinel
        $script:mtimes[$fastVictim] = (Get-Date).AddDays(-30)
        $script:hidden = $true
        Invoke-FastPass
        $script:hidden = $false
        if ("$($sessF.lastActive)" -ne $sentinel) { Fail 'the fast pass ran while the window was hidden' }
        else { Pass 'hidden, the fast pass does nothing' }
    } finally {
        $sessF.lastActive = $wasActive
        $script:hidden = $false
    }
}

# --- 10f. THE FIXTURE IS STILL THE FIXTURE ----------------------------------
# Everything above asserts against staged state. If a background probe replaced
# it half way through, those assertions were measuring the machine rather than
# the fixture - and would still pass, because each one re-reads the list it is
# about to check. This is the guard that makes the rest of the file mean what it
# says.
$stagedStill = 0
foreach ($k in @($StagedAgents.Keys)) { if ($script:agents[$k] -and "$($script:agents[$k].Name)" -eq "$($StagedAgents[$k].Name)") { $stagedStill++ } }
if ($stagedStill -ne $StagedAgents.Count) {
    Fail "the staged agents were replaced during the run ($stagedStill of $($StagedAgents.Count) survived) - a background probe fired and every assertion above was measuring the real machine"
} elseif (-not $script:live[$ids[4].ToLower()]) {
    Fail "the staged inferred-live conversation is gone from `$script:live (now holds: $((@($script:live.Keys) -join ', ')))"
} elseif ($script:running.Count -ne 4) {
    Fail "the staged running table changed during the run ($($script:running.Count) entries, expected 4)"
} elseif ($script:conv.Count -ne $StagedConv.Count) {
    Fail "the staged conversation states changed during the run ($($script:conv.Count) entries, expected $($StagedConv.Count))"
} else { Pass "the fixture survived the whole run ($($StagedAgents.Count) agents, $($script:running.Count) running, $($script:live.Count) inferred-live, $($script:conv.Count) states)" }

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
