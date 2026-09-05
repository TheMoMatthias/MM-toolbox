# ===========================================================================
# THE SHIPPED WINDOW (lib\sessions-window.ps1), built and never shown.
#
# 🔴 THIS IS THE ONLY SUITE THAT TESTS WHAT ACTUALLY OPENS. headless, inbox and
# keys drive lib\sessions-gui.ps1, the RETIRED window, and their green says
# nothing about the app. Every assertion here was written against a real defect
# found while building the thing it covers - none of them are decorative.
#
# It runs against the OPERATOR'S OWN REGISTRY rather than a fixture, because the
# defects it caught were all shaped by real data: 218 conversations, 27 projects
# whose leaf names collide, worktrees named after the conversation inside them.
# Anything it changes, it changes back, and it never saves.
#
# 🔴 IT NEVER LAUNCHES, KILLS OR TYPES INTO ANYTHING. Every destructive path is
# checked by asking what it WOULD do. The one place that genuinely starts a
# session is the app suite's own probe, not here.
# ===========================================================================

$fails = 0
function Fail { param($m) Write-Host "  FAIL  $m" -ForegroundColor Red; $script:fails++ }
function Pass { param($m) Write-Host "  ok    $m" -ForegroundColor Green }
function Note { param($m) Write-Host "        $m" -ForegroundColor DarkGray }
function Ms   { param($sb) $sw=[Diagnostics.Stopwatch]::StartNew(); & $sb | Out-Null; $sw.Stop(); $sw.Elapsed.TotalMilliseconds }

Update-Model
Note "$($script:model.Count) conversations across $(@($script:dirs).Count) projects"

# --- LAYOUT: realise the containers so hit-testing is real -----------------
$W = 1480.0; $H = 980.0
$root = $window.Content
$root.Background = $window.Background
function Lay {
    foreach ($p in 1, 2) {
        $root.Measure((New-Object System.Windows.Size $W, $H))
        $root.Arrange((New-Object System.Windows.Rect 0, 0, $W, $H))
        $root.UpdateLayout()
        [System.Windows.Threading.Dispatcher]::CurrentDispatcher.Invoke(
            [System.Windows.Threading.DispatcherPriority]::Loaded, [action]{})
    }
}

# 🔴 THE SUITE OWNS THE LAYOUT IT MEASURES. foldProjects and foldSessions are
# REAL OPERATOR SETTINGS saved in the config, so a run on a machine where the
# columns happen to be pinned collapsed measured a 1,365px pane and a projects
# rail with no realised tiles - and two assertions failed on a build that was
# entirely correct: the text column "did not grow" because it was already at
# its ceiling, and the first tile had "no realised container" because the rail
# was not on screen at all.
#
# 🪤 A test that reads an input it does not own is not testing the code, it is
# testing the machine it runs on. Every block below assumes both columns are
# open; the collapse block sets and restores its own state on top of this.
# [[feedback-test-accidents]]
$script:foldRail = $false
$script:foldList = $false
$script:foldApplied = ''
# 🔴 AND THE RAIL'S AGE BANDS ARE THE SAME KIND OF INPUT. railBandsShut is a
# REAL OPERATOR SETTING too, and it defaults to everything-but-TODAY folded - so
# a suite that did not own it would measure a rail holding whichever projects
# happened to have been touched since midnight, and "12 project tiles" would be
# a different assertion every morning. Every block below assumes all four bands
# are open; the band block sets and restores its own state on top of this.
# [[feedback-test-accidents]]
$script:railBandShut = @{}
Update-Columns
Lay

# THE WINDOW'S OWN SOURCE, and one function's body out of it. Read once, up
# here, because blocks all the way down the driver assert on what a handler
# CALLS - and a function has to exist before the line calling it RUNS, not
# merely before the file ends.
$winSrc = [System.IO.File]::ReadAllText((Join-Path $SR_Root 'lib\sessions-window.ps1'))

# One function's body out of a source file, comments stripped. 🪤 THE COMMENTS
# GO FIRST, and the first version of this failed without it: the extraction
# runs to the next `function`, so it swallows the comment block sitting between
# two of them - and those comments NAME the very calls these checks look for.
# The assertion is about what a handler CALLS, not what its prose mentions.
function Get-SRBodyOf { param([string]$Src, [string]$Marker)
    $a = $Src.IndexOf($Marker)
    if ($a -lt 0) { return '' }
    $b = $Src.IndexOf("`nfunction ", $a + $Marker.Length)
    if ($b -lt 0) { $b = $Src.Length }
    $body = $Src.Substring($a, $b - $a)
    return ((($body -split "`n") | ForEach-Object { ($_ -split '#', 2)[0] }) -join "`n")
}

# ===========================================================================
Write-Host ''
Write-Host '--- the logon buttons plan before they act ---'
# ===========================================================================
$plan = Get-TickedPlan
$fresh = @($plan.Fresh); $rest = @($plan.Restart); $busy = @($plan.Busy); $blk = @($plan.Blocked)
Note ("ticked: fresh $($fresh.Count)  restart $($rest.Count)  mid-turn $($busy.Count)  blocked $($blk.Count)")

$ids = @()
foreach ($r in $fresh + $rest + $busy) { $ids += $r.Id }
foreach ($b in $blk) { $ids += $b.R.Id }
$dupe = @($ids | Group-Object | Where-Object { $_.Count -gt 1 })
if ($dupe.Count) { Fail "a conversation lands in two buckets: $($dupe[0].Name)" }
else { Pass "the four buckets are disjoint across $($ids.Count) ticked conversation(s)" }

if (@($rest | Where-Object { -not ($_.A -and $_.A.Pid) }).Count) {
    Fail 'Restart holds something with no live pid - relaunch would kill nothing and open a duplicate'
} else { Pass "every Restart entry has a live pid ($($rest.Count))" }

# 🔴 A kill loses the reply being written. This is the assertion that keeps
# Relaunch safe enough to be a button.
if (@($rest | Where-Object { "$($_.A.Status)" -eq 'busy' }).Count) {
    Fail 'a mid-turn conversation is in Restart'
} else { Pass 'no mid-turn conversation is ever in Restart' }

if (@($fresh | Where-Object { $_.A -and $_.A.Pid }).Count) {
    Fail 'Fresh holds something already running - Open would double it'
} else { Pass "nothing in Fresh is already running ($($fresh.Count))" }

if (@($fresh + $rest + $busy | Where-Object { -not [bool]$_.S.enabled }).Count) {
    Fail 'an UNTICKED conversation is in the plan'
} else { Pass 'the plan contains only ticked conversations' }

# Restart + Fresh is the bug that turned "fix the names on 12" into 29 tabs.
$expect = @($script:model.ToArray() | Where-Object { [bool]$_.S.enabled -and $_.D.enabled -and -not $_.D.missing -and $_.A -and $_.A.Pid -and "$($_.A.Status)" -ne 'busy' }).Count
if ($rest.Count -ne $expect) { Fail "Restart is $($rest.Count) but $expect are ticked, running and idle" }
else { Pass "Restart is exactly the ticked-and-running-and-idle set ($expect)" }

Start-LaunchQueue @()
if ($script:launchTimer.IsEnabled) { Fail 'an empty launch set started the timer'; $script:launchTimer.Stop() }
else { Pass 'an empty launch set starts no timer' }

# 🔴 THE REBOOT CASE, WHICH HAD NO TEST AND IS THE TOOL'S WHOLE PURPOSE.
# On 2026-08-29 the operator restarted the machine; nothing came back, and
# pressing Relaunch did nothing at all. Two independent causes, both here:
#
#   1. Relaunch took ONLY the running set. After a reboot that set is empty, so
#      the button planned zero work and looked dead. It now takes both, and the
#      cap is shared between them rather than applied twice.
#   2. The logon restore skipped 15 conversations as "already live (transcript
#      written < 3 min ago)" - written seconds before the shutdown, on a restart
#      that took less than three minutes. See Test-SRTranscriptLive below.
# 🔴 RESTORED IN A finally, BECAUSE THIS OBJECT IS NOW SHARED. $script:cfg is
# what Get-SRConfig handed back, and since the config cache landed that is the
# ONE parsed object every reader in the process holds - so between the write
# below and the restore, Get-SRCompactBrief, the zoom read and the cleartype
# read all see maxSessions=4. That was survivable while the restore always ran;
# it was a bare statement at the end of the block, so any Fail that threw in
# between left the value poisoned for the rest of the suite.
$capWas = $null
try { $capWas = $script:cfg.maxSessions } catch { }
try {
    $script:cfg.maxSessions = 4
    $a = Limit-ToCap @(1, 2, 3, 4, 5, 6)
    $b = Limit-ToCap @(7, 8, 9) -Already @($a.Go).Count
    if (@($a.Go).Count -ne 4) { Fail "the cap let $(@($a.Go).Count) through instead of 4" }
    elseif (@($b.Go).Count -ne 0) { Fail "a second call ignored what the first already took: $(@($b.Go).Count) more" }
    elseif ($b.Over -ne 3) { Fail "the second call reported $($b.Over) over the cap, not 3" }
    else { Pass 'two calls in one action share one cap rather than each getting a whole one' }
    $c = Limit-ToCap @(7, 8, 9) -Already 2
    if (@($c.Go).Count -ne 2) { Fail "with 2 already taken the cap left room for $(@($c.Go).Count), not 2" }
    else { Pass 'the shared cap leaves exactly the room that is left' }
} finally {
    if ($null -ne $capWas) { $script:cfg.maxSessions = $capWas }
}

# 🪤 A FRESH TRANSCRIPT AFTER A REBOOT IS THE OPPOSITE OF A LIVE SESSION, and
# a shorter window would not have fixed it - only a faster reboot was needed.
# The gate is the boot time, so this asserts the exact reported shape: a file
# written moments ago, but before this machine came up.
$tmp = Join-Path $SR_StateDir ('livecheck-{0}.jsonl' -f ([guid]::NewGuid().ToString('N')))
# 🪤 THE BOOT TIME IS FORCED, and it has to be. Written naively - a real
# file aged to just before the REAL boot - this passed without ever reaching the
# new guard: this machine booted long ago, so the file was already outside the
# 3-minute window and the ORIGINAL check rejected it. Green, and blind to the
# very bug it was written for. The reported shape needs a transcript that is
# INSIDE the window AND older than the boot, which is only reproducible with a
# boot time under the test's control.
$bootWas = $script:SR_BootTime
try {
    Set-Content -LiteralPath $tmp -Value '{}' -Encoding UTF8

    # The exact reported case: a fast restart. Boot 30 seconds ago, transcript
    # written 90 seconds ago - comfortably inside the live window, and written
    # before the machine came up, so nothing can be holding it.
    $script:SR_BootTime = (Get-Date).AddSeconds(-30)
    (Get-Item -LiteralPath $tmp).LastWriteTime = (Get-Date).AddSeconds(-90)
    if (Test-SRTranscriptLive -JsonlPath $tmp) {
        Fail 'a transcript written before this boot still counts as live - the reboot skip is back'
    } else { Pass 'a transcript written before this boot is never mistaken for a live session' }

    # And the inverse, or the assertion above would pass on a function that
    # simply always said no. Written since boot, with claude.exe on the machine
    # - which there is, this suite runs inside one.
    $script:SR_BootTime = (Get-Date).AddHours(-4)
    (Get-Item -LiteralPath $tmp).LastWriteTime = (Get-Date).AddSeconds(-20)
    $anyClaude = [bool]@(Get-Process -Name 'claude' -ErrorAction SilentlyContinue).Count
    if (-not $anyClaude) { Note 'no claude.exe on the machine, so the positive case cannot be posed' }
    elseif (-not (Test-SRTranscriptLive -JsonlPath $tmp)) {
        Fail 'a transcript written since boot, with sessions running, is not recognised as live'
    } else { Pass 'a genuinely live transcript is still recognised' }
} finally {
    $script:SR_BootTime = $bootWas
    Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue
}

if (@($blk | Where-Object { -not "$($_.Why)".Trim() }).Count) { Fail 'a blocked conversation carries no reason' }
else { Pass 'every blocked conversation names why' }

# ===========================================================================
Write-Host ''
Write-Host '--- the session manager can actually be used ---'
# ===========================================================================
$ui.ModeManage.IsChecked = $true
Set-Surface 'manage'
Lay

$items = @($ui.ManageList.Items)
$convIdx = -1
for ($i = 0; $i -lt $items.Count; $i++) { if ($items[$i].Kind -eq 'conv') { $convIdx = $i; break } }
# 🔴 EVERY PROJECT USED TO DEFAULT TO FOLDED, so no conversation row was ever on
# screen - which is why there were no visible ticks, no lane, no last-said and no
# age. Four reports, one cause.
if ($convIdx -lt 0) { Fail 'no conversation row is on screen - every project is folded' }
else { Pass "a project holding a tick opens itself: a conversation is on screen at row $convIdx" }

if ($convIdx -ge 0) {
    $container = $ui.ManageList.ItemContainerGenerator.ContainerFromIndex($convIdx)
    if (-not $container) { Fail 'the row has no realised container' }
    else {
        function Find-Named { param($El, [string]$Name)
            if (($El -is [System.Windows.FrameworkElement]) -and $El.Name -eq $Name) { return $El }
            $n = [System.Windows.Media.VisualTreeHelper]::GetChildrenCount($El)
            for ($i = 0; $i -lt $n; $i++) {
                $hit = Find-Named ([System.Windows.Media.VisualTreeHelper]::GetChild($El, $i)) $Name
                if ($hit) { return $hit }
            }
            return $null
        }
        $box = Find-Named $container 'TickBox'
        if (-not $box) { Fail "no element named 'TickBox' in the row - a click can never tell box from row" }
        else { Pass 'the tick box is in the visual tree and named' }

        # 🔴 ListBoxItem marks the button-down HANDLED when it selects, so
        # ListBox.MouseDoubleClick never fires and the old binding could not tick
        # anything at all. Resolved from the clicked visual instead.
        $row = Get-ClickedRow $box
        if (-not $row -or $row.Kind -ne 'conv') { Fail 'a click inside the row does not resolve to it' }
        else { Pass "a click resolves to its row ('$($row.Name)')" }
        if ($box -and -not (Test-ClickedTick $box)) { Fail 'a click on the box is not recognised - one click will not tick' }
        elseif ($box) { Pass 'a click on the box is told apart from a click on the row' }
        if (Test-ClickedTick $container) { Fail 'a click on the ROW was mistaken for a box click' }
        else { Pass 'clicking the row does not tick it' }

        if ($row) {
            $before = [bool]$row.Row.S.enabled
            $bg0 = $items[$convIdx].TickBg
            Set-TickOn $row.Row
            if ([bool]$row.Row.S.enabled -eq $before) { Fail 'Set-TickOn did not change the tick' }
            else { Pass "ticking flips the state ($before -> $(-not $before))" }
            $bg1 = $null
            foreach ($x in @($ui.ManageList.Items)) {
                if ($x.Kind -eq 'conv' -and $x.Row -and $x.Row.Id -eq $row.Row.Id) { $bg1 = $x.TickBg; break }
            }
            if ("$bg0" -eq "$bg1") { Fail 'the painted box did not change - ticking would look like it did nothing' }
            else { Pass "and repaints the box ('$bg0' -> '$bg1')" }
            # 🔴 Get-TickedPlan skips a directory that is not enabled, so a tick
            # inside a disabled project would draw a filled box and launch nothing.
            if ([bool]$row.Row.S.enabled -and -not [bool]$row.Row.D.enabled) {
                Fail 'the project was left disabled - the tick would launch nothing'
            } else { Pass 'ticking arms the project too, so the tick cannot lie' }
            Set-TickOn $row.Row      # put the operator's own registry back
            if ([bool]$row.Row.S.enabled -ne $before) { Fail 'could not restore the original tick' }
            else { Pass 'restored - nothing was saved, the file on disk is untouched' }
        }
    }
}
$script:dirty = $false

# The header must line up with the rows, which means it has to be the same Grid.
if ($ui.ManageCaption -isnot [System.Windows.Controls.Grid]) {
    Fail 'the column header is not a Grid - padded spaces cannot line up with rows that are'
} else { Pass 'the column header is a Grid on the same widths as the rows' }

# The LANE column printed 'GOV-1  GOV-1' down the screen, because worktrees are
# named after the conversation in them.
$echo = @($ui.ManageList.Items | Where-Object { $_.Kind -eq 'conv' -and "$($_.Lane)" -eq "$($_.Name)" })
if ($echo.Count) { Fail "$($echo.Count) row(s) print the conversation's own name in the LANE column" }
else { Pass 'the lane column never just repeats the conversation name' }

# 🔴 'WHAT IT LAST SAID' WAS ONE OF THE FOUR COLUMNS REPORTED BLANK, and unlike
# the other three it is the only one whose emptiness is INDISTINGUISHABLE from a
# quiet machine: with nothing running, every cell is legitimately empty and the
# column looks exactly as broken as it did when it was. So this asserts against
# the live set specifically - if a conversation is running, its last line is
# readable, and a blank cell for it is the defect.
$liveRows = @($ui.ManageList.Items | Where-Object { $_.Kind -eq 'conv' -and $_.Row -and $_.Row.Live })
if (-not $liveRows.Count) {
    Note 'nothing is running, so the last-said column has nothing it could show - not asserted'
} else {
    $blank = @($liveRows | Where-Object { -not "$($_.Said)".Trim() })
    if ($blank.Count) {
        $b = $blank[0]
        $raw = $null
        try { $raw = Get-SRLastSaid -JsonlPath $b.Row.S.jsonl } catch { }
        if ($raw -and "$($raw.Said)".Trim()) {
            Note 'the transcript HAS a last line - it is being lost between the read and the row'
        }
        Fail ("$($blank.Count) of $($liveRows.Count) RUNNING conversation(s) show nothing in 'what it last said', " +
              "first '$($b.Name)'")
    } else { Pass "every one of the $($liveRows.Count) running conversations shows what it last said" }
}

# 🔴 THE RIGHT-CLICK MENU MUST BE OURS, NOT WINDOWS'. A ContextMenu lives in
# its own popup outside the window's visual tree, so an implicit style in
# Window.Resources is not something to rely on reaching it - and without the
# template it keeps the OS chrome: a white slab with a blue highlight in the
# middle of a black window, on the gesture this surface is built around.
$cm = $ui.ManageList.ContextMenu
if (-not $cm) { Fail 'the manager has no per-row menu' }
elseif (-not $cm.Style) { Fail 'the right-click menu carries no style - it would render as a white Windows slab' }
elseif (-not @($cm.Style.Setters | Where-Object { $_.Property.Name -eq 'Template' }).Count) {
    Fail 'the menu style sets no Template, so the OS chrome survives underneath it'
} else {
    $items = @($cm.Items | Where-Object { $_ -is [System.Windows.Controls.MenuItem] })
    $bare = @($items | Where-Object { -not $_.Style })
    if ($bare.Count) { Fail "$($bare.Count) menu item(s) carry no style - they would highlight in Windows blue" }
    else { Pass "the right-click menu and all $($items.Count) of its items are drawn by this window, not by Windows" }
}
if (-not $ui.ManageList.ContextMenu) { Fail 'the manager has no per-row menu' }
else {
    $have = @($ui.ManageList.ContextMenu.Items |
              Where-Object { $_ -is [System.Windows.Controls.MenuItem] } | ForEach-Object { "$($_.Header)" })
    $missing = @(@('Open it now','Relaunch it','Go to its terminal','Settings...') | Where-Object { $have -notcontains $_ })
    if ($missing.Count) { Fail "the manager menu is missing: $($missing -join ', ')" }
    else { Pass "per-row actions: $($have -join ', ')" }
}

# ===========================================================================
Write-Host ''
Write-Host '--- the work surface keeps itself current ---'
# ===========================================================================
$ui.ModeWork.IsChecked = $true
Set-Surface 'work'
Lay
Build-Sessions

# 🔴 A repaint cost 2,336 ms because restoring the selection re-rendered the
# transcript AND spawned a console-read child process. Every search keystroke
# paid it.
$null = Ms { Build-Sessions }
$cost = Ms { Build-Sessions }
Note ("repaint with the selection unchanged: {0:N0} ms" -f $cost)
if ($cost -gt 400) { Fail ("a repaint costs {0:N0} ms - typing in the search box would freeze the window" -f $cost) }
else { Pass ("a repaint with the selection unchanged costs {0:N0} ms" -f $cost) }

$script:tailBytes = $script:TailBase * 4
Build-Sessions
if ($script:tailBytes -ne ($script:TailBase * 4)) { Fail "a repaint reset the tail budget - pressing L would be undone" }
else { Pass 'a repaint leaves an expanded conversation expanded' }
$script:tailBytes = $script:TailBase

$script:probeAt = (Get-Date).AddSeconds(-30)
$ui.Stamp.Text = 'stale'
$t = Ms { Invoke-FastPass }
if ($t -gt 300) { Fail ("the fast pass costs {0:N0} ms - too slow for its 6s tick" -f $t) }
else { Pass ("the fast pass costs {0:N0} ms" -f $t) }
if ($ui.Stamp.Text -eq 'stale') { Fail 'the fast pass did not move the stamp - the window would look frozen' }
else { Pass "the stamp moves every tick: '$($ui.Stamp.Text)'" }

# 🔴 Build-Sessions replaces ItemsSource, which throws away the scroll position.
# A repaint that changes nothing would yank the list from under your hand, every
# six seconds.
# 🪤 THIS ASSERTION IS ONLY MEANINGFUL WHILE NOTHING MOVED, and the fingerprint
# contains the AGE STRING - which ticks over on a minute boundary all by itself.
# The first version failed in a slow sweep for exactly that reason and was
# saying "the model changed", not "the code repainted wrongly". So the
# fingerprint is re-checked afterwards, and a run where it genuinely moved is
# retried rather than counted.
$sentinel = [PSCustomObject]@{ Kind = 'sentinel' }
$quiet = $false
foreach ($attempt in 1, 2, 3) {
    $fp0 = Get-ModelFingerprint
    $script:lastFp = $fp0
    $withMark = @(@($ui.SessionList.ItemsSource) + @($sentinel))
    $ui.SessionList.ItemsSource = $withMark
    Invoke-FastPass
    $kept = @($ui.SessionList.ItemsSource | Where-Object { $_.Kind -eq 'sentinel' }).Count
    if ((Get-ModelFingerprint) -ne $fp0) { Note "the model moved mid-check (attempt $attempt) - retrying"; continue }
    if (-not $kept) { Fail 'the fast pass repainted although nothing changed - it would steal your scroll every 6s' }
    else { Pass 'nothing changed, so nothing was repainted' }
    $quiet = $true
    break
}
if (-not $quiet) { Note 'the model never held still long enough to check this - not counted either way' }
$ui.SessionList.ItemsSource = $withMark
$script:lastFp = 'deliberately-different'
Invoke-FastPass
if (@($ui.SessionList.ItemsSource | Where-Object { $_.Kind -eq 'sentinel' }).Count) {
    Fail 'the fast pass did NOT repaint when the fingerprint moved'
} else { Pass 'a changed fingerprint does repaint - the check above can go red' }

$t2 = Ms { Start-LiveProbe }
if ($t2 -gt 300) { Fail ("starting the live probe blocked for {0:N0} ms - it is not in the background" -f $t2) }
else { Pass ("the live probe starts in {0:N0} ms - its 1.7s never lands on the UI thread" -f $t2) }
Start-LiveProbe
Pass 'a second probe while one is in flight is refused'
$sw = [Diagnostics.Stopwatch]::StartNew()
while ($sw.Elapsed.TotalSeconds -lt 90 -and $script:probePs) { Complete-LiveProbe; Start-Sleep -Milliseconds 200 }
if ($script:probePs) { Fail 'the probe never completed in 90s' }
else { Pass ("the probe completed and was collected in {0:N1}s" -f $sw.Elapsed.TotalSeconds) }

# ===========================================================================
Write-Host ''
Write-Host '--- the control plane ---'
# ===========================================================================
$pick = $null
foreach ($x in $script:model) { if ($x.A -and $x.A.Pid) { $pick = $x; break } }
if (-not $pick) { foreach ($x in $script:model) { $pick = $x; break } }
$script:selId = $pick.Id
Build-Sessions
foreach ($it in @($ui.SessionList.Items)) { if ($it.Kind -eq 'session' -and $it.Id -eq $pick.Id) { $ui.SessionList.SelectedItem = $it; break } }
Lay
$headerBefore = $ui.PaneName.Parent.Parent.ActualHeight
Show-Settings
Lay
if ($ui.SettingsBox.Visibility -ne [System.Windows.Visibility]::Visible) { Fail 'the settings panel did not open' }
else { Pass "the settings panel opens for '$((Get-Title $pick.S $pick.D).Text)'" }
# 🪤 Row 0 is Height="Auto": a 470px panel there stretches the HEADER rather
# than floating over the transcript.
if ([math]::Abs($ui.PaneName.Parent.Parent.ActualHeight - $headerBefore) -gt 1) {
    Fail 'the panel stretched the pane header - it is in a sizing row'
} else { Pass 'the panel floats; it does not push the header' }

if ($ui.SetName.Text -ne (Get-Title $pick.S $pick.D).Text) { Fail 'the name box is not pre-filled' }
else { Pass 'the name box carries the conversation name' }
# 🔴 --remote-control used to be hard-coded on every launch. If this default ever
# flips, Remote Control silently switches off for every session on the machine.
if (-not $ui.SetRemote.IsChecked) { Fail 'Remote Control defaulted OFF - it would switch off everywhere' }
else { Pass 'Remote Control defaults on, as every existing session already is' }
if ($ui.SetHidden.IsChecked) { Fail 'hidden defaulted on' } else { Pass 'hidden defaults off' }

Set-DropValue $ui.SetPerm 'bypassPermissions'; Update-PermNote
if ("$($ui.SetPermNote.Text)" -notmatch 'NO permission checks') { Fail 'bypassPermissions is not explained' }
else { Pass 'the mode that runs every command says what it costs' }
Set-DropValue $ui.SetPerm 'plan'; Update-PermNote
if ("$($ui.SetPermNote.Text)" -notmatch 'changes nothing') { Fail 'plan is not explained' }
else { Pass 'each permission mode explains itself' }
Hide-Settings

# --- what those settings become on the command line ------------------------
$probe = [PSCustomObject]@{ sessionId = '11111111-2222-3333-4444-555555555555'; title = 'probe' }
if (@(Get-SRSessionArgs $probe).Count -ne 0) { Fail 'a conversation with no settings produced flags' }
else { Pass 'a conversation with no settings adds no flags at all' }
Set-SRSessionPref $probe 'allowedTools' @('Read', 'Grep')
$fl = @(Get-SRSessionArgs $probe)
# 🪤 claude reads an EMPTY --allowedTools as "allow nothing": a stray trailing
# space would produce a session that can do nothing at all.
if (@($fl | Where-Object { -not "$_".Trim() }).Count) { Fail 'an empty tool rule reached the command line' }
else { Pass 'no empty tool rule can reach the command line' }
if (($fl -join ' ') -ne '--allowedTools Read --allowedTools Grep') { Fail "tool rules built as: $($fl -join ' ')" }
else { Pass 'each tool rule becomes its own flag' }

# --- and what the LAUNCH LINE ends up being --------------------------------
# 🔴 THE FLAGS ARE ONLY REAL IF THEY REACH `& claude`. Everything above tests
# the builder; this tests the line that is actually run. Read from the boot
# script's claude line ONLY - an earlier test in this suite matched
# '--remote-control' inside a COMMENT and would have passed however the code
# behaved - and always as a PAIR, on and off, so neither answer can come from a
# grep that always finds it or never does.
$bootDir = $SR_StateDir
# 🪤 NOT $Args - THAT IS AN AUTOMATIC VARIABLE. The first version of this helper
# took a parameter called $Args, which collides with PowerShell's own, and the
# flags silently never reached New-SRBootScript: four assertions failed against
# code that was correct. The same class of bug as the $Said collision this suite
# was extended to catch, hit while writing the test for it.
function Get-ClaudeLine { param([bool]$Remote, [string[]]$Extra)
    $p = New-SRBootScript -Dir $env:TEMP -SessionId '11111111-2222-3333-4444-555555555555' `
            -Title 'PROBE-1' -ClaudeArgs $Extra -RemoteControl $Remote
    $line = ''
    try {
        $line = @(Get-Content -LiteralPath $p -Encoding UTF8 |
                  Where-Object { $_ -match '^\s*&\s*claude\b' })[0]
    } finally { Remove-Item -LiteralPath $p -Force -ErrorAction SilentlyContinue }
    return "$line"
}
$onLine  = Get-ClaudeLine -Remote $true  -Args @()
$offLine = Get-ClaudeLine -Remote $false -Args @()
if ($onLine -notmatch '--remote-control') { Fail "Remote Control ON produced no flag: $onLine" }
elseif ($offLine -match '--remote-control') { Fail "Remote Control OFF still passed the flag: $offLine" }
else { Pass 'Remote Control reaches the launch line when on, and is absent when off' }
if ($onLine -notmatch "-n\s+'PROBE-1'") { Fail "the conversation name does not reach the launch line: $onLine" }
else { Pass 'the name you type is the name the session launches under' }

$withArgs = Get-ClaudeLine -Remote $true -Extra @('--model', 'opus', '--permission-mode', 'plan')
foreach ($bit in @('--model', 'opus', '--permission-mode', 'plan')) {
    if ($withArgs -notmatch [regex]::Escape($bit)) { Fail "'$bit' never reached the launch line: $withArgs" }
}
if ($withArgs -match '--model' -and $withArgs -match 'plan') {
    Pass 'the per-session settings arrive on the command the session is started with'
}

# Hidden is a LAUNCH decision, not a claude flag - it changes how the shell is
# started, so it must never appear on the claude line.
$hidProbe = [PSCustomObject]@{ sessionId = '99999999-8888-7777-6666-555555555555'; title = 'hidden probe' }
if (Test-SRHiddenWanted $hidProbe) { Fail 'a conversation with no preference is treated as hidden' }
else {
    Set-SRSessionPref $hidProbe 'hidden' $true
    if (-not (Test-SRHiddenWanted $hidProbe)) { Fail 'setting hidden did not take' }
    elseif (@(Get-SRSessionArgs $hidProbe) -match 'hidden') { Fail "'hidden' leaked onto the claude command line" }
    else { Pass 'hidden is a launch decision and never becomes a claude flag' }
}

# ===========================================================================
Write-Host ''
Write-Host '--- send to many ---'
# ===========================================================================
Show-Cast
# 🪤 NOT $rows / $running. The driver is spliced into the GUI's own scope, so a
# name the window keeps state in would be overwritten by the test - the harness
# refuses to build a driver that does it, which is how this was caught.
$castRows = @($ui.CastList.ItemsSource)
$castLive = @($script:model | Where-Object { $_.A -and $_.A.Pid }).Count
if ($castRows.Count -ne $castLive) { Fail "it lists $($castRows.Count) but $castLive are running" }
else { Pass "it lists exactly the $castLive running conversation(s)" }
if (@($castRows | Where-Object { -not ($_.Row.A -and $_.Row.A.Pid) }).Count) { Fail 'something not running is offered' }
else { Pass 'nothing that is not running can be selected' }
# 🔴 A keystroke arriving mid-reply is not undoable.
$busyRows = @($castRows | Where-Object { $_.Busy })
if (@($busyRows | Where-Object { -not "$($_.Why)".Trim() }).Count) { Fail 'a mid-turn conversation is offered with no reason' }
else { Pass "every mid-turn conversation says why it is unavailable ($($busyRows.Count) of $($castRows.Count))" }
$ui.CastText.Text = ''
$script:castPick = @{}
Build-Cast
if ($ui.CastSend.IsEnabled) { Fail 'Send is armed with nothing ticked and no message' }
else { Pass 'Send arms only with both a target and a message' }
Hide-Cast

# ===========================================================================
Write-Host ''
Write-Host '--- selecting a conversation is not evidence about it ---'
# ===========================================================================
# 🔴 CLICKING A WAITING CONVERSATION MADE IT VANISH FROM THE BAND YOU CLICKED
# IT IN. followStamp is reset to $null on a new selection, so the very next
# 1-second tick compared the stamp against nothing, called that growth, and
# moved the row out of NEEDS YOU. Selecting something is not evidence about it -
# a first observation is not a change - and the operator could not simply look
# at a waiting conversation without reclassifying it.
$ui.ModeWork.IsChecked = $true
Set-Surface 'work'
$script:bandPick = $null; $script:railPick = $null
$ui.Search.Text = ''; $ui.RailSearch.Text = ''; $ui.ListSearch.Text = ''
Build-Sessions
$liveItem = @($ui.SessionList.Items | Where-Object { $_.Kind -eq 'session' -and $_.Row.Live })[0]
if (-not $liveItem) { Note 'nothing is running, so the selection case cannot be posed' }
else {
    $row = $liveItem.Row
    $bandWas = $row.Band
    $stampWas = $script:followStamp
    $selWas = $script:selId

    # Exactly what happens on a click: the row is put into NEEDS YOU, selected,
    # and then the follow timer fires once.
    $row.Band = 'needs'
    $ui.SessionList.SelectedItem = $liveItem
    $script:followStamp = $null
    Invoke-FollowTick
    if ("$($row.Band)" -ne 'needs') {
        Fail "selecting a waiting conversation moved it to '$($row.Band)' - it vanishes from the band you clicked it in"
    } else { Pass 'selecting a waiting conversation leaves it exactly where it was' }

    # 🪤 AND THE INVERSE, or this would pass on a tick that never moves anything.
    # A SECOND, DIFFERENT stamp is real growth and must still move the row.
    $script:followStamp = 'a-stamp-that-is-definitely-stale'
    Invoke-FollowTick
    if ("$($row.Band)" -eq 'needs') {
        Fail 'a transcript that genuinely grew did not move the row - the reactivity is gone'
    } else { Pass 'but a transcript that actually grows still moves it' }

    $row.Band = $bandWas; $script:followStamp = $stampWas; $script:selId = $selWas
    Build-Sessions
}

# ===========================================================================
Write-Host ''
Write-Host '--- no timer tick may take the window down ---'
# ===========================================================================
# 🔴 AN UNHANDLED EXCEPTION OUT OF A DispatcherTimer TICK CLOSES THE WINDOW.
# The launch tick's own comment says exactly that, and then three of the seven
# ticks were left unguarded anyway - including the search rebuild, so one
# malformed registry entry plus one character typed into the search box was a
# closed window, and the launch DRAIN branch, which runs in the moments after a
# relaunch has already closed the conversations it is reopening.
#
# 🪤 This reads the SOURCE rather than firing the ticks, because a tick that
# throws in a test would take the test host down with it - which is the whole
# point being asserted.
$guiSrc = Get-Content -LiteralPath (Join-Path $SR_LibDir 'sessions-window.ps1') -Raw -Encoding UTF8
$bareTicks = @()
$tickNames = @('followTimer', 'searchTimer', 'launchTimer', 'castTimer', 'fastTimer', 'liveTimer', 'pollTimer')
$checked = 0
foreach ($tn in $tickNames) {
    $at = $guiSrc.IndexOf('$script:' + $tn + '.Add_Tick(')
    if ($at -lt 0) { Fail "no tick found for $tn - the audit is not reading the source"; continue }
    $checked++
    # The tick runs to the next top-level $script: declaration, or to the end of
    # the file for the last one. A fixed-size window was tried first and was
    # wrong twice: too small missed a try sitting behind a long comment, too
    # large bled into the NEXT tick and passed on its guard.
    $end = $guiSrc.IndexOf("`n`$script:", $at + 10)
    if ($end -lt 0) { $end = $guiSrc.Length }
    if ($guiSrc.Substring($at, $end - $at) -notmatch '(?s)try\s*\{') { $bareTicks += $tn }
}
if ($checked -ne $tickNames.Count) {
    Fail "only $checked of $($tickNames.Count) timer ticks were inspected"
} elseif ($bareTicks.Count) {
    Fail ('these timer ticks can throw straight out and close the window: ' + ($bareTicks -join ', '))
} else { Pass "all $checked timer ticks contain a try - none can close the window by throwing" }

# ===========================================================================
Write-Host ''
Write-Host '--- a probe that never returns must not stop the window ---'
# ===========================================================================
# 🔴 THE "ONE AT A TIME" GUARD WAS THE ONLY THING GATING A NEW PROBE, so a
# single job that never completed left $script:probePs set for the rest of the
# session: every later tick returned immediately, no refresh ever ran again, and
# NOTHING SAID SO. The only visible symptom is the "as of" stamp quietly
# ceasing to move. It spawns `claude agents --json`, so a wedged child is not
# hypothetical, and raising the probe to 15 s tripled the chances of meeting one.
$psWas = $script:probePs; $atWas = $script:probeStartedAt
try {
    $script:probePs = $null; $script:probeStartedAt = $null
    if (Test-ProbeOverdue) { Fail 'no probe is running and it is reported overdue' }
    else {
        # In flight, started a moment ago: must NOT be abandoned, or two probes
        # run at once and the guard was pointless.
        $script:probePs = 'in-flight'
        $script:probeStartedAt = (Get-Date)
        if (Test-ProbeOverdue) { Fail 'a probe that has just started is treated as hung' }
        else {
            # In flight, started well past the deadline: must be abandoned.
            $script:probeStartedAt = (Get-Date).AddSeconds(-($script:ProbeDeadlineSeconds + 30))
            if (-not (Test-ProbeOverdue)) {
                Fail "a probe stuck for $($script:ProbeDeadlineSeconds + 30)s is not recognised as hung - the window would never refresh again"
            } else { Pass "a probe stuck past $($script:ProbeDeadlineSeconds)s is abandoned so refreshing can resume" }
        }
    }
} finally { $script:probePs = $psWas; $script:probeStartedAt = $atWas }
if ($script:ProbeDeadlineSeconds -lt ($script:LiveSeconds * 3)) {
    Fail "the probe deadline ($($script:ProbeDeadlineSeconds)s) is less than three intervals - a slow but healthy probe would be killed"
} else { Pass "the deadline is $($script:ProbeDeadlineSeconds)s against a $($script:LiveSeconds)s interval, so a slow probe is not mistaken for a hung one" }

# ===========================================================================
Write-Host ''
Write-Host '--- how often a status can actually change ---'
# ===========================================================================
# 🔴 THE 6-SECOND PASS USED TO BE A REPAINT WEARING A REFRESH'S CLOTHES. It
# re-derived bands from $script:model, which only the 45-second probe refreshed,
# so a conversation you were not looking at could be three-quarters of a minute
# stale while the window looked busy. The probe is 15 s now, and the fast pass
# has a signal of its own: a transcript that is GROWING is a session working.
if ($script:LiveSeconds -gt 20) { Fail "the probe runs every $($script:LiveSeconds)s - status would be that stale" }
else { Pass "the probe refreshes status every $($script:LiveSeconds)s" }

$liveRows = @($script:model.ToArray() | Where-Object { $_.Live })
if (-not $liveRows.Count) { Note 'nothing is running, so the cheap tier cannot be posed' }
else {
    $cost = Ms { $null = Update-LiveWriters }
    Note ("  the cheap tier stats $($liveRows.Count) live transcript(s) in {0:N1} ms" -f $cost)
    if ($cost -gt 400) { Fail ("the 6-second tier costs {0:N0} ms - that is not a cheap tier" -f $cost) }
    else { Pass ("the 6-second tier costs {0:N0} ms against the probe's ~1200" -f $cost) }

    # 🪤 IT MOVES A ROW OUT OF NEEDS YOU, NEVER INTO IT. File activity proves a
    # session is doing something; it can never prove one has started waiting.
    $victim = $liveRows[0]
    $bandWas = $victim.Band
    $victim.Band = 'needs'
    $script:liveStamp["$($victim.Id)"] = 'definitely-not-the-current-stamp'
    $null = Update-LiveWriters
    if ("$($victim.Band)" -ne 'working') {
        Fail 'a live conversation whose transcript changed was left in NEEDS YOU'
    } else { Pass 'a transcript that grew moves its row out of NEEDS YOU within the 6-second tick' }

    # The inverse: a row that is NOT needing you is never pushed into needs.
    $victim.Band = 'done'
    $script:liveStamp["$($victim.Id)"] = 'also-not-the-current-stamp'
    $null = Update-LiveWriters
    if ("$($victim.Band)" -ne 'done') { Fail "the cheap tier moved a row INTO '$($victim.Band)' - only the probe may do that" }
    else { Pass 'and never moves a row into a state it cannot measure' }
    $victim.Band = $bandWas
}

# ===========================================================================
Write-Host ''
Write-Host '--- what you actually wait on ---'
# ===========================================================================
# 🔴 THE PER-CONVERSATION NUMBER WAS NEVER THE THING YOU FEEL. It measures the
# fast pass, which is already 3-5 ms; what the operator waits on is selecting a
# conversation, switching surfaces and the transcript rendering. Those are
# measured here, at real size, against the operator's own 190 conversations.
#
# 🪤 The budgets are DELIBERATELY LOOSE. An earlier perf assertion in this
# suite failed on 7.2 ms vs 34.4 ms of the same code on a busy machine and had
# to be relaxed to a tenfold rule; a benchmark that cries wolf gets muted, and a
# muted benchmark catches nothing.
$ui.ModeWork.IsChecked = $true
Set-Surface 'work'
$script:bandPick = $null
Build-Sessions
Lay
$sessions = @($ui.SessionList.Items | Where-Object { $_.Kind -eq 'session' })
if ($sessions.Count -lt 2) { Note 'not enough conversations on screen to profile selection' }
else {
    $perf = [ordered]@{}
    $perf['build the sessions column'] = Ms { Build-Sessions }
    $perf['build the project rail']    = Ms { Build-Rail }
    $perf['build the manager']         = Ms { Build-Manager }
    $perf['switch to the manager']     = Ms { Set-Surface 'manage' }
    $perf['switch back to work']       = Ms { Set-Surface 'work' }
    # The expensive one: selecting a DIFFERENT conversation renders its
    # transcript from disk. -Force is what the window itself calls.
    # 🪤 A *DIFFERENT* CONVERSATION, WHICH IS THE PATH THAT COSTS. The first
    # version of this profile measured Show-Selected twice on the same row -
    # $same was true, the whole expensive branch was skipped, and it reported
    # 133 ms for a gesture the operator was experiencing as multi-second lag.
    # $script:selId is what makes it "the same one", so it is cleared here.
    $script:selId = $null
    $ui.SessionList.SelectedItem = $sessions[0]
    $perf['select a conversation (cold)'] = Ms { Show-Selected }
    $script:selId = $null
    $ui.SessionList.SelectedItem = $sessions[1]
    $perf['select another (cold)']        = Ms { Show-Selected }
    $perf['re-select the same one']       = Ms { Show-Selected }
    $perf['re-render the transcript']     = Ms { Update-Document -Wait }
    # The sub-steps of a cold selection, so the next stall is aimed at rather
    # than guessed. Show-Selected is: Update-Document, Move-ToBottom,
    # Show-Ask, a probe kick and Update-SendState.
    $perf['  Move-ToBottom']              = Ms { Move-ToBottom }
    $perf['  Update-SendState']           = Ms { Update-SendState }
    $perf['  Show-Ask $null']             = Ms { Show-Ask $null }
    # Update-Document is parse-then-build; which half costs is the question.
    $jp = "$(@($ui.SessionList.Items | Where-Object { $_.Kind -eq 'session' })[0].Row.S.jsonl)"
    $blk = $null
    $perf['  parse the transcript']       = Ms { $script:__blk = Get-SRTranscriptBlocks -JsonlPath $jp -MaxRecords 220 -MaxTailBytes $script:tailBytes }
    $perf['  build the FlowDocument']     = Ms { $null = Build-ReadDocument -Blocks $script:__blk -Truncated $false }
    # 🔴 WHERE DOES THE ~400 ms GO? Two candidates, both measurable rather
    # than arguable: the size of the transcript tail being rendered, and WPF's
    # optimal-paragraph line breaker. Measured here so the fix is aimed.
    $tailWas = $script:tailBytes
    $optWas = $true
    $script:tailBytes = 98304
    $perf['  ...at a 96 KB tail']  = Ms { Update-Document -Wait }
    $script:tailBytes = 262144
    $perf['  ...at a 256 KB tail'] = Ms { Update-Document -Wait }
    $script:tailBytes = $tailWas
    foreach ($k in $perf.Keys) { Note ("  {0,-30} {1,7:N1} ms" -f $k, $perf[$k]) }

    # One budget, on the thing that would actually be felt: selecting a
    # conversation is the gesture repeated all day.
    # The budget is on the COLD path, because that is the click.
    if ($perf['select another (cold)'] -gt 900) {
        Fail ("selecting a conversation costs {0:N0} ms - that is a visible stall" -f $perf['select another (cold)'])
    } else { Pass ("selecting a conversation costs {0:N0} ms" -f $perf['select another (cold)']) }
    if ($perf['switch to the manager'] -gt 900) {
        Fail ("switching surfaces costs {0:N0} ms" -f $perf['switch to the manager'])
    } else { Pass ("switching surfaces costs {0:N0} ms" -f $perf['switch to the manager']) }
}

# ===========================================================================
Write-Host ''
Write-Host '--- the design, end to end ---'
# ===========================================================================
# 🔴 ANY CONTROL WITHOUT A STYLE IS A WINDOWS CONTROL. WPF's defaults are a
# light-grey 3D theme, so a single unstyled Button or ComboBox in a black window
# is instantly the loudest thing on screen - and it is invisible in review until
# the exact state that shows it. The operator asked to "verify the design is now
# adopted end to end across every single aspect"; this is that verification, as
# a standing check rather than a look.
$xamlText = Get-Content -LiteralPath (Join-Path $SR_LibDir 'window2.xaml') -Raw -Encoding UTF8
$spawnText = Get-Content -LiteralPath (Join-Path $SR_LibDir 'spawn2.xaml') -Raw -Encoding UTF8
# Comments first, or the examples inside them are audited as if they were markup.
$strip = { param($t) [regex]::Replace($t, '(?s)<!--.*?-->', '') }
# Types WPF gives a visible default chrome to. ScrollViewer and Grid have none,
# so they are deliberately absent.
$needStyle = @('Button', 'TextBox', 'ComboBox', 'CheckBox', 'RadioButton', 'ListBox', 'Slider', 'TabControl')
foreach ($pair in @(@('window2.xaml', (& $strip $xamlText)), @('spawn2.xaml', (& $strip $spawnText)))) {
    $file = $pair[0]; $body = $pair[1]
    $bare = New-Object System.Collections.Generic.List[string]
    $seen = 0
    foreach ($t in $needStyle) {
        # 🪤 The word boundary is a character class rather than \b on purpose: a
        # literal BACKSPACE byte got into this pattern on the first run, the
        # regex then matched NOTHING, and the audit pronounced every file clean
        # while inspecting zero controls. That is why $seen exists below.
        foreach ($m in [regex]::Matches($body, ('<' + $t + '[\s>/][^>]*>'))) {
            $seen++
            $tag = $m.Value
            # A control inside a ControlTemplate is being styled BY that template.
            if ($tag -match 'Style=') { continue }
            if ($tag -match 'x:Key=') { continue }
            $bare.Add(($t + ($(if ($tag -match 'x:Name="([^"]+)"') { " '" + $Matches[1] + "'" } else { '' }))))
        }
    }
    # 🔴 THE COUNT IS REPORTED, NOT JUST THE VERDICT. "0 unstyled" out of 0
    # inspected is not evidence of anything - and that is precisely what this
    # assertion reported on its first run, with a broken pattern underneath it.
    if ($seen -lt 5) { Fail "$file : only $seen styleable control(s) found - the audit is not reading the markup" }
    elseif ($bare.Count) { Fail ("$file has $($bare.Count) control(s) with no style, which render as Windows chrome: " + (($bare | Select-Object -First 6) -join ', ')) }
    else { Pass "$file styles all $seen controls that have a Windows default" }
}

# The two surfaces that are NOT markup, and were the last to be drawn by Windows.
foreach ($k in @([System.Windows.Controls.ContextMenu], [System.Windows.Controls.MenuItem],
                 [System.Windows.Controls.ToolTip], [System.Windows.Controls.Separator])) {
    $st = $null
    try { $st = $window.FindResource($k) } catch { }
    if (-not $st) { Fail "$($k.Name) has no implicit style - it would keep the OS chrome" }
    elseif (-not @($st.Setters | Where-Object { $_.Property.Name -eq 'Template' }).Count) {
        Fail "$($k.Name) is styled but not TEMPLATED, so the OS chrome survives under it"
    }
}
Pass 'the right-click menu, its items, separators and tooltips are all templated here'

# And nothing may reach for a MessageBox again - that was the whole point of
# the sheet, and it is the easiest thing to reintroduce by habit.
$guiCode = @(Get-Content -LiteralPath (Join-Path $SR_LibDir 'sessions-window.ps1') -Encoding UTF8 |
             ForEach-Object { ($_ -replace '(?<!`)#.*$', '') } | Where-Object { $_.Trim() })
$boxes = @($guiCode | Where-Object { $_ -match 'MessageBox' })
if ($boxes.Count) { Fail "a stock MessageBox is back: $($boxes[0].Trim())" }
else { Pass 'no stock dialog anywhere in the window' }

# ===========================================================================
Write-Host ''
Write-Host '--- is a session in the right band? ---'
# ===========================================================================
# The operator asked whether the categorisation and the "has pending work"
# reading are actually right. These are the invariants that make each band
# mean what its heading says; a row in the wrong one is worse than no bands.
$ui.ModeWork.IsChecked = $true
Set-Surface 'work'
$script:bandPick = $null
Build-Sessions
$rows = @($script:model.ToArray() | Where-Object { Test-OnSurface $_ })
$byBand = @{}
foreach ($r in $rows) { $k = "$($r.Band)"; if (-not $byBand.ContainsKey($k)) { $byBand[$k] = 0 }; $byBand[$k]++ }
Note ('bands: ' + ((@($byBand.Keys | Sort-Object | ForEach-Object { "$_=$($byBand[$_])" })) -join '  '))

# NEEDS YOU is a claim that something is blocked on the operator. A conversation
# that is not running cannot be waiting on anyone.
$ghosts = @($rows | Where-Object { "$($_.Band)" -eq 'needs' -and -not $_.Live })
if ($ghosts.Count) { Fail "$($ghosts.Count) conversation(s) claim to need you but are not running: $((@($ghosts | ForEach-Object { (Get-Title $_.S $_.D).Text }) | Select-Object -First 3) -join ', ')" }
else { Pass "nothing claims to need you unless it is actually running ($($byBand['needs']) in NEEDS YOU)" }

# WORKING likewise: it is a statement about a live process.
$idleWorkers = @($rows | Where-Object { "$($_.Band)" -eq 'working' -and -not $_.Live })
if ($idleWorkers.Count) { Fail "$($idleWorkers.Count) conversation(s) are shown as WORKING with no process" }
else { Pass 'everything shown as working has a live process' }

# And the reverse - a live, mid-turn conversation must never be filed as
# finished or not-running, which would hide it exactly when it matters.
$misfiled = @($rows | Where-Object { $_.Live -and "$($_.A.Status)" -eq 'busy' -and @('done','quiet','idle') -contains "$($_.Band)" })
if ($misfiled.Count) { Fail "$($misfiled.Count) mid-turn conversation(s) are filed as finished or idle" }
else { Pass 'a mid-turn conversation is never filed as finished or idle' }

# Every row lands in exactly one band, and every band the list draws is one the
# model actually produced.
$known = @($script:Bands | ForEach-Object { $_.Key })
$strays = @($rows | Where-Object { $known -notcontains "$($_.Band)" })
if ($strays.Count) { Fail "$($strays.Count) row(s) carry a band the list cannot draw: $((@($strays | ForEach-Object { $_.Band }) | Sort-Object -Unique) -join ', ')" }
else { Pass "every conversation carries one of the $($known.Count) known bands" }

# ===========================================================================
Write-Host ''
Write-Host '--- the manager filter strip ---'
# ===========================================================================
# 🔴 THE MANAGER HAD SORTING AND NOTHING ELSE. This surface decides what comes
# back at the next logon, and there was no way to ask "just the ticked ones" -
# the question it exists to answer.
$ui.ModeManage.IsChecked = $true
Set-Surface 'manage'
$fWas = $script:mgrFilter
$fFoldWas = @{}; foreach ($fk in @($script:fold.Keys)) { $fFoldWas[$fk] = $script:fold[$fk] }
$fOlderWas = $script:showOlder
$script:showOlder = $true
$script:mgrFilter = 'all'; Build-Manager
foreach ($fk in @($script:fold.Keys)) { $script:fold[$fk] = $false }
Build-Manager
$allRows = @($ui.ManageList.Items | Where-Object { $_.Kind -eq 'conv' })
foreach ($case in @(@('ticked', { param($r) [bool]$r.S.enabled }),
                    @('running', { param($r) $r.Live }),
                    @('needs',   { param($r) "$($r.Band)" -eq 'needs' }))) {
    $script:mgrFilter = $case[0]
    Build-Manager
    $rows = @($ui.ManageList.Items | Where-Object { $_.Kind -eq 'conv' })
    $wrong = @($rows | Where-Object { -not (& $case[1] $_.Row) })
    $expect = @($allRows | Where-Object { & $case[1] $_.Row }).Count
    if ($wrong.Count) { Fail "the '$($case[0])' filter let $($wrong.Count) row(s) through that do not match" }
    elseif ($rows.Count -ne $expect) { Fail "the '$($case[0])' filter shows $($rows.Count) rows but $expect match" }
    else { Pass "'$($case[0])' shows exactly the $($rows.Count) that match" }
    # 🪤 AND IT HAS TO SAY SO. A filter left on silently is a list you read as
    # complete, on the surface that decides what reopens at logon.
    if (-not "$($ui.MgrFilterNote.Text)".Trim()) { Fail "the '$($case[0])' filter does not say the list is filtered" }
}
Pass 'a filtered list says out loud that it is filtered'
$script:mgrFilter = 'all'; Build-Manager
if ("$($ui.MgrFilterNote.Text)".Trim()) { Fail 'the note stays up when nothing is filtered' }
else { Pass 'and says nothing when everything is shown' }
$script:mgrFilter = $fWas; $script:showOlder = $fOlderWas
foreach ($fk in @($fFoldWas.Keys)) { $script:fold[$fk] = $fFoldWas[$fk] }
Build-Manager

# ===========================================================================
Write-Host ''
Write-Host '--- the manager sorts by its column headers ---'
# ===========================================================================
# 🔴 THE HEADERS WERE INERT AND LOOKED SORTABLE. The operator clicked LOGON,
# nothing happened, and reported the filter broken - a header that looks like
# every other sortable header on the machine and does nothing teaches you the
# table is dead. Each one is asserted to actually REORDER the rows, because a
# handler that fires and sorts by a key that does not vary would look identical.
$ui.ModeManage.IsChecked = $true
Set-Surface 'manage'
$sortWas = $script:mgrSort; $descWas = $script:mgrDesc
# 🪤 UNFOLD FIRST. Earlier assertions in this suite tick, untick and fold, so
# by the time sorting is reached one project may be open with a single row in
# it - and a one-row table sorts identically in both directions, which would
# have reported a working sort as broken (it did, first run).
$foldWas = @{}; foreach ($fk in @($script:fold.Keys)) { $foldWas[$fk] = $script:fold[$fk] }
$olderWas = $script:showOlder
$script:showOlder = $true
Build-Manager
foreach ($fk in @($script:fold.Keys)) { $script:fold[$fk] = $false }
function Get-MgrNames {
    return @($ui.ManageList.Items | Where-Object { $_.Kind -eq 'conv' } | ForEach-Object { "$($_.Name)" })
}
foreach ($hn in @('HdrLogon', 'HdrName', 'HdrLane', 'HdrSaid', 'HdrAge')) {
    if (-not $ui.$hn) { Fail "the manager has no header '$hn'" }
    elseif (-not "$($ui.$hn.Tag)") { Fail "'$hn' carries no sort key, so a click could not act on it" }
}
$script:mgrSort = 'name'; $script:mgrDesc = $false; Build-Manager
$asc = Get-MgrNames
$script:mgrDesc = $true; Build-Manager
$desc = Get-MgrNames
if ($asc.Count -lt 2) { Fail "only $($asc.Count) conversation(s) visible - sorting cannot be posed" }
elseif (($asc -join '|') -eq ($desc -join '|')) {
    Fail 'reversing the sort direction changed nothing - the arrow would lie'
} else { Pass "sorting by name reorders $($asc.Count) rows, and reverses" }

# Sorting is WITHIN a project, so the grouping the surface is built on survives.
$script:mgrSort = 'age'; $script:mgrDesc = $true; Build-Manager
$seq = @($ui.ManageList.Items | Where-Object { $_.Kind -eq 'conv' -or $_.Kind -eq 'project' })
$projSeen = New-Object System.Collections.Generic.List[string]
$broken = $false
foreach ($x in $seq) {
    if ($x.Kind -eq 'project') {
        if ($projSeen.Contains("$($x.Path)")) { $broken = $true; break }
        $projSeen.Add("$($x.Path)")
    }
}
if ($broken) { Fail 'sorting split a project into more than one run - the grouping is gone' }
else { Pass "the project grouping survives the sort ($($projSeen.Count) projects, each in one run)" }

# Every key has to be usable, not just the two that are easy.
foreach ($k in @('logon', 'name', 'lane', 'said', 'age')) {
    $script:mgrSort = $k
    try { Build-Manager } catch { Fail "sorting by '$k' threw: $($_.Exception.Message)" }
}
Pass 'every column key sorts without throwing'
$script:mgrSort = $sortWas; $script:mgrDesc = $descWas
$script:showOlder = $olderWas
foreach ($fk in @($foldWas.Keys)) { $script:fold[$fk] = $foldWas[$fk] }
Build-Manager

# ===========================================================================
Write-Host ''
Write-Host '--- the state filter, on the band headings ---'
# ===========================================================================
# 🔴 THE RETIRED WINDOW HAD THIS AND THE REWRITE DROPPED IT. Three clickable
# count pills became nothing at all, and there was no way to narrow the list to
# "what is waiting on me" - reported as "the filter option and logic is gone".
$ui.ModeWork.IsChecked = $true
Set-Surface 'work'
$script:bandPick = $null
Build-Sessions
$allRows = @($ui.SessionList.Items | Where-Object { $_.Kind -eq 'session' }).Count
$heads = @($ui.SessionList.Items | Where-Object { $_.Kind -eq 'band' })
if ($heads.Count -lt 2) { Note "only $($heads.Count) band(s) on screen - the filter cannot be posed" }
else {
    $key = "$($heads[0].BandKey)"
    if (-not $key) { Fail 'a band heading carries no key, so a click could not tell which band it is' }
    else {
        $script:bandPick = $key
        Build-Sessions
        $now  = @($ui.SessionList.Items | Where-Object { $_.Kind -eq 'session' })
        $offBand = @($now | Where-Object { "$($_.Row.Band)" -ne $key })
        if (-not $now.Count) { Fail "filtering to '$key' left no conversations at all" }
        elseif ($offBand.Count) { Fail "$($offBand.Count) conversation(s) from other bands survived the filter" }
        elseif ($now.Count -ge $allRows) { Fail "filtering showed $($now.Count) of $allRows - it narrowed nothing" }
        else { Pass "filtering to one band shows $($now.Count) of $allRows conversations" }

        # 🪤 EVERY HEADING STAYS. Hiding the others leaves no way back to the
        # full list except a control that is now off screen.
        $stillHeads = @($ui.SessionList.Items | Where-Object { $_.Kind -eq 'band' })
        if ($stillHeads.Count -ne $heads.Count) {
            Fail "filtering hid $($heads.Count - $stillHeads.Count) heading(s) - there would be no way back"
        } else { Pass 'every band heading stays on screen, so you can switch or clear it' }
        $lit = @($stillHeads | Where-Object { "$($_.BandHint)".Trim() })
        if ($lit.Count -ne 1) { Fail "$($lit.Count) headings claim to be the active filter, not 1" }
        else { Pass 'the active band says so on the heading itself' }

        # And it must come back off.
        $script:bandPick = $null
        Build-Sessions
        $back = @($ui.SessionList.Items | Where-Object { $_.Kind -eq 'session' }).Count
        if ($back -ne $allRows) { Fail "clearing the filter left $back conversations, not the original $allRows" }
        else { Pass 'clearing it restores every conversation' }
    }
}
$script:bandPick = $null
Build-Sessions

# ===========================================================================
Write-Host ''
Write-Host '--- each pane searches, sorts and filters itself ---'
# ===========================================================================
# 🔴 THE HEADER BOX IS GLOBAL; THESE ARE NOT. Being able to hold one term for
# projects and another for conversations at the same time is the whole point of
# having both, and is what "I am still missing the search in the work surface
# projects and sessions" meant after the global box already reached both panes.
$ui.ModeWork.IsChecked = $true
Set-Surface 'work'
$script:bandPick = $null; $script:railPick = $null
$ui.Search.Text = ''; $ui.RailSearch.Text = ''; $ui.ListSearch.Text = ''
Build-Rail; Build-Sessions
$tiles0 = @($ui.RailList.ItemsSource | Where-Object { $_.Kind -eq 'project' }).Count
$rows0  = @($ui.SessionList.Items | Where-Object { $_.Kind -eq 'session' }).Count
if ($tiles0 -lt 2 -or $rows0 -lt 2) { Note 'not enough on screen to pose the search' }
else {
    # The rail's box narrows the rail and LEAVES THE SESSIONS ALONE.
    $ui.RailSearch.Text = 'algotrader'
    Build-Rail; Build-Sessions
    $tilesR = @($ui.RailList.ItemsSource | Where-Object { $_.Kind -eq 'project' })
    $rowsR  = @($ui.SessionList.Items | Where-Object { $_.Kind -eq 'session' }).Count
    $offName = @($tilesR | Where-Object { "$($_.Label)".ToLower() -notlike '*algotrader*' })
    if (-not $tilesR.Count) { Fail "the rail search matched no project at all" }
    elseif ($offName.Count) { Fail "$($offName.Count) project(s) survived a search they do not match" }
    elseif ($tilesR.Count -ge $tiles0) { Fail "the rail search narrowed nothing ($($tilesR.Count) of $tiles0)" }
    elseif ($rowsR -ne $rows0) { Fail "the rail's own box changed the SESSIONS column too ($rows0 -> $rowsR)" }
    else { Pass "the rail box narrows the rail to $($tilesR.Count) of $tiles0 and leaves the sessions untouched" }
    $ui.RailSearch.Text = ''

    # And the sessions box narrows the sessions and LEAVES THE RAIL ALONE.
    Build-Rail; Build-Sessions
    $anyName = @($ui.SessionList.Items | Where-Object { $_.Kind -eq 'session' })[0].Name
    $frag = "$anyName".Substring(0, [Math]::Min(4, "$anyName".Length)).ToLower()
    $ui.ListSearch.Text = $frag
    Build-Rail; Build-Sessions
    $tilesL = @($ui.RailList.ItemsSource | Where-Object { $_.Kind -eq 'project' }).Count
    $rowsL  = @($ui.SessionList.Items | Where-Object { $_.Kind -eq 'session' })
    $offRow = @($rowsL | Where-Object { "$($_.Name)".ToLower() -notlike "*$frag*" -and "$($_.Row.S.autoTitle)".ToLower() -notlike "*$frag*" })
    if (-not $rowsL.Count) { Fail "the sessions search on '$frag' matched nothing, not even the row it came from" }
    elseif ($offRow.Count) { Fail "$($offRow.Count) conversation(s) survived a search they do not match" }
    elseif ($tilesL -ne $tiles0) { Fail "the sessions box changed the RAIL too ($tiles0 -> $tilesL)" }
    else { Pass "the sessions box narrows to $($rowsL.Count) of $rows0 and leaves the rail untouched" }
    $ui.ListSearch.Text = ''
    Build-Rail; Build-Sessions
}

# The rail's own ordering, and its own filter.
foreach ($k in @('recent', 'name', 'waiting', 'busiest')) {
    $script:railSort = $k
    try { Build-Rail } catch { Fail "ordering the rail by '$k' threw: $($_.Exception.Message)" }
}
$script:railSort = 'name'; Build-Rail
# 🔴 SORTED WITHIN THE BAND, NEVER ACROSS IT - the same rule the sessions column
# states beside Sort-SessionRows. This checked one global sequence, which held
# only while the rail had a single band; now that it carries every project there
# are four, and a globally-sorted list would mean the age grouping had been
# thrown away. So the order is checked inside each band and the bands are
# checked to be in age order elsewhere.
$nameBad = @()
$nameBand = ''; $nameSeen = @{}
foreach ($it in @($ui.RailList.ItemsSource)) {
    if ($it.Kind -eq 'band') { $nameBand = "$($it.BandKey)"; $nameSeen[$nameBand] = New-Object System.Collections.Generic.List[string]; continue }
    if ($nameBand) { $nameSeen[$nameBand].Add("$($it.Label)".ToLower()) }
}
$nameTotal = 0
foreach ($bk in @($nameSeen.Keys)) {
    $got = @($nameSeen[$bk].ToArray())
    $nameTotal += $got.Count
    $want = @($got | Sort-Object)
    if (($got -join '|') -ne ($want -join '|')) { $nameBad += $bk }
}
if ($nameBad.Count) { Fail "ordering the rail by name did not sort inside band(s): $($nameBad -join ', ')" }
elseif (-not $nameTotal) { Fail 'ordering the rail by name left no projects to check' }
else { Pass "the rail orders itself four ways ($($names.Count) projects, name order verified)" }
$script:railSort = 'recent'

$script:railOnlyLive = $true; Build-Rail
$live = @($ui.RailList.ItemsSource | Where-Object { $_.Kind -eq 'project' })
$dead = @($live | Where-Object { "$($_.State)" -like '*idle*' -and "$($_.State)" -notlike '*working*' -and "$($_.State)" -notlike '*waiting*' })
if ($dead.Count) { Fail "$($dead.Count) project(s) with nothing running survived the 'only running' filter" }
else { Pass "'only running' leaves $($live.Count) project(s), none of them idle" }
$script:railOnlyLive = $false; Build-Rail

# ===========================================================================
Write-Host ''
Write-Host '--- the grouping is cached, and every input invalidates it ---'
# ===========================================================================
# 🔴 A CACHE INVALIDATED ON A SUBSET OF ITS INPUTS SHOWS A RAIL THAT DISAGREES
# WITH REALITY, and it reads as a data bug rather than a caching one. So each
# input is changed in turn and the grouping is required to actually change -
# and the negative is asserted too, or "it always rebuilds" would pass every
# positive here while caching nothing.
#
# The inputs were enumerated, not guessed: the walk reads which rows are in the
# model, plus $r.D.path, $r.At, $r.Hay and $r.HayProj - all four written once in
# Update-Model. It does NOT read .Live or .Band, which is what makes it safe,
# because the probe's light branch mutates those in place without replacing the
# model. See the note on Get-RailGrouping.
$cgGenWas = $script:modelGen
$cgKeyWas = $script:railGroupKey
try {
    # Same inputs twice: the very same object comes back.
    $g1 = Get-RailGrouping -Q '' -QR ''
    $g2 = Get-RailGrouping -Q '' -QR ''
    if (-not [object]::ReferenceEquals($g1.ByProj, $g2.ByProj)) {
        Fail 'the grouping was rebuilt with nothing changed - it is not caching at all'
    } else { Pass "an unchanged model reuses the grouping ($(@($g1.ByProj.Keys).Count) projects)" }

    # 1. THE MODEL. This is the one the light probe cannot bump on its own, so a
    #    cache keyed on anything weaker would go stale on a real rescan.
    $script:modelGen++
    $g3 = Get-RailGrouping -Q '' -QR ''
    if ([object]::ReferenceEquals($g1.ByProj, $g3.ByProj)) {
        Fail 'a new model did not invalidate the grouping - the rail would keep showing the old projects'
    } else { Pass 'a new model invalidates it' }

    # 2. THE HEADER SEARCH. Narrows by conversation, so it changes which rows
    #    land in each project and can drop a project entirely.
    $g4 = Get-RailGrouping -Q 'zzz-no-such-conversation' -QR ''
    if ([object]::ReferenceEquals($g3.ByProj, $g4.ByProj)) {
        Fail 'the header search did not invalidate the grouping'
    } elseif (@($g4.ByProj.Keys).Count -ge @($g3.ByProj.Keys).Count) {
        Fail "a search matching nothing left $(@($g4.ByProj.Keys).Count) project(s) - it is not filtering"
    } else { Pass "the header search invalidates it ($(@($g3.ByProj.Keys).Count) -> $(@($g4.ByProj.Keys).Count) projects)" }

    # 3. THE RAIL SEARCH. A different box asking a different question, and it
    #    has its own haystack - so it needs its own slot in the key.
    $g5 = Get-RailGrouping -Q '' -QR 'zzz-no-such-project'
    if ([object]::ReferenceEquals($g3.ByProj, $g5.ByProj)) {
        Fail 'the rail search did not invalidate the grouping'
    } elseif (@($g5.ByProj.Keys).Count -ge @($g3.ByProj.Keys).Count) {
        Fail "a project search matching nothing left $(@($g5.ByProj.Keys).Count) project(s)"
    } else { Pass "the rail search invalidates it ($(@($g5.ByProj.Keys).Count) projects)" }

    # 🔴 PAIRWISE, AND THIS IS THE CHECK THAT ACTUALLY PROVES A SLOT IS IN THE
    # KEY. The three above do not: dropping $QR from the key entirely still left
    # them all green, because each call also changed $Q or the generation, so a
    # rebuild happened for the wrong reason and the counts still came out right.
    # Found by breaking the key and watching the suite stay green - the gap was
    # in the test, not the code. Each pair below changes exactly ONE input.
    $p0 = Get-RailGrouping -Q '' -QR ''
    $p1 = Get-RailGrouping -Q '' -QR 'zzz-only-the-rail-box-moved'
    if ([object]::ReferenceEquals($p0.ByProj, $p1.ByProj)) {
        Fail 'changing ONLY the rail search reused the grouping - $QR is not in the cache key'
    } else { Pass 'the rail search alone invalidates it' }

    $p2 = Get-RailGrouping -Q '' -QR ''
    $p3 = Get-RailGrouping -Q 'zzz-only-the-header-box-moved' -QR ''
    if ([object]::ReferenceEquals($p2.ByProj, $p3.ByProj)) {
        Fail 'changing ONLY the header search reused the grouping - $Q is not in the cache key'
    } else { Pass 'the header search alone invalidates it' }

    $p4 = Get-RailGrouping -Q '' -QR ''
    $script:modelGen++
    $p5 = Get-RailGrouping -Q '' -QR ''
    if ([object]::ReferenceEquals($p4.ByProj, $p5.ByProj)) {
        Fail 'changing ONLY the model reused the grouping - the generation is not in the cache key'
    } else { Pass 'the model alone invalidates it' }

    # 🪤 AND THE TWO BOXES ARE NOT INTERCHANGEABLE. The same string in the other
    # slot must give a different grouping, or the key is concatenating them into
    # something ambiguous.
    $g6 = Get-RailGrouping -Q 'mm' -QR ''
    $g7 = Get-RailGrouping -Q '' -QR 'mm'
    if ([object]::ReferenceEquals($g6.ByProj, $g7.ByProj)) {
        Fail 'the two search boxes share a slot in the cache key - one would serve the other its answer'
    } else { Pass 'the two search boxes are told apart in the key' }

    # 🔴 THE CACHED LISTS HOLD ROW REFERENCES, NOT COPIES - which is what lets a
    # tile's counts stay live while the grouping is reused. If they were copies,
    # a band the probe changed under the cache would be drawn stale.
    $gk = @($g1.ByProj.Keys)[0]
    $cgRow = $g1.ByProj[$gk][0]
    $cgIsLive = $false
    foreach ($m in $script:model) { if ([object]::ReferenceEquals($m, $cgRow)) { $cgIsLive = $true; break } }
    if (-not $cgIsLive) { Fail 'the grouping holds copies of the rows - a band changed by the probe would draw stale' }
    else { Pass 'the grouping holds the model rows themselves, so their counts stay live' }
} finally {
    $script:modelGen = $cgGenWas
    $script:railGroupKey = $cgKeyWas
    $script:railGroupBy = $null
    Build-Rail
}

# 🔑 THE INVARIANT THE WHOLE THING RESTS ON: assigning the model bumps the
# generation. Asserted on the source because it is about every assignment that
# exists, including ones a run does not reach - the startup-failure path sets an
# empty model and cannot bite today, which is exactly why a third assignment
# would be added without the bump.
$cgSrc = [regex]::Matches($winSrc, '(?m)^\s*\$script:model\s*=\s*[^\r\n]*')
if ($cgSrc.Count -lt 2) { Fail "found $($cgSrc.Count) model assignment(s) - this check can no longer see them" }
else {
    $cgBad = 0
    foreach ($m in $cgSrc) {
        $after = $winSrc.Substring($m.Index, [Math]::Min(240, $winSrc.Length - $m.Index))
        # The declaration at the top is the initial value, not a reassignment.
        if ($m.Value -match '=\s*@\(\)') { continue }
        if ($after -notmatch '\$script:modelGen\+\+') { $cgBad++ }
    }
    if ($cgBad) { Fail "$cgBad model assignment(s) do not bump the generation - a cache keyed on it would serve the previous model" }
    else { Pass "every model assignment bumps the generation ($($cgSrc.Count) found)" }
}

# ===========================================================================
Write-Host ''
Write-Host '--- the projects rail, in age bands you can fold ---'
# ===========================================================================
# 🔴 EVERY ONE OF THESE IS ABOUT SOMETHING BEING STRANDED. A rail that folds is
# a rail that can hide the project you were looking for, so the assertions are
# not "did it fold" - they are "is everything it folded still counted, still
# reachable, and still where its age says it should be".
$railShutWas = @{}
foreach ($k in @($script:railBandShut.Keys)) { $railShutWas[$k] = $true }
$railPickWas = $script:railPick
$railSortWas = $script:railSort

# 🔴 THE SUITE MUST NOT WRITE THE OPERATOR'S CONFIG, AND FOLDING A BAND QUEUES A
# SETTING. Toggle-RailBand hands 'railBandsShut' to Save-SRConfigLater and asks
# for a flush; the flush is a dispatcher callback, so it cannot run until this
# thread pumps - and this takes the value straight back off the queue before
# anything does. Nothing reaches the file, and the value it took is the evidence
# that the fold is remembered at all, so the safety and the assertion are the
# same line. Same reasoning as the config block further down, which redirects
# SR_ConfigPath for the tests that genuinely need a write.
$railCacheWas = $null
$railCacheHad = $false
try {
    if ($script:SR_ConfigCache -and $null -ne $script:SR_ConfigCache.PSObject.Properties['railBandsShut']) {
        $railCacheHad = $true; $railCacheWas = "$($script:SR_ConfigCache.railBandsShut)"
    }
} catch { }
function Pop-QueuedBandFold {
    if (-not $script:SR_ConfigPending.ContainsKey('railBandsShut')) { return $null }
    $v = "$($script:SR_ConfigPending['railBandsShut'])"
    $null = $script:SR_ConfigPending.Remove('railBandsShut')
    return $v
}

$script:railPick = $null
$script:railBandShut = @{}
$script:railSort = 'recent'
Build-Rail

$railItems = @($ui.RailList.ItemsSource)
$heads = @($railItems | Where-Object { $_.Kind -eq 'band' })
$bandTiles = @($railItems | Where-Object { $_.Kind -eq 'project' })
$bandKeys = @($script:RailBands | ForEach-Object { "$($_.Key)" })

if (-not $heads.Count) { Fail 'the rail draws no age band headings at all' }
else {
    $strayHead = @($heads | Where-Object { $bandKeys -notcontains "$($_.BandKey)" })
    if ($strayHead.Count) { Fail "a heading carries a band the rail does not define: $($strayHead[0].BandKey)" }
    else { Pass "the rail bands the projects: $((@($heads | ForEach-Object { '{0} {1}' -f $_.BandLabel, $_.BandCount })) -join ', ')" }

    # THE DECLARED ORDER, NEWEST FIRST. A band list that came out of a hashtable
    # would be in whatever order .NET felt like, and "Older" above "Today" is
    # the one arrangement that makes the whole feature pointless.
    $seenOrder = @($heads | ForEach-Object { "$($_.BandKey)" })
    $wantOrder = @($bandKeys | Where-Object { $seenOrder -contains $_ })
    if (($seenOrder -join '|') -ne ($wantOrder -join '|')) {
        Fail "the bands are drawn $($seenOrder -join ' > ') - newest is not first"
    } else { Pass "the bands run newest to oldest ($($seenOrder -join ' > '))" }
}

# 🔑 THE COUNT ON A HEADING IS WHAT MAKES FOLDING SAFE, so it is checked against
# the tiles actually under it rather than against itself.
$curBand = ''; $underHead = @{}
foreach ($it in $railItems) {
    if ($it.Kind -eq 'band') { $curBand = "$($it.BandKey)"; $underHead[$curBand] = 0; continue }
    if ($curBand) { $underHead[$curBand] = [int]$underHead[$curBand] + 1 }
}
$badCount = @($heads | Where-Object { [int]$_.BandCount -ne [int]$underHead["$($_.BandKey)"] })
if ($badCount.Count) {
    $b = $badCount[0]
    Fail "$($b.BandLabel) says $($b.BandCount) but $([int]$underHead["$($b.BandKey)"]) tile(s) follow it"
} else { Pass "every heading's count matches the tiles under it ($($bandTiles.Count) across $($heads.Count) band(s))" }

# 🔴 AND THE BAND IS THE ONE THE AGE SAYS. Recomputed here from the model with
# its own date arithmetic rather than by calling Get-RailBandKey - a test that
# asks the code under test what the answer is cannot disagree with it.
$midnight = [datetime]::Today
# 🪤 NO Test-OnSurface HERE, AND THAT IS THE POINT OF THE CHANGE. This mirrored
# the rail's old 24-hour filter, so once the rail started carrying every project
# it disagreed on 24 of 36 - reporting them as "last touched 1 Jan", which is
# [datetime]0, which is what an unset entry looks like. The rail bands every
# project the registry still has; so does this.
$newestOf = @{}
foreach ($r in $script:model) {
    $pp = "$($r.D.path)"
    if (-not $newestOf.ContainsKey($pp) -or [long]$r.At -gt [long]$newestOf[$pp]) { $newestOf[$pp] = [long]$r.At }
}
$curBand = ''; $misband = @()
foreach ($it in $railItems) {
    if ($it.Kind -eq 'band') { $curBand = "$($it.BandKey)"; continue }
    $when = [datetime]([long]$newestOf["$($it.Path)"])
    $wantBand = 'older'
    if     ($when -ge $midnight)               { $wantBand = 'today' }
    elseif ($when -ge $midnight.AddDays(-7))   { $wantBand = 'week' }
    elseif ($when -ge $midnight.AddDays(-30))  { $wantBand = 'month' }
    if ($wantBand -ne $curBand) { $misband += "$($it.Label) last touched $($when.ToString('d MMM')) sits in $curBand, not $wantBand" }
}
if ($misband.Count) { Fail "$($misband.Count) project(s) are in the wrong band: $($misband[0])" }
else { Pass "all $($bandTiles.Count) project(s) sit in the band their newest conversation puts them in" }

# 🔴 THE RAIL CARRIES EVERY PROJECT, WHICH IS THE WHOLE POINT OF THE BANDS.
# Against Test-OnSurface it held 12 of 36 - three bands could never fill, and a
# project quiet enough to be worth shelving had no tile to right-click. Counted
# against the registry rather than against a number, so it tracks the machine.
$railWant = @{}
foreach ($r in $script:model) { $railWant["$($r.D.path)"] = $true }
$railMissing = @($railWant.Keys | Where-Object { $bandTiles.Path -notcontains $_ })
if ($railMissing.Count) {
    Fail "$($railMissing.Count) project(s) the registry still has never reach the rail, first: $($railMissing[0])"
} else { Pass "every one of the $(@($railWant.Keys).Count) project(s) in the registry has a tile" }
if (@($railWant.Keys).Count -le 12) {
    Note 'this machine has 12 or fewer projects, so the widening cannot be told apart from the old behaviour here'
}

# 🪤 AND THE SESSIONS COLUMN DID NOT WIDEN WITH IT. Test-OnSurface has two other
# callers and its note explains why they must keep the 24-hour cut: a sessions
# column listing all 322 conversations is exactly what it prevents. The fix was
# rail-local, and this is what says so.
# 🔴 ASSERTED ON THE BUILT LIST, NOT ON A SOURCE GREP - and the grep failed on a
# CORRECT change, which is how it earned its replacement.
#
# This read the SOURCE of Build-Rail and Build-Sessions and looked for the string
# 'Test-OnSurface' in one and not the other. Two things are wrong with that, and
# this repo has now been bitten by both: a grep passes just as happily against a
# commented-out line or one moved somewhere it never runs, AND it cannot tell an
# INLINE from a deletion. The predicate was inlined into the filter loop because
# 327 calls to keep 52 rows was 17,9% of the whole rebuild - the rule was
# untouched and the grep went red anyway.
#
# So each claim is now asserted against the thing it is about:
#   - the rail is NOT gated - proved above, every project in the registry has a
#     tile, which a 24-hour gate would make impossible
#   - the sessions column IS gated - proved below, it never exceeds the count of
#     conversations Test-OnSurface itself keeps
#   - and the SELECTED conversation is pinned on even when it is cold, which is
#     the half of the rule an inline is most likely to drop and which neither of
#     the other two would notice.
#
# 🪤 THE PIN CHECK CHANGES EXACTLY ONE INPUT. It picks a row that is neither
# live nor warm, selects it, rebuilds, and rebuilds again with the selection
# cleared. Nothing else moves between the two builds, so the row appearing and
# then not appearing can only be $script:selId. A check that changed the model
# as well would rebuild for the wrong reason and still come out green.
$selWas = $script:selId
$cold = @($script:model.ToArray() | Where-Object { -not $_.Live -and -not $_.Warm })
if (-not $cold.Count) {
    # 🔴 A THIRD STATE, SPELLED OUT, because this suite has only Fail and Pass
    # and silence would read as green. If every conversation happens to be live
    # or warm when this runs, the rule was not exercised and that is not a pass.
    Note 'COULD NOT BE CHECKED THIS RUN: every conversation is live or warm, so the cold-pin rule was never exercised. It is NOT a pass.'
} else {
    $pinId = "$($cold[0].Id)"
    $script:selId = $pinId
    Build-Sessions
    $withPin = @($ui.SessionList.Items | Where-Object { $_.Kind -eq 'session' -and "$($_.Id)" -eq $pinId }).Count
    $script:selId = $null
    Build-Sessions
    $noPin = @($ui.SessionList.Items | Where-Object { $_.Kind -eq 'session' -and "$($_.Id)" -eq $pinId }).Count
    if ($withPin -eq 1 -and $noPin -eq 0) {
        Pass 'a cold conversation is on the surface only while it is selected - the pin is the only thing holding it'
    } else {
        Fail ('the selection pin is broken: a cold conversation drew {0} time(s) selected and {1} time(s) not' -f $withPin, $noPin)
    }
    $script:selId = $selWas
    Build-Sessions
}

$onSurface = @($script:model.ToArray() | Where-Object { Test-OnSurface $_ }).Count
$script:railPick = $null
Build-Sessions
$listRows = @($ui.SessionList.Items | Where-Object { $_.Kind -eq 'session' }).Count
if ($listRows -gt $onSurface) {
    Fail "the sessions column shows $listRows rows against $onSurface on the surface - it widened too"
} else { Pass "with no project picked the sessions column still shows only the $listRows on-surface conversation(s) of $($script:model.Count)" }

# 🔴 AND CLICKING AN OLDER PROJECT SHOWS ITS CONVERSATIONS. This is the gesture
# the widening exists for - "click on further-away filtered projects... and
# continue working on them if needed" - and before the pick-scoped lift it
# answered with an EMPTY LIST, because nothing in an old project is on surface.
$oldPick = $null
foreach ($it in @($ui.RailList.ItemsSource)) {
    if ($it.Kind -ne 'project') { continue }
    $kidsAll = @($script:model | Where-Object { "$($_.D.path)" -eq "$($it.Path)" })
    $kidsOn = @($kidsAll | Where-Object { Test-OnSurface $_ })
    if ($kidsAll.Count -and -not $kidsOn.Count) { $oldPick = $it; break }
}
if (-not $oldPick) { Note 'every project on this rail has something on the surface - the empty-list case cannot be posed' }
else {
    $script:railPick = "$($oldPick.Path)"
    Build-Sessions
    $oldRows = @($ui.SessionList.Items | Where-Object { $_.Kind -eq 'session' })
    $stray = @($oldRows | Where-Object { "$($_.Row.D.path)" -ne $script:railPick })
    if (-not $oldRows.Count) { Fail "filtering to '$($oldPick.Label)' shows nothing - the tile is there but leads to an empty list" }
    elseif ($stray.Count) { Fail "filtering to '$($oldPick.Label)' let $($stray.Count) conversation(s) from other projects through" }
    else { Pass "filtering to an older project shows its $($oldRows.Count) conversation(s), none of them on the surface" }
    $script:railPick = $null
    Build-Sessions
}

# FOLDING TAKES THE TILES AND LEAVES THE HEADING. Every heading stays on screen
# for the same reason the sessions column keeps all five: the count beside it is
# the reason to open it again, and a heading that folded itself away would have
# removed the only way back.
$foldable = @($heads | Where-Object { [int]$_.BandCount -gt 0 })
if (-not $foldable.Count) { Note 'no band holds a project, so folding cannot be posed' }
else {
    $victimBand = "$($foldable[0].BandKey)"
    $wasCount = [int]$foldable[0].BandCount
    Toggle-RailBand $victimBand
    $queued = Pop-QueuedBandFold
    if ($null -eq $queued) { Fail 'folding a band remembered nothing - it will be back open at the next restart' }
    elseif (@($queued -split ',') -notcontains $victimBand) {
        Fail "folding $victimBand queued '$queued', which does not name it"
    } else { Pass "folding a band queues it to be remembered ('$queued')" }
    $after = @($ui.RailList.ItemsSource)
    $leftIn = @($after | Where-Object { $_.Kind -eq 'project' -and "$($newestOf["$($_.Path)"])" -ne '' })
    $headsAfter = @($after | Where-Object { $_.Kind -eq 'band' })
    $stillThere = @($headsAfter | Where-Object { "$($_.BandKey)" -eq $victimBand })
    # Which tiles belonged to the folded band, decided by walking the OPEN build
    # above rather than by trusting the folded one.
    $curBand = ''; $wantGone = @()
    foreach ($it in $railItems) {
        if ($it.Kind -eq 'band') { $curBand = "$($it.BandKey)"; continue }
        if ($curBand -eq $victimBand) { $wantGone += "$($it.Path)" }
    }
    $survivors = @($leftIn | Where-Object { $wantGone -contains "$($_.Path)" })
    if (-not $stillThere.Count) { Fail "folding $victimBand took its own heading away - there is no way back to it" }
    elseif ([int]$stillThere[0].BandCount -ne $wasCount) {
        Fail "a folded band says $($stillThere[0].BandCount) instead of the $wasCount it is holding"
    }
    elseif ($survivors.Count) { Fail "$($survivors.Count) tile(s) survived their band being folded" }
    elseif ($headsAfter.Count -ne $heads.Count) { Fail "folding one band removed $($heads.Count - $headsAfter.Count) heading(s)" }
    else { Pass "folding $victimBand hides its $wasCount tile(s), keeps every heading, and still says how many are behind it" }

    # 🔴 AND THE PROJECT YOU ARE FILTERED TO IS NEVER FOLDED AWAY. The pick keeps
    # narrowing the sessions column whether or not its tile is drawn, so a folded
    # band that swallowed it would leave the list showing one project's
    # conversations with nothing on screen saying which.
    if (-not $wantGone.Count) { Note 'the folded band held nothing, so the pinned-pick case cannot be posed' }
    else {
        $script:railPick = $wantGone[0]
        Build-Rail
        $pinned = @($ui.RailList.ItemsSource | Where-Object { $_.Kind -eq 'project' -and "$($_.Path)" -eq $script:railPick })
        if (-not $pinned.Count) { Fail 'the project the rail is filtered to vanished into a folded band' }
        else { Pass 'a folded band still shows the project the rail is filtered to' }
        $script:railPick = $null
    }

    # UNFOLDING PUTS THEM BACK - the check above can only mean something if this
    # one passes too.
    Toggle-RailBand $victimBand
    $reopened = Pop-QueuedBandFold
    $back = @($ui.RailList.ItemsSource | Where-Object { $_.Kind -eq 'project' }).Count
    if ($back -ne $bandTiles.Count) { Fail "unfolding restored $back tile(s), not the $($bandTiles.Count) there were" }
    elseif (@("$reopened" -split ',') -contains $victimBand) {
        Fail "unfolding $victimBand still remembers it as folded ('$reopened')"
    } else { Pass "unfolding restores all $back tile(s), and stops remembering it as folded" }
}

# 🔴 A HEADING IS NOT A PROJECT. Its Path is '', and a SelectionChanged that let
# that through set railPick to an empty string - which matches nothing, so the
# sessions column filtered itself down to zero rows with no tile lit to say why.
# Driven through the real selection, not by calling the handler.
$script:railPick = $null
$ui.RailList.SelectedIndex = -1
Build-Rail
$headIx = -1
$railNow = @($ui.RailList.ItemsSource)
for ($i = 0; $i -lt $railNow.Count; $i++) { if ($railNow[$i].Kind -eq 'band') { $headIx = $i; break } }
if ($headIx -lt 0) { Note 'no heading to select' }
else {
    $ui.RailList.SelectedIndex = $headIx
    if ($null -ne $script:railPick) { Fail "selecting a band heading set the project filter to '$script:railPick'" }
    else { Pass 'selecting a band heading is not a project filter' }
    # And the inverse, so the assertion above cannot pass by nothing ever
    # setting railPick at all.
    $tileIx2 = -1
    for ($i = 0; $i -lt $railNow.Count; $i++) { if ($railNow[$i].Kind -eq 'project') { $tileIx2 = $i; break } }
    if ($tileIx2 -ge 0) {
        $ui.RailList.SelectedIndex = $tileIx2
        if (-not $script:railPick) { Fail 'selecting a project tile did NOT set the filter - the check above proves nothing' }
        else { Pass "selecting a project tile does set it ('$(Split-Path -Leaf $script:railPick)')" }
    }
}
$script:railPick = $railPickWas
$ui.RailList.SelectedIndex = -1
$script:railSort = $railSortWas
# Left OPEN for the blocks below, which all count tiles - see the note beside
# foldRail at the top. What is restored is the operator's own value, put back on
# the cache and the queue so nothing this block did can reach the file.
$script:railBandShut = @{}
$null = Pop-QueuedBandFold
try {
    if ($railCacheHad) { $script:SR_ConfigCache.railBandsShut = $railCacheWas }
    elseif ($script:SR_ConfigCache -and $null -ne $script:SR_ConfigCache.PSObject.Properties['railBandsShut']) {
        $script:SR_ConfigCache.PSObject.Properties.Remove('railBandsShut')
    }
} catch { }
if ($script:SR_ConfigPending.ContainsKey('railBandsShut')) {
    Fail 'the band block left a config write queued - it would reach the operator file'
} else { Pass 'the band block queued nothing that outlives it' }
Note ("the operator's own folded bands were '$(@($railShutWas.Keys | Sort-Object) -join ',')' and are unchanged")
Build-Rail; Build-Sessions

# ===========================================================================
Write-Host ''
Write-Host '--- shelving a project takes it off the rail, and says how many are away ---'
# ===========================================================================
# 🔴 THIS BLOCK NEVER CALLS Set-ProjectShelved ON THE REAL REGISTRY. Shelving writes
# through Save-SRRegistry, and this suite's rule is that it never saves - a rule
# that exists because a test wrote over the operator's registry on 2026-08-30 and
# cost them 210 conversations. So the DISPLAY half is driven by setting the field
# on the model's own directory object and putting it back, and the WRITE half is
# driven further down with SR_RegistryPath pointed at a sandbox. [[feedback-tests-reaching-live-data]]
$hideTiles = @($ui.RailList.ItemsSource | Where-Object { $_.Kind -eq 'project' })
if ($hideTiles.Count -lt 2) { Note "only $($hideTiles.Count) project(s) on the rail - hiding cannot be posed" }
else {
    $hideTilesWas = $hideTiles.Count
    $hideRow = @($script:model | Where-Object { "$($_.D.path)" -eq "$($hideTiles[0].Path)" })[0]
    $hideDir = $hideRow.D
    $hideLabel = "$($hideTiles[0].Label)"
    $hideFieldWas = $null
    $hideFieldHad = ($null -ne $hideDir.PSObject.Properties['shelved'])
    if ($hideFieldHad) { $hideFieldWas = $hideDir.shelved }
    $hideShowWas = $script:railShowShelved
    try {
        Set-Field $hideDir 'shelved' $true
        $script:railShowShelved = $false
        Build-Rail
        $hideNow = @($ui.RailList.ItemsSource | Where-Object { $_.Kind -eq 'project' })
        $hideStill = @($hideNow | Where-Object { "$($_.Path)" -eq "$($hideDir.path)" })
        if ($hideStill.Count) { Fail "'$hideLabel' is shelved and still on the rail" }
        elseif ($hideNow.Count -ne $hideTilesWas - 1) {
            Fail "shelving one project took $($hideTilesWas - $hideNow.Count) tile(s) off the rail"
        } else { Pass "shelving '$hideLabel' takes exactly it off the rail ($hideTilesWas -> $($hideNow.Count))" }

        # 🔑 AND THE RAIL SAYS SO. A list that silently drew fewer tiles would be
        # a list whose length cannot be trusted, and there would be no way back
        # to what it dropped.
        if ([int]$script:railShelved -ne 1) { Fail "the rail counted $($script:railShelved) shelved project(s), not 1" }
        elseif ("$($ui.RailShelved.Visibility)" -ne 'Visible') { Fail 'the rail shelves a project and says nothing about it' }
        elseif ("$($ui.RailShelved.Text)" -notmatch '1') { Fail "the header reads '$($ui.RailShelved.Text)' and does not say how many" }
        else { Pass "the rail header says '$($ui.RailShelved.Text)' rather than silently omitting it" }

        # SHOWING THEM AGAIN PUTS IT BACK, which is what makes shelving safe to try.
        $script:railShowShelved = $true
        Build-Rail
        $hideBack = @($ui.RailList.ItemsSource | Where-Object { $_.Kind -eq 'project' })
        $hideFound = @($hideBack | Where-Object { "$($_.Path)" -eq "$($hideDir.path)" })
        if (-not $hideFound.Count) { Fail 'showing shelved projects did not bring the shelved one back' }
        elseif ($hideBack.Count -ne $hideTilesWas) { Fail "showing them back gives $($hideBack.Count) tile(s), not $hideTilesWas" }
        else { Pass "'show shelved' puts all $hideTilesWas back, so nothing is ever stranded" }

        # The menu's one item has to read the way it will act. An item saying
        # "Shelve this project" over a shelved one would do the opposite of what
        # it says, which on this gesture is the whole risk.
        $verbHidden = Get-RailShelveVerb $hideDir
        Set-Field $hideDir 'shelved' $false
        $verbShown = Get-RailShelveVerb $hideDir
        if ($verbHidden -eq $verbShown) { Fail "the menu offers '$verbShown' whichever state the project is in" }
        elseif ($verbHidden -notmatch 'Put') { Fail "over a shelved project the menu offers '$verbHidden'" }
        elseif ($verbShown -notmatch 'Shelve') { Fail "over a visible project the menu offers '$verbShown'" }
        else { Pass "the one menu item reads the way it acts ('$verbShown' / '$verbHidden')" }
    } finally {
        if ($hideFieldHad) { Set-Field $hideDir 'shelved' $hideFieldWas }
        elseif ($null -ne $hideDir.PSObject.Properties['shelved']) { $hideDir.PSObject.Properties.Remove('shelved') }
        $script:railShowShelved = $hideShowWas
        Build-Rail
    }
    $hideAfter = @($ui.RailList.ItemsSource | Where-Object { $_.Kind -eq 'project' }).Count
    if ($hideAfter -ne $hideTilesWas) { Fail "the shelving block left the rail at $hideAfter tile(s), not the $hideTilesWas it found" }
    else { Pass "restored - the operator's registry was never touched, and the rail is back at $hideAfter" }
}

# 🔴 THE MENU MUST BE OURS, NOT WINDOWS'. Same reasoning as the manager's, and
# the same failure: a ContextMenu is outside the window's visual tree, so an
# implicit style in Window.Resources is not something to rely on reaching it -
# and the gesture underneath this one decides what comes back tomorrow morning.
$railCm = $ui.RailList.ContextMenu
if (-not $railCm) { Fail 'a project tile has no right-click menu, so there is no way to shelve one' }
elseif (-not $railCm.Style) { Fail "the rail's menu carries no style - it would render as a white Windows slab" }
elseif (-not @($railCm.Style.Setters | Where-Object { $_.Property.Name -eq 'Template' }).Count) {
    Fail "the rail menu's style sets no Template, so the OS chrome survives underneath it"
} else {
    $railItems = @($railCm.Items | Where-Object { $_ -is [System.Windows.Controls.MenuItem] })
    $railBare = @($railItems | Where-Object { -not $_.Style })
    if (-not $railItems.Count) { Fail 'the rail menu has no items' }
    elseif ($railBare.Count) { Fail "$($railBare.Count) rail menu item(s) carry no style - they would highlight in Windows blue" }
    else { Pass "the project tile's menu and its $($railItems.Count) item(s) are drawn by this window, not by Windows" }
}

# ===========================================================================
Write-Host ''
Write-Host '--- what the rail suggests shelving, and never does itself ---'
# ===========================================================================
# 🔴 THE SUGGESTION IS COMPUTED OVER THE WHOLE REGISTRY, NOT THE RAIL. The work
# surface is live-or-spoke-in-the-last-day, so every project the rail draws was
# touched within 24 hours and a project quiet for a fortnight is never a tile on
# it. A count taken from the rail's own contents would be permanently zero, and
# a green suite saying "0 suggested, correct" would be describing nothing.
$sugShelvedWas = @{}
foreach ($dsug in $script:dirs) {
    if ($null -ne $dsug.PSObject.Properties['shelved']) { $sugShelvedWas["$($dsug.path)"] = $dsug.shelved }
}
Update-ShelveSuggestions
$sugFound = @($script:shelveSuggestNames)
$sugDays = 14
try { $sugDays = [int]$script:cfg.shelveSuggestDays } catch { }
Note ("$($sugFound.Count) of $(@($script:dirs).Count) project(s) are quiet past $sugDays days with nothing running")

# 🔑 NOTHING WAS SHELVED BY LOOKING. The whole promise is that the tool points
# and the operator decides, so the pass that points must leave every flag as it
# found it - checked against a snapshot taken before it ran.
$sugTouched = @()
foreach ($dsug in $script:dirs) {
    $now2 = $(if ($null -ne $dsug.PSObject.Properties['shelved']) { $dsug.shelved } else { $null })
    $was2 = $(if ($sugShelvedWas.ContainsKey("$($dsug.path)")) { $sugShelvedWas["$($dsug.path)"] } else { $null })
    if ("$now2" -ne "$was2") { $sugTouched += "$($dsug.path)" }
}
if ($sugTouched.Count) { Fail "the suggestion pass SHELVED $($sugTouched.Count) project(s) by itself: $($sugTouched[0])" }
else { Pass "suggesting changed nothing - all $(@($script:dirs).Count) projects are exactly as they were" }

# AND EVERY PROJECT IT NAMES REALLY IS QUIET. Recomputed here off the registry
# with its own arithmetic, so a wrong threshold cannot agree with itself.
$sugWrong = @()
foreach ($dsug in $script:dirs) {
    if ($script:shelveSuggest.ContainsKey("$($dsug.path)")) {
        $alive = @(@($dsug.sessions) | Where-Object { -not $_.gone })
        $newest2 = [datetime]0
        foreach ($ssug in $alive) { try { $t2 = [datetime]$ssug.lastActive; if ($t2 -gt $newest2) { $newest2 = $t2 } } catch { } }
        # The halved threshold is the floor a worktree-only repo can reach, so a
        # candidate must be at least that quiet whatever lane it is in.
        $floor = [Math]::Max(1, [int][Math]::Ceiling($sugDays / 2.0))
        if (-not $alive.Count) { $sugWrong += "$($dsug.path) has no conversations left at all" }
        elseif ((([datetime]::Now - $newest2).TotalDays) -lt $floor) {
            $sugWrong += ("$($dsug.path) was touched $([int](([datetime]::Now - $newest2).TotalDays)) day(s) ago")
        }
        elseif ([bool]$dsug.shelved) { $sugWrong += "$($dsug.path) is already shelved" }
        elseif ([bool]$dsug.missing) { $sugWrong += "$($dsug.path) is missing, not quiet" }
    }
}
if ($sugWrong.Count) { Fail "$($sugWrong.Count) suggestion(s) are wrong: $($sugWrong[0])" }
else { Pass "every one of the $($sugFound.Count) suggestion(s) is a project that really has gone quiet" }

# 🔴 AND A CANDIDATE IS POSED, because the check above is VACUOUS WHEN NOTHING IS
# FOUND. Emptying the pass entirely - `foreach ($d in @())` - left this suite
# fully green: "every one of the 0 suggestions is correct" is true of a function
# that does nothing, and the rail assertion below then takes its "nothing to
# suggest" branch and says so too. Whether the operator's machine happens to
# hold a quiet project is not something a test may depend on, so one is put in
# front of the pass and taken away again. [[feedback-written-is-not-working]]
$sugDirsWas = $script:dirs
try {
    $sugFixture = [PSCustomObject]@{
        path = 'C:\posed\quiet-project'; enabled = $true; missing = $false
        sessions = @([PSCustomObject]@{
            sessionId = 'posedquiet01'; title = 'POSED'; enabled = $true; gone = $false; lane = 'main'
            lastActive = ([datetime]::Now.AddDays(-($sugDays + 5))).ToString('o')
        })
    }
    $script:dirs = @(@($sugDirsWas) + $sugFixture)
    Update-ShelveSuggestions
    if (-not $script:shelveSuggest.ContainsKey('C:\posed\quiet-project')) {
        Fail "a project quiet for $($sugDays + 5) days with nothing running was NOT suggested - the pass finds nothing"
    } else { Pass "a posed project quiet $($sugDays + 5) days is found, so the pass is really looking" }
} finally {
    $script:dirs = $sugDirsWas
    Update-ShelveSuggestions
}
$sugFound = @($script:shelveSuggestNames)

# THE RAIL SAYS IT, on a line of its own because it is speaking for projects it
# cannot draw.
$sugNamesWas = $script:shelveSuggestNames
$sugMapWas = $script:shelveSuggest
try {
    Build-Rail
    if ($sugFound.Count) {
        if ("$($ui.RailSuggest.Visibility)" -ne 'Visible') { Fail "$($sugFound.Count) project(s) could be put away and the rail says nothing" }
        elseif ("$($ui.RailSuggest.Text)" -notmatch "$($sugFound.Count)") {
            Fail "the rail reads '$($ui.RailSuggest.Text)' and does not say how many"
        }
        elseif ("$($ui.RailSuggest.ToolTip)" -notmatch [regex]::Escape("$($sugFound[0])")) {
            Fail "the rail counts them but names none - there is no way to find out which"
        } else { Pass "the rail says '$($ui.RailSuggest.Text)' and names them in its tooltip" }
    } else { Note 'nothing is quiet enough to suggest right now' }

    # AND SAYS NOTHING WHEN THERE IS NOTHING TO SAY. A 248px rail cannot afford
    # a line explaining the usual case - and without this the check above passes
    # on a control that is simply always visible.
    $script:shelveSuggestNames = @()
    $script:shelveSuggest = @{}
    Build-Rail
    if ("$($ui.RailSuggest.Visibility)" -eq 'Visible') { Fail 'the rail keeps a suggestion line with nothing to suggest' }
    else { Pass 'with nothing to suggest the line is gone, not empty' }

    # 🔴 AND A SUGGESTED PROJECT THAT IS ON THE RAIL CARRIES IT ON THE TILE. Rare
    # in practice for the reason above, so it is posed here rather than waited
    # for: the reason is put on a real rail project and the tile is read back.
    $sugTiles = @($ui.RailList.ItemsSource | Where-Object { $_.Kind -eq 'project' })
    if (-not $sugTiles.Count) { Note 'no tiles on the rail to mark' }
    else {
        $sugPath = "$($sugTiles[0].Path)"
        $sugPlain = "$($sugTiles[0].State)"
        $script:shelveSuggest = @{ $sugPath = 'nothing running, quiet 30 days' }
        $script:shelveSuggestNames = @('posed')
        Build-Rail
        $sugTile = @($ui.RailList.ItemsSource | Where-Object { $_.Kind -eq 'project' -and "$($_.Path)" -eq $sugPath })
        if (-not $sugTile.Count) { Fail 'the posed project left the rail' }
        elseif ("$($sugTile[0].State)" -notmatch 'shelved') {
            Fail "a suggested tile reads '$($sugTile[0].State)' - nothing on it says it could be shelved"
        }
        elseif (-not "$($sugTile[0].Tip)") { Fail 'the tile is marked but its tooltip does not say why' }
        elseif ("$($sugTile[0].State)" -eq $sugPlain) { Fail 'the marked tile reads exactly as the unmarked one did' }
        else { Pass "a suggested tile says so: '$($sugTile[0].State)'" }
        # The inverse: with the suggestion gone the tile goes back to what it said.
        $script:shelveSuggest = @{}
        Build-Rail
        $sugAgain = @($ui.RailList.ItemsSource | Where-Object { $_.Kind -eq 'project' -and "$($_.Path)" -eq $sugPath })
        if (@($sugAgain).Count -and "$($sugAgain[0].State)" -ne $sugPlain) {
            Fail "the mark did not come off: '$($sugAgain[0].State)' against '$sugPlain'"
        } else { Pass 'and it comes off again - the mark tracks the suggestion, not the tile' }
    }
} finally {
    $script:shelveSuggestNames = $sugNamesWas
    $script:shelveSuggest = $sugMapWas
    Build-Rail
}

# ===========================================================================
Write-Host ''
Write-Host '--- the project tiles ---'
# ===========================================================================
$ui.ModeWork.IsChecked = $true
Set-Surface 'work'
Build-Rail
Lay
$tiles = @($ui.RailList.ItemsSource | Where-Object { $_.Kind -eq 'project' })
if ($tiles.Count -lt 2) { Fail "the rail built $($tiles.Count) tile(s)" }
else {
    Pass "$($tiles.Count) project tiles"

    # A TILE HAS TO SAY WHAT IS HAPPENING IN THERE. It replaced a name and a
    # count, and a count is the same number whether every conversation is asleep
    # or one is waiting on you - which is the only thing the rail is for.
    $mute = @($tiles | Where-Object { -not "$($_.State)".Trim() })
    if ($mute.Count) { Fail "$($mute.Count) tile(s) say nothing about their state" }
    else { Pass 'every tile says what is happening inside it' }

    # 🔴 IDENTITY IS STABLE AND DISTINCT, or it is not identity. Derived from the
    # path, so it must survive a restart without being stored - and two projects
    # must not collide, which a naive character sum does for names as close as
    # AlgoTrader / AlgoTrader-tp / AlgoTrader-tps (all three are in this rail).
    $noAcc = @($tiles | Where-Object { -not $_.Accent })
    if ($noAcc.Count) { Fail "$($noAcc.Count) tile(s) have no identity colour at all" }
    else {
        # 🪤 THIS USED TO DEMAND SIX DISTINCT COLOURS ACROSS THE TILES ON SCREEN,
        # AND THAT IS NOT SOMETHING THE DESIGN PROMISES. The wheel has twelve
        # slots dealt by sorted index, so with twenty-seven projects two of them
        # WILL share a colour - the deliberate trade recorded in
        # Get-ProjectAccent, taken because a guaranteed spread beats a
        # probabilistic one. Which projects the rail happens to show is live
        # data, so the old assertion went red the first time two tiles twelve
        # apart appeared together, having said nothing about the code.
        #
        # What the design DOES promise, and what is checked here: the twelve
        # slots are twelve different colours, and names close enough to be
        # confused never land on the same one.
        $ring = @()
        foreach ($k in @($script:accentOrder | Select-Object -First 12)) {
            $ring += "$((Get-ProjectAccent $k).Color)"
        }
        $ringUniq = @($ring | Sort-Object -Unique)
        if ($ring.Count -and $ringUniq.Count -ne $ring.Count) {
            Fail "the wheel yields only $($ringUniq.Count) colours for $($ring.Count) slots - two slots are the same colour"
        } else { Pass "$($ringUniq.Count) distinct colours across the $($ring.Count) wheel slots" }

        # Two tiles may share a colour ONLY by wrapping the twelve-slot wheel.
        # Anything else - two projects at adjacent indices drawing the same
        # colour - would mean the dealing broke, and that is what this catches.
        # Counting distinct colours cannot tell the two apart, which is why the
        # expected number is DERIVED from the slots rather than assumed to be
        # the number of tiles.
        $all = @($script:accentOrder)
        $slots = @()
        foreach ($t in $tiles) {
            $at = [array]::IndexOf($all, "$($t.Path)".ToLower())
            if ($at -lt 0) { $at = 0 }
            $slots += ($at % 12)
        }
        $cols = @($tiles | ForEach-Object { "$($_.Accent.Color)" })
        $uniq = @($cols | Sort-Object -Unique)
        $wantUniq = @($slots | Sort-Object -Unique).Count
        if ($uniq.Count -ne $wantUniq) {
            Fail "$($tiles.Count) projects occupy $wantUniq wheel slots but draw $($uniq.Count) colours - the dealing is broken"
        } elseif ($uniq.Count -lt $tiles.Count) {
            Pass "$($uniq.Count) colours for $($tiles.Count) projects - $($tiles.Count - $uniq.Count) wrapped the twelve-slot wheel, as designed"
        } else { Pass "$($uniq.Count) distinct identity colours across $($tiles.Count) projects" }
    }
    # 🔴 AND IT MUST ACTUALLY BE ON SCREEN. The colours were right, distinct
    # and at full opacity while the bar was drawing at ZERO WIDTH - which no
    # amount of looking at a downscaled screenshot could settle. This walks the
    # realised container and measures the mark.
    $ui.RailList.UpdateLayout()
    # 🪤 THE FIRST ITEM IS NOT THE FIRST TILE ANY MORE. Index 0 is an age-band
    # heading, which carries a Transparent accent by design - so measuring index
    # 0 would look for a coloured mark in the one row that is supposed not to
    # have one, and this assertion would have gone red on a correct build.
    $tileIx = -1
    $railAll = @($ui.RailList.ItemsSource)
    for ($i = 0; $i -lt $railAll.Count; $i++) { if ($railAll[$i].Kind -eq 'project') { $tileIx = $i; break } }
    $c0 = $(if ($tileIx -ge 0) { $ui.RailList.ItemContainerGenerator.ContainerFromIndex($tileIx) } else { $null })
    if (-not $c0) { Fail 'the first tile has no realised container' }
    else {
        function Find-Mark { param($El)
            if ($El -is [System.Windows.Controls.Border]) {
                $bg = $El.Background
                if ($bg -is [System.Windows.Media.SolidColorBrush]) {
                    $col = $bg.Color
                    if ($col.A -gt 0 -and -not ($col.R -eq $col.G -and $col.G -eq $col.B)) { return $El }
                }
            }
            $n = [System.Windows.Media.VisualTreeHelper]::GetChildrenCount($El)
            for ($i = 0; $i -lt $n; $i++) {
                $hit = Find-Mark ([System.Windows.Media.VisualTreeHelper]::GetChild($El, $i))
                if ($hit) { return $hit }
            }
            return $null
        }
        $mark = Find-Mark $c0
        if (-not $mark) { Fail 'no coloured mark anywhere in the realised tile' }
        elseif ($mark.ActualWidth -le 0 -or $mark.ActualHeight -le 0) {
            Fail ("the identity mark lays out at $($mark.ActualWidth) x $($mark.ActualHeight) - it is invisible")
        } elseif ($mark.Opacity -le 0.05) {
            Fail "the identity mark is drawn at opacity $($mark.Opacity)"
        } else {
            Pass ("the mark is on screen: {0:N0} x {1:N0} px of {2}" -f $mark.ActualWidth, $mark.ActualHeight, $mark.Background.Color)
        }
    }
    $again = @($tiles | ForEach-Object { "$((Get-ProjectAccent $_.Path).Color)" })
    if (($again -join ',') -ne (@($tiles | ForEach-Object { "$($_.Accent.Color)" }) -join ',')) {
        Fail 'the same path produced a different colour on a second call - it would change every restart'
    } else { Pass 'the same project is the same colour every time it is asked' }

    # 🪤 AND IT MUST STAY A MARK, NOT A SURFACE. The operator asked for greyscale
    # and then for project identity; the two only coexist while hue is confined
    # to something small. If an accent ever becomes a tile background, the white
    # that means NEEDS YOU has to compete with it.
    $loud = @($tiles | Where-Object {
        $_.PickBg -and $_.PickBg.Color -and
        ($_.PickBg.Color.R -ne $_.PickBg.Color.G -or $_.PickBg.Color.G -ne $_.PickBg.Color.B) })
    if ($loud.Count) { Fail 'a tile background carries hue - state and identity are competing' }
    else { Pass 'tile surfaces stay grey; only the mark carries hue' }
}

# ===========================================================================
Write-Host ''
Write-Host '--- the prose under the answers ---'
# ===========================================================================
# 🔴 THE FIRST THING THE OPERATOR REPORTED, AND NOTHING TESTED IT. "I do not see
# the text that oftentimes is below the selectable answers" - the reasoning
# claude writes under each option, which is usually the only thing that tells
# the two options apart. It was built and never asserted, which is precisely the
# shape of the two features found dead this session: present in the markup,
# green in the suite, and never checked against what is on screen.
#
# Driven with a synthetic parse rather than a live conversation: a real one is
# whatever happens to be asking right now, which is nothing most of the time.
$fake = [PSCustomObject]@{
    Header   = 'it is asking'
    Question = 'Which way do you want this handled?'
    Options  = @('Add the allow rule', 'Keep digging for a proof', 'Leave it')
    Details  = @('One change, unblocks every lane.', 'Costs time and ends in the same place.', '')
    Footer   = 'Enter to confirm - Esc to go back'
    Multi    = $false
    Screen   = ''
}
Show-Ask $fake
$btns = @($ui.AskOptions.ItemsSource)
if ($btns.Count -ne 3) { Fail "the panel built $($btns.Count) buttons for 3 options" }
else {
    # An option's button is a Grid: the number in its own badge column, then a
    # stack holding the label and the reasoning under it.
    #
    # 🪤 THE NUMBER MOVED, AND IT STILL HAS TO BE THERE. It used to be the first
    # two characters of the label ("1.  Add the allow rule"); it is now a badge
    # in its own column, because it is the key the operator PRESSES and inline
    # it drifted away from the option it numbered on any option that wrapped.
    # The guarantee is unchanged and so is this test's job - only where it looks
    # changed. Reading the label alone would now pass a panel that numbers
    # nothing at all.
    $withProse = 0
    $labels = @()
    $badges = @()
    foreach ($b in $btns) {
        $cells = @($b.Content.Children)
        $badges += "$($cells[0].Child.Text)".Trim()
        $kids = @($cells[1].Children)
        $labels += "$($kids[0].Text)"
        if ($kids.Count -ge 2 -and "$($kids[1].Text)".Trim()) { $withProse++ }
    }
    if ($withProse -ne 2) {
        Fail "$withProse of the 3 options carry their reasoning underneath - two were given some"
    } else { Pass 'each option shows the reasoning written under it, and the one without stays bare' }
    if ("$($labels[0])" -ne 'Add the allow rule') {
        Fail "the first option reads '$($labels[0])' - it must carry claude's own words"
    } else { Pass "the options carry claude's own words, unprefixed" }
    if (($badges -join ',') -ne '1,2,3') {
        Fail "the badges read '$($badges -join ',')' - they must be the numbers the operator will type, in order"
    } else { Pass 'each option is numbered with the key that answers it' }
}
if ($ui.AskFooter.Visibility -ne $V_Show -or "$($ui.AskFooter.Text)" -ne 'Enter to confirm - Esc to go back') {
    Fail 'the footer that qualifies the whole question is not shown'
} else { Pass 'the footer under the buttons is shown when there is one' }

# And the inverse, or the assertion above would pass on a panel that always
# shows everything it has ever been given.
$bare = [PSCustomObject]@{
    Header = 'it is asking'; Question = 'Yes or no?'; Options = @('Yes', 'No')
    Details = @(); Footer = ''; Multi = $false; Screen = ''
}
Show-Ask $bare
if ($ui.AskFooter.Visibility -ne $V_Hide) { Fail 'the footer stays up for a question that has none' }
elseif (@(@(@($ui.AskOptions.ItemsSource)[0].Content.Children)[1].Children).Count -ne 1) {
    Fail 'an option with no reasoning still draws a second line'
} else { Pass 'a question with neither shows neither' }

# Clearing has to be complete: a stale question filed against a new answer is
# the defect the $lastAsk comment above this function was written for.
Show-Ask $null
if ($ui.AskBox.Visibility -ne $V_Hide) { Fail 'the ask panel stays up with nothing to ask' }
elseif ($script:lastAsk) { Fail 'the previous question is still on record after it was cleared' }
else { Pass 'nothing to ask clears the panel and the record together' }

# ===========================================================================
Write-Host ''
Write-Host '--- the panel drawing a real batched round ---'
# ===========================================================================
# 🔴 DRIVEN BY SCREENS CAPTURED OFF A REAL ROUND, not by a question built here
# to suit the panel. tests\screens\*.txt came off a sandboxed claude on
# 2026-08-30, one file per state. What the parser makes of them is asserted in
# the relay suite; this asserts what the PANEL makes of the parse.
$shotDir = Join-Path $SR_Root 'tests\screens'
function Get-AskShot { param([string]$Name)
    $p = Join-Path $shotDir $Name
    if (-not (Test-Path -LiteralPath $p)) { return $null }
    return (Invoke-SRParseScreenQuestion -Text ([System.IO.File]::ReadAllText($p)))
}

$roundFresh = Get-AskShot 'round-single-fresh.txt'
if (-not $roundFresh) { Fail 'the captured round did not parse, so the panel cannot be driven by it' }
else {
    Show-Ask $roundFresh
    # The strip: two arrows plus one chip per question.
    if ($ui.AskTabs.Visibility -ne $V_Show) { Fail 'a three-question round draws no tab strip' }
    else {
        $strip = @($ui.AskTabs.ItemsSource)
        if ($strip.Count -ne 5) { Fail "the strip has $($strip.Count) items - two arrows and three questions" }
        else { Pass 'a batched round draws a strip: back, one chip per question, on' }
        # 🔑 THE ARROWS ARE THE NAVIGATION, and they carry a DIRECTION rather
        # than a position - which is deliberate: the terminal marks the active
        # tab with colour, and the screen reader takes characters only.
        if ([int]$strip[0].Tag -ne -1 -or [int]$strip[$strip.Count - 1].Tag -ne 1) {
            Fail 'the two arrows do not carry back and forward'
        } else { Pass 'the arrows step the round back and forward, one question at a time' }
    }
    # 🔴 THE ROWS THE TUI ADDS ARE NOT BUTTONS. This is the hazard: ENTER on an
    # empty "Type something" DECLINES THE WHOLE ROUND, and it was being drawn as
    # option 4 of 5.
    $rBtns = @($ui.AskOptions.ItemsSource)
    if ($rBtns.Count -ne 3) { Fail "the panel drew $($rBtns.Count) option buttons - only the three real options may be buttons" }
    else { Pass 'type-something and chat-about-this are not offered as options to click' }
    $rLabels = @($rBtns | ForEach-Object { "$(@(@($_.Content.Children)[1].Children)[0].Text)" })
    if ($rLabels -contains 'Type something.' -or $rLabels -contains 'Chat about this') {
        Fail "a TUI row reached the buttons: $($rLabels -join ', ')"
    } else { Pass 'and neither of them is reachable by mistake from the option list' }
    # The editor gets a box of its own instead.
    if ($ui.AskFreeBox.Visibility -ne $V_Show) { Fail 'the question offers no way to answer in your own words' }
    elseif ("$($ui.AskFree.Text)") { Fail "the box is prefilled with '$($ui.AskFree.Text)' on a fresh question" }
    else { Pass 'answering in your own words gets a text box, empty until you type in it' }
}

# 🔑 WHAT YOU ALREADY CHOSE, on a question you have come back to.
$roundAns = Get-AskShot 'round-single-answered.txt'
if ($roundAns) {
    Show-Ask $roundAns
    $aBtns = @($ui.AskOptions.ItemsSource)
    $aBadge = @($aBtns | ForEach-Object { "$(@($_.Content.Children)[0].Child.Text)".Trim() })
    if (($aBadge -join ',') -ne "1,$([char]0x2714),3") {
        Fail "the badges read '$($aBadge -join ',')' - the one you chose carries a tick where its number was"
    } else { Pass 'revisiting an answered question, the option you chose is marked' }
    $doneTabs = @(@($ui.AskTabs.ItemsSource) | Where-Object { $_ -is [System.Windows.Controls.Border] })
    if ($doneTabs.Count -ne 3) { Fail "the strip drew $($doneTabs.Count) chips for a three-question round" }
    else { Pass 'the strip still names every question in the round' }
}

# 🔑 THE TEXT YOU TYPED, shown rather than remembered - the operator's own ask.
$roundTyped = Get-AskShot 'round-free-committed.txt'
if ($roundTyped) {
    Show-Ask $roundTyped
    if ("$($ui.AskFree.Text)" -ne 'my own words here') {
        Fail "the box shows '$($ui.AskFree.Text)' - it must show what was typed into that question"
    } else { Pass 'coming back to a question you answered in your own words, your words are there' }
    if ("$($ui.AskFreeLabel.Text)" -notlike '*YOUR OWN WORDS*') {
        Fail "the label reads '$($ui.AskFreeLabel.Text)'"
    } else { Pass 'and it says that is your answer, not a draft' }
}

# The inverse: text typed but never committed must NOT read as the answer.
$roundDraft = Get-AskShot 'round-free-typed.txt'
if ($roundDraft) {
    Show-Ask $roundDraft
    if ("$($ui.AskFreeLabel.Text)" -ne 'TYPED, NOT YET SENT') {
        Fail "an uncommitted draft is labelled '$($ui.AskFreeLabel.Text)'"
    } else { Pass 'text typed but not sent is labelled as a draft, not as the answer' }
}

# 🔑 THE REVIEW - how the whole round currently stands.
$roundRev = Get-AskShot 'round-review.txt'
if ($roundRev) {
    Show-Ask $roundRev
    if ($ui.AskReview.Visibility -ne $V_Show) { Fail 'the review tab shows no answers' }
    else {
        $revRows = @($ui.AskReview.ItemsSource)
        if ($revRows.Count -ne 2) { Fail "the review drew $($revRows.Count) row(s), the screen carries 2" }
        else { Pass 'the review shows every question with the answer it holds' }
        $revText = @($revRows | ForEach-Object { "$(@($_.Child.Children)[1].Text)" })
        if ($revText -notcontains 'Beta three, Beta one') {
            Fail "the review answers read '$($revText -join ' | ')'"
        } else { Pass 'including a multi-select answer, in the form the menu shows it' }
    }
}

# And a plain single question draws none of it - or every assertion above would
# pass on a panel that shows the round furniture unconditionally.
Show-Ask $bare
if ($ui.AskTabs.Visibility -ne $V_Hide) { Fail 'a question on its own still draws a round strip' }
elseif ($ui.AskFreeBox.Visibility -ne $V_Hide) { Fail 'a question with no editor row still offers one' }
elseif ($ui.AskReview.Visibility -ne $V_Hide) { Fail 'a question that is not a review still draws one' }
else { Pass 'a single question draws no strip, no editor and no review' }
Show-Ask $null

# ===========================================================================
Write-Host ''
Write-Host '--- the question card following the screen at 400 ms ---'
# ===========================================================================
# 🔴 THE CARD USED TO BE FED ONLY BY THE FIFTEEN-SECOND PROBE, which is the
# whole of "the questions are also not immediately updated". Invoke-AskPoll now
# reads the selected session's screen four times a second and redraws ONLY when
# the menu actually moved - and the signature that decides that is the one thing
# here that can fail quietly, in either direction:
#
#   too STABLE  the card freezes mid-round: the cursor moves on screen, the
#               signature does not, and nothing is ever redrawn again.
#   too VOLATILE  Show-Ask runs every 400 ms, replacing ItemsSource under the
#               operator's click and taking keyboard focus out of the list.
#
# Both are asserted, against the real captures rather than a built question.

$sigFresh = Get-AskSignature $roundFresh
if (-not $sigFresh) { Fail 'a real parsed question produced no signature at all' }
else { Pass 'a parsed question has a signature' }

# STABLE: the identical parse must not redraw.
$sigAgain = Get-AskSignature (Get-AskShot 'round-single-fresh.txt')
if ($sigAgain -ne $sigFresh) { Fail 'the same screen parsed twice gives two signatures - the card would redraw every tick' }
else { Pass 'the same screen twice is one signature - no redraw under the click' }

# MOVES WITH THE CURSOR. This is the freeze case, and it is the reason CursorAt
# is in the signature at all: walking a round changes nothing else about the
# question, so a signature built from the text alone would never move again.
$moved = Get-AskShot 'round-single-fresh.txt'
if ($moved) {
    $wasAt = [int]$moved.CursorAt
    $moved.CursorAt = $wasAt + 1
    if ((Get-AskSignature $moved) -eq $sigFresh) {
        Fail 'moving the cursor does not change the signature - the card would freeze mid-round'
    } else { Pass 'the cursor moving changes the signature' }
}

# MOVES WITH THE TICKS, from two real captures of the same multi-select menu
# before and after an option was ticked.
$mFresh  = Get-AskShot 'round-multi-fresh.txt'
$mTicked = Get-AskShot 'round-multi-ticked.txt'
if (-not $mFresh -or -not $mTicked) { Fail 'the multi-select captures did not parse' }
elseif ((Get-AskSignature $mFresh) -eq (Get-AskSignature $mTicked)) {
    Fail 'ticking an option does not change the signature - the ticks would never redraw'
} else { Pass 'ticking an option changes the signature' }

# 🔑 AND EVERY OTHER PATH THAT DRAWS THE CARD LEAVES THE LANE AGREEING WITH IT.
# The probe, the answer landing and a round move all call Show-Ask directly; if
# any of them left $askSig stale, the very next poll would redraw the identical
# menu - which is the focus-stealing failure above, arriving 400 ms after every
# answer instead of continuously.
Show-Ask $roundFresh
if ($script:askSig -ne $sigFresh) {
    Fail 'Show-Ask does not leave the poll signature matching what it drew - the next tick redraws it'
} else { Pass 'drawing the card from any path leaves the poll agreeing with it' }
Show-Ask $null
if ($script:askSig) { Fail 'clearing the card leaves a stale signature behind' }
else { Pass 'clearing the card clears the signature' }

# ===========================================================================
Write-Host ''
Write-Host '--- all three sends are off the UI thread, and none of them can answer by accident ---'
# ===========================================================================
# Answering went off the UI thread months ago; the round arrows and the typed
# answer never did, and they do the same shape of work - Invoke-SRRoundMove
# sends up to eight keys and reads the screen after EACH one. Both now go
# through Start-AskSend.

foreach ($fn in @('Invoke-AskMove', 'Invoke-AskTyped', 'Invoke-Answer', 'Invoke-Send', 'Invoke-Interrupt')) {
    if ($winSrc -notmatch [regex]::Escape("function $fn")) { Fail "$fn is gone"; continue }
    # The body, up to the next top-level function.
    $bodyIx = $winSrc.IndexOf("function $fn")
    $nextIx = $winSrc.IndexOf("`nfunction ", $bodyIx + 10)
    if ($nextIx -lt 0) { $nextIx = $winSrc.Length }
    $body = $winSrc.Substring($bodyIx, $nextIx - $bodyIx)
    # 🪤 COMMENTS OUT FIRST, and the first version of this test failed without
    # it: the extraction runs to the next `function`, so it swallows the comment
    # block sitting between two of them - and the note above Invoke-AskTyped
    # NAMES Invoke-SRAnswerTypedOnScreen while explaining why the order matters.
    # The assertion is about what the handler CALLS, not what the prose mentions.
    $body = (($body -split "`n") | ForEach-Object { ($_ -split '#', 2)[0] }) -join "`n"
    if ($body -notmatch 'Start-AskSend') { Fail "$fn does not go through Start-AskSend - it is still sending on the UI thread" }
    else { Pass "$fn hands its send to the lane" }
    # 🔴 AND NOTHING BLOCKING IS LEFT BEHIND IN IT. These are the three calls
    # that read another process's console; every one of them belongs in the
    # runspace, and one left in a click handler is a frozen window.
    $left = @()
    # 🔴 Send-SRSessionInput IS ON THIS LIST, and it is the one that mattered
    # most. Invoke-Send called it inline: Get-SRAgentStatus -Refresh spawns
    # `claude agents --json` (528-862 ms), then Start-Sleep 400 before the
    # ENTER - about 1.0-1.3 SECONDS of frozen window per press, excused in the
    # coverage map as "its gesture is a string trim".
    # 🔴 Send-SRInterrupt IS ON THIS LIST TOO. It reads Win32_Process before it
    # sends - a CIM call, which is the same shape of cost as the others and
    # would freeze the window on the one gesture whose whole point is to be
    # instant.
    foreach ($blocking in @('Invoke-SRRoundMove', 'Invoke-SRAnswerTypedOnScreen', 'Send-SRQuestionAnswer',
                            'Send-SRSessionInput', 'Send-SRInterrupt', 'Get-SRScreenQuestion')) {
        if ($body -match [regex]::Escape($blocking)) { $left += $blocking }
    }
    if ($left.Count) { Fail ("$fn still calls " + ($left -join ', ') + ' on the UI thread') }
    else { Pass "$fn does no console work on the thread that draws" }
}

# 🔴 THE ONE THAT WOULD BE SILENT AND IRREVERSIBLE. Both switches that dispatch
# a send used to put the option click in the `default` arm, which turns ANY
# unrecognised kind - including one misspelled at a call site - into a committed
# answer. Pressing "back" would answer the question, and nothing would say so.
$dispatchBad = 0
foreach ($m in [regex]::Matches($winSrc, 'default\s*\{[^}]*Send-SRQuestionAnswer')) { $dispatchBad++ }
if ($dispatchBad) { Fail "a send dispatch still answers in its default arm ($dispatchBad) - a mistyped kind would commit an answer" }
else { Pass 'no send dispatch answers by default - an unknown kind refuses instead' }

# ===========================================================================
Write-Host ''
# ===========================================================================
Write-Host ''
Write-Host '--- the escape hatch is offered only where somebody can take it ---'
# ===========================================================================
# 🔴 THE REFUSAL NAMED AN ACTION NOBODY COULD TAKE. "or send anyway" was in the
# message while none of the four callers passed -Force. The offer now lives in
# the composer's landing, which is the one caller with the operator in front of
# it - and it must NOT appear in the two that act across sessions nobody is
# watching, where forcing a sentence into a menu is the accident being prevented.
$fcSrc = Get-SRBodyOf $winSrc 'function Complete-AnswerLanded'
if (-not $fcSrc) { Fail 'Complete-AnswerLanded is gone' }
elseif ($fcSrc -notmatch 'Test-SRForceableRefusal') {
    Fail 'the send landing does not tell a forceable refusal from any other - it cannot offer the retry'
}
elseif ($fcSrc -notmatch 'Confirm-Action') {
    Fail 'the send landing retries without asking - forcing text into a menu must be the operator saying so'
}
elseif ($fcSrc -notmatch 'Start-AskSend[^\n]*-Force') {
    Fail 'the send landing asks, and then does not re-send forced - the offer is still a dead end'
} else { Pass 'the composer catches a forceable refusal, asks, and re-sends forced' }

# 🪤 AND IT CANNOT LOOP. A forced send skips both refusals so it can never come
# back forceable, but the guard says so rather than resting on that.
if ($fcSrc -notmatch '-not \$Force') {
    Fail 'the retry is not guarded on $Force - a refusal that survived forcing would ask again forever'
} else { Pass 'a send that was already forced never offers the retry again' }

# 🔴 AND THE BATCH PATHS STAY UNFORCED. This is the assertion that stops a
# future reader "finishing the job" by wiring -Force everywhere.
foreach ($fcFn in @('Invoke-Compact')) {
    $b = Get-SRBodyOf $winSrc "function $fcFn"
    if (-not $b) { Fail "$fcFn is gone"; continue }
    if ($b -match 'Send-SRSessionInput[\s\S]*?-Force') {
        Fail "$fcFn forces its send - nobody is watching that session, and forcing text into a menu is the accident the refusal exists to stop"
    } else { Pass "$fcFn never forces its send" }
}
# The broadcast queue is a timer body rather than a named function, so it is
# matched on the call itself.
$castCall = [regex]::Match($winSrc, 'Send-SRSessionInput -SessionId \$r\.Id -Text \$script:castMsg[\s\S]{0,240}')
if (-not $castCall.Success) { Fail 'the broadcast send has moved - this check can no longer see it' }
elseif ($castCall.Value -match '-Force') { Fail 'the broadcast queue forces its sends across every ticked conversation' }
else { Pass 'the broadcast queue never forces its sends' }

# ===========================================================================
Write-Host ''
Write-Host '--- interrupting a turn, and refusing to press Esc anywhere else ---'
# ===========================================================================
# 🔴 THE GATE IS THE WHOLE SAFETY ARGUMENT, so it is what gets tested. Every
# other send in this tool reads the screen before it commits, because every
# other send PICKS something and can check it picked the right thing. Esc picks
# nothing: on a running turn it stops the turn, at a prompt it clears the input
# box, and pressed twice it opens the rewind picker, which offers to revert
# CODE. There is nothing to verify after the fact, so the only thing standing
# between the button and that is Get-InterruptBlocker refusing.
#
# 🔴 AND NOTHING HERE PRESSES ANYTHING. Every case asks what the gate WOULD say,
# on fabricated rows; the suite's rule is that it never types into a real
# session, and this is the one gesture where breaking it would cost a turn of
# somebody's work. [[feedback-tests-reaching-live-data]]
function New-StopRow { param([string]$Status, [string]$Kind = 'interactive', $Pid_ = 4242)
    return [PSCustomObject]@{
        Id = 'stop-fixture'; Band = 'working'; Live = $true
        S = [PSCustomObject]@{ sessionId = 'stop-fixture'; title = 'STOP' }
        D = [PSCustomObject]@{ path = 'C:\p\stop' }
        A = $(if ($null -eq $Pid_) { $null } else {
                [PSCustomObject]@{ Pid = $Pid_; Status = $Status; Kind = $Kind; Name = 'STOP' } })
    }
}

$stopBusy = Get-InterruptBlocker (New-StopRow -Status 'busy')
if ($stopBusy) { Fail "a mid-turn conversation cannot be interrupted: '$stopBusy'" }
else { Pass 'a conversation that is mid-turn can be interrupted' }

# 🔑 AND EVERY OTHER STATE IS REFUSED. This is the inverse of Get-AskBlocker -
# a question can only be READ off a session that has stopped, an interrupt is
# only meaningful on one that has not - and the pair must never both allow.
$stopRefused = 0
foreach ($st in @('idle', 'waiting', 'summarising', 'unknown', '')) {
    $why = Get-InterruptBlocker (New-StopRow -Status $st)
    if (-not $why) { Fail "Esc would be sent to a conversation the probe calls '$st' - at a prompt that clears what is typed there" }
    else { $stopRefused++ }
}
if ($stopRefused -eq 5) { Pass 'every state but mid-turn is refused, so Esc never reaches a session sitting at its prompt' }

$stopAgent = Get-InterruptBlocker (New-StopRow -Status 'busy' -Kind 'agent')
if (-not $stopAgent) { Fail 'a background agent would be sent Esc - it has no console to press it in' }
else { Pass "a background agent is refused: '$stopAgent'" }

$stopDead = Get-InterruptBlocker (New-StopRow -Status 'busy' -Pid_ $null)
if (-not $stopDead) { Fail 'a conversation with no process would be sent Esc' }
else { Pass "a conversation that is not running is refused: '$stopDead'" }

$stopNone = Get-InterruptBlocker $null
if (-not $stopNone) { Fail 'with nothing selected the interrupt still goes ahead' }
else { Pass 'nothing selected is refused rather than acted on' }

# 🔴 AND THE TWO GATES DISAGREE ON EVERY ROW, which is the property that matters:
# if both ever allowed at once, the window would be offering to read a question
# off a session and to interrupt it in the same breath, and one of the two would
# be wrong about what it is looking at.
$stopBoth = @()
foreach ($st in @('busy', 'idle', 'waiting', 'summarising', 'unknown')) {
    $row = New-StopRow -Status $st
    if (-not (Get-InterruptBlocker $row) -and -not (Get-AskBlocker $row)) { $stopBoth += $st }
}
if ($stopBoth.Count) { Fail "both gates allow at once on status '$($stopBoth[0])' - one of them is reading the session wrong" }
else { Pass 'the interrupt gate and the question gate never both allow - they are opposites, on the same evidence' }

# THE BUTTON IS WIRED, and to the gated function rather than to the send.
if (-not $ui.PaneStop) { Fail 'there is no Interrupt button' }
else {
    $stopSrc = Get-SRBodyOf $winSrc 'function Invoke-Interrupt'
    if (-not $stopSrc) { Fail 'Invoke-Interrupt is gone' }
    elseif ($stopSrc -notmatch 'Get-InterruptBlocker') { Fail 'the Interrupt button sends without asking the gate' }
    elseif ($stopSrc -notmatch "Kind 'esc'") { Fail 'the Interrupt button does not send the esc kind' }
    else { Pass 'the Interrupt button asks the gate, then hands the key to the lane' }
}

# 🪤 ONE Esc, NEVER TWO. Two in one batch is the rewind gesture, which offers to
# revert CODE - so the primitive refuses a count rather than trusting a caller's
# arithmetic, and there is no way to ask it for two.
$escSrc = Get-SRBodyOf ([System.IO.File]::ReadAllText((Join-Path $SR_Root 'lib\_common.ps1'))) 'function Send-SRInterrupt'
if (-not $escSrc) { Fail 'Send-SRInterrupt is gone' }
elseif ($escSrc -notmatch '0x1B') { Fail 'Send-SRInterrupt no longer sends VK_ESCAPE' }
elseif (([regex]::Matches($escSrc, '0x1B')).Count -ne 1) { Fail 'Send-SRInterrupt sends Esc more than once - that is the rewind gesture' }
# 🪤 THE CHECK, NOT THE SPELLING. This used to look for the literal 'claude.exe',
# which left the file when the WMI guard was replaced: Win32_Process.Name is
# "claude.exe" but Process.ProcessName is "claude", so the new guard cannot
# contain that string and the assertion went red on a send path that had just
# become MORE careful, not less. It follows the call now. The helper's own
# behaviour - refuse a non-claude pid, accept a real one - is driven directly in
# tests\ask-spec.ps1, which is where that belongs: it can be called without
# typing into anybody's console, which is why it was extracted.
elseif ($escSrc -notmatch 'Test-SRClaudeProcess') { Fail 'Send-SRInterrupt types into a pid without checking it is still a claude' }
else { Pass 'the primitive sends exactly one Esc, and only into a process it has confirmed is claude' }

# ===========================================================================
Write-Host ''
Write-Host '--- the vitals strip, and the clock that must stay cheap ---'
# ===========================================================================
Build-Sessions
$chipRow = @($ui.SessionList.Items | Where-Object { $_.Kind -eq 'session' })
if (-not $chipRow.Count) { Fail 'no session to read vitals for' }
else {
    $ui.SessionList.SelectedItem = $chipRow[0]
    Update-Chips $chipRow[0].Row -Force
    $chipKids = @($ui.PaneChips.Children)
    if ($chipKids.Count -lt 2) {
        Fail "the strip drew $($chipKids.Count) chip(s) - model and context are unconditional"
    } else { Pass "$($chipKids.Count) chips: the strip is reading the transcript, not a placeholder" }

    # 🔴 THE PER-SECOND PATH MUST NOT READ THE TRANSCRIPT. Step-ChipClock runs
    # on the one-second follow tick. It used to call Get-SRSessionVitals, whose
    # cache is keyed on the file's size and mtime - and a LIVE session, the only
    # kind whose clock you watch, changes both constantly. So it missed the
    # cache every tick and re-parsed up to 600 KB through ConvertFrom-Json on
    # the UI thread, once a second, to advance a number it already had.
    #
    # Timing is the assertion because "did it open the file" is not observable
    # from here. A parse costs hundreds of milliseconds; a subtraction costs
    # microseconds.
    #
    # 🪤 THE THRESHOLD IS 500 ms FOR FIFTY TICKS, NOT 60. At 60 it measured
    # 12-24 ms with room to spare and STILL went red once on a loaded machine -
    # a flaky assertion, which is worse than none because the next red gets
    # assumed to be the same flake. The defect it guards costs 120 ms PER TICK,
    # so fifty of them would be six seconds: 500 ms still catches it with more
    # than a tenfold margin, and no amount of ordinary load reaches it.
    $clockMs = Ms { for ($ci = 0; $ci -lt 50; $ci++) { Step-ChipClock } }
    if ($clockMs -gt 500) {
        Fail ("50 clock ticks cost {0:N0} ms - it is re-reading the transcript, not doing arithmetic" -f $clockMs)
    } else { Pass ("50 clock ticks cost {0:N1} ms - arithmetic only" -f $clockMs) }

    # And the inverse, so the assertion above cannot pass by finding nothing:
    # the real read over the same conversation must be MEASURABLY dearer.
    $readMs = Ms { Update-Chips $chipRow[0].Row -Force }
    if ($readMs -le ($clockMs / 50)) {
        Fail ("a full vitals read cost {0:N1} ms, no more than one clock tick - the timing check above proves nothing" -f $readMs)
    } else { Pass ("a full read costs {0:N1} ms against {1:N2} ms a tick, so the cheap path is really the cheap one" -f $readMs, ($clockMs / 50)) }

    # 🔴 THE GIT CALL MUST RETURN, AND MUST LEAVE NOTHING BEHIND.
    #
    # Its first version read stdout to the end BEFORE WaitForExit, so the
    # timeout could never fire; measured 2026-08-30, two git processes sat at
    # zero CPU for twenty-two minutes with the caller blocked inside ReadToEnd,
    # and every further call leaked another pair. On the UI thread that is the
    # whole window frozen, permanently, the first time git is slow.
    #
    # Counting processes is the assertion that would have caught it: a call that
    # deadlocks leaves its child running, and one that times out correctly kills
    # it. Timing alone would not - the first version returned promptly whenever
    # git happened to be fast, which was every time it was tried by hand.
    # 🪤 OUR OWN CHILDREN, NOT EVERY git ON THE MACHINE. Counting them globally
    # went red at 16 -> 17 while twelve of the operator's own conversations were
    # running git of their own: a shared count cannot answer a question about
    # one process, and a flaky assertion is worse than none because the next red
    # gets waved through as the same noise. ParentProcessId makes it exact.
    function Get-MyGit {
        try { return @(Get-CimInstance Win32_Process -Filter "Name='git.exe'" -ErrorAction Stop |
                       Where-Object { $_.ParentProcessId -eq $PID }).Count }
        catch { return -1 }
    }
    $gitBefore = Get-MyGit
    $gitMs = Ms {
        for ($gi = 0; $gi -lt 4; $gi++) { $null = Get-SRWorkingDiff -Path (Split-Path -Parent $SR_LibDir) }
    }
    Start-Sleep -Milliseconds 400
    $gitAfter = Get-MyGit
    if ($gitBefore -lt 0 -or $gitAfter -lt 0) {
        Fail 'could not enumerate child processes, so the leak check proved nothing'
    } elseif ($gitAfter -gt $gitBefore) {
        Fail ("this process's own git children went {0} -> {1} - a call is leaving its child behind" -f $gitBefore, $gitAfter)
    } else { Pass ("4 working-tree reads in {0:N0} ms and no git child left behind" -f $gitMs) }
    if ($gitMs -gt 12000) {
        Fail ("4 working-tree reads took {0:N0} ms - the timeout is not bounding them" -f $gitMs)
    } else { Pass ('the working-tree read is bounded') }

    # 🔴 FOUR CHIPS THAT HAD NEVER ONCE RENDERED.
    #
    # shells, sub-agents, permission mode and effort are all CONDITIONAL - they
    # appear only when there is something to say. Every conversation on this
    # machine while the strip was being built had zero background shells, zero
    # sub-agents and no per-session model settings, so all four paths shipped
    # unexecuted and were reported as working on the strength of having been
    # written. Written is not working.
    #
    # The vitals reader is replaced for the length of this check rather than
    # waiting for a session to happen to be running a sub-agent: the thing under
    # test is the STRIP, and making it depend on live state is what let these
    # four go unseen in the first place.
    $chipOrigVitals = ${function:Get-SRSessionVitals}
    function Get-SRSessionVitals {
        param([string]$JsonlPath, $Session, [string]$WorkDir, [int]$MaxTailBytes = 600000, [switch]$NoDiff)
        return [PSCustomObject]@{
            Model = 'claude-opus-5'; Tokens = 184000; Window = 1000000; Branch = 'feat/rails'
            Shells = 2; Agents = 1; Remote = $true
            Effort = 'xhigh'; Mode = 'acceptEdits'; Elapsed = 570.0; TurnTokens = 40500
            Added = 166; Removed = 66; Ok = $true; TurnAt = ([datetime]::UtcNow.AddSeconds(-570))
        }
    }
    # 🔴 THE CONTEXT COMES OFF THE SCREEN NOW, so the screen is what this test
    # has to supply. It used to force Tokens/Window through the vitals, which is
    # exactly the path that was removed: both halves of it were wrong in ways
    # nobody could see - the window inferred from the count, the count stale
    # across a compact - so a chip built from it was a chip built from a guess.
    # Driving the real source keeps the assertion about the strip.
    $chipCtxWas = $script:rowScreen["$($chipRow[0].Row.Id)"]
    $null = Set-RowScreenSig -Id "$($chipRow[0].Row.Id)" -Shells 2 -Agents 1 -Effort 'xhigh' `
                             -CtxTokens 184000 -CtxWindow 1000000
    try {
        Update-Chips $chipRow[0].Row -Force
        $chipText = @()
        foreach ($chipEl in @($ui.PaneChips.Children)) {
            $stackEl = $chipEl.Child
            $words = @()
            foreach ($kid in @($stackEl.Children)) {
                if ($kid -is [System.Windows.Controls.TextBlock]) { $words += "$($kid.Text)" }
            }
            $chipText += ($words -join '')
        }
        $joined = ($chipText -join ' | ')
        foreach ($want in @(
            @('opus 5',        'the model it is replying with'),
            @('184k / 1,0M',   'context against the window it actually has'),
            @('feat/rails',    'the branch'),
            @('+166',          'lines added in the working tree'),
            @('66',            'lines removed'),
            @('remote control','Remote Control is on'),
            @('accept edits',  'the permission mode it was launched with'),
            @('xhigh effort',  'the thinking effort'),
            @('2 shells',      'background shells still running'),
            @('1 sub-agent',   'a sub-agent still running'),
            @('9m 30s',        'how long this turn has been going'),
            # 🪤 The separator is the CULTURE'S, not a dot. This machine is
            # de-DE and the string really is "40,5k"; hard-coding either form
            # makes the suite pass on one machine and fail on another for a
            # reason that has nothing to do with the code.
            @(('40' + [cultureinfo]::CurrentCulture.NumberFormat.NumberDecimalSeparator + '5k'),
                               'what the turn has written, to the half thousand')
        )) {
            if ($joined -notlike "*$($want[0])*") {
                Fail ("the strip does not show {0} - expected '{1}' in: {2}" -f $want[1], $want[0], $joined)
            } else { Pass ("the strip shows {0}" -f $want[1]) }
        }

        # And the inverse, or every assertion above would pass on a strip that
        # simply prints everything it is ever handed. Nothing running, nothing
        # configured: those four must go away again.
        function Get-SRSessionVitals {
            param([string]$JsonlPath, $Session, [string]$WorkDir, [int]$MaxTailBytes = 600000, [switch]$NoDiff)
            return [PSCustomObject]@{
                Model = 'claude-opus-5'; Tokens = 12000; Window = 200000; Branch = 'main'
                Shells = 0; Agents = 0; Remote = $false
                Effort = ''; Mode = ''; Elapsed = 4.0; TurnTokens = 0
                Added = -1; Removed = -1; Ok = $true; TurnAt = ([datetime]::UtcNow.AddSeconds(-4))
            }
        }
        # 🔴 THE SCREEN SOURCE HAS TO GO QUIET TOO. Effort, the shell and
        # sub-agent counts and the context now come off the session's own line,
        # so a strip built while that cache still holds the busy figures would
        # keep showing them - and this assertion, which exists to prove the
        # chips are conditional, would be proving nothing.
        $null = $script:rowScreen.Remove("$($chipRow[0].Row.Id)")
        Update-Chips $chipRow[0].Row -Force
        $quiet = @()
        foreach ($chipEl in @($ui.PaneChips.Children)) {
            $words = @()
            foreach ($kid in @($chipEl.Child.Children)) {
                if ($kid -is [System.Windows.Controls.TextBlock]) { $words += "$($kid.Text)" }
            }
            $quiet += ($words -join '')
        }
        $quietJoined = ($quiet -join ' | ')
        $leaked = @()
        foreach ($gone in @('shell', 'sub-agent', 'effort', 'accept edits', 'remote control', '+')) {
            if ($quietJoined -like "*$gone*") { $leaked += $gone }
        }
        if ($leaked.Count) {
            Fail ("a quiet session still shows {0} - the chips are unconditional: {1}" -f ($leaked -join ', '), $quietJoined)
        } else { Pass 'a session with nothing running and nothing configured shows none of those chips' }
    } finally {
        ${function:Get-SRSessionVitals} = $chipOrigVitals
        if ($chipCtxWas) { $script:rowScreen["$($chipRow[0].Row.Id)"] = $chipCtxWas }
        else { $script:rowScreen.Remove("$($chipRow[0].Row.Id)") }
    }
}

# ===========================================================================
Write-Host ''
Write-Host '--- the two new buttons in the pane header ---'
# ===========================================================================
# Show-Spawn ends in ShowDialog and would park this harness forever, so what is
# checked is everything up to the point of opening: that the button is there,
# that something is wired to it, and that the dialog can actually take the
# preset the handler passes. A handler calling Show-Spawn with a parameter it
# does not have would throw only when pressed - on the operator's machine.
if (-not $ui.PaneWorktree) { Fail 'there is no New on worktree button' }
elseif (-not $ui.PaneTools) { Fail 'there is no Steps button' }
else {
    Pass 'both new header buttons exist'

    $spawnParams = @((Get-Command Show-Spawn).Parameters.Keys)
    $missing = @(@('PresetDir', 'PresetWorktree') | Where-Object { $spawnParams -notcontains $_ })
    if ($missing.Count) {
        Fail ("Show-Spawn has no {0} parameter - the worktree button would throw when pressed" -f ($missing -join ' or '))
    } else { Pass 'the new-session dialog takes the project and the worktree tick the button passes it' }

    
# 🔴 THE SIGN-IN MUST NOT CREATE A CONVERSATION. `claude /login` starts an
# interactive session and types a slash command into it, so every press left a
# real transcript behind - found by tracing a nameless, blank, "live"
# conversation back to this morning's sign-in. In a tool that decides which
# conversations reopen at logon, manufacturing one per sign-in is a defect that
# compounds: each ghost is a candidate for tomorrow's restore.
# 🪤 STRIP THE COMMENTS FIRST - and this assertion failed on its own
# explanation the moment it was written, which is the trap this suite already
# carries a warning about further down. The comment above the fix NAMES the
# broken command, so a raw match on the file finds it forever.
$signSrc = ((Get-Content -LiteralPath (Join-Path $SR_LibDir 'sessions-window.ps1') -Encoding UTF8) |
            Where-Object { -not ($_.TrimStart().StartsWith('#')) }) -join "`n"
if ($signSrc -match "claude\s+/login") {
    Fail 'the Sign in button runs `claude /login`, which starts a conversation and leaves a transcript behind'
} elseif ($signSrc -notmatch "claude\s+auth\s+login") {
    Fail 'the Sign in button does not run `claude auth login` - the only form that signs in without creating a session'
} else {
    Pass 'the Sign in button uses `claude auth login`, which leaves no conversation behind'
}

$wireSrc = Get-Content -LiteralPath (Join-Path $SR_LibDir 'sessions-window.ps1') -Raw -Encoding UTF8
    foreach ($wire in @(
        @('$ui.PaneWorktree.Add_Click', 'the worktree button'),
        @('$ui.PaneTools.Add_Click',    'the steps button'))) {
        if ($wireSrc -notmatch [regex]::Escape($wire[0])) {
            Fail ("{0} has nothing wired to it" -f $wire[1])
        } else { Pass ("{0} is wired" -f $wire[1]) }
    }

    # The label has to agree with the setting, or the button lies about the
    # state it is in - and it is the only thing on screen that reports it.
    foreach ($view in @('folded', 'full', 'hidden')) {
        $script:toolView = $view
        $lbl = Get-ToolViewLabel
        if ($lbl -notlike "*$view*") { Fail "with toolView '$view' the button reads '$lbl'" }
        else { Pass "the steps button reads '$lbl' when the pane is $view" }
    }
    $script:toolView = 'folded'
}

# ===========================================================================
Write-Host ''
Write-Host '--- selecting a conversation must not read its vitals ---'
# ===========================================================================
# 🔴 THE CLICK IS THE ONE INTERACTION ALREADY REPORTED AS LAGGY, and reading the
# vitals costs ~120 ms of JSONL parsing plus a git call. Show-Selected clears
# the strip; the one-second follow tick fills it. This asserts BOTH halves,
# because either alone is a bug: clearing without filling leaves a permanently
# empty header, and filling on the click is the cost this avoids.
Build-Sessions
$clickRows = @($ui.SessionList.Items | Where-Object { $_.Kind -eq 'session' })
if ($clickRows.Count -lt 2) { Fail 'need two conversations to test selecting between them' }
else {
    $ui.SessionList.SelectedItem = $clickRows[0]
    $script:selId = $null
    Show-Selected
    if ($script:chipVitals) {
        Fail 'selecting a conversation read its vitals - that is 120 ms and a git call on the click path'
    } elseif (@($ui.PaneChips.Children).Count -ne 0) {
        Fail "the strip kept $(@($ui.PaneChips.Children).Count) chip(s) from the conversation you just left"
    } else { Pass 'the click clears the strip and reads nothing' }

    Invoke-FollowTick
    if (-not $script:chipVitals -or @($ui.PaneChips.Children).Count -eq 0) {
        Fail 'and then nothing filled it - the header would stay empty forever'
    } else { Pass "one tick later the strip is back, with $(@($ui.PaneChips.Children).Count) chips" }
}

# ===========================================================================
Write-Host ''
Write-Host '--- a session mid-turn is never asking you anything ---'
# ===========================================================================
# 🔴 THE QUESTION IS READ OFF THE SESSION'S SCREEN, and a screen mid-reply is
# full of whatever is being written. Measured on a real session: a reply
# containing "1. The failure is now a carried rule / 2. The registration commit
# / 3. The lane is resumed" was read as a three-option menu and drawn as a
# question, with the prose as its options - and nothing was selectable, because
# nothing was a menu. Three paths could do it and only one had a guard.
foreach ($busyCase in @(
    @{ n = 'busy';  status = 'busy';  want = $false },
    @{ n = 'idle';  status = 'idle';  want = $true })) {
    $fakeRow = [PSCustomObject]@{ A = [PSCustomObject]@{ Pid = 4242; Status = $busyCase.status } }
    $got = [bool](Test-AskAllowed $fakeRow)
    if ($got -ne $busyCase.want) {
        Fail ("a {0} session: asking allowed = {1}, expected {2}" -f $busyCase.n, $got, $busyCase.want)
    } else { Pass ("a {0} session {1} have its screen read for a question" -f $busyCase.n, $(if ($busyCase.want) { 'may' } else { 'may not' })) }
}
if (Test-AskAllowed $null) { Fail 'a missing row still allows a screen read' }
else { Pass 'nothing selected is never asking' }
if (Test-AskAllowed ([PSCustomObject]@{ A = $null })) { Fail 'a conversation with no process still allows a screen read' }
else { Pass 'a conversation that is not running is never asking' }

# ===========================================================================
Write-Host ''
Write-Host '--- clicking a waiting conversation leaves it in NEEDS YOU ---'
# ===========================================================================
# 🪤 THE WATCHER BROKE THIS AND THE EXISTING ASSERTION DID NOT NOTICE. The
# follow tick reads a null followStamp as "first look at what you just
# selected" and refuses to call the difference growth. The 100 ms write lane
# then started filling that stamp in before the tick ever ran, so the next tick
# saw a changed stamp with firstLook false and moved the row - reported as
# clicking V-INGEST in NEEDS YOU and watching it jump to WORKING. The other
# assertion still passed because it tests growth AFTER a first look.
Build-Sessions
$needRow = @($ui.SessionList.Items | Where-Object { $_.Kind -eq 'session' -and $_.Row.Band -eq 'needs' })
if (-not $needRow.Count) { Pass 'nothing is waiting on you right now, so there is nothing to click (not a failure)' }
else {
    $ui.SessionList.SelectedItem = $needRow[0]
    $script:selId = $null
    $script:followStamp = $null
    Show-Selected
    # The write lane fires before the one-second tick gets its first look.
    $script:transcriptDirty = $true
    Invoke-WriteLane
    if ($null -ne $script:followStamp) {
        Fail 'the write lane filled in the follow stamp before the tick had looked - a click will move the row'
    } else { Pass 'the write lane leaves the first look to the tick' }
    $bandWas = "$($needRow[0].Row.Band)"
    Invoke-FollowTick
    if ("$($needRow[0].Row.Band)" -ne $bandWas) {
        Fail ("selecting a waiting conversation moved it from {0} to {1}" -f $bandWas, $needRow[0].Row.Band)
    } else { Pass 'selecting a waiting conversation leaves it where you clicked it' }
}

# ===========================================================================
Write-Host ''
Write-Host '--- the ask probe, against a real console ---'
# ===========================================================================
# 🔴 THIS IS THE PATH THAT SHOWED NOTHING FOR FIFTEEN SECONDS. The question used
# to ride on the heavy probe - which refreshes the registry and spawns claude
# before it ever reaches the screen read - on the one surface whose whole
# purpose is showing what is waiting on you. It now has its own runspace, and
# unit assertions cannot tell whether that runspace actually returns a question:
# only a real console can.
#
# 🪤 The replica is spawned MINIMIZED and killed in a finally, the same shape
# the relay suite has used since it was written. A test that leaves a console on
# the operator's desktop is a test that gets switched off.
$askReplica = Join-Path $SR_Root 'tests\menu-replica.ps1'
if (-not (Test-Path -LiteralPath $askReplica)) { Fail 'menu-replica.ps1 is missing, so the ask probe cannot be driven' }
else {
    Build-Sessions
    $probeItem = @($ui.SessionList.Items | Where-Object { $_.Kind -eq 'session' })[0]
    $askOut = Join-Path $SR_StateDir ('askprobe-' + [Guid]::NewGuid().ToString('N').Substring(0, 6) + '.txt')
    $askProc = $null
    # The row is pointed at the replica for the length of this check and put
    # back afterwards: the probe reads whatever process the selected row names,
    # and building a row it would not accept would test a different thing.
    $savedPid = $null; $savedStatus = $null; $hadA = $false
    try {
        $askProc = Start-Process -FilePath 'powershell.exe' -PassThru -WindowStyle Minimized -ArgumentList @(
            '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $askReplica,
            '-Out', $askOut, '-Cursor', '0', '-TimeoutSeconds', '120',
            '-StatusLine', '"^^ auto mode on . 3 shells . <- for agents"')

        $ui.SessionList.SelectedItem = $probeItem
        $script:selId = "$($probeItem.Id)"
        if ($probeItem.Row.A) {
            $hadA = $true
            $savedPid = $probeItem.Row.A.Pid
            $savedStatus = $probeItem.Row.A.Status
            $probeItem.Row.A.Pid = $askProc.Id
            $probeItem.Row.A.Status = 'idle'
        } else {
            $probeItem.Row | Add-Member -NotePropertyName A -NotePropertyValue ([PSCustomObject]@{ Pid = $askProc.Id; Status = 'idle' }) -Force
        }

        # Poll the way the window does - start the probe, collect on the lane -
        # rather than sleeping a guess. Generous, because each screen read is a
        # child process with its own budget and this machine runs many.
        $askSw = [Diagnostics.Stopwatch]::StartNew()
        $askGot = $null
        $script:screenShells = -1
        while ($askSw.Elapsed.TotalSeconds -lt 60) {
            if (-not $script:askPs) { Start-AskProbe $probeItem.Row }
            Start-Sleep -Milliseconds 200
            Complete-AskProbe
            if ($script:lastAsk -and @($script:lastAsk.Options).Count -ge 2) { $askGot = $script:lastAsk; break }
        }
        $askSw.Stop()
        if (-not $askGot) {
            Fail 'the ask probe never returned a question from a console that was showing one'
        } else {
            Pass ("the ask probe read a {0}-option menu off a real console in {1:N1}s" -f @($askGot.Options).Count, $askSw.Elapsed.TotalSeconds)
            if ($ui.AskBox.Visibility -ne $V_Show) { Fail 'the question came back and the panel stayed hidden' }
            else { Pass 'and the panel is on screen' }
            # 🪤 THE COUNT IS NOT ASSERTED HERE, and that is deliberate rather
            # than a gap. It came back -1 intermittently in this harness while
            # reading the very same screen parses correctly on demand
            # (shells=3), which points at two screen reads racing for one
            # console rather than at the parse. The relay suite proves the count
            # against a real console with nothing else contending for it, which
            # is the stronger test - and duplicating it here with a race in it
            # would only teach us to ignore a red.
        }

        # 🔴 WHAT ANSWERING ACTUALLY COSTS, and it is not a gesture budget.
        # Pressing an option calls Send-SRQuestionAnswer, which reads the
        # session's SCREEN again to find the cursor before it sends a single
        # key - a child process with a three-second budget. The button returns
        # instantly; the answer does not leave until that read comes back, and
        # nothing measured it. Timed here as the read alone, because sending
        # keys into a console is the one thing this suite may never do.
        $ansBest = [double]::MaxValue
        foreach ($ap in 1..5) {
            $asw = [Diagnostics.Stopwatch]::StartNew()
            $atxt = Get-SRScreenText -ProcessId $askProc.Id
            if ($atxt) { $null = Invoke-SRParseScreenQuestion -Text $atxt }
            $asw.Stop()
            if ($atxt -and $asw.Elapsed.TotalMilliseconds -lt $ansBest) { $ansBest = $asw.Elapsed.TotalMilliseconds }
        }
        if ($ansBest -eq [double]::MaxValue) { Fail 'the screen could not be read at all, so answering cannot be timed' }
        else {
            Pass ("answering pays a {0:N0} ms screen read before the keys leave" -f $ansBest)
            # 🔴 250 ms, DOWN FROM A SECOND, BECAUSE IT NOW COSTS 66. The read
            # was 560 ms while it compiled C# on every call; compiled once into
            # an exe it is tens of milliseconds. A budget left at a second would
            # have let that regress the whole way back without a word - the
            # budget has to follow the measurement or it stops being one.
            if ($ansBest -gt 250) {
                Fail ("answering waits {0:N0} ms on a screen read - the reader is being compiled per call again" -f $ansBest)
            } else { Pass 'the answer leaves in well under a quarter second' }
        }

        # 🔴 THE QUIET CHECK, against the same real console. Working -> needs you
        # was the slowest transition in the tool: it came from the agent probe,
        # which spawns claude, so a conversation could sit in WORKING for fifteen
        # seconds after it had stopped and asked. A transcript that has stopped
        # growing plus one 66 ms screen read answers it in about three.
        $qRow = $probeItem.Row
        $qBandWas = "$($qRow.Band)"
        $script:quietSince["$($qRow.Id)"] = (Get-Date).AddSeconds(-30)
        $script:quietChecked = @{}
        $qRow.Band = 'working'
        try {
            $qsw = [Diagnostics.Stopwatch]::StartNew()
            $qMoved = $false
            # 🪤 THE BAND IS THE ASSERTION, NOT THE RETURN VALUE. Complete-QuietCheck
            # answers "does the list need redrawing", and it now says yes for the
            # OTHER thing it files - what the session printed about its shells and
            # sub-agents. Looping on the return therefore stopped on the first
            # completed read of any session and then asked why this row had not
            # moved. What is under test is where this row ended up.
            while ($qsw.Elapsed.TotalSeconds -lt 30 -and -not $qMoved) {
                if (-not $script:quietPs) { Start-QuietCheck }
                Start-Sleep -Milliseconds 100
                $null = Complete-QuietCheck
                if ("$($qRow.Band)" -eq 'needs') { $qMoved = $true }
            }
            $qsw.Stop()
            if (-not $qMoved) { Fail 'a quiet session showing a menu was never moved into NEEDS YOU' }
            elseif ("$($qRow.Band)" -ne 'needs') { Fail "the quiet check moved the row to '$($qRow.Band)' rather than needs" }
            else { Pass ("a quiet session showing a menu reaches NEEDS YOU in {0:N1}s" -f $qsw.Elapsed.TotalSeconds) }

            # 🪤 AND IT MAY ONLY EVER MOVE INTO 'needs'. Claiming a conversation
            # wants you is a claim that has to be measured - the same rule the
            # follow tick states for the opposite direction. A row that is NOT
            # working must be left exactly where it is, whatever the screen says.
            # 🔴 THROUGH Test-QuietVerdict, WITH Asking=$true. Driven through
            # Complete-QuietCheck with no job in flight, these three passed
            # because the collector returns at its first line when there is
            # nothing to collect - the rule was never reached and the green
            # could not go red. The verdict is its own function so a real
            # positive can be handed to it.
            $qRow.Band = 'working'
            if (-not (Test-QuietVerdict -Row $qRow -Asking $true) -or "$($qRow.Band)" -ne 'needs') {
                Fail 'a WORKING row shown a menu was not moved into needs - the positive case does not fire'
            } else { Pass 'a working row shown a menu is moved into needs' }

            # ===============================================================
            # 🔴 AND A RECOMPUTE MUST AGREE, NOT OVERRULE. This is the flap the
            # operator reported: a conversation flipping between NEEDS YOU and
            # WORKING every few seconds. The band is DERIVED, so writing
            # $r.Band = 'needs' after the fact was undone by the next Get-Band -
            # and the agent probe says 'working' for a session sitting on a
            # menu, so the two took turns forever. The screen's answer is an
            # INPUT now, and this is the assertion that says so.
            # ===============================================================
            # 🪤 THE UNDERLYING STATE IS PINNED TO 'working' FOR THIS, or the
            # assertion proves nothing: this row's real Conv says waiting, so
            # Get-Band would answer 'needs' whatever the flag held and the test
            # would pass without the fix. The whole question is what happens
            # when the probe says WORKING and the screen says otherwise.
            $qConvWas = $qRow.Conv
            $qSaidWas = $qRow.Said
            $qRow.Conv = [PSCustomObject]@{ State = 'working'; Needs = $false; Stuck = $false; Stale = $false }
            if ((Get-Band $qRow) -ne 'needs') {
                Fail "a recompute puts the row back to '$(Get-Band $qRow)' - the screen's verdict does not survive it"
            } else { Pass 'recomputing the band agrees with the menu that was seen, rather than overruling it' }
            # Cleared by evidence: keys were delivered, so it is not asking now.
            $null = Set-AskSeen -Id "$($qRow.Id)" -Asking $false
            if ((Get-Band $qRow) -ne 'working') {
                Fail "the row derives as '$(Get-Band $qRow)' after the menu was answered - the flag stuck"
            } else { Pass 'and once the menu is gone the recompute lets it leave, so the flag cannot stick' }
            # ===================================================================
            # 🔴 REVERSED ON PURPOSE, AND REWRITTEN RATHER THAN DELETED.
            #
            # These four used to assert that a done / idle / quiet row is never
            # dragged into needing you by the ask flag - only a WORKING one could
            # move. That rule was right when it was written and it was
            # compensating for a specific weakness: the parser could not tell an
            # ordinary numbered list from a live menu, so "the screen shows a
            # menu" was not trustworthy evidence and the band was used as a
            # second opinion to contain the damage.
            #
            # The structural test removed the weakness - 13 of 13 fixtures
            # against the old cursor gate's 10, and exact agreement with
            # `claude agents --json` over 30 live consoles - and the containment
            # then cost more than it saved. A row the 15 s probe last called idle
            # or done was FORBIDDEN to move, so noticing fell through to that
            # probe, which measures 11.3 s on a 15 s timer: a worst case near
            # 26 s, on exactly the rows most likely to be asking, because a
            # session that has just gone quiet is the one about to want you.
            #
            # So the assertions now describe the new rule, in both directions -
            # what may move, and the one thing that still may not.
            # ===================================================================
            $qLiveWas = $qRow.Live
            $qRow.Live = $true
            $null = Set-AskSeen -Id "$($qRow.Id)" -Asking $true
            $qRow.Said = $null
            foreach ($liveState in @('idle', 'working')) {
                $qRow.Conv = [PSCustomObject]@{ State = $liveState; Needs = $false; Stuck = $false; Stale = $false }
                if ((Get-Band $qRow) -ne 'needs') {
                    Fail ("a live '{0}' conversation with a menu on screen derives as '{1}' - the operator would not see it" -f $liveState, (Get-Band $qRow))
                } else { Pass ("a live '{0}' row with a menu actually seen derives as needing you" -f $liveState) }
            }
            # 🪤 AND 'quiet' IS STILL EXCLUDED - the half that did NOT change,
            # and it is a fact rather than a policy. Get-Band reaches quiet for a
            # conversation that is stuck, stale, or has no process at all, none
            # of which has a screen a menu could have been seen on, so a flag
            # surviving on one is stale by definition.
            $qRow.Conv = [PSCustomObject]@{ State = 'idle'; Needs = $false; Stuck = $true; Stale = $false }
            if ((Get-Band $qRow) -eq 'needs') {
                Fail 'a stuck conversation was dragged into needing you by the ask flag'
            } else { Pass 'a stuck row is still never dragged in - it has no screen to have been read' }
            $qRow.Conv = $qConvWas
            $qRow.Said = $qSaidWas
            $null = Set-AskSeen -Id "$($qRow.Id)" -Asking $false
            $qRow.Band = 'working'
            if ((Test-QuietVerdict -Row $qRow -Asking $false) -or "$($qRow.Band)" -ne 'working') {
                Fail 'a row with no menu on screen was moved anyway'
            } else { Pass 'no menu on screen moves nothing' }
            # 🔑 THE PROMOTE DIRECTION, WHICH IS WHAT THIS CHANGE IS FOR. Under
            # the old rule both of these were held back until the 15 s probe.
            foreach ($otherBand in @('done', 'idle')) {
                $qRow.Band = $otherBand
                # Feed it a positive result directly: the question is what it
                # does with one, not whether it can get one.
                $moved = Test-QuietVerdict -Row $qRow -Asking $true
                if (-not $moved -or "$($qRow.Band)" -ne 'needs') {
                    Fail ("a '{0}' row with a menu on its screen was left alone - that is the ~26 s notice bug" -f $otherBand)
                } else { Pass ("a '{0}' row with a menu actually seen is promoted rather than held for the probe" -f $otherBand) }
                $null = Set-AskSeen -Id "$($qRow.Id)" -Asking $false
            }
            # 🔒 AND A CONVERSATION WITH NO PROCESS IS STILL REFUSED. Not a
            # softer version of the old rule - a different fact. There is no
            # screen, so nothing can have seen a menu on it.
            $qRow.Band = 'quiet'
            $qRow.Live = $false
            if ((Test-QuietVerdict -Row $qRow -Asking $true) -or "$($qRow.Band)" -ne 'quiet') {
                Fail 'a conversation with no process was moved into needing you - there is no screen to have read'
            } else { Pass 'a row that is not running is refused: no process, no screen, no menu' }
            $qRow.Live = $qLiveWas
        } finally {
            $qRow.Band = $qBandWas
            $script:quietChecked = @{}
            $script:quietSince = @{}
        }

        # ===================================================================
        # 🔴 THE SQUARE SHELL MARK, WHICH HAD NEVER APPEARED ON A ROW AT ALL.
        # The row drew it from Get-SRRowSignals, which looked for a Bash call
        # nobody had answered - and a background Bash is answered the instant it
        # is launched, so that count was structurally zero. Both halves are
        # asserted: that the transcript really cannot see one, and that the
        # count read off the session's own status line reaches the row.
        # ===================================================================
        $bgLine = '{"type":"assistant","message":{"content":[{"type":"tool_use","id":"toolu_TESTBG01","name":"Bash","input":{"command":"sleep 60","run_in_background":true}}]}}'
        $bgAns = '{"type":"user","message":{"content":[{"type":"tool_result","tool_use_id":"toolu_TESTBG01","content":"started"}]}}'
        $bgFile = Join-Path $SR_StateDir ('shellsig-' + [Guid]::NewGuid().ToString('N').Substring(0, 6) + '.jsonl')
        try {
            [System.IO.File]::WriteAllText($bgFile, ($bgLine + "`n" + $bgAns + "`n"))
            $bgSig = Get-SRRowSignals $bgFile
            if ([int]$bgSig.Shells -ne 0) {
                Fail ("the transcript reader claims {0} shell(s) - it cannot know that" -f $bgSig.Shells)
            } else { Pass 'a launched background shell leaves nothing outstanding in the transcript - the row cannot learn it there' }
        } finally { Remove-Item -LiteralPath $bgFile -Force -ErrorAction SilentlyContinue }

        # ===================================================================
        # 🔴 AND IT HAS TO ARRIVE FAST, ACROSS EVERY LIVE SESSION AT ONCE.
        # Filing the marks was a second duty on the quiet check, which takes ONE
        # session per pass and gives "is it asking?" first refusal - so on a busy
        # machine it never ran, and when it did a new shell could be a quarter of
        # a minute late. Reported as the marks never appearing, which is what
        # "eventually" looks like. The sweep reads every console in one child.
        # ===================================================================
        $swPids = @()
        foreach ($mr in $script:model) {
            if ($mr.Live -and $mr.A -and $mr.A.Pid -and (-not $mr.A.Kind -or "$($mr.A.Kind)" -eq 'interactive')) {
                $swPids += [int]$mr.A.Pid
            }
        }
        # ===================================================================
    # 🔴 GREEN, AMBER, RED - ON TOKENS, NOT ON THE FRACTION. The thresholds
    # were fractions of the window, so the same colour described two
    # completely different situations: 85% of a 200k window is 170k and
    # comfortable; 85% of a 1M window is 850k and nearly out. Named
    # boundaries now, asserted either side of each.
    # ===================================================================
    $ctxCases = @(
        @{ T = 0;       Want = 'Ok';   Why = 'an empty context' },
        @{ T = 199999;  Want = 'Ok';   Why = 'just under 200k' },
        @{ T = 200001;  Want = 'Warn'; Why = 'just over 200k' },
        @{ T = 599999;  Want = 'Warn'; Why = 'just under 600k' },
        @{ T = 600001;  Want = 'Bad';  Why = 'just over 600k' },
        @{ T = 990000;  Want = 'Bad';  Why = 'nearly a full 1M window' }
    )
    # 🔑 THE DOT BREATHES ONLY WHILE IT IS WORKING. The one animation in the
    # window, so it has to mean something: started for a busy session, stopped
    # dead for anything else. A storyboard left running on a control that has
    # moved on keeps a timer alive and pulses about a session that finished an
    # hour ago.
    Set-WorkingPulse $false
    Set-WorkingPulse $true
    if (-not $script:pulseOn) { Fail 'the working pulse would not start' }
    else {
        Set-WorkingPulse $false
        if ($script:pulseOn) { Fail 'the working pulse would not stop' }
        elseif ($ui.PaneStateDot.Opacity -ne 1.0) { Fail "the dot was left at opacity $($ui.PaneStateDot.Opacity) after the pulse stopped" }
        else { Pass 'the working dot pulses while a session is mid-turn and stops when it is not' }
    }

    $ctxBad = 0
    foreach ($cc in $ctxCases) {
        $got = Get-CtxBrush ([int]$cc.T)
        if (-not [Object]::ReferenceEquals($got, $Pal[$cc.Want])) {
            Fail ("{0} ({1:N0} tokens) is not {2}" -f $cc.Why, $cc.T, $cc.Want)
            $ctxBad++
        }
    }
    if (-not $ctxBad) { Pass 'the context bar runs green to amber at 200k and amber to red at 600k' }

    if (-not $swPids.Count) { Note 'no live session to sweep - the batch read cannot be timed here' }
        else {
            $swBest = [double]::MaxValue
            $swGot = $null
            foreach ($swTry in 1..3) {
                $swSw = [Diagnostics.Stopwatch]::StartNew()
                $swRes = Get-SRScreenTextMany -ProcessIds $swPids
                $swSw.Stop()
                if ($swSw.Elapsed.TotalMilliseconds -lt $swBest) { $swBest = $swSw.Elapsed.TotalMilliseconds; $swGot = $swRes }
            }
            if (-not $swGot -or $swGot.Count -lt 1) {
                Fail 'the batched read returned no screens at all'
            } else {
                Pass ("one child read {0} of {1} live console(s) in {2:N0} ms" -f $swGot.Count, $swPids.Count, $swBest)
                # 🪤 THE BUDGET IS PER SWEEP, NOT PER CONSOLE, which is the whole
                # point of batching. A regression to one spawn per session shows
                # up here as roughly 130 ms x the session count.
                $swBudget = 250 + (60 * $swPids.Count)
                if ($swBest -gt $swBudget) {
                    Fail ("the sweep took {0:N0} ms for {1} session(s), over its {2} ms budget - is it spawning a child each?" -f $swBest, $swPids.Count, $swBudget)
                } else { Pass ("the whole board refreshes inside its {0} ms budget" -f $swBudget) }
                # Every pid asked for is a pid answered for, or the marks would
                # silently stop at whichever session failed to read.
                $swMissing = @($swPids | Where-Object { -not $swGot.ContainsKey($_) })
                if ($swMissing.Count) {
                    Note ("{0} console(s) could not be read this pass" -f $swMissing.Count)
                } else { Pass 'every live console answered in the one pass' }
            }
        }

        $sigId = "$($probeItem.Row.Id)"
        $sigWas = $script:rowScreen[$sigId]
        try {
            $null = Set-RowScreenSig -Id $sigId -Shells 2 -Agents -1
            Build-Sessions
            $drawn = @($ui.SessionList.ItemsSource | Where-Object { "$($_.Id)" -eq $sigId })
            if (-not $drawn.Count) { Fail 'the conversation under test is not in the list' }
            elseif ("$($drawn[0].ShellVis)" -ne 'Visible') { Fail 'a session with 2 shells running draws no shell mark' }
            elseif ("$($drawn[0].ShellText)" -ne '2') { Fail "the shell mark reads '$($drawn[0].ShellText)' rather than 2" }
            else { Pass 'a shell count read off the status line reaches the row as a square mark' }

            # ===============================================================
            # 🔴 THE CONTEXT BAR AND THE MARKS, TOGETHER. Reported as the bar
            # being wrong "when the sub agent or shell indicator is turned on".
            # The row draws dot / name / marks / bar / age across one Grid, and
            # only the name is star-width - so the suspicion was that the marks
            # squeeze the bar out. Asserted here because a report nobody can
            # reproduce comes back.
            # ===============================================================
            $null = Set-RowScreenSig -Id $sigId -Shells 2 -Agents 1 -CtxTokens 700000 -CtxWindow 1000000
            Build-Sessions
            $both = @($ui.SessionList.ItemsSource | Where-Object { "$($_.Id)" -eq $sigId })
            if (-not $both.Count) { Fail 'the conversation under test left the list' }
            else {
                $bw = $both[0]
                if ("$($bw.ShellVis)" -ne 'Visible' -or "$($bw.AgentVis)" -ne 'Visible') {
                    Fail 'a session with both a shell and a sub-agent draws neither mark'
                } elseif ("$($bw.CtxVis)" -ne 'Visible') {
                    Fail 'the context bar disappears when a mark is showing - the marks are squeezing it out'
                } elseif ([double]$bw.CtxWidth -lt 20.0) {
                    Fail ("the context bar is {0:N1}px wide beside the marks - it is being squeezed" -f $bw.CtxWidth)
                } else {
                    Pass ("the bar and both marks coexist: bar {0:N0}px at 70% with a shell and a sub-agent" -f $bw.CtxWidth)
                }
                # And the width still tracks the fraction rather than collapsing
                # to a minimum whenever anything else is on the row.
                $null = Set-RowScreenSig -Id $sigId -Shells 2 -Agents 1 -CtxTokens 950000 -CtxWindow 1000000
                Build-Sessions
                $fuller = @($ui.SessionList.ItemsSource | Where-Object { "$($_.Id)" -eq $sigId })
                if ($fuller.Count -and [double]$fuller[0].CtxWidth -le [double]$bw.CtxWidth) {
                    Fail ("a fuller context did not draw a longer bar: {0:N1}px at 95% vs {1:N1}px at 70%" -f $fuller[0].CtxWidth, $bw.CtxWidth)
                } else { Pass 'and the bar still tracks how full it is, with the marks alongside' }
            }

            # 🪤 AND IT HAS TO CLEAR. A finished shell prints no count, which is
            # a true zero - if that read only ever overwrote a positive the mark
            # would stay up for the life of the window.
            $null = Set-RowScreenSig -Id $sigId -Shells 0 -Agents -1
            Build-Sessions
            $drawn = @($ui.SessionList.ItemsSource | Where-Object { "$($_.Id)" -eq $sigId })
            if ($drawn.Count -and "$($drawn[0].ShellVis)" -eq 'Visible') {
                Fail 'the shell mark stayed up after the session stopped reporting one'
            } else { Pass 'the mark clears when the shell finishes' }

            # 🪤 A COUNT THE STATUS LINE NEVER PRINTED IS NOT A ZERO. Sub-agents
            # the transcript CAN see, so -1 there means "ask the transcript"
            # rather than "there are none" - the opposite default to shells.
            $script:rowScreen[$sigId] = @{ At = (Get-Date).AddSeconds(-600); Shells = 3; Agents = 3 }
            Build-Sessions
            $drawn = @($ui.SessionList.ItemsSource | Where-Object { "$($_.Id)" -eq $sigId })
            if ($drawn.Count -and "$($drawn[0].ShellVis)" -eq 'Visible') {
                Fail 'a ten-minute-old count is still being drawn - it describes a session that has since done anything at all'
            } else { Pass 'a count past its life is not drawn' }
        } finally {
            if ($sigWas) { $script:rowScreen[$sigId] = $sigWas } else { $script:rowScreen.Remove($sigId) }
            Build-Sessions
        }

        # ===================================================================
        # 🔴 WHAT IS QUEUED BEHIND IT, ON THE ROW. The complaint this answers is
        # not being able to see which of twenty sessions is sitting on your
        # work, so the assertion that matters is not "a number appears" - it is
        # WHICH number appears, and in which colour.
        # ===================================================================
        $qbRow = $probeItem.Row
        $qbWas = $qbRow.Q
        function New-QBadgeFixture { param([int]$Mine, [int]$Machine)
            $qbItems = New-Object System.Collections.Generic.List[object]
            for ($qbI = 0; $qbI -lt $Mine; $qbI++) {
                $null = $qbItems.Add([PSCustomObject]@{
                    Text = "something you typed $qbI"; First = "something you typed $qbI"
                    At = (Get-Date).AddSeconds(-45); Mine = $true })
            }
            for ($qbI = 0; $qbI -lt $Machine; $qbI++) {
                $null = $qbItems.Add([PSCustomObject]@{
                    Text = '<cross-session-message from="uds:pipe">x</cross-session-message>'
                    First = '<cross-session-message from="uds:pipe">x</cross-session-message>'
                    At = (Get-Date).AddSeconds(-20); Mine = $false })
            }
            return [PSCustomObject]@{
                Items = $qbItems.ToArray(); Count = ($Mine + $Machine)
                Mine = $Mine; Machine = $Machine; Ok = $true }
        }
        function Get-QBadge {
            Build-Sessions
            $qbD = @($ui.SessionList.ItemsSource | Where-Object { "$($_.Id)" -eq "$($qbRow.Id)" })
            if (-not $qbD.Count) { return $null }
            return $qbD[0]
        }
        try {
            $qbRow.Q = $null
            $qbNone = Get-QBadge
            if (-not $qbNone) { Fail 'the conversation under test is not in the list' }
            elseif ("$($qbNone.QVis)" -eq 'Visible') { Fail 'a session with nothing queued still draws a queue mark' }
            else { Pass 'nothing queued draws no mark' }

            $qbRow.Q = New-QBadgeFixture -Mine 2 -Machine 0
            $qbMine = Get-QBadge
            if ("$($qbMine.QVis)" -ne 'Visible') { Fail 'two of your messages are waiting and the row says nothing' }
            elseif ("$($qbMine.QText)" -ne '2') { Fail "the queue mark reads '$($qbMine.QText)' rather than 2" }
            elseif ("$($qbMine.QBrush.Color)" -ne "$(([System.Windows.Media.SolidColorBrush]$window.FindResource('HueOut')).Color)") {
                Fail 'a queue of your own messages is not drawn in the colour that means you spoke'
            } else { Pass 'two of your own messages waiting draws an amber >>2 on the row' }

            # 🪤 THE ONE THAT KEEPS THE MARK WORTH LOOKING AT. Measured on this
            # machine: 1,356 cross-session messages and 1,107 task
            # notifications against 144 lines a person typed. A row that adds
            # them together reads ">>16" when SIXTEEN things are waiting and
            # only two of them could possibly matter - and a mark that is
            # always lit is a mark you stop seeing.
            $qbRow.Q = New-QBadgeFixture -Mine 2 -Machine 14
            $qbMix = Get-QBadge
            if ("$($qbMix.QText)" -eq '16') {
                Fail 'the row totalled your 2 messages with 14 machine ones - the count has to be the part you care about'
            } elseif ("$($qbMix.QText)" -ne '2') {
                Fail "with 2 yours behind 14 machine ones the mark reads '$($qbMix.QText)', expected 2"
            } else { Pass 'two of yours behind fourteen machine messages still reads 2, not 16' }
            if ("$($qbMix.QTip)" -notlike '*14 from the machine*') {
                Fail "the machine traffic is not mentioned anywhere: '$($qbMix.QTip)'"
            } else { Pass 'and the machine traffic is in the tooltip rather than in the count' }

            # Machine-only: still worth showing, never worth an accent.
            $qbRow.Q = New-QBadgeFixture -Mine 0 -Machine 6
            $qbMach = Get-QBadge
            if ("$($qbMach.QVis)" -ne 'Visible') { Fail 'six queued messages draw nothing at all' }
            elseif ("$($qbMach.QText)" -ne '6') { Fail "a machine-only queue reads '$($qbMach.QText)' rather than 6" }
            elseif ("$($qbMach.QBrush.Color)" -eq "$(([System.Windows.Media.SolidColorBrush]$window.FindResource('HueOut')).Color)") {
                Fail 'a queue with nothing of yours in it is drawn in the accent that means your words are waiting'
            } else { Pass 'a machine-only queue is drawn grey - present, not shouting' }
            # ===============================================================
            # 🔴 AND THE PANEL UNDER THE CONVERSATION, which is the other half:
            # the row says WHERE, this says WHAT.
            # ===============================================================
            $ui.SessionList.SelectedItem = @($ui.SessionList.ItemsSource |
                Where-Object { "$($_.Id)" -eq "$($qbRow.Id)" })[0]

            $qbRow.Q = $null
            $script:qSig = $null
            Update-QueuePanel
            if ("$($ui.QueueBox.Visibility)" -eq 'Visible') {
                Fail 'the queue panel is showing for a conversation with nothing queued'
            } else { Pass 'the queue panel stays out of the way when nothing is waiting' }

            $qbRow.Q = New-QBadgeFixture -Mine 2 -Machine 14
            $script:qSig = $null
            Update-QueuePanel
            $qbList = @($ui.QueueList.ItemsSource)
            if ("$($ui.QueueBox.Visibility)" -ne 'Visible') { Fail 'sixteen queued and the panel says nothing' }
            elseif ($qbList.Count -ne 4) {
                Fail "the panel drew $($qbList.Count) rows; it caps at 4 because a real queue reached 57 on this machine"
            } else { Pass 'a 16-deep queue draws four rows, not sixteen' }

            # 🪤 THE ORDER IS THE POINT. In queue order these two would sit
            # behind fourteen cross-session messages and fall off the cap -
            # so the operator would open a session that IS holding their work
            # and see four lines of machine chatter instead.
            $qbMineRows = @($qbList | Where-Object { "$($_.QiText)" -like 'something you typed*' })
            if ($qbMineRows.Count -ne 2) {
                Fail "both of your messages should be inside the cap; $($qbMineRows.Count) made it"
            } else { Pass 'your two messages are shown first, ahead of fourteen machine ones' }
            if ("$($qbList[0].QiText)" -notlike 'something you typed*') {
                Fail "the top of the panel is '$($qbList[0].QiText)', not something you typed"
            } else { Pass 'and the first row is yours' }
            if ("$($ui.QueueHead.Text)" -notlike '*12 MORE NOT SHOWN*') {
                Fail "the remainder is not accounted for: '$($ui.QueueHead.Text)'"
            } else { Pass 'and the twelve it did not draw are counted, not dropped' }

            # 🔒 The envelope is NAMED, never printed. A cross-session message is
            # 60 characters of pipe address before a word of content.
            $qbMach = @($qbList | Where-Object { "$($_.QiText)" -notlike 'something you typed*' })
            if ($qbMach.Count -and "$($qbMach[0].QiText)" -like '*uds:*') {
                Fail "the routing envelope is being printed as the message: '$($qbMach[0].QiText)'"
            } else { Pass 'a machine message is named rather than having its envelope printed' }

            # 🔴 AND TYPING MUST NOT REBUILD IT. Update-QueuePanel hangs off
            # Update-SendState, and one of that function's callers is the
            # composer's TextChanged - so without the signature guard every
            # keystroke would hand WPF a new ItemsSource.
            # 🔴 A MESSAGE THAT HAS SAT THERE SAYS SO. 21% of queued messages
            # wait longer than two minutes on this machine and the p90 is 26,
            # so "queued" alone stops being the useful fact fairly quickly.
            function Set-QAge { param([int]$Secs)
                $q = New-QBadgeFixture -Mine 1 -Machine 0
                $q.Items[0].At = (Get-Date).AddSeconds(-$Secs)
                $qbRow.Q = $q
                $script:qSig = $null
                Update-QueuePanel
            }
            Set-QAge 20
            if ("$($ui.QueueHead.Text)" -match 'WAITED') {
                Fail ("a message queued 20 seconds ago is being flagged as stale: '{0}'" -f $ui.QueueHead.Text)
            } else { Pass 'a message queued seconds ago draws no warning' }
            $freshFg = "$($ui.QueueHead.Foreground)"

            Set-QAge 400
            if ("$($ui.QueueHead.Text)" -notmatch 'WAITED') {
                Fail ("a message waiting nearly seven minutes says nothing: '{0}'" -f $ui.QueueHead.Text)
            } else { Pass ("past two minutes the heading says how long: '{0}'" -f $ui.QueueHead.Text) }
            if ("$($ui.QueueHead.Foreground)" -eq $freshFg) {
                Fail 'the heading did not change colour for a message that has been waiting'
            } else { Pass 'and it changes colour, in the pane rather than on the scanned row' }

            # 🪤 THE GUARD MUST NOT SWALLOW IT. Nothing about a queue changes
            # while it sits - same count, same front - so a signature built only
            # from its contents is identical either side of the two-minute line
            # and the warning would never be drawn. Same fixture, only older.
            $qStaleSig = $script:qSig
            Set-QAge 20
            if ($script:qSig -eq $qStaleSig) {
                Fail 'the panel signature is the same for a fresh queue and a stale one - the warning can never appear'
            } else { Pass 'and waiting is part of what makes the panel redraw' }

            $qbBefore = $ui.QueueList.ItemsSource
            $qbWasText = "$($ui.SendBox.Text)"
            try {
                foreach ($qbCh in @('a','b','c','d','e','f','g','h')) { $ui.SendBox.Text = "$($ui.SendBox.Text)$qbCh" }
                if (-not [object]::ReferenceEquals($qbBefore, $ui.QueueList.ItemsSource)) {
                    Fail 'typing in the composer rebuilt the queue panel - eight keystrokes, eight rebuilds'
                } else { Pass 'eight keystrokes in the composer rebuilt the panel exactly zero times' }
            } finally { $ui.SendBox.Text = $qbWasText }
        } finally {
            $qbRow.Q = $qbWas
            $script:qSig = $null
            Build-Sessions
        }

        # 🪤 AND THE BUSY GATE, on the same live console. Without this the two
        # assertions above would pass on a probe that reads any session at all,
        # which is exactly the defect that drew a numbered list as a menu.
        $probeItem.Row.A.Status = 'busy'
        Show-Ask $null
        Start-AskProbe $probeItem.Row
        if ($script:askPs) { Fail 'the ask probe started against a session that is mid-turn' }
        else { Pass 'a mid-turn session is never probed' }
    } finally {
        if ($hadA) { $probeItem.Row.A.Pid = $savedPid; $probeItem.Row.A.Status = $savedStatus }
        if ($askProc) { try { if (-not $askProc.HasExited) { $askProc.Kill() } } catch { } }
        Remove-Item -LiteralPath $askOut -Force -ErrorAction SilentlyContinue
        Show-Ask $null
    }
}

# ===========================================================================
Write-Host ''
Write-Host '--- the transcript watcher actually fires ---'
# ===========================================================================
# 🔴 THE WHOLE RESPONSIVENESS CLAIM RESTS ON THIS ONE FLAG. The 100ms lane does
# nothing unless the watcher raises it, so a watcher that never fires means a
# pane that only ever updates on the one-second backstop - which looks like it
# is working, just not as fast as promised. That is the least visible way for
# this to be broken and it had no test at all.
$watchFile = Join-Path $SR_StateDir ('watch-' + [Guid]::NewGuid().ToString('N').Substring(0, 6) + '.jsonl')
try {
    [System.IO.File]::WriteAllText($watchFile, "{}`n", (New-Object System.Text.UTF8Encoding($false)))
    Start-TranscriptWatch $watchFile
    if (-not $script:watcher) { Fail 'the watcher would not start on a file that exists' }
    else {
        Pass 'the watcher is on the selected transcript'
        $null = @(Get-Event -SourceIdentifier 'SRTranscript' -ErrorAction SilentlyContinue | ForEach-Object { Remove-Event -EventIdentifier $_.EventIdentifier -ErrorAction SilentlyContinue })
        $script:transcriptDirty = $false
        [System.IO.File]::AppendAllText($watchFile, "{}`n", (New-Object System.Text.UTF8Encoding($false)))
        # The handler runs on the engine event queue, which the runspace pumps
        # between statements - polling with a short sleep is what gives it the
        # chance, and it returns the instant the flag is up.
        $wSw = [Diagnostics.Stopwatch]::StartNew()
        $wFired = $false
        while ($wSw.Elapsed.TotalSeconds -lt 8 -and -not $wFired) { Start-Sleep -Milliseconds 50; $wFired = [bool](Invoke-WriteLane) }
        $wSw.Stop()
        if (-not $wFired) {
            Fail 'a write to the watched transcript never raised the flag - the pane is on the 1s backstop only'
        } else { Pass ("a write raised the flag in {0:N0} ms" -f $wSw.Elapsed.TotalMilliseconds) }

        # 🪤 AND SWITCHING CONVERSATIONS MUST NOT KILL IT. Register-ObjectEvent
        # keeps its subscription under a SourceIdentifier until it is explicitly
        # unregistered, and disposing the watcher does NOT take it with it - so
        # the second conversation you selected hit "identifier already in use",
        # the registration failed inside a try, and the window fell back to the
        # timer for the rest of its life without saying so.
        $watchFile2 = Join-Path $SR_StateDir ('watch2-' + [Guid]::NewGuid().ToString('N').Substring(0, 6) + '.jsonl')
        try {
            [System.IO.File]::WriteAllText($watchFile2, "{}`n", (New-Object System.Text.UTF8Encoding($false)))
            Start-TranscriptWatch $watchFile2
            if (-not $script:watcher) { Fail 'the watcher did not survive being pointed at a second conversation' }
            else {
                $script:transcriptDirty = $false
                [System.IO.File]::AppendAllText($watchFile2, "{}`n", (New-Object System.Text.UTF8Encoding($false)))
                $wSw2 = [Diagnostics.Stopwatch]::StartNew()
                $wFired2 = $false
                while ($wSw2.Elapsed.TotalSeconds -lt 8 -and -not $wFired2) { Start-Sleep -Milliseconds 50; $wFired2 = [bool](Invoke-WriteLane) }
                $wSw2.Stop()
                if (-not $wFired2) {
                    Fail 'the SECOND conversation is not watched - selecting another one silently drops to the backstop'
                } else { Pass ("the second conversation is watched too, {0:N0} ms" -f $wSw2.Elapsed.TotalMilliseconds) }
            }
        } finally { Remove-Item -LiteralPath $watchFile2 -Force -ErrorAction SilentlyContinue }

        # And it must STOP when told, or a closed conversation keeps waking the
        # pane for a file nobody is reading.
        Stop-TranscriptWatch
        $null = @(Get-Event -SourceIdentifier 'SRTranscript' -ErrorAction SilentlyContinue | ForEach-Object { Remove-Event -EventIdentifier $_.EventIdentifier -ErrorAction SilentlyContinue })
        $script:transcriptDirty = $false
        [System.IO.File]::AppendAllText($watchFile, "{}`n", (New-Object System.Text.UTF8Encoding($false)))
        Start-Sleep -Milliseconds 600
        if ([bool](Invoke-WriteLane) -or @(Get-Event -SourceIdentifier 'SRTranscript' -ErrorAction SilentlyContinue).Count) { Fail 'a stopped watcher is still raising events' }
        else { Pass 'a stopped watcher stays stopped' }
    }
} finally {
    try { Stop-TranscriptWatch } catch { }
    Remove-Item -LiteralPath $watchFile -Force -ErrorAction SilentlyContinue
    $script:transcriptDirty = $false
}

# ===========================================================================
Write-Host ''
Write-Host '--- the turns folded off-thread are the turns folded inline ---'
# ===========================================================================
# 🔴 Get-ReadTurns RAN ON THE UI THREAD AT 16.3 ms ON EVERY CONVERSATION OPENED
# - over the bar on its own, before a single WPF object is made, while the parse
# beside it had been off-thread for months. It is 113 lines over plain records
# calling nothing but built-ins, so there was never a reason for it to be there.
#
# 🪤 THE FUNCTION IS SENT INTO THE RUNSPACE AS SOURCE, not moved into
# _common.ps1 - it belongs to the reading pane. That makes the round trip the
# risk: ${function:X}.ToString() gives the BODY, and if anything is lost
# recreating it the pane would render one thing off-thread and another inline,
# which is precisely the class of bug that stays invisible until someone reads
# a transcript carefully. So the two are compared on real blocks.
# 🪤 BLOCKS BUILT HERE, NOT A TRANSCRIPT FOUND SOMEWHERE. Two earlier versions
# of this test looked for input and both produced a comparison that proved
# nothing: the operator's live conversations gave one folding into a SINGLE turn
# (on which "same count, same kinds" holds for almost any implementation,
# including a broken one), and the committed .jsonl fixtures are message and
# queue captures rather than conversation transcripts, so they fold into none.
#
# A block is a plain record - Kind, Head, Body, Meta, When - so the input can
# simply be written down. That makes the test deterministic, independent of what
# the operator was doing, and readable: the turns it should fold into are
# visible right here.
function New-TurnBlock { param([string]$Kind, [string]$Head = '', [string]$Body = '', [string]$Meta = '')
    return [PSCustomObject]@{ Kind = $Kind; Head = $Head; Body = $Body; Meta = $Meta; When = (Get-Date) }
}
$turnBlocks = @(
    (New-TurnBlock -Kind 'you'  -Body 'first thing the operator asked')
    (New-TurnBlock -Kind 'said' -Body "an answer with two lines`nand a second one")
    (New-TurnBlock -Kind 'run'  -Head 'Bash' -Meta 'ls -la' -Body 'a b c')
    (New-TurnBlock -Kind 'run'  -Head 'Read' -Meta 'a/file.ps1' -Body 'contents')
    (New-TurnBlock -Kind 'said' -Body 'a second answer, after the tools')
    (New-TurnBlock -Kind 'you'  -Body 'a follow-up question')
    (New-TurnBlock -Kind 'said' -Body 'the last thing it said')
)
if (@(Get-ReadTurns $turnBlocks).Count -lt 3) {
    Fail ('the hand-built blocks fold into {0} turn(s) - the round-trip comparison cannot prove anything' -f @(Get-ReadTurns $turnBlocks).Count)
}
else {
    $inline = @(Get-ReadTurns $turnBlocks)
    $viaSrc = $null
    try {
        $sbTurns = [scriptblock]::Create(${function:Get-ReadTurns}.ToString())
        $viaSrc = @(& $sbTurns $turnBlocks)
    } catch { $viaSrc = $null }
    if ($null -eq $viaSrc) { Fail 'Get-ReadTurns could not be recreated from its own source - the off-thread fold would silently do nothing' }
    elseif ($viaSrc.Count -ne $inline.Count) {
        Fail ("recreated Get-ReadTurns folded {0} turns where the original folded {1}" -f $viaSrc.Count, $inline.Count)
    } else {
        $sameKinds = $true
        for ($ti = 0; $ti -lt $inline.Count; $ti++) {
            if ("$($viaSrc[$ti].Kind)" -ne "$($inline[$ti].Kind)") { $sameKinds = $false; break }
        }
        if (-not $sameKinds) { Fail 'recreated Get-ReadTurns produced different turn kinds - the pane would differ off-thread' }
        else { Pass ("the fold survives the round trip into a runspace: {0} turns, same kinds" -f $inline.Count) }
    }
}

Write-Host ''
Write-Host '--- the strip selects a conversation without rebuilding the list ---'
# ===========================================================================
# 🔴 IT REBUILT EVERY ROW TO CHANGE WHICH ONE WAS HIGHLIGHTED. The handler set
# $script:selId and called Build-Sessions purely so the rebind would restore the
# selection from it - a correct route to the right outcome, audited at 164 ms for
# the gesture with 114 of it inside that single call.
#
# 🪤 THE FALLBACK IS THE HALF THAT MUST NOT ROT. A filter or a search can leave
# the target out of the bound list, and then there is nothing to select - so it
# still rebuilds. Both paths are asserted, because a version that always found
# the row would pass a test that only checked the happy one.
$ui.ModeWork.IsChecked = $true
Set-Surface 'work'
Build-Sessions
$stripRow = @($ui.SessionList.Items | Where-Object { $_.Kind -eq 'session' }) | Select-Object -Last 1
if (-not $stripRow) { Fail 'no session row to select from the strip' }
else {
    $srcBefore = $ui.SessionList.ItemsSource
    $direct = Select-SRSessionById "$($stripRow.Row.Id)"
    if (-not $direct) { Fail 'selecting a conversation that IS in the list fell back to a rebuild' }
    elseif (-not [object]::ReferenceEquals($srcBefore, $ui.SessionList.ItemsSource)) {
        Fail 'selecting from the strip rebuilt the list - the 114 ms is back'
    } elseif ("$($ui.SessionList.SelectedItem.Row.Id)" -ne "$($stripRow.Row.Id)") {
        Fail 'the strip selected the wrong conversation'
    } else { Pass 'the strip selects the row in place, with no rebuild' }

    # And a conversation the list does not hold must still fall back.
    $fell = Select-SRSessionById 'not-a-conversation-id-00000000'
    if ($fell) { Fail 'an id that is not in the list reported success instead of falling back' }
    else { Pass 'an id the list does not hold falls back to the rebuild' }
    $script:selId = "$($stripRow.Row.Id)"
}

Write-Host ''
Write-Host '--- switching to the manager does not rebuild it unless it has to ---'
# ===========================================================================
# 🔴 THE ASYMMETRY WAS ONE FUNCTION CALL. Audited: Set-Surface manage is two
# Visibility assignments (0.18 ms) plus a full Build-Manager (80.00); the other
# direction is the same 0.36 ms and nothing else, because the work surface is
# kept current by the background passes and can simply SHOW what was last built.
# The manager had no dirty flag, so the only way it could be right on arrival was
# to rebuild every time - measured repeated (87.75) and alternating (79.92).
#
# 🪤 THE RISK IS NOT SPEED, IT IS A STALE SURFACE. This decides what reopens at
# logon, so a manager that skipped a rebuild it needed would be a lie about
# tomorrow morning. Both directions are asserted: it must NOT rebuild when
# nothing changed, and it MUST when something did.
$ui.ModeManage.IsChecked = $true
Set-Surface 'manage'
$mgrSrcA = $ui.ManageList.ItemsSource
Set-Surface 'work'
Set-Surface 'manage'
$mgrSrcB = $ui.ManageList.ItemsSource
if (-not [object]::ReferenceEquals($mgrSrcA, $mgrSrcB)) {
    Fail 'switching away and back rebuilt the manager although nothing had changed'
} else { Pass 'switching away and back reuses what was already built' }

# And now something DOES change while the manager is not the visible surface.
Set-Surface 'work'
$script:mgrItems = @{}
$script:mgrDirty = $true          # what Update-Model / Set-TickOn / Toggle-Tick do
Set-Surface 'manage'
$mgrSrcC = $ui.ManageList.ItemsSource
if ([object]::ReferenceEquals($mgrSrcB, $mgrSrcC)) {
    Fail 'the model changed while the manager was hidden and it came back stale'
} else { Pass 'a change while it was hidden forces the rebuild on arrival' }
if ($script:mgrDirty) { Fail 'Build-Manager left the surface marked dirty - it would rebuild on every switch' }
else { Pass 'a completed build clears the flag' }

Write-Host ''
Write-Host '--- the manager row cache cannot show a stale tick ---'
# ===========================================================================
# 🔴 THE CACHE EXISTS BECAUSE SORTING REBUILT EVERY ROW. Sorting and filtering
# change which rows appear and in what order - never what a row SAYS - so the
# built objects are reused, which took the manager's gestures from 55 ms to
# ~40 ms. The danger is obvious and specific: a tick is the one thing a built
# row says that can change without the model being rebuilt, and this surface
# decides what reopens at logon. A row showing a tick that is not set would be a
# lie about tomorrow morning.
$ui.ModeManage.IsChecked = $true
Set-Surface 'manage'
$script:mgrFilter = 'all'
$script:showOlder = $true
Build-Manager
foreach ($fk2 in @($script:fold.Keys)) { $script:fold[$fk2] = $false }
Build-Manager
$cacheRow = @($ui.ManageList.Items | Where-Object { $_.Kind -eq 'conv' })[0]
if (-not $cacheRow) { Fail 'no manager row to test the cache with' }
else {
    $wasEnabled = [bool]$cacheRow.Row.S.enabled
    $tickBefore = "$($cacheRow.TickBg)"
    try {
        # Prove the cache is real first: a rebuild with nothing changed must hand
        # back the SAME object, or there is no cache and this test proves nothing.
        Build-Manager
        $again = @($ui.ManageList.Items | Where-Object { $_.Kind -eq 'conv' -and $_.Row.Id -eq $cacheRow.Row.Id })[0]
        if (-not [object]::ReferenceEquals($again, $cacheRow)) {
            Fail 'the manager rebuilt its rows - the cache is not in use, so the staleness check below proves nothing'
        } else { Pass 'an unchanged rebuild reuses the built rows' }

        # 🪤 THE CONTRACT, NOT A ROUND TRIP. An earlier version of this flipped
        # `enabled` and then called Set-TickOn - which sets the tick ON, so on an
        # already-ticked row it put the value straight back and the assertion
        # failed against correct code. What has to be true is narrower and
        # checkable: every path that can change what a row says empties the
        # cache. Each is exercised, so a new one added without an invalidation
        # is the thing that goes red.
        foreach ($path in @(
            @{ n = 'ticking a row';   go = { Set-TickOn $cacheRow.Row } },
            @{ n = 'toggling a tick'; go = { Toggle-Tick } },
            @{ n = 'rebuilding the model'; go = { Update-Model -Registry $script:reg -Agents $script:agents -Said @{} } }
        )) {
            Build-Manager
            if ($script:mgrItems.Count -eq 0) { Fail "the cache is empty before '$($path.n)' - nothing is being cached"; continue }
            try { & $path.go } catch { }
            Build-Manager
            # 🪤 NOT "the cache is empty". Set-TickOn drops the cache and then
            # rebuilds, so it legitimately leaves 205 rows cached again - an
            # earlier version of this failed correct code for that. What must
            # never be true is a DRAWN row disagreeing with the conversation it
            # stands for, whichever way the invalidation was achieved.
            $lying = @()
            foreach ($it2 in @($ui.ManageList.Items | Where-Object { $_.Kind -eq 'conv' })) {
                $drawnOn = ("$($it2.TickBg)" -ne "$([System.Windows.Media.Brushes]::Transparent)")
                if ($drawnOn -ne [bool]$it2.Row.S.enabled) { $lying += $it2 }
            }
            if ($lying.Count) {
                Fail ("after {0}, {1} row(s) draw a tick that disagrees with the conversation - the manager is lying about what reopens at logon" -f $path.n, $lying.Count)
            } else { Pass ("after {0}, every drawn tick matches its conversation" -f $path.n) }
        }

        # And the value really does follow the row afterwards, which is the thing
        # the invalidation exists to make true.
        $script:mgrItems = @{}
        $cacheRow.Row.S.enabled = (-not $wasEnabled)
        Build-Manager
        $after = @($ui.ManageList.Items | Where-Object { $_.Kind -eq 'conv' -and $_.Row.Id -eq $cacheRow.Row.Id })[0]
        if (-not $after) { Fail 'the row vanished after its tick changed' }
        elseif ("$($after.TickBg)" -eq $tickBefore) {
            Fail 'a rebuilt row still draws the old tick'
        } else { Pass 'a rebuilt row draws the tick the conversation actually has' }
    } finally {
        $cacheRow.Row.S.enabled = $wasEnabled
        $script:mgrItems = @{}
        Build-Manager
    }
}
$ui.ModeWork.IsChecked = $true
Set-Surface 'work'

# ===========================================================================
Write-Host ''
Write-Host '--- end to end: how long until you SEE something ---'
# ===========================================================================
# 🔴 THE GESTURE BUDGET IS NOT THE WHOLE ANSWER. Selecting a conversation
# returns in 16 ms, but what the operator asked was "how long until I can read
# it" - and the parse moved off-thread precisely so the click could return
# before the document existed. That makes the honest number the round trip:
# click, parse, build, on screen. Same for a session writing a line.
Build-Sessions
$e2eRows = @($ui.SessionList.Items | Where-Object { $_.Kind -eq 'session' -and "$($_.Row.S.jsonl)" -and (Test-Path -LiteralPath "$($_.Row.S.jsonl)") })
# 🔴 THE ROW UNDER TEST IS CHOSEN BY ITS DATA, NOT BY ITS POSITION.
#
# This block used to take $e2eRows[0] - whatever happened to be top of the
# sessions list. On a machine with 34 live conversations that is a different
# row on every run, and about one run in three it was a session whose tail is
# all folded tool traffic: the document came out at 2 blocks and 92 characters
# and "the only text is the pane's own truncation notice" went red, correctly,
# about a pane that was fine.
#
# 🪤 AN INTERMITTENT SUITE IS WORSE THAN A MISSING ONE. It teaches whoever
# inherits it to re-run until green, and that is how a real regression gets
# waved through. So the pick is the LARGEST TRANSCRIPT ON DISK - a property of
# the data, stable between runs minutes apart, and immune to any future change
# in how the sessions column sorts.
function Get-E2EBiggest { param($Rows)
    $best = $null; $bestLen = -1
    foreach ($e in @($Rows)) {
        $len = 0
        try { $len = (Get-Item -LiteralPath "$($e.Row.S.jsonl)" -ErrorAction Stop).Length } catch { $len = 0 }
        if ($len -gt $bestLen) { $bestLen = $len; $best = $e }
    }
    return $best
}
if ($e2eRows.Count -lt 2) { Note 'not enough conversations with transcripts to time the round trip' }
else {
    # SELECT -> READABLE. Driven exactly as the window does it: Show-Selected
    # kicks the parse, the 100ms lane collects it and builds the document.
    $e2eBest = [double]::MaxValue
    foreach ($pass in 1..7) {
        $pick = $e2eRows[$pass % $e2eRows.Count]
        $script:selId = $null
        $ui.PaneDoc.Document = $null
        $sw = [Diagnostics.Stopwatch]::StartNew()
        $ui.SessionList.SelectedItem = $pick
        Show-Selected
        while ($sw.Elapsed.TotalSeconds -lt 10 -and -not $ui.PaneDoc.Document) {
            Start-Sleep -Milliseconds 5
            $null = Complete-DocParse
        }
        $sw.Stop()
        if ($ui.PaneDoc.Document -and $sw.Elapsed.TotalMilliseconds -lt $e2eBest) { $e2eBest = $sw.Elapsed.TotalMilliseconds }
    }
    if ($e2eBest -eq [double]::MaxValue) { Fail 'selecting a conversation never produced a document' }
    elseif ($e2eBest -gt 400) { Fail ("a conversation takes {0:N0} ms to become readable - that is a wait, not a load" -f $e2eBest) }
    else { Pass ("select to readable: {0:N0} ms" -f $e2eBest) }

    # ===================================================================
    # 🔴 AND IT HAS TO HAVE SOMETHING IN IT. Everything above asks whether a
    # Document OBJECT exists, which an EMPTY document satisfies perfectly -
    # so the operator reported a pane that showed the "last 96 KB" header
    # and nothing else while every assertion here stayed green. A test that
    # cannot go red on a blank page is not testing the page.
    #
    # Three separate claims, because they fail differently: the document has
    # blocks at all, some of those blocks carry the conversation's own words,
    # and those words are not just the header the pane draws for itself.
    # ===================================================================
    $docRow = Get-E2EBiggest $e2eRows
    # 🔑 AND THE CHOICE MUST NOT DEPEND ON THE ORDER, or a later change to how
    # the sessions column sorts reintroduces the flake while this test carries
    # on passing on a lucky machine. Reversing the list has to pick the same
    # conversation - that is the property, and asserting the document is merely
    # non-empty would not have caught any of this.
    $docRev = @($e2eRows); [array]::Reverse($docRev)
    $docRow2 = Get-E2EBiggest $docRev
    if (-not $docRow) { Fail 'no conversation with a readable transcript to render' }
    elseif (-not [object]::ReferenceEquals($docRow, $docRow2)) {
        Fail 'the conversation under test depends on the list order - this block will flake again the next time the sort changes'
    } else {
        Pass ("the conversation under test is picked by transcript size, not position ('{0}', {1:N0} KB)" -f `
            $docRow.Name, ((Get-Item -LiteralPath "$($docRow.Row.S.jsonl)").Length / 1KB))
    }
    $script:selId = $null
    $ui.PaneDoc.Document = $null
    $ui.SessionList.SelectedItem = $docRow
    Show-Selected
    $docSw = [Diagnostics.Stopwatch]::StartNew()
    while ($docSw.Elapsed.TotalSeconds -lt 10 -and -not $ui.PaneDoc.Document) {
        Start-Sleep -Milliseconds 5
        $null = Complete-DocParse
    }
    # Each stage counted separately, so a blank pane says WHICH stage lost the
    # conversation rather than just that it is gone.
    $diagBlocks = @()
    # Assign, then wrap - see the note in the DocJob. The one-step form is
    # what put a blank pane in front of the operator.
    try { $diagGot = Get-SRTranscriptBlocks -JsonlPath "$($docRow.Row.S.jsonl)"; $diagBlocks = @($diagGot) } catch { Note "blocks threw: $($_.Exception.Message)" }
    $diagTurns = @()
    try { $diagTurns = @(Get-ReadTurns $diagBlocks) } catch { Note "turns threw: $($_.Exception.Message)" }
    $diagKinds = @{}
    foreach ($dt in $diagTurns) { $dk = "$($dt.Kind)"; $diagKinds[$dk] = [int]$diagKinds[$dk] + 1 }
    Note ("transcript -> {0} block(s) -> {1} turn(s): {2}" -f $diagBlocks.Count, $diagTurns.Count,
          (@($diagKinds.Keys | Sort-Object | ForEach-Object { "$_=$($diagKinds[$_])" }) -join ' '))
    Note ("toolView is '$($script:toolView)'")

    $doc = $ui.PaneDoc.Document
    if (-not $doc) { Fail 'no document at all for the conversation under test' }
    else {
        $docBlocks = @($doc.Blocks)
        if ($docBlocks.Count -lt 1) {
            Fail 'the document is EMPTY - the pane would show nothing at all'
        } else {
            Pass ("the document carries {0} block(s)" -f $docBlocks.Count)

            # ===============================================================
            # 🔴 THE GUTTER HAS TO ACTUALLY LINE UP, AND NOTHING CHECKED IT.
            #
            # Reported twice as "the text is not aligned". The whole reading
            # pane is built on one claim - that every block kind starts its
            # content at the same x - and that claim was only ever verified by
            # looking at screenshots, which is how a 4px drift survived.
            #
            # Two different constructions have to agree:
            #   a PROSE paragraph hangs off a negative TextIndent with a
            #   fixed-width gutter box as its first inline;
            #   a RAIL block is a BlockUIContainer whose Grid column 0 is that
            #   same width.
            # Measured here in RENDERED coordinates rather than argued about:
            # GetCharacterRect for the text, TransformToAncestor for the panel.
            # ===============================================================
            $ui.PaneDoc.Document = $doc
            $ui.PaneDoc.Measure((New-Object System.Windows.Size 900, 600))
            $ui.PaneDoc.Arrange((New-Object System.Windows.Rect 0, 0, 900, 600))
            $ui.PaneDoc.UpdateLayout()
            [System.Windows.Threading.Dispatcher]::CurrentDispatcher.Invoke(
                [System.Windows.Threading.DispatcherPriority]::Loaded, [action]{})

            $proseX = $null
            $railX  = $null
            foreach ($blk in @($doc.Blocks)) {
                if ((-not $proseX) -and $blk -is [System.Windows.Documents.Paragraph]) {
                    # The first REAL run of prose - skip the gutter box itself,
                    # which is an InlineUIContainer, and any empty spacer.
                    foreach ($inl in @($blk.Inlines)) {
                        if ($inl -is [System.Windows.Documents.Run] -and "$($inl.Text)".Trim().Length -gt 3) {
                            try {
                                $r = $inl.ContentStart.GetCharacterRect([System.Windows.Documents.LogicalDirection]::Forward)
                                if ($r.X -gt 0) { $proseX = [double]$r.X }
                            } catch { }
                            break
                        }
                    }
                }
                if ((-not $railX) -and $blk -is [System.Windows.Documents.BlockUIContainer]) {
                    $g = $blk.Child
                    if ($g -and $g.Children.Count -ge 2) {
                        # Child 0 is the marker in column 0; the LAST child is
                        # the content that sits in column 1.
                        $content = $g.Children[$g.Children.Count - 1]
                        try {
                            $t = $content.TransformToAncestor($ui.PaneDoc)
                            $railX = [double]($t.Transform((New-Object System.Windows.Point 0, 0))).X
                        } catch { }
                    }
                }
            }
            if ($null -eq $proseX -or $null -eq $railX) {
                Note "could not measure both a prose paragraph and a rail block in this tail - alignment unchecked"
            } else {
                $drift = [Math]::Abs($proseX - $railX)
                # One pixel of tolerance for glyph bearing and rounding. Four is
                # what was on screen and is plainly visible in a column of them.
                if ($drift -gt 1.5) {
                    Fail ("the gutter does not line up: prose starts at {0:N1}px, a rail block at {1:N1}px - {2:N1}px apart" -f $proseX, $railX, $drift)
                } else {
                    Pass ("prose and rail blocks start at the same x ({0:N1} vs {1:N1})" -f $proseX, $railX)
                }
            }
            # Pull every run of text out of the flow, whatever it is nested in.
            $docText = New-Object System.Text.StringBuilder
            $stack = New-Object System.Collections.Generic.Stack[object]
            foreach ($blk in $docBlocks) { $stack.Push($blk) }
            $guard = 0
            while ($stack.Count -and $guard -lt 20000) {
                $guard++
                $el = $stack.Pop()
                if ($el -is [System.Windows.Documents.Run]) { $null = $docText.Append("$($el.Text)").Append(' ') ; continue }
                foreach ($p in @('Blocks', 'Inlines', 'ListItems', 'Cells', 'Rows', 'RowGroups')) {
                    try {
                        if ($el.PSObject.Properties[$p] -and $el.$p) { foreach ($kid in $el.$p) { $stack.Push($kid) } }
                    } catch { }
                }
                try { if ($el.PSObject.Properties['Child'] -and $el.Child) { $stack.Push($el.Child) } } catch { }
                try { if ($el.PSObject.Properties['Children'] -and $el.Children) { foreach ($kid in $el.Children) { $stack.Push($kid) } } } catch { }
            }
            $flat = "$($docText.ToString())".Trim()
            if ($flat.Length -lt 40) {
                Fail ("the document renders {0} character(s) of text - the pane is effectively blank" -f $flat.Length)
            } else { Pass ("the document renders {0:N0} characters of the conversation" -f $flat.Length) }
            # 🪤 AND NOT MERELY THE PANE'S OWN FURNITURE. The truncation notice
            # is text too, so a document holding only that would pass the length
            # check while showing the operator nothing they came for.
            $furniture = $flat -replace 'showing the last[^\n]*', '' -replace 'press L to load earlier', ''
            if ("$furniture".Trim().Length -lt 40) {
                Fail 'the only text in the document is the pane''s own truncation notice'
            } else { Pass 'and that text is the conversation, not just the header the pane draws' }

            # ===============================================================
            # 🔴 GROWTH IS AN APPEND, AND IT MUST NOT DRIFT FROM A REBUILD.
            #
            # A working conversation used to rebuild this entire document every
            # time it wrote - measured ~250 ms - and assign a NEW FlowDocument,
            # which resets the scroll extent. Scroll up to read something while
            # a session worked and every write threw you back to where the pane
            # decided. Growth now appends into the document already on screen.
            #
            # The one thing that matters about an append is that it produces
            # what a full rebuild would. A second renderer that drifts from the
            # first is a bug NEITHER HALF CAN SEE - each looks right alone.
            # ===============================================================
            $flatten = {
                param($d)
                $sb = New-Object System.Text.StringBuilder
                $st = New-Object System.Collections.Generic.Stack[object]
                # Pushed in order and popped, so both documents are walked the
                # same way - the comparison is of content, not of traversal.
                foreach ($b in $d.Blocks) { $st.Push($b) }
                $gd = 0
                while ($st.Count -and $gd -lt 40000) {
                    $gd++
                    $e = $st.Pop()
                    if ($e -is [System.Windows.Documents.Run]) { $null = $sb.Append("$($e.Text)").Append("`n"); continue }
                    if ($e -is [System.Windows.Controls.TextBlock]) { $null = $sb.Append("$($e.Text)").Append("`n"); continue }
                    foreach ($p in @('Blocks', 'Inlines')) {
                        try { if ($e.PSObject.Properties[$p] -and $e.$p) { foreach ($k in $e.$p) { $st.Push($k) } } } catch { }
                    }
                    try { if ($e.PSObject.Properties['Child'] -and $e.Child) { $st.Push($e.Child) } } catch { }
                    try { if ($e.PSObject.Properties['Children'] -and $e.Children) { foreach ($k in $e.Children) { $st.Push($k) } } } catch { }
                }
                return $sb.ToString()
            }
            $srcAll = @($script:__blk)
            if ($srcAll.Count -lt 6) { Note "only $($srcAll.Count) blocks here - not enough to exercise the append path" }
            else {
                $keyWas = $script:docKey; $pathWas = $script:docPath
                try {
                    $script:docPath = 'C:\append-under-test.jsonl'
                    $cut = [int]($srcAll.Count * 0.7)
                    if ($cut -lt 2) { $cut = 2 }
                    $head = @($srcAll[0..($cut - 1)])
                    $testKey = ('{0}|{1}|{2}' -f "$($script:docPath)".ToLower(), $script:tailBytes, $script:toolView)

                    $script:docKey = ''; $script:docTurns = $null
                    Set-ReadDocument -Blocks $head -Truncated $false

                    # 🔴 THE FAST PATH MUST ACTUALLY BE TAKEN. Without this the
                    # comparison below passes trivially whenever the append
                    # refuses and silently rebuilds - which is every way this
                    # can regress.
                    $turnsAll = @(Get-ReadTurns $srcAll)
                    if (-not (Test-CanAppend -NewTurns $turnsAll -Key $testKey)) {
                        Fail 'pure growth was refused by the append path - the pane would rebuild on every write'
                    } else {
                        Pass 'a transcript that only grew is recognised as appendable'
                        Set-ReadDocument -Blocks $srcAll -Truncated $false
                        $apCount = $ui.PaneDoc.Document.Blocks.Count
                        $apText = (& $flatten $ui.PaneDoc.Document)

                        # The same content, built from nothing.
                        $script:docKey = ''; $script:docTurns = $null
                        Set-ReadDocument -Blocks $srcAll -Truncated $false
                        $fullCount = $ui.PaneDoc.Document.Blocks.Count
                        $fullText = (& $flatten $ui.PaneDoc.Document)

                        if ($apCount -ne $fullCount) {
                            Fail ("appending produced {0} blocks where a rebuild produces {1}" -f $apCount, $fullCount)
                        } elseif ($apText -ne $fullText) {
                            $n1 = "$apText".Length; $n2 = "$fullText".Length
                            Fail ("appending and rebuilding render different text ({0} vs {1} characters)" -f $n1, $n2)
                        } else {
                            Pass ("appending a grown transcript renders exactly what a rebuild does: {0} blocks, {1:N0} characters" -f $apCount, "$apText".Length)
                        }
                    }
                } finally {
                    $script:docKey = $keyWas; $script:docPath = $pathWas
                    $script:docTurns = $null
                    try { Show-Selected -Force } catch { }
                }
            }

            # ===============================================================
            # 🔴 AND THE MACHINERY MAY NOT DROWN IT. A Remote Control session
            # prints a notice per artifact per reconnect, and folded they were
            # each drawn in full - a rendered pane turned out to be ELEVEN of
            # them in cramped mono above two lines of what claude actually
            # said. That is the "flooded with text" this surface was rebuilt to
            # fix, still present, and invisible to every assertion here because
            # they only ever asked whether text EXISTED.
            #
            # The measure is the ratio: folded, notices must be a minority of
            # the pane. They are merged into one line the way a tool run is.
            # ===============================================================
            $noticeChars = 0
            foreach ($m in [regex]::Matches($flat, '(?i)\b(informational|bridge status|away summary|local command)\b')) {
                $noticeChars += 60
            }
            if ($flat.Length -gt 0 -and $noticeChars -gt ($flat.Length * 0.5)) {
                Fail ("notices are about {0:N0} of {1:N0} characters in the folded pane - they are drowning the conversation" -f $noticeChars, $flat.Length)
            } else { Pass 'folded, the machinery does not outweigh what was said' }
        }
    }

    # A SESSION WRITES -> YOU SEE IT. The watcher raises an event, the lane
    # redraws. This is the number behind "I want to see what is happening".
    # Same reasoning as the document row above: a conversation chosen by
    # position is a different one every run.
    $liveRow = Get-E2EBiggest $e2eRows
    $liveFile = "$($liveRow.Row.S.jsonl)"
    $ui.SessionList.SelectedItem = $liveRow
    $script:selId = $null
    Show-Selected
    Start-TranscriptWatch $liveFile
    $null = @(Get-Event -SourceIdentifier 'SRTranscript' -ErrorAction SilentlyContinue |
              ForEach-Object { Remove-Event -EventIdentifier $_.EventIdentifier -ErrorAction SilentlyContinue })
    $script:transcriptDirty = $false
    # 🪤 APPENDED TO A COPY, NEVER TO THE OPERATOR'S OWN TRANSCRIPT. Writing a
    # line into a live conversation's file to time a redraw would corrupt the
    # record the whole tool reads.
    $watchCopy = Join-Path $SR_StateDir ('e2e-' + [Guid]::NewGuid().ToString('N').Substring(0, 6) + '.jsonl')
    try {
        Copy-Item -LiteralPath $liveFile -Destination $watchCopy -Force
        Start-TranscriptWatch $watchCopy
        $wrote = [Diagnostics.Stopwatch]::StartNew()
        [System.IO.File]::AppendAllText($watchCopy, "{}`n", (New-Object System.Text.UTF8Encoding($false)))
        $saw = $false
        while ($wrote.Elapsed.TotalSeconds -lt 8 -and -not $saw) {
            Start-Sleep -Milliseconds 5
            foreach ($ev2 in @(Get-Event -SourceIdentifier 'SRTranscript' -ErrorAction SilentlyContinue)) {
                Remove-Event -EventIdentifier $ev2.EventIdentifier -ErrorAction SilentlyContinue
                $saw = $true
            }
        }
        $wrote.Stop()
        if (-not $saw) { Fail 'a session writing a line never reached the pane - it is on the 1s backstop' }
        elseif ($wrote.Elapsed.TotalMilliseconds -gt 700) {
            Fail ("a written line takes {0:N0} ms to reach the pane" -f $wrote.Elapsed.TotalMilliseconds)
        } else { Pass ("a session writes to being on screen: {0:N0} ms" -f $wrote.Elapsed.TotalMilliseconds) }
    } finally {
        Stop-TranscriptWatch
        Remove-Item -LiteralPath $watchCopy -Force -ErrorAction SilentlyContinue
    }
}

# ===========================================================================
Write-Host ''
Write-Host '--- the text size reaches the rows without regenerating the list ---'
# ===========================================================================
# 🔴 Step-Zoom USED TO CALL Items.Refresh(), on the belief that rows "carry their
# own measured heights". They do not: every FontSize is a {DynamicResource Sz*}
# and Set-SRTypeScale assigns the resource, which WPF propagates on its own.
# Measured, the refresh changed the height by nothing and cost 339.5 ms against
# the gesture's other 12.5 ms - it regenerated every container to reach the size
# the rows had already taken.
#
# 🪤 THIS ASSERTS THE PROPERTY THE REMOVAL DEPENDS ON, not the removal. If a row
# ever bakes a font-derived number into its item object, the height stops
# tracking and this goes red - which is the thing that would otherwise be noticed
# months later as "the zoom looks wrong sometimes".
$tzWas = $script:Zoom
try {
    function Get-TzRowHeight {
        $ui.SessionList.UpdateLayout()
        for ($i = 0; $i -lt @($ui.SessionList.Items).Count; $i++) {
            if ($ui.SessionList.Items[$i].Kind -ne 'session') { continue }
            $c = $ui.SessionList.ItemContainerGenerator.ContainerFromIndex($i)
            if ($c -and $c.ActualHeight -gt 0) { return [double]$c.ActualHeight }
        }
        return 0.0
    }
    Set-SRTypeScale -Percent 100; Lay
    $tzSmall = Get-TzRowHeight
    # No refresh, no rebuild - only the resource assignment inside Set-SRTypeScale.
    Set-SRTypeScale -Percent 150; Lay
    $tzBig = Get-TzRowHeight
    if ($tzSmall -le 0 -or $tzBig -le 0) { Note 'no realised session row to measure - the type scale is unchecked here' }
    elseif ($tzBig -le $tzSmall) {
        Fail "the row height did not follow the type scale without a refresh ($tzSmall px -> $tzBig px) - something font-derived is baked into the item"
    } else { Pass "the row height follows the type scale with no refresh and no rebuild ($tzSmall px -> $tzBig px)" }

    # And it comes back, so the check above is not just measuring a one-way drift.
    Set-SRTypeScale -Percent 100; Lay
    $tzBack = Get-TzRowHeight
    if ([Math]::Abs($tzBack - $tzSmall) -gt 0.5) { Fail "stepping back left the row at $tzBack px, not the $tzSmall px it started at" }
    else { Pass 'and it comes back when the scale does' }
} finally {
    Set-SRTypeScale -Percent $tzWas
    Lay
}

# 🔴 AND THE REFRESH MUST NOT COME BACK. It is the whole cost of the gesture and
# it buys nothing; a future reader seeing rows "not updating" will reach for it.
$tzSrc = Get-SRBodyOf $winSrc 'function Step-Zoom'
if (-not $tzSrc) { Fail 'Step-Zoom is gone' }
elseif ($tzSrc -match 'Items\.Refresh') {
    Fail 'Step-Zoom regenerates the whole list again - measured at 339.5 ms for a height the rows already had'
} else { Pass 'the text-size gesture does not regenerate the list' }

# ===========================================================================
Write-Host ''
Write-Host '--- the reading pane does not pay for the slow line breaker ---'
# ===========================================================================
# 🔴 THE PANE DOES NOT VIRTUALIZE, so every splitter drag frame, every resize and
# every text-size step re-lays the whole document. Knuth-Plass line breaking cost
# a measured 480 ms against 355 ms on the largest transcript here - about 125 ms
# a reflow, on the one surface that pays it repeatedly.
#
# 🪤 ASSERTED ON THE DOCUMENT, NOT ON THE SOURCE. A source grep would pass
# against a line that had been commented out, or moved somewhere it never runs.
# This asks the FlowDocument the pane actually built.
$lbDoc = $ui.PaneDoc.Document
if (-not $lbDoc) {
    $script:selId = @($script:model | Where-Object { $_.Live })[0].Id
    Show-Selected
    $lbSw = [Diagnostics.Stopwatch]::StartNew()
    while ($lbSw.Elapsed.TotalSeconds -lt 10 -and -not $ui.PaneDoc.Document) {
        [System.Windows.Threading.Dispatcher]::CurrentDispatcher.Invoke(
            [System.Windows.Threading.DispatcherPriority]::Background, [action]{})
    }
    $lbDoc = $ui.PaneDoc.Document
}
if (-not $lbDoc) { Note 'no document rendered - the line breaker cannot be checked' }
elseif ($lbDoc.IsOptimalParagraphEnabled) {
    Fail 'the reading pane has the optimal-paragraph breaker on - it costs ~125 ms on every reflow, and this pane reflows on every drag frame'
}
elseif ($lbDoc.IsHyphenationEnabled) {
    Fail 'hyphenation is on - it was deliberately off, and it is the other half of the same cost'
}
else { Pass 'the reading pane leaves the slow line breaker off, as WPF defaults it' }

# ===========================================================================
Write-Host ''
Write-Host '--- a foldable block in the reading pane can actually be clicked ---'
# ===========================================================================
# 🔴 IT NEVER OPENED, FOR AS LONG AS IT HAS EXISTED. Reported as "clicking a
# foldable block does nothing", and it was all of them - tool runs, THINKING,
# QUEUED, HOOK, NOTICES. The header wired Add_MouseLeftButtonUp, and it lives in
# a BlockUIContainer inside PaneDoc, a FlowDocumentScrollViewer with
# IsSelectionEnabled="True": with selection on, the viewer's TextEditor handles
# button-DOWN and captures the mouse, so the matching Up goes to the capture
# target and never reaches the Border. An Up-only handler in there cannot fire.
#
# 🪤 AND THE OBVIOUS TEST PROVES NOTHING. WPF's MouseLeftButtonDown/Up and their
# previews are DIRECT routed events, so raising one on the Border in a test fires
# the handler whether or not a real click could ever reach it - a "I raised it
# and it toggled" test passes just as well against the broken code. Both kinds
# of check are here and they are labelled for what each one is worth.
$foldWasView = $script:toolView
$script:toolView = 'folded'
$foldRow = $null
foreach ($fr in $script:model) { if ($fr.Live) { $foldRow = $fr; break } }
if (-not $foldRow -and $script:model.Count) { $foldRow = $script:model[0] }
if (-not $foldRow) { Note 'no conversation to render - the fold header cannot be posed' }
else {
    $script:selId = $foldRow.Id
    $ui.PaneDoc.Document = $null
    Show-Selected
    $foldSw = [Diagnostics.Stopwatch]::StartNew()
    while ($foldSw.Elapsed.TotalSeconds -lt 10 -and -not $ui.PaneDoc.Document) {
        [System.Windows.Threading.Dispatcher]::CurrentDispatcher.Invoke(
            [System.Windows.Threading.DispatcherPriority]::Background, [action]{})
    }
    $ui.PaneDoc.Measure((New-Object System.Windows.Size 900, 600))
    $ui.PaneDoc.Arrange((New-Object System.Windows.Rect 0, 0, 900, 600))
    $ui.PaneDoc.UpdateLayout()
    [System.Windows.Threading.Dispatcher]::CurrentDispatcher.Invoke(
        [System.Windows.Threading.DispatcherPriority]::Loaded, [action]{})

    # A fold header is the only Border in there whose Tag carries a Caret and a
    # Panel - that is what Invoke-FoldToggle reads, so it is what identifies one.
    function Find-FoldHeaders { param($El, $Bag)
        if ($El -is [System.Windows.Controls.Border]) {
            $tg = $El.Tag
            if ($tg -is [hashtable] -and $tg.ContainsKey('Caret') -and $tg.ContainsKey('Panel')) {
                $null = $Bag.Add($El)
            }
        }
        $n = [System.Windows.Media.VisualTreeHelper]::GetChildrenCount($El)
        for ($i = 0; $i -lt $n; $i++) {
            Find-FoldHeaders ([System.Windows.Media.VisualTreeHelper]::GetChild($El, $i)) $Bag
        }
    }
    $foldBag = New-Object System.Collections.Generic.List[object]
    Find-FoldHeaders $ui.PaneDoc $foldBag
    $foldHeads = $foldBag.ToArray()

    if (-not $foldHeads.Count) { Note 'this conversation rendered no foldable block - nothing to click' }
    else {
        Note ("$($foldHeads.Count) foldable block(s) in the rendered document")
        $fh = $foldHeads[0]

        # 🔴 THE HIT TEST CANNOT BE RUN HERE, AND THAT IS MEASURED, NOT ASSUMED.
        # InputHitTest is the check that would really discriminate - does a click
        # land on the header or on the selection layer in front of it - and in
        # this suite it returns NULL for EVERYTHING: the fold header, and equally
        # a realised SessionList row whose container this same suite measures
        # elsewhere. Hit testing needs a PresentationSource, and the whole point
        # of this suite is that the window is built and never shown. The control
        # case is asserted below so this stays a known limitation rather than
        # quietly becoming a passing test of nothing.
        $hitCtl = $null
        try { $hitCtl = $ui.SessionList.InputHitTest((New-Object System.Windows.Point 40, 40)) } catch { }
        $hitHdr = $null
        try {
            $tf = $fh.TransformToAncestor($ui.PaneDoc)
            $origin = $tf.Transform((New-Object System.Windows.Point 0, 0))
            $hitHdr = $ui.PaneDoc.InputHitTest(
                (New-Object System.Windows.Point ($origin.X + 5), ($origin.Y + [Math]::Max(2.0, $fh.ActualHeight / 2))))
        } catch { }
        if ($hitCtl) {
            # A window that CAN hit-test has appeared under this suite. Then the
            # real check is available and should be made rather than skipped.
            if (-not $hitHdr) { Fail 'hit testing works here now, and a click inside a fold header lands on nothing' }
            else {
                $inHdr = $false; $walk = $hitHdr
                while ($walk) {
                    if ([object]::ReferenceEquals($walk, $fh)) { $inHdr = $true; break }
                    $walk = [System.Windows.Media.VisualTreeHelper]::GetParent($walk)
                }
                if ($inHdr) { Pass 'a click inside a fold header lands on the header, not on the selection layer' }
                else { Fail "a click inside a fold header lands on $($hitHdr.GetType().Name) - the header never sees it" }
            }
        } else {
            Note 'InputHitTest returns null for a realised SessionList row too - no PresentationSource on an unshown window, so the hit test is unavailable here and the click-lands-where check is NOT made by this suite'
        }

        # 🔑 SO THE INVARIANT IS ASSERTED INSTEAD, and it is the one that actually
        # explains the bug: PaneDoc has selection ON, which is what makes its
        # TextEditor capture the mouse on button-DOWN and swallow the matching Up.
        # These two facts are coupled - with selection off, an Up handler would
        # have worked - so pinning both is what stops the fix being undone from
        # either side.
        if (-not $ui.PaneDoc.IsSelectionEnabled) {
            Note 'PaneDoc no longer has selection enabled - the capture that broke the Up handler is gone, and the coupling below is worth less'
        } else { Pass 'PaneDoc has selection enabled, so its editor captures button-down - an Up-only handler in there cannot fire' }

        # 🪤 THIS ONE IS ABOUT THE TOGGLE, NOT THE CLICK. Direct routed event, so
        # it would have passed against the broken code too - it is here to cover
        # Invoke-FoldToggle's own logic and is worth exactly that much.
        $st = $fh.Tag
        $openWas = [bool]$st.Open
        Invoke-FoldToggle $fh
        $openNow = [bool]$st.Open
        $visNow = "$($st.Panel.Visibility)"
        Invoke-FoldToggle $fh
        $openBack = [bool]$st.Open
        if ($openNow -eq $openWas) { Fail 'toggling a fold header did not change its open state' }
        elseif ($openNow -and $visNow -ne 'Visible') { Fail "it says open but its panel is $visNow" }
        elseif ($openBack -ne $openWas) { Fail 'toggling twice did not put it back' }
        else { Pass 'the toggle opens the panel and closes it again (logic only - a direct event proves nothing about the click)' }
    }
}
$script:toolView = $foldWasView

# 🔴 AND THE WIRING CANNOT BE SILENTLY REVERTED. Up-only is the shape that was
# broken; both together would toggle twice on one click, which looks exactly
# like the bug it replaced.
$foldSrc = Get-SRBodyOf $winSrc 'function New-FoldHeader'
if (-not $foldSrc) { Fail 'New-FoldHeader is gone' }
elseif ($foldSrc -match 'Add_MouseLeftButtonUp') {
    Fail 'the fold header is back on MouseLeftButtonUp - the viewer captures the mouse and it will never fire'
}
elseif ($foldSrc -notmatch 'Add_PreviewMouseLeftButtonDown') {
    Fail 'the fold header no longer handles preview-down, so the click cannot reach it'
}
elseif ($foldSrc -notmatch 'Handled') {
    Fail 'the fold header handles the click but does not mark it handled - the viewer starts a selection drag from it'
}
else { Pass 'the fold header takes preview-down, marks it handled, and no longer waits for an Up that never comes' }

# 🔴 AND IT WAS NEVER ONLY THE FOLD HEADER. Fixing that one turned up three more
# clickable elements built into the SAME document with the SAME Up-only wiring,
# every one of them dead for the same reason: "open its conversation", the way
# BACK out of a sub-agent document, and "load earlier". The first two are the
# only way in and the only way out of that document, so between them the whole
# sub-agent view could be neither entered nor left.
#
# 🪤 SO THE ASSERTION IS ABOUT THE DOCUMENT, NOT ABOUT ONE FUNCTION. Anything
# that puts a clickable element into PaneDoc has to take preview-down; a check
# aimed at New-FoldHeader alone would have said nothing about the other three,
# and said it in green. These are the builders that put UIElements in there.
$docBuilders = @('New-FoldHeader', 'Add-RunDetail', 'Build-ReadDocument', 'Add-ReadLabel', 'Add-MonoDetail')
$deadClicks = @()
foreach ($fn in $docBuilders) {
    $b = Get-SRBodyOf $winSrc "function $fn"
    if (-not $b) { Fail "$fn is gone - the reading pane's click check cannot see it"; continue }
    if ($b -match 'Add_MouseLeftButtonUp') { $deadClicks += $fn }
}
if ($deadClicks.Count) {
    Fail ('clickable elements inside the reading pane still wait for an Up that never arrives, in: ' + ($deadClicks -join ', '))
} else { Pass "no builder that fills the reading pane wires a click to MouseLeftButtonUp ($($docBuilders.Count) checked)" }

# ===========================================================================
Write-Host ''
Write-Host '--- how fast a status changes ---'
# ===========================================================================
# 🔴 THE BAND IS THE WHOLE POINT OF THE LIST. It says which conversations want
# you and which are working, and it used to change on the six-second pass at
# best - the authoritative state behind it comes from the agent probe, which
# spawns claude every fifteen. Answering a question and watching the row stay
# in NEEDS YOU is the complaint this measures.
$statRows = @($ui.SessionList.Items | Where-Object { $_.Kind -eq 'session' -and $_.Row.Live })
if (-not $statRows.Count) { Note 'nothing is live, so a status change cannot be timed' }
else {
    # 1. ANSWERING. Move-RowToWorking is called by Invoke-Answer, Invoke-Send
    #    and Invoke-Compact the moment the send succeeds - this proves the row
    #    really is in WORKING before anything else has had to run.
    $statRow = $statRows[0].Row
    $bandWas2 = "$($statRow.Band)"
    $statRow.Band = 'needs'
    Build-Sessions
    $mv = Ms { Move-RowToWorking $statRow }
    $drawn = @($ui.SessionList.Items | Where-Object { $_.Kind -eq 'session' -and $_.Id -eq $statRows[0].Id })
    if ("$($statRow.Band)" -ne 'working') { Fail 'replying did not move the conversation into WORKING' }
    elseif (-not $drawn.Count) { Fail 'the row vanished from the list after replying' }
    elseif ($mv -gt 250) { Fail ("replying takes {0:N0} ms to show as working" -f $mv) }
    else { Pass ("replying shows as working in {0:N0} ms" -f $mv) }
    $statRow.Band = $bandWas2

    # 2. A SESSION STARTS WRITING. One watcher covers every transcript on the
    #    machine; the lane drains it and runs the file-stat pass. Timed against
    #    a COPY - writing into a live conversation's transcript to time a redraw
    #    would corrupt the record the whole tool reads.
    $statCopy = Join-Path $SR_StateDir ('band-' + [Guid]::NewGuid().ToString('N').Substring(0, 6) + '.jsonl')
    try {
        Start-ProjectsWatch
        if (-not $script:projWatcher) { Fail 'the projects watcher would not start - every status change waits for the 6s pass' }
        else {
            Pass 'every transcript on the machine is watched, not just the selected one'
            # The watcher covers the projects root; a file written anywhere under
            # it must raise an event, which is what the lane acts on.
            $probeDir = Join-Path $env:USERPROFILE '.claude\projects'
            $probeFile = Join-Path $probeDir ('zz-band-probe-' + [Guid]::NewGuid().ToString('N').Substring(0, 6) + '.jsonl')
            try {
                $null = @(Get-Event -SourceIdentifier 'SRProjects' -ErrorAction SilentlyContinue |
                          ForEach-Object { Remove-Event -EventIdentifier $_.EventIdentifier -ErrorAction SilentlyContinue })
                $bsw = [Diagnostics.Stopwatch]::StartNew()
                [System.IO.File]::WriteAllText($probeFile, "{}`n", (New-Object System.Text.UTF8Encoding($false)))
                [System.IO.File]::AppendAllText($probeFile, "{}`n", (New-Object System.Text.UTF8Encoding($false)))
                $sawBand = $false
                while ($bsw.Elapsed.TotalSeconds -lt 8 -and -not $sawBand) {
                    Start-Sleep -Milliseconds 5
                    foreach ($bv in @(Get-Event -SourceIdentifier 'SRProjects' -ErrorAction SilentlyContinue)) {
                        Remove-Event -EventIdentifier $bv.EventIdentifier -ErrorAction SilentlyContinue
                        $sawBand = $true
                    }
                }
                $bsw.Stop()
                if (-not $sawBand) {
                    Fail 'a transcript was written and the watcher never saw it - statuses are back on the 6s pass'
                } elseif ($bsw.Elapsed.TotalMilliseconds -gt 700) {
                    Fail ("a transcript write takes {0:N0} ms to reach the status pass" -f $bsw.Elapsed.TotalMilliseconds)
                } else { Pass ("any session writing reaches the status pass in {0:N0} ms" -f $bsw.Elapsed.TotalMilliseconds) }
            } finally { Remove-Item -LiteralPath $probeFile -Force -ErrorAction SilentlyContinue }
        }
    } finally { Remove-Item -LiteralPath $statCopy -Force -ErrorAction SilentlyContinue }

    # 3. AND THE PASS ITSELF STAYS CHEAP, because it now runs on every write
    #    rather than every six seconds.
    $lwMs = Ms { $null = Update-LiveWriters }
    if ($lwMs -gt 50) { Fail ("the status pass costs {0:N0} ms and now runs on every write" -f $lwMs) }
    else { Pass ("the status pass costs {0:N1} ms" -f $lwMs) }
}

Write-Host ''
Write-Host '--- closing the window does not abandon a send mid-flight ---'
# ===========================================================================
# 🔴 THE BAD DIRECTION HAS TO BE REACHABLE OR THIS PROVES NOTHING. A disposal
# test that passes because nothing was ever in flight is the same green that
# cannot go red as the three already found in this suite today.
#
# So the stand-in job SLEEPS AND THEN WRITES ITS MARKER, in that order - which is
# the shape of the thing being protected. Every send types and then submits as
# two steps (Invoke-SRAnswerTypedOnScreen writes the text, re-reads the screen,
# and only then sends ENTER; Send-SRSessionInput says the same of itself). A
# teardown that does not wait kills the thread between them, and the marker - the
# ENTER - never happens. The marker file IS the submit.
# ===========================================================================
$mark = Join-Path $SR_StateDir ('sendmark-' + [Guid]::NewGuid().ToString('N').Substring(0, 8) + '.txt')
function Start-FakeSend {
    param([int]$Ms, [string]$Marker)
    $rs = [runspacefactory]::CreateRunspace()
    $rs.ApartmentState = 'MTA'; $rs.ThreadOptions = 'ReuseThread'; $rs.Open()
    $rs.SessionStateProxy.SetVariable('SRMark', $Marker)
    $rs.SessionStateProxy.SetVariable('SRMs', $Ms)
    $ps = [powershell]::Create(); $ps.Runspace = $rs
    $null = $ps.AddScript({
        Start-Sleep -Milliseconds $SRMs
        [System.IO.File]::WriteAllText($SRMark, 'submitted')
    })
    $script:ansRs = $rs
    $script:ansPs = $ps
    $script:ansHandle = $ps.BeginInvoke()
    $script:ansFor = @{ Row = [PSCustomObject]@{ Id = 'FAKE-SEND' }; Pid = 0; Index = 0; Kind = 'typed'; At = (Get-Date) }
}
try {
    # 1. NOTHING IN FLIGHT. It must say so rather than inventing work.
    $script:ansPs = $null; $script:ansRs = $null; $script:ansHandle = $null
    $r0 = Stop-SendInFlight -BudgetMs 200
    if ($r0 -ne 'idle') { Fail "with no send in flight it reported '$r0'" }
    else { Pass 'with nothing in flight it reports idle and touches nothing' }

    # 2. IN FLIGHT, AND IT WAITS. The job is deliberately still running when the
    #    close begins - asserted, not assumed - so a teardown that did not wait
    #    would take it apart here.
    Remove-Item -LiteralPath $mark -Force -ErrorAction SilentlyContinue
    Start-FakeSend -Ms 600 -Marker $mark
    if ($script:ansHandle.IsCompleted) {
        Fail 'the stand-in send finished before the close began - the test proves nothing'
    } elseif (Test-Path -LiteralPath $mark) {
        Fail 'the marker existed before the send completed - the test proves nothing'
    } else {
        $r1 = Stop-SendInFlight -BudgetMs 5000
        if ($r1 -ne 'landed') { Fail "a send that had time to finish reported '$r1'" }
        elseif (-not (Test-Path -LiteralPath $mark)) {
            Fail 'the close returned before the send submitted - text would be left typed and unsent'
        } else { Pass 'a send in flight is waited for, and its submit actually happens' }
        if ($script:ansPs -or $script:ansRs -or $script:ansHandle) {
            Fail 'the send runspace was left behind after a clean landing'
        } else { Pass 'and the runspace is released once it has landed' }
    }

    # 3. THE BAD DIRECTION, REACHED ON PURPOSE. A send that outlives the budget
    #    must be REPORTED as abandoned, not silently swallowed - that is the one
    #    case where the operator has to go and look at the session.
    Remove-Item -LiteralPath $mark -Force -ErrorAction SilentlyContinue
    Start-FakeSend -Ms 4000 -Marker $mark
    $r2 = Stop-SendInFlight -BudgetMs 150
    if ($r2 -ne 'abandoned') {
        Fail "a send that outran the budget reported '$r2' - the half-delivered case is not being detected"
    } elseif (Test-Path -LiteralPath $mark) {
        Fail 'the marker appeared anyway - the stand-in is not modelling a two-step send'
    } else {
        Pass 'a send that outruns the budget is reported as abandoned, not swallowed'
    }
    if ($script:ansPs -or $script:ansRs -or $script:ansHandle) {
        Fail 'the send runspace was left behind after an abandoned send'
    } else { Pass 'and the runspace is released either way' }
} finally {
    Remove-Item -LiteralPath $mark -Force -ErrorAction SilentlyContinue
    $script:ansPs = $null; $script:ansRs = $null; $script:ansHandle = $null; $script:ansFor = $null
}

# THE HANDLER ACTUALLY CALLS IT. The function can be perfect and unreached.
$closedSrc = Get-SRBodyOf $winSrc 'Add_Closed'
if (-not $closedSrc) {
    # Add_Closed is a method call taking a scriptblock, not a function, so fall
    # back to the raw text rather than reporting a false pass.
    $closedSrc = $winSrc
}
foreach ($needed in @('Stop-SendInFlight', 'Stop-ReadJobs')) {
    if ($winSrc -notmatch ([regex]::Escape($needed) + '\s*\}?\s*catch')) {
        if ($winSrc -notmatch [regex]::Escape($needed)) {
            Fail "the close handler never calls $needed"
        } else { Pass "$needed is called on close" }
    } else { Pass "$needed is called on close" }
}
# 🪤 AND THE CONFIG FLUSH STAYS FIRST. It is deliberately ahead of the timers,
# the runspaces and the child process because each of those can throw and skip
# whatever came after; the new cleanup went in AFTER it, not before.
$iFlush = $winSrc.IndexOf('Save-SRConfigWrites')
$iSend  = $winSrc.IndexOf('Stop-SendInFlight')
if ($iFlush -lt 0 -or $iSend -lt 0) { Fail 'could not locate the close-handler ordering' }
elseif ($iFlush -gt $iSend) { Fail 'the send wait now runs BEFORE the settings flush - a throw there loses the settings' }
else { Pass 'the settings flush still runs first, before the send wait' }

Write-Host ''
Write-Host '--- the skill picker ---'
# ===========================================================================
$sk = @(Get-SRSkills -Dir "$($pick.D.path)")
if ($sk.Count -lt 5) { Fail "only $($sk.Count) skills found" } else { Pass "reads $($sk.Count) skills off disk" }
if (@($sk | Group-Object { "$($_.Name)".ToLower() } | Where-Object { $_.Count -gt 1 }).Count) {
    Fail 'a skill is listed twice'
} else { Pass 'no skill is listed twice, whichever source it came from' }
$ui.SendBox.Text = 'see the /realign skill'
Update-SkillPop
if ($script:skillOpen) { Fail 'a slash MID-SENTENCE opened the picker' }
else { Pass 'a slash mid-sentence is just a slash' }
$ui.SendBox.Text = '/rea'
Update-SkillPop
if (-not $script:skillOpen) { Fail "'/rea' did not open the picker" }
else { Pass "'/rea' opens the picker with $(@($ui.SkillList.Items).Count) match(es)" }
$ui.SendBox.Text = '/realign now'
Update-SkillPop
if ($script:skillOpen) { Fail 'a space did not close the picker - the name is finished' }
else { Pass 'a space closes it: the name is done and the rest is arguments' }
$ui.SendBox.Text = ''
Update-SkillPop

# ===========================================================================
Write-Host ''
Write-Host '--- the composer grows with what you type ---'
# ===========================================================================
# 🔴 REPORTED: "when I enter the text, the text is cut off and I cannot see my
# full reply ... the text field is not scaling with the amount of input". The
# composer shared the Search style, which pins Height=30 and centres its
# content host, so it was structurally INCAPABLE of growing - and with
# AcceptsReturn="False" and no wrapping, everything past one line's width
# scrolled off to the left where it could not be read back.
$long = 'I need to always at all times be shown what I enter in a conversation, and this line is deliberately longer than one line of the composer so that a box which wraps has to grow taller to hold it.'

if (-not [object]::ReferenceEquals($ui.SendBox.Style, $window.FindResource('Composer'))) {
    Fail 'the composer is not on the Composer style - it is sharing Search again, which pins Height=30'
} else { Pass 'the composer has its own style rather than the search box''s' }

# 🔴 EVERY BOX YOU TYPE SOMETHING READABLE INTO, not just the composer. Asked
# for "the input field for every session ... at all times we can always read
# what we have typed". CastText is a message going to many terminals and
# SetAllow/SetDeny are permission lists that run well past one line - all three
# were pinned to 30px and clipped. The three SEARCH boxes and the two NAME
# fields stay one line on purpose: a filter is not something you read back.
foreach ($n in 'SendBox', 'AskFree', 'CastText', 'SetAllow', 'SetDeny') {
    $b = $ui.$n
    if (-not [object]::ReferenceEquals($b.Style, $window.FindResource('Composer'))) {
        Fail "$n is not on the Composer style - it is pinned to one line and clips what you type into it"
    } elseif ("$($b.TextWrapping)" -ne 'Wrap') {
        Fail "$n does not wrap, so a long line scrolls out of sight sideways"
    } else { Pass "$n wraps and grows with what you type" }
}
# 🪤 AND ONLY THE TWO THAT SHOULD take a literal newline do. Wrapping is visual;
# AcceptsReturn is what the Enter key DOES - and in CastText a newline is an
# Enter in every terminal the message reaches, submitting it half-typed.
foreach ($n in 'SendBox', 'AskFree') {
    if (-not $ui.$n.AcceptsReturn) { Fail "$n cannot hold a second line" }
    else { Pass "$n takes Shift+Enter as a newline" }
}
foreach ($n in 'CastText', 'SetAllow', 'SetDeny') {
    if ($ui.$n.AcceptsReturn) { Fail "$n accepts a literal newline - in CastText that is an Enter in every terminal it reaches" }
    else { Pass "$n wraps but never takes a newline" }
}

$ui.SendBox.Text = ''
Lay
$hEmpty = [double]$ui.SendBox.ActualHeight
$eLines = [int]$ui.SendBox.LineCount
$ui.SendBox.Text = $long
Lay
$hFull  = [double]$ui.SendBox.ActualHeight
$fLines = [int]$ui.SendBox.LineCount
# 🪤 BOTH STATES, READ WHERE THEY HAPPEN. The first version of this note read
# the box AFTER the long text went in while claiming to describe the empty one,
# and reported "text len 194" for what it called empty - three separate wrong
# diagnoses came out of that one misplaced line before the numbers were trusted.
Note ("empty {0:N1}px / {1} line(s)   ->   full {2:N1}px / {3} line(s) for {4} chars   (Send button {5:N1}px, cap {6:N0}px)" -f `
      $hEmpty, $eLines, $hFull, $fLines, $long.Length, $ui.SendBtn.ActualHeight, $ui.SendBox.MaxHeight)
if ($hFull -le $hEmpty + 1) {
    Fail ("the composer did not grow: {0:N0}px empty, {1:N0}px holding {2} characters" -f $hEmpty, $hFull, $long.Length)
} else {
    Pass ("the composer grows: {0:N0}px -> {1:N0}px for {2} characters" -f $hEmpty, $hFull, $long.Length)
}
# 🔑 AND THE CASE THE OPERATOR NAMED: "if we paste a lot of text we can either
# scroll or can also see the text easily". A wall of text must stop growing at
# the cap AND still be reachable - a box that caps without scrolling has simply
# eaten the end of what you pasted.
$wall = ('paste this into the composer and read it back ' * 90)
$ui.SendBox.Text = $wall
$ui.SendBox.CaretIndex = $wall.Length
Lay
$hWall = [double]$ui.SendBox.ActualHeight
if ([Math]::Abs($hWall - [double]$ui.SendBox.MaxHeight) -gt 2) {
    Fail ("{0:N0} characters made the composer {1:N0}px against a {2:N0}px cap - it is not stopping where it should" -f $wall.Length, $hWall, $ui.SendBox.MaxHeight)
} elseif ($ui.SendBox.ExtentHeight -le $ui.SendBox.ViewportHeight + 1) {
    Fail ("{0:N0} characters fit the viewport exactly - the end of a big paste is being dropped, not scrolled" -f $wall.Length)
} else {
    Pass ("{0:N0} pasted characters stop at the {1:N0}px cap and scroll ({2:N0}px of content in a {3:N0}px window)" -f `
          $wall.Length, $ui.SendBox.MaxHeight, $ui.SendBox.ExtentHeight, $ui.SendBox.ViewportHeight)
}
$ui.SendBox.Text = $long
Lay

if ($hFull -gt [double]$ui.SendBox.MaxHeight + 1) {
    Fail ("it grew past its cap: {0:N0}px against MaxHeight {1:N0}px - a long message would push the transcript off the top" -f $hFull, $ui.SendBox.MaxHeight)
} else { Pass ("and it is capped: MaxHeight {0:N0}px" -f $ui.SendBox.MaxHeight) }

# 🔑 THE NEGATIVE CONTROL, and it is the point of this block. "It grew" on its
# own only proves ActualHeight returns a number. The SEARCH box is supposed to
# stay exactly one line high, so the same text through the same measurement has
# to come back unchanged - otherwise this test cannot tell the composer apart
# from any other box and would pass just as happily on the broken build.
$keep = "$($ui.Search.Text)"
$ui.Search.Text = ''
Lay
$sEmpty = [double]$ui.Search.ActualHeight
$ui.Search.Text = $long
Lay
$sFull = [double]$ui.Search.ActualHeight
$ui.Search.Text = $keep
Lay
if ($sFull -ne $sEmpty) {
    Fail ("the search box grew too ({0:N0} -> {1:N0}px) - this measurement is not telling the composer apart from anything else" -f $sEmpty, $sFull)
} else {
    Pass ("negative control: the search box holds {0:N0}px with the very same text" -f $sFull)
}
$ui.SendBox.Text = ''
Lay

# 🔴 THE CARET AND THE PLACEHOLDER MUST START AT THE SAME POINT. Reported after
# the composer was rebuilt: "the cursor when nothing is entered is misaligned
# with a background message". They are two different controls drawn in the same
# cell - a TextBlock and the TextBox's own content host - so nothing makes them
# agree except giving them identical metrics and identical insets. Asserted in
# RENDERED coordinates rather than by reading the XAML back, because the whole
# class of defect here is two things that look equal in markup and are not.
$phC = $null
try { $phC = $ui.SendBox.Template.FindName('ph', $ui.SendBox) } catch { }
if (-not $phC) {
    Fail 'the composer template has no placeholder to line up with'
} else {
    $caret = $ui.SendBox.GetRectFromCharacterIndex(0)
    $orig  = $phC.TransformToVisual($ui.SendBox).Transform((New-Object System.Windows.Point 0, 0))
    $dx = [Math]::Abs($caret.X - $orig.X)
    $dy = [Math]::Abs($caret.Y - $orig.Y)
    Note ("caret ({0:N1}, {1:N1})   placeholder ({2:N1}, {3:N1})   delta ({4:N1}, {5:N1})" -f `
          $caret.X, $caret.Y, $orig.X, $orig.Y, $dx, $dy)
    # 🪤 2px, NOT 0. Measured after the double-padding was removed: 1.6px across
    # and 0.0px down. That residual is WPF's own doing - a TextBox lays its first
    # glyph fractionally right of where a TextBlock lays the same character - and
    # compensating for it would mean a magic number in the template that is wrong
    # at another size or DPI. The tolerance is set just above the real residual,
    # so it still catches what it was written for: the defect it found first was
    # 13.6px across and 6.4px down.
    if ($dx -gt 2.0 -or $dy -gt 1.0) {
        Fail ("the caret and the placeholder do not start in the same place - out by {0:N1}px across and {1:N1}px down" -f $dx, $dy)
    } else {
        Pass ("the caret starts where the placeholder does ({0:N1}px across, {1:N1}px down)" -f $dx, $dy)
    }
}

# ===========================================================================
Write-Host ''
Write-Host '--- what happens between pressing Send and the reply ---'
# ===========================================================================
# Four reports, one surface: no sign the session started working, no way to
# write a second message, and the conversation disappearing after typing.

# 🔴 A CONVERSATION NEVER GETS SHORTER. Every reader in the document path is
# best-effort - the parse runs in a runspace that swallows its own exceptions,
# a tail can miss, a file can be locked mid-write - and each of those hands back
# an EMPTY block list that is indistinguishable from "nothing in this
# conversation". The pane drew that over a conversation that was correct a
# moment earlier. Reported as: I entered something and the content was gone.
$docBefore = $ui.PaneDoc.Document
$turnsBefore = @($script:docTurns).Count
if ($turnsBefore -lt 1) {
    Note 'no document is on screen, so the empty-read guard has nothing to protect - not asserted'
} else {
    Set-ReadDocument -Blocks @()
    $turnsAfter = @($script:docTurns).Count
    if ($turnsAfter -lt $turnsBefore) {
        Fail ("an empty read replaced a {0}-turn conversation with {1} - this is the vanishing content" -f $turnsBefore, $turnsAfter)
    } elseif (-not $ui.PaneDoc.Document) {
        Fail 'an empty read left the pane with no document at all'
    } else {
        Pass ("an empty read keeps the {0} turns already on screen" -f $turnsBefore)
    }
    # 🔑 THE CONTROL. The guard must not be refusing every update - a real read
    # with real blocks still has to land, or the pane would freeze on its first
    # document and never move again.
    $realBlocks = $null
    try { $realBlocks = Get-SRTranscriptBlocks -JsonlPath "$($script:docPath)" -MaxRecords 220 -MaxTailBytes $script:tailBytes } catch { }
    $realArr = @($realBlocks)
    if ($realArr.Count) {
        Set-ReadDocument -Blocks $realArr
        if (@($script:docTurns).Count -lt 1) { Fail 'a real read was refused as well - the pane can no longer update' }
        else { Pass ("and a real read of {0} block(s) still lands" -f $realArr.Count) }
    }
}

# 🔴 BUSY IS NOT A BLOCKER ANY MORE. The box used to be disabled outright while
# a session was mid-turn, which is why a second message could not be written.
# claude ACCEPTS typed input mid-turn and queues it - refusing here made the
# tool less capable than the terminal it is a window onto.
$selIt = $ui.SessionList.SelectedItem
if (-not $selIt -or $selIt.Kind -ne 'session') {
    Note 'no session is selected - the send-state assertions are skipped'
} else {
    $selRow = $selIt.Row
    $statusWas = $(if ($selRow.A) { "$($selRow.A.Status)" } else { '' })
    $askWas = [bool]$script:askSeen["$($selRow.Id)"]
    try {
        if ($selRow.A) {
            $script:askSeen.Remove("$($selRow.Id)")
            $selRow.A.Status = 'busy'
            Update-SendState
            if (-not $ui.SendBox.IsEnabled) {
                Fail 'the composer is disabled while the session is mid-turn - a second message cannot be queued'
            } elseif ("$($ui.SendNote.Visibility)" -ne 'Visible') {
                Fail 'nothing says the message will be queued'
            } elseif ("$($ui.SendNote.Text)" -notmatch 'queue') {
                Fail ("the note does not mention queueing: '{0}'" -f $ui.SendNote.Text)
            } else {
                Pass ("mid-turn you can still type, and it says why: '{0}'" -f $ui.SendNote.Text)
            }

            # 🔴 AND IT SAYS WHERE THE MESSAGE WILL LAND. "queued behind it" is
            # true and useless when four things are already waiting - the real
            # question is whether this is read next or fifth. With three
            # queued, what you are typing is number four.
            $posQWas = $selRow.Q
            try {
                $selRow.Q = [PSCustomObject]@{
                    Items = @(); Count = 3; Mine = 1; Machine = 2; Ok = $true }
                Update-SendState
                if ("$($ui.SendNote.Text)" -notmatch 'position 4') {
                    Fail ("with three already queued the note should place the next at 4: '{0}'" -f $ui.SendNote.Text)
                } else { Pass 'and with three already waiting it says the next one is position 4' }

                $selRow.Q = $null
                Update-SendState
                if ("$($ui.SendNote.Text)" -match 'position') {
                    Fail ("with nothing queued the note still claims a position: '{0}'" -f $ui.SendNote.Text)
                } else { Pass 'and it claims no position when nothing is waiting' }
            } finally {
                # 🪤 PUT THE PANEL BACK TOO, not just the row. Update-SendState
                # drives Update-QueuePanel, which caches what it last drew in
                # $script:qSig - so a test that stages a queue and walks away
                # leaves both the panel and its cache describing a conversation
                # that no longer has one, for every assertion that follows.
                $selRow.Q = $posQWas
                $script:qSig = $null
                try { Update-QueuePanel } catch { }
            }

            # 🪤 THE ONE CASE STILL REFUSED. A session sitting on a MENU reads
            # keystrokes as menu input, so text typed here would PICK AN OPTION
            # rather than queue behind one.
            $null = Set-AskSeen -Id "$($selRow.Id)" -Asking $true
            Update-SendState
            if ($ui.SendBox.IsEnabled) {
                Fail 'the composer accepts typing while the session sits on a menu - those keystrokes would pick an option'
            } else { Pass 'a session waiting on a question still refuses the composer, and says so' }
            $null = Set-AskSeen -Id "$($selRow.Id)" -Asking $false

            # 🔴 AND THE WORKING INDICATOR STARTS AT ONCE. The pulse existed but
            # was driven from the agent probe's status, so it began up to fifteen
            # seconds after the keys were delivered.
            Set-WorkingPulse $false
            Move-RowToWorking $selRow
            if (-not $script:pulseOn) {
                Fail 'sending did not start the working pulse - nothing moves until the next probe'
            } else { Pass 'sending starts the working pulse immediately, not on the next probe' }
        }
    } finally {
        if ($selRow.A) { try { $selRow.A.Status = $statusWas } catch { } }
        $null = Set-AskSeen -Id "$($selRow.Id)" -Asking $askWas
        Update-SendState
    }
}

# 🔴 THE CONTEXT CHIP IS ASKED FOR AGAIN UNTIL THE BAR ARRIVES. Reported as "I
# do not see the context upon restarting the sessions, only after a while". The
# chip comes from the session's own status bar and nothing else - that rule is
# staying, it was made against measurements - but the screen was read ONCE per
# selection, so a conversation that had not printed a bar yet waited for the
# slow rotation. Same single source, asked more than once.
$ctxRow = Get-SelectedRow
if (-not $ctxRow -or -not $ctxRow.A -or -not $ctxRow.A.Pid) {
    Note 'no running session is selected - the context retry is not exercised'
} else {
    $cid = "$($ctxRow.Id)"
    $ctxSigWas = $script:rowScreen[$cid]
    try {
        $script:rowScreen.Remove($cid)
        $script:ctxFor = ''; $script:ctxTries = 0; $script:ctxAt = $null
        $script:askWanted = $false
        Request-ContextRetry
        if (-not $script:askWanted) { Fail 'no context bar is known and nothing asked for one' }
        else { Pass 'with no context bar known, the screen is asked for again' }

        # 🪤 IT MUST NOT SPIN. This is called from a lane running ten times a
        # second, and each attempt is a child process against another console.
        $script:askWanted = $false
        Request-ContextRetry
        if ($script:askWanted) { Fail 'it asked twice inside the retry interval - that is a child process ten times a second' }
        else { Pass ('and not again inside {0:N0}s, so it cannot spin at lane speed' -f $SR_CtxRetrySecs) }

        $script:ctxTries = $SR_CtxRetryMax
        $script:ctxAt = $null
        $script:askWanted = $false
        Request-ContextRetry
        if ($script:askWanted) { Fail 'it kept asking past its ceiling - a spinner nobody can see, for the life of the window' }
        else { Pass ('and gives up after {0} attempts rather than chasing forever' -f $SR_CtxRetryMax) }

        # 🔑 AND IT STOPS THE MOMENT THE BAR IS THERE - the whole point of the
        # retry is that it ENDS.
        $null = Set-RowScreenSig -Id $cid -Shells 0 -Agents 0 -CtxTokens 1234 -CtxWindow 200000
        $script:ctxFor = ''; $script:ctxTries = 0; $script:ctxAt = $null
        $script:askWanted = $false
        Request-ContextRetry
        if ($script:askWanted) { Fail 'it is still chasing a context bar it already has' }
        else { Pass 'once the bar is known it stops asking' }
    } finally {
        if ($ctxSigWas) { $script:rowScreen[$cid] = $ctxSigWas } else { $script:rowScreen.Remove($cid) }
        $script:ctxFor = ''; $script:ctxTries = 0; $script:ctxAt = $null
        $script:askWanted = $false
    }
}

# ===========================================================================
Write-Host ''
Write-Host '--- collapsing the projects and sessions columns ---'
# ===========================================================================
# Asked for: collapse the projects and sessions tabs so the pane where you read
# a session gets bigger. Three decisions were put up and all three are asserted
# here: the manual choice overrides the width rule, the sessions column
# collapses to a STRIP rather than to nothing, and the labels say what pressing
# them does.
#
# 🪤 Update-Columns, NOT Invoke-ColumnFold. The button path calls
# Save-SRConfigValue, which writes the OPERATOR'S REAL CONFIG - a test that
# flips a setting on the machine it runs on has changed the thing it was
# measuring. The decision and the applier are exercised directly; the button is
# checked for existence and its handler left alone.
$foldRailWas = $script:foldRail
$foldListWas = $script:foldList

# 🔴 FOUR CARETS, TWO ACTIONS. The first attempt put two text buttons in the
# header row and the operator could not find them - "I still do not see the
# collapse buttons" - which for a control is the same as not having one. Each
# column's own header collapses it; the strip it collapses to opens it again,
# so neither collapse can strand you with no way back.
$absentFold = @(@('RailFold', 'ListFold', 'RailStrip', 'RailOpen', 'ListOpen',
                  'ListStrip', 'StripList', 'StripCount') | Where-Object { -not $ui.$_ })
if ($absentFold.Count) { Fail ("the collapse controls are missing: {0}" -f ($absentFold -join ', ')) }
else { Pass 'four carets are wired: one on each column header, one on each strip' }
# 🪤 AND THE OLD BUTTONS ARE GONE, not left beside them. Two controls for one
# action is the smell this replaced.
if ($ui.FoldRail -or $ui.FoldList) {
    Fail 'the header fold buttons are still there alongside the carets - two controls for one action'
} else { Pass 'the header buttons they replace are gone, not kept beside them' }
if (-not (Get-Command Invoke-ColumnFold -ErrorAction SilentlyContinue)) {
    Fail 'Invoke-ColumnFold is not defined - the buttons and Ctrl+1/Ctrl+2 have nothing to call'
} else { Pass 'Invoke-ColumnFold is defined for the buttons and the shortcuts' }

# Open, and remember the width it is opened at.
$script:foldList = $false
$script:foldApplied = ''
Update-Columns
Lay
$listOpenW = [double]$ui.ListCol.Width.Value
if ("$($ui.ListPane.Visibility)" -ne 'Visible' -or "$($ui.ListStrip.Visibility)" -eq 'Visible') {
    Fail 'the sessions column is not showing when it is pinned open'
} elseif ("$($ui.ListFold.Text)".Trim() -eq "$($ui.ListOpen.Text)".Trim()) {
    # 🪤 THE TWO CARETS MUST NOT LOOK THE SAME. One collapses and one opens, and
    # they are never on screen together - so if they were drawn identically the
    # only cue for which state you are in would be gone. This replaces a check on
    # the old buttons' labels, which said what pressing them did; a caret says it
    # by pointing, and the direction is the thing that can be got backwards.
    Fail ("both sessions carets draw '{0}' - one collapses and one opens" -f $ui.ListFold.Text)
} else { Pass ("open: the sessions column is {0:N0}px, and its caret points the other way from the strip's" -f $listOpenW) }

# 🔴 COLLAPSED TO A STRIP, NOT TO NOTHING. The window's whole job is saying
# which conversation is waiting on you, and a collapse that hides that turns the
# tool off while you use it.
$script:foldList = $true
$script:foldApplied = ''
Update-Columns
Lay
if ("$($ui.ListPane.Visibility)" -eq 'Visible') {
    Fail 'the sessions list is still drawn while the column is collapsed'
} elseif ("$($ui.ListStrip.Visibility)" -ne 'Visible') {
    Fail 'the column collapsed to nothing - a conversation can now need you with nowhere on screen to say so'
} elseif ([Math]::Abs([double]$ui.ListCol.Width.Value - $SR_StripWidth) -gt 0.5) {
    Fail ("the collapsed column is {0:N0}px, not the {1:N0}px strip" -f $ui.ListCol.Width.Value, $SR_StripWidth)
} elseif ("$($ui.RailFold.Text)".Trim() -eq "$($ui.RailOpen.Text)".Trim()) {
    Fail ("both projects carets draw '{0}' - one collapses and one opens" -f $ui.RailFold.Text)
} else {
    Pass ("collapsed: a {0:N0}px strip stands in for the list, with a caret on it to open it again" -f $ui.ListCol.Width.Value)
}
$needs   = @($script:model | Where-Object { "$($_.Band)" -eq 'needs'   -and (Test-OnSurface $_) })
$working = @($script:model | Where-Object { "$($_.Band)" -eq 'working' -and (Test-OnSurface $_) })
$onStrip = @($ui.StripList.ItemsSource)
if ($onStrip.Count -ne ($needs.Count + $working.Count)) {
    Fail ("the strip shows {0} dot(s) for {1} waiting and {2} working" -f $onStrip.Count, $needs.Count, $working.Count)
} elseif ("$($ui.StripCount.Text)" -ne "$($needs.Count)" -and $needs.Count -gt 0) {
    # 🪤 THE COUNT IS THE WAITING ONES. The dots show two states; a number over
    # them that meant "both" would answer a question nobody asked.
    Fail ("the count reads '{0}' for {1} conversation(s) waiting on you" -f $ui.StripCount.Text, $needs.Count)
} else {
    Pass ("the strip carries {0} waiting + {1} working, and the count is the waiting ones: '{2}'" -f `
          $needs.Count, $working.Count, $ui.StripCount.Text)
}
# 🔑 AND THE TWO STATES ARE TOLD APART. One accent for both would make the
# second band pure noise - more dots saying nothing new.
$hues = @(@($onStrip | ForEach-Object { "$($_.Accent)" }) | Sort-Object -Unique)
if ($needs.Count -gt 0 -and $working.Count -gt 0 -and $hues.Count -lt 2) {
    Fail 'waiting and working dots are drawn in the same accent - the second band adds nothing'
} else { Pass ("the strip's dots carry {0} distinct accent(s)" -f $hues.Count) }

# 🪤 AND THE WIDTH COMES BACK. The strip's 44px must never be mistaken for the
# column's own width, or re-opening would give you a 44px sessions list.
$script:foldList = $false
$script:foldApplied = ''
Update-Columns
Lay
if ([Math]::Abs([double]$ui.ListCol.Width.Value - $listOpenW) -gt 1.0) {
    Fail ("re-opening gave the column {0:N0}px instead of the {1:N0}px it had - the strip's width was remembered as its own" -f $ui.ListCol.Width.Value, $listOpenW)
} else { Pass ("re-opening restores the width it had ({0:N0}px)" -f $listOpenW) }

# The projects rail collapses to NOTHING, deliberately: it is a filter, and
# nothing in it says a conversation needs you.
$script:foldRail = $true
$script:foldApplied = ''
Update-Columns
Lay
if ("$($ui.RailPane.Visibility)" -eq 'Visible') {
    Fail 'the projects rail is still drawn while collapsed'
} elseif ("$($ui.RailStrip.Visibility)" -ne 'Visible') {
    # 🪤 A CONTROL THAT COLLAPSES ITS OWN COLUMN AND LEAVES NOTHING BEHIND has
    # removed the only way back. The caret is the whole of the collapsed rail.
    Fail 'the rail collapsed to nothing at all - there is no caret left to open it again'
} elseif ([double]$ui.RailCol.Width.Value -gt $SR_RailStripWidth + 0.5) {
    Fail ("the collapsed rail takes {0:N0}px, more than the {1:N0}px caret" -f $ui.RailCol.Width.Value, $SR_RailStripWidth)
} else {
    Pass ("the projects rail collapses to its caret and nothing else ({0:N0}px)" -f $ui.RailCol.Width.Value)
}

# 🔴 THE MANUAL CHOICE OVERRIDES THE WIDTH RULE. Asked and answered: your choice
# wins, always. Get-ColumnFold must return what was set regardless of how wide
# the window happens to be.
$script:foldRail = $true; $script:foldList = $true
$gc = Get-ColumnFold
if (-not $gc.Rail -or -not $gc.List) { Fail 'a pinned-collapsed column reads as open - the width rule is overriding the operator' }
else {
    $script:foldRail = $false; $script:foldList = $false
    $gc2 = Get-ColumnFold
    if ($gc2.Rail -or $gc2.List) { Fail 'a pinned-open column reads as collapsed' }
    else { Pass 'a column set by hand keeps that setting whatever the window width says' }
}
# 🪤 $null IS A THIRD STATE: unset means "follow the width", not "open". A bool
# here would kill the adaptive layout on every fresh install.
$script:foldRail = $null; $script:foldList = $null
$gc3 = Get-ColumnFold
if ($null -eq $gc3.Rail -or $null -eq $gc3.List) { Fail 'unset does not resolve to a decision at all' }
else { Pass 'unset falls back to the width rule rather than to a pinned state' }

$script:foldRail = $foldRailWas
$script:foldList = $foldListWas
$script:foldApplied = ''
Update-Columns
Lay

# ===========================================================================
Write-Host ''
Write-Host '--- the morning compact, across every ticked conversation ---'
# ===========================================================================
# Asked for: a central way to tell all ~20 open sessions to compact and keep
# the working state, findings, tasks, next items and rulings - so the morning
# starts small without losing what each lane knows.
if (-not $ui.CastCompact) {
    Fail 'Send-to-many has no morning-compact control'
} else {
    $castWas = "$($ui.CastText.Text)"
    $brief = Get-SRCompactBrief
    # 🔴 ONE LINE, AND IT STARTS WITH THE COMMAND. /compact takes instructions;
    # a brief sent as a separate message would spend a turn per session and
    # still leave the summariser guessing at what mattered.
    if ($brief -notmatch '^/compact\s+\S') {
        Fail ("the brief is not a /compact with instructions on it: '{0}'" -f $brief.Substring(0, [Math]::Min(60, $brief.Length)))
    } else { Pass 'the brief is a single /compact carrying its instructions' }
    foreach ($must in @('OPEN', 'next item', 'verbatim')) {
        if ($brief -notmatch [regex]::Escape($must)) { Fail ("the brief never mentions '{0}'" -f $must) }
    }
    Pass 'it names what to keep: what is open, the next item, and that identifiers stay verbatim'
    # 🪤 IT FILLS THE BOX, IT DOES NOT SEND. Twenty sessions compacting is not
    # something to set off with one press and no chance to read what goes out.
    $ui.CastText.Text = ''
    $ui.CastCompact.RaiseEvent((New-Object System.Windows.RoutedEventArgs ([System.Windows.Controls.Button]::ClickEvent)))
    if ("$($ui.CastText.Text)" -ne $brief) {
        Fail 'pressing it did not put the brief in the box where it can be read'
    } else { Pass 'pressing it fills the box for review rather than sending' }
    $ui.CastText.Text = $castWas
}

# ===========================================================================
Write-Host ''
Write-Host '--- the live screen while a compact runs ---'
# ===========================================================================
# 🔴 REPORTED: "when I compact a session, the session is not shown any longer
# or I do not see the progress of what is happening when I compact something."
# The cause is not a bug in the pane - it is that a compact writes NOTHING to
# the transcript until it finishes, so for 30-90s there is nothing on disk to
# draw. The fix reads the session's screen instead, and the whole question is
# WHEN to do that. This exercises that decision without needing a real compact.
$missing = @($('LivePane','LiveMark','LiveHead','LiveText') | Where-Object { -not $ui.$_ })
if ($missing.Count) { Fail ("the live-screen panel is missing: {0}" -f ($missing -join ', ')) }
else { Pass 'the live-screen panel is wired: LivePane, LiveMark, LiveHead, LiveText' }

# 🔴 SHAPED LIKE A REAL ROW, AND THAT IS THE WHOLE POINT. The first version of
# these fixtures carried the state on a `D` property because that is what
# Test-SRCompacting read - so the test proved the function agreed with the test
# and nothing about the rows the window holds. D is the DIRECTORY object; the
# state lives on Conv (see Get-Band). A hand-built fixture can only ever confirm
# the shape its author believed in, which is why the shape here is copied from
# Update-Model's own row rather than invented.
$fakeId  = 'test-compact-0000'
$rowBusy = [PSCustomObject]@{ Id = $fakeId
                              A    = [PSCustomObject]@{ Pid = 4242; Status = 'busy' }
                              Conv = [PSCustomObject]@{ State = 'working' } }
$rowIdle = [PSCustomObject]@{ Id = $fakeId
                              A    = [PSCustomObject]@{ Pid = 4242; Status = 'waiting' }
                              Conv = [PSCustomObject]@{ State = 'waiting' } }
$script:compactSent.Remove($fakeId)

# 🔑 THE FIXTURE IS CHECKED AGAINST A REAL ROW. This is the assertion that was
# missing when the defect above shipped: without it, a hand-built row can agree
# perfectly with a function that is reading the wrong property, and both can be
# wrong together for as long as nobody looks at the window.
$realRow = @($script:model | Where-Object { $_.Conv }) | Select-Object -First 1
if (-not $realRow) {
    Note 'no row with a Conv to check the fixture shape against - the shape check is skipped'
} else {
    $absent = @(@('Id', 'A', 'Conv') | Where-Object { $null -eq $realRow.PSObject.Properties[$_] })
    if ($absent.Count) {
        Fail ("a real row has no {0} - the compact fixtures are shaped like nothing the window holds" -f ($absent -join ', '))
    } elseif ($null -eq $realRow.Conv.PSObject.Properties['State']) {
        Fail 'a real row''s Conv carries no State - Test-SRCompacting is reading a property that does not exist'
    } else {
        Pass 'the compact fixtures carry the properties a real row actually has'
    }
}

if (Test-SRCompacting $rowBusy) { Fail 'a session nobody compacted reads as compacting - the pane would be replaced at random' }
else { Pass 'a session nobody compacted is left alone' }

$script:compactSent[$fakeId] = Get-Date
if (-not (Test-SRCompacting $rowBusy)) { Fail 'a compact we just sent is not being watched' }
else { Pass 'a compact we just sent is watched' }

# 🪤 THE 12-SECOND FLOOR. /compact is typed into a terminal and takes a moment
# to be picked up, so for the first seconds the session still reads 'waiting'
# and the transcript still says whatever it said before - which is
# indistinguishable from "finished" and would close the panel before it drew.
if (-not (Test-SRCompacting $rowIdle)) {
    Fail 'a compact sent a second ago was called finished because the session had not picked it up yet'
} else { Pass 'the floor holds: a compact is not called finished before it has started' }

$script:compactSent[$fakeId] = (Get-Date).AddSeconds(-30)
if (Test-SRCompacting $rowIdle) { Fail 'a finished compact is still being watched' }
elseif ($script:compactSent.ContainsKey($fakeId)) { Fail 'a finished compact was not forgotten - the table would grow for the life of the window' }
else { Pass 'a finished compact stops being watched, and is forgotten' }

$script:compactSent[$fakeId] = (Get-Date).AddSeconds(-($SR_CompactWatch + 5))
if (Test-SRCompacting $rowBusy) { Fail 'a compact that never returns is watched forever' }
else { Pass ('a compact is abandoned after {0}s even while the session stays busy' -f $SR_CompactWatch) }
$script:compactSent.Remove($fakeId)

# The other signal: a compact typed straight into the terminal, which this
# window never saw sent.
$rowSumm = [PSCustomObject]@{ Id = 'test-compact-other'
                              A    = [PSCustomObject]@{ Pid = 4242; Status = 'busy' }
                              Conv = [PSCustomObject]@{ State = 'summarising' } }
if (-not (Test-SRCompacting $rowSumm)) { Fail 'a compact typed in the terminal is invisible here' }
else { Pass 'a compact typed in the terminal is picked up from the transcript' }

# 🔑 THE SHOWING PATH, ON THE REAL CONTROLS. Everything above tests a decision;
# this tests the thing the operator actually sees. The row is made up and its
# pid does not exist, so the screen read fails and the panel falls back to its
# waiting text - which is the point: no probe is pointed at a real conversation,
# and the visibility switch is still exercised end to end.
$script:compactSent[$fakeId] = Get-Date
Update-LivePane -Row $rowBusy
if ("$($ui.LivePane.Visibility)" -eq 'Collapsed') {
    Fail 'a compact is in flight and the live pane did not appear'
} elseif ("$($ui.PaneDoc.Visibility)" -ne 'Collapsed') {
    Fail 'the live pane appeared but the transcript is still drawn underneath it'
} elseif (-not "$($ui.LiveText.Text)".Trim()) {
    Fail 'the live pane is showing an empty box - a failed screen read left nothing to look at'
} else {
    Pass ("a compact in flight puts the screen in the pane: '{0}'" -f "$($ui.LiveHead.Text)")
}
$script:compactSent.Remove($fakeId)

# ...and it has to LEAVE again. A panel that shows itself and never goes away
# would hide every transcript for the rest of the session.
Update-LivePane
if ("$($ui.LivePane.Visibility)" -ne 'Collapsed') { Fail 'the live pane is still showing with nothing to watch' }
elseif ("$($ui.PaneDoc.Visibility)" -eq 'Collapsed') { Fail 'the transcript never came back after the compact finished' }
else { Pass 'and when it finishes the cell goes back to the transcript' }

# ===========================================================================
Write-Host ''
Write-Host '--- the seam, and the frame ---'
# ===========================================================================
# The window paints its own caption, so the OS one is gone and these have to work.
foreach ($n in @('WinMin','WinMax','WinClose','TitleBar')) {
    if (-not $ui.$n) { Fail "the custom title bar has no '$n'" }
}
Pass 'the custom title bar carries drag, minimise, maximise and close'
$chrome = [System.Windows.Shell.WindowChrome]::GetWindowChrome($window)
if (-not $chrome) { Fail 'no WindowChrome - the window would lose Aero Snap and edge resize' }
# 🔴 CaptionHeight MUST BE NON-ZERO, and this assertion used to demand the
# opposite. At 0 the window could not be MOVED at all: Windows was told there is
# no caption, so drag, snap, aero-shake, Win+arrow and the Alt+Space menu were
# all gone, and only the app's own maximise and close buttons worked. Reported
# by the operator. It must also match the header's height, or part of the strip
# drags and part does not - measured from the WINDOW's top edge, which is not
# where the header starts: the app is a card inset inside the window, so the
# caption has to cover that inset as well or the top band of the header is dead.
elseif ($chrome.CaptionHeight -le 0) {
    Fail 'CaptionHeight is 0 - Windows will not move this window at all'
} else {
    $inset = 0.0
    if ($ui.Shell) { $inset = $ui.Shell.Margin.Top }
    $want = $ui.TitleBar.Height + $inset
    if ([Math]::Abs($chrome.CaptionHeight - $want) -gt 0.5) {
        Fail ("CaptionHeight is $($chrome.CaptionHeight) but the header ends at $want " +
              "($($ui.TitleBar.Height) header + $inset inset) - part of the strip would not drag")
    } else {
        Pass ("Windows drags the window by its $($chrome.CaptionHeight)px caption " +
              "($($ui.TitleBar.Height) header + $inset inset), and still snaps and resizes it")
    }
}

# Everything interactive sitting ON that caption must opt out of the chrome, or
# Windows treats the click as a drag and the control never sees it.
foreach ($n in @('Search', 'WinMin', 'WinMax', 'WinClose', 'Rescan', 'NewSession')) {
    $el = $ui.$n
    $inChrome = $false
    $walk = $el
    while ($walk -and -not $inChrome) {
        try { $inChrome = [System.Windows.Shell.WindowChrome]::GetIsHitTestVisibleInChrome($walk) } catch { }
        if ($inChrome) { break }
        $walk = $(if ($walk -is [System.Windows.FrameworkElement]) { $walk.Parent } else { $null })
    }
    if (-not $inChrome) { Fail "'$n' sits on the caption but is not hit-test visible in chrome - clicking it would drag the window" }
}
Pass 'every control on the caption is clickable rather than draggable'

# ===========================================================================
Write-Host ''
Write-Host '--- the shipped typeface reaches the text, not just the key ---'
# ===========================================================================
# 🔴 THIS ASKS A REALISED TextBlock WHAT IT IS DRAWN WITH. The font suite asked
# FindResource('FontText') what the KEY resolved to, which was Manrope, and the
# window was still rendering Segoe everywhere: Install-SRTypeface replaces the
# dictionary entry after this file is parsed, and a {StaticResource FontText}
# inside a Setter had already captured the OLD FontFamily object and stopped
# looking at the key. Every style is a DynamicResource now. Asking the key
# proves nothing - it passed throughout - so this asks the control.
# 🔴 THE EXPECTED FACE IS ASKED OF THE WINDOW, NOT TYPED IN. This block used to
# name Manrope, and when the chrome moved to IBM Plex Mono it failed on six
# controls that were drawing exactly what they should - the assertion had
# outlived the face it was written for, which is the third time that shape has
# cost something today. It reads FontPane now, and a separate assertion further
# up pins FontPane to a real family, so this is not circular: one test says what
# the shipped face IS, these say the controls reached it.
$faceWant = ''
if ($script:hasPlex) { $faceWant = "$($window.Resources['FontPane'].Source)" }
elseif ($script:hasManrope) { $faceWant = "$($window.Resources['FontText'].Source)" }

if ($faceWant) {
    Lay
    $off = @()
    foreach ($n in @('PaneName', 'Status', 'SheetTitle', 'SheetBody', 'ListCaption', 'PaneState')) {
        $el = $ui.$n
        if ($el -and "$($el.FontFamily.Source)" -ne $faceWant) { $off += "$n on '$($el.FontFamily.Source)'" }
    }
    if ($off.Count) { Fail ("the shipped typeface never reached (want '$faceWant'): " + ($off -join '; ')) }
    else { Pass "the header, the status line, the list and the sheet all draw in the shipped face" }

    # And the styles themselves, which is where the break actually was.
    $stale = @()
    foreach ($k in @('Display', 'H1', 'Caption', 'Body', 'Dim', 'Meta')) {
        $st = $window.FindResource($k)
        $f = @($st.Setters | Where-Object { $_.Property.Name -eq 'FontFamily' })[0]
        $v = $(if ($f) { $f.Value } else { $null })
        # A DynamicResource setter holds the EXTENSION, not the value - which is
        # the point: it is resolved per-use, so the swap reaches it.
        if ($v -is [System.Windows.Media.FontFamily] -and "$($v.Source)" -notlike '*Manrope*') { $stale += $k }
    }
    if ($stale.Count) { Fail ('these styles captured the old face at parse time: ' + ($stale -join ', ')) }
    else { Pass 'no text style holds a face captured before the swap' }
} else {
    Note 'lib\fonts\Manrope.ttf is absent - the typeface assertions are skipped, as the window is on the system face by design'
}

# ===========================================================================
Write-Host ''
Write-Host '--- one type scale, and the zoom moves all of it ---'
# ===========================================================================
# 🔴 SAME RULE AS THE BLOCK ABOVE: ASK THE CONTROL. A zoom that writes the six
# Sz* resources and never reaches a realised TextBlock is the FontFamily bug
# wearing different clothes, and it would pass any assertion made against
# FindResource. So every check here reads FontSize off something on screen.
Lay
function Get-TextBlocks { param($El, [int]$Depth = 0)
    $out = @()
    if (-not $El -or $Depth -gt 40) { return $out }
    if ($El -is [System.Windows.Controls.TextBlock]) { $out += $El }
    $n = 0
    try { $n = [System.Windows.Media.VisualTreeHelper]::GetChildrenCount($El) } catch { return $out }
    for ($i = 0; $i -lt $n; $i++) {
        $c = $null
        try { $c = [System.Windows.Media.VisualTreeHelper]::GetChild($El, $i) } catch { }
        if ($c) { $out += Get-TextBlocks $c ($Depth + 1) }
    }
    return $out
}

$scale = @{}
foreach ($k in @('Micro', 'Caption', 'Body', 'Mono', 'Strong', 'Display', 'Pane')) {
    $scale[$k] = [double]$window.Resources["Sz$k"]
}

# 🔴 THE PARITY CHECK THAT USED TO LIVE HERE IS GONE, AND ITS REMOVAL IS THE
# POINT. It asserted that Manrope prose and Cascadia machine text drew the same
# x-height - 6.48px against 6.47px, which it passed, correctly, right up until
# the operator reported the pane as "too terminal-like". That was the defect:
# tool traffic outnumbers prose FIVE TO ONE here, so drawing it exactly as
# prominent as prose makes five-sixths of the surface read at full strength,
# which is what a terminal looks like. The test was true and the design was
# wrong, so a passing parity assertion is not something to preserve.
#
# The contract now is stricter and much simpler: ONE face, ONE size, for every
# category of message. There is no ratio left to get wrong.
$paneFam = $window.Resources['FontPane']
if ($paneFam -isnot [System.Windows.Media.FontFamily]) {
    Fail 'FontPane is not a FontFamily - the transcript has no face of its own'
} else {
    $src = "$($paneFam.Source)"
    if ($src -notlike '*IBM Plex Mono*') {
        Fail ("the pane face is '{0}', not IBM Plex Mono - lib\fonts did not load and the transcript is on the fallback stack" -f $src)
    } else {
        # 🪤 THE FACE COUNT IS THE POINT OF SHIPPING THREE FILES. A family with
        # only a Regular makes WPF synthesise bold and italic, and a synthesised
        # bold is exactly the smeared weight the operator called "fat". Fragment
        # Mono lost the face comparison on this and nothing else.
        $faceN = @($paneFam.GetTypefaces()).Count
        if ($faceN -lt 2) {
            Fail ("IBM Plex Mono exposes {0} face - every bold in the transcript would be synthesised" -f $faceN)
        } else {
            Pass ("the transcript has one face of its own: IBM Plex Mono, {0} real typefaces" -f $faceN)
        }
        $tf = New-Object System.Windows.Media.Typeface $paneFam,
                  ([System.Windows.FontStyles]::Normal), ([System.Windows.FontWeights]::Normal),
                  ([System.Windows.FontStretches]::Normal)
        $gt = $null
        if ($tf.TryGetGlyphTypeface([ref]$gt)) {
            Note ('pane: {0} at {1}px - x-height {2:N2}px ({3:N3} em)' -f $src, $scale.Pane, ($gt.XHeight * $scale.Pane), $gt.XHeight)
        }
    }
}
if ([Math]::Abs($script:readSize - $script:MonoSize) -gt 0.01) {
    Fail ('prose and machine text are still two sizes: {0} and {1}' -f $script:readSize, $script:MonoSize)
} else {
    Pass ('prose and machine text are one size ({0}px)' -f $script:readSize)
}

# 🔴 THE MEASURE'S CHARACTER WIDTH MUST COME FROM THE FACE THAT IS DRAWN. It was
# a literal 0.52 - Manrope's average advance - and it stayed that way when the
# pane went monospaced, so a column asked for 100 characters was sized for 87.
# A hard-coded metric outlives the face it was measured from, silently.
$expAdv = -1.0
try {
    $tfM = New-Object System.Windows.Media.Typeface $window.Resources['FontPane'],
               ([System.Windows.FontStyles]::Normal), ([System.Windows.FontWeights]::Normal),
               ([System.Windows.FontStretches]::Normal)
    $gtM = $null
    if ($tfM.TryGetGlyphTypeface([ref]$gtM)) {
        $expAdv = [double]$gtM.AdvanceWidths[$gtM.CharacterToGlyphMap[[int][char]'0']]
    }
} catch { }
if ($expAdv -lt 0) {
    Note 'the pane face exposes no glyph typeface here - the advance check is skipped'
} elseif ([Math]::Abs($script:PaneAdvanceEm - $expAdv) -gt 0.02) {
    Fail ('the measure uses {0:N3} em per character but the face advances {1:N3} em - the column is sized for a face that is not on screen' -f $script:PaneAdvanceEm, $expAdv)
} else {
    Pass ('the measure takes its character width from the face itself ({0:N3} em)' -f $expAdv)
}

# 🪤 AND THE LEADING HAS EXACTLY ONE OWNER. Set-ReadMeasure runs on every layout
# and held its own copy of the factor; when the scale moved to 1.48 and this one
# stayed 1.38, the invisible copy won. Third time a number here has been written
# down twice, so it is asserted now rather than commented about.
$docM = New-Object System.Windows.Documents.FlowDocument
Set-ReadMeasure -Doc $docM
$leadWant = [Math]::Round($script:PaneSize * $SR_LeadFactor, 1)
if ([Math]::Abs($script:readLead - $leadWant) -gt 0.05) {
    Fail ('a layout pass left the leading at {0} instead of {1} - a second copy of the factor is back' -f $script:readLead, $leadWant)
} else {
    Pass ('the leading survives a layout pass ({0}px, factor {1})' -f $script:readLead, $SR_LeadFactor)
}
$colW = [double]$ui.PaneDoc.ActualWidth - $docM.PagePadding.Left - $docM.PagePadding.Right
$chars = 0.0
if ($script:PaneSize -gt 0 -and $script:PaneAdvanceEm -gt 0) { $chars = $colW / ($script:PaneSize * $script:PaneAdvanceEm) }
Note ('pane {0:N0}px -> text column {1:N0}px (~{2:N0} chars), {3:N0}px unused on the right [readingWidth: {4}]' -f `
      $ui.PaneDoc.ActualWidth, $colW, $chars, $docM.PagePadding.Right, $script:readWidth)

# 🔴 THE COLUMN GROWS WITH THE PANE, AND THEN STOPS. Reported as "the content
# isn't scaling when we change the window size - the text was cut off half the
# screen although the screen was empty". ReadMeasureChars is a CEILING, not a
# width, and at 100 it stopped growing at ~780px - most of a laptop pane and
# half of a wide monitor. Measured at two real widths rather than reasoned
# about, because the arithmetic looks like a fixed column and is not.
$Wwas = $W
$W = 2600.0
Lay
$docW = New-Object System.Windows.Documents.FlowDocument
Set-ReadMeasure -Doc $docW
$paneWide = [double]$ui.PaneDoc.ActualWidth
$colWide  = $paneWide - $docW.PagePadding.Left - $docW.PagePadding.Right
$W = $Wwas
Lay
$ceil = ($script:ReadMeasureChars * $script:PaneSize * $script:PaneAdvanceEm) + $script:GutterW
Note ('at a {0:N0}px window: pane {1:N0}px -> column {2:N0}px (~{3:N0} chars), ceiling {4:N0}px' -f `
      2600.0, $paneWide, $colWide, ($colWide / ($script:PaneSize * $script:PaneAdvanceEm)), $ceil)
if ($colWide -le $colW + 1) {
    Fail ('the text column did not grow when the pane widened: {0:N0}px at a {1:N0}px pane, {2:N0}px at a {3:N0}px one' -f $colW, $ui.PaneDoc.ActualWidth, $colWide, $paneWide)
} elseif ($colWide -gt $ceil + 3) {
    Fail ('the column grew past its ceiling: {0:N0}px against {1:N0}px - long lines are what the cap exists to prevent' -f $colWide, $ceil)
} else {
    Pass ('the text column grows with the pane and stops at its ceiling ({0:N0}px -> {1:N0}px, cap {2:N0}px)' -f $colW, $colWide, $ceil)
}

# ===========================================================================
Write-Host ''
Write-Host '--- every derived metric, against the thing it derives from ---'
# ===========================================================================
# 🔴 THIS BLOCK EXISTS BECAUSE THE SAME DEFECT HAPPENED FOUR TIMES IN ONE DAY,
# and every instance was a number or a name that outlived what it was measured
# from, with no symptom until something adjacent was touched:
#
#   0.52 em   Manrope's average advance, still in the measure after the pane
#             went monospaced - a column asked for 100 characters, built for 87.
#   1.38      a second copy of the leading factor inside Set-ReadMeasure, which
#             runs on every layout, silently beating the 1.48 the scale sets.
#   'Manrope' named in three test assertions, which then failed on twelve
#             controls that were drawing exactly what they should.
#   $R.D.State  a property read off the wrong object, with a hand-built fixture
#             shaped to match the mistake.
#
# The rule this encodes: a derived value is asserted against its SOURCE, never
# against a literal. Three of the four above are caught here and by the advance
# and leading checks above; the fourth is caught by the fixture-shape assertion
# in the compact block. Adding a metric means adding its check here.

# The gutter must hold the marker it exists for. It is a fixed pixel column and
# the glyph inside it is sized from the face - so a wider face silently pushes
# the marker out of its own column, and the prose would no longer line up with
# the rail blocks beside it.
$glyphW = $script:PaneSize * $script:PaneAdvanceEm
if ($script:GutterW -lt ($glyphW * 1.5)) {
    Fail ('the gutter is {0:N1}px but one marker glyph is {1:N1}px in this face - the marker will not fit its column' -f $script:GutterW, $glyphW)
} else {
    Pass ('the gutter holds its marker with room after it ({0:N1}px column, {1:N1}px glyph)' -f $script:GutterW, $glyphW)
}

# 🔴 ONE SIZE MEANS ONE SIZE. The six-step scale is collapsed by decision, so
# every Sz* resource must carry the same number - if one is ever given its own
# value again, the window is back to a scale nobody chose.
$sizes = @()
foreach ($k in @('Micro', 'Caption', 'Body', 'Mono', 'Strong', 'Display', 'Pane')) {
    $sizes += [double]$window.Resources["Sz$k"]
}
$distinct = @($sizes | Sort-Object -Unique)
if ($distinct.Count -ne 1) {
    Fail ('the window draws {0} different sizes ({1}) - the scale was collapsed to one' -f $distinct.Count, ($distinct -join ', '))
} else {
    Pass ('every size resource in the window carries the same value ({0}px)' -f $distinct[0])
}

# 🔴 SHOW THE PANELS THAT ARE COLLAPSED BY DEFAULT FIRST, OR THE SWEEP BELOW IS
# A LIE. A collapsed panel realises no children, so walking the tree as the
# window opens covers the list, the rail and the pane - and silently SKIPS the
# question card and the running-shells panel, which are exactly the two surfaces
# the operator named ("consider all types of text and assess all possible
# outputs even questions"). The first version of this reported "all 278 blocks
# are on the scale" having never once looked at a question.
# The round is the real captured one, the same fixture the shot harness draws.
$askShown = $false
try {
    $askRound = Get-AskShot 'round-single-answered.txt'
    if ($askRound) {
        Show-Ask $askRound
        $askShown = ("$($ui.AskBox.Visibility)" -eq 'Visible')
    }
} catch { }
if (-not $askShown) { Note 'the question card could not be shown - the sweep below does not cover it' }
$ui.ShellList.ItemsSource = @([PSCustomObject]@{
    ShDesc = 'Run the full suite'; ShCmd = 'pytest -q'; ShOut = 'collected 412 items'
    ShOutVis = 'Visible'; ShAge = '1m 4s'; ShMark = ([string][char]0x25A0); ShTip = ''
})
$ui.ShellHead.Text = (Get-TrackedText '1 SHELL RUNNING')
$ui.ShellBox.Visibility = 'Visible'
Lay

# Every size actually on screen has to BE one of the six. This is the assertion
# the old "one scale" comment claimed and never made: counted at the time it was
# written, sixteen distinct sizes were live, many half a pixel apart.
# 🪤 $root, NOT $window. The window is built and never SHOWN, so it has
# no visual tree of its own - Lay measures and arranges $root, and that is the
# only subtree that realises. Walking $window returns nothing at all, which
# reads as "no strays found" and would have passed this check forever.
$blocks = @(Get-TextBlocks $root)
$allowed = @($scale.Values) + 0.0
$stray = @{}
foreach ($b in $blocks) {
    $s = [Math]::Round([double]$b.FontSize, 2)
    if ($allowed -notcontains $s) {
        $t = "$($b.Text)"; if ($t.Length -gt 24) { $t = $t.Substring(0, 24) }
        if (-not $stray.ContainsKey("$s")) { $stray["$s"] = $t }
    }
}
if (-not $blocks.Count) {
    Fail 'no realised TextBlock anywhere in the window - the scale check saw nothing'
} elseif ($stray.Count) {
    Fail ('{0} size(s) on screen are not on the scale: {1}' -f $stray.Count,
          (($stray.Keys | Sort-Object | ForEach-Object { "$_ px ('$($stray[$_])')" }) -join ', '))
} else {
    Pass ('all {0} realised text blocks are on the six-step scale' -f $blocks.Count)
}

# Put both panels back the way they were found. The shells-panel block below
# asserts that it STARTS collapsed, and a sweep that leaves its own scaffolding
# standing fails the next assertion instead of the code.
$ui.ShellList.ItemsSource = $null
$ui.ShellBox.Visibility = 'Collapsed'
$ui.AskBox.Visibility = 'Collapsed'
Lay

# And the zoom. Measured on a control, before and after, then put back.
$zWas = $script:Zoom
$sample = @($blocks | Where-Object { $_.FontSize -gt 0 })[0]
$before = [double]$sample.FontSize
Set-SRTypeScale -Percent 150
Lay
$after = [double]$sample.FontSize
Set-SRTypeScale -Percent $zWas
Lay
$back = [double]$sample.FontSize
if ($after -le $before) {
    Fail ('the zoom wrote its resources but the text did not move ({0} -> {1}px) - a DynamicResource is missing somewhere' -f $before, $after)
} elseif ([Math]::Abs($back - $before) -gt 0.01) {
    Fail ('the zoom does not come back: {0} -> {1} -> {2}px' -f $before, $after, $back)
} else {
    Pass ('150% moves realised text {0} -> {1}px and returns to {2}' -f $before, $after, $back)
}
# 🔴 AND NOTHING IN THE HEADER MAY OVERLAP AT ANY ZOOM. The header overlap was
# reported twice and both times found by LOOKING at a screenshot; the second
# cause only appears once the type grows, because a horizontal StackPanel hands
# every child its full desired width and quietly draws over its neighbour. This
# measures it in RENDERED coordinates at the largest size the control offers,
# which is where it is worst and where no one thinks to look.
$ovWas = $script:Zoom
foreach ($pct in @(100, 150)) {
    Set-SRTypeScale -Percent $pct
    Lay
    $boxes = @()
    foreach ($n in @('LiveCount', 'Search', 'Stamp', 'BridgeNote')) {
        $el = $ui.$n
        if (-not $el -or "$($el.Visibility)" -ne 'Visible' -or $el.ActualWidth -le 0) { continue }
        try {
            $tl = $el.TransformToAncestor($root).Transform((New-Object System.Windows.Point 0, 0))
            $boxes += @{ N = $n; L = $tl.X; R = $tl.X + $el.ActualWidth }
        } catch { }
    }
    $hits = @()
    for ($a = 0; $a -lt $boxes.Count; $a++) {
        for ($b = $a + 1; $b -lt $boxes.Count; $b++) {
            $o = [Math]::Min($boxes[$a].R, $boxes[$b].R) - [Math]::Max($boxes[$a].L, $boxes[$b].L)
            if ($o -gt 1.0) { $hits += ('{0} over {1} by {2:N0}px' -f $boxes[$a].N, $boxes[$b].N, $o) }
        }
    }
    if ($hits.Count) { Fail ("at {0}% the header overlaps: {1}" -f $pct, ($hits -join '; ')) }
    else { Pass ("at {0}% no two header elements overlap ({1} measured)" -f $pct, $boxes.Count) }
}
Set-SRTypeScale -Percent $ovWas
Lay

if ([Math]::Abs($script:MonoSize - $scale.Pane) -gt 0.01 -or [Math]::Abs($script:readSize - $scale.Pane) -gt 0.01) {
    Fail ('the document builder is off the pane size after a zoom round-trip: mono {0}, prose {1} (both want {2})' -f
          $script:MonoSize, $script:readSize, $scale.Pane)
} else {
    Pass ('the document builder comes back on the pane size, prose and machine alike ({0}px)' -f $scale.Pane)
}

# ===========================================================================
Write-Host ''
Write-Host '--- the running-shells panel puts what it is given on screen ---'
# ===========================================================================
# 🪤 A MISSPELLED BINDING RENDERS AN EMPTY CELL AND SAYS NOTHING. That is the
# same trap the SubVis/AgentVis comment in window2.xaml records, and this panel
# has six bindings. state-driver proves the DATA is right; nothing there would
# notice if ShDesc were spelled ShDsc in the template, and the operator would
# get a panel of blank rows reporting that something is running.
#
# 🔴 THE ROWS ARE SUBSTITUTED, NOT WAITED FOR. A live background shell is not
# something a test may arrange - it would mean running a real command inside
# somebody's session - so the branch is driven by handing the control the shape
# Update-ShellPanel builds. Waiting for real data here would mean this path was
# only ever exercised by accident.
if (-not $ui.ShellBox -or -not $ui.ShellList) {
    Fail 'the running-shells panel is not in the window'
} else {
    if ("$($ui.ShellBox.Visibility)" -ne 'Collapsed') { Fail 'the shells panel starts visible - it must appear only when something is running' }
    else { Pass 'it starts collapsed' }

    # Both kinds at once - the panel exists to show them side by side, and the
    # mark is the only thing that tells them apart.
    $ui.ShellList.ItemsSource = @(
        [PSCustomObject]@{
            ShDesc = 'Rebuild the bundle'; ShCmd = 'npm run build'; ShOut = 'webpack: compiling...'
            ShOutVis = 'Visible'; ShAge = '2m 14s'; ShMark = ([string][char]0x25A0); ShTip = 'tip'
        },
        [PSCustomObject]@{
            ShDesc = 'Audit the panel'; ShCmd = '@code-reviewer'; ShOut = 'reading sessions-window.ps1'
            ShOutVis = 'Visible'; ShAge = '51s'; ShMark = ([string][char]0x25CF); ShTip = 'tip'
        }
    )
    $ui.ShellBox.Visibility = 'Visible'
    Lay
    $shTexts = @(Get-TextBlocks $ui.ShellList | ForEach-Object { "$($_.Text)" } | Where-Object { $_ })
    $missing = @()
    foreach ($want in @('Rebuild the bundle', 'npm run build', 'webpack: compiling...', '2m 14s',
                        'Audit the panel', '@code-reviewer', 'reading sessions-window.ps1')) {
        if ($shTexts -notcontains $want) { $missing += $want }
    }
    if (-not $shTexts.Count) {
        Fail 'the shells panel realised no text at all - every binding is dead'
    } elseif ($missing.Count) {
        Fail ('these never reached the screen: ' + ($missing -join ' | ') + "  (got: " + ($shTexts -join ' / ') + ')')
    } else {
        Pass 'description, command, live output and elapsed all reach the screen'
    }
    # 🪤 THERE IS NO SEPARATE MACHINE FACE ANY MORE. This asked for Cascadia or
    # Consolas, which was right while the window had two faces and became wrong
    # the moment it had one - a command is still the machine voice, it is simply
    # not told apart by its typeface now. What it must still be is the face the
    # window ships, so that is what is asserted.
    $monoWant = $(if ($faceWant) { $faceWant } else { '' })
    if ($monoWant) {
        $monoOff = @(Get-TextBlocks $ui.ShellList |
                     Where-Object { "$($_.Text)" -eq 'npm run build' -or "$($_.Text)" -eq 'webpack: compiling...' } |
                     Where-Object { "$($_.FontFamily.Source)" -ne $monoWant })
        if ($monoOff.Count) { Fail ("{0} line(s) in the shells panel are not in the shipped face ('{1}')" -f $monoOff.Count, $monoWant) }
        else { Pass 'the command and its output are in the shipped face' }
    }

    # 🔴 AND THE TWO KINDS MUST LOOK DIFFERENT. A square is machinery and a
    # round mark is a sub-agent, everywhere else in this window; if the template
    # ever drew one glyph for both, the panel would say two things are running
    # and refuse to say what kind either was.
    $marks = @(Get-TextBlocks $ui.ShellList | ForEach-Object { "$($_.Text)" } |
               Where-Object { $_ -eq ([string][char]0x25A0) -or $_ -eq ([string][char]0x25CF) })
    if (@($marks | Sort-Object -Unique).Count -ne 2) {
        Fail ('the shells panel drew {0} distinct mark(s) for a shell and a sub-agent - they must differ' -f @($marks | Sort-Object -Unique).Count)
    } else {
        Pass 'a shell draws a square and a sub-agent draws a round mark'
    }

    $ui.ShellList.ItemsSource = $null
    $ui.ShellBox.Visibility = 'Collapsed'
}

# ===========================================================================
Write-Host ''
Write-Host '--- the window asks in its own voice ---'
# ===========================================================================
# 🪤 GREP THE CODE, NOT THE COMMENTS. An earlier assertion in this suite matched
# '--remote-control' inside a COMMENT and would have passed however the code
# behaved. Every line here is stripped of comments first, and the grep is proved
# capable of finding something before its silence is trusted.
$src = Get-Content -LiteralPath (Join-Path $SR_LibDir 'sessions-window.ps1') -Encoding UTF8
$code = @($src | ForEach-Object { ($_ -replace '(?<!`)#.*$', '') } | Where-Object { $_.Trim() })
$stock = @($code | Where-Object { $_ -match 'MessageBox' })
$mine  = @($code | Where-Object { $_ -match 'Show-Sheet' })
if (-not $mine.Count) {
    Fail 'the comment-stripped grep found no Show-Sheet either - it is not reading the code at all'
} elseif ($stock.Count) {
    Fail ("a stock MessageBox survives the migration: $($stock[0].Trim())")
} else {
    Pass "no MessageBox remains; $($mine.Count) code lines go through the sheet instead"
}

foreach ($n in @('Scrim', 'Sheet', 'SheetTitle', 'SheetBody', 'SheetB1', 'SheetB2', 'SheetB3')) {
    if (-not $ui.$n) { Fail "the sheet has no '$n'" }
}
if ($ui.Scrim.Visibility -ne $V_Hide -or $ui.Sheet.Visibility -ne $V_Hide) {
    Fail 'the sheet is visible at rest - it would cover the window before anything was asked'
} else { Pass 'the sheet and its scrim start hidden' }

# 🔴 THE SCRIM MUST NOT BE ABLE TO INFLATE A ROW. It spans rows 0-3 and three of
# those are Height="Auto"; anything with a real desired size placed across them
# stretches the header, which is the trap already documented on SettingsBox. A
# Rectangle with no Width/Height desires nothing, and this is what proves it
# still does not - a Width slipped onto it later would fail here rather than in
# the operator's window.
Lay
if ([System.Windows.Controls.Grid]::GetRowSpan($ui.Scrim) -lt 4) {
    Fail 'the scrim does not span every row - the header would stay undimmed'
} elseif ($ui.Scrim.DesiredSize.Width -gt 0 -or $ui.Scrim.DesiredSize.Height -gt 0) {
    Fail ("the scrim now desires $($ui.Scrim.DesiredSize) - it would stretch the Auto rows it spans")
} else { Pass 'the scrim covers all four rows and cannot stretch any of them' }

# --- and it actually answers ------------------------------------------------
# Show-Sheet BLOCKS on a nested dispatcher frame, so it is driven the way the
# operator drives it: a callback posted onto that same dispatcher presses a
# button while the call is parked.
#
# 🪤 THE BUTTON NAME CANNOT BE CAPTURED IN THE CLOSURE, and the first version of
# this helper did exactly that. A scriptblock posted from inside a function
# outlives that function's scope, so by the time the dispatcher ran it the
# parameter had gone and every sheet fell through to the dismiss path. It still
# looked green: three of the assertions expected the ESCAPE value, which is what
# dismissing returns, so they passed without a button ever being pressed. Hence
# both rules below - the name goes through a script-scoped variable, and NO test
# here may expect a value the escape could also produce.
$disp = [System.Windows.Threading.Dispatcher]::CurrentDispatcher
function Press { param([string]$Which)
    $script:pressWhich = $Which
    $script:pressOk = $false
    $null = $disp.BeginInvoke([System.Windows.Threading.DispatcherPriority]::Background, [action]{
        # Read from INSIDE the open sheet: the gate every timer checks.
        $script:seenDepth = ($script:sheetDepth -ge 1)
        $script:seenB3    = "$($ui.SheetB3.Content)"
        $script:seenB2vis = $ui.SheetB2.Visibility
        $script:seenB1vis = $ui.SheetB1.Visibility
        $b = $(if ($script:pressWhich) { $ui[$script:pressWhich] } else { $null })
        if ($b) {
            $script:pressOk = $true
            $b.RaiseEvent((New-Object System.Windows.RoutedEventArgs(
                [System.Windows.Controls.Primitives.ButtonBase]::ClickEvent)))
        } else {
            # No button: the way out Esc takes, which returns the nominated escape.
            $script:sheetFrame.Continue = $false
        }
    })
}

Press 'SheetB3'
$got = Show-Sheet -Title 'Two choices' -Body 'body' -Escape 'no' -Choices @(
    @{ Key = 'no'; Label = 'Cancel' }, @{ Key = 'yes'; Label = 'Do it' })
if ($got -ne 'yes') { Fail "pressing the primary returned '$got', not 'yes'" }
elseif ($script:seenB3 -ne 'Do it') { Fail "the primary button read '$($script:seenB3)', not the last choice" }
elseif (-not $script:seenDepth) { Fail 'sheetDepth was 0 while a sheet was open - every timer would keep mutating the model underneath it' }
elseif ($script:seenB1vis -ne $V_Hide) { Fail 'a third button showed for a two-choice sheet' }
else { Pass "the last choice lands on the primary, presses through, and freezes the model while it is up" }

# The MIDDLE of three, whose key is neither the primary's nor the escape's -
# the only press that can tell all three buttons apart in one go.
Press 'SheetB2'
$got = Show-Sheet -Title 'Three choices' -Body 'body' -Escape 'stay' -Choices @(
    @{ Key = 'stay'; Label = 'Keep working' },
    @{ Key = 'discard'; Label = 'Close anyway' },
    @{ Key = 'save'; Label = 'Save and close' })
if ($got -ne 'discard') { Fail "the middle of three returned '$got', not 'discard'" }
elseif ($script:seenB3 -ne 'Save and close') { Fail "three choices put '$($script:seenB3)' on the primary" }
else { Pass 'three choices fill left to right with the primary last' }

# The leftmost, again against an escape it cannot be confused with.
Press 'SheetB1'
$got = Show-Sheet -Title 'Leftmost' -Body 'body' -Escape 'save' -Choices @(
    @{ Key = 'stay'; Label = 'Keep working' },
    @{ Key = 'discard'; Label = 'Close anyway' },
    @{ Key = 'save'; Label = 'Save and close' })
if ($got -ne 'stay') { Fail "the leftmost of three returned '$got', not 'stay'" }
else { Pass 'the leftmost button carries the first choice' }

Press $null
$got = Show-Sheet -Title 'Dismissed' -Body 'body' -Escape 'stay' -Choices @(
    @{ Key = 'stay'; Label = 'Keep working' }, @{ Key = 'go'; Label = 'Close anyway' })
if ($got -ne 'stay') { Fail "dismissing returned '$got' - Esc must answer with the safe way out, never the destructive one" }
else { Pass 'dismissing answers with the nominated escape, not the primary' }

if ($ui.Scrim.Visibility -ne $V_Hide -or $ui.Sheet.Visibility -ne $V_Hide) {
    Fail 'the sheet stayed up after answering - the window would be left unusable'
} elseif ($script:sheetDepth -ne 0) {
    Fail "sheetDepth is $($script:sheetDepth) after the sheets closed - the timers would never restart"
} else { Pass 'it clears itself and the model starts moving again' }

# The contract repeated at all seven real call sites. Cancel and Esc mean the
# same thing here by design, so this leans on $pressOk to prove the button was
# genuinely found and pressed rather than quietly skipped.
Press 'SheetB3'
$yes = Confirm-Action 'Relaunch this conversation' 'body' -Verb 'Relaunch'
$yesPressed = $script:pressOk
Press 'SheetB1'
$no  = Confirm-Action 'Relaunch this conversation' 'body' -Verb 'Relaunch'
if (-not ($yesPressed -and $script:pressOk)) { Fail 'the harness never actually pressed a button - this assertion proves nothing' }
elseif (-not $yes) { Fail 'Confirm-Action returned false when the action was confirmed - every guarded action would silently do nothing' }
elseif ($no)   { Fail 'Confirm-Action returned true when it was cancelled - every guarded action would fire anyway' }
elseif ($script:seenB3 -ne 'Relaunch') { Fail "the confirm button read '$($script:seenB3)' rather than naming the action" }
else { Pass "Confirm-Action still means yes/no, and its button names the verb" }

# Show-Notice is the one-button shape, and a second button on it would mean the
# operator could be asked to choose about something they cannot change.
Press 'SheetB3'
Show-Notice 'Not saved' 'body'
if (-not $script:pressOk) { Fail 'the notice was never dismissed' }
elseif ($script:seenB2vis -ne $V_Hide) { Fail 'a notice offered more than one button' }
elseif ($script:seenB3 -ne 'Close') { Fail "the notice's only button read '$($script:seenB3)'" }
else { Pass 'a notice tells you one thing and offers one way out' }

# ===========================================================================
Write-Host ''
Write-Host '--- a stale registry must not trap your ticks ---'
# ===========================================================================
# 🔴 THE STALE-WRITE GUARD HAD NO WAY OUT. It refuses a save when the file
# has moved on since this window read it - right, and it stopped two windows
# discarding each other's ticks - but the HOURLY SCAN TASK writes that file from
# its own process. Tick something, wait for the scan, press Save: refused. Press
# Rescan: it saves first, also refused. Neither button could get the ticks out
# and the only exit was closing the window and losing them. Reachable within an
# hour of ordinary use, and introduced by the fix for the two-window case.
$dirtyWas = $script:dirty
$stampWas = $null
try { $stampWas = Get-SRRegistryStamp } catch { }
# 🔴 THE REGISTRY PATH IS REDIRECTED FIRST. This assertion drives a real
# Save-SRRegistry, and this suite's own rule is that it NEVER SAVES - a rule that
# exists because a test wrote over the operator's registry on 2026-08-30 and cost
# them 210 conversations. The first version of this block ignored that and did
# write; the content happened to match, which is luck rather than design. Save
# resolves $SR_RegistryPath at call time, so pointing it at a temp file makes a
# real write impossible rather than merely unlikely, and the real file's stamp is
# checked at the end.
$realRegPath = $SR_RegistryPath
$realRegStamp = $null
try { $realRegStamp = (Get-Item -LiteralPath $realRegPath -ErrorAction Stop).LastWriteTimeUtc.Ticks } catch { }
$sandReg = Join-Path $SR_StateDir ('conflict-' + [Guid]::NewGuid().ToString('N').Substring(0, 8) + '.json')
try {
    $script:SR_RegistryPath = $sandReg
    # 🪤 THE SANDBOX FILE HAS TO EXIST FIRST. A missing file has no stamp, so
    # the staleness check cannot fire and the save simply succeeds - which is what
    # the first version of this measured, and it reported the decline path as
    # broken when it had never been reached.
    Save-SRRegistry -Registry $script:reg
    # Now make this window's view stale: the stamp IS its memory of what it saw.
    Set-SRRegistryStamp 'a-stamp-from-before-something-else-wrote'
    $script:dirty = $true

    # Refuse the prompt: nothing is written, and the window stays usable.
    Press 'SheetB1'
    $ok = Save-RegistryOrAsk 'the probe ticks'
    if ($ok) { Fail 'declining the conflict prompt still saved' }
    elseif (-not $script:pressOk) { Fail 'no conflict prompt was shown - the save failed silently' }
    else { Pass 'a stale save asks rather than refusing outright' }

    # Accept it: the ticks get out. This is the exit the deadlock lacked.
    Set-SRRegistryStamp 'a-stamp-from-before-something-else-wrote'
    $script:dirty = $true
    Press 'SheetB3'
    $ok2 = Save-RegistryOrAsk 'the probe ticks'
    if (-not $ok2) { Fail 'accepting the prompt did not save - the ticks are still trapped' }
    elseif ($script:dirty) { Fail 'it saved but the window still thinks it has unsaved work' }
    else { Pass 'accepting it saves, so the ticks are never trapped in the window' }

    # 🔴 AND SHELVING A PROJECT GOES THROUGH THAT SAME WRITE, so it inherits the
    # same failure. Set-ProjectShelved sets the field and then asks; if the write
    # is refused, THE FIELD HAS TO GO BACK. A rail showing a project as shelved
    # while the file on disk still says otherwise would come back with it visible
    # at the next restart and nothing to explain why - the flag would have been a
    # lie for as long as the window stayed open. Driven here rather than in the
    # rail block above because this is the only place the registry path is
    # sandboxed, and this assertion writes.
    # 🪤 $script:model[0], NOT @($script:model)[0]. The model is a List[object]
    # and @() over one THROWS on PS 5.1 - "Argument types do not match", which
    # names neither the list nor the wrap and takes the whole harness down.
    # [[feedback-array-wrap-trap]]
    $hideDirW = $script:model[0].D
    $hideWasW = $null
    $hideHadW = ($null -ne $hideDirW.PSObject.Properties['shelved'])
    if ($hideHadW) { $hideWasW = $hideDirW.shelved }
    try {
        Set-SRRegistryStamp 'a-stamp-from-before-something-else-wrote'
        $script:dirty = $true
        Press 'SheetB1'   # "Leave it for now"
        $hideRefused = Set-ProjectShelved -Dir $hideDirW -Shelved $true
        if ($hideRefused) { Fail 'a refused save still reported the project as shelved' }
        elseif ([bool]$hideDirW.shelved) {
            Fail 'the save was refused and the project is still marked shelved - the rail now disagrees with the file'
        } else { Pass 'a refused save puts the shelved flag back rather than leaving the rail lying' }

        # And the accepted path really does persist it, or the check above is
        # only measuring a function that never works.
        Set-SRRegistryStamp 'a-stamp-from-before-something-else-wrote'
        $script:dirty = $true
        Press 'SheetB3'   # "Save mine anyway"
        $hideTook = Set-ProjectShelved -Dir $hideDirW -Shelved $true
        $onDisk = $null
        try { $onDisk = (Get-Content -LiteralPath $sandReg -Raw | ConvertFrom-Json) } catch { }
        $wrote = @(@($onDisk.directories) | Where-Object { "$($_.path)" -eq "$($hideDirW.path)" -and $_.shelved })
        if (-not $hideTook) { Fail 'shelving was accepted at the prompt and still reported failure' }
        elseif (-not $wrote.Count) { Fail 'shelving reported success but the registry on disk does not say shelved' }
        else { Pass 'shelving reaches the registry file, so it survives a restart' }
    } finally {
        if ($hideHadW) { $hideDirW.shelved = $hideWasW }
        elseif ($null -ne $hideDirW.PSObject.Properties['shelved']) { $hideDirW.PSObject.Properties.Remove('shelved') }
    }

    # ===================================================================
    # 🔴 THE GUARD HAD TO BE ABLE TO PASS WHEN IT SHOULD THROW, AND THAT IS
    # THE ONLY DIRECTION WORTH TESTING.
    #
    # Asserting that Save-SRRegistry refuses a genuinely different file passes
    # today and proves nothing - length and ticks both move in that case. The
    # hazard is the pair that COLLIDES: same length, same LastWriteTimeUtc,
    # different content. Then the old length|ticks stamp matched, the guard
    # agreed, and this window overwrote another window's ticks.
    #
    # 🔑 THE TIMESTAMP IS SET, NOT RACED. The real collision needs a write
    # inside the clock's ~15.6 ms granularity, which is a race and would make
    # this flaky. Writing LastWriteTimeUtc explicitly reproduces the same state
    # deterministically - it is the state that matters, not how it arose.
    # ===================================================================
    $collideA = '{"version":2,"lastScan":"x","directories":[{"path":"P","sessions":[{"sessionId":"AAAA"},{"sessionId":"BBBB"}]}]}'
    $collideB = '{"version":2,"lastScan":"x","directories":[{"path":"P","sessions":[{"sessionId":"BBBB"},{"sessionId":"AAAA"}]}]}'
    if ($collideA.Length -ne $collideB.Length) {
        Fail 'the collision fixtures are not the same length - the test cannot reach the hazard'
    } else {
        $fixedT = [DateTime]::new(2026, 1, 1, 12, 0, 0, [DateTimeKind]::Utc)
        [IO.File]::WriteAllText($sandReg, $collideA, (New-Object System.Text.UTF8Encoding($false)))
        (Get-Item -LiteralPath $sandReg).LastWriteTimeUtc = $fixedT
        $oldStyleA = '{0}|{1}' -f (Get-Item -LiteralPath $sandReg).Length, (Get-Item -LiteralPath $sandReg).LastWriteTimeUtc.Ticks
        $regObj = Get-SRRegistry            # this window's view, and its stamp

        [IO.File]::WriteAllText($sandReg, $collideB, (New-Object System.Text.UTF8Encoding($false)))
        (Get-Item -LiteralPath $sandReg).LastWriteTimeUtc = $fixedT
        $oldStyleB = '{0}|{1}' -f (Get-Item -LiteralPath $sandReg).Length, (Get-Item -LiteralPath $sandReg).LastWriteTimeUtc.Ticks

        # The test only bites if the OLD stamp really could not tell these apart.
        if ($oldStyleA -ne $oldStyleB) {
            Fail "the collision was not reproduced (old-style stamps differ: $oldStyleA vs $oldStyleB) - this assertion proves nothing"
        } else {
            Pass 'two different registries really can share a length and a timestamp'
            $threw = $false
            $msg = ''
            try { Save-SRRegistry -Registry $regObj } catch { $threw = $true; $msg = "$($_.Exception.Message)" }
            if (-not $threw) {
                Fail 'the guard PERMITTED a save over a registry that had changed underneath it - another window''s ticks would be gone'
            } elseif ($msg -notmatch 'changed on disk') {
                Fail "it threw, but not the staleness refusal: $msg"
            } else { Pass 'a save over content that changed behind an identical stamp is refused' }
            # And the file must still hold B - a refusal that half-wrote would be
            # worse than the bug.
            $after = ''
            try { $after = [IO.File]::ReadAllText($sandReg) } catch { }
            if ($after -ne $collideB) { Fail 'the refused save still modified the registry' }
            else { Pass 'and the refused save left the file exactly as it was' }
        }

        # 🪤 AND THE SAME WINDOW MUST STILL BE ABLE TO SAVE TWICE. The obvious
        # way to build a content baseline is to remember what was serialised -
        # and that is wrong, because Set-Content -Encoding utf8 on 5.1 adds a
        # BOM and a trailing newline, so the file never equals the string. A
        # baseline taken that way turns a silent-overwrite bug into a
        # cannot-save-twice bug. The stamp is read back off the file for exactly
        # this reason, and this is the assertion that would catch it.
        [IO.File]::WriteAllText($sandReg, $collideA, (New-Object System.Text.UTF8Encoding($false)))
        $regTwice = Get-SRRegistry
        $twiceOk = $true
        $twiceWhy = ''
        try { Save-SRRegistry -Registry $regTwice } catch { $twiceOk = $false; $twiceWhy = "first: $($_.Exception.Message)" }
        if ($twiceOk) {
            try { Save-SRRegistry -Registry $regTwice } catch { $twiceOk = $false; $twiceWhy = "second: $($_.Exception.Message)" }
        }
        if (-not $twiceOk) { Fail "a window cannot save twice in a row - $twiceWhy" }
        else { Pass 'the same window can save twice in a row, so the baseline is read back off the file' }

        # 🔴 AND A CHECK THAT CANNOT TELL MUST NOT PERMIT. An unreadable registry
        # used to fall straight through the guard, because the empty stamp was
        # tested with -and rather than asked about.
        Set-SRRegistryStamp 'a-stamp-from-before-something-else-wrote'
        $held = $null
        try {
            $held = [System.IO.File]::Open($sandReg, [System.IO.FileMode]::Open,
                                           [System.IO.FileAccess]::Read, [System.IO.FileShare]::None)
            $blocked = $false
            try { Save-SRRegistry -Registry $regTwice } catch { $blocked = $true }
            if (-not $blocked) { Fail 'a save went ahead while the registry could not be read to check it' }
            else { Pass 'a registry that cannot be read refuses the save rather than assuming it is unchanged' }
        } finally { if ($held) { $held.Dispose() } }
    }
} finally {
    $script:SR_RegistryPath = $realRegPath
    Remove-Item -LiteralPath $sandReg -Force -ErrorAction SilentlyContinue
    $script:dirty = $dirtyWas
    if ($stampWas) { Set-SRRegistryStamp $stampWas }
}
# And prove it: the operator's own registry must not have moved.
$nowStamp = $null
try { $nowStamp = (Get-Item -LiteralPath $realRegPath -ErrorAction Stop).LastWriteTimeUtc.Ticks } catch { }
if ($realRegStamp -and $nowStamp -ne $realRegStamp) {
    Fail 'this assertion wrote to the real registry - the suite must never save'
} else { Pass 'the conflict test wrote only to its own file, never the real registry' }

# 🪤 AFTER the sheet section, not before it: this drives the conflict
# prompt with Press, which is defined there. PowerShell runs a script top to
# bottom, so a helper used above where it is declared is simply not a command.
# ===========================================================================
Write-Host ''
Write-Host '--- the new-session dialog reads the same palette ---'
# ===========================================================================
# 🔴 A MISSPELLED DynamicResource KEY FAILS SILENTLY. That is the whole risk of
# moving this dialog onto the window's dictionary: StaticResource would have
# thrown at parse time, DynamicResource just resolves to nothing and the control
# renders with its default brush - which on a dark window is stock Aero grey, the
# exact thing the move was meant to end. Every key it names is checked here.
$spPath = Join-Path $SR_LibDir 'spawn2.xaml'
$spRaw  = Get-Content -LiteralPath $spPath -Raw -Encoding UTF8
$keys = @([regex]::Matches($spRaw, '\{DynamicResource\s+([A-Za-z0-9_]+)\s*\}') |
          ForEach-Object { $_.Groups[1].Value } | Sort-Object -Unique)
if ($keys.Count -lt 8) { Fail "only $($keys.Count) DynamicResource keys found - the dialog is not on the shared palette" }
else {
    $missing = @()
    foreach ($k in $keys) { try { $null = $window.FindResource($k) } catch { $missing += $k } }
    if ($missing.Count) { Fail ("the dialog asks for keys the window does not define: " + ($missing -join ', ')) }
    else { Pass "all $($keys.Count) keys the dialog names resolve against the window's own dictionary" }
}

# 🪤 AND THE OLD PALETTE MUST BE GONE, not merely unused. A leftover #0F1013 is
# what "already a whole redesign behind" looked like the first time. Comments are
# stripped first: the first version of this check matched the three colours named
# in the comment that EXPLAINS they were removed, and failed on a clean file.
$spCode = [regex]::Replace($spRaw, '(?s)<!--.*?-->', '')
$hard = @([regex]::Matches($spCode, '(?<!x:Key=")#[0-9A-Fa-f]{6}') | ForEach-Object { $_.Value } |
          Where-Object { $_ -ne '#000000' } | Sort-Object -Unique)
if ($hard.Count) { Fail ("spawn2.xaml still hard-codes " + ($hard -join ', ') + " instead of a token") }
else { Pass 'the dialog hard-codes no colour of its own beyond the shadow' }
if ($spCode -match 'FontFamily="Segoe') { Fail 'spawn2.xaml still names a Segoe face by hand - it would not follow the window onto Manrope' }
else { Pass 'it names no typeface of its own' }

# Built and merged exactly as Show-Spawn does it, then asked what it resolved to.
$spr = New-Object System.Xml.XmlNodeReader ([xml]$spRaw)
$spw = [Windows.Markup.XamlReader]::Load($spr)
$spw.Resources.MergedDictionaries.Add($window.Resources)
$nm = $spw.FindName('SpName')
if (-not $nm) { Fail 'the dialog has no SpName after loading' }
elseif (-not $nm.Style) { Fail 'the name box resolved no style - it would render as stock Aero' }
elseif (-not [object]::ReferenceEquals($nm.Style, $window.FindResource('Search'))) {
    Fail 'the name box resolved a DIFFERENT style object than the window uses'
} else { Pass 'a merged control resolves the very same style object the window holds' }
# 🪤 ASK A REALISED CONTROL, NOT THE SETTER. Now that the styles are dynamic the
# setter holds a DynamicResourceExtension rather than a face, so reading
# .Value.Source off it returns an empty string - which is what the first version
# of this assertion reported as "not Manrope". The value only exists once the
# element is measured and the reference is resolved through its parent chain.
if ($faceWant) {
    $spRoot = $spw.Content
    $spRoot.Measure((New-Object System.Windows.Size 540, 900))
    $spRoot.Arrange((New-Object System.Windows.Rect 0, 0, 540, 900))
    $spRoot.UpdateLayout()
    $bad = @()
    foreach ($n in @('SpWarn', 'SpDirPath', 'SpHint', 'SpPermNote')) {
        $t = $spw.FindName($n)
        if ($t -and "$($t.FontFamily.Source)" -ne $faceWant) { $bad += "$n on '$($t.FontFamily.Source)'" }
    }
    if ($bad.Count) { Fail ("the dialog text never picked up the shipped face (want '$faceWant'): " + ($bad -join '; ')) }
    else { Pass 'the shipped typeface reaches the dialog through the merge' }
}

# ===========================================================================
Write-Host ''
Write-Host '--- remembering a setting stops happening on the click that set it ---'
# ===========================================================================
# 🔴 THE WHOLE RISK OF THIS CHANGE IS A LOST SETTING, so that is what is tested.
# Taking the write off the click is easy; the part that can go wrong is the
# value sitting in a hashtable when the window goes away.
#
# 🪤 THE CONFIG IS REDIRECTED, NOT USED. Every other test in this file goes out
# of its way to avoid Save-SRConfigValue because it writes the OPERATOR'S REAL
# CONFIG - but this one is ABOUT the writing, so it cannot dodge it. The path
# and all three pieces of cache state are restored in a finally, and the scratch
# directory goes with them: a fixture that leaks either is the thing this
# machine's conventions were written about.
$cfgWas      = $SR_ConfigPath
$cfgCacheWas = $script:SR_ConfigCache
$cfgStampWas = $script:SR_ConfigStamp
$cfgPendWas  = $script:SR_ConfigPending
$cfgDir = Join-Path ([System.IO.Path]::GetTempPath()) ('sr-cfg-' + [guid]::NewGuid().ToString('N'))
try {
    $null = New-Item -ItemType Directory -Path $cfgDir -Force
    $script:SR_ConfigPath    = Join-Path $cfgDir 'session-restore.config.json'
    $script:SR_ConfigCache   = $null
    $script:SR_ConfigStamp   = ''
    $script:SR_ConfigPending = @{}
    $utf8 = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText($SR_ConfigPath, '{"zoom":100,"transcriptTools":"folded"}', $utf8)

    # The click itself must not reach the disk.
    Save-SRConfigLater -Name 'zoom' -Value 125
    $onDisk = (Get-Content -LiteralPath $SR_ConfigPath -Raw | ConvertFrom-Json)
    if ([int]$onDisk.zoom -ne 100) { Fail ('the click wrote the file after all: zoom is already {0}' -f $onDisk.zoom) }
    else { Pass 'the gesture leaves the file exactly as it was' }

    # 🔴 BUT THIS PROCESS MUST READ BACK WHAT IT JUST SET. The file has not
    # moved, so the stamp still matches and Get-SRConfig would otherwise hand
    # back a config that predates the click - a setting that reverts when
    # anything asks for it is worse than one that costs 21 ms.
    if ([int](Get-SRConfig).zoom -ne 125) { Fail ('Get-SRConfig reports {0}, not the 125 that was just set' -f (Get-SRConfig).zoom) }
    else { Pass 'a queued setting reads back as the value that was clicked' }

    # Two settings, ONE read-modify-write - which is the saving, not a detail.
    Save-SRConfigLater -Name 'transcriptTools' -Value 'full'
    if (-not (Save-SRConfigWrites)) { Fail 'the flush said it had nothing to write with two settings queued' }
    else {
        $onDisk = (Get-Content -LiteralPath $SR_ConfigPath -Raw | ConvertFrom-Json)
        if ([int]$onDisk.zoom -ne 125 -or "$($onDisk.transcriptTools)" -ne 'full') {
            Fail ("the flush did not land both settings: zoom={0} tools='{1}'" -f $onDisk.zoom, $onDisk.transcriptTools)
        } else { Pass 'both queued settings reach the file in one write' }
        if ($script:SR_ConfigPending.Count -ne 0) { Fail 'the flush wrote but did not clear the queue - the next one would write them again' }
        else { Pass 'a written setting leaves the queue' }
    }

    # 🪤 ASSERTED BY CONTENT, NOT BY TIMESTAMP. Two writes inside the system
    # clock's ~15.6 ms tick can share a LastWriteTime, so an unchanged stamp is
    # not evidence that nothing was written.
    [System.IO.File]::WriteAllText($SR_ConfigPath, '{"zoom":125,"sentinel":"kept"}', $utf8)
    if (Save-SRConfigWrites) { Fail 'a flush with an empty queue claimed it wrote something' }
    else {
        $onDisk = (Get-Content -LiteralPath $SR_ConfigPath -Raw | ConvertFrom-Json)
        if ("$($onDisk.sentinel)" -ne 'kept') { Fail 'a flush with an empty queue rewrote the file anyway' }
        else { Pass 'a flush with nothing queued writes nothing, and says so' }
    }

    # 🔴 THE ONE THAT WOULD LOOK LIKE THE SETTING REVERTING ON ITS OWN. A
    # synchronous write is later than anything queued for the same key; if the
    # queue kept its copy, the next flush would put the older value back some
    # seconds after the newer one was written.
    $script:SR_ConfigCache = $null; $script:SR_ConfigStamp = ''
    Save-SRConfigLater -Name 'zoom' -Value 150
    Save-SRConfigValue -Name 'zoom' -Value 90
    $null = Save-SRConfigWrites
    $onDisk = (Get-Content -LiteralPath $SR_ConfigPath -Raw | ConvertFrom-Json)
    if ([int]$onDisk.zoom -ne 90) { Fail ('a queued value came back over a synchronous write: zoom is {0}, not 90' -f $onDisk.zoom) }
    else { Pass 'a synchronous write drops the queued value for the same key' }

    $strays = @(Get-ChildItem -LiteralPath $cfgDir -Filter '.config.*.tmp' -Force -ErrorAction SilentlyContinue)
    if ($strays.Count) { Fail ("{0} .config.<guid>.tmp left beside the config after four writes" -f $strays.Count) }
    else { Pass 'no temp file is left beside the config' }

    # 🔴 THE CASE THAT WAS SILENTLY BROKEN, AND HAD BEEN SINCE BEFORE THE QUEUE.
    # Get-Content and Move-Item report a blocked file as a NON-TERMINATING error,
    # so the writer's own try/catch never saw it: the read returned nothing and
    # the write went ahead against a BLANK object, producing a config holding
    # only the key being saved. Every other setting on it was destroyed - and
    # then the flush cleared its queue for a value that never landed.
    #
    # A destination opened with FileShare None is that state, on demand.
    [System.IO.File]::WriteAllText($SR_ConfigPath, '{"zoom":100,"transcriptTools":"folded","recencyDays":14}', $utf8)
    $script:SR_ConfigCache = $null; $script:SR_ConfigStamp = ''
    $script:SR_ConfigPending = @{}
    Save-SRConfigLater -Name 'zoom' -Value 133
    $lock = [System.IO.File]::Open($SR_ConfigPath, 'Open', 'ReadWrite', 'None')
    $lockThrew = $false
    try { $null = Save-SRConfigWrites } catch { $lockThrew = $true }
    $lock.Dispose()
    if (-not $lockThrew) { Fail 'a write against a config another process holds open reported success' }
    else { Pass 'a blocked write throws instead of reporting success' }
    if (-not $script:SR_ConfigPending.ContainsKey('zoom')) { Fail 'the blocked write cleared the queue - the setting is gone' }
    else { Pass 'a blocked write keeps the setting queued' }
    $onDisk = (Get-Content -LiteralPath $SR_ConfigPath -Raw | ConvertFrom-Json)
    if ($null -eq $onDisk.PSObject.Properties['recencyDays'] -or $null -eq $onDisk.PSObject.Properties['transcriptTools']) {
        Fail 'the blocked write replaced the config with only the key it was saving - the other settings are gone'
    } else { Pass 'a blocked write leaves every other setting on the file untouched' }
    $strays = @(Get-ChildItem -LiteralPath $cfgDir -Filter '.config.*.tmp' -Force -ErrorAction SilentlyContinue)
    if ($strays.Count) { Fail ("a blocked write left {0} temp file(s) beside the config" -f $strays.Count) }
    else { Pass 'a blocked write cleans up its own temp' }
    $script:SR_ConfigPending = @{}

    # 🔴 A FAILED FLUSH KEEPS THE SETTING. This is what makes the close-flush a
    # backstop rather than a second chance to lose it: the queue is only cleared
    # for keys that actually reached the file.
    $script:SR_ConfigPath  = Join-Path $cfgDir 'no-such-dir\session-restore.config.json'
    $script:SR_ConfigCache = $null; $script:SR_ConfigStamp = ''
    Save-SRConfigLater -Name 'zoom' -Value 110
    $threw = $false
    try { $null = Save-SRConfigWrites } catch { $threw = $true }
    if (-not $threw) { Fail 'a write into a directory that does not exist reported success' }
    elseif (-not $script:SR_ConfigPending.ContainsKey('zoom')) { Fail 'a failed flush dropped the setting instead of keeping it for the next one' }
    else { Pass 'a failed flush keeps the setting queued, and says it failed' }
}
finally {
    $script:SR_ConfigPath    = $cfgWas
    $script:SR_ConfigCache   = $cfgCacheWas
    $script:SR_ConfigStamp   = $cfgStampWas
    $script:SR_ConfigPending = $cfgPendWas
    try { Remove-Item -LiteralPath $cfgDir -Recurse -Force -ErrorAction SilentlyContinue } catch { }
}

# AND THE THREE GESTURES ACTUALLY GO THROUGH IT. Same body extraction as the
# send lane above - Get-SRBodyOf is defined up there beside $winSrc, because a
# function has to exist before the line that calls it RUNS and the interrupt
# block reaches for it several hundred lines earlier than this one.
$cfgSrc = [System.IO.File]::ReadAllText((Join-Path $SR_Root 'lib\sessions-window.ps1'))

foreach ($fn in @('Invoke-ColumnFold', 'Step-ToolView', 'Step-Zoom', 'Toggle-RailBand')) {
    $body = Get-SRBodyOf $cfgSrc "function $fn"
    if (-not $body) { Fail "$fn is gone"; continue }
    if ($body -match 'Save-SRConfigValue') { Fail "$fn still writes the config synchronously on the click" }
    elseif ($body -notmatch 'Save-SRConfigLater') { Fail "$fn no longer remembers its setting at all" }
    elseif ($body -notmatch 'Request-SRConfigFlush') { Fail "$fn queues the setting and never asks for it to be written" }
    else { Pass "$fn queues its setting and asks for the flush" }
}

# 🪤 COALESCED, OR THE CHANGE IS HALF OF ITSELF. Without the guard each click
# queues its own callback: the writes still leave the gesture, but four clicks
# are still four read-modify-writes of the file.
$rqBody = Get-SRBodyOf $cfgSrc 'function Request-SRConfigFlush'
if (-not $rqBody) { Fail 'Request-SRConfigFlush is gone - the queued settings have no lane to reach the file on' }
elseif ($rqBody -notmatch 'cfgFlushQueued') { Fail 'the flush is not coalesced - every click would queue its own write' }
elseif ($rqBody -notmatch 'ApplicationIdle') { Fail 'the flush does not wait for idle - it is back on the gesture' }
else { Pass 'the flush is coalesced and runs when the window has nothing better to do' }

# 🔴 AND THE CLOSE IS THE BACKSTOP. A setting clicked in the last moment before
# the window goes away lives only in that hashtable; if Add_Closed does not
# flush, the queue is exactly a way to lose it.
$clIx = $cfgSrc.IndexOf('$window.Add_Closed(')
if ($clIx -lt 0) { Fail 'the window has no Add_Closed handler' }
else {
    $clBody = $cfgSrc.Substring($clIx)
    $clBody = ((($clBody -split "`n") | ForEach-Object { ($_ -split '#', 2)[0] }) -join "`n")
    if ($clBody -notmatch 'Save-SRConfigWrites') { Fail 'closing the window does not flush the queued settings - a setting clicked in the last moment is lost' }
    else { Pass 'closing the window writes whatever is still queued' }
}

# ===========================================================================
Write-Host ''
Write-Host '--- a numbered list in prose is not a menu ---'
# ===========================================================================
# 🔴 REPORTED LIVE: the card demanded an answer to a question neither the
# terminal nor the phone was showing. The session had written two decisions as
# ORDINARY PROSE in a numbered list - it wrote them that way precisely because a
# rule forbade it using the selectable prompt - and the screen parser turned the
# prose straight back into a prompt. Its defences are "starts at 1",
# "consecutive" and "at least two"; a 1./2. list clears all three.
$CURg = [string][char]0x276F

$proseScreen = @(
    ''
    'Two decisions are yours. R-269 forbids me putting them through the'
    'selectable prompt, so here they are in prose.'
    ''
    '  1. What does "no planned successor" mean in R-423 section 1?'
    '  2. May the R-h file-by-file mass go wholesale?'
    ''
) -join "`n"

$proseQ = Invoke-SRParseScreenQuestion -Text $proseScreen
# 🪤 THE FIXTURE HAS TO REPRODUCE THE BUG OR THE TEST IS VACUOUS. If the parser
# stopped seeing this as a question, the assertion below would pass for the
# wrong reason and would keep passing if the gate were deleted - so a fixture
# that no longer parses is itself a failure, not a relief.
if (-not $proseQ -or @($proseQ.Options).Count -lt 2) {
    Fail 'the prose fixture no longer parses as a question - this test can no longer prove anything'
} else {
    Pass ("the parser still reads plain prose as a {0}-option question - which is why the gate exists" -f @($proseQ.Options).Count)
    $pAt = -1
    try { if ($proseQ.PSObject.Properties['CursorAt']) { $pAt = [int]$proseQ.CursorAt } } catch { }
    if ($pAt -ge 0) { Fail ("the prose fixture reports a cursor at {0} - it cannot stand in for a cursorless parse" -f $pAt) }
    elseif (Test-ScreenMenu $proseQ) { Fail 'prose with no cursor passed Test-ScreenMenu - the card would be drawn from it' }
    else { Pass 'prose with no highlight is refused: no cursor, no menu' }
}

# 🔴 AND THE INVERSE, or the gate could be `return $false` and still pass. A real
# menu has its highlight somewhere, and must still draw.
$menuScreen = @(
    ''
    'R-136 rollback: what should happen to the four migrations?'
    ''
    "$CURg 1. Record the correction, leave the rollback standing"
    '  2. Re-apply all four now'
    '  3. Type something'
) -join "`n"
$menuQ = Invoke-SRParseScreenQuestion -Text $menuScreen
if (-not $menuQ) { Fail 'a real menu was not parsed at all' }
elseif (-not (Test-ScreenMenu $menuQ)) {
    Fail ("a real menu with its cursor at {0} was refused - the gate rejects everything" -f $menuQ.CursorAt)
} else { Pass ("a real menu is still accepted: cursor at {0}" -f $menuQ.CursorAt) }

if (Test-ScreenMenu $null) { Fail 'Test-ScreenMenu accepted $null' }
else { Pass 'nothing on screen is not a menu either' }

# 🪤 SCREEN-DERIVED ONLY. A question recovered from the TRANSCRIPT carries no
# cursor - a transcript has no highlight to read - so the gate must not sit on
# Show-Ask itself or every one of those would be blanked. This is the assertion
# that would have caught putting it in the wrong place.
$transQ = [PSCustomObject]@{
    Header   = 'from the transcript'
    Question = 'Which way should the migration go?'
    Options  = @('Forward', 'Back')
    Details  = @('', '')
    Footer   = ''
}
Show-Ask $transQ
if ("$($ui.AskBox.Visibility)" -ne 'Visible') {
    Fail 'a transcript-derived question no longer draws - the cursor gate was put on Show-Ask instead of the screen paths'
} else { Pass 'a transcript-derived question still draws, cursor or no cursor' }
Show-Ask $null

# And the three screen-derived draw sites actually go through it.
$gateSrc = [System.IO.File]::ReadAllText((Join-Path $SR_Root 'lib\sessions-window.ps1'))
foreach ($fn in @('Update-Ask', 'Invoke-AskPoll')) {
    $b = Get-SRBodyOf $gateSrc "function $fn"
    if (-not $b) { Fail "$fn is gone" }
    elseif ($b -notmatch 'Test-ScreenMenu') { Fail "$fn draws the card from a screen parse without asking whether it is a menu" }
    else { Pass "$fn asks whether the screen parse is really a menu" }
}
$landed = Get-SRBodyOf $gateSrc 'function Complete-AnswerLanded'
if (-not $landed) { Fail 'Complete-AnswerLanded is gone' }
elseif ($landed -notmatch 'Test-ScreenMenu') { Fail 'the answer landing redraws the card from a screen parse without the menu check' }
else { Pass 'the answer landing checks it too' }

Write-Host ''
if ($fails) { Write-Host "$fails FAILURE(S)" -ForegroundColor Red; exit 1 }
Write-Host 'the shipped window holds' -ForegroundColor Green
exit 0
