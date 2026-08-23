# CONTEXT — session-restore

The shared vocabulary for this subsystem. One sentence each, so the same word
means the same thing in the code, the commits, the UI and the conversation.

Read this before changing `sessions-gui.ps1` or `_common.ps1`. Several of the
entries exist because two names for one idea, or one name for two ideas, shipped
a bug that took an afternoon to find.

---

## The nouns

**conversation** — one Claude session: an id, a transcript (`.jsonl`), a working
directory, and whatever the tool has learned about it. The unit of everything.
Never "session" in new code, because that word is also what the OS calls a logon.

**project** — a repository. Holds conversations. Shown as a column, never as a
row: it stopped being a level of hierarchy when the tree became a table.

**lane** — `main` for a repo's own tree, plus one per git worktree. A worktree has
its OWN git index, which is why it gets its own lane and its own auto-tick
budget instead of competing with main for one.

**registry** — `sessions-registry.json`. What the tool knows: every conversation
it has discovered, its tick, its pin, its `lastSeen`, its `note`. Written
atomically under a named mutex, never half-written.

**band** — one of exactly four attention groups: **Needs you** / **Working** /
**Idle** / **Not running**. `Get-InboxBand` is the only thing that assigns one,
so the inbox's headings, the filter chips and the summary pills are the same
number by construction rather than by three functions agreeing.
*Retired alias: "bucket".* `Get-ConvBucket` partitioned conversations by the LAST
state their transcript was seen in, and 110 of 143 landed in "waiting" — one word
meaning two things on one screen. Gone.

**sort key stack** — the ordered list of columns the list is sorted by, each with
its own direction. Click a heading and it becomes the only key; shift-click and
it joins the end. "Sorted by what it needs, then newest" is a two-item stack and
reads off the headings as `STATE ↑1  WHEN ↓2`.

---

## The two views

**Inbox** — every conversation that is running or was, across every project,
grouped into bands and ordered by what it wants from you. The bands are not a
sort key and cannot be sorted away: they are what the inbox *is*.

**All** — one flat, sortable row per conversation, bounded to the last
`listDays` (7). Holds the logon tick. Nothing is hidden silently: whatever the
age window cut is counted on a row of its own at the bottom, and any search
reaches past it.

*Retired: "Projects" and "Restore".* They rendered byte-identical row sets — 195
rows, same keys, same order. One of the three views was a duplicate of another.

---

## The states, which are three different questions

**live** — a process is holding this conversation. Certain (`LIVE`, filled dot)
when a running `claude.exe` carries the id on its command line; inferred (`live`,
hollow dot) when only the transcript moved recently. NOT the same as "working".

**doing** — what that process is currently up to: waiting / working /
summarising / idle. From `claude agents --json` where there is a process to ask,
from the transcript tail where there is not.

**moved** — it has said something since you last had it on screen. The unread
dot. A conversation with no `lastSeen` baseline is NOT moved: with no baseline
there is no answer, and rendering an unknown as a yes put a dot on eleven of
eleven rows.

**stale** — not touched inside `recencyDays`. A decoration on a row, never a
reason to hide one.

**gone** — its transcript is off disk. It can never be launched, and it is marked
four ways because one mark at 11px was mistaken for something else in review.

---

## The verbs

**tick** — reopens this conversation at the next logon. Nothing else. It does not
launch anything now, and it lives on conversations only — it used to sit on
project and lane rows too, which is where "we always have to tick all the boxes"
came from.

**pin** — the hourly auto-tick roll leaves this conversation alone. Touching a
conversation pins it, which is why 128 of 143 are pinned and why the useful half
of that filter is "not pinned".

**seen** — stamped when the reading pane actually shows a conversation, or when
you jump to its terminal. Never on scroll: marking things seen because they went
past is the one way an unread mark becomes worse than none.

**jump** — find this conversation's real Windows Terminal tab and select it. One
`WindowsTerminal.exe` owns many top-level windows, so the enumeration walks all
of them; tab titles drift, so the UIA element is cached rather than the title.

**broadcast** — one message typed into several running sessions. Recipients are
chosen in the overlay and never taken from the ticks, because the tick means
logon and most ticked conversations are not running.

---

## The traps this codebase keeps walking into

**`,@()` on return.** Six instances so far, two of them shipped. `,@(...)` stops a
ONE-element array unrolling to a scalar — and makes `@(f)` at the call site an
array of one element holding everything. It only works if every caller assigns
first and wraps second, forever. **Return a plain array.** `@(...)` at the call
site handles zero, one and many.

**Case-insensitive names plus dynamic scoping.** PowerShell variable names are
case-insensitive AND name resolution walks the CALL STACK, so `foreach ($c in …)`
in any caller *is* `$C` in every callee. It emptied the palette (now `$Pal`) and
replaced a test's staged agent table (now `$StagedAgents`). Do not use
single-letter variables anywhere in this subsystem.

**The test driver shares the GUI's scope.** `tests/run-tests.ps1` APPENDS a driver
to the script rather than calling it, so `$x = …` at a driver's top level writes
the same scope the GUI keeps state in. `$live`, `$rows`, `$said` and `$byId` all
collided. `New-GuiHarness` now refuses to build a harness that shadows a
`$script:` name.

**`@($list)` on a `List[object]`** throws *Argument types do not match* on
PowerShell 5.1. Use `.Count`, `.ToArray()`, or `foreach`.

**A trigger that only animates.** A checked chip's legibility was carried
entirely by a Storyboard: `Foreground` flipped to near-black by Setter while the
pale fill behind it waited on an animation clock. Anywhere the clock does not
tick — including every off-screen render — the label was invisible. Resting
states belong in Setters; animations are for the transition.

**`e.Source` inside a template.** A routed event that crosses a template boundary
is RETARGETED, so `e.Source` on a ListBox handler is the ListBox. Always
`e.OriginalSource`.

---

## Testing

**headless** is where the bulk of the checking belongs: the window is BUILT and
never SHOWN, so nothing appears on screen and nothing takes focus. Every bug that
has actually shipped from this subsystem was a code bug that a built-but-unshown
window would have caught.

The driver **stops the clocks before staging**. A 60-second liveTimer runs in the
prefix; once the suite grew past a minute, a real probe replaced the staged
fixture mid-run and the counts moved silently underneath assertions that were
still green. There is now an assertion that the fixture is still the fixture at
the end.

**Assertions must be able to fail for the right reason.** Two in this suite could
not: one set the seen-gate stamp by hand and proved the arithmetic rather than
the path the operator takes (the path was broken); another checked that the fast
pass changed `lastActive`, which is already derived from the value it compares
against. Drive the real entry point, and start from a sentinel.

**The registry these tests run against is the operator's real one.** Restore
anything you touch.
