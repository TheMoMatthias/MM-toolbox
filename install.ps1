# install.ps1 - Install MM-toolbox by symlinking each asset into ~/.claude/.
# Idempotent. Backs up replaced originals to ~/.claude/.pre-mmtoolbox-backup-<timestamp>/.
# Requires Windows Developer Mode (for symlinks without admin) OR Administrator.
# Falls back to Junction for directories if SymbolicLink fails.
#
# Why item-by-item: Claude Code expects FLAT layouts under ~/.claude/skills/<skill>
# and ~/.claude/agents/<agent>.md. MM-toolbox keeps a CATEGORIZED layout in the repo
# (skills/workflow/<skill>, agents/core/<agent>.md). install.ps1 bridges the two:
# each skill/agent is symlinked back to the flat ~/.claude/ location it expects.
# This also leaves any existing items in ~/.claude/hooks/skills/agents that AREN'T
# in MM-toolbox (e.g. ~/.claude/hooks/verify-loop.ps1) UNTOUCHED.

param(
    [switch]$Force,
    [string]$ClaudeHome = "$env:USERPROFILE\.claude",

    # Skip the session-restore tool (logon task + desktop button + cc/ccr shell
    # functions). Everything else installs as normal.
    [switch]$NoSessionRestore
)

$ErrorActionPreference = 'Stop'

$RepoRoot = Split-Path -Parent $PSCommandPath
Write-Host "[install] MM-toolbox at: $RepoRoot"
Write-Host "[install] Claude home:   $ClaudeHome"

if (-not (Test-Path "$RepoRoot\CLAUDE.md") -or -not (Test-Path "$RepoRoot\skills")) {
    throw "RepoRoot does not look like an MM-toolbox checkout: $RepoRoot"
}
if (-not (Test-Path $ClaudeHome)) { New-Item -ItemType Directory -Path $ClaudeHome -Force | Out-Null }

# Ensure standard subdirs exist as REAL dirs in ClaudeHome (we link INTO them).
foreach ($d in @('hooks', 'skills', 'agents')) {
    $p = Join-Path $ClaudeHome $d
    if (-not (Test-Path -LiteralPath $p)) {
        New-Item -ItemType Directory -Path $p -Force | Out-Null
    } else {
        $item = Get-Item -LiteralPath $p -Force
        $isLink = ($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -eq [System.IO.FileAttributes]::ReparsePoint
        if ($isLink) {
            throw "$p is currently a symlink/junction. Run uninstall.ps1 first, or remove the link manually."
        }
    }
}

$Stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$Backup = "$ClaudeHome\.pre-mmtoolbox-backup-$Stamp"
$BackupCreated = $false

function Ensure-Backup {
    if (-not $script:BackupCreated) {
        New-Item -ItemType Directory -Path $Backup -Force | Out-Null
        Write-Host "[backup] $Backup"
        $script:BackupCreated = $true
    }
}

# Link one item: $Source (in repo) -> $Target (in ClaudeHome).
# $Kind is 'File' or 'Dir' (controls symlink fallback).
function Link-One {
    param([string]$Source, [string]$Target, [string]$Kind)

    if (-not (Test-Path -LiteralPath $Source)) {
        Write-Warning "[missing] source not found: $Source"
        return
    }
    if (Test-Path -LiteralPath $Target) {
        $item = Get-Item -LiteralPath $Target -Force
        $isLink = ($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -eq [System.IO.FileAttributes]::ReparsePoint
        if ($isLink) {
            $cur = $item.Target
            $curStr = if ($cur) { $cur[0] } else { '' }
            if ($curStr -eq $Source) {
                Write-Host "[skip]   $Target (already linked here)"
                return
            }
            if (-not $Force) {
                throw "Existing symlink $Target -> $curStr. Re-run with -Force to replace."
            }
            Write-Host "[unlink] $Target (was -> $curStr)"
            if ($item.PSIsContainer) { $item.Delete() } else { Remove-Item -LiteralPath $Target -Force }
        } else {
            # A HARDLINK is not a reparse point, so the check above cannot see one.
            # Without this, every re-run treats an already-hardlinked file as an
            # original, backs it up again, and re-links it -- so install.ps1 was
            # idempotent for directories (junctions) but NOT for files, and each run
            # left another .pre-mmtoolbox-backup-* dir behind. Six had accumulated.
            if (-not $item.PSIsContainer) {
                try {
                    $links = & fsutil.exe hardlink list $Target 2>$null
                    $repoRef = $links | Where-Object {
                        $_ -and $_.TrimEnd() -and $Source.EndsWith($_.Trim(), [System.StringComparison]::OrdinalIgnoreCase)
                    }
                    if ($repoRef) {
                        Write-Host "[skip]   $Target (already hardlinked here)"
                        return
                    }
                } catch {
                    # fsutil unavailable -- fall through to the backup path.
                }
            }
            Ensure-Backup
            $relName = Split-Path -Leaf $Target
            $parent = Split-Path -Parent $Target
            $relParent = $parent.Substring($ClaudeHome.Length).TrimStart('\','/')
            $dst = if ($relParent) { Join-Path (Join-Path $Backup $relParent) $relName } else { Join-Path $Backup $relName }
            New-Item -ItemType Directory -Path (Split-Path -Parent $dst) -Force | Out-Null
            Write-Host "[backup] $Target -> $dst"
            Move-Item -LiteralPath $Target -Destination $dst -Force
        }
    }
    try {
        New-Item -ItemType SymbolicLink -Path $Target -Target $Source -Force | Out-Null
        Write-Host "[link]   $Target -> $Source"
    } catch {
        if ($Kind -eq 'Dir') {
            try {
                New-Item -ItemType Junction -Path $Target -Target $Source | Out-Null
                Write-Host "[junct]  $Target -> $Source"
            } catch {
                throw "Could not create symlink or junction for dir $Target -> $Source. Original error: $_"
            }
        } else {
            try {
                New-Item -ItemType HardLink -Path $Target -Target $Source | Out-Null
                Write-Host "[hlink]  $Target -> $Source  (hardlink fallback; no admin)"
            } catch {
                throw "Could not create symlink or hardlink for file $Target -> $Source. Enable Developer Mode (Settings > Privacy & security > For developers) or run as Administrator. Original error: $_"
            }
        }
    }
}

# ---- 1) Top-level files ----
Link-One "$RepoRoot\CLAUDE.md"        "$ClaudeHome\CLAUDE.md"        'File'
Link-One "$RepoRoot\keybindings.json" "$ClaudeHome\keybindings.json" 'File'

# ---- 2) Hooks (file-by-file; verify-loop.ps1 if present stays as-is) ----
Get-ChildItem -LiteralPath "$RepoRoot\hooks" -File | ForEach-Object {
    if ($_.Name -ieq 'README.md') { return }
    Link-One $_.FullName (Join-Path "$ClaudeHome\hooks" $_.Name) 'File'
}

# ---- 3) Skills (categorized -> flat) ----
Get-ChildItem -LiteralPath "$RepoRoot\skills" -Directory | ForEach-Object {
    $category = $_
    Get-ChildItem -LiteralPath $category.FullName -Directory | ForEach-Object {
        $skill = $_
        Link-One $skill.FullName (Join-Path "$ClaudeHome\skills" $skill.Name) 'Dir'
    }
}

# ---- 4) Agents (categorized -> flat) ----
Get-ChildItem -LiteralPath "$RepoRoot\agents" -Directory | ForEach-Object {
    $category = $_
    Get-ChildItem -LiteralPath $category.FullName -File -Filter '*.md' | ForEach-Object {
        if ($_.Name -ieq 'README.md') { return }
        Link-One $_.FullName (Join-Path "$ClaudeHome\agents" $_.Name) 'File'
    }
}

# ---- 5) Session-restore tool ----
# NOT symlinked into ~/.claude: the scheduled task and the desktop shortcut point
# at an absolute path, so they should point straight at this checkout. Clone the
# repo anywhere, run install.ps1, and the task follows the clone.
$SessionRestore = Join-Path $RepoRoot 'tools\session-restore\restore-sessions.ps1'
if ($NoSessionRestore) {
    Write-Host "[skip]   session-restore (-NoSessionRestore)"
} elseif (-not (Test-Path -LiteralPath $SessionRestore)) {
    Write-Warning "[missing] $SessionRestore"
} else {
    Write-Host ""
    Write-Host "[tools]  session-restore"
    & $SessionRestore -Install

    # Shell front door: `cc` (new NAMED session, here), `ccr` (restore what you
    # selected), `ccs` (choose what reopens). This matters because NO hook can set a
    # session title -- all 31 hook events are informational or permission-gating --
    # so a bare `claude` can only ever end up with an auto-generated name on your
    # phone. Never launching bare is the whole fix.
    #
    # The functions themselves live in the REPO (tools/session-restore/profile.ps1);
    # the profile gets a SINGLE dot-source line. Editing them needs no re-install,
    # and nothing about this tool is scattered outside MM-toolbox.
    $begin = '# >>> MM-toolbox session-restore >>>'
    $end   = '# <<< MM-toolbox session-restore <<<'
    $shellProfile = Join-Path (Split-Path -Parent $SessionRestore) 'profile.ps1'
    $block = @"
$begin
. '$shellProfile'
$end
"@

    $profilePath = $PROFILE.CurrentUserAllHosts
    $profileDir  = Split-Path -Parent $profilePath
    if (-not (Test-Path -LiteralPath $profileDir)) {
        New-Item -ItemType Directory -Path $profileDir -Force | Out-Null
    }

    $existing = ''
    if (Test-Path -LiteralPath $profilePath) {
        $existing = Get-Content -LiteralPath $profilePath -Raw
        if ($null -eq $existing) { $existing = '' }
    }

    if ($existing -match [regex]::Escape($begin)) {
        # Idempotent: replace the previous block rather than appending another.
        $pattern = [regex]::Escape($begin) + '.*?' + [regex]::Escape($end)
        $updated = [regex]::Replace($existing, $pattern, [System.Text.RegularExpressions.MatchEvaluator]{ param($m) $block }, 'Singleline')
        Set-Content -LiteralPath $profilePath -Value $updated -Encoding utf8
        Write-Host "[profile] refreshed cc/ccr in $profilePath"
    } else {
        Add-Content -LiteralPath $profilePath -Value ("`r`n" + $block) -Encoding utf8
        Write-Host "[profile] added cc/ccr to $profilePath"
    }
    Write-Host "[profile] open a NEW terminal, then: cc   (new named session)  /  ccr   (restore)"
}

Write-Host ""
if ($BackupCreated) {
    Write-Host "[done]   Originals backed up at: $Backup"
} else {
    Write-Host "[done]   No backups needed (no real files were replaced)."
}
Write-Host "[done]   To roll back: run uninstall.ps1"
