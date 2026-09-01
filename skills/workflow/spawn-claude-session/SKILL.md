---
name: spawn-claude-session
description: Spawn a brand-new Claude Code session in a separate terminal window, brief it with a handover file, and leave it BOTH locally resumable (`claude --resume`) and phone-drivable (Remote Control on by default). Critically, it SCRUBS the inherited CLAUDE_CODE_CHILD_SESSION / CLAUDE_CODE_SESSION_ID environment before starting claude - without that scrub a spawned session writes NO transcript and its whole history is lost. Pass -HandoffFile to hand over handover/plan/memory .md files. Opens in a directory you CHOOSE (-Directory) or the smart-detected cwd. Use when the user wants to start/launch/open an independent Claude session, hand work over to a fresh session, or open another Claude terminal.
---

# spawn-claude-session

Launch a **new, independent Claude Code session** in its own terminal window, hand it a
**handover document**, and leave it **resumable** and **phone-drivable**. This does not
touch the current session.

## 🔴 The bug this skill exists to prevent

**A spawned session inherits its parent's Claude environment, and that silently
destroys its history.** The spawning session's shell exports:

```
CLAUDE_CODE_CHILD_SESSION=1
CLAUDE_CODE_SESSION_ID=<the PARENT session's id>
CLAUDECODE=1  CLAUDE_CODE_ENTRYPOINT  CLAUDE_PID  CLAUDE_CODE_SSE_PORT
```

Every child process inherits them — through `wt.exe`, through `powershell.exe`, into
`claude`. A `claude` that starts with those set is treated as a **child session** and
**writes no transcript of its own**, so `claude --resume` can never find it and the
entire conversation dies with the window.

**Measured 2026-07-28 (v2.1.220)** — two launches identical except the environment:

| | transcript |
|---|---|
| env inherited (what the old script did) | **no `.jsonl` at all after 12 minutes** |
| env scrubbed | `.jsonl` with a real assistant turn after **5 seconds** |

`spawn.ps1`'s generated boot script deletes those variables before running `claude`.
**That is the whole fix.** It affected every spawned session, Remote Control or not.

### ⛔ Refuted — do not re-derive it

> "`--remote-control <name>` at launch makes the session *bridge-born*, so its
> conversation lives on the bridge and cannot be resumed locally."

**False.** It looked true because every Remote-Control session on this machine had
been *spawned* (dirty env) while every session with a healthy transcript had been
*hand-started* in a terminal (clean env) — the environment was perfectly confounded
with the flag. A controlled test (clean env + `--remote-control` at launch) produced a
transcript containing the real user prompt, the real assistant reply, **and** the
`bridge-session` marker. **Remote Control does not cost local persistence.** Keep the
flag; Remote Control is on by default and needs no manual `/remote-control` step.

## What it does

1. Validates the target directory and every `-HandoffFile` **before** opening a window.
2. Pre-assigns a session id (`--session-id <uuid>`) so the resume command and the
   transcript path are known up front rather than guessed by diffing a directory.
3. Opens a new **Windows Terminal** window, `cd`s into the target directory, and runs a
   generated boot script that **scrubs the inherited Claude env**, then launches
   `claude -n <name> --session-id <uuid> --remote-control <name> "<opening prompt>"`.
4. Verifies: a live `claude.exe` carrying that session id, **and** a transcript
   containing a real conversation turn (which is exactly what `--resume` reads), **and**
   the `bridge-session` marker confirming Remote Control attached.
5. Prints the exact `claude --resume <id>` command.

## Handover

`-HandoffFile` is the normal way to brief the new session. Paths are resolved to
absolute and referenced **by path** in the opening prompt — the file stays the single
source of truth and the prompt stays small.

```powershell
-HandoffFile "C:\...\memory\handover_one_system_execution_2026-07-28_evening.md"
-HandoffFile "C:\...\handover.md","C:\...\plan_master.md"     # several, read in order
```

The generated opening prompt tells the session to read them end-to-end first and treat
them as the authoritative account of the work. Combine with `-Prompt` to add the
concrete first task on top of the handover.

## How to run it

1. **Target directory:** use the path the user gave (`-Directory`), or default to the
   current working directory and say which you used.
2. **Handover:** pass `-HandoffFile` for every doc the new session must read.
3. **Opening prompt:** `-Prompt` for the concrete first task. Never spawn with neither —
   a session that takes no turn does nothing and dies with its window.
4. **Run the launcher:**

   ```powershell
   powershell -NoProfile -ExecutionPolicy Bypass -File "C:\Users\mauri\.claude\skills\spawn-claude-session\spawn.ps1" -Directory "<dir>" -HandoffFile "<handover.md>" -Prompt "<first task>" [-Name "<name>"] [-Model "<alias>"]
   ```

   - `-DryRun` prints the resolved command, transcript path, env-scrub list and the
     full opening prompt without spawning anything.
   - `-Local` disables Remote Control (phone pairing) only.

5. **Report back:** session name, directory, handover file(s), the
   `claude --resume <session-id>` command, and that Remote Control is active.

## Arguments (spawn.ps1)

| Param             | Meaning                                                                                      |
|-------------------|----------------------------------------------------------------------------------------------|
| `-Directory`      | Repo/working dir for the new session. CHOOSE it, or omit to smart-detect the caller's cwd.    |
| `-Name`           | Session display name — used for `claude -n` (labels the `--resume` picker and terminal title) and as the Remote Control session name. Auto-derived if omitted. |
| `-Prompt`         | Opening prompt / first task. Delivered via a file, never through `-Command`.                  |
| `-HandoffFile`    | One or more handover/plan/memory `.md` files. Validated up front; referenced by absolute path. |
| `-Model`          | Optional model alias (`opus`, `sonnet`, …).                                                   |
| `-Local`          | (alias `-NoRemoteControl`) No Remote Control — local session only, no phone pairing.          |
| `-RemoteControl`  | (alias `-Rc`) No-op affirmation — Remote Control is the default.                              |
| `-Pwsh`           | Force a PowerShell window instead of Windows Terminal.                                        |
| `-TurnTimeoutSec` | How long to wait for the first turn to land in the transcript (default 180).                  |
| `-RetryHeadless`  | **F-226 hardening (chain/automation callers should pass this).** If the prompt produces no transcript turn inside `-TurnTimeoutSec` (the measured pre-transcript freeze: live pid, window open, zero turns), the frozen spawn is killed (our pid, by session id) and relaunched headless (`claude -p`, same env scrub, fresh session id, hidden window) with its own verify window of max(TurnTimeoutSec, 60)s. Measured working end-to-end 2026-08-28 (forced 2s window: kill + headless retry + verified turn). Exit codes are honest either way: 0 only when a turn was verified for the prompt given, 2 when every spawn path failed. |
| `-AllowDuplicate` | Spawn even though a live session already holds this directory or this name. **Prints itself** — an override is a visible act. |
| `-DryRun`         | Print the resolved command, transcript path and opening prompt; launch nothing.               |

## Notes / gotchas

- 🔴 **IT REFUSES TO SPAWN ONTO A LANE SOMEBODY IS ALREADY WORKING.** Measured 2026-08-21:
  a second session was spawned onto a plan row a live session had held for **73 minutes**,
  by a spawner who had checked every register the project offers — **none of which observes
  a running process**. This script queried the process table exactly once before, and only
  to poll for *its own* session id **after** launching.
  **Two keys, and the first is the strong one:** ① the **DIRECTORY** — a live `claude.exe`
  whose `--session-id` resolves into this directory's transcript folder is working this
  directory, whatever it is called; ② the **NAME**, as a second opinion for a live session
  the transcript store cannot place (measured: 3 of 12 processes carry neither `-n` nor
  `--session-id`).
  🔒 **It fails OPEN on every uncertainty** — an unreadable process table prints a note and
  proceeds. It can miss a duplicate; it can never invent one, because a false refusal blocks
  a session that has done nothing wrong. `-AllowDuplicate` overrides and says so.
  *(Ruled as R-95 §2 in the AlgoTrader refactor ledger, where the incident was measured.)*

- **Windows Terminal is required in practice.** A plain PowerShell window started from
  a non-interactive parent has repeatedly failed to give `claude` a usable console: the
  session starts but never submits its opening prompt. `-Pwsh` exists but warns.
- **`/remote-control` is a TOGGLE, not a re-attach button.** Typing it into a session
  that already believes it is connected **disconnects** it. An odd number of toggles
  from a connected state leaves you disconnected.
- **A successful connect prints nothing to stdout** (a disconnect does). Verify by the
  footer `[/rc active]` / the pairing URL, never by stdout being empty.
- **Do not try to auto-type keystrokes into the new window.** Windows Defender AMSI
  blocks `SendKeys` + `user32` window-targeting outright ("This script contains
  malicious content"), and Windows Terminal hosts many windows in **one process**, so
  activating by process id can land on a *different* session.
- **Auth (Remote Control):** needs a logged-in claude.ai subscription account. An
  API-key-authenticated session fails **silently**.
- **Diagnostic order for any RC failure:** ① status.claude.com ② count bridge
  connections (≫8 = retry storm — wait, don't fix) ③ only then suspect local config.
- **Keep `spawn.ps1` pure ASCII:** Windows PowerShell 5.1 reads `.ps1` as ANSI, so an
  em-dash / smart quote corrupts the parse.
- **Prompt text never crosses a shell boundary as syntax.** `powershell.exe -Command`
  re-parses its argv, so `(S4 first)` once became a subexpression and killed the window.
  The prompt goes to a `.txt` that a boot `.ps1` reads — a path is never parsed as code.
- **Independent session:** the spawned session inherits nothing from this conversation
  except what the handover file and opening prompt say.
- **Windows-only launcher.** Outbound HTTPS:443 only; no inbound ports.
