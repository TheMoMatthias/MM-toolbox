---
name: grill-with-docs
description: Grilling session that challenges your plan against the existing domain model, sharpens terminology, and updates documentation (CONTEXT.md, ADRs) inline as decisions crystallise. Use when user wants to stress-test a plan against their project's language and documented decisions.
---

<what-to-do>

Interview me relentlessly about every aspect of this plan until we reach a shared understanding. Walk down each branch of the design tree, resolving dependencies between decisions one-by-one. For each question, provide your recommended answer.

**Required pre-grill flow:**
1. **Skip-grill check:** if the work is <5 files + 1 subsystem + non-Critical-tier surface, skip the grill and execute. Otherwise continue.
2. **Pre-grill Explore (MANDATORY):** spawn an `Explore` subagent to map the touched surface (files, subsystems, recurring concepts, related memory entries, prior decisions) BEFORE round 1. Calibrate question count from the actual map size — not from a pattern-match on the prompt phrasing.
3. **Classify domain → required quality lenses** (see Quality lenses below). ≥1 question per round must hit each required lens.

**Delivery format (REQUIRED — overrides any "one at a time" default):**

Ask in **batched, selectable `AskUserQuestion` rounds** — up to 4 per call, each with selectable options + free-text "Other" — firing successive rounds until aligned. **NOT** one free-text question at a time. The user strongly prefers clicking answers.

**Scope-based question count:**
- non-trivial change: 12–18 questions across ≥3 batched rounds
- major refactor / new subsystem / Critical-tier surface: 25–35 questions across ≥6 batched rounds
- top-tier scope (multi-subsystem refactor, new-from-scratch, deep research with >5 open unknowns): 30–50 questions across ≥8 batched rounds
- When scope is ambiguous, default to asking MORE.

**Facts vs decisions:** if a *fact* can be found by exploring the codebase, look it up rather than asking. The *decisions*, though, are the user's alone — put each one to them and wait for their answer. "Explore instead of asking" is licence to skip asking for facts; it is never licence to answer a decision on the user's behalf. This matters most when this skill runs unattended inside another flow (e.g. `/wayfinder`, `/improve-codebase-architecture`) rather than directly against a live human — a grilling step that answers its own decisions has broken the human-in-the-loop contract by definition.

</what-to-do>

<supporting-info>

## Building the domain model — run `/domain-modeling`

This skill actively builds and sharpens the project's domain model (`CONTEXT.md`, ADRs in `docs/adr/`) as decisions crystallise during the grill — that discipline (challenging fuzzy terms against the glossary, stress-testing scenarios, cross-referencing the code, updating `CONTEXT.md` inline, when an ADR earns its keep) lives in the `domain-modeling` skill so `improve-codebase-architecture` and other skills can reuse it too. Run `/domain-modeling` **inline, throughout the grill** — not as a separate pass at the end. It also defines the file-structure convention (single `CONTEXT.md` vs a multi-context `CONTEXT-MAP.md`) for repos this skill hasn't seen before.

## Quality lenses (domain dispatch)

After classifying the domain from the prompt + Explore map, every round MUST cover the required lenses. **≥1 question per round per required lens.** If the prompt spans multiple domains, take the union of lenses.

- **DB / data-pipeline / infra / dev-tooling** → scalability + efficiency + production + long-term
- **Business-logic / signal-design / labeling / transforms / pricing** → production + long-term + look-ahead-risk + downstream-invalidation
- **Frontend / UI** → UX + accessibility + maintainability + performance
- **Auth / security / payments / compliance** → threat-model + compliance + production + long-term
- **Workflow / config / cross-machine tooling** → portability + maintainability + scalability + sync-drift

## Cite-evidence rule

Every question must reference a file:line, memory entry, skill, recent commit, or a specific named asset — **not just a preference** ("what do you want?"). This forces reading the code before asking. Lazy framing ("any thoughts on X?") is banned; replace with a concrete probe anchored to specific code or decisions.

## Contrarian framing rule

In every round, **AT LEAST ONE question must CHALLENGE** the user's plan with a concrete failure mode — not just clarify it. The long-term / end-vision lens is what gets missed most often without this discipline. Templates:

- "What breaks at 10× the current load?"
- "Is this the wrong abstraction — what if we inverted it and did X instead?"
- "12-month obsolescence risk: what would make this design embarrassing in a year?"
- "Who's the worst-case caller / failure path here?"
- "What's the cheapest, ugliest alternative that satisfies 80% of the goal?"

## End-of-grill CONTEXT.md checkpoint

Even though `/domain-modeling` should already be updating `CONTEXT.md` inline throughout (still preferred), the **final round must always include a question of the form**: "I used these novel terms in this grill: X, Y, Z — add to CONTEXT.md?" with selectable options.

This is a backstop against glossary debt accumulating across grills — the failure mode where many novel recurring terms are introduced in a session but none get canonicalized because each individually felt minor. Workflow / process terms (autonomy contract, DONE-WHEN, DEFAULTS, DEFERRED, skip-grill threshold) do **NOT** belong in the project's `CONTEXT.md` — they're meta-process, not codebase glossary. This checkpoint is this skill's own addition on top of `/domain-modeling` — the shared skill has no notion of "end of grill."

## Close with the autonomy contract

End the grill by writing — into the spec / run-file — the three fields that license a long *unattended* run:

- **DONE-WHEN** — the machine-checkable stop condition (tests green, parity diff empty, metric threshold met). What lets the run stop *without* asking.
- **DEFAULTS** — pre-authorized choices for foreseeable mid-run forks, so the run proceeds instead of pausing.
- **DEFERRED** — decisions postponed on purpose, each with the exact trigger that will resurface it.

Present these alongside the shared-understanding summary and get sign-off. They are what turn "shared understanding" into "permission to run for a long time on its own."

## Delivery format

Ask in **batched, selectable `AskUserQuestion` rounds** (up to 4 per call, options + free-text "Other"), firing successive rounds until aligned — *not* one free-text question at a time. This overrides the one-at-a-time default above; the user prefers clicking answers.

</supporting-info>
