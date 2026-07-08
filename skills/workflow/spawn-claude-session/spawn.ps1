# spawn.ps1 - launch a NEW Claude Code session in a new terminal.
#
# Backs the `spawn-claude-session` skill. Opens a fresh Windows Terminal window
# (falls back to a plain PowerShell window when wt.exe is absent), starts in the
# requested directory, and launches `claude`.
#
# DEFAULT = a LOCAL session WITH REMOTE CONTROL enabled (`claude --remote-control
# <name>`). The session runs 100% LOCALLY on THIS PC with full functionality (all
# tools, file/bash access, the project - you type in the local terminal normally);
# Remote Control ADDS a phone/web pairing so you can ALSO navigate/drive it from the
# Claude mobile app / claude.ai. The compute is local; only the message relay is
# remote. Operator preference (2026-07-08): local full control + phone navigation.
#
# LAUNCH LOCATION: the session opens in the repo you pass (or the caller's cwd).
#   * Explicit  : pass -Directory "<path>" to CHOOSE the repo (e.g. AlgoTrader).
#   * Smart auto: omit -Directory and it uses the caller's cwd - normally the right repo.
#
# -Local (alias -NoRemoteControl) OPTS OUT of Remote Control -> a pure local session
# with NO phone pairing. Its transcript is written to the project folder for the
# launch dir, so it is reopenable via `claude --resume` / `claude --continue` from a
# terminal there. (Resumability of a Remote-Control session is not guaranteed - a
# lesson from 2026-06-16 - so use -Local when local resume is the priority.)
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
    # smart-detect the caller's cwd.
    [Parameter(Position = 0)]
    [string]$Directory = (Get-Location).Path,

    # Session display name (Remote Control name / transcript label).
    # Auto-derived from the leaf dir + timestamp when omitted.
    [Parameter(Position = 1)]
    [string]$Name = "",

    # Optional model alias (e.g. 'opus', 'sonnet') for the spawned session.
    [string]$Model = "",

    # Opt OUT of Remote Control -> a pure local session (no phone pairing), resumable
    # locally. Remote Control is ON BY DEFAULT (operator wants phone navigation).
    [Alias("NoRemoteControl")]
    [switch]$Local,

    # Back-compat / explicit affirm: Remote Control is the default now, so passing
    # -RemoteControl just affirms it. Ignored when -Local is also passed.
    [Alias("Rc")]
    [switch]$RemoteControl,

    # Force a plain PowerShell window instead of Windows Terminal.
    [switch]$Pwsh,

    # Print what would launch without spawning anything.
    [switch]$DryRun
)

$ErrorActionPreference = "Stop"

# Remote Control is ON unless the caller explicitly opts out with -Local.
$rcOn = -not $Local

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
# DEFAULT: `claude --remote-control <name>` = local session + phone/web control.
# -Local drops the flag for a pure local session.
$claudeTokens = @()
if ($rcOn) {
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
    if ($rcOn) { $modeStr = "LOCAL session + Remote Control (runs on this PC; also drive from phone/claude.ai)" }
    else { $modeStr = "LOCAL only (no phone pairing; resumable via 'claude --resume' from this directory)" }
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
    # New Windows Terminal window; -d sets the starting dir; -NoExit keeps the pane open
    # so the Remote Control pairing URL/QR stays readable.
    & $wtPath -w new -d "$resolved" powershell.exe -NoExit -Command $claudeCmd
} else {
    # Fallback: a plain new PowerShell window.
    $inner = "Set-Location -LiteralPath '$resolved'; $claudeCmd"
    Start-Process powershell.exe -ArgumentList @("-NoExit", "-Command", $inner) | Out-Null
}

if ($rcOn) {
    Write-Host "Spawned a LOCAL Claude session '$Name' WITH Remote Control in: $resolved"
    Write-Host "Runs on THIS PC (full local control - type in the window) AND drivable from the Claude mobile app / https://claude.ai/code - the new window shows the pairing URL/QR."
    Write-Host "Pass -Local next time if you want a pure local session with no phone pairing."
} else {
    Write-Host "Spawned a LOCAL-only Claude session in: $resolved (Remote Control disabled via -Local)"
    Write-Host "Reopen it later from a terminal in THIS directory via 'claude --resume' (pick it) or 'claude --continue' (most recent)."
}
