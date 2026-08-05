---
name: wrap-up
description: Produce an evidence-backed account of what a working session actually achieved - the requests as they were made, what was delivered, what was NOT delivered and why, issues hit along the way, and the resulting state on disk. Gathers evidence from the session transcript, git, task state and test output instead of writing from recollection. Project-agnostic. Use when the user asks what was done or achieved, wants a session summary, recap, report or status, says "wrap up" or "where did we land", or before compacting or closing out a block of work.
argument-hint: [optional scope, e.g. "just the migration work" or "since this morning"]
---

# Wrap-Up

A recap written from recollection reads identically whether it is accurate or not. **Gather
evidence first**; every claim in the report must cite something a reader could check.

This skill **reports**. It does not fix, finish or start anything. Optional scope: $ARGUMENTS.

## Quick start

```powershell
powershell -NoProfile -File "$HOME\.claude\skills\wrap-up\scripts\session-requests.ps1"
```

That recovers the user's own turns from the session transcript. Then gather the rest of the
evidence (Step 1), classify every request (Step 2), and write the six sections (Step 3).

## Step 1 - Evidence, before writing a word

1. **The requests, as they were actually made** - run the script above. Do not reconstruct these
   from memory: after a compaction the original wording is the first thing lost from context,
   which is the exact failure this skill exists to prevent.
   🔴 If it recovers zero turns or cannot find the transcript, **say so in the report** and label
   the request list as reconstructed-from-context. Never silently substitute recollection.
2. **What actually landed** - `git log --oneline` for this session's commits, `git status --short`
   for uncommitted work, `git diff --stat` for its shape. Note whether commits are pushed.
3. **Task state** - the todo list, plus any run-file or plan the session worked against.
4. **Verification actually performed** - the test / lint / build summary lines captured this
   session. If none were run, that is a finding; record it rather than omitting it.
5. **External effects** - anything that left this machine: a deploy, a push, a message sent, a
   service restarted, a migration applied.

## Step 2 - The ledger

Every request from Step 1 gets **exactly one** status. There is no "unclear" bucket - if you
cannot tell, it is `not started`, reason "status could not be established".

| Status | Means |
|---|---|
| `delivered` | Done and verified. Cite the evidence. |
| `partial` | Some of it shipped. Name precisely what is missing. |
| `blocked` | Could not proceed. Name the blocker and what would unblock it. |
| `descoped` | Dropped on purpose. Name who decided, and when. |
| `failed` | Attempted, did not work. Say what was learned. |
| `not started` | Never begun. Say why - deprioritised, forgotten, superseded. |

**Nothing is `delivered` without a citation** - a commit sha, a `file:line`, or a quoted test
summary line. "Looks correct", "traced manually" and "should work" are not citations; they read
identically whether the work is right or not. Downgrade to `partial` instead.

```
[2] "update all other audit skills to be more generic"
    partial - audit + audit-loop-codebase rewritten (ea4c77b); audit-loop left as the user's
    own version, unreviewed. Single-file kept against the <100-line rule, at user's request.
```

## Step 3 - The report

All six sections, always, in this order. An empty section says "none"; it is never dropped.

- **What you asked for** - the requests in the user's own words, numbered, in order.
- **What was delivered** - per request: what shipped, and the citation. Grouped by request, not
  by file.
- **What was NOT delivered** - every `partial` / `blocked` / `descoped` / `failed` / `not started`,
  each with its reason. **This is the section the report exists for.**
- **Issues encountered** - problems hit and how each was resolved, or that it was not. Include
  what was worked around rather than fixed, and anything found that was not part of the ask.
- **Open items** - what is left, each with enough context to pick up cold, and the trigger that
  resumes it. Flag anything waiting on the user.
- **State on disk** - branch; commits and whether they are pushed; uncommitted or untracked
  files; anything deployed or restarted outside this repo; what a fresh session would find.

## Rules

- **No new work.** Do not fix a thing you notice while writing. Report it under *Issues* and stop.
- **Do not flatter the delivered pile.** Completion bias makes the done list write itself and the
  not-done list disappear. Give *What was NOT delivered* the same effort as *What was delivered*.
- **Do not write files unless asked.** Print the report. If it should persist, follow the
  project's own convention for notes, and never leave a stray `.md` in the repo.
- **Contradictions are findings.** Where the evidence disagrees with what was claimed during the
  session, report the evidence and name the discrepancy.
