---
name: realign
description: Surface every open decision, unconfirmed assumption and drift from the agreed objective, and put them to the user as batched selectable questions. Use when the user asks what you need from them, asks you to realign, says "ask me about anything you need decided", or right after a progress report or summary when it is unclear whether the work is still pointed where they wanted it.
argument-hint: "(optional) an area to focus the sweep on"
---

# realign

Stop producing. Sweep the conversation for everything that needs **the user's judgment**,
and ask it in one batched round.

The point is to catch a wrong direction *before* more work is built on it. So the bar is
not "what am I unsure about" — it is **"what would I do differently depending on their
answer?"**

## What to sweep for

Walk the conversation from the last point of confirmed alignment to now, and collect:

1. **Assumptions in flight** — choices you made without asking, that are now load-bearing.
   These matter most and are the easiest to forget, because they stopped feeling like
   decisions once you built on them.
2. **Forks you are about to hit** — a decision coming up where the options diverge enough
   that guessing wrong wastes real work.
3. **Deferred items whose trigger has fired** — anything parked as "decide later" where
   later has arrived.
4. **Drift** — where what is being built has quietly moved away from what was asked. State
   the gap plainly; do not soften it.
5. **Blocked work** — anything you cannot finish without something only they can give
   (a credential, an external decision, access, a preference with no defensible default).
6. **Contradictions** — two instructions, or an instruction and a constraint in the repo's
   `CLAUDE.md`, that cannot both hold.

If `$ARGUMENTS` names an area, scope the sweep to it and say so.

## The filter — do not skip this

Drop anything you can settle yourself. A question is only worth their attention if:

- **their answer changes what you do next** — not just how you describe it, and
- **you cannot resolve it** from the code, the repo's conventions, or a sensible default.

If a defensible default exists, do not ask — **state the default, act on it, and list it
under "proceeding unless you say otherwise."** That list belongs in the same message.

Never pad to fill a round. Two real decisions beat eight manufactured ones, and a round of
busywork teaches the user to stop reading these.

## How to ask

Use **`AskUserQuestion`, in batched rounds of up to 4**, each option selectable with a
one-line consequence. Fire successive rounds until aligned — the cap is per call, not per
conversation.

For every question:

- **Lead with your own recommendation**, marked `(Recommended)`, and say why in the
  description. They are relying on your read, especially where they cannot size up the
  territory themselves.
- **Cite the evidence** — a `file:line`, a decision earlier in this conversation, a
  measured result. No preference-bare questions.
- **Make at least one option a real challenge** to the current direction, where one exists.
  If you think the plan has a flaw, the round is where you say so.

Order the rounds so that **decisions others depend on come first** — never ask about a
detail whose relevance a later answer could erase.

## Close the loop

After the last round, write back in one short block:

```
DECIDED     what they chose, in their words
DEFAULTS    what you are proceeding with unasked, and why
DEFERRED    what is still open + the exact trigger that resurfaces it
CHANGED     what this changes about the work in flight
```

If the project keeps a run-file or spec (see the repo's `CLAUDE.md`), update it with the
same block so the realignment survives a context compaction. Then resume work — do not
wait for further confirmation on anything already decided.
