---
name: checkpoint
description: Save the session's whole working state to durable notes before a /compact (or any break) - progress, findings, insights, what is in flight, what still needs evaluating, next tasks and objectives, and the rulings and workflows established - then hand back a ready-to-paste `/compact <focus>` line. Use when the user says checkpoint, save state, "compact but keep everything", or before compacting a long session.
disable-model-invocation: true
argument-hint: "(optional) what the next stretch of work is about"
---

# checkpoint

**A compaction summary is lossy and nobody audits it. A note on disk is not.** This skill
writes everything the next context needs into the project's notes *first*, so `/compact` can
only lose what is already saved. It does not compact by itself: `/compact` is a built-in the
model cannot run. It ends by giving the user the exact line to paste.

**Focus:** `$ARGUMENTS` (empty = the whole session).

## 1. Find the notes

In this order: the run-file the session already uses (`run_<topic>_<date>.md` in the project's
memory or notes dir), else the project's orchestrator/notes file, else create
`run_<topic>_<YYYY-MM-DD>.md` in the auto-memory dir and add **one link line** to `MEMORY.md`
(never content - MEMORY.md is a link index). Read the existing note before writing, so you
append and correct instead of duplicating.

## 2. Gather - from the session, not from memory of it

Re-read what is on hand: the user's messages (including the clauses inside long ones and
messages sent mid-turn), your recent tool results, the todo list, the run-file. Collect:

| Section | What goes in | Done-when it is complete |
|---|---|---|
| **State** | repo, branch, last commit + pushed?, versions, what is live/installed, running processes you started | a fresh session could verify each line with one command |
| **Done this session** | each delivered item with its evidence (commit, test count, measured number) | no item without evidence |
| **Findings & insights** | facts learned the hard way: API quirks, measured costs, traps, root causes, things that turned out wrong | each is one line, specific, with the number or error text |
| **In flight** | anything half-done: edited-not-tested, tested-not-committed, started processes, temp files/workspaces to clean | nothing the next context could trip over unknowingly |
| **To evaluate / unverified** | claims not yet verified (e.g. "UI not seen by the user"), open questions to the user, risks noticed | each says how to verify it |
| **Next** | requested-but-not-done first, then agreed follow-ups, then proposals awaiting a decision | each row has a done-when; proposals are marked as undecided |
| **Rulings & workflows** | decisions the user made (quote the choice), standing permissions and their limits (e.g. "commit+push approved per round, ask each round"), conventions established (paths, commands, test suites to run, backups to take) | the next context could follow them without asking again |

**Be concrete.** Paths, ids, commands, exact numbers. "Improved performance" is useless;
"forced sync 9.4 s -> 0.77 s (socket report_metadata)" is a finding.

**Secrets never go in notes.** Tokens, passwords and keys are referenced by where they live.

## 3. Write

Append a dated `## Checkpoint <YYYY-MM-DD HH:MM>` block with the sections above to the note
(correct earlier lines it supersedes rather than leaving contradictions). Keep the run-file
skimmable: one line per item.

Durable cross-session facts (a user preference, a standing ruling, a reusable reference) also
get their own memory file + a `MEMORY.md` link line, per the memory rules - not just a
run-file line.

## 4. Hand back

Reply with, and only with:

1. one line: where the checkpoint was written (clickable path) and how many items per section;
2. anything **in flight** the user should know before compacting (uncommitted work, a running
   process);
3. the line to paste, in a code block:

```
/compact Keep: <project> - <current objective>. State: <branch/commit/version>. In flight: <...>. Next: <top 3>. Rulings: <the ones that change behaviour>. Full checkpoint: <path to note>.
```

Keep that line under ~600 characters: it steers the summary, the note holds the detail. After
`/compact`, the first thing the next context does is read the note it names.
