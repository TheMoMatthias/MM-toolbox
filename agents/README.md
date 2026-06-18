# Agents

Subagents are specialists with their own context window. Use them to delegate scoped work and protect the main session's context, or for adversarial perspectives (a code reviewer that hasn't seen the implementer's reasoning).

## Categories

| Category | Domain | Agents |
|---|---|---|
| [core/](core/) | Universally useful — invoke in any project | `code-reviewer`, `function-tester`, `systems-architect`, `research-engineer`, `data-quality-engineer`, `ml-engineer` |
| [backend/](backend/) | Backend platform + database design | `backend-platform-architect`, `database-architect` |
| [infra/](infra/) | Infrastructure, CI/CD, observability | `devops-infra-engineer`, `observability-engineer` |
| [security/](security/) | Security review, threat modeling, compliance | `security-auditor` |
| [frontend/](frontend/) | UI / UX / visual design | `ui-design-architect` |
| [quant/](quant/) | Quant-finance specialization (algorithmic trading, AFML methods, market microstructure) | `quant-trading-architect`, `quant-researcher`, `data-quality-scientist`, `ml-systems-architect` |

## Choosing between `core/` and a specialist

When the work is genuinely domain-specific (quant finance, frontend visual design, security threat modeling), use the specialist — its examples and idiom match the work. When the work is cross-cutting or the specialist would over-fit, use the `core/` variant.

`core/systems-architect.md` ⟷ `quant/quant-trading-architect.md`, `core/research-engineer.md` ⟷ `quant/quant-researcher.md`, `core/data-quality-engineer.md` ⟷ `quant/data-quality-scientist.md`, `core/ml-engineer.md` ⟷ `quant/ml-systems-architect.md` — same discipline, different example domains.
