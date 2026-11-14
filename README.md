# magpie-routing-config

**English** | [中文](README.zh.md)

**Open-source routing-strategy blueprints for [magpie](https://usemagpie.ai)** — distills "how to design magpie routing" into docs + templates + an agent workflow. Contains no real keys or machine-specific config.

> Independent community project; not affiliated with or endorsed by the official [magpie](https://github.com/yetone/magpie) team.

## Who it's for

People who already run [magpie](https://usemagpie.ai) (a macOS menu-bar AI routing gateway; [GitHub](https://github.com/yetone/magpie)) with model providers configured, and want better routing. You don't need to study the config format — hand this repo to your agent.

## 30-second quickstart

```bash
git clone https://github.com/evenchan86/magpie-routing-config.git && cd magpie-routing-config
```

Then tell your agent (Claude Code / Codex / …):

> Read this repo's AGENTS.md and configure my local magpie routing following the workflow.

The agent will: probe your local config schema → discover your providers and models → propose a role→model mapping (**you confirm**) → render a routing-layer draft → validate → back up and merge-write (**you confirm**).

Your providers and keys **stay untouched**; this repo only touches the routing layer (groups/rules/classifier).

## Core concept: model roles

Strategies aren't bound to specific models. Five capability roles are mapped to your own models:

| Role | Purpose |
|---|---|
| `reasoning/strong` | Architecture, hard debugging, large changes |
| `code/general` | Implementation, bug fixes, tests, review |
| `design/ui` | UI, styling, visual reproduction (incl. screenshots) |
| `fast/cheap` | Simple Q&A, intent classifier, fallback |
| `context/long` | Long-context summarization |

Seven mutually exclusive intents (test / Q&A / implement / refactor / architecture / UI / review) + reasoning trigger + fallback + summarization group cover the coding loop. See the [routing pattern library](docs/patterns.md).

## Repository layout

```text
AGENTS.md                  # agent workflow & red lines (entry point)
docs/
  concepts.md              # routing concepts
  schema.md                # config field reference (with confidence notes)
  patterns.md              # routing pattern library
templates/
  roles.json               # role definitions & mapping
  groups.template.json     # routing-layer template (role placeholders)
examples/demo/             # end-to-end example with a fictional provider
scripts/
  validate.py              # routing-layer draft validator
  e2e.sh                   # isolated acceptance test
```

## Example

[examples/demo/](examples/demo/README.md) walks from local config to a routing-layer artifact using a fictional provider `acme/*`.

## Honesty note

The schema docs are based on single-machine observation of magpie v0.1.4130 and are **not an official specification**; the agent workflow defers to probing your actual local config. Fields with uncertain semantics are flagged individually in [schema.md](docs/schema.md).

## License

[MIT](LICENSE)
