#requires -Version 5.1
<#
    Splices tests\align-driver.ps1 onto the LIVE window script, exactly the way
    run-tests.ps1 does for `shot`, and runs it in a child STA powershell.

    Kept out of run-tests.ps1 on purpose: this is an investigation harness, not
    a suite, and run-tests.ps1 is not mine to edit.

    It writes nothing but its own harness file under .state\ and its report to
    stdout. It never touches session-restore.config.json or the registry.
#>
[CmdletBinding()]
param(
    [string]$Driver = 'align-driver.ps1',
    [string]$OutFile = 'align-test.ps1',
    [string]$Gui = 'sessions-window.ps1',

    # 🔑 DRIVE A CANDIDATE THAT IS NOT IN lib\ YET. run-tests.ps1's -GuiFile
    # takes a name WITHIN lib\, so a proposed rewrite has to be installed
    # before it can be tested - which is the wrong way round when the whole
    # point is to know whether it works before installing it. An absolute path
    # here lets a preview be measured where it lies.
    [string]$GuiPath = ''
)
$ErrorActionPreference = 'Stop'

$here  = $PSScriptRoot
if (-not $here) { $here = Split-Path -Parent $MyInvocation.MyCommand.Path }
$tool  = Split-Path -Parent $here
$lib   = Join-Path $tool 'lib'
$state = Join-Path $tool '.state'
if (-not (Test-Path $state)) { $null = New-Item -ItemType Directory -Path $state -Force }

$guiFull = $(if ($GuiPath) { $GuiPath } else { Join-Path $lib $Gui })
if (-not (Test-Path -LiteralPath $guiFull)) { throw ('no window script at {0}' -f $guiFull) }
Write-Host ("  window under test: {0}" -f $guiFull)
$src = @(Get-Content -LiteralPath $guiFull)
$cut = -1
for ($k = 0; $k -lt $src.Count; $k++) {
    if ($src[$k].Trim() -eq '$null = $window.ShowDialog()') { $cut = $k; break }
}
if ($cut -lt 0) { throw ('marker gone: {0} no longer ends with "$null = $window.ShowDialog()"' -f $Gui) }

$prefix = @($src[0..($cut - 1)]) | ForEach-Object {
    if ($_ -eq '$here = $PSScriptRoot') { "`$here = '$lib'" } else { $_ }
}
$body = Get-Content -LiteralPath (Join-Path $here $Driver) -Raw
$path = Join-Path $state $OutFile
[System.IO.File]::WriteAllText($path, (($prefix -join "`n") + "`n" + $body),
    (New-Object System.Text.UTF8Encoding($false)))

& powershell.exe -STA -NoProfile -ExecutionPolicy Bypass -File $path -NoScan
exit $LASTEXITCODE
