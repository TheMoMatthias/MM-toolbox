# session-restore

Bring back the Claude Code conversations **you have selected** — each with Remote
Control attached under its real name — automatically at logon, or from a desktop
button.

Nothing is tied to a particular repository. Projects are **discovered**; which of
them reopen is **your choice**.

## Quick start

```powershell
git clone https://github.com/TheMoMatthias/MM-toolbox.git
cd MM-toolbox
.\install.ps1
```

That registers two scheduled tasks, two desktop buttons, and three shell functions.
Open a new terminal:

| command | does |
|---|---|
| `ccs` | **choose what reopens** — interactive picker, projects with their conversations |
| `ccs -List` | print the current selection as a tree |
| `ccs -Disable E2b-python-312` | untick without the picker — matches a project path *or* a conversation title/id |
| `ccs -Enable F1-seam-wave` | tick the same way |
| `ccr` | restore the selected conversations, one tab each |
| `ccr -DryRun` | show what *would* come back, launch nothing |
| `ccr -All` | ignore the tick list and the cap, just this once |
| `ccr -Scan` | refresh the registry now |
| `cc` | start a correctly-**named** new session in the current directory |
| `cc "my-name" --model opus` | …with a name, plus any `claude` flags |

**Double-click** `Select Sessions.bat` or `Restore Sessions.bat` in this folder —
the desktop buttons point at those same two files, so there is one launch path.
They pass any arguments straight through (`Restore Sessions.bat -DryRun`) and pause
only when double-clicked, so the output stays readable. Set `SR_NOPAUSE=1` if you
ever drive them from a script.

`.\uninstall.ps1` removes both tasks and both buttons and leaves your selections
alone.

⚠️ **The name must come first:** `cc [name] [claude flags…]`. Once a flag appears,
everything after it goes to `claude` — otherwise the *value* of a flag gets taken
as the session name (`cc --model opus` would name the session `opus`).

## Two separate questions

**What exists** and **what should reopen** are deliberately different things.

- **Discovery** scans `~/.claude/projects/` and resolves every conversation's real
  working directory. It runs hourly and at logon as a *scan-only* task that
  **launches nothing**, so work you start today appears in the picker within the
  hour with no risk attached.
- **The registry** (`sessions-registry.json`, beside these scripts) records your
  ticks. A project you untick stays shut however discoverable it is — which is how
  a finished repo stops reopening every morning.

### Several conversations per project

A project can reopen **more than one** conversation, because you routinely run
several at once. The registry is therefore two levels: a **project** has a master
tick, and each **conversation** under it has its own. Untick the project and nothing
in it reopens; untick one conversation to drop just that slice.

### The ticks roll

The scan **recomputes** the auto-ticked set every hour, so it follows the work
rather than freezing at first discovery. Within each project, the newest
`autoTickPerDirectory` (3) conversations that were active within
`sessionWindowDays` (3) are ticked; anything that drops below that is unticked.
Go back to an old slice and it re-ticks itself; move on and it falls out.

That ceiling is the whole point. Measured here: AlgoTrader had **44** conversations
inside the tracking window and **16** inside a 3-day one. Without a ceiling,
"reopen everything recent" means sixteen tabs in one repo.

### …unless you pin it

Touching a conversation in the picker **pins** it — the roll then leaves it alone
permanently, and `*` marks it in the list. Without this, the hourly scan would undo
every hand-made choice within the hour and the picker would be decorative.

A pinned-and-ticked conversation **spends part of the ceiling**, so the total per
project stays bounded however it was set. Verified: pinning a fourth conversation
in a 3-ceiling project pushed the lowest auto-ticked one out, keeping the total at
three.

`U` in the picker hands one back to the roll (`U` on a project row releases all of
its conversations). `A`, `N`, `-Enable` and `-Disable` all pin what they change,
since they are deliberate acts.

A newly discovered **project** arrives ticked if you worked in it within
`recencyDays`; the project-level tick is never auto-managed.

### Two conversations in one working tree

They share a single git index, so a bare `git commit` in either takes whatever the
other staged. The restore **warns once per project** when it opens two or more, and
the picker flags it. The mitigation is `git commit -m msg -- <paths>`, not avoiding
it — you already run concurrent sessions this way.

### Your tick wins

If a ticked directory has not been touched in longer than `recencyDays`, it **still
reopens** — your explicit selection beats the heuristic. The picker shows it amber,
and the restore prints `STALE` and logs it. Age is *information*, never a second
gate: one source of truth, and it is the tick.

`recencyDays` therefore only decides what arrives **pre-ticked**. It does not gate
the restore.

## Why this exists

Launching a bare `claude` while `remoteControlAtStartup` is true registers a Remote
Control session **for an empty conversation**. The remote title then falls to the
last rule in Claude Code's precedence — an auto-generated
`<hostname>-graceful-unicorn` — and a later `/resume` does **not** send the
switched-to conversation's title or history to the connected device. Your phone ends
up bound to a placeholder the terminal already walked away from.

Each abandoned placeholder is a **118-byte** transcript holding one `bridge-session`
line with an *empty* `bridgeSessionId`.

The cure is to resume first and name explicitly:

```
claude --resume <id> -n "<name>" --remote-control "<name>"
```

| flag | writes | survives? |
|---|---|---|
| `-n <name>` | a `custom-title` record (precedence rule 2) | ✅ the **conversation** keeps the name for every future resume |
| `--remote-control <name>` | names only *this* remote session (rule 1) | ❌ measured: writes no `custom-title` |

Verified on a conversation with **zero** `custom-title` records across 7,638 lines:
one restore later it had exactly one.

**No hook can set a session title.** All 31 hook events are informational or
permission-gating, so a *new* session can only be named at launch — which is what
`cc` is for.

## Guards

- **Never opens a conversation twice.** A conversation is skipped if a `claude.exe`
  is already running it (matched on `--resume <id>` in its command line) *or* if its
  transcript was written in the last 3 minutes. Complementary: a bare-started
  session carries no id, and an idle one writes nothing. Every line names *which*
  conversation, since a project can have several.
- **Child-session environment is scrubbed.** A `claude` launched with
  `CLAUDE_CODE_CHILD_SESSION` inherited writes **no transcript at all**. Measured:
  env inherited → no `.jsonl` after 12 minutes; scrubbed → a real turn in 5 seconds.
- **Three distinct outcomes, never one silent green:** nothing discovered, nothing
  ticked, and nothing restorable are different problems and say so separately.
- **It logs.** At logon both tasks run hidden, so `Write-Host` reaches nobody. Every
  line also lands in `.state/restore.log`.

## Files

Everything lives in this folder — nothing is scattered elsewhere on the machine.

| file | |
|---|---|
| `Restore Sessions.bat` · `Select Sessions.bat` | double-clickable; the desktop buttons point here |
| `_common.ps1` | discovery, registry, the rolling auto-tick, guards, launching — shared, so there is one copy |
| `restore-sessions.ps1` | restore · `-Scan` · `-New` · `-Install` · `-Uninstall` |
| `select-sessions.ps1` | the picker |
| `profile.ps1` | the `cc` / `ccr` / `ccs` functions; your PowerShell profile gets a single dot-source line pointing here |
| `session-restore.config.json` | `recencyDays`, `maxSessions`, `excludePatterns` |
| `sessions-registry.json` | **your selections** (gitignored — the paths are local) |
| `.state/` | log + generated boot scripts (gitignored, regenerated) |

## Three traps worth knowing

1. **`$PSScriptRoot` is empty while a `param()` default is evaluated** under
   `powershell.exe -File`, which is how the tasks run. Resolve the script directory
   in the body, never in a parameter default. This failed hidden, at logon, once.
2. **`Get-Command wt.exe` returns nothing.** Windows Terminal is a WindowsApps
   execution alias — a reparse point often missing from a child shell's PATH, and
   from a scheduled task's. Fall back to
   `%LOCALAPPDATA%\Microsoft\WindowsApps\wt.exe`.
3. **`& script @args` (array splatting) does not reliably bind switches.** Measured:
   `cc -DryRun --model opus` put `-DryRun` into the pass-through array and *actually
   launched claude* instead of dry-running. The wrappers splat a **hashtable**.

If it ever seems to do nothing at logon, read `.state/restore.log` first.
