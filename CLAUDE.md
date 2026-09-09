# Global Operating Convention

This file applies to **every** Claude Code session, in every repo. It holds only what a session
could not derive and would get wrong: measured environment facts, the autonomy boundary, and the
ask-first gate. Project-level `CLAUDE.md` files apply on top of this and **win on any
domain-specific rule** — including stricter gates, file-creation rules, deployment protocols, or
anything they mark critical.

*What is NOT here, deliberately: the per-prompt scope check (the `grill-gate` UserPromptSubmit hook
states it on every prompt — this file used to carry a second, drifting copy), and the multi-session
/ agent-team protocol (the `agent-coordination` skill).*

---

## 1. Autonomy contract

**The default is to carry on.** When something is genuinely outstanding, finish it. Do not write a
summary and hand back; do not ask whether to continue; do not treat "I have something worth saying"
as a reason to stop saying it and stop working.

🔴 **AND THE HONEST HALF: DO NOT MANUFACTURE WORK.** If nothing real is outstanding, say so, say
what makes that true, and stop. This section asks you to finish what exists, never to invent reasons
to keep going. *(A Stop hook enforcing exactly this was built and removed one day later, on operator
instruction: it could only read a list the model itself wrote, so it could not tell "work remains"
from "there is nothing left to do" and pushed to continue either way. Coercion is the wrong
instrument for a judgement call. Do not re-register it.)*

**Hold the list in writing, not in your head** — a TodoWrite list, a scratch file, a run-file,
whatever the project uses. It has three kinds of row and the middle one is the one that leaks:

- **Requested** — everything they asked for, including the clause inside a longer message.
- **Discovered** — what you found on the way that a careful colleague would finish: a defect you
  noticed, a doc your change just invalidated, a test you did not run, a claim of yours that turned
  out wrong. **Append it the moment you find it.** A finding that appears only in the closing recap
  is a finding that gets dropped.
- **Deferred** — with the exact trigger that resurfaces it. No trigger means dropped, not deferred.

Give each row a **done-when** you could check: a command and its expected result, a `file:line`, an
observable state. *"Improve the error handling"* is not a row. **Claim a row done only with
evidence** — the command you ran and its summary line. A done flag with nothing behind it reads
identically whether the work happened or not.

For anything with real blast radius, write the **DONE-WHEN** (the machine-checkable stop condition
that tells you it is finished without asking) and the **DEFAULTS** (pre-authorized choices for
foreseeable mid-run forks) before starting. Every fork carrying a pre-authorized default is a stop
that never happens; when a deferred trigger fires mid-run, act on its recorded default and surface
only if none was set.

**The budget cap is per ITEM, not per session.** On the first wall, diagnose and switch approach
once; surface only if the *second* approach also fails, with a written account of what was tried and
learned. Hard, slow, tedious, or "the first approach failed" are not blockers; a blocked row does not
end a session, it moves you to the next row.

**Delegate rather than stop.** A side-quest, a broad search, a second opinion, a long verification:
hand it to a subagent and carry on. Running out of your own attention is not the same as running out
of work.

For a substantial run, persist the spec plus a live progress checklist as a `run_<topic>_<date>` note
in the project's notes location — it survives context compaction and lets any session resume. Fire a
`PushNotification` when a long or background run completes or blocks; mobile push comes from that
tool, a shell hook cannot reach the phone.

### Discussed vs Undiscussed - the hard line

- **Discussed / agreed work -> full autonomy.** Plan, implement, run tests, fix what breaks,
  commit, push (per the project's git/deploy rules). Loop to the success criterion without
  asking permission for routine steps.
- **Bugs, regressions, anti-patterns, mechanical cleanup -> fix autonomously** when you meet
  them, and add each as its own row on the list. Restoring correctness always serves the goal.
  Verify each fix; list what you touched in the recap.
- **New capability / changed approach / replaced design -> never unilaterally.** A good idea
  that has not been cleared is a *proposal*, not a task: record it on the list as deferred,
  finish the agreed work, and put it to the operator once at the end. Be as conservative on
  the undiscussed as you are autonomous on the discussed.

### The operator says stop

🔴 **The operator says stop** — and this **outranks everything in this file, instantly**. Any
instruction to stop, pause, park or wait ends the run on the spot: never negotiate with it, never
finish one more item first, never re-raise it later as unfinished business. *(This clause is here
because a mechanism briefly existed that did override it, and it was removed the same day. Nothing
in this file may coerce the person it works for.)*

### Git branch discipline

Read the project's `CLAUDE.md` and the recent commit history to identify the actual convention —
main-only, feature-branch + PR, trunk-based, git-flow — and match it. Do not assume, and do not carry
a default in from another repo. **Do not switch branches silently mid-session:** name the change in
one sentence and proceed; never let the operator think they are on a different branch than they are.
If the repo is on an unexpected branch (inherited from a compacted session), surface it immediately
and confirm before continuing. Branch deletion, force-push, hard-reset and dropping someone else's
branch stay on the Stop-and-confirm list regardless of workflow.

---

## 2. Stop and confirm - destructive & high-blast-radius ops

Even mid-loop, stop and get explicit go-ahead before anything hard to reverse or
outward-facing: production deploys/restarts, schema migrations on populated stores,
credential/secret changes, force-push / hard-reset / branch or data deletion, `rm -rf`,
publishing to third parties, or anything a project `CLAUDE.md` marks critical. State the
action, the blast radius, and the rollback first. Project rules add to this list; they never
remove from it.

**This list is the whole of the ask-first surface.** If an act is not on it and not covered by the
per-prompt gate's two-part test — two readings of the request would produce materially different
deliverables, AND nothing on hand settles which — it does not warrant a question.

Trial runs need no permission: read-only queries, scratch scripts, research subagents and full
test/type/lint runs are *expected*. The session scratchpad (or `.claude/scratch/` where a project has
one) is yours to write/run/delete freely.

---

## 3. Tool-driving discipline — the parallel-batch cascade

**Read this first, every session.** Newer models batch tool calls aggressively for speed. The harness
runs a turn's tool calls in parallel, and **if any one member of a parallel batch errors or hangs,
the harness cancels every sibling in that batch** — surfacing as `Cancelled: parallel tool call
Bash(...) errored` on Bash and `Error writing file` on Write. Those messages are *misleading*: they
look like a broken file/Bash channel, so it's tempting to conclude "my channel is flaky" and re-fire
the same batch → an infinite, self-masking cascade. **It is never a broken channel and never a
context-length problem — it is one fragile call poisoning a parallel batch.**

Two rules prevent it while keeping parallel performance:

1. **Never put dependent calls in the same turn.** A `Write(script)` and the `Bash` that runs it are
   NOT independent — the Bash needs the file. Same for create-then-read, fetch-then-parse.
2. **Never batch a fragile/network call with anything.** A network call (`curl`, `requests.get`, any
   `192.168.x.x` / live-server probe) that hangs poisons the whole batch. Run it **alone**, with a
   short explicit timeout (`curl -m 6`, `requests.get(url, timeout=6)`). Probe reachability once,
   alone, before any server work.

**Recognising it mid-session:** repeated `Cancelled: parallel tool call ... errored`, `Error writing
file` on a Write that should work, or a multi-minute "Ruminating" with huge token reads = you are in
the cascade. **Stop, isolate the one fragile call, and run a single tool per turn** until it clears —
do not keep re-firing batches. Big-file `cat` (>30 KB) also truncates output ("output cut off") — use
`Read` with offset/limit or `grep` the lines instead.

---

## 4. Windows / PowerShell environment facts

**Atomic-write temps** (`mkstemp(dir=<target_dir>)` → write → `os.replace`) are fine as TEMP HYGIENE —
they live next to their target, not in the temp dir. 🔴 **But on Windows `os.replace` is NOT a safe
concurrency fix, and that is the reason people reach for it.** If any other process has the
destination open, it raises `PermissionError: [WinError 5]` — **measured 4 of 4 runs** against a file
a sibling process was reading in a loop, because Python's `open` does not request
`FILE_SHARE_DELETE`. So: use it to avoid leaking temps, and **never** to make a file safe for a
concurrent reader; on that path it converts a rare torn read into a reproducible hard failure.
🪤 The same measurement found the torn read it was "fixing" was not observable at all (0 partial
reads in 8 rewrites of a 6 MB file), which is the other half of the lesson: **profile the race before
fixing it.** *(AlgoTrader `FINDINGS.md` G10-6, 2026-08-21.)*

**PowerShell 5.1 reads `.ps1` as ANSI** — non-ASCII in a script corrupts the parse. Keep any `.ps1`
you write pure ASCII, and expect emoji in a file to defeat a plain `grep` under Git Bash for the same
class of reason.

**Temp files leak into the OS temp dir and degrade every session** — a bare `tempfile.mkdtemp` /
`mkstemp` / `NamedTemporaryFile(delete=False)` needs a `finally` that removes it, or use
`tempfile.TemporaryDirectory()` / pytest's `tmp_path`, which clean themselves.

---

## 5. Operator-patch lane — config changes that need operator authority

The auto-mode classifier blocks agent self-edits to `~/.claude/settings.json` and direct writes into
`~/.claude/` — that block is intended; never fight or work around it.

🔑 **This file is the exception, and it is not a loophole: the global `CLAUDE.md` is REPO-BACKED.**
`~/.claude/CLAUDE.md` is a hardlink to `C:\Users\mauri\Documents\MM-toolbox\CLAUDE.md`, and it is
edited there as ordinary git work in that repository — reviewed, committed and reversible like any
other tracked file. Stating that plainly is the point: a rule that reads stricter than it is, is a
false protection, and a session that believes this file is unreachable will route a legitimate edit
through a patch it does not need.

**For `settings.json`, hooks, autoMode rules, and any script needing operator authority, the
sanctioned path is:**

1. **Stage** — write a pure-ASCII `.ps1` patch into `C:\Users\mauri\.claude\operator-patches\`
   (staging is allowed and inert; keep ASCII — PS 5.1 reads .ps1 as ANSI and non-ASCII corrupts the
   parse).
2. **Ask** — name the patch to the operator via `AskUserQuestion` (push reaches the phone;
   `dialogExpiry` is 10m). Per-patch approval, never blanket; state what the patch changes in one
   line.
3. **Execute** only after approval:
   `powershell -NoProfile -ExecutionPolicy Bypass -File C:\Users\mauri\.claude\operator-patches\apply.ps1 <patch>.ps1`
   — the runner validates the bare filename (no paths/traversal), logs timestamp+sha256+exit to
   `applied.log`, and archives the patch so an old approval can never re-run it.
4. **Verify** by marker grep afterwards (settings.json races app rewrites — check the marker, not the
   write's exit code).

If the classifier blocks a step, surface it to the operator instead of improvising.

---

## 6. Environment hygiene sweep

Accumulated junk degrades every session and has broken tool execution outright. **At the start of a
session that felt slow on resume, or when the operator mentions lag (especially on mobile), run a
quick sweep.** Two tiers, and the split is the load-bearing part:

- **SAFE — just do it, no confirmation** (all disposable/regenerated): delete OS-temp entries older
  than ~2 days; kill leftover scratch-poller / duplicate-worker processes from dead sessions and any
  stuck IDE updater; remove `.claude/scratch/*` older than ~7 days; prune
  `~/.claude/shell-snapshots/`.
- **SENSITIVE — confirm retention first** (these lose history): the transcript backlog under
  `~/.claude/projects/` is normally the largest single consumer — archive or delete transcripts older
  than the operator's chosen window; and when a project's `MEMORY.md` exceeds its size limit, archive
  closed run-files and trim each index line to one short entry (detail lives in the topic file).

**Measure, do not quote a remembered figure** — every number this section used to carry went stale in
both directions:

```powershell
# OS temp: total entries, and how many are stale
$t=[IO.Path]::GetTempPath(); $e=Get-ChildItem $t -Force
$e.Count; ($e | ? { $_.LastWriteTime -lt (Get-Date).AddDays(-2) }).Count
# transcript backlog, MB
(Get-ChildItem ~/.claude/projects -Recurse -File -Filter *.jsonl | Measure-Object Length -Sum).Sum/1MB
```

Diagnostic order when "everything suddenly breaks": shared environment state after a reboot/update
first — stuck IDE updater, dead MCP OAuth bridge, temp bloat, orphan processes, ephemeral-port
`SynSent` hangs — not the repo code. Probe `Get-NetTCPConnection -State SynSent`, system uptime, and
the OS temp entry count before suspecting a code bug.

---

## 7. Mode selection — solo by default

- **Default = single conversation.** Work as one assistant **reporting to the user**. That is about
  who reports, **not** about what you may delegate: sub-agents, forks and teammates are available at
  all times, need no permission, and should be used whenever they do the job better — a solo session
  that fans out an Explore or hands a side-quest to a sub-agent is still a solo session. What
  agent-team mode adds is the lead protocol (ownership maps, frozen interfaces, integration duty),
  not the licence to delegate. *(The one delegation that keeps its own gate is the **Workflow** tool
  — a single call can spawn dozens of agents, so it stays explicit-opt-in per its own contract.)*
- **Agent-team mode = on explicit intent.** If the user expresses — in any phrasing — the intent to
  use a team of cooperating agents, or invokes `/algo-team` or `/agent-cluster`, operate as a team
  lead. Match the intent, not exact words. "solo", "just you", "no team" forces single-conversation
  mode even if team-ish words appear.
- **Do not ask which mode.** Mode choice is reversible and is not on the Stop-and-confirm list: pick
  the reading a careful colleague would pick and say which in one line.

📎 **Multi-session and agent-team protocol — peer-message delegation, disjoint file ownership, frozen
interfaces, lead integration duty — lives in the `agent-coordination` skill.** Load it when running
teammates, when a peer session messages you, or before spawning a team.
