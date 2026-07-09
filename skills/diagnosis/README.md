# skills/diagnosis

Skills for finding what's wrong and verifying what's right.

| Skill | Purpose |
|---|---|
| [diagnose/](diagnose/) | Disciplined diagnosis loop for hard bugs and performance regressions. Reproduce → minimise → hypothesise → instrument → fix → regression-test. |
| [audit/](audit/) | One-shot audit of a system or component against a checklist of failure modes. |
| [audit-loop/](audit-loop/) | Audit + iterate-until-clean. Each pass surfaces issues; the loop continues until the audit finds nothing new. |
| [audit-loop-codebase/](audit-loop-codebase/) | Codebase-wide audit loop. Wider scope than `audit-loop`. |
| [diagnosing-bugs/](diagnosing-bugs/) | Tight-feedback-loop bug diagnosis: refuses to theorise until it has one command that already reproduces the failure, then fixes with a regression test. Hands off to `improve-codebase-architecture` when the real finding is a missing test seam. |
| [code-review/](code-review/) | Two-axis review of a diff since a fixed point — Standards (repo conventions plus a Fowler smell baseline) and Spec (does it faithfully implement the originating issue/PRD) — run as parallel sub-agents so neither pollutes the other. |
