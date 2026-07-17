---
name: audit
description: Perform a comprehensive one-shot audit of code for logical correctness, domain-specific correctness, completeness, and inefficiencies, then report findings by severity. Project-agnostic — it grounds itself in the target repo's own CLAUDE.md/conventions, language, and toolchain before auditing. Use to verify implemented changes or review existing code quality in any repository.
disable-model-invocation: true
argument-hint: [file, module, or path to audit]
effort: max
---

# Comprehensive Code Audit

Perform a rigorous, read-only audit of the specified code and report findings — this skill does **not** apply fixes (use `/audit-loop` for the fix-and-verify loop). The target is: $ARGUMENTS

This skill is **project-agnostic**: nothing about the target stack is hard-coded. It first grounds itself in the *target repository* — its conventions, language, and domain — and lets those govern what "correct" means, then audits against that ground truth.

## Step 0: Ground in the Target Project

Before auditing, read the ground truth for *this* repo so every check is project-correct:

1. **Conventions:** read the repo's `CLAUDE.md` / `AGENTS.md` / equivalent (including nested ones covering the target). Extract: critical-surface / change-risk rules, explicit prohibitions ("never do X"), invariants (timezone, numeric precision, schema/versioning, data-flow rules), and required patterns. **These override every default below.**
2. **Stack & layout:** detect the primary language(s), frameworks, and domain from the manifest (`pyproject.toml` / `package.json` / `go.mod` / `Cargo.toml` / …) and directory structure. This selects which domain lenses in Step 3 actually apply.

If the repo has no such conventions file, fall back to the generic heuristics below and note that you inferred them.

## Step 1: Identify Audit Scope

- Read ALL files/modules named in the arguments.
- If a directory or module is specified, identify every relevant file within it (skip generated/vendored/binary files).
- Note the purpose and role of each file in the broader system, and who consumes its output.

## Step 2: Logical Correctness

For each function and code path, verify:

- **Control flow**: Are all branches reachable? Any unreachable paths or missing branches?
- **Edge cases**: Empty inputs, null/NaN values, zero-length collections, single-element inputs, boundary values, overflow.
- **Off-by-one errors**: Loop bounds, indexing, slicing, range calculations.
- **Type safety**: Are types consistent across calls? Any implicit coercions that could fail?
- **Return values**: Does every path return the expected type? Are error returns handled by callers?
- **State mutations**: Unintended side effects? Is shared mutable state properly managed?
- **Concurrency**: If threads/async/multiprocessing are used — race conditions, deadlocks, missing locks, unsafe shared state?
- **Resource lifecycle**: Are files, connections, locks, handles released on every path (including errors)?

## Step 3: Domain-Specific Correctness

Apply the lenses that match the domain detected in Step 0 — and prioritize whatever the repo's own conventions flag as critical. **Skip lenses that don't apply; do not force an irrelevant one.** Common lenses, with examples:

- **Data / ML / statistics** (if the code handles datasets, features, models):
  - *Look-ahead / leakage*: does any feature, label, or transform use future data? Check rolling windows, shifts, joins, fills. Are train/val/test splits purged/embargoed, and do transforms fit on training data only?
  - *NaN / null propagation*: do missing values silently corrupt downstream results?
  - *Numerical stability*: division by zero, log of non-positive, overflow in exponentials, catastrophic cancellation.
  - *Dtype / precision contracts*: silent upcasts, precision loss, categorical stored as objects.
  - *Time handling*: are timestamps in the repo's required zone/format? Risk of double-conversion or naive arithmetic across boundaries (e.g. DST)?
- **Web / API / services**: input validation at boundaries, authz on every path, error-response correctness, idempotency, injection-safe queries.
- **Systems / concurrency / performance-critical**: memory ownership, buffer bounds, allocation in hot paths, lock ordering.
- **Financial / quantitative logic**: unit consistency, rounding/precision on money, correct return/PnL conventions, no forward-looking assumptions in simulation.

(These examples are illustrative — the repo's own CLAUDE.md is the authority on which invariants are non-negotiable here.)

## Step 4: Completeness

- **Missing functionality**: TODOs, stubs, placeholder returns, commented-out code that should be implemented.
- **Missing error handling**: external calls, I/O, and untrusted inputs properly guarded.
- **Missing validation**: inputs validated at system boundaries.
- **Missing cleanup**: resources released; no leaks on error paths.
- **Consistency with codebase**: follows existing patterns, naming, imports, and paradigms rather than diverging.

## Step 5: Inefficiencies

Flag language- and domain-appropriate anti-patterns. Examples:

- **Algorithmic**: redundant recomputation without caching; quadratic work where linear is available; repeated I/O or queries in a loop that could be batched.
- **Data-heavy code**: element-wise loops where a vectorized / compiled / set-based operation exists (e.g. Python loops over DataFrames → vectorize or JIT; N+1 queries → join/batch); unnecessary copies where a view/in-place works; suboptimal dtypes (float64 where float32 suffices, object where categorical fits).
- **Resource**: unbounded accumulation; heavy modules imported at top level instead of deferred; connections/clients created per-call instead of pooled.
- **Dead code**: unused functions, variables, imports, unreachable branches.

Match each suggestion to what the detected stack actually supports — do not recommend a tool the repo doesn't use.

## Step 6: Report

Structure the audit report as:

### Critical Issues (must fix)
Wrong results, data leakage / look-ahead, security holes, broken invariants, corruption — anything that produces incorrect output or violates a repo-defined critical rule.

### High Priority (should fix)
Significant performance bottlenecks (>2× potential speedup), missing error handling for likely failure modes, memory issues.

### Medium Priority (recommended)
Code quality, minor inefficiencies, consistency improvements, edge cases for unlikely scenarios.

### Low Priority (nice to have)
Style, naming, minor readability.

For each issue:
- **File:line** — exact location.
- **Problem** — what is wrong (1-2 sentences).
- **Impact** — what goes wrong if unfixed.
- **Fix** — concrete suggestion (code snippet if helpful).

If a finding touches a surface the repo's conventions mark critical (schema, security, money, published contracts, model weights, infra), say so explicitly so the reader knows it needs the project's change-control process, not a casual edit.
