# grill-gate.ps1 - UserPromptSubmit hook
# Fires on EVERY prompt, unconditionally -- no keyword/content matching. The previous
# version tried to guess "does this look non-trivial" from prompt text (regex over
# structural/systemic/risk/tooling-sync buckets) and kept mis-firing: false positives
# on discussion/question prompts (regex can't tell a task from a question), false
# negatives on prompts that needed the grill but used no trigger words. Classifying
# scope is a judgment call that requires actually reading the request -- a pre-flight
# hook structurally cannot do that, so this version stopped trying.
#
# What this version guarantees instead: a fresh, per-prompt nudge to actually apply
# the mandatory grill gate from CLAUDE.md, so the check can't silently get skipped
# under mid-session momentum (deep in execute-mode on other agreed work, a new
# non-trivial ask slips by without re-triggering alignment). The judgment itself --
# is THIS prompt trivial, light-touch, non-trivial, major, or top-tier -- stays with
# the model every time, because only the model can actually read the request; this
# hook never attempts that classification itself.
# ASCII-only on purpose (see CLAUDE.md .ps1 hazards). Fail-open: any error -> exit 0.

$ErrorActionPreference = 'Stop'

if (-not [Console]::IsInputRedirected) { exit 0 }

try {
    $raw = [Console]::In.ReadToEnd()
    if ([string]::IsNullOrWhiteSpace($raw)) { exit 0 }
    # Parsed only to stay consistent with the hook's I/O contract and fail open on
    # malformed input -- the prompt text itself is deliberately never inspected;
    # see the header comment for why.
    $null = $raw | ConvertFrom-Json
} catch {
    exit 0
}

try {
    # Only name skills that are actually installed on this machine -- a machine that
    # hasn't pulled the latest MM-toolbox yet won't be told to invoke something that
    # isn't there.
    $skillsRoot = Join-Path (Split-Path -Parent $PSScriptRoot) 'skills'
    function Has-Skill($skillName) {
        Test-Path -LiteralPath (Join-Path $skillsRoot $skillName) -PathType Container
    }

    $hasGrillWithDocs = Has-Skill 'grill-with-docs'
    $hasGrillMe = Has-Skill 'grill-me'

    $grillLine = if ($hasGrillWithDocs -and $hasGrillMe) {
        '/grill-with-docs (repo with a codebase) or /grill-me (no codebase)'
    } elseif ($hasGrillWithDocs) {
        '/grill-with-docs'
    } elseif ($hasGrillMe) {
        '/grill-me'
    } else {
        $null
    }

    if (-not $grillLine) { exit 0 }

    $lines = @()
    $lines += "[grill-gate] Standing per-prompt check (CLAUDE.md 'Mandatory grill gate') -- fires every time on purpose, it does not read the prompt to decide anything."
    $lines += "If what was just asked is obviously trivial or purely conversational, proceed/reply normally -- nothing to surface."
    $lines += "Otherwise, before acting: state your own scope read (light-touch / non-trivial / major / top-tier) and effort estimate, then ask one selectable AskUserQuestion offering proceed / light-touch / full grill via $grillLine. Always state your own judgment -- the user relies on it most in territory they can't size up themselves."
    $lines += "Skip this entirely if the current prompt is just answering a gate question you already asked this turn."

    Write-Output ($lines -join "`n")
    exit 0
} catch {
    exit 0
}
