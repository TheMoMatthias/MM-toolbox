# Plan template

The shape of the document `to-execution-plan` produces. Keep the headings; drop any
section that genuinely does not apply and say why rather than leaving it blank.

**Sections 1 and 2 are written and complete before section 3 is started.** The sequence is
derived from the design; a sequence drafted first silently dictates the design instead.

---

## 1. Vision

**Goal** — one sentence. What is true when this is done that is not true now.

**Requirements** — numbered `R1…Rn`, each testable. These are referenced by steps later,
so the numbering is load-bearing.

**Constraints** — what the solution may not do (budget, latency, compatibility, platform,
data residency, existing contracts it must not break).

**Non-goals** — explicitly out of scope, so nobody plans it back in.

**Gaps** — where the source was silent. Each one: the question, the default assumed, and
whether it changes the architecture. Architecture-changing gaps must be closed before
section 2 is written.

## 2. System design

**Components** — each with the one thing it owns.

**Contracts** — the interfaces between components: signatures, shapes, error cases. These
get frozen first, because they unblock parallel work.

**State** — what is persisted, where, and who may write it.

**Data flow** — the path a request or record takes, end to end.

**Rejected alternatives** — what was considered, and the reason it lost. Prevents the
plan's decisions being reopened at every step.

## 3. Sequence

A dependency-ordered list of phases. State for each **why it is here** and not earlier or
later: what it unblocks, or what risk it retires.

Mark phases that can run **in parallel**, with the file ownership that keeps them apart.

## 4. Phases

Repeat per phase.

```
### Phase <n> — <name>

OBJECTIVE     one sentence
WHY NOW       what it unblocks / what risk it retires
REQUIREMENTS  R2, R5      (which requirements this satisfies)
DEPENDS ON    phase <n>   (or: nothing)
PARALLEL WITH phase <m>   (or: nothing)
OWNS          the files/dirs this phase may modify - exclusive while it runs
DONE-WHEN     machine-checkable, for the phase as a whole
ROLLBACK      how to undo it, and the blast radius if it goes wrong
DEFAULTS      decisions pre-authorized for this phase, so it does not stall
RISKS         what could make this phase wrong, and the earliest signal
```

Then its steps:

```
#### <n>.<m> — <what changes>

DO            the concrete change, in one or two sentences
TOUCHES       exact files
DONE-WHEN     the command or observation that proves it, verbatim
NOTES         gotchas, prior art, the trap that makes this non-obvious
```

Steps are ordered. Every step leaves the system building and passing.

## 5. Execution framework

**How each step is worked.** The loop, stated once so no phase re-invents it — typically:
read the step, make the change, run its DONE-WHEN command, fix until green, commit.

**Verification** — the commands that must pass, and when: per step, per phase, before any
push.

**Definition of done for the whole plan** — the single check that says the goal in section
1 is met.

**Git workflow** — branch per phase or trunk, commit granularity, what may be pushed
without review. Follow the repo's `CLAUDE.md`; state which convention is in force.

**Session model** — one session per phase (see `handover-and-spawn`), or one session for
several. If several run at once, the ownership map from section 3 is what keeps them from
overwriting each other.

**Escalation** — when a session stops and asks rather than deciding: budget cap hit, a
DEFAULT that turns out not to hold, anything destructive or outward-facing.

## 6. Traceability

A table mapping every requirement to the steps that satisfy it. An unmapped requirement is
work nobody planned; a step mapping to no requirement is work nobody asked for.

| requirement | phase.step |
|---|---|
| R1 | 1.2, 1.3 |

## 7. Open questions

| question | default if unanswered | blocking? | resurfaces when |
|---|---|---|---|

Blocking questions go to the user before execution starts. Everything else proceeds on its
default and is revisited only when its trigger fires.
