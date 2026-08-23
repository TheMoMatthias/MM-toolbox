# session-restore

Bring back the Claude Code conversations **you have selected** — each with Remote
Control attached under its real name — automatically at logon, from a desktop
button, or one at a time from a control panel whenever you want them.

Nothing is tied to a particular repository. Projects are **discovered**; which of
them reopen is **your choice**.

## Quick start

**Double-click `Install Session Restore.bat` in this folder.** That is the whole
install: it registers the two scheduled tasks, creates the two desktop buttons, and
seeds the registry so the picker has something to show straight away. It does *not*
touch your PowerShell profile.

Re-run it any time — the tasks are re-registered with `-Force`, so it doubles as the
repair when a checkout moves. To remove all of it: `restore-sessions.ps1 -Uninstall`.

From then on the tool is two double-clicks:

| double-click | does |
|---|---|
| `Sessions.bat` | **the session console** — every conversation, what each last said, what is waiting on you |
| `Restore Sessions.bat` | bring back everything you ticked, in one go |
| `Enable Auto Logon.bat` | let the PC sign itself in, so the restore runs with nobody at the keyboard |

The desktop buttons point at those same files, so there is one launch path. They
pass arguments through (`Restore Sessions.bat -DryRun`) and pause only when
double-clicked, so the output stays readable. Set `SR_NOPAUSE=1` to drive them from
a script.

**One screen, one entry point.** There have been three duplicates of it over time
and all three are gone: `Select Sessions.bat` (a second name for the same panel,
removed 2026-08-22), `Sessions GUI.bat` (a second launcher for the same window),
and `select-sessions.ps1` — a hand-written terminal panel with its own painter and
key loop, retired 2026-08-23 when the window overtook it. The window does
everything the panel did and several things a console cannot: read a conversation,
reply to it, and jump to its real terminal tab. **`Sessions.bat` is the entry
point; every other file here does a different job.**

`Sessions GUI.vbs` opens the same window with no console flash at all, and is what
the Start Menu shortcut uses. `Sessions.bat` is the one to run from a terminal;
`SR_GUI_SHOW=1` keeps the console up so a startup error is on screen rather than in
`.state\restore.log`.

## The session console

`Sessions.bat` opens a single window for every conversation on the machine, across
every repo, in two views:

- **Inbox** — what is running or was, grouped by what it wants from you:
  **Needs you** / **Working** / **Idle** / **Not running**, each row carrying the
  one line that conversation last said.
- **All** — one flat, sortable row per conversation from the last `listDays` (7),
  and the logon ticks. Click a column heading to sort; shift-click to sort by one
  thing and then another.

Selecting a row opens the conversation underneath the list, with a box to reply
into it — and the reply box stays dead until what is on screen is what that session
last said, so you cannot answer something it has already moved past.

**Two independent things live on it, and confusing them is the one way to misread
the screen:**

| | |
|---|---|
| the tick `[x]` | does this reopen automatically **at logon**? |
| the key **`L`** | open this one **now**, whatever its tick says |

So a conversation you never want back at logon is still one keypress away, and
ticking something does not launch it. Nothing launches until you press `L` or `X`.

| key | does |
|---|---|
| `L` | **launch the row under the cursor now.** On a project or lane row, everything under it — confirmed by count first |
| `S` | **spawn a new named session** in that row's directory |
| `X` | launch everything ticked, skipping whatever is already open |
| `SPACE` | tick/untick (and pin, so the hourly roll leaves it alone) |
| `U` | unpin — hand the row back to the roll |
| `←` `→` | fold a project or lane away |
| `PGUP` `PGDN` | move by a full page; `HOME` `END` jump to the ends |
| the selected row | carries a full-width band, not just a `>`. A brighter foreground is not enough to find yourself in a 47-row list |
| `A` `N` | tick all / none |
| `W` | show or hide git-worktree lanes, and write it to the config |
| `/` or `F` | **find** — narrow the list by title, id, worktree or project. `ESC` clears it. Also advertised on the title line, because a key nobody can see is a key nobody presses |
| `R` | rescan — also the only thing that re-checks what is live, and always really scans |
| `ENTER` `ESC` | save the ticks / discard them |

Launching never consults the ticks, and ticking never launches. That is the
separation the whole screen is built around.

**It opens in about a second, not two.** Measured with 117 conversations: 1.94 s
from double-click to a usable screen, of which the opening scan was 679 ms cold and
329 ms warm — with nothing on screen for any of it. An hourly task already rescans,
so re-walking every transcript because you opened the panel twice in a minute buys
nothing. The scan is now skipped while the registry is fresh (`panelScanMaxAgeSeconds`,
default 300), which takes a warm open to **~1.03 s**. When the scan *is* skipped and
the list is over a minute old the header says so — a stale list is never quiet. `R`
always really scans, `-Scan` forces one, `-NoScan` never scans, and `0` restores the
old always-scan behaviour.

The other 391 ms is the liveness probe, and it stays: it is a single CIM query
already filtered to `claude.exe`, so the cost is the WMI round trip itself rather
than the work. Measured, not assumed.

**The screen repaints in place, and only the lines that changed.** Getting this
right took two passes, and the second one is the interesting half.

The first pass stopped the panel calling `Clear-Host` on every keystroke (which in
Windows Terminal pushes the old frame into scrollback instead of repainting), fixed
a chrome height that was hardcoded to 14 against a chrome that reaches 18, and made
the viewport **sticky** rather than recentring on the cursor. Two screen lines then
changed per arrow key instead of the whole frame.

It still felt like the list flew to the end on its own. It was not a positioning
bug at all — it was **latency**. Painting all 47 lines cost **89 ms**, about 190
`Write-Host` calls, so the panel managed 13 frames a second while Windows repeats a
held key **30 times a second**. Every repeat past the first sat in the console input
buffer and was drained one frame at a time *after* the finger came off the key: a
one-second press on `↓` kept the list moving for nearly three seconds. So:

- **only the changed lines are repainted** — measured **4 writes per arrow key**,
  down from ~190, and an identical frame writes nothing at all;
- **movement keys are coalesced** — everything already queued is applied, and the
  result is drawn once;
- frame time went **89 ms → ~20 ms**, inside the 33 ms key-repeat interval, so
  presses stop outrunning the screen.

### What "live" means

| mark | evidence |
|---|---|
| `LIVE` | a `claude.exe` is holding that conversation's id — certain |
| `live` | its transcript was written in the last few minutes — near certain |
| `GONE` | its transcript is no longer on disk — it can never be launched |
| blank | **no evidence**, which is not the same as "closed" |

Two probes, because neither is enough alone. Only sessions carrying `--resume <id>`
on their command line — the ones this tool launched — are visible to the first;
measured here, that was 5 of 9 running `claude.exe`. The other 3 were a bare
`claude` with a conversation picked from `/resume` afterwards, which leaves the id
nowhere on the command line. The transcript's mtime catches those, but only while
the session is actively writing; one sitting idle at its prompt looks closed.

`L` refuses on either signal, so the worst case is a refusal to open something you
could have opened — never a duplicate tab on a live conversation.

The header also reports **how many running `claude.exe` could not be matched to any
conversation**. Rather than implying `LIVE` is complete, it puts a number on the
blind spot.

`S` applies the same reasoning to a *new* session: if anything is already live in
that directory it says which, warns that they will share the tree's git index, and
makes you confirm. It is the refusal `spawn-claude-session` makes, for the same
reason — a session was once spawned onto a lane a live one had held for 73 minutes.

### Opening one by name

Type into the search box — it matches project path, worktree name, conversation
title or id — and press **Open** on the row, or **Go to** to jump to the terminal
tab it is already running in. Ticks are not consulted; opening is not a tick.

This used to be `select-sessions.ps1 -Launch <pattern>` from a shell. That script
is retired. `restore-sessions.ps1` remains the scriptable path and is what the
logon task runs — it applies exactly the same guards.

### Launches are verified, not assumed

Both the restore and `-Launch` poll the process table afterwards and report
`restored N   verified M`. Until this existed, `[ok]` meant only that `wt.exe`
started — **the tab's child is what fails**, which is how every tab in one repo
could die on a quoting bug while the restore printed success and the scheduled task
returned `0`. A session that never appears is now named, and the run exits non-zero.

## Auto-logon

The logon task cannot fire until someone signs in. `Enable Auto Logon.bat` removes
that step: power on → Windows signs in → the restore runs → the tabs are there.

```powershell
.\enable-autologon.ps1 -Status          # change nothing, just report
.\enable-autologon.ps1                  # enable (prompts, elevates)
.\enable-autologon.ps1 -LockAfterLogon  # …and lock the screen once the sessions are up
.\enable-autologon.ps1 -Disable         # undo, and delete the stored password
```

⚠️ **What it costs.** Anyone who can press the power button gets your desktop,
already signed in, with every restored conversation and its Remote Control session
attached. Disk encryption does not help — the machine unlocks itself.
`-LockAfterLogon` buys most of that back: the sessions still start, the screen still
locks a few minutes later, and Remote Control still reaches them.

**Where the password goes.** Into the **LSA private-data store** — encrypted,
readable only by SYSTEM, the same place Sysinternals Autologon puts it. It is *not*
written to `HKLM\…\Winlogon\DefaultPassword`, which is where nearly every
"enable autologon" registry snippet puts it **in plaintext**, readable by anything
running as you. If the script finds that value, it deletes it.

The password is **verified against Windows before anything is written**. A wrong one
does not fail here — it fails at the next boot, on a logon screen that cannot tell
you why.

Windows 11 hides the `netplwiz` checkbox once Hello-only sign-in is on
(`DevicePasswordLessBuildVersion = 2`); the script clears it to `0`, which is
exactly what that checkbox does. Hold **SHIFT** during boot for the normal logon
screen once.

### Optional: the repo-wide install

```powershell
git clone https://github.com/TheMoMatthias/MM-toolbox.git
cd MM-toolbox
.\install.ps1        # or double-click Install.bat
```

That does everything above **plus** links the skills and agents into `~/.claude` and
adds three shell functions. The functions are optional — skip them entirely with
`Install Session Restore.bat` above. Open a new terminal:

| command | does |
|---|---|
| `ccs` | **the control panel** — every conversation; tick what reopens, `L` to launch now |
| `ccs -List` | print the current selection as a tree, with what is live |
| `ccs -Launch RC-WORKFLOW` | launch a conversation now, ticked or not — matches title, id, worktree or project |
| `ccs -Disable E2b-python-312` | untick without the picker — matches a project path *or* a conversation title/id |
| `ccs -Enable F1-seam-wave` | tick the same way |
| `ccs -Worktrees off` | hide git-worktree lanes (`on` to show) — writes the config |
| `ccr` | restore the selected conversations, one tab each |
| `ccr -DryRun` | show what *would* come back, launch nothing |
| `ccr -All` | ignore the tick list and the cap, just this once |
| `ccr -Scan` | refresh the registry now |
| `cc` | start a correctly-**named** new session in the current directory |
| `cc "my-name" --model opus` | …with a name, plus any `claude` flags |

`.\uninstall.ps1` removes both tasks and both buttons and leaves your selections
alone — as does `restore-sessions.ps1 -Uninstall` without touching anything else.

⚠️ **The name must come first:** `cc [name] [claude flags…]`. Once a flag appears,
everything after it goes to `claude` — otherwise the *value* of a flag gets taken
as the session name (`cc --model opus` would name the session `opus`).

## Two separate questions

**What exists** and **what should reopen** are deliberately different things.

- **Discovery** scans `~/.claude/projects/` and resolves every conversation's real
  working directory. It runs hourly and at logon as a *scan-only* task that
  **launches nothing**, so work you start today appears in the picker within the
  hour with no risk attached.
- **The registry** (`sessions-registry.json`, beside these scripts) records your
  ticks. A project you untick stays shut however discoverable it is — which is how
  a finished repo stops reopening every morning.

### Projects, lanes, conversations

A **project** is a repository. Under it sit **lanes** — `main` for the repo's own
tree, and **one lane per git worktree**. Each conversation has its own tick, and the
project has a master tick above them all.

```
[x] AlgoTrader                 4/67
      main                     3/44
         [x] RC-WORKFLOW              0h
        *[x] I1-ingest-spine          0h
         [x] F1-seam-wave             1h
      worktree: D1               1/1
         [x] D1-design                0h
      worktree: bounded-contexts 0/22
```

A worktree is a **separate tree with its own git index** — that is the whole point
of one — so it gets its own lane and its own budget rather than competing with main.
Detection is the definitive marker: a linked worktree has a `.git` **file** whose
first line is `gitdir: <repo>/.git/worktrees/<name>`, which also hands back the
parent repo. Not a path pattern, so a worktree anywhere is found.

**Turning them off** hides them entirely — not listed, not restored, including any
already recorded in the registry. Three ways in, none of which needs you to open the
config file:

- press **`W`** in the picker (the footer shows the current state)
- `ccs -Worktrees off` / `ccs -Worktrees on` from a terminal
- set `includeWorktrees` in `session-restore.config.json` by hand

All three write the same setting. The file write is a targeted replacement of that
one value, so the hand-laid-out `_README` block is never reflowed, and the result is
read back and verified rather than assumed.

A project can reopen **more than one** conversation, because you routinely run
several at once. Untick the project and nothing in it reopens; untick one
conversation to drop just that slice.

### The ticks roll

The scan **recomputes** the auto-ticked set every hour, so it follows the work
rather than freezing at first discovery. **Per lane**: the newest
`autoTickPerDirectory` (3) in `main`, and `autoTickPerWorktree` (3) in *each*
worktree, among conversations active within `sessionWindowDays` (3). Anything that
drops below is unticked. Go back to an old slice and it re-ticks itself; move on and
it falls out.

Per lane, not per project — otherwise one busy lane crowds out every other, and
"one worktree per lane" stops working.

That ceiling is the whole point. Measured here: AlgoTrader had **44** conversations
inside the tracking window and **16** inside a 3-day one. Without a ceiling,
"reopen everything recent" means sixteen tabs in one repo.

### …unless you pin it

Touching a conversation in the picker **pins** it — the roll then leaves it alone
permanently, and `*` marks it in the list. Without this, the hourly scan would undo
every hand-made choice within the hour and the picker would be decorative.

A pinned-and-ticked conversation **spends part of the ceiling**, so the total per
project stays bounded however it was set. Verified: pinning a fourth conversation
in a 3-ceiling project pushed the lowest auto-ticked one out, keeping the total at
three.

`U` in the picker hands one back to the roll (`U` on a project row releases all of
its conversations). `A`, `N`, `-Enable` and `-Disable` all pin what they change,
since they are deliberate acts.

A newly discovered **project** arrives ticked if you worked in it within
`recencyDays`; the project-level tick is never auto-managed.

### Two conversations in one working tree

They share a single git index, so a bare `git commit` in either takes whatever the
other staged. The restore **warns once per tree** when it opens two or more, and the
picker flags the lane. The mitigation is `git commit -m msg -- <paths>`, not avoiding
it — you already run concurrent sessions this way.

**Main and each worktree count separately**, because they are different trees with
different indexes. Three in `main` warns; one in `main` and one in `D1` does not.

### Your tick wins

If a ticked directory has not been touched in longer than `recencyDays`, it **still
reopens** — your explicit selection beats the heuristic. The picker shows it amber,
and the restore prints `STALE` and logs it. Age is *information*, never a second
gate: one source of truth, and it is the tick.

`recencyDays` therefore only decides what arrives **pre-ticked**. It does not gate
the restore.

## Why this exists

Launching a bare `claude` while `remoteControlAtStartup` is true registers a Remote
Control session **for an empty conversation**. The remote title then falls to the
last rule in Claude Code's precedence — an auto-generated
`<hostname>-graceful-unicorn` — and a later `/resume` does **not** send the
switched-to conversation's title or history to the connected device. Your phone ends
up bound to a placeholder the terminal already walked away from.

Each abandoned placeholder is a **118-byte** transcript holding one `bridge-session`
line with an *empty* `bridgeSessionId`.

The cure is to resume first and name explicitly:

```
claude --resume <id> -n "<name>" --remote-control "<name>"
```

| flag | writes | survives? |
|---|---|---|
| `-n <name>` | a `custom-title` record (precedence rule 2) | ✅ the **conversation** keeps the name for every future resume |
| `--remote-control <name>` | names only *this* remote session (rule 1) | ❌ measured: writes no `custom-title` |

Verified on a conversation with **zero** `custom-title` records across 7,638 lines:
one restore later it had exactly one.

**No hook can set a session title.** All 31 hook events are informational or
permission-gating, so a *new* session can only be named at launch — which is what
`cc` is for.

## Guards

- **Never opens a conversation twice.** A conversation is skipped if a `claude.exe`
  is already running it (matched on `--resume <id>` in its command line) *or* if its
  transcript was written in the last 3 minutes. Complementary: a bare-started
  session carries no id, and an idle one writes nothing. Every line names *which*
  conversation, since a project can have several. The panel's `L`, `X` and
  `-Launch` go through the same two guards — one launch path, one set of rules, so
  launching by hand can never disagree with the logon restore.
- **Child-session environment is scrubbed.** A `claude` launched with
  `CLAUDE_CODE_CHILD_SESSION` inherited writes **no transcript at all**. Measured:
  env inherited → no `.jsonl` after 12 minutes; scrubbed → a real turn in 5 seconds.
- **Three distinct outcomes, never one silent green:** nothing discovered, nothing
  ticked, and nothing restorable are different problems and say so separately.
- **It logs.** At logon both tasks run hidden, so `Write-Host` reaches nobody. Every
  line also lands in `.state/restore.log`, which is trimmed to its last 2000 lines once
  it passes 512 KB — it is the file you read when the tool seems dead, and scrolling a
  year of it to find this morning is its own failure.
- **The registry is locked while it is rewritten.** The hourly scan, a restore and the
  panel all read-modify-write the same file and overlap routinely. Without a lock that is
  a plain lost update: the scan reads, you tick something and save, the scan writes its
  copy back, and your tick is gone with nothing reported. A re-entrant named mutex spans
  the whole read-modify-write; it **fails open** after 15 s rather than losing your work.
  ⚠️ It does *not* cover the panel holding a copy in memory while you browse — there the
  last writer wins, which is you, and the scan's findings are regenerated an hour later.
- **`GONE` conversations are never launched and never auto-ticked.** A transcript can be
  deleted out from under the registry. The row is kept (a tick is the operator's, not the
  scan's, to delete) but marked, excluded from the restore, and skipped by the rolling
  auto-tick so it cannot spend a lane's budget on something that can never come back.
- **`.state/` is swept on every scan.** Generated boot scripts are regenerated on demand,
  so an old one is litter. The per-session ones expire after 30 days; the new-session ones
  carry a timestamp in their name and would otherwise accumulate one per press of `S`,
  forever, so they expire after one day.

## Tests

`tests
un-tests.ps1`. Three suites, each of which exists because something shipped
broken.

| suite | |
|---|---|
| `frame` | pure geometry — 112 frames across seven window sizes, with the filter line, the staleness warning and the unattributed warning all forced on. Never taller than the window, always shows a list row, cursor always on screen |
| `paint` | its own console window, because `CursorTop` / `CursorVisible` / `KeyAvailable` mean nothing without one. Counts the painter's **writes** — 4 per arrow key against ~190 for a full repaint — and times a frame against the 33 ms key-repeat interval |
| `keys` | drives the GUI through UI Automation: `HOME`, `END`, `PAGEUP`, `PAGEDOWN`, arrows. Needs a desktop; skip with `-NoGui` |

The panel is one script ending in an interactive loop, so a harness is that script
with the loop cut off and a driver bolted on. The runner splices from the **live**
source every time, and asserts every marker — if the script changes shape the run
fails loudly instead of testing something that no longer exists.

**The launch and spawn paths are exercised for real, not just reasoned about.**
On 2026-08-22 both ran end to end against real conversations: a multi-tab launch
opened two Anonymizer sessions (`claude.exe` 13 -> 15, both resuming the right ids,
`launched 2 verified 2 skipped 1` — the skip being a genuinely missing transcript),
and a spawn through the panel's own `Invoke-SpawnNew` started a named session with
Remote Control attached (`15 -> 16`, `-n SPAWN-PROOF-… --remote-control SPAWN-PROOF-…`).
Everything opened was closed again: `claude.exe` back to 13, the count it started at.

That run also proved the `TrimEnd` fix against reality rather than in isolation.
With two sessions genuinely live in `…\Anonymizer`, the guard returns 2 for both
`…\Anonymizer` and `…\Anonymizer\`. Under the old `TrimEnd('')` the trailing-separator
form returned 0 — the guard would have failed open and waved a third session into a
tree that already had two running.

🪤 **Launching a conversation makes it the newest in its lane, so the next scan
auto-ticks it.** The test left `Anonymizer` and `ANONYMIZER` ticked. That is the roll
working as designed, and it is inert here because the Anonymizer *project* tick is
off — but it is a reminder that opening a conversation is an input to what reopens at
logon, and that only pinning makes a tick stick.

**They are calibrated, not merely written.** Reintroducing the viewport margin bug
turns `frame` red (9 failures at 90x12). Removing the comma protection from
`Build-Frame`'s return, however, left it **green** — that assertion never guarded the
unroll hazard, and the hazard itself is gone for an unrelated reason (blank lines are
a one-segment line holding an empty string, not an empty array). That is recorded in
the driver rather than quietly deleted, because the wrong lesson is "we have a test
for that". A suite that has never failed has never been shown capable of failing.

## Files

Everything lives in this folder — nothing is scattered elsewhere on the machine.

| file | |
|---|---|
| `Install Session Restore.bat` | double-click to install just this tool — tasks + buttons, no profile changes |
| `Sessions.bat` | **the entry point** — the session console. Double-clickable; the desktop button points here |
| `Sessions GUI.vbs` | the same window with no console flash — what the Start Menu shortcut uses |
| `Restore Sessions.bat` | reopen the ticked conversations without showing the panel |
| `Enable Auto Logon.bat` | self-elevating wrapper for `enable-autologon.ps1` |
| `_common.ps1` | discovery, registry, the rolling auto-tick, guards, launching — shared, so there is one copy |
| `restore-sessions.ps1` | restore · `-Scan` · `-New` · `-Install` · `-Uninstall` |
| `sessions-gui.ps1` | the window itself: markup, `$ui`, handlers |
| `gui/` | the rest of it — `gui-model` (what a conversation is) · `gui-rows` (what a row shows) · `gui-notify` (tray, toasts) · `gui-read` (reading and replying) · `gui-actions` |
| `CONTEXT.md` | the shared vocabulary, and the traps this subsystem keeps walking into |
| `enable-autologon.ps1` | auto-logon on/off, password into the LSA store — needs elevation |
| `profile.ps1` | the `cc` / `ccr` / `ccs` functions; your PowerShell profile gets a single dot-source line pointing here |
| `session-restore.config.json` | `recencyDays`, `maxSessions`, `excludePatterns` |
| `sessions-registry.json` | **your selections** (gitignored — the paths are local) |
| `.state/` | log + generated boot scripts (gitignored, regenerated) |

## Ten traps worth knowing

1. **`$PSScriptRoot` is empty while a `param()` default is evaluated** under
   `powershell.exe -File`, which is how the tasks run. Resolve the script directory
   in the body, never in a parameter default. This failed hidden, at logon, once.
2. **`Get-Command wt.exe` returns nothing.** Windows Terminal is a WindowsApps
   execution alias — a reparse point often missing from a child shell's PATH, and
   from a scheduled task's. Fall back to
   `%LOCALAPPDATA%\Microsoft\WindowsApps\wt.exe`.
3. **`& script @args` (array splatting) does not reliably bind switches.** Measured:
   `cc -DryRun --model opus` put `-DryRun` into the pass-through array and *actually
   launched claude* instead of dry-running. The wrappers splat a **hashtable**.
4. **`Start-Process -ArgumentList @(...)` joins the array with spaces and quotes
   *nothing*.** Same family as trap 3 — PowerShell does not quote on your behalf.
   Measured by dumping the receiver's argv: a project under `Trading Bot` arrived as
   `-d C:\Users\mauri\Documents\Trading` plus a stray `Bot\Python\…`, so `wt.exe`
   tried to **run** the fragment and every tab in that repo died with `0x80070002`
   while space-free repos launched fine. 🔑 The tell is that the failing command line
   in the error **starts mid-path**. A single *string* is forwarded verbatim, so
   `ConvertTo-SRArg` quotes each argument (CommandLineToArgvW rules) and the launcher
   passes one string.
5. **A conversation's `cwd` moves, and the transcript does not follow it.** Claude
   Code files a transcript under the directory the session was *created* in and
   never moves it. Deriving the folder from the *current* `cwd` therefore resolves
   to a path that does not exist, and the restore refuses the conversation as
   "transcript missing" — it quietly stops being restorable. Not exotic: the Bash
   tool's cwd persists between calls, so a session that `cd`s into a subfolder
   writes the new cwd into its own transcript. The registry now records the real
   path the scan found, and `Get-SRTranscriptPath` prefers it — but only when the
   filename matches the session id, so a stale row cannot vouch for someone else's
   transcript.
6. **`RepoRoot` used to be the cwd itself on the main lane**, which made every
   *subfolder* its own "project". Combined with trap 5, this repo appeared twice —
   once as `MM-toolbox` and once as `MM-toolbox\tools\session-restore`. A project is
   a repository, so discovery now walks up to the git root exactly as the worktree
   branch already did. Registry rows are never deleted, so a scan also **collapses**
   a conversation that exists in two projects down to one — keeping the *pinned*
   row's tick verbatim rather than OR-ing the ticks together, because a pinned row
   is an operator decision and the other is just whatever the roll last computed.

7. **A frame slower than the key-repeat interval is indistinguishable from the list
   moving on its own.** Windows repeats a held key about every 33 ms; painting a
   frame cost 89 ms. Every repeat queued and drained *after* the key came up, so a
   one-second press kept the list scrolling for three seconds and read as "it jumped
   to the end by itself" — and as the page moving rather than the cursor. Neither a
   positioning bug nor a rendering bug: a throughput one. 🔑 The tell is that the
   movement **continues after you stop pressing**. Fixed by repainting only changed
   lines (190 writes → 4) and coalescing queued movement keys.
8. **This console has no scrollback: buffer 118x48, window 118x48.** So a prompt
   printed on the row just below the panel scrolls the *entire buffer* up by one and
   leaves the cursor on the same row it started on — which means a "has the cursor
   moved?" check sees nothing while the panel has silently drifted up a line, and the
   diff then repaints nothing because it believes the screen still matches. It fired
   on every `/`, `S`, `L` and `X`. Detected now by re-reading a row that was painted
   and comparing it with what was painted there, plus a deterministic invalidation on
   every key that can print. The probe has to land on a row with **text** on it: a
   blank row still matches itself after a scroll and would vote that nothing happened.
9. **A frame measured by a constant is a frame that scrolls.** The panel reserved a
   flat 14 lines for chrome that reaches 18 once the filter line and the
   unattributed-processes warning are both up — so it wrote more lines than the
   window held and the terminal scrolled the whole picture. Together with a
   `Clear-Host` per keystroke (which in Windows Terminal pushes the old frame into
   scrollback rather than repainting) and a viewport that recentred on the cursor
   every keystroke, an arrow key looked like the list jumping and reloading. All
   three are gone: the frame is built as lines and its height derived from them, it
   is stamped over the previous frame from row 0, and the viewport is sticky. The
   first test written against the fix **caught the fix's own bug** — a `Max(3, …)`
   floor on the list height guaranteed an 18-line frame in a 14-line window. Chrome
   now sheds itself, worst line first, rather than overrunning.
10. **A `List` returned bare is unrolled by PowerShell's output stream — and an empty
   element is unrolled a second time and vanishes.** Building the frame as a list of
   lines, where a blank line is an empty array, means every blank silently
   disappears on return and the whole frame shifts up. Same family as the `,@()`
   trap: `return ,($lines.ToArray())`. Blank lines are also built as a one-segment
   line holding an empty string rather than as an empty array, so there is nothing
   for the stream to swallow in the first place.

If it ever seems to do nothing at logon, read `.state/restore.log` first.
