---
name: ask-me
description: Ask me about the open decisions instead of settling them alone. Takes the last response and everything still open in the session as given, groups it by track, puts the decisions up as selectable questions with a recommendation each - then implements the answers rather than handing back a list. Use when you want to be asked what to decide next.
disable-model-invocation: true
argument-hint: "(optional) an area to focus the questions on"
---

# ask-me

**You typed this because you would rather be asked than told.** Turn the session's open
decisions into questions, put them up, and then *act on the answers*.

**This is not `realign`.** realign re-checks a "done" claim against evidence before it asks
anything. This one **takes the session's own account as given** and goes straight to the
decisions — that is what makes it cheap enough to fire at any point. If what you doubt is the
account itself, that is realign's job, not this one.

**Honour `$ARGUMENTS`** — an area scopes the questions to it; say so when it does.

## 1. Gather the decision surface

No verification pass, no re-running anything. Read what is already in front of you:

- **The last response** — every fork it named, hedged over, or quietly settled on your behalf.
- **Everything still open in the session** — in flight, parked, deferred, dropped, handed to a
  lane, or raised once and never resolved. **Include what you decided alone**; those are the
  ones nobody will otherwise revisit.
- **What just landed.** A finished piece opens moves that did not exist while it was
  unfinished, and the plan rarely lists them — they were not options when it was written.

**Group by track.** Two items share a track when one decision steers both. Tracks are
decisional, not topical.

## 2. Split HOW from WHERE

- **HOW — decide it.** Implementation, tooling, structure, ordering inside a step. Report it in
  a line; do not spend a question on it.
- **WHERE — ask.** Priority, scope, what counts as next, whether the objective still holds.

🔴 **A track you did not ask about is a track you decided alone.** Correct for HOW, never for
WHERE.

## 3. Put the open items up — briefly

A few lines grouped by track, before the questions. Not a reconciliation block — just enough
that the questions have something to stand on. 🪤 **Questions with no picture in front of them
are an interrogation**: nobody can weigh an option they have to reconstruct first.

## 4. Ask — at least one question, every time

🔴 **Invoking this skill IS the request, so an empty return is a failed run.** Even when the
course looks obvious there is a real question available: what the last piece made possible,
how far to take it, what comes after the current item.

🪤 **The floor is met by a FORWARD question, never by reopening a settled point.** A forced
choice on something already decided invents a crossroads that was not there and steers worse
than the decision you would have made alone. When nothing is genuinely contested, ask about
what comes *next* — that question is always real, and it cannot drift the spec.

🔴 **One option always holds the current course**, and it is the recommendation *unless* new
evidence undercuts what it rested on — then the question is "is this evidence enough to
amend?", not "A or B".

- **Lead with your own recommendation**, marked `(Recommended)`, its evidence cited — a
  `file:line`, an earlier decision, a measured result. **Never offer a menu that leaves out
  what you actually think is right.**
- **Every option carries its consequence**, and one genuinely challenges the current course.
- **Keep them wide enough that "Other" is not the only true answer.**
- **Decisions others depend on come first.**

Use **`AskUserQuestion`, batched, up to 4 per round** — the cap is per call, not per run. Every
track needing a decision earns its own question.

🔔 **Push them, do not just post them.** `PushNotification` the moment they go up, one line
naming what is waiting. It suppresses itself when the user is already at this terminal, so it
costs nothing when they are here and is the only thing that reaches them when they are not.

## 5. Implement the answer

🔴 **The answer is implemented, not recorded.** Writing it down and stopping is the exact
failure this skill exists to remove — it makes them type the thing they just answered.

🔁 **Then this rule applies again to whatever is left.** When work is still open after the
answer lands, the remaining items go back up: which to take now, or confirm the order you
propose. **One item that plainly follows is not a choice** — say so in a line and do it.

**Nothing outstanding?** Say so, and say what makes that true. A closure that does not name
what makes it one reads as a session that simply stopped.
