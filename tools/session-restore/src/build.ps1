# ===========================================================================
#  Build, test and publish the C# rebuild.
#
#      powershell -NoProfile -ExecutionPolicy Bypass -File src\build.ps1
#      ... -Publish            also produce dist\Sessions2.exe
#      ... -Publish -Framework framework-dependent (0,2 MB, needs the runtime)
#      ... -SkipTests          build only
#
#  WHY A SCRIPT AND NOT "dotnet build". Three things have to be true together
#  and each fails differently: the SDK has to be present, the tests have to
#  pass, and the publish has to be the SELF-CONTAINED one. A bare dotnet
#  command gets one of the three and is silent about the other two.
#
#  🔴 IT DOES NOT TOUCH Sessions.exe. That is the launcher the operator uses
#  every day and it stays the PowerShell tool until the cutover at plan item
#  6.1. This publishes Sessions2.exe into dist\, which nothing points at yet.
# ===========================================================================
[CmdletBinding()]
param(
    [switch]$Publish,
    [switch]$Framework,
    [switch]$SkipTests
)

$ErrorActionPreference = 'Stop'
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$sln  = Join-Path $here 'SessionRestore.sln'
$dist = Join-Path (Split-Path -Parent $here) 'dist'

function Say  { param($m) Write-Host $m }
function Good { param($m) Write-Host "  ok    $m" -ForegroundColor Green }
function Bad  { param($m) Write-Host "  FAIL  $m" -ForegroundColor Red }

# ---- 1. the SDK ------------------------------------------------------------
# 🔴 THE ONE THING THAT IS DIFFERENT ABOUT THIS BUILD. The PowerShell tool needs
# nothing installed - csc.exe ships with Windows and app\build.ps1 uses it. The
# rebuild needs the .NET SDK, and on a machine that has not got one the failure
# is a command that is simply not found. Saying so, once, in a sentence, is the
# whole reason this check is here rather than left to dotnet's own error.
$dotnet = (Get-Command dotnet -ErrorAction SilentlyContinue)
if (-not $dotnet) {
    Bad 'The .NET SDK is not installed, or dotnet is not on PATH.'
    Say ''
    Say '  The C# rebuild needs the .NET 8 SDK. Get it from'
    Say '      https://dotnet.microsoft.com/download/dotnet/8.0'
    Say '  The PowerShell tool (Sessions.exe) needs none of this and is unaffected.'
    exit 3
}

$sdks = @(& dotnet --list-sdks 2>$null)
$have8 = @($sdks | Where-Object { $_ -match '^8\.' })
if (-not $have8.Count) {
    Bad ('No .NET 8 SDK found. Installed: ' + (($sdks | ForEach-Object { ($_ -split ' ')[0] }) -join ', '))
    Say '  Get 8.0 from https://dotnet.microsoft.com/download/dotnet/8.0'
    exit 3
}
Good ('SDK ' + ((& dotnet --version) 2>$null))

# ---- 2. build --------------------------------------------------------------
# Warnings are errors here (see Directory.Build.props), so a clean build is a
# real statement rather than a scroll-past.
Say ''
& dotnet build $sln -c Release --nologo -v quiet
if ($LASTEXITCODE -ne 0) { Bad 'build failed'; exit 1 }
Good 'build clean, warnings are errors'

# ---- 3. test ---------------------------------------------------------------
if (-not $SkipTests) {
    & dotnet test $sln -c Release --nologo -v quiet --no-build
    if ($LASTEXITCODE -ne 0) { Bad 'tests failed'; exit 1 }
    Good 'tests pass'
} else {
    Write-Host '        tests skipped' -ForegroundColor DarkGray
}

# ---- 4. publish ------------------------------------------------------------
if ($Publish) {
    # 🔑 SELF-CONTAINED BY DEFAULT, AND THE SIZE IS THE PRICE OF THAT. Measured
    # 2026-09-09 on this machine:
    #
    #     self-contained, single file        154,5 MB
    #     self-contained + compression        68,4 MB   <- what this ships
    #     framework-dependent                  0,2 MB   <- -Framework
    #
    # The operator moves between machines. A tool that will not start because a
    # runtime is absent is exactly the silent failure app\SessionsHost.cs was
    # written to remove, and 68 MB of local disk is a smaller price than that.
    # dist\ is gitignored, so the size costs disk and copy time, not history.
    $args = @(
        'publish', (Join-Path $here 'SessionRestore.App\SessionRestore.App.csproj'),
        '-c', 'Release', '-r', 'win-x64',
        '-p:PublishSingleFile=true',
        '-o', $dist, '--nologo'
    )
    if ($Framework) {
        $args += '--self-contained'; $args += 'false'
    } else {
        $args += '--self-contained'; $args += 'true'
        $args += '-p:IncludeNativeLibrariesForSelfExtract=true'
        $args += '-p:EnableCompressionInSingleFile=true'
    }
    & dotnet @args | Out-Null
    if ($LASTEXITCODE -ne 0) { Bad 'publish failed'; exit 1 }

    $exe = Join-Path $dist 'Sessions2.exe'
    if (-not (Test-Path -LiteralPath $exe)) { Bad "published, but $exe is not there"; exit 1 }
    Good ('dist\Sessions2.exe  {0:N1} MB' -f ((Get-Item $exe).Length / 1MB))
    Write-Host '        Sessions.exe is untouched - the cutover is plan item 6.1' -ForegroundColor DarkGray
}

Say ''
exit 0
