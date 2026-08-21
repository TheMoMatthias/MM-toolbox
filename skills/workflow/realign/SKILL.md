---
name: realign
description: Close out a report, summary or "I'm finished" claim without leaving anything on the field - re-check the objective against evidence rather than recollection, account for every unfinished task and deviation, decide the approach yourself, ask the user about DIRECTION, then carry straight on with the outstanding work and the next item. Use when a progress report, summary or status update has just been given, when a session claims the work is done or complete, when the user asks what decisions you need or whether the objective was really met, says "realign", "carry on", "keep going", "are you sure you are finished" or "do not leave anything open", or when work on a plan has paused and should continue.
argument-hint: "(optional) an area to focus on, or a steer for what to do next"
---

# realign

**The deliverable is work resumed correctly, not a list of questions.** Used at the end of
a report, summary, update — or a claim of being finished. Account for what is open, settle
the approach yourself, check the direction with the user, then **keep going**. Step 4 is
the point; 1–3 make it safe.

## 1. Sweep — on evidence, not recollection

🔴 **If the work was just called done, that claim is the thing under test.** You cannot
check it with the reasoning that produced it: whatever made the claim wrong makes the
memory of it wrong too. **Assume it is false and try to prove it.** Check artifacts, never
your own summary:

- **Re-read the original ask verbatim** — message, spec, plan item. Not your paraphrase;
  the paraphrase is where the drift already happened.
- **Run the DONE-WHEN now.** "Tests were green" is not evidence; a command passing this
  turn is. Same for lint, typecheck, build.
- **Look at what exists** — `git status`, the diff, the files, the real output.
- **Walk the requirements one at a time**, naming what satisfies each. An unmapped
  requirement is unfinished work however confident the summary was.
- **Ask where it deviated.** A wrong turn taken confidently reads exactly like progress.

**Default to NOT DONE on any doubt.** A re-check costs minutes; a false "finished" costs
whatever gets built on top of it.

Then list honestly — done, partly done, not started, abandoned: **scope not delivered**
(including the parts that turned out hard); **started and left mid-air**; **promised in
passing** ("I'll come back to that" — the most common thing a session loses); **red**
(tests, lint, typecheck, TODOs in the diff); **deferred items whose trigger has fired**.
**Report scope you cut, even when cutting it was right** — silently narrowing the job is
the failure this step exists to catch.

## 2. Decide the approach yourself

Settle each open item from the code, the repo's conventions, the plan, or a defensible
default. This is the default path, not the exception: most items need nobody. It covers
**HOW** things get done — **WHERE** the work is headed belongs to step 3.

## 3. Ask about direction

- **HOW — decide it.** Implementation, tooling, structure, ordering within a step. Report
  under DEFAULTS; do not spend a question on it.
- **WHERE — ask.** Priority, scope, what counts as "next", whether the objective still
  holds, whether this is still worth doing. Your pick can be perfectly defensible and
  still not be what they want, and drift here is expensive to unwind.

Ask anything whose answer changes what you do next and that you cannot resolve — and **on
top of that, raise at least one direction question whenever a real one exists**, even
where you could have chosen. Usually 1–3 in total.

🪤 **A question is itself an intervention.** Three options frame the space, and a wrong
frame steers harder than a wrong decision would have. Use **`AskUserQuestion`, batched, up
to 4 per round**, selectable options each carrying its consequence:

- **Lead with your own recommendation**, marked `(Recommended)`, and say why — including
  when it is "carry on as planned". **Never offer a menu that leaves out what you actually
  think is right.**
- **Do not manufacture a fork.** No genuine uncertainty? Say in one line where you are
  heading and why, and go. A forced choice invents a crossroads that was not there.
- **Cite evidence** — a `file:line`, an earlier decision, a measured result.
- **Keep the options wide enough that "Other" is not the only true answer**, and include
  one that genuinely challenges the current course where such a course exists.
- Ask about the **unfinished work** too — finish, drop, or hand off.

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

Say what you are doing in one line, then do it. Report at the end, not before starting.
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
> Re-run: 2 failures, "green" predated the last edit. The spec asks for idempotent
> retries; the diff has retries but no idempotency key, so R4 is unmapped. A migration
> script was written and never run.
>
> Settled alone: fix the tests, run the migration. Asked: the idempotency gap is a scope
> call, and phase 3 assumes Postgres while phase 2 introduced DuckDB — with "carry on
> unchanged" among the options, because it may still be right.
>
> Then all three closed and phase 3 started. The claim was wrong three ways, none of them
> visible from the summary.
