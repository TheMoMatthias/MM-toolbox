# Global Operating Convention

Applies to every session and repo. Project `CLAUDE.md` files win on domain-specific rules (stricter gates, file rules, deploy protocols, anything marked critical).

## Tool discipline
A parallel batch is cancelled when any member errors or hangs ("Cancelled: parallel tool call…", "Error writing file"). That is never a broken channel, so don't re-fire the batch. Isolate the failing call.
- Dependent calls (write-then-run, create-then-read) go in separate turns.
- Network/live-server calls run alone with a short timeout (`curl -m 6`).
- Prefer Read/Grep/Glob over probe scripts. Use `Read` with offset/limit for files over 30 KB.
- No `cd "path with spaces" && …`; no multiline `python -c` with embedded quotes. Use a scratch file.

## Temp hygiene
- Don't leak temps into the system temp dir. Use `TemporaryDirectory()` / pytest `tmp_path`, or remove in `finally`.
- Atomic write (`mkstemp(dir=target)` + `os.replace`) is fine for hygiene. On Windows it is **not** a concurrency fix: it raises WinError 5 when a reader holds the file. Profile a race before fixing it.
- Restore any env var/global a fixture mutates. Pytest suites get a session `conftest.py` guard that redirects `tempfile.tempdir` and sweeps known prefixes.

## Config changes to ~/.claude
If the classifier blocks a self-edit to `~/.claude` (settings, hooks, this file), don't work around it. Stage a pure-ASCII `.ps1` patch in `~/.claude/operator-patches/`, name it to the operator via `AskUserQuestion` (approval per patch), run it after approval, and verify by grepping for a marker.

## Model routing (cost/quality frontier, Oct 2026)
Use only the settings on the frontier: **Haiku 5.5 max** (execution, search, mechanical edits) → **Sonnet 5.5 high** (routine engineering) → **Opus 5.5 medium** (default) → **Opus 5.5 high** (quant, security, systems, research) → **Opus 5.5 xhigh** (only when the user asks, or for genuinely hardest problems). Avoid Sonnet low/medium/xhigh/max and Opus low: a cheaper setting on the frontier beats each of them. When delegating, pick the cheapest tier that can do the job.

## How I work
**Align before, autonomous during.** Question depth scales with risk and ambiguity, not file count.
- If the request gives the goal, constraints and success criterion, act. Look up facts in code/docs/history yourself; ask only about decisions that would materially change the outcome.
- **Grill gate** (the `grill-gate.ps1` hook prompts this every turn): for anything not obviously trivial, state your scope read (light-touch / non-trivial / major / top-tier) and effort estimate, then offer one selectable choice: proceed / light-touch questions / full grill. Skip it when the user already said to implement, or is answering a gate question.
- Batch real blocking questions in `AskUserQuestion` (selectable options, up to 4 per call), and give your own recommendation. Use `grill-with-docs` for broad, high-blast-radius, or explicitly requested stress-tests, and stop once aligned. Include a challenge question when a concrete failure mode exists.
- For non-trivial work, write a short spec (GOAL, CONTRACT, PLAN, TESTS, DONE-WHEN, DEFAULTS, DEFERRED, ROLLBACK, OUT OF SCOPE) and get sign-off. For long runs, persist it as `run_<topic>_<date>` in the project's notes location and update progress there.
- **Discussed work → full autonomy:** implement, test, fix, commit per repo rules. **Bugs/regressions/cleanup → fix and list them.** **New capability or changed design → propose, don't do.**
- Act, then report. Loop to DONE-WHEN with one-line milestone pings. Scratch work, read-only probes and test runs need no permission. On the first wall, switch approach once; re-engage after ~5 attempts / ~30 min.
- Run relevant tests/lint/typecheck at the start and end of substantive tasks, scoped to the subsystem.
- Don't silently reverse a prior verified decision. State what changed and why. Keep the project goal and `CONTEXT.md` glossary in view, and add terms only when genuinely new.
- Long runs: background agents by default; `PushNotification` on done or blocked.

## Compact instructions
On every compaction, manual or automatic, preserve: the current working state; all decisions (with rationale); findings; deviations from plan; plans; done tasks; open tasks; and active workflow instructions (user rules, agreed DEFAULTS/DONE-WHEN, run-file paths). Keep exact file paths, IDs, commands and the user's verbatim instructions. Drop raw tool output.

## Stop and confirm
Production deploys/restarts, migrations on populated stores, credential changes, force-push / hard-reset / branch or data deletion, `rm -rf`, publishing externally, anything a project marks critical. State the action, blast radius and rollback first.

## Git
Match the repo's actual workflow (read its CLAUDE.md and log). Default for team repos is a feature branch + PR, with the spec as the PR body. Never switch branches silently. Surface an unexpected branch immediately.

## Verify loop (opt-in)
The `verify-loop.ps1` Stop hook is inert unless `.claude/verify-loop.active` exists (JSON: `verify_command`, `attempt`, `max_attempts:5`, `deadline`, `status`). Arm it only for agreed autonomous runs. On green, stage only the files the loop touched and ask before committing critical-tier files. Delete the sentinel when done or capped.

## Environment hygiene
When sessions feel slow: delete OS-temp entries older than 2 days, kill orphan pollers/stuck updaters, prune `.claude/scratch` (>7d) and `shell-snapshots` (keep ~20). Ask before deleting transcripts or trimming memory. When "everything breaks", check shared environment state (temp count, orphans, `SynSent` hangs, uptime) before the code.

## Agents
- Single conversation by default, but delegate freely to subagents and forks. Workflow tool only on explicit opt-in.
- Team mode on any expressed intent ("team", "split across agents", `/agent-cluster`). "solo" / "no team" overrides it. As lead: disjoint file ownership, lead owns shared files, freeze interfaces before fanning out, lead integrates and verifies.
- Peer-session messages: hand each exchange to one named delegate (message verbatim + the state it needs). The delegate escalates before writes, commits or promises, and returns a ~5-line digest. Exception: one-line answers you already know. Operator messages are always answered directly.
