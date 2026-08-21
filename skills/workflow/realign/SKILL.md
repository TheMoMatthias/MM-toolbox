---
name: realign
description: Close out a session properly - sweep for every unfinished task, every open decision, and every drift from the agreed objective, put the decisions to the user as batched selectable questions, and re-plan what remains. Use when the user asks what you need from them, asks you to realign, says "ask me about anything you need decided", wants to know what is still open, or right after a progress report or summary when it is unclear whether the work is finished or still pointed where they wanted it.
argument-hint: "(optional) an area to focus the sweep on"
---

# realign

Stop producing. Account for **everything still open** — work and decisions both — put
what needs the user's judgment to them, and come out with an agreed plan for the rest.

Three passes, in order. Do not skip to the questions: half of what needs deciding only
becomes visible once the unfinished work is laid out.

---

## Pass 1 — the open-work sweep

Walk the conversation from the last point of confirmed alignment to now and account for
**every** commitment made in it. For each, state honestly: done, partly done, not started,
or abandoned.

Sweep for:

1. **Stated scope not delivered** — anything in the original ask that has not been built.
   Including the parts that turned out to be harder than expected.
2. **Started and left mid-air** — code written but not wired up, a refactor half applied,
   a file created and never used.
3. **Promised in passing** — "I'll come back to that", "worth doing later", offers you
   made that were never taken up or declined. These evaporate silently and are the most
   common thing a session loses.
4. **Deliberately deferred** — what you scoped out, and whether its trigger has fired.
5. **Red** — failing tests, lint or typecheck errors, TODOs left in the diff, anything
   knowingly left broken.
6. **Unverified** — anything you reported as done but never actually checked.

**Report scope you cut, even when cutting it was right.** Silently narrowing the job is
the failure this pass exists to catch — scaling work down is the user's call, not yours.

## Pass 2 — the open-decision sweep

Now, over the same span, collect what needs **their judgment**:

1. **Assumptions in flight** — choices you made without asking that are now load-bearing.
   The easiest to miss, because they stopped feeling like decisions once you built on them.
2. **Forks ahead** — a coming decision where the options diverge enough that guessing
   wrong wastes real work.
3. **Drift** — where what is being built has moved away from what was asked. State the gap
   plainly; do not soften it.
4. **Blocked** — anything you cannot finish without something only they can give: a
   credential, an external decision, access, a preference with no defensible default.
5. **Contradictions** — two instructions, or an instruction and a constraint in the repo's
   `CLAUDE.md`, that cannot both hold.

If `$ARGUMENTS` names an area, scope both sweeps to it and say so.

### The filter — do not skip this

Drop anything you can settle yourself. A question earns their attention only if:

- **their answer changes what you do next** — not just how you describe it, and
- **you cannot resolve it** from the code, the repo's conventions, or a sensible default.

Where a defensible default exists, do not ask — **state the default, act on it, and list
it under "proceeding unless you say otherwise."**

Never pad to fill a round. Two real decisions beat eight manufactured ones, and a round of
busywork teaches the user to stop reading these.

## Pass 3 — ask, then re-plan

**Show the open-work list first**, compactly, so the questions have context. Then ask.

Use **`AskUserQuestion`, in batched rounds of up to 4**, each option selectable with a
one-line consequence. Fire successive rounds until aligned — the cap is per call, not per
conversation. For every question:

- **Lead with your own recommendation**, marked `(Recommended)`, and say why. They rely on
  your read, most of all where they cannot size up the territory themselves.
- **Cite evidence** — a `file:line`, a decision earlier in this conversation, a measured
  result. No preference-bare questions.
- **Make at least one option a real challenge** to the current direction, where one exists.
  If you think the plan has a flaw, this round is where you say so.

Order rounds so decisions others depend on come first — never ask about a detail whose
relevance a later answer could erase. **Ask about the unfinished work too**, not only the
decisions: what to finish now, what to drop, and what to hand to a fresh session.

Then close in one block:

```
DECIDED      what they chose, in their words
DEFAULTS     what you are proceeding with unasked, and why
DROPPED      what you are explicitly not doing, and that they agreed
DEFERRED     what is still open + the exact trigger that resurfaces it
NEXT         the remaining work, in the order you will now do it
```

`NEXT` is the point of the whole skill: a realignment that ends without a re-ordered plan
has only made a list. If the project keeps a run-file or spec (see the repo's `CLAUDE.md`),
write the same block into it so this survives a context compaction.

Then resume work. Do not seek further confirmation on anything already decided.
