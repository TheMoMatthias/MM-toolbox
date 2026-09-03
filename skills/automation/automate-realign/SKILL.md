---
name: automate-realign
description: The orchestrated variant of /realign - close out a report, summary or "I'm finished" claim without leaving anything on the field. Re-read your own CONVERSATION first, then the artefacts, account for every open item and deviation, decide the approach yourself, break what stands in the way instead of writing it off, then emit ONE structured block to ORCHESTRATOR instead of asking the user. Use this INSTEAD of /realign in any session reporting to an orchestrating lane - when a progress report or status update has just been given, when the session claims the work is done or that it has nothing outstanding, when something has been called blocked, too hard or not feasible, when something was skipped or never got done, or when told to realign, carry on, keep going, or not leave anything open.
argument-hint: "(optional) an area to focus on, or a steer for what to do next"
---

# automate-realign

> 🔴 **§0 IS MANDATORY AND RUNS FIRST — IT ABSORBS `automate-lane-check`, WHICH IS NO LONGER A
> SEPARATE SKILL:**
> ```
> venv/Scripts/python.exe "$HOME/.claude/skills/automate-lane-check/lane_check.py" --as-realign-input
> ```
> **It answers the one thing you CANNOT get from your own context: WHICH RULINGS LANDED WHILE YOU
> WERE BUSY.** ⚖️ Nothing else in the programme tells a lane a ruling arrived, and silence on a
> disputed ruling is taken as ASSENT. **Read its `RULINGS` section before writing a single line of
> your block; a sweep that misses a ruling landed against your own row is not a sweep.**
>
> 🔒 **WHEN THIS SKILL RUNS — it is no longer ad-hoc:** **① whenever the orchestrator asks** (they
> now rotate it across lanes every check-in) · **② ALWAYS before your row closes** — `R-107` §3
> refuses a closed lane's trailer, so anything you still hold becomes unrecoverable at close ·
> **③ ALWAYS when you are about to report *nothing outstanding*.** 📏 **Measured across one day that
> claim was sincere and wrong three times out of three, and what it omitted was never work anyone
> had forgotten: a promise made mid-message, a question routed once and never answered, and a
> decision that only ever existed in conversation.**
>
> 🔑 **AND GRADE EVERY FIGURE YOUR BLOCK CARRIES (`R-328` ①): `measured-by-me` / `relayed` /
> `documented`.** `relayed` is not forbidden; publishing it UNLABELLED is. **A block that hands the
> orchestrator an ungraded number is how a wrong figure reaches another lane's brief — measured
> four times in one day.**


**The deliverable is work resumed correctly, plus one block ORCHESTRATOR can act on without
asking you anything back.** §0 and §1 make it honest, §5 is the point, §6 is what they read.

🔴 **THIS SKILL NEVER CALLS `AskUserQuestion` AND NEVER CALLS `PushNotification`.** Every
decision goes to **ORCHESTRATOR by `SendMessage`**, who puts it to the operator and lands the
answer as a numbered ruling. **`AskUserQuestion` has no path from the answer back to the
ledger** — the operator can only click, the reasoning evaporates, and you cannot record what
was decided. **A question you put directly to the operator is a decision that will not
survive the session.**

🔴 **AND IT NEVER ENDS BY STOPPING.** Send the block, then **continue with everything not
blocked on a numbered decision.** One pending answer does not block a board.

**Honour `$ARGUMENTS`** — an area scopes the sweep (say so); a steer settles the ordering, so
do not re-ask what you were just told. **Scale the effort to the board.**

---

## §0. READ YOUR OWN CONVERSATION — mandatory, first, and not skippable

🔴 **Before touching an artefact, re-read this session's conversation from the start of the
current block of work.** ⚖️ **Your summary of it is not a substitute — that summary is the
thing under test.** 🔑 **Measured across a full day of parallel lanes, EVERY item lost was
lost here: stated in a message, acted on once, and never re-read.**

**Extract five things. Each becomes a line in the block. Write `(none)` where empty:**

1. **UNANSWERED** — every question you asked that never got an answer. **A question asked
   once and not repeated is a question that was dropped**, and you will not remember it.
2. **PROMISED** — every *"next I will…"*, *"then I'll take…"*, *"after this…"* you wrote.
   **Did you do it?** 🪤 **This is the single highest-yield line**: a stated next item is a
   commitment nothing tracks, and neither a board nor a status tool can see it.
3. **SUPERSEDED** — every claim, figure or verdict you published that a later message
   corrected. 🔴 **AND WHETHER THE WRONG VERSION REACHED ANYONE ELSE.** A correction that
   did not travel as far as the error is not a correction. Name who got the original.
4. **INBOUND-UNCONFIRMED** — everything routed *to* you that you have not acknowledged,
   acted on, or explicitly declined. **Silence on an inbound item reads to the sender as
   agreement.**
5. **ORAL-ONLY** — anything decided, measured or agreed **in conversation that never reached
   a register, ledger, brief or file.** 🔑 **This is the one that costs most: a decision that
   exists only in a message is invisible to every sweep, every check and every future
   session, and it will be re-litigated or silently reversed.**

⚖️ **If §0 returns nothing on all five lines, say so explicitly.** That is a finding, not a
formality — and it is rarer than it feels.

## §1. Sweep the artefacts — evidence, not recollection

🔴 **If the work was just called done, that claim is the thing under test.** Re-read the
register rows, the files, the check output, the commits. **A summary is not evidence for the
claim the summary makes.**

🔑 **The three this catches most often:**
- **A ruling that mandated a register change and never landed** — the ledger says one thing,
  the register another, and nothing compares them.
- **A question already answered whose row still wears an open marker** — it gets routed to
  somebody a second time.
- **A claim TRUE WHEN WRITTEN that expired silently** — a count, a blocked-by, a denominator.
  🔒 **Re-derive every figure you are about to carry forward. Do not quote your own earlier
  number.**

🔴 **Then run it in the other direction.** *"Can't be done"*, *"unsupported"*, *"out of
scope"* — each is a claim with a confidence, and most are `inferred`. **Say which.**

## §2. An approach for every item — you may not defer here

🔴 **Every item leaves this step with an approach, the hard ones included.** "Too hard" and
"someone else's" are not approaches — they are §5 outputs, and must arrive there having been
*tried*. ⚖️ **Ownership is not an approach either**: an item outside your subtree still gets
one — *"measure it read-only and route it"* is one. **Declining to act is correct; declining
to think is not.**

## §3. Reconcile — every item lands on exactly one line

**Group by track.** Two items share a track when one decision steers both. 🔴 **Every item
from §0 and §1 lands on exactly ONE line of the block. Nothing leaves unaccounted.**
🪤 **Simply not doing a thing is the same act with no decision to point at** — a deferral
leaves a trace; an item never started, half-satisfied, or swapped for an easier neighbour
leaves none.

## §4. Route direction — to ORCHESTRATOR

- **HOW — decide it.** Implementation, tooling, structure, ordering inside a step. Goes under
  `DEFAULTS`; it is not a decision to route.
- **WHERE — route it.** Priority, scope, what counts as next, whether the objective holds.

**Six probes, over EACH track:** ① does what you learned change what *done* means · ② is the
next item still the right one · ③ has cost/benefit moved · ④ does new evidence undercut an
assumption the plan rested on · ⑤ is anything now not worth doing · ⑥ **what did landing this
make possible that was not before?**

🔴 **A track you did not examine is a track you decided alone.** ⛔ **But do not manufacture a
fork** — no genuine uncertainty means one line saying where you are heading.

🔒 **Mark each decision with the operator-reserved class it touches, if any:
`production-write` · `capital` · `scope-widening` · `reversal` · or `NONE`.**
**ORCHESTRATOR decides everything marked `NONE` themselves — marking this correctly is what
lets them answer immediately instead of asking you back.**

## §5. Carry on — and break what is in the way

**Your own decisions are now locked.** Do not re-litigate; do not seek confirmation to begin.

🔴 **A wall is work, not a finding.** Do not report it, route around it, or narrow the scope
to avoid it. **Try it.**
🔴 **You do not defer, drop, descope or substitute on your own authority.** A wall that
survives goes into the block with its claim, what you tried, **its confidence —
`measured` · `documented` · `inferred`, and `inferred` is the weakest and by far the most
common** — and what would change it.

Say what you are doing in one line, then do it. **Do not narrate progress mid-run.**

## §6. The block — emit it AND `SendMessage` it to ORCHESTRATOR

🔒 **Omit any line that is empty EXCEPT `HEADLINE`, `DECISIONS` and `NEXT`** — those three are
never omitted; write `(none)` and mean it. **Asserting emptiness out loud is the point.**

🔴 **RANK EVERY LIST BY CONSEQUENCE, NEVER BY COUNT.** ⚖️ **Count is the axis that is always
available and almost never the one that ranks** — measured repeatedly: 512 alarms on a
re-fetchable plane against 1 on an irrecoverable one; a 2,714-row cluster whose real content
was 21. **Order by what is lost if it is wrong: irrecoverable first, then live-and-growing,
then bounded, then cosmetic.**

```
=== REALIGN-AUTOMATE | <LANE> | <UTC timestamp> ===

HEADLINE    ONE line. The single most consequential thing ORCHESTRATOR must know.
            If nothing is consequential, say so in one line.

--- what the conversation held (§0) ---
UNANSWERED  questions you asked that were never answered
PROMISED    what you said you would do next, and whether you did it
SUPERSEDED  what you published that was later corrected -- AND WHO GOT THE WRONG VERSION
INBOUND     routed to you and not yet acknowledged, acted on, or declined
ORAL-ONLY   decided/measured/agreed in conversation, never written to any register

--- what you did (§1-§5) ---
VERIFIED    what you re-checked and HOW: the command, the query, the file:line.
            Not "confirmed" -- the evidence.
CHANGED     what you fixed or landed, with commit shas
REJECTED    what you considered and refused, WITH THE REASON. A refusal without its
            reason is indistinguishable from an oversight to the next reader.
WALLS       what stood in the way | what you tried | how it ended | measured|documented|inferred
CORRECTIONS what this sweep proved wrong in your own earlier work
DEFAULTS    what you settled yourself, and why -- NOT decisions to route
DROPPED     what is being stopped, and on whose authority
DEFERRED    claim | confidence | trigger | OWNER | SEQUENCE | DONE-WHEN | HOW
SENT        what went to which lane, and whether they confirmed

--- what ORCHESTRATOR must act on ---
DECISIONS   NEVER OMITTED. Ranked by consequence. For each:
            D<n>  <the question, one sentence>
                  WHY NOW    what is blocked or degrading while this is open
                  OPTIONS    each with its CONSEQUENCE, not just its name
                  RECOMMEND  your pick + its evidence (file:line | a measurement | a ruling).
                             Never omit what you actually think.
                  RESERVED   production-write | capital | scope-widening | reversal | NONE
                  BLOCKS     what of yours waits on this, or NOTHING

NEXT        NEVER OMITTED. Remaining work per track, in the order you will do it, marking
            what runs in parallel and what is blocked on which D<n>.
            Write `NEXT  (nothing outstanding)` and mean it.
```

**Then one or two plain sentences outside the block** — what happens now, named. **Not a
restatement of the block.**

## §7. How it ends — never "stop and wait"

| NEXT | what you do |
|---|---|
| `(nothing outstanding)` | send the block, say what makes it closed, stop |
| blocked ONLY on a `D<n>` | send the block, say **which** decision, stop |
| anything else | send the block, then **CONTINUE** with everything not blocked on a `D<n>` |

🔴 **The most common failure is stopping with unblocked work on `NEXT` because a decision is
pending on something else.** **If three items are open and one needs a ruling, do the other
two and say the third is waiting.**

🪤 **FOUR WAYS THIS GETS DODGED. All feel like an ending; none is one:**
1. **The block feels terminal.** It is a reconciliation. Emitting it is one step of two.
2. **`DEFERRED` and `DROPPED` read as closure.** They are not `NEXT`.
3. **"I sent it to ORCHESTRATOR."** Sending is not waiting.
4. **"§0 found nothing."** Then say so on all five lines. **An omitted §0 line reads as
   *nothing there* to the next reader and to you, and you never check whether that is true.**

🔴 **Before you stop, re-read your own `NEXT` line.** If anything on it is not blocked on a
numbered decision, **you are not finished — go and do it.**
