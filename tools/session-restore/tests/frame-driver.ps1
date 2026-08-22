
# ---------------------------------------------------------------- test driver
# Pure geometry: no console needed. Everything here is about the SHAPE of the
# frame, which is what the old hardcoded chrome height got wrong.
$script:tw = 120; $script:th = 30
function Get-WinSize { return [PSCustomObject]@{ W = $script:tw; H = $script:th } }

$fails = 0
function Fail { param($m) Write-Host ("  FAIL  " + $m) -ForegroundColor Red; $script:fails++ }
function Pass { param($m) Write-Host ("  ok    " + $m) -ForegroundColor Green }

$rows = Build-Rows
Write-Host ("rows built: " + @($rows).Count)
if (@($rows).Count -lt 20) { Fail "need a real registry with >=20 rows to test scrolling; got $(@($rows).Count)" }

# --- 1. the frame must NEVER be taller than the window ---------------------
# The original bug: a flat 14 lines reserved for chrome that reaches 18 with the
# filter line and the unattributed warning both up, so the frame overran the
# window and the terminal scrolled it. Worst case forced here, every size.
$script:unattributed = 3
$script:status       = 'launched 1 session'
$checked = 0
foreach ($wt in @($true, $false)) {
  $script:showWt = $wt
  foreach ($flt in @($null, 'a')) {
    $script:filter = $flt
    $r = Build-Rows
    foreach ($sz in @(@(120,30), @(80,24), @(200,60), @(118,48), @(100,16), @(64,14), @(90,12))) {
      $script:tw = $sz[0]; $script:th = $sz[1]
      $n = @($r).Count
      foreach ($cur in @(0, 3, [int]($n/2), [Math]::Max(0,$n-1))) {
        if ($n -eq 0 -or $cur -ge $n) { continue }
        $frame = Build-Frame -Rows $r -Cursor $cur
        $fc = @($frame).Count
        $checked++
        if ($fc -gt $script:th - 1) {
          Fail ("frame {0} lines in a {1}x{2} window (wt={3} filter={4} cur={5})" -f $fc, $sz[0], $sz[1], $wt, $flt, $cur)
        }
        # The cursor marker, not a tick: a LANE row carries no tick at all, and at
        # twelve rows the one surviving list row can easily be a lane.
        $body = 0
        foreach ($ln in $frame) { $t=''; foreach ($s in $ln) { $t += [string]$s.T }; if ($t -match '^\s*>') { $body++ } }
        if ($body -ne 1) { Fail ("{0} rows carry the cursor marker at {1}x{2} - expected exactly 1" -f $body, $sz[0], $sz[1]) }
      }
    }
  }
}
$script:filter = $null; $script:unattributed = 0; $script:status = $null; $script:showWt = $true
if ($fails -eq 0) { Pass "frame always fits the window and always shows list rows ($checked frames)" }

# --- 2. blank lines must survive the return --------------------------------
# CALIBRATION NOTE, recorded because it matters more than the assertion does.
# This was written to guard the unroll hazard: a List returned bare is unrolled
# by the output stream, and an EMPTY line would be unrolled a second time and
# vanish. It does NOT catch that. Removing the comma protection from
# Build-Frame's return was tried deliberately and this suite stayed green -- the
# hazard no longer exists, because blank lines are built as a one-segment line
# holding an empty string rather than as an empty array, so there is nothing for
# the stream to swallow. The comma is cheap insurance, not load-bearing.
# What this assertion DOES check is real and worth keeping: the frame still has
# its spacing rows, so the header, list and footer are not silently collapsing
# into each other.
$script:tw = 118; $script:th = 48
$rows = Build-Rows
$frame = Build-Frame -Rows $rows -Cursor 0
$blank = 0
foreach ($ln in $frame) {
  if ($null -eq $ln) { Fail "a null line survived into the frame" }
  $txt = ''
  foreach ($s in $ln) { $txt += [string]$s.T }
  if ($txt.Trim() -eq '') { $blank++ }
}
if ($blank -lt 3) { Fail "only $blank blank lines in the frame - they are being swallowed" }
else { Pass "blank lines survive the return ($blank of them)" }

# --- 3. the viewport is STICKY, not recentring ------------------------------
$script:first = 0
$null = Build-Frame -Rows $rows -Cursor 0
$page = $script:pageSize
$moved = -1
for ($c = 0; $c -lt @($rows).Count; $c++) {
  $before = $script:first
  $null = Build-Frame -Rows $rows -Cursor $c
  if ($script:first -ne $before) { $moved = $c; break }
}
if ($moved -lt 0) { Fail "viewport never moved at all over $(@($rows).Count) rows (page=$page)" }
elseif ($moved -lt $page - 3) { Fail "viewport scrolled at cursor $moved but the page holds $page rows - it is recentring, not sticky" }
else { Pass ("viewport is sticky: held still for {0} rows, first scrolled at cursor {1} (page={2})" -f $moved, $moved, $page) }

$script:first = 0
$null = Build-Frame -Rows $rows -Cursor (@($rows).Count - 1)
$deep = $script:first
if ($deep -le 0) { Fail "viewport did not follow the cursor to the end of the list" }
else {
  $null = Build-Frame -Rows $rows -Cursor 0
  if ($script:first -ne 0) { Fail "viewport did not return to the top (first=$($script:first))" }
  else { Pass "viewport follows the cursor to the end ($deep) and back to 0" }
}

# --- 4. the cursor row is always ON screen ----------------------------------
$script:first = 0
$bad = 0
for ($c = 0; $c -lt @($rows).Count; $c += 7) {
  $null = Build-Frame -Rows $rows -Cursor $c
  if ($c -lt $script:first -or $c -gt $script:first + $script:pageSize - 1) { $bad++ }
}
if ($bad) { Fail "$bad cursor positions fell outside the visible window" } else { Pass "cursor is always inside the visible window" }

# --- 5. exactly one row carries the highlight -------------------------------
# The operator lost track of the cursor entirely while moving, so the selected
# row now paints a full-width band. Exactly one row may carry it, and the band
# must run the whole way across or it reads as a ragged stripe.
$frame = Build-Frame -Rows $rows -Cursor 12
$hi = @()
for ($i = 0; $i -lt @($frame).Count; $i++) {
  foreach ($s in $frame[$i]) { if ($s.B) { $hi += $i; break } }
}
if (@($hi).Count -ne 1) { Fail "expected exactly one highlighted row, found $(@($hi).Count)" }
else { Pass "exactly one row carries the selection band" }
$allBg = $true
foreach ($s in $frame[$hi[0]]) { if ([string]$s.T -ne '' -and -not $s.B) { $allBg = $false } }
if (-not $allBg) { Fail "part of the selected row has no background - the band is ragged" }
else { Pass "every segment of the selected row carries the band" }
$marker = ''
foreach ($s in $frame[$hi[0]]) { $marker += [string]$s.T }
if ($marker -notmatch '^\s*>') { Fail "the highlighted row is not the one with the > marker" }
else { Pass "the band and the > marker are on the same row" }

# --- 6. Get-Visible memo must not change what it returns --------------------
$script:visCache = @{}
$a = @(Get-Visible $dirs[0])
$b = @(Get-Visible $dirs[0])
if ($a.Count -ne $b.Count) { Fail "cached Get-Visible returned $($b.Count), uncached $($a.Count)" }
else { Pass "Get-Visible memo is shape-stable ($($a.Count) sessions)" }

Write-Host ''
if ($fails) { Write-Host ("$fails FAILURE(S)") -ForegroundColor Red; exit 1 }
Write-Host 'all geometry tests passed' -ForegroundColor Green
exit 0
