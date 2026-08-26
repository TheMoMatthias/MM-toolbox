
# ---------------------------------------------------------------------------
# shot-driver -- the real window, drawn to PNG, with nothing on screen.
#
# NOT A TEST. It asserts nothing and it can never fail a build. It exists so a
# change to the layout can be LOOKED AT against the operator's own registry --
# 204 conversations across 26 projects -- rather than against the six staged
# fixtures the headless suite uses. Every layout bug that survived a green
# headless run was a bug about DENSITY: a pill that clipped, a caption that
# mojibaked, a group that scrolled past the fold. None of those are visible at
# six rows.
#
# It is spliced onto sessions-gui.ps1 exactly like headless-driver, so what it
# draws is the shipped window, wired to the shipped registry -- not a mock of
# either. It opens nothing, saves nothing and never writes to the registry:
# $script:dirty is asserted clean at the end, and a dirty exit is the one thing
# here that reports a failure.
#
#   .\run-tests.ps1 -Only shot                 both views, into .state\shots
#   $env:SR_SHOT_DIR = 'C:\somewhere'          somewhere else
#   $env:SR_SHOT_SIZE = '1920x1200'            a different window size
#
# The two render passes below are not a mistake. An unshown window has never
# been through a layout pass, so the first Measure/Arrange is what REALISES the
# ListBox items; they have not been arranged when it returns, and rendering
# after one pass gives a window with an empty list in it.
# ---------------------------------------------------------------------------

$shotDir = $env:SR_SHOT_DIR
if (-not $shotDir) { $shotDir = Join-Path $here '.state\shots' }
if (-not (Test-Path -LiteralPath $shotDir)) { $null = New-Item -ItemType Directory -Path $shotDir -Force }

$shotW = 1480.0
$shotH = 980.0
if ($env:SR_SHOT_SIZE -and $env:SR_SHOT_SIZE -match '^(\d+)x(\d+)$') {
    $shotW = [double]$Matches[1]
    $shotH = [double]$Matches[2]
}

$shotFails = 0
function Write-ShotOk   { param([string]$Text) Write-Host "  ok    $Text" -ForegroundColor DarkGray }
function Write-ShotBad  { param([string]$Text) $script:shotFails++; Write-Host "  FAIL  $Text" -ForegroundColor Red }

function Save-Shot {
    param([string]$Name)

    $shotRoot = $window.Content

    # PAINT THE GROUND FIRST. RenderTargetBitmap draws the visual it is handed,
    # and the dark background belongs to the WINDOW, not to its content. Render
    # the content alone and the bitmap is transparent -- which every viewer shows
    # as WHITE, so near-white text lands on near-white and the shot reads as a
    # broken window rather than the one on screen.
    $shotHadBg = $shotRoot.Background
    if (-not $shotHadBg -or $shotHadBg -eq [System.Windows.Media.Brushes]::Transparent) {
        $shotRoot.Background = $(if ($window.Background) { $window.Background } else { $Pal.Ink })
    }
    try {
        foreach ($shotPass in 1, 2) {
            $shotRoot.Measure((New-Object System.Windows.Size $shotW, $shotH))
            $shotRoot.Arrange((New-Object System.Windows.Rect 0, 0, $shotW, $shotH))
            $shotRoot.UpdateLayout()
        }
        $shotPath = Join-Path $shotDir "$Name.png"
        $shotBmp = New-Object System.Windows.Media.Imaging.RenderTargetBitmap(
            [int]$shotW, [int]$shotH, 96, 96, [System.Windows.Media.PixelFormats]::Pbgra32)
        $shotBmp.Render($shotRoot)
        $shotEnc = New-Object System.Windows.Media.Imaging.PngBitmapEncoder
        $shotEnc.Frames.Add([System.Windows.Media.Imaging.BitmapFrame]::Create($shotBmp))
        $shotFs = [System.IO.File]::Create($shotPath)
        try { $shotEnc.Save($shotFs) } finally { $shotFs.Dispose() }
        $shotLen = (Get-Item -LiteralPath $shotPath).Length
        if ($shotLen -gt 5000) {
            Write-ShotOk "$Name.png  $([int]$shotW)x$([int]$shotH)  $([int]($shotLen/1024)) KB"
        } else {
            Write-ShotBad "$Name.png is only $shotLen bytes - probably a blank bitmap"
        }
    } finally {
        $shotRoot.Background = $shotHadBg
    }
}

Write-Host ''
Write-Host "  registry: $($script:totalCount) conversation(s), $(@($script:dirs).Count) project(s)" -ForegroundColor DarkGray
Write-Host "  into    : $shotDir" -ForegroundColor DarkGray

# 🔴 A SHOT WITHOUT A PROBE PASS LIES ABOUT WHICH COLUMNS ARE EMPTY.
#
# The harness runs -NoScan, so nothing fills $script:conv -- and Update-RowConv
# returns early with a blank STATE and a blank WHAT IT LAST SAID for every row.
# The screenshot then shows two wide, entirely empty columns, and the obvious
# conclusion is to delete them. They are not empty in the real window: the
# background pass reads every conversation in the registry, not just the live
# ones, and measures at about 3 ms each.
#
# So read them here too. This is the whole point of drawing the REAL registry:
# a picture that disagrees with the running window is worse than no picture.
$shotSw = [Diagnostics.Stopwatch]::StartNew()
$shotConv = @{}
$shotRead = 0
foreach ($shotDir2 in @($script:dirs)) {
    foreach ($shotS in @(Get-Visible $shotDir2)) {
        if (-not $shotS.sessionId -or -not $shotS.jsonl) { continue }
        try { $shotConv["$($shotS.sessionId)".ToLower()] = Get-SRConversationState -JsonlPath $shotS.jsonl; $shotRead++ } catch { }
    }
}
$script:conv = $shotConv
try { $script:agents = Get-SRAgentStatus } catch { }
Write-Host "  probed  : $shotRead conversation(s) in $([int]$shotSw.ElapsedMilliseconds) ms, $(@($script:agents.Keys).Count) agent(s)" -ForegroundColor DarkGray
# No repaint needed here: every Set-ViewMode below rebuilds through Update-List,
# which paints each row's state and last-said from exactly this table.

# --- the two views, as they open -------------------------------------------
Set-ViewMode 'inbox'
Save-Shot 'now'

Set-ViewMode 'all'
Save-Shot 'roster'

# --- the roster, fully unfolded, which is the shape being complained about --
# Every fold open is the worst case for scanning, and the one the operator hits
# after clicking a project open to look for something.
foreach ($shotKey in @($script:fold.Keys)) { $script:fold[$shotKey] = $false }
Update-List
Save-Shot 'roster-open'

# --- the roster with the age window off, which is the full 204 -------------
$script:showOlder = $true
Update-List
Save-Shot 'roster-all'
$script:showOlder = $false
Update-List

# --- nothing here may have changed the registry ----------------------------
if ($script:dirty) {
    Write-ShotBad 'the shot run marked the registry dirty - it must only ever read'
} else {
    Write-ShotOk 'the registry is untouched'
}

Write-Host ''
if ($shotFails) { Write-Host "$shotFails FAILURE(S)" -ForegroundColor Red; exit 1 }
Write-Host 'the shots are drawn' -ForegroundColor Green
exit 0
