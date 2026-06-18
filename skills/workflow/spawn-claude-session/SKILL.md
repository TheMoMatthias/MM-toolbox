---
name: spawn-claude-session
description: Spawn a brand-new Claude Code session in a separate terminal window. By DEFAULT it is a local, RESUMABLE session opened in the current conversation's directory (so its chat history survives and can be reopened later via `claude --resume` from a terminal in that same directory). Pass -RemoteControl to instead drive it from the Claude mobile app / claude.ai (cloud-driven; may NOT be locally resumable). Use when the user wants to start/launch an independent Claude session or open another Claude terminal.
---

# spawn-claude-session

Launch a **new, independent Claude Code session** in its own terminal window. This
does **not** touch the current session — it opens a fresh one.

**Default = a LOCAL, RESUMABLE session.** It opens in the current conversation's
directory (the caller's cwd) and writes its transcript (`<id>.jsonl`) into the
project folder for that directory. That means the chat's "memory" survives: you can
later reopen it from **any terminal in the SAME directory** (e.g. a new VS Code
terminal) via `claude --resume` (pick it from the list) or `claude --continue` (the
most recent). **This is the behavior to use whenever you want to come back to the
chat.**

**Remote Control is OPT-IN** (`-RemoteControl` / `-Rc`). It adds
`claude --remote-control <name>` so the session can be driven from the Claude mobile
app / claude.ai. ⚠️ **Lesson (2026-06-16):** a remote-DRIVEN conversation's history
lives in the cloud and may **not** leave a locally-resumable transcript — if the
window is closed you may only be able to reopen it from claude.ai, not a local
terminal. So only choose Remote Control when phone/web control is the actual goal,
not when you want a resumable local chat.

## What it does

Runs the bundled `spawn.ps1`, which opens a new **Windows Terminal** window (falling
back to a plain PowerShell window if `wt.exe` is unavailable), `cd`s into the target
directory, and runs either:

```
claude                              # default: local, resumable
claude --remote-control "<name>"    # with -RemoteControl
```

The window is kept open (`-NoExit`).

## How to run it

1. **Determine the target directory** (this skill is parameterized by directory):
   - If the user gave a path in the invocation args, use it.
   - If they gave none, default to the **current working directory** (the directory
     the current conversation runs in) and say so in your reply. Keeping the new
     session in the SAME directory is what makes it resumable from a terminal there.
     (Only ask the user which directory if it's genuinely ambiguous.)
2. **Decide the mode:** default to a **local resumable** session. Only add
   `-RemoteControl` if the user explicitly wants to drive it from the phone/claude.ai.
3. **Optionally** pick up a session name (Remote Control only) and/or model alias.
4. **Run the launcher** via the Bash or PowerShell tool:

   ```powershell
   powershell -NoProfile -ExecutionPolicy Bypass -File "C:\Users\mauri\.claude\skills\spawn-claude-session\spawn.ps1" -Directory "<dir>" [-RemoteControl] [-Name "<name>"] [-Model "<alias>"]
   ```

   - Add `-DryRun` to preview the exact command + mode without spawning anything.
   - Add `-Pwsh` to force a plain PowerShell window instead of Windows Terminal.

5. **Report back:**
   - **Local (default):** the directory, and that the session is resumable later from
     a terminal in that directory via `claude --resume` / `claude --continue`.
   - **Remote Control:** the session name, the directory, that the new window shows
     the pairing URL/QR — and the caveat that it may not be locally resumable.

## Arguments (spawn.ps1)

| Param            | Meaning                                                                          |
|------------------|----------------------------------------------------------------------------------|
| `-Directory`     | Working dir for the new session. Defaults to caller's cwd (current conversation).|
| `-RemoteControl` | (alias `-Rc`) OPT-IN: enable Remote Control. Omit for a resumable LOCAL session. |
| `-Name`          | Remote Control display name. Auto-derived (`<leaf>-<MMdd-HHmm>`) if omitted.      |
| `-Model`         | Optional model alias (`opus`, `sonnet`, …) for the spawned session.              |
| `-Pwsh`          | Force a PowerShell window instead of Windows Terminal.                            |
| `-DryRun`        | Print the resolved command + mode; launch nothing.                               |

## Notes / gotchas

- **Resumability is the default and the point.** Same directory + local session →
  `claude --resume` from a VS Code terminal there finds it. Remote Control trades
  that away for phone/web control.
- **Auth (Remote Control only):** needs a logged-in claude.ai account. If the new
  window prompts for `/login`, that's expected — complete it in that window.
- **Verified CLI surface:** the `claude` flag is `--remote-control <name>`. There is
  **no** `claude remote-control` subcommand and **no** `--rc` flag on the `claude`
  CLI — do not invent them. (`-Rc` is only an alias for *this launcher's*
  `-RemoteControl` parameter, not a `claude` flag.)
- **Independent session:** the spawned session has its own context window and does not
  inherit the current conversation. Brief it via the opening prompt if needed.
- **Windows-only launcher:** `spawn.ps1` targets Windows (wt.exe / PowerShell). The
  network path is outbound HTTPS:443 to Anthropic — no inbound ports.
