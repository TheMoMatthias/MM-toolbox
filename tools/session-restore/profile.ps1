# MM-toolbox session-restore -- shell front door.
#
# Dot-sourced from your PowerShell profile by install.ps1, which writes ONE line
# there. The functions live here, in the repo, so editing them needs no re-install
# and nothing about this tool is scattered outside MM-toolbox.
#
#   cc  [name] [claude flags...]   start a NEW correctly-named session, here
#   ccr [-DryRun] [-All]           restore the conversations you have selected
#   ccs [-List]                    choose which directories reopen at logon
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

# ccs                      the picker
# ccs -List                print the current selection
# ccs -Enable  <match>     tick   by project path, worktree name, title or id
# ccs -Disable <match>     untick the same way
# ccs -Worktrees on|off    show or hide git-worktree lanes (writes the config)
function ccs {
    $p = @{}
    $lists = @{}
    $pendingList   = $null
    $pendingScalar = $null

    foreach ($a in $args) {
        $s = [string]$a
        if ($pendingList)   { $lists[$pendingList] += $s;  $pendingList   = $null; continue }
        if ($pendingScalar) { $p[$pendingScalar]    = $s;  $pendingScalar = $null; continue }
        switch -regex ($s) {
            '^-+List$'      { $p['List']   = $true }
            '^-+NoScan$'    { $p['NoScan'] = $true }
            '^-+Enable$'    { $pendingList = 'Enable';  if (-not $lists.ContainsKey('Enable'))  { $lists['Enable']  = @() } }
            '^-+Disable$'   { $pendingList = 'Disable'; if (-not $lists.ContainsKey('Disable')) { $lists['Disable'] = @() } }
            '^-+Worktrees$' { $pendingScalar = 'Worktrees' }
            # `ccs -Worktrees off` is the long form; `ccs worktrees off` is not, so a
            # bare on/off with nothing pending is a mistake worth naming.
            default { Write-Warning "ccs: ignoring unrecognised argument '$a' (try -List, -Enable <match>, -Disable <match>, -Worktrees on|off)" }
        }
    }
    if ($pendingList -or $pendingScalar) {
        Write-Warning "ccs: -$($pendingList)$($pendingScalar) was given no value - ignored"
    }
    foreach ($k in $lists.Keys) { if (@($lists[$k]).Count -gt 0) { $p[$k] = $lists[$k] } }
    & (Join-Path $Global:MMSessionRestoreRoot 'select-sessions.ps1') @p
}
