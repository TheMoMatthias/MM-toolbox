# skills/workflow

Skills that drive the grill-spec-execute discipline and inter-session coordination.

| Skill | Purpose |
|---|---|
| [grill-with-docs/](grill-with-docs/) | Run a relentless alignment interview, sharpen terminology into `CONTEXT.md`, end with an autonomy contract. **Invoked before any non-trivial change.** Baked in: mandatory pre-grill Explore, domain-lens dispatch, cite-evidence rule, contrarian framing, end-of-grill CONTEXT.md checkpoint, an explicit facts-vs-decisions split. Delegates the actual domain-model bookkeeping to [domain-modeling/](domain-modeling/). |
| [grill-me/](grill-me/) | Lighter-weight standalone grilling without the docs cross-reference. Useful for personal-decision grilling outside a codebase. |
| [domain-modeling/](domain-modeling/) | Shared, reusable discipline for actively building and sharpening a project's domain model — challenging fuzzy terms, stress-testing scenarios, updating `CONTEXT.md` and ADRs inline. `grill-with-docs` and `improve-codebase-architecture` both run this rather than inlining their own copy. |
| [grilling/](grilling/) | The bare interview primitive — one question at a time, facts looked up vs decisions put to the human, a confirmation gate before enacting anything. Meant to be run *by other skills* (`triage`, `wayfinder`, `improve-codebase-architecture`) as an embedded step; `grill-me`/`grill-with-docs` are the richer, user-invoked front doors for a live session. |
| [handoff/](handoff/) | Compact the current conversation into a handoff document for another session/agent to resume cleanly. Redacts secrets/PII before writing. |
| [spawn-claude-session/](spawn-claude-session/) | Launch a new Claude Code session in a separate terminal (local + resumable, or cloud-driven via mobile). |
| [reevaluate/](reevaluate/) | Comprehensive deep-dive audit of the current state of a project or initiative. |
| [writing-great-skills/](writing-great-skills/) | Reference for writing and editing skills well — the vocabulary and failure modes (no-op, sprawl, negation, negative space) that make a skill predictable. Consult before adding or editing anything under `skills/`. |
| [teach/](teach/) | Teach the user a new skill or concept over multiple sessions, using the current directory as a stateful teaching workspace. |
