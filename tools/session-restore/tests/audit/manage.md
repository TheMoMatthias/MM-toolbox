# The 7 ms audit — the session manager, the settings sheet, the window chrome

**6 AT BAR, 0 NEAR, 2 OVER, 3 GUARDED, 1 UNMEASURABLE** across the twelve
controls in this lane — plus **9 more controls on this surface that the perf
coverage map does not name at all, every one of them OVER.**

Driver: `C:\Users\mauri\Documents\MM-toolbox\tools\session-restore\tests\audit-manage.ps1`
Run twice, best-of-15 per row, against the live registry: **299 conversations
across 30 projects**, 142 rows in the manager at rest.

> **The machine.** Fixed 100k-`Sqrt` loop: 16 ms at the start, 20 ms at the end;
> 25 `claude` sessions running throughout, unchanged. Between the two full runs
> every figure below moved by less than the contention band except
> `Update-Model -KeepAgents` (410 → 576 ms).
> 🪤 **This spin number is NOT comparable to the 337 ms `perf-driver.ps1`
> records.** Mine runs inside a function, where PowerShell resolves locals in a
> frame instead of walking the session state; the same loop is ~17× cheaper for
> that reason alone. It is only comparable between my own runs, and there it is
> stable.

---

## Every control in the lane

| control | handler | what pressing it does | best | med | p90 | verdict | what dominates |
|---|---|---|---|---|---|---|---|
| `ModeWork` | `Checked` | two `Visibility` assignments + `Set-Status` | **0.41** | 0.97 | 2.20 | `AT BAR` | nothing; it rebuilds nothing at all |
| `ModeManage` | `Checked` | `Set-Surface manage` → **`Build-Manager`** | **90.11** | 121.06 | 137.04 | `OVER` | `Build-Manager`, 80 ms of the 90 |
| `ManageList` | `PreviewMouseLeftButtonDown` | branch `project` — fold a project open | **62.90** | 106.51 | 129.89 | `OVER` | `Build-Manager` |
| `ManageList` | ↳ branch `more` | drop the 7-day window | **81.76** | 139.78 | 163.59 | `OVER` | `Build-Manager` over the whole registry |
| `ManageList` | ↳ branch `conv` | `Set-TickOn` — tick one conversation | **141.90** | 166.39 | 202.67 | `OVER` | drops the row cache → a **cold** `Build-Manager` |
| `ManageList` | `PreviewMouseRightButtonDown` | `Get-ClickedRow` + select the row | **0.32** | 0.34 | 0.96 | `AT BAR` | the visual-tree walk, 6 levels, is free |
| `SetCancel` | `Click` | `Hide-Settings` + `Set-Status` | **0.42** | 0.51 | 0.65 | `AT BAR` | — |
| `SetPerm` | `SelectionChanged` | `Update-PermNote` | **0.57** | 0.79 | 0.94 | `AT BAR` | one `FindResource` |
| `SetApply` | `Click` | writes settings, saves, rebuilds everything | 0.42 / 3.96 / 1.72 | | | `GUARDED` | pre-step timed in three parts (below). **The tail it runs after the save is ~776 ms.** |
| `SaveBtn` | `Click` | writes the registry, then redraws | 1.11 / 12.40 / 73.48 | | | `GUARDED` | `Get-SRRegistryStamp`, the `ConvertTo-Json`, and the `Build-Manager` redraw |
| `Rescan` | `Click` | saves, rescans disk, rebuilds everything | **1.20** | 1.28 | 1.52 | `GUARDED` | the pre-step is a file stat. **The tail is the same ~776 ms.** |
| `WinMin` | `Click` | `WindowState = Minimized` | **0.16** | 0.18 | 0.22 | `AT BAR` | — |
| `WinMax` | `Click` | toggle `WindowState` + `Update-MaxGlyph` | **0.30** | 0.35 | 0.42 | `AT BAR` | with the relayout it forces: 2.79 ms, still at bar |
| `WinClose` | `Click` | `$window.Close()` | — | | | `UNMEASURABLE` | never invoked; see below |

### The nine controls the coverage map cannot see — all OVER

Reachable from `ManageList` and the mode toggles, and every one of them a full
`Build-Manager`:

| control | handler | best | med | p90 | verdict |
|---|---|---|---|---|---|
| `HdrLogon` | `MouseLeftButtonDown` → sort `logon` | 71.84 | 108.29 | 130.28 | `OVER` |
| `HdrName` | `MouseLeftButtonDown` → sort `name` | 90.62 | 112.97 | 135.10 | `OVER` |
| `HdrLane` | `MouseLeftButtonDown` → sort `lane` | 87.40 | 104.56 | 131.67 | `OVER` |
| `HdrSaid` | `MouseLeftButtonDown` → sort `said` | 68.56 | 99.20 | 135.08 | `OVER` |
| `HdrAge` | `MouseLeftButtonDown` → sort `age` | 88.28 | 107.73 | 132.57 | `OVER` |
| (re-clicking the same header — the `mgrDesc` flip) | | 91.94 | 125.58 | 141.60 | `OVER` |
| `MgrAll` | `Checked` → filter `all` (128 rows survive) | 98.42 | 136.16 | 149.30 | `OVER` |
| `MgrTicked` | `Checked` → filter `ticked` (32 rows) | 42.46 | 69.86 | 85.31 | `OVER` |
| `MgrRunning` | `Checked` → filter `running` (24 rows) | 40.99 | 63.88 | 80.47 | `OVER` |
| `MgrNeeds` | `Checked` → filter `needs` (**10 rows**) | 48.55 | 59.53 | 76.95 | `OVER` |

Driven through the real `RadioButton` (`MgrAll` → `MgrTicked`) rather than by
assigning `$script:mgrFilter`: **45.70 ms**. The wiring costs nothing; the
rebuild is the whole figure.

---

## Why the surface switch is asymmetric — 90 ms one way, 0.4 ms the other

It is not a caching effect and it is not measurement order. `Set-Surface` has
two branches and **only one of them rebuilds anything** (`sessions-window.ps1:528`):

```powershell
if ($Mode -eq 'manage') {
    $ui.WorkSurface.Visibility   = $V_Hide
    $ui.ManageSurface.Visibility = $V_Show
    Build-Manager                     # <-- 80 ms
    Set-Status '...'
} else {
    $ui.ManageSurface.Visibility = $V_Hide
    $ui.WorkSurface.Visibility   = $V_Show
    Set-Status '...'                  # <-- and nothing else
}
```

Measured in isolation, the pieces account for both directions exactly:

| | best | med | p90 |
|---|---|---|---|
| the two `Visibility` assignments, alternating | **0.18** | 0.21 | 0.72 |
| `Set-Status` | **0.18** | 0.30 | 0.42 |
| `Build-Manager`, warm row cache | **80.00** | 93.10 | 107.05 |
| `Build-Manager`, cold row cache | **132.33** | 146.10 | 187.53 |

0.18 + 0.18 = the 0.41 ms work direction. 0.18 + 0.18 + 80 = the 90 ms manage
direction. **The asymmetry is one function call.**

The reason that call is there is structural, not accidental: the *work* surface
is kept current by the 6-second passes (`Invoke-FastPass`, `Update-Surface`), so
switching to it can safely show whatever was last built. **The manager has no
equivalent — nothing keeps it current, and nothing records whether it is
stale — so the only way it can be right on arrival is to rebuild it every
single time.** Every other manager gesture inherits the same decision, which is
why the sorts, the filters, the folds and the tick all land in the same 40–140 ms
band: they are all the same 80 ms function with a different flag set first.

Confirmed both ways: repeated (`Set-Surface 'manage'` fifteen times, 87.75 ms)
and alternating (a real toggle, each timed call preceded by an untimed switch to
work, 79.92 ms) agree. Nothing is cached between presses.

---

## The worst three, diagnosed

### 1. `SetApply` and `Rescan` — ~776 ms of work **after** the disk step

Both handlers end with the same three calls
(`sessions-window.ps1:7921` and `:8393`):

```powershell
Update-Model -KeepAgents; Update-Surface; Start-LiveProbe
```

| | best | med | p90 |
|---|---|---|---|
| `Update-Model -KeepAgents` | **575.87** | 578.89 | 816.16 |
| `Update-Surface` | **200.40** | 230.91 | 1195.88 |

That is **111× the bar, and none of it is the write.** The write is guarded and
was not run; this is the part of the click that is neither destructive nor
timed by any existing suite. `perf-driver.ps1` benches `Update-Model
-KeepAgents` under the `SLOW` class (1000 ms), so the whole 776 ms is currently
inside budget and invisible.

`Update-Model -KeepAgents` already exists *because* this path was too slow —
the comment at `sessions-window.ps1:1010` records dropping `claude agents
--json` off it, taking 1,091 ms to ~78. It reads 576 ms here on 299
conversations. The saving is real; the remainder is not small.

The pre-steps, which are all `SetApply` does before `Save-SRRegistry`:

| | best | med | p90 | verdict |
|---|---|---|---|---|
| step 1 — linear scan of the model for `setFor` | 0.42 | 0.45 | 1.13 | `AT BAR` |
| step 2 — the change-detection pass (`Get-SRSessionArgsLabel` + `Get-Title`, run twice) | 3.96 | 6.65 | 16.36 | `AT BAR` |
| step 3 — writing all six prefs (against a **JSON clone**; the real row untouched) | 1.72 | 2.49 | 15.23 | `AT BAR` |

`Rescan`'s pre-step is a file stat and a boolean: **1.20 ms**.

### 2. `ManageList` branch `conv` — ticking one box costs 142 ms

`Set-TickOn` (`sessions-window.ps1:774`) opens with:

```powershell
$script:mgrItems = @{}      # drop EVERY built row, for a change to one of them
```

…and then calls `Build-Manager`, which now has to reconstruct all ~140 visible
rows instead of reusing them. That is the entire difference between the warm
80 ms and the cold 132 ms, and the tick pays the cold path every time.

The cache exists for a good reason (the comment at `:690` is right that a stale
tick on screen is worse than a slow one). But the row that changed is *known* —
one `TickBg` brush on one item — and the cache is dropped wholesale for it.

### 3. `ModeManage`, the five sort headers, the four filter chips, both folds

One cause, thirteen controls: `Build-Manager`. Taken apart over 299
conversations / 30 projects:

| piece of `Build-Manager` | best | med | p90 | note |
|---|---|---|---|---|
| `Sort-ManagerRows` for every project | **34.76** | 44.05 | 50.88 | the largest warm-path item |
| `Get-AgeTicks` for every row | **51.14** | 59.89 | 73.65 | cold path only (row construction) |
| group the model by project | **14.39** | 17.71 | 20.93 | |
| the two `Where-Object` counting passes at the end | **7.80** | 10.89 | 16.01 | |
| the 7-day window filter over every project | 4.62 | 9.23 | 11.83 | |
| `Get-ProjectLabel` per project | 1.72 | 3.89 | 5.28 | |
| order the projects by newest conversation | 0.92 | 1.78 | 2.45 | |
| `Select-ManagerRows` per project (filter `all`) | 1.75 | 3.61 | 5.13 | |
| **assign `ManageList.ItemsSource` — the re-bind** | **0.13** | 0.15 | 0.44 | 🔴 **WPF is not the problem** |

Two of those have a measured, mechanical cause rather than an algorithmic one:

**`Sort-ManagerRows` is paying for a scriptblock key.** Same rows, same
projects, three ways:

| | best | med | p90 |
|---|---|---|---|
| the key scriptblock invoked once per row, **no sorting at all** | 13.19 | 23.46 | 29.43 |
| `Sort-Object -Property At` per project | **3.15** | 5.72 | 7.99 |
| `Sort-Object { & $key $_ }` per project — **what ships** | 24.28 | 43.17 | 48.00 |

**`Get-AgeTicks` is paying for a wrapper.** It is a one-line function that calls
`Get-AgeLabel`; the cost is two PowerShell frames per row, not the arithmetic:

| | best | med | p90 |
|---|---|---|---|
| an **empty** `foreach` over all 299 | 0.17 | 0.22 | 0.37 |
| `foreach` + one property read (`$r.At`) | 0.19 | 0.32 | 2.17 |
| `foreach` + the grouping's string interpolation `"$($r.D.path)"` | 0.40 | 0.48 | 2.25 |
| `foreach` + `Get-AgeLabel` — **one** call per row | 17.51 | 26.15 | 36.59 |
| `foreach` + `Get-AgeTicks` — **two nested** calls per row | 49.47 | 66.71 | 80.95 |

The loop is free. The property reads are free. The string interpolation is
free. **Every millisecond is PowerShell function-call overhead**, ~58 µs per
call layer × 299 rows, and the second layer buys one subtraction.

---

## What a click pays for that it should not

1. **`Build-Manager` costs almost the same whether 14 rows are on screen or
   160.** Measured directly:

   | | rows on screen | best | med | p90 |
   |---|---|---|---|---|
   | every project folded **shut** | 14 | **66.95** | 96.10 | 116.08 |
   | every project **open** | 160 | **91.88** | 103.27 | 119.56 |

   Two-thirds of the cost is paid for rows that are never added to the list.
   The cause is the order of the statements at `sessions-window.ps1:651`:

   ```powershell
   $kids = @(Sort-ManagerRows (Select-ManagerRows $byProj[$k]))   # sorts ALL of them
   ...
   $armed = @($kids | Where-Object { [bool]$_.S.enabled }).Count
   $shut  = [bool]$script:fold[$k]
   ...
   if ($shut) { continue }                                        # ...then throws them away
   ```

   A folded project genuinely needs `$kids` — the heading prints its count and
   its armed count — but it does **not** need them **sorted**. Moving
   `Sort-ManagerRows` below the `if ($shut) { continue }` skips the whole 35 ms
   sort for every folded project, and the surface opens folded by design.

2. **The manager rebuilds on arrival even when nothing has changed.** Pressing
   Session manager → Work surface → Session manager pays 90 ms the second time
   for a table that is byte-identical. There is no dirty flag on the manager;
   `$script:mgrItems` caches the *rows* but nothing caches the *list*.

3. **Two `Where-Object` pipelines to produce two integers**, at the end of every
   rebuild. The same two counts as a single `foreach`: **0.40 ms** against
   **7.80 ms**. This one is free money.

4. **`Set-TickOn` drops all ~300 cached rows to change one brush.** See worst-3
   above.

5. **`SetApply` computes its change-detection label twice** (`$was` before the
   writes, `$now` after) — 3.96 ms for the pair, so not a problem, but the
   second call re-derives `Get-Title` from a row it just wrote.

6. Nothing in this lane reads the screen, spawns a subprocess, or touches disk
   on the click path — **except** `SaveBtn` and `Rescan`, where that is the
   point, and `SetApply`/`Rescan`'s post-write tail, where it is not.

---

## Controls the coverage map does not name at all

`perf-driver.ps1:610` matches `^\$ui\.([A-Za-z]+)\.Add_(?:Click|SelectionChanged|TextChanged|KeyDown|Checked|MouseDoubleClick)`.
On this surface it misses **eleven** controls, for two separate reasons:

**The handler kind is not in the list** (the CONTRACT already flags this class):
- `ManageList.Add_PreviewMouseLeftButtonDown` (`:6139`) — the primary gesture of
  the whole surface: folds a project, opens the older rows, ticks a
  conversation. Three branches, 63–142 ms. **`ManageList` appears nowhere in
  `$COVERAGE` and nowhere in `$wired`.**
- `ManageList.Add_PreviewMouseRightButtonDown` (`:6341`) — the context menu that
  can relaunch or jump to a session.
- `HdrLogon` / `HdrName` / `HdrLane` / `HdrSaid` / `HdrAge` — `Add_MouseLeftButtonDown`
  (`:6261`). Five sorts, 68–92 ms each.

**The anchor cannot see indexer-wired controls.** This is a *second* blind spot
the CONTRACT does not name:
- `MgrAll` / `MgrTicked` / `MgrRunning` / `MgrNeeds` are wired as
  `$ui[$pair[0]].Add_Checked({...})` in a loop (`:6287`). `Add_Checked` **is** in
  the regex — but the pattern anchors on `^\$ui\.` and these are
  `$ui[`, so all four are invisible anyway. Four filters, 41–98 ms each.
  Anything wired through the `$ui[...]` indexer is outside the check regardless
  of its event kind.

For contrast, the same file wires `RailSort`, `RailOnlyLive` and `ListSort` with
`Add_MouseLeftButtonDown` too (`:6301`–`:6329`) — another lane's controls, but
the same blind spot.

`$COVERAGE` does name ten of my twelve, and none of its entries are stale.

---

## What could not be measured, and what would fix that

| | why | what would make it measurable |
|---|---|---|
| `WinClose` | 🔴 The contract forbids invoking it, and there is nothing else to time: the handler is `$window.Close()` with no pre-step. Its real cost is `$window.Add_Closed` (`:9187`) — stopping 8 timers, `Stop()`+`Dispose()` on a live runspace, `Stop-VitalsSweep`, `Stop-SRScreenServer` — which is teardown of a window that is already gone. `Add_Closing` (`:6022`) is a `return` when `$script:dirty` is false and a **blocking modal sheet** when it is true. | a harness that builds a *second*, disposable window and closes that one. Nothing short of that can time it honestly. |
| `SaveBtn`'s actual write | writes the operator's registry | the `Invoke-SRWithRegistryLock` + `Move-Item` half is untimed. What **is** timed: `Get-SRRegistryStamp` **1.11 ms**, and `ConvertTo-Json -Depth 8` over the whole 516 KB registry, **built and discarded**, **12.40 ms**. A `Save-SRRegistry -Path` parameter pointed at a temp file would make the rest measurable in a sandbox. |
| `Rescan`'s scan | `Invoke-SRRescan` walks `~/.claude/projects` and can save | **it was not run.** `Update-SRRegistryCore` already takes `-Config`; a `-RegistryPath` override would let a sandboxed copy be scanned. |
| `SetApply`'s writes against the **real** row | `Set-SRSessionPref` mutates the live registry graph | timed against a `ConvertTo-Json`/`ConvertFrom-Json` clone instead — same code, same shapes, **1.72 ms**. |
| `Start-LiveProbe` | starts a runspace | not run. It is the third call in both the `SetApply` and `Rescan` tails, so the ~776 ms figure for that tail is a **floor**. |

Everything `Set-TickOn` mutates (`enabled`, `pinned`, the project's `enabled`,
`$script:dirty`) was captured before the bench and restored after, and the
restore is asserted in the driver output. `$script:dirty` is forced to `$false`
at the end of the run.

---

## Handing this to the lead — the ranked fixes

| # | change | measured saving | risk |
|---|---|---|---|
| 1 | Move `Sort-ManagerRows` below `if ($shut) { continue }` in `Build-Manager` | up to **35 ms**, on the default folded state | low — a folded project's heading needs the count, not the order |
| 2 | Give the manager a dirty flag so `Set-Surface 'manage'` rebuilds only when the model or a tick changed | **90 ms → ~0.4 ms** on every re-entry, matching the work direction | medium — needs the same invalidation points `$script:mgrItems` already uses |
| 3 | Precompute the sort key onto the row and use `Sort-Object -Property` | **24 ms → 3 ms** | low |
| 4 | Call `Get-AgeLabel` directly in `Build-Manager` (and hoist `[DateTime]::Now.Ticks` out of the loop) | **~32 ms** off the cold path | low — same function, one frame instead of two |
| 5 | Replace the two trailing `Where-Object` pipelines with one `foreach` | **7.4 ms** | none |
| 6 | `Set-TickOn`: update the one cached row instead of clearing `$script:mgrItems` | **~52 ms**, the warm/cold gap | medium — the cache-staleness argument at `:690` applies |
| 7 | Get `Update-Model -KeepAgents` + `Update-Surface` off the `SetApply` / `Rescan` click (defer, or hand the probe the work) | **~776 ms** | high — this is the correctness path both handlers exist to run |

Fixes 1, 3, 4 and 5 together are ~75 ms off a rebuild that currently costs 80 ms
warm and 132 ms cold, with no change to what is on screen. That still leaves the
manager an order of magnitude over a 7 ms bar; **fix 2 is the only one that
closes the gap**, because the cheapest rebuild is the one that does not happen.
