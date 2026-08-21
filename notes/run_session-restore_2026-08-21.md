# run: session-restore — history consolidated into this repo (2026-08-21)

Status: **done**. This is the durable record of the session-restore build and of the migration that
brought its conversation and memories into MM-toolbox's own scope.

## Why this file exists

`tools/session-restore/README.md` documents *what the tool is and why it is built that way*. It does
not record *where the work happened* or *how to get back to it*. That is this file's job.

## The build

Fourteen commits, `d2882db` → `90d3519`, 2026-08-17 11:55 → 2026-08-20 15:48, all direct to `main`
(this repo is main-only). Roughly in order:

| commit | what it settled |
|---|---|
| `d2882db` | session-restore in the README |
| `928d541` | `cc`/`ccr` misbound their arguments; a dry run could actually launch claude |
| `fa2420a` | selection registry, hourly scan, a picker, everything in one folder |
| `fbad31c` | several conversations per project, registered per conversation |
| `c1a9798` | `-All` ignored the cap, which now means 46 tabs |
| `792dcba` | the auto-tick rolls, pinning protects your choices, `.bat` entry points |
| `00ab9b9` | the scan took 115 seconds and said nothing while it ran |
| `5809579` | stop excluding git worktrees — it hid a live session |
| `6b5effd` | worktrees become lanes under their repo, with their own budget |
| `ae8429c` | worktrees on/off from the picker and the terminal, not just the config |
| `5388349` | quote launcher args — a space in the path killed every tab |
| `62e61fd` | double-clickable `Install.bat`/`Uninstall.bat`; stop swallowing bad switches |
| `9e9c410` | double-clickable installer for the tool alone |
| `90d3519` | `-ClaudeArg` passthrough for flags the script has no param for |

The measured findings behind these — the Remote Control naming precedence, the empty-`param()`
`$PSScriptRoot`, the missing `wt.exe` alias, the two argument-quoting traps — are written up in
`tools/session-restore/README.md`. Do not re-derive them.

## The migration (2026-08-21)

**Problem.** The whole tool was built in conversation `444f91ed-5a95-4157-a481-de977b7ade7c`
("RC-WORKFLOW"), but that session ran with `cwd = Trading Bot\Python\AlgoTrader`. Claude Code keys
transcripts by working directory, so the conversation was filed under the AlgoTrader project and
`claude --resume` from this repo never offered it. No memory recorded the tool at all.

**What was done.**

1. **Transcript relocated with its `cwd` rewritten.** `444f91ed-….jsonl` (6.1 MB, 2864 lines) and its
   `tool-results/` sidecar were copied into
   `~\.claude\projects\C--Users-mauri-Documents-MM-toolbox\`, and the top-level per-line `cwd` field
   — 1926 occurrences, exactly one distinct value — was rewritten to `C:\Users\mauri\Documents\MM-toolbox`.

   The rewrite was an exact-literal string replace, **not** a JSON re-serialisation, so every other
   byte is preserved verbatim. That is safe because a path quoted *inside* a message string is
   double-escaped (`C:\\\\Users`), so the single-escaped `"cwd":"C:\\Users\\…"` literal can only be
   the real field. Twenty double-escaped in-message mentions were left untouched, by design. All
   2864 lines were re-parsed as JSON after the write. The original mtime was then restored so
   `lastActive` still reads 2026-08-18 23:46 rather than the rewrite time.

   The `cwd` rewrite was necessary, not cosmetic: `_common.ps1` resolves a conversation's working
   directory **from inside the transcript**, so moving the file alone would have fixed `--resume`
   but left the picker filing it under AlgoTrader.

2. **Registry entry moved.** The `RC-WORKFLOW` session entry was moved out of the AlgoTrader block
   in `tools/session-restore/sessions-registry.json` into a new MM-toolbox block, keeping its title,
   `pinned: true`, `enabled`, and `firstSeen`. Its `stamp` was cleared so the next scan would
   re-read it. Confirmed: a subsequent `ccr -DryRun` scanned in 349 ms, re-resolved the cwd to
   MM-toolbox on its own, and recomputed the stamp.

3. **Memories written** into `~\.claude\projects\C--Users-mauri-Documents-MM-toolbox\memory\` —
   `project_mm_toolbox.md`, `reference_session_restore.md`, `project_conversation_relocation.md`,
   plus the three cross-cutting ones a session here still needs (`user_role`,
   `feedback_permissions`, `feedback_powershell_encoding`). Project memories for unrelated repos
   were deliberately not copied.

## How to get back to it

```
cd C:\Users\mauri\Documents\MM-toolbox
claude --resume 444f91ed-5a95-4157-a481-de977b7ade7c
```

It is **pinned but not ticked** in the restore registry, so it does not reopen at logon. Tick it in
`ccs` if you want it back automatically.

## Rollback

Nothing was deleted. The pre-migration originals:

- `~\.claude\projects\C--Users-mauri-Documents-Trading-Bot-Python-AlgoTrader\444f91ed-….jsonl.bak`
- the sidecar dir `…-de977b7ade7c.bak\` beside it
- `tools/session-restore/sessions-registry.json.bak`

Rename them back and delete the MM-toolbox copies. All three are `.bak`, which this repo gitignores,
so none of them is committed.

## Out of scope

The tool's behaviour was not changed — no script in `tools/session-restore/` was edited. The
conversation's `enabled` flag was left `false`; flipping it is a deliberate act for the picker, not
something a migration should do silently.
