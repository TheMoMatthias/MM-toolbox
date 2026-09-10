# Resume here

**Kept current. Last updated 2026-09-10. Everything is committed and pushed;
the working tree holds only the operator's own live files.**

Last commit: see `git log`. Branch `main`.

---

## Read these three, in this order

1. **`00-PLAN.md`** — where everything is. Every finished item has an "as it
   turned out" section under Phase 2 saying what it cost and what it found.
2. **This file** — what to do first, and where to pick up.
3. **`05-ARCHITECTURE.md`** — only if a design question comes up.

---

## The state in one table

| | | |
|---|---|---|
| Phase 0 | freeze the spec | ✅ 741 facts, 2.269 assertions extracted |
| Phase 1 | scaffold + oracle | ✅ 4 projects, warnings are errors |
| 2.1 | config | ✅ 25 settings, one catalogue |
| 2.2 | registry read | ✅ 558 conversations × 13 fields |
| 2.3a | last said | ✅ all 546 transcripts |
| 2.3b | blocks | ✅ 15 conversations, every field, + a widening fixture |
| 2.4a | console read | ✅ 22 live screens, character for character |
| 2.4b | console write + server | ✅ replica console; 26 consoles in 25 ms |
| 2.5a | agent map | ✅ 28 sessions, field by field |
| 2.5b | the three sub-agent readers | ✅ 386 sub-agents, 326 last lines |
| 2.5c | launching and ending | ✅ 428 planned over, 0 launched |
| 2.6 | bands and titles | ✅ 428 banded, every route proven |
| 2.7 | registry WRITE | ✅ 562 written and read back; live file never opened |
| 3.1 | rows bound once | ✅ proven: no rebuild of the source |
| 3.2 | a keystroke under 16 ms | ✅ **2,1 ms**, live filtering, no Reset |
| 3.3 | bands as grouping | ✅ one row Moves between headings, no Reset |
| 3.4 | the background loops | ✅ 12 cadences, drift-checked |
| 3.5 | the whole-list gestures | ⏸ carried to 4.1 |
| **4** | **the view** | ⏸ **start here** |
| 4-6 | the view, parity, cutover | ⏸ |

**221 xUnit tests, 42 oracle cases. PHASE 2 IS COMPLETE. Nothing in the C# has written to any live
file, nothing has typed into a conversation, and nothing has launched or ended
one - the Launch namespace has no method that could.**

---

## Do this first

```
powershell -NoProfile -ExecutionPolicy Bypass -File src\build.ps1 -Oracle
```

That builds, runs the tests, then runs every comparison against the live
PowerShell. **It should be all green, in about 70 seconds of oracle** - most of
that the console comparison waiting a second per session on purpose, plus the
11 s `transcript/last-said` walk over every transcript on the machine.

🪤 **If it takes much longer than that, something is wrong with the HARNESS
rather than the code.** That happened on 2026-09-10: a sample that had outgrown
itself as the transcripts grew, a body being copied once per block, and a read
whose deadline could never fire. All three are fixed and written up in
`00-PLAN.md`; the shape of the lesson is that this check has to stay fast or it
stops being run.

🪤 **And you cannot build while it is running** - `sr-oracle` holds the Core DLL,
so a build fails with "the file is locked by sr-oracle". Let it finish, or kill
it.

🪤 **If `console/screens` or `transcript/blocks-*` reports a difference, read the
allowance line before believing it.** Those compare against things that move -
a screen redraws, a transcript grows - and a run where the operator was working
hard can legitimately forgive a row. A difference that is NOT forgiven is real.


🪤 **AND A CASE THAT REDS ONCE AND PASSES TWICE IS ALMOST CERTAINLY THE
OPERATOR WORKING, NOT A DEFECT.** Several cases read things that move while ~30
conversations are live. Each has a named allowance, and the shape they all need
is the same - so when one goes red intermittently, check these before anything
else:

1. **Does the "it moved" marker fill EVERY field the PowerShell emitted?** A
   partly-marked row reports its remaining fields as *"present in PowerShell,
   missing in C#"*, and those lines match no allowance. This has now bitten
   `launch/processes`, `subagents/live-tasks` and `transcript/last-said`.
2. **Is the allowance checked line by line**, rather than with `EndsWith` on the
   whole difference text?
3. **Does the case still fail if nothing was compared?**

🔴 `transcript/blocks-detail` was seen red once and green twice on
2026-09-10 and is **still open**: its sample is the 15 newest conversations,
which are precisely the ones being written to. Reproduce it by running the oracle
while working, then apply the three checks above.

---

## Phase 4, which is where to start - and 4.1 inherits two measurements

**Phases 0-3 are done.** A search keystroke is **2,1 ms** with a real frame,
against **512 ms** in the PowerShell.

```
src\SessionRestore.Appin\Release
et8.0-windows\Sessions2.exe --bench --repeats 40
```

Exit 0 means every gesture landed inside a frame AND every binding check passed.
**It exits non-zero today, honestly** - see 3.5 below.

**4.1 is the XAML port**, and it arrives carrying two things that were
deliberately not chased:

| what | measured | why it waited |
|---|---|---|
| cycling the sort | ~21 ms | `SortDescriptions` Reset, then re-layout of 428 rows |
| clearing a search / project / only-live | 65-115 ms | grouping, on a whole-list **widen** |

🔴 **BOTH ARE VIRTUALIZATION QUESTIONS AND NEITHER CAN BE ANSWERED HONESTLY
YET.** The bench binds a placeholder `ListBox` with `DisplayMemberPath` and **no
`GroupStyle` at all**, so WPF is building group containers with nothing to build
them from. Tuning container recycling and row height against that is tuning the
wrong thing. `VirtualizingPanel.IsVirtualizingWhenGrouping` is already on - it is
the least discoverable line in the view layer, since grouping turns
virtualization off by default - and it was **not** what was costing.

🪤 **AND EVERY NUMBER ABOVE WAS TAKEN AT 35-65% CPU with 29 live
conversations**, one worst-case reading 684 ms. Re-measure on a quiet machine
before believing any absolute figure; only the 13 -> 70 kind of jump survived all
three load levels.

---

## What Phase 3 established

🔴 **1. TWO "OBVIOUS" FIXES WERE TRIED AND BOTH WERE WORSE.** Written down so
they are not re-derived:

- **"One Reset when most rows move"** is right in principle - 428 notifications
  against one Reset - but the only lever is toggling `IsLiveFiltering`, which
  makes the view rebuild its own tracking over every item: a keystroke went
  **2,1 -> 25,5 ms**.
- **`IsLiveSorting = false`** bought nothing measurable and would have cost
  something real: a conversation whose `lastActive` moves on a background refresh
  has to rise to the top of a recent-first list.

🔴 **2. A CHECK HAD TO BE TOLD WHAT IT WAS FOR, THREE TIMES.** Each passed
while the thing it named was untrue:

| the check | passed because |
|---|---|
| "no rebuild on a gesture" | it watched the `ObservableCollection`; a ListBox binds to the **VIEW** |
| "the VIEW does not Reset" | the view had **stopped filtering entirely** |
| "a conversation moving band does not rebuild" | the row **had not moved** - `groups 1 -> 1` |

🔑 **The pattern in all three: the check asked what must NOT happen and never
asked whether the thing itself still worked.** The questions that broke them open
were `428 -> 0 -> 428` and *did it land in the new group* - and both needed a
**dispatcher pump before counting**, because WPF applies live shaping through the
dispatcher and a count on the next line reads the previous set.

---

## Phase 2 is complete - what it cost and what it found

**41 oracle cases, 218 xUnit tests.** Nothing in the C# has written to any live
file, typed into a conversation, or launched or ended one.

**Five live defects found in the shipped PowerShell**, all fixed, all with gui2
and state passing afterwards - see `00-PLAN.md` for each. The pattern in all five
is the same: they were found by running the old code over **everything**, rather
than over the cases that happen to be exercised.

**Three behaviour-preserving splits of the shipped tool**, each turning an act
into a value so it could be compared without being performed:

| what | was | is now |
|---|---|---|
| the wt.exe command line | inside `Start-SRSession`, reachable only by launching | `Get-SRLaunchCommandLine`, a string |
| the registry stale check | inside `Save-SRRegistry`, which is FENCED | `Get-SRSaveRefusal`, a sentence |
| the launch plan | already a value (`Get-TickedPlan`) | unchanged, and the C# matches its shape |

---

## What Phase 2 established, beyond its own items

🔑 **1. A PLAN IS A VALUE; ONE CALL TURNS IT INTO PROCESSES.** The PowerShell
was split to get that shape - `Get-SRLaunchCommandLine` returns the wt.exe
command line, `Start-SRSession` is the only thing that hands it to a process.
**`SessionRestore.Core.Launch` has no method that starts or ends anything at
all**, and that absence is the guard until Phase 4.

🔴 **2. A GREEN OVER LIVE DATA PROVES ONLY THE PATHS LIVE DATA REACHES - AND
THIS IS NOW THE FIRST QUESTION TO ASK OF ANY CASE.** Three separate times:

| the case | it agreed over | and yet |
|---|---|---|
| `launch/settings` | all 560 conversations | **no session has a `prefs` object at all** - every row was the default path, and breaking `--model` stayed green |
| `bands/live` | all 428 | 399 are *quiet*, reached three different ways; most of `Get-Band` was untouched |
| `bands/on-surface` | all 560, twice | the "coldest" row it picked is **live**, so the clause under test was never reached |

The fix is always the same and it is never "widen the check": **substitute the
data source**, with the shapes spelled identically on both sides, and then break
each branch and watch it go red. `launch/settings-shapes` and `bands/shapes` are
the pattern.

🪤 **3. A MARKER GOES IN EVERY FIELD THE OTHER SIDE EMITTED.** A row this
side cannot answer for must carry its reason in *all* of the other side's fields,
or the unmarked ones report "present in PowerShell, missing in C#" and match no
allowance. This bit twice - `launch/processes` and then `subagents/live-tasks`,
where it made the case **intermittently** red, which is worse than red because it
teaches you to re-run.

🪤 **4. AN ALLOWANCE IS CHECKED LINE BY LINE.** `subagents/live-tasks` used
`EndsWith` on the whole difference text, so it inspected one line and forgave all
of them. Every allowance now splits the text and requires that EVERY line be one
it named.

🔴 **5. AN ALLOWANCE THAT COVERS THE ONLY FIELD IS AN OFF SWITCH.**
`write/stamp` had one field and forgave any difference in it, so it could not go
red at all. Ask of every tolerance: *what is left that could still fail?* If the
answer is nothing, the case is decoration.

🔴 **6. A ROUND-TRIP INSIDE ONE IMPLEMENTATION PROVES NOTHING ABOUT A FIELD
BOTH HALVES DROP.** `write/read-back` re-read the file it had just written, so a
lossy writer and a matching reader agreed with each other perfectly. Compare
**intent against the other tool's reader**, not output against your own.

🔴 **7. AN ASSERTION ONLY ONE SIDE MAKES IS NOT COMPARED.** It arrives as
"present in C#, missing in PowerShell" and gets swallowed by the allowance
covering exactly that shape. Make both sides answer the same question a different
way.

---

## The four things that keep being true

🔑 **1. The old tool is the oracle, and it stays running until the new one
passes.** Every domain step is verified by running the PowerShell and the C# on
the same real input and diffing. "The C# looks right" is not a check.

🔑 **2. Everything this tool reads is MOVING**, and three comparisons have now
needed the same four-part shape: record what state was read → answer about that
same state or say you could not → tolerate the difference **by name**, narrowly,
printed every time → and **fail if nothing was compared**. 🪤 What must never
happen is the C# side echoing the PowerShell's answer back — that turns a
limitation into a pass.

🔴 **3. A green is not evidence until it has been seen to go red.** Every
finished item was deliberately broken once and the break was caught: a flipped
boolean in one row of 558, a character appended to a headline, the control bit
dropped from a chord, a bang on every agent status.

🔴 **4. `dotnet run --no-build` after a FAILED build runs the previous
assembly.** It reported a deliberately-broken comparison as **ok**. Always go
through `src\build.ps1`, which gates the oracle behind a build that passed.

---

## Two things waiting on the operator, not on code

- 🔴 **The window needs restarting.** Today's fixes to the PowerShell tool — the
  Escape/rewind key routing, and the block-timestamp defect the rebuild found —
  are in `lib\` but not in the running window.
- **Rewind** is still blocked on the Esc-Esc screen capture. 🔴 Do not
  reconstruct that screen from memory or inference; see
  `reference_rewind_brief` in memory.

---

## What the rebuild has found in the SHIPPED PowerShell

All fixed, committed, and confirmed with gui2 and state both PASS:

1. **Escape never reached the terminal** — `PreviewKeyDown` tunnels, so the
   window's handler ran first, swallowed the key and moved the focus. Rewind was
   never broken; it was never being asked for. `/` and `l` were being eaten too.
2. **Five kinds of block carried the previous record's timestamp** — 36 ms out,
   which is a record boundary rather than a rounding.
3. **`Get-SRAgentLastLine` threw on every single-line answer** — `(pipeline)[0]`
   on a pipeline that yielded one element indexed into a *string* and handed back
   a `[System.Char]`. Its caller catches and falls back to `'starting'`, so a
   running sub-agent that had said something showed **"starting" for ever**.
4. **The boot script the tool writes carried nine bytes of mojibake.** This file
   is UTF-8 with no BOM and the machine's ANSI codepage is 1252 (measured), so
   PowerShell 5.1 read the 🔴 inside the boot-script here-string as four
   Latin-1 characters. Found as a five-byte length difference.
5. **The settings label was going to the window mojibaked** — the same trap on a
   *displayed* string: a literal middot in `Get-SRSessionArgsLabel`, so a row
   would have read `max  Â·  plan`. 🔑 A scan found **zero** other non-ASCII
   string literals across the three `.ps1` files, so this was the single leak.

🔴 **And one live SEMANTIC difference, ported rather than "fixed":**
PowerShell's `[int]` / `[long]` casts round half to **even**, so `Get-AgeLabel`
reads 3m31s as **"4m"** and 90 s minus a tick as **"2m"**. C# integer division
truncates and disagreed at every half-unit boundary. It feeds the repaint
fingerprint as well as the label, so the two had to match.

🔑 **All three were found by running the old code over EVERYTHING** rather than
over the cases that happen to be exercised. That is what the oracle is for, and
it is the strongest argument for keeping the PowerShell alive until Phase 6.
