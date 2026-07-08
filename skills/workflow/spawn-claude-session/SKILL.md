---
name: spawn-claude-session
description: Spawn a brand-new Claude Code session in a separate terminal window. DEFAULT = a LOCAL, RESUMABLE session running on this PC (full functionality — all tools, file/bash access, the project) whose transcript is saved so you can reopen it later via `claude --resume` from a terminal in the same directory. It launches in a directory you CHOOSE (-Directory) or smart-detects the current cwd, so resumability is tied to the repo (AlgoTrader or any other). Remote Control (cloud, phone/web-driven) is a discouraged explicit opt-in only — the operator wants LOCAL resumable sessions, NOT cloud. Use when the user wants to start/launch/open an independent Claude session or another Claude terminal.
---

# spawn-claude-session

Launch a **new, independent Claude Code session** in its own terminal window. This
does **not** touch the current session — it opens a fresh one.

**Default = a LOCAL, RESUMABLE session** (`claude`). It runs on **this PC** with full
functionality (all tools, file/bash access, the project — exactly like typing
`claude` in a terminal) and writes its transcript (`<id>.jsonl`) into the project
folder for the launch directory. So the chat's "memory" survives: reopen it later
from **any terminal in the SAME directory** via `claude --resume` (pick it) or
`claude --continue` (most recent).

**Launch location — the design that makes resume work** (operator, 2026-07-08):
resumability is tied to the directory the session launches in, so it must open in the
repo you'll resume it from.
- **Choose it:** pass `-Directory "<path>"` (e.g. the AlgoTrader repo).
- **Smart auto-detect:** omit `-Directory` and it uses the current conversation's cwd
  — normally already the right repo. Say which directory you used in your reply.

**Remote Control is a DISCOURAGED explicit opt-in** (`-RemoteControl` / `-Rc`). It adds
`claude --remote-control <name>` to drive the session from the Claude mobile app /
claude.ai, BUT ⚠️ a **cloud-driven conversation's history lives in the cloud and may
NOT leave a locally-resumable transcript** (lesson 2026-06-16). **The operator does not
want cloud sessions** — only pass this on an explicit one-off request for phone control,
and mention the resume trade-off.

## What it does

Runs the bundled `spawn.ps1`, which opens a new **Windows Terminal** window (falling
back to a plain PowerShell window if `wt.exe` is unavailable), `cd`s into the target
directory, and runs:

```
claude                              # DEFAULT: local, resumable
claude --remote-control "<name>"    # only with -RemoteControl (cloud; discouraged)
```

The window is kept open (`-NoExit`).

## How to run it

1. **Determine the target directory** (this skill is parameterized by directory):
   - If the user gave a path in the invocation args, use it (`-Directory`).
   - Otherwise default to the **current working directory** and say so. Keeping the
     new session in the right repo dir is what makes it resumable there.
2. **Mode:** default to **local + resumable** (just run it). Add `-RemoteControl` ONLY
   if the user explicitly asks for phone/web control this one time.
3. **Optionally** pick up a session name and/or model alias.
4. **Run the launcher** via the Bash or PowerShell tool:

   ```powershell
   powershell -NoProfile -ExecutionPolicy Bypass -File "C:\Users\mauri\.claude\skills\spawn-claude-session\spawn.ps1" -Directory "<dir>" [-Name "<name>"] [-Model "<alias>"] [-RemoteControl]
   ```

   - Add `-DryRun` to preview the exact command + mode without spawning anything.
   - Add `-Pwsh` to force a plain PowerShell window instead of Windows Terminal.

5. **Report back:**
   - **Local (default):** the directory, and that it's resumable later via
     `claude --resume` / `claude --continue` from a terminal there.
   - **Remote Control (opt-in):** the session name, the directory, that the window
     shows the pairing URL/QR — and the caveat that it may not be locally resumable.

## Arguments (spawn.ps1)

| Param            | Meaning                                                                                    |
|------------------|--------------------------------------------------------------------------------------------|
| `-Directory`     | Repo/working dir for the new session. CHOOSE it, or omit to smart-detect the caller's cwd. |
| `-Name`          | Session display name. Auto-derived (`<leaf>-<MMdd-HHmm>`) if omitted.                       |
| `-Model`         | Optional model alias (`opus`, `sonnet`, …) for the spawned session.                        |
| `-RemoteControl` | (alias `-Rc`) DISCOURAGED opt-in: cloud phone/web control; may NOT be locally resumable.    |
| `-Pwsh`          | Force a PowerShell window instead of Windows Terminal.                                      |
| `-DryRun`        | Print the resolved command + mode; launch nothing.                                         |

## Notes / gotchas

- **Local + resumable is the default and the point.** Same directory + local session →
  `claude --resume` from a terminal there finds it. Only reach for Remote Control on an
  explicit phone-control request, knowing it trades away local resumability.
- **Auth (Remote Control only):** needs a logged-in claude.ai account. If the window
  prompts for `/login`, that's expected — complete it in that window.
- **Verified CLI surface:** the `claude` flag is `--remote-control <name>`. There is
  **no** `claude remote-control` subcommand and **no** `--rc` flag on the `claude`
  CLI — do not invent them. (`-Rc` is only an alias for *this launcher's*
  `-RemoteControl` parameter, not a `claude` flag.)
- **Independent session:** the spawned session has its own context window and does not
  inherit the current conversation. Brief it via the opening prompt if needed.
- **Windows-only launcher:** `spawn.ps1` targets Windows (wt.exe / PowerShell). The
  network path is outbound HTTPS:443 to Anthropic — no inbound ports.
