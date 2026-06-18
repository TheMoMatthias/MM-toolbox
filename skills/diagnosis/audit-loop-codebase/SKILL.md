---
name: audit-loop-codebase
description: Autonomously run /audit across the entire repository (or a subtree / domain), fix every finding (Critical → High → Medium → Low), verify the fixes, and re-audit until two consecutive scans return zero issues. Use when you want a hands-off, full-codebase cleanup pass — slower and broader than /audit-loop.
disable-model-invocation: true
argument-hint: [optional: <domain-keyword> | <subdirectory>] [--max-iters N] [--include-low false] [--exclude path,path]
effort: max
---

# Autonomous Audit + Fix Loop (whole-repository scope)

This skill is the repo-wide twin of `/audit-loop`. Same loop body, broader scope, longer runtime, higher risk surface.

**Scope defaults to the entire repository:**
- All tracked files under the project root.
- Excludes generated artifacts, dependencies, binary blobs, and lockfiles by default (`node_modules/**`, `venv/**`, `__pycache__/**`, `*.parquet`, `*.duckdb`, `*.lock`, `infra/postgres-backups/**`).
- A subdirectory or domain keyword narrows the sweep but keeps the "full-pass" semantics within that scope.

For audits scoped to in-flight branch work, use `/audit-loop` instead.

---

## Step 0: Resolve Scope and Loop Parameters

The first non-flag argument selects scope mode. Resolution order:

1. **Domain keyword** (case-insensitive, alias-friendly).
2. **Explicit subdirectory or glob**.
3. **Default = whole repository**.

### Mode A — Domain keyword

If the first argument matches a key (or any of its aliases) in the table below, expand it to the listed file set. Multiple keywords may be combined comma-separated (e.g. `/audit-loop-codebase ui,backend`).

| Keyword (canonical) | Aliases | Expands to |
|---|---|---|
| `userinterface` | `ui`, `frontend`, `react`, `web` | `terminal/frontend/**/*.{ts,tsx,js,jsx,css,html}` |
| `backend` | `api`, `terminal-backend`, `fastapi`, `routers` | `terminal/backend/**/*.py` |
| `datahub` | `hub`, `daemon`, `providers`, `ingest` | `datahub/**/*.py` |
| `dataloader` | `data-loader`, `training-pipeline`, `features` | `data_loader/**/*.py` |
| `trading` | `realtime`, `execution`, `api-trader`, `runner` | `api_trader/**/*.py` |
| `database` | `db`, `postgres`, `timescale`, `connection` | `db/**/*.{py,sql}` |
| `infra` | `infrastructure`, `ops`, `docker`, `compose` | `infra/**/*.{ps1,bat,sh,yml,yaml,conf,sql,env*}`, `Dockerfile*`, `docker-compose*.yml` |
| `ml` | `machine-learning`, `models`, `keras`, `optuna` | `machine_learning/**/*.py` |
| `backtest` | `backtesting`, `vectorbt` | `backtesting/**/*.py` |
| `config` | `configuration`, `paths`, `settings` | `config/**/*.{py,ini,yaml,yml,csv}` |
| `utils` | `utilities`, `helpers`, `logging` | `utils/**/*.py` |
| `tests` | `test`, `pytest` | `tests/**/*.py` |
| `tools` | `migration`, `scripts` | `tools/**/*.py` |

Resolution rules:
- Match canonical key OR any alias, case-insensitive, hyphens/underscores/spaces interchangeable.
- If no exact alias match, attempt a fuzzy match: case-insensitive substring against canonical keys + top-level directory names. If exactly one match → use it; if multiple → list candidates and ask.

### Mode B — Explicit subdirectory or glob

If the argument starts with `./`, `/`, contains a `/`, or contains a glob metacharacter (`*`, `?`, `[`), treat it as a path/glob and pass it directly to `git ls-files <path>`.

### Mode C — Default (whole repository)

If no scope argument is provided, build the file list with `git ls-files`.

### Common processing

Apply default + user-supplied exclusion patterns (`--exclude path,path` adds to the defaults). Drop binary files.

Bucket the resolved files by subsystem (use the directory layout in CLAUDE.md):
`db/`, `infra/`, `tools/`, `datahub/`, `data_loader/`, `api_trader/`, `terminal/backend/`, `terminal/frontend/`, `config/`, `backtesting/`, `machine_learning/`, `utils/`, `tests/`.
This bucketing drives Phase A's parallel agent dispatch — each subsystem gets a focused sub-audit so no agent receives an unmanageable file list.

### Flag parsing (independent of mode)

- `--max-iters N` → cap iterations (default **10**, hard ceiling 15).
- `--include-low false` → skip Low-priority drainage (default **true**).
- `--exclude path,path` → additional exclusions on top of the defaults.

State scope back to the user, e.g. `Scope: domain "userinterface" → 87 files in 1 subsystem. Max iterations: 10. Estimated wall time per iteration: ~5 min.`

If the resolved scope is empty, stop and report.

---

## Step 1: Iteration Loop

Run the body below repeatedly. Each iteration is one full repo-wide audit + fix + verify cycle.

### Stop conditions (any one ends the loop)

- **Convergence:** the most recent audit returned zero Critical, High, Medium, **and** Low findings, AND the previous audit also returned zero. Two clean scans in a row = done.
- **Iteration cap:** iteration counter reaches `--max-iters` (default 10).
- **Stuck:** the same finding (matched on file:line + problem signature) survives three consecutive fix attempts → escalate to user.
- **User halt:** any user-facing message asking the loop to stop.

### Per-iteration body

For each iteration `i = 1..max_iters`:

#### Phase A — Audit (parallel, per-subsystem)

For each subsystem bucket from Step 0, dispatch the specialist agents **in parallel** in a single message. Within a subsystem, run all relevant agents at once; across subsystems, batch dispatch is fine but watch the message size.

| Agent | Lens |
|---|---|
| `code-reviewer` | Design, maintainability, API quality, dead code, premature abstraction, test quality. |
| `quant-trading-architect` | Look-ahead bias, leakage, slippage assumptions, barrier/labeling correctness, order construction. (Only for `data_loader/`, `datahub/`, `api_trader/`, `backtesting/`, `machine_learning/`.) |
| `data-quality-scientist` | Statistical soundness, NaN propagation, dtype contracts, distribution sanity, transform correctness. (Only for data + ML + feature-engineering subsystems.) |
| `database-architect` | Schema design, query plans, index coverage, migration safety, hypertable correctness. (Only for `db/`, `tools/`, `infra/`, and any router that issues SQL.) |
| `security-auditor` | Auth, secrets, SQL injection, SSRF, dependency CVEs, file-upload paths, unsafe deserialization. (All subsystems.) |
| `function-tester` | Bug hunting via concrete test cases for each modified function: edge cases, boundary inputs, type contracts. |
| `observability-engineer` | Logging, metrics, alerting, runbook coverage. (Only for `infra/`, `terminal/backend/`, daemons.) |
| `devops-infra-engineer` | Container, CI, deployment, secret handling, IaC correctness. (Only for `infra/`, `Dockerfile.*`, `docker-compose.yml`.) |

Each agent receives a self-contained brief that includes:
- The exact subsystem file list it owns.
- A copy of Steps 2-5 from the original `/audit` skill (Logical Correctness, Domain-Specific Correctness, Completeness, Inefficiencies).
- The required output format from Phase B below.
- A one-line note: "Findings only — do not modify any files."

#### Phase B — Synthesize Findings

1. Collect every finding from every agent.
2. Deduplicate by `(file, line_range, problem_signature)`. Cross-subsystem duplicates are common — merge them.
3. Categorize by severity using the original `/audit` definitions:
   - **Critical** — wrong results, data leakage, look-ahead bias, security holes, broken invariants.
   - **High** — perf bottlenecks (>2× speedup), missing error handling for likely failures, memory issues.
   - **Medium** — code quality, minor inefficiencies, edge cases for unlikely scenarios.
   - **Low** — style, naming, readability.
4. For each finding produce a normalized record:
   ```
   id:        <stable hash of file+line+signature>
   severity:  Critical | High | Medium | Low
   subsystem: <bucket>
   file:      <path>:<line>
   problem:   <1-2 sentences>
   impact:    <what breaks if unfixed>
   fix:       <concrete change, code snippet preferred>
   tier:      <safe | caution | critical>   # per CLAUDE.md "Change Risk Classification"
   ```
5. Print a short table: counts per severity × per subsystem, plus counts per tier.

#### Phase C — Tier Gate (CLAUDE.md Critical surfaces)

Before applying any fix, scan the finding list for `tier: critical`. CLAUDE.md defines these as:
> Feature engineering code, transforms, Postgres schema, IPC format, model weights, signal logic, order construction, `db/connection.py`, `infra/postgres.conf`, `infra/pg_hba.conf`.

If **any** finding is `tier: critical`:
- **Pause the loop.**
- Surface those findings to the user with proposed fixes.
- Wait for explicit go-ahead per finding.
- Apply only the ones the user approves; defer the rest with a `won't-fix-this-loop` note + reason.

Do not auto-apply Critical-tier edits under any circumstance.

#### Phase D — Plan + Test First (TDD-lite)

For each finding the loop will fix this iteration (Critical → High → Medium → Low order, all included by default):

1. Re-read the target file(s) — never edit from memory.
2. Grep all callers of any function being modified.
3. Write or update a focused test that **fails** because of the bug (or asserts the missing behavior). Place it next to existing tests for the module. Skip this step only when the issue is a pure perf/style change with no behavioral delta.
4. Confirm the test fails before the fix.

#### Phase E — Implement

For each finding, in dependency order:
1. Apply the change with `Edit` (or `Write` for genuinely new files).
2. Honor every `❌ NEVER` rule in CLAUDE.md (no `bfill`, no `main_spread_*` features, no Optuna over data-pipeline params, no raw `psycopg.connect()`, no new `.md` files unless the user asked, etc.).
3. Do **not** add unrelated improvements, refactors, or docstrings beyond the fix.

#### Phase F — Verify

After every fix in this iteration is applied:
1. Syntax check each modified Python file:
   `python -c "import ast; ast.parse(open(r'FILE').read())"`
2. Import check for each modified module.
3. Run the tests written in Phase D — they must now **pass**.
4. Run any pre-existing tests that cover the modified code (`pytest <path>` for affected paths).
5. For frontend changes: `tsc --noEmit` on the touched packages.
6. Type/contract spot-check: function signatures, return types, call sites still aligned.
7. If any verification fails: revert the fix for that finding, mark it `regressed`, and surface it in the iteration report.

#### Phase G — Iteration Report (inline, no file)

Print a compact report:
```
Iteration i / max_iters
  Findings:  C=__ H=__ M=__ L=__   (Δ vs prev: C=__ H=__ M=__ L=__)
  Fixed:     C=__ H=__ M=__ L=__
  Deferred:  <count>  (Critical-tier awaiting approval, regressed, stuck)
  Tests:     <wrote N>, <ran M>, all green / <list failures>
  Files touched: <count>
  Subsystems touched: <list>
```

#### Phase H — Stop Check

Evaluate stop conditions. If none triggered, start iteration `i+1`.

---

## Step 2: Final Report

When the loop ends, print one consolidated report:

### Loop Summary
- Iterations run.
- Why the loop stopped (convergence / cap / stuck / halt).
- Total findings fixed by severity × subsystem.
- Findings deferred + reasons.
- Findings regressed + reasons.

### Files Modified
One line per file: `path — N edits, tests added/updated`.

### Tests
- New tests created (paths).
- Pre-existing tests rerun and their pass/fail status.

### Outstanding Items (require user)
- Critical-tier findings awaiting approval.
- Stuck findings that survived three fix attempts.
- Anything the loop could not verify (state explicitly what and how the user can verify it manually).

### Downstream Effects
Per CLAUDE.md "Phase 4 Mandatory Reporting": call out anything that requires retraining, schema version bump, daemon restart, or operator action.

### Scope Boundaries
What was explicitly NOT changed (out-of-scope files, exclusions, deferred refactors).

---

## Hard Rules for the Loop

- **No `.md`, summary, or documentation files** are created during the loop unless the user explicitly asked.
- **No git commits, pushes, or branch operations.** The loop modifies the working tree only.
- **No deployments, daemon restarts, or service touches.** The loop is local.
- **No edits to `infra/` operator scripts, Postgres config, or schema files** without an explicit user go-ahead per Phase C.
- **No silent skips.** If a finding cannot be fixed, the iteration report must say so and why.
- **Cache awareness.** If a Numba kernel signature changes, clear `__pycache__` `.nbi`/`.nbc` files for that module before verification.
- **Backend portability.** Any DB-touching fix must work under both `ALGOTRADER_DB_BACKEND=postgres` and `=duckdb` until DuckDB is formally retired.
- **Timezone discipline.** Every data-handling fix asserts `str(df.index.tz) == 'Europe/Berlin'` where applicable.
- **Subsystem batching.** Never give one agent a file list >50 files; bucket by subsystem and dispatch in parallel.
- **Wall-time discipline.** Each iteration of a full-repo sweep can run 15–30 minutes. If a single iteration exceeds 60 minutes, halt and report so the user can narrow scope.
