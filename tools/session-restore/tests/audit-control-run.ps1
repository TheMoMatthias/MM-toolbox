#requires -Version 5.1
<#
.SYNOPSIS
    Runs the control-surface audit driver against the real window.

.DESCRIPTION
    Same splice every GUI suite uses: take lib\sessions-window.ps1, cut it at
    `$null = $window.ShowDialog()`, bolt the driver on in its place, and run the
    result in an STA child process. The window is fully wired and nothing is on
    screen.

    IT IS ITS OWN RUNNER for the reason pixels-run.ps1 gives: run-tests.ps1
    knows its suites by name and passes each a fixed set of switches, and this
    driver needs parameters it has no way to forward. They travel as environment
    variables, named here in one place, and removed in a finally.

.PARAMETER Inject
    Milliseconds of artificial delay injected into ONE wrapped function, so the
    attribution instrument can be made to go red on purpose. A profiler that has
    never mis-attributed on demand has never been shown to attribute at all.

.PARAMETER InjectInto
    Which function the delay goes into. Must be one the profiler wraps.

.PARAMETER Only
    Substring: run only the sections whose name contains it.
#>
[CmdletBinding()]
param(
    [double]$Inject = 0,
    [string]$InjectInto = 'Build-Rail',
    [string]$Only = '',
    [int]$Runs = 7,
    [string]$Driver = 'audit-control.ps1',
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

# --- the splice (a copy of run-tests.ps1's, with its two guards) -------------
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

$harness = Join-Path $state 'audit-control-test.ps1'
[System.IO.File]::WriteAllText($harness, (($prefix -join "`n") + $body), (New-Object System.Text.UTF8Encoding($false)))

# 🔒 THE OPERATOR'S TWO FILES, HASHED EITHER SIDE OF THE RUN.
#
# The driver redirects both paths into .state and PROVES the redirect with a
# real write before it presses anything. These hashes are the second, outer
# check on that claim - and the two files do NOT get the same verdict, because
# the check can only tell for one of them. Nothing else writes the config, so a
# changed config is this run's doing and is a hard failure. The registry is
# written by the operator's own window every time a conversation ticks, so a
# changed hash there is genuinely ambiguous and is reported, not judged.
$cfgGuard = Join-Path $tool 'session-restore.config.json'
$regGuard = Join-Path $tool 'sessions-registry.json'
$guardWas = @{}
foreach ($g in @($cfgGuard, $regGuard)) {
    try { $guardWas[$g] = (Get-FileHash -LiteralPath $g -Algorithm SHA256 -ErrorAction Stop).Hash } catch { $guardWas[$g] = '' }
    if (-not $guardWas[$g]) {
        Write-Host ("[warn] could not hash {0} - that guard is NOT armed for this run." -f (Split-Path -Leaf $g)) -ForegroundColor Yellow
    }
}

# 🔴 THE SOURCE MUST HOLD STILL WHILE IT IS BEING MEASURED. Another lane owns
# lib\sessions-window.ps1 and the splice above reads it LIVE, so a run started
# mid-edit measures a half-written window and its numbers look like numbers.
$srcGuard = @((Join-Path $lib $GuiFile), (Join-Path $lib '_common.ps1'))
$srcWas = @{}
foreach ($s in $srcGuard) {
    try { $srcWas[$s] = (Get-FileHash -LiteralPath $s -Algorithm SHA256 -ErrorAction Stop).Hash } catch { $srcWas[$s] = '' }
    if (-not $srcWas[$s]) {
        Write-Host ("[warn] could not hash {0} - the source-stability guard is NOT armed." -f (Split-Path -Leaf $s)) -ForegroundColor Yellow
        continue
    }
    $age = 999.0
    try { $age = ((Get-Date) - (Get-Item -LiteralPath $s).LastWriteTime).TotalSeconds } catch { }
    if ($age -lt 30) {
        Write-Host ("[warn] {0} was written {1:N0}s ago - another lane may be mid-edit." -f (Split-Path -Leaf $s), $age) -ForegroundColor Yellow
    }
}

$code = 3
try {
    $env:SR_AUD_INJECT      = ('{0}' -f $Inject)
    $env:SR_AUD_INJECT_INTO = $InjectInto
    $env:SR_AUD_ONLY        = $Only
    $env:SR_AUD_RUNS        = ('{0}' -f $Runs)
    # 🔴 'Continue' AROUND THE CHILD, AND NOT AS A TIDY-UP. With
    # ErrorActionPreference at Stop, one line on the child's stderr becomes a
    # terminating NativeCommandError here - so the run aborts at the `&` and
    # EVERY line the child printed is thrown away. Measured: a format-string
    # error in the driver surfaced as a bare "Error formatting a string" with
    # no output at all, which reads as a broken harness rather than as one bad
    # line in the driver.
    $zzEap = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $out = & powershell.exe -STA -NoProfile -ExecutionPolicy Bypass -File $harness -NoScan 2>&1
        $code = $LASTEXITCODE
    } finally { $ErrorActionPreference = $zzEap }
    $out | ForEach-Object { Write-Host $_ }
}
finally {
    foreach ($v in 'SR_AUD_INJECT', 'SR_AUD_INJECT_INTO', 'SR_AUD_ONLY', 'SR_AUD_RUNS') {
        Remove-Item ("Env:\{0}" -f $v) -ErrorAction SilentlyContinue
    }
}

function Test-GuardMoved { param([string]$Path)
    if (-not $guardWas[$Path]) { return $null }
    $now = ''
    try { $now = (Get-FileHash -LiteralPath $Path -Algorithm SHA256 -ErrorAction Stop).Hash } catch { }
    if (-not $now) { return $null }
    return ($now -ne $guardWas[$Path])
}

$srcMoved = @()
foreach ($s in $srcGuard) {
    if (-not $srcWas[$s]) { continue }
    $now = ''
    try { $now = (Get-FileHash -LiteralPath $s -Algorithm SHA256 -ErrorAction Stop).Hash } catch { }
    if ($now -and $now -ne $srcWas[$s]) { $srcMoved += (Split-Path -Leaf $s) }
}
if ($srcMoved.Count) {
    Write-Host ''
    Write-Host ("[INCONCLUSIVE] {0} changed WHILE this run was measuring it. Nothing above is offered as a number." -f ($srcMoved -join ' and ')) -ForegroundColor Magenta
    exit 2
}

if ((Test-GuardMoved $cfgGuard) -eq $true) {
    Write-Host '[FAIL] this run CHANGED session-restore.config.json - an audit may not touch the operator settings.' -ForegroundColor Red
    exit 1
}
if ((Test-GuardMoved $regGuard) -eq $true) {
    Write-Host '[warn] sessions-registry.json moved during this run. The driver redirects every save path away from it and' -ForegroundColor Yellow
    Write-Host '       proves that redirect, and the operator window writes this file on its own tick - so this outer check' -ForegroundColor Yellow
    Write-Host '       cannot tell the two apart. It is reported, not judged. The driver''s own inner check is the one to read.' -ForegroundColor Yellow
}
if ((Test-GuardMoved $cfgGuard) -eq $null) {
    Write-Host '[warn] the config guard was never armed - this run cannot say whether the operator settings moved.' -ForegroundColor Yellow
}

exit $code
