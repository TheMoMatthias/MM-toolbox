# session-requests.ps1 - recover everything the user actually said this session.
#
# The wrap-up skill uses this so the report is built from evidence rather than recollection.
# After a compaction the original request wording is the first thing lost from context; the
# transcript on disk still has all of it.
#
# Transcript structure, measured rather than assumed - a user utterance reaches the log by
# TWO different routes and reading only the obvious one loses real requests:
#   type=user              normal submitted turns (content string, or a block array)
#   type=queue-operation   messages typed MID-TURN while the model was working
#                          (operation=enqueue, content is a plain string)
# Other types are noise for this purpose: last-prompt is a truncated UI breadcrumb,
# attachment/mode/system are harness bookkeeping.
#
# Three things arrive as type=user but are NOT the user speaking, and each is classified out
# rather than silently dropped - the suppressed counts are printed:
#   skill payloads    an invoked SKILL.md injected into the turn
#   carry-over        a compaction summary of an earlier context
#   command echoes    bare slash commands (/compact, /model)
# Carry-over is reported separately, never merely discarded: it is where the PREVIOUS
# context's unfinished business is recorded, and that is exactly what a wrap-up needs.
#
# PURE ASCII ONLY. Windows PowerShell 5.1 reads .ps1 as ANSI and a smart quote corrupts it.

[CmdletBinding()]
param(
    [string]$Directory = (Get-Location).Path,
    [string]$TranscriptPath,
    [switch]$IncludeCarryOver,
    [int]$TailLines = 45,
    [int]$Limit = 0,
    # A long session can hold a few enormous pasted messages. Truncate each request so total
    # output stays proportional to the NUMBER of requests, not to the longest paste.
    [int]$MaxChars = 600,
    [switch]$Full
)

$ErrorActionPreference = 'Stop'

function Resolve-Transcript {
    param([string]$Dir)
    $root = Join-Path $HOME '.claude\projects'
    if (-not (Test-Path $root)) { throw "No transcript root at $root" }

    # Claude Code slugifies the working directory: ':', '\', '/' and spaces all become '-'.
    #   C:\Users\me\Documents\My Repo  ->  C--Users-me-Documents-My-Repo
    $slug = $Dir -replace '[:\\/ ]', '-'
    $projectDir = Join-Path $root $slug
    if (-not (Test-Path $projectDir)) {
        Write-Host "No project dir for slug '$slug'. Candidates under ${root}:" -ForegroundColor Yellow
        Get-ChildItem $root -Directory | Sort-Object LastWriteTime -Descending |
            Select-Object -First 15 -ExpandProperty Name | ForEach-Object { Write-Host "  $_" }
        throw "Could not resolve a transcript. Pass -TranscriptPath explicitly."
    }
    $file = Get-ChildItem $projectDir -Filter *.jsonl -File |
        Sort-Object LastWriteTime -Descending | Select-Object -First 1
    if (-not $file) { throw "No .jsonl transcripts in $projectDir" }
    return $file
}

function Get-UserText {
    param($Entry)
    $content = $Entry.message.content
    if ($null -eq $content) { return '' }

    if ($content -is [string]) {
        $text = $content
    } else {
        # Block array: text blocks only. tool_result blocks are not user speech.
        $text = ($content | Where-Object { $_.type -eq 'text' } |
                 ForEach-Object { $_.text }) -join "`n"
    }
    if (-not $text) { return '' }

    foreach ($tag in 'system-reminder','local-command-caveat','command-message',
                     'command-args','local-command-stdout') {
        $text = [regex]::Replace($text, "(?s)<$tag>.*?</$tag>", '')
    }
    return $text.Trim()
}

function Get-Kind {
    param([string]$Text)
    # The turn queue carries harness traffic as well as the user: background-task
    # notifications and subagent reports are enqueued exactly like a typed message.
    # Measured on a 26-compaction session: 236 of 263 apparent requests were these.
    if ($Text -match '^\s*<(task-notification|agent-message|system-reminder|local-command[a-z-]*|command-[a-z]+)\b') { return 'system' }
    if ($Text -match '^Another Claude session sent a message:')             { return 'system' }
    if ($Text -match '^Base directory for this skill:')                     { return 'skill' }
    if ($Text -match '^This session is being continued from a previous')    { return 'carryover' }
    if ($Text -match '^\s*<command-name>')                                  { return 'command' }
    if ($Text -match '^/[A-Za-z][A-Za-z0-9_\-]*\s*$')                       { return 'command' }
    return 'request'
}

if ($TranscriptPath) {
    if (-not (Test-Path $TranscriptPath)) { throw "No such transcript: $TranscriptPath" }
    $file = Get-Item $TranscriptPath
} else {
    $file = Resolve-Transcript -Dir $Directory
}

$requests  = New-Object System.Collections.ArrayList
$carryover = New-Object System.Collections.ArrayList
$seen      = New-Object System.Collections.Generic.HashSet[string]
$nSkill = 0; $nCommand = 0; $nSystem = 0

foreach ($line in [System.IO.File]::ReadLines($file.FullName)) {
    if (-not $line.Trim()) { continue }
    try { $entry = $line | ConvertFrom-Json } catch { continue }

    $text = ''
    $queued = $false

    if ($entry.type -eq 'user') {
        $text = Get-UserText -Entry $entry
    } elseif ($entry.type -eq 'queue-operation' -and $entry.operation -eq 'enqueue') {
        # Typed while the model was mid-turn. Never appears as a type=user entry.
        if ($entry.content -is [string]) { $text = $entry.content.Trim() }
        $queued = $true
    } else {
        continue
    }
    if (-not $text) { continue }

    # Deliberately if/elseif, NOT switch: in PowerShell 'continue' inside a switch continues
    # the SWITCH, not the enclosing foreach, so classified entries fall through into the
    # request list while the counters still look correct. Measured, not theoretical.
    $kind = Get-Kind $text
    if     ($kind -eq 'skill')     { $nSkill++;   continue }
    elseif ($kind -eq 'system')    { $nSystem++;  continue }
    elseif ($kind -eq 'command')   { $nCommand++; continue }
    elseif ($kind -eq 'carryover') { [void]$carryover.Add($text); continue }

    # An enqueued message may also surface later as a normal turn. Count it once.
    $key = ($text -replace '\s+', ' ')
    if ($key.Length -gt 400) { $key = $key.Substring(0, 400) }
    if (-not $seen.Add($key)) { continue }

    [void]$requests.Add([pscustomobject]@{ Text = $text; Queued = $queued })
}

Write-Host "transcript : $($file.FullName)"
Write-Host "modified   : $($file.LastWriteTime)"

Write-Host ""
Write-Host "=== REQUESTS ===" -ForegroundColor Green
$n = 0
foreach ($r in $requests) {
    $n++
    $tag = if ($r.Queued) { "  (queued mid-turn)" } else { "" }
    Write-Host ""
    Write-Host "[$n]$tag" -ForegroundColor Cyan
    $body = $r.Text
    if (-not $Full -and $body.Length -gt $MaxChars) {
        $body = $body.Substring(0, $MaxChars) + "`n    ... [truncated; $($body.Length) chars total - use -Full]"
    }
    Write-Host $body
    if ($Limit -gt 0 -and $n -ge $Limit) { Write-Host ""; Write-Host "(stopped at -Limit $Limit)"; break }
}

if ($carryover.Count -gt 0) {
    Write-Host ""
    Write-Host "=== CARRY-OVER FROM EARLIER CONTEXT ===" -ForegroundColor Green
    Write-Host "$($carryover.Count) compaction summary block(s). This session did not start empty:"
    Write-Host "work already unfinished BEFORE a compaction is recorded here, not in REQUESTS."
    # Each summary folds in the ones before it, so the LAST is the authoritative one. Printing
    # all of them buries the report in its own evidence - one session here had 26.
    $blocks = if ($IncludeCarryOver) { $carryover } else { @($carryover[$carryover.Count - 1]) }
    if (-not $IncludeCarryOver -and $carryover.Count -gt 1) {
        Write-Host "Showing the LAST only; it supersedes the earlier $($carryover.Count - 1). -IncludeCarryOver for all."
    }
    foreach ($c in $blocks) {
        Write-Host ""
        Write-Host "--- block ($($c.Length) chars) ---" -ForegroundColor Cyan
        $lines = $c -split "`n"
        if (-not $IncludeCarryOver -and $lines.Count -gt $TailLines) {
            Write-Host "(tail $TailLines of $($lines.Count) lines)"
            Write-Host (($lines | Select-Object -Last $TailLines) -join "`n")
        } else {
            Write-Host $c
        }
    }
}

Write-Host ""
Write-Host "=== SUPPRESSED (not user speech) ===" -ForegroundColor Green
Write-Host "skill payloads : $nSkill"
Write-Host "harness traffic: $nSystem   (task notifications, subagent reports)"
Write-Host "command echoes : $nCommand"

Write-Host ""
Write-Host "$($requests.Count) request(s), $($carryover.Count) carry-over block(s)."
if ($requests.Count -eq 0) {
    Write-Host "ZERO requests recovered - report this in the wrap-up rather than falling back to recollection." -ForegroundColor Yellow
}
