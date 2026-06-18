---
name: agent-cluster
description: Analyze any codebase (or a referenced file structure) and auto-partition it into an efficient cluster of coordinated agents with disjoint file ownership, then spawn the team after you approve the plan. Use when the user wants to parallelize work on an arbitrary project across an agent team, "divide this repo into agents", or invokes /agent-cluster.
disable-model-invocation: true
argument-hint: [optional path/repo/structure to analyze] [goal] [--auto] [--size coarse|medium|fine]
effort: max
---

# Agent Cluster

Analyze a project's real structure, partition it into a **cluster of agents** that each own a disjoint slice, and run them as a team — without any two agents overwriting each other. You are the **lead**. This is the general counterpart to `/algo-team`; here the ownership map is *discovered*, not pre-baked.

Optional input from the user: `$ARGUMENTS`

## Step 1 — Resolve target + goal

- **Target** = the current repo by default. If `$ARGUMENTS` names a path, repo, or pastes a file tree, analyze that instead.
- **Goal** = the objective in one sentence (from `$ARGUMENTS`, or ask). The goal narrows which parts of the cluster actually get spawned — don't spawn agents for domains the goal never touches.

## Step 2 — Analyze the structure

Use the Agent tool with `subagent_type=Explore` (or read directly for small repos) to map:

1. **Top-level layout** — directories, packages, languages, monorepo vs single app.
2. **Module boundaries** — where cohesive units live (packages, services, apps, libs).
3. **Dependency edges** — which modules import which (this tells you where coupling is high vs low — cut the cluster where coupling is *lowest*).
4. **Cross-cutting / shared files** — imported by many modules: config, shared types/models, DB/connection layer, auth, utils, central registries, codegen, CI/build config. These will be **lead-owned**, never assigned to one agent.
5. **Build/test/lint commands** — from `package.json`, `pyproject.toml`, `Makefile`, `pytest.ini`, CI config. You'll need these to verify in Step 7.
6. **Existing conventions** — read the project `CLAUDE.md` and `CONTEXT.md` if present; respect their rules and vocabulary.

## Step 3 — Partition into a cluster (heuristics)

Build the ownership map by these rules — quality matters more than agent count:

- **Respect existing boundaries.** One cohesive module/package/service stays with one agent; never split it across agents.
- **Cut where coupling is lowest.** Group modules so inter-domain dependency edges are minimized; tightly-coupled modules belong to the same agent.
- **Balance size.** Avoid one giant domain + many tiny ones; aim for roughly comparable slices.
- **Disjoint by construction.** Every source file belongs to exactly one agent (or to the lead). State globs, not vague labels.
- **Lead owns cross-cutting files** (from Step 2.4). List them explicitly.
- **Right-size the agent count.** Default **medium = 4–8 agents**; `--size coarse` = 2–4, `--size fine` = one per module (use only for large parallel sweeps — coordination cost rises and in-process viewing gets heavy). Scale to repo size and goal scope.
- **Map each domain to a best-fit owner** (`subagent_type`) when one applies — e.g. `ui-design-architect` for a web front end, `database-architect` for a data layer, `backend-platform-architect` for an API, `devops-infra-engineer` for infra/CI, `security-auditor` for an auth module — else `claude`.

## Step 4 — Propose, then confirm

Present the plan and **wait for approval before spawning** (unless `--auto` is set, or the user already said "go"):

```
CLUSTER PLAN — <N> agents
  <agent>   owns <globs>            owner: <subagent_type>   tasks: <short>
  ...
LEAD-OWNED (shared/cross-cutting): <files>
FROZEN CONTRACTS (lead writes first): <APIs/schemas/types multiple agents depend on>
VERIFY WITH: <discovered build/test/lint commands>
```

Ask: *"Spawn this cluster, or adjust the split first?"* Apply any edits the user gives, then proceed.

## Step 5 — Freeze contracts + spawn

1. If agents share a contract (an API signature, a schema, a type, an event format), the **lead writes/freezes it first** so agents implement against a fixed surface — this is what prevents parallel work from clobbering or ignoring each other.
2. Build the shared task list: one task per ownership unit, dependencies explicit, agents self-claim.
3. Spawn one teammate per in-scope domain (Agent tool, `name` = domain, `team_name` = `cluster`, `subagent_type` = best-fit owner) with a self-contained brief (teammates don't inherit your history):

```
GOAL        <objective; this agent's slice>
OWNS        <exact globs — these files only>
DO NOT TOUCH anything outside your globs. Shared/cross-cutting files
            (<list>) are LEAD-owned — message the lead for changes there.
CONTRACT    <frozen signatures/schemas this slice implements against>
RULES       Obey the project CLAUDE.md/CONTEXT.md if present. No new .md
            docs unless asked. Verify your slice before reporting done.
DONE WHEN   <success criterion> — then SendMessage the lead.
```

## Step 6 — Coordinate

Watch the task list; unblock dependencies in order. Cross-cutting change requested → lead makes it, notifies dependents. Genuine file overlap → serialize (one finishes and signals before the next starts).

## Step 7 — Integrate + verify (lead)

Never declare done on teammate say-so. The lead:

1. Runs the discovered build + test + lint/typecheck commands across the touched modules.
2. Spot-checks the seams where domains meet (shared contract honored on both sides; call sites aligned).
3. Resolves merge points and any cross-cutting edits.
4. Delivers **one** consolidated report: what each agent did, what was verified, what could not be verified, downstream effects, and what was explicitly NOT changed.

## Hard Rules

- **Prime directive:** no two agents edit the same file — disjoint ownership + lead-owned shared files + serialize overlaps.
- **Confirmation gate** before spawning, unless `--auto` or explicit "go".
- **Respect the project's own rules** — read its `CLAUDE.md`/`CONTEXT.md` first; they override this skill on any conflict.
- **No new `.md` / summary / doc files** unless the user asked.
- **No commits/pushes/deploys** unless the user asked; the lead does it once after integration.
- **One team at a time; no nested teams.** Cap default agent count at 8 unless `--size fine` is requested.
