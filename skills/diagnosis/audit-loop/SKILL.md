---
name: audit-loop
description: Autonomously audit a scope, fix every finding (Critical → High → Medium → Low), verify the fixes, and re-audit until two consecutive scans return zero issues. Scope defaults to the current branch's diff vs the main branch, but accepts explicit paths, globs, or a domain keyword (inferred from the repo's own structure) to audit an entire subsystem regardless of recent changes. Project-agnostic: it reads the target repo's own CLAUDE.md / conventions to decide critical surfaces, prohibitions, and toolchain. Use when you want a hands-off audit → fix → verify → re-audit pass over in-flight branch work or a chosen scope, in any repository.
disable-model-invocation: true
argument-hint: [optional: <domain-keyword> | <path> | <glob>] [--max-iters N] [--include-low false]
effort: max
---

# Autonomous Audit + Fix Loop (branch / path / domain scope)

This skill audits a scope, applies the resulting fixes, verifies them, then re-audits — and keeps going until the scope is clean. It is **project-agnostic**: nothing about the target stack is hard-coded. Before auditing, it grounds itself in the *target repository* — its `CLAUDE.md` (and any nested ones), its directory layout, its language/toolchain, and its test runner — and lets those govern critical surfaces, prohibitions, verification commands, and domain lenses.

For a whole-repository sweep, use the codebase-wide variant if the project defines one; otherwise pass the repo root as the scope.

---

## Step 0: Ground in the Target Project, then Resolve Scope

### Step 0a — Project grounding (do this first, every run)

Before resolving scope, read the ground truth for *this* repo so every later phase is project-correct:

1. **Conventions:** read the repo's `CLAUDE.md` / `AGENTS.md` / equivalent, including nested ones under the scope. Extract: critical-surface / change-risk classification, explicit prohibitions ("never do X"), git/branch rules, test/verify commands, and any data/invariant rules (timezone, backend portability, schema versioning, etc.). **These override every default in this skill.**
2. **Layout & stack:** detect the primary language(s), package manager, and test runner from the manifest (`pyproject.toml`/`package.json`/`go.mod`/`Cargo.toml`/…) and directory structure. Record the correct **syntax-check**, **import/build-check**, and **test** commands for later phases (e.g. Python → `python -c "import ast; ast.parse(...)"` + `pytest`; TS/JS → `tsc --noEmit`/`node --check` + the project's test script; etc.).
3. **Main branch name:** determine it (`git symbolic-ref refs/remotes/origin/HEAD`, else `main`/`master` as present) rather than assuming `main`.

If the repo has no CLAUDE.md, fall back to the generic critical-surface heuristic in Phase C and note that you inferred it.

### Step 0b — Scope resolution

The first non-flag argument selects scope mode. Resolution order:

1. **Domain keyword** (case-insensitive, alias-friendly) — audit an entire subsystem regardless of git status.
2. **Explicit path or glob** — concrete files/dirs/patterns provided by the user.
3. **Default = branch diff** — in-flight work since branching off the main branch.

#### Mode A — Domain keyword (inferred from the repo, not a fixed list)

There is **no hard-coded domain table**. Resolve a keyword against *this repo's actual structure*:

- Normalize the keyword (case-insensitive; hyphens/underscores/spaces interchangeable) and match it against the repo's real top-level directories and packages, plus common conventional aliases:
  - `ui` / `frontend` / `web` / `client` → the front-end source tree (e.g. `**/*.{ts,tsx,js,jsx,vue,svelte,css,html}` under the detected UI dir).
  - `backend` / `api` / `server` → the server/app source (routers, handlers, services).
  - `database` / `db` / `schema` → DB access + migration + schema files.
  - `infra` / `ops` / `deploy` → Dockerfiles, compose, IaC, CI, shell/PS scripts, server config.
  - `tests` → the test tree. `config` → configuration. `utils` / `helpers` → shared utilities. `docs` → documentation.
  - Domain-specific names (a subsystem, service, or package) → the matching directory.
- Combine multiple keywords comma-separated (e.g. `ui,backend`).
- Fuzzy match: case-insensitive substring against real top-level directory/package names. Exactly one match → use it; multiple → list candidates and ask; none → treat the argument as a path/glob (Mode B) or report that no such subsystem exists.
- Expand to the concrete file list via the repo's real paths, then drop generated/binary/vendored files: lockfiles, build artifacts, `node_modules/**`, `__pycache__/**`, virtualenvs, `dist/**`, `build/**`, data blobs (`*.parquet`, `*.duckdb`, `*.sqlite`, large binaries).

State the resolved scope back to the user, e.g. `Scope: domain "frontend" → 41 files under src/web/. Max iterations: 10.`

#### Mode B — Explicit path or glob

If the argument starts with `./`, `/`, contains a `/`, or contains a glob metacharacter (`*`, `?`, `[`), treat it as a path/glob and expand directly. No keyword lookup.

#### Mode C — Default (branch diff)

If no scope argument is provided, build the scope from in-flight work against the detected main branch:
```bash
git diff <main-branch>...HEAD --name-only
git status --porcelain
```
Union the results; drop binary/generated/lockfiles as in Mode A. If this is empty (clean tree, already merged), say so and ask the user for a target rather than silently doing nothing.

### Flag parsing (independent of mode)

- `--max-iters N` → cap iterations (default **10**, hard ceiling 15).
- `--include-low false` → skip Low-priority drainage (default **true** — Low is included).

If the resolved scope is empty, stop and report — there is nothing to audit.

---

## Step 1: Iteration Loop

Run the body below repeatedly. Each iteration is one full audit + fix + verify cycle.

### Stop conditions (any one ends the loop)

- **Convergence:** the most recent audit returned zero Critical, High, Medium, **and** Low findings, AND the previous audit also returned zero. Two clean scans in a row = done.
- **Iteration cap:** iteration counter reaches `--max-iters` (default 10).
- **Stuck:** the same finding (matched on file:line + problem signature) survives three consecutive fix attempts → escalate to user, do not loop forever.
- **User halt:** any user-facing message asking the loop to stop.

### Per-iteration body

For each iteration `i = 1..max_iters`:

#### Phase A — Audit (parallel specialists, chosen to fit the codebase)

Dispatch sub-agents **in parallel** in a single message. Hand each the exact scope file list, the project-grounding notes from Step 0a, the audit checklist (Logical Correctness, Domain-Specific Correctness, Completeness, Inefficiencies), the required output format from Phase B, and a one-line note: **"Findings only — do not modify any files."**

Roster = a fixed core + domain lenses selected from what the code actually is:

**Always include (core):**
| Agent | Lens |
|---|---|
| `code-reviewer` | Design, maintainability, API quality, dead code, premature abstraction, test quality. |
| `security-auditor` | Auth, secrets, injection, SSRF, unsafe deserialization, dependency CVEs, file/upload/path handling, data-at-rest, PII/logging leaks. |
| `function-tester` | Bug hunting via concrete test cases for each modified function: edge cases, boundary inputs, type contracts. |

**Add the domain lenses that match the detected stack** (skip those that don't apply — do not force an irrelevant specialist):
| If the code involves… | Add lens |
|---|---|
| Data pipelines, ML, statistics, dtype/NaN contracts | `data-quality-scientist` |
| Model architecture / training / inference | `ml-engineer` |
| Trading / market / backtest / execution logic | `quant-trading-architect` |
| SQL, schema, migrations, query performance | `database-architect` |
| APIs, multi-tenancy, jobs/queues, webhooks, billing | `backend-platform-architect` |
| UI / UX / layout / accessibility | `ui-design-architect` |
| Containers, CI/CD, cloud, IaC | `devops-infra-engineer` |
| Logging, metrics, tracing, SLOs | `observability-engineer` |

Pick the smallest set that covers the scope's real risk surface; state which lenses you chose and why. (If none of the domain lenses fit, the core trio is sufficient.)

#### Phase B — Synthesize Findings

1. Collect every finding from every agent.
2. Deduplicate by `(file, line_range, problem_signature)`. When two agents flag the same root cause from different angles, merge into one finding and keep both rationales.
3. Categorize by severity:
   - **Critical** — wrong results, data leakage, security holes, broken invariants, corruption, silent data loss.
   - **High** — significant perf bottlenecks (>2× speedup), missing error handling for likely failures, memory issues.
   - **Medium** — code quality, minor inefficiencies, edge cases for unlikely scenarios.
   - **Low** — style, naming, readability.
4. For each finding produce a normalized record:
   ```
   id:        <stable hash of file+line+signature>
   severity:  Critical | High | Medium | Low
   file:      <path>:<line>
   problem:   <1-2 sentences>
   impact:    <what breaks if unfixed>
   fix:       <concrete change, code snippet preferred>
   tier:      <safe | caution | critical>   # per the project's change-risk classification (Phase C)
   ```
5. Print a short table: counts per severity, counts per tier.

#### Phase C — Tier Gate (project-defined critical surfaces)

Before applying any fix, classify each finding's `tier` using **the target project's own critical-surface / change-risk definition** (from its CLAUDE.md, read in Step 0a). Those rules win.

If the project defines none, infer `tier: critical` for high-blast-radius surfaces by these generic heuristics:
> Security/auth/crypto code; anything handling money, secrets, or PII; data-write/verification/fail-loud paths; DB schema & migrations; persisted data formats & IPC/serialization contracts; public/published API contracts; model weights or their loading; infra/deploy config that affects production.

If **any** finding is `tier: critical`:
- **Pause the loop.**
- Surface those findings to the user with proposed fixes.
- Wait for explicit go-ahead per finding.
- Apply only the ones the user approves; defer the rest with a `won't-fix-this-loop` note + reason.

Do not auto-apply Critical-tier edits under any circumstance.

#### Phase D — Plan + Test First (TDD-lite)

For each finding the loop will fix this iteration (Critical → High → Medium → Low order, all included by default):

1. Re-read the target file(s) — never edit from memory.
2. Grep all callers of any function/symbol being modified.
3. Write or update a focused test that **fails** because of the bug (or asserts the missing behavior), using the project's own test framework/layout. Skip this step only when the issue is a pure perf/style change with no behavioral delta.
4. Confirm the test fails before the fix.

#### Phase E — Implement

For each finding, in dependency order:
1. Apply the change with `Edit` (or `Write` for genuinely new files).
2. **Honor every prohibition in the target repo's CLAUDE.md** (framework/library bans, forbidden patterns, file-creation rules, data/invariant rules, etc.). When the project forbids something, that ban is absolute here.
3. Do **not** add unrelated improvements, refactors, or docstrings beyond the fix.

#### Phase F — Verify (using the project's own toolchain)

After every fix in this iteration is applied, run the checks recorded in Step 0a:
1. **Syntax check** each modified file with the language-appropriate command (Python `ast.parse`; `node --check`; `tsc --noEmit`; compiler for compiled languages; etc.).
2. **Import/build check** for each modified module.
3. **Run the tests written in Phase D** — they must now **pass**.
4. **Run pre-existing tests** covering the modified code via the project's runner.
5. **Type/contract spot-check:** signatures, return types, and call sites still aligned.
6. If any verification fails: revert the fix for that finding, mark it `regressed`, and surface it in the iteration report.
7. **Cache/artifact awareness:** if a change alters a compiled/cached signature (native-compiled kernels, generated code, build caches), invalidate the relevant cache before verifying so a stale artifact can't mask the change.

#### Phase G — Iteration Report (inline, no file)

Print a compact report:
```
Iteration i / max_iters
  Lenses:    <which specialists ran this iteration>
  Findings:  C=__ H=__ M=__ L=__   (Δ vs prev: C=__ H=__ M=__ L=__)
  Fixed:     C=__ H=__ M=__ L=__
  Deferred:  <count>  (Critical-tier awaiting approval, regressed, stuck)
  Tests:     <wrote N>, <ran M>, all green / <list failures>
  Files touched: <count>
```

#### Phase H — Stop Check

Evaluate stop conditions. If none triggered, start iteration `i+1`.

---

## Step 2: Final Report

When the loop ends, print one consolidated report:

### Loop Summary
- Iterations run.
- Why the loop stopped (convergence / cap / stuck / halt).
- Total findings fixed by severity.
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
Call out anything that requires follow-up action per the project's conventions — retraining, schema/version bump, service or daemon restart, cache rebuild, dependency reinstall, or operator action.

### Scope Boundaries
What was explicitly NOT changed (out-of-scope files, deferred refactors).

---

## Hard Rules for the Loop

- **Honor the target repo's CLAUDE.md above this skill.** Its prohibitions, critical-surface rules, git workflow, and invariant rules (timezone, backend portability, schema versioning, framework bans, etc.) are authoritative wherever they apply.
- **No documentation/summary files** (`.md` or otherwise) are created during the loop unless the user explicitly asked.
- **No git commits, pushes, or branch operations.** The loop modifies the working tree only.
- **No deployments, service/daemon restarts, or production touches.** The loop is local.
- **No edits to infra/operator/deploy/schema config** without an explicit user go-ahead per Phase C.
- **No silent skips.** If a finding cannot be fixed, the iteration report must say so and why.
- **Restore any global/env/config a fix or test mutates**, so one iteration cannot pollute the next.
- **Cache invalidation on signature change**, so stale compiled/generated artifacts cannot mask an unverified fix.
