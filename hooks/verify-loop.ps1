# verify-loop.ps1 - asyncRewake Stop hook : self-healing verify loop
#
# Inert unless ARMED. Armed = a per-repo sentinel  <cwd>\.claude\verify-loop.active
# exists (JSON). When armed, on every stop this runs the sentinel's verify_command
# and decides what to tell the model on re-wake (exit code 2 = re-wake; 0 = quiet).
#
#   verify_command exit:  0 = GREEN | 1 = RED (retry) | other = HARNESS ERROR
#   caps:  max_attempts (default 5)  AND  deadline (epoch seconds, default arm+30min)
#   terminal status (green|stopped|error) re-wakes EXACTLY once, then goes quiet.
#
# Fail-safe: any internal error -> mark status=error, re-wake once, else exit 0.
# ASCII-only (see CLAUDE.md .ps1 hazards).

$ErrorActionPreference = 'Stop'

# Never block: if stdin isn't piped, there's nothing to read -> exit immediately.
if (-not [Console]::IsInputRedirected) { exit 0 }

function Read-Cwd {
    $raw = [Console]::In.ReadToEnd()
    if ([string]::IsNullOrWhiteSpace($raw)) { return $null }
    return ([string]((($raw | ConvertFrom-Json).cwd)))
}

$sentinelPath = $null
try {
    $cwd = Read-Cwd
    if ([string]::IsNullOrWhiteSpace($cwd)) { exit 0 }            # no cwd -> nothing to do
    $sentinelPath = Join-Path $cwd '.claude\verify-loop.active'
    if (-not (Test-Path -LiteralPath $sentinelPath)) { exit 0 }   # NOT ARMED -> inert
} catch {
    exit 0                                                         # cannot even parse input -> fail-safe quiet
}

# ---- armed: load state -------------------------------------------------------
try {
    $s = Get-Content -LiteralPath $sentinelPath -Raw | ConvertFrom-Json
} catch {
    exit 0   # unreadable sentinel -> stay quiet (model can re-arm); never runaway
}

function Save-State($state) {
    $state | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $sentinelPath -Encoding ASCII
}
function Emit-Rewake($msg) { Write-Output $msg; exit 2 }

try {
    $status = [string]$s.status
    if ($status -in @('green','stopped','error')) { exit 0 }   # terminal already signaled once

    $maxAttempts = [int]$s.max_attempts; if ($maxAttempts -le 0) { $maxAttempts = 5 }
    $attempt     = [int]$s.attempt
    $deadline    = [long]$s.deadline
    $now         = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()

    # ---- wall-clock cap (applies before running anything) --------------------
    if ($deadline -gt 0 -and $now -gt $deadline) {
        $s.status = 'stopped'; Save-State $s
        Emit-Rewake "[verify-loop] CAP - 30-min wall-clock deadline hit (attempt $attempt/$maxAttempts). STOP the loop: (1) write the user a concise account of what was tried and the remaining failure, (2) fire a PushNotification (run blocked), (3) DELETE the sentinel .claude/verify-loop.active to disarm. Do NOT auto-commit. Leave code changes in place."
    }

    # ---- run the verify command in the repo ---------------------------------
    $verifyCmd = [string]$s.verify_command
    if ([string]::IsNullOrWhiteSpace($verifyCmd)) {
        $s.status = 'error'; Save-State $s
        Emit-Rewake "[verify-loop] SCRIPT ERROR - sentinel has no verify_command. DELETE the sentinel and re-arm correctly."
    }

    Push-Location -LiteralPath $cwd
    try {
        $out = cmd /c $verifyCmd 2>&1 | Out-String
        $vrc = $LASTEXITCODE
    } finally {
        Pop-Location
    }
    if ($null -eq $vrc) { $vrc = -1 }
    $tail = (($out -split "`n") | Select-Object -Last 40) -join "`n"

    # ---- decide -------------------------------------------------------------
    if ($vrc -eq 0) {
        $s.status = 'green'; Save-State $s
        Emit-Rewake @"
[verify-loop] GREEN - verify passed. Run the on-green procedure now:
  1) ABORT if a destructive / irreversible production operation is in flight (per the project's Critical-tier list, if any). If so, do NOT commit/deploy - just notify + disarm.
  2) git add ONLY the files this run modified - NEVER 'git add -A', never sweep unrelated dirty files.
  3) If ANY staged file is Critical-tier per the project's CLAUDE.md, STOP and ask the user before committing. Otherwise commit + push (per the project's git workflow).
  4) Fire a PushNotification (run complete).
  5) DELETE the sentinel .claude/verify-loop.active to disarm.
"@
    }

    if ($vrc -eq 1) {
        if (($attempt + 1) -ge $maxAttempts) {
            $s.status = 'stopped'; Save-State $s
            Emit-Rewake "[verify-loop] CAP - still RED after $maxAttempts attempts. STOP: (1) write the user a concise account of what was tried and the remaining failure, (2) fire a PushNotification (run blocked), (3) DELETE the sentinel to disarm. Leave code changes in place. Failing output (tail):`n$tail"
        }
        $s.attempt = $attempt + 1; Save-State $s
        Emit-Rewake "[verify-loop] RED - attempt $($attempt + 1)/$maxAttempts. The armed verify command failed. Keep fixing the code until it passes, then stop again (the loop re-checks automatically). Failing output (tail):`n$tail"
    }

    # any other exit code = harness error (verify could not run normally)
    $s.status = 'error'; Save-State $s
    Emit-Rewake "[verify-loop] HARNESS ERROR - verify command exited $vrc (not a normal pass/fail). The verify harness is broken (import crash / infra down / misconfigured command), not the code under test. STOP re-waking: investigate, fix or re-arm with a corrected command, then DELETE the sentinel. Output (tail):`n$tail"

} catch {
    # internal script failure -> mark terminal, re-wake once, else quiet
    try { $s.status = 'error'; Save-State $s } catch { exit 0 }
    Emit-Rewake "[verify-loop] SCRIPT ERROR - the verify-loop hook itself errored: $($_.Exception.Message). DELETE the sentinel and investigate verify-loop.ps1."
}
