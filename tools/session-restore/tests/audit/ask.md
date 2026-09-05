# The ask panel and the composer, against the 7.0 ms bar

**7 AT BAR, 1 NEAR, 0 OVER, 4 GUARDED, 0 UNMEASURABLE** across the twelve
handlers on the eleven controls this lane owns.

**But the lane's own machinery is where the time is, and none of it is a
control**: one `Invoke-AskPoll` tick costs **20.7 ms and runs four times a
second forever**, and a question appearing costs **20–26 ms to draw**. Both are
`OVER`. The controls are fine; the thing that runs whether or not you touch
anything is not.

Driver: `tests/audit-ask.ps1`. Run 2026-09-05, best of 15 per row.
Machine: a fixed 100k-`Math::Sqrt` loop read **160 ms** with **25 `claude`
processes** running. (`perf-driver.ps1` records 337 ms / 26 sessions on
2026-09-04 for the same loop, so this box was *less* contended than that
baseline - these numbers are not flattered by a quiet machine, they are the
better half of the two conditions.)

Nothing here launched, killed, typed, saved or wrote. The one console read was a
`tests/menu-replica.ps1` this driver spawned, read and killed itself.

---

## The controls

| control | handler | what pressing it does | best | med | p90 | verdict | what dominates |
|---|---|---|---|---|---|---|---|
| `SendBox` | `PreviewKeyDown` | decide whether the key belongs to the skill picker or the composer | 0.15 | 0.17 | 0.21 | AT BAR | two comparisons. Body timed, not raised - see *what I could not measure* |
| `SendBox` | `TextChanged` | ordinary character: `Update-SendState` + `Update-SkillPop` | 0.86 | 0.98 | 1.68 | AT BAR | `Update-SendState` 0.55; `Update-SkillPop` bails on the first `StartsWith('/')` |
| `SendBox` | `TextChanged` | a character of a `/skill` name | 5.43 | 8.79 | 11.61 | AT BAR (NEAR at the median) | `Select-SRSkills` ranking 61 skills, 3.09 ms - **per keystroke** |
| `SendBox` | `LostKeyboardFocus` | close the picker unless focus went into it | 0.65 | 0.76 | 1.21 | AT BAR | the visual-tree walk. Event raised for real |
| `SendBtn` | `Click` | **GUARDED** - `Invoke-Send` up to `Send-SRSessionInput` | 0.19 | 0.22 | 0.35 | GUARDED | a `SelectedItem` check and a `.Trim()`. The send itself was never called |
| `AskFree` | `PreviewKeyDown` | **GUARDED** - Enter runs `Invoke-AskTyped`; timed up to `Start-AskSend` | 0.19 | 0.20 | 0.26 | GUARDED | the three refusals. Any non-Enter key is 0.14 ms |
| `AskFreeSend` | `Click` | **GUARDED** - the same `Invoke-AskTyped`, up to `Start-AskSend` | 0.18 | 0.21 | 0.22 | GUARDED | same. `Set-AskEnabled`, the pass that greys the card, is 0.28 |
| `Broadcast` | `Click` | open send-to-many: `Set-Surface` + `Show-Cast` -> `Build-Cast` | 7.53 | 10.04 | 11.39 | NEAR | `Build-Cast` 4.70, of which `Get-Title` x25 is 1.58. Pressing it to *close* is 0.27 |
| `CastList` | `PreviewMouseLeftButtonDown` | tick one conversation: `Get-ClickedRow` -> toggle -> `Build-Cast` | 5.01 | 7.73 | 9.83 | AT BAR | `Build-Cast` - the whole list is rebuilt to move one tick |
| `CastText` | `TextChanged` | enable/disable Send | 0.14 | 0.26 | 0.40 | AT BAR | one `.Trim().Length` and a hashtable count |
| `CastCompact` | `Click` | fill the box with the morning-compact brief | 5.05 | 7.47 | 8.75 | AT BAR | `Get-SRConfig` - **a 15 KB disk read + `ConvertFrom-Json` on the click**, 3.45 ms of the 5.05 |
| `CastCancel` | `Click` | `Hide-Cast` + `Set-Status` | 0.40 | 0.49 | 0.71 | AT BAR | nothing; it sets one `Visibility` |
| `CastSend` | `Click` | **GUARDED** - the re-check and the names, up to `Confirm-Action` | 1.79 | 2.94 | 4.36 | GUARDED | `Get-Title` over the ticked rows (3 ticked). `Confirm-Action` and the send queue were never reached |

### The lane's own machinery (not a control, and where the time actually is)

| what | best | med | p90 | verdict |
|---|---|---|---|---|
| `Invoke-AskPoll` - **one tick, steady state** (read + parse + signature, no redraw) | **20.69** | 23.80 | 29.65 | **OVER** |
| `Invoke-AskPoll` - one tick where the menu changed (tick + `Show-Ask`) | **34.20** | 39.64 | 73.36 | **OVER** |
| `Invoke-AskPoll` - one tick, nothing selected | 0.51 | 0.66 | 1.19 | AT BAR |
| `Invoke-AskPoll` - one tick, selected but not running (`Test-AskAllowed` refuses) | 0.45 | 0.49 | 0.68 | AT BAR |
| `Show-Ask` drawing `round-single-fresh` (5 options, 3 tabs) | **24.16** | 32.08 | 41.22 | **OVER** |
| `Show-Ask` drawing `round-multi-ticked` (6 options, 3 tabs, multi) | **25.50** | 34.91 | 40.29 | **OVER** |
| `Show-Ask` drawing `round-review` | **24.13** | 29.42 | 33.96 | **OVER** |
| `Show-Ask` drawing `round-free-typed` | **20.33** | 24.64 | 36.68 | **OVER** |
| `Show-Ask` + a window layout pass | **43.04** | 57.82 | 64.76 | **OVER** |
| `Get-AskSignature` on a real parsed round | 0.75-1.27 | 1.26-1.51 | 1.36-1.95 | AT BAR |

**`Get-AskSignature` is not the problem.** It was the thing to check, and the
answer is no: 0.75-1.27 ms across four real captured rounds, single-select,
multi-select, review and free-text. At four ticks a second that is 0.3% of the
UI thread. Leave it alone.

---

## 1. The worst three, diagnosed

### (a) `Show-Ask` - 20-26 ms for a real round, and ~90% of it is PowerShell setting properties

Not a WPF cost and not a layout cost. Taken apart:

| | best (ms) |
|---|---|
| fixed cost: 1 option, no details, no tabs | 5.88 |
| 5 options, no details, no tabs | 20.57 |
| 5 options **with** the reasoning under each | 25.38 |
| 5 options + the round tab strip | 37.69 |
| 5 options + tabs + the review list | 43.66 |

So: **~3.7 ms per option**, ~1.0 ms per detail line, **~17 ms for the tab
strip**, ~3 ms per review row. Inside one option (five of them replicated
outside `Show-Ask` = 18.29 ms):

| piece of one option x5 | best (ms) | share |
|---|---|---|
| the seven bare `New-Object` WPF controls | 1.77 | 10% |
| the three `FindResource` lookups | 0.17 | 1% |
| `Add_Click` wiring the scriptblock | 5.10 (18.29 - 13.19) | 28% |
| **everything else = the property assignments** | **11.42** | **62%** |
| handing the finished buttons to the `ItemsControl` | 0.08 | - |

Each option sets ~25 dependency properties (`Style`, `Margin`, `CornerRadius`,
`Foreground`, `FontSize`, `FontWeight`, `FontFamily`, two `Thickness`
constructions, `Grid::SetColumn`, ...) through PowerShell's PSObject adapter, at
roughly 0.09 ms each. `sessions-window.ps1:4115-4185` builds that graph in code,
per option, on every draw.

**The fix is structural, not micro:** `AskOptions` is an `ItemsControl` already.
A XAML `DataTemplate` over plain `[PSCustomObject]` rows (`Badge`, `Label`,
`Detail`, `IsOn`) would move all of it into WPF's own template instantiation and
reduce `Show-Ask` to one `ItemsSource` assignment - measured at **0.08 ms**. The
same applies to `New-AskTabChip`/`New-AskArrow` (**7.85 ms for five chips**,
`sessions-window.ps1:3941-3982`) and to the review rows built at
`sessions-window.ps1:4057-4074`.

The tab strip is worth calling out on its own: **it costs as much as four
options** (+17.1 ms) to draw five small chips. 7.85 of that is the chips and
1.39 is the `AskTabs.ItemsSource` assignment; the remaining ~8 ms did not
resolve into a single named call and sits inside this operation's run-to-run
spread, so I am reporting it as unattributed rather than inventing a cause.

### (b) `Invoke-AskPoll` - 20.7 ms every 400 ms is 5.2% of the UI thread, permanently

| piece of one tick | best (ms) | share |
|---|---|---|
| `Get-SRScreenText` (held-open reader) | 5.57 | 27% |
| `Invoke-SRParseScreenQuestion` | **9.33** | **45%** |
| `Get-AskSignature` | 0.82 | 4% |
| `Add-Member` stapling the screen onto the result | 0.66 | 3% |
| `Get-SelectedRow` | 0.28 | 1% |
| `Test-AskAllowed` | 0.40 | 2% |
| accounted | 17.06 | 82% |

🔴 **The comment at `sessions-window.ps1:4596-4598` says this costs "about 2% of one
thread". Measured, it is 5.2% at best and 6.0% at the median.** The estimate
counted the 9.3 ms read and not the 9.3 ms parse that follows it every single
time. That is not a rounding difference - it is the parse, which is the largest
single piece of the tick and was left out of the sum.

**The parse is the thing to remove, and it is removable.** The tick already
knows how to do nothing cheaply - `Get-AskSignature` exists precisely so an
unchanged menu is not redrawn - but the signature is computed *after* the parse.
Measured on a static console, **ten consecutive reads produced one distinct
signature**: the screen is identical between ticks in the overwhelming majority
of cases. Comparing the raw screen text to the last one *before* parsing would
skip 9.33 ms on those ticks and take the lane from 20.7 ms to ~7 ms - at the
bar, and less than half the thread cost.

Two smaller notes on the same tick:

- The parse cost tracks screen content, not screen size: four captured rounds of
  2098-2586 chars parsed at 6.12-7.29 ms, and the 573-char replica at 9.33 ms.
  So a shorter screen does not buy anything.
- `Add-Member` through the pipeline is 0.66 ms against 0.19 ms for
  `PSObject.Properties.Add`. Real, but 0.5 ms - list it, do not lead with it.

### (c) The screen read without the held-open reader - 77.6 ms

`Get-SRScreenText` against the same console: **5.57 ms served, 77.64 ms spawning
a child** (p90 101.3, matching the contract's 99.8 ms figure). The lane's own
backoff (`> 40 ms` -> poll every 2500 ms, `sessions-window.ps1:4650`) is
correctly calibrated and is the only reason a machine that cannot start the
reader does not lose a fifth of its UI thread to this timer.

But the backoff fires **after** the first slow read, and the reader is started in
`Add_ContentRendered` *after* the timers. On a machine where
`Start-SRScreenServer` fails there is a window of ticks at ~78 ms each before the
lane notices. It self-corrects; worth knowing it is not instant.

---

## 2. What a click pays for that it should not

1. **`CastCompact` reads and re-parses the config file on the click.**
   `Get-SRCompactBrief` -> `Get-SRConfig`, and `Get-SRConfig`
   (`_common.ps1:192`) has **no cache** - it does `Get-Content -Raw |
   ConvertFrom-Json` over the 15 KB `session-restore.config.json` every call.
   That is 3.45 ms of a 5.05 ms click, for a string that changes when the
   operator edits a file.
2. **Every keystroke of a `/skill` name re-ranks all 61 skills.**
   `Select-SRSkills` is 3.09 ms best / 5.34 median, and a `-replace '\s+',' '`
   runs per row on top (1.13 ms for 8 rows). `Get-SRSkills` itself is cached and
   costs 0.52 ms, so this is **not** a disk problem - it is ranking work repeated
   from scratch on each character of a monotonically-growing prefix.
3. **`Build-Cast` rebuilds the entire list to move one tick.** `CastList`'s
   handler ends in `Build-Cast`, which loops all 25 running conversations,
   re-runs `Get-Title` on each (1.58 ms), re-sorts and replaces `ItemsSource` -
   5.01 ms to toggle one checkbox. It also throws away and regenerates every
   container, which is what made this control unmeasurable by repeated event
   raising (below).
4. **`Show-Ask` rebuilds the whole card on every redraw**, including the tab
   strip and the review list, when a round move changes only the cursor. See
   (a).

Nothing in this lane spawns a subprocess on a click, and nothing writes to disk
on a click. The only disk read on a click path is `Get-SRConfig` above.

---

## 3. Controls the coverage map does not name at all

`tests/perf-driver.ps1:610` matches only
`Click|SelectionChanged|TextChanged|KeyDown|Checked|MouseDoubleClick`, and its
`$COVERAGE` map is checked only against what that regex finds. In this lane:

- **`AskFree` / `PreviewKeyDown`** - not in `$COVERAGE`, and `PreviewKeyDown` is
  not in the regex either, so it is invisible from both directions. It is the
  Enter key that commits a typed answer into a live session.
- **`CastList` / `PreviewMouseLeftButtonDown`** - same: not in `$COVERAGE`, not
  in the regex. It is the only way to choose who a broadcast goes to, and it is
  the most expensive control on that panel at 5.01 ms.
- **`SendBox` is in `$COVERAGE` once**, as `'filter the skill picker'`. It
  carries **three** handlers - `PreviewKeyDown`, `TextChanged`,
  `LostKeyboardFocus` - and that entry covers `Update-SkillPop`, which is half of
  one of them. A name present in the map reads as a control that is covered.

---

## 4. What I could not measure, and what would make it measurable

- **The irreversible halves of the four destructive controls.**
  `Send-SRSessionInput` (`SendBtn`), `Invoke-SRAnswerTypedOnScreen`
  (`AskFreeSend`, `AskFree`+Enter), and `Confirm-Action` + the 300 ms cast queue
  (`CastSend`) were never called. All four are recorded `GUARDED` against the
  pre-step named in the table. *Measurable* the way `relay-driver.ps1` does it -
  against a spawned menu replica rather than a live conversation - but that is
  the relay suite's job, not an audit lane's.
- **`Get-ClickedRow` inside the `CastList` handler.** The handler ends in
  `Build-Cast`, which replaces `ItemsSource`; the `ListBoxItem` this driver held
  is then recycled and its `DataContext` becomes WPF's `DisconnectedItem`
  sentinel, so runs 2-15 indexed the tick table with a null `Id` and threw. The
  raise is therefore done **once**, checked (`the raise toggled a tick: True`),
  and the repeated timing is the same body against a live row. Making the walk
  itself measurable needs a container that survives the rebuild.
  🔴 **This is also where an unmeasured control was nearly reported as fast.**
  Raising the tunnelling `PreviewMouseLeftButtonDown` *on the `ListBoxItem`* does
  not reach the `ListBox`'s handler in a window that has never been rendered:
  the handler returned having done nothing, and the first three runs of this
  driver reported `CastList` at **0.19-0.30 ms, AT BAR**. It is 5.01 ms. The
  driver now proves the tick moved before it reports a number.
- **A real `PreviewKeyDown` raise.** `KeyEventArgs` requires a
  `PresentationSource` and this harness never shows the window, so the two
  `PreviewKeyDown` rows are **handler bodies, timed, not events delivered**. Both
  are pure branch logic (0.14-0.19 ms) so the distinction costs nothing here; a
  `live-driver.ps1`-style unactivated `HwndSource` would make them raisable.
- **Signature stability against a *live* claude screen.** Proven only against the
  static replica: ten reads, one distinct signature. `Get-AskSignature` reads
  only parsed fields (question, header, options, cursor, ticks, multi, tabs) and
  never the raw screen, so a spinner or a clock on a real screen should not move
  it - but that is reasoning, not a measurement, and if it is ever wrong the tick
  goes from 20.7 ms to 34.2 ms four times a second.
- **`Invoke-AskPoll` with an answer in flight** (`$script:ansPs` set) was not
  timed separately. It is the same early return as the other two guards, both
  measured at 0.45-0.51 ms.

---

## What the lead should change, in order

1. **Compare the raw screen text before parsing it in `Invoke-AskPoll`.** Biggest
   single win available in this lane: 20.7 ms -> ~7 ms per tick, four times a
   second, forever. (`sessions-window.ps1:4670-4674`)
2. **Draw the ask card from a `DataTemplate` instead of building it in code.**
   `Show-Ask` 20-26 ms -> an `ItemsSource` assignment. Applies equally to the
   option buttons, the tab chips and the review rows.
3. **Cache `Get-SRConfig`** against the config file's timestamp. It is on a click
   path here and is almost certainly on others.
4. **Correct the "about 2% of one thread" claim at `sessions-window.ps1:4598`.**
   Measured: 5.2% best, 6.0% median. The estimate omitted the parse.
5. **Widen the coverage regex in `perf-driver.ps1:610`** and add `AskFree` and
   `CastList` to `$COVERAGE`; split the `SendBox` entry so its three handlers are
   not covered by one name.
