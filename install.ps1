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
# in MM-toolbox UNTOUCHED. (This comment used to cite ~/.claude/hooks/verify-loop.ps1
# as the example of such a file. It was WRONG: verify-loop.ps1 was in this repo and
# hardlinked, so the "untouched" claim did not apply to it. That hook is now retired.)
#
# 🪤 LINKING A HOOK IS NOT INSTALLING IT. See section 2b: this installer also writes
# the registration into ~/.claude/settings.json, because for weeks it did not, and a
# Stop hook sat linked-but-unregistered on a real machine and never ran once while the
# global CLAUDE.md described it as installed.

# 🪤 [CmdletBinding()] is load-bearing, not decoration. A plain param() block puts
# UNBOUND arguments into $args and carries on: measured 2026-08-18,
# `install.ps1 -NotARealSwitch` installed everything and exited 0, so a typo'd
# -NoSessionRestore would silently install the very thing you asked it to skip.
# This makes an unknown switch an error instead. Neither script reads $args.
[CmdletBinding()]
param(
    [switch]$Force,
    [string]$ClaudeHome = "$env:USERPROFILE\.claude",

    # Skip the session-restore tool (logon task + desktop buttons). Everything else
    # installs as normal.
    [switch]$NoSessionRestore,

    # Wire the cc / ccr / ccs shell functions into your PowerShell profile.
    # OFF BY DEFAULT: the tool is driven from Sessions.bat, the desktop buttons and
    # the panel, and a profile that dot-sources something on every terminal you open
    # should be something you asked for. Without this the installer REMOVES the block
    # if a previous install left one, so re-running it converges either way.
    [switch]$ShellFunctions,

    # Skip writing the hook registration into ~/.claude/settings.json.
    # Registration is ON by default, and that default is deliberate: opt-in is exactly
    # how the previous Stop hook stayed dark. Pass this only if you maintain the hooks
    # block by hand and do not want the installer near it.
    [switch]$NoHookRegistration
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

# ---- 2) Hooks (file-by-file) ----
Get-ChildItem -LiteralPath "$RepoRoot\hooks" -File | ForEach-Object {
    if ($_.Name -ieq 'README.md') { return }
    Link-One $_.FullName (Join-Path "$ClaudeHome\hooks" $_.Name) 'File'
}

# ---- 2b) Register the hooks in ~/.claude/settings.json ----
# 🪤 LINKING A HOOK IS NOT INSTALLING IT, AND THE DIFFERENCE IS INVISIBLE.
# Until 2026-09-08 this installer linked hook FILES and wrote nothing to settings.json;
# hooks/README.md told you to re-type the JSON per machine. Measured consequence on this
# machine: verify-loop.ps1 sat linked for weeks while settings.json registered NO Stop
# hook at all, so it never ran once -- and the global CLAUDE.md described it as installed
# the whole time. A fresh clone reproduced that exactly. An unregistered hook and a
# working one look identical from the filesystem, which is why this step now exists.
#
# Scope is deliberately narrow: hook entries only. Everything else in settings.json --
# permissions, autoMode, model, statusLine -- stays yours, per machine.
#
# TEXTUAL insertion, not a JSON round-trip: PS 5.1's ConvertTo-Json escapes ' < > & as
# \uXXXX, which would mangle the prose in your autoMode strings on every install. So we
# PARSE to decide (reliable) and SPLICE to apply (lossless), validating before writing.
if ($NoHookRegistration) {
    Write-Host "[hooks]  settings.json registration skipped (-NoHookRegistration)"
} else {
    $settingsPath = Join-Path $ClaudeHome 'settings.json'
    # Only hooks that ADVISE. 2026-09-08: an objective-loop Stop hook briefly lived here
    # and was removed on operator instruction -- a Stop hook can only read a ledger the
    # model itself wrote, so it cannot tell "work remains" from "nothing left to do" and
    # pressures the session to continue either way. Continuation is a judgement call
    # (CLAUDE.md -> "Continuing without being told") or an explicit request
    # (the continue-work skill). Neither belongs in a hook.
    $wanted = @(
        [pscustomobject]@{ Event = 'UserPromptSubmit'; Script = 'grill-gate.ps1'; Timeout = 5; Status = 'grill-gate' }
    )

    function New-HookGroupJson {
        param([string]$TargetPath, [int]$Timeout, [string]$StatusMessage)
        # 🪤 JSON-escape the path: each `\` becomes `\\`. The REPLACEMENT is two literal
        # backslashes, not four - .NET treats only `$` as special in a replacement string,
        # so '\\\\' emits FOUR and the parsed path comes back as C:\\Users\\... , naming a
        # file that does not exist. Measured in the sandbox suite; a fresh machine would
        # have registered a hook pointing at nothing, which is the exact failure this
        # whole section exists to prevent.
        $esc = $TargetPath -replace '\\', '\\'
        return @"
      {
        "hooks": [
          {
            "type": "command",
            "command": "powershell.exe",
            "args": [
              "-NoProfile",
              "-ExecutionPolicy",
              "Bypass",
              "-File",
              "$esc"
            ],
            "timeout": $Timeout,
            "statusMessage": "$StatusMessage"
          }
        ]
      }
"@
    }

    # 🪤 A SPLICE THAT ALWAYS APPENDS A COMMA PRODUCES `{ "hooks": {...}, }` ON AN EMPTY
    # CONTAINER, and a trailing comma is invalid JSON. Caught by the validate-before-write
    # gate below on the very first sandbox run - the gate refused rather than corrupting
    # settings.json, which is the whole reason it is there. So: only add the separator
    # when something actually follows the insertion point.
    function Test-NeedsComma {
        param([string]$Json, [int]$Pos, [char]$CloseChar)
        for ($i = $Pos; $i -lt $Json.Length; $i++) {
            $ch = $Json[$i]
            if ([char]::IsWhiteSpace($ch)) { continue }
            return ($ch -ne $CloseChar)      # an immediate close = we are the only element
        }
        return $false
    }

    # Splice one group into the JSON text. Three shapes, in order of how much exists.
    function Add-HookRegistration {
        param([string]$Json, [string]$EventName, [string]$GroupJson)
        $mHooks = [regex]::Match($Json, '"hooks"\s*:\s*\{')
        if (-not $mHooks.Success) {
            # no "hooks" object at all -> create it right after the root opening brace
            $open = $Json.IndexOf('{')
            if ($open -lt 0) { return $null }
            $sep = if (Test-NeedsComma -Json $Json -Pos ($open + 1) -CloseChar '}') { ',' } else { '' }
            $block = "`r`n  ""hooks"": {`r`n    ""$EventName"": [`r`n$GroupJson`r`n    ]`r`n  }$sep"
            return $Json.Insert($open + 1, $block)
        }
        $tail = $Json.Substring($mHooks.Index)
        $mEvent = [regex]::Match($tail, ('"' + [regex]::Escape($EventName) + '"\s*:\s*\['))
        if ($mEvent.Success) {
            # the event array exists -> insert our group as its first element
            $at = $mHooks.Index + $mEvent.Index + $mEvent.Length
            $sep = if (Test-NeedsComma -Json $Json -Pos $at -CloseChar ']') { ',' } else { '' }
            return $Json.Insert($at, "`r`n$GroupJson$sep")
        }
        # "hooks" exists but not this event -> add the event array inside it
        $at = $mHooks.Index + $mHooks.Length
        $sep = if (Test-NeedsComma -Json $Json -Pos $at -CloseChar '}') { ',' } else { '' }
        $block = "`r`n    ""$EventName"": [`r`n$GroupJson`r`n    ]$sep"
        return $Json.Insert($at, $block)
    }

    $rawCfg = $null
    if (Test-Path -LiteralPath $settingsPath) {
        $rawCfg = Get-Content -LiteralPath $settingsPath -Raw
        if ($null -eq $rawCfg -or [string]::IsNullOrWhiteSpace($rawCfg)) { $rawCfg = "{`r`n}" }
    } else {
        $rawCfg = "{`r`n}"
        Write-Host "[hooks]  no settings.json yet - creating one with just the hook registration"
    }

    $cfg = $null
    try { $cfg = $rawCfg | ConvertFrom-Json } catch {
        Write-Warning "[hooks]  settings.json is not valid JSON - NOT touching it. Register by hand (see hooks/README.md). Error: $($_.Exception.Message)"
    }

    if ($null -ne $cfg) {
        $working = $rawCfg
        $changed = $false

        foreach ($w in $wanted) {
            $target = Join-Path "$ClaudeHome\hooks" $w.Script
            if (-not (Test-Path -LiteralPath $target)) {
                Write-Warning "[hooks]  $($w.Script) is not in $ClaudeHome\hooks - not registering a hook that isn't there"
                continue
            }
            # Already registered? Decide from the PARSED config, matching on the script
            # FILENAME, so a differently-spelled but equivalent path still counts.
            $already = $false
            if ($cfg.PSObject.Properties['hooks'] -and $cfg.hooks.PSObject.Properties[$w.Event]) {
                $probe = ($cfg.hooks.($w.Event) | ConvertTo-Json -Depth 20 -Compress)
                if ($probe -like ('*' + $w.Script + '*')) { $already = $true }
            }
            if ($already) {
                Write-Host ("[hooks]  {0} already registered for {1}" -f $w.Script, $w.Event)
                continue
            }

            $group = New-HookGroupJson -TargetPath $target -Timeout $w.Timeout -StatusMessage $w.Status
            $next = Add-HookRegistration -Json $working -EventName $w.Event -GroupJson $group
            if ($null -eq $next) {
                Write-Warning "[hooks]  could not splice $($w.Event) into settings.json - skipped"
                continue
            }
            try { $null = $next | ConvertFrom-Json } catch {
                Write-Warning "[hooks]  splicing $($w.Event) produced invalid JSON - skipped, nothing written"
                continue
            }
            $working = $next
            $changed = $true
            Write-Host ("[hooks]  registering {0} -> {1}" -f $w.Event, $w.Script)
        }

        if (-not $changed) {
            Write-Host "[hooks]  settings.json already current - not rewritten"
        } else {
            if (Test-Path -LiteralPath $settingsPath) {
                Ensure-Backup
                $dst = Join-Path $Backup 'settings.json'
                Copy-Item -LiteralPath $settingsPath -Destination $dst -Force
                Write-Host "[backup] $settingsPath -> $dst"
            }
            [System.IO.File]::WriteAllText($settingsPath, $working, (New-Object System.Text.UTF8Encoding($false)))

            # Verify by MARKER, never by the write succeeding: Claude Code rewrites
            # settings.json on its own schedule and can race this.
            $check = Get-Content -LiteralPath $settingsPath -Raw
            $missing = @($wanted | Where-Object { (Test-Path (Join-Path "$ClaudeHome\hooks" $_.Script)) -and ($check -notlike ('*' + $_.Script + '*')) })
            $parses = $true
            try { $null = $check | ConvertFrom-Json } catch { $parses = $false }
            if (-not $parses) {
                Write-Warning "[hooks]  settings.json on disk does not parse after the write. Restore from $Backup and register by hand."
            } elseif ($missing.Count -gt 0) {
                Write-Warning ("[hooks]  MARKER CHECK FAILED - absent after the write: " + (($missing | ForEach-Object { $_.Script }) -join ', ') + ". Close Claude Code and re-run install.ps1.")
            } else {
                Write-Host "[hooks]  settings.json updated and verified"
            }
        }
    }

    Write-Host "[hooks]  NOTE: hook changes take effect for sessions started AFTER this point."
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
$SessionRestore = Join-Path $RepoRoot 'tools\session-restore\lib\restore-sessions.ps1'
if ($NoSessionRestore) {
    Write-Host "[skip]   session-restore (-NoSessionRestore)"
} elseif (-not (Test-Path -LiteralPath $SessionRestore)) {
    Write-Warning "[missing] $SessionRestore"
} else {
    Write-Host ""
    Write-Host "[tools]  session-restore"
    & $SessionRestore -Install

    # Shell front door: `cc` (new NAMED session, here), `ccr` (restore what you
    # selected), `ccs` (the panel). Opt-in via -ShellFunctions. The same jobs are
    # done by Sessions.bat and the desktop buttons, so this is convenience, not the
    # tool -- and it is the only part of the install that touches a file outside
    # MM-toolbox and ~/.claude.
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

    $pattern = [regex]::Escape($begin) + '.*?' + [regex]::Escape($end)
    $hasBlock = $existing -match [regex]::Escape($begin)

    if (-not $ShellFunctions) {
        # Not asked for. Leave nothing behind, and take out anything an earlier
        # install added -- otherwise the default is "whatever you happened to run
        # first", which is not a default at all.
        if ($hasBlock) {
            $updated = [regex]::Replace($existing, $pattern, '', 'Singleline').TrimEnd() + "`r`n"
            Set-Content -LiteralPath $profilePath -Value $updated -Encoding utf8
            Write-Host "[profile] removed the cc/ccr/ccs block from $profilePath (pass -ShellFunctions to keep it)"
        } else {
            Write-Host "[profile] untouched - pass -ShellFunctions if you want cc/ccr/ccs in your terminal"
        }
    }
    elseif ($hasBlock) {
        # Idempotent: replace the previous block rather than appending another.
        $updated = [regex]::Replace($existing, $pattern, [System.Text.RegularExpressions.MatchEvaluator]{ param($m) $block }, 'Singleline')
        Set-Content -LiteralPath $profilePath -Value $updated -Encoding utf8
        Write-Host "[profile] refreshed cc/ccr in $profilePath"
        Write-Host "[profile] open a NEW terminal, then: cc   (new named session)  /  ccr   (restore)"
    }
    else {
        Add-Content -LiteralPath $profilePath -Value ("`r`n" + $block) -Encoding utf8
        Write-Host "[profile] added cc/ccr to $profilePath"
        Write-Host "[profile] open a NEW terminal, then: cc   (new named session)  /  ccr   (restore)"
    }
}

Write-Host ""
if ($BackupCreated) {
    Write-Host "[done]   Originals backed up at: $Backup"
} else {
    Write-Host "[done]   No backups needed (no real files were replaced)."
}
Write-Host "[done]   To roll back: run uninstall.ps1"
