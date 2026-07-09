# hooks

UserPromptSubmit / Stop hooks for the Claude Code harness. Each hook is fail-open (any error -> exit 0; never blocks the session).

| Hook | Type | Purpose |
|---|---|---|
| `grill-gate.ps1` | UserPromptSubmit | Fires on **every** prompt, unconditionally. Injects a short, content-blind reminder to apply the mandatory grill gate (`CLAUDE.md` -> "Mandatory grill gate") -- it never reads the prompt to decide anything, it only guarantees the check gets considered every turn instead of relying on the model remembering under mid-session momentum. The actual scope judgment (trivial / light-touch / non-trivial / major / top-tier) stays entirely with the model each time. Only names `/grill-with-docs` or `/grill-me` if they're actually installed on the machine. |
| `verify-loop.ps1` | Stop (`asyncRewake`) | Self-healing verify loop. Inert unless armed. Arm by writing `<repo>/.claude/verify-loop.active` (JSON: `{verify_command, attempt:0, max_attempts:5, deadline:<epoch+1800>, status:"active"}`). While armed, every Stop re-runs the verify command and re-wakes the model until it passes; capped at 5 attempts AND 30 minutes. On GREEN it walks the model through a safe commit-and-push (never `git add -A`, Critical-tier gate). Disarm = delete the sentinel. See global `CLAUDE.md` -> "Self-healing verify loop" for the full contract. |

## `grill-gate.ps1` history — two very different designs

**v1 (removed):** pattern-matched prompt text for refactor-class keywords (structural / systemic / risk / tooling-sync buckets) and only fired when something matched. It kept mis-firing — e.g. on "critically evaluate X" whenever X happened to contain a trigger word like "integrate" — because keyword regex fundamentally cannot distinguish a task from a question or a discussion. That's a *content-classification* problem, and a pre-flight hook that never actually reads the request in context is the wrong tool for it.

**v2 (current):** stopped trying to classify content at all. It fires on every single prompt with the same short, generic reminder regardless of what the prompt says, and leaves the actual "is this trivial / light-touch / non-trivial / major / top-tier" judgment to the model, every time, informed by whatever the model can see of the request. This trades "hook decides" for "hook guarantees the model decides" — it can no longer misclassify anything because it doesn't classify anything; the only thing it does is make sure the check isn't silently skipped once a long session's execute-mode momentum makes it easy to plow through a new non-trivial ask without re-triggering alignment.

Note that the batched, selectable `AskUserQuestion` format this whole thing exists to protect lives in `grill-with-docs`'s own `SKILL.md`, not the hook, in either version — the hook only ever controlled *whether the check gets surfaced*, never *how the questions get asked once it is*.

## Wiring

Each hook is registered in `~/.claude/settings.json` (which is NOT in this repo — it's machine-local). **Recommended registration** — pass the path as an `args` entry rather than embedding it in a shell string, so no shell ever gets a chance to parse/mangle it:

```json
{
  "hooks": {
    "UserPromptSubmit": [
      {
        "matcher": "*",
        "hooks": [
          {
            "type": "command",
            "command": "powershell.exe",
            "args": ["-NoProfile", "-ExecutionPolicy", "Bypass", "-File", "C:\\Users\\<you>\\.claude\\hooks\\grill-gate.ps1"]
          }
        ]
      }
    ],
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

The Stop hook is inert (exit 0) unless a project has `<repo>/.claude/verify-loop.active` — so registering it globally is safe. `grill-gate.ps1` always produces output (unless neither `grill-with-docs` nor `grill-me` is installed on the machine) — that's intentional, see above.

After `install.ps1` symlinks `~/.claude/hooks` to this repo, settings.json keeps working — paths don't change, so `args` never goes stale (it must, however, be re-typed per machine with that machine's actual username).

### Why `args`, not a `%VAR%` / `$env:VAR` shell string

This wiring broke twice, in two different ways, on two different real machines, both trying to reference the home directory inside a single `command` string:

1. `%USERPROFILE%` (cmd/batch syntax) failed with `The argument '%USERPROFILE%\.claude\hooks\grill-gate.ps1' to the -File parameter does not exist` — whatever invoked the command didn't expand cmd-style `%VAR%` syntax, so PowerShell received it as a literal path containing percent signs.
2. `$env:USERPROFILE` (PowerShell syntax) — which fixed machine 1 — then failed on machine 2 with `Processing -File ':USERPROFILE\.claude\hooks\grill-gate.ps1' failed`. That mangled path is the signature of a **POSIX shell** (bash/sh), not PowerShell, parsing the string first: `$env` reads as an unset shell variable (-> empty), leaving the literal `:USERPROFILE...` behind.

The conclusion still applies to any hook wired this way: **which shell actually parses a hook's `command` string is not guaranteed to be the same across machines/installs**, so no single `%VAR%` or `$env:VAR` syntax is safe to standardize on. The `args` array sidesteps the whole question — each entry is passed as a literal argv token, so nothing tokenizes or expands the path string regardless of what (if anything) sits between Claude Code and the `powershell.exe` process. The only cost is that the absolute path must be **hardcoded per machine** (swap `<you>` for the real username) rather than resolved from an env var — acceptable because `settings.json` is already machine-local and never synced by this repo.

## Notes

- **ASCII-only.** PowerShell .ps1 files in this repo MUST be ASCII (no curly quotes, no `→`, no `≥` — the hook stream chokes on UTF-16 BOMs and the heredocs become unparseable). Use `>=` and `->` instead.
- **Fail-open.** Every hook starts with `$ErrorActionPreference = 'Stop'` and an outer try/catch that exits 0 on any error. A broken hook should never block a prompt.
- **No interactive prompts.** Hooks run non-interactively. Use `Console::IsInputRedirected` guard to skip when stdin isn't piped.
- **Windows path wiring.** Use the `args`-array form with a hardcoded absolute path, not a `%VAR%` / `$env:VAR` shell string — which shell parses `command` is not guaranteed across machines. See the "Why" section above.
