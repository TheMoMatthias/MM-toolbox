# session-requests.ps1 - extract the user's own turns from the current session transcript.
#
# The wrap-up skill uses this so the "what you asked for" section comes from evidence
# rather than recollection. After a compaction the original wording is the first thing
# lost from context; the transcript on disk still has all of it.
#
# PURE ASCII ONLY. Windows PowerShell 5.1 reads .ps1 as ANSI and a smart quote or an
# em-dash corrupts the parse.

[CmdletBinding()]
param(
    # Working directory whose project transcript we want. Defaults to the current directory.
    [string]$Directory = (Get-Location).Path,
    # Explicit .jsonl to read, bypassing slug derivation.
    [string]$TranscriptPath,
    # Cap the number of turns printed (0 = all).
    [int]$Limit = 0
)

$ErrorActionPreference = 'Stop'

function Resolve-Transcript {
    param([string]$Dir)

    $root = Join-Path $HOME '.claude\projects'
    if (-not (Test-Path $root)) {
        throw "No transcript root at $root"
    }

    # Claude Code slugifies the working directory by replacing ':', '\', '/' and spaces with '-'.
    #   C:\Users\me\Documents\My Repo  ->  C--Users-me-Documents-My-Repo
    $slug = $Dir -replace '[:\\/ ]', '-'
    $projectDir = Join-Path $root $slug

    if (-not (Test-Path $projectDir)) {
        Write-Host "No project dir for slug '$slug'." -ForegroundColor Yellow
        Write-Host "Candidates under ${root}:" -ForegroundColor Yellow
        Get-ChildItem $root -Directory |
            Sort-Object LastWriteTime -Descending |
            Select-Object -First 15 -ExpandProperty Name |
            ForEach-Object { Write-Host "  $_" }
        throw "Could not resolve a transcript directory. Pass -TranscriptPath explicitly."
    }

    # The most recently written .jsonl is the live session.
    $file = Get-ChildItem $projectDir -Filter *.jsonl -File |
        Sort-Object LastWriteTime -Descending |
        Select-Object -First 1

    if (-not $file) { throw "No .jsonl transcripts in $projectDir" }
    return $file
}

function Get-TurnText {
    param($Entry)

    $content = $Entry.message.content
    if ($null -eq $content) { return '' }

    if ($content -is [string]) {
        $text = $content
    } else {
        # Content is a block array. Keep text blocks; tool_result blocks are not user speech.
        $text = ($content |
            Where-Object { $_.type -eq 'text' } |
            ForEach-Object { $_.text }) -join "`n"
    }
    if (-not $text) { return '' }

    # Injected context is not something the user typed.
    $text = [regex]::Replace($text, '(?s)<system-reminder>.*?</system-reminder>', '')
    $text = [regex]::Replace($text, '(?s)<local-command-caveat>.*?</local-command-caveat>', '')
    $text = [regex]::Replace($text, '(?s)<command-message>.*?</command-message>', '')
    $text = [regex]::Replace($text, '(?s)<command-args>.*?</command-args>', '')
    $text = [regex]::Replace($text, '(?s)<local-command-stdout>.*?</local-command-stdout>', '')

    return $text.Trim()
}

if ($TranscriptPath) {
    if (-not (Test-Path $TranscriptPath)) { throw "No such transcript: $TranscriptPath" }
    $file = Get-Item $TranscriptPath
} else {
    $file = Resolve-Transcript -Dir $Directory
}

Write-Host "transcript : $($file.FullName)"
Write-Host "modified   : $($file.LastWriteTime)"
Write-Host ("-" * 72)

$n = 0
foreach ($line in [System.IO.File]::ReadLines($file.FullName)) {
    if (-not $line.Trim()) { continue }

    try { $entry = $line | ConvertFrom-Json } catch { continue }
    if ($entry.type -ne 'user') { continue }

    $text = Get-TurnText -Entry $entry
    if (-not $text) { continue }

    # Slash-command echoes and other harness chatter are not requests.
    if ($text -match '^\s*<command-name>') { continue }
    if ($text -match '^\s*Caveat: The messages below') { continue }

    $n++
    Write-Host ""
    Write-Host "[$n]" -ForegroundColor Cyan
    Write-Host $text

    if ($Limit -gt 0 -and $n -ge $Limit) {
        Write-Host ""
        Write-Host "(stopped at -Limit $Limit)"
        break
    }
}

Write-Host ""
Write-Host ("-" * 72)
Write-Host "$n user turn(s) recovered."
if ($n -eq 0) {
    Write-Host "ZERO turns recovered - report this in the wrap-up rather than falling back to recollection." -ForegroundColor Yellow
}
