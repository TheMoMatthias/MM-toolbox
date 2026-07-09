# hooks

Stop hook for the Claude Code harness. Fail-open (any error -> exit 0; never blocks the session).

| Hook | Type | Purpose |
|---|---|---|
| `verify-loop.ps1` | Stop (`asyncRewake`) | Self-healing verify loop. Inert unless armed. Arm by writing `<repo>/.claude/verify-loop.active` (JSON: `{verify_command, attempt:0, max_attempts:5, deadline:<epoch+1800>, status:"active"}`). While armed, every Stop re-runs the verify command and re-wakes the model until it passes; capped at 5 attempts AND 30 minutes. On GREEN it walks the model through a safe commit-and-push (never `git add -A`, Critical-tier gate). Disarm = delete the sentinel. See global `CLAUDE.md` -> "Self-healing verify loop" for the full contract. |

## `grill-gate.ps1` — removed

This repo used to ship a `UserPromptSubmit` hook that pattern-matched prompt text for refactor-class keywords and injected a grill reminder. It was removed: keyword regex couldn't distinguish a task from a question or a discussion (it kept mis-firing — e.g. on "critically evaluate X" whenever X happened to contain a trigger word), and the thing that actually mattered — batched, selectable `AskUserQuestion` rounds — lives in `grill-with-docs`'s own `SKILL.md`, not the hook, so removing the hook doesn't touch that behaviour at all.

Its job now happens in-conversation instead of pre-flight: see global `CLAUDE.md` -> "Mandatory grill gate" for the replacement — a single selectable question, asked before any non-obviously-trivial work, offering proceed / light-touch / full grill with the model's own scope read as context. No hook, no keyword list to maintain, no false positives from surface text.

## Wiring

Each hook is registered in `~/.claude/settings.json` (which is NOT in this repo — it's machine-local). **Recommended registration** — pass the path as an `args` entry rather than embedding it in a shell string, so no shell ever gets a chance to parse/mangle it:

```json
{
  "hooks": {
    "Stop": [
      {
        "matcher": "*",
        "hooks": [
          {
            "type": "command",
            "command": "powershell.exe",
            "args": ["-NoProfile", "-ExecutionPolicy", "Bypass", "-File", "C:\\Users\\<you>\\.claude\\hooks\\verify-loop.ps1"],
            "asyncRewake": true
          }
        ]
      }
    ]
  }
}
```

The Stop hook is inert (exit 0) unless a project has `<repo>/.claude/verify-loop.active` — so registering it globally is safe.

After `install.ps1` symlinks `~/.claude/hooks` to this repo, settings.json keeps working — paths don't change, so `args` never goes stale (it must, however, be re-typed per machine with that machine's actual username).

### Why `args`, not a `%VAR%` / `$env:VAR` shell string

This wiring broke twice, in two different ways, on two different real machines, both trying to reference the home directory inside a single `command` string (back when `grill-gate.ps1` was still wired the same way):

1. `%USERPROFILE%` (cmd/batch syntax) failed with `The argument '%USERPROFILE%\.claude\hooks\grill-gate.ps1' to the -File parameter does not exist` — whatever invoked the command didn't expand cmd-style `%VAR%` syntax, so PowerShell received it as a literal path containing percent signs.
2. `$env:USERPROFILE` (PowerShell syntax) — which fixed machine 1 — then failed on machine 2 with `Processing -File ':USERPROFILE\.claude\hooks\grill-gate.ps1' failed`. That mangled path is the signature of a **POSIX shell** (bash/sh), not PowerShell, parsing the string first: `$env` reads as an unset shell variable (-> empty), leaving the literal `:USERPROFILE...` behind.

The conclusion still applies to any hook wired this way: **which shell actually parses a hook's `command` string is not guaranteed to be the same across machines/installs**, so no single `%VAR%` or `$env:VAR` syntax is safe to standardize on. The `args` array sidesteps the whole question — each entry is passed as a literal argv token, so nothing tokenizes or expands the path string regardless of what (if anything) sits between Claude Code and the `powershell.exe` process. The only cost is that the absolute path must be **hardcoded per machine** (swap `<you>` for the real username) rather than resolved from an env var — acceptable because `settings.json` is already machine-local and never synced by this repo.

## Notes

- **ASCII-only.** PowerShell .ps1 files in this repo MUST be ASCII (no curly quotes, no `→`, no `≥` — the hook stream chokes on UTF-16 BOMs and the heredocs become unparseable). Use `>=` and `->` instead.
- **Fail-open.** Every hook starts with `$ErrorActionPreference = 'Stop'` and an outer try/catch that exits 0 on any error. A broken hook should never block a prompt.
- **No interactive prompts.** Hooks run non-interactively. Use `Console::IsInputRedirected` guard to skip when stdin isn't piped.
- **Windows path wiring.** Use the `args`-array form with a hardcoded absolute path, not a `%VAR%` / `$env:VAR` shell string — which shell parses `command` is not guaranteed across machines. See the "Why" section above.
