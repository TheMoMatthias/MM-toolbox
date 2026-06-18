---
name: reevaluate
description: Comprehensive deep-dive audit of the current pipeline state. Challenges assumptions, gathers evidence from logs/metrics/code, researches fresh approaches, and proposes a prioritized recalibration plan. Use when work feels stuck or results are plateauing.
disable-model-invocation: true
argument-hint: [optional focus area, e.g. "labeling" or "feature set"]
effort: max
---

You are performing a **Reevaluate** session — a comprehensive deep-dive to audit the current state of the AlgoTrader pipeline, challenge assumptions, and recalibrate the approach with fresh, creative, and rigorous thinking.

Optional focus area from the user: $ARGUMENTS

## Phase 1: Gather Evidence (Facts First)

Systematically collect data from ALL available sources. Launch parallel agents where possible:

1. **Training logs & metrics**: Read latest run outputs, loss curves, validation metrics, Optuna trial results
2. **Model comparison results**: Check `MachineLearning/` outputs, `run_compare.py` results, saved model metrics
3. **Pipeline config**: Current Excel/JSON config, feature set composition, labeling parameters, model architectures
4. **Recent code changes**: Run `git log --oneline -20` to understand what was recently tried and changed
5. **Data quality**: Dataset statistics, feature distributions, label balance, coverage gaps
6. **Backtest results**: Strategy performance (Sharpe, Sortino, drawdown, win rate, profit factor)
7. **Error logs**: Warnings, failures, anomalies in recent pipeline runs
8. **Charts/images**: If user provides screenshots or saved plots, analyze them visually
9. **Memory files**: Read relevant memory entries for historical context on what was tried before

Present a structured **Status Report** with: what's working, what's failing, what's stale, and where the bottlenecks are.

## Phase 2: Challenge Assumptions

Critically question every major architectural decision. For each, state the current approach, why it might be wrong, and what the alternative would be:

- **Labeling**: Are triple-barrier params appropriate for the current market regime? Is the barrier floor (0.9%) still right?
- **Event filtering**: Are vol_breakout/volume_surge/entropy the right triggers? What events are we missing?
- **Features**: Are we carrying dead weight? Missing high-signal alternatives? Is the feature count optimal?
- **Architecture**: Would a different model class better fit the problem? Are we using the right loss function?
- **Validation**: Is walk-forward/purging properly calibrated? Are we measuring the right metrics?
- **Data pipeline**: Are transforms (frac diff, EWM standardize, bounded rescale) optimal?
- **Regime handling**: Is our regime detection capturing actual market state changes?

## Phase 3: Research & Innovate

Search for fresh approaches using all available tools:

- **Web search**: Latest 2024-2026 papers on crypto ML, market microstructure, temporal models
- **Cross-domain**: Techniques from NLP, computer vision, reinforcement learning applicable here
- **Unconventional ideas**: Challenge orthodoxy — what if standard approaches are wrong for our use case?
- **Tool/library updates**: New versions of key dependencies that unlock capabilities

## Phase 4: Propose Recalibration

Deliver a **prioritized action plan**:

1. **Quick wins** (high impact, low effort) — implement these first
2. **Strategic changes** (high impact, high effort) — plan and validate carefully
3. **Things to STOP doing** — complexity to remove
4. **Experiments to run** — A/B tests, ablation studies, walk-forward comparisons

For each proposal: state the specific change, expected impact, risk, and how to validate it.

## Key Principles

- **Data-driven, not opinion-driven**: Every claim must be backed by evidence from logs, metrics, or code
- **Fresh eyes**: Pretend seeing this system for the first time — what would surprise you?
- **Intellectual honesty**: Acknowledge when something isn't working, even if it was clever
- **Pareto focus**: Find the 20% of changes that yield 80% of improvement
- **No sacred cows**: Everything is open for questioning, including fundamental architecture decisions
- **Be specific**: Not "improve features" but "replace X with Y because Z, expected impact W"

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
