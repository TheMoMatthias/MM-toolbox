# hooks

UserPromptSubmit / SessionStart / Stop hooks for the Claude Code harness. Each hook is fail-open (any error -> exit 0; never blocks the session).

| Hook | Type | Purpose |
|---|---|---|
| `grill-gate.ps1` | UserPromptSubmit | Injects a short reminder when a prompt matches non-trivial signal buckets (structural, systemic, risk, tooling-sync). Counts how many buckets fire to give a provisional scope-tier guess (non-trivial vs major-or-top-tier), checks which grill skills are actually installed on the machine before naming them, and suggests `/wayfinder` only when the systemic bucket fires. Deliberately does NOT restate the pre-grill flow (skip-grill threshold, domain-lens dispatch, cite-evidence rule, contrarian framing, facts-vs-decisions split, autonomy contract) — that content is single-sourced in `grill-with-docs`'s `SKILL.md` so this hook can't drift out of sync with it; the reminder just points there. |
| `verify-loop.ps1` | Stop (`asyncRewake`) | Self-healing verify loop. Inert unless armed. Arm by writing `<repo>/.claude/verify-loop.active` (JSON: `{verify_command, attempt:0, max_attempts:5, deadline:<epoch+1800>, status:"active"}`). While armed, every Stop re-runs the verify command and re-wakes the model until it passes; capped at 5 attempts AND 30 minutes. On GREEN it walks the model through a safe commit-and-push (never `git add -A`, Critical-tier gate). Disarm = delete the sentinel. See global `CLAUDE.md` -> "Self-healing verify loop" for the full contract. |

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

The Stop hook is inert (exit 0) unless a project has `<repo>/.claude/verify-loop.active` — so registering it globally is safe.

After `install.ps1` symlinks `~/.claude/hooks` to this repo, settings.json keeps working — paths don't change, so `args` never goes stale (it must, however, be re-typed per machine with that machine's actual username).

### Why `args`, not a `%VAR%` / `$env:VAR` shell string — and why this is on its second rewrite

This wiring has broken twice, in two different ways, on two different real machines, both trying to reference the same home directory inside a single `command` string:

1. `%USERPROFILE%` (cmd/batch syntax) failed with `The argument '%USERPROFILE%\.claude\hooks\grill-gate.ps1' to the -File parameter does not exist` — whatever invoked the command didn't expand cmd-style `%VAR%` syntax, so PowerShell received it as a literal path containing percent signs.
2. `$env:USERPROFILE` (PowerShell syntax) — which fixed machine 1 — then failed on machine 2 with `Processing -File ':USERPROFILE\.claude\hooks\grill-gate.ps1' failed`. That mangled path is the signature of a **POSIX shell** (bash/sh), not PowerShell, parsing the string first: `$env` reads as an unset shell variable (-> empty), leaving the literal `:USERPROFILE...` behind.

The conclusion: **which shell actually parses a hook's `command` string is not guaranteed to be the same across machines/installs**, so no single `%VAR%` or `$env:VAR` syntax is safe to standardize on. The `args` array sidesteps the whole question — each entry is passed as a literal argv token, so nothing tokenizes or expands the path string regardless of what (if anything) sits between Claude Code and the `powershell.exe` process. The only cost is that the absolute path must be **hardcoded per machine** (swap `<you>` for the real username) rather than resolved from an env var — acceptable because `settings.json` is already machine-local and never synced by this repo.

If you still want to try a shell-string form for brevity, verify it round-trips on *this specific machine* before trusting it: pipe a test prompt through the hook directly (`'{"prompt":"test"}' | powershell.exe -NoProfile -File <path>`) and separately watch for a `UserPromptSubmit hook error` banner on a real prompt — don't assume a syntax that worked on another machine will work here.

## Notes

- **ASCII-only.** PowerShell .ps1 files in this repo MUST be ASCII (no curly quotes, no `→`, no `≥` — the hook stream chokes on UTF-16 BOMs and the heredocs become unparseable). The grill-gate uses `>=` and `->` for that reason.
- **Fail-open.** Every hook starts with `$ErrorActionPreference = 'Stop'` and an outer try/catch that exits 0 on any error. A broken hook should never block a prompt.
- **No interactive prompts.** Hooks run non-interactively. Use `Console::IsInputRedirected` guard to skip when stdin isn't piped.
- **Windows path wiring.** Use the `args`-array form with a hardcoded absolute path, not a `%VAR%` / `$env:VAR` shell string — which shell parses `command` is not guaranteed across machines. See the "Why" section above.
