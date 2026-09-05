# The 7 ms audit - lane: the sessions list and the project rail

**0 AT BAR, 0 NEAR, 9 OVER, 4 GUARDED, 0 UNMEASURABLE.**

Every control in this lane that does any work is over the bar. The four that are
`GUARDED` are the fold carets, and they are guarded because they write the
operator's config; the visible half of three of them is the only thing in the
lane that is genuinely fast.

Driver: `tests/audit-list.ps1`. Best of 15, all figures in milliseconds.
Machine: a fixed 100k-sqrt loop read **16 ms** at the start and **18 ms** at the
end, with **25 claude sessions running**; 299 conversations across 30 projects,
of which 43 are on the work surface (48 rows including 5 band headings), 6
projects in the rail. Selection profiled against `RC-WORKFLOW` (193 KB of
transcript) and `MM-toolbox` (66 KB).

Four full runs were taken on identical source. `Build-Sessions` read 70.5, 79.9,
88.2 and 99.0 ms best across them with the spin loop between 14 and 16 ms - so
individual numbers move about 30% with the machine. Not one verdict moves with
them: everything here is 5x to 40x the bar.

## 🔴 Read this before reading the table

**Every rebuild figure below except the band-heading click is measured against a
list WPF has no containers realized for, and that under-reports the on-screen
cost by about 3x.** The existing perf suite measures the same way: it lays the
window out once, then benches `Build-Sessions` in a loop, and from the second
iteration on there are no containers to tear down. Same function, same rows,
only difference being a layout pass in the untimed setup:

| | best | med | p90 |
|---|---|---|---|
| `Build-Sessions`, list **not** realized (what the suite measures) | 94.5 | 125.3 | 274.8 |
| `Build-Sessions`, list **realized**, as it always is on screen | **277.7** | 323.3 | 366.1 |

That is why the band-heading click - the one control here driven through a real
routed event with the list laid out first - reads 272 ms while the identical
handler body called by hand off an unrealized list reads 36.6 ms. The routing is
not the cost (a full tunnel down the same visual tree onto a session row, where
the handler returns immediately, is 0.49 ms). The realized list is.

## The controls

One row per control. `best` is what the operator waits for, which for the three
search boxes is the debounced rebuild and not the keystroke - a debounce moves
work 180 ms later on the same thread, it does not make it free.

| control | handler | what pressing it does | best | med | p90 | verdict | what dominates |
|---|---|---|---|---|---|---|---|
| `SessionList` | `PreviewMouseLeftButtonDown` | on a band heading: filter to that band, rebuild, set the status line | 272.5 | 310.7 | 382.3 | `OVER` | one `Build-Sessions` against a realized list (277.7 on its own); the auto-reselect it forces is inside that |
| `SessionList` | `PreviewMouseLeftButtonDown` | on a session row: resolve the row, see it is not a heading, return | 0.5 | 0.6 | 15.6 | `AT BAR` | `Get-ClickedRow` walking the visual tree, 0.15 ms |
| `SessionList` | `SelectionChanged` | cold - open a different conversation | 37.8 | 54.9 | 75.6 | `OVER` | `Start-DocParse` opening a runspace on the UI thread, 24.9 of it. **Then the UI thread blocks for a further ~680 ms building and laying out the document** - see below |
| `SessionList` | `SelectionChanged` | warm - the row already selected | 0.4 | 0.5 | 1.3 | `AT BAR` | the `$same` guard returns before anything reads a file |
| `SessionList` | `SelectionChanged` | on a band heading - steps past it onto the next row | 44.6 | 56.5 | 74.2 | `OVER` | the re-entrant selection lands a full cold `Show-Selected` |
| `RailClear` | `MouseLeftButtonUp` | clear the project pick, rebuild both panes | 158.2 | 223.6 | 322.1 | `OVER` | `Build-Sessions` (99.0) + `Build-Rail` (39.9); on a realized list, ~3x that |
| `RailSearch` | `TextChanged` | restart the debounce; 180 ms later rebuild **both** panes | 145.7 | 158.3 | 170.3 | `OVER` | `Build-Sessions` (99.0), **which this box cannot change**; the keystroke itself is 0.08 |
| `ListSort` | `MouseLeftButtonDown` | cycle newest/name/project, relabel, rebuild the list | 100.2 | 128.1 | 140.2 | `OVER` | `Build-Sessions` under the new order (96.6 / 111.1 / 125.9); the relabel is 0.29 |
| `ListSearch` | `TextChanged` | restart the debounce; 180 ms later rebuild **both** panes | 83.6 | 94.9 | 113.2 | `OVER` | `Build-Sessions` (99.0) plus a `Build-Rail` (39.9) **this box cannot change**; keystroke 0.24 |
| `RailList` | `SelectionChanged` | pick/unpick a project, rebuild both panes | 79.9 | 98.6 | 217.0 | `OVER` | `Build-Sessions` then `Build-Rail` |
| `Search` | `TextChanged` | restart the debounce; 180 ms later rebuild both panes | 55.1 | 67.1 | 75.7 | `OVER` | both builds, but this box narrows the model first so both are cheaper; keystroke 0.07 |
| `RailOnlyLive` | `MouseLeftButtonDown` | toggle all/running, relabel, rebuild the rail | 43.2 | 49.1 | 53.5 | `OVER` | `Build-Rail` (39.9); the relabel is 0.19 |
| `RailSort` | `MouseLeftButtonDown` | cycle recent/name/waiting/busiest, relabel, rebuild the rail | 40.9 | 54.9 | 64.8 | `OVER` | `Build-Rail` (35.4-44.0 across the four orders) |
| `ListFold` | `MouseLeftButtonUp` | collapse the sessions column to its strip, **write the config** | 12.6 + 23.8 | 17.3 | 20.4 | `GUARDED` | `Update-Columns` incl. `Update-Strip` (12.1 on its own) **plus** `Save-SRConfigValue`, 23.8, measured on a copy |
| `RailOpen` | `MouseLeftButtonUp` | reopen the projects column, **write the config** | 0.4 + 23.8 | 0.5 | 1.0 | `GUARDED` | the write is 50x the visible half |
| `RailFold` | `MouseLeftButtonUp` | collapse the projects column, **write the config** | 0.4 + 23.8 | 0.6 | 2.3 | `GUARDED` | the write |
| `ListOpen` | `MouseLeftButtonUp` | reopen the sessions column, **write the config** | 0.4 + 23.8 | 0.5 | 0.7 | `GUARDED` | the write |

`GUARDED` names `Save-SRConfigValue`. `Invoke-ColumnFold` calls it on every one
of the four carets, so none of them was invoked. `$SR_ConfigPath` was repointed
at a temp copy of the real config, the write was timed against that, and the
path was restored and the copy deleted - verified in the driver's output. The
operator's `session-restore.config.json` was never opened for writing.

Every raise in this driver is verified by its side effect before it is timed
(`ListSort` moved recent->name, `RailOnlyLive` toggled, `RailClear` emptied
`railPick`, the heading click set `bandPick`, selecting a row set `selId`).
Without that check a raise that reaches no handler returns in 20 microseconds
and reports as the fastest control in the window - which is exactly what happens
if you raise `PreviewMouseLeftButtonDown` on a child, because it and
`MouseLeftButtonDown/Up` are **Direct** routed events, not tunnelling or
bubbling ones. The ListBox handler is driven through
`Mouse.PreviewMouseDownEvent` instead, which is the event real input travels on.

## 1. The worst three, diagnosed

### 1. `SessionList` band heading - 272 ms

It is one `Build-Sessions` against a realized list, and nothing else: the same
handler body from an unrealized list is 36.6 ms, and `Build-Sessions` against a
realized list is 277.7 ms on its own. Inside it, two things stack:

- **the rebuild itself**, whose isolable parts over 299 conversations / 43 rows
  are: the `Test-OnSurface` filter loop **18.4**, `Get-RowSubAgents` x43 **7.6**
  (warm), `Get-AgeTicks` x43 **7.5**, `Get-CtxBrush` x43 **3.4**,
  `Get-RowScreenSig` x43 **2.4**, `Sort-SessionRows` **0.7**. Those sum to
  ~40 ms of the 94.5 ms unrealized figure; the remaining ~55 ms is the per-row
  item construction (a `PSCustomObject` of ~40 properties per row, plus the
  brush and string work), which cannot be isolated without editing
  `sessions-window.ps1`.
- **the auto-reselect.** Filtering to one band drops the open conversation out
  of the list, so `Build-Sessions` selects a row for you - and that goes down
  the same cold path a click does. Measured directly: the same rebuild with the
  selection dropped is **76.0**, with the selection still present **47.6**. The
  extra ~28 ms is a transcript parse, a runspace and a `FileSystemWatcher`
  nobody asked for.

### 2. `RailClear` - 158 ms (and `RailSearch`'s tick, 146 ms)

`Build-Sessions` (99.0) + `Build-Rail` (39.9). No part of either is expensive on
its own - `Build-Rail`'s pieces are `Get-ProjectLabel` x30 **1.9**,
`Get-ProjectAccent` x30 **1.8**, the ordering `Sort-Object` **4.8** - the cost is
that both walk all 299 conversations to produce 43 rows and 6 tiles. The filter
loop is the largest single item in either function.

### 3. `ListSort` - 100 ms

Entirely `Build-Sessions` under the new order (96.6 recent / 111.1 name / 125.9
project). The label update the operator actually sees change is **0.29 ms**. The
`name` and `project` orders are dearer because `Sort-SessionRows` calls
`Get-Title` inside the sort key - but only by ~15-30 ms; the base rebuild is the
problem, not the ordering.

## 2. What a click is paying for that it should not

- **Disk, on a click, once every 20 seconds.** `Get-RowSubAgents` is called for
  every visible row and is cached for 20 s (`$SR_SubAgentTTL`), so roughly one
  rebuild in eight refreshes it - and the list rebuilds every 2.5 s. That
  rebuild costs **784.7 ms** against 88.2 ms warm. Whichever control the
  operator happens to press when the TTL expires appears to hang for the better
  part of a second, at random.
- **A runspace opened on the UI thread inside the click.**
  `Show-Selected` -> `Update-Document` -> `Start-DocParse` is **24.9 ms**, of
  which **17.4 ms** is a bare `runspacefactory` open with no work in it. That is
  2.5x the whole bar, on the most-repeated gesture in the tool, to move a parse
  off the thread it is already blocking.
- **A second runspace, in the same handler.** `Show-Selected` also calls
  `Start-LiveProbe` on a cold selection, which opens another runspace whenever
  no probe is in flight. Its comment says the opposite ("REQUESTED HERE, STARTED
  ON THE LANE") - the request is `$script:askWanted`, but the `Start-LiveProbe`
  call two lines below it is real. See "what could not be measured".
- **`Stop()` on a parse that is still running.** `Start-DocParse` stops the
  previous pipeline before starting its own, and `PowerShell.Stop()` blocks the
  caller: **26.9 ms with a parse in flight against 22.4 ms without**. Small
  here; it scales with how much transcript is left to abandon, which is exactly
  what clicking quickly through big conversations does.
- **A file write on a fold caret.** `Save-SRConfigValue` reads the config,
  parses it, re-serialises it, writes a temp file and `Move-Item`s it -
  **23.8 ms** - on the UI thread, so the caret that hides a column costs 50x
  more in persisting the preference than in moving the column.
- **Half of every search tick cannot change anything.** One `DispatcherTimer`
  serves all three boxes and its tick runs `Build-Rail; Build-Sessions`
  unconditionally. Typing in the sessions box pays a 39.9 ms `Build-Rail` that
  cannot narrow (the rail matches `HayProj`, which `ListSearch` never touches);
  typing in the projects box pays a 99.0 ms `Build-Sessions` for the same
  reason. Only the header box legitimately needs both.
- **The auto-reselect turns a keystroke into a click.** When the letters filter
  the open conversation away, the tick is **103.7 ms** against 55.1 for a tick
  that keeps it - a whole cold selection, transcript parse and all, fired by
  typing.
- **The document the click triggers.** The click returns in 37.8 ms and then the
  UI thread is unavailable for `Complete-DocParse` **323.6 ms** plus the
  document's layout **360.2 ms**. Deferred by one lane tick, not avoided. That
  pane is another lane's to fix, but it is the sessions list that triggers it,
  and it is the largest thing the operator feels after a click.

## 3. Controls the coverage map does not name at all

**Eight of this lane's thirteen controls are absent from `$COVERAGE` in
`perf-driver.ps1:551`:** `ListFold`, `ListOpen`, `ListSort`, `RailClear`,
`RailFold`, `RailOnlyLive`, `RailOpen`, `RailSort`. The map lists only `Search`,
`RailSearch`, `ListSearch`, `SessionList` and `RailList`.

They are not merely unlisted - they are **invisible to the check that would
report them missing**. The regex at `perf-driver.ps1:610` matches
`Click|SelectionChanged|TextChanged|KeyDown|Checked|MouseDoubleClick`, and nine
of this lane's fourteen handlers use none of those: five `MouseLeftButtonUp`
(`RailClear`, `RailFold`, `ListFold`, `RailOpen`, `ListOpen`), three
`MouseLeftButtonDown` (`ListSort`, `RailSort`, `RailOnlyLive`) and one
`PreviewMouseLeftButtonDown` (`SessionList`). So `$wired` never contains them,
`$unmeasured` never names them, and the staleness check cannot see them either.
Before this audit, five of the eight had **never been executed by any test** -
not the sorts, not the fold carets, not the running/all toggle. `RailClear` and
band filtering are approximated by benches that set `$script:railPick` /
`$script:bandPick` by hand and rebuild.

## 4. Where this lane agrees and disagrees with `perf-driver.ps1`

- **Agrees:** `select a conversation (COLD - the click)` - 37.8 here, inside its
  50 ms `GESTURE` class and consistent with the history in its comments.
  `select the same one again (warm)` - 0.4 here, `INSTANT`, at bar.
  `pick a project in the rail` - 79.9 here, matching my `RailList` figure.
- **Disagrees - `Build-Sessions` is already failing its own gate.** It is
  benched as a `GESTURE` (50 ms budget) and reads **88.2-99.0 ms best** on this
  machine across four runs. A `-Only perf` run applies that budget as a hard
  gate. Either the suite is only ever run in soft mode, or the registry has
  grown past what it was calibrated on - its comments talk about 190-240
  conversations; there are 299 now.
- **Disagrees - the search benches measure half the handler.**
  `search: sessions box only` is `$ui.ListSearch.Text='ker'; Build-Sessions`,
  but the shared timer rebuilds **both** panes: 83.6 ms, not one build.
- **Disagrees - `filter sessions by band` (a bare `Build-Sessions` with
  `$script:bandPick` set) reads ~50 ms; the real control reads 272 ms.** It
  omits the realized list and the auto-reselect.
- **The class budgets themselves.** `GESTURE` and `INSTANT` are both 50.0, so
  everything in this lane except the four rebuild-driven controls passes that
  suite while being 5x to 40x the terminal. As the contract says, its green is
  not evidence about the question this audit asks.

## 5. What could not be measured, and what would make it measurable

- **`Start-LiveProbe` inside a real click.** It returns immediately while a
  probe is in flight, and in a spliced harness no dispatcher runs, so
  `Complete-LiveProbe` never fires and `$script:probePs` stays non-null after
  the first call. Every iteration after the first therefore skips the runspace
  open, and best-of-15 reports the cheap path. The floor is measured
  (`17.4 ms` for a bare runspace open) but the real distribution - how often a
  click lands with no probe in flight, plus the `Stop()`/`Dispose()`/`Close()`
  path when a probe is judged overdue at 90 s - needs a driver that pumps the
  dispatcher and drives the live timer. Recommend the lead treat "the cold click
  opens up to two runspaces" as measured-in-principle and unquantified in
  frequency.
- **The four fold carets end-to-end.** `GUARDED`; the write was timed on a copy
  of the config. Making them measurable honestly means moving the write off the
  click (it is a preference, not a transaction), which is also the fix.
- **WPF's own input pipeline.** These are raised events, so hit-testing, mouse
  capture and the input queue are excluded. Every figure here is a floor for the
  real gesture, never a ceiling.
- **The `part 7: assigning ItemsSource` line (0.07 ms) proves nothing.** It
  assigns the same collection back and WPF short-circuits it. The
  realized/unrealized pair at the top of this report is what actually measures
  the swap.
- **Nothing threw.** No `UNMEASURABLE` controls in this lane.

## What I would put in front of the operator first

1. **Stop rebuilding the whole list for every gesture.** Nine of the thirteen
   controls are one function, and on screen that function is ~280 ms. A sort, a
   band filter and a project pick all re-derive 48 rows from 299 conversations
   when the row objects have not changed - only their order, or which of them
   is shown. Reordering or filtering an existing `ItemsSource` (or a
   `CollectionView` with a `SortDescription` / `Filter`) is the difference
   between 280 ms and a few.
2. **Get `Get-RowSubAgents`'s disk read off the rebuild.** One rebuild in eight
   costs 785 ms and the operator cannot predict which.
3. **Split the search timer per box, or give the tick a flag for which pane
   changed.** Half of every search rebuild cannot change what it rebuilds.
4. **Move `Save-SRConfigValue` off the fold carets** (fire-and-forget, or write
   on close). 23.8 ms of file I/O to remember a caret.
5. **Do not open a runspace inside a click handler.** Both `Start-DocParse` and
   `Start-LiveProbe` do; a pool opened once at startup costs the click nothing.
