# Splice agentclick-driver.ps1 onto the shipped window, exactly the way
# run-tests.ps1's New-GuiHarness does, and run it. Read-only on lib\.
# -Candidate splices from .state\sessions-window-candidate.ps1 instead of the
# shipped file, so a proposed fix can be driven WITHOUT writing into lib\.
param([ValidateSet('', 'A', 'B')][string]$Candidate = '', [string]$Driver = 'agentclick-driver.ps1')
$ErrorActionPreference = 'Stop'
$acHere  = $PSScriptRoot
$acTool  = Split-Path -Parent $acHere
$acLib   = Join-Path $acTool 'lib'
$acState = Join-Path $acTool '.state'
if (-not (Test-Path $acState)) { $null = New-Item -ItemType Directory -Path $acState -Force }

$acGui = Join-Path $acLib 'sessions-window.ps1'
if ($Candidate -eq 'A') { $acGui = Join-Path $acState 'sessions-window-candidate.ps1' }
if ($Candidate -eq 'B') { $acGui = Join-Path $acState 'sessions-window-candidate-b.ps1' }
Write-Host ("splicing from: {0}" -f $acGui) -ForegroundColor DarkGray
$acSrc = @(Get-Content -LiteralPath $acGui)
$acCut = -1
for ($k = 0; $k -lt $acSrc.Count; $k++) {
    if ($acSrc[$k].Trim() -eq '$null = $window.ShowDialog()') { $acCut = $k; break }
}
if ($acCut -lt 0) { throw 'marker gone: sessions-window.ps1 no longer ends with $null = $window.ShowDialog()' }

$acPrefix = @($acSrc[0..($acCut - 1)]) | ForEach-Object {
    if ($_ -eq '$here = $PSScriptRoot') { "`$here = '$acLib'" } else { $_ }
}
$acBody = Get-Content -LiteralPath (Join-Path $acHere $Driver) -Raw

# The same scope-clash guard the real runner applies.
$acAll = ($acSrc -join "`n")
$acNames = @{}
foreach ($m in [regex]::Matches($acAll, '\$script:([A-Za-z_]\w*)')) { $acNames[$m.Groups[1].Value.ToLower()] = $true }
$acClash = @{}
foreach ($pat in @('(?m)^\s*\$([A-Za-z_]\w*)\s*=', 'foreach \(\$([A-Za-z_]\w*) in')) {
    foreach ($m in [regex]::Matches($acBody, $pat)) {
        $nm = $m.Groups[1].Value
        if ($acNames[$nm.ToLower()]) { $acClash[$nm] = $true }
    }
}
if ($acClash.Count) { throw ('driver shadows GUI script state: ' + (@($acClash.Keys | Sort-Object) -join ', ')) }

$acPath = Join-Path $acState 'agentclick-test.ps1'
[System.IO.File]::WriteAllText($acPath, (($acPrefix -join "`n") + $acBody), (New-Object System.Text.UTF8Encoding($false)))
Write-Host ("harness: {0}" -f $acPath) -ForegroundColor DarkGray
& powershell.exe -STA -NoProfile -ExecutionPolicy Bypass -File $acPath -NoScan 2>&1 | ForEach-Object { Write-Host $_ }
