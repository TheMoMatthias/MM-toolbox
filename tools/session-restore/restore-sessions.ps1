#requires -Version 5.1
<#
.SYNOPSIS
    Bring back the Claude Code conversations you were last working on, each with
    Remote Control attached under its real name. Discovers projects dynamically -
    nothing is hardcoded to a particular repo.

.DESCRIPTION
    THE PROBLEM THIS SOLVES (measured 2026-08-17)

    Launching a bare `claude` while remoteControlAtStartup is true registers a
    Remote Control session for an EMPTY conversation. The remote title then falls
    to the last rule in the documented precedence - an auto-generated
    "<hostname>-graceful-unicorn" - and a later /resume does NOT send the
    switched-to conversation's title or history to the connected device. The phone
    ends up bound to a placeholder that the terminal has already walked away from.
    The abandoned placeholder is left on disk as a 118-byte transcript holding one
    bridge-session line with an EMPTY bridgeSessionId.

    THE FIX: resume the conversation FIRST, and name it explicitly.

        claude --resume <id> -n "<name>" --remote-control "<name>"

    -n and --remote-control are NOT the same lever and both are needed:
      -n <name>                writes a custom-title record into the transcript
                               (title-precedence rule 2), so the CONVERSATION keeps
                               the name for every future resume.
      --remote-control <name>  names THIS remote session (title-precedence rule 1).
                               Measured: it writes no custom-title, so on its own the
                               conversation stays nameless forever.

    NEW SESSIONS: no hook can set a session title - all 31 hook events are
    informational or permission-gating. The only fix is to never launch a bare
    `claude`. Use `-New` (or the `cc` shell function install.ps1 offers) which
    always passes -n.

.PARAMETER Install
    Register the logon scheduled task and create the desktop shortcut.

.PARAMETER Uninstall
    Remove both. Leaves the repo untouched.

.PARAMETER New
    Start a correctly-named NEW session in the current directory instead of
    restoring anything.

.PARAMETER Name
    Explicit name for -New. Defaults to "<folder>-<MMdd-HHmm>".

.PARAMETER DryRun
    Resolve and print what would launch, without launching.

.PARAMETER All
    Ignore the recency window and the session cap. Everything discoverable.

.EXAMPLE
    .\restore-sessions.ps1 -DryRun        # what would come back?
    .\restore-sessions.ps1                # bring it back
    .\restore-sessions.ps1 -New           # a correctly-named NEW session, here
    .\restore-sessions.ps1 -Install       # run at every logon + desktop button
#>
[CmdletBinding()]
param(
    [switch]$Install,
    [switch]$Uninstall,
    [switch]$New,
    [string]$Name,
    [switch]$DryRun,
    [switch]$All,
    [string]$ConfigPath,

    # Anything not recognised above is forwarded verbatim to `claude` by -New, so
    # `cc --model opus` works. Without this the flag bound to -Name and the session
    # was silently called "model" on the default model -- no error, wrong result.
    [Parameter(ValueFromRemainingArguments = $true)]
    [string[]]$ClaudeArgs
)

$ErrorActionPreference = 'Stop'

# $PSScriptRoot is EMPTY while a param() default is being evaluated under
# `powershell.exe -File <script>` - which is exactly how the scheduled task runs
# this. Measured 2026-08-17: by hand it worked; through Task Scheduler it died on
# "config not found", with -WindowStyle Hidden and nothing but LastTaskResult=1 to
# show for it. Resolve the directory in the BODY, never in a parameter default, and
# never trust a hand-run to have exercised this path.
$ScriptDir = $PSScriptRoot
if (-not $ScriptDir -and $MyInvocation.MyCommand.Path) {
    $ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
}
if (-not $ScriptDir) { $ScriptDir = (Get-Location).Path }

$TaskName      = 'ClaudeSessionRestore'
$ShortcutName  = 'Restore Claude Sessions.lnk'
$ProjectsRoot  = Join-Path $env:USERPROFILE '.claude\projects'
$StateDir      = Join-Path $ScriptDir '.state'
$LogPath       = Join-Path $StateDir 'restore.log'
$LocalOverride = Join-Path $env:USERPROFILE '.claude\session-restore.local.json'

if ([string]::IsNullOrWhiteSpace($ConfigPath)) {
    $ConfigPath = Join-Path $ScriptDir 'session-restore.config.json'
}

# A transcript smaller than this is a placeholder, not a conversation: a lone
# bridge-session line is 118 bytes. Any real exchange is far larger.
$MinRealTranscriptBytes = 5000

# A transcript written this recently is being held by a live session.
$LiveWindowMinutes = 3

# The six variables that mark a process as a CHILD session. A claude started with
# these set writes NO transcript of its own, so the conversation cannot be resumed
# later and dies with its window. Measured 2026-07-28: env inherited = no .jsonl
# after 12 minutes; env scrubbed = a real turn on disk in 5 seconds.
$ChildSessionVars = @(
    'CLAUDE_CODE_CHILD_SESSION',
    'CLAUDE_CODE_SESSION_ID',
    'CLAUDECODE',
    'CLAUDE_CODE_ENTRYPOINT',
    'CLAUDE_PID',
    'CLAUDE_CODE_SSE_PORT'
)

# ---------------------------------------------------------------------------
# Output. At logon this runs with -WindowStyle Hidden, so Write-Host reaches
# nobody. Every line also goes to a log, otherwise a failed morning restore is
# indistinguishable from a successful one - which is how this tool failed its own
# first logon test.
# ---------------------------------------------------------------------------
function Write-Log {
    param([string]$m)
    try {
        if (-not (Test-Path -LiteralPath $StateDir)) {
            New-Item -ItemType Directory -Path $StateDir -Force | Out-Null
        }
        Add-Content -LiteralPath $LogPath -Encoding utf8 `
            -Value ("{0}  {1}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $m)
    } catch { }
}

function Write-Step { param([string]$m) Write-Host "  $m";                                    Write-Log "         $m" }
function Write-Ok   { param([string]$m) Write-Host "  [ok]   $m" -ForegroundColor Green;      Write-Log "  [ok]   $m" }
function Write-Skip { param([string]$m) Write-Host "  [skip] $m" -ForegroundColor DarkYellow; Write-Log "  [skip] $m" }
function Write-Fail { param([string]$m) Write-Host "  [FAIL] $m" -ForegroundColor Red;        Write-Log "  [FAIL] $m" }

function Clear-ChildSessionEnv {
    foreach ($v in $ChildSessionVars) {
        if (Test-Path "Env:$v") { Remove-Item "Env:$v" -ErrorAction SilentlyContinue }
    }
}

# ---------------------------------------------------------------------------
# Config: repo defaults, optionally overridden per machine so a clone stays clean.
# ---------------------------------------------------------------------------
function Get-Config {
    if (-not (Test-Path -LiteralPath $ConfigPath)) {
        throw "config not found: $ConfigPath"
    }
    $cfg = Get-Content -LiteralPath $ConfigPath -Raw | ConvertFrom-Json

    if (Test-Path -LiteralPath $LocalOverride) {
        $local = Get-Content -LiteralPath $LocalOverride -Raw | ConvertFrom-Json
        foreach ($p in $local.PSObject.Properties) {
            $cfg | Add-Member -NotePropertyName $p.Name -NotePropertyValue $p.Value -Force
        }
        Write-Step "machine-local overrides applied from $LocalOverride"
    }
    return $cfg
}

# ---------------------------------------------------------------------------
# Discovery
# ---------------------------------------------------------------------------

# The transcript FOLDER name is a lossy encoding of the working directory: every
# character that is not a letter or digit becomes '-', so a space and a backslash
# are indistinguishable and the path cannot be reversed. The transcript itself
# records the real path in a "cwd" field, so read that instead.
#
# Read the LAST one, not the first. A session that moved directories keeps its
# original cwd at the top: e1b72e40 opens with C:\Users\mauri and ends in
# C:\Users\mauri\Documents\Millwright, and it exists under BOTH project folders.
# Taking the last value resolves both copies to the same real directory, which the
# one-per-directory rule then collapses for free.
function Get-SessionCwd {
    param([Parameter(Mandatory)][string]$JsonlPath)

    try {
        $tail = Get-Content -LiteralPath $JsonlPath -Tail 400 -ErrorAction Stop
        $line = $tail | Where-Object { $_ -like '*"cwd":*' } | Select-Object -Last 1
        if (-not $line) {
            $head = Get-Content -LiteralPath $JsonlPath -TotalCount 60 -ErrorAction Stop
            $line = $head | Where-Object { $_ -like '*"cwd":*' } | Select-Object -Last 1
        }
        if (-not $line) { return $null }
        $parsed = $line | ConvertFrom-Json
        if ($parsed.cwd) { return [string]$parsed.cwd }
    } catch { }
    return $null
}

# The title the operator gave the conversation with /rename or -n. Written
# repeatedly through the transcript, so the tail is enough and avoids reading a
# 100 MB file end to end.
function Get-SessionTitle {
    param([Parameter(Mandatory)][string]$JsonlPath)
    try {
        $tail = Get-Content -LiteralPath $JsonlPath -Tail 400 -ErrorAction Stop
    } catch { return $null }

    $line = $tail | Where-Object { $_ -like '*"type":"custom-title"*' } | Select-Object -Last 1
    if (-not $line) { return $null }
    try {
        $parsed = $line | ConvertFrom-Json
        if ($parsed.customTitle) { return [string]$parsed.customTitle }
    } catch { }
    return $null
}

function Test-Excluded {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)]$Config
    )

    # The home directory is never a project. Claude Code creates a transcript folder
    # for it the moment anyone runs `claude` from ~, and restoring a session there
    # would open a tab in a directory with no repo.
    if ($Path.TrimEnd('\') -ieq $env:USERPROFILE.TrimEnd('\')) { return $true }

    foreach ($pat in @($Config.excludePatterns)) {
        if ([string]::IsNullOrWhiteSpace($pat)) { continue }
        $expanded = [Environment]::ExpandEnvironmentVariables($pat)
        if ($Path -like $expanded) { return $true }
    }
    return $false
}

function Get-DiscoveredSessions {
    param([Parameter(Mandatory)]$Config)

    if (-not (Test-Path -LiteralPath $ProjectsRoot)) {
        throw "no Claude projects folder at $ProjectsRoot - has claude ever run on this machine?"
    }

    $cutoff = (Get-Date).AddDays(-1 * [double]$Config.recencyDays)
    $found  = @()
    $scanned = 0

    foreach ($pdir in (Get-ChildItem -LiteralPath $ProjectsRoot -Directory -ErrorAction SilentlyContinue)) {

        $newest = Get-ChildItem -LiteralPath $pdir.FullName -Filter *.jsonl -File -ErrorAction SilentlyContinue |
                  Where-Object { $_.Length -ge $MinRealTranscriptBytes } |
                  Sort-Object LastWriteTime -Descending |
                  Select-Object -First 1
        if (-not $newest) { continue }
        $scanned++

        if (-not $All -and $newest.LastWriteTime -lt $cutoff) { continue }

        $cwd = Get-SessionCwd -JsonlPath $newest.FullName
        if (-not $cwd) { continue }
        if (-not (Test-Path -LiteralPath $cwd -PathType Container)) { continue }
        if (Test-Excluded -Path $cwd -Config $Config) { continue }

        $found += [PSCustomObject]@{
            Dir       = $cwd.TrimEnd('\')
            SessionId = $newest.BaseName
            Jsonl     = $newest.FullName
            Touched   = $newest.LastWriteTime
        }
    }

    # One session per working tree. Two sessions sharing a directory share one git
    # index, and a bare `git commit` in either takes whatever the other staged.
    # Grouping by directory also folds away a session that appears under two
    # project folders because it changed cwd mid-life.
    $unique = $found |
              Group-Object -Property { $_.Dir.ToLowerInvariant() } |
              ForEach-Object { $_.Group | Sort-Object Touched -Descending | Select-Object -First 1 } |
              Sort-Object Touched -Descending

    $cap = [int]$Config.maxSessions
    if (-not $All -and $cap -gt 0 -and @($unique).Count -gt $cap) {
        $dropped = @($unique).Count - $cap
        $unique = $unique | Select-Object -First $cap
        # Never truncate silently: a capped list reads exactly like a complete one.
        Write-Step "capped at $cap most recent - $dropped older project(s) not restored (use -All for everything)"
    }

    return ,@($unique)
}

# ---------------------------------------------------------------------------
# Guards
# ---------------------------------------------------------------------------

# The mtime guard below only catches a session that is actively WRITING. A session
# sitting idle at its prompt writes nothing and would sail straight past it.
# Sessions launched by this tool carry `--resume <id>` in their command line, so
# they are identifiable. Verified: pid 22436 showed
#   claude.exe --resume e1b72e40-... -n Millwright --remote-control Millwright
# Bare-`claude` sessions that later /resume'd into a conversation carry no id,
# which is why the mtime guard stays as well. The two are complementary.
function Test-SessionProcessRunning {
    param([Parameter(Mandatory)][string]$SessionId)
    $procs = Get-CimInstance Win32_Process -Filter "Name='claude.exe'" -ErrorAction SilentlyContinue |
             Where-Object { $_.CommandLine -and $_.CommandLine -like "*$SessionId*" }
    return (@($procs).Count -gt 0)
}

function Test-SessionIsLive {
    param([Parameter(Mandatory)][string]$JsonlPath)
    if (-not (Test-Path -LiteralPath $JsonlPath)) { return $false }
    $age = (Get-Date) - (Get-Item -LiteralPath $JsonlPath).LastWriteTime
    return ($age.TotalMinutes -lt $LiveWindowMinutes)
}

# ---------------------------------------------------------------------------
# Launching
# ---------------------------------------------------------------------------

# Get-Command does NOT find wt.exe. It ships as a WindowsApps execution alias - a
# reparse point frequently absent from a child shell's PATH, and absent from the
# even thinner PATH a Task Scheduler logon action inherits. Measured 2026-08-17:
# `Get-Command wt.exe` returned nothing while the alias file existed. Resolving by
# PATH alone would have failed every morning, inside a hidden window, unseen.
function Resolve-WindowsTerminal {
    $gc = Get-Command wt.exe -ErrorAction SilentlyContinue
    if ($gc -and $gc.Source) { return $gc.Source }

    foreach ($c in @(
        (Join-Path $env:LOCALAPPDATA 'Microsoft\WindowsApps\wt.exe'),
        (Join-Path $env:ProgramFiles 'WindowsApps\wt.exe')
    )) {
        if (Test-Path -LiteralPath $c) { return $c }
    }

    $pkg = Get-ChildItem (Join-Path $env:ProgramFiles 'WindowsApps') -Filter 'Microsoft.WindowsTerminal*' `
               -Directory -ErrorAction SilentlyContinue |
           Sort-Object Name -Descending | Select-Object -First 1
    if ($pkg) {
        $exe = Join-Path $pkg.FullName 'wt.exe'
        if (Test-Path -LiteralPath $exe) { return $exe }
    }
    return $null
}

function New-BootScript {
    param(
        [Parameter(Mandatory)][string]$Dir,
        [Parameter(Mandatory)][string]$SessionId,
        [Parameter(Mandatory)][string]$Title
    )

    if (-not (Test-Path -LiteralPath $StateDir)) {
        New-Item -ItemType Directory -Path $StateDir -Force | Out-Null
    }

    $slug = ((Split-Path $Dir -Leaf) -replace '[^A-Za-z0-9]', '-')
    $boot = Join-Path $StateDir "boot-$slug.ps1"

    # Single-quoted here-string: nothing below is expanded here. The placeholders
    # are substituted afterwards, so a title containing $ or a backtick can never
    # be re-parsed as PowerShell. A prompt or a name must never cross a shell
    # boundary as syntax.
    $body = @'
# Generated by restore-sessions.ps1 -- safe to delete.
# Scrub the inherited child-session environment. Without this, claude writes no
# transcript at all and the conversation cannot be resumed afterwards.
foreach ($v in @(__SCRUBVARS__)) {
    if (Test-Path "Env:$v") { Remove-Item "Env:$v" -ErrorAction SilentlyContinue }
}
Set-Location -LiteralPath '__DIR__'
# -n writes a DURABLE custom-title into the conversation; --remote-control names
# only this remote session. Both are needed. See the header of restore-sessions.ps1.
& claude --resume '__SESSION__' -n '__TITLE__' --remote-control '__TITLE__'
'@

    $scrubLiteral = (($ChildSessionVars | ForEach-Object { "'" + $_ + "'" }) -join ',')

    $body = $body.Replace('__SCRUBVARS__', $scrubLiteral)
    $body = $body.Replace('__DIR__',       $Dir.Replace("'", "''"))
    $body = $body.Replace('__SESSION__',   $SessionId.Replace("'", "''"))
    $body = $body.Replace('__TITLE__',     $Title.Replace("'", "''"))

    Set-Content -LiteralPath $boot -Value $body -Encoding utf8
    return $boot
}

function Start-RestoredSession {
    param(
        [Parameter(Mandatory)][string]$Dir,
        [Parameter(Mandatory)][string]$BootScript,
        [Parameter(Mandatory)][string]$Title
    )

    $wtPath = Resolve-WindowsTerminal
    if (-not $wtPath) {
        throw "Windows Terminal (wt.exe) not found. A plain PowerShell window spawned from a non-interactive parent does not reliably give claude a usable console, so Windows Terminal is required."
    }

    # -w 0 attaches to the existing Windows Terminal window as a new tab, and
    # creates one if none is open.
    $wtArgs = @(
        '-w', '0', 'new-tab',
        '--title', $Title,
        '-d', $Dir,
        'powershell.exe', '-NoExit', '-NoProfile', '-ExecutionPolicy', 'Bypass',
        '-File', $BootScript
    )
    Start-Process -FilePath $wtPath -ArgumentList $wtArgs | Out-Null
}

# ---------------------------------------------------------------------------
# Modes
# ---------------------------------------------------------------------------

function Invoke-Restore {
    Write-Host ""
    Write-Host "Claude session restore" -ForegroundColor Cyan
    if ($DryRun) { Write-Host "DRY RUN - nothing will be launched" -ForegroundColor Yellow }
    Write-Host ""
    Write-Log "---- restore run ($(if($DryRun){'dry'}else{'live'})) ----"

    $config   = Get-Config
    $sessions = Get-DiscoveredSessions -Config $config

    # Discovering nothing is a THIRD state, not a success. Without this the tool
    # prints the same "failed 0" whether it found your work or found an empty disk.
    if (@($sessions).Count -eq 0) {
        Write-Fail ("no restorable conversation found under {0} within {1} day(s). Use -All to ignore the window." -f $ProjectsRoot, $config.recencyDays)
        return 1
    }

    $launched = 0; $skipped = 0; $failed = 0

    foreach ($s in $sessions) {
        $label = Split-Path $s.Dir -Leaf

        if (Test-SessionProcessRunning -SessionId $s.SessionId) {
            Write-Skip "$label - a claude.exe is already running this conversation (one session per working tree)"
            $skipped++; continue
        }
        if (Test-SessionIsLive -JsonlPath $s.Jsonl) {
            Write-Skip "$label - a session is already live here (transcript written < $LiveWindowMinutes min ago)"
            $skipped++; continue
        }

        # Where the name comes from matters, so say which. A folder-name fallback
        # means the conversation carries no title of its own - worth knowing rather
        # than reading as a real name. Passing -n below then CURES it: the name
        # becomes a durable property of the conversation from this launch on.
        $title = Get-SessionTitle -JsonlPath $s.Jsonl
        $titleSource = 'conversation title'
        if ([string]::IsNullOrWhiteSpace($title)) {
            $title = $label
            $titleSource = 'FALLBACK to folder name - conversation had no title; -n will give it one'
        }

        $short = $s.SessionId.Substring(0, 8)
        $age   = [int]((Get-Date) - $s.Touched).TotalHours

        if ($DryRun) {
            Write-Ok "$label   (last active ${age}h ago)"
            Write-Step "claude --resume $($s.SessionId) -n `"$title`" --remote-control `"$title`""
            Write-Step "in $($s.Dir)"
            Write-Step "name from: $titleSource"
            $launched++
            continue
        }

        try {
            $boot = New-BootScript -Dir $s.Dir -SessionId $s.SessionId -Title $title
            Start-RestoredSession -Dir $s.Dir -BootScript $boot -Title $title
            Write-Ok "$label -> `"$title`" ($short, ${age}h)"
            if ($titleSource -like 'FALLBACK*') { Write-Step $titleSource }
            $launched++
            Start-Sleep -Milliseconds 1200   # let Windows Terminal settle between tabs
        } catch {
            Write-Fail "$label - $($_.Exception.Message)"
            $failed++
        }
    }

    Write-Host ""
    Write-Host ("  restored {0}   skipped {1}   failed {2}" -f $launched, $skipped, $failed)
    if ($launched -eq 0) {
        Write-Host "  NOTHING WAS RESTORED - every discovered project was skipped or failed." -ForegroundColor Yellow
    }
    Write-Host ""
    Write-Log ("  restored {0}   skipped {1}   failed {2}" -f $launched, $skipped, $failed)

    if ($failed -gt 0) { return 1 }
    return 0
}

function Invoke-NewSession {
    $dir = (Get-Location).Path
    $n = $Name
    $extra = @()
    if ($ClaudeArgs) { $extra = @($ClaudeArgs) }

    # A leading token starting with '-' is a claude flag, never a session name.
    # PowerShell would otherwise bind it to -Name and you would get a session
    # called "model" with the flag silently discarded.
    if ($n -and $n.StartsWith('-')) {
        $extra = @($n) + $extra
        $n = $null
    }

    if ([string]::IsNullOrWhiteSpace($n)) {
        $n = (Split-Path $dir -Leaf) + '-' + (Get-Date -Format 'MMdd-HHmm')
    }
    $n = ($n -replace '\s+', '-').Trim('-')
    if ([string]::IsNullOrWhiteSpace($n)) { $n = 'claude-' + (Get-Date -Format 'MMdd-HHmm') }

    Write-Host ""
    Write-Host "Starting a NEW named session: `"$n`"" -ForegroundColor Cyan
    Write-Host "  in $dir"
    if ($extra.Count -gt 0) { Write-Host ("  forwarding to claude: " + ($extra -join ' ')) }
    Write-Host ""

    $claudeArgv = @('-n', $n, '--remote-control', $n) + $extra

    if ($DryRun) {
        Write-Step ("claude " + (($claudeArgv | ForEach-Object {
            if ($_ -match '\s') { '"' + $_ + '"' } else { $_ }
        }) -join ' '))
        return 0
    }

    # Runs in THIS console on purpose - you are already here, and a new window
    # would just be another thing to find.
    Clear-ChildSessionEnv
    & claude @claudeArgv
    return 0
}

function Invoke-Install {
    $scriptPath = Join-Path $ScriptDir 'restore-sessions.ps1'

    Write-Host ""
    Write-Host "Installing" -ForegroundColor Cyan

    $action = New-ScheduledTaskAction -Execute 'powershell.exe' `
        -Argument ("-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"{0}`"" -f $scriptPath)

    $trigger = New-ScheduledTaskTrigger -AtLogOn -User "$env:USERDOMAIN\$env:USERNAME"
    $trigger.Delay = 'PT45S'    # let the shell and Windows Terminal come up first

    $principal = New-ScheduledTaskPrincipal -UserId "$env:USERDOMAIN\$env:USERNAME" `
        -LogonType Interactive -RunLevel Limited

    $settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
        -ExecutionTimeLimit ([TimeSpan]::FromMinutes(10)) -MultipleInstances IgnoreNew

    Register-ScheduledTask -TaskName $TaskName -Action $action -Trigger $trigger `
        -Principal $principal -Settings $settings -Force `
        -Description 'Restore recent Claude Code conversations with Remote Control attached.' | Out-Null
    Write-Ok "scheduled task '$TaskName' registered (at logon, 45s delay)"

    $lnkPath = Join-Path ([Environment]::GetFolderPath('Desktop')) $ShortcutName
    $shell   = New-Object -ComObject WScript.Shell
    $lnk     = $shell.CreateShortcut($lnkPath)
    $lnk.TargetPath       = 'powershell.exe'
    $lnk.Arguments        = ("-NoProfile -ExecutionPolicy Bypass -File `"{0}`"" -f $scriptPath)
    $lnk.WorkingDirectory = $ScriptDir
    $lnk.IconLocation     = 'powershell.exe,0'
    $lnk.Description      = 'Restore recent Claude Code conversations'
    $lnk.Save()
    Write-Ok "desktop shortcut created: $lnkPath"

    Write-Host ""
    Write-Host "  Preview any time with:  restore-sessions.ps1 -DryRun"
    Write-Host "  Tune discovery in:      $ConfigPath"
    Write-Host "  Per-machine overrides:  $LocalOverride  (optional, never committed)"
    Write-Host ""
    return 0
}

function Invoke-Uninstall {
    Write-Host ""
    Write-Host "Uninstalling" -ForegroundColor Cyan

    if (Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue) {
        Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false
        Write-Ok "scheduled task '$TaskName' removed"
    } else {
        Write-Skip "scheduled task '$TaskName' was not registered"
    }

    $lnkPath = Join-Path ([Environment]::GetFolderPath('Desktop')) $ShortcutName
    if (Test-Path -LiteralPath $lnkPath) {
        [System.IO.File]::Delete($lnkPath)
        Write-Ok "desktop shortcut removed"
    } else {
        Write-Skip "desktop shortcut was not present"
    }

    Write-Host ""
    return 0
}

# ---------------------------------------------------------------------------
Clear-ChildSessionEnv

if ($Install -and $Uninstall) {
    Write-Fail "-Install and -Uninstall are mutually exclusive"
    exit 1
}

# A fatal throw at logon would otherwise vanish with the hidden window.
try {
    if ($Install)   { exit (Invoke-Install) }
    if ($Uninstall) { exit (Invoke-Uninstall) }
    if ($New)       { exit (Invoke-NewSession) }
    exit (Invoke-Restore)
} catch {
    Write-Fail ("FATAL: " + $_.Exception.Message)
    Write-Log  ("       at " + $_.InvocationInfo.PositionMessage)
    exit 1
}
