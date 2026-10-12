# spawn-session - registry router and local runtime adapters.
# Keep this file ASCII: Windows PowerShell 5.1 may read scripts as ANSI.

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$Runtime,

    [string]$Directory = (Get-Location).Path,
    [string]$Name = "",
    [string]$Prompt = "",
    [string[]]$HandoffFile = @(),
    [string]$Model = "",

    [ValidateSet("analysis", "implementation")]
    [string]$Mode = "implementation",

    [switch]$AllowDuplicate,
    [switch]$ListModels,
    [switch]$Pwsh,
    # Open in Windows Terminal even when a herdr server is running (default: herdr wins).
    [switch]$Wt,
    [int]$VerifyTimeoutSec = 90,
    [switch]$DryRun
)

$ErrorActionPreference = "Stop"

function Stop-SpawnSession {
    param([string]$Message)
    Write-Error ("spawn-session: " + $Message)
    exit 1
}

function Get-ContentText {
    param($Content)
    if ($Content -is [string]) { return $Content }
    if ($null -eq $Content) { return "" }
    $parts = @()
    foreach ($block in @($Content)) {
        if ($null -ne $block -and $null -ne $block.text) { $parts += [string]$block.text }
    }
    return ($parts -join "")
}

function Test-PiPromptInSession {
    param(
        [string]$Path,
        [string]$ExpectedDirectory,
        [string]$ExpectedPrompt,
        [string]$ExpectedSessionId
    )
    try {
        $lines = Get-Content -LiteralPath $Path -Encoding UTF8 -ErrorAction Stop
        if ($lines.Count -eq 0) { return $false }
        $header = $lines[0] | ConvertFrom-Json -ErrorAction Stop
        if ($header.type -ne "session" -or [string]$header.cwd -ne $ExpectedDirectory) { return $false }
        if (-not [string]::IsNullOrWhiteSpace($ExpectedSessionId) -and [string]$header.id -ne $ExpectedSessionId) { return $false }
        foreach ($line in $lines) {
            $entry = $line | ConvertFrom-Json -ErrorAction Stop
            if ($entry.type -eq "message" -and $null -ne $entry.message -and $entry.message.role -eq "user") {
                if ((Get-ContentText $entry.message.content) -ceq $ExpectedPrompt) { return $true }
            }
        }
    } catch {
        return $false
    }
    return $false
}

function Expand-RegistryArgs {
    param(
        $ArgsTemplate,
        [string]$SessionName,
        [string]$SelectedModel
    )
    $expanded = @()
    foreach ($arg in @($ArgsTemplate)) {
        $token = [string]$arg
        $token = $token.Replace("{name}", $SessionName)
        $token = $token.Replace("{model}", $SelectedModel)
        $expanded += $token
    }
    return $expanded
}

$registryPath = Join-Path $PSScriptRoot "runtimes.local.json"
if (-not (Test-Path -LiteralPath $registryPath -PathType Leaf)) {
    Stop-SpawnSession "runtime registry is missing -> $registryPath"
}
try {
    $registry = Get-Content -Raw -LiteralPath $registryPath -Encoding UTF8 | ConvertFrom-Json -ErrorAction Stop
} catch {
    Stop-SpawnSession ("runtime registry is invalid JSON -> " + $_.Exception.Message)
}

$runtimeKey = $Runtime.Trim().ToLowerInvariant()
$runtimeConfig = $registry.runtimes.$runtimeKey
if ($null -eq $runtimeConfig) {
    Stop-SpawnSession "runtime '$Runtime' is not configured. Add a fully declared unverified entry to $registryPath; see STATUS.md. No runtime was substituted."
}
foreach ($field in @("executable", "interactiveLaunchArgs", "resumeGuidance", "verificationLevel")) {
    if ($null -eq $runtimeConfig.$field -or [string]::IsNullOrWhiteSpace([string]$runtimeConfig.$field)) {
        Stop-SpawnSession "runtime '$runtimeKey' has no '$field' declaration in $registryPath."
    }
}
foreach ($field in @("modelDiscoveryArgs", "modelArgs")) {
    if ($runtimeConfig.PSObject.Properties.Name -notcontains $field) {
        Stop-SpawnSession "runtime '$runtimeKey' must explicitly declare optional '$field' in $registryPath."
    }
}

$verificationLevel = [string]$runtimeConfig.verificationLevel
if ($runtimeKey -eq "pi" -and $verificationLevel -ne "preassigned-id-prompt-correlation") {
    Stop-SpawnSession "Pi requires verificationLevel 'preassigned-id-prompt-correlation'."
}
if ($runtimeKey -eq "claude" -and $verificationLevel -ne "adapter-verified") {
    Stop-SpawnSession "Claude requires verificationLevel 'adapter-verified'."
}
if ($runtimeKey -notin @("pi", "claude") -and $verificationLevel -ne "unverified") {
    Stop-SpawnSession "generic runtime '$runtimeKey' may launch only with verificationLevel 'unverified'."
}

try {
    $resolved = (Resolve-Path -LiteralPath $Directory -ErrorAction Stop).Path
} catch {
    Stop-SpawnSession "directory not found -> $Directory"
}
if (-not (Test-Path -LiteralPath $resolved -PathType Container)) {
    Stop-SpawnSession "not a directory -> $resolved"
}

$handoffAbs = @()
foreach ($handoff in $HandoffFile) {
    if ([string]::IsNullOrWhiteSpace($handoff)) { continue }
    try {
        $path = (Resolve-Path -LiteralPath $handoff -ErrorAction Stop).Path
    } catch {
        Stop-SpawnSession "handover file not found -> $handoff"
    }
    if (Test-Path -LiteralPath $path -PathType Container) {
        Stop-SpawnSession "handover path is a directory -> $path"
    }
    $handoffAbs += $path
}

if ([string]::IsNullOrWhiteSpace($Name)) {
    $Name = (Split-Path -Leaf $resolved) + "-" + (Get-Date -Format "MMdd-HHmm")
}
$Name = ($Name -replace "[^A-Za-z0-9_.-]+", "-").Trim("-")
if ([string]::IsNullOrWhiteSpace($Name)) { $Name = "spawn-" + (Get-Date -Format "MMdd-HHmm") }

if ($Mode -eq "implementation" -and $AllowDuplicate) {
    Stop-SpawnSession "-AllowDuplicate is analysis-only. Implementation sessions must refuse an occupied lane."
}

$promptParts = @()
if ($handoffAbs.Count -gt 0) {
    $promptParts += "HANDOVER: you are a fresh session continuing existing work. Before anything else, read these file(s) end-to-end; they are your authoritative briefing:"
    $number = 1
    foreach ($path in $handoffAbs) {
        $promptParts += ("  " + $number + ". " + $path)
        $number++
    }
    $promptParts += "Follow the paths and links they reference rather than re-deriving context."
    $promptParts += ""
}
if (-not [string]::IsNullOrWhiteSpace($Prompt)) { $promptParts += $Prompt }
$fullPrompt = ($promptParts -join "`n").Trim()
if (-not $ListModels -and [string]::IsNullOrWhiteSpace($fullPrompt)) {
    Stop-SpawnSession "pass -Prompt and/or -HandoffFile. A new session needs an opening task."
}

$exe = [string]$runtimeConfig.executable
$command = Get-Command $exe -ErrorAction SilentlyContinue
if ($null -eq $command) {
    Stop-SpawnSession "configured executable '$exe' was not found on PATH. Install/configure this runtime, then retry; no PATH locations were guessed."
}

if ($ListModels) {
    if ($null -eq $runtimeConfig.modelDiscoveryArgs -or @($runtimeConfig.modelDiscoveryArgs).Count -eq 0) {
        Write-Host "MODEL      : $runtimeKey has no model inventory. Use the runtime default or a typed -Model override."
        exit 0
    }
    Write-Host "MODEL      : read-only inventory for $runtimeKey"
    & $command.Source @(Expand-RegistryArgs $runtimeConfig.modelDiscoveryArgs $Name $Model)
    exit $LASTEXITCODE
}

if ($runtimeKey -eq "claude") {
    $claudeLauncher = Join-Path $PSScriptRoot "..\spawn-claude-session\spawn.ps1"
    if (-not (Test-Path -LiteralPath $claudeLauncher -PathType Leaf)) {
        Stop-SpawnSession "Claude adapter is missing -> $claudeLauncher"
    }
    $claudeParams = @{ Directory = $resolved; Name = $Name; Prompt = $Prompt }
    if ($handoffAbs.Count -gt 0) { $claudeParams.HandoffFile = $handoffAbs }
    if (-not [string]::IsNullOrWhiteSpace($Model)) { $claudeParams.Model = $Model }
    if ($AllowDuplicate) { $claudeParams.AllowDuplicate = $true }
    if ($DryRun) { $claudeParams.DryRun = $true }
    & $claudeLauncher @claudeParams
    exit $LASTEXITCODE
}

$launchArgs = @(Expand-RegistryArgs $runtimeConfig.interactiveLaunchArgs $Name $Model)
if (-not [string]::IsNullOrWhiteSpace($Model)) {
    if ($null -eq $runtimeConfig.modelArgs -or @($runtimeConfig.modelArgs).Count -eq 0) {
        Stop-SpawnSession "runtime '$runtimeKey' does not declare modelArgs; omit -Model or configure its adapter."
    }
    $launchArgs += @(Expand-RegistryArgs $runtimeConfig.modelArgs $Name $Model)
}

# Assign the Pi session identity before launch. This makes recovery independent of
# the current working directory, picker scope, terminal lifetime, or prompt correlation.
$launchSessionId = ""
if ($runtimeKey -eq "pi") {
    $launchSessionId = [guid]::NewGuid().ToString()
    $launchArgs += @("--session-id", $launchSessionId)
}

$stateRoot = Join-Path $env:LOCALAPPDATA "spawn-session"
$markerRoot = Join-Path $stateRoot "running"
New-Item -ItemType Directory -Force -Path $markerRoot | Out-Null
$markerPath = Join-Path $markerRoot ($runtimeKey + "-" + $Name + ".json")

# Capture the session set before launch, then require the newly created target-cwd
# file to contain both the preassigned session id and the exact opening prompt.
$sessionRoot = Join-Path $env:USERPROFILE ".pi\agent\sessions"
$before = @{}
if ($runtimeKey -eq "pi" -and (Test-Path -LiteralPath $sessionRoot -PathType Container)) {
    Get-ChildItem -LiteralPath $sessionRoot -Filter "*.jsonl" -Recurse -File -ErrorAction SilentlyContinue | ForEach-Object { $before[$_.FullName] = $true }
}

$duplicateReasons = @()
if (Test-Path -LiteralPath $markerPath -PathType Leaf) {
    try {
        $marker = Get-Content -Raw -LiteralPath $markerPath -Encoding UTF8 | ConvertFrom-Json -ErrorAction Stop
        $markerProcess = Get-Process -Id ([int]$marker.pid) -ErrorAction SilentlyContinue
        if ($markerProcess) {
            if ([string]$marker.directory -eq $resolved) {
                $duplicateReasons += "an adapter-owned $runtimeKey session named '$Name' is running in this directory (boot pid $($marker.pid))"
            } else {
                $duplicateReasons += "an adapter-owned $runtimeKey session already uses the name '$Name' (boot pid $($marker.pid))"
            }
        } else {
            Remove-Item -LiteralPath $markerPath -Force -ErrorAction SilentlyContinue
        }
    } catch {
        $duplicateReasons += "the existing adapter marker for '$Name' cannot be read; remove it only after confirming its session is not live"
    }
}
if ($runtimeKey -eq "pi") {
    try {
        $escapedName = [regex]::Escape($Name)
        $piProcesses = @(Get-CimInstance Win32_Process -Filter "Name='node.exe'" -ErrorAction Stop)
        foreach ($process in $piProcesses) {
            $line = [string]$process.CommandLine
            if ($line -match ("(?:^|\s)--(?:name|n)\s+" + $escapedName + "(?:\s|$)")) {
                $duplicateReasons += "node.exe pid $($process.ProcessId) carries the requested session name '$Name'"
            }
        }
    } catch {
        Write-Host ("NOTE       : process inspection unavailable; only adapter-owned lane markers were checked (" + $_.Exception.Message + ").") -ForegroundColor DarkYellow
    }
}
if ($duplicateReasons.Count -gt 0 -and -not $AllowDuplicate) {
    Write-Host "REFUSING   : this $Mode lane is already held." -ForegroundColor Red
    foreach ($reason in $duplicateReasons) { Write-Host ("             " + $reason) -ForegroundColor Red }
    Write-Host "             Choose a different worktree/lane or, for analysis only, pass -AllowDuplicate."
    exit 1
}
if ($duplicateReasons.Count -gt 0) {
    Write-Host "OVERRIDE   : analysis-only duplicate override accepted." -ForegroundColor Yellow
    foreach ($reason in $duplicateReasons) { Write-Host ("             " + $reason) -ForegroundColor Yellow }
}

if ($DryRun) {
    Write-Host "Runtime    : $runtimeKey ($($runtimeConfig.displayName))"
    Write-Host "Directory  : $resolved"
    Write-Host "Session    : $Name"
    Write-Host "Mode       : $Mode"
    if ($Model) { Write-Host "Model      : $Model" } else { Write-Host "Model      : runtime default" }
    foreach ($path in $handoffAbs) { Write-Host "Handover   : $path" }
    Write-Host "Command    : $exe $($launchArgs -join ' ') <opening prompt from file>"
    Write-Host "Launcher   : Windows Terminal preferred; prompt is passed as one argv element from a UTF-8 file."
    Write-Host "Verify     : $verificationLevel"
    if ($runtimeKey -eq "pi") {
        Write-Host "Session id : $launchSessionId (preassigned)"
        Write-Host "Resume     : pi --session $launchSessionId       (from $resolved)"
    } else {
        Write-Host "Resume     : $($runtimeConfig.resumeGuidance)"
    }
    Write-Host ""
    Write-Host "--- opening prompt ---"
    Write-Host $fullPrompt
    exit 0
}

$bootId = [guid]::NewGuid().ToString()
$bootDir = Join-Path $stateRoot ("boot-" + $bootId)
New-Item -ItemType Directory -Force -Path $bootDir | Out-Null
$promptPath = Join-Path $bootDir "prompt.txt"
$bootPath = Join-Path $bootDir "boot.ps1"
$utf8NoBom = New-Object System.Text.UTF8Encoding($false)
[System.IO.File]::WriteAllText($promptPath, $fullPrompt, $utf8NoBom)

$launchLiterals = ($launchArgs | ForEach-Object { "'" + ($_ -replace "'", "''") + "'" }) -join ", "
$bootLines = @(
    "# Auto-generated by spawn-session.",
    "`$ErrorActionPreference = 'Stop'",
    ('$markerPath = ''{0}''' -f ($markerPath -replace "'", "''")),
    ('$promptPath = ''{0}''' -f ($promptPath -replace "'", "''")),
    ('$piArgs = @({0})' -f $launchLiterals),
    ('$marker = @{{ pid = $PID; directory = ''{0}''; name = ''{1}''; runtime = ''{2}'' }} | ConvertTo-Json -Compress' -f ($resolved -replace "'", "''"), ($Name -replace "'", "''"), $runtimeKey),
    "[System.IO.File]::WriteAllText(`$markerPath, `$marker, (New-Object System.Text.UTF8Encoding(`$false)))",
    "try {",
    "    `$openingPrompt = Get-Content -Raw -LiteralPath `$promptPath",
    ('    & ''{0}'' @piArgs $openingPrompt' -f ($command.Source -replace "'", "''")),
    "} finally {",
    "    Remove-Item -LiteralPath `$markerPath -Force -ErrorAction SilentlyContinue",
    "    Remove-Item -LiteralPath `$promptPath -Force -ErrorAction SilentlyContinue",
    "    Remove-Item -LiteralPath `$PSCommandPath -Force -ErrorAction SilentlyContinue",
    ('    Remove-Item -LiteralPath ''{0}'' -Force -ErrorAction SilentlyContinue' -f ($bootDir -replace "'", "''")),
    "}"
)
[System.IO.File]::WriteAllLines($bootPath, [string[]]$bootLines, $utf8NoBom)

$receiptPath = $null
if ($runtimeKey -eq "pi") {
    $receiptRoot = Join-Path $env:USERPROFILE ".pi\agent\spawned-sessions"
    New-Item -ItemType Directory -Force -Path $receiptRoot | Out-Null
    $receiptPath = Join-Path $receiptRoot ($launchSessionId + ".json")
    $receipt = [ordered]@{
        schemaVersion = 1
        runtime = "pi"
        sessionId = $launchSessionId
        name = $Name
        directory = $resolved
        status = "launching"
        createdAt = (Get-Date).ToUniversalTime().ToString("o")
        sessionFile = $null
        resumeCommand = "pi --session $launchSessionId"
    }
    [System.IO.File]::WriteAllText($receiptPath, ($receipt | ConvertTo-Json), $utf8NoBom)
}

# --- herdr: open inside the running herdr server when there is one ---------------
# Same placement as spawn-claude-session: the workspace already open on this folder (a worktree
# workspace counts), else herdr's worktree Space linked to the repo, else the repo's main
# workspace, else a new one. A session in a herdr pane is registered with herdr (Agents panel,
# alerts, the Navigator); one in a Windows Terminal tab is not. Nothing here starts a herdr server.
function Get-HerdrTarget([string]$dir) {
    $hb = Get-Command herdr -ErrorAction SilentlyContinue
    if (-not $hb) { return $null }
    $json = & $hb.Source workspace list 2>$null
    if ($LASTEXITCODE -ne 0 -or -not $json) { return $null }
    try { $wss = (($json | Out-String) | ConvertFrom-Json).result.workspaces } catch { return $null }
    $norm = { param($x) if (-not $x) { return "" }; ($x -replace '^\\\\\?\\', '' -replace '/', '\').TrimEnd('\').ToLowerInvariant() }
    $want = & $norm $dir
    $top = ""
    try { $top = (& git -C $dir rev-parse --show-toplevel 2>$null | Out-String).Trim() } catch { }
    $common = ""
    try { $common = (& git -C $dir rev-parse --path-format=absolute --git-common-dir 2>$null | Out-String).Trim() } catch { }
    $main = ""
    if ($common) { $main = Split-Path -Parent $common }
    $topN = & $norm $top
    $mainN = & $norm $main
    $linked = [bool]($topN -and $mainN -and $topN -ne $mainN)
    $ws = $wss | Where-Object { $_.worktree -and (& $norm $_.worktree.checkout_path) -eq $want } | Select-Object -First 1
    if (-not $ws -and $topN) {
        $ws = $wss | Where-Object { $_.worktree -and (& $norm $_.worktree.checkout_path) -eq $topN } | Select-Object -First 1
    }
    $mainWs = $null
    if ($mainN) {
        $mainWs = $wss | Where-Object { $_.worktree -and -not $_.worktree.is_linked_worktree -and (& $norm $_.worktree.repo_root) -eq $mainN } | Select-Object -First 1
    }
    if (-not $ws -and -not $linked) { $ws = $mainWs }
    return @{ Bin = $hb.Source; Workspace = $ws; MainWs = $mainWs; Linked = $linked; Top = $top }
}

function Start-InHerdr($herdr, [string]$dir, [string]$label, [string]$boot) {
    # A named tab whose shell runs boot.ps1. The herdr server is its parent, so closing the
    # herdr window does not end the session. Returns $true only when herdr took the command.
    try {
        $wsId = $null
        $created = $false
        if ($herdr.Workspace) { $wsId = $herdr.Workspace.workspace_id }
        elseif ($herdr.Linked -and $herdr.MainWs) {
            $leaf = Split-Path -Leaf $herdr.Top
            $wsJson = & $herdr.Bin worktree open --workspace $herdr.MainWs.workspace_id --path "$($herdr.Top)" --label "$leaf" --no-focus 2>$null
            if ($LASTEXITCODE -eq 0) {
                $wo = (($wsJson | Out-String) | ConvertFrom-Json).result
                $wsId = $wo.workspace.workspace_id
                $created = [bool]$wsId -and -not $wo.already_open
            }
        }
        if (-not $wsId) {
            $leaf = Split-Path -Leaf $dir
            $wsJson = & $herdr.Bin workspace create --cwd "$dir" --label "$leaf" --no-focus 2>$null
            if ($LASTEXITCODE -eq 0) { $wsId = (($wsJson | Out-String) | ConvertFrom-Json).result.workspace.workspace_id; $created = [bool]$wsId }
        }
        if (-not $wsId) { return $false }
        $paneId = $null
        if ($created) {
            # a new Space already has an idle root pane: run in it rather than adding a tab
            $pl = & $herdr.Bin pane list --workspace $wsId 2>$null
            if ($LASTEXITCODE -eq 0) {
                $root = (($pl | Out-String) | ConvertFrom-Json).result.panes | Select-Object -First 1
                if ($root) {
                    $paneId = $root.pane_id
                    & $herdr.Bin tab rename $root.tab_id "$label" 2>$null | Out-Null
                }
            }
        }
        if (-not $paneId) {
            $tabJson = & $herdr.Bin tab create --workspace $wsId --cwd "$dir" --label "$label" --no-focus 2>$null
            if ($LASTEXITCODE -eq 0) { $paneId = (($tabJson | Out-String) | ConvertFrom-Json).result.root_pane.pane_id }
        }
        if (-not $paneId) { return $false }
        $runLine = 'powershell.exe -NoExit -NoProfile -ExecutionPolicy Bypass -File "' + $boot + '"'
        & $herdr.Bin pane run $paneId $runLine 2>$null | Out-Null
        if ($LASTEXITCODE -ne 0) { return $false }
        Write-Host "Opened in herdr: workspace $wsId, pane $paneId"
        return $true
    } catch { return $false }
}

$launchedInHerdr = $false
if (-not $Wt -and -not $Pwsh) {
    $herdrTarget = Get-HerdrTarget $resolved
    if ($herdrTarget) {
        $launchedInHerdr = Start-InHerdr $herdrTarget $resolved $Name $bootPath
        if (-not $launchedInHerdr) { Write-Warning "spawn-session: herdr did not take the session - opening it in Windows Terminal instead." }
    }
}

$wtCmd = Get-Command wt.exe -ErrorAction SilentlyContinue
if ($null -eq $wtCmd) {
    $wtAlias = Join-Path $env:LOCALAPPDATA "Microsoft\WindowsApps\wt.exe"
    if (Test-Path -LiteralPath $wtAlias -PathType Leaf) { $wtPath = $wtAlias } else { $wtPath = $null }
} else {
    $wtPath = $wtCmd.Source
}
if ($launchedInHerdr) {
    # registered with herdr; the verify below finds the session exactly as for a wt tab
} elseif ($null -ne $wtPath -and -not $Pwsh) {
    & $wtPath -w spawn-session new-tab --title $Name -d $resolved powershell.exe -NoExit -NoProfile -ExecutionPolicy Bypass -File $bootPath
} else {
    Write-Warning "spawn-session: Windows Terminal is unavailable or -Pwsh was requested; using a PowerShell window."
    Start-Process powershell.exe -ArgumentList @("-NoExit", "-NoProfile", "-ExecutionPolicy", "Bypass", "-File", ('"' + $bootPath + '"')) -WorkingDirectory $resolved | Out-Null
}

if ($runtimeKey -ne "pi") {
    Write-Host "UNVERIFIED : generic runtime '$runtimeKey' was launched. Registry declares unverified; inspect the terminal and use: $($runtimeConfig.resumeGuidance)" -ForegroundColor Yellow
    exit 0
}

$deadline = (Get-Date).AddSeconds($VerifyTimeoutSec)
$verifiedPath = $null
while ((Get-Date) -lt $deadline) {
    if (Test-Path -LiteralPath $sessionRoot -PathType Container) {
        $candidates = Get-ChildItem -LiteralPath $sessionRoot -Filter "*.jsonl" -Recurse -File -ErrorAction SilentlyContinue |
            Where-Object { -not $before.ContainsKey($_.FullName) }
        foreach ($candidate in $candidates) {
            if (Test-PiPromptInSession $candidate.FullName $resolved $fullPrompt $launchSessionId) {
                $verifiedPath = $candidate.FullName
                break
            }
        }
    }
    if ($verifiedPath) { break }
    Start-Sleep -Milliseconds 500
}

Write-Host ""
Write-Host "Runtime    : Pi CLI (npm)"
Write-Host "Directory  : $resolved"
Write-Host "Session    : $Name"
if ($Model) { Write-Host "Model      : $Model" } else { Write-Host "Model      : runtime default" }
if ($verifiedPath) {
    $receipt = Get-Content -Raw -LiteralPath $receiptPath -Encoding UTF8 | ConvertFrom-Json
    $receipt.status = "verified"
    $receipt.sessionFile = $verifiedPath
    $receipt | Add-Member -NotePropertyName verifiedAt -NotePropertyValue ((Get-Date).ToUniversalTime().ToString("o")) -Force
    [System.IO.File]::WriteAllText($receiptPath, ($receipt | ConvertTo-Json), $utf8NoBom)
    Write-Host "VERIFIED   : preassigned session id and exact opening prompt persisted in the target cwd."
    Write-Host "Session id : $launchSessionId"
    Write-Host "Session file: $verifiedPath"
    Write-Host "Receipt    : $receiptPath"
    Write-Host "RESUME     : pi --session $launchSessionId       (from $resolved)"
    exit 0
}

if ($receiptPath -and (Test-Path -LiteralPath $receiptPath -PathType Leaf)) {
    $receipt = Get-Content -Raw -LiteralPath $receiptPath -Encoding UTF8 | ConvertFrom-Json
    $receipt.status = "unverified"
    $receipt | Add-Member -NotePropertyName checkedAt -NotePropertyValue ((Get-Date).ToUniversalTime().ToString("o")) -Force
    [System.IO.File]::WriteAllText($receiptPath, ($receipt | ConvertTo-Json), $utf8NoBom)
}
Write-Warning "UNVERIFIED/FAILED: the preassigned Pi session $launchSessionId did not persist its exact opening prompt in the target cwd within ${VerifyTimeoutSec}s. Inspect the terminal. If startup completed, resume directly with 'pi --session $launchSessionId' from $resolved. Receipt: $receiptPath. Boot files: $bootDir"
exit 2
