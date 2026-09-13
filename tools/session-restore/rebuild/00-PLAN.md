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

🔴 **Still open in 4.1:**

| what | why it waits | trigger |
|---|---|---|
| **2b-2..: context bar, compact progress, sub-agent and shell counts** | their readers (`Get-SRRowCtx` + the vitals cache, `Get-CtxBrush`, `Get-SRCompactText`, the status-line parse behind `Set-RowScreenSig`) are PowerShell-only; each needs an oracle case before its property stops being present-and-off | next 4.1 tranche |
| **the band pick** (`BandBg`, "only this") | 🪤 it cannot be a filter: the shipped column keeps EVERY heading when one band is picked, and a filtered-out group has no header | 4.2, with the handler |
| **3.5's two measurements, against the real template** | the run on 2026-09-13 was at **99% CPU** (a game plus other sessions' python), so the ported window reading 5-10x the placeholder is not evidence of anything yet | a quiet machine: `--bench --repeats 40` |

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
