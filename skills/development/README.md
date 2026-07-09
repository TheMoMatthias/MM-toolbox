# skills/development

Skills for the build-and-ship loop: implementing features, writing tests, drafting PRDs and issues.

| Skill | Purpose |
|---|---|
| [implement/](implement/) | Implement a feature from a signed spec. Drives `/tdd` at pre-agreed seams, closes out with `/code-review`, loops until DONE-WHEN. |
| [tdd/](tdd/) | Red-green TDD loop. Test-first development at pre-agreed seams; refactoring belongs to `/code-review`, not this loop. |
| [write-a-skill/](write-a-skill/) | Create new agent skills with proper structure, progressive disclosure, and bundled resources. The canonical template for adding to this repo. |
| [to-issues/](to-issues/) | Break a plan, spec, or PRD into independently-grabbable issues on the project tracker using tracer-bullet vertical slices — including the expand-contract sequencing for wide, mechanical refactors that vertical slicing can't cover. |
| [to-prd/](to-prd/) | Turn the current conversation into a PRD (aka spec) and publish it to the project issue tracker, sketching the seams to test against. |
| [prototype/](prototype/) | Build a throwaway prototype to answer a design question — a runnable terminal app for state/logic questions, or several radically different UI variations toggleable from one route. |
| [research/](research/) | Investigate a question against primary sources and capture the findings as a cited Markdown file, run as a background agent. |
| [resolving-merge-conflicts/](resolving-merge-conflicts/) | Disciplined loop for resolving an in-progress git merge or rebase conflict. Standalone. |
| [triage/](triage/) | Move incoming issues and PRs through a state machine of triage roles (needs-triage, needs-info, ready-for-agent, ready-for-human, wontfix) until they're agent-ready. |
| [wayfinder/](wayfinder/) | Plan a huge chunk of work, more than one agent session can hold, as a shared map of investigation tickets on the issue tracker — resolve them one at a time until the way to the destination is clear. |
| [setup-engineering-skills/](setup-engineering-skills/) | One-time per-repo setup: configure the issue tracker, triage label vocabulary, and domain-doc layout the other development skills assume. Run before first use of `to-issues`, `to-prd`, `triage`, or `wayfinder` in a new repo. |
