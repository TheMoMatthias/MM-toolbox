---
name: agent-coordination
description: Protocol for work spread across more than one Claude session — how to handle a message from a peer session without loading their subject matter into your context, and how to lead an agent team so teammates never overwrite each other (disjoint file ownership, lead-owned shared files, frozen interfaces, serialized overlaps, lead integration). Use when a peer session or teammate sends you a message, when you need something from another session, when about to spawn teammates or an agent team, when acting as team lead or splitting work across agents, when invoking /agent-cluster or /algo-team, or when several sessions are running in parallel on one repository.
---

# Agent coordination

This was carried in the global `CLAUDE.md` and read into every session, including the large majority
that never run a second agent. It is unchanged — only relocated, so it costs nothing until the
condition that makes it apply is actually true. Load it at the moment a peer message lands, or before
spawning teammates.

## Inter-session comms - peer message handling is delegated, always

**Scope: session-to-session traffic only. A message from the OPERATOR is never delegated** - you answer the user yourself, every time. Everything below is about peer sessions.

**When several sessions run at once and messaging is enabled, an inbound message is cheap but ANSWERING it is not.** The notification is one line; reading the peer's files, running their probe and drafting a reply is thousands of tokens of somebody else's subject matter loaded into a context committed to different work. That is the pollution - not the message.

**So peer message handling is MANDATORY sub-agent work, in both directions.** *Inbound:* the parent notes that a message landed and dispatches it - it does not investigate, does not open the peer's files, does not compose the reply. *Outbound:* when you need something from a peer, the delegate composes it, sends it, and owns the reply that comes back. **Not "when it looks expensive" - always.** A rule carrying a broad judgment call gets rationalised away under momentum, which is exactly when the context is most worth protecting.

**The one exception, deliberately narrow: what you can already answer in a line or two from what is in front of you** - an acknowledgement, a sha you just landed, a yes/no about your own state, a "done, you are clear to rebase". No reading, no probing, no deciding. The moment you would have to LOOK something up, it is a delegate's job.

**TRAP - a sub-agent cannot intercept the inbound message.** `SendMessage` addresses agents by name and peers address THIS session's name, so it always lands here first. What the delegate owns is everything AFTER it lands. Do not design around interception; design around handoff.

**The handoff.** Spawn ONE **named** delegate per exchange and put in its prompt: the message verbatim; who sent it and what they are working on; the parts of YOUR state it needs (paths, decisions, constraints - it inherits none of your history); what it may settle alone; where to reply. Name it so follow-ups in the same thread go back to the SAME delegate via `SendMessage` instead of respawning a cold one. Use `subagent_type: "fork"` when the peer is asking about YOUR work and the answer genuinely lives in your context - a fork inherits everything and is priced accordingly.

**The delegate may, alone:** read anything, run read-only probes, write to scratch, follow up with the peer, send informational replies.
**It MUST escalate first:** any write outside scratch; any commit, push or index operation; any promise about this session's work, ownership or schedule; anything needing a ruling or the operator. *(Shared-tree index collisions are why the write bar sits this low - see the one-worktree-per-lane rule.)*

**What comes back is a digest, about 5 lines** - what was asked, what was answered, and anything that changes THIS session's plan. Longer only where the parent must act on the detail. Never the transcript, never the peer's reasoning, never the files it read.

**The test that it worked: after the exchange, can you still state your own next step without scrolling?** If the peer's subject matter is now in your working set, the handling was not delegated - it was narrated.

## When in agent-team mode — lead responsibilities

The experimental teammates feature is enabled. Each teammate is a separate Claude Code instance with its own context window; it loads the project `CLAUDE.md` + skills but **not** your conversation history — so brief each one fully in its spawn prompt. On native Windows teammates run in-process: view/switch with **Shift+Down** (no split panes).

**Prime directive: teammates must never overwrite each other's work.** Enforce it structurally, not by hope:

1. **Disjoint file ownership.** Assign each teammate a non-overlapping set of files/dirs up front. State the full ownership map before spawning.
2. **Lead owns cross-cutting / shared files.** Files multiple domains touch (shared base classes, connection/DB layers, path utils, central registries, IPC/schema contracts) are edited by the **lead only** — teammates request changes via message; the lead applies them. Two teammates never edit one file concurrently.
3. **Lock interfaces before parallelizing.** When teammates depend on a shared contract (a class API, a DB schema, an IPC format), the lead writes/freezes the signature first; teammates implement against the fixed contract. This is what lets parallel work "account for each other's changes" without collision.
4. **Serialize unavoidable overlaps.** If two teammates must touch one file, one goes first and signals done (SendMessage) before the other starts.
5. **Coordinate via the shared task list.** One task per ownership unit; dependencies explicit; teammates self-claim. Use SendMessage for handoffs, not status spam.
6. **Lead integrates + verifies.** After teammates report, the lead runs the cross-cutting build/test/typecheck, resolves merge points, and delivers the single final report.

**Launcher:** **`/agent-cluster`** analyzes the repo structure and proposes an ownership map before spawning. A project's `CLAUDE.md` may pin a more specific launcher with pre-mapped ownership.
