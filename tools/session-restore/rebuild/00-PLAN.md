# The rebuild plan

One pass, worked top to bottom. Every item has a **done-when** you can check
without asking anybody — a command and its expected result, or an observable
state. An item with no done-when is not an item.

**PHASE 2 IS COMPLETE.** Phases 0 and 1, and every item from 2.1 to 2.7.

✅ **3.1 AND 3.2 ARE DONE.** A search keystroke is **2,1 ms** with a real frame,
against 512 ms in the PowerShell. Two whole-list gestures - cycling the sort and
toggling only-live - are still one frame over, and are recorded below as 3.5. The PowerShell tool remains the daily driver and is untouched by any
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
| 2.3a | **Transcripts: last said** — the tail reader and the headline | same last-said text, pending tool and timestamp over every conversation on disk | ✅ 2 oracle cases, 546 transcripts |
| 2.3b | **Transcripts: blocks** — `Get-SRTranscriptBlocks`, the reading model | same blocks, same order, same fields over a 40-conversation sample | ✅ 2 oracle cases + a defect found in the PowerShell |
| 2.4a | **Console API: reading** — attach, read, detach | a live screen matches `Get-SRScreenText` character for character | ✅ 22 live screens, 1 oracle case |
| 2.4b | **Console API: the pipe server, and WRITING** | a held-open helper matches the spawn-per-read; keys land in a REPLICA console this tool owns | ✅ 26 consoles in 25 ms; `hello<tab><ctrl-c>` in a real console |
| 2.5a | **The agent map** — `claude agents --json` | the map matches, including `busy` | ✅ 28 sessions, field by field |
| 2.5b | **The sub-agent readers** — `Get-SRSubAgents`, `Get-SRLiveTasks`, `Get-SRAgentLastLine` | the same sub-agents and shells over every conversation with any | ✅ 386 sub-agents, 326 last lines, 25 conversations |
| 2.5c | **Launching and ending** — `wt.exe`, `taskkill`, the process tree | a launch plan matches; NOTHING is launched or killed to prove it | ✅ 10 cases, 428 conversations planned over, 0 launched |
| 2.6 | **Bands and titles** — `Get-Band`, `Get-Title`, the surface predicate | every conversation lands in the same band as the PowerShell puts it in | ✅ 7 cases, 428 banded, every route proven |
| 2.7 | **Registry WRITE** — last, behind the guards | refuses every case the PowerShell refuses; the stale check still fires; verified against a *copy*, never the live file | ✅ 4 cases, 562 conversations through a real write, the live file never opened |

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

### 2.3a as it turned out

**Agrees over every one of the 546 transcripts on this machine** - the headline,
the pending tool, the timestamp and both ends of the full message. PowerShell
11,1 s, C# 1,08 s for the same work. Confirmed red by appending one character to
any headline over 30 characters.

🔴 **Scope call: the three sub-agent readers moved to 2.5.** `Get-SRSubAgents`,
`Get-SRLiveTasks` and `Get-SRAgentLastLine` read a transcript, but what they
answer is *what is running now* - which is the agent map's question, not the
transcript's content. Keeping them here would have made 2.3 unfinishable in one
piece.

🪤 **THE BODY CAP TAKES THE TAIL, NOT THE HEAD.** What is still open is written
at the *close* of a message, so a cap that kept the first 4.000 characters would
throw away the only part anything reads it for.

🪤 **And a difference the oracle reported was about the harness, not the code.**
The first version of the markdown fixtures was built out of C# string
concatenation with backtick escapes and produced 13 fixtures where there are 10.
There is now not one backtick in that PowerShell: single quotes and an explicit
`[char]10` have one meaning each.

### 2.3b as it turned out — and the oracle found a live defect

🔴 **`Get-SRTranscriptBlocks` was stamping five kinds of block with the WRONG
TIME, in the shipped tool.** `New-Block` closes over `$recWhen`, and `$recWhen`
was assigned only in the user/assistant branch - so every **system, compact,
hook, file and queued** block carried the *previous* conversation record's
timestamp. It surfaced as the two sides agreeing on every field of a block
except `when`, 36 ms apart: a record boundary, not a rounding.

🪤 **The queue-operation branch already carried a note about exactly this
hazard** and had fixed it *locally, for itself* - which is why the whole thing
read as handled. Same defect class as the `$scr` off-by-one found in the window
the same day: **an unassigned local in a loop is not empty, it is last round's.**
Fixed in `lib/_common.ps1` by reading the timestamp once, at the top of the
record, before any branch can run; both local fixes removed.

**Three more differences, each real and each decided rather than papered over:**

| what the oracle said | what it was | what changed |
|---|---|---|
| one block whose every property was an array | `@(Get-SRTranscriptBlocks …)` on a comma-guarded return gives ONE element, and member enumeration then reads every kind at once | the harness: assign first, wrap second |
| `"lane position 3,8s"` vs `"3.8s"` | `InvariantGlobalization` made **display** invariant too, on a German machine | the property is gone; comparisons are ordinal because they *say so*, and CA1307/CA1310 are errors |
| `a.png b.png` vs `["a.png","b.png"]` | a tool argument that is a list | the C#: PowerShell's shape is the better one on a reading surface |

🪤 **Scoped to 40 conversations, not all 546, and the reason is what it costs:**
this reads a 2 MB tail per conversation, so running it over everything would
read the better part of a gigabyte to answer a question about a pane that only
ever parses ONE conversation - the selected one. The sample is the most recently
active, which is what the surface shows.

🪤 **And the diff now walks the left side's own key order.** Sorting
alphabetically put `bodyLen` ahead of `kinds` and reported a body-length
difference on a row whose block *sequence* was the thing worth looking at. Key
order is still not a difference; it is just the right order to look in.

### 2.4a as it turned out

**22 of the operator's live sessions read character for character by both
implementations.** One moved between the two sides and is reported as such.

🔴 **NOTHING IN THE C# CAN TYPE INTO A SESSION YET, and that is deliberate rather
than incidental.** `WriteConsoleInputW` is absent from `ConsoleApi`, from Core
and from this phase; it arrives at **2.4b** with a replica console of its own to
be proven against, the way `tests/term-replica.ps1` proves the PowerShell's.

🔴 **The attaching happens in a helper process (`sr-screen`), never in the
window.** A process can be attached to only one console at a time, and attaching
hands it somebody else's - a UI process doing that would have its own standard
handles and Ctrl+C behaviour redefined underneath it. The answer comes back
through a FILE rather than stdout, which is the PowerShell's own measured
lesson: a child that has just freed its console is not something to trust a
redirected stream to.

🪤 **A LIVE SCREEN MOVES, and that is a fact about the thing being read.** Both
sides read twice - the PowerShell with a full second between, which is long
enough to mean "idle" - and only screens that held still are compared. Three
things came out of getting that right:

- The first version handled "still for them, moving for us" by **echoing the
  PowerShell's own text back**, which turns a limitation into a pass. That is
  the one thing the oracle's contract forbids outright; it now says so in its
  own words and the difference is reported.
- The allowance is **named, narrow and printed every time it is used** - exactly
  two difference shapes, and any other difference in any other field still
  fails.
- `JsonDiff` collects **every** difference now, not the first. A tolerance
  applied to the first alone would let a forgiven row hide every real difference
  behind it, silently widening into "ignore this case".

🔴 **And it refuses to be green having checked nothing.** If every session
happened to be working, the case would compare nothing and pass - so it emits a
row saying so, and the run prints how many screens it actually held to a
comparison.

### 2.4b as it turned out

**The write path is proven against `tests/term-replica.ps1`** - the same real
console with a real input queue the PowerShell suite uses, deliberately, because
two implementations proven against one stand-in are comparable and two proven
against two are not. `hello<tab><ctrl-c>` arrives as itself.

🔴 **And it was then broken on purpose.** Dropping the control bit from
`SendChord` gave `hello<tab>` - the chord vanished entirely, because a chord
without it is a bare `c` and the character 0x03 is below the replica's threshold.
That is the whole content of the "a chord is three fields" rule, demonstrated
rather than asserted.

🔒 **The guard is a TYPE.** `ConsoleWriter` takes a `ConsoleTarget`, which has no
public constructor - the only public way to get one is `ForSession`, which
refuses anything that is not a live `claude` process and says what it found
instead. A new call site cannot forget the check; it cannot be written without
it. The test escape hatch (`ForOwnedConsole`) is `internal`, so it stays inside
the assembly the tests live in rather than on the public surface.

🔴 **The server was measured before it was built, and again after** - over the
operator's 26 live consoles:

| | |
|---|---|
| spawned, one process per read | **1.673 ms** (51,7 ms each) |
| the PowerShell's own held-open pipe | 63 ms |
| **this** | **25 ms** (0,9 ms each) |

Spawning is eleven times over a 150 ms sweep budget before anything is drawn, so
the server is not an optimisation but the difference between the design working
and not. 🪤 The test asserts a **direction, not a figure** - a threshold in
milliseconds is a fact about whichever machine runs it, and this repo has already
withdrawn speed claims made that way.

🪤 **Framed by length, not by a sentinel:** console text can contain anything at
all, including whatever separator looked safe. And the protocol lives in `Core`
so the client that builds a request and the server that reads one share one
definition - two copies of a wire format is two things to keep in step, and the
one that drifts is the one nobody looks at.

🪤 **One request at a time down the pipe**, for the reason the oracle's own
session already taught: two in flight would each read part of the other's answer,
producing screens that are real, reproducible under load, and belong to the wrong
session.

### 2.5a as it turned out

**28 of the operator's sessions compared field by field** - status, what each is
waiting for, pid, kind, name, cwd and start time. Confirmed red by appending one
character to every status.

🪤 **The same moving-target discipline as a screen, milder.** A session goes from
busy to idle while the comparison runs, so the PowerShell asks TWICE and only
sessions whose every field was identical across both asks are compared. And the
case refuses to be green having compared nothing: if claude were unreachable both
sides would hand back an empty map and it would pass having established nothing.

🔴 **2.5 was split into three.** The plan's done-when - "the agent map matches,
including busy" - is met by 2.5a alone. What was bundled with it is not: the
three sub-agent readers (2.5b, moved here from 2.3 because they answer *what is
running* rather than what a transcript says), and the launch/kill path (2.5c),
which must be ported without ever launching or ending anything to prove it.

### A discipline that keeps recurring, written down once

🔑 **EVERYTHING THIS TOOL READS IS MOVING.** A screen redraws, a transcript
grows, a session changes its mind. Three comparisons have now needed the same
shape, and it is the same shape each time:

1. the PowerShell records **what state it read** (a second read, a file length,
   a repeated ask);
2. the C# answers about **that same state**, or says plainly that it could not;
3. the difference that produces is **tolerated by name, narrowly, and printed
   every time it is used**;
4. and the case **fails if it compared nothing at all**.

🪤 What must never happen - and was written once, and removed - is the C# side
**echoing the PowerShell's answer back** when it cannot hold the target still.
That turns a limitation into a pass and is the one thing the oracle's contract
forbids outright.

### 2.5b as it turned out — a THIRD live defect, and the same trap twice

🔴 **`Get-SRAgentLastLine` THREW on every sub-agent whose last message was a
single line**, and the throw was invisible.

```powershell
return (("$($b.text)".Trim() -split "`n" | Where-Object { $_.Trim() })[0]).Trim()
```

A pipeline that yields exactly ONE line hands back a bare **string**, not an
array — so `[0]` indexed into the string, returned its first **character**, and
`.Trim()` on a `[System.Char]` throws. That is the **array-wrap trap** this repo
already has a note about, and the SHELL branch of the very same caller does it
correctly twenty lines away.

🪤 **The caller wraps it in `try/catch` and falls back to `'starting'`** — so a
running sub-agent that had said something showed **"starting" for ever**. Nothing
was logged and nothing looked wrong.

**It was found because the oracle called it over every sub-agent on the
machine** rather than over the ones that happen to be multi-line: 3 of the first
3 it reached threw. Fixed by assigning first and indexing second; `state` and
`gui2` both PASS after.

**What the three cases cover:** 386 sub-agents (every conversation — the list is
cheap, it reads small meta files and stats one transcript each), 326 last lines,
and 25 conversations for what is still running.

🪤 **`Live` is deliberately NOT compared.** It is a clock reading — "was this
written to in the last three minutes" — so the two sides evaluate it seconds
apart and an agent on the boundary legitimately differs. Everything it is
*computed from* is compared instead: `HasTranscript` and the transcript's mtime.

🔒 **And the agent id is pattern-checked before it becomes a filename.** It
arrives from a transcript — data this tool does not write — and `..\..\something`
is the difference between reading a sub-agent and reading whatever the caller was
pointed at.


### 2.5c as it turned out - the launch path, and two more live defects

**Ten oracle cases, 428 conversations planned over, four boot scripts compared
byte for byte, and nothing launched, ended or typed into.** 161 xUnit tests.

🔑 **THE SHAPE IS THE WHOLE POINT, AND THE POWERSHELL HAD TO BE SPLIT TO GET IT.**
`Start-SRSession` built the wt.exe command line and then handed it to
`Start-Process` in one function, so the piece whose defects are invisible until a
tab dies was reachable only by launching something. It is now
`Get-SRLaunchCommandLine`, which returns the string, and `Start-SRSession`, which
is the only caller that turns it into a process - a pure extraction, no behaviour
change, and the reason the quoting is now compared over every real project path
on the machine. The C# mirrors it exactly: `CommandLine`, `BootScript`,
`LaunchPlan` and `EndPlans` are values, and **there is no method in the assembly
that starts or ends anything.**

🔑 **AND TWO OF THE CASES RUN THE WINDOW'S OWN SOURCE.** `Get-LaunchBlock` and
`Get-TickedPlan` live in `sessions-window.ps1`, which the oracle must not load.
Their source is spliced out by name and defined in the oracle's session - the
shipped body, over the real registry, without the window around it. A failed
splice leaves the function undefined and the case reports "could not run", which
is the third state, never a pass.

**Two more live defects in the shipped PowerShell, both found by comparing bytes
rather than behaviour:**

🔴 **4. The boot script the tool writes contained nine bytes of mojibake.**
`lib/_common.ps1` is UTF-8 with no BOM, this machine's ANSI codepage is 1252
(measured), and PowerShell 5.1 therefore read the 🔴 inside the boot-script
here-string as the four Latin-1 characters its UTF-8 bytes happen to be. Written
back out as UTF-8 those became nine bytes, in a comment, in a file the operator
opens when a launch goes wrong. Found as `1.677 bytes against 1.672`. The
template is pure ASCII now.

🔴 **5. The settings label was going to the WINDOW mojibaked.** The same trap,
but this one is a *displayed* string: `Get-SRSessionArgsLabel` joined with a
literal middot, so the row would have read `max  Â·  plan`. It is built from
`[char]0x00B7` now. A scan of the other two `.ps1` files found **zero** non-ASCII
string literals, so this was the single leak - the rule had been followed
everywhere else.

🔴 **AND THE ONE THAT MATTERS MOST HERE: "WRITTEN IS NOT WORKING."**
`launch/settings` walked all 560 conversations, every one agreed, and a
deliberate break to the `--model` branch **did not turn it red** - because *not
one session in the live registry has a `prefs` object at all*. A comparison over
live data proves only the paths live data reaches, and here that was exactly one:
the default. So the DATA SOURCE was substituted rather than the check weakened -
`launch/settings-shapes` carries 22 shapes covering every setting the sheet can
produce, and five separate breaks were each seen to go red through it.

🪤 **Three harness traps, all of which cost a run:**
- **A here-string cannot be indented.** PowerShell needs a closing `'@` in column
  1 and a C# raw string literal indents everything it holds, so the shell sat
  waiting for input and the case came back 300 s later. (That it came back at all
  is yesterday's read-deadline fix earning its keep.)
- **`` `u{1} `` is PowerShell 6+.** 5.1 emitted it literally. It had been in the
  older settings case all along and never mattered, because every row's flag list
  was empty - the same blindness as the defect above.
- **The array-wrap trap, from the other side.** `blocked = ,(...)` - the leading
  comma is for a `return`, where it stops an array being unrolled; in an
  *assignment* it simply wraps, and 26 blocked rows read as "1 item in PowerShell,
  26 in C#".

🪤 **One named difference kept rather than hidden:** PowerShell 5.1's
`Sort-Object` is not stable (`-Stable` arrived in PowerShell 6) and LINQ's
`OrderByDescending` is, so two conversations sharing a `lastActive` to the tick
can come back swapped. The allowance forgives an ORDER difference inside `fresh`
or `restart` only - and the case emits the sorted SETS alongside, so a membership
change lands somewhere nothing forgives. Without that the allowance would have
forgiven a conversation being *replaced* as readily as two being swapped, since
one changed member shifts every index after it.

🪤 **And one deliberate non-change.** PowerShell's `-contains` is
case-insensitive, so `effort: "High"` clears the validation and reaches claude as
`High` - a guard narrower than it reads, since the accepted values are lowercase.
The C# was made to match rather than tightened: the settings sheet only ever
writes an exact value, so it is unreachable in practice, and an Ordinal test
would have been a behaviour change smuggled into a port.



### 2.6 as it turned out - and the coverage question asked FIRST this time

**Seven oracle cases, 428 conversations banded, 201 xUnit tests.** The whole row
layer: `Titles`, `OpenItems`, `SessionState`, `Bands`, `RailCuts`, `Surface`.

🔑 **THE 2.5c LESSON WAS APPLIED BEFORE IT COULD BITE.** `bands/live` walks
every conversation, and the spread is **399 quiet, 18 done, 3 idle, 3 working,
3 needs, 2 open** - so almost the whole case is one band reached by three
different routes, and most of `Get-Band` is untouched by it. `bands/shapes`
carries 16 synthetic agent reports covering every route in, and **ten separate
breaks were each seen to go red**, one per branch.

🪤 **TWO OF THOSE TEN DID NOT GO RED FIRST TIME, AND NEITHER WAS A CODE
PROBLEM:**

- **The "coldest conversation" the surface case selected is LIVE.** A running
  session whose registry `lastActive` was never updated is the oldest row on the
  machine - so `Test-OnSurface` returned on its first line and the
  pinned-because-selected clause, the entire point of the case, was never
  reached. Breaking that clause stayed green. The pick is now the coldest row
  **nothing is running**, and it throws if no such row exists rather than
  quietly testing nothing.
- **The quiet exclusion had no route into it.** A stuck row returns quiet from
  `Get-Band`'s FIRST line, before the ask-seen override is reached, so it proves
  nothing about it. Only an *unrecognised status* falls through the switch to
  quiet and then meets the override. That shape was missing and is now there.

🔴 **A live semantic difference: PowerShell's casts ROUND, they do not
truncate.** `[long]($Delta / 10000000)` and `[int]($s / 60)` are
`Convert.ToInt64/ToInt32`, which round half to **even** - so 3m31s reads "4m",
and 90 seconds minus one tick becomes 90 whole seconds, then 1,5 minutes, then
**"2m"**. C# integer division truncates, which is the conventional reading of an
age and disagreed at every half-unit boundary. Found at 89,9999999 s, where the
two sides said "2m" and "now". 🔑 It matters more than a label: `Get-AgeLabel`
also feeds the change-detection fingerprint, so a port that truncated would have
made the row and its own repaint test disagree about whether an age had moved.
Ported faithfully, with the reasoning written where the next reader will want to
"fix" it.

🪤 **And two defects in my own harness, found because 2.6's full run went
red on a case I had not touched.** `subagents/live-tasks` was **intermittently**
red - the worst state a check can be in, because it teaches people to re-run:

- its "the file grew" marker filled two fields of a six-field row, so the other
  four reported "present in PowerShell, missing in C#" and matched no allowance.
  The same mistake `launch/processes` had already been fixed for: **one marker
  per field the other side emitted.**
- its allowance was `d.EndsWith("C# \"-2\"")` on the WHOLE difference text - so
  it inspected a single line and forgave all of them. That is the
  tolerance-on-the-first-difference mistake seen from the other end. It is
  line-wise now, and the case reports **23 compared, not 25**, when two
  conversations grew.

🔑 **`Resolve-SRSessionState` is called with `-Conv $null`, and that is not a
simplification - it is what `Update-Model` does.** The transcript state reader is
not on the band path at all, so the corroboration test reduces to "is there a
pid". Porting the `Conv` branch would have been porting a caller that does not
exist.



### 2.7 as it turned out - the item that could lose work

**Four oracle cases (41 in total), 218 xUnit tests, 562 conversations written by
the C# and read back by the shipped PowerShell.** The live registry and the live
config were sha256'd before and after the whole run and are **byte-identical**.

🔴 **THE DIFFICULTY OF THIS ITEM IS THAT THE THING TO VERIFY IS FENCED.**
`Save-SRRegistry` is on the oracle's fence - it is one of the calls that cost 210
conversations - and un-fencing it to make a comparison possible is exactly the
"loosening a write guard to make a test pass" this repo has a standing rule
against. So the PowerShell was split instead: the stale check is now
`Get-SRSaveRefusal`, which takes four values and returns a sentence, and
`Save-SRRegistry` calls it. **The guard is compared; the act stays fenced.** Same
move as 2.5c, for the same reason.

🔴 **THREE STRUCTURAL GUARDS, NONE OF THEM REMEMBERED:**

1. **`RegistryTarget` - the live file cannot be NAMED.** `ForCopy` is the only
   factory, it refuses the registry and the config by resolved full path, and
   there is deliberately **no `Live()` factory, not even an internal one** - an
   internal one is reachable from the test assembly, and "a test that CAN reach
   live state WILL destroy it" is written down here because it already happened.
   Phase 6 adds exactly one.
2. **`SaveDecision` - the stale check is a value**, with four outcomes, three of
   them refusals told apart on purpose because the operator can act on each
   differently.
3. **Write beside, then replace, and REPORT the failure.** `SaveResult.Written`
   is false when an error was recorded, and the stamp is **not** refreshed on a
   failed write.

🪤 **THREE OF THE SIX CASES COULD NOT GO RED WHEN FIRST WRITTEN, AND EACH
FAILED FOR A DIFFERENT STRUCTURAL REASON. This is the most useful thing in the
item:**

- **`write/stamp` had one field and an allowance that forgave it.** A total
  tolerance is not an allowance, it is an off switch: a deliberate break from
  `LastWriteTimeUtc` to `LastWriteTime` sailed straight through. Now the
  PowerShell stamps the file **twice**; if those agree the file held still and
  this side's answer is compared exactly, and only a file that moved mid-run is
  forgiven.
- **`write/read-back` re-read the file it had just written.** So both sides were
  reading the same possibly-lossy file and agreeing about the loss - dropping
  `[JsonExtensionData]` from `RegistrySession`, the exact bug that would destroy
  `prefs`, left it **green**. It now compares **what the C# meant to write**
  against **what the shipped PowerShell reader found**, which is the only
  arrangement where a dropped field has nowhere to hide.
- **`write/refuses-the-live-file` asserted into the void.** Its verdicts existed
  only on the C# side, so they showed up as "present in C#, missing in
  PowerShell" and were swallowed by the tolerance covering exactly that. Both
  sides now answer the SAME question - "does this path name a live file" - one by
  resolving the path, the other by asking its guard, row for row, with **no
  allowance at all**.

🔑 **AND THE BYTES ARE DELIBERATELY NOT COMPARED.** The two JSON writers
indent, escape and format numbers differently and none of it is data. What has to
survive is every FIELD of every conversation, including the ones this build does
not model - so the round-trip carries two synthetic conversations holding a
`prefs` object and a key called `somethingFromTheFuture`, because **no session in
the live registry has any prefs at all** and the column would otherwise be
proving nothing.

🔴 **One divergence, named and kept:** two stamps differing only in case.
PowerShell's `-ne` on strings is case-insensitive, so it calls them equal and
**allows the save**; the C# compares ordinally and refuses. It cannot occur - a
stamp is `length|ticks|SHA256HEX` from one function - so it is out of the shared
shapes rather than covered by an allowance, and pinned in a unit test instead.
**This side is deliberately the stricter of the two**: writing a knowingly weaker
guard to match a quirk that cannot fire is the wrong trade on the check that
protects 210 conversations.


### The health check went from a twenty-minute hang to 86 seconds

The first run of a new day found nothing wrong with the code and three things
wrong with the harness. Recorded because each would have gone on wasting a
morning.

🔴 **A HANG IS THE WORST OUTCOME A HARNESS HAS.** `PsSession` checked its
deadline in the loop condition and then called `ReadLine()`, **which blocks for
ever** - so a PowerShell that stopped answering hung the whole run with the
timeout unable to fire. Observed: `sr-oracle` at two seconds of CPU for twenty
minutes, its output file empty, holding the build's DLL locked, and nothing
saying why. A red is a fact and a green is a claim; a hang is neither, and it
takes the next build with it. The read now honours the deadline and reports
which side went quiet.

🔴 **THE BLOCK SAMPLE OUTGREW ITSELF.** 40 conversations with no size bound
covered **474 MB** and one 68 MB file; it had run in 3,2 s the day before on the
same code. Nothing changed but the data. Now 15 conversations under 12 MB
(p90 is 8 MB) — and 🔑 **size is not where a parser differs, variety is.** What
the giants exercise is the WIDENING loop, and that is a deterministic path
better proven by a fixture whose newest record is bigger than the window. Same
split the first-line case already uses.

🪤 **`"$($y.Body)"` COPIES THE BODY**, and a body can be megabytes. The detail
case did it once per block and spent five minutes copying strings, while the
shape case did the same reading in 2,2 s because it only ever asked for a
`.Length`.

🪤 **`$len` WAS ALREADY TAKEN.** The file-length pin reused the name of the
body-sum accumulator four lines above it, so `bodyLen` came back as **11.718.403**
against the C#'s **13.492** — a difference that looked like a parser disagreeing
and was a name collision. Same family as the `$ShellId` and `$args` collisions
already recorded here.

🪤 **And an allowance that was too broad.** A grown conversation made 289 rows
face 290, and the tolerance written for it forgave *"the counts differ"* — which
would forgive a genuine fifty-block disagreement just as happily. The C# emits
one marker **per row the other side emitted** instead, so the arrays stay aligned
and a count difference goes on meaning what it says.

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
| 3.1 | `ConversationVm` with `INotifyPropertyChanged`, bound once | changing one property repaints one row and does not rebuild the list | ✅ 5 of 6 checks; the source collection is never rebuilt |
| 3.2 | `ICollectionView` for sort, filter and search | `tests/rebuild-bench.ps1`'s equivalent measures a keystroke **< 16 ms** with a frame | ✅ **2,1 ms**, live filtering, no Reset |
| 3.3 | The bands as grouping, not as constructed heading rows | a conversation moving band does not rebuild the column | ✅ `1 x Move, 1 x Add, 1 x Remove`, no Reset, landed in its new heading |
| 3.4 | The background loops replacing the 11 timers | the cadences in `01-CAPABILITIES.md` are preserved, with their measured values | ✅ 12 cadences, drift-checked against the window's own source |
| 3.5 | The two whole-list gestures | cycling the sort and toggling only-live land inside a frame too | ⏸ only-live is inside now; **the sort is still 21 ms** - deferred to 4.1 |

🔴 **3.2 is the item this whole rebuild is justified by.** If it does not land
under 16 ms, stop and find out why before building any more of the view.


### 3.1 and 3.2 as they turned out - the gate did its job twice

`Sessions2.exe --bench --repeats 40` runs both and writes
`%TEMP%\sr-keystroke-bench.txt`. Exit 0 means every gesture landed inside a frame
AND every binding check passed. It shows a window at **-32000**, unfocusable and
not hit-testable, drains to **ContextIdle** (the dispatcher processes Render and
Loaded above it, so returning means the frame is drawn), asserts a real
**PresentationSource**, and closes. It reads the registry and nothing else.

✅ **3.2 IS CLEARED: a search keystroke is 2,1 ms**, against **512 ms** in the
PowerShell - and the view reports `428 x Remove, 428 x Add` with **no Reset**.

| gesture | before (PowerShell) | ICollectionView.Refresh | live filtering |
|---|---|---|---|
| **search keystroke** | 512 | 14,9 / 17,4 / 15,1 | **2,1** |
| clear the search | - | 12,3 | 10,6 |
| pick a project | 452 | 4,4 | 9,7 |
| clear the project | - | **19,1 over** | 13,6 |
| cycle the sort | 98 | 14,5 | **21,2 over** |
| only-live on and off | - | 5,3 | **19,3 over** |

🔴 **THE FIRST ATTEMPT LOOKED CLOSE AND WAS THE WRONG SHAPE.**
`ListCollectionView.Refresh()` - which is what changing a `Filter` predicate
comes to - raises **Reset**, and a Reset makes WPF drop and rebuild every
realised container. So the per-row rebuild the whole design exists to remove was
still happening, relocated from PowerShell into WPF. The fix is to stop changing
the predicate: the filter now reads one bool off the row, `IsLiveFiltering` is on
with `Matches` named in `LiveFilteringProperties`, and a gesture writes that bool
on every row. The writes that change nothing raise nothing.

🪤 **AND THE CHECKS LIED TWICE BEFORE THEY TOLD THE TRUTH. Both are worth
knowing:**

1. **They watched the wrong collection.** Four checks passed while every gesture
   was Resetting, because they watched the `ObservableCollection` - which
   genuinely is never rebuilt. **A ListBox does not bind to the source, it binds
   to the VIEW.**
2. **Then "no Reset" passed because the view had stopped filtering.** With live
   filtering wired up the check reported *"the view raised nothing"* and the
   keystroke fell to 2 ms - both because **the filter was not running at all**.
   Two things were needed to see it: a check that the filter still filters
   (`428 -> 0 -> 428`), and a **dispatcher pump before counting** - WPF applies
   live shaping through the dispatcher, so a count taken on the next line reads
   the previous set. The bench never saw it because `Measure` drains between the
   gesture and the count.

🔑 **The lesson is the session's own, arriving again: a green is not evidence
until it has been seen to go red, and "it got faster" is not evidence that it got
faster at the right thing.** 2 ms was the cost of doing nothing, and only an
independent question - *does it still filter?* - could tell the two apart.

### 3.3 as it turned out - done, and it costs on the widening gestures

✅ **THE DONE-WHEN IS MET AND PROVEN.** A conversation moving band reports
`quiet -> working, 1 x Move, 1 x Add, 1 x Remove, groups 1 -> 2, landed: True` -
one row between two headings, **no Reset**, and it is really in the new group.

The bands are a real `GroupDescription` with `IsLiveGrouping`. What that removes
is the PowerShell's heading-as-fake-list-item: a heading there carries **every
session property present-but-switched-off**, because a heading and a row share
one DataTemplate and a binding to a property that is not on the object is a
silent trace error and an empty cell. A real group header has its own template
and never has to pretend.

🪤 **THE ORDER IS A NUMBER, NOT THE LABEL'S ALPHABET.** A view forms groups in
the order its items arrive, so `BandOrder` sorts first, always, whatever the
column is sorted by inside a band. Without it the column heads FINISHED, IDLE,
NEEDS YOU.

🪤 **AND THE CHECK PASSED ONCE WHILE NOTHING REGROUPED.** Its first version
asked only "no Reset, and something is still on screen" - which is true of a row
that never moved, and it reported `groups 1 -> 1` while saying **ok**. It now
asserts the mover is *in* the group named after its new band. Third time this
session that a check had to be told what it was actually for.

🔴 **THE COST: grouping takes the whole-list WIDENING gestures well over a
frame.** Clearing a search went from ~13 ms to 70-115; clearing a project from
~14 to ~65; only-live from ~15 to ~65-83. Typing is unaffected (it narrows).

🪤 **`VirtualizingPanel.IsVirtualizingWhenGrouping` WAS TRIED AND DID NOT MOVE
IT.** Grouping does turn WPF virtualization off by default and it *is* the least
discoverable line in the view layer - it stays on for that reason - but it is not
what is costing here.

🔴 **This is where the tuning stops until 4.1, deliberately.** The bench binds
a placeholder `ListBox` with `DisplayMemberPath` and **no `GroupStyle` at all**,
so WPF is building group containers with no template to build them from. Tuning
that is tuning the wrong thing, for exactly the reason already written under 3.5.
Carried to **4.1** with the sort.

🪤 **Every number above was taken at 35-65% CPU with 29 live conversations,**
and one worst-case read 684 ms. The absolute figures are not trustworthy; the
13 -> 70 jump is, because it held at all three load levels.

### 3.4 as it turned out - the cadences are values, and drift is caught

✅ **Twelve cadences in one place, compared against the shipped window's own
source.** `loops/cadences` reads every `$script:*Timer.Interval` out of
sessions-window.ps1, resolves the three that are named constants
(`FastSeconds`, `LiveSeconds`, `AskPollFastMs`), and diffs them against
`Core/Cadences.cs`. Changing `Fast` from 6 s to 7 s turns it red.

🔑 **It is a DRIFT check, not a port check, and that is the only kind
available** - the timers are created at window scope in a file the oracle must
not load. What it catches is not a crash: it is a rebuild that quietly feels
different from the tool it replaces, in a way nobody can point at. The failure
mode these numbers protect against was reported in exactly those words - *"I have
to click a different session to see whether this one is still going."*

🪤 **THE FIRST *RESOLVABLE* ASSIGNMENT, NOT THE FIRST ONE.** `askTimer` has
its interval re-set at runtime from `$(if ($slow ...))`, and that assignment
appears **earlier in the file** than the one that creates it - so taking the
first textual match reported "could not resolve" for a timer whose cadence is a
plain constant twelve thousand lines further down.

🪤 **AND A COMPARISON KEYED ON THE POWERSHELL'S ROWS CANNOT CATCH A MISSING
NAME** - a timer absent from both sides agrees perfectly. `CadenceTests` asserts
the table holds all twelve by name, which is the half the oracle structurally
cannot do.

**`BackgroundPass` replaces a DispatcherTimer**, and the three things it keeps
that a naive port would lose:

- 🔴 **The work is not on the UI thread.** Every one of the window's eleven
  timers ticks on the dispatcher, so a 508 ms model pass happens *between frames*
  and is felt as a stutter rather than seen as a delay. Here the reading is on
  the thread pool and only the finished answer is marshalled back.
- 🪤 **A tick never overlaps itself.** A DispatcherTimer cannot re-enter, so
  the PowerShell had that for free and a port loses it silently. The interval is
  the gap BETWEEN passes, not the period.
- 🪤 **A failing pass does not kill the loop.** An unobserved exception in an
  async loop stops it and says nothing - the tool would keep drawing a board that
  had stopped updating, which is indistinguishable from a quiet machine.

### 3.5 - tried, measured, reverted, and one gesture deferred

🔴 **"ONE RESET WHEN MOST ROWS MOVE" IS THE OBVIOUS IDEA AND IT IS WORSE.**
Live filtering IS the wrong trade for a whole-list swap in principle - 428
notifications against one Reset - so the fix was to count the movers and switch
above a threshold. The only lever for that is toggling `IsLiveFiltering`, and
toggling it makes the view **rebuild its own tracking over every item**:

| gesture | live filtering | with the toggle |
|---|---|---|
| search keystroke | 2,1 | **25,5** |
| clear the search | 10,6 | **38,9** |

Reverted. Written into `SessionsVm.Reselect`'s own comment so the next reader
does not re-derive it.

🪤 **AND `IsLiveSorting = false` WAS THE SECOND ATTEMPT, ALSO REVERTED.** It
bought nothing measurable on the sort (21,2 -> 22,5, inside the noise) and it
would have cost something real: a conversation whose `lastActive` moves on a
background refresh has to rise to the top of a recent-first list, and with live
sorting off it would sit where it was until something else re-sorted.

**Where it landed:** toggling only-live is now **inside a frame** (15,6 ms).
**Cycling the sort is still 21 ms** and is deferred to **4.1**: changing
`SortDescriptions` Resets whatever else is true, so its cost is a Reset plus a
re-layout of 428 items - and the lever for that is container recycling and a
fixed row height, which cannot be tuned honestly until the real row template
exists. Chasing it against a placeholder `DisplayMemberPath` would be tuning the
wrong thing.

🪤 **A NOTE ON EVERY NUMBER IN THIS SECTION: the machine was at 35-49% CPU.**
At that load the spread on a 16,7 ms boundary is around plus or minus a half, and
two runs of the same build differed by 10 ms on one gesture. The 2,1 ms keystroke
was measured on a quiet machine; 3,6-4,0 ms is the same build under load. Only
differences of the 2 -> 25 ms kind were treated as real.
[[feedback-measure-a-control]]

---
## Phase 4 — the view

| | what | done-when |
|---|---|---|
| 4.1 | Port `window2.xaml`, replacing imperative updates with bindings | the window opens and every control in `01-CAPABILITIES.md` is present |
| 4.2 | Wire the 77 handlers | every row of the capability table has its handler, and the 101 unwired elements are each confirmed as label/container or deleted |
| 4.3 | Keyboard: the tunnel order from `01-CAPABILITIES.md` | the terminal watcher receives Escape, `/` and `l`; the settings panel still closes on Escape |
| 4.4 | The reading pane, virtualized | a 2,5 MB conversation opens without a tail budget, and the alignment harness still passes |
| 4.4c-a | The pane's geometry, as numbers | ✅ `pane/metrics`, `pane/marks`, `pane/measure`, `pane/blocks`, `pane/prose`; 48 breaks, 48 red |
| 4.4c-b | The pane as lines - the split, the spans, the links | ✅ `read/spoken`, `read/prose-shapes`, `read/prose-live`, `read/doc-links`; 1,500 rows over 155 real bodies; 49 breaks, 48 red |
| 4.5 | Animation: transitions on the gestures that now have headroom | no gesture exceeds 16 ms while an animation is running |

🪤 **4.4 last of the view work.** The typography was tuned against rendered
pixels, not against a description, and it is the easiest thing here to break
without noticing.

### 4.1 as it turned out - first tranche: the window opens, 164 of 164

**`Sessions2.exe --surface`** builds the ported window with no data context,
shows it the render-driver way, and writes `%TEMP%\sr-surface-check.txt`. Exit 0
means it opened, both shipped faces installed, and every named element in
`01-CAPABILITIES.md` is present **by name and by kind**. The list is read from
that document, not retyped.

- **The markup is `lib/window2.xaml` with one attribute added** (`x:Class`), and
  169 KB of it compiled to BAML first time. Every divergence from here is a named
  change.
- 🔴 **The XAML does not say what is on screen.** It names Segoe and Cascadia;
  the PowerShell swaps in Manrope and IBM Plex Mono after parse and collapses
  every `Sz*` to the pane size. `Views\Typefaces.cs` ports all three, with the
  put-it-back-if-refused rule, and the fonts are embedded (linked from
  `lib\fonts`, one copy in the repo).
- 🪤 **Three names hide where a shown window never builds**: an inline
  `ItemTemplate` on an empty list (`CastTick`), a `DataTemplate` in the resources
  (`TickBox`), and a template nested in a template (`bb`). The check loads every
  template's content, recursively, instead of needing data to reach them.
- **Seen red, every path**: a renamed window control, a renamed name in an inline
  item template, one in a resource template, a changed kind, and a face that did
  not load - each failed on its own line. 🪤 The first break was invalid - `bb`
  is a trigger target, so the BUILD failed and the check ran the previous exe
  green. Every break since is gated on a build that passed.

### 4.1 second tranche (2a) - the sessions column is the real column

- **`SessionRowTpl` is split three ways**: the band heading is `BandHeaderTpl`,
  a real `GroupStyle` header binding the group (`Name`, `ItemCount`); the
  sub-agent row is `SubAgentRowTpl`, kept verbatim for 4.2; the session row keeps
  everything else. `SessionList` groups, with `IsVirtualizingWhenGrouping`.
- **The row binds the view model**: `Title`, `Age`, `Said` (via
  `Core.Rows.Headline`, whose expected values were printed by the PowerShell
  expression itself), `DotVis`/`NameWeight` on NEEDS YOU, `NameStyle` on a
  derived title, `BarOpacity`, and the accent through a `BandAccent` converter
  fed from the window's own `Acc*` brushes.
- 🔴 **The bench now counts binding errors, and they fail the run.** A binding to
  a missing property is a silent trace line AND a Visible default. The trap
  caught two on its first two runs: `{Binding Name}` (the PowerShell row's word
  for the title) and `Items[0].Band` in the header, which errors on a group
  that is momentarily empty. Both fixed; 0 now, in both hosts.
- 🔴 **LOOKING at the column found a port defect no check had asked about.**
  `--render <png>` draws the column bound to the registry read-only - and it
  drew **all 416 conversations under NOT RUNNING**. `SessionsVm` never applied
  the surface rule. It does now (live, warm, or selected; a picked project shows
  all of that project), with a binding check over all three arms that requires a
  cold row to exist and was seen red with the rule removed. The column is 31.
- The band-move check had to move a row that is **on screen**: `Rows[0]` became
  a hidden cold row and reported `landed: False` about something nobody sees.

### 4.1 (2b-1) - the queue mark, and the antivirus in the harness

- **`Core.Transcripts.Waiting`** ports `Get-SRQueue` + `Test-SRQueueFresh`;
  **`Core.Rows.QueueMark`** ports the per-row block of `Build-Sessions`. Four
  oracle cases: `queue/read-shapes` (14 synthetic transcripts, one per rule),
  `queue/read-live` (60 newest, pinned), `queue/fresh` (every boundary), and
  `queue/mark` - which **splices the block out of `Build-Sessions` by its first
  and last lines** and runs it, because it is inline and has no function to call.
  **Eight deliberate breaks, eight caught**; two of them also reddened the live
  case, so real transcripts reach hop-chain and popAll.
- 🔴 **Three comparisons the PowerShell makes case-insensitively without looking
  like comparisons**: `-ne 'queue-operation'`, the `switch` on the operation, and
  `-eq` matching a remove to its enqueue. Ported as such.
- 🔴 **THE ANTIVIRUS REFUSED A CASE, AND THE HARNESS REPORTED A 300 s HANG.** The
  first `read-shapes` shipped fixtures as base64 that PowerShell decoded and wrote
  to disk - a dropper's shape - and the script scan blocked it as a parser error
  on stderr. The end marker never printed, so the session waited out its deadline
  and said only "stopped answering". Found by `SR_ORACLE_DUMP=<dir>` (new: writes
  every script as sent) and replaying the dump through stdin. Fixtures are now
  plain string expressions; **`PsSession` fails fast on a parser error or an AV
  block**; and **a closed shared session is replaced** - one hung case used to
  crash the rest of the run with `ObjectDisposedException`.
- 🪤 A join of two script fragments glued `}` to the next statement (`}$dir =`)
  - a raw string literal has no trailing newline. Every join now adds one.
- The row binds `QVis`/`QText`/`QTip` and `QMine` through a `BoolBrush`
  (`HueOut`/`TextLow`); `--render <png> --fake-queue` drew `» 2` in amber.

### 4.1 (2b-2) - every mark the row draws, against the shipped row loop

- **`Core.Console.ScreenVitals`** ports `Read-SRScreenVitals` (30 screens in
  `vitals/shapes`, 12 breaks caught, plus `vitals/live`, which hands the C# the
  PowerShell's screen text - the question, not the answer - because a screen
  redraws between two reads).
- **`Core.Transcripts.ContextUse`** ports the model/tokens/window part of
  `Get-SRSessionVitals` (15 shapes, 10 breaks caught, 60 live).
- **`Core.Rows.RowDecor`** ports the rest of the row: the said line with the
  compact override, the shell and sub-agent marks, `Get-SRRowCtx` with both
  TTLs and the printed-window rule, `Get-CtxBrush`, `Get-SRCompactText`.
  **`row/decorations` splices two regions out of `Build-Sessions` and runs
  them** - one ends inside the hashtable literal that builds the row object - over
  24 specs; 9 breaks caught.
- 🪤 **`ToString("R")` IS NOT THE SAME ON BOTH RUNTIMES.** .NET Framework prints
  17 digits, .NET 8 the shortest round-trip, so an identical `6.8000000000000007`
  read as a difference. Doubles are compared as their bits.
- 🪤 A shape that could not fail: the context tail case gave both records a
  model, and the last one wins either way - a break that removed the tail limit
  stayed green until the model was put only on the record outside the tail.
- `--render --fake-queue` draws a row with every mark at once; the real rows
  show their transcript context bars.

🔴 **4.1 IS DONE BY ITS DONE-WHEN** (the window opens; 164/164 controls, by name
and kind) **and the sessions column is fully bound.** 🔑 The other surfaces - the
rail's tiles, the manage list, the strip, the pane, the question card, the
settings and cast panels - get their bindings WITH their handlers in 4.2, one
surface at a time: a binding with nothing to drive it cannot be checked, and a
data flow built before its handler is guessed at twice.

| still open | why it waits | trigger |
|---|---|---|
| sub-agent rows under the selected conversation (`SubAgentRowTpl`) | they appear on SELECTION, which is a handler | 4.2, `SessionList` selection |

### 4.2a as it turned out - the handlers that only change what is shown

**`Sessions2.exe --handlers`** drives each handler through its REAL event on
the real control (`sr-handler-check.txt`, exit = failures): the chrome, the sort
cycle, the 90 ms search debounce, both column folds with the strip, the two
surfaces, the zoom. Twelve checks; zoom, the structural guard and the debounce
were each seen red.

- 🔴 **NOTHING IN THE APP CAN ACT ON A SESSION, AND A CHECK PROVES IT FROM THE
  ASSEMBLY.** The first check reads every member reference compiled into
  `Sessions2.dll` out of its metadata and fails on `ConsoleWriter`,
  `RegistryWriter`, `RegistryTarget` or `Process.Start` - seen red by adding one
  call to `ConsoleWriter.Send`.
- 🔴 **THE SHIPPED FOLD AND ZOOM WRITE THE LIVE CONFIG.** Both call
  `Save-SRConfigLater`. In the rebuild remembering is `IPreferences`, and the only
  implementation is `NoPreferences`, which writes nothing and records what it was
  asked - the check asserts the four folds were ASKED.
- 🔴 **The zoom compounded** - `Typefaces.Scale` read the size it had just
  written, so 100 -> 110 -> 125 read 13, 14.5, 18. The base is captured once, as
  `$script:TypeBase` does. Caught on the check's first run.
- 🪤 The maximise and minimise buttons are NOT pressed: maximising a window at
  -32000 puts it on the operator's monitor. Their glyph rule is checked as a value.

**Three port defects found in 3.x's view model on the way**, each now matching
the shipped window with an oracle case:

| what | was | is |
|---|---|---|
| the sort cycle | recent / name / **band** | recent / name / **project** - bands are always the grouping |
| the search haystack | title, id, path, **cwd** | title, **auto-title**, path, id, **project label** (`search/filter`) |
| what a search IS | `Contains` | **`-like "*q*"`** - `*` `?` `[ab]` are wildcards, a backtick escapes, an unclosed `[` throws and the list stays as it was |

- **`Core.Rows.ProjectLabels`** ports `Update-ProjectLabels`: a folder name,
  growing by a parent segment per clash up to four, case-insensitive in both the
  keys and the grouping (`labels/live`, `labels/shapes`, 3 breaks).
- 🪤 **`Split-Path -Leaf` is provider-relative**: `C:\` stays `C:\` and a bare
  `\` becomes the current drive's root. `Titles.Leaf` answered `C:` - found only by
  a shape, since no live project is a drive root.

### 4.2b as it turned out - the projects rail

- **`Core.Rows.Rail`** ports `Build-Rail`, `Get-RailGrouping` and `New-RailTile`;
  **`ProjectAccent`** the dealt twelve-hue wheel; **`ShelveSuggestion`**
  `Get-SRShelveSuggestion`. **`rail/build` splices `Build-Rail` and sixteen of its
  helpers and runs the whole function**, over a model built to reach every rule, in
  eleven rail settings - only `$ui`'s controls and `$window`'s brushes are stubbed,
  with real brushes so the shipped casts survive.
- 🔴 **Fourteen breaks; four MISSED on the first model.** It had no live-but-idle
  conversation (so "working" counting `.Live` agreed), no working-but-not-live one
  (so only-live reading the band agreed), a worktree project past BOTH cut-offs,
  and no band holding two different waiting counts. Shapes added for each; all
  fourteen caught.
- 🪤 **Waiting and busiest tie, and PowerShell 5.1 promises nothing about ties.**
  Each side checks its own order is non-increasing in the count (`orderOk`) and
  then orders tiles that share a count by path - the ORDER is still compared, the
  arbitrary tie-break is not.
- 🪤 **`enabled` ABSENT IS NOT FALSE.** `Test-SRProjectRestoreOff` fires only on a
  present false; `RegistryDirectory.EnabledPresent` now says which, without changing
  what the writer writes.
- **`RailVm` patches the list by id and signature** (`Sync-SRSessionItems`), and
  `WindowShell` wires search (the shared 90 ms timer now rebuilds both panes),
  sort, only-live, shelved, clear, heading-fold and tile-pick. `--handlers` is 18
  checks, including one that fails on any binding error the handlers cause.
- 🪤 **`PreviewMouseLeftButtonDown` IS A DIRECT EVENT.** Raised on a tile's
  container it reached nothing above it, and the check stayed red with a correct
  handler - a real click is a tunnelling `PreviewMouseDown`.
- `--render` now draws the rail too, through the real shell.

### 4.2c as it turned out - selection, the pane's header, and a defect the checks could not see

- **`Core.Rows.PaneHeader`** ports the two header shapes inside `Show-Selected` -
  a conversation (band label, what the process is doing, the project) and a
  sub-agent (kind, who it works for, what it was asked to do). **`pane/header`
  splices both regions out of `Show-Selected`** and runs them over twelve
  conversations and five agents; `$ui` and `$window.FindResource` are stubbed,
  and the stub returns the resource KEY, which is what makes the dot comparable
  at all. **Six breaks, six reds.**
- **`Core.Rows.AgentRow`** is what a sub-agent row says. **`agents/row` splices
  the shipped row block** - the tag and tooltip, then the drawn fields out of the
  hashtable literal - over fourteen specs. **Eight breaks, seven red**; the
  eighth (passing `0` for now instead of the hoisted clock) is not a defect and
  was replaced by one that empties the age, which reds.
- **`IListRow`** is the compile-time half of the column's contract. The view
  filters, groups and sorts by property NAME, per item, by reflection - so two
  row types with a renamed property is not an error anything sees: the sort
  quietly stops ordering. Nothing binds to the interface; it exists so that
  cannot happen.
- 🔴 **`SubOrder` IS WHAT KEEPS AN AGENT UNDER ITS OWN CONVERSATION.** Every
  other key on an agent row is MIRRORED from its parent, so the pair ties on all
  of them and this breaks the tie. The shipped window never needed it - it builds
  the list in order - and a view that sorts is a different machine.
- 🪤 **AND THE FIRST CHECK OF IT COULD NOT GO RED.** With two conversations the
  break stayed GREEN: `Array.Sort`, which is what a `ListCollectionView` sorts
  with, falls back to a STABLE insertion sort below sixteen elements, so the
  agent rows stayed put for a reason unrelated to the code. The check now builds
  35 filler conversations to get above that threshold, and the break reds.
- 🔴 **THE PORT SHOWED EVERY AGENT A CONVERSATION HAD EVER SPAWNED - 24 of them,
  all finished, on the first conversation rendered. Found by LOOKING at
  `--render`; all 25 checks were green.** The shipped rule is what is RUNNING,
  plus the one being read, and its own comment records the operator reporting the
  other behaviour twice. The checks now assert one row of three, and that the one
  being read stays once it stops writing.
- **The collapsed strip's marks select too**, and deliberately do NOT re-open
  the column: un-folding there would undo the thing that was just asked for. It
  selects the row rather than rebuilding the column to reach it - the shipped
  handler used to call `Build-Sessions` purely so the rebind would restore the
  selection, audited at 164 ms with 114 of it inside that one call. 🪤 The strip
  is an `ItemsControl`, so its container is a **ContentPresenter** and a
  `is ListBoxItem` test in the check found nothing while the handler was right.
- **The pane's dot breathes only while a conversation is mid-turn**, and stopping
  it CLEARS the animation rather than setting the opacity back - an animation
  left running holds the property hostage and the assignment is ignored. Both
  halves are one check, because "it is still for a quiet conversation" passes
  just as well when the animation is never started for anything.
- `--handlers` is **27 checks**, nine of them selection, all inside the same
  binding-error trap. `--render` opens the first conversation in the VIEW that
  has agents - picking from the MODEL picks one that is not on the surface, and
  the picture came back with nothing on it and no way to tell why.

🪤 **A defect the port inherits on purpose: a COLD conversation whose sub-agent is
selected drops off the surface.** `Test-OnSurface` compares the selected id
against the conversation's own, and a selected agent's id is `agent:...` - so
neither the parent nor its agent rows survive the next model pass. It cannot
happen to a live or warm conversation, which is every one you can reach. Ported
as-is; parity first.

### 4.2c also found a live reader defect - and it was in the C#

🔴 **`run_in_background` is written BOTH WAYS.** A background Bash writes the
JSON boolean `true`; an **Agent writes the STRING `"true"`**. PowerShell's
`if ($b.input.run_in_background)` is true for any non-empty string, so the shipped
tool sees both - and the C#, testing `ValueKind == True`, **silently dropped every
background AGENT and kept every background shell.**

- Caught by `subagents/live-tasks` as *PowerShell 2, C# 1* on a conversation with
  one of each, with the file's length pinned on both sides so growth could not
  explain it. Confirmed by running both readers on the same bytes.
- **`Core.Json.PsTruth`** is now the one rule, and the other three sites use it:
  two had their own private copies that disagreed with each other about an empty
  array, and the third tested the kind directly. 🪤 **A non-empty string is true
  even when it says "false"** - that is what the shipped tool does, and a port
  that "fixed" it would differ from the window the operator is looking at.
- 🔴 **The live case could only catch it by coincidence** - it needs an agent to
  be out at that moment. **`subagents/task-shapes`** writes all twenty ways a
  launch, an id and a finish can be spelled, so the next one needs no luck.

### And one more harness hole, of the shape the others were

🪤 **`bands/live` went red on the `pending` column, and its guard could not see
it.** The guard compared a SHA of the last-said TEXT - so a session that is
mid-turn, changing what it is PENDING while the last thing it said stands,
matched the SHA, was never marked, and reported a real difference that was only
the operator working in that conversation. The read is now pinned with the
file's **length and last-write stamp on both sides of BOTH reads**, the whole row
is marked through `Moving.Mark`, the `rows` entry is marked with it (a
conversation that spoke can change BAND too), and the case fails if nothing held
still. Two breaks - the band, and the pending text - both red.

### 4.2d as it turned out - the acting seam, and a launch verified without launching

**Every handler that could reach a conversation now exists, is wired, and is
driven by the checks - and NOTHING behind them can act.** `IActs` is the one way
anything in the window reaches a session; the only implementation in the build is
`NoActs`, which performs nothing and records what it was asked. That is not a
placeholder, it is the check: pressing Relaunch asserts that a RELAUNCH was
requested, for THAT conversation, after a sheet was shown.

- **`Core.Acting`** turns each act into a VALUE - `Interrupt.Blocker`,
  `Typing.Of` (the send box's blocker and its note), `Relaunch.Refusal` /
  `PaneAsk` / `ManagerAsk` / `TabName` / `IsBootShell`. Same move as Phase 2:
  `Get-SRLaunchCommandLine` out of `Start-SRSession`, `Get-SRSaveRefusal` out of
  the fenced `Save-SRRegistry`. An act becomes a value, and a value can be
  compared.
- **`acting/decisions`** CALLS `Get-InterruptBlocker` (it is a function) and
  SPLICES the decision half of `Update-SendState`, over fifteen states a probe
  can report. **`acting/sentences`** evaluates the shipped LINE that builds each
  refusal and each sheet, with `Set-Status` and `Confirm-Action` replaced by
  stubs that only remember what they were handed. **Eight breaks, eight red.**
- 🔴 **`Invoke-RelaunchOne` IS NEVER EVALUATED, under any stub.** It calls
  `Stop-Process`. What is compared is the sentence it would say, cut out of the
  file by the words in it.
- 🪤 **A `Confirm-Action` sits inside `if (...)` and can be continued with a
  backtick**, so the call is cut by BALANCING the bracket the `if` opened. The
  first attempt took the nearest bracket behind the marker - which is the body
  argument's own - and evaluated a format string that called nothing, leaving
  every field empty.
- **`--handlers` is 39 checks**, twelve of them acting: Stop refuses what it
  cannot interrupt and asks no sheet; Relaunch asks first and does nothing at all
  on a no; the same button OPENS what is not running; /compact is sent as text
  and is not confirmed; Send trims and an empty box sends nothing; Go to terminal
  refuses a conversation with no terminal.

**The guard was widened, not relaxed:**

| | |
|---|---|
| the reference check | now also refuses `ConsoleApi`, `Process.Kill` and `Process.CloseMainWindow` |
| **a new one** | the only implementations of `IActs`, `IConfirms` and `IPreferences` in this assembly are the ones that do nothing - a second one is red, whatever it references |

🪤 **AND A BREAK THAT STAYED GREEN BECAUSE THE EDIT NEVER REACHED THE FILE.**
The script adding `Process.Kill` to the list threw on a later line and wrote
nothing, so the check went on reading the list it always had and the break looked
caught when the rule did not exist. Proven properly afterwards: with `Kill`
really on the list, the break reds. *Verify the bytes, not the intention.*

🪤 **A SECOND INVALID BREAK, the same day:** the first version of that one called
`Process.Kill()` for real, so the app killed itself before writing its report and
the harness read the PREVIOUS run's file. A reference in the metadata is all the
check reads, so the call now sits behind a condition that is false.

🔴 **TWO BLOCKING PRECONDITIONS FOR ANY REAL `IActs`:**

1. **There is no confirmation sheet in the ported window yet.** `NoConfirms`
   answers yes. An implementation that actually relaunches, wired before the
   sheet is ported, would close conversations without asking anybody.
2. **The send box does not yet know a conversation is sitting on a MENU.** That
   is the one refusal `Typing.Of` has that matters most - a session on a question
   reads keystrokes as menu input, so text typed at it PICKS AN OPTION rather
   than queueing behind one - and what knows is the screen probe, which the
   background pass has not ported. `onAMenu: false` is honest while nothing can
   act and must not survive anything that can. The queue DEPTH is wired, so the
   note already says where a message will land.

### 4.2e, the safe half - the two things that were blocking an implementation

**Both preconditions in front of anything that can act are now built and
proven, and nothing that can act was written.** They were named at the end of
4.2d as the reasons a real `IActs` could not be wired; this closes them.

**1. THE CONFIRMATION SHEET.** `NoConfirms` answered yes. An implementation
wired in front of that would have closed conversations without asking anybody.
`Views/Sheet.cs` is the shipped `Show-Sheet`: a nested `DispatcherFrame`, so the
caller parks on its own line while the dispatcher keeps pumping - which is what
lets seven call sites stay written as `if (Confirm-Action ...) { do it }`.
Buttons fill from the RIGHT so the primary always lands on B3, Esc answers with
whatever the caller nominated as the safe way out, Enter takes the primary, and
the scrim comes down only at depth zero.

- **`--handlers` is 51 checks**, twelve of them the sheet's, driven through its
  real buttons and real keys. **Ten breaks, ten red** - including Ask answering
  yes whatever was pressed, Escape taking the primary, the buttons filling from
  the left, and the sheet never being shown at all.
- 🪤 **AND ONE CHECK WAS ASSERTING THE WRONG THING.** The nesting check pressed
  B3 after an inner sheet had closed and expected the OUTER's answer; it got the
  inner's key, because a closing sheet does not put the outer one's labels back.
  That is the shipped behaviour character for character - `Show-Sheet` saves
  `$sheetFrame` and `$sheetEscape` and nothing else. **The check was wrong, not
  the port**, so it now asserts the thing that IS restored: the outer sheet's own
  Escape.
- The structural guard was widened rather than relaxed: the seam rule now reads
  *the only implementation of `IActs` here does nothing, and the only sheet is
  the one that asks*. A sheet cannot launch, type or write; a second `IActs`
  is still red.

**2. THE MENU PROBE.** The send box was passing `onAMenu: false`. A session
sitting on a menu reads keystrokes as MENU INPUT, so a sentence typed at it picks
an option instead of queueing behind the turn. `Core.Console.LiveMenu` is
`Test-SRPromptLine` + `Get-SRLiveMenuStart` + `Test-SRLiveMenu`, ported as one
function for the reason the shipped tool made it one: the band and the card were
answering it differently.

| the case | what it is over |
|---|---|
| `screen/menu-fixtures` | the fourteen CAPTURED screens, the start line and every prompt line BY INDEX |
| `screen/menu-live` | the operator's own consoles, on the screens that held still |
| `screen/menu-shapes` | twenty screens written to reach every rule |

🔴 **AND THE CAPTURES COULD NOT GO RED. Seven rules were broken one at a time
against `screen/menu-fixtures` and FOUR OF THE SEVEN STAYED GREEN** - a run of
one counting as a menu, the shortcuts status line dropped from the patterns, the
option pattern loosened to three digits and an empty label, and the patterns
losing the case-insensitivity PowerShell's `-match` gives them. The fourteen real
screens simply do not contain those shapes.

🔑 **WHICH IS "A GREEN OVER LIVE DATA PROVES ONLY THE PATHS LIVE DATA REACHES",
ONE LEVEL UP. A CAPTURED CORPUS IS STILL A DATA SOURCE.** A corpus is not a
spec; it covers the branches the captures happened to walk, and it stops being
obvious that it does once the files are checked in and look like fixtures. The
answer is the same one as always - substitute the data source, spell the shapes
identically on both sides, break each rule again. **Against `screen/menu-shapes`
all seven red.**

🪤 **AND `screen/menu-live` COMPARED FIVE CONSOLES WITH NOT ONE OF THEM ON A
MENU.** It proves the agreement holds on real screens; it proves nothing about
the menu arm, and its coverage line says so in as many words. That is the
distinction between a case that ran and a case that checked something.

**3. THE REFUSAL BELOW THE SEAM, which is the one that protects the operator.**
`Typing` decides what the window SAYS from what it has already seen;
`Core.Acting.SendRefusal` decides whether the keystrokes are written at all,
from a screen read taken at the moment of sending. The shipped tool split them
deliberately - the window's own record is up to ~26 s behind (a 15 s probe that
itself takes 11.3 s), and a screen read through the held-open reader costs ~9 ms.

- **`acting/send-refusal`** splices the ladder out of `Send-SRSessionInput` by
  the words in it, cutting ABOVE the first line that could type. The region is
  refused outright if `[SRCon]` appears anywhere in it, so there is nothing to
  stub - nothing that types is present. **Twelve breaks, twelve red**, including
  the menu refusal dropped altogether and the process check moved below the
  screen check.
- 🔴 **A FAILED READ IS NOT A MISSING MENU**, and that is deliberately not the
  safe-looking choice: the reader sometimes comes back empty about a menu that is
  plainly still there, so an unreadable screen refuses nothing. 🪤 The first
  break written for that rule was INVALID - `IsOn("")` is already false, so it
  changed no behaviour. The valid one (an unreadable screen treated AS a menu)
  reds.
- 🪤 **AND THE CURSOR GLYPH MANGLED IN TRANSIT, for the third time in this
  rebuild.** U+276F written literally into the script arrived as two Latin-1
  characters, the menu screen's first option stopped matching, and the PowerShell
  reported NO refusal where the C# reported the menu one - which reads exactly
  like a port that is wrong about menus. Every non-ASCII character now goes down
  the pipe as `$([char]0xNNNN)`.

**Verified:** 272 xUnit tests, **64 oracle cases**, `--surface` 164/164 exit 0,
`--handlers` **51/51** exit 0 with zero binding errors. 29 deliberate breaks
across the three units, 29 red - after two that were invalid and were redone.

🔴 **WHAT IS STILL NOT WIRED, AND IT IS ONE STEP RATHER THAN A RULE: nothing
FILLS the ask-seen record.** `Bands.Of` already takes it and `Typing.Of` already
reads it; what is missing is the cadence that reads a screen and sets it, which
belongs with the background model pass. Until that exists the window's send box
cannot know, which is why the refusal that matters lives BELOW the seam, where
the screen is read fresh.

---

### 4.2f - the band pick, and the first optimisation with a control under it

**THE BAND PICK.** Clicking a heading narrows the column to that band; clicking
it again gives everything back. It was deferred out of 4.2a with a note saying
why, and the note was right:

🪤 **IT CANNOT BE A FILTER.** The shipped column keeps EVERY heading when one
band is picked - *"hiding the others would leave no way back except a control
that is now off screen, and the counts beside them are the reason to switch in
the first place"* - and a grouped view builds its headings FROM its items, so a
band whose rows are filtered out loses its heading and its count with them.

🔑 **SO THE ROWS STAY IN THE VIEW AND THE CONTAINER COLLAPSES.** Every group
keeps its heading and its `ItemCount` - and the count stays RIGHT by doing
nothing, because the shipped `BandCount` is taken BEFORE the pick skips any row.
Two different questions, and one answer each.

- `--handlers` **63 checks**, nine of them the pick, pressed on the real heading
  through the real event. **Nine breaks, nine red.**
- 🪤 **AND `PreviewMouseLeftButtonDown` IS A DIRECT ROUTED EVENT.** Raised on a
  leaf it reaches that leaf and nothing above it, so the column's handler never
  ran and two checks read as a broken handler. A real click routes
  `PreviewMouseDown`, which every element on the way re-raises as the Left
  variant on itself. **The strip learned this in 4.2c and the rail before it;
  this is the third time.**
- 🪤 **A GroupItem CONTAINS ITS ROWS AS WELL AS ITS HEADING**, so "the first
  TextBlock under it" is a conversation's title. The heading's own elements are
  the ones whose DataContext is still the GROUP.
- 🪤 **AND TWO OF THE FIRST EIGHT BREAKS WERE INVALID.** One deleted a rule that
  was enforced in TWO places, so nothing changed; the fix was to delete the
  second copy rather than the check. The other found a real gap behind it - a
  sub-agent row BUILT while a band is picked started out drawn, because a
  constructor assumed rather than inherited.
- 🪤 **AND ONE CHECK COULD NOT SEE THE HEADING AT ALL.** Cutting the
  notification that tells the headings the pick moved left every check green:
  the column would narrow with no sign of why, and the way back is the heading
  you cannot see is pressed. Now asserted as the ground and the words.

---

**THE BENCH GREW A CONTROL, AND IT SHOULD HAVE HAD ONE FROM THE START.** Every
absolute figure carried out of Phase 3 was taken at 35-99% CPU with about thirty
live conversations, and none of them could be compared to anything afterwards.

| control | what it is |
|---|---|
| `spin` | a fixed arithmetic loop. Moves when the CPU is contended and for no other reason |
| `idle frame` | a drain to `ContextIdle` with NOTHING changed - WPF's own floor, through the very drain every gesture is measured with |

Both are medians over nine, taken BEFORE and AFTER the gestures, and the worse
of the two is reported. 🪤 The spin returns its sum and the caller keeps it: a
loop whose result is discarded is a loop the JIT may delete, and a control that
has been compiled away reads as a machine that got infinitely fast - which makes
every gesture beside it look correspondingly worse and be blamed on the diff.

🔴 **AND IT IMMEDIATELY RETIRED A CARRIED CLAIM.** `RESUME.md` said the ported
window read "5-10x the placeholder". Measured with the control in the same
process: **1,27x on `clear the project` and 2x on `cycle the sort`** - and the
placeholder's `clear the project` is over a frame too, at 17,45 ms. The port was
never the cause.

**FOUR SUSPECTS REMOVED ONE AT A TIME, AND NOT ONE OF THEM MOVED EITHER
GESTURE** (ported host, 40 repeats, spin beside each):

| variant | cycle the sort | clear the project |
|---|---|---|
| baseline | 16,15 (spin 8,15) | 22,49 |
| live sorting off | 16,30 (spin 5,68) | 22,47 |
| live grouping off | 18,35 (spin 6,19) | 23,64 |
| **grouping off entirely** | 15,89 (spin 8,03) | 18,64 |
| the fourth sort key dropped | 17,16 (spin 5,50) | 20,99 |

What was left was the containers. **A sort changed `SortDescriptions`, and
replacing one raises Reset whatever `IsLiveSorting` says** - so every realised
container was dropped and rebuilt through the real row template, which is the
8,5 ms the ported host pays over the placeholder.

🔑 **SO THE SORT MOVED OFF THE DESCRIPTIONS AND ONTO A KEY THE ROWS CARRY.**
Three descriptions, set once and never replaced - band, key, sub-order - and
cycling the sort assigns a new `SortKey` to each row. 🪤 Which means it has to
be ONE ascending string: "most recent" is descending, so the ticks are
subtracted from `long.MaxValue` and printed to a fixed width of 19, and "by
project" is two keys joined with a character that cannot occur in either.

**`cycle the sort`: 16,15 -> 8,17 ms, inside the frame.** (Spin 8,15 -> 6,96, so
about 1,7x after the machine is taken out of it.)

🔴 **AND IT BROKE THREE CHECKS WITHIN A MINUTE, WHICH IS THE POINT.** Rows
created by the model pass never got a key, so they all tied - and what then
decided the order was the sub-order, which puts every conversation above every
sub-agent instead of each agent under its own parent. A row is now keyed BEFORE
it is added to the view, because an unkeyed row enters at the position its empty
key puts it and live sorting does not put it right afterwards.

🔴 **AND THE OTHER HALF OF THE QUESTION HAD TO BE ADDED.** *"The view answers a
sort without a Reset"* went from `2 x Reset` to `the view raised nothing` - and
that sentence is satisfied perfectly by a view that has STOPPED SORTING. It is
the exact shape of the three Phase 3 checks that passed while the thing they
named was untrue. So `SelectionChecks` now asserts, over a real window, that the
column is really reordered by name, that each sort gives a different order, and
that **a conversation that just spoke rises to the top of a recent-first
column** - which is the reason live sorting is on at all and which nothing had
ever checked.

🪤 **AND A THIRD "OBVIOUS FIX" WAS MEASURED AND WAS WORSE.** Dropping the
`DeferRefresh` around the filter loop, so a WIDEN raises Adds instead of one
Reset: **24,17 ms against 21,57.** It joins the two Phase 3 already has.

🔴 **`clear the project` IS STILL OVER A FRAME AT 21,6 ms, AND IS LEFT THERE.**
It is the whole-list widen - 407 of 415 rows coming back at once - the placeholder
host is over on it too, turning grouping off entirely buys 4 ms of 22, and the
two cheap levers have now been measured and rejected three times between them.
It is one gesture, done rarely, at 1,3 frames, against 512 ms in the PowerShell.

---

### 4.3 as it turned out - the keyboard, and the order that cost the operator rewind

**The window's shortcut handler is ported, and the ORDER is what was ported.**
`PreviewKeyDown` tunnels root to leaf, so the window's handler runs BEFORE
whatever holds the keyboard - which is how the shipped tool ate Escape out of
the terminal watcher AND threw the focus out of the pane, so the SECOND Escape
of the rewind gesture went to the conversation list too. Neither could ever
work. `/` and `l` were going the same way: `/compact` arrived as `compact` and
`hello` as `heo`.

- **`Core.Keys.KeyRoute`** is the whole decision as a value - fourteen acts, and
  a `Handled` flag that is the other half of the answer.
- **`keys/route` EVALUATES THE SHIPPED HANDLER**, cut out of the file by the
  words around it, with each of its nine sinks replaced by a stub that records
  only its own name. Twenty-seven states. 🪤 Three of the nine sinks are
  ASSIGNMENTS rather than calls - emptying a search box, flipping `showOlder`,
  folding a project - so there is no function to stub and what they did is read
  off the state afterwards. A first version stubbed only the calls and reported
  "nothing happened" for the manager's own `O`.
- **`keys/term-typing`** puts `Test-SRTermTyping` through nine states.
  🪤 **AND ONE OF THEM HAD TO BE INVENTED TO MAKE A RULE OBSERVABLE AT ALL.**
  Dropping the empty-name guard stayed GREEN: an empty name simply misses in the
  streaming record and both sides say no anyway. It only parts company when the
  record HAS an empty key - so that shape is in the table now, and the break
  reds.
- **`--handlers` is 73 checks**, nine of them real keys raised into the real
  window. 🔑 The shipped suite could not do this at all: a window that has never
  been SHOWN has no PresentationSource and a `KeyEventArgs` cannot be
  constructed against one, which is why the decision was split into functions
  over there. This window is shown at -32000, so the tunnelling event itself can
  be raised - and a tunnel-order defect is exactly what a value comparison alone
  cannot see.

🔴 **AND WIRING IT BROKE THE SHEET, WHICH IS HOW THE MISSING RULE WAS FOUND.**
The first run hung with no report written: with a confirmation sheet up, the
window's new shortcut handler took Escape first, marked it handled, the sheet's
own handler never ran, and its nested dispatcher frame pumped for ever. The
shipped window gets this free - `Show-Sheet`'s handler is registered at line 297
and the shortcut handler at 14329, so the sheet marks the key handled and WPF
never calls the later one. The port asks instead: `WindowShell.SheetUp`.

🪤 **A COLLAPSED ELEMENT CANNOT TAKE THE KEYBOARD.** `LivePane` starts
Collapsed, so `Focus()` on it returns false - and the first version of the
watcher check pressed its keys with the focus still on the list and reported the
window eating them, **which is what the real defect would look like too**.

🔑 **AND AN UNPORTED ACT DECLINES THE KEY RATHER THAN SWALLOWING IT.** Five of
the fourteen belong to panels this port has not reached. Reporting a key as
handled when nothing happened is how a shortcut becomes a hole. There is a check
that says so, and it is MEANT to fail when the reading pane arrives.

**Six breaks of the wiring and twelve of the routing, all red** - including the
one that reproduces the original defect exactly, and one whose failure mode is
the run hanging rather than a red line.

**Verified:** 272 xUnit tests, **66 oracle cases**, `--surface` 164/164 exit 0,
`--handlers` **73/73** exit 0, zero binding errors.

🔴 **AND THE ASK-SEEN RECORD IS NOW A RECORD.** The send box was passing a
literal `onAMenu: false`; it reads `WindowShell.AskSeen` instead - the port of
`$script:askSeen`, set and cleared by EVIDENCE so that a recompute reaches the
same band rather than flipping the row between NEEDS YOU and WORKING. Nothing
fills it yet - the cadence that reads a screen belongs with the model pass - but
it is a gap with a name rather than a gap.

---

### 4.6 - the background pass: the board stops being a screenshot

**Every reader this rebuild needs was finished in Phase 2 and nothing had ever
called them on a clock**, so the ported window showed whatever was true when it
opened. `ModelPass` runs the three cadences the shipped window runs, and they
are three rather than one for a measured reason:

| tier | every | what it costs |
|---|---|---|
| fast | 6 s | a registry read. Re-derives the bands from the agent map WITHOUT re-reading transcripts - which is what moves a conversation into NEEDS YOU |
| live | 15 s | `claude agents --json`, a SUBPROCESS: 295 ms of a 508 ms refresh, the single dominant cost |
| ask | 400 ms | one screen read. The difference between a question appearing in fifteen seconds and in under half of one |

🔑 **THE PROBE'S TWO HALVES COLLAPSE INTO ONE PASS**, and it is the one
deliberate difference from the shipped structure. Over there the live probe is a
runspace started by one timer and harvested by a 200 ms collector, because a
DispatcherTimer tick cannot await. `BackgroundPass` already reads on the thread
pool and applies on the UI thread, so the starter and the collector are one
statement.

🔴 **AND THE ASK-SEEN GAP IS CLOSED.** The send box has been reading a record
that nothing filled. `Core.Sessions.AskSeenSet` is `Set-AskSeen` - flagged and
cleared by EVIDENCE, never by a recompute, which is what stopped a conversation
flipping between NEEDS YOU and WORKING every few seconds. `agents/ask-seen`
compares it over eleven polls, **answer and set**; five breaks, five red.

- **`--handlers` is 82 checks**, nine of them the pass. Every reader is
  SUBSTITUTED - nothing in the checks reads a live console or the registry.
- 🔴 **A poll whose answer did not move costs NOTHING.** 🪤 The first version of
  that check counted model reads and could not tell this tier's from the fast
  tier's - *"1 read during 4 polls"*, and no way to say which clock had struck.
  A check that cannot attribute what it measured is not measuring the rule; it
  counts rebands now.
- 🪤 **AND A CHECK PROVED THE WRONG LOOP SURVIVED.** "A pass that throws is
  reported and the loop carries on" cleared its failure flag the moment ONE
  failure was reported - so a tier that had never thrown kept the read count
  moving and the check passed while the loop that threw was dead.

🔴 **AND A BREAK FOUND A DEADLOCK I HAD WRITTEN.** Disposing the pass from the
UI thread while a pass was parked in `InvokeAsync` waiting for that same thread
hung the whole run for four minutes. It only surfaced because a break made the
fastest tier tick every 400 ms and so made the race easy to lose. The
cancellation token now reaches the invoke, and the check pumps rather than
blocks. **Six breaks of the pass, six red - after two that would not compile and
one that hung instead of reddening.**

**Verified:** 272 xUnit tests, **67 oracle cases**, `--surface` 164/164 exit 0,
`--handlers` **82/82** exit 0, zero binding errors.

---

### 4.6b - the rail over real data, and two breaks that were not breaks

**`rail/live` builds the rail from the registry that is actually on this
machine: 412 real conversations across 14 real projects, with real bands and
real live flags.** It was deferred out of 4.2b with a named trigger - *"the rail
needs bands and live agents per row, which the oracle has no model pass to
build"* - and the background pass built exactly that composition.

🔑 **THE POWERSHELL COMPOSES THE ROWS AND HANDS THEM OVER AS THE QUESTION.**
The band of a live conversation moves and the agent map is a subprocess taken at
one moment, so two sides reading those independently would differ for reasons
about the machine rather than about either rail. Here the INPUT is fixed by one
side and the ANSWER - headings, tiles, counts, accents, order - is computed
twice. **Nothing moves, so nothing needs forgiving, and a difference is real.**

🔴 **ONE VIEW REACHED ONE SET OF BRANCHES.** The first version built only
`recent`, and over that view the rail never reads the LIVE flag at all -
dropping it on the C# side stayed **green**. It runs `recent` and `only-live`
now, and the break reds.

🪤 **`busiest` AND `waiting` ARE DELIBERATELY NOT IN IT.** They order tiles by a
count, and over 412 real conversations that count ties constantly - both sorts
are unstable, so the two sides disagreed about the order of tied tiles and about
nothing else. `rail/build` already compares those two orders across eleven
shaped views with a tie normaliser written for it; a second copy here would
catch nothing new.

🪤 **AND TWO OF THE SEVEN BREAKS WERE NOT BREAKS AT ALL:**

| the break | why it changed nothing |
|---|---|
| reversing the accent order | `ProjectAccent.Order` sorts its input, so the reverse is a no-op. The valid form - making every lookup MISS, so every tile takes slot 0 - reds |
| un-disambiguating a project label | `ProjectLabels.Of` falls back to the path's leaf, and all fourteen of this machine's projects already have distinct leaves. **The disambiguation branch is not reachable by the operator's own data at all** - `labels/shapes`, over projects built to clash at every depth, is what covers it |

🔴 **The second one is worth keeping in view: a case over real data cannot test a
rule the real data does not contain**, and the tell is a break that will not go
red rather than anything in the output.

**Verified:** 272 xUnit tests, **68 oracle cases**, `--surface` 164/164 exit 0,
`--handlers` 82/82 exit 0. Six valid breaks, six red.

---

### 4.4, first tranche - the turns the reading pane draws

**`Core.Transcripts.ReadTurns` is `Get-ReadTurns` and `Get-RunSummary`: blocks
grouped into the turns the pane renders.** This is the whole of what the pane
SHOWS, as a value - and it is the half that can be compared before a pixel is
drawn.

🔑 **IT IS ALSO WHY THE DOCUMENT CAN BE VIRTUALIZED AT ALL.** The shipped window
builds a `FlowDocument` straight out of this function, and a FlowDocument has no
virtualization - which is the entire reason the pane needs a tail budget. A LIST
of turns can be bound to a virtualizing panel instead. Either way the grouping
is the same rule, so it is ported and compared first.

| case | over |
|---|---|
| `read/turn-shapes` | 34 blocks written to reach every merge, every call shape and every cut |
| `read/turns-live` | 195 real blocks from 12 real conversations, grouped into 89 turns carrying 31 steps |

🔑 **THE BLOCKS ARE THE QUESTION IN THE LIVE CASE, NOT THE ANSWER.** They are
already compared field for field by `transcript/blocks-detail`; what is asked
here is whether two GROUPERS of the same blocks agree. Reading the transcript
again on this side would compare two readers and two groupers at once, and a
difference in either would look the same.

🪤 **ONE EMITTER, SPLICED INTO THE POWERSHELL AND WRITTEN ONCE IN C#.** Two
hand-kept field lists drift, and a field only one side prints arrives as
*"present in PowerShell, missing in C#"* - which every allowance in this harness
is shaped to forgive by accident.

🪤 **AND `@($null).Count` IS 1, TWICE IN THAT ONE EMITTER.** A turn with no
calls reported *"1 step     "* and emitted a call made of empty strings - both
of which read exactly like a broken port. The kind says whether a turn carries
steps; `Where-Object { $_ }` says which calls are real.

**Twenty-two breaks, twenty-two red** - every merge, the blank line between
merged messages, the notice count, the head-first first notice, the three
special call kinds, the shell id read out of prose, the failed mark, the folded
line's cut at 127 (not 130), the blank-line handling either side of the fold,
the empty run that adds no turn, the turn's start stamp, and all four of the
summary's rules.

🔴 **AND ONE RULE HAD NO SHAPE UNTIL A BREAK STAYED GREEN ON IT.** Taking the
LAST answer for a call instead of the first went unnoticed, because neither the
written blocks nor twelve real conversations contained a call with two results.
A tool that streams produces exactly that, and taking the last would show the
tail of a long run instead of what it said. There is a shape for it now.

**Verified:** 272 xUnit tests, **70 oracle cases**, `--surface` 164/164 exit 0,
`--handlers` 82/82 exit 0.

**Still to come in 4.4:** the pane's own rendering - the turn cards, the folded
steps, the typography tuned against rendered pixels, and the virtualizing panel
that lets the tail budget go.

---

### 4.4b - what the pane DRAWS for each turn, and a shapes table that lied

**`Core.Transcripts.ReadDoc` is the document's own decisions**: the rule above a
human turn, the heading and whose voice it is, the trailing note, the marker
word, a fold's caption and the one line a closed fold shows, the gutter's mark,
and whether a fold starts open. `read/document` EVALUATES `Add-ReadTurn` with
every WPF sink replaced by one that only writes down what it was handed, at all
three steps settings.

🔴 **THE HIDDEN COUNT IS AN ACCUMULATOR ACROSS TURNS**, which is why this is a
document rather than a per-turn value. A dropped step adds to a running total
that is SPENT on the next heading - "3 steps hidden" beside the next thing
anybody said - and reset.

**Four real port defects, all found by the case:**

| what I had wrong | what the shipped one does |
|---|---|
| `thinking` drawn on `hidden` | dropped - and **not counted**, because reasoning is not a STEP |
| `queued` and `thinking` bodies both trimmed | only `thinking` trims |
| a gutter mark on every spoken turn | you/said/msgin are LABELLED; only rail blocks carry a mark |
| the hook, file and notice captions missing | `HOOK {name}`, `{tool}  N file(s)`, `NOTICE` / `N NOTICES`, each with a headline beside it |

🔴 **AND THE SHAPES TABLE WAS WEAKER THAN IT READ.** Eight breaks stayed green
the first time, and the biggest reason was not a missing rule - it was that
**six runs written back to back are ONE run.** The grouper consumes every
consecutive tool/result block into a single turn, so a table that looked like it
held six runs held one turn of sixteen calls, and every per-run rule was being
tested once. Found by a break that could not go red: matching ANY shell instead
of the live one changed nothing, because there was only ever one run and it held
the live shell already. A spoken turn between each of them fixed it: **27 turns,
68 drawn entries, and 25 of 26 breaks red.**

🪤 **THE TWENTY-SIXTH IS AN INVALID BREAK AND IS WRITTEN DOWN AS ONE.** The
`.Trim()` that `queued` lacks and `thinking` has cannot be seen from here at
all: the headline already skips blank lines and trims the line it picks. Where
it WOULD show is the fold's DATA, which this comparison does not reach.

🪤 **AND THE STALE ASSEMBLY CAUGHT ME TWICE IN ONE HOUR.** A break that will not
compile leaves the PREVIOUS binary in place, and `--no-build` then runs it and
reports green. Both times the tell was a coverage line that had not moved -
"14 turn(s)" after adding five shapes. The break harness checks the build's exit
code; a hand-run probe does not, and that is the one that lied.

🪤 **`ArrayList.Add` RETURNS THE INDEX.** The shipped `$doc.Blocks.Add($fp)` is
unguarded - correct against a FlowDocument, whose collection returns void - so a
stand-in ArrayList emitted a stray integer per block and the case failed with
*"'0' is invalid after a single JSON value"*, which names neither the call nor
the reason. `List[object]` has a void Add.

**Verified:** 272 xUnit tests, **71 oracle cases**, `--surface` 164/164 exit 0,
`--handlers` 82/82 exit 0.

**Still to come in 4.4:** the pixels - the turn cards themselves, the typography
tuned against rendered output, and the virtualizing panel that lets the tail
budget go.

---

### 4.5 - the one animation, and the port that had it wrong

🔴 **THE BREATHING DOT WAS WRONG SINCE 4.2c AND EVERY CHECK PASSED.** The port
wrote it straight into the shell - **1.0 to 0.35, no easing** - against a shipped
animation that goes to **0.25 on a SineEase, in and out**. The checks asked
whether the dot animated when a conversation was mid-turn and stopped when it
was not; both were true. None of them asked what it LOOKED like, and the shipped
source says exactly why that matters:

> *Eased, not linear: a linear fade reads as a fault light, a sine one reads as
> breathing.*

A dot reading as a fault light on every mid-turn conversation is the opposite of
what it is for. **It was found by reading `New-SRPulse`, not by a check.**

- **`Core.Rows.Pulse`** is the animation as numbers; `WindowShell.Breath()`
  builds it, once, for the reason the shipped tool has one function: *"two
  copies of a 900 ms sine is how they drift apart."*
- **`anim/pulse`** evaluates `New-SRPulse` and reads the real `DoubleAnimation`
  back field by field. Nothing is stubbed - building an animation draws nothing.
  🪤 The easing is compared by TYPE NAME and MODE, not by sampling: a different
  family with the same endpoints samples identically at 0 and 1 and differently
  everywhere a person looks. **Six breaks, six red.**
- 🔴 **AND THE ELEMENT IS CHECKED SEPARATELY FROM THE TABLE.** `anim/pulse`
  passes just as well if the dot is animated by something else entirely - which
  is precisely what had happened. `--handlers` now SAMPLES the dot's own opacity
  over a half-breath and requires it to reach the shipped floor: a fade that
  stops at 0.35 never reaches 0.3, whatever the table says. Measured **0.266**.
  The seventh break - the table right, the element wrong - reds.

**AND 4.5'S DONE-WHEN IS MET.** `--bench` now runs a THIRD host: the ported
window **with the pulse running**, which is the state the operator actually makes
gestures in - the dot breathes on every conversation that is mid-turn, and
mid-turn is when he is looking.

```
gesture                    median      min    worst   drawn   x idle
search keystroke             1.13     0.04    10.56       8     11.2   ok
clear the search             7.03     4.00    49.93       8     69.8   ok
pick a project               8.83     1.83    61.03      92     87.6   ok
clear the project           16.32     7.88    46.44       8    161.9   ok
cycle the sort               6.69     3.04    22.38       8     66.4   ok
only-live on and off         5.54     1.30    21.35       0     54.9   ok
```

**Exit 0 - the first time the bench has left non-zero behind.** 🪤 `clear the
project` is at 16,32 against a 16,7 budget, which is INSIDE and is not
comfortable: the same gesture measured 21,6 on a busier run an hour earlier.
The control is printed beside it so the next run can say which way the machine
moved, and the widen remains the one gesture with no margin.

🪤 **ON THE WINDOW, NOT ON A ROW.** A row's container is recycled by the
virtualizing panel, so an animation started on one is thrown away the moment it
scrolls - which would measure nothing and look like a pass. And it is cleared
before the window closes: an animation left running on a window holds it, and a
bench that leaked one would keep the process alive after its report was written.


---

### 4.4c-a - the pane's GEOMETRY, before anything is drawn with it

🔴 **THE ALIGNMENT HARNESS IS MADE OF THESE NUMBERS, SO THEY GO FIRST.** The
shipped rule is *"EVERY BLOCK STARTS ON THE TEXT COLUMN, OR IT IS ON A NAMED
LIST"*, and the text column is `PagePadding.Left + GutterW` - two values that
live in two different parts of a 15,000-line script. Port either of them wrong
and the ported harness still passes, because it would be measuring the port
against the port. `Core.Reading.PaneMetrics` settles them against the shipped
window first; the harness is built on top of numbers already known to agree.

**Five cases, and four of them read RENDERED ELEMENTS rather than a table:**

| case | what it compares |
|---|---|
| `pane/metrics` | the gutter base, the leading, the measure, the tail and the three line spacings - and the gutter, size and lead at **seven zooms**, two of them outside the clamp |
| `pane/marks` | every one of the fifteen markers by **code point** and by palette key, plus a capitalised kind, an empty one and an unknown one |
| `pane/measure` | `Set-ReadMeasure`'s page padding at six pane widths x three reading widths x **two zooms**, and the text column it implies |
| `pane/blocks` | `New-GutterPara`, `New-RailBlock`, `Add-ReadRule` and `Add-ReadLabel` **built for real** - margins, indents, column widths, the rail's inset and the gaps around a timestamp, read back off the objects |
| `pane/prose` | `Add-ReadProse` for six line shapes x grounded and not - where a bullet's block indent goes, which character it draws, and the hanging indent |

**48 breaks, 48 red.** [[feedback-verification]]

🪤 **AND FOUR OF THEM WOULD NOT GO RED THE FIRST TIME - none because the code
was right.** Each one is the same shape: *a case over data that cannot contain
the rule.*

- **`TooNarrow` and `AssumedWidth` were unobservable at 100% zoom.** The
  measured target is 867 px and the assumed pane is 900, so
  `available - 44 - target` is negative everywhere below about 1400 px and the
  44 px floor answers instead. The ladder now walks **two zooms**; at 70% the
  target is 600 and the arithmetic reaches the surface.
- **`TextColumn` had no consumer yet** - it is the harness's line, and the
  harness is the next tranche. `pane/measure` now reports it, computed the same
  way the shipped assertion computes it.
- **`ListBump` had no consumer either**, so `pane/prose` was written: it calls
  the real `Add-ReadProse` and reads the paragraph's margin.
- **A one-line grounded turn cannot tell "first and last" from "every".** The
  9 px cap inside a ground goes on the FIRST paragraph's `Padding.Top` and the
  LAST one's `Padding.Bottom`; a single-line turn is both, so a break that
  capped every paragraph stayed green. A three-line turn was added.

🔴 **A REAL DEFECT IN THE SHIPPED CODE, AND IT IS THE ORACLE'S ANSWER THAT
STANDS.** `Set-ReadMeasure -Size 16` does nothing. Its own comment calls the
parameter *"the one legitimate override (the shot harness renders at a fixed
size so a picture is comparable between runs)"* - but **PowerShell variable
names ignore case**, so the function's first line, `$size = $script:PaneSize`,
overwrites the `$Size` PARAMETER before `if ($Size -gt 0)` below it ever looks
at it. The test then reads 13, passes, and assigns 13 over 13. Every picture the
shot harness has ever taken was rendered at the pane size, not at the size it
asked for. `pane/measure` asserts the shipped behaviour and says why; the day
somebody repairs the collision, the case goes red and the note explains it.
[[feedback-powershell-truthiness]]

🪤 **A SPLICE ORDER THAT LOOKS EXACTLY LIKE A PORT DEFECT.** Running the
`$SR_Marks` literal before `$SR_MarkDot` bound every `G` to `$null`, `[char]$null`
is `[char]0`, and the whole marker table came back as fifteen NUL glyphs. The
shape on screen - every glyph wrong, all in the same way - reads as "the port
got the table wrong" and is a two-line ordering bug in the harness.

🔑 **`Typefaces.Scale` NOW CALLS `PaneMetrics.Size`.** The clamp and the
half-pixel rounding were about to exist twice - once for the type and once for
the gutter - and two copies of *"between 70 and 200, rounded to the half"* is
precisely how the marker column and the words it marks end up on different
half-pixels.

**Still to come in 4.4c:** the pixels themselves - the virtualizing panel that
replaces `FlowDocumentScrollViewer`, the turn cards, and the alignment harness
walking what they render.


---

### 4.4c-b - the pane as LINES, and the rule that a row is not a turn

🔑 **A ROW IS A LINE, NOT A TURN, AND THAT IS THE WHOLE POINT OF VIRTUALIZING.**
A reply of four hundred lines drawn as one item is one item the panel must
realize in full before it can measure the next; as four hundred rows, it
realizes the dozen on screen. The shipped `FlowDocument` had no choice - it does
not virtualize at all, which is the entire reason there is a 96 KB tail budget
to retire.

`Core.Reading.PaneRows` walks what `ReadDoc` already decided and splits the three
kinds that carry prose - `you`, `msgin`, `said` - into source lines, the way
`Add-ReadProse` does. **Nothing is re-decided there**; anything that looks like a
decision in it is a bug. `DocEntry` gained a `Turn` index for it, stamped in ONE
place rather than at the eleven emit sites, because the entries are a
SUBSEQUENCE of the turns and a view walking both lists in step would pair the
wrong body with the wrong heading the moment anything was hidden.

**Four more ports, all of them values:**

| what | why it had to be ported |
|---|---|
| `Core.Transcripts.Spoken` | `Convert-SRSpoken` - the one body the pane edits before drawing it |
| `Core.Reading.Inline` | `Add-SRInlineRuns` + `Add-SRLinkedText` - bold, inline code, emphasis, links |
| `Core.Reading.DocLinks` | `Set-SRDocLinks` + `Get-SRDocLinkRx` - which files this conversation wrote |
| `Core.Reading.PaneRows` | the split itself, plus the ground's first and last line |

**Four cases, and 49 breaks with 48 red** (the one that stays green is recorded
below as unreachable, not as a gap). `read/prose-live` compares **1,500 rows out
of 155 real bodies**, run by run - text, weight, slant, face, and whether it
opens.

🔴 **THE COMPARISON STARTED WEAKER THAN IT READ, AND THE EXCLUSION WAS THE
TELL.** The first version compared a whole line of text and excused any line
carrying a backtick or an asterisk as `(inline)` - about a third of the real
corpus. The first thing that exclusion hid was that the two sides did not agree
what `semi` MEANT on such a line: on the shipped side it had become *"something
in here is bold"*, on the ported side it was still *"this line is a heading"*.
The fix was not a better exclusion, it was to port `Add-SRInlineRuns` so there
is nothing to exclude. **An allowance that covers a third of the data is not an
allowance, it is the check giving up.**

🪤 **AND FOUR BREAKS THAT WOULD NOT GO RED, ALL FOR THE SAME REASON AS LAST
TIME:** the case could not reach the rule. A fence with trailing blank lines, a
seventh hash, a `+` bullet and a `\r\n` line ending were each absent from the
table; the empty `<command-args>` row could not tell the two orderings apart
because the whole string was the tag and `Trim()` flattened both answers. The
overlap and ordering rules inside the link splitter needed a SECOND pattern to
overlap with, which is why `DocLinks` was ported in this tranche rather than
later.

🔴 **TWO PIECES OF THE SHIPPED CODE CANNOT FIRE, AND THE PORT CARRIES THEM
ANYWAY.**

- **A URL on a line with no markdown marks is not a link.** `Add-ReadProse`'s
  cheap gate - *"a line with no backtick and no asterisk cannot carry any inline
  mark"* - skips the emitter that link detection lives inside. So
  `see https://example.com` is pressable only when the same line happens to hold
  a backtick or an asterisk. It is reproduced because the oracle compares against
  the window, but it reads as a defect rather than a decision.
- **The recursion cap of 3 is one more than can ever be used.** The bold
  alternative is non-greedy, so a bold span can never contain another `**` pair;
  the italic alternative's body is `[^*]*`, so an italic can never contain a `*`
  at all. The deepest a real line reaches is **2**. Measured: a cap of 1 goes
  red, a cap of 2 does not.

🪤 **THREE HARNESS TRAPS WORTH THE LINE THEY COST.** A placeholder token that is
a SUBSTRING of another (`CALLS` inside `OTHERCALLS`) silently rewrote the second
one - the same collision as `WIDTHS` inside `READWIDTHS` an hour earlier.
`JsonArray.Add(string)` needs a `TypeInfoResolver` and throws at the first
element - third time in this rebuild; `JsonValue.Create` is the answer. And
**PowerShell's `Sort-Object` is culture-aware and case-insensitive**, so it put
`bcdc864d358f` before `bcdc86-scratch` while an ordinal sort does the opposite -
and the two sides then disagreed about a SET they had both got right.

**Still to come in 4.4c:** the panel itself - the `ItemsControl` that replaces
`FlowDocumentScrollViewer`, the templates per row shape, and the alignment
harness walking what they render.

---

| next in 4.2 | why it waits | trigger |
|---|---|---|
| a live-data rail comparison | ✅ `rail/live`: 412 real conversations, 14 real projects, two views | - |
| 🔴 an implementation that really acts | the seam, the sheet and the menu probe are all built; what is left is the thing behind them - replica console, scratch registry and config, in its OWN assembly so this one stays provably unable to touch a conversation | **4.2e - the gate in front of the operator** |
| the ask-seen record | ✅ closed in 4.6: the ask tier fills it, `agents/ask-seen` compares the rule | - |
| **3.5's two measurements** | ✅ done, with a control: `cycle the sort` is 8,2 ms and inside the frame; `clear the project` is 21,6 and left there | - |
| a quiet-machine re-run | the bench now reports its own control, so a figure taken at 45% CPU can be set beside one taken at 5% - but none of the figures above was taken on an idle machine | whenever the machine is quiet |

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
