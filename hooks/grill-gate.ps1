# grill-gate.ps1 - UserPromptSubmit hook
# Reads the submitted prompt from stdin JSON. If it pattern-matches non-trivial /
# refactor-class / cross-cutting-tooling work, injects a SHORT reminder (via stdout)
# pointing at the grill skills rather than restating their content -- the full
# pre-grill flow (skip-grill threshold, mandatory pre-grill Explore, domain-lens
# dispatch, cite-evidence + contrarian framing rules, facts-vs-decisions split,
# end-of-grill CONTEXT.md checkpoint, autonomy contract) lives in grill-with-docs's
# SKILL.md and must stay single-sourced there -- duplicating it here would drift out
# of sync the next time that skill changes. Trivial prompts produce no output (exit 0).
# ASCII-only on purpose (see CLAUDE.md .ps1 hazards). Fail-open: any error -> exit 0.

$ErrorActionPreference = 'Stop'

# Never block: if stdin isn't piped, there's nothing to read -> exit immediately.
if (-not [Console]::IsInputRedirected) { exit 0 }

try {
    $raw = [Console]::In.ReadToEnd()
    if ([string]::IsNullOrWhiteSpace($raw)) { exit 0 }
    $obj = $raw | ConvertFrom-Json
    $prompt = [string]$obj.prompt
    if ([string]::IsNullOrWhiteSpace($prompt)) { exit 0 }
} catch {
    exit 0
}

try {
    # Each bucket is a distinct SIGNAL of non-trivial scope. Counting how many buckets
    # fire (not just whether ANY fires) is what makes the tier guess scope-adaptive
    # instead of a single binary trigger -- more independent signals firing together
    # is itself evidence of bigger blast radius, separate from which specific words matched.
    $buckets = [ordered]@{
        structural = '(?i)(refactor|re-?architect|re-?design|re-?structure|re-?write|overhaul|consolidat|migrat|rework|redesign|major (refactor|change|rework|overhaul|migration|surgery)|big (refactor|change)|large (refactor|change))'
        systemic   = '(?i)(across (the|multiple|several)|whole (system|pipeline|codebase|module)|multi-?subsystem|new (provider|subsystem|model|pipeline|architecture)|from scratch|high[- ]blast)'
        risk       = '(?i)(schema (change|migration)|change the schema|breaking change)'
        toolingsync = '(?i)(integrat|adopt (all|the|new)|sync (skills|repo|hooks?)|cross-machine|new skill|add (a |new )?skill|update (the )?(hook|skill|agent)s?|bring.*up to (date|speed)|install.*(nativ|on this machine))'
    }

    $hitNames = @()
    foreach ($name in $buckets.Keys) {
        if ($prompt -match $buckets[$name]) { $hitNames += $name }
    }

    if ($hitNames.Count -eq 0) { exit 0 }

    # Tier guess is provisional -- explicitly labelled as such in the message below.
    # grill-with-docs itself calibrates from the pre-grill Explore map, not prompt
    # phrasing; this heuristic exists only to decide whether to speak up at all, and
    # to give a rough starting estimate the model should override once it has explored.
    $riskOrSystemic = ($hitNames -contains 'risk') -or ($hitNames -contains 'systemic')
    if ($riskOrSystemic -or $hitNames.Count -ge 2) {
        $tierGuess = 'major-or-top-tier (25-50 questions, >=6 batched rounds)'
    } else {
        $tierGuess = 'non-trivial (12-18 questions, >=3 batched rounds)'
    }

    # Only recommend skills that are actually installed on THIS machine right now --
    # a machine that hasn't pulled the latest MM-toolbox yet won't be told to invoke
    # something that isn't there. This is what makes the hook adapt to the real
    # installed skill set instead of assuming a fixed one.
    $skillsRoot = Join-Path (Split-Path -Parent $PSScriptRoot) 'skills'
    function Has-Skill($skillName) {
        Test-Path -LiteralPath (Join-Path $skillsRoot $skillName) -PathType Container
    }

    $hasGrillWithDocs = Has-Skill 'grill-with-docs'
    $hasGrillMe = Has-Skill 'grill-me'
    $hasWayfinder = Has-Skill 'wayfinder'

    $grillLine = if ($hasGrillWithDocs -and $hasGrillMe) {
        'Invoke /grill-with-docs (repo with a codebase) or /grill-me (no codebase) via the Skill tool.'
    } elseif ($hasGrillWithDocs) {
        'Invoke /grill-with-docs via the Skill tool.'
    } elseif ($hasGrillMe) {
        'Invoke /grill-me via the Skill tool.'
    } else {
        $null
    }

    if (-not $grillLine) { exit 0 }

    $matchedList = $hitNames -join ', '

    $lines = @()
    $lines += "[grill-gate] Prompt matched non-trivial signal(s): $matchedList. Rough tier guess: $tierGuess -- NOT authoritative; the skill's own pre-grill Explore overrides this guess once it runs."
    $lines += "Per standing convention, before writing any code:"
    $lines += "  1) Skip-grill threshold still applies first: <5 files + 1 subsystem + non-Critical-tier surface = no grill, proceed."
    $lines += "  2) Otherwise, mandatory pre-grill Explore (map the touched surface), THEN $grillLine Do not just ask a couple of inline questions and call it alignment."
    $lines += "  3) Facts vs decisions: look up facts yourself by exploring; every decision goes to the user and waits for their answer -- never answer a decision on their behalf."
    $lines += "  4) Deliver questions as batched, selectable AskUserQuestion rounds (up to 4 per call) -- not one free-text question at a time. Fire successive rounds until aligned."
    $lines += "  5) Close with the autonomy contract (DONE-WHEN, DEFAULTS, DEFERRED) before any long autonomous run."
    if ($hasWayfinder -and ($hitNames -contains 'systemic')) {
        $lines += "  6) If this is bigger than one session can hold, suggest /wayfinder to the user instead of pushing through one long grill -- it is user-invoked, so name it rather than calling it yourself."
    }
    $lines += "See grill-with-docs's SKILL.md for the full flow (quality-lens dispatch, cite-evidence rule, contrarian framing rule, end-of-grill CONTEXT.md checkpoint) -- this reminder is intentionally short so it can't drift out of sync with that file."
    $lines += "(If this is actually a trivial one-liner or mechanical edit, ignore this and proceed.)"

    Write-Output ($lines -join "`n")
    exit 0
} catch {
    exit 0
}
