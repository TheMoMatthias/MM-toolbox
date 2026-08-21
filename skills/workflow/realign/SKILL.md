---
name: realign
description: Close out a report, summary or "I'm finished" claim without leaving anything on the field - re-check the objective against evidence rather than recollection, account for every unfinished task and deviation, decide everything that can be decided, ask the user ONLY about what genuinely needs their judgment, then carry straight on with the outstanding work and the next item. Use when a progress report, summary or status update has just been given, when a session claims the work is done or complete, when the user asks what decisions you need or whether the objective was really met, says "realign", "carry on", "keep going", "are you sure you are finished" or "do not leave anything open", or when work on a plan has paused and should continue.
argument-hint: "(optional) an area to focus on, or a steer for what to do next"
---

# realign

**The deliverable is work resumed correctly, not a list of questions.** Used at the end
of a report, summary, update — or a claim of being finished. Account for what is open,
settle what you can, ask about the little that needs the user, then **keep going**.
Four steps: step 4 is the point, steps 1-3 make it safe.

## 1. Sweep — on evidence, not recollection

🔴 **If the work was just called done, that claim is the thing under test.** You cannot
check it with the reasoning that produced it: whatever made the claim wrong makes the
memory of it wrong too. **Assume it is false and try to prove it.**

Check against artifacts, never against your own summary:

- **Re-read the original ask verbatim** — the message, the spec, the plan item. Not your
  paraphrase, which is where the drift already happened.
- **Run the DONE-WHEN now.** "Tests were green" is not evidence; a command passing in
  this turn is. Same for lint, typecheck, the build.
- **Look at what exists** — `git status`, the diff, the actual files, the actual output.
- **Walk the requirements one at a time** and name what satisfies each. An unmapped
  requirement is unfinished work however confident the summary was.
- **Ask where it deviated.** A wrong turn taken confidently reads exactly like progress.

**Default to NOT DONE on any doubt.** A re-check costs minutes; a false "finished" costs
whatever gets built on top of it.

Then list honestly — done, partly done, not started, abandoned:

- **Scope not delivered**, including the parts that turned out harder than expected.
- **Started and left mid-air** — code not wired up, a refactor half applied.
- **Promised in passing** — "I'll come back to that". The most common thing a session loses.
- **Red** — failing tests, lint, typecheck, TODOs left in the diff.
- **Deferred items whose trigger has now fired.**

**Report scope you cut, even when cutting it was right.** Silently narrowing the job is
the failure this step exists to catch.

## 2. Decide everything you can

Settle each open item **yourself** where you legitimately can — from the code, the repo's
conventions, the plan, or a defensible default. This is the default path, not the
exception. Most items need nobody.

## 3. Ask only about what survives

A question earns the user's attention **only** if both hold: their answer **changes what
you do next**, and you genuinely **cannot** resolve it.

**If nothing survives, ask nothing.** Say in two lines what you are proceeding with and
go to step 4. Manufactured questions train the user to stop reading them.

Otherwise use **`AskUserQuestion`, batched, up to 4 per round**, options selectable with
their consequences:

- **Lead with your recommendation**, marked `(Recommended)`, and say why.
- **Cite evidence** — a `file:line`, an earlier decision, a measured result.
- **Include one option that challenges the current direction** where one exists.
- Ask about the **unfinished work** too — finish, drop, or hand off — not only decisions.

Decisions others depend on come first.

## 4. Carry on

**Decisions are now locked** for the rest of the session: do not re-ask, do not
re-litigate, do not seek confirmation to begin.

1. **Finish the outstanding work from step 1** — the mid-air items and anything red.
   Starting something new on top of them is how a session accumulates debt.
2. **Then take the next item.** With a plan (see `to-execution-plan`) that is its next
   step, and its DONE-WHEN is your stop condition. Without one, what the objective implies.
3. **Keep going** until genuinely blocked, the objective is met **on evidence**, or a new
   decision clears the step-3 bar.

State what you are doing in one line, then do it. Report at the end, not before starting.

Close with this block, **omitting every line that has nothing in it** — on a routine
update that is often just VERIFIED and NEXT. Write it into the run-file or spec if the
project keeps one, so it survives a compaction.

```
VERIFIED   what you re-checked, and how
DECIDED    what they chose, in their words
DEFAULTS   what you settled yourself, and why
DROPPED    what you are explicitly not doing
DEFERRED   still open + the exact trigger that resurfaces it
NEXT       the remaining work, in the order you will now do it
```

## Example

> *"Phase 2 is done, tests green."* → `/realign`
>
> Re-running the suite: 2 failures — "green" predated the last edit. The spec, re-read,
> asks for idempotent retries; the diff has retries but no idempotency key, so R4 is
> unmapped. A migration script was written and never run.
>
> Two are settleable (fix the tests, run the migration); the idempotency gap is a design
> choice, so one question, answer locked. Then all three closed and phase 3 started.
> The claim was wrong in three ways, none visible from the summary.
