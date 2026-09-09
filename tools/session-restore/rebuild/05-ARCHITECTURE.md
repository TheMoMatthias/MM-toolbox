# The target architecture

Written, not generated. This is the design the rebuild is aiming at and the
reasoning behind each choice, so a later session can disagree with a decision
knowingly rather than drift away from it by accident.

---

## The target, in one line

**.NET 8, C#, WPF** — a single self-contained `Sessions.exe`, with the domain in
a library that has no reference to WPF at all.

### Why .NET 8 and not Framework 4.8

`app/SessionsHost.cs` compiles today with `csc.exe`, which ships with Windows,
so the current build needs nothing installed. .NET 8 gives that up in exchange
for `async`/`await` throughout, `System.Text.Json` with source generators,
nullable reference types, and a self-contained publish that stops asking
whether a runtime is present.

🪤 **The SDK is already on this machine** (`8.0.200`), so the objection that
usually kills this — "now the build needs a toolchain" — does not apply here.
It would still apply on a *fresh* machine, which is what `Install.bat` has to
learn to handle.

### Why WPF and not WinUI 3, Avalonia, or a web stack

`lib/window2.xaml` is 169 KB and 66 styles and templates, and **it is the single
biggest asset in this repo that ports across essentially unchanged.** Every
other target throws it away and re-does typography work that took days and was
measured against real screen captures.

- **WinUI 3** — better composition and genuinely independent animation, but the
  XAML dialect differs enough that the port stops being mechanical, and the
  packaging story is worse for a personal tool.
- **Avalonia** — cross-platform, which buys nothing here: the tool is
  Win32 console API from top to bottom.
- **Tauri / Electron** — best animation ergonomics, and it would need a native
  sidecar anyway for the 36 P/Invokes, so it adds a process boundary in exchange
  for throwing away the XAML.

🔴 **One honest cost of choosing WPF: its animations are ticked on the UI
thread.** A busy dispatcher freezes them. So smooth animation is not something
the framework gives you — it is a consequence of every gesture being short, and
that has to be true in any case.

---

## The shape

```
src/
  SessionRestore.Core/            <- no WPF reference. This is what makes it testable.
    Model/          Conversation, Project, Band, AgentStatus, Question
    Config/         the 25 settings, their defaults, their allowed values
    Registry/       read + the guarded writer
    Transcripts/    .jsonl reader, turn folding, the reading model
    Console/        the console API - one class, not two
    Sessions/       claude CLI, wt.exe, the process tree
  SessionRestore.App/             <- WPF, and as thin as it can be made
    Views/          the ported XAML
    ViewModels/     INotifyPropertyChanged, ICollectionView
    Services/       DI wiring, the background loops
  SessionRestore.Tests/           <- xUnit against Core. No window.
  SessionRestore.UiTests/         <- the shown-window harness, fenced as render-driver is
```

### 🔑 The one rule that matters: Core does not reference WPF

Everything the current test suites fight is a consequence of the domain and the
window living in one 15,252-line script. `tests/run-tests.ps1` *splices the GUI
at a literal line* to get a testable object; `refresh-bench-run.ps1` has a clash
guard because drivers are appended into the window's own scope.

None of that exists if the domain is a library. It is not a nicety — it is the
difference between 30,708 lines of harness and ordinary unit tests.

---

## The decisions, and why

### 1. Rows are bound once; sort, filter and search are `ICollectionView`

🔴 **This is the measured fix and the whole performance case.**
`tests/rebuild-bench.ps1` found that **81% of a column rebuild is constructing
and drawing 32 rows** — about a millisecond a row — and only 19% is the walk
over all 434 conversations. One search keystroke rebuilds both columns twice.

So the fix is not a faster rebuild. It is **not rebuilding**: an
`ObservableCollection<ConversationVm>` that changes only when the *model*
changes, with `ICollectionView.Filter` and `SortDescriptions` doing the gesture.
A keystroke becomes a predicate over 434 items in native code instead of 32
object constructions in an interpreter.

🪝 Keep `tests/rebuild-bench.ps1`'s measurement as the acceptance test — the
same gesture, the same machine, a number that has to move.

### 2. The reading pane virtualizes

`lib/window2.xaml` says it itself: *"a FlowDocument does not virtualize"*, which
is why there is a 96 KB tail budget and an "L" shortcut to lift it. Replace it
with an `ItemsControl` of turn view models over a `VirtualizingStackPanel`.

🪤 **This is the riskiest port in the plan**, because the typography — the
gutter, the grounded blocks, the hanging indents, the x-height calibration — all
lives in the pane, and it was tuned by looking at rendered pixels. Do it last of
the view work, and keep the alignment harness.

### 3. One console class, not two

The extractor found `AttachConsole`, `CreateFileW`, `ReadConsoleOutputCharacterW`
and five others **declared twice** — `SRCon` and `SRConLite` are two `Add-Type`
blocks with overlapping imports, which exists because a PowerShell script cannot
easily share a compiled type between two scopes. In C# that reason is gone.

🔑 And this is the part of the rebuild that gets strictly *easier*: 36 P/Invokes
that are currently C# fragments inside PowerShell strings, compiled at startup
with nothing checking the marshalling, become ordinary signatures the compiler
checks.

### 4. Safety becomes types, not conventions

🔴 A registry-overwrite bug in this repo's history cost **210 conversations.**
Today the guards are runtime checks and a discipline. In C# some of them can be
made unrepresentable:

- `Get-InterruptBlocker` refuses anything that is not `busy`. Make `Interrupt`
  take a `BusySession` that can only be constructed from a probe result that
  said busy. Then the gate cannot be forgotten at a new call site.
- The registry writer takes a `RegistryEdit` produced by a read-modify-merge,
  never a bare object. A blind overwrite has no type to pass.
- The forwarded key set is an enum, not a hashtable of strings.

### 5. Timers become a few async loops

11 `DispatcherTimer`s today. Most exist because PowerShell has no `await`. Fold
them into: one fast UI cadence, one background model refresh, one screen sweep,
one write lane — each an `async Task` with a `CancellationToken`, marshalling to
the dispatcher only to publish results.

🔴 Keep the cadences as *settings with their measured values*, not as new
guesses: `01-CAPABILITIES.md` lists every one, and the knowledge ledger records
what each was measured against.

### 6. The launcher stays, and hosts both during the cutover

`app/SessionsHost.cs` already owns `Main`, STA, DPI, single-instance and the
splash. It keeps doing that. During the cutover it can open either window, which
is what makes the migration incremental instead of a flag day.

---

## What does NOT get rebuilt

- **The retired window** (`lib/sessions-gui.ps1` and the suites that drive it).
  Its green says nothing about the app; carrying its assertions across would
  import requirements for a window that no longer exists.
- **The 101 named XAML elements with no handler** — check each against
  `01-CAPABILITIES.md` before porting. Some are labels and containers; some were
  wired once and are not any more.
- **The PowerShell test harness.** 30,708 lines. The *assertions* port
  (`04-BEHAVIOUR.md`); the splicing machinery does not, and does not need to.

---

## The acceptance targets

Measured today with a real frame on the end, 27 conversations on screen
(`tests/render-driver.ps1`). 60 fps is a 16,7 ms budget.

| gesture | today | target | why that number |
|---|---|---|---|
| a search keystroke | **512 ms** | **< 16 ms** | it must not drop a frame while typing |
| pick a project, then clear | **452 ms** | **< 16 ms** | pure view work, no model change |
| cycle the sessions sort | **98 ms** | **< 16 ms** | same |
| switch conversation | **749 ms** | **< 50 ms** | reads a transcript; one frame of delay is fair |
| zoom one step | **599 ms** | **< 50 ms** | relayout of everything |
| double-click to window | **~5,8 s** | **< 1 s** | measured 2026-08-27 at 208 conversations; re-measure at 434 before trusting it |

🪤 **Measure with a frame or not at all.** Every headless harness in this repo
reports these gestures 4-10x faster than they are, and three separate causes
were investigated and eliminated on headless numbers before anyone noticed that
no harness here draws anything.
