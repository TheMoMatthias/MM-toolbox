---
name: continue-work
description: Drive the current work to completion autonomously - build the real list of what is outstanding from the conversation itself, decide every open fork yourself instead of asking, work the list to done without pausing to check in, and report once at the end. Use when the user says continue, carry on, keep going, don't stop, finish it, stop asking me, just decide, work through everything, do it all, or invokes /continue-work; and whenever a session is mid-task and the user wants it to run unattended rather than hand back after each step.
---

# continue-work — you have the wheel until the list is empty

**Invoking this is a standing instruction, not a nudge.** For the rest of this session, unless
the user says otherwise: you decide, you continue, and you report once at the end. They should
not have to type "carry on" again.

🔴 **And the honest half, which comes first because it is the one that gets dropped:
DO NOT INVENT WORK.** If the list is genuinely empty, say so plainly, say what makes it
empty, and stop. Padding a list to look busy is the failure mode this skill exists to avoid,
not the behaviour it asks for. *A mechanism that pressures a session to continue regardless
of whether anything remains is exactly what was removed to make room for this skill.*

---

## 1. Build the real list — from the conversation, not from memory

**Re-read the user's own messages in this session.** Not your summary of them. Requests get
buried mid-turn, arrive in asides, or sit inside a longer message about something else.

Then write the list. Every item, in one place:

- **Requested** — everything they asked for, including the clause you skimmed past.
- **Discovered** — anything you found on the way that a careful colleague would finish:
  a defect you noticed, a stale doc your change just invalidated, a test you did not run,
  a temp file you leaked, a claim you made that turned out wrong.
- **Deferred** — anything you said "later" about. Each needs a trigger, or it is not deferred,
  it is dropped.
- **Assumed** — every fork you decided alone. These need saying out loud at the end even
  when they were right.

Give each item a **done-when**: a command and its expected result, or a file:line, or an
observable state. *"Improve the error handling"* is not an item; *"`pytest tests/test_x.py -q`
reaches a summary line with 0 failed"* is.

**Where to keep it is your call** — a TodoWrite list, a scratch file, or in-message. What
matters is that it exists in writing and that discovered work gets **appended to it** rather
than mentioned in prose and forgotten.

## 2. Decide — do not ask

**Default to acting.** For every fork: pick what a careful colleague would pick, record it as
an assumption in one line, and keep moving. You can correct a wrong assumption far more
cheaply than a round trip costs.

Ask **only** when one of these holds — this list is the whole of it:

- the act is **irreversible or outward-facing**: production, money, deletion, credentials,
  publishing, a third party;
- another rule requires a **named approval** (e.g. an operator-patch lane);
- proceeding on **any** reading would make the work useless if wrong, and nothing on hand
  settles it — not the code, not the git history, not a recorded decision.

**Not reasons to ask:** you would like reassurance; there are two reasonable designs; the
task is bigger than expected; you are unsure they still want it (if it is in scope, it is
authorised); you want to show your options before choosing.

**When you genuinely must ask: finish everything that does not depend on the answer first**,
then ask once, batched, with your own recommendation marked and its evidence cited. A question
arrives with the rest of the work already done, never instead of it.

## 3. Work it to done

- **Top to bottom.** One item at a time, finished, before the next.
- **Verify each item against its own done-when** and keep the evidence — the command and its
  summary line. "Looks right" and "manually traced" are not results; they read identically
  whether or not you did the work.
- **On a wall: diagnose, then switch approach once.** Only if the second approach also fails
  does the item become blocked — and a blocker names what specifically is in the way and what
  would clear it. Hard, slow and tedious are not blockers.
- **A blocked item does not end the session.** Record it, move to the next item, come back.
- **Delegate rather than stop.** A broad search, a side-quest, a long verification, a second
  opinion — hand it to a subagent and carry on. Running out of your own attention is not the
  same as running out of work.
- **Progress pings, not check-ins.** One line at a real milestone. Never "shall I continue?"

## 4. The only four ways this ends

1. **Done** — every item finished, with evidence.
2. **A gate** — an irreversible or outward-facing act that genuinely needs the user.
3. **A real blocker** — recorded with what is in the way and what would clear it.
4. **The user says stop** — 🔴 **and this outranks everything above, immediately and without
   argument.** Any instruction to stop, pause, park or wait ends the run on the spot. Never
   negotiate with it, never finish "just one more item" first, never re-raise it later as
   though it were unfinished business. If they interrupt to steer, the new instruction
   replaces this one.

**Explicitly not endings:** you have written a good summary; the turn feels long; you found
something adjacent and would rather ask about it; a check went red and you tried one thing;
you are unsure whether they want the next item.

## 5. Report once, at the end

- **What changed** — file:line.
- **What was verified** — the command and its result line.
- **What could NOT be verified**, and how they can.
- **Every assumption you made**, listed plainly — this is what earns the autonomy.
- **What is still open** and why, each with its trigger.
- **What you deliberately did not touch.**

Then ask what to take next — one question, forward-looking. Not a menu of things you could
have done.
