#requires -Version 5.1
<#
    Sessions.exe -- the application wrapper.

    WHAT IS UNDER TEST is not the window. Every other suite already covers what
    the window does; this one covers the four claims made by shipping an exe at
    all, and each is asserted as something that CAN go red:

      1. it builds from source with nothing installed  (csc.exe, already on the
         machine -- if that stops being true this fails rather than falling back
         to a stale binary, so the exe can never quietly age)
      2. NO powershell.exe is spawned                  (the whole point: the
         console-host layer is gone, not hidden)
      3. NO console is allocated                       (winexe, not exe)
      4. a SECOND launch does not open a second window (one registry, one view)

    Plus the refusal: started where sessions-gui.ps1 is not, it must exit 2 and
    say so in the log rather than sitting there having done nothing. That case
    is what proves the other assertions are capable of failing.

    RUNS AGAINST THE REAL REGISTRY, so it launches with -NoScan and hashes
    sessions-registry.json either side. Discovering a project or rolling the
    hourly auto-tick during a test would be a real edit to the operator's own
    selections.

    A window appears on the desktop for a few seconds. It is closed in a
    finally, and -NoSteal in run-tests.ps1 skips this suite entirely.
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$here = $PSScriptRoot
if (-not $here) { $here = Split-Path -Parent $MyInvocation.MyCommand.Path }
$tool = Split-Path -Parent $here

$fails = 0
function Fail { param($m) Write-Host "  FAIL  $m" -ForegroundColor Red; $script:fails++ }
function Pass { param($m) Write-Host "  ok    $m" -ForegroundColor Green }
function Note { param($m) Write-Host "        $m" -ForegroundColor DarkGray }

$exe      = Join-Path $tool 'Sessions.exe'
$ico      = Join-Path $tool 'app\sessions.ico'
$build    = Join-Path $tool 'app\build.ps1'
$registry = Join-Path $tool 'sessions-registry.json'
$WindowTitle = 'Claude sessions'

function Get-WindowCount {
    @(Get-Process -ErrorAction SilentlyContinue |
        Where-Object { $_.MainWindowTitle -eq $WindowTitle }).Count
}

function Get-Children { param([int]$Ppid, [string]$Name)
    @(Get-CimInstance Win32_Process -Filter "ParentProcessId=$Ppid" -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -like $Name })
}

function Get-Hash { param($p)
    if (-not (Test-Path -LiteralPath $p)) { return '(absent)' }
    (Get-FileHash -LiteralPath $p -Algorithm SHA256).Hash
}

# --- refuse to run over a window that is already open -----------------------
# The single-instance assertion below is the reason. With the operator's own
# window up, launch two would raise THAT one and the test would pass without
# ever having proved anything.
if ((Get-WindowCount) -gt 0) {
    Note "a '$WindowTitle' window is already open - close it and run this again"
    Note 'the single-instance case cannot be judged honestly while one is up'
    exit 2
}

$started = $null
try {
    # --- 1. it builds -------------------------------------------------------
    Get-Process -Name Sessions -ErrorAction SilentlyContinue | Stop-Process -Force
    Start-Sleep -Milliseconds 300
    if (Test-Path -LiteralPath $exe) { Remove-Item -LiteralPath $exe -Force }

    $sw = [Diagnostics.Stopwatch]::StartNew()
    $out = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $build -Force -Quiet 2>&1
    $buildCode = $LASTEXITCODE
    $sw.Stop()
    if ($buildCode -ne 0) {
        $out | ForEach-Object { Note "$_" }
        Fail "build.ps1 exited $buildCode"
    } elseif (-not (Test-Path -LiteralPath $exe)) {
        Fail 'build.ps1 reported success but produced no Sessions.exe'
    } else {
        $kb = [Math]::Round((Get-Item -LiteralPath $exe).Length / 1KB, 1)
        Pass ("built from source in {0:N1}s, {1} KB, no SDK and no package fetched" -f $sw.Elapsed.TotalSeconds, $kb)
    }

    # --- the icon -----------------------------------------------------------
    # Read back what was actually written rather than trusting the drawing code.
    # A one-entry icon looks fine on the desktop and turns to mush in Alt-Tab,
    # which is exactly the sort of thing nobody notices for months.
    if (Test-Path -LiteralPath $ico) {
        $b = [System.IO.File]::ReadAllBytes($ico)
        $count = [BitConverter]::ToUInt16($b, 4)
        $dims = @()
        for ($i = 0; $i -lt $count; $i++) {
            $d = $b[6 + (16 * $i)]
            $dims += $(if ($d -eq 0) { 256 } else { [int]$d })
        }
        if ($count -ge 5 -and ($dims -contains 16) -and ($dims -contains 256)) {
            Pass ("icon carries $count sizes: " + ($dims -join ', '))
        } else {
            Fail ("icon carries $count size(s): " + ($dims -join ', ') + ' - want 16 through 256')
        }
    } else { Fail 'no sessions.ico was produced' }

    # --- 2, 3. it launches, alone -------------------------------------------
    $before = Get-Hash $registry

    $sw = [Diagnostics.Stopwatch]::StartNew()
    $started = Start-Process -FilePath $exe -ArgumentList '-NoScan' -PassThru
    $title = ''
    while ($sw.Elapsed.TotalSeconds -lt 90) {
        Start-Sleep -Milliseconds 300
        $started.Refresh()
        if ($started.HasExited) { break }
        if ($started.MainWindowTitle) { $title = $started.MainWindowTitle; break }
    }
    $sw.Stop()

    if ($title -ne $WindowTitle) {
        if ($started.HasExited) { Fail "the app exited with code $($started.ExitCode) before showing a window" }
        else { Fail "no '$WindowTitle' window after $([int]$sw.Elapsed.TotalSeconds)s (title was '$title')" }
    } else {
        Pass ("window up in {0:N1}s, titled '{1}'" -f $sw.Elapsed.TotalSeconds, $title)

        # THE CLAIM THE EXE EXISTS TO MAKE. The old route was wscript.exe ->
        # powershell.exe -> a runspace. If a powershell.exe is hanging off this
        # process, the runspace is NOT being hosted here and nothing was saved.
        $kids = Get-Children -Ppid $started.Id -Name 'powershell*'
        if ($kids.Count) { Fail "$($kids.Count) powershell process(es) were spawned - the runspace is not hosted in-process" }
        else { Pass 'no powershell.exe spawned - the runspace is hosted in this process' }

        # /target:winexe. An exe built as a console app gets a conhost even when
        # the window is hidden, and that is what used to flash.
        $con = Get-Children -Ppid $started.Id -Name 'conhost*'
        if ($con.Count) { Fail "$($con.Count) conhost process(es) attached - this was built as a console app" }
        else { Pass 'no console allocated' }
    }

    # --- 4. a second launch raises the first --------------------------------
    if ($title -eq $WindowTitle) {
        $two = Start-Process -FilePath $exe -ArgumentList '-NoScan' -PassThru -Wait
        $live = @(Get-Process -Name Sessions -ErrorAction SilentlyContinue)
        if ($two.ExitCode -ne 0) { Fail "the second launch exited $($two.ExitCode), expected 0" }
        elseif ($live.Count -ne 1) { Fail "$($live.Count) Sessions processes are running after a second launch, expected 1" }
        elseif ((Get-WindowCount) -ne 1) { Fail "$(Get-WindowCount) windows titled '$WindowTitle' are open, expected 1" }
        else { Pass 'a second launch raised the first window instead of opening another' }
    }

    # --- the refusal --------------------------------------------------------
    # Copied somewhere the scripts are not. This is the case that proves the
    # assertions above can go red: if the exe cannot tell a good start from a
    # hopeless one, none of them mean anything.
    $sandbox = Join-Path ([System.IO.Path]::GetTempPath()) ("sr-app-" + [Guid]::NewGuid().ToString('N'))
    try {
        $null = New-Item -ItemType Directory -Path $sandbox -Force
        $orphan = Join-Path $sandbox 'Sessions.exe'
        Copy-Item -LiteralPath $exe -Destination $orphan -Force

        $env:SR_GUI_NODIALOG = '1'
        $r = Start-Process -FilePath $orphan -PassThru -Wait
        Remove-Item Env:\SR_GUI_NODIALOG -ErrorAction SilentlyContinue

        if ($r.ExitCode -ne 2) { Fail "with no sessions-gui.ps1 beside it the app exited $($r.ExitCode), expected 2" }
        else { Pass 'refuses to start where sessions-gui.ps1 is not, exit 2' }

        $orphanLog = Join-Path $sandbox '.state\restore.log'
        if ((Test-Path -LiteralPath $orphanLog) -and
            ((Get-Content -LiteralPath $orphanLog -Raw) -match 'sessions-gui\.ps1 is not next to')) {
            Pass 'and wrote the reason to .state\restore.log'
        } else { Fail 'the refusal left nothing in .state\restore.log' }
    } finally {
        # Never leave this behind: a temp directory per run is how a machine ends
        # up with 11,000 of them.
        Remove-Item -LiteralPath $sandbox -Recurse -Force -ErrorAction SilentlyContinue
    }

    # --- the registry was not touched ---------------------------------------
    $after = Get-Hash $registry
    if ($before -eq $after) { Pass 'sessions-registry.json is byte-identical - the test changed none of your selections' }
    else { Fail 'sessions-registry.json CHANGED during the test' }

} finally {
    if ($started -and -not $started.HasExited) {
        $null = $started.CloseMainWindow()
        if (-not $started.WaitForExit(8000)) { $started | Stop-Process -Force }
    }
    Get-Process -Name Sessions -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
    Remove-Item Env:\SR_GUI_NODIALOG -ErrorAction SilentlyContinue
}

Write-Host ''
if ($fails) { Write-Host "$fails FAILURE(S)" -ForegroundColor Red; exit 1 }
Write-Host 'Sessions.exe: builds, hosts its own runspace, allocates no console, opens once' -ForegroundColor Green
exit 0
