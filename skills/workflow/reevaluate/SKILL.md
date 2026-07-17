---
name: reevaluate
description: Comprehensive deep-dive audit of the current state of a project or system. Gathers evidence from logs/metrics/code, challenges assumptions, researches fresh approaches, and proposes a prioritized recalibration plan. Project-agnostic — it grounds in the target repo's own conventions and domain. Use when work feels stuck, results are plateauing, or you want to step back and re-plan.
disable-model-invocation: true
argument-hint: [optional focus area, e.g. "the data layer" or "the API surface"]
effort: max
---

You are performing a **Reevaluate** session — a comprehensive deep-dive to audit the current state of the project, challenge assumptions, and recalibrate the approach with fresh, creative, and rigorous thinking.

This skill is **project-agnostic**: nothing about the domain is hard-coded. First **ground yourself in the target repository** — read its `CLAUDE.md` / `AGENTS.md` / README and conventions, detect its language/stack, and identify what this project actually *does* and what "success" means for it. Everything below adapts to that ground truth. The examples given are illustrative; substitute the equivalents that exist in *this* project.

Optional focus area from the user: $ARGUMENTS

## Phase 1: Gather Evidence (Facts First)

Systematically collect data from ALL available sources. Launch parallel agents where possible. Adapt this list to whatever the project actually produces:

1. **Run outputs & metrics**: latest logs, test/CI results, benchmark numbers, evaluation metrics — whatever the project measures itself by.
2. **Comparison results**: any A/B, before/after, or candidate-vs-baseline outputs the project keeps.
3. **Configuration**: current config files, parameters, feature flags, and the composition of the thing being built.
4. **Recent changes**: `git log --oneline -20` (and open PRs/issues) to understand what was recently tried and changed.
5. **Quality/health signals**: data statistics, coverage gaps, error rates, resource usage, distribution or drift indicators — as applicable.
6. **Outcome measures**: the project's top-line results (e.g. accuracy, latency, throughput, revenue, backtest Sharpe — whichever apply here).
7. **Error logs**: warnings, failures, and anomalies in recent runs.
8. **Artifacts/visuals**: if the user provides screenshots, dashboards, or saved plots, analyze them.
9. **Memory / history**: read relevant memory entries or docs for historical context on what was tried before.

Present a structured **Status Report**: what's working, what's failing, what's stale, and where the bottlenecks are.

## Phase 2: Challenge Assumptions

Critically question every major decision. For each, state the current approach, why it might be wrong, and what the alternative would be. Pick the axes that matter for *this* project — examples across domains:

- **Core logic / correctness**: are the central algorithms/rules right for the current conditions? Any assumptions that no longer hold?
- **Inputs & preprocessing**: is the data/input handling optimal? Any leakage, bias, or ordering risk introduced upstream?
- **Design / architecture**: would a different structure or component choice better fit the problem? Are the boundaries in the right place?
- **Parameters / configuration**: are tunable values still appropriate, or calibrated to conditions that have changed?
- **Validation / evaluation**: is the measurement methodology sound? Are you measuring the right thing, and is the evaluation free of leakage or overfitting?
- **Regime / environment**: has the operating context shifted in a way the system isn't tracking?

(For a data/ML/trading project this is where labeling, feature set, walk-forward/purging, transforms, and regime detection get interrogated; for a web/API project it's schema, contracts, auth model, and scaling assumptions. Interrogate the equivalents that exist here.)

## Phase 3: Research & Innovate

Search for fresh approaches using all available tools:

- **Web / literature search**: recent papers, releases, and best-practice shifts relevant to this domain.
- **Cross-domain**: techniques from adjacent fields that could transfer.
- **Unconventional ideas**: challenge orthodoxy — what if the standard approach is wrong for this specific use case?
- **Tool/library updates**: newer versions of key dependencies that unlock capabilities.

When searching for recent work, ask for the *latest* results rather than pinning to specific years, so this stays current over time.

## Phase 4: Propose Recalibration

Deliver a **prioritized action plan**:

1. **Quick wins** (high impact, low effort) — do these first.
2. **Strategic changes** (high impact, high effort) — plan and validate carefully.
3. **Things to STOP doing** — complexity to remove.
4. **Experiments to run** — A/B tests, ablations, controlled comparisons.

For each proposal: state the specific change, expected impact, risk, and how to validate it.

## Key Principles

- **Data-driven, not opinion-driven**: every claim must be backed by evidence from logs, metrics, or code.
- **Fresh eyes**: pretend you're seeing this system for the first time — what would surprise you?
- **Intellectual honesty**: acknowledge when something isn't working, even if it was clever.
- **Pareto focus**: find the 20% of changes that yield 80% of the improvement.
- **No sacred cows**: everything is open for questioning, including fundamental architecture decisions.
- **Be specific**: not "improve X" but "replace X with Y because Z, expected impact W".

## Output Format

Structure your response as:

### Status Report
(Current state with evidence)

### Diagnosis
(What's working / failing / stale / bottlenecked)

### Assumptions Challenged
(Each assumption questioned with evidence)

### Research Findings
(New ideas from literature/web/cross-domain)

### Action Plan
(Prioritized, concrete changes with trade-off analysis)

**Wait for user alignment before implementing any changes.**
