---
name: realign
description: Close out a report, summary or "I'm finished" claim without leaving anything on the field - re-check the objective against evidence rather than recollection, account for every open item and deviation, decide the approach yourself, break what stands in the way instead of writing it off, put the picture up grouped by track, ask about DIRECTION on every track that needs it, steer the other lanes that share the plan, then carry on into the work and ask what to take next rather than handing back a list. Use when a progress report, summary or status update has just been given, when a session claims the work is done or complete, when something has been called blocked, too hard or not feasible, when something was skipped, cut short or never got done, when the user asks what decisions you need or whether the objective was really met, says "realign", "carry on", "keep going", "are you sure you are finished" or "do not leave anything open", or when work on a plan has paused and should continue.
argument-hint: "(optional) an area to focus on, or a steer for what to do next"
---

# realign

**The deliverable is work resumed correctly** — the direction checked, and nothing quietly
written off. Account for what is open, settle the approach yourself, put the picture up,
check the direction, then keep going and break what is in the way. Step 5 is the point;
1–4 make it safe.

## 1. Sweep — on evidence, not recollection

🔴 **If the work was just called done, that claim is the thing under test** — you cannot
check it with the reasoning that produced it. **Assume it is false and try to prove it.**
Check artifacts, never your own summary:

- **Re-read the original ask verbatim** — message, spec, plan item. Your paraphrase is where
  the drift already happened.
- **Run the DONE-WHEN now.** "Tests were green" is not evidence; a command passing this turn
  is. Same for lint, typecheck, build.
- **Look at what exists** — `git status`, the diff, the files, the real output.
- **Walk the requirements one at a time**, naming what satisfies each. An unmapped
  requirement is unfinished work however confident the summary was.
- **Ask where it deviated.** A wrong turn taken confidently reads exactly like progress.

**Default to NOT DONE on any doubt.**

🔴 **Now run that test in the other direction.** *"This can't be done"*, *"the library
doesn't support it"* is a claim too, and it earns **more** scrutiny than a done-claim: a
false "done" is caught by the next test run, a false "blocked" removes the work forever.
**Default to NOT BLOCKED on any doubt.**

Then list honestly — done, partly done, not started, abandoned: **scope not delivered**;
**started and left mid-air**; **promised in passing** ("I'll come back to that" — the most
common thing a session loses); **red** (tests, lint, typecheck, TODOs); **anything written
off as blocked, too hard or not feasible** — a finding to re-open, never a fact; **anything
swapped for an easier neighbour, or met in part and reported whole**; **deferred items whose
trigger has fired**. **Report scope you cut, even when cutting it was right.**

**Name the track each item belongs to** — a plan phase, a lane, a subsystem, an open thread,
including tracks another session owns. Two items share a track when one decision steers
both. The sweep is a portfolio, not a list: [TRACKS.md](TRACKS.md).

## 2. Assign an approach to every item — you may not defer here

Settle each item from the code, the repo's conventions, the plan, or a defensible default.
This is the default path, not the exception: most items need nobody. It covers **HOW** —
**WHERE** the work is headed belongs to step 4.

🔴 **Every item leaves this step with an approach, the hard ones included.** "Too hard",
"blocked", "not feasible" are **not available verdicts here**: nothing has been tried yet,
and a feasibility call made at the desk is a guess wearing a conclusion's clothes. The hard
item gets an approach *and the first thing to try*. Only step 5, after a real attempt
failed, can produce a deferral.

## 3. Put the board up

🔴 **Show the picture, compact and in one place**: what step 1 found still open, what you
settled yourself, what stood in the way, and **the order you propose to take the rest in**.
**Group it by track** — owner, state, next step, parallel or serialized behind another
([TRACKS.md](TRACKS.md)). A flat list hides which tracks are moving and which are waiting.

**This happens every time — whether or not you have a question.** It is the status update
the skill exists to produce, and the one moment the plan can be redirected before the effort
is spent. The closing block is the account of what happened; this is the proposal.

## 4. Ask about direction

- **HOW — decide it.** Implementation, tooling, structure, ordering within a step. Report
  under DEFAULTS; do not spend a question on it.
- **WHERE — ask.** Priority, scope, what counts as "next", whether the objective still holds.
  A defensible pick can still be the wrong one, and drift here is expensive to unwind.

**Run all six probes over EACH track**, not once over the session. Five look back at what is
already committed; the sixth looks forward at what just became possible:

1. Does what you just learned change what **"done" should mean**?
2. Is the **next item still the right next item**, given what landed?
3. Has the **cost/benefit moved** — far more expensive now, or suddenly cheap?
4. Does new evidence **undercut an assumption** the plan was built on?
5. Is anything now **not worth doing at all**?
6. **What did landing this make possible that was not before?** A finished piece opens moves
   that did not exist while it was unfinished — a second provider, a different frequency,
   the next source — and the plan rarely lists them, because they were not options when it
   was written.

**Every track that returns something earns its own question** — three live tracks means
three questions. Add anything whose answer changes what you do next, the unfinished work,
and any wall from step 5. 🔴 **A track you did not ask about is a track you decided alone**:
correct for HOW, never for WHERE. **If every probe on every track comes back empty — rarer
than it feels — say in one line that you ran them, then go.**

🔴 **An open track with no live owner, or one gone quiet past its cadence, is a question by
itself** — who drives it, and when. **"Nothing from me" is not an answer; it is the reason
to ask**: only the user can assign a track nobody is driving, and a stalled lane looks
identical to a healthy one on a board.

Use **`AskUserQuestion`, batched, up to 4 per round**, options selectable and each carrying
its consequence. **Fire successive rounds until every track is covered — the cap is per
call, not per realignment.**

- **Do not manufacture a fork.** No genuine uncertainty means one line saying where you are
  heading, then go. A forced choice invents a crossroads that was not there, and steers
  worse than the decision you would have made alone.
- **Lead with your own recommendation**, marked `(Recommended)`, its evidence cited — a
  `file:line`, an earlier decision, a measured result — including when it is "carry on as
  planned". **Never offer a menu that leaves out what you actually think is right.**
- **Keep the options wide enough that "Other" is not the only true answer**, and include one
  that genuinely challenges the current course. Decisions others depend on come first.
- **Say what the plan already says, and mark any option that would amend it.** One option
  always holds the current spec, and it is the recommendation *unless* new evidence undercuts
  what it rested on — then the question is "is this evidence enough to amend?", not "A or B".
  🪤 **A question forces an answer**; offering a settled point as an open menu is how a signed
  plan drifts with nobody deciding to change it.

🔔 **Push the questions — do not just post them.** `PushNotification` the moment they go up,
one line naming the lane and what is waiting. It suppresses itself when the user is already
at this terminal, so it costs nothing when they are present and is the only thing that
reaches them when they are not. **A question nobody sees is a question nobody asked** —
measured across concurrent lanes, the median wait was 45 minutes, and nothing inside five.

## 5. Carry on — and break what is in the way

**Decisions are now locked** for the rest of the session: do not re-ask, do not re-litigate,
do not seek confirmation to begin.

1. **Finish the outstanding work from step 1** — the mid-air items and anything red. Starting
   something new on top of them is how a session accumulates debt.
2. **Then take the next item.** With a plan (see `to-execution-plan`) that is its next step,
   and its DONE-WHEN is your stop condition. Without one, what the objective implies.
3. **Keep going** until the objective is met **on evidence**, a wall survives the ladder, or
   a new decision clears the step-4 bar.

**A plan does not stop at the boundary of the session reading it.** Tracks another lane owns
stay in scope: name the owner, say what you will send **before** you send it, then
`SendMessage` only what changes their next action. Re-scoping is a brief via
`handover-and-spawn`, not a message. Never redirect a lane mid-flight on something
destructive, never hand one file to a second lane, and **a lane that has not answered has
not agreed**. [TRACKS.md](TRACKS.md)

🔴 **A wall is work, not a finding.** Do not report it, route around it, or narrow the scope
to avoid it until it has survived the ladder in [WALLS.md](WALLS.md) — stated falsifiably,
diagnosed to the real failure, attacked by a *different* approach, and checked against
something outside your own head. Most "X doesn't support Y" is "I don't know how X does Y".

🔴 **You do not defer, drop, descope, skip, shrink or substitute on your own authority.** A
wall that survives goes to the user carrying its claim, what you tried, **how far the
conclusion can be trusted** — `measured` · `documented` · `inferred`, and `inferred` is the
weakest and by far the most common — and what would change it. Then they choose: keep
pushing · defer with a trigger · drop it · hand it off.

🪤 **Simply not doing it is the same act with no decision to point at.** A deferral leaves a
trace; an item never started, half-satisfied, or swapped for an easier neighbour leaves
none. Reconciliation catches it instead: **every item from step 1 lands on exactly one line
of the closing block.** [WALLS.md](WALLS.md) lists the shapes this takes.

Say what you are doing in one line, then do it. **Do not narrate progress mid-run** — the
board went up in step 3, and the account comes at the end. Close with this block, **omitting
every line that has nothing in it**, then the sentence below it. Write it into the run-file
or spec if the project keeps one, so it survives a compaction.

```
VERIFIED   what you re-checked, and how
WALLS      what stood in the way, what you tried, how each ended
DECIDED    what they chose, in their words
DEFAULTS   what you settled yourself, and why
DROPPED    what they agreed to stop doing
DEFERRED   what they agreed to park — claim, confidence, and the trigger that resurfaces it
SENT       what went to which lane, and whether they have confirmed it
NEXT       the remaining work per track, in the order you will now do it, marking what runs
           in parallel — anything not verified, decided, dropped or deferred lands here.
           Nothing leaves the sweep unaccounted, on any track.
```

### The last thing you write is a sentence, not a field

🔴 **End every realign with one or two plain sentences, outside the block** — never omitted,
even when every line in the block was empty. The block is a reconciliation, dense on
purpose; it is not an answer. Someone reading only the last line must still know what
happens now.

- **Still open** — the next action, who takes it, and anything the user must do first. Name
  the thing: "next I run the migration, then phase 3", not "continuing with the outstanding
  items".
- **Closed** — say it is closed, and what makes that true. A closure that does not say what
  makes it one reads as a session that simply stopped.

🪤 **Do not restate the block in prose, and do not hedge.** If the sentence lists five things
it has become the block again; and if X "may need a look", X is the next action.

### A non-empty NEXT is not an ending

🔁 **When work is still open, the sentence is followed by a question — not by silence.** Put
the remaining items up: which to take now, or confirm the order you proposed. Then
**implement the answer**, and when that lands the rule applies again. Handing back a list
and stopping just makes them invoke the skill again to get the same list.

This does not re-open step 4 — those decisions stay locked; it chooses what comes *after*
the work they governed. **One item left that plainly follows? Say so in a line and do it.**
**Only when nothing is outstanding on any track does a realign end on the sentence alone.**

## Example

> *"Phase 2 is done, tests green. The idempotency key needs a schema change, so I deferred
> it."* → `/realign`
>
> Re-run: 2 failures, "green" predated the last edit, R4 unmapped, a migration written and
> never run. The deferral was `inferred` — reasoned from the model file, never tried;
> attacked, it is one nullable column and `orders/migrations/0007` already does exactly
> this. Twenty minutes. It was never a wall.
>
> Board, three tracks. **ingest** — moving: tests, migration, phase 3. **schema** — was
> "deferred", now moving, serialized behind the migration. **lane F2** — building on the old
> storage decision, and not this session's call.
>
> Two questions, one per track that had one: phase 3 assumes Postgres while phase 2
> introduced DuckDB, with "carry on unchanged" among the options; and whether F2 keeps its
> own store. The answer goes to F2 by `SendMessage`. Then the tests, the migration, phase 3.
>
> **Next I run the two failing tests down, then the migration, then phase 3 — F2 is
> unblocked as soon as the storage answer reaches it.** Then a closing question, because
> phase 3 is not the only thing the migration unlocked: phase 3 as planned, the second
> provider the schema now supports, or the backfill that was waiting on it. Answered, and
> straight into it.
>
> Had nothing been left: **"This is closed: phase 3 landed, all suites green on the pushed
> commit, and every track from the sweep is verified or explicitly dropped."**
