# Skills

Skills are user-invocable workflows that Claude Code can run via the `Skill` tool. Invoke from chat with `/<skill-name>` or via the skill description matching.

## Categories

| Category | Purpose | Skills |
|---|---|---|
| [workflow/](workflow/) | The grill-spec-execute discipline + handoffs + session orchestration | `grill-with-docs`, `grill-me`, `handoff`, `spawn-claude-session`, `reevaluate` |
| [development/](development/) | Building features, tests, PRDs, issues | `implement`, `tdd`, `write-a-skill`, `to-issues`, `to-prd` |
| [diagnosis/](diagnosis/) | Bug hunting, audits, debugging loops | `diagnose`, `audit`, `audit-loop`, `audit-loop-codebase` |
| [architecture/](architecture/) | Codebase-wide refactor / shape work | `improve-codebase-architecture` |
| [orchestration/](orchestration/) | Multi-agent coordination | `agent-cluster` |

## When to add a new skill vs. an agent

- **Skill** — a *workflow* I run myself (or Claude runs for me). Many steps, a specific recipe. Examples: "grill me on this plan", "convert this conversation to a PRD".
- **Agent** — a *specialist* with its own context that I delegate to. Examples: "review this code for security issues", "design this database schema".

If you're writing a multi-step recipe → skill. If you're writing a "spawn a domain expert" → agent.

See `skills/development/write-a-skill/` for the canonical skill format.
