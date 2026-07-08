# spawn.ps1 - launch a NEW Claude Code session in a new terminal.
#
# Backs the `spawn-claude-session` skill. Opens a fresh Windows Terminal window
# (falls back to a plain PowerShell window when wt.exe is absent), starts in the
# requested directory, and launches `claude`.
#
# DEFAULT = a LOCAL, RESUMABLE session (`claude`). It runs on THIS PC with full
# functionality (all tools, file/bash, the project) and writes its transcript
# (<id>.jsonl) into the project folder for the launch directory - so the chat's
# "memory" survives and you can reopen it later from ANY terminal in the SAME
# directory via `claude --resume` (pick it) / `claude --continue` (most recent).
#
# LAUNCH LOCATION (operator design 2026-07-08): resumability is tied to the launch
# directory, so the session must open in the repo you'll resume it from.
#   * Explicit  : pass -Directory "<path>" to CHOOSE the repo (e.g. AlgoTrader).
#   * Smart auto: omit -Directory and it uses the caller's cwd (the directory the
#                 current conversation runs in) - normally already the right repo.
# Resume it later by running `claude --resume` from a terminal in that same dir.
#
# -RemoteControl is an EXPLICIT OPT-IN and is NOT recommended by default: it adds
# `--remote-control <name>` so the session can be driven from the Claude mobile app /
# claude.ai, BUT a cloud-DRIVEN conversation's history lives in the cloud and may NOT
# leave a locally-resumable transcript (lesson 2026-06-16). The operator does NOT want
# cloud sessions - use this only on an explicit, one-off request for phone control.
#
# Verified surface (claude --help on this machine):
#   --remote-control [name]   Start an interactive session with Remote Control enabled
#   --model <model>           Model alias or full id
# There is NO `claude remote-control` subcommand and NO `--rc` shorthand - do not use them.
#
# NOTE: keep this file pure ASCII. Windows PowerShell 5.1 reads .ps1 as ANSI, so a
# non-ASCII char (em-dash, smart quote) corrupts the parse. Use '-' not a long dash.

[CmdletBinding()]
param(
    # Working directory for the new session. CHOOSE the repo explicitly, or omit to
    # smart-detect the caller's cwd. Resumability is tied to this directory.
    [Parameter(Position = 0)]
    [string]$Directory = (Get-Location).Path,

    # Session display name (used for the transcript label / Remote Control name).
    # Auto-derived from the leaf dir + timestamp when omitted.
    [Parameter(Position = 1)]
    [string]$Name = "",

    # Optional model alias (e.g. 'opus', 'sonnet') for the spawned session.
    [string]$Model = "",

    # EXPLICIT OPT-IN only: enable Remote Control (drive from phone / claude.ai).
    # NOT the default - a cloud-driven chat may NOT be locally resumable, and the
    # operator wants resumable LOCAL sessions. Use only on an explicit request.
    [Alias("Rc")]
    [switch]$RemoteControl,

    # Force a plain PowerShell window instead of Windows Terminal.
    [switch]$Pwsh,

    # Print what would launch without spawning anything.
    [switch]$DryRun
)

$ErrorActionPreference = "Stop"

# --- Resolve + validate the target directory ---------------------------------
try {
    $resolved = (Resolve-Path -LiteralPath $Directory).Path
} catch {
    Write-Error "spawn-claude-session: directory not found -> $Directory"
    exit 1
}
if (-not (Test-Path -LiteralPath $resolved -PathType Container)) {
    Write-Error "spawn-claude-session: not a directory -> $resolved"
    exit 1
}

# --- Derive + sanitize the session name --------------------------------------
if ([string]::IsNullOrWhiteSpace($Name)) {
    $leaf  = Split-Path -Leaf $resolved
    $stamp = Get-Date -Format "MMdd-HHmm"
    $Name  = "$leaf-$stamp"
}
# Collapse whitespace to '-' so the name is a single safe command-line token.
$Name = ($Name -replace '\s+', '-').Trim('-')
if ([string]::IsNullOrWhiteSpace($Name)) { $Name = "claude-$(Get-Date -Format 'MMdd-HHmm')" }

# --- Build the inner `claude` command ----------------------------------------
# Plain `claude` (default) = a local, resumable session. --remote-control is added
# ONLY when -RemoteControl is explicitly passed (cloud-driven; may not be resumable).
$claudeTokens = @()
if ($RemoteControl) {
    $claudeTokens += @("--remote-control", $Name)
}
if (-not [string]::IsNullOrWhiteSpace($Model)) {
    $claudeTokens += @("--model", $Model)
}
$claudeCmd = ("claude " + (($claudeTokens | ForEach-Object {
    if ($_ -match '\s') { '"' + $_ + '"' } else { $_ }
}) -join ' ')).Trim()

# --- Pick the launcher --------------------------------------------------------
# Resolve wt.exe robustly: Get-Command misses the WindowsApps execution-alias
# (a reparse point not always on a child shell's PATH), so fall back to the
# known alias location and invoke by full path.
$wtPath = $null
$gc = Get-Command wt.exe -ErrorAction SilentlyContinue
if ($gc) {
    $wtPath = $gc.Source
} else {
    $alias = Join-Path $env:LOCALAPPDATA 'Microsoft\WindowsApps\wt.exe'
    if (Test-Path -LiteralPath $alias) { $wtPath = $alias }
}
$useWt = ($wtPath -ne $null) -and (-not $Pwsh)

if ($DryRun) {
    if ($RemoteControl) { $modeStr = "Remote Control (cloud-driven; may NOT be locally resumable) - opt-in" }
    else { $modeStr = "LOCAL + resumable (reopen via 'claude --resume' from this directory)" }
    if ($useWt) { $launcherStr = "Windows Terminal (wt.exe)" } else { $launcherStr = "PowerShell window" }
    Write-Host "Directory : $resolved"
    Write-Host "Session   : $Name"
    if ($Model) { Write-Host "Model     : $Model" }
    Write-Host "Command   : $claudeCmd"
    Write-Host "Mode      : $modeStr"
    Write-Host "Launcher  : $launcherStr"
    exit 0
}

if ($useWt) {
    # New Windows Terminal window; -d sets the starting dir; -NoExit keeps the pane open.
    & $wtPath -w new -d "$resolved" powershell.exe -NoExit -Command $claudeCmd
} else {
    # Fallback: a plain new PowerShell window.
    $inner = "Set-Location -LiteralPath '$resolved'; $claudeCmd"
    Start-Process powershell.exe -ArgumentList @("-NoExit", "-Command", $inner) | Out-Null
}

if ($RemoteControl) {
    Write-Host "Spawned Claude session '$Name' (Remote Control - CLOUD) in: $resolved"
    Write-Host "Connect from the Claude mobile app or https://claude.ai/code - the new window shows the pairing URL/QR."
    Write-Host "NOTE: a cloud-driven conversation may NOT be resumable from a local terminal."
} else {
    Write-Host "Spawned a LOCAL, resumable Claude session in: $resolved"
    Write-Host "Reopen it later from a terminal in THIS directory via 'claude --resume' (pick it) or 'claude --continue' (most recent)."
}
