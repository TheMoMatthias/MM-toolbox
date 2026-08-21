---
name: algo-team
description: Spin up a coordinated agent team for the AlgoTrader repo, with a pre-mapped 8-domain ownership split so teammates work in parallel without overwriting each other. Use when the user wants to parallelize AlgoTrader work across an agent team, or says "spin up the team", "/algo-team", or "split this across agents".
disable-model-invocation: true
argument-hint: [optional goal, e.g. "ship the IV-surface provider"] [--only domain,domain] [--auto]
effort: max
---

# AlgoTrader Agent Team

Launch an agent team where each teammate owns a **disjoint slice** of the AlgoTrader codebase. You are the **lead**: you plan the split, freeze shared contracts, spawn teammates, coordinate them, and integrate + verify. The prime directive is **non-negotiable: no two teammates ever edit the same file**.

Optional input from the user: `$ARGUMENTS`

## Step 1 — State the goal

Restate the objective in one sentence (from `$ARGUMENTS`, or ask if absent). Decide which domains the goal actually touches — **only spawn teammates for domains in scope.** A frontend-only task does not need the `ml` or `trading` teammate. Honor `--only domain,domain` to force a subset.

## Step 2 — Ownership map (8 domains)

Each teammate owns exactly these globs. Ownership is by **file**, disjoint by construction.

| Teammate | Owns | Best-fit owner (subagent_type) |
|---|---|---|
| `ingest` | `datahub/**/*.py` (providers, daemon, fetch) | `backend-platform-architect` |
| `database` | `db/**/*.{py,sql}`, `tools/**/*.py` | `database-architect` |
| `training` | `data_loader/**/*.py` (labeling, transforms, pipeline) | `quant-researcher` |
| `ml` | `machine_learning/**/*.py`, `backtesting/**/*.py` | `quant-researcher` |
| `trading` | `api_trader/**/*.py` (realtime_runner, data_daemon) | `quant-trading-architect` |
| `backend` | `terminal/backend/**/*.py` (FastAPI routers/services) | `backend-platform-architect` |
| `frontend` | `terminal/frontend/**/*.{ts,tsx,css}` | `ui-design-architect` |
| `platform` | `infra/**`, `config/**`, `utils/**` | `devops-infra-engineer` |

**Tests:** each teammate owns the test files that cover its domain (`tests/test_<domain>*.py`). If two need the same test file, the lead arbitrates.

Use `claude` as the owner type for any domain where the specialist doesn't fit the specific task.

## Step 3 — Lead-owned cross-cutting files (NEVER assign to a teammate)

These are imported/contract-shared across domains and overlap with CLAUDE.md's Critical-tier surfaces. **Only the lead edits them**; teammates request changes by message and the lead applies them:

- `db/connection.py` — the single DB access surface (Critical-tier).
- `config/path_utils.py` — every module imports `init_paths_for_module`.
- `datahub/datahub.py` — singleton + `_PgConnAdapter` read/write surface for every consumer.
- `db/schema/*.sql` — migrations (Critical-tier; versioned + tested on empty+populated).
- IPC contract: `data_daemon` ↔ `realtime_runner` parquet manifest `schema_version`.
- `CONTEXT.md` — shared lexicon (lead maintains inline, per the no-`.md` exception).

## Step 4 — Pre-flight: freeze contracts, build the task list

1. If the goal requires a shared contract change (a new feature column, a schema field, an API/IPC signature two domains depend on), **the lead writes/freezes that signature first** and announces it. Teammates implement against the frozen contract — this is what prevents "one agent's change ignores the other's".
2. Create the shared task list: one task per ownership unit, dependencies explicit (e.g. `frontend` depends on `backend` endpoint shape). Teammates self-claim.
3. Honor the AlgoTrader Live Trading Safety Protocol: if `realtime_runner` holds an open position, do not let the `trading`/`training`/`ml`/`ingest` teammates touch live signal/feature/transform/order code without the halt→flatten→deploy procedure. Surface this to the user before spawning those domains.

## Step 5 — Spawn teammates

For each in-scope domain, spawn one teammate (Agent tool, `name` = domain, `team_name` = `algo`, `subagent_type` = best-fit owner). Each spawn brief is **self-contained** (teammates don't inherit your history):

```
GOAL        <the one-sentence objective, your slice of it>
OWNS        <exact globs from the map — these files only>
DO NOT TOUCH any file outside your globs. Cross-cutting files
            (db/connection.py, config/path_utils.py, datahub/datahub.py,
            db/schema/*.sql, the IPC manifest) are LEAD-owned —
            if you need a change there, message the lead, don't edit.
CONTRACT    <frozen signatures/schema this slice must implement against>
RULES       Obey the repo CLAUDE.md in full: route DB via db.connection,
            assert Europe/Berlin tz after loads, no bfill, no look-ahead,
            no main_spread_* features, no new .md files, [Module][function]
            logging, no SELECT * in prod. Verify your slice to the
            Non-Negotiable Testing Contract.
DONE WHEN   <success criterion for this slice> — then SendMessage the lead.
```

## Step 6 — Coordinate

- Watch the task list; unblock dependencies in order.
- If a teammate asks for a cross-cutting change, the lead makes it, then notifies dependents via SendMessage.
- If two teammates surface a genuine file overlap, serialize them (one finishes → signals → next starts).

## Step 7 — Integrate + verify (lead)

Once teammates report done, the lead runs the cross-cutting checks — never declare done on teammate say-so alone:

1. Per-domain syntax/import check on changed Python (`python -c "import ast; ast.parse(open(r'FILE').read())"`).
2. `pytest` for every affected subsystem's tests.
3. `tsc --noEmit` if `terminal/frontend` changed; rebuild via the frontend-build endpoint if deploying.
4. Contract spot-check: feature counts vs model `input_shape`, manifest `schema_version`, Postgres column sets vs table schema.
5. If a feature/transform/schema/signal changed → state model-invalidation / retrain / schema-bump impact (CLAUDE.md Phase 4 reporting).
6. Deliver **one** consolidated report (what each teammate did, what was verified, downstream effects, what's NOT changed).

## Hard Rules

- **Prime directive:** no two teammates edit the same file — ever. Disjoint ownership + lead-owned shared files + serialize overlaps.
- **Critical-tier gate:** schema migrations, transform/IPC/model-weight/signal/order changes, and edits to `db/connection.py` / `infra/postgres.conf` / `infra/pg_hba.conf` stop for explicit user go-ahead (CLAUDE.md). A teammate must never auto-apply these.
- **No new `.md` / summary / doc files** (sole exception: `CONTEXT.md`, lead-only).
- **No commits/pushes/deploys** unless the user asked; if they did, the lead does it once after integration (Live Trading Safety Protocol still binding).
- **Spawn only in-scope domains.** Idle teammates are coordination cost, harder to view in-process.
- **One team at a time; no nested teams** — teammates cannot spawn their own teams.
