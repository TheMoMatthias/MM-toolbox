# spawn-session local status

Registered adapters: `pi` (preassigned durable ID plus verified prompt correlation) and
`claude` (existing verified adapter). The registry is local and intentionally has no speculative
PATH probing. Every Pi launch writes `~/.pi/agent/spawned-sessions/<id>.json` before terminal
startup so its exact resume identity survives launcher output loss or a closed terminal.

## Add an unverified runtime

Add a fully declared entry to `runtimes.local.json`; the generic adapter will otherwise refuse it.
Only `verificationLevel: "unverified"` permits a generic launch.

```json
"example-cli": {
  "displayName": "Example CLI",
  "executable": "example",
  "interactiveLaunchArgs": ["start", "--name", "{name}"],
  "modelDiscoveryArgs": ["models", "--list"],
  "modelArgs": ["--model", "{model}"],
  "defaultModelChoice": "runtime-default",
  "resumeGuidance": "Run example resume from the target directory.",
  "verificationLevel": "unverified"
}
```

Use `null` for unavailable optional model discovery/arguments. Verify the executable and every
flag manually before registering it. Generic reports are intentionally unverified; do not infer
persistence, a session ID, remote control, or resume capability from a terminal launch.

## Pi recovery and limitation

Pi's `pi -r` and `/resume` picker is scoped to the current project directory. A valid session
spawned into another repository is therefore absent when recovery is attempted from the parent
session's directory. Use `recover.ps1 -Name <name>` or `recover.ps1 -SessionId <id>`; it searches
all durable Pi project buckets, reports the original cwd and exact JSONL path, refuses ambiguous
names, and relaunches with `pi --session <id>` in that cwd.

The duplicate guard reliably sees adapter-owned live sessions by marker and checks visible named
`node.exe` commands. A Pi session started outside this adapter can hide its cwd from process
inspection, so a differently named external session is not detectable. Use a separate worktree
and lane name for implementation work.
