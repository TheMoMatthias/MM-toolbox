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
| `ccs` | **choose which directories reopen** — interactive picker |
| `ccs -List` | print the current selection and exit |
| `ccs -Disable CardTrader` | untick by path substring, no picker |
| `ccr` | restore the selected conversations, one tab each |
| `ccr -DryRun` | show what *would* come back, launch nothing |
| `ccr -All` | ignore the tick list and the cap, just this once |
| `ccr -Scan` | refresh the registry now |
| `cc` | start a correctly-**named** new session in the current directory |
| `cc "my-name" --model opus` | …with a name, plus any `claude` flags |

`select-sessions.ps1` and `restore-sessions.ps1` are ordinary scripts — run them
directly, or use the **Select Claude Sessions** / **Restore Claude Sessions**
desktop buttons. `.\uninstall.ps1` removes both tasks and both buttons and leaves
your selections alone.

⚠️ **The name must come first:** `cc [name] [claude flags…]`. Once a flag appears,
everything after it goes to `claude` — otherwise the *value* of a flag gets taken
as the session name (`cc --model opus` would name the session `opus`).

## Two separate questions

**What exists** and **what should reopen** are deliberately different things.

- **Discovery** scans `~/.claude/projects/` and resolves each conversation's real
  working directory. It runs hourly and at logon as a *scan-only* task that
  **launches nothing**, so a project you start today appears in the picker within
  the hour with no risk attached.
- **The registry** (`sessions-registry.json`, beside these scripts) records your
  tick per directory. A directory you untick stays shut however discoverable it is —
  which is how a finished project stops reopening every morning.

A newly discovered directory arrives **ticked if you worked in it within
`recencyDays`**, and unticked if it is older. So it behaves sensibly out of the box
and you only intervene to switch something off.

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

- **One session per working tree.** Two Claude sessions in one directory share a
  single git index, and a bare `git commit` in either takes whatever the other
  staged. A directory is skipped if a `claude.exe` is already running that
  conversation (matched on `--resume <id>` in its command line) *or* if the
  transcript was written in the last 3 minutes. Complementary: a bare-started
  session carries no id, and an idle one writes nothing.
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
| `_common.ps1` | discovery, registry, guards, launching — shared, so there is one copy |
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
