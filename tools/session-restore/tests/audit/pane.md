# The 7 ms audit — the reading pane

**5 AT BAR, 0 NEAR, 3 OVER, 4 GUARDED, 0 UNMEASURABLE.**

Driver: `tests/audit-pane.ps1`. Best of 15 (10 for the document builds, 5 for the
per-turn instrumented builds), median and p90 alongside. Nothing here launched,
killed, typed, sent or wrote the operator's config.

**Machine, and why it matters here.** Two full runs, minutes apart, identical
source: a fixed 100k-sqrt loop read **148 ms** on the first and **202 ms** on the
second, with 25 claude sessions running throughout. Everything in the document
section moved with it by roughly the same factor (`[folded]` construction 203 →
409 ms). **The numbers below are the second, complete run (202 ms loop).** Where
the two runs disagree materially I give both. The ratios and the attributions —
which call inside a handler owns the time — held across both.

**The conversation profiled is chosen at run time** and named in the driver's
output: the tail is capped at 96 KB, so file size does not decide how much
document gets built — how many *turns* land inside that cap does. Picking by
bytes found a 193 KB transcript whose tail folds into nine turns. The driver
parses the tail of the forty largest and takes the one producing the most turns.
Run A landed on `V-RESEARCH` (26 turns / 63 blocks), run B on `I8` (27 turns /
91 blocks). The operator's transcripts are live, so this drifts.

🔴 **The pane is not in its code-default state.** `session-restore.config.json`
has `transcriptTools: "full"`, so every fold in the document is built **open**.
The code default is `folded`. Both are measured below and both are labelled; a
table measured only in the cheap state would describe a window nobody has.

🪤 **Line numbers were re-anchored at the end of the audit**, but the lead is
editing `sessions-window.ps1` and `_common.ps1` while this runs — they moved once
already (`New-GutterMark` 2596 → 2612). Every citation also names its function,
which does not drift.

---

## The twelve controls

| control | handler | what pressing it does | best | med | p90 | verdict | what dominates |
|---|---|---|---|---|---|---|---|
| `PaneDoc` | SizeChanged | restarts the 240 ms re-measure timer | **0.17** | 0.20 | 0.93 | AT BAR | nothing — the work is deferred into the tick (below) |
| `PaneCompact` | Click | GUARDED — types `/compact` into a live session | **0.31** | 0.43 | 1.28 | GUARDED | timed the guard + `Set-Status`, up to `Send-SRSessionInput` |
| `PaneGoTo` | Click | GUARDED — raises a real terminal tab | **0.31** | 0.34 | 0.40 | GUARDED | timed the guard + `Set-Status`, up to `Invoke-SRJumpToSession` |
| `PaneRelaunch` | Click | GUARDED — kills and reopens a live session | **0.37** | 0.47 | 1.32 | GUARDED | timed `Get-SelectedRow` + `Get-Title`, up to `Confirm-Action` (a modal; not run either) |
| `PaneSettings` | Click | opens / closes the per-session settings panel | **3.31** open, **0.29** close | 4.95 / 0.33 | 11.78 / 1.06 | AT BAR | `Show-Settings` reads six prefs and fills the panel |
| `PaneTools` | Click | cycles folded/full/hidden and redraws | **36.63** redraw **+ 20.95** config write ≈ **57.6** | 56.02 / 25.65 | 85.21 / 70.19 | **OVER** | `Show-Selected -Force`, plus a synchronous JSON read-modify-write on the click path |
| `PaneWorktree` | Click | GUARDED — opens the new-session dialog | **0.30** | 0.34 | 7.64 | GUARDED | timed `Get-SelectedRow` + the project path, up to `Show-Spawn` |
| `PaneZoom` | Click | steps the type scale for the whole window | **53.39** redraw **+ 20.95** config write ≈ **74.3** | 66.33 / 25.65 | 75.12 / 70.19 | **OVER** | six window resources re-resolve, `SessionList.Items.Refresh()`, `Show-Selected -Force`, then the same config write |
| `StripList` | PreviewMouseLeftButtonUp | jumps to the conversation a dot stands for | **164.49** | 175.98 | 202.66 | **OVER** | `Build-Sessions` 114.5 + `Update-Strip` 24.3; the visual-tree walk is 0.22 |
| `ShellFold` | Click | hides the running-shells panel | **0.30** | 0.41 | 0.82 | AT BAR | two assignments and the layout the collapse forces |
| `Shell` | SizeChanged | re-cuts the window card's clip rect | **0.37** | 0.42 | 0.70 | AT BAR | one `Rect` assignment |
| `SkillList` | MouseLeftButtonUp | writes `/name` into the send box, closes the picker | **0.48** | 0.62 | 1.25 | AT BAR | `Complete-Skill` + the `TextChanged` it fires |

Run A (quieter machine) read the three OVER controls at 25.2 / 40.7 / 102.3 ms
redraw. Both runs put all three over the bar by 4–20x; none of them is near it.

Also measured on the document surface, not in the twelve:

| operation | best | med | p90 | verdict |
|---|---|---|---|---|
| scroll: a wheel notch (48 px) | 0.76 | 0.92 | 2.25 | AT BAR |
| scroll: one screen down / up | 0.65 / 0.76 | 0.94 / 0.89 | 1.63 / 2.15 | AT BAR |
| scroll: jump to end / top | 0.28 / 0.29 | 0.31 / 0.33 | 1.12 / 0.91 | AT BAR |
| the deferred `measureTimer` tick, size band held | 0.45 | 0.52 | 1.35 | AT BAR |
| open a fold with no disk in it | 12.08 | 18.13 | 21.55 | NEAR |
| open a fold holding a background-shell call | **289.39** | 309.76 | 323.24 | **OVER** |

**Scrolling and expanding: confirmed, with one correction.** The lead's ~1.1 ms
for scrolling holds — I measure 0.65–0.76 ms for a notch or a page, over a
10,456 px document (17.5 screens, none of it virtualized). Expanding a
background command does **not** hold at 3.6 ms: a fold with nothing to read is
12.1 ms, and a fold holding a background-shell call is **289 ms** (see below).

🪤 **How the scroll number is obtained decides whether it is 0.7 ms or 290 ms,
and both are wrong-lookings of the same thing.** Calling
`$ui.PaneDoc.Measure(w, h)` with a size of my own choosing fights the constraint
the parent gave the pane, so every call re-lays the whole document — my first
version did that and read 294 ms for a wheel notch. `UpdateLayout()` runs
exactly the pending pass the gesture invalidated, at the size the pane actually
has. That is what the UI thread blocks on in the real window, and it is what
every layout number in this report uses.

---

## 1. The worst three, diagnosed

### `StripList` — 164 ms, and 114 of it is a list rebuild

Split into its three parts: the visual-tree walk that finds which dot was hit is
**0.22 ms**; `Update-Strip` is **24.3 ms**; `Build-Sessions` is **114.5 ms**. The
handler jumps to a conversation by setting `$script:selId` and rebuilding the
*entire* sessions list, then rebuilding the strip from the model. Nothing in the
gesture needs the list rebuilt — the selection could be set on the existing
ItemsSource. `Build-Sessions` is the list lane's to own; what belongs here is
that a dot-click pays for it at all.

`Update-Strip`'s own 24 ms is `Get-Title $r.S $r.D` once per row over every
on-surface session, plus `Sort-SessionRows` twice.

### The fold-open — 289 ms, of which 330 ms is a directory glob

`Get-SRShellOutputPath` (`lib/_common.ps1:4857`, the glob at `:4866`) resolves a
background shell's output file by globbing
`%TEMP%\claude\*\<session>\tasks\<shell>.output`. Measured directly:
**330.43 ms best / 416.61 med / 434.76 p90.** `%TEMP%\claude` holds **170
directories** on this machine for that wildcard to walk. The file it finds is
**903 bytes**, and reading it — `Get-SRShellOutput`, including the ANSI strip —
is **2.13 ms**. So >99% of that click is the path lookup, not the read.

(The two measurements of the composite, 289 ms, and of the glob alone, 330 ms,
straddle each other because the OS directory cache is warmer in one loop than
the other. Both runs agree the glob is essentially all of it: run A read
325.74 ms glob against a 331.14 ms composite.)

A fold with no shell and no sub-agent in it is 12.1 ms — the object
construction, nothing more.

### `PaneZoom` / `PaneTools` — a JSON read-modify-write on the click path

Both call `Save-SRConfigValue` inline: read `session-restore.config.json`,
`ConvertFrom-Json`, `ConvertTo-Json -Depth 8`, write a temp beside it,
`Move-Item` over the original. Measured with the same code against a scratch
destination (never the real file): **20.95 ms best / 25.65 med / 70.19 p90.**
That is three times the whole bar, on every press of a control the operator
holds down to find a text size. The redraw half is on top of it — 53.4 ms for
zoom, 36.6 ms for the steps toggle — and the document rebuild lands *after* both,
on a later dispatcher frame.

`perf-driver.ps1` deliberately excludes this write from its `PaneTools`/`PaneZoom`
benches on the grounds that "the redraw never waits on it". The redraw doesn't,
but the *click* does: `Save-SRConfigValue` is called before `Show-Selected -Force`
returns, on the same thread, inside the handler.

---

## 2. What a click should not be paying for

- **A 170-directory wildcard walk of `%TEMP%\claude`** on every fold-open of a
  background-shell block — `Get-SRShellOutputPath`, `lib/_common.ps1:4866`. 330 ms to locate a 903-byte
  file. The session id and the shell id are both known; only the cwd-slug
  segment is unknown, and it is stable per conversation.
- **A synchronous config read-modify-write** inside `Step-ToolView`
  (`lib/sessions-window.ps1:5812`) and `Step-Zoom` (`:5846`). 21 ms.
- **A whole-transcript re-parse inside a fold-open.** `Add-RunDetail` calls
  `Get-SRSubAgents -JsonlPath $script:docParentPath` per sub-agent call
  (`lib/sessions-window.ps1:3296`). Neither tail held a `Task` call on the two
  runs, so this one is **stated, not measured** — see §4.
- **A full `Build-Sessions`** inside the `StripList` handler
  (`lib/sessions-window.ps1:8366`), to change which row is selected.
- **The document rebuild that `Show-Selected -Force` schedules** is not on the
  click, but it is on the UI thread one frame later, and it is 643 ms folded /
  1,770 ms with `Steps: full`. See §5.

---

## 3. Controls the coverage map does not name at all

`perf-driver.ps1`'s coverage check reads `^\$ui\.<Name>.Add_(Click|…)` plus, for
code-built controls, only `\$x.Add_Click({ param(...) Fn`. **Every clickable
control the reading pane builds inside the document is wired with
`Add_MouseLeftButtonUp`, so neither pattern sees any of them.** Four exist, and
none is in `$COVERAGE`:

| where | what it does |
|---|---|
| `lib/sessions-window.ps1:2806` | **the fold header** — `Invoke-FoldToggle`. Every folded block in every conversation. Measured here at 12.1 ms (nothing to read) to **289 ms** (a background shell). |
| `lib/sessions-window.ps1:3644` | **"load earlier"** — doubles `$script:tailBytes` and calls `Update-Document`. Measured here as `load-earlier`: **919 ms** to build and lay out. |
| `lib/sessions-window.ps1:3613` | **"← back to …"** — `Close-AgentDoc`, drawn at the top of a drilled-into sub-agent's document. |
| `lib/sessions-window.ps1:3309` | **"open its conversation →"** — `Show-AgentDoc`, inside a run block for a `Task` call. |

The fold header is the most-pressed control on this surface and the most
expensive one I measured. It has never been timed.

---

## 4. What I could not measure, and what would make it measurable

- **The sub-agent re-parse inside a fold-open.** `Get-SRSubAgents` over the
  parent transcript runs once per `Task` call in an opened block. Neither
  profiled tail contained a `Task` call (`0 sub-agent call(s)` on both runs), so
  the driver skipped it. Making it measurable needs a conversation whose last
  96 KB dispatched an agent — the driver already selects on turn count; it would
  need to select on "has an agent call in the tail" instead.
- **The `measureTimer` tick that actually rebuilds.** The tick re-pads the
  document, and rebuilds it only when `$script:readSize` moves by ≥0.5 px
  (`lib/sessions-window.ps1:6107`). I measured the padding-only path (0.45 ms).
  The rebuild path is `Show-Selected -Force`, already in the table at 36.6 ms
  plus the deferred document build — but I did not drive it through a real
  resize, because the window is never shown.
- **`PaneRelaunch`, `PaneCompact`, `PaneGoTo`, `PaneWorktree` past their guard.**
  All four are GUARDED for the reasons in the contract. What each *would* wait on
  is not this lane's to time: `PaneGoTo` waits on `Invoke-SRJumpToSession` (the
  `jump` suite), `PaneCompact` on `Send-SRSessionInput` (the `relay` suite).
- **The real fold-open click**, as opposed to `Build-FoldContent` called
  directly. `Invoke-FoldToggle` also flips `Visibility` on the content panel,
  which forces a document relayout I did not include. My number is a floor.

---

## 5. The document: building it, laying it out, and the tail-first answer

Run B, `I8`, 27 turns → 91 document blocks, pane 807 × 619 px, machine at
202 ms/loop:

| state | Get-ReadTurns | construction | layout | whole | swap floor |
|---|---|---|---|---|---|
| `folded` (code default) | 16.3 | **408.9** | **200.6** | **643.1** | 0.94 |
| `Steps: full` (**the operator's config**) | 16.8 | **1,270.9** | **378.7** | **1,770.0** | 1.22 |
| `load earlier` (tail doubled, 41 turns / 117 blocks) | 20.7 | 585.1 | 255.6 | 919.0 | 1.31 |

Run A, quieter machine, 26 turns / 63 blocks: folded 202.8 / 59.5 / 288.6;
`Steps: full` 688.8 / 198.0 / 954.1. **Layout agrees with the lead's ~58 ms;
construction does not — I measure 3–7x their 43 ms.** The difference is document
size: their number was against a smaller tail.

**The swap itself is free.** Assigning an *empty* `FlowDocument` to `PaneDoc` and
laying it out costs **0.94 ms**. So there is no fixed re-templating cost hiding
in the 643 ms — it is all content, and it is all proportional. That is the
precondition for tail-first working at all, and it holds.

### The answer: what would first paint cost with only the tail built?

| turns built for first paint | folded | Steps: full | load earlier |
|---|---|---|---|
| **1** | **13.6** ms (10.0 build + 3.6 layout) | **20.8** ms | **16.5** ms |
| **2** | 24.5 | 33.0 | 33.3 |
| **3** | 31.8 | 73.3 | 44.5 |
| **6** | **79.6** | **495.6** | **86.7** |
| 10 | 339.5 | 783.3 | 325.1 |
| 20 | 541.2 | 1,353.0 | 584.1 |
| all | 643.1 | 1,770.0 | 919.0 |

**Six turns is not the number. One is, and one still misses.**

- At the lead's ~6 turns, first paint is **79.6 ms folded and 495.6 ms in the
  config the operator is actually running** — 11x and 71x the bar. It is a real
  8x saving on `Steps: full`, and it does not reach the bar.
- At **one turn** it is **13.6 ms folded / 20.8 ms full** — 2–3x the bar. Even a
  single-turn first paint does not reach 7 ms.
- The cliff between 6 and 10 turns is not a threshold in the code; it is where
  the long prose turns happen to sit in this tail. Cost tracks turn *content*,
  not turn count — see the per-turn table below.

**And the fill-in frames are the harder half.** Filling the remaining turns in
chunks of six, inserting blocks at the top of the live document (a
`FlowDocument` has no prepend helper, so this is `Blocks.InsertBefore`) and
laying out after each chunk:

- folded: 4 frames, **40.9 – 492.9 ms each**, 4 of 4 over the bar
- `Steps: full`: 4 frames, **81.1 – 512.5 ms each**, 4 of 4 over the bar
- load earlier: 6 frames, **75.2 – 420.4 ms each**, 6 of 6 over the bar

So tail-first converts one long stall into a first paint that is still 2–70x the
bar plus a series of frames that are each *also* over the bar. It moves the pain;
it does not remove it. **It is worth doing anyway** — 1,770 ms → 20.8 ms to first
readable content is the difference between a frozen window and a responsive one —
but it should be sold as "the pane paints in 20 ms and fills in behind you", not
as reaching the terminal's 7 ms.

Two other findings bear on where a fix belongs:

**Mutating the live document is not cheaper than swapping it.** Building the same
six turns by clearing `Blocks` on the document already in the pane and re-adding
them: **73.8 ms**, against 79.6 ms for a fresh document. The swap was never the
cost, so reusing the document object buys nothing.

**`Get-ReadTurns` is on the UI thread and is 16.3 ms.** The parse runs off-thread;
the fold-into-turns pass does not. `Set-ReadDocument` calls it, then hands the
result to `Build-ReadDocument` (which correctly reuses it). It is over the bar on
its own before a single WPF object is made, and there is nothing thread-affine
about it — it operates on plain records.

### `Add-ReadTurn`, per turn

Instrumented build, best per turn across 5 repetitions. `folded`, run B:

| kind | turns | total | each |
|---|---|---|---|
| said | 10 | 124.3 ms | 12.43 |
| you | 2 | 90.9 ms | **45.44** |
| msgin | 1 | 59.4 ms | **59.39** |
| run | 8 | 57.5 ms | 7.19 |
| hook | 3 | 23.5 ms | 7.83 |
| system | 3 | 21.6 ms | 7.19 |

The six dearest turns were all prose: 69.7 ms for 2,315 chars, 59.4 for 1,571,
56.0 for 1,811. **Cost tracks body length, at roughly 25 µs per character and
3.4 ms per source line.** Under `Steps: full` the ordering inverts — `run` turns
go from 7.19 ms each to **83–320 ms each**, because every fold is built open and
each one pays whatever disk lookup its calls carry.

### Inside the builder: which primitive owns the construction time

| primitive | best | per object |
|---|---|---|
| `New-RailBlock` ×50 | 120.08 | **2.40 ms** |
| `New-GutterMark` ×100 | 85.32 | **0.85 ms** |
| `New-ReadRun` ×100 | 23.70 | 0.24 ms |
| `New-ReadText` ×100 | 16.22 | 0.16 ms |
| `New-Object Thickness` ×100 | 6.99 | 0.07 ms |
| `New-Object Paragraph` ×100 | 6.63 | **0.07 ms — the raw WPF floor** |

A bare `Paragraph` costs 0.07 ms. The two wrappers that host a **UIElement inside
the flow** cost 12x and 34x that:

- `New-GutterMark` (`lib/sessions-window.ps1:2612`) puts a `TextBlock` inside an
  `InlineUIContainer`, and `Add-ReadProse` adds **one to every paragraph** —
  including a blank one on every continuation line. At 0.85 ms each that is
  ~25% of the 3.44 ms a source line costs, and it is paid on lines that show
  nothing but a space.
- `New-RailBlock` wraps its child in a `BlockUIContainer`, one per non-prose
  block, at 2.40 ms.

`perf-driver.ps1` records an A/B of exactly the first of these — "the gutter as a
hosted element vs a Run (4 ms, then −21 ms)" — filed as noise and retired. At a
controlled count of 100 it is not noise: it is 0.85 ms per paragraph, measured
consistently across both runs (0.76 and 0.85). The earlier A/B was a whole-document
diff against contention; this is the primitive on its own.

**Where this points.** Construction is ~4.5 ms per document block and the raw WPF
objects account for well under a tenth of it. The rest is PowerShell function-call
overhead multiplied by object count — which is why the fix that actually reaches
the bar is *building fewer objects per line*, not building fewer turns. Replacing
the hosted gutter mark with a plain `Run` (or a fixed left margin) removes one
UIElement per paragraph; that is the single cheapest change available, and it is
worth re-A/B-ing properly against these numbers rather than against the retired one.
