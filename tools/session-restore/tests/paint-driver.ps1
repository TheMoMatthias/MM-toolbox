
# ------------------------------------------------- real-console paint driver
# Runs in its OWN console window so [Console]::CursorTop, CursorVisible and
# KeyAvailable are real. Results go to a file, because stdout here is a live
# screen buffer.
# The runner supplies this. stdout here is a live screen buffer, so results
# have to leave through a file rather than the pipe.
$log = $env:SR_TEST_OUT
if (-not $log) { $log = Join-Path $here '.state\paint-result.txt' }
$out = New-Object System.Collections.Generic.List[string]
$fails = 0
function Fail { param($m) $script:out.Add("  FAIL  $m"); $script:fails++ }
function Pass { param($m) $script:out.Add("  ok    $m") }

$script:clears = 0
function Clear-Host { $script:clears++; [Console]::Clear() }

# Count every write the painter makes, because the whole defect was their number.
$script:writes = 0
function Write-Host {
    [CmdletBinding()]
    param([Parameter(ValueFromPipeline=$true,Position=0)]$Object, [switch]$NoNewline,
          $ForegroundColor, $BackgroundColor, $Separator)
    $script:writes++
    $p = @{ Object = $Object }
    if ($NoNewline) { $p.NoNewline = $true }
    if ($ForegroundColor) { $p.ForegroundColor = $ForegroundColor }
    Microsoft.PowerShell.Utility\Write-Host @p
}

$hasConsole = $true
try { $null = [Console]::CursorTop } catch { $hasConsole = $false }
$r = $Host.UI.RawUI
$out.Add("console: $hasConsole   buffer $($r.BufferSize.Width)x$($r.BufferSize.Height)   window $($r.WindowSize.Width)x$($r.WindowSize.Height)")
if (-not $hasConsole) { Fail 'no real console - this test proves nothing'; $out | Out-File $log -Encoding utf8; exit 1 }

$rows = Build-Rows
$out.Add("rows: $(@($rows).Count)")

function Snap {
    $w = $Host.UI.RawUI.WindowSize.Width; $h = $Host.UI.RawUI.WindowSize.Height
    $top = $Host.UI.RawUI.WindowPosition.Y
    $rect = New-Object System.Management.Automation.Host.Rectangle 0, $top, ($w-1), ($top+$h-1)
    $buf = $Host.UI.RawUI.GetBufferContents($rect)
    $lines = @()
    for ($y = 0; $y -lt $buf.GetLength(0); $y++) {
        $s = ''
        for ($x = 0; $x -lt $buf.GetLength(1); $x++) { $s += $buf[$y,$x].Character }
        $lines += $s
    }
    return ,$lines
}

# --- 1. first frame, then two arrow keys ------------------------------------
Render -Rows $rows -Cursor 0
$c1 = $script:clears; $w1 = $script:writes; $y1 = [Console]::CursorTop; $s1 = Snap
$script:writes = 0
Render -Rows $rows -Cursor 1
$c2 = $script:clears; $w2 = $script:writes; $y2 = [Console]::CursorTop; $s2 = Snap
$script:writes = 0
Render -Rows $rows -Cursor 2
$c3 = $script:clears; $w3 = $script:writes; $y3 = [Console]::CursorTop

$out.Add("writes: first frame $w1, then $w2 and $w3 per arrow key")
if ($c1 -ne 1) { Fail "first frame cleared $c1 times, expected 1" } else { Pass 'first frame clears once' }
if ($c3 -ne 1) { Fail "an arrow key cleared the screen (total clears: $c3)" } else { Pass 'arrow keys never clear' }
if ($y1 -ne $y2 -or $y2 -ne $y3) { Fail "frame end row drifted: $y1 -> $y2 -> $y3" } else { Pass "frame parks on the same row every time (row $y1)" }
# THE regression guard: a one-row move must not repaint the whole frame.
if ($w2 -gt 12 -or $w3 -gt 12) { Fail "an arrow key made $w2/$w3 writes - the whole frame is being repainted" }
else { Pass "an arrow key makes $w2 writes (a full repaint was about 190)" }

$diff = 0
for ($i = 0; $i -lt [Math]::Min($s1.Count, $s2.Count); $i++) { if ($s1[$i] -ne $s2[$i]) { $diff++ } }
if ($diff -eq 0)     { Fail 'the screen did not change between cursor 0 and cursor 1' }
elseif ($diff -gt 4) { Fail "$diff screen lines changed for a one-row move" }
else                 { Pass "$diff screen line(s) change per arrow key" }

# --- 2. an identical frame must write nothing -------------------------------
$script:writes = 0
Render -Rows $rows -Cursor 2
if ($script:writes -ne 0) { Fail "repainting an identical frame made $($script:writes) writes" }
else { Pass 'repainting an identical frame writes nothing at all' }

# --- 3. LATENCY: a frame must beat the key-repeat interval ------------------
# Windows repeats a held key about every 33 ms. A frame slower than that queues
# keypresses that drain after the finger comes off, which is what made the list
# run away to the end of its own accord.
# MEDIAN of individually timed frames, not a mean over a batch. A mean is
# dominated by whatever else the machine was doing -- an earlier run measured the
# cheaper path SLOWER than the dearer one, which is the signature of scheduler
# noise rather than of a real cost. The median answers "what does a frame usually
# cost", which is the question that matters for keeping ahead of key-repeat.
function Measure-Frames { param([int]$N)
    $t = @()
    for ($k = 0; $k -lt $N; $k++) {
        $sw = [Diagnostics.Stopwatch]::StartNew()
        Render -Rows $rows -Cursor (10 + ($k % 20))
        $sw.Stop()
        $t += $sw.Elapsed.TotalMilliseconds
    }
    $s = @($t | Sort-Object)
    return [PSCustomObject]@{ Med = $s[[int]($s.Count/2)]; Min = $s[0]; Max = $s[-1] }
}
$m = Measure-Frames 41
$out.Add(("frame time: best {0:N1} ms   median {1:N1}   worst {2:N1}   ({3:N0} fps at best)" -f $m.Min, $m.Med, $m.Max, (1000/$m.Min)))
# Asserted on the BEST frame, not the median. The minimum is what the CODE costs;
# the median is what the machine happened to be doing. Measured on an idle box the
# two agree (20.7 median / 17.7 best); with a real claude.exe running alongside,
# the median went to 37 ms while the best stayed at 21.7 and nothing in the panel
# had changed. Asserting on the median there would have reported a regression that
# did not exist, and the fix for that is a better estimator, not a looser budget.
#
# An occasional slow frame is survivable anyway: the coalescer drains queued
# movement keys WITHOUT drawing each one, so a 60 ms frame no longer means the
# list runs away. That failure mode is guarded by the write-count assertion above
# -- 4 writes per arrow key -- which is a property of the code and does not move
# with machine load at all. That is the real regression guard; this is a budget.
if ($m.Min -gt 33) { Fail ("even the best frame costs {0:N1} ms, over the 33 ms key-repeat budget" -f $m.Min) }
else { Pass ("the best frame costs {0:N1} ms, inside the 33 ms key-repeat budget (median {1:N1} under load)" -f $m.Min, $m.Med) }

# --- 4. a filter change must repaint the whole frame ------------------------
$script:filter = 'algo'
$fr = Build-Rows
$script:writes = 0
Render -Rows $fr -Cursor 0
if ($script:writes -lt 20) { Fail "a filter change made only $($script:writes) writes - stale rows are being left on screen" }
else { Pass "a filter change repaints the frame ($($script:writes) writes)" }
$script:filter = $null
$rows = Build-Rows
Render -Rows $rows -Cursor 0

# --- 5. no painted line may reach the last column ---------------------------
# The previous version of this check TrimEnd()ed first, so it could never fail.
$s = Snap
$maxw = 0
foreach ($v in $s) { $t = $v.TrimEnd(); if ($t.Length -gt $maxw) { $maxw = $t.Length } }
$bw = $Host.UI.RawUI.BufferSize.Width
$out.Add("widest painted line: $maxw   buffer width: $bw")
if ($maxw -ge $bw) { Fail "a painted line reaches column $maxw of a $bw-wide buffer and will wrap" }
else { Pass "widest painted line is $maxw in a $bw-wide buffer - cannot wrap" }

# --- 6. foreign write, caret ------------------------------------------------
$before = $script:clears
Write-Host 'a prompt printed under the panel'
# What the main loop does after any key that is not a movement key. The screen
# check is deliberately NOT armed on the arrow-key path: re-reading a row off the
# screen costs a marshalled GetBufferContents and only a key that can PRINT can
# scroll the panel out from under us.
$script:verifyScreen = $true
Render -Rows $rows -Cursor 3
if ($script:clears -ne $before + 1) { Fail 'a foreign write did not trigger exactly one clear' } else { Pass 'a write below the panel triggers exactly one clear' }
$s6 = Snap
if (@($s6 | Where-Object { $_ -match 'a prompt printed under the panel' }).Count) { Fail 'the foreign line survived the repaint' } else { Pass 'the foreign line is gone after the repaint' }
if ([Console]::CursorVisible) { Fail 'caret visible while painting' } else { Pass 'caret hidden while painting' }
Show-Caret
if (-not [Console]::CursorVisible) { Fail 'Show-Caret did not restore the caret' } else { Pass 'Show-Caret restores the caret' }

# --- 6b. the arrow-key path, reported not asserted --------------------------
# Timing the two paths apart has been inconclusive on a loaded machine: the path
# doing LESS work has measured slower than the one doing more. So this is printed
# for information and NOT asserted -- an assertion that fails on machine load is
# worse than no assertion, because it teaches you to ignore a red suite. Test 3
# already guards the thing that actually matters.
$script:verifyScreen = $false
$fast = (Measure-Frames 21).Med
$script:verifyScreen = $true
$slow = (Measure-Frames 21).Med
$out.Add(("FYI  arrow-key frame {0:N1} ms median   with the screen check {1:N1} ms median" -f $fast, $slow))

# --- 7. the coalescer ------------------------------------------------------
# No way to inject real keystrokes here, so verify the arithmetic and the
# clamping with an empty input buffer.
$max = @($rows).Count - 1
if ((Move-Cursor -Cursor 5 -Max $max -Delta 1) -ne 6)        { Fail 'Move-Cursor did not step down by one' } else { Pass 'Move-Cursor steps down by one' }
if ((Move-Cursor -Cursor 0 -Max $max -Delta (-1)) -ne 0)     { Fail 'Move-Cursor went above the top' } else { Pass 'Move-Cursor clamps at the top' }
if ((Move-Cursor -Cursor $max -Max $max -Delta 1) -ne $max)  { Fail 'Move-Cursor went past the end' } else { Pass 'Move-Cursor clamps at the end' }
if ((Move-Cursor -Cursor 5 -Max $max -Absolute 0) -ne 0)     { Fail 'Move-Cursor -Absolute 0 failed' } else { Pass 'Move-Cursor jumps to an absolute row' }
if ((Move-Cursor -Cursor 5 -Max (-1) -Delta 1) -ne 0)        { Fail 'Move-Cursor on an empty list did not return 0' } else { Pass 'Move-Cursor survives an empty list' }

$out.Add('')
$out.Add($(if ($fails) { "$fails FAILURE(S)" } else { 'all paint tests passed' }))
$out | Out-File -FilePath $log -Encoding utf8
[Console]::Clear()
exit $(if ($fails) { 1 } else { 0 })
