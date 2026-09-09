# The rebuild plan

One pass, worked top to bottom. Every item has a **done-when** you can check
without asking anybody — a command and its expected result, or an observable
state. An item with no done-when is not an item.

**Phases 0 and 1 are complete, and 2.1-2.2 with them.** Everything from 2.3 down
is still to do. The PowerShell tool remains the daily driver and is untouched by any
of it.

---

## The rule that makes this safe

🔑 **THE OLD TOOL IS THE ORACLE, AND IT STAYS RUNNING UNTIL THE NEW ONE PASSES.**

Every domain step below is verified the same way: run the PowerShell function
and the C# one **on the same real input** and diff the answers. Not "the C#
looks right" — *the same 434 conversations, the same 1 MB registry, the same
live console*, and a difference is a defect until explained.

This is available only because the rebuild is a rewrite *beside* a working
implementation rather than instead of one. It is the single biggest reason this
can be done in one pass at all, and it is why **the PowerShell is not deleted
until Phase 6 signs off**.

🔴 And the standing safety rules do not relax for a rebuild:
- Never launch, kill, type into, or sign into a session to test something.
- Never run either GUI against live data outside the fenced harnesses.
- `sessions-registry.json` and `session-restore.config.json` are live operator
  files. A registry-overwrite bug in this repo's history cost **210
  conversations**.

---

## Phase 0 — freeze the spec ✅ DONE

The rebuild's central risk is re-deriving, wrongly, a fact that took days to
establish. Those facts are already written down; this phase copies them out
where the rebuild can work through them.

| | what | done-when | state |
|---|---|---|---|
| 0.1 | Knowledge ledger | `python rebuild/tools/extract_knowledge.py` → 741 blocks | ✅ `02-KNOWLEDGE.md` |
| 0.2 | Capability surface | `python rebuild/tools/extract_surface.py` → 164 elements, 77 handlers | ✅ `01-CAPABILITIES.md` |
| 0.3 | External contracts | `python rebuild/tools/extract_contracts.py` → 36 P/Invoke, 25 settings | ✅ `03-CONTRACTS.md` |
| 0.4 | Behaviour spec | `python rebuild/tools/extract_behaviour.py` → 2.269 assertions | ✅ `04-BEHAVIOUR.md` |
| 0.5 | Target architecture | written, with the reasoning per decision | ✅ `05-ARCHITECTURE.md` |

🪝 **All four are re-runnable.** The PowerShell keeps moving while the rebuild
happens, so re-run them and diff before each phase rather than trusting a
snapshot.

---

## Phase 1 — scaffold ✅ DONE

| | what | done-when | state |
|---|---|---|---|
| 1.1 | .NET 8 solution, four projects per `05-ARCHITECTURE.md` | `dotnet build` clean, zero warnings, `TreatWarningsAsErrors` on | ✅ 0 warnings, 0 errors |
| 1.2 | `Nullable` and `ImplicitUsings` on; analyzers at `latest-recommended` | build stays clean with them enabled | ✅ plus `InvariantGlobalization` |
| 1.3 | Self-contained publish to **`dist/`** | the published exe runs and shows a window | ✅ 68,4 MB, window in 1.529 ms |
| 1.4 | A build script that says so when the SDK is absent | a machine without the SDK gets a sentence, not a stack trace | ✅ `src/build.ps1`, exit 3 |
| 1.5 | The differential-oracle harness | it can compare two trivial functions and report a difference | ✅ `sr-oracle`, 5 self-tests |

**Two corrections to this phase as it was originally written:**

🔴 **1.3 said "to the current `Sessions.exe` path", and that was wrong.** In
phase 1 it would overwrite the launcher the operator uses every day, before the
rebuild has replaced anything at all. It publishes `Sessions2.exe` into `dist/`;
the swap is item 6.1 and nothing points at the new one until then.

🪤 **1.4 said `Install.bat`, and that is premature.** Nothing uses the new exe
yet, so teaching the installer to build it would wire a dependency to a thing
with no callers. The SDK check lives in `src/build.ps1`; the `Install.bat`
wiring moves to **6.4**, where the rest of the launcher re-pointing already is.

**Publish size, measured rather than assumed:**

| | |
|---|---|
| self-contained, single file | 154,5 MB |
| **self-contained + compression** | **68,4 MB** ← what ships |
| framework-dependent | 0,2 MB (`-Framework`) |

Self-contained is chosen because the operator moves between machines, and a tool
that will not start because a runtime is absent is the exact silent failure
`app/SessionsHost.cs` was written to remove. `dist/` is gitignored, so the size
costs disk and copy time, not history.

🪤 **1.529 ms to a window is the SCAFFOLD, with no data in it** - against the
5,8 s the PowerShell takes. Do not read it as the startup target being met: the
model, the registry and the first paint are all still to come, and a compressed
single-file pays an extraction cost on its first run after each build.

🔑 **The oracle got 550x faster during this phase, and that mattered.** A fresh
`powershell.exe` dot-sourcing `lib/_common.ps1` (455 KB) cost **4,5 to 14,5
seconds** per comparison - five self-tests took 41 s. Phase 2 compares hundreds
of things against real data; at that price the safety net would simply not get
run. The session is now kept open and fed one comparison at a time down its
stdin: **14.539 ms → 26 ms**. Same trick the tool already uses for screen reads.

🪤 And two defects in the harness itself, both found before it was trusted:
`Run` was not serialised, so xUnit's parallel test classes would have interleaved
two comparisons on one pipe and invented differences about nothing; and the
timeout path disposed the semaphore from inside its own guarded region, so a
comparison that merely timed out came back as an `ObjectDisposedException`.

---

## Phase 2 — the domain, bottom-up

In dependency order. Each item ships with xUnit tests **and** a differential run
against the PowerShell on the operator's real data.

| | what | done-when | state |
|---|---|---|---|
| 2.1 | **Config** — the 25 settings, defaults, allowed values (`03-CONTRACTS.md`) | reads the operator's real config; every setting resolves to the same value; an untouched default is never written | ✅ 3 oracle cases, 13 tests |
| 2.2 | **Registry read** — typed model of `sessions-registry.json` | same conversation count, ids and ticks as `Get-SRRegistry` on the real 1 MB file | ✅ 3 oracle cases, 558 sessions x 13 fields |
| 2.3 | **Transcripts** — `.jsonl` reader, turn folding | same turn count and same last-said text as the PowerShell, over every conversation on disk | — |
| 2.4 | **Console API** — one class, the 36 imports (`03-CONTRACTS.md`) | a live screen read matches `Get-SRScreenText` character for character, and the attribute plane matches too | — |
| 2.5 | **Sessions / agents** — `claude agents --json`, `wt.exe`, process tree | the agent map matches, including `busy` | — |
| 2.6 | **Bands and titles** — `Get-Band`, `Get-Title`, the surface predicate | every conversation lands in the same band as the PowerShell puts it in | — |
| 2.7 | **Registry WRITE** — last, behind the guards | refuses every case the PowerShell refuses; the stale check still fires; verified against a *copy*, never the live file | — |

### 2.1 as it turned out

**The done-when was written as "round-trips it byte-identically" and that was
the wrong bar.** Matching PowerShell's `ConvertTo-Json -Depth 8` formatting
character for character buys nothing — after cutover the C# owns the format, and
both tools read JSON either way. What actually matters is that a write **keeps
what it did not come to change**, so the done-when is that instead: every key
survives a render, prose and commented-out keys included, and rendering with no
changes adds nothing.

🔴 **There were THREE places a default lived, not one.** `Get-SRConfigRead`'s
table in `_common.ps1` (15 keys), `$SR_CfgMeta`'s `Default` in the window (7),
and inline at the point of use (`$SR_TermColour = $true`, `$SR_YouGround =
'neutral'`). Where two of them define the same key they **agree** — checked, so
this was duplication rather than a live defect, but it is exactly the shape that
becomes one. `SettingsCatalog.g.cs` is the single table, and it is **generated**
from the PowerShell by `rebuild/tools/gen_settings.py` so it cannot drift while
both exist.

🪤 **The oracle earned itself on its first real comparison.** `railBandsShut`
came back as `week,month,older` where the operator's file says `month,older` —
the generator was reading choice lists from `Options` only, and this setting
declares its values under `Flags`, so it arrived with none allowed. Two defects,
and the second is the one that matters:

- the generator now reads both lists;
- **`Accepts` treated "no options declared" as "nothing is allowed"**, which
  turned a gap in generated code into a *silent reset of a real setting*. It
  reads the other way now — no declared options means nothing to check against,
  because when this code is wrong the safe thing is to keep what the operator
  wrote. The strictness moved into a test that fails if any Choice or Flags
  setting declares no options, confirmed red by re-injecting the defect.

### 2.2 as it turned out

**Agreed first time on all 558 conversations, every field** - and that is
precisely why it was then broken on purpose. Flipping one boolean on one row in
558 must be caught, and it was: `$.rows[0].pinned: PowerShell "true", C# "false"`.

🪤 **AND THE FIRST ATTEMPT AT THAT PROOF WAS ITSELF A FALSE GREEN.** The build
failed on an analyzer rule, `dotnet run --no-build` happily ran the PREVIOUS
assembly, and the deliberately-broken comparison came back **ok**. A stale green
is worse than a red: it is the harness reporting on something it did not check.
`src/build.ps1 -Oracle` exists now so the oracle can only run behind a build that
passed — the fix is structural rather than a note to remember.

🔴 **The two data files disagree about the byte-order mark.**
`sessions-registry.json` starts `EF BB BF`; `session-restore.config.json` does
not. Measured, not assumed. `ReadAllText` detects and strips it, but a reader
that hands raw bytes to a parser breaks on exactly one of the two - so both
readers state it, and a test writes a BOM'd file and reads it back.

🔴 **Every record carries a `[JsonExtensionData]` bag, and that is for 2.7.** A
registry written by a newer build carries fields this one does not model; a model
that drops them turns the next save into a silent delete. Tested at all three
levels - file, directory and session.

🔴 **The v1 and v2 migrations are deliberately NOT ported.** They rewrite the
operator's ticks in place - v2→v3 re-parents every session onto its repo rather
than its working directory - and the only file available to test them against is
already v3, so a port would be code that has never once run on its own input.
The PowerShell still has both and still runs, so an old registry is **refused
with advice** ("open Sessions.exe once"), not migrated by something unexercised.
*Deferred; trigger: a v1 or v2 registry actually turns up.*

**Reading is 8x faster than the PowerShell** on the same file (13 ms against
106), which is a by-product rather than the point - the point is that they agree.

🔴 **2.7 is last on purpose.** Nothing writes until everything reads correctly.
The guards are ported before the writer they guard, and they are ported as
**types** (`05-ARCHITECTURE.md` §4), not as calls somebody has to remember.

🪤 **2.4 is the one with no documentation to fall back on.** What is known about
ConPTY here was measured, not read: the pseudo-console buffer is the size of the
viewport, so **there is no scrollback**; the attribute plane is 4-bit against
claude's 24-bit VT, so colour is a 16-value approximation. Both are in the
ledger. Re-deriving them costs the same days again.

---

## Phase 3 — the view models

| | what | done-when |
|---|---|---|
| 3.1 | `ConversationVm` with `INotifyPropertyChanged`, bound once | changing one property repaints one row and does not rebuild the list |
| 3.2 | `ICollectionView` for sort, filter and search | `tests/rebuild-bench.ps1`'s equivalent measures a keystroke **< 16 ms** with a frame |
| 3.3 | The bands as grouping, not as constructed heading rows | a conversation moving band does not rebuild the column |
| 3.4 | The background loops replacing the 11 timers | the cadences in `01-CAPABILITIES.md` are preserved, with their measured values |

🔴 **3.2 is the item this whole rebuild is justified by.** If it does not land
under 16 ms, stop and find out why before building any more of the view.

---

## Phase 4 — the view

| | what | done-when |
|---|---|---|
| 4.1 | Port `window2.xaml`, replacing imperative updates with bindings | the window opens and every control in `01-CAPABILITIES.md` is present |
| 4.2 | Wire the 77 handlers | every row of the capability table has its handler, and the 101 unwired elements are each confirmed as label/container or deleted |
| 4.3 | Keyboard: the tunnel order from `01-CAPABILITIES.md` | the terminal watcher receives Escape, `/` and `l`; the settings panel still closes on Escape |
| 4.4 | The reading pane, virtualized | a 2,5 MB conversation opens without a tail budget, and the alignment harness still passes |
| 4.5 | Animation: transitions on the gestures that now have headroom | no gesture exceeds 16 ms while an animation is running |

🪤 **4.4 last of the view work.** The typography was tuned against rendered
pixels, not against a description, and it is the easiest thing here to break
without noticing.

---

## Phase 5 — behaviour parity

| | what | done-when |
|---|---|---|
| 5.1 | Work the checklist in `04-BEHAVIOUR.md` | every one of the 2.269 items is either an xUnit test that passes, or struck out with a written reason |
| 5.2 | Re-run every extractor against the *new* source | the capability surface matches; nothing was quietly dropped |
| 5.3 | The fenced shown-window harness, ported | it can go red, and the danger counters are asserted zero |
| 5.4 | The acceptance targets in `05-ARCHITECTURE.md` | every gesture is inside its budget, measured **with a frame** |

🪤 **5.1 is the largest single item in this plan** and the one most likely to be
under-estimated. Budget it at roughly 40% of the whole rebuild. It is also the
only thing standing between "it looks finished" and "it is finished".

---

## Phase 6 — cutover

| | what | done-when |
|---|---|---|
| 6.1 | `SessionsHost` opens either window behind a switch | both start; the switch is a setting, not a rebuild |
| 6.2 | Run the new one as the daily driver, old one one keystroke away | a week of daily use with no fallback |
| 6.3 | Retire the PowerShell window | `lib/sessions-window.ps1` moved to an archive folder, not deleted |
| 6.4 | Re-point `Install.bat`, the scheduled tasks and the desktop button | a fresh logon restores sessions through the new path |

🔴 **6.3 moves, it does not delete.** The moment the PowerShell is gone, the
oracle is gone — and so is the only way to answer "did it always do that?"

---

## What is deliberately NOT in this plan

- **New features.** The rebuild is at parity or it is not finished. Anything
  wanted on top goes on a separate list and waits.
- **The retired window** and the suites that drive it.
- **A port of the PowerShell test harness.** Its assertions carry over; its
  splicing machinery has no reason to exist once the domain is a library.

## The known risks

| risk | what it looks like | what holds it |
|---|---|---|
| A measured fact gets re-derived wrongly | "it works" and then a class of sessions is invisible | `02-KNOWLEDGE.md`, 741 blocks, read before touching a subsystem |
| Parity is declared on a partial checklist | quiet regressions found weeks later in daily use | 5.1 — every item struck out with a reason, not silently |
| The rebuild stalls half-ported | two half-tools and no working one | the old one keeps running and stays the default until 6.2 |
| The 16 ms target is not reached | months spent and the same lag | 3.2 gates the rest of the view work |
| Typography drifts | it looks subtly worse and nobody can say why | 4.4 last, alignment harness kept |
