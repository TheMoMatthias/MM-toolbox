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
├── skills/             # 45 skills. Every one carries agents/openai.yaml for Codex as well.
│   ├── workflow/       # grill-with-docs, grill-me, grilling, domain-modeling, handoff, claude-handoff,
│   │                   # spawn-claude-session, reevaluate, wrap-up, teach, ask-matt, loop-me,
│   │                   # to-questionnaire, wait-what, writing-great-skills
│   ├── development/    # implement, tdd, write-a-skill, to-issues, to-prd, prototype, research,
│   │                   # resolving-merge-conflicts, triage, wayfinder, wizard,
│   │                   # setup-engineering-skills, setup-pre-commit
│   ├── diagnosis/      # diagnose, audit, audit-loop, audit-loop-codebase, diagnosing-bugs, code-review
│   ├── architecture/   # improve-codebase-architecture, codebase-design, setup-ts-deep-modules
│   ├── writing/        # writing-for-agents, writing-beats, writing-fragments, writing-shape
│   ├── misc/           # git-guardrails-claude-code, migrate-to-shoehorn, scaffold-exercises
│   └── orchestration/  # agent-cluster
├── agents/
│   ├── core/           # universal: code-reviewer, function-tester, systems-architect, research-engineer, data-quality-engineer, ml-engineer
│   ├── backend/        # backend-platform-architect, database-architect
│   ├── infra/          # devops-infra-engineer, observability-engineer
│   ├── security/       # security-auditor
│   ├── frontend/       # ui-design-architect
│   └── quant/          # quant-trading-architect, quant-researcher, data-quality-scientist, ml-systems-architect
├── tools/
│   └── session-restore/ # bring back recent Claude conversations at logon, correctly named
│                        # (see tools/session-restore/README.md)
├── install.ps1         # symlink ~/.claude/* into this repo (backs up originals)
└── uninstall.ps1       # remove symlinks, optionally restore originals
```

## Resuming yesterday's work

`install.ps1` also sets up **session-restore**: a logon task, a desktop button, and
two shell functions.

| command | does |
|---|---|
| `ccr` | restore the conversations you were last working on, one tab each, Remote Control attached under each one's real name |
| `ccr -DryRun` | show what *would* come back |
| `ccr -All` | ignore the recency window and the cap |
| `cc` | start a correctly-**named** new session in the current directory |
| `cc "my-name" --model opus` | …with a name you choose, plus any `claude` flags (the name comes first) |

Projects are discovered, not listed — work in a new repo once and it is picked up.
Pass `-NoSessionRestore` to `install.ps1` to skip all of it.

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

- ~~Multi-LLM portability (GPT / Gemini adapter layer)~~ — **partly done 2026-08-17**: every skill now carries an `agents/openai.yaml` with Codex metadata (`display_name`, `short_description`, and `allow_implicit_invocation: false` on user-invoked skills), adopted from upstream. Gemini remains untouched, and the skill *bodies* are still written for Claude Code — see divergence 3 in [SKILLS-UPSTREAM.md](SKILLS-UPSTREAM.md).
- Auto-pull on session start via a `SessionStart` hook — currently manual `git pull`.
- Adoption-by-others install script that asks which preferences to keep — currently single-user.
