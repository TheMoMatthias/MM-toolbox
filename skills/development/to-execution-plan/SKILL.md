---
name: to-execution-plan
description: Turn an idea, grill outcome, wayfinder map, spec or prototype into a granular two-layer execution plan. Establishes the vision and designs the optimal system FIRST - either by its own analysis or by ingesting a prior grill or spec - and only then derives phases sized for one session each, decomposed into atomic steps with machine-checkable DONE-WHEN conditions and an execution framework. Use when the user wants an idea turned into an actionable plan, wants a spec made executable, asks how to sequence or break down a build, or wants a plan agents can work through one item at a time.
argument-hint: "(optional) the idea, or a path to the grill/spec/wayfinder output"
---

# to-execution-plan

Turn *what we want* into *what to do next*, at a grain a machine can execute and verify.

The output is a **plan document**, not code. Write no implementation during this skill.

Two stages with a hard gate between them. **Stage A establishes the vision and designs the
system. Stage B turns that design into phases and steps.** Nothing about phases, ordering,
or tasks may be drafted until Stage A is written out in full — see the gate below.

---

# Stage A — vision, then the optimal system

## A1. Establish the vision and the requirements

Read the source: `$ARGUMENTS`, or the grill / wayfinder / prototype / spec output in the
conversation.

- **If a prior grill or spec already did this work, ingest it — do not redo it.** Restate
  it in the plan's own words so the plan stands alone, and *check it for completeness*
  against the list below. A grill answers what was asked; it can still be silent on
  something the build needs.
- **If there is no such source, do the analysis yourself** — the same questions, answered
  from the idea, the codebase and the domain.

Either way, write down: the **goal** in one sentence; the **requirements** it must satisfy,
numbered `R1…Rn` and each testable; the **constraints** it must respect; the explicit
**non-goals**.

**Where the source is silent on something load-bearing, that is a gap — list it rather
than inventing an answer.** If a gap would change the architecture, stop and ask before
designing. Everything else gets a stated assumption and carries on.

## A2. Design the optimal system

Not "what components will exist" — **an argued design**, derived from the vision and the
requirements rather than from how the code happens to be arranged today.

- **Components**, each with the one thing it owns.
- **Contracts** between them: signatures, shapes, error cases. These get frozen first
  because they unblock everything downstream.
- **State** — what is persisted, where, and who may write it.
- **Data flow** — the path a request or record takes, end to end.
- **Alternatives considered, and why they lost.** At least one real alternative. A design
  presented without its rejected options gets relitigated at every step, and a design that
  never had an alternative was not chosen — it was assumed.
- **How it holds up** — where it breaks at 10×, what is expensive to change later, which
  requirement it serves least well.

Map each requirement from A1 onto the part of the design that satisfies it. An unmapped
requirement means the design is not finished.

## 🔴 The gate

**Do not draft a single phase, step or task before A1 and A2 are written out in full.**

A task list written before the system is designed encodes whatever structure you happened
to imagine first, and *every* step inherits it — silently, and past the point where it is
cheap to change. This is the single most expensive mistake this skill exists to prevent.

Before continuing, confirm all of these:

- [ ] The goal is one sentence, and the requirements are numbered and testable.
- [ ] Gaps are listed; any that would change the architecture have been resolved.
- [ ] The design names its components, contracts, state and data flow.
- [ ] At least one real alternative is recorded with the reason it lost.
- [ ] Every requirement maps onto some part of the design.

If the design is large, or the user should weigh an alternative, **present Stage A and get
agreement before starting Stage B.** Sequencing the wrong design perfectly is worse than
sequencing nothing.

---

# Stage B — derive the sequence from the design

Only now decide the order. It is driven by dependency and risk, not by what feels natural
to build:

- **Contracts before implementations.** Freeze an interface and both sides can proceed.
- **Riskiest assumption first**, where cheap to test. A plan that discovers its fatal flaw
  at step 14 wasted thirteen steps.
- **Vertical slices over horizontal layers.** One thin path end-to-end beats a finished
  layer that cannot be exercised.
- **Every step leaves the system working.** No step may depend on a later one to compile,
  pass, or run.
- **Parallelisable work marked as such**, with its file ownership stated, so lanes can run
  as separate sessions without colliding.

## Two layers

| layer | grain | owner |
|---|---|---|
| **Phase** | one session's worth of work, with its own brief and rollback | a spawned session |
| **Step** | the smallest change with a machine-checkable pass/fail | one edit-verify loop |

Phases are what you hand to a session (see `handover-and-spawn`). Steps are what that
session works through in order. A phase with one step is too small; a phase with thirty is
two phases.

Use **[PLAN-TEMPLATE.md](PLAN-TEMPLATE.md)** for the exact shape of both.

## DONE-WHEN is the load-bearing field

A step is only actionable if something other than judgment can say it is finished.

- **Good:** `pytest tests/ingest/test_spine.py passes; mypy clean on src/ingest/`
- **Good:** `GET /health returns 200 with {"db":"ok"} on a cold container`
- **Bad:** `the ingest layer works` · `refactored properly` · `tests added`

If you cannot write a checkable condition, the step is not understood well enough to
plan — split it until you can, or make it an explicit **investigation** step whose
DONE-WHEN is *the question is answered*.

## Before you hand it over

- Every requirement maps to at least one step, in a traceability table.
- Every step names the files it may touch; overlaps between parallel lanes are serialized.
- Every phase has a rollback and a blast radius.
- Open questions carry a **pre-authorized default** so execution proceeds instead of
  stalling. Anything with no defensible default is blocking — raise it now, not mid-build.

Save the plan where the project keeps such notes (follow the repo's `CLAUDE.md`), and
report the phase count, the step count, and what you would start with.
