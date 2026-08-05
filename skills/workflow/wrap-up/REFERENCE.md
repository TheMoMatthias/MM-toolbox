# wrap-up reference

Status vocabulary and a worked example. The procedure is in [SKILL.md](SKILL.md).

## Status vocabulary

Every request and every derived item gets exactly one.

| Status | Means | Goes in section |
|---|---|---|
| `delivered` | Done and verified. Cite the evidence. | Delivered |
| `partial` | Some of it shipped. Name precisely what is missing. | Not delivered |
| `blocked` | Could not proceed. Name the blocker and what would unblock it. | Not delivered |
| `needs-decision` | Work is ready but waiting on a choice only the user can make. | Needs your decision |
| `descoped` | Dropped on purpose. Name who decided, and when. | Not delivered |
| `failed` | Attempted, did not work. Say what was learned. | Not delivered |
| `not started` | Never begun. Say why - deprioritised, forgotten, superseded. | Not delivered |

`blocked` vs `needs-decision` is the distinction that matters most in practice. `blocked` is an
external obstacle - a broken credential, an unreachable host, a failing dependency. It has an
owner other than the user. `needs-decision` is waiting on a judgment call, and if it is not
surfaced explicitly it will simply never happen. Default to `needs-decision` when a question was
asked and never answered.

## Where ledger rows come from

Two sources, and the second is the one that gets forgotten:

- **Requests** - what the user said, recovered by `scripts/session-requests.ps1`. Includes
  messages typed mid-turn, and items inherited from a compaction summary.
- **Derived items** - work that entered the session another way: a question you asked that was
  never answered, an option you offered that was never chosen, a problem you found and parked, a
  decision explicitly deferred, or something you said you "could" do. Attribute each to how it
  arose so the user can see it was never their instruction.

## Worked example

```
[4] "update all other audit skills to be more generic"
    partial - audit + audit-loop-codebase rewritten (ea4c77b); audit-loop left as the user's
    own version, unreviewed. Single-file kept against the framework's <100-line rule, at the
    user's request.

[d1] (derived - offered, never answered) normalise the CLAUDE.md filename case mismatch
    needs-decision - `.claude/CLAUDE.md` on disk vs `.claude/claude.md` in git. A `git mv`
    fixes it; it touches a file with unrelated uncommitted edits, so it needs a yes.

[d2] (derived - found while working) server cannot `git pull` MM-toolbox
    blocked - origin is set to GitHub HTTPS and the auth prompt hangs. The server therefore
    does not have any skill committed after the bundle bootstrap. Unblocks with a credential
    helper or a deploy key.
```

Note what the example does: it never marks something `delivered` on the strength of having
written it, it names who decided each descope, and it distinguishes a thing waiting on the user
from a thing waiting on the world.

## Failure modes this skill was built against

- **Recollection substituted for evidence.** After a compaction the original request wording is
  gone from context; the transcript on disk still has it. Always run the script.
- **Mid-turn messages lost.** A message typed while the model is working is recorded as a
  `queue-operation`, not as a normal user turn. Reading only the obvious entry type loses it.
- **The dirty tree misattributed.** A working tree carries pre-existing edits and, in a shared
  repo, a parallel session's work. Neither is this session's output.
- **Completion bias.** The delivered list writes itself. Everything the user actually needs -
  what is unfinished, and what is waiting on them - is in the sections that do not.
