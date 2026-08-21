---
name: to-execution-plan
description: Turn an idea, grill outcome, wayfinder map, spec or prototype into a granular two-layer execution plan - the system designed from the vision and requirements first, then phases sized for one session each, each decomposed into atomic steps with machine-checkable DONE-WHEN conditions and an execution framework. Use when the user wants an idea turned into an actionable plan, wants a spec made executable, asks how to sequence or break down a build, or wants a plan agents can work through one item at a time.
argument-hint: "(optional) the idea, or a path to the grill/spec/wayfinder output"
---

# to-execution-plan

Turn *what we want* into *what to do next*, at a grain a machine can execute and verify.

The output is a **plan document**, not code. Write no implementation during this skill.

## Order matters — design before sequencing

Do not start by listing tasks. A task list written before the system is designed encodes
whatever structure you happened to imagine first, and every later step inherits it.

**1. Recover the vision and the requirements.**
Read the source (`$ARGUMENTS`, or the grill / wayfinder / prototype output in the
conversation). Extract, and write down: the goal in one sentence; the requirements it must
satisfy; the constraints it must respect; the explicit non-goals. **Where the source is
silent on something load-bearing, that is a gap — list it rather than inventing an answer.**
If a gap would change the architecture, stop and ask before designing.

**2. Design the system.**
From the vision and requirements, decide the shape: the components and what each owns, the
contracts between them, where state lives, the data flow, and the seams that let it be
built in pieces. **Name the alternatives you rejected and why** — a plan that hides its
design decisions gets them relitigated at every step.

**3. Derive the sequence from the design.**
Now order the work. The correct order is driven by dependency and risk, not by what feels
natural to build:

- **Contracts before implementations.** Freeze an interface and both sides can proceed.
- **Riskiest assumption first**, where cheap to test. A plan that discovers its fatal flaw
  at step 14 wasted thirteen steps.
- **Vertical slices over horizontal layers.** One thin path end-to-end beats a finished
  layer that cannot be exercised.
- **Every step leaves the system working.** No step may depend on a later step to compile,
  pass, or run.
- **Parallelisable work marked as such**, with its file ownership stated, so lanes can run
  as separate sessions without colliding.

## Two layers

| layer | grain | owner |
|---|---|---|
| **Phase** | one session's worth of work, with its own brief and rollback | a spawned session |
| **Step** | the smallest change with a machine-checkable pass/fail | one edit-verify loop |

Phases are what you hand to a session (see the `handover-and-spawn` skill). Steps are what
that session works through in order. Every phase decomposes into steps; a phase with one
step is a sign the phase is too small, and a phase with thirty is a sign it is two phases.

Use **[PLAN-TEMPLATE.md](PLAN-TEMPLATE.md)** for the exact shape of both.

## DONE-WHEN is the load-bearing field

A step is only actionable if something other than judgment can say it is finished.

- **Good:** `pytest tests/ingest/test_spine.py passes; mypy clean on src/ingest/`
- **Good:** `GET /health returns 200 with {"db":"ok"} on a cold container`
- **Bad:** `the ingest layer works` · `refactored properly` · `tests added`

If you cannot write a checkable condition, the step is not understood well enough to
plan — split it until you can, or mark it explicitly as **needs investigation** with its
own step whose DONE-WHEN is *the question is answered*.

## Before you hand it over

- Every requirement from step 1 maps to at least one step. Say which — an unmapped
  requirement is work nobody planned.
- Every step names the files it may touch. Overlaps between parallel lanes are serialized
  or reassigned.
- Every phase has a rollback and a blast radius.
- Open questions are listed with a **pre-authorized default**, so execution proceeds
  instead of stalling. Anything with no defensible default is a blocking question — raise
  it now, not mid-build.

Save the plan where the project keeps such notes (follow the repo's `CLAUDE.md`), and
report the phase count, the step count, and what you would start with.
