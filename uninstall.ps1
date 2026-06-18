# uninstall.ps1 - Remove MM-toolbox symlinks from ~/.claude/.
# Walks the same items as install.ps1 (top-level files, hooks files, skill dirs, agent files)
# and removes any symlink whose target lives inside this repo.
# With a backup dir (auto-detected from .pre-mmtoolbox-backup-*) it restores originals.

param(
    [string]$ClaudeHome = "$env:USERPROFILE\.claude",
    [string]$BackupDir,
    [switch]$NoRestore,
    [switch]$Force
)

$ErrorActionPreference = 'Stop'
$RepoRoot = (Split-Path -Parent $PSCommandPath)

# Auto-resolve backup if none specified
if (-not $BackupDir -and -not $NoRestore) {
    $candidates = Get-ChildItem -LiteralPath $ClaudeHome -Directory -Filter '.pre-mmtoolbox-backup-*' -ErrorAction SilentlyContinue |
                  Sort-Object -Property LastWriteTime -Descending
    if ($candidates) {
        $BackupDir = $candidates[0].FullName
        Write-Host "[uninstall] Auto-selected backup: $BackupDir"
    } elseif (-not $Force) {
        Write-Warning "No backup dir found under $ClaudeHome. Pass -NoRestore (or -Force) to proceed without restoration."
        return
    }
}

# Remove a link at $Target if it points into (or hardlinks into) $RepoRoot.
# Handles SymbolicLink + Junction (via ReparsePoint) AND HardLink (via fsutil).
function Remove-IfRepoLink {
    param([string]$Target)
    if (-not (Test-Path -LiteralPath $Target)) { return }
    $item = Get-Item -LiteralPath $Target -Force
    $isReparse = ($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -eq [System.IO.FileAttributes]::ReparsePoint

    if ($isReparse) {
        $cur = $item.Target
        $curStr = if ($cur) { $cur[0] } else { '' }
        if ($curStr -and ($curStr.StartsWith($RepoRoot, [System.StringComparison]::OrdinalIgnoreCase))) {
            Write-Host "[remove-link] $Target -> $curStr"
            if ($item.PSIsContainer) { $item.Delete() } else { Remove-Item -LiteralPath $Target -Force }
        } else {
            Write-Warning "[skip] $Target is a link, but not to this repo ($curStr); leaving alone."
        }
        return
    }

    # Not a symlink/junction. If it's a file, check whether it's a hardlink that also lives in the repo.
    if (-not $item.PSIsContainer) {
        try {
            $links = & fsutil.exe hardlink list $Target 2>$null
            $repoRef = $links | Where-Object { $_ -and $_.StartsWith($RepoRoot, [System.StringComparison]::OrdinalIgnoreCase) }
            if ($repoRef) {
                Write-Host "[remove-hardlink] $Target  (hardlinked to $repoRef)"
                Remove-Item -LiteralPath $Target -Force
            }
        } catch {
            # fsutil unavailable; leave alone
        }
    }
}

# Top-level files
Remove-IfRepoLink "$ClaudeHome\CLAUDE.md"
Remove-IfRepoLink "$ClaudeHome\keybindings.json"

# Hooks (only the ones MM-toolbox provides)
if (Test-Path "$RepoRoot\hooks") {
    Get-ChildItem -LiteralPath "$RepoRoot\hooks" -File | ForEach-Object {
        if ($_.Name -ieq 'README.md') { return }
        Remove-IfRepoLink (Join-Path "$ClaudeHome\hooks" $_.Name)
    }
}

# Skills (categorized -> flat)
if (Test-Path "$RepoRoot\skills") {
    Get-ChildItem -LiteralPath "$RepoRoot\skills" -Directory | ForEach-Object {
        Get-ChildItem -LiteralPath $_.FullName -Directory | ForEach-Object {
            Remove-IfRepoLink (Join-Path "$ClaudeHome\skills" $_.Name)
        }
    }
}

# Agents (categorized -> flat)
if (Test-Path "$RepoRoot\agents") {
    Get-ChildItem -LiteralPath "$RepoRoot\agents" -Directory | ForEach-Object {
        Get-ChildItem -LiteralPath $_.FullName -File -Filter '*.md' | ForEach-Object {
            if ($_.Name -ieq 'README.md') { return }
            Remove-IfRepoLink (Join-Path "$ClaudeHome\agents" $_.Name)
        }
    }
}

# Restore originals from backup if available
if ($BackupDir -and (Test-Path -LiteralPath $BackupDir)) {
    Write-Host "[restore] from $BackupDir"
    # Recursively move everything from backup into ClaudeHome (preserving structure)
    Get-ChildItem -LiteralPath $BackupDir -Recurse -Force | Where-Object { -not $_.PSIsContainer } | ForEach-Object {
        $rel = $_.FullName.Substring($BackupDir.Length).TrimStart('\','/')
        $dst = Join-Path $ClaudeHome $rel
        $dstParent = Split-Path -Parent $dst
        if (-not (Test-Path -LiteralPath $dstParent)) {
            New-Item -ItemType Directory -Path $dstParent -Force | Out-Null
        }
        if (Test-Path -LiteralPath $dst) {
            Write-Warning "[restore-skip] $dst already exists; not overwriting."
            return
        }
        Write-Host "[restore] $($_.FullName) -> $dst"
        Move-Item -LiteralPath $_.FullName -Destination $dst -Force
    }
    # Clean up empty backup dirs
    Get-ChildItem -LiteralPath $BackupDir -Recurse -Directory -Force |
        Sort-Object -Property FullName -Descending |
        ForEach-Object {
            if (-not (Get-ChildItem -LiteralPath $_.FullName -Force | Select-Object -First 1)) {
                Remove-Item -LiteralPath $_.FullName -Force
            }
        }
    if (-not (Get-ChildItem -LiteralPath $BackupDir -Force | Select-Object -First 1)) {
        Remove-Item -LiteralPath $BackupDir -Force
    }
}

Write-Host ""
Write-Host "[done] MM-toolbox uninstalled."
if (-not $BackupDir) {
    Write-Host "[note] No backup was restored. The MM-toolbox repo at $RepoRoot still has all your assets."
}
