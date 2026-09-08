# grill-gate.ps1 - UserPromptSubmit hook. DEFAULT IS PROCEED.
#
# HISTORY, because both previous versions were wrong in opposite directions.
# v1 pattern-matched the prompt text to decide whether to fire, and could not tell a
# task from a question -- false positives on discussion, false negatives on real work.
# v2 fired unconditionally and told the model to ask a selectable
# "proceed / light-touch / full grill" question every time. Measured outcome: the
# operator chose `proceed` every single time it was shown. A question whose answer is
# known in advance costs a full round trip and buys nothing, and it trained sessions to
# treat stopping-to-ask as the normal shape of work.
#
# v3 keeps the unconditional fire -- momentum really does bury a scope check -- but
# inverts the default. The model states its read in ONE line and starts. A question is
# reserved for the cases where being wrong is expensive and unrecoverable.
#
# ASCII-only on purpose (see CLAUDE.md .ps1 hazards). Fail-open: any error -> exit 0.

$ErrorActionPreference = 'Stop'

if (-not [Console]::IsInputRedirected) { exit 0 }

try {
    $raw = [Console]::In.ReadToEnd()
    if ([string]::IsNullOrWhiteSpace($raw)) { exit 0 }
    # Parsed only to honour the hook I/O contract and fail open on malformed input --
    # the prompt text is deliberately never inspected; see the header for why.
    $null = $raw | ConvertFrom-Json
} catch {
    exit 0
}

try {
    $lines = @()
    $lines += "[gate] Standing per-prompt check. It does not read your prompt - the scope judgment is yours, every time."
    $lines += "DEFAULT IS PROCEED. State your scope read and effort estimate in ONE line, then start working. Trivial or conversational: just answer."
    $lines += "Ask a batched AskUserQuestion ONLY if one of these holds: (a) the act is irreversible or outward-facing - production, money, deletion, secrets, a third party; (b) two readings of the request would produce materially different deliverables AND nothing on hand settles it - not the code, not a recorded ruling, not a DEFAULT from a prior ledger; (c) another rule requires a named approval, e.g. the operator-patch lane."
    $lines += "Otherwise pick the reading a careful colleague would pick, record it as an ASSUMPTION, say so in one line, and keep moving. Do NOT offer a 'proceed / light-touch / full grill' menu - it has been answered 'proceed' every time it has been shown."
    $lines += "Deep alignment stays available ON REQUEST: /grill-with-docs when the operator asks for it."
    $lines += "When work remains, carry on under your own judgement (CLAUDE.md -> 'Continuing without being told'): finish what is genuinely outstanding, and stop when it genuinely is not. Nothing forces you either way - decide, and say which you decided and why."

    Write-Output ($lines -join "`n")
    exit 0
} catch {
    exit 0
}