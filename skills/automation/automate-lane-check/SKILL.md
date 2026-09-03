---
name: automate-lane-check
description: Where does THIS lane stand - its register row, its OPEN findings, what it last landed, and WHICH RULINGS LANDED WHILE IT WAS BUSY. One lane, no transcript reading, a screenful of output, and it can emit its findings as a paste-ready automate-realign artefact sweep. Run it FIRST on resume, first on unpause, and before closing a slice.
argument-hint: "(optional) a lane name, and/or --as-realign-input"
---

# automate-lane-check

**The specialist lane's tool.** It answers four questions about *you* and stops.

```
venv/Scripts/python.exe "$HOME/.claude/skills/automate-lane-check/lane_check.py"
venv/Scripts/python.exe "$HOME/.claude/skills/automate-lane-check/lane_check.py" F5
venv/Scripts/python.exe "$HOME/.claude/skills/automate-lane-check/lane_check.py" --as-realign-input
```

| flag | effect |
|---|---|
| *(none)* | infer the lane from the worktree directory name |
| `LANE` | a named lane |
| `--as-realign-input` | emit as a paste-ready `/automate-realign` §1 block (see §3) |
| `--repo <path>` | run against another checkout |

---

## §1. RUN IT FIRST ON RESUME — the RULINGS section is why it exists

🔴 **Nothing else in a parallel programme tells a lane that a ruling landed while it was
busy.** The ledger is append-only and nobody broadcasts it. A lane heads-down for six hours,
or paused for a day, is **bound by rulings it has never read** — and it will act on a plan
made before them without ever learning that one moved its bar.

**So `RULINGS` is the load-bearing section, and it is derived, not declared:** the diff of the
ledger between *your own last landing* and the shared ref. It is the one question a lane
genuinely cannot answer from its own context, which is why this tool reads anything at all.

🔒 **Run it FIRST when you resume. FIRST when you unpause. And before any close.** Not
mid-slice out of habit — at the three moments where your picture of the programme is
guaranteed stale.

⚖️ **A ruling you dispute is not a wall.** Disputing one is correct behaviour and escalates
through the orchestrator; acting against one you never read is neither.

🪤 **When you have landed nothing yet, this section says so rather than reporting "none".**
There is no landing to diff from, so *no rulings found* would be **absence read as data** —
the exact failure the rest of this skillset exists to prevent. Read the ledger tail by hand.

---

## §2. The other three, and what it deliberately does NOT do

- **ROW** — state, owns, and the resume trigger if paused. 🔒 If you are resuming, **delete
  the pause object in the commit that resumes**; a stale pause note reads as a dead lane.
- **OPEN** — your OPEN findings *of those you raised*, each needing a disposition:
  **IN-SCOPE** (blocks your DONE-WHEN) · **ROUTED** (file it with an owner and **close
  anyway**) · **REFUTED**. **Finding it does not make it yours.**
- **LANDED** — your last commit on the shared ref, by trailer.
- **CLOSE BAR** — the project's own close conditions, and which of them is unevaluable today.

🔑 **It reads no other lane, no transcripts, and no history you already have.** A lane HAS its
own context; re-deriving what it did is paying twice for something it knows. **Output is a
screenful, on purpose.** If you want the cross-lane picture, that is the orchestrator's
`automate-lane-status`, not this.

🪤 **And it is not a realign.** It sweeps **artefacts**. Everything living in your own
conversation — a question you asked once, a *"next I'll…"* nobody tracked, a decision that
never reached a register — is **invisible here** and is `/automate-realign` §0's subject.
**Measured, every item lost was lost there.**

---

## §3. `--as-realign-input` — how the two skills compose instead of overlapping

`/automate-realign` §1 is *"sweep the artefacts — evidence, not recollection"*. **That is
exactly this tool's output**, so run it with `--as-realign-input` and paste the block in
rather than re-deriving the same four things by hand.

It emits `VERIFIED` (row + last landing, each with the command that produced it), `DEFERRED`
(your OPEN findings, with the disposition each needs), `INBOUND` (rulings that landed since
you last spoke — *silence on an inbound item reads to the sender as agreement*), `CLOSE-BAR`,
and one line that matters more than the rest:

🔴 **`UNSWEPT` — this block is §1 ONLY.** It has not read your conversation, so §0's five
lines (`UNANSWERED` · `PROMISED` · `SUPERSEDED` · `INBOUND-UNCONFIRMED` · `ORAL-ONLY`) are
still entirely yours. **Do not paste this and stop.** The block exists to save you the
artefact half so you spend the effort on the half a tool cannot do.

⚖️ **The `INBOUND` line is a prompt, not an answer.** Read each ruling, then say on that line
whether it changes your `NEXT` — that sentence is the whole point of surfacing them.

---

## §4. Re-binding it to another project

🔴 **Everything project-specific lives in ONE block at the top of `lane_check.py`, marked
`██ PROJECT BINDINGS ██`.** Change that block and nothing else; a project path, an id pattern
or a close-bar sentence found anywhere below it is a bug in the script.

| binding | what it is | how to find it in a new repo |
|---|---|---|
| `ref` | the shared ref every derivation reads | **never your own HEAD** — your HEAD is your claim, the shared ref is the programme's |
| `register` · `register_lanes_key` | the JSON with one row per lane | grep for the file the project's board reads |
| `findings` · `finding_row_re` · `open_state_re` | the findings log, how a row you raised looks, and how its STATE cell reads when open | read two rows and anchor on the row start |
| `open_dispositions` | what a lane must do with each open finding | the project's own words |
| `ledger` · `ruling_add_re` · `ruling_sort_key` · `ruling_note` | the decisions log and how a NEW entry appears in its diff | one heading form; `ADR-n`, `RFC-n`, `R-n` — whatever the repo already uses |
| `trailer_key` | the commit trailer attributing work to a lane | `git log --format=%B` on recent commits |
| `close_bar` | the bar a lane must clear to close, verbatim | the project's contract |

🔒 **It refuses rather than reports nothing.** `check_bindings()` resolves the register, the
findings log and the ledger, and when one is missing prints **`NOT BOUND TO THIS PROJECT`**
with what is missing and exits `2`. **An empty row on a repo this does not fit would read as
a lane with nothing open** — which is the most dangerous thing it could say to a lane about
to close.

🪤 **Adopt the repo's vocabulary rather than importing this one** (`automate-orchestrator`
§0). **A parallel numbering scheme is a second register, and two registers of one reality
always diverge.**

---

## §5. After running

- **Every OPEN finding leaves with a disposition.** IN-SCOPE, ROUTED, or REFUTED — routing
  one is not deferring it, and it does not block your close.
- **Every ruling in the RULINGS block gets read before you act on a pre-ruling plan.**
- **If the close bar has a condition you cannot evaluate, say which and why** — as loudly as
  the ones you cleared. A close reported against three of four conditions with the fourth
  unmentioned is indistinguishable from one against all four.
