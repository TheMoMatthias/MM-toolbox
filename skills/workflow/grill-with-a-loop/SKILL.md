---
name: grill-with-a-loop
description: Grill a plan to a signed autonomy contract, then automatically run its DONE-WHEN as a bounded self-verifying loop — proving the check CAN fail before trusting that it passed, and having independent agents try to demolish the result before anything is committed. Use when the user wants a plan stress-tested AND executed unattended to a machine-checkable finish.
disable-model-invocation: true
argument-hint: [what you want built] [--max-attempts N] [--max-minutes M]
effort: max
---

# Grill With a Loop

`grill-with-docs`, then the loop it earns.

```
PART 1  ALIGN — run /grill-with-docs to a signed autonomy contract   (delegated, not duplicated)
PART 2  RUN   — turn DONE-WHEN into a PROVEN-FAILABLE oracle and loop to it, unattended
```

The join between the two halves is the **Oracle Contract**. Everything that makes this more
reliable than "loop until the tests pass" lives there — not in the looping.

> **The premise.** A loop's reliability is not how often it re-checks. It is whether its check
> *could have failed*. A check never observed failing tells you nothing when it passes; re-running
> it only stamps an authoritative GREEN on an uninformative result. This skill spends its effort
> on oracle **validity**, and treats the looping itself as the cheap part.

---

## Part 1 — The grill (delegated)

Invoke **`grill-with-docs`** via the Skill tool and run it to completion. Do not re-implement it —
its scope tiers, quality-lens dispatch, cite-evidence rule, contrarian-framing rule, batched
`AskUserQuestion` rounds, and CONTEXT.md checkpoint all apply unchanged.

**One addition:** its closing autonomy-contract round is no longer the end. That round now also
carries the Oracle Contract and its falsifiability proof, because here **signing is launching**
(Step 3). Build the contract *before* firing that round.

If the grill ends with **no machine-checkable DONE-WHEN**, stop here and say so — see
*When NOT to use this* at the bottom. Do not invent an oracle to satisfy the skill.

---

## Part 2 — The loop

### Step 1 — Build the Oracle Contract

Every DONE-WHEN becomes exactly one contract, written into the run-file:

```
CLAIM         One sentence, in the user's own terms, that is TRUE when this is done.
COMMAND       The exact command, runnable from the repo root, one line.
              Exit 0 = the claim holds.  Non-zero = it does not.
COVERS        Which part of CLAIM this command actually tests.
BLIND-SPOTS   What the command CANNOT see. Written BEFORE the loop starts.
BROKEN-READS  What this command outputs if the system were broken in the way that matters.
              If that equals what it outputs when healthy, THE COMMAND IS NOT THE ORACLE —
              go back and build a different one.
BASELINE      Exit code + output tail observed in Step 2. MUST be non-zero.
CAPS          max_attempts (default 5), max_minutes (default 30).
```

**Rules for `COMMAND`:**

- **One command, one exit code.** If DONE-WHEN needs several checks, chain with `&&` so any
  failure is non-zero, or write a small script in the project's scratch dir that returns a single code.
- **Measure the result, not the activity.** Rows written over runs executed. Resulting state over
  log lines. *A run count answers "did it run", never "did it work".*
- **Exit code only.** No oracle whose pass depends on me reporting what I saw.
- **Decide what "nothing happened" means.** `pytest` exits 5 on no-tests-collected; `grep` exits 1
  on no-match; a query returning zero rows exits 0. Each of those can be a false pass *or* a false
  fail. Pick, and write which in `COVERS`.
- **If the check reads a number, write down that number's value when broken.** That is `BROKEN-READS`,
  and it is the field that catches wrong oracles. Same value healthy and broken ⇒ wrong number.

### Step 2 — The falsifiability gate (HARD)

**Run `COMMAND` now, before any work is done.**

- **Non-zero** → record `BASELINE`, proceed to Step 3.
- **Exit 0** → **REFUSE TO LAUNCH.** Diagnose which case this is and report it:
  - **(a) The goal is already met.** There is no work. Say so and stop.
  - **(b) The command doesn't measure the goal.** Return to Step 1 and build a different oracle.
    This is the common case and the entire reason the gate exists.
  - **(c) A deliberate keep-it-green loop** (a regression guard that must stay passing). This is the
    only legitimate bypass and it requires **both**: a `BASELINE-OVERRIDE` field containing a prose
    reason in the run-file, **and** a demonstration in place of the observed red — break the thing on
    purpose (revert the guard, feed bad input, point at a bad fixture), confirm the command goes
    non-zero, restore, and record both exit codes.

Never bypass silently. Never with an empty reason. This gate is not paperwork: a pass from a check
never observed failing is the single most common way a loop reports success on a broken system.

### Step 3 — Sign-off IS launch

Fire **one** `AskUserQuestion` round carrying the grill's autonomy contract *and* the oracle:

- `CLAIM`, `COMMAND`, `COVERS`, `BLIND-SPOTS`, `BROKEN-READS`
- `BASELINE` — the observed red, i.e. the proof this check can fail
- `CAPS` and the on-done policy (Step 6)
- DONE-WHEN / DEFAULTS / DEFERRED from the grill

**Signing starts the loop. There is no second click.** State that plainly in the question.

If the user edits the command, **return to Step 2** — a changed oracle has no baseline, and an
unproven oracle is exactly what this skill exists to prevent.

### Step 4 — The fix loop

For `attempt = 1..max_attempts`, inside `max_minutes`:

1. Do the work.
2. Run `COMMAND`. Append exit code + output tail to the run-file.
3. **Exit 0** → go to Step 5.
4. **Non-zero** → before touching code again, test both stall conditions:
   - **NO-OP** — no file changed since the last attempt. This was not an attempt; do **not**
     increment the counter. Diagnose why nothing was done rather than burning the cap.
   - **IDENTICAL** — the output is byte-identical to the previous attempt. The change had no effect
     on what the check can see: either the fix is in the wrong place, or the check cannot observe it.
     **Two identical outputs in a row ⇒ stop editing and re-read the code.** Do not fix a third time.
5. **A second failure on the same approach means the diagnosis was wrong**, not that the fix was
   incomplete. Switch to investigation — instrument, grep callers, re-read the failing path, spawn an
   `Explore` subagent. Do not apply a variant of the same fix.
6. One-line progress ping per attempt, not per action.

**At either cap:** STOP. Write what was tried, what was learned, and the exact remaining failure.
`PushNotification`. Leave the changes in place. **Do not commit.**

### Step 5 — The refutation panel (on green, BEFORE commit)

Spawn **three** subagents **in parallel, in a single message**. Give each one ONLY:

- the `CLAIM`
- the diff (`git diff`)
- the exact `COMMAND` and its full output

**Do not give them the reasoning for why it is correct.** That reasoning is the thing under test;
supplying it is how you bribe a verifier.

Each is instructed: *your job is to REFUTE. Default to `refuted: true` when uncertain.* Each returns
`{refuted: bool, reason: str}`.

| Agent | Attacks | Prompt core |
|---|---|---|
| **R1 — the oracle** | the `COMMAND` | Could this command have failed at all? Does it cover the CLAIM or a narrower proxy? What would it print if the system were broken in the way that matters? Does it measure the result or merely the activity? |
| **R2 — the change** | the diff | Does the code do what the CLAIM says? Edge cases, callers, type/shape contracts, the path the check never exercises. Name one input for which this is wrong. |
| **R3 — the link** | claim vs evidence | Does this output demonstrate THE CLAIM, or something adjacent that would look identical? Name the assumption joining evidence to claim, and attack it. |

- **≥2 refuted** → return to Step 4 with their reasoning appended as the new failure. Counts as one attempt.
- **≤1 refuted** → the claim survives. Record **all three** verdicts in the run-file, including the dissent.

Use `code-reviewer` for R2 when the diff is code; the default subagent is fine otherwise. **Never
give one agent all three lenses** — one agent with three jobs converges on one opinion, which is
the redundancy you were trying to avoid.

### Step 6 — On a surviving green

The **target repo's own rules win** over anything in this skill.

1. **Abort** if a live/production operation is in flight — notify, do not commit.
2. Stage **only loop-touched files**. Never `git add -A`.
3. Any staged file on the project's **Critical-tier** list → **STOP AND ASK** before committing.
4. Otherwise commit + push per the project's git workflow.
5. `PushNotification`.
6. Archive the run-file: the contract, every attempt's exit code, all three refuter verdicts.

---

## The run-file

One file, `run_<topic>_<date>.md`, in the project's notes location (**never** a committed `.md`
unless the project allows it). It holds the signed contract, the oracle contract, the attempt log,
and the refuter verdicts. **Update it as you go, not at the end** — it is what lets a fresh session
resume after context compaction.

## Hard rules

- **The oracle is chosen before the work, never after.** An oracle written after the fix is a
  description of the fix.
- **Never widen the oracle mid-loop to make it pass.** Narrowing it is worse. If the oracle turns out
  to be wrong, STOP, say so, and re-run Step 2 — a changed oracle needs a new baseline.
- **Never report done on a green that skipped the refutation panel.**
- **Never commit a Critical-tier file without asking**, whatever the loop concluded.
- **State what could NOT be verified.** Silence reads as confidence.
- Honour every prohibition in the target repo's `CLAUDE.md` — file-creation rules, framework bans,
  invariants (timezone, look-ahead, schema versioning). Those are absolute here.

## When NOT to use this

- **No machine-checkable DONE-WHEN exists** — taste, design direction, open research. Use
  `/grill-with-docs` alone. *A loop with a fake oracle is worse than no loop*, because it produces a
  green.
- **Trivial work.** Just do it.
- **Irreversible / production operations.** The loop does not own those; they stay in stop-and-confirm
  regardless of what the oracle says.
