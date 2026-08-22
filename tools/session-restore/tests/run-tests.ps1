#requires -Version 5.1
<#
.SYNOPSIS
    The session-restore test suite. Run it after touching select-sessions.ps1 or
    sessions-gui.ps1.

.DESCRIPTION
    Three suites, and each exists because something shipped broken.

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

    THE PANEL IS ONE SCRIPT THAT ENDS IN AN INTERACTIVE LOOP, so a harness is
    that script with the loop cut off and a driver bolted on in its place. This
    runner does the splicing, from the LIVE source every time -- the tests can
    never drift onto a stale copy. If select-sessions.ps1 changes shape enough
    that the markers stop matching, this fails loudly rather than testing
    something that no longer exists.

    Generated harnesses go to .state\ , which is gitignored.

.PARAMETER Only
    Run one suite: frame, paint or keys.

.PARAMETER NoGui
    Skip the keys suite. Use on a machine with no interactive desktop.

.EXAMPLE
    .\run-tests.ps1
    .\run-tests.ps1 -Only frame
    .\run-tests.ps1 -NoGui
#>
[CmdletBinding()]
param(
    [ValidateSet('frame', 'paint', 'keys')]
    [string]$Only,
    [switch]$NoGui
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
if ((-not $Only -or $Only -eq 'keys') -and -not $NoGui) {
    Write-Host "`n=== keys (GUI keyboard navigation) ===" -ForegroundColor Cyan
    $drv = Join-Path $here 'keys-driver.ps1'
    $out = & powershell.exe -STA -NoProfile -ExecutionPolicy Bypass -File $drv 2>&1
    $out | ForEach-Object { Write-Host $_ }
    # 2 means it could not get keyboard focus, which is a statement about the
    # desktop and not about the GUI. Not a pass, and deliberately not a failure.
    Record 'keys' $LASTEXITCODE @($out)
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
