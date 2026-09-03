# skills/automation

Skills for running a programme of parallel Claude sessions without a human in the message
path. They share one rule: **decisions travel to the orchestrator, never straight to the
operator**, because `AskUserQuestion` has no path from the answer back to a register - the
operator can only click, and the reasoning evaporates.

**Two roles, two skills each - a doctrine skill and the tool that feeds it:**

| Skill | Role | Purpose |
|---|---|---|
| [automate-orchestrator/](automate-orchestrator/) | orchestrator | Become the coordination lane: hold the board, push every lane onto its stated next item rather than polling it, decide everything outside a small reserved set, and record every operator answer where it binds. |
| [automate-lane-status/](automate-lane-status/) | orchestrator | The board itself, in one pass over every lane and **costing no peer a turn**: DID / OWES / DOING, plus the **STATED NEXT ITEM** that exists nowhere else, and an ACT ON banner for every lane that has none. |
| [automate-realign/](automate-realign/) | lane | What a *lane* runs instead of `/realign`. Same sweep and the same refusal to write work off, but it re-reads its own conversation first and emits one structured block to the orchestrator instead of asking the user a question. |
| [automate-lane-check/](automate-lane-check/) | lane | Where **this** lane stands, and the one thing it cannot know from its own context: **which rulings landed while it was busy or paused**. `--as-realign-input` emits its findings as `automate-realign` §1's artefact sweep. |

🔑 **The two tools do not overlap, and the split is deliberate.** `automate-lane-status` reads
every lane and their transcripts; `automate-lane-check` reads **one lane and no transcripts at
all**, because a lane already HAS its own context and re-deriving what it did is paying twice.
**A lane that wants the cross-lane picture should ask the orchestrator, not run the board.**

🪤 **Both tools ship a `.py` and are bound to ONE project by a block at the top of that
script.** They **refuse** with `NOT BOUND TO THIS PROJECT` on a repo they do not fit rather
than printing an empty board - an empty board reads as a quiet programme, which is the most
expensive thing either could say. See each skill's *Re-binding* section.

## Naming

Every skill here is prefixed `automate-` so the set is distinguishable at a glance from the
interactive skills in `workflow/`, which are built around asking the operator directly. Adding
one? Keep the prefix, and keep the no-`AskUserQuestion` rule - a skill in this folder that
asks the user directly breaks the pairing for every other lane.

## Installing on a new machine

The two doctrine skills are machine-agnostic: they bind to a project at run time
(`automate-orchestrator` §0) rather than at install time, so the same files work on any repo
and any host. **The two tool skills carry a bindings block in their `.py`** and must be
re-pointed once per project - each SKILL.md has the table.

- **The whole toolbox** - `install.ps1` from the repo root. It walks `skills/<category>/<skill>`
  and links each skill *flat* into `~/.claude/skills/<skill>`, which is the layout Claude Code
  reads. A new category is picked up automatically, so this folder needed no installer change.
  Links, not copies, so an edit here is live immediately.
- **Just this folder** - link (or copy) `skills/automation/<skill>/` to `~/.claude/skills/<skill>/`.
  The directory name must equal the frontmatter `name:`, or the skill does not resolve.
- **On a machine where agents may not write into `~/.claude/`** - stage a patch under
  `~/.claude/operator-patches/` and let the operator apply it. Two exist:
  `add-automate-skillset.ps1` (the doctrine pair) and `install-automate-lane-skills.ps1` (the
  two tools; it also moves the pre-rename `lane-check` / `lane-status` copies aside so they
  cannot compete with the `automate-` names).

🪤 **Prefer a link over a copy wherever the repo is present.** A copied skill diverges from this
folder silently, and then an edit here fixes nothing.

## Relationship to `workflow/realign`

`automate-realign` is a deliberate fork of `workflow/realign`, not a replacement. Use
`realign` in a solo session where the user is in the loop; use `automate-realign` in a lane
that reports to an orchestrator. **A sync of one is not a sync of the other** - they diverge
on purpose at step 4 (route, don't ask) and step 6 (the block, and never ending by stopping).
