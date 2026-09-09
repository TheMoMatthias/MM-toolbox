# Resume here

**Written 2026-09-09, end of the first rebuild session. Everything is committed
and pushed; the working tree is clean.**

Last commit: `51a7e12`. Branch `main`.

---

## Read these three, in this order

1. **`00-PLAN.md`** — where everything is. Every finished item has an "as it
   turned out" section under Phase 2 saying what it cost and what it found.
2. **This file** — what to do first tomorrow.
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
| 2.3b | blocks | ✅ 40 conversations, every field |
| 2.4a | console read | ✅ 22 live screens, character for character |
| 2.4b | console write + server | ✅ replica console; 26 consoles in 25 ms |
| 2.5a | agent map | ✅ 28 sessions, field by field |
| **2.5b** | **the three sub-agent readers** | ⏸ **start here** |
| 2.5c | launching and ending | ⏸ |
| 2.6 | bands and titles | ⏸ |
| 2.7 | registry WRITE | ⏸ last on purpose |
| 3-6 | view models, view, parity, cutover | ⏸ |

**100 xUnit tests, 17 oracle cases. Nothing in the C# has written to any live
file, and nothing has typed into a conversation.**

---

## Do this first tomorrow

```
powershell -NoProfile -ExecutionPolicy Bypass -File src\build.ps1 -Oracle
```

That builds, runs 100 tests, then runs all 17 comparisons against the live
PowerShell. **It should be all green.** It takes a few minutes, most of it the
console comparison waiting a second per session on purpose.

🪤 **If `console/screens` or `transcript/blocks-*` reports a difference, read the
allowance line before believing it.** Those compare against things that move -
a screen redraws, a transcript grows - and a run where the operator was working
hard can legitimately forgive a row. A difference that is NOT forgiven is real.

---

## 2.5b, which is where to start

Port these three from `lib/_common.ps1`, in this order:

| function | line | what it answers |
|---|---|---|
| `Get-SRSubAgentDir` | 5736 | where a conversation's sub-agents live |
| `Get-SRSubAgents` | 5756 | which ones exist |
| `Get-SRAgentLastLine` | 6001 | what one of them last said |
| `Get-SRLiveTasks` | 6100 | which are still running, and which shells |

🔑 They belong to 2.5 rather than 2.3 because they answer **what is running**,
not what a transcript says — even though they read a transcript to do it.

🪤 `Get-SRLiveTasks` reads over a **tail**, so it answers "what is running now"
and NOT "what has ever run". The chip on screen means the former. Do not
re-point it at the latter without changing what the chip says.

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

## What was found in the shipped PowerShell today

Both fixed, committed, and confirmed with gui2 and state both PASS:

1. **Escape never reached the terminal** — `PreviewKeyDown` tunnels, so the
   window's handler ran first, swallowed the key and moved the focus. Rewind was
   never broken; it was never being asked for. `/` and `l` were being eaten too.
2. **Five kinds of block carried the previous record's timestamp** — found by
   the rebuild's oracle, 36 ms out, which is a record boundary rather than a
   rounding.
