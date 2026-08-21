---
name: realign
description: Close out a report or summary without leaving anything on the field - account for every unfinished task, decide everything that can be decided, ask the user ONLY about what genuinely needs their judgment, then carry straight on with the outstanding work and the next item. Use when a progress report, summary or status update has just been given, when the user asks what decisions you need from them, says "realign", "carry on", "keep going" or "do not leave anything open", or when work on a plan has paused and should continue.
argument-hint: "(optional) an area to focus on, or a steer for what to do next"
---

# realign

**The deliverable is work resumed correctly, not a list of questions.** Used at the end
of a report, summary or update — most often mid-way through a plan. Account for what is
open, settle what you can settle, ask about the little that needs the user, then **keep
going**. Four steps: step 4 is the point, steps 1-3 exist to make it safe.

## 1. Sweep — what is actually still open

From the last point of confirmed alignment to now, list honestly — done, partly done,
not started, abandoned:

- **Scope not delivered.** Including the parts that turned out harder than expected.
- **Started and left mid-air** — code not wired up, a refactor half applied.
- **Promised in passing** — "I'll come back to that", offers never taken up. These
  evaporate silently and are the most common thing a session loses.
- **Red** — failing tests, lint, typecheck, TODOs left in the diff.
- **Claimed done but never actually verified.**
- **Deferred items whose trigger has now fired.**

**Report scope you cut, even when cutting it was right.** Silently narrowing the job
is the failure this step exists to catch.

## 2. Decide everything you can

Go through the open items and **settle each one yourself** where you legitimately can:
from the code, the repo's conventions, the plan, or a defensible default.

This is the default path, not the exception. Most items need no one.

## 3. Ask only about what survives

A question earns the user's attention **only** if both hold:

- their answer **changes what you do next**, and
- you genuinely **cannot** resolve it — no defensible default exists.

**If nothing survives the filter, do not ask anything.** Say in two lines what you are
proceeding with and go to step 4. A round of manufactured questions trains the user to
stop reading them.

For what does survive, use **`AskUserQuestion` in batched rounds of up to 4**, options
selectable, each with its consequence. Fire successive rounds until aligned.

- **Lead with your recommendation**, marked `(Recommended)`, and say why.
- **Cite evidence** — a `file:line`, an earlier decision, a measured result.
- **Include one option that challenges the current direction** where one exists. If you
  think the plan has a flaw, this is where you say so.
- Ask about the **unfinished work** too — what to finish, drop, or hand off — not only
  about decisions.

Order rounds so that decisions others depend on come first.

## 4. Carry on

**Decisions are now locked.** Treat every answer as settled for the rest of the session.
Do not re-ask, do not re-litigate, do not seek confirmation to begin.

Work in this order:

1. **Finish the outstanding work from step 1** — the mid-air items and anything red.
   Leaving those to start something new is how a session accumulates debt.
2. **Then take the next item.** If a plan exists (see `to-execution-plan`), that is the
   next step in it, and its DONE-WHEN is your stop condition. If not, it is the next
   thing the objective implies.
3. **Keep going** through further items until genuinely blocked, the objective is met,
   or a new decision appears that meets the step-3 bar.

State what you are doing in one line, then do it. Report at the end, not before starting.

Close with this block, and write it into the run-file or spec if the project keeps one,
so it survives a context compaction:

```
DECIDED    what they chose, in their words
DEFAULTS   what you settled yourself, and why
DROPPED    what you are explicitly not doing
DEFERRED   still open + the exact trigger that resurfaces it
NEXT       the remaining work, in the order you will now do it
```

## Example

> *Report ends: "Phase 2 is committed. Tests green."* → `/realign`
>
> Sweep finds: the migration script is written but never run; a `TODO` left in
> `loader.py:88`; phase 3 is next. Two are settleable — run the script, resolve the
> TODO per the plan's convention. One is not: phase 3 assumed Postgres, but phase 2
> introduced DuckDB.
>
> One question asked, about that conflict. Answer taken as locked. Then: migration run,
> TODO closed, phase 3 started against the chosen store — without being told to.
