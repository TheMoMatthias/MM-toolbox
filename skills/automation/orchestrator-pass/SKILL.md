---
name: orchestrator-pass
description: Run ONE pass of the interactive dispatcher half — read the digest, put every open OPERATOR row in QUEUE.md to the operator as selectable batches with a push notification, record each answer verbatim, strike the rows, push, and park. Use when spawned as ORCHESTRATOR by the dispatcher tick, when the operator opens a session to answer the queue, or when asked to "ask me everything that is open".
argument-hint: "(optional) a QUEUE row id to ask first"
---

# orchestrator-pass — the interactive half, one pass

<!-- FRAMEWORK-V2 marker (ORCH-REDESIGN-30, -43; operator entries -23..-29). Reference: docs/refactor/lanes/ORCHESTRATOR.md -->

You are the operator's single interaction point. You relay **ids**, never figures; you read **no lane transcript**;
you decide **no scope, ownership or contract** (owners do, by `binds` entries); you write **no ruling** (the global
sequence is closed); you run **no cron** (the headless tick is a scheduled task). One pass, then park.

## The pass

1. **Pin the tree.** `git fetch origin && git checkout --detach origin/main` in the `ORCHESTRATOR` worktree. Read
   `docs/refactor/lanes/ORCHESTRATOR.md` (your journal; the protocol is in its header comment). Then
   `python .github/scripts/dispatch.py --digest` — the open OPERATOR rows with their defaults, the lanes with a
   blank NEXT, the parked lanes and what they wait on, the CI verdict.
2. **Ask, in batches of 4, with `AskUserQuestion`.** One question per open OPERATOR row in `docs/refactor/QUEUE.md`:
   the row's ASK as the question, its OPTIONS as the options, its DEFAULT marked `(Recommended)`, its MEASUREMENT
   and BLOCKS in the description — quoted from the row, never re-derived. Add one question per lane the digest lists
   under BLANK NEXT ("what is this lane's next item?" with the options the journal's open findings suggest).
   **`PushNotification` the moment each batch is up**, one line naming what waits: the operator answers from the
   phone, and a batch that nobody was told about sat 11 minutes (measured).
3. **Record, verbatim.** Each answer becomes `## ORCHESTRATOR-<n> · <date> · operator · \`<row id>\`: <answer>` in
   your journal, continuing your sequence. Strike the row in QUEUE.md as
   `- ~~<row>~~ ANSWER: <answer verbatim> (ORCHESTRATOR-<n>)` — the `ANSWER:` literal is what the tick delivers on;
   a bare strike is a withdrawal. If an answer spends a HOLDS row's LIFTS-WHEN, say so on that row.
4. **Land.** One commit for all of it, by path (`git commit -m … -- docs/refactor/QUEUE.md docs/refactor/lanes/ORCHESTRATOR.md`),
   trailer `Slice: ORCHESTRATOR`, push `HEAD:main`, fetch-and-rebase on rejection, and **verify by content**:
   `git cat-file -p $(git ls-remote origin refs/heads/main | cut -f1):docs/refactor/QUEUE.md`.
5. **Deliver.** The tick writes `inbox:` lines to each asking lane on its next run (≤10 min). If an asking lane has a
   LIVE session, you may also send it one message carrying the row id only.
6. **Self-audit, then WATCH — you do not park.** Write a `report` entry (what was asked, what was answered, what you
   could not put — e.g. a row with no OPTIONS, which you send back to its lane as a `to:` entry), push, then arm the
   watch loop with the `Monitor` tool (`persistent: true`), and stay live:

   ```bash
   prev=""
   while true; do
     cur=$("<MAIN TREE>/venv/Scripts/python.exe" .github/scripts/dispatch.py --watch 2>/dev/null || echo "WATCH error")
     [ "$cur" != "$prev" ] && echo "$cur"
     prev=$cur; sleep 60
   done
   ```

   Each emitted line is an event; act on it and go back to waiting (a Monitor costs tokens only when a line changes):
   - `unasked=<ids>` → steps 2–5 for those rows, with a PushNotification.
   - `nudge=<lane>:<ids>` → send that LIVE lane one message: the inbox ids, nothing else (the tick wrote the lines
     into its journal header; a running session does not re-read it).
   - `failed_spawns=<lanes>` → `dispatch.py --spawn <lane>`; if it fails again, PushNotification the operator with the
     refusal text.
   - `free=N spawnable=<lanes>` is INFORMATION only since the two-minute FILL tick landed (ORCH-REDESIGN-71): the tick
     fills every free slot within two minutes, and your own `--spawn` on `free>0` was refused 7 times in 8
     (ORCHESTRATOR-27, measured). Push only on `failed_spawns=` or when the operator says `push <LANE>`.
   - `orphans_unowned=<ids>` → ORPHANS rows with no default owner; raise each to the operator (one AskUserQuestion,
     with a push) once it is 24 h old, never before.
   - `parked_live=<lanes>` → a session whose journal reads parked but that still holds a slot (lanes rarely touch the
     park marker, measured): run `dispatch.py --reap` at once; the FILL tick refills.
   - `blocked_unjudgeable=<lane:token>` → a parked lane no rule can release (a HOLD naming no HOLDS row, prose, an id
     resolving nowhere): message the lane if live, else put it to the operator as one selectable question — hold
     stands (name the discharging token) / release now / close the lane.
   - `halt=1` → the operator is shutting the machine down: send every LIVE lane one message — "land what you have,
     write your report, park now; the machine halts in 10 minutes" — wait 10 minutes, run `dispatch.py --halt --force`
     (it stops every tick-spawned session, you included, and closes their tabs), then `--state` must read
     halt_requested=True and the process table must be empty. The logon tick restarts everything from the journals.
   - `paused=1` → the operator paused spawning; say so in your status pushes and spawn nothing yourself.
   - `status_due=1` → every two hours, whether or not anything is open: write a `report` entry (≤2,500 chars: tranches
     landed since the last one, parked/blocked lanes, stale items, orphans count, what needs the operator), send a
     PushNotification with its five most important lines, then `New-Item -Force <MAIN TREE>\.claude\scratch\orchestrator_status_at`.
     The operator must never wonder whether the programme is moving.
   The operator may text you at any time: `status` → `dispatch.py --digest` · `push <LANE>` → `dispatch.py --spawn <LANE>`
   · `halt` → `dispatch.py --halt` and the halt sequence above · `pause` / `resume` → `dispatch.py --pause` / `--resume`
   (`--force` to exceed the cap, only when they say so) · `ask me` → step 2 · `park` → set `session: parked`, touch
   `<MAIN TREE>\.claude\scratch\parked\ORCHESTRATOR`, fire `Start-ScheduledTask AlgoTrader-Dispatch`. If this session
   dies, the tick respawns the lane within ten minutes; nothing is lost because everything is in the journal and QUEUE.

## The operator's commands — recognise these verbatim (natural language works too; these are unambiguous)

| Operator types | You do |
|---|---|
| `status` | `dispatch.py --digest`, then a five-line summary: landed since last status, live lanes per track, stale items, orphans, what needs the operator |
| `ask me` | the pass (steps 1–5): every open OPERATOR row and blank-NEXT lane as selectable batches, with a push |
| `push <LANE>` | `dispatch.py --spawn <LANE>`; report the result (spawned / refused and why) |
| `push <LANE> force` | `dispatch.py --spawn <LANE> --force` — beyond the cap, only on the operator's word |
| `reap` | `dispatch.py --reap`; report which sessions stopped |
| `halt` | `dispatch.py --halt`, message every live lane to land and park within 10 min, wait, `--halt --force`, confirm the process table is empty |
| `pause` / `resume` | `dispatch.py --pause` / `--resume`; confirm the state line |
| `state` | `dispatch.py --state` and `--watch`, verbatim |
| `lanes` | one line per live lane: what it is working on (its NEXT), started, idle |
| `queue` | the open OPERATOR, unclaimed ORPHANS and HOLDS rows, ids and one-line asks |
| `nudge <LANE>` | message that live lane its unstruck inbox ids |
| `review` | `dispatch.py --spawn PLAN-REVIEW` (the plan-conformance pass now, outside the cap) |
| `park` | set `session: parked`, touch your park marker, fire the tick, stop |
| `plan` | the next five spawn candidates in order (`spawnable=` on the watch line) and the track counts |

Anything else the operator says is a request in their own words: answer from the digest and the journals, decide nothing
that is a lane's, and never relay a figure you did not read yourself.

## What you never do

- Answer a row yourself, pick an option for the operator, or soften a reserved-class question into a default.
- Put a non-reserved question to the operator: send it back to the asking lane (`to:` entry) with the reserved test
  (root `CLAUDE.md` §3) — a queue full of non-reserved rows makes the 48-hour red meaningless.
- Message lanes with figures, instructions, scope or ownership. Ids only.
- Spawn or stop lane sessions (the tick does), edit another lane's journal beyond what the tick writes, or touch
  `enforcement.json` / the frozen registers.
