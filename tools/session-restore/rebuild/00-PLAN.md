# The rebuild plan

One pass, worked top to bottom. Every item has a **done-when** you can check
without asking anybody — a command and its expected result, or an observable
state. An item with no done-when is not an item.

**Nothing in this plan is started.** Phase 0 is complete; everything below it is
work to be authorised.

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

## Phase 1 — scaffold

| | what | done-when |
|---|---|---|
| 1.1 | .NET 8 solution, four projects per `05-ARCHITECTURE.md` | `dotnet build` clean, zero warnings, `TreatWarningsAsErrors` on |
| 1.2 | `Nullable` and `ImplicitUsings` on; analyzers at `latest-recommended` | build stays clean with them enabled |
| 1.3 | Self-contained publish to the current `Sessions.exe` path | the published exe runs and shows an empty window |
| 1.4 | `Install.bat` learns to build it, and to say so when the SDK is absent | a machine without the SDK gets a sentence, not a stack trace |
| 1.5 | The differential-oracle harness: run a PS function and a C# one on one input, diff | it can compare two trivial functions and report a difference |

🔴 **1.5 before any domain code.** It is the thing every step below leans on;
building it after the first port means the first port was never verified.

---

## Phase 2 — the domain, bottom-up

In dependency order. Each item ships with xUnit tests **and** a differential run
against the PowerShell on the operator's real data.

| | what | done-when |
|---|---|---|
| 2.1 | **Config** — the 25 settings, defaults, allowed values (`03-CONTRACTS.md`) | reads the operator's real config; round-trips it byte-identically; an untouched default is never written |
| 2.2 | **Registry read** — typed model of `sessions-registry.json` | same conversation count, ids and ticks as `Get-SRRegistry` on the real 1 MB file |
| 2.3 | **Transcripts** — `.jsonl` reader, turn folding | same turn count and same last-said text as the PowerShell, over every conversation on disk |
| 2.4 | **Console API** — one class, the 36 imports (`03-CONTRACTS.md`) | a live screen read matches `Get-SRScreenText` character for character, and the attribute plane matches too |
| 2.5 | **Sessions / agents** — `claude agents --json`, `wt.exe`, process tree | the agent map matches, including `busy` |
| 2.6 | **Bands and titles** — `Get-Band`, `Get-Title`, the surface predicate | every conversation lands in the same band as the PowerShell puts it in |
| 2.7 | **Registry WRITE** — last, behind the guards | refuses every case the PowerShell refuses; the stale check still fires; verified against a *copy*, never the live file |

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
