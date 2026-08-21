---
name: server-health
description: Server Health Routine — a thorough, sequential, foundation-up health sweep of the live AlgoTrader server (network/reachability, host resources, Postgres+TimescaleDB, hub_daemon + data operations, data quality per provider, FastAPI backend, realtime_runner + data_daemon IPC bridge, frontend, git/deploy drift, GPU + scheduled tasks, log/process tracking, tests). Read-only by default; every issue it finds comes with a concrete fix proposal that is GATED — nothing is executed, restarted, or edited without explicit per-item go-ahead. Persists a machine-diffable snapshot + human report outside the repo. Supports `--watch N` to re-sweep every N minutes and surface only deltas. Use for a frequent, on-demand "is everything still healthy?" check.
disable-model-invocation: true
argument-hint: [optional: <section keyword(s)>] [--watch N] [--since <when>]
effort: max
---

# Server Health Routine

A disciplined, **sequential, foundation-up** audit of the live Server (`192.168.178.34` / `Kampfserver`) and everything that runs on it. It confirms — with real evidence, not assumption — that every layer of the production stack is intact: nothing is throttled, every provider is ingesting, the data is clean, the backend serves every request, the daemons are alive and tracked, and the deployed code matches `main`.

This is the infrastructure-facing sibling of `/audit` and `/audit-loop`. Where those audit *code*, this audits *a running system*.

**Posture: report-and-propose, never act unasked.** Every probe is read-only. When a check is RED or YELLOW, draft a concrete, copy-pasteable fix and **stop for explicit go-ahead before doing anything** (restart, edit, query-write, temp-clear, deploy). Nothing in this routine mutates the server, the database, the trading state, or the working tree on its own. See **Gated Remediation** below.

---

## Step 0 — Preflight, Scope, Output

### 0.1 Resolve scope and flags

- **No argument** → run **all** sections, in order.
- **Section keyword(s)** (comma-separated) → run only those, e.g. `/server-health database,backend,dataquality`. Keys: `network`, `host`, `database`, `daemon`, `dataquality`, `backend`, `realtime`, `frontend`, `deploy`, `gpu`, `logs`, `tests`. Aliases resolve loosely (case/hyphen/underscore-insensitive; `db`→database, `hub`/`ingest`→daemon, `data`→dataquality, `api`→backend, `runner`/`trading`→realtime, `ui`→frontend, `git`→deploy).
- `--watch N` → after the first full sweep, repeat every **N minutes**, surfacing only **deltas** (newly-RED/YELLOW checks, newly-cleared checks). Continue until the user halts. See **Watch Mode**.
- `--since <when>` → window for data-quality and log scans (e.g. `--since 6h`, `--since "2026-06-07 00:00"`). Default = **since the current hub_daemon start time** (so "since the daemon is running", matching the operator intent), falling back to the last sweep's timestamp, then 24h.

State the resolved scope back, e.g. `Scope: full sweep (12 sections). Window: since daemon start (2026-06-07 08:14). Output → Data\ServerHealth\runs\2026-06-07_0931\`.

### 0.2 Connection preflight (do this FIRST, alone — never batched)

Per the tool-driving discipline, a network probe that hangs poisons a parallel batch. Probe reachability **once, alone**, with a short timeout, before any server work:

```powershell
# single, isolated reachability probe
Test-Connection 192.168.178.34 -Count 2 -TimeoutSeconds 4
```

Confirm the three operating surfaces are available (these are the toolkit for every section):

| Surface | How | Use for |
|---|---|---|
| **DB** | `from db.connection import query_df` (workstation already points `DATABASE_URL` at the server) | `meta.*` heartbeat/catalog/events/jobs, `raw.*`/`features.*` freshness & quality, locks, txn state |
| **SSH** | `ssh server "<cmd>"` or `srv "<cmd>"` (key auth as `Maurice` — note capital M; SAM ≠ profile-folder `mauri`) | server-side `Get-Process`/`Get-Service`/`Get-ScheduledTask`, `Get-NetTCPConnection`, disk, uptime, one-shot scripts |
| **SMB** | `\\Kampfserver\C$\...` or mapped `S:\` (= `\\Kampfserver\C$`) — Read/Grep/Glob accept UNC paths directly | reading server log files & lock files without an SSH round-trip |
| **API** | `Invoke-RestMethod http://192.168.178.34:8000/api/v1/...` (trusted-subnet bypass on LAN/WG/Tailnet; else `Authorization: Bearer $ALGOTRADER_API_TOKEN`) | backend `/health`, router probes, `/system/logs`, `/ml/active-jobs`, `/gpu/jobs`, service status |

If the server is **unreachable**, that is itself the top finding — emit a RED `network` section (see §1) covering RDP/SSH/Tailscale/WireGuard + ephemeral-port exhaustion, propose the watchdog/reboot path, and stop. Do not fabricate downstream GREENs you could not verify.

### 0.3 Prepare the output directory (outside the repo)

Reports live in the data tree, **not** the repo (honors the no-`.md`-in-repo rule; this path is outside it):

```
C:\Users\mauri\Documents\Trading Bot\Data\ServerHealth\
  runs\<YYYY-MM-DD_HHMM>\
    snapshot.json     # canonical, machine-diffable: every check + result + evidence ref
    report.md         # human-readable RED/YELLOW/GREEN rollup (free to be .md — outside repo)
    raw\              # captured evidence: log tails, command outputs, query results
  _latest\            # snapshot.json + report.md overwritten each run (quick access + watch diff)
  history.jsonl       # one summary line per run, appended (trend over time)
```

Create the timestamped run folder at the start (`New-Item -ItemType Directory -Force`). Get the timestamp from `Get-Date -Format "yyyy-MM-dd_HHmm"`.

---

## Step 1 — Sequential Section Sweep

Run sections **in order** (foundation → up the stack); a foundational RED (e.g. DB down) explains and de-prioritizes downstream noise. For each section: run its checks, assign a section status by the **Status Rubric**, capture evidence into `raw\`, and record findings. Do **not** parallelize across sections that share a fragile probe; within a section, independent read-only probes may batch.

### §1 — Network · Reachability · Port Exhaustion (`network`)
The class that silently kills the box. Check:
- RDP/SSH/SMB reachable; Tailscale (`100.64.0.0/10`) and WireGuard (FRITZ!Box, `192.168.178.0/24`) status.
- **Ephemeral-port drain**: `ssh server "Get-NetTCPConnection -State TimeWait | Measure-Object | Select Count"` and `... -State SynSent`. Flag if TIME_WAIT is in the tens of thousands or SynSent is nonzero/growing (precursor to RDP error 0x3/0x11; System events **4231**/4266).
- RDP Connectivity Watchdog alive (`infra/scripts/watchdog-rdp-connectivity.py`; scheduled task present & Ready).
- System uptime (a recent unexpected reboot is a clue for everything else).

### §2 — Host · Resources · Hygiene (`host`)
The slow-degradation class. Check:
- **Disk free** on the DB/data volume (RED if the Postgres volume <10% free).
- **OS-temp bloat** (`$env:TEMP` entry count; the `algo_*_test_*` / `mat-debug-*` / `tmp*` accumulation that drags every tool call — flag >2-day-old bulk).
- Log-dir sizes under `Trading Bot\Logging\*` and `infra/logs` (runaway log = a stuck retry loop somewhere).
- **Postgres backup freshness**: newest dump in `infra/postgres-backups/` (RED if older than the operator's expectation; daily cadence).
- CPU/RAM headroom (32 GB box); orphaned python/node processes from dead sessions.

### §3 — Database · Postgres + TimescaleDB (`database`)
System of record — verify before anything that reads it. Check:
- Container/service up (`docker ps` via ssh, or pool opens cleanly via `db.connection`); `SELECT 1` latency sane.
- **Connection health**: pool not exhausted; **idle-in-transaction** sessions (`SELECT * FROM pg_stat_activity WHERE state='idle in transaction'` — any long one is a leak/footgun); long-running queries; blocked locks (`pg_locks` not-granted).
- TimescaleDB present; hypertables healthy; compression jobs not failing.
- **Per-table freshness & size** from `meta.catalog` (last_updated, row_count, status) cross-checked against `raw.*`/`features.*` actuals — no table silently stale or shrinking.
- Schema/guard sanity: `statement_timeout`/`lock_timeout`/`idle_in_transaction_session_timeout` set (per `db.connection`).

### §4 — Data Daemon · Hub · Data Operations (`daemon`)
The ingest engine. Check:
- `hub_daemon.py` process alive on server (`ssh server "Get-Process python | ..."`); **DaemonWatchdog** scheduled task Ready (respawns every 60s — a *missing* process that keeps respawning ≈ crash loop).
- **Heartbeat fresh**: `meta.daemon_status` written within the expected interval (a FROZEN heartbeat = daemon hung — distinct from a clean stop).
- **Cycle completion**: recent `daemon.cycle.completed` events in `meta.events` with timing metrics; fast cycle (~15s, `_refresh_ohlcv_fast_lean`) keeping OHLCV current.
- **Per-provider ingest** for **every** source (binance, blockchain, coinalyze, sentiment/GDELT, deribit, coinmetrics, etf_flow, …): recent `ingest.completed` vs `ingest.failed` in `meta.events`; cooldowns in `provider_cooldowns.json` not stuck-open; last-known-good still present on failure.
- No provider silently dark since `--since` window.

### §5 — Data Quality (`dataquality`)
Confirm the data the daemon wrote since it started is actually *good*, per provider:
- **Row completeness** since `--since`: >95% of expected bars per provider group (ta, blockchain, derivatives, sentiment, macro); no gap >3× the bar interval.
- **OHLCV integrity**: `high≥low/open/close`, `low≤open/close`, `volume≥0`, monotonic index, zero duplicate timestamps.
- **Timezone**: assert Europe/Berlin on every loaded frame (`str(df.index.tz)=='Europe/Berlin'`); no double-conversion/naive-arithmetic drift.
- **NaN/Inf**: per-column NaN rate <5% (excluding legitimate warmup); zero Inf; no all-NaN feature columns; std > 1e-6.
- **Feature freshness/width**: `features.engineered` latest row recent and width ≈ **390** (FEATURE_COUNT_TARGET; flag drift).
- Spot anomaly: any column exceeding ~20× its std (flag, do not winsorize).

### §6 — Backend · FastAPI (`backend`)
"Every request goes through; we never hit a bottleneck or throttle." Check:
- Process alive (venv-parent + system-Python310 child is *by design*, not a duplicate); `/health` 200.
- **Router reachability + latency**: probe the key routers (`/api/datahub/providers`, `/api/v1/system/...`, `/ml/active-jobs`, `/gpu/jobs`, artifacts/models) — all 200, none >5s (handler-block ceiling), none 401 (auth/token intact).
- **No throttling/bottleneck**: backend log (`Trading Bot\Logging\terminal\` on server — NOT `infra/logs`) free of recent tracebacks, pool-exhaustion, `idle in transaction`, rate-limit, or starvation/angel-restart signatures.
- **Job lifecycle**: `meta.jobs` — no job stuck `running` past its ETA; no orphaned jobs from dead sessions.
- Pool not leaked across requests; no handler holding a txn open.

### §7 — Realtime Runner · Data Daemon IPC Bridge (`realtime`)
Only fully applies when trading is live; otherwise verify the bridge is *ready & consistent*. Check:
- **Trading state** first (live vs paper vs idle) — determines how loud a RED here is, and gates any proposed action hard (never restart a runner with an open position).
- `data_daemon` writing `features_latest.parquet` + `data_manifest.json` (atomic rename; parquet-first); manifest fresh (<15 min) and `schema_version` ∈ `MANIFEST_KNOWN_VERSIONS`.
- `realtime_runner` alive (if expected); model input shape == feature count (load-time assert); no schema-mismatch halt / Telegram alert pending.
- Latency budget sane (manifest+parquet read, SIDE/META inference, order path) — no hot-path Postgres round-trips crept in.

### §8 — Frontend (`frontend`)
Light by design (API-contract dependent). Check:
- Built bundle present & fresh on each client host; served without error.
- Client→backend contract intact: `VITE_API_TOKEN` present, `Authorization` header path working, providers/artifacts endpoints the UI depends on return 200.
- No obvious build/console-breaking drift since last deploy (vitest/tsc green if run locally).

### §9 — Git / Deploy Drift (`deploy`)
"Is the live code the code we think it is?" Check:
- Server checked-out commit == `origin/main` HEAD (`ssh server "git -C <repo> rev-parse HEAD"` vs `git ls-remote`).
- No uncommitted drift in the server working tree (`git status --porcelain` server-side).
- Running processes loaded *after* the latest deploy (daemon/backend restarted post-pull) — stale process running old code is a classic silent failure.

### §10 — GPU · Training · Scheduled Tasks (`gpu`)
Check:
- `gpu_worker` liveness & queue (durable `.gpu_compare_results`; `/gpu/jobs` 200, none stuck).
- Scheduled tasks Ready, not Disabled/Failed: `AlgoTrader\DaemonWatchdog`, RDP-connectivity watchdog, any backup task.
- No orphaned/zombie background jobs (ml_compare, feature_select, backtests) from dead sessions holding the GPU or a worker slot.

### §11 — Logs & Process Tracking Cross-Check (`logs`)
"Are we still correctly tracking every process via its log file?" Check:
- Each expected log dir under `Trading Bot\Logging\*` (hub_daemon, data_daemon, data_loader, terminal, live_trader, ml_compare, …) and `infra/logs\hub_daemon.{out,err}.log` is **being written** (recent mtime) — a silent log = a dead or detached process.
- Scan the `--since` window across logs for ERROR/CRITICAL/Traceback/`[Module][function]`-tagged failures; tally by source.
- **Lock files** sane: no stale `.lock` held by a dead PID (e.g. `.claude/scheduled_tasks.lock`, daemon/worker locks) — stale lock blocks the next legitimate start.

### §12 — Tests (corroboration) (`tests`)
Run the cheap, high-signal health tests as an independent cross-check (workstation, read-only against server DB where applicable):
- `tests/test_dataloader_postgres_purity.py` (Cardinal-rule writer guard), connection/pool tests, provider smoke/schema tests, any `test_temp_leak_guard`.
- Report pass/fail; a failing invariant test is a RED even if every live probe looked GREEN.

---

## Step 2 — Synthesize · Findings · Gated Remediation

### 2.1 Section + overall status (Status Rubric)
Assign each section, then the overall run:
- **GREEN** — every check passed; observed within expected bounds.
- **YELLOW** — degraded-but-serving: a soft threshold crossed (e.g. one provider stale, temp bloat, backup a day late, one slow router) — no correctness/trading risk yet.
- **RED** — broken or correctness/trading-threatening: daemon hung, frozen heartbeat, DB unreachable, look-ahead/leakage in live data, schema mismatch, port exhaustion, provider dark, deployed code ≠ main with a behavioral delta.

Overall = worst section status (with the foundational-RED note so downstream reds aren't double-counted).

### 2.2 Findings
For each YELLOW/RED check, record a normalized finding:
```
section:    <name>
severity:   Critical | High | Medium | Low      # Critical≈RED-correctness, High≈RED-availability, Medium/Low≈YELLOW
check:      <which probe>
observed:   <actual value / evidence ref in raw\>
expected:   <threshold / invariant>
impact:     <what breaks / what risk if unfixed>
proposed_fix: <concrete, copy-pasteable command / edit / query — NOT executed>
tier:       safe | caution | critical          # per CLAUDE.md Change Risk Classification
auto_ok:    true|false                          # true ONLY for trivially-reversible, non-trading, non-schema ops
```

### 2.3 Gated Remediation — the hard line
This routine **never acts unasked.** After presenting findings:

1. Group proposed fixes by tier (`safe` → `caution` → `critical`).
2. **Surface them and STOP.** Ask the user which to apply, per item. Present the exact command/edit and its blast radius + rollback.
3. Apply only the explicitly-approved items, one at a time, verifying each before the next.
4. **Critical-tier is double-gated** — for anything on the CLAUDE.md Critical list (Postgres schema, transforms, IPC format, model weights, signal logic, order construction, `db/connection.py`, `infra/postgres.conf|pg_hba.conf|docker-compose.yml`, restarting services while trading is live) follow the **Safe Deployment Procedure** (halt → flatten → backup → deploy → verify → resume) and re-confirm before each phase.
5. **Never** restart `realtime_runner`/`data_daemon`/`hub_daemon`, pull+restart, clear data, or write to the DB without that go-ahead — even if `auto_ok:true`. `auto_ok` only *pre-qualifies* an item as low-risk for the approval prompt; it is not a license to act.

If trading is live, default to *propose-and-wait* for **everything**, including YELLOW housekeeping.

---

## Step 3 — Persist Outputs

Write, into the run folder created in §0.3:

1. **`snapshot.json`** — the canonical record:
   ```json
   {
     "run_id": "2026-06-07_0931",
     "started_at": "...", "finished_at": "...",
     "scope": ["network","host", "..."],
     "window_since": "...",
     "trading_state": "idle|paper|live",
     "overall_status": "GREEN|YELLOW|RED",
     "sections": [
       {"name":"database","status":"GREEN","checks":[{"id":"...","label":"...","status":"...","observed":"...","expected":"...","evidence":"raw/db_catalog.txt"}],"findings":[...]}
     ],
     "deltas_vs_previous": {"new_red":[...],"new_yellow":[...],"cleared":[...]}
   }
   ```
2. **`report.md`** — human rollup: a status table (section · status · one-line headline), then per-section detail for anything not GREEN, then a **"Proposed fixes (awaiting go-ahead)"** block. (Free to be Markdown — this path is outside the repo.)
3. **`raw\`** — the evidence captures referenced by `evidence` fields (log tails, query outputs, command results) so a finding is always traceable.
4. Overwrite **`_latest\snapshot.json`** + **`_latest\report.md`**.
5. Append one line to **`history.jsonl`**: `{"run_id","finished_at","overall_status","red":N,"yellow":N,"section_status":{...}}`.

Then print the rollup table inline and the path to the run folder. Keep the inline message tight; the detail lives in the files.

---

## Watch Mode (`--watch N`)

1. Run a full sweep (Steps 1-3) as the baseline; persist it.
2. Sleep N minutes, re-sweep, **diff `snapshot.json` against `_latest`**.
3. Inline, surface **only deltas**: newly-RED/YELLOW checks (loud), and newly-cleared ones (quiet confirmation). A fully-unchanged sweep prints a single GREEN heartbeat line + the run path.
4. Still persist every run (timestamped folder + history line) so the trend is complete.
5. Continue until the user halts. **Remediation stays gated every cycle** — watch mode never escalates to auto-fix.

To pace the wait, prefer the harness's scheduling for long intervals rather than a blocking sleep; surface a one-line status each cycle.

---

## Hard Rules

- **Read-only by default; every fix is gated.** No restart, edit, deploy, DB-write, temp-clear, or lock-removal without explicit per-item approval. `auto_ok` pre-qualifies, it never authorizes.
- **Never act on a live trading system** beyond observation without the full Safe Deployment Procedure and re-confirmation. Check trading state before proposing anything in §7.
- **No `.md`/summary files in the repo.** Reports go only to `Data\ServerHealth\` (outside the repo). The sole in-repo `.md` exception remains `CONTEXT.md`.
- **No git commits/pushes/branch ops.** Stay on `main`; this routine never touches the working tree or VCS.
- **Probe networks alone.** Any reachability/server-network probe runs in its own turn with a short timeout — never batched with other calls (parallel-batch-cascade hazard).
- **Prefer Read/Grep/Glob over scratch probe-scripts** for inspecting server files over SMB; they don't cascade-cancel and are faster.
- **Route all DB access through `db.connection`.** Never raw `psycopg.connect()`. Reads only here — no writes without approval.
- **Verify, don't assume.** If a layer could not be reached, mark its checks `unverified` and say so explicitly — never emit a GREEN you didn't evidence. "Silence = confidence."
- **Evidence everything.** Every non-GREEN finding cites a capture in `raw\` so the user can independently confirm.
