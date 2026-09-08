# objective-loop.ps1 - GLOBAL Stop hook: a session does not end while its own
# objectives are open. THE OPERATOR ALWAYS OUTRANKS THIS HOOK.
#
# WHY THIS EXISTS. Until 2026-09-08 the global CLAUDE.md described a "self-healing
# verify loop" as an INSTALLED Stop hook. It was never registered in settings.json --
# the hooks block held UserPromptSubmit only -- so nothing on this machine could
# continue a session after it stopped. Every "it stopped with work outstanding" had
# exactly one mechanism that was supposed to prevent it, and that mechanism had never
# run. The rule read as installed, which is why nobody re-derived it.
#
# AND A VERIFY LOOP WOULD NOT HAVE BEEN ENOUGH. It re-runs a verify command, so it
# answers "do the tests pass". The thing that actually goes missing is "is the
# objective complete, including what was discovered on the way". That is what this
# hook holds, and it holds it in a file the model must keep honest.
#
# ============================ OPERATOR OVERRIDE ==============================
# Reported 2026-09-08 by the operator: they told a session to stop, it stopped, and
# this hook re-continued it anyway. That is unacceptable -- a mechanism built to
# coerce the MODEL must never be able to coerce the PERSON. Three independent
# overrides, any one of which disarms the loop for the rest of the session:
#
#   1. LITERAL TOKEN - the last operator message contains `!stop` (or `stop loop`).
#      Exact match, cannot misfire, and it is printed in EVERY block message, so the
#      way out is always visible at the moment it is needed.
#   2. SHORT PLAIN STOP - the last operator message is a short, unambiguous stop
#      ("stop", "halt", "that's enough", "park it"...). Deliberately narrow: <= 80
#      chars, anchored to the whole message, and negations ("don't stop", "keep
#      going") are excluded. This is the ONLY content-matching in this hook and it is
#      kept tight on purpose -- grill-gate v1 failed at exactly this, and its lesson
#      is written up in hooks/README.md.
#   3. ANY INTERJECTION - CONTENT-BLIND, AND THE PRIMARY GUARD. If the operator typed
#      ANYTHING since the last time this hook blocked, they are steering; the loop
#      stands down. No parsing, no keyword list, no guess about what they meant. This
#      is what actually fixes the reported behaviour; 1 and 2 only make it faster.
#
# EVERY AMBIGUITY HERE RESOLVES TOWARD STOPPING. A loop that over-stops is merely the
# old behaviour; a loop that ignores the operator is a broken tool. So a transcript we
# cannot parse, a count we cannot trust, or a message we half-recognise all bias to
# "stand down", never to "keep pushing".
# =============================================================================
#
# CONTRACT
#   ledger : %USERPROFILE%\.claude\state\objective-loop\<session_id>.json   (model writes)
#   state  : %USERPROFILE%\.claude\state\objective-loop\<session_id>.state  (hook owns)
#
#   ledger schema:
#     { "status": "working" | "blocked" | "parked" | "complete",
#       "blocked_reason": "...",            # required when status=blocked
#       "max_rewakes": 30, "deadline_epoch": 0,   # optional overrides
#       "items": [ { "id":"1", "what":"...", "done_when":"...",
#                    "done": false, "evidence": "" } ] }
#
#   operator stop      -> disarm permanently, exit 0 (checked FIRST, before anything)
#   no ledger          -> re-wake ONCE per session with the close-out demand, then quiet
#   status=blocked     -> quiet at once (only the operator can move it)
#   status=parked      -> quiet at once (deliberate park, e.g. lane-tranche discipline)
#   any item open      -> re-wake with the open list, until a cap
#   done with no evid. -> re-wake demanding evidence: a done item with no evidence is a
#                         claim, not a result, and this is the one part a hook CAN check
#   complete + open    -> re-wake: the declaration contradicts the list
#   cap hit            -> re-wake ONCE telling it to report and notify, then quiet
#
# DELIBERATELY IGNORES stop_hook_active. Honouring it caps the loop at exactly one
# continuation, which is the behaviour this hook exists to remove. What bounds the loop
# instead is the pair of hard caps -- re-wake count AND wall clock -- recorded in the
# hook-owned state file where the model cannot quietly reset them, plus the operator
# overrides above, which are not bounded at all because they are not the model's to spend.
#
# Emits BOTH forms on purpose: {"decision":"block","reason":...} on stdout AND the same
# text on stderr with exit 2. Whichever contract this build honours, the text reaches the
# model. A hook that is silent because it guessed the wrong output shape is the failure
# this replaces.
#
# ASCII-only (PS 5.1 reads .ps1 as ANSI). Fail-open: any internal error -> exit 0.

$ErrorActionPreference = 'Stop'

if (-not [Console]::IsInputRedirected) { exit 0 }

$DEFAULT_MAX_REWAKES = 30
$DEFAULT_MAX_HOURS   = 8

try {
    $raw = [Console]::In.ReadToEnd()
    if ([string]::IsNullOrWhiteSpace($raw)) { exit 0 }
    $inp = $raw | ConvertFrom-Json
} catch { exit 0 }

try {
    $sid = [string]$inp.session_id
    if ([string]::IsNullOrWhiteSpace($sid)) { exit 0 }
    if ($sid -notmatch '^[A-Za-z0-9_.-]{1,128}$') { exit 0 }
    $transcript = [string]$inp.transcript_path

    $stateDir = Join-Path $env:USERPROFILE '.claude\state\objective-loop'
    if (-not (Test-Path -LiteralPath $stateDir)) {
        New-Item -ItemType Directory -Path $stateDir -Force | Out-Null
    }
    $ledgerPath = Join-Path $stateDir "$sid.json"
    $statePath  = Join-Path $stateDir "$sid.state"
} catch { exit 0 }

function Load-State {
    if (Test-Path -LiteralPath $script:statePath) {
        try { return (Get-Content -LiteralPath $script:statePath -Raw | ConvertFrom-Json) } catch { }
    }
    return [pscustomobject]@{
        rewakes                 = 0
        notified_nofile         = $false
        notified_cap            = $false
        operator_stop           = $false
        blocked_once            = $false
        user_msgs_at_last_block = -1
        first_seen              = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
    }
}
function Save-State($s) {
    try { $s | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $script:statePath -Encoding ASCII } catch { }
}
function Ensure-Field($obj, $name, $default) {
    if (-not $obj.PSObject.Properties[$name]) {
        $obj | Add-Member -NotePropertyName $name -NotePropertyValue $default
    }
}
function Emit-Block($msg) {
    $full = $msg + @"


-------------------------------------------------------------------------------
OPERATOR: this loop is holding the session open. To end it right now, reply with
  !stop
Anything you type at all also stands the loop down - it never argues with you.
-------------------------------------------------------------------------------
"@
    $payload = [pscustomobject]@{ decision = 'block'; reason = $full } | ConvertTo-Json -Depth 4 -Compress
    [Console]::Out.WriteLine($payload)
    [Console]::Error.WriteLine($full)
    exit 2
}

# Count the operator's OWN typed messages in the transcript, and return the text of the
# last one. A tool_result is recorded as a user-role entry and is NOT the operator
# typing, so those are excluded -- counting them would read the model's own work as an
# interjection and disarm the loop on its first tool call.
function Get-UserActivity {
    param([string]$Path)
    $res = [pscustomobject]@{ count = -1; last = '' }          # count = -1 means "unknown"
    if ([string]::IsNullOrWhiteSpace($Path)) { return $res }
    if (-not (Test-Path -LiteralPath $Path)) { return $res }
    try { $lines = @(Get-Content -LiteralPath $Path -ErrorAction Stop) } catch { return $res }

    $n = 0
    $lastText = ''
    foreach ($ln in $lines) {
        if ([string]::IsNullOrWhiteSpace($ln)) { continue }
        if (($ln -notlike '*"type":"user"*') -and ($ln -notlike '*"type": "user"*')) { continue }
        if ($ln -like '*tool_result*')   { continue }
        if ($ln -like '*"isMeta":true*') { continue }
        $n++
        try {
            $o = $ln | ConvertFrom-Json
            $c = $o.message.content
            if ($c -is [string]) { $lastText = $c }
            elseif ($c) { $lastText = ((@($c | ForEach-Object { [string]$_.text }) | Where-Object { $_ }) -join ' ') }
        } catch { }
    }
    $res.count = $n
    $res.last  = [string]$lastText
    return $res
}

function Test-OperatorStop {
    param([string]$Text)
    if ([string]::IsNullOrWhiteSpace($Text)) { return $false }
    $t = $Text.Trim()

    # 1. Literal token - exact, cannot misfire.
    if ($t -match '(?i)(^|\s)!stop(\s|$)')        { return $true }
    if ($t -match '(?i)^\s*stop\s+loop\s*[.!]*$') { return $true }

    # 2. A short, unambiguous plain-language stop. Negations win, and the whole message
    #    must BE the stop -- "stop the scheduler when you can" is a task, not a stop.
    if ($t.Length -gt 80) { return $false }
    if ($t -match '(?i)(do\s?n.?t|dont|never|no\s+need\s+to)\s+stop')     { return $false }
    if ($t -match '(?i)(keep\s+going|carry\s+on|continue|don.?t\s+park)') { return $false }
    if ($t -match '(?i)^\s*(stop|halt|abort|cancel|pause|quit|park(\s+it)?|enough|that.?s\s+enough|that.?s\s+all|we.?re\s+done|you.?re\s+done|leave\s+it(\s+there)?|hold\s+on|wait)\b[\s.,!]*$') { return $true }
    return $false
}

try {
    $st = Load-State
    # A state file written by an older build lacks the override fields; add them rather
    # than reading $null as 0 and mistaking "unknown" for "no messages yet".
    Ensure-Field $st 'operator_stop'           $false
    Ensure-Field $st 'blocked_once'            $false
    Ensure-Field $st 'user_msgs_at_last_block' -1
    $now = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()

    # ============ OPERATOR OVERRIDES - CHECKED BEFORE ANYTHING ELSE ==============
    if ($st.operator_stop) { exit 0 }                     # already stood down this session

    $act = Get-UserActivity $transcript

    if (Test-OperatorStop $act.last) {
        $st.operator_stop = $true; Save-State $st
        exit 0
    }

    # Content-blind: the operator has typed since we last blocked -> they are steering.
    if ($st.blocked_once -and $act.count -ge 0 -and [int]$st.user_msgs_at_last_block -ge 0 `
        -and $act.count -gt [int]$st.user_msgs_at_last_block) {
        $st.operator_stop = $true; Save-State $st
        exit 0
    }
    # =============================================================================

    # ---------- no ledger: one mandatory close-out, then quiet ----------
    if (-not (Test-Path -LiteralPath $ledgerPath)) {
        if ($st.notified_nofile) { exit 0 }
        $st.notified_nofile = $true
        $st.blocked_once = $true
        $st.user_msgs_at_last_block = $act.count
        Save-State $st
        Emit-Block @"
[objective-loop] Do not end here yet - account for this session first. This fires once.

1. RE-READ what was actually asked (the user's own messages in this conversation, not your
   recollection of them) and list EVERY outstanding item: what was requested, what you
   discovered along the way that a careful colleague would finish, and every assumption you
   proceeded on. A follow-up you deferred is an item. A test you did not run is an item.
2. If ANY item is not done: KEEP WORKING. You have standing authority for everything inside
   the agreed scope - do not ask, do it, and report once at the end.
3. Write the ledger so this check can hold you to it, at exactly this path:
     $ledgerPath
   {"status":"working","items":[{"id":"1","what":"...","done_when":"...","done":false,"evidence":""}]}
   - done:true REQUIRES a non-empty evidence string - the command you ran and its summary
     line, or file:line. A done item with no evidence is a claim, not a result, and this
     hook will send it back.
   - APPEND discovered work as new items. Do not narrate a finding in prose and move on.
4. Only three things end a session: every item done WITH evidence; a stop-class gate (an
   irreversible or outward-facing act that needs the operator); or a genuine blocker
   recorded as {"status":"blocked","blocked_reason":"..."} - something you cannot resolve,
   not something merely hard or slow. A deliberate park (lane-tranche discipline) is
   {"status":"parked"}.
5. IF THE OPERATOR HAS ASKED YOU TO STOP: write {"status":"parked"} to the ledger and stop.
   Their instruction outranks this check, always. Never argue with it or work around it.

If you have genuinely finished, write the ledger with every item done and evidence filled
in, and stop. That takes one turn and leaves a record.
"@
    }

    # ---------- ledger present ----------
    try {
        $led = Get-Content -LiteralPath $ledgerPath -Raw | ConvertFrom-Json
    } catch {
        $st.blocked_once = $true; $st.user_msgs_at_last_block = $act.count; Save-State $st
        Emit-Block "[objective-loop] The ledger at $ledgerPath is not valid JSON and this check cannot read it. Rewrite it correctly (schema is in the hook header and in CLAUDE.md), then stop again."
    }

    $status = [string]$led.status
    if ($status -eq 'blocked') {
        if ([string]::IsNullOrWhiteSpace([string]$led.blocked_reason)) {
            $st.blocked_once = $true; $st.user_msgs_at_last_block = $act.count; Save-State $st
            Emit-Block "[objective-loop] status=blocked with no blocked_reason. A blocker that names nothing is a stop with extra steps. Record what specifically you cannot resolve and who or what would unblock it, then stop."
        }
        exit 0
    }
    if ($status -eq 'parked') { exit 0 }

    $items = @()
    if ($null -ne $led.items) { $items = @($led.items) }

    $open       = @($items | Where-Object { -not $_.done })
    $noEvidence = @($items | Where-Object { $_.done -and [string]::IsNullOrWhiteSpace([string]$_.evidence) })

    if ($open.Count -eq 0 -and $noEvidence.Count -eq 0) { exit 0 }   # genuinely finished

    # ---------- caps ----------
    $maxRewakes = $DEFAULT_MAX_REWAKES
    if ($led.max_rewakes -and [int]$led.max_rewakes -gt 0) { $maxRewakes = [int]$led.max_rewakes }
    $deadline = [long]0
    if ($led.deadline_epoch) { $deadline = [long]$led.deadline_epoch }
    if ($deadline -le 0) { $deadline = [long]$st.first_seen + ($DEFAULT_MAX_HOURS * 3600) }

    if ([int]$st.rewakes -ge $maxRewakes -or $now -gt $deadline) {
        if ($st.notified_cap) { exit 0 }
        $st.notified_cap = $true
        $st.blocked_once = $true; $st.user_msgs_at_last_block = $act.count
        Save-State $st
        $why = if ($now -gt $deadline) { "wall-clock deadline" } else { "re-wake cap ($maxRewakes)" }
        Emit-Block "[objective-loop] CAP - $why reached with $($open.Count) item(s) still open. Stop the loop properly: (1) write the user a concise account of what was done, what remains, and what specifically is in the way; (2) fire a PushNotification; (3) set the ledger to {""status"":""blocked"",""blocked_reason"":""...""}. Leave all work in place. Do not silently mark items done to escape this."
    }

    # ---------- evidence first: a done claim with nothing behind it ----------
    if ($noEvidence.Count -gt 0) {
        $st.rewakes = [int]$st.rewakes + 1
        $st.blocked_once = $true; $st.user_msgs_at_last_block = $act.count
        Save-State $st
        $ids = ($noEvidence | ForEach-Object { [string]$_.id }) -join ', '
        Emit-Block "[objective-loop] $($noEvidence.Count) item(s) marked done with NO evidence: $ids. That is a claim, not a result - it reads identically whether you did the work or not. For each: fill evidence with the command you ran and its summary line, or file:line. If you cannot, set done back to false and finish it. ($($open.Count) other item(s) still open.)"
    }

    # ---------- open items ----------
    $st.rewakes = [int]$st.rewakes + 1
    $st.blocked_once = $true; $st.user_msgs_at_last_block = $act.count
    Save-State $st

    $listing = ($open | ForEach-Object {
        $dw = [string]$_.done_when
        if ([string]::IsNullOrWhiteSpace($dw)) { $dw = '(no done_when recorded - write one)' }
        "  - [$([string]$_.id)] $([string]$_.what)`n        done_when: $dw"
    }) -join "`n"

    $declared = ''
    if ($status -eq 'complete') {
        $declared = "`nYou set status=complete while $($open.Count) item(s) are still open. The list is the truth; the declaration is not.`n"
    }

    Emit-Block @"
[objective-loop] $($open.Count) item(s) still open (re-wake $($st.rewakes)/$maxRewakes). Keep going - do not report and stop.
$declared
OPEN:
$listing

Rules for this continuation:
  - Work the list. Everything on it is inside already-agreed scope, so act - do not ask.
  - APPEND anything you discover to the ledger as a new item rather than mentioning it in
    prose. Discovered work that only appears in a recap is work that gets dropped.
  - Mark an item done ONLY with evidence (command + its summary line, or file:line).
  - On a wall: diagnose and switch approach ONCE. Only if the second approach also fails
    does it become {"status":"blocked","blocked_reason":"..."}.
  - If a remaining item genuinely needs the operator (irreversible, outward-facing, or a
    fork with no recorded default), finish every other item FIRST, then ask once - batched.
  - IF THE OPERATOR ASKED YOU TO STOP: write {"status":"parked"} and stop. They outrank
    this check, always.

Ledger: $ledgerPath
"@

} catch {
    exit 0
}
