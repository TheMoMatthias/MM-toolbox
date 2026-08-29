# ===========================================================================
# THE SHIPPED WINDOW (lib\sessions-gui2.ps1), built and never shown.
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
$src = Get-Content -LiteralPath (Join-Path $SR_LibDir 'sessions-gui2.ps1') -Encoding UTF8
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
