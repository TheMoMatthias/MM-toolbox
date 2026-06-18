# spawn.ps1 — launch a NEW Claude Code session in a new terminal.
#
# Backs the `spawn-claude-session` skill. Opens a fresh Windows Terminal window
# (falls back to a plain PowerShell window when wt.exe is absent), starts in the
# requested directory (default = caller's cwd, i.e. the directory the current
# conversation runs in), and launches `claude`.
#
# DEFAULT = a LOCAL, RESUMABLE session: it writes a transcript (<id>.jsonl) into
# the project folder for that directory, so the chat's "memory" survives and you
# can reopen it later from any terminal in the SAME directory via
# `claude --resume` (pick it) / `claude --continue` (most recent).
#
# -RemoteControl is OPT-IN: it adds `--remote-control <name>` so you can drive the
# session from the Claude mobile app / claude.ai. Caveat (lesson 2026-06-16): a
# remote-DRIVEN conversation's history lives in the cloud and may NOT leave a
# locally-resumable transcript — use it only when you want phone control, not when
# you want a resumable local chat. The window is kept open (-NoExit) so the
# Remote Control pairing URL / QR code stays readable.
#
# Verified surface (claude --help on this machine):
#   --remote-control [name]   Start an interactive session with Remote Control enabled
#   --model <model>           Model alias or full id
# There is NO `claude remote-control` subcommand and NO `--rc` shorthand — do not use them.

[CmdletBinding()]
param(
    # Working directory for the new session. Defaults to the caller's cwd.
    [Parameter(Position = 0)]
    [string]$Directory = (Get-Location).Path,

    # Remote Control session display name (shown in claude.ai/code + mobile).
    # Auto-derived from the leaf dir + timestamp when omitted.
    [Parameter(Position = 1)]
    [string]$Name = "",

    # Optional model alias (e.g. 'opus', 'sonnet') for the spawned session.
    [string]$Model = "",

    # Enable Remote Control (drive from phone / claude.ai). OPT-IN: a remote-driven
    # chat may NOT be locally resumable. Default is a resumable LOCAL session.
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
# only when -RemoteControl is passed (cloud-driven; may not be locally resumable).
$claudeTokens = @()
if ($RemoteControl) {
    $claudeTokens += @("--remote-control", $Name)
}
if (-not [string]::IsNullOrWhiteSpace($Model)) {
    $claudeTokens += @("--model", $Model)
}
$claudeCmd = "claude " + (($claudeTokens | ForEach-Object {
    if ($_ -match '\s') { '"' + $_ + '"' } else { $_ }
}) -join ' ')

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
    Write-Host "Directory : $resolved"
    Write-Host "Session   : $Name"
    if ($Model) { Write-Host "Model     : $Model" }
    Write-Host "Command   : $claudeCmd"
    Write-Host ("Mode      : " + $(if ($RemoteControl) { "Remote Control (cloud-driven; may NOT be locally resumable)" } else { "Local (resumable via 'claude --resume' from this directory)" }))
    Write-Host ("Launcher  : " + $(if ($useWt) { "Windows Terminal (wt.exe)" } else { "PowerShell window" }))
    exit 0
}

if ($useWt) {
    # New Windows Terminal window; -d sets the starting dir; -NoExit keeps the
    # pane open after claude exits so the Remote Control URL/QR stays visible.
    & $wtPath -w new -d "$resolved" powershell.exe -NoExit -Command $claudeCmd
} else {
    # Fallback: a plain new PowerShell window.
    $inner = "Set-Location -LiteralPath '$resolved'; $claudeCmd"
    Start-Process powershell.exe -ArgumentList @("-NoExit", "-Command", $inner) | Out-Null
}

if ($RemoteControl) {
    Write-Host "Spawned Claude session '$Name' (Remote Control) in: $resolved"
    Write-Host "Connect from the Claude mobile app or https://claude.ai/code - the new window shows the pairing URL/QR."
    Write-Host "NOTE: a remote-DRIVEN conversation lives in the cloud and may NOT be resumable from a local terminal."
} else {
    Write-Host "Spawned a LOCAL Claude session in: $resolved"
    Write-Host "It writes a resumable transcript here - reopen later from a terminal in THIS directory via 'claude --resume' (pick it) or 'claude --continue' (most recent)."
}
