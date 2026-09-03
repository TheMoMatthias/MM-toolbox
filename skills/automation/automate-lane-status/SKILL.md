---
name: automate-lane-status
description: One pass over every lane of a parallel-session programme - what it DID, what it still OWES, what it is DOING right now, and the one column that exists nowhere else, its STATED NEXT ITEM - derived from the register, git trailers, the findings log and each session's own transcript. Costs no peer session a turn. Use when you want a status update across all running sessions, before spawning or closing a lane, when deciding what to drive next, or at the top of an automate-orchestrator check-in.
argument-hint: "(optional) lane names to report in full, or --all"
---

# automate-lane-status

**The orchestrator's tool.** It reads four sources that nobody maintains by hand, plus each
lane's own words, and produces the board `automate-orchestrator` §8 step 1 needs — **without
spending a single lane a turn.**

🔒 **A message costs the receiving lane a turn, and one that only asks for status carries no
instruction.** This is what you run *instead* of polling. Poll with this; message with intent.

```
venv/Scripts/python.exe "$HOME/.claude/skills/automate-lane-status/lane_status.py"
```

| flag | effect |
|---|---|
| *(none)* | every open row, plus every lane whose transcript moved in the last 4h |
| `--all` | every lane that ever existed on this host |
| `LANE ...` | only those lanes, in full |
| `--since N` | hours of git history to attribute (default 24) |
| `--chars N` | how much of DOING to print (default **1200**) |
| `--full` | do not truncate DOING at all |
| `--repo <path>` | run against another checkout of the bound project |

---

## §1. The column that carries the skill — STATED NEXT ITEM

🔴 **`automate-orchestrator` §7: the stated next item is "the load-bearing column, because it
is the one thing that exists nowhere else."** A board shows *landings*, not intentions. A
state file usually has no NEXT section — **measured: 4 of ~30.** The lane's own intention
lives in a message you read once and discard.

**So this tool extracts it, and GRADES the extraction**, because *"the lane said this"* and
*"a regex found a verb"* are different claims and must not read alike:

| grade | where it came from |
|---|---|
| `realign` | the `NEXT` line of the lane's most recent `/automate-realign` block — it wrote that line **for** this |
| `stated` | an explicit *"NEXT:"*, *"next I will…"*, *"then I'll…"* in its recent prose |
| `inferred` | a weaker *"I'll…"* / *"proceeding to…"* — **the weakest and by far the most common** |
| `state-file` | a `NEXT` section in the lane's own state file |

🔒 **NEXT is never truncated**, at any `--chars` setting. Cutting it is the same defect as the
DOING cap below, arriving one line lower.

🪤 **It deliberately does NOT fall back to the last commit subject.** A landing says what a
lane **DID**; using it as a next item **manufactures one where none exists** — and the entire
value of this column is that it can come up empty.

### `-- NO NAMED ITEM --` is the output you act on

When nothing is derivable the row says so loudly, and the run ends with an **ACT ON** banner
naming every such lane. That is `automate-orchestrator` §1 **rule C**: give it the next work
on the critical path, or **tell it to stay idle deliberately.** Never leave a lane silently
idle, and 🔒 **never report one as "nothing outstanding" unless it SAID so** — silence is not
that. When it does say so, that is a claim under test: reply *"run `/automate-realign` and
send me the block."*

---

## §2. Why four sources, and how each one lies

1. **the register** — the row: state, paused, owns
2. **`git log` trailers** — what the lane actually LANDED
3. **the findings log** — rows the lane RAISED that are still OPEN
4. **the lane's own transcript** — what it is doing now, in its own words

🔑 **Each is wrong in a different direction, and all four have been measured wrong:** a row
says `open` while nobody works it · a landing says a lane **was** working an hour ago, never
that it **is** · a still-open list decays toward looking **BUSY**, because nothing prunes it ·
a hand-kept roster decays toward looking **IDLE**. **Read together they disagree usefully;
read alone each of them lies.** Keep all four when you re-bind — dropping one does not make
the report shorter, it makes it confident.

---

## §3. What it cannot see — stated, because a sweep that hides its blind spots is the pattern

- **Sessions on another machine.** It reads this host's transcript store.
- **A lane resumed under a new session id** whose OLD transcript is newer on disk.
- **Intent, correctness, or whether a lane is right** about anything it says.
- 🔴 **SESSION STATE — `busy` / `idle` = turn finished / `waiting` = blocked on input.**
  **Only `ListAgents` carries that**, no transcript or register does, and
  `automate-orchestrator` §1 turns on the distinction. **Run both.**

---

## §4. Re-binding it to another project

🔴 **Everything project-specific lives in ONE block at the top of `lane_status.py`, marked
`██ PROJECT BINDINGS ██`.** Change that block and nothing else; a project path, an id pattern
or a close-bar sentence found anywhere below it is a bug in the script.

| binding | what it is | how to find it in a new repo |
|---|---|---|
| `repo` · `ref` | the checkout and the shared ref every derivation reads | never a lane's local branch — the shared ref is the programme's |
| `register` · `register_lanes_key` | the JSON with one row per lane | grep for the file the project's board reads |
| `trailer_key` | the commit trailer that attributes work to a lane | `git log --format=%B \| grep -i ':'` on recent commits |
| `findings` · `finding_row_re` · `open_state_re` | the findings log and how a row and an OPEN state look in it | read two rows and anchor on the row start |
| `transcript_store` · `transcript_prefix` | where session transcripts live, and how a directory name encodes the lane | `ls ~/.claude/projects` |
| `state_file` | optional per-lane state file, `{lane}` substituted | omit it if the project has none |
| `idle_lane_minutes` · `doing_chars` · `tail_bytes` | tuning | leave alone until a report is wrong |

🔒 **It refuses rather than reports nothing.** `check_bindings()` resolves every artefact named
above and, when one is missing, prints **`NOT BOUND TO THIS PROJECT`** with what is missing and
exits `2`. **A tool that silently produces an empty board on a repo it does not fit reads as a
quiet programme, which is the most expensive thing it could say.**

🪤 **Adopt the repo's vocabulary rather than importing this one** (`automate-orchestrator` §0):
if its lanes are `ADR`-numbered or its findings are `<AREA>-<n>`, bind those. **A parallel
numbering scheme is a second register, and two registers of one reality always diverge.**

---

## §5. After running

Report per lane: **DID / OWES / DOING / NEXT.** Then act:

- **Every lane with a named item it is not visibly working → SEND IT.** Push on the item.
  **Never park a lane that has a named item.**
- **Every lane under the ACT ON banner → give it work or stand it down deliberately.**
- **Chase only what is quiet past its own cadence**, and **ask** rather than reporting a
  stall — elapsed time cannot tell a stall from an event-cadence lane or one blocked on
  another lane. 🪤 **Try a message before any restart:** a lane blocked on an operator answer
  that never passed through you is indistinguishable from hung, and measured, every "frozen"
  lane woke on a message.

🔴 **Read a lane's FULL last message before concluding anything about it** (`--full`).
**A status tool that truncates hides exactly the reports that list open items** — which is
the defect this version exists to close: the cap used to be 340 characters, shorter than a
single realign `HEADLINE` line.
