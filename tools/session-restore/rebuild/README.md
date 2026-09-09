# rebuild/ — the specification, extracted

The tool is being rebuilt in C# / .NET 8. This folder is **Phase 0 of
`00-PLAN.md`: freeze the spec before touching code.**

It exists because the central risk in a rewrite is not writing the new code. It
is losing a fact that took days to establish and re-deriving it wrongly — and
this repo has over a thousand such facts, written down beside the code they
constrain, where nobody is going to re-read them one at a time in a new
language.

## Read in this order

| file | what it is | size |
|---|---|---|
| **`00-PLAN.md`** | the ordered work plan, every item with a done-when | written |
| **`05-ARCHITECTURE.md`** | the target design and the reasoning per decision | written |
| `01-CAPABILITIES.md` | every control, what it says it does, what it calls | generated |
| `02-KNOWLEDGE.md` | 741 marked facts, verbatim, with file and line | generated |
| `03-CONTRACTS.md` | the native surface, the CLIs, the files, the 25 settings | generated |
| `04-BEHAVIOUR.md` | 2.269 test assertions as a parity checklist | generated |

`00-PLAN.md` and `05-ARCHITECTURE.md` are **decisions** and are edited by hand.
The other four are **extracted** and must not be — edit the extractor instead.

## Regenerating

```
python rebuild/tools/extract_knowledge.py     # -> 02-KNOWLEDGE.md
python rebuild/tools/extract_surface.py       # -> 01-CAPABILITIES.md
python rebuild/tools/extract_contracts.py     # -> 03-CONTRACTS.md
python rebuild/tools/extract_behaviour.py     # -> 04-BEHAVIOUR.md
```

🪝 **Re-run them before each phase and diff.** The PowerShell keeps moving while
the rebuild happens; a snapshot taken once is a spec that quietly goes stale, and
this whole folder exists to stop exactly that class of error.

Each extractor also writes a `.json` sidecar next to its Markdown, so a later
tool can consume the same data without re-parsing the prose. **The sidecars are
gitignored** - they duplicate the Markdown byte for byte in a different shape,
and `knowledge.json` alone is 700 KB. Run an extractor to get them back.

## What was found while extracting

Worth recording, because each of these was invisible until something read the
source mechanically rather than from memory:

- **101 of the 164 named XAML elements have no handler.** Most are labels and
  containers. Some may be dead. Each is checked at plan item 4.2 rather than
  ported on faith.
- **Eight console imports are declared twice** — `SRCon` and `SRConLite` both
  need them, because a PowerShell script cannot easily share a compiled type
  between two scopes. In C# that reason disappears.
- **There are 25 settings, not 23.** The count was quoted from a test's output
  earlier in the day; reading `$SR_CfgMeta` with balanced braces gives 25.
- The first version of the settings extractor **invented three settings** —
  `C`, `D` and `Z` — by reading past the end of the table into the Ctrl-chord
  map with a fixed character window. A spec that invents a setting is worse than
  one that misses it, because somebody would build it. It is bounded by braces
  now, and the note is kept in the extractor.
