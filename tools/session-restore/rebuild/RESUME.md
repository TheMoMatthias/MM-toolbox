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
| **2.6** | **bands and titles** | ⏸ **start here** |
| 2.7 | registry WRITE | ⏸ last on purpose |
| 3-6 | view models, view, parity, cutover | ⏸ |

**161 xUnit tests, 30 oracle cases. Nothing in the C# has written to any live
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

---

## 2.6, which is where to start

Bands and titles: `Get-Band`, `Get-Title`, and the surface predicate. Every
conversation has to land in the same band the PowerShell puts it in, and the
title has to come out identical for all 558 - the shapes that bite are worktrees
named after the conversation inside them and 27 projects whose leaf names
collide.

Both live in `sessions-window.ps1`, so they are reached the same way 2.5c
reached `Get-LaunchBlock`: **splice the function's own source out by name and
define it in the oracle's session.** See `LaunchCases.PlanPreamble` - it is four
lines, and it runs the shipped body rather than a copy of it. 🪤 A `foreach`
body shares its caller's scope and a *function* does not, so the
`Invoke-Expression` has to sit in the loop, not in a helper.

After that: **2.7**, the registry write, which is last on purpose.

---

## 2.5c is done, and this is the part worth knowing

🔑 **A PLAN IS A VALUE; ONE CALL TURNS IT INTO PROCESSES.** To get that shape the
PowerShell was split: `Get-SRLaunchCommandLine` returns the wt.exe command line
and `Start-SRSession` is the only thing that hands it to a process. Nothing about
either behaviour changed - but the quoting that once killed every AlgoTrader tab
is now compared over every real project path on the machine, without opening a
conversation to do it. **`SessionRestore.Core.Launch` has no method that starts
or ends anything at all**, and that absence is the guard until Phase 4.

🔴 **AND THE LESSON THAT GENERALISES: A GREEN OVER LIVE DATA PROVES ONLY THE PATHS
LIVE DATA REACHES.** `launch/settings` walked all 560 conversations, agreed
everywhere, and did not go red when the `--model` branch was deliberately broken
- because **no session in the registry has a `prefs` object at all**. The fix was
to substitute the data source, not to weaken the check: `launch/settings-shapes`
carries 22 shapes and each branch was seen to go red through it. **Any future
item should ask what fraction of its own branches the live data actually
exercises before trusting its green.**

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

🔑 **All three were found by running the old code over EVERYTHING** rather than
over the cases that happen to be exercised. That is what the oracle is for, and
it is the strongest argument for keeping the PowerShell alive until Phase 6.
