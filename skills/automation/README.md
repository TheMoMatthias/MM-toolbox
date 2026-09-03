# skills/automation

Skills for running a programme of parallel Claude sessions without a human in the message
path. They are a matched pair and share one rule: **decisions travel to the orchestrator,
never straight to the operator**, because `AskUserQuestion` has no path from the answer back
to a register - the operator can only click, and the reasoning evaporates.

| Skill | Purpose |
|---|---|
| [automate-orchestrator/](automate-orchestrator/) | Become the coordination lane: hold the board, push every lane onto its stated next item rather than polling it, decide everything outside a small reserved set, and record every operator answer where it binds. |
| [automate-realign/](automate-realign/) | What a *lane* runs instead of `/realign`. Same sweep and the same refusal to write work off, but it re-reads its own conversation first and emits one structured block to the orchestrator instead of asking the user a question. |

## Naming

Every skill here is prefixed `automate-` so the set is distinguishable at a glance from the
interactive skills in `workflow/`, which are built around asking the operator directly. Adding
one? Keep the prefix, and keep the no-`AskUserQuestion` rule - a skill in this folder that
asks the user directly breaks the pairing for every other lane.

## Relationship to `workflow/realign`

`automate-realign` is a deliberate fork of `workflow/realign`, not a replacement. Use
`realign` in a solo session where the user is in the loop; use `automate-realign` in a lane
that reports to an orchestrator. **A sync of one is not a sync of the other** - they diverge
on purpose at step 4 (route, don't ask) and step 6 (the block, and never ending by stopping).
