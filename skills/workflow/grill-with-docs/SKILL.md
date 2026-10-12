---
name: grill-with-docs
description: Grilling session that challenges your plan against the existing domain model, sharpens terminology, and updates documentation (CONTEXT.md, ADRs) inline as decisions crystallise. Use when user wants to stress-test a plan against their project's language and documented decisions.
---

<what-to-do>

Stress-test the plan until shared understanding is sufficient to act safely. Resolve only decisions whose alternatives materially change the implementation, risk, cost, or outcome. For each question, provide your recommended answer.

**Required pre-grill flow:**
1. **Sufficiency check:** if the prompt and existing evidence already settle the objective, constraints, and success criterion, do not manufacture questions; summarize the understood contract and proceed to sign-off or execution as appropriate.
2. **Explore when useful:** inspect the codebase, docs, history, and prior decisions before asking factual questions. Use a read-only scout only when the surface is broad or unfamiliar enough that it will materially improve the questions.
3. **Classify domain → relevant quality lenses** (see Quality lenses below). Cover a lens only when it exposes a plausible consequential decision.

**Delivery format (REQUIRED — overrides any "one at a time" default):**

Ask in **batched, selectable `AskUserQuestion` rounds** — up to 4 per call, each with selectable options + free-text "Other" — firing successive rounds until aligned. **NOT** one free-text question at a time. The user strongly prefers clicking answers.

**Adaptive stopping rule:**
- There is no minimum number of questions or rounds.
- Ask all currently known consequential questions in one batch (up to 4).
- Ask a later batch only when an answer reveals a new consequential fork that could not reasonably have been asked earlier.
- Stop immediately when the remaining uncertainty can be resolved from evidence, handled by an agreed default, or does not materially affect the result.
- Complexity increases the breadth of risks to inspect; it does not create a quota of questions.

**Facts vs decisions:** if a *fact* can be found by exploring the codebase, look it up rather than asking. The *decisions*, though, are the user's alone — put each one to them and wait for their answer. "Explore instead of asking" is licence to skip asking for facts; it is never licence to answer a decision on the user's behalf. This matters most when this skill runs unattended inside another flow (e.g. `/wayfinder`, `/improve-codebase-architecture`) rather than directly against a live human — a grilling step that answers its own decisions has broken the human-in-the-loop contract by definition.

</what-to-do>

<supporting-info>

## Building the domain model — run `/domain-modeling`

This skill actively builds and sharpens the project's domain model (`CONTEXT.md`, ADRs in `docs/adr/`) as decisions crystallise during the grill — that discipline (challenging fuzzy terms against the glossary, stress-testing scenarios, cross-referencing the code, updating `CONTEXT.md` inline, when an ADR earns its keep) lives in the `domain-modeling` skill so `improve-codebase-architecture` and other skills can reuse it too. Run `/domain-modeling` **inline, throughout the grill** — not as a separate pass at the end. It also defines the file-structure convention (single `CONTEXT.md` vs a multi-context `CONTEXT-MAP.md`) for repos this skill hasn't seen before.

## Quality lenses (domain dispatch)

After classifying the domain from the prompt and available evidence, use the applicable lenses as a review checklist. Ask about a lens only when it reveals a real unresolved decision. Do not force one question per lens or per round.

- **DB / data-pipeline / infra / dev-tooling** → scalability + efficiency + production + long-term
- **Business-logic / domain rules / data transforms / pricing** → production + long-term + temporal-correctness (ordering / look-ahead) + downstream-invalidation
- **Frontend / UI** → UX + accessibility + maintainability + performance
- **Auth / security / payments / compliance** → threat-model + compliance + production + long-term
- **Workflow / config / cross-machine tooling** → portability + maintainability + scalability + sync-drift

## Cite-evidence rule

Every question must reference a file:line, memory entry, skill, recent commit, or a specific named asset — **not just a preference** ("what do you want?"). This forces reading the code before asking. Lazy framing ("any thoughts on X?") is banned; replace with a concrete probe anchored to specific code or decisions.

## Contrarian framing rule

Challenge the user's plan with a concrete failure mode when a plausible failure mode is relevant. Do not add a contrarian question solely to satisfy the format. Templates:

- "What breaks at 10× the current load?"
- "Is this the wrong abstraction — what if we inverted it and did X instead?"
- "12-month obsolescence risk: what would make this design embarrassing in a year?"
- "Who's the worst-case caller / failure path here?"
- "What's the cheapest, ugliest alternative that satisfies 80% of the goal?"

## End-of-grill CONTEXT.md checkpoint

When the grill introduces durable project-domain terms that are novel, fuzzy, or overloaded, include a final selectable question offering to add them to `CONTEXT.md`. Skip this checkpoint when no such terms were introduced.

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
