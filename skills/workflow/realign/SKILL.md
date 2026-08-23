---
name: realign
description: Close out a report, summary or "I'm finished" claim without leaving anything on the field - re-check the objective against evidence rather than recollection, account for every unfinished task and deviation, decide the approach yourself, break what stands in the way instead of writing it off, put up a compact picture of everything still open with the order you propose to take it in, ask the user about DIRECTION, then carry straight on with the outstanding work and the next item. Use when a progress report, summary or status update has just been given, when a session claims the work is done or complete, when something has been called blocked, too hard or not feasible, when something was skipped, cut short or never got done, when the user asks what decisions you need or whether the objective was really met, says "realign", "carry on", "keep going", "are you sure you are finished" or "do not leave anything open", or when work on a plan has paused and should continue.
argument-hint: "(optional) an area to focus on, or a steer for what to do next"
---

# realign

**The deliverable is work resumed correctly** — the direction checked, and nothing quietly
written off. Used at the end of a report, summary, update, or a claim of being finished.
Account for what is open, settle the approach yourself, **put the picture up and check the
direction**, then **keep going and break what is in the way**. Step 5 is the point; 1–4
make it safe.

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

**Default to NOT DONE on any doubt.**

🔴 **Now run that test in the other direction.** *"This can't be done"*, *"the library
doesn't support it"*, *"that needs a rewrite"* is a claim too — same reasoning, same
pressure to be finished. It earns **more** scrutiny than a done-claim, not less: a false
"done" gets caught by the next test run, a false "blocked" removes the work silently and
forever. **Default to NOT BLOCKED on any doubt.**

Then list honestly — done, partly done, not started, abandoned: **scope not delivered**
(including the parts that turned out hard); **started and left mid-air**; **promised in
passing** ("I'll come back to that" — the most common thing a session loses); **red**
(tests, lint, typecheck, TODOs in the diff); **anything written off as blocked, too hard or
not feasible** — a finding to re-open, never a fact; **anything quietly swapped for an
easier neighbour, or met in part and reported whole**; **deferred items whose trigger has
fired**. **Report scope you cut, even when cutting it was right** — silently narrowing the
job is the failure this step exists to catch, and doing it to yourself mid-run counts.

## 2. Assign an approach to every item — you may not defer here

Settle each item from the code, the repo's conventions, the plan, or a defensible default.
This is the default path, not the exception: most items need nobody. It covers **HOW**
things get done — **WHERE** the work is headed belongs to step 4.

🔴 **Every item leaves this step with an approach, the hard ones included.** "Too hard",
"blocked", "not feasible" are **not available verdicts here** — nothing has been tried yet,
and a feasibility call made at the desk is a guess wearing a conclusion's clothes. The hard
item gets an approach *and the first thing to try*. Only step 5, after an attempt that
actually failed, can produce a deferral.

## 3. Put the board up

🔴 **Show the picture, compact and in one place**: what step 1 found still open, what you
settled yourself, what stood in the way, and **the order you propose to take the rest in**.

**This happens every time — whether or not you have a question.** It is the status update
the skill exists to produce, and it is the one moment the plan can still be redirected
before the effort is spent. Questions with no board in front of them are an interrogation:
they ask the user to choose between consequences they cannot see. The closing block at the
end is the account of what happened; this is the proposal of what is about to.

## 4. Ask about direction

- **HOW — decide it.** Implementation, tooling, structure, ordering within a step. Report
  under DEFAULTS; do not spend a question on it.
- **WHERE — ask.** Priority, scope, what counts as "next", whether the objective still
  holds. Your pick can be perfectly defensible and still not be what they want, and drift
  here is expensive to unwind.

**Run all five probes. Do not conclude from memory that there is nothing to ask:**

1. Does what you just learned change what **"done" should mean**?
2. Is the **next item still the right next item**, given what landed?
3. Has the **cost/benefit moved** — something far more expensive now, or suddenly cheap?
4. Does new evidence **undercut an assumption** the plan was built on?
5. Is anything now **not worth doing at all**?

Ask about every probe that returns something, plus anything whose answer changes what you
do next, plus the unfinished work — finish, drop, hand off — and any wall from step 5.
Usually 1–3 questions. **If all five come back empty — rarer than it feels — say in one
line that you ran them and found nothing, then go.** "There was no real question" is a
conclusion you reach by looking, not by not looking.

Use **`AskUserQuestion`, batched, up to 4 per round**, selectable options each carrying its
consequence. 🪤 **Frame it well — a wrong frame steers harder than a wrong decision would.**

- **Lead with your own recommendation**, marked `(Recommended)`, its evidence cited — a
  `file:line`, an earlier decision, a measured result — including when it is "carry on as
  planned". **Never offer a menu that leaves out what you actually think is right.**
- **Keep the options wide enough that "Other" is not the only true answer**, and include one
  that genuinely challenges the current course. Decisions others depend on come first.

## 5. Carry on — and break what is in the way

**Decisions are now locked** for the rest of the session: do not re-ask, do not
re-litigate, do not seek confirmation to begin.

1. **Finish the outstanding work from step 1** — the mid-air items and anything red.
   Starting something new on top of them is how a session accumulates debt.
2. **Then take the next item.** With a plan (see `to-execution-plan`) that is its next
   step, and its DONE-WHEN is your stop condition. Without one, what the objective implies.
3. **Keep going** until the objective is met **on evidence**, a wall survives the ladder
   below, or a new decision clears the step-4 bar.

### When something stands in the way

🔴 **A wall is work, not a finding.** Do not report it, route around it, or narrow the
scope to avoid it until it has survived the ladder in [WALLS.md](WALLS.md) — stated
falsifiably, diagnosed to the real failure, attacked by a *different* approach, and checked
against something outside your own head. Most "X doesn't support Y" is "I don't know how X
does Y". Two real approaches down, or ~5 attempts / ~30 min, and it escalates.

🔴 **You do not defer, drop, descope, skip, shrink or substitute on your own authority.** A
wall that survives goes to the user as a question carrying its claim, what you tried, **how
far the conclusion can be trusted** — `measured` · `documented` · `inferred`, and `inferred`
is the weakest and by far the most common — and what would change it. [WALLS.md](WALLS.md)
has the form. Then they choose: keep pushing · defer with a trigger · drop it · hand it off.

🪤 **Simply not doing it is the same act with no decision to point at.** A deferral leaves a
trace; an item quietly never started, half-satisfied, or swapped for an easier neighbour
leaves none — so no rule about authority can catch it. Reconciliation catches it instead:
**every item from step 1 lands on exactly one line of the closing block.** An item on none
of them was written off by nobody. [WALLS.md](WALLS.md) lists the shapes this takes.

Say what you are doing in one line, then do it. **Do not narrate progress mid-run** — the
board went up in step 3, and the account comes at the end. Close with this block,
**omitting every line that has nothing in it**. Write it into the run-file or spec if the
project keeps one, so it survives a compaction.

```
VERIFIED   what you re-checked, and how
WALLS      what stood in the way, what you tried, how each ended
DECIDED    what they chose, in their words
DEFAULTS   what you settled yourself, and why
DROPPED    what they agreed to stop doing
DEFERRED   what they agreed to park — claim, confidence, and the trigger that resurfaces it
NEXT       the remaining work, in the order you will now do it — anything not verified,
           decided, dropped or deferred lands here. Nothing leaves the sweep unaccounted.
```

## Example

> *"Phase 2 is done, tests green. The idempotency key needs a schema change, so I deferred
> it."* → `/realign`
>
> Re-run: 2 failures, and "green" predated the last edit. R4 is unmapped. A migration script
> was written and never run. The deferral was `inferred` — reasoned from the model file,
> never tried; attacked, the schema change is one nullable column and
> `orders/migrations/0007` already does exactly this. Twenty minutes. It was never a wall.
>
> Board up: the four open items, the order proposed for them, and the one thing that needs a
> call — phase 3 assumes Postgres while phase 2 introduced DuckDB. Asked, with "carry on
> unchanged" among the options, because it may still be right. Then the tests, the
> migration, phase 3.
>
> The claim was wrong three ways, and the thing written off was the cheapest of them.
