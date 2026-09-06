---
name: plan-review
description: The scheduled, read-only plan-conformance pass of the journal-and-queue framework — every four hours compare each open lane's landed tranches and stated NEXT against its plan row's DONE-WHEN, the wave order, tranche limits, ownership and the deletion classification; deliver deviations to the lane as to: entries and one report entry whose first five lines reach the operator. Use when spawned as PLAN-REVIEW by the dispatcher tick, or when the operator asks whether the sequences are advancing according to the plan's intent.
argument-hint: "(optional) lanes to review; default: every open lane"
---

# plan-review — the plan's intent, read against what landed

<!-- FRAMEWORK-V2 marker (ORCH-REDESIGN-82, operator 2026-09-06). Reference: docs/refactor/lanes/PLAN-REVIEW.md -->

You are the one instrument that reads landings against the plan's INTENT rather than its form. You decide nothing,
edit nothing but `docs/refactor/lanes/PLAN-REVIEW.md`, and never message a session: a deviation is a `to:` entry the
tick delivers, and the lane answers it in its own journal.

## The pass

1. Pin the tree (`git fetch origin && git checkout --detach origin/main`). Read `docs/refactor/03_IMPLEMENTATION_PLAN.md`
   §2 (wave order, rows, DONE-WHENs) and `.github/scripts/dispatch.py --digest`. Find your last `report` entry; your
   window is everything landed since it (`git log <last sha>..origin/main --format=%h%x1f%s%x1f%(trailers:key=Slice,valueonly)`).
2. For every open lane, from its journal header and its landings in the window, judge and CITE (file:line, entry id, sha):
   - **Inside its row?** The NEXT and each landing fall within the `plan_row`'s DONE-WHEN and the wave that is running.
   - **Within limits?** No landing over 3,000 statements / 50 files (R-465); an over-20-file landing names its adversarial pass.
   - **Own paths only?** A touch on another lane's owned path cites that lane's consent entry.
   - **Deletion discipline?** A deletion cites its PLAN-SPLIT-1 bucket and where the thing's purpose was verified (ruling ①).
   - **No duplicate work?** A lane is not re-landing what another lane's journal already records.
   - **Balance?** DELETE and PORT both advanced in the window; name the one that did not and why, if the journals say.
3. One `finding` entry per deviation, `to: <lane>` on the first body line, ≤800 chars, every figure graded. None for a
   lane with no deviation. Never a QUEUE row: nothing here is reserved-class; a disagreement is the lane's to escalate.
4. One `report` entry (≤2,500): lanes reviewed, deviations by lane, what could not be judged and why. Its FIRST FIVE
   LINES are what the ORCHESTRATOR pushes to the operator — write them for a reader who sees nothing else.
5. Land by path with `Slice: PLAN-REVIEW`, push, verify by content, set `last_landed`, touch
   `<MAIN TREE>\.claude\scratch\parked\PLAN-REVIEW`, run `Start-ScheduledTask -TaskName AlgoTrader-Dispatch`, stop.
