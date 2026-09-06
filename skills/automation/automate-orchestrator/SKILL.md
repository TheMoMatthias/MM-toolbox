---
name: automate-orchestrator
description: Re-establish and operate the journal-and-queue coordination framework for a programme of parallel Claude sessions — lanes as durable journals, sessions as one-tranche runs, a zero-token dispatcher that spawns, reaps, un-parks and delivers, an interactive pass that puts only the reserved decisions to the operator as selectable batches, and owners who number their own decisions. Use when starting or restoring coordination on any repo, when the previous orchestration session's context is gone, when sessions idle with work outstanding, when decisions evaporate instead of reaching a register, or when porting this workflow to another project.
argument-hint: "(optional) install | operate | port <repo> — default: operate on the current repo"
---

# automate-orchestrator — the framework, in the order you need it

<!-- FRAMEWORK-V2 marker: rebuilt 2026-09-06 by ORCH-REDESIGN under R-524 (rulings R-525..R-534, entries ORCH-REDESIGN-1..-46).
     The AlgoTrader repo is the reference implementation; every path below is relative to it. -->

> **What replaced what, and why (measured, AlgoTrader 2026-08-25 → 09-06).** A standing coordinator session that
> relayed messages between 19 long-lived lanes cost 3.6–4.4 BILLION input tokens per lane over 12 days at a median
> context of ~500k per call, received 190–234 cross-session messages per lane, closed 57 of 64 rows in a day or
> less each, and still let three lanes' pause state go wrong in a memory file within days. The design below cut a
> lane's per-call context to ~225k (a 20-minute tranche costs ~24M tokens instead of ~300M per day), removed the
> coordinator's relay entirely (0 inbound messages in the fresh sessions), and put every decision where its owner
> writes it. The first hour of operation found the machine's own defects (a parked session never exits; a `LANE:`
> block never resolved; duplicate deliveries; no push notification) — all fixed in `dispatch.py` and listed under
> **Invariants** so a port does not re-learn them.

## 0. The model, one screen

| Thing | Is | Lives at |
|---|---|---|
| **Lane** | a name + a durable **journal**; the header IS the register row (`owns`, `plan_row` strict key or `NONE`, `state` open/parked/closed, `NEXT` one line, `BLOCKED` token, `tranche`, `last_landed`, `session`, `migration_prefixes`, `inbox:` lines) | `docs/refactor/lanes/<LANE>.md` (template `lanes/_TEMPLATE.md`) |
| **Entry** | `## <LANE>-<n> · <date> · <tag> · <title>` — tags `finding · binds · operator · close · report · fanout`; ≤800 chars; every figure graded inline `(measured)/(relayed: id)/(documented: path:line)/(inferred)`; ids CONTINUE the lane's frozen sequence, never restart | the journal, append-only, newest last |
| **Session** | ONE tranche (≤3,000 statements / ≤50 files), then `report` entry + park. Hard stop at the second context compaction | spawned INTO `.claude/worktrees/<LANE>` (detached from `origin/main`) |
| **QUEUE** | the ONE file for what needs the operator (**OPERATOR**: reserved classes only), work nobody owns (**ORPHANS**, with a default owner), and holds (**HOLDS**: a hold with no row does not exist). The asking lane writes its own row; an answered row is struck `~~…~~` + `ANSWER: … (<recording id>)` | `docs/refactor/QUEUE.md` |
| **Decision** | a `binds` entry with `check: <script>` or `NO CHECK — <why>`, numbered by the OWNER under its own lane id; a cross-lane contract = two entries carrying a `to:` line; disagreement → OPERATOR row. The global ruling sequence is CLOSED | the owner's journal |
| **Dispatcher, headless** | `dispatch.py --run` from a scheduled task every 10 min, zero tokens: REAP · UN-PARK · DELIVER · SPAWN · digest | `.github/scripts/dispatch.py`, `dispatch_tick.ps1`, task `AlgoTrader-Dispatch` |
| **Dispatcher, interactive** | the `ORCHESTRATOR` session: digest → selectable batches to the operator with a push notification → record verbatim → strike → park. Spawned by the tick OUTSIDE the cap when an OPERATOR row it never asked is open | `lanes/ORCHESTRATOR.md` (the protocol is in its header comment); skill `orchestrator-pass` |
| **Board** | derived, never maintained: `status.py --session-start`; the digest is `dispatch.py --digest` | `.github/scripts/status.py` |
| **Rules** | root `CLAUDE.md` §1–§8 (no grills · lane/session/dispatcher · owners decide · QUEUE · landing · quality checklist · self-recut · standing constraints) | repo root, loaded into every session |

**Reserved to the operator, always:** production writes · the money path / live trading · deploy or restart · data deletion or table drops · anything a `CLAUDE.md` 🔒 covers · a disputed decision. Everything else is the owner's to number. Code deletion is not reserved.

## 1. Install (fresh repo, or after losing the previous orchestration session)

Everything is a file in the repo; nothing lives only in a session. Do these in order and verify each by content.

1. **Root `CLAUDE.md`** — copy AlgoTrader's §1–§8 block (the "SPEC-EXECUTION programme · session rules" file) and adapt names. It overrides any per-prompt grill gate: a lane on a plan row never runs an alignment round; `AskUserQuestion` is never a programme decision.
2. **`docs/refactor/lanes/_TEMPLATE.md`** — copy verbatim. The header field order matters: `dispatch.py` and `status.py` read it.
3. **`docs/refactor/QUEUE.md`** — the three sections with their row forms (copy the header paragraphs from AlgoTrader's; strike nothing, delete nothing, ever).
4. **`docs/refactor/lanes/ORCHESTRATOR.md`** — copy; its header comment IS the interactive protocol. `NEXT: nothing outstanding …` is deliberate.
5. **`.github/scripts/dispatch.py`** — copy. Parameters at the top: `LANES`, `QUEUE`, `STATUS`, `SPAWN` (the `spawn-claude-session` skill's `spawn.ps1`), `MAIN_TREE`, `WORKTREES`, `CAP_FULL/CAP_HALVED`, `PRIORITY` (operator-pinned first spawns), `NON_LANES` (the interactive half), `REAP_IDLE_MIN`, `REAP_OPEN_IDLE_MIN`, `WORKFLOW` (the CI yaml for red routing). Run `--selftest` (17 named arms) and `--dry-run` before the first real tick.
   *Contract it needs from the board:* `status.py --json` must return `live_sessions` (`lane`, `pid`, `idle_min` from transcript mtime, `started`, `repo`) and `gate` (`verdict`, `run_id`, `first_red_sha`). A repo without `status.py` gets a 40-line stand-in: process table (`Get-CimInstance Win32_Process`, `-n <lane>` in the command line) + transcript mtime under `~/.claude/projects/<repo-slug>/`.
6. **`.github/scripts/dispatch_tick.ps1`** — copy (pure ASCII; it pins a `DISPATCH` worktree to `origin/main` each tick, runs the MAIN tree's interpreter, byte-redirects through `cmd.exe`, forces `PYTHONUTF8=1`).
7. **The scheduled task** — through the operator-patch lane if the machine has one; else `Register-ScheduledTask` with `-LogonType Interactive`, trigger `-Once -RepetitionInterval (New-TimeSpan -Minutes 10)`, action `powershell -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File <DISPATCH worktree>\.github\scripts\dispatch_tick.ps1`. Verify `LastTaskResult = 0` and a log at `.claude/scratch/dispatch.log` in the MAIN tree.
8. **`automate-realign` destination override** — its output goes to the lane's journal as a `report` entry plus QUEUE rows, never as a message to a session (AlgoTrader's SKILL.md carries the override block; copy it).
9. **Migrate existing lanes** — one journal per lane from whatever state file it had: header + pointers to open findings by id; ids CONTINUE; `plan_row` a strict key or `NONE`; a one-line pointer at the top of the old file, then stop editing it. A new lane also opens a minimal register row where the repo keeps one (`enforcement.json` in AlgoTrader).
10. **Relaunch** — stop every long-lived session after verifying its journal landed on `origin/main` by content and its pid identity (`stop_lane.ps1` shape: `git cat-file -p $(git ls-remote origin refs/heads/main | cut -f1):<journal>`, then `Win32_Process` command line must carry `-n <lane>`). Then let the tick spawn.

## 2. Operate — what runs by itself, and the two things a human does

**The tick (every 2 min a FILL — reap parked sessions, refill free slots from the process table; every 10 min the full pass below; zero tokens):**
- **REAP**, inside a strict domain: ① any session whose lane carries a **park marker** (`<main>/.claude/scratch/parked/<LANE>`, the lane's own last act) newer than the session — ended at that tick, busy or idle; otherwise ② only a session **the tick itself spawned** (it records pid and time in `dispatch_spawned.json`) and **never one a human typed into** after its first two minutes (transcript metadata only), when its journal reads parked, was committed by the lane after the session started, and it idled ≥8 min; ③ a tick-spawned OPEN lane idle ≥2 h. Identity-checked `Stop-Process`. Without reaping the cap fills with idle processes within one hour (measured: 4 of 4 slots, zero lanes working); without the domain the reaper stopped the operator's own session (measured, 2026-09-06 19:34).
- **UN-PARK** by the `BLOCKED` prefix: `QUEUE:<id>` struck · `HOLD:<id>` struck · `LANE:<id>` landed as an entry heading.
- **DELIVER** `inbox:` lines, once per (lane, key): a new journal entry's template deviations (`[LINT:<id>]`, form only) · answered OPERATOR rows (an `operator` entry citing the row also counts as delivered) · any entry whose body opens `to: LANE` whatever its tag · ORPHANS rows naming a default owner · a red main to the last lane on the failing script's path (`[CI-RED:<first red sha>]`, one line per lane per window) · a `close` with no same-day `report`. Committed `[skip ci]` with `Slice: ORCHESTRATOR`.
- **SPAWN** the ORCHESTRATOR whenever none is live (outside the cap, always live); then open lanes with a NEXT, `BLOCKED: NONE`, no live session — red-holders first, then `PRIORITY`, then the most starved — under the cap (8, halved while CI has <1 green run in 24 h). A failed spawn holds no slot. A clean lane worktree is pinned to `origin/main` first.
- **A lane's last act at park** is touching the park marker and `Start-ScheduledTask AlgoTrader-Dispatch`, so the freed slot refills at once.

**The ORCHESTRATOR stays live and watches** (`dispatch.py --watch` under a `Monitor`, one line every 60 s, tokens only on change): new OPERATOR rows → it asks with a push notification; a live lane with unstruck inbox lines → it messages that lane the ids; a failed spawn → `dispatch.py --spawn <lane>`. The operator texts it at any time: `status`, `push <LANE>`, `ask me`, `park`.

**The operator does two things:** answers the ORCHESTRATOR's selectable batches (from the phone; a push notification announces each), and acts on the reserved-class items in person. Nothing else reaches them.

**A lane session does one thing:** its NEXT, as one tranche, under the `lane-tranche` skill.

## 2b. Power cycles — the machine is not on 24/7, and nothing here needs it to be

Durable state is the repo (journals, QUEUE) plus five scratch files (spawn records, seen entries, park markers, the
status stamp, the sweep/pause/halt flags). A session is one tranche, so a power-off is "every session dies
mid-tranche" and a power-on is "the tick spawns from the journals". Three mechanisms make that orderly:

- **Halt before shutdown:** the operator texts the ORCHESTRATOR `halt` (or runs `dispatch.py --halt`). The
  ORCHESTRATOR tells every live lane to land and park within 10 minutes, then runs `--halt --force`, which stops every
  tick-spawned session and closes its tab. If nobody runs it, the tick itself force-reaps 15 minutes after the halt
  flag appears. A hard power-off without a halt costs at most one unfinished tranche per lane: the worktree keeps the
  uncommitted files, and the next session's prompt tells it to read that diff against its NEXT before continuing.
- **Restart at logon:** the `AlgoTrader-Dispatch-Logon` task fires two minutes after the operator logs in and runs
  `dispatch_tick.ps1 -Logon`: it heals the DISPATCH checkout (a tick cut mid-rebase), clears a shutdown halt (never an
  operator `--pause`), and runs a full tick — reaping nothing (no processes), then spawning the ORCHESTRATOR and every
  open lane up to the cap. No tool and no human message is needed; the operator's own session-restore tool is only
  for the sessions the operator opened by hand.
- **Pause / resume:** `dispatch.py --pause` stops spawning until `--resume`; live sessions finish their tranche and
  are reaped as usual. The pause survives a reboot because it is the operator's intent; a halt does not.

Port to another project: the same three, renamed; the only machine-specific parts are the two scheduled tasks.

## 3. Invariants — each one was bought with a measured failure

- **A session never exits by itself.** "Park" is a header edit; the reaper is what ends the process. Never count on a session closing.
- **The interactive half is never a cap candidate** (`NON_LANES`), and a `NEXT: nothing outstanding` is the exhaustion signal the tick reads.
- **Nobody relays a figure or an answer.** The asking lane writes the QUEUE row; the ORCHESTRATOR strikes it with the answer; the asking lane records it verbatim. A seeded, relayed row was wrong on first contact (`ORCH-REDESIGN-3`).
- **Cross-lane consent is an entry with a `to:` line, not a message.** A message reaches only a live session; `V-INGEST-180` reached nobody and the critical-path lane sat parked on it for an hour.
- **Ids continue the frozen sequence.** A journal restarting at `-1` makes one id resolve to two facts; a QUEUE row's id IS its journal entry's id (`V-INGEST-182`, `ORCH-REDESIGN-20`).
- **A `BLOCKED:` token has a prefix.** Prose there is unjudgeable; so is prose in `plan_row` (it made STALL unjudgeable for a week).
- **Every figure carries its grade inline**; a relayed figure is never published past the lane that measured it; every sweep names its DOMAIN and blind spot; every assertion ships with the control that can fail.
- **The ORPHANS escalation goes to the default owner first**; an instrument red is not an operator question.
- **The fixed context floor is the cost.** 144k tokens on the first call of every fresh session (measured, identical across sessions): instruction files + board + skill/agent descriptions. It is 66 % of a tranche. Cut the session-start board to ≤2 KB, keep instruction files lean, never print "read these N rulings" into every session.
- **Verify a push by content**, never by exit code: `git cat-file -p $(git ls-remote origin refs/heads/main | cut -f1):<path>`.
- **The dispatcher reads no transcript, decides no scope, writes no ruling.** Judgement lives in owners' `binds` entries and the operator's answers.

## 4. Port to another project

Copy items 1–8 of §1, then rename: the task, the `Slice:` trailer convention (any commit trailer that names the lane), the lanes directory, the CI workflow file for red routing. Keep the header field order, the tags, the `BLOCKED` prefixes and the QUEUE row forms byte-identical — the parsers are regexes over them. Pin `PRIORITY` to the project's critical path. If the project has no CI, set `cap_for()` to return `CAP_FULL` and drop red routing; if it has no plan rows, `plan_row: NONE` everywhere and STALL is judged on landings alone.

## 5. Superseded — do not resurrect

`automate-lane-status`, `automate-lane-check` (the journal header + `dispatch.py --digest` are the status), `agency-lane-worker` (the journal is the brief), `handover-and-spawn` (the journal is the handover; the tick spawns), the 20-minute check-in loop, coordinator rotations, the `_STATE.md` briefs, the coordinator's relay of answers, and any cap on lanes below the CI-derived one. `spawn-claude-session` stays (the tick calls it); `automate-realign` stays with its journal destination; `orchestrator-pass` and `lane-tranche` are the two operating skills.

## 6. Where the evidence is

AlgoTrader `docs/refactor/DECISIONS_REFACTOR.md` R-525..R-534 (the last global rulings) · `docs/refactor/lanes/ORCH-REDESIGN.md` entries -1..-46 (interviews, token profiles, the null-hypothesis verdict, the first-hour defects and their fixes) · memory `run_orch_redesign_2026-09-06.md` · `.github/scripts/dispatch.py --selftest` (every branch fires by name, with its negative).
