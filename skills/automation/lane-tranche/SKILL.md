---
name: lane-tranche
description: The specialist lane's session discipline under the journal-and-queue framework — read your journal, act on your inbox, do exactly ONE tranche of your NEXT, land it by path with the lane trailer, write the self-audit report entry, park with strict header tokens, and fire the dispatcher tick. Use when spawned by the dispatcher onto a lane, when resuming a lane from its journal, or whenever a session on a plan row is about to claim done or blocked.
argument-hint: "(optional) the lane name; default: the -n name this session was spawned with"
---

# lane-tranche — one session, one tranche, then park

<!-- FRAMEWORK-V2 marker (R-526 §2, R-528, R-533; ORCH-REDESIGN-28, -40). Reference: root CLAUDE.md §1–§8, lanes/_TEMPLATE.md -->

## Start (≤5 minutes, no exploration beyond your own paths)

0. `git status` first. Uncommitted changes in your worktree are your predecessor session's unfinished tranche — a reap,
   a halt or a power-off cut it. Read the diff against your NEXT; continue it or discard it deliberately (`git checkout
   -- .`), never blindly, and say which in your first entry.

1. Read root `CLAUDE.md` §1–§8, then your journal `docs/refactor/lanes/<LANE>.md`: the header is your register
   row, the entries are your memory. **Do not** read other lanes' journals, transcripts, or the frozen registers
   beyond the ids you cite; a claim about another lane's artefact cites that lane's entry id.
2. **Act on every `inbox:` line, then strike it (`~~…~~`) in the commit where you act.** A `CI RED` line IS your
   NEXT. An answered QUEUE row → record it verbatim as `<LANE>-<n> · operator` naming the row. A `to:` entry from
   another lane → cite its id where it binds you. A `NO-REPORT` line → write the missing `report` entry first.
3. No grill, no alignment round, no `AskUserQuestion` (root `CLAUDE.md` §1). Apply the **reserved test** before
   writing any OPERATOR row: production writes · money path · deploy/restart · data deletion · a 🔒 rule · a disputed
   decision. Anything else is yours to number as a `binds` entry (with the other owner's consent id if it crosses a
   lane, obtained by an entry carrying a `to:` line — never by a message to a session that may not be live).

## The tranche

- **One item, ≤3,000 statements / ≤50 files.** If NEXT is larger, re-cut it: the first sub-item is this tranche,
  the rest becomes the new NEXT.
- **Quality, every landing (R-533):** every figure graded inline `(measured) · (relayed: id) · (documented: path:line) · (inferred)`;
  a relayed figure is never published past the lane that measured it; every sweep states its DOMAIN and blind spot;
  every assertion ships with the control that can fail (assert AND run — ask what a green would print if the
  system were broken); a contract landing reads its CONSUMER; a deletion names WHERE the thing's purpose was
  verified; every derived figure names its sha; a finding names `class: … · prior: …`; a landing over 20 files gets
  a fresh read-only subagent's adversarial pass.
- **Landing (R-528/R-532):** `main` only, from your detached worktree, `git commit -m <msg> -- <paths>` (never a bare
  commit — the index is yours alone only because the worktree is), trailer `Slice: <LANE>`, `git push origin HEAD:main`,
  fetch-and-rebase on rejection, never force, never `--no-verify`. Journal edits land IN the commit that produced
  them. **Verify by content:** `git cat-file -p $(git ls-remote origin refs/heads/main | cut -f1):<path>`.
  One push per tranche step, not per register edit. Ask the tool for a migration prefix, never a listing.
- **Cross-lane:** a result another lane must see is an entry whose body opens `to: LANE1, LANE2` — the tick
  delivers it. Work nobody owns → an ORPHANS row naming the default owner (importing side owns an inbound edge).
  A block on another lane → `BLOCKED: LANE:<their entry id>`; on a QUEUE row → `QUEUE:<id>`; on a hold → `HOLD:<id>`.
  The tick un-parks you when the token is discharged.

## Done or blocked — the self-audit is mandatory

Run `automate-realign` at every done/blocked claim. Its block goes to your journal as a `report` entry (what was
proven, what was NOT, the domain and blind spots, every open item and where it went) plus QUEUE rows for anything
reserved. Never as a message. **Hard stop at your second context compaction**: land or park, whatever state you are in.

## Park (the header is the handover; a fresh session resumes from it alone)

```
state: open                      # parked only when BLOCKED names a token; closed only when nothing remains
NEXT: <the ONE next item, one line; `nothing outstanding` is an answer>
BLOCKED: NONE | QUEUE:<id> | HOLD:<id> | LANE:<lane>-<n>   # join with ` + `; prose here is unjudgeable
tranche: <sha this tranche was cut against>
last_landed: <sha> · <date>
session: <spawn date> · parked <date time>
```

Then, as your **last act**, leave the park marker and fire the tick — the marker is what ends this process:

```
powershell -NoProfile -Command "New-Item -ItemType File -Force '<MAIN TREE>\.claude\scratch\parked\<LANE>' | Out-Null; Start-ScheduledTask -TaskName AlgoTrader-Dispatch"
```

The tick stops any session whose lane carries a marker newer than the session, deletes the marker, and spawns the
next lane. Without the marker the tick only reaps sessions it spawned itself, and only after they idle (8 min with a
parked journal, 2 h otherwise); a session a human opened or typed into is never reaped. Do not wait for it, do not
message anyone, do not start a second tranche.
