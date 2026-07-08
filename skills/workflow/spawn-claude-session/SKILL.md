---
name: spawn-claude-session
description: Spawn a brand-new Claude Code session in a separate terminal window. DEFAULT = a LOCAL session WITH Remote Control enabled (`claude --remote-control <name>`) — it runs 100% on this PC with full functionality (all tools, file/bash, the project; you type in the local window) AND is drivable from the Claude mobile app / claude.ai so you can navigate it from your phone. It is fully locally RESUMABLE (`claude --resume` / `claude --continue`) — Remote Control does not disable local session persistence. Opens in a directory you CHOOSE (-Directory) or the smart-detected cwd. Pass -Local for a pure local session with no phone pairing. Use when the user wants to start/launch/open an independent Claude session or another Claude terminal.
---

# spawn-claude-session

Launch a **new, independent Claude Code session** in its own terminal window. This
does **not** touch the current session — it opens a fresh one.

**Default = a LOCAL session WITH Remote Control** (`claude --remote-control <name>`).
The session runs **100% locally on this PC** with full functionality (all tools,
file/bash access, the project — you type in the local terminal window normally) AND
Remote Control adds a phone/web pairing so you can **also navigate/drive it from the
Claude mobile app / claude.ai**. The compute is local; only the message relay is
remote. Operator preference (2026-07-08): full local control + phone navigation.

**Fully locally RESUMABLE — no trade-off** (confirmed vs the official Remote Control +
Sessions docs, 2026-07-08). Remote Control sessions are ordinary interactive sessions:
they persist their transcript locally at `~/.claude/projects/<encoded-cwd>/<session-id>.jsonl`
and reopen via `claude --resume` (pick by name) / `claude --continue` (most recent) /
`claude --resume <session-id>` from a terminal in that directory. Turns driven from the
phone/browser **sync into the SAME local transcript**, so a local resume continues the
FULL conversation. (`--no-session-persistence` only applies to headless `claude -p`; it
never affects interactive or Remote-Control sessions. If the phone link drops mid-session,
run `/remote-control` inside the session to re-attach.)

**Launch location** — where it opens (resume context is tied to this directory):
- **Choose it:** pass `-Directory "<path>"` (e.g. the AlgoTrader repo).
- **Smart auto-detect:** omit `-Directory` and it uses the current conversation's cwd.
  Say which directory you used in your reply.

**`-Local` (alias `-NoRemoteControl`) = opt out of Remote Control** → a pure local
session with **no phone pairing**. Resume is identical (both modes persist locally);
`-Local` only removes the phone/web channel — use it when you don't want phone access.

## What it does

Runs the bundled `spawn.ps1`, which opens a new **Windows Terminal** window (falling
back to a plain PowerShell window if `wt.exe` is unavailable), `cd`s into the target
directory, and runs:

```
claude --remote-control "<name>"    # DEFAULT: local session + phone/web control (resumable)
claude                              # with -Local: pure local, no phone pairing (resumable)
```

Resume either later with `claude --resume` / `claude --continue` from a terminal in
that directory. The window is kept open (`-NoExit`) so the pairing URL/QR stays readable.

## How to run it

1. **Determine the target directory:** use the path the user gave (`-Directory`), or
   default to the **current working directory** and say so.
2. **Mode:** default to **local + Remote Control** (just run it). Add `-Local` only if
   the user wants no phone pairing.
3. **Optionally** pick up a session name and/or model alias.
4. **Run the launcher** via the Bash or PowerShell tool:

   ```powershell
   powershell -NoProfile -ExecutionPolicy Bypass -File "C:\Users\mauri\.claude\skills\spawn-claude-session\spawn.ps1" -Directory "<dir>" [-Name "<name>"] [-Model "<alias>"] [-Local]
   ```

   - Add `-DryRun` to preview the exact command + mode without spawning anything.
   - Add `-Pwsh` to force a plain PowerShell window instead of Windows Terminal.

5. **Report back:** the session name + directory; that it runs locally with full control,
   is phone/web drivable (window shows the pairing URL/QR), AND is resumable via
   `claude --resume` / `claude --continue` from a terminal there.

## Arguments (spawn.ps1)

| Param            | Meaning                                                                                    |
|------------------|--------------------------------------------------------------------------------------------|
| `-Directory`     | Repo/working dir for the new session. CHOOSE it, or omit to smart-detect the caller's cwd. |
| `-Name`          | Session display name (Remote Control name / resume-by-name label). Auto-derived if omitted. |
| `-Model`         | Optional model alias (`opus`, `sonnet`, …) for the spawned session.                        |
| `-Local`         | (alias `-NoRemoteControl`) OPT OUT of Remote Control → local session, no phone pairing.      |
| `-RemoteControl` | (alias `-Rc`) No-op affirmation — Remote Control is the DEFAULT now; kept for back-compat.  |
| `-Pwsh`          | Force a PowerShell window instead of Windows Terminal.                                      |
| `-DryRun`        | Print the resolved command + mode; launch nothing.                                         |

## Notes / gotchas

- **Local + Remote Control is the default, and it's fully resumable.** Full local
  functionality on the PC + phone/web navigation + `claude --resume` all coexist. Use
  `-Local` only to drop the phone pairing, not for resumability (identical either way).
- **Resume recipe:** `claude --continue` (most recent) or `claude --resume "<name>"` /
  `claude --resume <session-id>` from a terminal in the launch directory. `/remote-control`
  inside a session re-attaches a dropped phone link. `--fork-session` branches to a NEW id.
- **Auth (Remote Control):** needs a logged-in claude.ai account. If the window prompts
  for `/login`, complete it in that window; the pairing URL/QR appears after.
- **Verified CLI surface:** the `claude` flag is `--remote-control <name>`; resume via
  `--resume [value]` / `--continue`. Do not invent a `--rc` flag on `claude` (`-Rc` is
  only an alias for *this launcher's* `-RemoteControl` param).
- **Keep spawn.ps1 pure ASCII:** Windows PowerShell 5.1 reads `.ps1` as ANSI, so an
  em-dash / smart quote corrupts the parse. Use `-`, plain quotes.
- **Independent session:** the spawned session has its own context window and does not
  inherit the current conversation. Brief it via the opening prompt if needed.
- **Windows-only launcher:** `spawn.ps1` targets Windows (wt.exe / PowerShell). The
  network path is outbound HTTPS:443 to Anthropic — no inbound ports.
