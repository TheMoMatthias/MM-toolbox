# MM-toolbox

A portable, cross-machine source-of-truth for a Claude Code workflow: grill-spec-execute discipline, batched alignment, autonomy contracts, parallel-batch-cascade discipline, and a curated library of skills + agents + hooks.

This repo is the **upstream** of `~/.claude/` on every machine I work from. Sit at a new machine, run `install.ps1`, and the full workflow appears — `CLAUDE.md`, hooks, skills, agents, keybindings — all kept in sync via git.

## What's inside

```
mm-toolbox/
├── CLAUDE.md           # global operating convention (loaded on every session, every repo)
├── keybindings.json
├── hooks/
│   ├── grill-gate.ps1   # UserPromptSubmit hook — fires every prompt, content-blind reminder of the mandatory grill gate
│   └── verify-loop.ps1  # Stop hook — opt-in self-healing verify loop (see hooks/README.md)
├── SKILLS-UPSTREAM.md  # provenance: which skills come from mattpocock/skills, at which commit,
│                       # what was renamed, and which divergences a sync must not undo
├── skills/             # 51 skills. Every one carries agents/openai.yaml for Codex as well.
│   ├── workflow/       # grill-with-docs, grill-me, grilling, domain-modeling, handoff, claude-handoff,
│   │                   # spawn-claude-session, handover-and-spawn, realign, reevaluate, wrap-up,
│   │                   # teach, ask-matt, loop-me, grill-with-a-loop, to-questionnaire, wait-what,
│   │                   # writing-great-skills
│   ├── development/    # implement, tdd, write-a-skill, to-issues, to-prd, to-execution-plan,
│   │                   # prototype, research, resolving-merge-conflicts, triage, wayfinder,
│   │                   # wizard, setup-engineering-skills, setup-pre-commit
│   ├── diagnosis/      # diagnose, audit, audit-loop, audit-loop-codebase, diagnosing-bugs,
│   │                   # code-review, server-health
│   ├── architecture/   # improve-codebase-architecture, codebase-design, setup-ts-deep-modules
│   ├── writing/        # writing-for-agents, writing-beats, writing-fragments, writing-shape
│   ├── misc/           # git-guardrails-claude-code, migrate-to-shoehorn, scaffold-exercises
│   └── orchestration/  # agent-cluster, algo-team
├── agents/
│   ├── core/           # universal: code-reviewer, function-tester, systems-architect, research-engineer, data-quality-engineer, ml-engineer
│   ├── backend/        # backend-platform-architect, database-architect
│   ├── infra/          # devops-infra-engineer, observability-engineer
│   ├── security/       # security-auditor
│   ├── frontend/       # ui-design-architect
│   └── quant/          # quant-trading-architect, quant-researcher, data-quality-scientist, ml-systems-architect
├── tools/
│   └── session-restore/ # every conversation across every repo: relaunch any of them any
│                        # time, or bring back the ticked ones at logon, correctly named
│                        # (see tools/session-restore/README.md)
├── Install.bat         # double-click to install (or re-install after a git pull)
├── Uninstall.bat       # double-click to remove
├── install.ps1         # symlink ~/.claude/* into this repo, register the tasks
└── uninstall.ps1       # remove symlinks, optionally restore originals
```

## Resuming yesterday's work

`install.ps1` also sets up **session-restore**: two scheduled tasks, two desktop
buttons, and three shell functions.

| command | does |
|---|---|
| `ccs` | **the control panel** — every conversation on the machine; tick what reopens at logon, `L` to open any of them now |
| `ccs -List` | print the current selection, with what is live |
| `ccs -Launch RC-WORKFLOW` | open one now, ticked or not — matches title, id, worktree or project |
| `ccr` | restore the selected conversations, one tab each, Remote Control attached under each one's real name |
| `ccr -DryRun` | show what *would* come back |
| `cc` | start a correctly-**named** new session in the current directory |
| `cc "my-name" --model opus` | …with a name you choose, plus any `claude` flags (the name comes first) |

**What exists and what reopens are separate.** A scan-only task runs hourly and at
logon, discovering every conversation you have — it launches nothing. A registry
records your ticks at **two levels**: a project has a master tick, and each
conversation under it has its own, so a project can reopen **several** conversations
and you can drop a finished slice without touching the rest.

**Projects, lanes, conversations.** A project is a repository; under it sit lanes —
`main` for the repo's own tree and **one per git worktree**, each with its own budget,
because a worktree is a separate tree with its own git index. `includeWorktrees: false`
hides them entirely.

**The ticks roll.** Every hour the scan recomputes the newest few **per lane** —
`autoTickPerDirectory` (3) in main, `autoTickPerWorktree` (3) in each worktree — among
conversations active within `sessionWindowDays` (3). Go back to an old slice and it
re-ticks itself, move on and it falls out. That ceiling matters: this repo had **44**
conversations in the tracking window and **16** inside 3 days, so without it "reopen
everything recent" means sixteen tabs.

**Unless you pin it.** Touching a conversation in the picker pins it and the roll
leaves it alone; `*` marks it. A pinned-and-ticked one spends part of the ceiling,
so the total per project stays bounded either way. `U` hands one back to the roll.
If a ticked conversation goes stale, **your tick still wins** — it reopens and says
`STALE` rather than silently dropping out of your morning.

**The tick and the launch are separate.** `[x]` decides what reopens at *logon*;
`L` opens the row under the cursor **now**, whatever its tick says. So a
conversation you never want back automatically is still one keypress away, and
ticking something does not launch it. `S` starts a new named session in that row's
directory, `X` opens everything ticked. The panel marks what is already live and
refuses to open it twice.

**Double-click** `Sessions.bat` — that is the entry point, and the only file you
need for day-to-day use. The others each do one specific job: `Restore Sessions.bat`
reopens the ticked conversations without showing the panel, `Install Session
Restore.bat` sets up the logon task, `Enable Auto Logon.bat` makes the machine sign
in by itself. The desktop buttons point at the same files.

**Auto-logon.** `Enable Auto Logon.bat` lets the PC sign itself in, so the restore
runs with nobody at the keyboard — power on, and the tabs are there. The password
goes into the encrypted LSA store, never the registry in plaintext, and is verified
before anything is written. `-LockAfterLogon` starts the sessions and then locks the
screen. Weigh it against physical access to the machine.

`restore-sessions.ps1` is an ordinary script you can run directly, and has a
desktop button. (`select-sessions.ps1`, the terminal panel, was retired on
2026-08-23 — the window replaced it.) Pass `-NoSessionRestore` to `install.ps1`
to skip all of it.

**Never launch a bare `claude` if you want to drive it from your phone.** Remote
Control registers against the *empty* conversation, so the phone shows an
auto-generated name and a later `/resume` never sends it your history. `cc` and
`ccr` exist to make that impossible. Full explanation in
[tools/session-restore/README.md](tools/session-restore/README.md).

## Install

```powershell
git clone https://github.com/TheMoMatthias/MM-toolbox.git
cd MM-toolbox
.\install.ps1
```

Or **double-click `Install.bat`** in the repo root — same thing, no terminal needed,
and it pauses so you can read the result. It passes any switches through, so
`Install.bat -NoSessionRestore` works too. Re-running it is also how you **apply an
update** after `git pull`.

That single step registers both scheduled tasks — `ClaudeSessionRestore` (at logon)
and `ClaudeSessionScan` (hourly + at logon, scan only) — plus the two desktop
buttons and the `cc`/`ccr`/`ccs` shell functions. There is nothing else to install.

Works **without admin** on a vanilla Windows install: tries `SymbolicLink` first; falls back to **NTFS Junction** for directories and **HardLink** for files (both work for non-admin users). For real symlinks instead, enable **Developer Mode** (Settings > Privacy & security > For developers) OR run as Administrator.

`install.ps1` does:

1. Backs up `~/.claude/{CLAUDE.md, keybindings.json, hooks, skills, agents}` to `~/.claude/.pre-mmtoolbox-backup-<timestamp>/` (skipped if a file isn't there).
2. Creates symlinks `~/.claude/<asset>` → `MM-toolbox/<asset>`.
3. Idempotent: re-running is safe; symlinks already pointing here are skipped.

After install, `git pull` in this repo is enough to update every machine's Claude config — the symlinks pick up the new content instantly.

## Uninstall

```powershell
.\uninstall.ps1
```

Or double-click **`Uninstall.bat`**. Removes the symlinks. If a backup dir exists under `~/.claude/`, restores the originals from the most recent one. Pass `-NoRestore` to keep the symlinks gone without restoring (the repo still has all your assets — useful when you're moving away from MM-toolbox but not throwing it away).

## Update workflow

```powershell
git -C path\to\MM-toolbox pull --rebase
```

Symlinks pick up the new content; no re-install needed.

## Customization (per-project)

`CLAUDE.md` here is the GLOBAL convention. Project repos can pin stricter or more specific rules in their own `.claude/CLAUDE.md`. Per-project rules **always override** the global ones (this rule is in the global file itself).

Examples of when to add a project-level `CLAUDE.md`:

- Critical-tier ladder for high-risk surfaces (trading, payments, healthcare)
- Domain-specific testing contract (e.g. look-ahead bias check for time-series ML)
- Custom Stop-and-Confirm gates (e.g. "any schema migration on a populated table")
- A project's preferred git workflow if it differs from feature-branch + PR

## Design choices

- **Symlink, not copy.** A live link means a single `git pull` updates every machine — no drift.
- **No personal-workflow rules in the global `CLAUDE.md`.** This repo aims to be team-friendly and production-grade. Personal preferences (e.g. "always commit to main") live in the project `CLAUDE.md`, not here.
- **Categorized dirs over flat frontmatter.** Browsing `skills/workflow/` vs `skills/diagnosis/` is faster than greping frontmatter when you have 30+ assets.
- **"Snapshot then prune"** posture. New skills/agents start as a verbatim copy from a real session, then get generalized once they prove broadly useful.

## Status

Day 1 of cross-machine use. Future work (deferred):

- ~~Multi-LLM portability (GPT / Gemini adapter layer)~~ — **partly done 2026-08-17**: every skill now carries an `agents/openai.yaml` with Codex metadata (`display_name`, `short_description`, and `allow_implicit_invocation: false` on user-invoked skills), adopted from upstream. Gemini remains untouched, and the skill *bodies* are still written for Claude Code — see divergence 3 in [SKILLS-UPSTREAM.md](SKILLS-UPSTREAM.md).
- Auto-pull on session start via a `SessionStart` hook — currently manual `git pull`.
- Adoption-by-others install script that asks which preferences to keep — currently single-user.
