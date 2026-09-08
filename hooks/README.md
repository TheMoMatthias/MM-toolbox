# hooks

Hooks for the Claude Code harness. Each is fail-open (any error -> exit 0; never blocks a session).

**`install.ps1` now registers these in `~/.claude/settings.json` for you.** It used not to, and
that gap is the reason this README was rewritten — see *Wiring* below.

| Hook | Type | Purpose |
|---|---|---|
| `grill-gate.ps1` | UserPromptSubmit | Fires on **every** prompt, unconditionally, and never reads the prompt to decide anything. Injects a short reminder whose default is **PROCEED**: state your scope read in one line and start working. It names the narrow set of cases that justify a question (irreversible/outward-facing, a required named approval, or a genuinely consequential ambiguity nothing on hand settles) and explicitly forbids the old "proceed / light-touch / full grill" menu. |

## Retired — `hooks/retired/`, kept for the record, **do not register**

| Hook | Retired | Why |
|---|---|---|
| `objective-loop.ps1` | 2026-09-08, one day old | A Stop hook that refused to let a session end while its objective list held open items. It **worked** — on its first live run it caught a `%TEMP%` leak, a false claim made to the operator, and a design defect in itself, all past a confident stopping point. It was still removed, on operator instruction, because **it could only ever read a list the model itself wrote**, so it could not distinguish "work remains" from "there is nothing left to do", and applied the same pressure to continue either way. It also, in one session, overrode the operator's own instruction to stop — which is disqualifying on its own. Replaced by judgement (global `CLAUDE.md` -> "Continuing without being told") and by the `continue-work` skill, which makes autonomy something the operator switches ON rather than something a hook imposes forever. |
| `verify-loop.ps1` | 2026-09-08 | Self-healing verify loop; armed by a `<repo>/.claude/verify-loop.active` sentinel, re-ran a verify command until it passed. **It was never registered in `settings.json` on any machine and therefore never ran once**, while the global `CLAUDE.md` described it as installed for weeks. Superseded in intent by the above, and by CI. Its real lesson is the *Wiring* section below. |

🧠 **The lesson both retirements share, and it is worth more than either hook: a mechanism that
coerces the MODEL must never be able to coerce the PERSON, and a mechanism nobody verified is
indistinguishable from one that works.**

## `grill-gate.ps1` history — three designs, two failures

**v1 (removed):** pattern-matched prompt text for refactor-class keywords and only fired on a
match. It kept mis-firing — e.g. on "critically evaluate X" whenever X contained a trigger word
— because keyword regex fundamentally cannot distinguish a task from a question from a
discussion. That is a *content-classification* problem, and a pre-flight hook that never reads
the request in context is the wrong tool for it.

**v2 (removed):** stopped classifying content entirely and fired on every prompt with the same
generic reminder, leaving the judgement to the model. Correct as far as it went — but it told
the model to **ask** a selectable "proceed / light-touch / full grill" question every time.
Measured outcome: the operator chose `proceed` every single time it was shown. A question whose
answer is known in advance costs a full round trip and buys nothing, and it trained sessions to
treat stopping-to-ask as the normal shape of work.

**v3 (current):** keeps the unconditional fire — momentum really does bury a scope check — and
**inverts the default to PROCEED**. The model states its read in one line and starts. A question
is reserved for cases where being wrong is expensive and unrecoverable. Deep alignment stays
available, but opt-**in** by the operator (`/grill-with-docs`), not opt-out by the model.

## Wiring

🪤 **LINKING A HOOK IS NOT INSTALLING IT, AND THE DIFFERENCE IS INVISIBLE FROM THE FILESYSTEM.**
This README used to say settings.json "must be re-typed per machine with that machine's actual
username". The measured consequence: `verify-loop.ps1` sat hardlinked into `~/.claude/hooks/`
for weeks while `settings.json` registered **no `Stop` hook at all**, so it never ran — and the
global `CLAUDE.md` described it as installed the entire time. Nobody re-derived it, because a
linked-but-unregistered hook and a working one look identical.

**So `install.ps1` now does both** (section 2b): it links the file *and* registers it, merging
into whatever `settings.json` already exists, backing the file up first, validating the result
before writing, and verifying by marker afterwards. Re-running is a true no-op. Pass
`-NoHookRegistration` to skip it if you maintain the hooks block by hand.

Scope is deliberately narrow — **hook entries only**. Permissions, `autoMode`, model, statusLine
and everything else in `settings.json` stay yours, per machine.

The shape it writes:

```json
{
  "hooks": {
    "UserPromptSubmit": [
      {
        "hooks": [
          {
            "type": "command",
            "command": "powershell.exe",
            "args": ["-NoProfile", "-ExecutionPolicy", "Bypass", "-File", "C:\\Users\\<you>\\.claude\\hooks\\grill-gate.ps1"],
            "timeout": 5,
            "statusMessage": "grill-gate"
          }
        ]
      }
    ]
  }
}
```

### Why `args`, not a `%VAR%` / `$env:VAR` shell string

This wiring broke twice, in two different ways, on two different real machines, both trying to
reference the home directory inside a single `command` string:

1. `%USERPROFILE%` (cmd/batch syntax) failed with `The argument '%USERPROFILE%\.claude\hooks\grill-gate.ps1' to the -File parameter does not exist` — whatever invoked the command didn't expand cmd-style `%VAR%`, so PowerShell received a literal path containing percent signs.
2. `$env:USERPROFILE` (PowerShell syntax) — which fixed machine 1 — then failed on machine 2 with `Processing -File ':USERPROFILE\.claude\hooks\grill-gate.ps1' failed`. That mangled path is the signature of a **POSIX shell** parsing the string first: `$env` reads as an unset shell variable (-> empty), leaving the literal `:USERPROFILE...`.

**Which shell actually parses a hook's `command` string is not guaranteed across machines**, so
no single `%VAR%` or `$env:VAR` syntax is safe to standardise on. The `args` array sidesteps the
question entirely — each entry is one literal argv token. The cost is an absolute path, which is
why `install.ps1` resolves it from `-ClaudeHome` at install time rather than hardcoding one.

🪤 **Also why the registration splices TEXT rather than round-tripping JSON:** PowerShell 5.1's
`ConvertTo-Json` escapes `'`, `<`, `>` and `&` as `\uXXXX`, which would mangle the English prose
in your `autoMode` strings on every install. So it **parses to decide** and **splices to apply**,
validating before it writes.

## Notes

- **ASCII-only.** `.ps1` files here MUST be ASCII (no curly quotes, no `→`, no `≥`). PS 5.1 reads `.ps1` as ANSI and non-ASCII corrupts the parse; heredocs become unparseable. Use `>=` and `->`.
- **Fail-open.** Every hook starts with `$ErrorActionPreference = 'Stop'` and an outer try/catch that exits 0 on any error. A broken hook must never block a prompt.
- **No interactive prompts.** Hooks run non-interactively. Guard with `[Console]::IsInputRedirected` so a hook never blocks waiting on stdin.
- **Test a hook by piping it real stdin**, not by reading it. Both retired hooks are a lesson in mechanisms nobody exercised; `objective-loop.ps1` was only trustworthy because 46 assertions drove every branch with real piped payloads.
- 🔴 **A hook must never be able to override the operator.** If you write one that can block, give it an unconditional, unmissable way out and print that way out in the blocking message itself.
