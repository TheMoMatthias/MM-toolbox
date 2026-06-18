---
name: audit
description: Perform a comprehensive audit of code for logical correctness, completeness, errors, and inefficiencies. Use to verify implemented changes or review existing code quality.
disable-model-invocation: true
argument-hint: [file or module to audit]
effort: max
---

# Comprehensive Code Audit

Perform a rigorous audit of the specified code. The target is: $ARGUMENTS

## Step 1: Identify Audit Scope

- Read ALL files/modules specified in the arguments
- If a directory or module is specified, identify every relevant file within it
- Note the purpose and role of each file in the broader system

## Step 2: Logical Correctness

For each function and code path, verify:

- **Control flow**: Are all branches reachable? Are there unreachable code paths or missing branches?
- **Edge cases**: What happens with empty inputs, None/NaN values, zero-length arrays, single-element inputs, boundary values?
- **Off-by-one errors**: Check loop bounds, array indexing, slicing, range() calls
- **Type safety**: Are types consistent across function calls? Are there implicit type coercions that could fail?
- **Return values**: Does every code path return the expected type? Are error returns handled by callers?
- **State mutations**: Are there unintended side effects? Is shared mutable state properly managed?
- **Concurrency**: If threading/multiprocessing is used — are there race conditions, deadlocks, or missing locks?

## Step 3: Domain-Specific Correctness (Trading/ML)

- **Look-ahead bias**: Does any feature, label, or transform use future data? Check rolling windows, shifts, joins, and fill operations
- **Data leakage**: Are train/val/test splits properly purged and embargoed? Do transforms fit on training data only?
- **Timezone handling**: Are all timestamps in Europe/Berlin? Is there risk of double-conversion or naive arithmetic?
- **NaN propagation**: Do NaN values silently corrupt downstream calculations?
- **Numerical stability**: Division by zero? Log of zero/negative? Overflow in exponentials?
- **Memory**: Unnecessary copies? Unbounded accumulation? Missing garbage collection for large intermediates?

## Step 4: Completeness

- **Missing functionality**: Are there TODOs, stubs, placeholder returns, or commented-out code that should be implemented?
- **Missing error handling**: Are external API calls, file I/O, and user inputs properly guarded?
- **Missing validation**: Are function inputs validated at system boundaries?
- **Missing cleanup**: Are resources (files, connections, locks) properly released?
- **Consistency with codebase**: Does the code follow existing patterns? Are there imports, naming conventions, or paradigms that diverge from the rest of the project?

## Step 5: Inefficiencies

- **Python loops over DataFrames**: Should be vectorized or use Numba
- **Redundant computation**: Same calculation done multiple times without caching
- **Unnecessary copies**: `.copy()`, `.reset_index()`, or implicit copies where in-place would work
- **Suboptimal data types**: float64 where float32 suffices, object dtype for categorical data
- **Groupby anti-patterns**: `.apply()` with lambda where built-in aggregations exist
- **Import overhead**: Heavy modules imported at top level instead of deferred
- **Dead code**: Unused functions, variables, imports, or unreachable branches

## Step 6: Report

Structure the audit report as:

### Critical Issues (must fix)
Bugs, data leakage, look-ahead bias, correctness errors — anything that produces wrong results.

### High Priority (should fix)
Performance bottlenecks (>2x potential speedup), missing error handling for likely failure modes, memory issues.

### Medium Priority (recommended)
Code quality, minor inefficiencies, consistency improvements, missing edge case handling for unlikely scenarios.

### Low Priority (nice to have)
Style, naming, minor readability improvements.

For each issue:
- **File:line** — exact location
- **Problem** — what is wrong (1-2 sentences)
- **Impact** — what goes wrong if unfixed
- **Fix** — concrete suggestion (code snippet if helpful)
