# MM-toolbox

A portable, cross-machine source-of-truth for a Claude Code workflow: grill-spec-execute discipline, batched alignment, autonomy contracts, parallel-batch-cascade discipline, and a curated library of skills + agents + hooks.

This repo is the **upstream** of `~/.claude/` on every machine I work from. Sit at a new machine, run `install.ps1`, and the full workflow appears — `CLAUDE.md`, hooks, skills, agents, keybindings — all kept in sync via git.

## What's inside

```
mm-toolbox/
├── CLAUDE.md           # global operating convention (loaded on every session, every repo)
├── keybindings.json
├── hooks/
│   └── grill-gate.ps1  # UserPromptSubmit hook — injects grill reminder on refactor-class prompts
├── skills/
│   ├── workflow/       # grill-with-docs, grill-me, handoff, spawn-claude-session, reevaluate
│   ├── development/    # implement, tdd, write-a-skill, to-issues, to-prd
│   ├── diagnosis/      # diagnose, audit, audit-loop, audit-loop-codebase
│   ├── architecture/   # improve-codebase-architecture
│   └── orchestration/  # agent-cluster
├── agents/
│   ├── core/           # universal: code-reviewer, function-tester, systems-architect, research-engineer, data-quality-engineer, ml-engineer
│   ├── backend/        # backend-platform-architect, database-architect
│   ├── infra/          # devops-infra-engineer, observability-engineer
│   ├── security/       # security-auditor
│   ├── frontend/       # ui-design-architect
│   └── quant/          # quant-trading-architect, quant-researcher, data-quality-scientist, ml-systems-architect
├── install.ps1         # symlink ~/.claude/* into this repo (backs up originals)
└── uninstall.ps1       # remove symlinks, optionally restore originals
```

## Install

```powershell
git clone https://github.com/TheMoMatthias/MM-toolbox.git
cd MM-toolbox
.\install.ps1
```

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

Removes the symlinks. If a backup dir exists under `~/.claude/`, restores the originals from the most recent one. Pass `-NoRestore` to keep the symlinks gone without restoring (the repo still has all your assets — useful when you're moving away from MM-toolbox but not throwing it away).

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

- Multi-LLM portability (GPT / Gemini adapter layer) — triggered when I actually use a non-Claude LLM with this workflow.
- Auto-pull on session start via a `SessionStart` hook — currently manual `git pull`.
- Adoption-by-others install script that asks which preferences to keep — currently single-user.
