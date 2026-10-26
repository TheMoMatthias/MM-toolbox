# terminate.ps1 - end a local agent session (Claude Code or Pi) cleanly and verifiably.
#
# Works for sessions inside herdr (closes the herdr tab or pane) and outside it (Windows
# Terminal or a plain PowerShell window: kills the agent's process tree, then the boot shell
# that hosted it, so the terminal tab closes). Keep this file pure ASCII: Windows PowerShell
# 5.1 reads .ps1 as ANSI.
#
# Refuses, unless -Force:
#   - a target that is the calling session itself (use -Self, which ends it after a delay);
#   - a target herdr reports as "working" or "blocked";
#   - a target with live background work: bash/git/python/ssh/gh/node descendants that are
#     not the agent's own helpers (measured 10-26: a "stopped" session's queue-wait push
#     scripts were still alive and would have pushed after the window closed);
#   - a target whose transcript cannot be found (it could not be resumed afterwards).
# Never touches a process that does not carry the session id or sit in the matched pane.

[CmdletBinding()]
param(
    [string]$SessionId,
    [string]$Name,
    [int]$ProcessId,
    [switch]$Self,
    [int]$DelaySec = 20,
    [switch]$Force,
    [switch]$DryRun,
    [switch]$List
)

$ErrorActionPreference = 'Stop'
$uuidRx = '[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}'

function Say([string]$tag, [string]$msg) { Write-Host ("{0,-11}: {1}" -f $tag, $msg) }

# ---- inventory: processes -------------------------------------------------------------
$all = @(Get-CimInstance Win32_Process)
$byPid = @{}; foreach ($p in $all) { $byPid[[int]$p.ProcessId] = $p }
$kids = @{}
foreach ($p in $all) {
    $pp = [int]$p.ParentProcessId
    if (-not $kids.ContainsKey($pp)) { $kids[$pp] = New-Object System.Collections.ArrayList }
    [void]$kids[$pp].Add($p)
}
function Get-Descendants([int]$root) {
    $out = New-Object System.Collections.ArrayList
    $stack = New-Object System.Collections.Stack; $stack.Push($root)
    while ($stack.Count -gt 0) {
        $cur = $stack.Pop()
        if ($kids.ContainsKey($cur)) { foreach ($c in $kids[$cur]) { [void]$out.Add($c); $stack.Push([int]$c.ProcessId) } }
    }
    return ,$out
}

# Agent processes: claude.exe (--session-id / --resume <uuid>, -n <name>) and Pi (node.exe
# whose command line names pi and a session id).
$agents = New-Object System.Collections.ArrayList
foreach ($p in $all) {
    $cl = [string]$p.CommandLine
    if (-not $cl) { continue }
    $runtime = $null
    if ($p.Name -ieq 'claude.exe') { $runtime = 'claude' }
    elseif ($p.Name -ieq 'node.exe' -and $cl -match '(?i)[\\/ ]pi(\.js|\.cmd)?["\s]|pi-coding-agent|@mariozechner') { $runtime = 'pi' }
    if (-not $runtime) { continue }
    $sid = $null; $m = [regex]::Match($cl, '--(?:session-id|resume|session)\s+"?(' + $uuidRx + ')')
    if ($m.Success) { $sid = $m.Groups[1].Value.ToLower() }
    $nm = $null; $m2 = [regex]::Match($cl, '(?:^|\s)-n\s+"?([^"\s]+)')
    if ($m2.Success) { $nm = $m2.Groups[1].Value }
    [void]$agents.Add([pscustomobject]@{ Pid = [int]$p.ProcessId; Parent = [int]$p.ParentProcessId; Runtime = $runtime; SessionId = $sid; Name = $nm; Pane = $null; Tab = $null; Status = $null })
}

# ---- inventory: herdr (optional) ------------------------------------------------------
$herdrBin = (Get-Command herdr -ErrorAction SilentlyContinue)
$herdrAgents = @()
if ($herdrBin) {
    try {
        $st = & $herdrBin.Source status server 2>$null | Out-String
        if ($st -match 'status:\s*running') {
            $j = (& $herdrBin.Source agent list 2>$null | Out-String) | ConvertFrom-Json
            $herdrAgents = @($j.result.agents)
        }
    } catch { Say 'NOTE' "herdr inventory failed ($($_.Exception.Message)); falling back to processes only" }
}
foreach ($h in $herdrAgents) {
    $hsid = $null; if ($h.agent_session -and $h.agent_session.value) { $hsid = ([string]$h.agent_session.value).ToLower() }
    $hit = $null
    if ($hsid) { $hit = $agents | Where-Object { $_.SessionId -eq $hsid } | Select-Object -First 1 }
    if (-not $hit) {
        # pane foreground process, for sessions whose command line carries no id
        try {
            $pi = (& $herdrBin.Source pane process-info --pane $h.pane_id 2>$null | Out-String) | ConvertFrom-Json
            $fg = [int]$pi.result.process_info.foreground_process_group_id
            $hit = $agents | Where-Object { $_.Pid -eq $fg } | Select-Object -First 1
        } catch {}
    }
    if (-not $hit) {
        $hit = [pscustomobject]@{ Pid = 0; Parent = 0; Runtime = [string]$h.agent; SessionId = $hsid; Name = $null; Pane = $null; Tab = $null; Status = $null }
        [void]$agents.Add($hit)
    }
    if (-not $hit.SessionId -and $hsid) { $hit.SessionId = $hsid }
    $hit.Pane = [string]$h.pane_id; $hit.Tab = [string]$h.tab_id; $hit.Status = [string]$h.agent_status
    if ($h.terminal_title_stripped) { $hit.Name = [string]$h.terminal_title_stripped }
}

if ($List) {
    $agents | Sort-Object Name | Format-Table Name, Runtime, Pid, SessionId, Status, Pane, Tab -AutoSize | Out-String -Width 220 | Write-Host
    exit 0
}

# ---- resolve the target ---------------------------------------------------------------
$own = ([string]$env:CLAUDE_CODE_SESSION_ID).ToLower()
if ($Self) {
    if (-not $own) { Say 'REFUSED' 'no CLAUDE_CODE_SESSION_ID in this environment; name the target instead'; exit 2 }
    $SessionId = $own
}
$cand = @()
if ($SessionId) { $cand = @($agents | Where-Object { $_.SessionId -and $_.SessionId.StartsWith($SessionId.ToLower()) }) }
elseif ($ProcessId) { $cand = @($agents | Where-Object { $_.Pid -eq $ProcessId }) }
elseif ($Name) { $cand = @($agents | Where-Object { $_.Name -eq $Name }) }
else { Say 'REFUSED' 'give -SessionId, -Name, -ProcessId or -Self (or -List)'; exit 2 }

if ($cand.Count -eq 0) { Say 'NOT FOUND' 'no live session matches; nothing to terminate (run -List)'; exit 3 }
if ($cand.Count -gt 1) {
    Say 'REFUSED' "ambiguous: $($cand.Count) sessions match; use -SessionId"
    $cand | Format-Table Name, Runtime, Pid, SessionId, Status, Pane -AutoSize | Out-String -Width 220 | Write-Host
    exit 2
}
$t = $cand[0]
Say 'TARGET' ("{0} ({1}) pid={2} session={3} herdr={4} status={5}" -f $t.Name, $t.Runtime, $t.Pid, $t.SessionId, $(if ($t.Pane) { "$($t.Tab)/$($t.Pane)" } else { 'no' }), $t.Status)

# ---- safety checks --------------------------------------------------------------------
$problems = @()
if ($t.SessionId -and $t.SessionId -eq $own -and -not $Self) { $problems += 'it is THIS session (use -Self to end it after a delay)' }
if (-not $Self -and $t.Status -in @('working', 'blocked')) { $problems += "herdr reports it '$($t.Status)'" }

$work = @()
if ($t.Pid) {
    foreach ($d in (Get-Descendants $t.Pid)) {
        $dn = ([string]$d.Name).ToLower(); $dc = [string]$d.CommandLine
        if ($dn -in @('bash.exe', 'sh.exe', 'git.exe', 'python.exe', 'python3.exe', 'pythonw.exe', 'ssh.exe', 'gh.exe', 'pwsh.exe', 'powershell.exe', 'cmd.exe', 'node.exe')) {
            # the agent's own helpers: MCP servers and its shell snapshot are not work
            if ($dn -eq 'node.exe' -and $dc -match '(?i)mcp|modelcontextprotocol') { continue }
            if ($dc -match '(?i)shell-snapshots|claude-shell-snapshot') { continue }
            $work += $d
        }
    }
}
if ($work.Count -gt 0) {
    $problems += "$($work.Count) live child process(es) look like background work"
    foreach ($w in $work | Select-Object -First 8) {
        $c = [string]$w.CommandLine; if ($c.Length -gt 140) { $c = $c.Substring(0, 140) + '...' }
        Say 'CHILD' ("{0} {1} {2}" -f $w.ProcessId, $w.Name, $c)
    }
}

$transcript = $null
if ($t.SessionId) {
    $roots = @("$env:USERPROFILE\.claude\projects", "$env:USERPROFILE\.pi\agent\sessions")
    foreach ($r in $roots) {
        if (-not (Test-Path $r)) { continue }
        $f = Get-ChildItem -Path $r -Recurse -File -Filter "*$($t.SessionId)*" -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($f) { $transcript = $f.FullName; break }
    }
}
if (-not $transcript) { $problems += 'no transcript found, so it could not be resumed afterwards' }
else { Say 'TRANSCRIPT' $transcript }

if ($problems.Count -gt 0) {
    foreach ($p in $problems) { Say 'BLOCKER' $p }
    if (-not $Force) { Say 'REFUSED' 'nothing was terminated; fix the blockers or pass -Force deliberately'; exit 2 }
    Say 'OVERRIDE' '-Force given: proceeding despite the blockers above'
}

$resume = $null
if ($t.SessionId) { if ($t.Runtime -eq 'pi') { $resume = "pi --session $($t.SessionId)" } else { $resume = "claude --resume $($t.SessionId)" } }

# ---- the plan -------------------------------------------------------------------------
$bootShell = $null
if ($t.Pid -and $byPid.ContainsKey($t.Parent)) {
    $par = $byPid[$t.Parent]
    if (([string]$par.Name) -match '(?i)^(powershell|pwsh)\.exe$' -and ([string]$par.CommandLine) -match '(?i)boot|spawn') { $bootShell = $par }
}
if ($t.Tab) { $plan = "herdr tab close $($t.Tab) (pane $($t.Pane)), then kill pid $($t.Pid) if still alive" }
else { $plan = "kill process tree of pid $($t.Pid)"; if ($bootShell) { $plan += " and its boot shell pid $($bootShell.ProcessId)" } }
Say 'PLAN' $plan
if ($resume) { Say 'RESUME' $resume }
if ($DryRun) { Say 'DRY RUN' 'nothing terminated'; exit 0 }

# ---- -Self: hand off to a detached, delayed copy of this script ------------------------
if ($Self) {
    $me = $MyInvocation.MyCommand.Path
    $argList = "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -Command `"Start-Sleep -Seconds $DelaySec; & '$me' -SessionId $($t.SessionId) -Force`""
    $env:CLAUDE_CODE_SESSION_ID = ''
    Start-Process -FilePath powershell.exe -ArgumentList $argList -WindowStyle Hidden | Out-Null
    Say 'SCHEDULED' "this session ends in ${DelaySec}s; finish the reply now"
    exit 0
}

# ---- terminate ------------------------------------------------------------------------
if ($t.Tab -and $herdrBin) {
    $tabPanes = @($herdrAgents | Where-Object { $_.tab_id -eq $t.Tab })
    if ($tabPanes.Count -le 1) { & $herdrBin.Source tab close $t.Tab 2>&1 | Out-Null }
    else { & $herdrBin.Source pane close $t.Pane 2>&1 | Out-Null }
}
$deadline = (Get-Date).AddSeconds(10)
while ($t.Pid -and (Get-Process -Id $t.Pid -ErrorAction SilentlyContinue) -and (Get-Date) -lt $deadline) { Start-Sleep -Milliseconds 500 }
if ($t.Pid -and (Get-Process -Id $t.Pid -ErrorAction SilentlyContinue)) {
    & taskkill.exe /PID $t.Pid /T /F 2>&1 | Out-Null
    Start-Sleep -Seconds 1
}
if ($bootShell -and (Get-Process -Id $bootShell.ProcessId -ErrorAction SilentlyContinue)) {
    & taskkill.exe /PID $bootShell.ProcessId /T /F 2>&1 | Out-Null
}

# ---- verify ---------------------------------------------------------------------------
$alive = @()
if ($t.Pid -and (Get-Process -Id $t.Pid -ErrorAction SilentlyContinue)) { $alive += "pid $($t.Pid)" }
foreach ($w in $work) { if (Get-Process -Id $w.ProcessId -ErrorAction SilentlyContinue) { $alive += "child $($w.ProcessId)" } }
if ($t.Tab -and $herdrBin) {
    try {
        $j2 = (& $herdrBin.Source agent list 2>$null | Out-String) | ConvertFrom-Json
        if (@($j2.result.agents | Where-Object { $_.pane_id -eq $t.Pane }).Count -gt 0) { $alive += "herdr pane $($t.Pane)" }
    } catch {}
}
if ($alive.Count -gt 0) { Say 'FAILED' ("still present: " + ($alive -join ', ')); exit 1 }
Say 'VERIFIED' ("session {0} ended; no process or herdr pane remains" -f $t.Name)
if ($resume) { Say 'RESUME' "$resume   (the transcript is kept)" }
exit 0
