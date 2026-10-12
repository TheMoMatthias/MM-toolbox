---
name: spawn-session
description: Launch a fresh local agent session through a declared runtime adapter. Use when a handover needs Pi or Claude Code, or when a runtime-specific session must be persistent and honestly verified.
---

# spawn-session

A **registry + adapter** launcher. The local registry ships only `pi` and `claude`.
It refuses an unknown runtime instead of guessing a CLI, flags, or fallback.

## Choose, then launch

1. Choose the target directory/worktree and a concrete opening task. Validate every handover
   file first. Do not start two implementation sessions on the same lane.
2. Choose the runtime. On this machine recommend **Pi CLI first**. If `pi` is chosen, run the
   read-only inventory before asking for a model:

   ```powershell
   powershell -NoProfile -ExecutionPolicy Bypass -File ".\spawn-session\spawn.ps1" -Runtime pi -ListModels
   ```

   Offer **runtime default** first; a typed `-Model` override wins. Pi has no separate thinking
   choice: use its runtime default. For Claude, offer Claude default or a typed model override;
   it has no hard-coded inventory here.
3. Launch through the adapter:

   ```powershell
   powershell -NoProfile -ExecutionPolicy Bypass -File ".\spawn-session\spawn.ps1" `
     -Runtime pi -Mode implementation -Directory "<worktree>" -Name "<lane>" `
     -HandoffFile "<handover.md>" -Prompt "<first action>" [-Model "<model>"]
   ```

   `-DryRun` validates and prints the resolved plan without opening a terminal.
   `-AllowDuplicate` is accepted only with `-Mode analysis` and is printed as an override.

## Recover a spawned Pi session

Pi's `pi -r` picker is scoped to the current working directory. If a session was spawned in
another repository, running `pi -r` from the parent session's directory will not show it. Use
the recovery helper, which searches durable session headers and the latest session name across
all project buckets, then resumes the exact ID in its original directory:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File ".\spawn-session\recover.ps1" `
  -Name "<session-name>" -DryRun
powershell -NoProfile -ExecutionPolicy Bypass -File ".\spawn-session\recover.ps1" `
  -SessionId "<full-or-partial-id>"
```

Use `-List` to inventory all sessions, optionally filtered by `-Directory`. If a name is
ambiguous, the helper refuses to guess and prints the matching IDs. Do not launch a new handover
session merely because it is absent from a picker in a different cwd.

## herdr

When a herdr server is running, every runtime opens as a **named tab inside herdr**, so herdr
registers it (Agents panel, alerts, the herdr Navigator) and it outlives the herdr window. The tab
goes into the workspace already open on the target folder (a worktree workspace counts), else
herdr's worktree Space linked to the repo, else the repo's main workspace, else a new workspace.
Same placement as `spawn-claude-session`. A session started any other way (a Windows Terminal
tab, or a headless `pi -p` / `opencode run` from a shell) is **not** registered with herdr, so do
not use those for sessions meant to be handed over. No herdr running, `-Wt` or `-Pwsh` means the
old Windows Terminal / PowerShell window. The verification below is the same either way.

## Adapter contracts

- **Pi:** preassigns a UUID with `--session-id`, starts an interactive named `pi` session in
  herdr or Windows Terminal (never `pi -p`), and writes a durable launch receipt under
  `~/.pi/agent/spawned-sessions/<id>.json` before opening the terminal. The opening prompt is
  read from UTF-8 and passed as one argv element. Success means the target-cwd JSONL contains
  both that exact UUID and opening prompt; only then mark the receipt verified and report its
  ID, path, receipt, and `pi --session <id>` command. Otherwise preserve the receipt as
  unverified and report the preassigned ID plus original target directory for deterministic
  diagnosis/recovery. Cross-project discovery can use `recover.ps1`.
- **Claude:** delegates unchanged to `../spawn-claude-session/spawn.ps1`. Its existing adapter is
  the only source for Remote Control and verified resume claims.
- **Other runtime:** add a complete declarative entry only as `unverified`; see `STATUS.md`.
  Its launch report must remain unverified.

Read `STATUS.md` only when changing the registry or diagnosing a launch.
