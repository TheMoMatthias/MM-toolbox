# Walls and quiet write-offs

Reached from step 4 of `realign` — whenever something looks like it cannot be done, or is
about to simply not get done.

🔴 **A false "blocked" is more expensive than a false "done".** A false "done" gets caught
by the next test run. A false "blocked" removes the work silently, permanently, and nothing
downstream ever asks about it again. Treat every "this cannot be done" as the weakest claim
in the session, not the settled part of it.

## The ladder — all five, in order

1. **State it as a falsifiable sentence.** Not "the migration is tricky" but "Alembic
   cannot autogenerate a partial unique constraint". A wall you cannot state precisely
   enough to be wrong about is a feeling, not a wall — and feelings do not get deferred.

2. **Diagnose the real failure.** The `diagnose` skill for a technical one: reproduce,
   minimise, hypothesise, instrument. **The first explanation is usually a symptom** — the
   import error that is really a version pin, the timeout that is really a lock. Deferring
   on a symptom defers the wrong thing.

3. **Take a different approach — not the same one more carefully.** A second careful pass
   at a failing approach is the same attempt with more time spent. Change something
   structural: a different library call, a different layer, a different order of
   operations, doing by hand what you tried to automate.

4. **Look outside your own head before concluding it cannot be done.** Ranked by how often
   each one dissolves the wall outright:
   - **This codebase.** Search for the place it was already solved. Precedent beats
     invention, and a repo this size usually has one.
   - **The primary docs.** The library's own reference, not your memory of it. Most
     "X doesn't support Y" is "I don't know how X does Y".
   - **A research subagent** — cheap, parallel, and it reads sources you would not.
   - **`reevaluate`** when it is not one wall but the whole approach that smells wrong.

5. **Two real approaches down, it escalates** — with everything below. Hard cap ~5 attempts
   or ~30 minutes, per `CLAUDE.md`, whichever comes first. "Real" means it ran and failed,
   not that you thought about it.

## The escalation — four things, never fewer

A wall that survives the ladder does **not** become a `DEFERRED` line you write yourself.
It goes to the user as an `AskUserQuestion`, carrying:

**1. The claim.** One falsifiable sentence, in the terms of the system — not "the auth
piece is complicated".

**2. What you tried.** Each approach and its *actual* failure output — the traceback, the
exit code, the wrong number. "It didn't work" is not an attempt report.

**3. How far the conclusion can be trusted.** Exactly one of:

| | what it means | how much weight it carries |
|---|---|---|
| `measured` | you ran it and watched it fail | strong — the failure is observed |
| `documented` | a primary source says so, and you cite it | strong, if the source really addresses your case |
| `inferred` | you reasoned it from code you read, and never tested it | **weak** |

🪤 **`inferred` is the weakest and by far the most common**, because reading code produces
a confident-feeling conclusion at no cost. It reads exactly like `measured` in a summary.
**Label it plainly, and never let an `inferred` wall close an item on its own** — if it
matters enough to defer, it matters enough to run once.

**4. What would change it.** The concrete thing that makes it solvable — a decision, a
dependency, an access grant, a design change. A wall with no such thing named has not been
understood yet; go back to step 2.

## Then it is their call

Offer, with a recommendation: **keep pushing** · **defer with a trigger** (a real,
observable event — not "later") · **drop it** · **hand it to a fresh session**.

## The shapes not-doing takes

Everything above assumes a moment where you decide to stop. **The larger loss has no such
moment** — nobody chose, so there is nothing for a rule about authority to catch:

- **Never reached.** It was in the sweep, it got an approach in step 2, and the turn ended
  first. No decision was made; the item just stopped existing.
- **Met in part, reported whole.** Three of five requirements satisfied, one status given.
- **Substituted.** An easier neighbour got done and counted — the caching layer that became
  a dict, the migration that became a note in the README, the test that asserts the mock.
- **Routed around.** The wall was avoided instead of declared, so nothing escalated and the
  scope shrank with no decision anywhere in the record.
- **Stopped at good-enough.** A quality bar lowered mid-run and never mentioned.
- **Waiting implicitly.** Not started because it felt like it needed a decision — but the
  decision was never actually put to anyone.

🔴 **The catch is reconciliation, not permission.** Every item from step 1 lands on exactly
one line of the closing block — `VERIFIED`, `WALLS`, `DECIDED`, `DEFAULTS`, `DROPPED`,
`DEFERRED` or `NEXT`. An item on none of them was written off by nobody. If it was not done
and they did not agree to stop, it belongs on `NEXT`, not in silence.

Silently narrowing the job is the failure `realign` exists to catch, and doing it to
yourself mid-run counts.
