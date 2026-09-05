# The 7 ms audit — META lane: auditing the instrument

**1 AT BAR, 0 NEAR, 1 OVER, 7 GUARDED, 5 UNMEASURABLE** across what this lane
timed — but that count is the least of it. The finding this lane exists to
produce is that **the perf suite's coverage check can see 37 of the tool's 88
interactive controls, and 1 of its 13 excuses survives contact with the code.**

Machines, so two tables can be compared:

| run | fixed 100k-sqrt loop | claude sessions |
|---|---|---|
| `perf-driver.ps1`, re-run for this audit | 153 ms | 25 |
| `audit-meta.ps1` (this lane) | 196 ms | 25 |

Both are *faster* than the 337 ms the driver records as its 2026-09-04 baseline,
so nothing below is inflated by a loaded box.

---

## Part 1 — the coverage hole

### The regex, and what it structurally cannot see

`tests/perf-driver.ps1:610`:

```
'(?m)^\$ui\.([A-Za-z]+)\.Add_(?:Click|SelectionChanged|TextChanged|KeyDown|Checked|MouseDoubleClick)'
```

Two independent blind spots, and neither is a near miss:

1. **Six event kinds out of twelve.** Measured off the source by this lane's
   driver, the handler kinds actually wired on `$ui.<name>`:

   | kind | wirings | in the regex? |
   |---|---:|---|
   | Click | 25 | yes |
   | TextChanged | 5 | yes |
   | SelectionChanged | 3 | yes |
   | Checked | 2 | yes |
   | **MouseLeftButtonUp** | **6** | **never counted** |
   | **MouseLeftButtonDown** | **3** | **never counted** |
   | **PreviewMouseLeftButtonDown** | **3** | **never counted** |
   | **PreviewKeyDown** | **2** | **never counted** |
   | **SizeChanged** | **2** | **never counted** |
   | **PreviewMouseRightButtonDown** | **1** | **never counted** |
   | **PreviewMouseLeftButtonUp** | **1** | **never counted** |
   | **LostKeyboardFocus** | **1** | **never counted** |

   19 of 54 `$ui.<name>` wirings are of a kind the regex has no alternative for.
   `MouseLeftButtonUp` / `MouseLeftButtonDown` is exactly how this UI wires its
   custom `Border`-based controls, so the blind spot lands squarely on the
   hand-built chrome rather than on anything incidental.

2. **`$ui.<name>` only.** The window also wires controls through the dictionary
   form, `$ui[$name].Add_…`, in three `foreach` loops. `\$ui\.` cannot match
   `$ui[` — these are not "missed", they are inexpressible.

Also worth recording: the `^` anchor turns out **not** to cost anything today —
every dot-form `Click`/`TextChanged`/`SelectionChanged`/`Checked` wiring happens
to sit at column 0. It is a latent trap (one indented wiring disappears
silently), not a live one.

### The true count

| population | exists | the map names | invisible |
|---|---:|---:|---:|
| `$ui.<name>.Add_*` (dot form) | **50** | 35 | **15** |
| `$ui[<name>].Add_*` (dictionary form) | **12** | 0 | **12** |
| built in code, no XAML name | **11** | 2 | **9** |
| the spawn dialog (`spawn2.xaml`) | **10** | 0 | **10** |
| `$window`-level operator gestures | **5** | 0 | **5** |
| **total interactive surface** | **88** | **37** | **51** |

`window2.xaml` carries **153** `x:Name` attributes — **141 distinct**, the other
12 being names repeated inside `DataTemplate`s, which is why a `FindName` sweep
of the window yields 141 — and `spawn2.xaml` a further 17. Of those, 50 + 12 =
**62 named controls carry a handler.** The remainder are labels, panels and
containers.

**The 15 named controls with a handler that the regex cannot see:**

`AskFree` · `CastList` · `ListFold` · `ListOpen` · `ListSort` · `ManageList` ·
`PaneDoc` · `RailClear` · `RailFold` · `RailOnlyLive` · `RailOpen` · `RailSort` ·
`Shell` · `SkillList` · `StripList`

Among them: `ManageList` carries **both** `PreviewMouseLeftButtonDown` (the tick
box and the double-click that ticks a row) **and**
`PreviewMouseRightButtonDown` (the per-row action menu) — the manager's two
primary gestures, neither visible. `ListSort`/`RailSort` are the sort controls
whose underlying rebuilds are the slowest gestures in the whole table (`sort
sessions: project` = 119.7 ms). `SkillList` commits a slash-command completion.
`AskFree`'s `PreviewKeyDown` is the Enter that **sends an answer into a live
session** — an irreversible keystroke on a control the check has never heard of.

**The 12 dictionary-form controls, none of them named anywhere in the map:**

| control(s) | wired at | what pressing it does |
|---|---|---|
| `SheetB1` `SheetB2` `SheetB3` | `sessions-window.ps1:220` | **every confirmation in the tool.** `Confirm-Action` and `Show-Notice` both render through `Show-Sheet`; these three buttons are what says yes to a relaunch that kills live sessions |
| `HdrLogon` `HdrName` `HdrLane` `HdrSaid` `HdrAge` | `:6262` | manager column sort — each fires `Update-ManagerHeaders` + `Build-Manager` (95.7 ms) |
| `MgrAll` `MgrTicked` `MgrRunning` `MgrNeeds` | `:6287` | manager filter chips — each fires `Build-Manager` (46.6–82.5 ms) |

**The 11 code-built controls (2 named, 9 invisible):**

| control | wired at | invokes |
|---|---|---|
| fold-block header (every collapsible block in the reading pane) | `:2773` | `Invoke-FoldToggle` |
| per-result scroller, wheel | `:3135` | wheel-chaining handler |
| “open its conversation →” | `:3276` | `Show-AgentDoc` |
| “← back to <parent>” | `:3580` | `Close-AgentDoc` |
| “load earlier” | `:3611` | doubles `$script:tailBytes` + `Update-Document` |
| ask arrows | `:3981` | `Invoke-AskMove` — **named** |
| answer option buttons | `:4164` | `Invoke-Answer` — **named** |
| context menu · “Open it now” | `:6188` | `Start-LaunchQueue` — **launches** |
| context menu · “Relaunch it” | `:6193` | `Invoke-RelaunchOne` — **kills** |
| context menu · “Go to its terminal” | `:6200` | `Invoke-SRJumpToSession` |
| context menu · “Settings…” | `:6207` | surface switch + `Build-Sessions` + `Show-Settings` |

Two of those nine invisible controls **launch and kill live claude sessions**.
They are the same actions as `OpenNotRunning` and `PaneRelaunch`, reached by a
right-click instead of a button, and the coverage check has no idea they exist.

**The spawn dialog (10)** — `SpDir` `SpPerm` `SpWorktree` `SpHidden` `SpBrowse`
`SpTitleBar` `SpClose` `SpCancel` `SpStart`, plus the dialog's own `KeyDown`
(`:8089`–`:8118`). `SpStart` is what actually starts a new conversation.

**`$window`-level (5)** — two `Add_PreviewKeyDown` (the sheet's Esc/Enter at
`:230`, the main hotkey map at `:8486`), `Add_SizeChanged` → `Set-Breakpoint`,
`Add_StateChanged` → `Update-Frame`, `Add_Closing`. Every keyboard shortcut in
the tool lives in one of those two handlers, and the map names neither.

### What the check actually reports

`37 wired controls: 24 measured, 13 excused` — reproduced verbatim on the fresh
run. 35 of those 37 are controls; the other 2 (`Invoke-Answer`, `Invoke-AskMove`)
are *function names* picked up by the secondary pattern, not controls. So the
sentence overstates its own reach: **it is 37 of 88, reported as if it were all
of them**, and a control added tomorrow of any of the eight uncounted kinds, or
in the dictionary form, or in code, fails nothing.

---

## Part 2 — the 13 excuses, checked against the code

**1 holds. 12 do not.**

| # | control | the excuse | verdict |
|---|---|---|---|
| 1 | `SignIn` | gesture cost is `Get-SRCredStamp`, benched | ✅ **HOLDS** |
| 2 | `Invoke-Answer` | gui2 times the screen read it waits on | ❌ times work the click does not do |
| 3 | `Invoke-AskMove` | relay drives the parse it depends on | ❌ relay times nothing; wrong work |
| 4 | `AskFreeSend` | same path as `SendBtn`; relay covers the read | ❌ opposite path; relay times nothing |
| 5 | `SendBtn` | its gesture is a string trim | ❌ **it blocks the UI thread for ~1.3 s** |
| 6 | `PaneCompact` | same path as `SendBtn` | ⚠️ path true, inherits a wrong cost |
| 7 | `CastSend` | (no substitute named) | ⚠️ nothing measured in its place |
| 8 | `SetApply` | (no substitute named) | ⚠️ ~650 ms attributed to nothing |
| 9 | `Rescan` | its cost IS `Update-Model`, benched | ❌ covers the cheapest third |
| 10 | `PaneRelaunch` | (no substitute named) | ⚠️ nothing measured in its place |
| 11 | `PaneGoTo` | the jump suite covers it | ❌ jump-driver times nothing |
| 12 | `NewSession` | its build cost is `Build-SettingDrops` | ❌ wrong function, ~4× under |
| 13 | `PaneWorktree` | opens the same dialog as `NewSession` | ⚠️ path true, inherits #12 |

### The three that matter most

**#5 `SendBtn` — “its gesture is a string trim”.** It is not. `$ui.SendBtn.Add_Click({ Invoke-Send })`
→ `Invoke-Send` (`sessions-window.ps1:4916`) calls `Send-SRSessionInput`
**synchronously, on the UI thread**. That function (`lib/_common.ps1:2854`) does,
in order:

- `Get-SRAgentStatus -Refresh` — **spawns `claude`**, benched *in this very
  suite* at **862.7 ms**
- `Get-CimInstance Win32_Process` for the target pid
- `[SRCon]::Send(...)`
- **`Start-Sleep -Milliseconds 400`** — a hard, unconditional sleep
- `[SRCon]::SendKeys(...)`

So the window is frozen for roughly **1.3 seconds** every time Send is pressed —
186× the bar — and the coverage map records that control's gesture as a string
trim. `relay-driver.ps1` contains **zero** `Stopwatch` calls (verified by grep),
so nothing anywhere times it.

**#2/#3/#4 the three ask controls — the excuse names the wrong thread.**
`Invoke-Answer`, `Invoke-AskMove` and `Invoke-AskTyped` (behind `AskFreeSend`)
all funnel into `Start-AskSend` (`:4375`), which does **not** read the screen on
the UI thread — it creates a **runspace** and hands the read to it. The click
therefore never waits on the 66 ms screen read gui2 times; it waits on runspace
construction, and nothing measured that. This lane did:

| | best | med | p90 |
|---|---:|---:|---:|
| `CreateRunspace` + `Open` + `SetVariable`×2 + `[powershell]::Create` + `AddScript` | **19.41 ms** | 21.40 | 27.94 |

`OVER` — 2.8× the bar, on the most consequential gesture in the window. And the
work gui2 *does* time (66 ms) is gated there at **250 ms**, 36× the bar; that
gate cannot detect a 7 ms-relevant regression even in the thing it watches.
`AskFreeSend` compounds it: its excuse says “same path as `SendBtn`”, but
`SendBtn` is synchronous and `AskFreeSend` is asynchronous — they are the two
opposite shapes, and one excuse cannot describe both.

**#12 `NewSession` — the named substitute is a different control.**
`$ui.NewSession.Add_Click({ Show-Spawn })`. `Show-Spawn` (`:7980`) reads
`spawn2.xaml` off disk, `[xml]`-parses it, runs `XamlReader.Load`, resolves 17
`FindName`s and merges the window's resource dictionary — **all before**
`ShowDialog`. `Build-SettingDrops` fills three combo boxes on the *settings panel
of the work surface*; it is not on this path at all.

| | best | med | p90 |
|---|---:|---:|---:|
| `Show-Spawn` up to (never including) `ShowDialog` | **13.38 ms** | 15.94 | 24.12 |
| `Build-SettingDrops` — what the map names instead | 3.50 ms | 7.20 | 11.59 |

### The rest, briefly

- **#9 `Rescan`** — “its cost IS `Update-Model`”. The handler also runs
  `Save-RegistryOrAsk` (a full registry **write**) and **`Invoke-SRRescan`** (a
  scan of every project directory), then `Update-Model -KeepAgents` (505.5 ms) +
  `Update-Surface` (143.5 ms) + `Start-LiveProbe`. `Invoke-SRRescan` appears
  **0 times** in `perf-driver.ps1`; `Save-SRRegistry` appears **0 times**.
- **#11 `PaneGoTo`** — `jump-driver.ps1` contains **zero** timing calls
  (verified by grep). It asserts correctness. `Invoke-SRJumpToSession` is timed
  nowhere in the repo.
- **#7 `CastSend`, #8 `SetApply`, #10 `PaneRelaunch`** — the map's own stated
  rule is that an excused control has “the work they do beforehand measured
  instead”. These three name no substitute at all. `SetApply` is the costly one:
  after its save it runs `Update-Model -KeepAgents` + `Update-Surface` +
  `Start-LiveProbe` — about **650 ms** that is on the table under other names and
  attributed to no control.

### And one that is counted among the 24 *measured*

**`SaveBtn` = 'is the registry stale? (what Save checks first)'** → benched as
`Get-SRRegistryStamp`, **0.9 ms**. But the handler is `Save-RegistryOrAsk`
(`:6577`), whose *first* statement is `Save-SRRegistry -Registry $script:reg` —
the whole-registry disk write — and which then runs `Build-Manager` (**95.7 ms**)
if the manage surface is up. `Save-SRRegistry` is benched **0 times**. The
description is also wrong about the order: nothing is "checked first"; the write
goes first and the stale case is handled in the `catch`. So one of the 24
"measured" controls has 100% of its work unmeasured.

### Divergence worth a line

`OpenNotRunning` and `RelaunchSessions` both call **`Get-TickedPlan -Adopt`**.
`-Adopt` *writes*: it copies live names over recorded ones and sets
`$script:dirty`. The suite benches the bare `Get-TickedPlan`. The cost gap is a
string compare per live row — immaterial — but the benched call is not the
called call, and that is the kind of drift the coverage check exists to stop.

---

## Part 3 — re-scoring at 7.0 ms

`$LIMITS` has `GESTURE = 50.0` and `INSTANT = 50.0`. Re-scoring the suite's own
run (2026-09-05, 299 conversations across 30 projects, 153 ms spin, 25 claude
sessions) against the 7.0 ms bar, with nothing changed but the number:

| bar | GESTURE + INSTANT operations failing | of which newly |
|---|---:|---:|
| 50.0 ms (today) | 21 of 79 | — |
| 16.0 ms (one frame) | 41 of 79 | +20 |
| **7.0 ms (the bar)** | **49 of 79** | **+28** |

**28 operations that pass today would fail at a 7.0 ms bar; 49 of 79 gesture and
instant operations are over it; 30 are at or under it.**

The 28 that flip from green to red, in order:

```
 46.6  GESTURE  filter manager: needs
 42.0  GESTURE  the text-size control (resources + list + redraw)
 41.7  GESTURE  filter sessions by band
 39.1  GESTURE  select a conversation (COLD - the click)
 34.5  GESTURE  search: sessions box only
 34.4  GESTURE  sort rail: name
 32.9  GESTURE  sort rail: recent
 32.2  GESTURE  sort rail: busiest
 31.2  GESTURE  Build-Rail
 30.9  GESTURE  sort rail: waiting
 28.9  INSTANT  Get-Title for every conversation
 28.4  GESTURE  filter rail to running only
 26.0  GESTURE  inside: New-SRTint x100
 25.6  GESTURE  Update-Document (the gesture - kicks the parse)
 24.2  GESTURE  load earlier (double the tail)
 21.5  GESTURE  toggle the steps view (the redraw half)
 19.2  INSTANT  Get-Band
 18.7  GESTURE  search: rail box only
 16.8  GESTURE  open everything not running (up to the launch)
 16.6  GESTURE  Get-TickedPlan
 14.5  INSTANT  draw a pending question
 13.4  INSTANT  Get-ProjectAccent (cold cache)
 11.9  GESTURE  inside: New-ReadText x100
 10.6  GESTURE  fold runs of tool calls into turns
  9.0  GESTURE  inside: Get-TrackedText x100
  8.2  INSTANT  Update-LiveWriters (every 6 s)
  8.0  GESTURE  open a run block (the lazy build a click pays)
  7.6  INSTANT  Update-ProjectLabels
```

The 21 already failing at 50 ms are unchanged (`build the FlowDocument` 196.9,
`sort sessions: project` 119.7, `Set-Surface manage` 101.0, `Build-Sessions`
97.7, `Build-Manager` 95.7, … down to `filter manager: running` 53.1).

Two notes for the re-tier, from the numbers rather than from preference:

- `INSTANT` and `GESTURE` are the same 50.0 today, so the class distinction
  carries no information. Five of the 28 newly-failing rows are `INSTANT`,
  including `Get-Title for every conversation` at 28.9 ms, which runs on a
  **6-second timer** — over the bar on every tick.
- Nothing in the `QUICK`/`SLOW` classes was re-scored here (the lead's Part 3
  named `GESTURE` and `INSTANT`), but `build AND lay out the document` at
  **519.4 ms** is described in the driver itself as "the pane is unresponsive
  for 519 ms shortly after a selection". Deferred is not free.

---

## Part 4 — the four lifecycle controls, `GUARDED`

🔴 **None of these four handlers was invoked. Not once.** Every figure below is
the work the handler does *before* its irreversible step, and the "what was
timed" column names the exact function. Best of 15, `[Diagnostics.Stopwatch]`,
on the machine recorded at the top (196 ms spin, 25 live claude sessions).

| control | handler | what pressing it does | best | med | p90 | verdict | what was timed instead |
|---|---|---|---:|---:|---:|---|---|
| `SignIn` | `Click` | opens a terminal for `claude auth login`, then arms a watcher that **relaunches ticked sessions** | **1.58** | 2.48 | 3.66 | `GUARDED` | `Get-SRCredStamp` — one file stat. This is genuinely all of it. |
| `OpenNotRunning` | `Click` | **launches** every ticked conversation that is not running | **15.63** | 18.93 | 22.50 | `GUARDED` | `Get-TickedPlan` + `Limit-ToCap` + `Get-Title` per row — everything up to `Confirm-Action` |
| `RelaunchSessions` | `Click` | **kills** every ticked running session, then reopens them | **19.77** | 25.25 | 34.65 | `GUARDED` | `Get-TickedPlan` + two `Limit-ToCap` + `Get-Title` over the restart / fresh / busy sets |
| `NewSession` | `Click` | opens a modal that `ShowDialog` never returns from without a human | **13.38** | 15.94 | 24.12 | `GUARDED` | `Show-Spawn` up to (never including) `ShowDialog`: `XamlReader.Load` of `spawn2.xaml` + 17 `FindName` + resource merge |

Component breakdown, so the lead can see where each one's time sits:

| component | best | med | p90 | verdict |
|---|---:|---:|---:|---|
| `Get-TickedPlan` (read-only form of the handler's `-Adopt`) | 15.86 | 19.30 | 24.96 | `OVER` |
| `Limit-ToCap` on the fresh set | 0.30 | 0.36 | 0.85 | `AT BAR` |
| `Get-LaunchBlock` for one row | 1.61 | 2.20 | 3.39 | `AT BAR` |
| `Get-SRCredStamp` | 1.58 | 2.48 | 3.66 | `AT BAR` |
| `Build-SettingDrops` (the map's substitute for `NewSession`) | 3.50 | 7.20 | 11.59 | `AT BAR` |
| `Start-AskSend` runspace spin-up (before `BeginInvoke`) | 19.41 | 21.40 | 27.94 | `OVER` |

**What dominates each:**

- `OpenNotRunning` and `RelaunchSessions` are **`Get-TickedPlan` and nothing
  else** — 15.86 of 15.63/19.77 ms. It walks all 299 conversations, calling
  `Get-LaunchBlock` (which does a `Test-Path` on the directory *and* a
  `Get-SRTranscriptPath` + `Test-Path` on the transcript) for every non-running
  one. That is **two disk stats per conversation on a click**, and it is why a
  plan costs 16–20 ms. `Limit-ToCap` and the name-joining are noise beside it.
- `NewSession` is **`XamlReader.Load`** — parsing a XAML document and
  instantiating its visual tree, plus one `Get-Content` off disk. 13.38 ms is
  the floor for building a window from markup at click time.
- `SignIn` is one `Get-Item().LastWriteTimeUtc`. It is the only one of the four
  whose pre-step is genuinely at the bar.

---

## What a click should not be paying for

1. **`Get-TickedPlan` stats the disk twice per conversation.** `Get-LaunchBlock`
   (`:6384`) runs `Test-Path` on the cwd and `Get-SRTranscriptPath` +
   `Test-Path` on the transcript, for every conversation that is not running.
   Over 299 conversations that is the whole 16 ms, on a gesture, and it happens
   again on every press.
2. **`SendBtn` spawns `claude` on the UI thread and then sleeps 400 ms.**
   `Send-SRSessionInput` calls `Get-SRAgentStatus -Refresh` (862.7 ms in this
   suite's own table) before it types anything, then `Start-Sleep 400`. Both are
   inline in the click.
3. **Pressing an answer option builds a PowerShell runspace on the UI thread**
   (19.41 ms). The read it is spun up for was correctly moved off-thread; the
   spin-up itself was not.
4. **`NewSession` parses XAML off disk at click time** (13.38 ms). The dialog is
   rebuilt from markup on every press.
5. **`Get-Title for every conversation` (28.9 ms) runs on a 6-second timer** —
   over the bar 10 times a minute, forever, whether or not anything changed.

---

## What could not be measured, and what would make it measurable

| control | why | what would fix it |
|---|---|---|
| `Confirm-Action` / `Show-Sheet` (`SheetB1/2/3`) | `Show-Sheet` blocks on a `DispatcherFrame` until a human answers; there is no non-blocking entry point | split the *build* of the sheet from the `PushFrame` that waits, so the build can be timed like any other panel |
| `SendBtn`, `CastSend`, `PaneCompact`, `AskFreeSend`, `Invoke-Answer` — end to end | the only honest measurement types into a live session | `Send-SRSessionInput` needs a `-WhatIf`/dry-run that does everything except `[SRCon]::Send`; then the 862.7 ms `Get-SRAgentStatus -Refresh` and the 400 ms sleep are attributable to the button that pays them |
| `Invoke-SRJumpToSession` (`PaneGoTo`, context-menu “Go to its terminal”) | raises a real terminal window and steals focus | it is already exercised by `jump-driver.ps1` — that suite simply needs a `Stopwatch` around the call it already makes |
| `Invoke-SRRescan` (`Rescan`) | scans and rewrites the operator's registry | it already takes `-Registry`/`-Config`/`-Dirty` parameters; pointed at a sandbox copy it is measurable today |
| `SpStart` (spawn dialog) | starts a conversation | the dialog's *construction* is timed above; only the final button is out of reach |

---

## What the lead should change in `perf-driver.ps1`

Stated as findings, not applied — this lane edits nothing.

1. **Widen the regex to every `Add_*` kind**, not a list of six, and add a second
   pattern for the `$ui[<name>]` dictionary form. That alone takes the check from
   35 controls to 62.
2. **Drop the `^` anchor** (or make it `^\s*`). It costs nothing today and will
   cost a whole control the first time someone indents a wiring.
3. **Fix the four excuses that name the wrong work** — `SendBtn`,
   `AskFreeSend`, `NewSession`, `PaneWorktree` — and give `CastSend`, `SetApply`
   and `PaneRelaunch` a named substitute or demote them to `UNMEASURABLE`.
4. **Re-point `Rescan` at `Invoke-SRRescan` and `SaveBtn` at `Save-SRRegistry`**,
   both currently benched zero times.
5. **Add `Start-AskSend`'s runspace spin-up as a first-class gesture bench.** It
   is 19.41 ms on the click path of the tool's most consequential control and
   exists in no table anywhere.
6. **Require an excuse to name a bench that exists.** Three of the thirteen point
   at `relay` and `jump`, neither of which contains a single `Stopwatch`. A
   coverage map that accepts a correctness suite as a timing substitute cannot
   tell a measured control from an unmeasured one — which is the one thing it is
   for.

---

*Driver: `tests/audit-meta.ps1`. Re-run it with the same harness the perf suite
uses (`New-GuiHarness -Driver 'audit-meta.ps1' -OutFile 'audit-meta-test.ps1'`),
then `powershell -STA -NoProfile -File <harness> -NoScan`. It launches nothing,
kills nothing, types nothing and opens no dialog.*
