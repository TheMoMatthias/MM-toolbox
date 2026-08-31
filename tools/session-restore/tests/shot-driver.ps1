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
    if ($shotSel -and ($shotSel.Kind -eq 'session' -or $shotSel.Kind -eq 'agent')) {
        $shotJs = "$($shotSel.Row.S.jsonl)"
        # A sub-agent's own transcript, which is a real file beside the parent's
        # and parses with the same reader.
        if ($shotSel.Kind -eq 'agent') { $shotJs = "$($shotSel.Sub.Path)" }
        if ($shotJs -and (Test-Path -LiteralPath $shotJs)) {
            $shotTrunc = $false
            try { $shotTrunc = ((Get-Item -LiteralPath $shotJs).Length -gt $script:tailBytes) } catch { }
            $shotGot = Get-SRTranscriptBlocks -JsonlPath $shotJs -MaxRecords 220 -MaxTailBytes $script:tailBytes
            Set-ReadDocument -Blocks @($shotGot) -Truncated $shotTrunc
        }
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
