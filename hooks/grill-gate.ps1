# grill-gate.ps1 - UserPromptSubmit hook
# Reads the submitted prompt from stdin JSON. If it looks like non-trivial /
# refactor-class work, injects a reminder (via stdout) telling the model to:
# run pre-grill Explore, invoke grill-with-docs, ask the tiered count (12-18 /
# 25-35 / 30-50) of batched selectable questions with domain-lens dispatch +
# cite-evidence + contrarian framing + end-of-grill CONTEXT.md checkpoint +
# autonomy contract. Trivial prompts produce no output (exit 0).
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

# Moderate trigger: structural / high-blast-radius verbs and explicitly-major phrasing.
# Deliberately excludes common low-stakes verbs (add/build/implement/fix) to avoid over-firing.
$pattern = '(?i)(refactor|re-?architect|re-?design|re-?structure|re-?write|overhaul|consolidat|migrat|rework|major (refactor|change|rework|overhaul|migration|surgery)|big (refactor|change)|large (refactor|change)|across (the|multiple|several)|whole (system|pipeline|codebase|module)|new (provider|subsystem|model|pipeline|architecture)|schema (change|migration)|change the schema|breaking change|from scratch|high[- ]blast|redesign)'

if ($prompt -notmatch $pattern) { exit 0 }

$msg = @'
[grill-gate] This prompt looks like non-trivial / refactor-class work. Per the user's standing preference, BEFORE writing any code:
  1) SKIP-GRILL THRESHOLD: <5 files + 1 subsystem + non-Critical-tier surface = no grill required. Otherwise proceed.
  2) PRE-GRILL EXPLORE (MANDATORY for any non-trivial change): spawn an Explore subagent to map the touched surface (files, subsystems, recurring concepts, prior decisions, related memory) BEFORE round 1. Calibrate question count from the map size, NOT from a pattern-match on the prompt. The ~30-60s pays back in question quality.
  3) Invoke the grill-with-docs skill via the Skill tool - actually run it; do NOT just ask a couple of inline questions and call it alignment.
  4) Ask the right question count for the scope, delivered as BATCHED selectable AskUserQuestion rounds (up to 4 per call, each with selectable options + free-text 'Other'):
     - non-trivial change: 12-18 questions, >= 3 batched rounds
     - major refactor / new subsystem / Critical-tier surface: 25-35 questions, >= 6 batched rounds
     - top-tier scope (multi-subsystem refactor / new subsystem from scratch / deep research with >5 unknowns): 30-50 questions, >= 8 batched rounds
     Fire successive rounds until aligned. Do NOT stop at 3.
  5) DOMAIN-LENS DISPATCH: classify the domain and emit required quality lenses. DB/data-pipeline/infra -> scalability + efficiency + production + long-term. Business-logic/signal -> production + long-term. Frontend -> UX + accessibility + maintainability. Auth/security -> threat-model + compliance. >=1 question per round must hit each required lens.
  6) CITE-EVIDENCE RULE: every question references a file:line, memory entry, or skill - no preference-bare questions ("what do you want?"). Read the code before asking, not after.
  7) CONTRARIAN FRAMING RULE: >=1 question per round CHALLENGES the plan with a concrete failure mode - not just clarifies it. "Wrong abstraction?", "what breaks at 10x?", "12-month obsolescence risk?". The long-term / end-vision lens is what gets missed most often.
  8) Override the grill skill's "one question at a time" default - batched selectable rounds.
  9) END-OF-GRILL CONTEXT.md CHECKPOINT: the final round always asks "novel terms used: X, Y, Z - add to CONTEXT.md?" with selectable options. Stops glossary debt accumulating across grills.
 10) Sharpen any fuzzy/overloaded terms into CONTEXT.md inline as decisions crystallise.
 11) Close the grill with an AUTONOMY CONTRACT in the spec - DONE-WHEN (machine-checkable stop), DEFAULTS (pre-authorized choices for foreseeable mid-run forks), DEFERRED (postponed decisions + their resurface trigger). Get sign-off, then execute autonomously - background agent/team by default; one-line progress ping per milestone; PushNotification on done-or-blocked.
If you are genuinely unsure whether this task needs the full grill, ASK "should I grill you on this first / ask more questions?" rather than guessing. Default to asking MORE when scope is ambiguous.
(If this is actually a trivial one-liner or mechanical edit, ignore this and proceed.)
'@

Write-Output $msg
exit 0
