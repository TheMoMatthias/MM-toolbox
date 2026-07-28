# spawn.ps1 - launch a NEW Claude Code session in a new terminal.
#
# Backs the `spawn-claude-session` skill. Opens a fresh Windows Terminal window
# (falls back to a plain PowerShell window when wt.exe is absent), starts in the
# requested directory, launches `claude` with Remote Control enabled, and hands it a
# handover / opening prompt.
#
# ############################################################################
# THE ROOT CAUSE OF "THE SPAWNED SESSION LOST ITS HISTORY"  (measured 2026-07-28,
# claude v2.1.220) - THE INHERITED CHILD-SESSION ENVIRONMENT.
# ############################################################################
# spawn.ps1 always runs from INSIDE a Claude session, and that session's shell
# exports:
#     CLAUDE_CODE_CHILD_SESSION=1
#     CLAUDE_CODE_SESSION_ID=<the PARENT session's id>
#     CLAUDECODE=1 / CLAUDE_CODE_ENTRYPOINT / CLAUDE_PID / CLAUDE_CODE_SSE_PORT
# Those are INHERITED by every process it launches - through wt.exe, through
# powershell.exe, into `claude`. A claude that starts with them set is treated as a
# CHILD session and writes NO transcript of its own, so `claude --resume` can never
# find it and the whole conversation is lost when the window closes.
#
# MEASURED, two launches identical except the environment:
#     env inherited -> NO .jsonl at all after 12 minutes
#     env scrubbed  -> .jsonl containing a real assistant turn after 5 SECONDS
#
# THE FIX: the generated boot script deletes those variables before running claude.
# That is the whole bug. It hit EVERY spawned session, Remote Control or not.
#
# ---------------------------------------------------------------------------
# REFUTED - do not re-derive it (it cost a long investigation on 2026-07-28):
#   "`--remote-control <name>` at launch makes the session bridge-born, so its
#    conversation lives on the bridge and cannot be resumed locally."
#   FALSE. It looked true because every Remote-Control session on this machine had
#   been SPAWNED (dirty env) while every session with a healthy transcript had been
#   hand-started in a terminal (clean env) - the environment was the hidden variable,
#   perfectly confounded with the flag.
#   CONTROLLED TEST: clean env + `--remote-control` at launch produced a transcript
#   holding the real user prompt, the real assistant reply, AND the bridge-session
#   marker. Remote Control does NOT cost local persistence. Keep the flag.
# ---------------------------------------------------------------------------
#
# NOTE: keep this file pure ASCII. Windows PowerShell 5.1 reads .ps1 as ANSI, so a
# non-ASCII char (em-dash, smart quote) corrupts the parse. Use '-' not a long dash.

[CmdletBinding()]
param(
    # Working directory for the new session. CHOOSE the repo explicitly, or omit to
    # smart-detect the caller's cwd.
    [Parameter(Position = 0)]
    [string]$Directory = (Get-Location).Path,

    # Session display name. Used for `claude -n <name>` (labels the `--resume` picker
    # and the terminal title) and as the Remote Control session name.
    [Parameter(Position = 1)]
    [string]$Name = "",

    # OPENING PROMPT / first task for the new session.
    # A session that never takes a turn does no work and dies with its window.
    # Delivered via a bootstrap script + file, never through `-Command`, so quotes,
    # parens and `$` in the text can never be re-parsed as PowerShell syntax.
    [Parameter(Position = 2)]
    [string]$Prompt = "",

    # HANDOVER FILE(S) to brief the new session with - the normal way to use this.
    # Each path is validated HERE (fail fast, before a window opens) and referenced by
    # ABSOLUTE PATH in the opening prompt, so the file stays the single source of truth
    # and the prompt stays small. Comma-separated / repeatable.
    [string[]]$HandoffFile = @(),

    # Optional model alias (e.g. 'opus', 'sonnet') for the spawned session.
    [string]$Model = "",

    # Opt OUT of Remote Control -> plain local session, no phone pairing.
    # (Resumability is identical either way - this only drops the phone channel.)
    [Alias("NoRemoteControl")]
    [switch]$Local,

    # Back-compat / explicit affirm: Remote Control is the default. Ignored with -Local.
    [Alias("Rc")]
    [switch]$RemoteControl,

    # Force a plain PowerShell window instead of Windows Terminal.
    [switch]$Pwsh,

    # Seconds to wait for the transcript to appear with a real turn. With the env
    # scrub in place this normally lands in under 10s; the generous default only
    # covers a slow first turn.
    [int]$TurnTimeoutSec = 180,

    # Print what would launch without spawning anything.
    [switch]$DryRun
)

$ErrorActionPreference = "Stop"

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

# --- Validate handover files BEFORE opening a window (fail fast) --------------
$handoffAbs = @()
foreach ($h in $HandoffFile) {
    if ([string]::IsNullOrWhiteSpace($h)) { continue }
    try {
        $hp = (Resolve-Path -LiteralPath $h).Path
    } catch {
        Write-Error "spawn-claude-session: handover file not found -> $h"
        exit 1
    }
    if (Test-Path -LiteralPath $hp -PathType Container) {
        Write-Error "spawn-claude-session: handover path is a directory, not a file -> $hp"
        exit 1
    }
    $handoffAbs += $hp
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

# --- Pre-assign the session id so the resume command is known up front --------
# `--session-id <uuid>` is honoured at launch, so we never have to guess which new
# .jsonl is ours (the old version diffed a directory listing and raced).
$sessionId  = [guid]::NewGuid().ToString()
$slug       = $resolved -replace '[^A-Za-z0-9]', '-'
$projDir    = Join-Path $env:USERPROFILE ".claude\projects\$slug"
$transcript = Join-Path $projDir "$sessionId.jsonl"

# --- Build the inner `claude` command ----------------------------------------
$claudeTokens = @("-n", $Name, "--session-id", $sessionId)
if ($rcOn) { $claudeTokens += @("--remote-control", $Name) }
if (-not [string]::IsNullOrWhiteSpace($Model)) {
    $claudeTokens += @("--model", $Model)
}
$claudeCmd = ("claude " + (($claudeTokens | ForEach-Object {
    if ($_ -match '\s') { '"' + $_ + '"' } else { $_ }
}) -join ' ')).Trim()

# --- Compose the opening prompt (handover briefing + caller's prompt) ---------
$promptParts = @()
if ($handoffAbs.Count -gt 0) {
    $promptParts += "HANDOVER: you are a fresh session continuing existing work. Before anything else, read the following file(s) end-to-end - they are your briefing from the session that spawned you:"
    $n = 1
    foreach ($hp in $handoffAbs) { $promptParts += ("  " + $n + ". " + $hp); $n++ }
    $promptParts += "Treat them as the authoritative account of the work: its current state, the decisions already made, and what to do next. Follow the paths and links they reference rather than re-deriving context."
    $promptParts += ""
}
if (-not [string]::IsNullOrWhiteSpace($Prompt)) { $promptParts += $Prompt }
$fullPrompt = ($promptParts -join "`n").Trim()

if ([string]::IsNullOrWhiteSpace($fullPrompt)) {
    Write-Warning "spawn-claude-session: no -Prompt and no -HandoffFile. The session will sit idle doing nothing. Pass -HandoffFile and/or -Prompt."
}
if ($fullPrompt) { $claudeCmd += ' <opening prompt, from file>' }

# --- Bootstrap: scrub the environment, then feed the prompt from a FILE --------
# `powershell.exe -Command` joins its argv tokens back into ONE script string and
# RE-PARSES it, stripping the quoting the parent shell added. Prompt text containing
# ( ) ; or $ then executes as PowerShell: on 2026-07-28 "(S4 first)" became a
# subexpression and the window died on "The term 'S4' is not recognized".
# So: prompt -> .txt, a boot .ps1 that reads it, launch with `-File <path>`.
# A PATH is never parsed as code. This is the only safe shape.
$bootDir = Join-Path $env:TEMP (Join-Path 'claude-spawn' $Name)
New-Item -ItemType Directory -Force -Path $bootDir | Out-Null
$promptPath = Join-Path $bootDir 'prompt.txt'
$bootPath   = Join-Path $bootDir 'boot.ps1'
$utf8NoBom  = New-Object System.Text.UTF8Encoding($false)

$argLiterals = ($claudeTokens | ForEach-Object { "'" + ($_ -replace "'", "''") + "'" }) -join ', '
$bootLines = @(
    '# Auto-generated by spawn-claude-session.',
    '',
    '# ---- SCRUB THE INHERITED CLAUDE ENVIRONMENT - THIS IS THE WHOLE FIX --------',
    '# The spawning session exports CLAUDE_CODE_CHILD_SESSION=1 and its own session',
    '# id, and every child process inherits them. A claude started with those set is',
    '# treated as a CHILD session and writes NO transcript, so `claude --resume`',
    '# cannot find it. MEASURED 2026-07-28: identical launches, env inherited = no',
    '# .jsonl after 12 minutes; env scrubbed = .jsonl with a real turn in 5 seconds.',
    'foreach ($v in @(''CLAUDE_CODE_CHILD_SESSION'',''CLAUDE_CODE_SESSION_ID'',''CLAUDECODE'',''CLAUDE_CODE_ENTRYPOINT'',''CLAUDE_PID'',''CLAUDE_CODE_SSE_PORT'')) {',
    '    if (Test-Path ("Env:\" + $v)) { Remove-Item ("Env:\" + $v) -Force }',
    '}',
    '',
    '# The opening prompt is read from a sibling file so no prompt text ever crosses',
    '# a shell boundary as syntax.',
    ('$claudeArgs = @(' + $argLiterals + ')'),
    ('$promptPath = ' + "'" + ($promptPath -replace "'", "''") + "'"),
    'if (Test-Path -LiteralPath $promptPath) {',
    '    $p = (Get-Content -Raw -LiteralPath $promptPath).Trim()',
    '    if ($p) { $claudeArgs += $p }',
    '}',
    'claude @claudeArgs'
)
[System.IO.File]::WriteAllLines($bootPath, [string[]]$bootLines, $utf8NoBom)
if ($fullPrompt) {
    [System.IO.File]::WriteAllText($promptPath, $fullPrompt, $utf8NoBom)
} elseif (Test-Path -LiteralPath $promptPath) {
    Remove-Item -LiteralPath $promptPath -Force
}

# --- Pick the launcher --------------------------------------------------------
# Resolve wt.exe robustly: Get-Command misses the WindowsApps execution-alias
# (a reparse point not always on a child shell's PATH), so fall back to the
# known alias location and invoke by full path.
# Windows Terminal is strongly preferred: a plain PowerShell window started from a
# non-interactive parent has repeatedly failed to give `claude` a usable console -
# the session starts but never submits its opening prompt.
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
    if ($rcOn) { $modeStr = "LOCAL session + Remote Control (runs on this PC; also drivable from phone/claude.ai) - and locally resumable" }
    else       { $modeStr = "LOCAL only (-Local): no phone pairing" }
    if ($useWt) { $launcherStr = "Windows Terminal (wt.exe)" } else { $launcherStr = "PowerShell window" }
    Write-Host "Directory  : $resolved"
    Write-Host "Session    : $Name"
    Write-Host "Session id : $sessionId"
    Write-Host "Transcript : $transcript"
    if ($Model) { Write-Host "Model      : $Model" }
    foreach ($hp in $handoffAbs) { Write-Host "Handover   : $hp" }
    Write-Host "Command    : $claudeCmd"
    Write-Host "Mode       : $modeStr"
    Write-Host "Launcher   : $launcherStr"
    Write-Host "Env scrub  : CLAUDE_CODE_CHILD_SESSION, CLAUDE_CODE_SESSION_ID, CLAUDECODE, CLAUDE_CODE_ENTRYPOINT, CLAUDE_PID, CLAUDE_CODE_SSE_PORT"
    Write-Host ""
    Write-Host "--- opening prompt ---"
    Write-Host $fullPrompt
    exit 0
}

if ($useWt) {
    # New Windows Terminal window; -d sets the starting dir; -NoExit keeps the pane
    # open so the Remote Control pairing URL/QR stays readable.
    & $wtPath -w new -d "$resolved" powershell.exe -NoExit -NoProfile -ExecutionPolicy Bypass -File "$bootPath"
} else {
    Write-Warning "spawn-claude-session: wt.exe not available - falling back to a plain PowerShell window. The session may fail to submit its opening prompt in this mode."
    Start-Process powershell.exe -ArgumentList @("-NoExit", "-NoProfile", "-ExecutionPolicy", "Bypass", "-File", "$bootPath") -WorkingDirectory $resolved | Out-Null
}

# --- VERIFY - the launch call can only confirm an ATTEMPT ---------------------
# Printing success on the strength of having ISSUED the launch is how a spawned
# session went missing on 2026-07-28. Proof is (1) a live `claude.exe` (a NATIVE
# binary - filtering for node.exe finds nothing and looks like failure) carrying OUR
# session id, and (2) a transcript at the KNOWN path containing a real assistant
# turn - which is exactly what `claude --resume` reads.
$proc = $null
for ($i = 0; $i -lt 9; $i++) {
    Start-Sleep -Seconds 5
    $proc = Get-CimInstance Win32_Process -Filter "Name='claude.exe'" -ErrorAction SilentlyContinue |
            Where-Object { $_.CommandLine -like "*$sessionId*" } | Select-Object -First 1
    if ($proc) { break }
}
if (-not $proc) {
    Write-Warning "spawn-claude-session: NO claude.exe carrying session id $sessionId appeared within 45s. The window is open but the session did NOT start - check it for an error. Boot script: $bootPath"
}

$turns = 0
$rcAttached = $false
if ($proc -and $fullPrompt) {
    $deadline = (Get-Date).AddSeconds($TurnTimeoutSec)
    while ((Get-Date) -lt $deadline) {
        Start-Sleep -Seconds 3
        if (Test-Path -LiteralPath $transcript) {
            $turns = @(Select-String -LiteralPath $transcript -Pattern '"type":"assistant"' -ErrorAction SilentlyContinue).Count
            if ($turns -gt 0) { break }
        }
    }
}
if (Test-Path -LiteralPath $transcript) {
    $rcAttached = @(Select-String -LiteralPath $transcript -Pattern '"type":"bridge-session"' -ErrorAction SilentlyContinue).Count -gt 0
}

# --- Report -------------------------------------------------------------------
Write-Host ""
Write-Host "Session    : $Name"
Write-Host "Session id : $sessionId"
Write-Host "Directory  : $resolved"
foreach ($hp in $handoffAbs) { Write-Host "Handover   : $hp" }

if ($proc)  { Write-Host "VERIFIED   : claude.exe pid $($proc.ProcessId) is running with this session id." }
if ($turns -gt 0) {
    Write-Host "VERIFIED   : transcript on disk with $turns conversation turn(s) - THIS SESSION IS RESUMABLE."
    Write-Host "             $transcript"
} elseif ($proc -and $fullPrompt) {
    Write-Warning "NO conversation turn on disk after ${TurnTimeoutSec}s. Expected at $transcript . If this file never appears, the environment scrub in $bootPath did not take effect - the session will NOT be resumable."
}

Write-Host ""
Write-Host "RESUME     : claude --resume $sessionId       (from a terminal in $resolved)"
Write-Host "             or run 'claude --resume' there and pick '$Name'."

if ($rcOn) {
    if ($rcAttached) { Write-Host "VERIFIED   : Remote Control active - drive it from the Claude mobile app / https://claude.ai/code . The new window shows the pairing URL/QR." }
    else             { Write-Host "NOTE       : Remote Control was requested; the pairing marker is not in the transcript yet. Check the new window for the pairing URL/QR (or run /remote-control there)." }
} else {
    Write-Host "Remote Control disabled (-Local): local session only, no phone pairing."
}
