
# DIAGNOSTIC, not a test. Runs the real probe synchronously and prints exactly
# what the inbox would show, so "the recognition is wrong" can be checked
# against processes that actually exist. No window, no focus.
Write-Host "running the real probe..."
$running = Get-SRRunningIds -Refresh
$agents  = Get-SRAgentStatus -Refresh
$live = @{}; $conv = @{}; $said = @{}
foreach ($d in $script:dirs) {
    foreach ($s in @($d.sessions)) {
        if (-not $s.sessionId) { continue }
        $cwd = if ($s.cwd) { $s.cwd } else { $d.path }
        $j = Get-SRTranscriptPath -Dir $cwd -SessionId $s.sessionId -Recorded $s.jsonl
        $key = "$($s.sessionId)".ToLower()
        if (Test-SRTranscriptLive -JsonlPath $j) { $live[$key] = $true }
        $cs = $null
        try { $cs = Get-SRConversationState -JsonlPath $j; $conv[$key] = $cs } catch { }
        if ($live[$key] -or $running[$key] -or ($cs -and -not $cs.Stale)) {
            try { $said[$key] = Get-SRLastSaid -JsonlPath $j } catch { }
        }
    }
}
$script:running = $running; $script:agents = $agents
$script:live = $live; $script:conv = $conv; $script:said = $said

Write-Host ""
Write-Host ("claude.exe processes : " + @(Get-CimInstance Win32_Process -Filter "Name='claude.exe'").Count)
Write-Host ("agents --json entries: " + $agents.Count)
Write-Host ("ids on a command line: " + $running.Count)
Write-Host ("transcripts warm     : " + $live.Count)
Write-Host ("registry conversations: " + $script:totalCount)

Set-ViewMode 'inbox'
Write-Host ""
Write-Host "=== WHAT THE INBOX SHOWS ==="
foreach ($r in $script:inboxRows.ToArray()) {
    if ($r.Kind -eq 'band') { Write-Host ("`n{0}  ({1})" -f $r.Name, $r.Counts) -ForegroundColor Cyan; continue }
    $key = "$($r.Session.sessionId)".ToLower()
    $a = $agents[$key]
    $src = @()
    if ($a) { $src += "agent:$($a.Status)" }
    if ($running[$key]) { $src += 'cmdline' }
    if ($live[$key]) { $src += 'warm' }
    Write-Host ("   {0,-24} {1,-26} [{2}]  {3}" -f $r.Name, $r.Project, ($src -join ','), $r.Stamp)
}
Write-Host ""
Write-Host "=== the header's own counts ==="
Write-Host ("   " + $ui.LiveSummary.Text)
Write-Host ("   " + $ui.WaitSummary.Text)
exit 0
