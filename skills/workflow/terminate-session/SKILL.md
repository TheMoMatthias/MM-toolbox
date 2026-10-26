---
name: terminate-session
description: End a local agent session (Claude Code or Pi) cleanly and verifiably, inside herdr or in a Windows Terminal / PowerShell window, keeping its transcript so it stays resumable. Use when a session has been handed over and is no longer needed, when retiring a lane after a successor took over, when closing idle or finished sessions to stay under a session cap, or when asked to close, kill, end, retire or terminate a session.
argument-hint: "<session name or id> | -Self | -List"
---

# terminate-session

One script, `terminate.ps1`, ends **one** session and proves it ended. It never guesses:
the target must match exactly one live session, by id, name or pid.

```powershell
$t = "C:\Users\mauri\.claude\skills\terminate-session\terminate.ps1"
powershell -NoProfile -ExecutionPolicy Bypass -File $t -List                 # inventory
powershell -NoProfile -ExecutionPolicy Bypass -File $t -Name LAB-B4 -DryRun  # plan only
powershell -NoProfile -ExecutionPolicy Bypass -File $t -Name LAB-B4          # end it
powershell -NoProfile -ExecutionPolicy Bypass -File $t -Self -DelaySec 20    # end THIS session
```

## What it does

1. **Finds the session** from two sources: the process table (`claude.exe` with
   `--session-id`/`--resume <uuid>` and `-n <name>`; Pi's `node.exe` with its session id)
   and, when a herdr server runs, `herdr agent list` (session id, tab, pane, status).
2. **Checks before it acts.** It refuses, unless `-Force`, when:
   - the target is the calling session (that needs `-Self`);
   - herdr reports it `working` or `blocked`;
   - it has **live background work**: `bash`/`git`/`python`/`ssh`/`gh`/shell descendants
     (MCP servers and shell snapshots excepted). They are listed. Measured 10-26: a session
     that reported its queue-wait push scripts "stopped" still had both alive; closing the
     window would have killed them mid-wait, or left them to push unowned;
   - no transcript exists, so it could not be resumed afterwards.
3. **Ends it the way it was hosted.** herdr: `herdr tab close` (or `pane close` when the
   tab holds other panes), then a process-tree kill if anything survives. Windows Terminal
   or PowerShell window: kills the agent's process tree and the spawn boot shell, so the
   terminal tab closes.
4. **Verifies**: no agent pid, no listed child and no herdr pane remains, then prints
   `VERIFIED` and the resume command. Exit codes: 0 done, 1 something survived, 2 refused,
   3 not found.

`-Self` cannot kill its own process mid-reply, so it starts a hidden, delayed copy of the
script and returns at once: finish the reply, and the session ends `-DelaySec` later.

## Judgment

- **End a session only when its work has moved.** Its RESUME or handover is written, its
  successor is verified running, and nothing of its own is still in flight. A `BLOCKER`
  line means one of those is not yet true: resolve it (hand the background work over, or
  wait for it to finish), don't reach for `-Force`.
- **`-Force` is for a session that is hung**, never for one that is merely busy.
- **Ending is reversible; losing the transcript is not.** The script keeps every transcript
  and prints `claude --resume <id>` / `pi --session <id>`.
- **Only your own sessions.** It acts on local processes of this user. Name a session from
  another project only when the user asked for that session by name.
