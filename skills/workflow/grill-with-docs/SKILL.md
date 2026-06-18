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

If a question can be answered by exploring the codebase, explore the codebase instead of asking.

</what-to-do>

<supporting-info>

## Domain awareness

During codebase exploration, also look for existing documentation:

### File structure

Most repos have a single context:

```
/
├── CONTEXT.md
├── docs/
│   └── adr/
│       ├── 0001-event-sourced-orders.md
│       └── 0002-postgres-for-write-model.md
└── src/
```

If a `CONTEXT-MAP.md` exists at the root, the repo has multiple contexts. The map points to where each one lives:

```
/
├── CONTEXT-MAP.md
├── docs/
│   └── adr/                          ← system-wide decisions
├── src/
│   ├── ordering/
│   │   ├── CONTEXT.md
│   │   └── docs/adr/                 ← context-specific decisions
│   └── billing/
│       ├── CONTEXT.md
│       └── docs/adr/
```

Create files lazily — only when you have something to write. If no `CONTEXT.md` exists, create one when the first term is resolved. If no `docs/adr/` exists, create it when the first ADR is needed.

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

## During the session

### Challenge against the glossary

When the user uses a term that conflicts with the existing language in `CONTEXT.md`, call it out immediately. "Your glossary defines 'cancellation' as X, but you seem to mean Y — which is it?"

### Sharpen fuzzy language

When the user uses vague or overloaded terms, propose a precise canonical term. "You're saying 'account' — do you mean the Customer or the User? Those are different things."

### Discuss concrete scenarios

When domain relationships are being discussed, stress-test them with specific scenarios. Invent scenarios that probe edge cases and force the user to be precise about the boundaries between concepts.

### Cross-reference with code

When the user states how something works, check whether the code agrees. If you find a contradiction, surface it: "Your code cancels entire Orders, but you just said partial cancellation is possible — which is right?"

### Update CONTEXT.md inline

When a term is resolved, update `CONTEXT.md` right there. Don't batch these up — capture them as they happen. Use the format in [CONTEXT-FORMAT.md](./CONTEXT-FORMAT.md).

`CONTEXT.md` should be totally devoid of implementation details. Do not treat `CONTEXT.md` as a spec, a scratch pad, or a repository for implementation decisions. It is a glossary and nothing else.

### End-of-grill CONTEXT.md checkpoint

Even if you've been updating `CONTEXT.md` inline (still preferred), the **final round must always include a question of the form**: "I used these novel terms in this grill: X, Y, Z — add to CONTEXT.md?" with selectable options.

This is a backstop against glossary debt accumulating across grills — the failure mode where many novel recurring terms are introduced in a session but none get canonicalized because each individually felt minor. Workflow / process terms (autonomy contract, DONE-WHEN, DEFAULTS, DEFERRED, skip-grill threshold) do **NOT** belong in the project's `CONTEXT.md` — they're meta-process, not codebase glossary.

### Offer ADRs sparingly

Only offer to create an ADR when all three are true:

1. **Hard to reverse** — the cost of changing your mind later is meaningful
2. **Surprising without context** — a future reader will wonder "why did they do it this way?"
3. **The result of a real trade-off** — there were genuine alternatives and you picked one for specific reasons

If any of the three is missing, skip the ADR. Use the format in [ADR-FORMAT.md](./ADR-FORMAT.md).

### Close with the autonomy contract

End the grill by writing — into the spec / run-file — the three fields that license a long *unattended* run:

- **DONE-WHEN** — the machine-checkable stop condition (tests green, parity diff empty, metric threshold met). What lets the run stop *without* asking.
- **DEFAULTS** — pre-authorized choices for foreseeable mid-run forks, so the run proceeds instead of pausing.
- **DEFERRED** — decisions postponed on purpose, each with the exact trigger that will resurface it.

Present these alongside the shared-understanding summary and get sign-off. They are what turn "shared understanding" into "permission to run for a long time on its own."

### Delivery format

Ask in **batched, selectable `AskUserQuestion` rounds** (up to 4 per call, options + free-text "Other"), firing successive rounds until aligned — *not* one free-text question at a time. This overrides the one-at-a-time default above; the user prefers clicking answers.

</supporting-info>
