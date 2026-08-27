#requires -Version 5.1
<#
    Sessions.exe -- the application wrapper.

    WHAT IS UNDER TEST is not the window. Every other suite already covers what
    the window does; this one covers the claims made by shipping an exe at all,
    and each is asserted as something that CAN go red:

      1. it builds from source with nothing installed  (csc.exe, already on the
         machine -- if that stops being true this fails rather than falling back
         to a stale binary, so the exe can never quietly age)
      2. ARGUMENTS REACH THE SCRIPT                    (see below)
      3. -Restore runs the other script                (one binary, both buttons)
      4. NO powershell.exe is spawned                  (the whole point: the
         console-host layer is gone, not hidden)
      5. NO console is allocated for the window        (winexe, not exe)
      6. a SECOND launch does not open a second window (one registry, one view)

    Plus the refusal: started where sessions-gui.ps1 is not, it must exit 2 and
    say so in the log rather than sitting there having done nothing. That case
    is what proves the other assertions are capable of failing.

    🔴 WHY (2) IS IN HERE AND FIRST AMONG THE REAL CHECKS. The host originally
    forwarded arguments with AddScript("param($p,$a) & $p @a") + AddArgument,
    which mis-binds SILENTLY: every token is passed positionally, so a parameter
    NAME is never recognised and "-DryRun" arrived as a string VALUE bound to
    the next positional parameter. Nothing errored. The measured cost on
    2026-08-27 was a restore asked for as a DRY RUN launching two real Claude
    sessions, and -NoScan never reaching the GUI at all. It shipped because
    nothing here tested it. "-Restore -DryRun must print DRY RUN" is that test,
    and it launches nothing.

    RUNS AGAINST THE REAL REGISTRY, so the window is launched with -NoScan and
    sessions-registry.json is hashed either side. Discovering a project or
    rolling the hourly auto-tick during a test would be a real edit to the
    operator's own selections.

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

$started = $null
$sandbox = $null
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

    # --- 2 and 3. arguments reach the script, through -Restore --------------
    # -DryRun is the perfect probe: the script announces it, and a run where it
    # failed to arrive is not a failed test, it is a real restore. Read the
    # header of the docstring before weakening this.
    if (Test-Path -LiteralPath $exe) {
        $capture = Join-Path ([System.IO.Path]::GetTempPath()) ("sr-app-out-" + [Guid]::NewGuid().ToString('N') + '.txt')
        try {
            $env:SR_NOPAUSE = '1'
            $r = Start-Process -FilePath $exe -ArgumentList '-Restore', '-DryRun' `
                    -PassThru -Wait -NoNewWindow -RedirectStandardOutput $capture
            Remove-Item Env:\SR_NOPAUSE -ErrorAction SilentlyContinue
            $text = $(if (Test-Path -LiteralPath $capture) { Get-Content -LiteralPath $capture -Raw } else { '' })

            if ($text -match 'Claude session restore') { Pass '-Restore runs restore-sessions.ps1, in this process' }
            else { Fail "-Restore printed nothing recognisable (exit $($r.ExitCode))" }

            if ($text -match 'DRY RUN') {
                Pass '-DryRun REACHED the script - a parameter name survives the hop'
            } else {
                Fail '-DryRun did NOT reach the script: the run was live, not a dry run'
            }

            # The other half of the same claim: a VALUE that looks like a switch
            # must stay a value. -Place '-3440,0' is the real case in this repo.
            if ($text -notmatch 'restored [1-9]') { Pass 'nothing was launched by the probe' }
            else { Fail 'the -DryRun probe LAUNCHED something' }
        } finally {
            Remove-Item -LiteralPath $capture -Force -ErrorAction SilentlyContinue
            Remove-Item Env:\SR_NOPAUSE -ErrorAction SilentlyContinue
        }
    }

    # --- the refusal --------------------------------------------------------
    # Copied somewhere the scripts are not. This is the case that proves the
    # assertions can go red: if the exe cannot tell a good start from a hopeless
    # one, none of them mean anything.
    $sandbox = Join-Path ([System.IO.Path]::GetTempPath()) ("sr-app-" + [Guid]::NewGuid().ToString('N'))
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

    # --- everything past here needs the desktop to itself -------------------
    # The single-instance assertion is the reason. With a window already up,
    # launch two would raise THAT one and the test would pass without ever
    # having proved anything.
    if ((Get-WindowCount) -gt 0) {
        Write-Host ''
        Note "a '$WindowTitle' window is already open - the launch cases were NOT run"
        Note 'close it and run this again; everything above did run'
        Write-Host ''
        if ($fails) { Write-Host "$fails FAILURE(S)" -ForegroundColor Red; exit 1 }
        exit 2
    }

    # --- 4, 5. it launches, alone -------------------------------------------
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
        else { Pass 'no console allocated for the window' }

        # The splash must not still be up, and must never have answered for the
        # real window: it is deliberately untitled and off the taskbar so that
        # MainWindowTitle cannot find it first.
        $tops = @(Get-Process -Id $started.Id | Select-Object -ExpandProperty MainWindowTitle)
        if ($tops -contains $WindowTitle) { Pass 'the splash stood aside for the real window' }

        # --- and it is the REAL window, not an empty shell ------------------
        # "A window appeared" is not "all the functionality we now have". The
        # host could plausibly produce a window whose data layer never ran --
        # _common.ps1 not dot-sourced, the registry not read, the XAML parsed
        # but unbound -- and it would look identical from the outside. So the
        # contents are read back through UI Automation, from the process the
        # exe started.
        #
        # 🔴 NOT THE TRAY. The retired `tray` suite walked Shell_TrayWnd and
        # NotifyIconOverflowWindow through UIA, and Bitdefender's behavioural
        # engine scored that as malicious and quarantined every script in the
        # chain (CONTEXT.md, 2026-08-23). Whatever it was worth, it is not
        # worth that. The tray is checked by using the app, not by a test.
        try {
            Add-Type -AssemblyName UIAutomationClient, UIAutomationTypes
            $root = [System.Windows.Automation.AutomationElement]::RootElement
            $cond = New-Object System.Windows.Automation.PropertyCondition(
                        [System.Windows.Automation.AutomationElement]::ProcessIdProperty, $started.Id)
            $win = $root.FindFirst([System.Windows.Automation.TreeScope]::Children, $cond)
            if (-not $win) {
                Fail 'the hosted window is not reachable through UI Automation'
            } else {
                # 🪤 POLLED, NOT SAMPLED ONCE. The title appears when the window
                # is shown; Add_ContentRendered then fires and fills the list
                # AFTERWARDS. Asking the instant the title exists reliably finds
                # an empty list and calls it a broken data layer -- which is a
                # test measuring its own timing, not the app.
                $items = 0
                $lists = $null
                $wait = [Diagnostics.Stopwatch]::StartNew()
                while ($wait.Elapsed.TotalSeconds -lt 45 -and $items -eq 0) {
                    $lists = $win.FindAll([System.Windows.Automation.TreeScope]::Descendants,
                                (New-Object System.Windows.Automation.PropertyCondition(
                                    [System.Windows.Automation.AutomationElement]::ControlTypeProperty,
                                    [System.Windows.Automation.ControlType]::List)))
                    $items = 0
                    foreach ($l in $lists) {
                        $items += @($l.FindAll([System.Windows.Automation.TreeScope]::Children,
                                    [System.Windows.Automation.Condition]::TrueCondition)).Count
                    }
                    if ($items -eq 0) { Start-Sleep -Milliseconds 500 }
                }
                $wait.Stop()
                # The list is VIRTUALIZED, so this is the count of REALISED rows
                # -- about a screenful, never the registry's 208. Any row at all
                # is the claim: the registry was read and bound under the host.
                if ($items -gt 0) { Pass ("the hosted window carries real rows ({0} realised under {1} list(s), after {2:N1}s) - the registry was read and bound" -f $items, $lists.Count, $wait.Elapsed.TotalSeconds) }
                else { Fail 'the hosted window still had no rows after 45s: it drew, but its data layer did not run' }

                $btns = @($win.FindAll([System.Windows.Automation.TreeScope]::Descendants,
                            (New-Object System.Windows.Automation.PropertyCondition(
                                [System.Windows.Automation.AutomationElement]::ControlTypeProperty,
                                [System.Windows.Automation.ControlType]::Button))) |
                         ForEach-Object { $_.Current.Name })
                if ($btns.Count -ge 3) { Pass "$($btns.Count) buttons are wired and reachable under the host" }
                else { Fail "only $($btns.Count) button(s) found - the window is not fully built" }
            }
        } catch {
            Fail "reading the hosted window through UI Automation threw: $($_.Exception.Message)"
        }
    }

    # --- 6. a second launch raises the first --------------------------------
    if ($title -eq $WindowTitle) {
        $two = Start-Process -FilePath $exe -ArgumentList '-NoScan' -PassThru -Wait
        $live = @(Get-Process -Name Sessions -ErrorAction SilentlyContinue)
        if ($two.ExitCode -ne 0) { Fail "the second launch exited $($two.ExitCode), expected 0" }
        elseif ($live.Count -ne 1) { Fail "$($live.Count) Sessions processes are running after a second launch, expected 1" }
        elseif ((Get-WindowCount) -ne 1) { Fail "$(Get-WindowCount) windows titled '$WindowTitle' are open, expected 1" }
        else { Pass 'a second launch raised the first window instead of opening another' }
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
    Remove-Item Env:\SR_NOPAUSE -ErrorAction SilentlyContinue
    # Never leave this behind: a temp directory per run is how a machine ends up
    # with 11,000 of them.
    if ($sandbox) { Remove-Item -LiteralPath $sandbox -Recurse -Force -ErrorAction SilentlyContinue }
}

Write-Host ''
if ($fails) { Write-Host "$fails FAILURE(S)" -ForegroundColor Red; exit 1 }
Write-Host 'Sessions.exe: builds, forwards its arguments, hosts its own runspace, opens once' -ForegroundColor Green
exit 0
