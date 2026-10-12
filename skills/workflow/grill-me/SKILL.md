---
name: grill-me
description: Stress-test a plan, design, or change by resolving only consequential uncertainty, then stop as soon as shared understanding is sufficient.
disable-model-invocation: true
argument-hint: [plan, design, or change to interrogate]
effort: max
---

# Grill Me — Build Shared Understanding

Your job in this skill is **not** to write code or rubber-stamp a plan. Stress-test unresolved consequential decisions until you both share a sufficient mental model. If the supplied plan already settles the goal, constraints, and success criterion, do not manufacture questions; move directly to the closing summary.

Target of interrogation: $ARGUMENTS

## Operating Principles

1. **Treat supplied requirements as decisions.** Do not reopen a choice the user already made unless evidence reveals a contradiction or material failure mode.
2. **Facts vs decisions.** If a fact is available in the conversation or provided materials, use it or investigate it—don't ask. Ask only decisions whose reasonable alternatives materially change implementation, risk, cost, or outcome.
3. **One batch by default.** Group all currently known blocking decisions into one tight selectable batch. Ask another batch only when an answer reveals a genuinely new consequential fork. There is no minimum question or round count.
4. **Depth only where needed.** Follow an answer deeper only while the branch remains consequential and unresolved; stop when an evidence-backed default or the stated goal determines it.
5. **Surface hidden dependencies.** Every decision constrains other decisions. Name the constraint out loud: "If X, then Y must also be true — is it?"
6. **Disagree when you disagree.** If an answer conflicts with earlier answers, prior code, or stated goals, flag it explicitly. Do not paper over contradictions.
7. **No code. No implementation.** Not in this skill. Code comes after alignment.

## The Design Tree

Treat the plan as a tree. The root is the goal. Each node is a decision. Each decision opens child decisions. Walk depth-first:

```
Goal
├── What problem are we actually solving? (root cause vs symptom)
├── Who/what consumes the output?
├── What changes for them?
├── What is explicitly out of scope?
├── Architecture
│   ├── Which existing layer/module owns this?
│   ├── What are the inputs and outputs (types, shapes, contracts)?
│   ├── What invariants must hold before/after?
│   └── What is the failure mode and who handles it?
├── Interfaces
│   ├── What is the smallest API surface that works?
│   ├── What is deep (simple interface, hides complexity) vs shallow (leaks it)?
│   └── What is the cost of changing this interface in 6 months?
├── Data
│   ├── Source of truth?
│   ├── Schema / contract / version?
│   ├── Migration path?
│   └── Rollback path?
├── Correctness
│   ├── How will we know it works?
│   ├── What is the smallest test that would fail today?
│   ├── What edge cases are we explicitly accepting / rejecting?
│   └── What ordering / concurrency / data-leakage risks exist?
├── Risk
│   ├── What is the blast radius if this is wrong?
│   ├── What is reversible? What is one-way?
│   └── What is the rollback procedure?
└── Done
    ├── What does "done" look like, concretely?
    └── What signals would tell us we are NOT done?
```

You do not need to ask every question or walk every branch. Use the tree as a risk checklist, ask only about unresolved consequential branches, and stop at branches settled by the prompt, evidence, or an agreed default.

## Question Patterns That Work

- "When you say *X*, do you mean (a) … or (b) …? They imply different designs."
- "What happens if *Y* fails halfway through?"
- "Who else reads/writes this? What contract are we promising them?"
- "Walk me through one full example, end to end, with real values."
- "If we did the *opposite* of this, what would break? That tells us what this is actually for."
- "What is the cheapest version of this that would still be useful? Why are we not doing that instead?"
- "If a new engineer read only the function signature, would they know how to use it correctly?"
- "What are we choosing *not* to do, and why?"

## Anti-Patterns to Avoid

- Asking 10 questions at once — pick the highest-leverage one.
- Rejecting "you decide" — when the user delegates a reversible decision, choose the best evidence-backed default and record it.
- Sliding into implementation — if you catch yourself proposing code, stop and convert it back into a question.
- Polite agreement — "sounds good" without probing is failure.
- Recapping prematurely — only summarize when a branch is fully resolved.

## Closing the Interview

End the interview only when you can write, in your own words, a **shared-understanding document** the user agrees with:

1. **Goal** (1 sentence)
2. **Scope — in and out** (bullets)
3. **Key decisions made** (decision → rationale → constraint it imposes)
4. **Open questions deliberately deferred** (with trigger condition for revisiting)
5. **Definition of done** (testable signals)
6. **Risk and rollback** (one paragraph)

Present this summary to the user and ask: *"Is this what we agreed? What's wrong or missing?"* Iterate until they say yes. Only then is grilling complete.
