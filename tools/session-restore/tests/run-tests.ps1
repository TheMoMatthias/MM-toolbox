#requires -Version 5.1
<#
.SYNOPSIS
    The session-restore test suite. Run it after touching sessions-gui.ps1,
    anything under gui\, or _common.ps1.

.DESCRIPTION
    Five suites, and each exists because something shipped broken.

      state   Get-SRConversationState. Hand-built transcripts force every state,
              so the assertions can actually fail regardless of what the operator
              happens to be running; then the same function over every real
              conversation, guarding cost and the 'unknown' rate among LIVE ones.

      headless  the GUI window BUILT BUT NEVER SHOWN, with fabricated session
              states so every band, the background agent, the open dialog and the
              idle-with-a-reply case are all present whatever the machine happens
              to be running. Nothing appears on screen and nothing takes focus.
              This is where the bulk of the checking belongs: every bug that has
              actually shipped from this subsystem was a code bug that a
              built-but-unshown window would have caught.
              -Shot <path> also renders it to a PNG off-screen.

      inbox   drives the real window through UI Automation: that it opens on the
              inbox, groups into bands, does NOT show the All view's column
              captions, that the count pills are real buttons, and that the view
              switch swaps lists. Every "is not showing" assertion is paired with
              the inverse in another view, so none of them can pass by finding
              nothing. Needs a desktop; skipped with -NoGui.

      keys    HOME, END, PAGEUP, PAGEDOWN and the arrows, against the All view
              because it is the list long enough to scroll. If it cannot find
              that view it FAILS rather than testing whatever is on screen -
              that fallback once made three working shortcuts look broken.

      app     Sessions.exe, the application wrapper. Not the window -- the four
              claims that shipping an exe makes: that it builds from source with
              nothing installed, that NO powershell.exe is spawned (the whole
              point), that no console is allocated, and that a second launch
              raises the first window instead of opening a second view of one
              registry. Its negative case runs the exe where the scripts are not
              and requires exit 2, which is what makes the rest able to go red.
              Needs a desktop, and refuses to judge anything while a session
              window is already open.

      jump    finding and activating a conversation's real Windows Terminal tab.
              Runs against the live machine, since whether a real tab can be
              found and switched to is not something a fixture can answer. It
              restores whichever tab was active when it started.

    RETIRED WITH THE TERMINAL PANEL: `frame` and `paint`. They tested
    select-sessions.ps1's geometry and its console painter - a hand-written TUI
    the window replaced. Their harness spliced that script just before its
    interactive loop; with the script gone there is nothing to splice.

    THE GUI IS ONE SCRIPT THAT ENDS IN ShowDialog, so a harness is that script
    with the call cut off and a driver bolted on in its place. This runner does
    the splicing, from the LIVE source every time -- the tests can never drift
    onto a stale copy. Generated harnesses go to .state\ , which is gitignored.

.PARAMETER Only
    Run one suite: frame, state, paint or keys.

.PARAMETER NoGui
    Skip the suites that need a desktop. Use on a machine that has none.

.EXAMPLE
    .\run-tests.ps1
    .\run-tests.ps1 -Only headless
    .\run-tests.ps1 -NoGui
#>
[CmdletBinding()]
param(
    # `shot` is the odd one out: it draws the real window to PNG and asserts
    # almost nothing. It never runs in a full sweep -- only when asked for by
    # name -- because its output is something to LOOK at, not something to pass.
    [ValidateSet('state', 'gui2', 'live', 'jump', 'relay', 'shot', 'design', 'type', 'perf', 'app')]
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

    # Render the window to this PNG, off-screen. Implies -Only shot; the suite
    # that used to honour it was retired with the window it drove.
    [string]$Shot,

    # Drive a CANDIDATE window script instead of the shipped one, by file name
    # within lib\. Every gui suite splices from the live source, so this is the
    # only way to put a rebuilt window under the suite before installing it -
    # which matters when the file cannot be replaced yet, and matters generally
    # for "does this build pass before I overwrite the one that works".
    [string]$GuiFile = 'sessions-window.ps1'
)

$ErrorActionPreference = 'Stop'

$here = $PSScriptRoot
if (-not $here -and $MyInvocation.MyCommand.Path) { $here = Split-Path -Parent $MyInvocation.MyCommand.Path }
if (-not $here) { $here = (Get-Location).Path }
$tool  = Split-Path -Parent $here
# The scripts moved into lib\ on 2026-08-28 so the tool folder shows the app
# rather than a wall of .ps1. $tool stays the TOOL root - .state, the config and
# the registry are anchored there - and only the SOURCES moved.
$lib   = Join-Path $tool 'lib'
$state = Join-Path $tool '.state'
if (-not (Test-Path $state)) { $null = New-Item -ItemType Directory -Path $state -Force }

# --- the splice -------------------------------------------------------------
# New-Harness spliced select-sessions.ps1 just before its interactive loop, for
# the `frame` and `paint` suites. Both went with the terminal panel: there is
# nothing left to splice, and the two things they guarded - that a frame fits
# its console and that an arrow key repaints four cells rather than 190 - are
# not questions a window has.
#
# `state` used that harness too, and did not need any of it: it tests
# _common.ps1 and builds its own fixtures. All it ever wanted was $here and a
# dot-source, which is what it gets now - one less thing that can break because
# a script it does not test changed shape.
function New-CommonHarness {
    param([string]$Driver, [string]$OutFile)
    $body = Get-Content -LiteralPath (Join-Path $here $Driver) -Raw
    $prefix = @(
        "`$here = '$lib'",
        ". (Join-Path `$here '_common.ps1')",
        ''
    ) -join "`n"
    $path = Join-Path $state $OutFile
    [System.IO.File]::WriteAllText($path, $prefix + $body, (New-Object System.Text.UTF8Encoding($false)))
    return $path
}

# --- the GUI splice ---------------------------------------------------------
# Same idea as New-Harness above, aimed at the other script. The window script
# builds its window and then calls ShowDialog; cut it at that line and the window
# exists, fully wired, with nothing on screen. Add_ContentRendered never fires on
# an unshown window, so no background scan starts and the state stays exactly
# what the driver puts there.
#
# There is one window now. lib\sessions-gui.ps1 and the suites that drove it
# (headless, inbox, keys) were deleted once tests\gui2-driver.ps1 covered the
# shipped one - a green suite that describes a window nobody launches is worse
# than no suite, because it reads as coverage.
function New-GuiHarness {
    param([string]$Driver, [string]$OutFile, [string]$Gui = 'sessions-window.ps1')

    $src = @(Get-Content -LiteralPath (Join-Path $lib $Gui))
    $cut = -1
    for ($k = 0; $k -lt $src.Count; $k++) {
        if ($src[$k].Trim() -eq '$null = $window.ShowDialog()') { $cut = $k; break }
    }
    if ($cut -lt 0) { throw ('marker gone: {0} no longer ends with "$null = $window.ShowDialog()"' -f $Gui) }

    # $PSScriptRoot would be .state for a spliced harness, so pin the real folder.
    $prefix = @($src[0..($cut - 1)]) | ForEach-Object {
        if ($_ -eq '$here = $PSScriptRoot') { "`$here = '$lib'" } else { $_ }
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
    foreach ($part in @(Get-ChildItem -LiteralPath (Join-Path $lib 'gui') -Filter '*.ps1' -ErrorAction SilentlyContinue)) {
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

# --- state: no console needed --------------------------------------------
if (-not $Only -or $Only -eq 'state') {
    Write-Host "`n=== state (what a conversation is doing) ===" -ForegroundColor Cyan
    $h = New-CommonHarness -Driver 'state-driver.ps1' -OutFile 'state-test.ps1'
    $out = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $h -NoScan 2>&1
    $out | ForEach-Object { Write-Host $_ }
    Record 'state' $LASTEXITCODE @($out)
}

# --- gui2: THE WINDOW THAT ACTUALLY OPENS -----------------------------------
# 🔴 THIS IS THE ONE THAT COVERS THE APP. headless, inbox and keys below all
# drive lib\sessions-gui.ps1, the RETIRED window; their green says nothing about
# what Sessions.exe launches. Same splice, aimed at the shipped script.
if (-not $Only -or $Only -eq 'gui2') {
    Write-Host "`n=== gui2 (the shipped window, built and never shown) ===" -ForegroundColor Cyan
    $h = New-GuiHarness -Driver 'gui2-driver.ps1' -OutFile 'gui2-test.ps1' -Gui $GuiFile
    $out = & powershell.exe -STA -NoProfile -ExecutionPolicy Bypass -File $h -NoScan 2>&1
    $out | ForEach-Object { Write-Host $_ }
    Record 'gui2' $LASTEXITCODE @($out)
}


# --- live: an HWND, but never a window anybody sees --------------------------
# The three things a never-shown window cannot answer: whether Windows will DRAG
# it, whether a click can land in the skill picker, and whether the transcript
# follows the newest line. It shows the window UNACTIVATED on a secondary
# display (off-screen when there is only one) and asks Windows via WM_NCHITTEST
# instead of moving the mouse - so it never takes focus and never touches the
# cursor. That is why it is NOT behind -NoSteal: it is safe to run while
# somebody is using the machine.
if (-not $Only -or $Only -eq 'live') {
    Write-Host "`n=== live (an HWND, unactivated and out of sight) ===" -ForegroundColor Cyan
    # -Place was declared and wired to nothing. This is the suite it was for.
    if ($Place) { $env:SR_PLACE = $Place } else { Remove-Item Env:\SR_PLACE -ErrorAction SilentlyContinue }
    $h = New-GuiHarness -Driver 'live-driver.ps1' -OutFile 'live-test.ps1' -Gui $GuiFile
    $out = & powershell.exe -STA -NoProfile -ExecutionPolicy Bypass -File $h -NoScan 2>&1
    $out | ForEach-Object { Write-Host $_ }
    Record 'live' $LASTEXITCODE @($out)
}

# --- relay: the question round trip, against a live console -----------------
# Spawns a REPLICA of claude's menu in a real console and answers it through the
# shipped code. It puts a minimized window on the desktop for a few seconds and
# writes real key events into it, so -NoSteal skips it -- but it never touches a
# claude session, and it kills what it started in a finally.
if ((-not $Only -or $Only -eq 'relay') -and -not $NoSteal) {
    Write-Host "`n=== relay (reading and answering a menu on a live console) ===" -ForegroundColor Cyan
    $h = New-CommonHarness -Driver 'relay-driver.ps1' -OutFile 'relay-test.ps1'
    $out = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $h 2>&1
    $out | ForEach-Object { Write-Host $_ }
    Record 'relay' $LASTEXITCODE @($out)
}

# --- shot: the real registry, drawn to PNG, never shown ---------------------
# BY NAME ONLY. It is not part of `all suites passed`: it renders the operator's
# own 204 conversations so a layout change can be looked at at real density,
# which is where every clipped pill and mojibaked caption has actually hidden.
if ($Only -eq 'shot' -or $Shot) {
    Write-Host "`n=== shot (the real window, drawn to PNG) ===" -ForegroundColor Cyan
    if ($Shot) { $env:SR_SHOT_OUT = $Shot }
    $h = New-GuiHarness -Driver 'shot-driver.ps1' -OutFile 'shot-test.ps1' -Gui $GuiFile
    $out = & powershell.exe -STA -NoProfile -ExecutionPolicy Bypass -File $h -NoScan 2>&1
    $out | ForEach-Object { Write-Host $_ }
    Record 'shot' $LASTEXITCODE @($out)
}

# --- design: competing designs for the reading surface, drawn to PNG ---------
# BY NAME ONLY, like shot. It draws the SAME conversation under several
# treatments of the transcript, the question panel and the header, so a design
# choice can be made by looking at real content at real density instead of by
# describing it. Nothing it draws is in lib\ - the variants live in the driver
# until one is picked.
if ($Only -eq 'design') {
    Write-Host "`n=== design (competing reading surfaces, drawn to PNG) ===" -ForegroundColor Cyan
    $h = New-GuiHarness -Driver 'design-driver.ps1' -OutFile 'design-test.ps1' -Gui $GuiFile
    $out = & powershell.exe -STA -NoProfile -ExecutionPolicy Bypass -File $h -NoScan 2>&1
    $out | ForEach-Object { Write-Host $_ }
    Record 'design' $LASTEXITCODE @($out)
}

# --- type: the same words under four text-rendering settings ----------------
# BY NAME ONLY. It asserts nothing - WPF text rendering is a look, and the only
# honest way to choose is to see the shipped antialiasing magnified.
if ($Only -eq 'type') {
    Write-Host "`n=== type (four text-rendering settings, magnified) ===" -ForegroundColor Cyan
    $h = New-GuiHarness -Driver 'type-driver.ps1' -OutFile 'type-test.ps1' -Gui $GuiFile
    $out = & powershell.exe -STA -NoProfile -ExecutionPolicy Bypass -File $h -NoScan 2>&1
    $out | ForEach-Object { Write-Host $_ }
    Record 'type' $LASTEXITCODE @($out)
}

# --- perf: every operation the operator can cause, timed ---------------------
# BY NAME ONLY, like shot, and for the same reason: it runs against the
# operator's own registry at real size and its output is a table to read rather
# than a verdict. It fails only on a genuine STALL - see the note in the driver
# about benchmarks that cry wolf.
if ($Only -eq 'perf') {
    Write-Host "`n=== perf (every operation, timed) ===" -ForegroundColor Cyan
    $h = New-GuiHarness -Driver 'perf-driver.ps1' -OutFile 'perf-test.ps1' -Gui $GuiFile
    $out = & powershell.exe -STA -NoProfile -ExecutionPolicy Bypass -File $h -NoScan 2>&1
    $out | ForEach-Object { Write-Host $_ }
    Record 'perf' $LASTEXITCODE @($out)
}

# --- jump: needs a desktop and the operator's real terminals -----------------
if ((-not $Only -or $Only -eq 'jump') -and -not $NoGui -and -not $NoSteal) {
    Write-Host "`n=== jump (reaching a session's terminal tab) ===" -ForegroundColor Cyan
    $drv = Join-Path $here 'jump-driver.ps1'
    $out = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $drv 2>&1
    $out | ForEach-Object { Write-Host $_ }
    Record 'jump' $LASTEXITCODE @($out)
}

# --- app: builds and launches Sessions.exe -----------------------------------
# Puts the real window on the desktop for a few seconds and closes it again, so
# it sits behind -NoSteal with the rest. It launches with -NoScan and hashes
# sessions-registry.json either side: a test is not allowed to change which
# conversations the operator has ticked.
if ((-not $Only -or $Only -eq 'app') -and -not $NoGui -and -not $NoSteal) {
    Write-Host "`n=== app (Sessions.exe) ===" -ForegroundColor Cyan
    $drv = Join-Path $here 'app-driver.ps1'
    $out = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $drv 2>&1
    $out | ForEach-Object { Write-Host $_ }
    # 2 means a session window was already open, which is a statement about the
    # desktop and not about the exe. Not a pass, deliberately not a failure.
    Record 'app' $LASTEXITCODE @($out)
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
