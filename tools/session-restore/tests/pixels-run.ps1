#requires -Version 5.1
<#
.SYNOPSIS
    Runs the click-to-pixels driver against the real window.

.DESCRIPTION
    Same splice as tests\run-tests.ps1 uses for every GUI suite: take
    lib\sessions-window.ps1, cut it at `$null = $window.ShowDialog()`, bolt the
    driver on in its place, and run the result in an STA child process. The
    window is fully wired and nothing is on screen.

    THIS EXISTS AS ITS OWN RUNNER, AND THAT IS DELIBERATE. run-tests.ps1 knows
    seven suites by name and passes each a fixed set of switches; this driver
    needs parameters run-tests has no way to forward (which gesture, how much
    delay to inject, where to inject it), and the spliced script cannot take
    parameters of its own because the GUI's own param() block is the one at the
    top of the file. So the parameters travel as environment variables, they are
    named here in one place, and every one of them is removed in a finally.

.PARAMETER Inject
    Milliseconds of artificial delay to add on an otherwise untouched code path,
    so the harness can be made to go red on purpose. THIS IS THE CALIBRATION:
    a harness that has never failed has never been shown to work.

.PARAMETER InjectAt
    Where the delay goes.
      build   inside Build-ReadDocument - the deferred document build, which is
              off the click and therefore invisible to the existing perf suite's
              'select a conversation (COLD - the click)'. This is the one that
              proves the new instrument sees something the old one cannot.
      click   inside the gesture itself, before it returns - both instruments
              should see this, which is the control.
      render  a blur on the pane, which costs nothing in the handler and nothing
              in layout and everything in the rasterizer.

.PARAMETER Only
    Substring: run only the gestures whose name contains it.
#>
[CmdletBinding()]
param(
    [double]$Inject = 0,
    [ValidateSet('build', 'click', 'render')]
    [string]$InjectAt = 'build',
    [string]$Only = '',
    [int]$Runs = 0,
    # Seconds to hold still and watch what the window does to itself with no
    # gesture at all. 0 = skip. See the idle-tax section in the driver.
    [int]$Idle = 0,
    # Attribute Build-Sessions' cost across the helpers it calls, by wrapping
    # them in the driver. Touches no lib file. Off by default - it adds a
    # rebuild pass and puts a stopwatch on ~2.000 calls.
    # 🪤 NOT -Profile. $Profile is a PowerShell automatic variable, and a
    # parameter of that name shadows it inside this script.
    [switch]$ProfileBuild,
    [string]$Driver = 'pixels-driver.ps1',
    [string]$GuiFile = 'sessions-window.ps1'
)

$ErrorActionPreference = 'Stop'

$here = $PSScriptRoot
if (-not $here -and $MyInvocation.MyCommand.Path) { $here = Split-Path -Parent $MyInvocation.MyCommand.Path }
if (-not $here) { $here = (Get-Location).Path }
$tool  = Split-Path -Parent $here
$lib   = Join-Path $tool 'lib'
$state = Join-Path $tool '.state'
if (-not (Test-Path $state)) { $null = New-Item -ItemType Directory -Path $state -Force }

# ---------------------------------------------------------------------------
# THE SPLICE. Copied in shape from run-tests.ps1's New-GuiHarness, including its
# two guards, because both of them exist for a bug that actually shipped:
#
#   * the marker check - if the last line of the window is no longer
#     ShowDialog, every GUI suite silently stops testing the window while still
#     reporting green;
#   * the name-clash guard - the driver is APPENDED, so `$rows = ...` at its top
#     level writes the window's own $script:rows.
#
# 🪤 IT IS A COPY AND THAT IS A COST. If the splice in run-tests.ps1 changes,
# this one does not follow. The alternative was to edit run-tests.ps1 to take a
# driver by name, which is a file another lane owns; a duplicated twenty lines
# with the divergence written down beats an unannounced edit to shared code.
# ---------------------------------------------------------------------------
$src = @(Get-Content -LiteralPath (Join-Path $lib $GuiFile))
$cut = -1
for ($k = 0; $k -lt $src.Count; $k++) {
    if ($src[$k].Trim() -eq '$null = $window.ShowDialog()') { $cut = $k; break }
}
if ($cut -lt 0) { throw ('marker gone: {0} no longer ends with "$null = $window.ShowDialog()"' -f $GuiFile) }

$prefix = @($src[0..($cut - 1)]) | ForEach-Object {
    if ($_ -eq '$here = $PSScriptRoot') { "`$here = '$lib'" } else { $_ }
}

$body = Get-Content -LiteralPath (Join-Path $here $Driver) -Raw

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

$harness = Join-Path $state 'pixels-test.ps1'
[System.IO.File]::WriteAllText($harness, (($prefix -join "`n") + $body), (New-Object System.Text.UTF8Encoding($false)))

# 🔴 THE OPERATOR'S CONFIG AND REGISTRY ARE HASHED EITHER SIDE. This driver
# never calls a handler that writes either of them, and that claim is worth
# exactly as much as the check that backs it. Not armed = say so, never assume.
#
# 🪤 AND THE TWO FILES DO NOT GET THE SAME VERDICT, because the check can only
# tell for one of them. Nothing else on this machine writes the config, so a
# changed config is this run's doing and is a hard failure. The REGISTRY is
# written by the operator's own session window every time a conversation ticks -
# it moved four times while this file was being written - so a changed hash
# there is genuinely ambiguous, and a gate that cannot tell must say "I cannot
# tell" rather than pick the answer that is convenient.
$cfgGuard = Join-Path $tool 'session-restore.config.json'
$regGuard = Join-Path $tool 'sessions-registry.json'
$guardWas = @{}
foreach ($g in @($cfgGuard, $regGuard)) {
    try { $guardWas[$g] = (Get-FileHash -LiteralPath $g -Algorithm SHA256 -ErrorAction Stop).Hash } catch { $guardWas[$g] = '' }
    if (-not $guardWas[$g]) {
        Write-Host ("[warn] could not hash {0} - that guard is NOT armed for this run." -f (Split-Path -Leaf $g)) -ForegroundColor Yellow
    }
}

$code = 3
try {
    $env:SR_PIX_INJECT    = ('{0}' -f $Inject)
    $env:SR_PIX_INJECT_AT = $InjectAt
    $env:SR_PIX_ONLY      = $Only
    $env:SR_PIX_RUNS      = ('{0}' -f $Runs)
    $env:SR_PIX_IDLE      = ('{0}' -f $Idle)
    $env:SR_PIX_PROFILE   = $(if ($ProfileBuild) { '1' } else { '' })
    $out = & powershell.exe -STA -NoProfile -ExecutionPolicy Bypass -File $harness -NoScan 2>&1
    $code = $LASTEXITCODE
    $out | ForEach-Object { Write-Host $_ }
}
finally {
    foreach ($v in 'SR_PIX_INJECT', 'SR_PIX_INJECT_AT', 'SR_PIX_ONLY', 'SR_PIX_RUNS', 'SR_PIX_IDLE', 'SR_PIX_PROFILE') {
        Remove-Item ("Env:\{0}" -f $v) -ErrorAction SilentlyContinue
    }
}

function Test-GuardMoved { param([string]$Path)
    if (-not $guardWas[$Path]) { return $null }          # never armed - not an answer
    $now = ''
    try { $now = (Get-FileHash -LiteralPath $Path -Algorithm SHA256 -ErrorAction Stop).Hash } catch { }
    if (-not $now) { return $null }
    return ($now -ne $guardWas[$Path])
}

if ((Test-GuardMoved $cfgGuard) -eq $true) {
    Write-Host '[FAIL] this run CHANGED session-restore.config.json - a measurement may not touch the operator settings.' -ForegroundColor Red
    exit 1
}
if ((Test-GuardMoved $regGuard) -eq $true) {
    Write-Host '[warn] sessions-registry.json moved during this run. This driver calls no save path, and the' -ForegroundColor Yellow
    Write-Host '       operator session window writes that file on its own tick, so this check cannot tell the' -ForegroundColor Yellow
    Write-Host '       two apart. It is reported, not judged.' -ForegroundColor Yellow
}

exit $code
