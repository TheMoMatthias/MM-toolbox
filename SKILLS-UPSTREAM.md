# Skills provenance

Most skills in this repo originate from **[mattpocock/skills](https://github.com/mattpocock/skills)**
and have since been adapted. Nothing recorded that until 2026-08-17, so the first
sync had to be reconstructed by diffing every skill against a fresh clone. This file
exists so the next one is a diff against a known baseline instead of an investigation.

| | |
|---|---|
| Upstream | `https://github.com/mattpocock/skills` |
| Last synced | **2026-08-17** |
| Upstream commit | `9c9f36c` (release **1.2.3**) |

**Update this file in the same commit as any sync.** A manifest that lags is worse
than no manifest — it reads as verified.

---

## How to run the next sync

```bash
git clone --depth 50 https://github.com/mattpocock/skills.git /tmp/upstream-skills
```

Then, per skill, compare against the table below. Two things will bite you:

- 🪤 **Normalise line endings.** This repo checks out CRLF, upstream is LF, so a
  naive `diff` reports **every** file as changed and the real edits vanish in the
  noise. Use `diff --strip-trailing-cr`.
- 🪤 **Both trees are categorised, and the categories differ.** Upstream uses
  `skills/{engineering,productivity,misc,in-progress,deprecated}/`; this repo uses
  `skills/{architecture,development,diagnosis,orchestration,workflow,writing,misc}/`.
  Match on the skill's directory *name*, not its path.

---

## Classification

### Tracks upstream by name (17)

`codebase-design` · `code-review` · `diagnosing-bugs` · `domain-modeling` ·
`grill-me` · `grill-with-docs` · `grilling` · `handoff` · `implement` ·
`improve-codebase-architecture` · `prototype` · `research` ·
`resolving-merge-conflicts` · `tdd` · `teach` · `triage` · `wayfinder`

### Renamed from upstream (3)

| here | upstream | why |
|---|---|---|
| `to-prd` | `to-spec` | this repo says PRD, not spec |
| `to-issues` | `to-tickets` | this repo says issues, not tickets |
| `setup-engineering-skills` | `setup-matt-pocock-skills` | vendor-neutral name |

### Adopted from upstream on 2026-08-17 (15)

`ask-matt` · `wizard` · `claude-handoff` · `loop-me` · `setup-ts-deep-modules` ·
`writing-beats` · `writing-fragments` · `writing-shape` ·
`git-guardrails-claude-code` · `migrate-to-shoehorn` · `scaffold-exercises` ·
`setup-pre-commit` · `to-questionnaire` · `wait-what` · `writing-for-agents`

⚠️ Six of these come from upstream's **`in-progress/`** bucket and are not stabilised
there: `claude-handoff`, `loop-me`, `setup-ts-deep-modules`, `writing-beats`,
`writing-fragments`, `writing-shape`. Expect them to change shape upstream.

⚠️ `ask-matt` is a router *over upstream's own skill set* and still describes that
set, not this one. It needs adapting before it is useful here.
⚠️ `migrate-to-shoehorn` and `scaffold-exercises` are specific to upstream's
TypeScript-course tooling and are unlikely to apply to this repo's work.

### Local — no upstream counterpart (12)

`agent-cluster` · `audit` · `audit-loop` · `audit-loop-codebase` · `diagnose` ·
`reevaluate` · `spawn-claude-session` · `wrap-up` · `write-a-skill` ·
`writing-great-skills` · `automate-orchestrator` · `automate-realign`

⚠️ `automate-realign` is a deliberate FORK of `workflow/realign`, which does track
upstream. **A sync of `realign` must not be applied to it** — they diverge on purpose at
step 4 (route the decision to an orchestrator, do not ask the user) and step 6 (emit a
structured block, and never end by stopping). `automate-realign` additionally adds a
mandatory conversation sweep that `realign` has no equivalent of.

---

## 🔒 Deliberate divergences — a sync must NOT undo these

1. **`/setup-matt-pocock-skills` → `/setup-engineering-skills`** in every
   cross-reference (`triage`, `code-review`, `wayfinder`, …).
2. **spec → PRD** and **tickets → issues** terminology throughout.
3. **Claude-specific subagent wording is kept** in `code-review`,
   `codebase-design` and `improve-codebase-architecture`. Upstream PR
   [#781](https://github.com/mattpocock/skills/pull/781) deliberately *removed*
   Claude Code's tool and agent-type names so the steps are followable on Codex.
   This repo keeps them because Claude Code is the primary harness and the named
   form is more actionable there. **This is a live trade-off, not an oversight** —
   flip it if Codex becomes a real target.
4. **Substantially rewritten locally, far beyond upstream**: `grill-me` (+74 lines),
   `grill-with-docs` (+48), `implement` (+38), `prototype`, `wayfinder`,
   `improve-codebase-architecture`, `handoff`. Do not overwrite these.
5. **`grill-with-docs` drops `disable-model-invocation`** on purpose — the global
   convention requires the model to be able to invoke it.
6. **`diagnosing-bugs` adds "Phase 6 — Cleanup + post-mortem"**, which upstream
   does not have.

---

## Taken from upstream on 2026-08-17

- **`diagnosing-bugs` — the `Redact` section** (upstream 1.2.3). The skill has the
  agent show commands, outputs and captured artifacts; this makes redaction the
  first move on each. Taken as a **safety fix**, not a nicety.
- **`grilling` — the design-tree rewrite**, wholesale. Upstream replaced
  one-question-at-a-time with a *frontier* model: ask every question whose
  prerequisites are settled in one numbered round, then recompute. This converges
  with the global convention's batched `AskUserQuestion` rounds, which previously
  had to override the skill.
- **`domain-modeling/CONTEXT-FORMAT.md`** — a whole file this repo was missing
  while `domain-modeling/SKILL.md:62` linked to it. The link was broken.
- **`agents/openai.yaml` for all 45 skills** (upstream 1.2.0). Codex/OpenAI
  metadata: `interface.display_name`, `interface.short_description`, and
  `policy.allow_implicit_invocation: false` on user-invoked skills — the Codex
  analog of `disable-model-invocation: true`. Copied for skills that track
  upstream; hand-written for the 10 local ones. This closes the
  "Multi-LLM portability" item the README listed as deferred.
- **The 15 new skills** listed above.

## Not taken, and why

Everything else that differs is this repo being **ahead of** or **deliberately
apart from** upstream — see the divergences above. There is no known upstream
improvement outstanding as of `9c9f36c`.
