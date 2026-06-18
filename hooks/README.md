# hooks

UserPromptSubmit / SessionStart / Stop hooks for the Claude Code harness. Each hook is fail-open (any error -> exit 0; never blocks the session).

| Hook | Type | Purpose |
|---|---|---|
| `grill-gate.ps1` | UserPromptSubmit | Injects a refactor-class reminder when a prompt matches structural / high-blast-radius patterns (refactor, re-architect, migrate, new subsystem, schema change, etc.). The reminder lists the full pre-grill flow: skip-grill threshold, mandatory pre-grill Explore, domain-lens dispatch, cite-evidence rule, contrarian framing rule, end-of-grill CONTEXT.md checkpoint, autonomy contract. |

## Wiring

Each hook is registered in `~/.claude/settings.json` (which is NOT in this repo — it's machine-local). Example registration:

```json
{
  "hooks": {
    "UserPromptSubmit": [
      {
        "matcher": "*",
        "hooks": [
          {
            "type": "command",
            "command": "powershell.exe -NoProfile -ExecutionPolicy Bypass -File \"%USERPROFILE%\\.claude\\hooks\\grill-gate.ps1\""
          }
        ]
      }
    ]
  }
}
```

After `install.ps1` symlinks `~/.claude/hooks` to this repo, settings.json keeps working — paths don't change.

## Notes

- **ASCII-only.** PowerShell .ps1 files in this repo MUST be ASCII (no curly quotes, no `→`, no `≥` — the hook stream chokes on UTF-16 BOMs and the heredocs become unparseable). The grill-gate uses `>=` and `->` for that reason.
- **Fail-open.** Every hook starts with `$ErrorActionPreference = 'Stop'` and an outer try/catch that exits 0 on any error. A broken hook should never block a prompt.
- **No interactive prompts.** Hooks run non-interactively. Use `Console::IsInputRedirected` guard to skip when stdin isn't piped.
