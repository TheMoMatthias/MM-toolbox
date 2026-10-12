# Find and resume Pi sessions by durable display name or session ID.
# Keep this file ASCII: Windows PowerShell 5.1 may read scripts as ANSI.

[CmdletBinding()]
param(
    [string]$Name = "",
    [string]$SessionId = "",
    [string]$Directory = "",
    [switch]$List,
    [switch]$DryRun,
    [switch]$Pwsh,
    [string]$SessionRoot = (Join-Path $env:USERPROFILE ".pi\agent\sessions")
)

$ErrorActionPreference = "Stop"

function Stop-Recovery {
    param([string]$Message)
    Write-Error ("spawn-session recovery: " + $Message)
    exit 1
}

function Get-PiSessionRecord {
    param([string]$Path)
    try {
        $header = $null
        $latestName = ""
        foreach ($line in Get-Content -LiteralPath $Path -Encoding UTF8) {
            if ([string]::IsNullOrWhiteSpace($line)) { continue }
            $entry = $line | ConvertFrom-Json -ErrorAction Stop
            if ($null -eq $header -and $entry.type -eq "session") { $header = $entry }
            if ($entry.type -eq "session_info" -and -not [string]::IsNullOrWhiteSpace([string]$entry.name)) {
                $latestName = [string]$entry.name
            }
        }
        if ($null -eq $header -or [string]::IsNullOrWhiteSpace([string]$header.id)) { return $null }
        return [pscustomobject]@{
            Id = [string]$header.id
            Name = $latestName
            Directory = [string]$header.cwd
            Path = $Path
            Updated = (Get-Item -LiteralPath $Path).LastWriteTime
        }
    } catch {
        Write-Warning ("Skipping unreadable Pi session '" + $Path + "': " + $_.Exception.Message)
        return $null
    }
}

if (-not (Test-Path -LiteralPath $SessionRoot -PathType Container)) {
    Stop-Recovery "session root not found -> $SessionRoot"
}

$resolvedDirectory = ""
if (-not [string]::IsNullOrWhiteSpace($Directory)) {
    try { $resolvedDirectory = (Resolve-Path -LiteralPath $Directory -ErrorAction Stop).Path }
    catch { Stop-Recovery "directory not found -> $Directory" }
}

$records = @(
    Get-ChildItem -LiteralPath $SessionRoot -Filter "*.jsonl" -Recurse -File -ErrorAction SilentlyContinue |
        ForEach-Object { Get-PiSessionRecord $_.FullName } |
        Where-Object { $null -ne $_ }
)

if (-not [string]::IsNullOrWhiteSpace($SessionId)) {
    $records = @($records | Where-Object { $_.Id.StartsWith($SessionId, [System.StringComparison]::OrdinalIgnoreCase) })
}
if (-not [string]::IsNullOrWhiteSpace($Name)) {
    $records = @($records | Where-Object { $_.Name -eq $Name })
}
if ($resolvedDirectory) {
    $records = @($records | Where-Object { $_.Directory -eq $resolvedDirectory })
}
$records = @($records | Sort-Object Updated -Descending)

if ($List) {
    if ($records.Count -eq 0) {
        Write-Host "No matching Pi sessions found."
        exit 0
    }
    $records | Select-Object Updated, Name, Id, Directory, Path | Format-Table -AutoSize
    exit 0
}

if ([string]::IsNullOrWhiteSpace($Name) -and [string]::IsNullOrWhiteSpace($SessionId)) {
    Stop-Recovery "pass -Name or -SessionId, or use -List."
}
if ($records.Count -eq 0) {
    Stop-Recovery "no matching Pi session found. Pi's -r picker is project-scoped; pass the original -Directory or use -List to search all projects."
}
if ($records.Count -gt 1 -and [string]::IsNullOrWhiteSpace($SessionId)) {
    Write-Host "AMBIGUOUS  : multiple sessions have this name. Re-run with -SessionId using one row below." -ForegroundColor Yellow
    $records | Select-Object Updated, Name, Id, Directory, Path | Format-Table -AutoSize
    exit 2
}

$target = $records[0]
$running = @(
    Get-CimInstance Win32_Process -Filter "Name='node.exe'" -ErrorAction SilentlyContinue |
        Where-Object { [string]$_.CommandLine -match ([regex]::Escape("--session " + $target.Id)) }
)
if ($running.Count -gt 0) {
    Write-Host ("ALREADY RUNNING: " + $target.Name + " (" + $target.Id + ")") -ForegroundColor Yellow
    Write-Host ("Process id : " + (($running | Select-Object -ExpandProperty ProcessId) -join ", "))
    Write-Host ("Directory  : " + $target.Directory)
    exit 0
}

Write-Host ("Session    : " + $target.Name)
Write-Host ("Session id : " + $target.Id)
Write-Host ("Directory  : " + $target.Directory)
Write-Host ("Session file: " + $target.Path)
Write-Host ("RESUME     : pi --session " + $target.Id)
if ($DryRun) { exit 0 }

$pi = Get-Command pi -ErrorAction SilentlyContinue
if ($null -eq $pi) { Stop-Recovery "pi executable was not found on PATH." }
$wt = Get-Command wt.exe -ErrorAction SilentlyContinue
if ($null -ne $wt -and -not $Pwsh) {
    & $wt.Source -w spawn-session new-tab --title $target.Name -d $target.Directory powershell.exe -NoExit -NoProfile -Command "pi --session $($target.Id)"
} else {
    Start-Process powershell.exe -WorkingDirectory $target.Directory -ArgumentList @("-NoExit", "-NoProfile", "-Command", "pi --session $($target.Id)") | Out-Null
}
Write-Host "RELAUNCHED : exact persisted Pi session."
