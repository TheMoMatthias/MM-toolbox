# ===========================================================================
# THE REAL WINDOW, DRAWN TO A PNG, NEVER SHOWN.
#
# By name only (`run-tests.ps1 -Only shot`) and deliberately not part of "all
# suites passed": it renders the operator's own conversations at real density,
# which is where every clipped pill, mojibaked caption and column that quietly
# echoes its neighbour has actually hidden. A layout change is looked at, not
# asserted.
#
#   SR_SHOT_SURFACE=manage   draw the session manager instead of the work surface
#   SR_SHOT_SIZE=1200x800    draw at another size, to see the adaptive breakpoints
#   SR_SHOT_OUT=<path>       where to write it
#   SR_SHOT_SHELLS=1         draw the running-shells panel (substituted rows)
#
# 🪤 RENDER THE CONTENT, NOT THE WINDOW, AND PAINT THE GROUND FIRST. A Window
# that has never been shown has no rendered visual root, so RenderTargetBitmap
# over it comes back blank; and the dark background belongs to the WINDOW, so
# the content alone renders transparent - which every viewer shows as white.
# ===========================================================================
$W = 1480.0; $H = 980.0
if ($env:SR_SHOT_SIZE -and $env:SR_SHOT_SIZE -match '^(\d+)x(\d+)$') {
    $W = [double]$Matches[1]; $H = [double]$Matches[2]
}
$out = $env:SR_SHOT_OUT
if (-not $out) { $out = Join-Path $SR_StateDir ('shots\{0}.png' -f (Get-Date -Format 'yyyyMMdd-HHmmss')) }

if ($env:SR_SHOT_SURFACE -eq 'manage') { $ui.ModeManage.IsChecked = $true; Set-Surface 'manage' }

# 🪤 THE SHEET CANNOT BE SEEN ANY OTHER WAY. It only ever appears while a caller
# is parked on a nested dispatcher frame, so there is no moment at which a shot
# taken normally would catch one - and it is the surface every destructive
# action in the window is read through. Dressed here directly rather than by
# calling Show-Sheet, which would block this script forever: PushFrame needs a
# dispatcher that is running, and a shot never starts one.
if ($env:SR_SHOT_SHEET) {
    $ui.SheetTitle.Text = 'Your ticks have not been saved'
    $ui.SheetBody.Text  = 'They decide which conversations reopen at your next logon. Closing now leaves that list exactly as it was.'
    $pairs = @(@('SheetB1', 'Keep working'), @('SheetB2', 'Close anyway'), @('SheetB3', 'Save and close'))
    foreach ($p in $pairs) { $ui[$p[0]].Content = $p[1]; $ui[$p[0]].Visibility = $V_Show }
    $ui.Scrim.Visibility = $V_Show
    $ui.Sheet.Visibility = $V_Show
}

# 🪤 THE PINNED QUESTION IS ONLY ON SCREEN WHILE A LIVE CONSOLE IS SITTING ON A
# MENU, so a shot taken normally almost never catches the one panel every answer
# goes through. Dressed here from a fabricated question - the same shape
# Get-SRScreenQuestion returns - so a change to it can be looked at on demand
# rather than waited for.
# 🔴 THE ROW AT ITS BUSIEST, on demand. The operator reported the context bar
# looking wrong "when the sub agent or shell indicator is turned on", and the
# case is hard to catch in the wild: it needs a session that is simultaneously
# past half its window AND holding a shell AND holding a sub-agent. The
# assertions in gui2 prove the VALUES are right; this is for looking at the
# layout, which is what the report was actually about.
if ($env:SR_SHOT_MARKS) {
    $mk = 0
    foreach ($mrow in $script:model) {
        if (-not $mrow.Live) { continue }
        $mk++
        if ($mk -gt 4) { break }
        $null = Set-RowScreenSig -Id "$($mrow.Id)" -Shells $mk -Agents $(if ($mk % 2) { 1 } else { 2 }) `
                                 -CtxTokens (150000 * $mk + 400000) -CtxWindow 1000000
    }
    Build-Sessions
}

# 🔴 SUBSTITUTED, BECAUSE THE REAL THING CANNOT BE ARRANGED FOR A PICTURE. The
# panel only appears while a background shell is genuinely running in the
# selected conversation, which is not a state a screenshot may create - it would
# mean starting a real command inside somebody's session. Without this knob the
# panel would only ever be reviewed by accident, on a day something happened to
# be running, which is how it would ship looking wrong.
# The SHAPE here is the shape Update-ShellPanel builds; only the values differ.
if ($env:SR_SHOT_SHELLS) {
    $ui.ShellList.ItemsSource = @(
        [PSCustomObject]@{
            ShDesc = 'Run the full suite'
            ShCmd  = 'cd "C:/repo" && pytest -q tests/ --maxfail=1'
            ShOut  = 'tests/test_engine.py ......................  [ 62%]'
            ShOutVis = 'Visible'; ShAge = '4m 12s'
            ShMark = [string][char]0x25A0; ShTip = ''
        },
        [PSCustomObject]@{
            ShDesc = 'Rebuild the bundle'
            ShCmd  = 'npm run build -- --profile'
            ShOut  = 'webpack: compiling...'
            ShOutVis = 'Visible'; ShAge = '38s'
            ShMark = [string][char]0x25A0; ShTip = ''
        },
        [PSCustomObject]@{
            ShDesc = 'Audit: the new panel'
            ShCmd  = '@code-reviewer'
            ShOut  = 'Reading lib/sessions-window.ps1 - 3 findings so far'
            ShOutVis = 'Visible'; ShAge = '1m 51s'
            ShMark = [string][char]0x25CF; ShTip = ''
        }
    )
    $ui.ShellHead.Text = (Get-TrackedText ('2 SHELLS  ' + [string][char]0x00B7 + '  1 SUB-AGENT RUNNING'))
    $ui.ShellBox.Visibility = 'Visible'
}

if ($env:SR_SHOT_ASK) {
    # 🔴 A REAL ROUND, OFF A REAL SCREEN. This used to hand Show-Ask a question
    # written here to suit the panel - which drew a picture of a surface that
    # did not exist, including 'Type something.' as an ordinary fourth option,
    # the exact thing that turned out to decline the whole round. The fixture is
    # one of the screens captured off a live menu on 2026-08-30, so what this
    # draws is what the operator will actually see.
    $askShot = Join-Path $SR_Root 'tests\screens\round-single-answered.txt'
    if (Test-Path -LiteralPath $askShot) {
        Show-Ask (Invoke-SRParseScreenQuestion -Text ([System.IO.File]::ReadAllText($askShot)))
    }
}

# 🪤 THE VITALS STRIP IS FILLED BY THE ONE-SECOND TICK, NOT BY THE CLICK - that
# is deliberate, to keep a JSONL parse and a git call off the click path. A shot
# never ticks, so without this the header draws empty and every screenshot taken
# for review silently omits the row of chips it was taken to review.
# Update-Chips directly rather than Invoke-FollowTick: the tick can also reach
# Update-Ask, which spawns a process to read another session's console, and a
# screenshot must not do that.
# 🔴 WHICH CONVERSATION TO DRAW. A shot takes whatever happens to be selected,
# and that is fine for the list but useless for reviewing the READING pane -
# whether a run card or an answered question renders well depends entirely on
# whether the conversation in front of you HAS one. Reviewing "Steps: full"
# against a session with no tool calls in its tail shows nothing at all, which
# reads as the feature being empty rather than the sample being wrong.
if ($env:SR_SHOT_SESSION) {
    $want = "$env:SR_SHOT_SESSION"
    $pick = @($ui.SessionList.Items | Where-Object {
        $_.Kind -eq 'session' -and "$($_.Name)" -like "*$want*"
    })
    if ($pick.Count) {
        $ui.SessionList.SelectedItem = $pick[0]
        $script:selId = "$($pick[0].Id)"
        Write-Host ("  drawing '{0}'" -f $pick[0].Name)
    } else {
        Write-Host ("  [warn] no conversation matching '{0}' - drawing whatever is selected" -f $want)
    }
}

# 🔑 AND DRILLING INTO ONE OF ITS SUB-AGENTS. Agent rows only exist once their
# parent is selected - they are expanded under the selection, not always - so
# this has to select the session, REBUILD the list, and only then look for the
# agent. Without the rebuild the rows are not there yet and the search finds
# nothing, which reads exactly like the feature being broken.
if ($env:SR_SHOT_AGENT) {
    Build-Sessions
    $wantA = "$env:SR_SHOT_AGENT"
    $pickA = @($ui.SessionList.Items | Where-Object {
        $_.Kind -eq 'agent' -and "$($_.SubName)" -like "*$wantA*"
    })
    if ($pickA.Count) {
        $ui.SessionList.SelectedItem = $pickA[0]
        $script:selId = "$($pickA[0].Id)"
        Write-Host ("  drilling into sub-agent '{0}'" -f $pickA[0].SubName)
    } else {
        $n = @($ui.SessionList.Items | Where-Object { $_.Kind -eq 'agent' }).Count
        Write-Host ("  [warn] no sub-agent matching '{0}' - {1} agent rows present" -f $wantA, $n)
    }
}

try {
    $shotSel = $ui.SessionList.SelectedItem
    if ($shotSel -and $shotSel.Kind -eq 'session') { Update-Chips $shotSel.Row -Force }
} catch { }

# 🔴 AND THE DOCUMENT, WHICH EVERY SHOT UNTIL NOW LEFT EMPTY. The window builds
# it on the 100ms lane out of a runspace parse, and a shot runs neither - so the
# reading pane, the whole point of the surface, was blank in every screenshot
# ever taken for review. That is not a small omission: three defects on
# 2026-08-30 were invisible to assertions and obvious the moment a row was
# actually rendered, and the reading pane had never been rendered at all.
#
# Read synchronously here. The parse is 150-215 ms even on a 132 MB transcript,
# which is nothing for a screenshot, and it keeps the shot free of the lane.
#
# 🪤 ASSIGN, THEN WRAP. Get-SRTranscriptBlocks comma-guards its return, so
# @(Get-SRTranscriptBlocks ...) in one step is ONE element holding every block -
# the exact bug that made this pane blank in the shipped window.
# Which Steps setting to draw. Without this a shot shows whatever the operator
# last left in the config, which is the one thing a review shot must not depend
# on - the folded view is the default and the one worth looking at most.
if ($env:SR_SHOT_STEPS) { $script:toolView = "$env:SR_SHOT_STEPS" }

try {
    $shotJs = ''
    # 🔴 SR_SHOT_JSONL DRAWS A TRANSCRIPT THAT IS NOT ANYBODY'S SELECTION, and
    # it exists because some blocks cannot be reached any other way. The
    # answered-question card renders outside the visible tail on every live
    # conversation tried so far, so it had been asserted for days and never once
    # LOOKED AT - the precise gap that let three defects ship on 2026-08-30.
    #
    # 🪤 Point it at REAL RECORDS, never at a hand-written fixture. A record
    # invented to match what the parser expects proves the guess against itself
    # and reads as verification - the reason the multi-select menu is still
    # deliberately unanswerable in the relay suite. Lift the lines out of an
    # actual transcript instead.
    if ($env:SR_SHOT_JSONL) {
        $shotJs = "$env:SR_SHOT_JSONL"
        Write-Host ("  drawing the transcript at {0}" -f $shotJs)
    } elseif ($shotSel -and ($shotSel.Kind -eq 'session' -or $shotSel.Kind -eq 'agent')) {
        $shotJs = "$($shotSel.Row.S.jsonl)"
        # A sub-agent's own transcript, which is a real file beside the parent's
        # and parses with the same reader.
        if ($shotSel.Kind -eq 'agent') { $shotJs = "$($shotSel.Sub.Path)" }
    }
    if ($shotJs -and (Test-Path -LiteralPath $shotJs)) {
        $shotTrunc = $false
        try { $shotTrunc = ((Get-Item -LiteralPath $shotJs).Length -gt $script:tailBytes) } catch { }
        # 🪤 ASSIGN, THEN WRAP. Get-SRTranscriptBlocks comma-guards its return,
        # so @(Get-SRTranscriptBlocks ...) in ONE step is a single element
        # holding every block - the bug that made this pane blank in the
        # shipped window, and one this suite walked into again while the
        # sub-agent assertions were being written.
        $shotGot = Get-SRTranscriptBlocks -JsonlPath $shotJs -MaxRecords 220 -MaxTailBytes $script:tailBytes
        Set-ReadDocument -Blocks @($shotGot) -Truncated $shotTrunc
    } elseif ($shotJs) {
        Write-Host ("  [warn] no transcript at {0}" -f $shotJs)
    }
} catch { Write-Host "  [warn] the document could not be built for the shot: $($_.Exception.Message)" }

$window.Width = $W; $window.Height = $H
$root = $window.Content
# 🔴 DO NOT PAINT THE GROUND ONTO THE CONTENT. The app is an inset card with the
# window's ground showing around it, and an earlier version of this script set
# $root.Background = $window.Background - which painted the GROUND COLOUR ONTO
# THE CARD, so every shot showed a full-bleed rectangle and the inset frame was
# invisible in review. The ground is composited behind instead, below.
foreach ($pass in 1, 2) {
    $root.Measure((New-Object System.Windows.Size $W, $H))
    $root.Arrange((New-Object System.Windows.Rect 0, 0, $W, $H))
    $root.UpdateLayout()
    [System.Windows.Threading.Dispatcher]::CurrentDispatcher.Invoke(
        [System.Windows.Threading.DispatcherPriority]::Loaded, [action]{})
}

# 🪤 SCROLL AFTER THE LAYOUT PASSES, NEVER BEFORE. A fresh document opens at the
# END - Move-ToBottom defers itself to Loaded priority, which is exactly what
# the passes above pump - so anything that scrolled first would be dragged back
# down before the frame was captured, and the shot would look like the option
# does nothing.
# 🔴 THE MEASURE IS ARITHMETIC ON THE PANE'S ACTUAL WIDTH, and at BUILD time the
# pane has not been laid out yet - ActualWidth is 0, Set-ReadMeasure falls back
# to an assumed 900, and the padding it computes is wrong for any pane that is
# not 900 wide. The real window does not have this problem: PaneDoc's
# SizeChanged starts a 240 ms timer that re-runs Set-ReadMeasure once the drag
# stops. A shot pumps no timers, so without this every review screenshot showed
# the measure UNCAPPED however the config was set - and a reviewer would
# reasonably conclude the setting did nothing.
if ($ui.PaneDoc.Document) {
    Set-ReadMeasure -Doc $ui.PaneDoc.Document -PadL 44
    $root.UpdateLayout()
    [System.Windows.Threading.Dispatcher]::CurrentDispatcher.Invoke(
        [System.Windows.Threading.DispatcherPriority]::Loaded, [action]{})
    Write-Host ("  measure: pane {0:N0}px, readingWidth={1}" -f $ui.PaneDoc.ActualWidth, $script:readWidth)
}

# 🔑 SR_SHOT_TFM=Display renders with glyph advances SNAPPED TO PIXELS instead
# of positioned at sub-pixel offsets. Ideal is what the window ships (see the
# note at the top of window2.xaml) and it is the better choice for a display
# face at large sizes; at 12px it is also what makes the spacing between
# characters look uneven, which is what the operator reported. This is
# capturable, unlike TextRenderingMode - see CONTEXT.md, a screenshot of
# 'cleartype' is greyscale wearing a label - so the two can be compared in a
# shot and judged rather than argued about.
if ($env:SR_SHOT_TFM) {
    [System.Windows.Media.TextOptions]::SetTextFormattingMode($window, "$env:SR_SHOT_TFM")
    $root.UpdateLayout()
    [System.Windows.Threading.Dispatcher]::CurrentDispatcher.Invoke(
        [System.Windows.Threading.DispatcherPriority]::Loaded, [action]{})
    Write-Host ("  TextFormattingMode = {0}" -f $env:SR_SHOT_TFM)
}

if ($env:SR_SHOT_TOP) {
    $svTop = Get-PaneScroller
    if ($svTop) {
        $svTop.ScrollToHome()
        $root.UpdateLayout()
        [System.Windows.Threading.Dispatcher]::CurrentDispatcher.Invoke(
            [System.Windows.Threading.DispatcherPriority]::Loaded, [action]{})
        Write-Host '  scrolled to the top of the document'
    } else { Write-Host '  [warn] no scroller - cannot scroll to the top' }
}

$dir = Split-Path -Parent $out
if ($dir -and -not (Test-Path -LiteralPath $dir)) { $null = New-Item -ItemType Directory -Path $dir -Force }

# 🪤 AN ELEMENT WITH NO PARENT RENDERS AT THE ORIGIN, margin and all. Arrange()
# sizes the card correctly (1452x952 inside 1480x980 - measured), but the 14px
# offset is applied by the PARENT during layout, and here the card has no
# parent: it draws hard against the top-left and the inset frame is invisible in
# every shot. A RenderTransform does NOT fix it either - RenderTargetBitmap
# ignores the transform on the visual it is handed. The offset is applied at
# composite time below, where the geometry is ours.
$mL = 0.0; $mT = 0.0
if ($root -is [System.Windows.FrameworkElement]) { $mL = $root.Margin.Left; $mT = $root.Margin.Top }
$content = New-Object System.Windows.Media.Imaging.RenderTargetBitmap([int]$W, [int]$H, 96, 96,
        [System.Windows.Media.PixelFormats]::Pbgra32)
$content.Render($root)

# The window's own ground first, then the content over it - which is exactly the
# order the compositor uses on screen, so the margin around the card reads as it
# really does rather than as transparency.
$dv = New-Object System.Windows.Media.DrawingVisual
$dc = $dv.RenderOpen()
try {
    $ground = $window.Background
    if (-not $ground) { $ground = [System.Windows.Media.Brushes]::Black }
    $dc.DrawRectangle($ground, $null, (New-Object System.Windows.Rect 0, 0, $W, $H))
    # Offset by the card's own margin. The bitmap overhangs by that much on the
    # right and bottom and is clipped there, which is exactly the ground the card
    # should be leaving on those edges anyway.
    $dc.DrawImage($content, (New-Object System.Windows.Rect $mL, $mT, $W, $H))
} finally { $dc.Close() }

$rtb = New-Object System.Windows.Media.Imaging.RenderTargetBitmap([int]$W, [int]$H, 96, 96,
        [System.Windows.Media.PixelFormats]::Pbgra32)
$rtb.Render($dv)
$enc = New-Object System.Windows.Media.Imaging.PngBitmapEncoder
$enc.Frames.Add([System.Windows.Media.Imaging.BitmapFrame]::Create($rtb))
$fs = [System.IO.File]::Create($out)
try { $enc.Save($fs) } finally { $fs.Dispose() }

Write-Host ("  ok    drew {0}  {1}x{2}" -f $out, [int]$W, [int]$H)
Write-Host ("        surface={0}  rail={1}  list={2}  rows={3}" -f `
    $script:surface, $ui.RailCol.Width.Value, $ui.ListCol.Width.Value, @($ui.SessionList.Items).Count)
exit 0
