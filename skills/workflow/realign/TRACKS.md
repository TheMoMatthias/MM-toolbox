# Tracks and other lanes

Reached from steps 1, 3 and 4 of `realign`, whenever more than one line of work is open —
which is most of the time.

## What a track is

A **track** is an independent line of work with its own direction: a phase of a plan, a
worktree lane, a subsystem, a review thread, a question someone is waiting on.

The test is decisional, not topical: **two items are on the same track when one decision
steers both.** If a decision would steer one and leave the other untouched, they are two
tracks — and two tracks need two questions.

🪤 The failure this exists to catch: **a session with four open tracks asks about the
loudest one and carries the other three at whatever direction they were last pointed.**
Nothing is dropped, so nothing looks wrong. The drift only surfaces later, when three
tracks turn out to have been running for a day on stale intent.

## The board, grouped

One group per track. A flat list hides the thing you actually need to see — which tracks
are moving, which are waiting, and on what.

```
TRACK  <name>          owner: this session | lane <X> | unassigned
  state     moving · blocked on <what> · waiting on you · not started
  open      the items from step 1 that belong here
  next      the one thing you propose to do next on this track
  ordering  parallel · serialized behind <track>
```

Mark **parallel vs serialized** explicitly. Two tracks that touch the same files are
serialized whether or not you intended it — say which one goes first, and why.

## Questions scale with tracks, not with your patience

Run the six probes **over each track**, not once over the session as a whole. Every track
that returns something earns its own question. Three live tracks means three questions.

**Fire successive rounds.** The four-per-round cap is per `AskUserQuestion` call, not per
realignment. A round that covers two of five tracks is followed by another round — not by a
quiet decision to let the other three drift.

🔴 **A track you did not ask about is a track you decided alone.** That is correct for HOW
and never correct for WHERE.

## Other lanes

Work usually lives in more sessions than this one — worktree lanes, spawned sessions, an
agent team. Their direction is in scope: **a plan does not stop at the boundary of the
session that happens to be reading it.**

1. **Find them.** `ListAgents` for reachable sessions; the plan, run-file or register says
   which lane owns what.
2. **Name the owner** of every track on the board, including the ones this session cannot
   touch itself.
3. **Say what you will send before you send it** — on the board, in the words you will use.
   A message that changes another lane's next action is visible work, not a side effect.
4. **Send it** with `SendMessage`: the decision just made, the finding that invalidates what
   they are building on, the correction. Only what changes their next action.
5. **Re-scoping is not a message.** A lane that needs a different job gets a brief through
   `handover-and-spawn`.

### Before you message a lane

- **Never redirect a lane mid-flight on something destructive** — a migration, a deploy, a
  push, a force operation. Wait for it to land, or tell the user instead.
- **Respect file ownership.** Two lanes editing one file is the failure an ownership map
  exists to prevent; a message that hands the same file to a second lane creates it.
- **One message, not a broadcast.** Send to the lane that owns the track. Copying five lanes
  on one direction change is how a decision gets implemented five times.
- **Say what changed and what it means for them** — not your whole board. They have their own.
- **A lane that does not answer is not a lane that agreed.** Record it as sent-not-confirmed
  on the board, and do not build on the assumption that it turned.
