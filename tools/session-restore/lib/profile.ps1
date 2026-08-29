# MM-toolbox session-restore -- shell front door.
#
# Dot-sourced from your PowerShell profile by install.ps1, which writes ONE line
# there. The functions live here, in the repo, so editing them needs no re-install
# and nothing about this tool is scattered outside MM-toolbox.
#
#   cc  [name] [claude flags...]   start a NEW correctly-named session, here
#   ccr [-DryRun] [-All]           restore the conversations you have selected
#   ccs                            open the session console (the window)
#
# 🪤 These wrappers must NOT forward with `& script @args`. ARRAY splatting does not
# reliably bind switches: measured 2026-08-17, `cc -DryRun --model opus` bound
# -DryRun into the pass-through array and ACTUALLY LAUNCHED claude instead of
# dry-running it. HASH splatting binds by name, so each wrapper classifies its own
# arguments and splats a hashtable.

$Global:MMSessionRestoreRoot = $PSScriptRoot

function ccr {
    $p = @{}
    foreach ($a in $args) {
        switch -regex ([string]$a) {
            '^-+(DryRun|WhatIf)$' { $p['DryRun']    = $true }
            '^-+All$'             { $p['All']       = $true }
            '^-+Scan$'            { $p['Scan']      = $true }
            '^-+Install$'         { $p['Install']   = $true }
            '^-+Uninstall$'       { $p['Uninstall'] = $true }
            default { Write-Warning "ccr: ignoring unrecognised argument '$a' (try -DryRun, -All, -Scan, -Install, -Uninstall)" }
        }
    }
    & (Join-Path $Global:MMSessionRestoreRoot 'restore-sessions.ps1') @p
}

# Usage: cc [name] [claude flags...] -- the NAME, if given, must come FIRST.
# Once a flag is seen everything after it belongs to claude, otherwise the VALUE of
# a flag gets taken as the session name (`cc --model opus` named the session "opus").
function cc {
    $p = @{ New = $true }
    $rest = @()
    $seenFlag = $false
    foreach ($a in $args) {
        $s = [string]$a
        if ($s -match '^-+(DryRun|WhatIf)$') { $p['DryRun'] = $true; continue }
        if (-not $seenFlag -and -not $p.ContainsKey('Name') -and $s -notmatch '^-') {
            $p['Name'] = $s; continue
        }
        $seenFlag = $true
        $rest += $s
    }
    if ($rest.Count -gt 0) { $p['ClaudeArgs'] = $rest }
    & (Join-Path $Global:MMSessionRestoreRoot 'restore-sessions.ps1') @p
}

# ccs   open the session console (the window)
#
# It used to take -List / -Enable / -Disable / -Worktrees and drive a terminal
# panel. The panel is gone - the window replaced it, and does all four of those
# things on screen where you can see what you are changing. Anything that has
# to be scripted goes through restore-sessions.ps1, which is the one that
# actually restores.
function ccs {
    if ($args.Count) {
        Write-Warning "ccs takes no arguments now - the window does the ticking. Ignoring: $($args -join ' ')"
    }
    $gui = Join-Path $Global:MMSessionRestoreRoot 'sessions-gui2.ps1'
    # -STA because WPF requires it, Start-Process because the window should not
    # hold the shell you launched it from.
    Start-Process powershell.exe -ArgumentList @(
        '-STA', '-NoProfile', '-ExecutionPolicy', 'Bypass', '-WindowStyle', 'Hidden', '-File', $gui
    ) | Out-Null
}
