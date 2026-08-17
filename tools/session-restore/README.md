# session-restore

Bring back the Claude Code conversations you were last working on — each with
Remote Control attached **under its real name** — automatically at logon, or from a
desktop button.

Nothing here is tied to a particular repository. Projects are discovered.

## Quick start

```powershell
git clone https://github.com/TheMoMatthias/MM-toolbox.git
cd MM-toolbox
.\install.ps1
```

That registers a logon task, drops a **Restore Claude Sessions** button on your
desktop, and adds two shell functions. Open a new terminal:

| command | does |
|---|---|
| `ccr` | restore recent conversations, one tab each |
| `ccr -DryRun` | show what *would* come back, launch nothing |
| `ccr -All` | ignore the recency window and the cap |
| `cc` | start a correctly-**named** new session in the current directory |
| `cc "my-name"` | …with a name you choose |
| `cc "my-name" --model opus` | …and any `claude` flags, forwarded verbatim |

⚠️ **The name must come first.** `cc [name] [claude flags…]`. Once a flag appears,
everything after it is forwarded to `claude` — otherwise the *value* of a flag gets
taken as the session name (`cc --model opus` would name the session `opus`).

🪤 The `cc`/`ccr` wrappers splat a **hashtable**, never `& script @args`. Array
splatting does not reliably bind switches: measured, `cc -DryRun --model opus` put
`-DryRun` into the pass-through array and **actually launched claude** instead of
dry-running it.

`.\uninstall.ps1` removes the task, the button and the shell functions.

## The problem it solves

Launching a bare `claude` while `remoteControlAtStartup` is true registers a Remote
Control session **for an empty conversation**. The remote title then falls to the
last rule in Claude Code's precedence — an auto-generated `<hostname>-graceful-unicorn`
— and a later `/resume` does **not** send the switched-to conversation's title or
history to the connected device. Your phone ends up bound to a placeholder the
terminal already walked away from, showing an arbitrary name and no history.

Each abandoned placeholder is left on disk as a **118-byte** transcript holding one
`bridge-session` line with an *empty* `bridgeSessionId`.

The fix is to resume first and name explicitly:

```
claude --resume <id> -n "<name>" --remote-control "<name>"
```

### Why both flags

| flag | writes | survives? |
|---|---|---|
| `-n <name>` | a `custom-title` record in the transcript (precedence rule 2) | ✅ the **conversation** keeps the name for every future resume |
| `--remote-control <name>` | names only *this* remote session (precedence rule 1) | ❌ measured: writes no `custom-title` |

Passing a name the conversation already has is idempotent. Passing one it lacks is
what finally cures the auto-generated name — verified on a conversation that had
**zero** `custom-title` records across 7,638 lines and had exactly one afterwards.

### New sessions

**No hook can set a session title.** All 31 hook events are informational or
permission-gating; none can rename a session or run a slash command. So the only
cure for a *new* session is to never launch a bare `claude` — which is what `cc`
is for.

## How discovery works

1. Scan `~/.claude/projects/*` for the newest transcript ≥ 5 KB (smaller ones are
   Remote Control placeholders, not conversations).
2. Read the conversation's **real** working directory from the last `cwd` field in
   the transcript. The folder-name encoding is lossy — every non-alphanumeric
   character becomes `-`, so a space and a backslash are indistinguishable and the
   path cannot be reversed. Taking the *last* `cwd` also resolves a session that
   changed directory mid-life, and folds together the two project folders such a
   session ends up in.
3. Drop anything outside the recency window, matching an exclude pattern, or equal
   to the home directory.
4. Keep **one session per directory**, most recent first, capped — and say how many
   were dropped rather than truncating silently.

Tune it in `session-restore.config.json`. Per-machine tweaks go in
`~/.claude/session-restore.local.json`, which is merged over the committed defaults
and never committed.

## Guards

- **One session per working tree.** Two Claude sessions in one directory share a
  single git index, and a bare `git commit` in either takes whatever the other
  staged. A directory is skipped if a `claude.exe` is already running that
  conversation (matched on `--resume <id>` in its command line) *or* if the
  transcript was written in the last 3 minutes. The two are complementary: a
  bare-started session carries no id, and an idle one writes nothing.
- **Child-session environment is scrubbed.** A `claude` launched with
  `CLAUDE_CODE_CHILD_SESSION` inherited writes **no transcript at all** and cannot
  be resumed afterwards. Measured: env inherited → no `.jsonl` after 12 minutes;
  env scrubbed → a real turn on disk in 5 seconds.
- **It logs.** At logon the task runs hidden, so `Write-Host` reaches nobody. Every
  line also lands in `.state/restore.log`.

## Two things that only a real logon run will catch

Both of these passed by hand and failed under Task Scheduler:

1. **`$PSScriptRoot` is empty while a `param()` default is evaluated** under
   `powershell.exe -File`. Resolve the script directory in the body, never in a
   parameter default.
2. **`Get-Command wt.exe` returns nothing.** Windows Terminal ships as a
   WindowsApps execution alias — a reparse point often missing from a child
   shell's PATH, and from the thinner PATH a scheduled task inherits. Fall back to
   `%LOCALAPPDATA%\Microsoft\WindowsApps\wt.exe`.

If it ever seems to do nothing at logon, read `.state/restore.log` first.
