---
name: implement
description: Implement all suggested code changes, then test them to ensure correctness. Use after receiving recommendations or a plan for code modifications.
disable-model-invocation: true
argument-hint: [description of changes to implement]
effort: max
---

# Implement & Verify

You have been given a set of changes to implement. Follow this process rigorously:

## Phase 1: Understand the Changes

1. **Review the conversation context** — identify every concrete change that was suggested (code edits, new functions, refactors, config updates, etc.)
2. **List all files** that need to be modified or created
3. **Identify dependencies** between changes — determine the correct implementation order
4. If $ARGUMENTS is provided, use it as additional context: $ARGUMENTS

## Phase 2: Implement

For each change, in dependency order:

1. **Read the target file first** — understand the surrounding code and existing patterns
2. **Apply the change** using Edit (preferred) or Write (for new files only)
3. **Verify the edit took effect** — re-read the modified section to confirm correctness
4. **Check for consistency** — ensure imports, naming, and patterns match the rest of the codebase
5. Mark each change as done before moving to the next

Where the change is new behavior rather than a mechanical edit, drive it with `/tdd` at pre-agreed seams (see the `tdd` skill for what a seam is and why it must be confirmed before any test is written) instead of writing implementation and tests separately.

**Rules:**
- Follow all of the target repo's CLAUDE.md guidelines (its performance, correctness, data-invariant, timezone, and path conventions, etc.)
- Do NOT add unrelated improvements, docstrings, or refactors beyond what was specified
- If a suggested change conflicts with existing code or seems incorrect, flag it — do not silently skip it

## Phase 3: Test & Validate

After ALL changes are implemented:

1. **Syntax check** — run `python -c "import ast; ast.parse(open(r'FILE').read())"` for each modified Python file to catch syntax errors
2. **Import check** — run `python -c "import MODULE"` (or equivalent) to verify no import errors
3. **Type consistency** — verify that function signatures, return types, and call sites are consistent
4. **Run existing tests** — if tests exist for the modified code, run them
5. **Functional smoke test** — if possible, write and run a minimal test that exercises the new/changed code paths
6. **Edge cases** — consider and test boundary conditions (empty inputs, None values, zero-length arrays, etc.)

## Phase 4: Review & Report

Before considering the work done, run `/code-review` against the diff — its Standards axis (repo conventions plus the Fowler smell baseline) and Spec axis (does the diff faithfully implement what was asked) run as parallel sub-agents so neither pollutes the other. Fix what it flags, or note explicitly why a flagged item was left as-is.

Provide a concise summary:
- **Changes made**: List each file and what was changed (1 line each)
- **Tests passed**: What was validated and the results
- **Code review findings**: What `/code-review` flagged and how each was resolved
- **Issues found**: Any problems discovered during testing (and whether they were fixed)
- **Warnings**: Anything that needs manual verification or could not be automatically tested
