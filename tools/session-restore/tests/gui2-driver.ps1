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
$capWas = $null
try { $capWas = $script:cfg.maxSessions } catch { }
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
if ($null -ne $capWas) { $script:cfg.maxSessions = $capWas }

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
$tiles0 = @($ui.RailList.ItemsSource).Count
$rows0  = @($ui.SessionList.Items | Where-Object { $_.Kind -eq 'session' }).Count
if ($tiles0 -lt 2 -or $rows0 -lt 2) { Note 'not enough on screen to pose the search' }
else {
    # The rail's box narrows the rail and LEAVES THE SESSIONS ALONE.
    $ui.RailSearch.Text = 'algotrader'
    Build-Rail; Build-Sessions
    $tilesR = @($ui.RailList.ItemsSource)
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
    $tilesL = @($ui.RailList.ItemsSource).Count
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
$names = @($ui.RailList.ItemsSource | ForEach-Object { "$($_.Label)".ToLower() })
$sorted = @($names | Sort-Object)
if (($names -join '|') -ne ($sorted -join '|')) { Fail 'ordering the rail by name did not sort it' }
else { Pass "the rail orders itself four ways ($($names.Count) projects, name order verified)" }
$script:railSort = 'recent'

$script:railOnlyLive = $true; Build-Rail
$live = @($ui.RailList.ItemsSource)
$dead = @($live | Where-Object { "$($_.State)" -like '*idle*' -and "$($_.State)" -notlike '*working*' -and "$($_.State)" -notlike '*waiting*' })
if ($dead.Count) { Fail "$($dead.Count) project(s) with nothing running survived the 'only running' filter" }
else { Pass "'only running' leaves $($live.Count) project(s), none of them idle" }
$script:railOnlyLive = $false; Build-Rail

# ===========================================================================
Write-Host ''
Write-Host '--- the project tiles ---'
# ===========================================================================
$ui.ModeWork.IsChecked = $true
Set-Surface 'work'
Build-Rail
Lay
$tiles = @($ui.RailList.ItemsSource)
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
    $c0 = $ui.RailList.ItemContainerGenerator.ContainerFromIndex(0)
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
            # Not a gesture budget - it is a child process by necessity - but it
            # is the number the operator feels when they press an option, so it
            # is held to something. Past a second it stops feeling like an answer
            # and starts feeling like a submission.
            if ($ansBest -gt 1000) {
                Fail ("answering waits {0:N0} ms on a screen read before anything is sent" -f $ansBest)
            } else { Pass 'the answer round trip stays under a second' }
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

    # A SESSION WRITES -> YOU SEE IT. The watcher raises an event, the lane
    # redraws. This is the number behind "I want to see what is happening".
    $liveFile = "$($e2eRows[0].Row.S.jsonl)"
    $ui.SessionList.SelectedItem = $e2eRows[0]
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
if ($script:hasManrope) {
    Lay
    $off = @()
    foreach ($n in @('PaneName', 'Status', 'SheetTitle', 'SheetBody', 'ListCaption', 'PaneState')) {
        $el = $ui.$n
        if ($el -and "$($el.FontFamily.Source)" -notlike '*Manrope*') { $off += "$n on '$($el.FontFamily.Source)'" }
    }
    if ($off.Count) { Fail ('the shipped typeface never reached: ' + ($off -join '; ')) }
    else { Pass 'the header, the status line, the list and the sheet all draw in the shipped face' }

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
if ($script:hasManrope) {
    $spRoot = $spw.Content
    $spRoot.Measure((New-Object System.Windows.Size 540, 900))
    $spRoot.Arrange((New-Object System.Windows.Rect 0, 0, 540, 900))
    $spRoot.UpdateLayout()
    $bad = @()
    foreach ($n in @('SpWarn', 'SpDirPath', 'SpHint', 'SpPermNote')) {
        $t = $spw.FindName($n)
        if ($t -and "$($t.FontFamily.Source)" -notlike '*Manrope*') { $bad += "$n on '$($t.FontFamily.Source)'" }
    }
    if ($bad.Count) { Fail ('the dialog text never picked up the shipped face: ' + ($bad -join '; ')) }
    else { Pass 'the shipped typeface reaches the dialog through the merge' }
}

Write-Host ''
if ($fails) { Write-Host "$fails FAILURE(S)" -ForegroundColor Red; exit 1 }
Write-Host 'the shipped window holds' -ForegroundColor Green
exit 0
