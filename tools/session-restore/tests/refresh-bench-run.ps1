# Splice and run refresh-bench.ps1 against the shipped window.
#
# The same cut run-tests.ps1 makes - the GUI is one script ending in
# ShowDialog, so a harness is that script with the call removed and a driver
# bolted on. Kept separate from run-tests because this is a BENCH, not a suite:
# it asserts nothing and always exits 0. Numbers to read, not a gate.
#
# Read-only. Nothing is shown, nothing is launched, typed into, sent or saved.
#
#     powershell -NoProfile -ExecutionPolicy Bypass -File tests\refresh-bench-run.ps1
param([string]$Driver = 'refresh-bench.ps1', [string]$Out = 'refresh-bench-test.ps1')

$tests = $PSScriptRoot
$tool  = Split-Path -Parent $tests
$lib   = Join-Path $tool 'lib'
$state = Join-Path $tool '.state'
if (-not (Test-Path $state)) { $null = New-Item -ItemType Directory -Path $state -Force }

$src = @(Get-Content -LiteralPath (Join-Path $lib 'sessions-window.ps1'))
$cut = -1
for ($k = 0; $k -lt $src.Count; $k++) {
    if ($src[$k].Trim() -eq '$null = $window.ShowDialog()') { $cut = $k; break }
}
if ($cut -lt 0) { throw 'marker gone: sessions-window.ps1 no longer ends with "$null = $window.ShowDialog()"' }

# $PSScriptRoot would be .state for a spliced harness, so pin the real folder.
$prefix = @($src[0..($cut - 1)]) | ForEach-Object {
    if ($_ -eq '$here = $PSScriptRoot') { "`$here = '$lib'" } else { $_ }
}
$body = Get-Content -LiteralPath (Join-Path $tests $Driver) -Raw

# 🔴 THE SAME CLASH GUARD THE SUITE USES, and not a courtesy: the driver is
# APPENDED to the script rather than called, so every top-level "$x = ..." in it
# writes the GUI's own scope. A driver variable called $live IS the liveness
# table. Comments are stripped first or the scan reads the prose warning about
# $script: as a name in use - see the note in run-tests.ps1.
$allSrc = [regex]::Replace(($src -join "`n"), '(?m)(?<=^|\s)#[^\r\n]*', '')
$names = @{}
foreach ($m in [regex]::Matches($allSrc, '\$script:([A-Za-z_]\w*)')) { $names[$m.Groups[1].Value.ToLower()] = $true }
$clash = @{}
foreach ($pat in @('(?m)^\s*\$([A-Za-z_]\w*)\s*=', 'foreach \(\$([A-Za-z_]\w*) in')) {
    foreach ($m in [regex]::Matches($body, $pat)) {
        $nm = $m.Groups[1].Value
        if ($names[$nm.ToLower()]) { $clash[$nm] = $true }
    }
}
if ($clash.Count) {
    throw ("$Driver assigns $(@($clash.Keys).Count) name(s) the GUI keeps script state in: " +
           ((@($clash.Keys) | Sort-Object) -join ', ') + '. Rename them in the driver.')
}

$path = Join-Path $state $Out
[System.IO.File]::WriteAllText($path, (($prefix -join "`n") + $body), (New-Object System.Text.UTF8Encoding($false)))
Write-Host ('harness: ' + $path)
& powershell.exe -STA -NoProfile -ExecutionPolicy Bypass -File $path -NoScan 2>&1 | ForEach-Object { Write-Host $_ }
