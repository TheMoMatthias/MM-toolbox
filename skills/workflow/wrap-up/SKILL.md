---
name: wrap-up
description: Produce an evidence-backed account of where a session actually stands - what was asked, what was delivered, what was NOT and why, what is blocked on a decision from the user, and what is still open. Reconstructs the requests from the session transcript (including messages typed mid-turn and unfinished business inherited from an earlier compacted context) rather than from recollection, then reconciles them against git, task state and test output. Project-agnostic. Use when the user asks what was done or achieved, wants a session summary, recap, report or status, asks where things stand or what is still open, says "wrap up", or before compacting or closing out a block of work.
argument-hint: [optional scope, e.g. "just the migration work" or "since this morning"]
---

# Wrap-Up

A recap written from recollection reads identically whether it is accurate or not. **Gather
evidence first**; every claim must cite something a reader could check.

The report answers one question: **what is still open, and what needs the user.** Optional
scope: $ARGUMENTS. Status vocabulary and a worked example: [REFERENCE.md](REFERENCE.md).

## Quick start

```powershell
powershell -NoProfile -File "$HOME\.claude\skills\wrap-up\scripts\session-requests.ps1"
```

## Step 1 - Evidence, before writing a word

1. **The requests** - run the script. It reads the transcript, so it survives compaction, and
   it separates three things you must treat differently:
   - `REQUESTS` - what the user actually said, including **messages typed mid-turn** (marked
     `queued mid-turn`; these reach the log by a different route and are easy to lose). Each is
     truncated to 600 chars; pass `-Full` when one needs reading whole.
   - `CARRY-OVER` - a compaction summary of an earlier context. **Read it.** Work already
     unfinished before a compaction is recorded there and nowhere else; fold its pending items
     into the ledger, marked as inherited. Only the last block shows - each supersedes the ones
     before it, and a long session can hold dozens.
   - `SUPPRESSED` - counts of skill payloads, harness traffic (background-task notifications,
     subagent reports, other sessions' messages) and slash-command echoes, so nothing is
     dropped silently.

   🔴 If it recovers zero requests, **say so in the report** and label the list
   reconstructed-from-context. Never silently substitute recollection.
   🪤 A very long session yields a lot of requests - measured, 113 across 26 compactions. If the
   full ledger would be unreadable, agree a scope with the user; never quietly drop rows.

2. **Derived items - the ones nobody asked for.** Requests are only half the ledger. Re-read
   your own turns for work that entered the session another way, because this is the half that
   disappears: questions you asked that were never answered · options you offered that were
   never chosen · problems you found and parked · decisions explicitly deferred · things you
   said you "could" do. Each becomes a ledger row, attributed to how it arose.

3. **What landed** - per repository; a session can touch more than one. `git log` for commits
   made *during this session*, `git status --short`, `git diff --stat`, and whether commits are
   pushed. 🪤 **Do not attribute a dirty working tree to this session.** Pre-existing edits and
   a parallel session's work show up identically here. Check whether a file was actually touched
   by this session before claiming it; if you cannot tell, say so.

4. **Verification actually performed** - the test / lint / build summary lines captured this
   session. If none ran, that is a finding; record it rather than omitting it.

5. **External effects** - anything that left this machine: a push, a deploy, a message sent, a
   service restarted, a migration applied.

## Step 2 - The ledger

Every request from Step 1 and every derived item from Step 2 gets **exactly one** status:
`delivered` · `partial` · `blocked` · `needs-decision` · `descoped` · `failed` · `not started`.
There is no "unclear" bucket - if you cannot tell, it is `not started`, reason "status could not
be established". Definitions: [REFERENCE.md](REFERENCE.md).

**Nothing is `delivered` without a citation** - a commit sha, a `file:line`, or a quoted test
summary line. "Looks correct", "traced manually" and "should work" are not citations; they read
identically whether the work is right or not. Downgrade to `partial` instead.

## Step 3 - The report

All seven sections, always, in this order. An empty section says "none"; it is never dropped.

1. **What you asked for** - the requests in the user's own words, numbered, in order. Mark
   inherited items from the carry-over block, and note anything raised mid-turn.
2. **Delivered** - per item: what shipped and the citation. Grouped by request, not by file.
3. **Not delivered** - every `partial` / `blocked` / `descoped` / `failed` / `not started`, with
   its reason. **This is the section the report exists for.**
4. **Needs your decision** - every `needs-decision`: the question, why it is blocking, the
   options, and your recommendation. Nothing here should be a surprise to the reader.
5. **Open items** - not blocked on the user. Enough context to pick up cold, plus the trigger
   that resumes each.
6. **Issues encountered** - problems hit and whether each was resolved. Include what was worked
   around rather than fixed, and anything found that was not part of the ask.
7. **State on disk** - per repo: branch; commits and whether pushed; uncommitted or untracked
   files, and whether they are yours; anything changed outside this repo.

## Rules

- **No new work.** Do not fix a thing you notice while writing. Report it and stop.
- **Do not flatter the delivered pile.** Completion bias makes the done list write itself and
  the not-done list disappear. Give sections 3 and 4 the same effort as section 2.
- **Do not write files unless asked.** Print the report. If it should persist, follow the
  project's own convention for notes, and never leave a stray `.md` in the repo.
- **Contradictions are findings.** Where evidence disagrees with what was claimed during the
  session, report the evidence and name the discrepancy.
