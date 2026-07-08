---
name: spawn-claude-session
description: Spawn a brand-new Claude Code session in a separate terminal window. DEFAULT = a LOCAL session WITH Remote Control enabled (`claude --remote-control <name>`) — it runs 100% on this PC with full functionality (all tools, file/bash, the project; you type in the local window) AND is drivable from the Claude mobile app / claude.ai so you can navigate it from your phone. It opens in a directory you CHOOSE (-Directory) or the smart-detected cwd. Pass -Local for a pure local session with no phone pairing (guaranteed locally resumable). Use when the user wants to start/launch/open an independent Claude session or another Claude terminal.
---

# spawn-claude-session

Launch a **new, independent Claude Code session** in its own terminal window. This
does **not** touch the current session — it opens a fresh one.

**Default = a LOCAL session WITH Remote Control** (`claude --remote-control <name>`).
The session runs **100% locally on this PC** with full functionality (all tools,
file/bash access, the project — you type in the local terminal window normally) AND
Remote Control adds a phone/web pairing so you can **also navigate/drive it from the
Claude mobile app / claude.ai**. The compute is local; only the message relay is
remote. This is the operator's standing preference (2026-07-08): full local control +
phone navigation.

**Launch location** — where it opens (resume/context is tied to this):
- **Choose it:** pass `-Directory "<path>"` (e.g. the AlgoTrader repo).
- **Smart auto-detect:** omit `-Directory` and it uses the current conversation's cwd
  — normally already the right repo. Say which directory you used in your reply.

**`-Local` (alias `-NoRemoteControl`) = opt out of Remote Control** → a pure local
session with **no phone pairing**, whose transcript is written to the project folder
for the launch dir and is **guaranteed reopenable** via `claude --resume` /
`claude --continue` from a terminal there.

⚠️ **Resumability trade-off (honest):** a pure `-Local` session definitely leaves a
locally-resumable transcript. A Remote-Control session may **not** always be
resumable from a local terminal (its history can live cloud-side — lesson 2026-06-16).
So the default gives phone control; use `-Local` when guaranteed local resume matters
more than phone access for that particular session.

## What it does

Runs the bundled `spawn.ps1`, which opens a new **Windows Terminal** window (falling
back to a plain PowerShell window if `wt.exe` is unavailable), `cd`s into the target
directory, and runs:

```
claude --remote-control "<name>"    # DEFAULT: local session + phone/web control
claude                              # with -Local: pure local, guaranteed resumable
```

The window is kept open (`-NoExit`) so the Remote Control pairing URL / QR stays readable.

## How to run it

1. **Determine the target directory:** use the path the user gave (`-Directory`), or
   default to the **current working directory** and say so.
2. **Mode:** default to **local + Remote Control** (just run it). Add `-Local` only if
   the user wants a pure local session with no phone pairing / guaranteed local resume.
3. **Optionally** pick up a session name and/or model alias.
4. **Run the launcher** via the Bash or PowerShell tool:

   ```powershell
   powershell -NoProfile -ExecutionPolicy Bypass -File "C:\Users\mauri\.claude\skills\spawn-claude-session\spawn.ps1" -Directory "<dir>" [-Name "<name>"] [-Model "<alias>"] [-Local]
   ```

   - Add `-DryRun` to preview the exact command + mode without spawning anything.
   - Add `-Pwsh` to force a plain PowerShell window instead of Windows Terminal.

5. **Report back:**
   - **Default (local + Remote Control):** the session name + directory, that it runs
     locally with full control AND the new window shows the pairing URL/QR for phone/web.
     Mention the resumability trade-off once.
   - **`-Local`:** the directory, and that it's guaranteed resumable via
     `claude --resume` / `claude --continue` from a terminal there.

## Arguments (spawn.ps1)

| Param            | Meaning                                                                                    |
|------------------|--------------------------------------------------------------------------------------------|
| `-Directory`     | Repo/working dir for the new session. CHOOSE it, or omit to smart-detect the caller's cwd. |
| `-Name`          | Session display name (Remote Control name / transcript label). Auto-derived if omitted.    |
| `-Model`         | Optional model alias (`opus`, `sonnet`, …) for the spawned session.                        |
| `-Local`         | (alias `-NoRemoteControl`) OPT OUT of Remote Control → pure local, guaranteed resumable.    |
| `-RemoteControl` | (alias `-Rc`) No-op affirmation — Remote Control is the DEFAULT now; kept for back-compat.  |
| `-Pwsh`          | Force a PowerShell window instead of Windows Terminal.                                      |
| `-DryRun`        | Print the resolved command + mode; launch nothing.                                         |

## Notes / gotchas

- **Local + Remote Control is the default.** Full local functionality on the PC PLUS
  phone/web navigation. Use `-Local` only when a session must be locally resumable.
- **Auth (Remote Control):** needs a logged-in claude.ai account. If the window prompts
  for `/login`, complete it in that window; the pairing URL/QR appears after.
- **Verified CLI surface:** the `claude` flag is `--remote-control <name>`. There is
  **no** `claude remote-control` subcommand and **no** `--rc` flag on the `claude`
  CLI — do not invent them. (`-Rc` is only an alias for *this launcher's*
  `-RemoteControl` parameter, not a `claude` flag.)
- **Keep spawn.ps1 pure ASCII:** Windows PowerShell 5.1 reads `.ps1` as ANSI, so an
  em-dash / smart quote corrupts the parse. Use `-`, plain quotes.
- **Independent session:** the spawned session has its own context window and does not
  inherit the current conversation. Brief it via the opening prompt if needed.
- **Windows-only launcher:** `spawn.ps1` targets Windows (wt.exe / PowerShell). The
  network path is outbound HTTPS:443 to Anthropic — no inbound ports.
