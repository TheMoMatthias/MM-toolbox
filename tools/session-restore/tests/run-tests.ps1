#requires -Version 5.1
<#
.SYNOPSIS
    The session-restore test suite. Run it after touching select-sessions.ps1 or
    sessions-gui.ps1.

.DESCRIPTION
    Four suites, and each exists because something shipped broken.

      frame   pure geometry. Builds the panel's frame at seven window sizes with
              the filter line and the unattributed warning forced on, and checks
              it never exceeds the window, always shows a list row, always keeps
              the cursor on screen, and never swallows a blank line.

      paint   runs in its own console window, because [Console]::CursorTop,
              CursorVisible and KeyAvailable are meaningless without one. Counts
              the WRITES the painter makes -- 4 per arrow key, ~190 for a full
              repaint -- and times a frame against the 33 ms key-repeat interval.

      keys    drives the GUI through UI Automation: HOME, END, PAGEUP, PAGEDOWN
              and the arrows. Needs a desktop session; skipped with -NoGui.

      headless  the GUI window BUILT BUT NEVER SHOWN, with fabricated session
              states so every band, the background agent, the open dialog and the
              idle-with-a-reply case are all present whatever the machine happens
              to be running. Nothing appears on screen and nothing takes focus.
              -Shot <path> also renders it to a PNG off-screen.

      inbox   drives the GUI's inbox: that it opens on the inbox, groups into
              bands, does NOT show the tree's column captions, that the count
              pills are real buttons, and that the view switch swaps lists.
              Every "is not showing" assertion is paired with the inverse in
              another view, so none of them can pass by finding nothing.
              Needs a desktop session; skipped with -NoGui.

      jump    finding and activating a conversation's real Windows Terminal tab.
              Runs against the live machine, since whether a real tab can be
              found and switched to is not something a fixture can answer. It
              restores whichever tab was active when it started.

      state   Get-SRConversationState. Hand-built transcripts force every state,
              so the assertions can actually fail regardless of what the operator
              happens to be running; then the same function over every real
              conversation, guarding cost and the 'unknown' rate among LIVE ones.

    THE PANEL IS ONE SCRIPT THAT ENDS IN AN INTERACTIVE LOOP, so a harness is
    that script with the loop cut off and a driver bolted on in its place. This
    runner does the splicing, from the LIVE source every time -- the tests can
    never drift onto a stale copy. If select-sessions.ps1 changes shape enough
    that the markers stop matching, this fails loudly rather than testing
    something that no longer exists.

    Generated harnesses go to .state\ , which is gitignored.

.PARAMETER Only
    Run one suite: frame, state, paint or keys.

.PARAMETER NoGui
    Skip the keys suite. Use on a machine with no interactive desktop.

.EXAMPLE
    .\run-tests.ps1
    .\run-tests.ps1 -Only frame
    .\run-tests.ps1 -NoGui
#>
[CmdletBinding()]
param(
    [ValidateSet('frame', 'paint', 'keys', 'state', 'inbox', 'jump', 'headless')]
    [string]$Only,
    [switch]$NoGui,

    # Keep every test window on a chosen screen and open it WITHOUT taking
    # focus. "<left>,<top>" in virtual-screen coordinates, so a monitor to the
    # left of the primary is negative -- e.g. -Place '-3440,0'.
    [string]$Place,

    # Skip every suite that puts a window on someone's screen: `keys` sends real
    # keystrokes, `jump` raises a terminal on purpose, and `inbox` drives the
    # visible window. Use this while the machine is being used for something
    # else -- `headless` covers most of what `inbox` asserts, without appearing.
    [switch]$NoSteal,

    # Render the headless window to this PNG. Off-screen, via
    # RenderTargetBitmap -- no window appears in order to produce it.
    [string]$Shot
)

$ErrorActionPreference = 'Stop'

$here = $PSScriptRoot
if (-not $here -and $MyInvocation.MyCommand.Path) { $here = Split-Path -Parent $MyInvocation.MyCommand.Path }
if (-not $here) { $here = (Get-Location).Path }
$tool  = Split-Path -Parent $here
$state = Join-Path $tool '.state'
if (-not (Test-Path $state)) { $null = New-Item -ItemType Directory -Path $state -Force }

# --- the splice -------------------------------------------------------------
# Cut the panel just before its interactive loop and append a driver. Every
# marker is asserted: a silent mismatch would produce a harness that tests the
# wrong half of the file and passes.
function New-Harness {
    param([string]$Driver, [string]$OutFile)

    $src = @(Get-Content -LiteralPath (Join-Path $tool 'select-sessions.ps1'))

    $i = ($src | Select-String -SimpleMatch 'if (-not $interactive) {' | Select-Object -First 1).LineNumber
    if (-not $i) { throw "marker gone: the no-console bail-out 'if (-not `$interactive) {' is not in select-sessions.ps1" }
    $i = $i - 1
    $j = -1
    for ($k = $i; $k -lt $src.Count; $k++) { if ($src[$k] -eq '}') { $j = $k; break } }
    if ($j -lt 0) { throw 'marker gone: no closing brace for the no-console bail-out' }
    $src = @($src[0..($i - 1)]) + @($src[($j + 1)..($src.Count - 1)])

    $cut = -1
    for ($k = 0; $k -lt $src.Count; $k++) { if ($src[$k].StartsWith('$rows = Build-Rows')) { $cut = $k; break } }
    if ($cut -lt 0) { throw 'marker gone: the interactive loop no longer starts at "$rows = Build-Rows"' }

    # $PSScriptRoot would be .state for a spliced harness, so pin the real folder.
    $prefix = @($src[0..($cut - 1)]) | ForEach-Object {
        if ($_ -eq '$here = $PSScriptRoot') { "`$here = '$tool'" } else { $_ }
    }

    $body = Get-Content -LiteralPath (Join-Path $here $Driver) -Raw
    $path = Join-Path $state $OutFile
    [System.IO.File]::WriteAllText($path, (($prefix -join "`n") + $body), (New-Object System.Text.UTF8Encoding($false)))
    return $path
}

# Passed to every GUI the drivers start. Set once, here, so no driver has to
# know about it.
if ($Place) {
    $env:SR_GUI_PLACE = "$Place,noactivate"
    Write-Host "test windows: placed at $Place, opened without focus" -ForegroundColor DarkGray
} else {
    Remove-Item Env:\SR_GUI_PLACE -ErrorAction SilentlyContinue
}
if ($NoSteal) { Write-Host "skipping the suites that put a window on screen (keys, inbox, jump)" -ForegroundColor DarkGray }

# --- the GUI splice ---------------------------------------------------------
# Same idea as New-Harness above, aimed at the other script. sessions-gui.ps1
# builds its window and then calls ShowDialog; cut it at that line and the window
# exists, fully wired, with nothing on screen. Add_ContentRendered never fires on
# an unshown window, so no background scan starts and the state stays exactly
# what the driver puts there.
function New-GuiHarness {
    param([string]$Driver, [string]$OutFile)

    $src = @(Get-Content -LiteralPath (Join-Path $tool 'sessions-gui.ps1'))
    $cut = -1
    for ($k = 0; $k -lt $src.Count; $k++) {
        if ($src[$k].Trim() -eq '$null = $window.ShowDialog()') { $cut = $k; break }
    }
    if ($cut -lt 0) { throw 'marker gone: sessions-gui.ps1 no longer ends with "$null = $window.ShowDialog()"' }

    # $PSScriptRoot would be .state for a spliced harness, so pin the real folder.
    $prefix = @($src[0..($cut - 1)]) | ForEach-Object {
        if ($_ -eq '$here = $PSScriptRoot') { "`$here = '$tool'" } else { $_ }
    }

    $body = Get-Content -LiteralPath (Join-Path $here $Driver) -Raw

    # A DRIVER MUST NOT SHADOW THE GUI'S OWN STATE.
    #
    # The driver is APPENDED to the script, not called as a function, so every
    # "$x = ..." at its top level writes the SAME scope the GUI keeps its state
    # in. "$live = $rows[0]" in a test is $script:live - the liveness table -
    # and the symptom is a staged conversation quietly vanishing from the list
    # four hundred lines later with every assertion still green.
    #
    # Three of them were in this suite: $live, $rows and $said. Caught by hand;
    # caught by construction from here on.
    # EVERY FILE THE HARNESS WILL LOAD, not just this one. sessions-gui.ps1 was
    # split into gui\*.ps1, and half the script state moved with it - a guard
    # that only read the main file would have stopped seeing most of the names
    # it exists to protect, silently, on the day of the split.
    $allSrc = ($src -join "`n")
    foreach ($part in @(Get-ChildItem -LiteralPath (Join-Path $tool 'gui') -Filter '*.ps1' -ErrorAction SilentlyContinue)) {
        $allSrc += "`n" + (Get-Content -LiteralPath $part.FullName -Raw)
    }
    $scriptNames = @{}
    foreach ($m in [regex]::Matches($allSrc, '\$script:([A-Za-z_]\w*)')) {
        $scriptNames[$m.Groups[1].Value.ToLower()] = $true
    }
    $clash = @{}
    foreach ($pat in @('(?m)^\s*\$([A-Za-z_]\w*)\s*=', 'foreach \(\$([A-Za-z_]\w*) in')) {
        foreach ($m in [regex]::Matches($body, $pat)) {
            $nm = $m.Groups[1].Value
            if ($scriptNames[$nm.ToLower()]) { $clash[$nm] = $true }
        }
    }
    if ($clash.Count) {
        throw ("$Driver assigns $(@($clash.Keys).Count) name(s) the GUI keeps script state in, and the driver runs in that same scope: " +
               (@($clash.Keys | Sort-Object) -join ', ') +
               ". Rename them in the driver - a test that overwrites `$script:live cannot fail honestly.")
    }

    $path = Join-Path $state $OutFile
    [System.IO.File]::WriteAllText($path, (($prefix -join "`n") + $body), (New-Object System.Text.UTF8Encoding($false)))
    return $path
}

$results = @()
function Record { param([string]$Name, [int]$Code, [string[]]$Output)
    $script:results += [PSCustomObject]@{ Name = $Name; Code = $Code; Output = $Output }
}

# --- frame: no console needed -----------------------------------------------
if (-not $Only -or $Only -eq 'frame') {
    Write-Host "`n=== frame (geometry) ===" -ForegroundColor Cyan
    $h = New-Harness -Driver 'frame-driver.ps1' -OutFile 'frame-test.ps1'
    $out = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $h -NoScan 2>&1
    $out | ForEach-Object { Write-Host $_ }
    Record 'frame' $LASTEXITCODE @($out)
}

# --- state: no console needed --------------------------------------------
if (-not $Only -or $Only -eq 'state') {
    Write-Host "`n=== state (what a conversation is doing) ===" -ForegroundColor Cyan
    $h = New-Harness -Driver 'state-driver.ps1' -OutFile 'state-test.ps1'
    $out = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $h -NoScan 2>&1
    $out | ForEach-Object { Write-Host $_ }
    Record 'state' $LASTEXITCODE @($out)
}

# --- paint: needs a real console, so it gets its own window ------------------
if (-not $Only -or $Only -eq 'paint') {
    Write-Host "`n=== paint (real console) ===" -ForegroundColor Cyan
    $h = New-Harness -Driver 'paint-driver.ps1' -OutFile 'paint-test.ps1'
    $res = Join-Path $state 'paint-result.txt'
    if (Test-Path -LiteralPath $res) { Remove-Item -LiteralPath $res -Force }
    $env:SR_TEST_OUT = $res
    # mode con matches what Sessions.bat does when double-clicked, so the geometry
    # under test is the geometry the operator actually gets.
    $cmd = "mode con: cols=118 lines=48 >nul 2>&1 & powershell.exe -NoProfile -ExecutionPolicy Bypass -File ""$h"" -NoScan"
    $p = Start-Process -FilePath cmd.exe -ArgumentList '/c', $cmd -WindowStyle Minimized -Wait -PassThru
    $out = if (Test-Path -LiteralPath $res) { @(Get-Content -LiteralPath $res) } else { @('NO RESULT FILE - the harness died before writing one') }
    $out | ForEach-Object { Write-Host $_ }
    Record 'paint' $p.ExitCode $out
}

# --- keys: drives the GUI, needs a desktop ----------------------------------
if ((-not $Only -or $Only -eq 'keys') -and -not $NoGui -and -not $NoSteal) {
    Write-Host "`n=== keys (GUI keyboard navigation) ===" -ForegroundColor Cyan
    $drv = Join-Path $here 'keys-driver.ps1'
    $out = & powershell.exe -STA -NoProfile -ExecutionPolicy Bypass -File $drv 2>&1
    $out | ForEach-Object { Write-Host $_ }
    # 2 means it could not get keyboard focus, which is a statement about the
    # desktop and not about the GUI. Not a pass, and deliberately not a failure.
    Record 'keys' $LASTEXITCODE @($out)
}

# --- headless: the window is BUILT but never SHOWN --------------------------
# Needs STA for WPF, needs no desktop attention at all: nothing appears, nothing
# takes focus, nothing touches the mouse. This is where the bulk of the checking
# belongs -- every bug that shipped from this subsystem was a code bug that a
# built-but-unshown window would have caught.
if (-not $Only -or $Only -eq 'headless') {
    Write-Host "`n=== headless (built, never shown) ===" -ForegroundColor Cyan
    $h = New-GuiHarness -Driver 'headless-driver.ps1' -OutFile 'headless-test.ps1'
    if ($Shot) { $env:SR_TEST_SHOT = $Shot } else { Remove-Item Env:\SR_TEST_SHOT -ErrorAction SilentlyContinue }
    $out = & powershell.exe -STA -NoProfile -ExecutionPolicy Bypass -File $h -NoScan 2>&1
    $out | ForEach-Object { Write-Host $_ }
    Record 'headless' $LASTEXITCODE @($out)
    Remove-Item Env:\SR_TEST_SHOT -ErrorAction SilentlyContinue
}

# --- inbox: drives the GUI, needs a desktop ---------------------------------
if ((-not $Only -or $Only -eq 'inbox') -and -not $NoGui -and -not $NoSteal) {
    Write-Host "`n=== inbox (the orchestration view) ===" -ForegroundColor Cyan
    $drv = Join-Path $here 'inbox-driver.ps1'
    $out = & powershell.exe -STA -NoProfile -ExecutionPolicy Bypass -File $drv 2>&1
    $out | ForEach-Object { Write-Host $_ }
    Record 'inbox' $LASTEXITCODE @($out)
}

# --- jump: needs a desktop and the operator's real terminals -----------------
if ((-not $Only -or $Only -eq 'jump') -and -not $NoGui -and -not $NoSteal) {
    Write-Host "`n=== jump (reaching a session's terminal tab) ===" -ForegroundColor Cyan
    $drv = Join-Path $here 'jump-driver.ps1'
    $out = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $drv 2>&1
    $out | ForEach-Object { Write-Host $_ }
    Record 'jump' $LASTEXITCODE @($out)
}

# --- summary ----------------------------------------------------------------
Write-Host "`n=== summary ===" -ForegroundColor Cyan
$bad = 0
foreach ($r in $results) {
    $verdict, $colour = switch ($r.Code) {
        0       { 'PASS',         'Green' }
        2       { 'INCONCLUSIVE', 'Yellow' }
        default { 'FAIL',         'Red' }
    }
    if ($r.Code -ne 0 -and $r.Code -ne 2) { $bad++ }
    Write-Host ("  {0,-6} {1}" -f $r.Name, $verdict) -ForegroundColor $colour
}
if (-not $results.Count) { Write-Host '  nothing ran' -ForegroundColor Yellow; exit 1 }
Write-Host ''
if ($bad) { Write-Host "$bad suite(s) failed" -ForegroundColor Red; exit 1 }
Write-Host 'all suites passed' -ForegroundColor Green
exit 0
