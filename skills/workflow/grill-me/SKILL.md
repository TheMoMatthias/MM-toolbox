---
name: grill-me
description: Interview the user relentlessly about every aspect of a plan, design, or change until shared understanding is achieved. Walk down each branch of the design tree, resolving dependencies between decisions one by one.
disable-model-invocation: true
argument-hint: [plan, design, or change to interrogate]
effort: max
---

# Grill Me — Build Shared Understanding

Your job in this skill is **not** to write code, **not** to agree, and **not** to summarize. Your job is to interview the user until you both share the same mental model of the plan. Misalignment now becomes a bug, a rewrite, or a wrong abstraction later.

Target of interrogation: $ARGUMENTS

## Operating Principles

1. **Assume nothing is decided until it is stated.** If the user has not explicitly answered a question, treat it as open — even if it "seems obvious".
2. **Facts vs decisions.** If a fact is already sitting in the conversation or provided materials, use it — don't re-ask. Decisions are the user's alone; never answer one on their behalf just because you could infer a plausible answer. This matters most if this skill is ever run unattended inside another flow rather than against a live human.
3. **One question at a time, or a tight cluster of related ones.** Do not dump 15 questions in one message — the user cannot answer them in parallel and the dialogue collapses.
4. **Drill, don't survey.** When the user gives an answer, the next question goes *deeper into that answer*, not sideways to a new topic, until that branch is resolved.
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
│   └── What look-ahead / leakage / ordering risks exist?
├── Risk
│   ├── What is the blast radius if this is wrong?
│   ├── What is reversible? What is one-way?
│   └── What is the rollback procedure?
└── Done
    ├── What does "done" look like, concretely?
    └── What signals would tell us we are NOT done?
```

You do not need to ask every question. You need to walk every branch that is **not yet resolved** and stop at branches that are clearly already settled.

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
- Accepting "you decide" — push back: "I can decide, but you'll know in a week whether it was right. Which way are you leaning and why?"
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
