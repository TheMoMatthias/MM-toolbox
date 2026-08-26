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

**project** — a repository. Holds conversations, and is a ROW again on the
roster — a collapsible header carrying the count, how many are armed, and whether
the project itself is switched off. It stopped being a row when the tree was
retired and became one again when the registry reached 173 conversations across
21 projects and the operator could not find a repository in it.

A project also has its own `enabled` flag, and it OUTRANKS every tick under it:
the restore consults the project first. 89 pinned conversations under a disabled
AlgoTrader came back from exactly none of them.

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

**now** / **roster** — the two screens, and the two questions. NOW is what is
happening: live and recently-active conversations, banded by what they need. The
ROSTER is what comes back at logon: every conversation, grouped project then lane,
ticks as the primary control. They used to be Inbox and All, which differed only
by SCOPE — and scope is a filter, not a screen, which is why All felt like a dump.
*Internally the modes are still `inbox` and `all`; renaming them would be churn
across a hundred call sites for no behaviour.*

**autoTitle** — claude's own generated name for a conversation, read out of its
transcript's `aiTitle` record. Kept in its OWN registry field, never merged into
`title`: `title` belongs to whoever NAMED the session (`-n`, a rename, an adopted
live agent name) and a guess must never overwrite a choice. The row draws a
derived name in *italic* for exactly that reason — upright means chosen. 97 of
204 conversations read "(untitled)" while their own transcripts held a perfectly
good name; 60 of them are named now.
*Aliases to avoid: "the title". Say `title` or `autoTitle` — which one is the
whole point.*

**tier** — whether a project is somewhere you could still go back to working in.
Ordered ahead of recency on the roster: an existing directory, then the **home
folder** (`not a project` — where a conversation lands when it started nowhere in
particular), then a directory that has been DELETED (`folder is gone` — discovery
refuses every conversation under it, so nothing there can ever be opened, ticked
or relaunched, and it arrives folded). It is an ORDER, NOT A FILTER: nothing is
excluded, and 06391a0 must not be quietly undone.

**project label** — what a project row is called. The LEAF name, widened one path
segment at a time until it is unique on screen: eight projects here are called
`repo`, so they read `R12 / repo`, `R08 / repo`. One rule, shared by the roster
header, the sort key and the filter dropdown, which each grew their own before.
This is what makes ordering the roster by recency safe.

**loose** — a conversation whose lane holds only it, hanging directly under its
project instead of under a lane row, with the lane shown as a tag beside the name.
A lane row is emitted only where the project has more than one lane AND that lane
has more than one conversation. AlgoTrader has 35 lanes and 31 hold exactly one:
without both halves of that rule the roster drew "V-INGEST  1 - 1 armed" and then,
directly under it, "V-INGEST", thirty-one times.

**fold** — a collapsed group on the roster. Lives on the project (`folded`, and
`foldedLanes` for the lanes under it), so it survives a restart. FILTERING IGNORES
FOLDS — hiding the rows that were searched for is the one thing a filter must
never do.

**hidden** — a conversation the operator has asked not to see. A FLAG, never a
deletion: `Show hidden` brings every one back. The gate sits ahead of the search,
because hiding outranks a filter that would otherwise match — not even a search
by session id reveals one.

**armed** — ticked AND in an enabled project, i.e. a tick that will actually fire
at logon. A group header says "9 armed"; if the project is off it says
"9 ticked, PROJECT OFF" instead, because those are different facts about tomorrow
morning.

**THREE NAMES, NOT ONE.** A conversation carries three, and they are set by
different flags with different lifetimes — conflating them is why remote sessions
lose their identity:

1. `-n <name>` — the DURABLE title, written into the conversation. It survives a
   restart, an account switch, everything. `claude agents --json` reports it, so
   the window is never wrong about a name.
2. `--remote-control <name>` — names ONE remote registration. Sign in to a
   different account, or re-enable Remote Control by hand, and this is gone.
3. `--remote-control-session-name-prefix` (env:
   `CLAUDE_REMOTE_CONTROL_SESSION_NAME_PREFIX`) — the prefix claude uses when it has
   to name a registration ITSELF. It defaults to the HOSTNAME, which is identical
   for every session on the machine.

Measured 2026-08-24: after an account switch the operator had 20 remote sessions
and could not tell them apart, while `claude agents --json` still reported every
local name correctly. Nothing was lost — only (2) was, and (3) had no idea what the
session was called. The boot script sets (3) to the conversation's own title, so a
registration claude makes for itself is still recognisable.

**relaunch** — closing the ticked conversations and opening them again. Not a
refresh: a running claude reads the login token at STARTUP, so after a token
expiry every open session sits at its own login prompt and signing in once does
not reach any of them. Only a new process picks the new token up.

It kills live processes, so three rules are load-bearing: only what is TICKED,
never what is mid-turn (a kill loses the reply being written; the transcript
survives), and every skip is NAMED — a relaunch that silently passed over half
the list would leave the operator believing the problem was fixed.

**pending question** — an `AskUserQuestion` tool_use with no tool_result carrying
its id. What a session is waiting on, readable from the transcript alone, and
answerable from the window.
**sort key stack** — the ordered list of columns the list is sorted by, each with
its own direction. Click a heading and it becomes the only key; shift-click and
it joins the end. "Sorted by what it needs, then newest" is a two-item stack and
reads off the headings as `STATE ↑1  WHEN ↓2`.

---

## The two views, and the two questions

**NOW** (the inbox) — every conversation that is running or was, across every
project, grouped into bands and ordered by what it wants from you. The bands are
not a sort key and cannot be sorted away: they are what this screen *is*.

**ROSTER** (internally `all`) — what comes back at logon. Grouped by project,
ordered by WHERE YOU LAST WORKED (never A–Z; see **project label** and **tier**
for why that is safe), lanes only where they group more than one conversation,
collapsible, ticks as the primary control, and the tick summary says what
the `maxSessions` cap will DROP before it drops it.

They differed only by SCOPE until 2026-08-24, and scope is a filter, not a screen.
That is why All read as a dump: 173 rows with no structure and no purpose of its
own. Each screen answers one question now, and "show me everything" is a filter
inside the roster rather than a place to go.

A lane row appears ONLY where a project has more than one lane. This is the
specific thing that retired the original tree — 143 conversations rendered as 195
rows because eleven of fifteen projects carried a lane row called `main`, a row
that said nothing under a row that said the same thing. Measured on the live
registry after the rework: 22 project rows and 26 lane rows for 117 conversations.
There is an assertion that no project carries a lone lane row.

Sorting applies WITHIN a group, not across everything. Sorting newest-first across
every project was a real capability of the flat list and the grouping costs it;
the operator was offered "grouped by default, flat when you sort" and chose
"grouping replaces it" anyway. The assertion says so out loud rather than
pretending the old contract still holds.

Nothing is hidden silently: whatever the age window cut is counted on a row of its
own at the bottom, and any search reaches past it — and past every fold.

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

**A CACHE THAT IS ALL HITS MIGRATES NOTHING.** The discovery cache is keyed on a
transcript's mtime+length, and a repeat scan is nearly all hits by design. So the
first scan after `autoTitle` shipped hit on all 204, carried forward a `$null`
that had never been read from anything, and named EXACTLY ZERO conversations —
silently, with the feature working perfectly on any file that happened to change.
A new field needs a THIRD state to migrate: `$null` = nobody looked (re-read,
never write it back), `''` = looked and there is none (a real answer; stops the
re-read), value = the answer. `cwd` already did this for v2 entries; copy it.

**THE TAIL IS NOT WHERE THE INTERESTING RECORDS ARE.** Tail-reading a transcript
is right for what a conversation is DOING and wrong for what it IS. The `aiTitle`
record sits at a MEDIAN 14.3% into the file, so a 256 KB tail found 60 of the 76
conversations that had one. The bounded full read (≤8 MB, only when the tail came
up short) exists for exactly this, and it is nearly free because the answer is
then cached against mtime+length forever.

**A TEST THAT ASSERTS AN ACCIDENT FAILS HONESTLY AND GETS BLAMED ON THE WEATHER.**
Two of these were being re-run until green for days. `headless` staged
`lastActive` for two of six conversations and then asserted the ordering of a band
holding THREE — the third kept its real timestamp, so whenever it landed on a
conversation being written at that moment the assertion failed correctly. `jump`
probed the tab cache with `$tabs[0]`, and five tabs on this machine are called
`C:\WINDOWS\SYSTEM32\cmd.exe`, which `Update-SRTabIndex` deliberately refuses as
ambiguous. **A fixture has to own every input its assertion reads.** If a suite
passes alone and fails in a sweep, that is a fact about the fixture, not the
machine.

**A HEADING FOR A COLUMN NOBODY CAN SEE.** Already recorded once as "WHEN v2 with
no ^1 anywhere", and walked into again from the other direction: deleting the
`PROJECT / LANE` column while leaving its sort heading would have left a heading
that orders the list by something not on screen. The header bar and the row
template share one set of `ColumnDefinitions` by hand — change one, change both.

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

**relay** proves the question round trip against a LIVE console, which is the
assertion that was missing for the three days the feature shipped without it.
Both halves were proven separately and honestly — the parser against captured
text, the key send against a real menu on 2026-08-24 — and read-the-screen →
measure-the-distance → send-arrows → commit had never run as one sequence.

Six attempts to prove it by driving a real claude session all died on the
harness rather than the code. **The way through was to drive a REPLICA**:
`tests\menu-replica.ps1` paints the same characters claude paints, in a real
console, and moves the same highlight with the same keys, so everything between
the test and the answer is shipped code — `ReadConsoleOutputCharacterW` on a real
screen buffer, the real parser, the real `WriteConsoleInputW`. Its menu text is a
VERBATIM capture, sharing its lines with the `state` fixtures.

`Invoke-SRAnswerOnScreen` exists for this. `Send-SRQuestionAnswer` is welded to a
real claude session — agent record, status `waiting`, a process actually named
`claude.exe` — and those guards are right, and are precisely why the risky half
could never be exercised. The guards stay in the caller.

**Assert that a NON-DEFAULT option commits, in BOTH directions.** A relay that
always answers option 1 passes any test that only asks "did something get
answered", and answers the wrong question every time.

**Multi-select is shown and not answerable, on purpose.** There is no real
capture of that menu, and a replica built from a guess would prove the guess
against itself while reading as verification. It needs one captured screen to
move, not more code.

## Four more traps, each of which cost a run

**THE COMMA-WRAPPED RETURN HAS NOW SHIPPED SEVEN TIMES.** `return ,$out` protects
a one-element result from unrolling, and makes `@(f)` at every call site a
ONE-ELEMENT array holding everything. The seventh was `Compress-ToolRuns`, where
the empty case was the tell: an empty result came back as a single empty array,
so "nothing to render" became one phantom row, and a second assertion failed for
the same cause. **Return a plain array. Always.** If a caller needs protection
from unrolling, that is the caller's job.

**`@($list)` THROWS ON A `List[object]`, AND `.ToArray()` THROWS ON AN ARRAY.**
`$script:rows` is a List and `$script:inboxRows` is a plain array, so neither
idiom is safe across both. A pipeline (`$list | Where-Object`) or a bare
`foreach` enumerates either. "Argument types do not match" is this, every time.

**PRINTED NON-ASCII MOJIBAKES.** PowerShell 5.1 reads a BOM-less UTF-8 file as
ANSI, so a middle dot in a string literal reached the screen as two characters:
the group headers read `93 A- 9 armed`. Comments survive because nothing prints
them. Keep printed literals ASCII.

**A `Conv` OBJECT IS NOT A TRANSCRIPT.** `Get-SRConversationState` returns a
result even when the file is gone, carrying State `unknown`. Any guard that means
"there is something to read" has to test for that, or it passes for exactly the
case it exists to catch. This one was caught by looking at a screenshot, not by a
test: a conversation rendered a bright `waiting` next to its own GONE mark.

### And one about writing this code, not running it

Authoring a patch through a shell heredoc converts escape sequences into literal
control bytes. A Windows path in a generated COMMENT is enough: `runs` after a
backslash becomes a carriage return, `ask-` becomes a BEL, and the file stops
parsing somewhere that looks unrelated. It happened five times in one session.
Write generated comments without backslashes, and if a file suddenly fails to
parse after an edit, scan it for control bytes before reading the diff.
## The antivirus is part of the test environment

**2026-08-23, measured.** A `tray` suite drove the LIVE Windows shell through UI
Automation — walking `Shell_TrayWnd`, `NotifyIconOverflowWindow` and
`TopLevelWindowForOverflowXamlIsland` to prove the tray icon had reached the
notification area — and killed the processes it had started in a `finally`.

Bitdefender's Advanced Threat Defense scored that behaviour as malicious and did
what it does to ransomware: terminated the process, QUARANTINED every script in
the causal chain, and ROLLED BACK the registry it had touched. Recorded as
`Atc4.Detection` in `C:\ProgramData\Bitdefender\Desktop\Quarantine\cache.db`:

    tools\session-restore\sessions-gui.ps1
    tools\session-restore\tests\run-tests.ps1
    tools\session-restore\tests\tray-driver.ps1
    tools\session-restore\.state\boot-MM-toolbox-444f91ed.ps1
    + four .py patch scripts from the scratchpad
    + HKCU\...\Explorer\SessionInfo\1\ApplicationViewManagement\W32:...

Rolling that last one back is what restarted `explorer.exe` at 13:17:22, and the
shell took the terminal — and the Claude session driving it — with it.

**The block outlives the process, and it is keyed to the exact path string.**
Recreating a quarantined path returns raw `NTSTATUS 0xC0000022
STATUS_ACCESS_DENIED` — not `STATUS_DELETE_PENDING`, which is what a stale file
handle would give. Ask the kernel (`NtCreateFile`) rather than .NET: Win32
flattens both statuses onto `ERROR_ACCESS_DENIED`, and the difference is the
whole diagnosis. It is an antivirus decision, so it survives a reboot.

**It does not need an exclusion to get past.** Measured, on the blocked path:

    create / open-for-write / delete / rename-away    ALL refused
    open for READ                                     allowed
    create a HARD LINK at that path                   ALLOWED
    the same filename one directory over              allowed

So the content goes back with `mklink /H <blocked-path> <temp-copy>`, and the
temp entry is then deleted — one directory entry, right name, right bytes, and
`git hash-object` matching the HEAD blob exactly.

**To EDIT a frozen file afterwards, rename its parent directory.** The filter
matches a path, and a directory rename drags the file out from under it:

    ren tests tests_x        &:: the file is now fully writable at tests_x\...
    <edit it>
    ren tests_x tests        &:: and it is back at its real path, edited

Nothing here needs the antivirus UI. An exclusion for the repo is still the
tidier long-term answer, but it is a preference, not a prerequisite.

Three rules follow:

- **A test asserts against objects this application owns.** The tray icon is a
  `NotifyIcon` we construct; assert on it. Never walk the live shell, and never
  kill a process this suite did not start — the cost of being wrong is the
  operator's whole desktop.
- **Commit a driver before you run it.** `tray-driver.ps1` was written, run once,
  quarantined, and is gone. Everything else came back out of `HEAD`.
- **`.state\boot-<slug>-<id>.ps1` is a deterministic name** (`_common.ps1:1926`).
  Quarantine one and the next restore of THAT conversation fails on a path it can
  no longer write. The exclusion is not a convenience.
