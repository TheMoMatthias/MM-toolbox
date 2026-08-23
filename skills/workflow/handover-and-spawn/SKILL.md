---
name: handover-and-spawn
description: Write a handover document for the current work and immediately spawn a fresh Claude Code session that picks it up, optionally briefed with specific objectives or instructions. Use when the user wants to continue in a new session, hand the next phase or step to a fresh context, pass the baton, or start a session that carries on from here.
argument-hint: "(optional) what the new session should work on - e.g. 'phase 3: the ingest spine'"
---

# handover-and-spawn

One move: **capture the state, then open a session that acts on it.** Composes the
`handoff` skill with `spawn-claude-session`, so neither is duplicated here.

Reach for it when this session has finished a phase, is running long, or is about to start
work that deserves its own clean context.

## Steps

1. **Settle the scope first.** `$ARGUMENTS` is what the new session is *for*. If it is
   empty and the next step is not obvious from the conversation, ask once — a handover
   written without knowing its purpose is a transcript, not a brief.

2. **Write the handover** with the `handoff` skill, tailored to that purpose. On top of
   what `handoff` produces, the new session cannot start without:

   - **The objective** — one sentence, and the DONE-WHEN that ends it.
   - **What is already true** — what is built, tested, committed, and what is not.
   - **Everything still open** — reconciled against this session's open list, not against
     memory of it. Every unfinished item either lands in the brief or is explicitly closed
     in it. 🔴 A thing never done and never written down disappears at the boundary: the
     new session cannot miss what it never heard of.
   - **Decisions already made, and why** — so they are not silently relitigated. Include
     anything ruled *out*, **and how firmly** — `measured` · `documented` · `inferred`,
     the labels the rest of the toolbox uses. Rejected on a tested result is settled;
     rejected on an `inferred` reading is reopenable and must say so. A brief that does not
     distinguish them promotes a guess into a constraint the new session cannot question —
     and it will not think to, because it was not there when you guessed.
   - **Constraints and pre-authorized defaults** — what it may decide alone, and what it
     must stop and ask about.
   - **Where the work lives** — files, branch, run-file, tests to run.
   - Anything the user added as special instructions in `$ARGUMENTS`.

   Reference existing artifacts (plans, PRDs, ADRs, run-files, commits) **by path**
   rather than restating them.

3. **Check the target directory** — same repo, or a worktree if the new session will
   touch the same files as this one. Two sessions in one working tree share a git index.

4. **Spawn it** with the `spawn-claude-session` skill: `-HandoffFile <the handover>`,
   `-Prompt` set to the concrete first action, `-Directory` the target, `-Name` after the
   phase (e.g. `phase-3-ingest`). Read that skill before running it — the env-scrub, the
   duplicate-lane refusal and the Windows Terminal requirement all live there.

   **Always pass `-Prompt`.** A session spawned with a handover but no first task reads
   its brief and then sits idle.

5. **Report back**: the handover path, the session name and directory, the
   `claude --resume <id>` command, and the first task it was given.

## Judgment

- **A handover is not a summary.** Summaries describe what happened; a handover says what
  to do next and what not to touch. Write it for someone who was not here.
- **Say what is uncertain.** A brief that reads as more settled than the work actually is
  produces a session that builds confidently on sand.
- **Do not hand over a decision the user should make.** If something is genuinely open,
  either settle it now (see the `realign` skill) or state it in the handover as an
  explicit open question with a pre-authorized default — never leave it implicit.
- **This session keeps going or stops, deliberately.** Say which. Two live sessions on the
  same work is the failure this is meant to avoid, not cause.
- **Split the work, not the context.** If the next phase has several independent lanes,
  spawn one session per lane with its own handover and its own worktree — not one session
  told to do everything.
