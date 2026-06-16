# archbuddy-ruby-client

The **Ruby client** for the [architecture-auditor](https://github.com/Kosmin/architecture-auditor)
engine. It captures a language-agnostic execution/call **graph** from a Ruby codebase, hands the
engine an *opaque* graph to analyze, and reconnects the engine's findings back to real code
locally — producing a ranked **architecture clutter report**.

## What archbuddy is

`archbuddy` is **one half of a two-repo system**:

- **archbuddy-ruby-client (this repo)** owns *capture* and *reconnect*.
- **[architecture-auditor](https://github.com/Kosmin/architecture-auditor) (the engine)** owns the
  shared **Contract** (ids/serializer/validator/schemas) and the *analysis* (graph → findings).

It owns two CLI concerns:

- **Collector** (`collect`): a static-AST adapter (via `prism`) that walks a Ruby codebase into
  method-level nodes + directed call/db/endpoint/external edges, then **anonymizes** them — emitting:
  - `graph.yml` — shareable, **opaque** node-ids, zero app semantics (safe to hand to the engine).
  - `id-map.yml` — **SECRET**, local-only, gitignored: maps each opaque id → `file:line:symbol`.
- **Reconnect + Report** (`report`): joins the engine's `findings.yml` back against the secret
  `id-map.yml` to produce a **ranked clutter report** scored against real code symbols.

The pluggable `Adapter` interface means a future React/Node.js client is a new adapter, not a rewrite.

## Data flow

```
your repo ──> archbuddy collect ──> graph.yml + id-map.yml(SECRET)
graph.yml ──> architecture-auditor analyze ──> findings.yml
findings.yml + id-map.yml ──> archbuddy report ──> ranked clutter report
```

`id-map.yml` **never leaves this machine** and is the only thing that can de-anonymize the graph.

## Requirements

- Ruby **>= 3.2** (see `.ruby-version`). On this machine all commands are prefixed with an rbenv
  selector — substitute the rbenv-resolvable name you have installed, e.g. `RBENV_VERSION=ruby-3.4.2`.
- [Bundler](https://bundler.io/).
- The **`architecture_auditor` engine gem** (the shared contract + the `analyze` CLI). See below.

## Install

```bash
git clone https://github.com/Kosmin/archbuddy-ruby-client.git
cd archbuddy-ruby-client
RBENV_VERSION=ruby-3.4.2 bundle install
```

### Installing the engine dependency

`archbuddy` depends on the `architecture_auditor` gem for the shared Contract. The `Gemfile` is wired
so a **fresh clone installs cleanly** *and* local dev keeps its ergonomics:

- **Default (fresh clone / distribution):** the engine resolves from its **git source**
  (`https://github.com/Kosmin/architecture-auditor.git`, branch `main`). No sibling checkout needed.
- **Local dev — two ways to point at a sibling checkout (`../architecture-auditor`):**

  1. **Env override (zero config), one-off:**
     ```bash
     ARCHITECTURE_AUDITOR_PATH=../architecture-auditor RBENV_VERSION=ruby-3.4.2 bundle install
     ```
     An unset/blank value falls through to the git source.

  2. **Bundler local override (persistent, no env needed)** — preferred for a permanent sibling:
     ```bash
     bundle config set --local local.architecture_auditor ../architecture-auditor
     RBENV_VERSION=ruby-3.4.2 bundle install
     ```
     Bundler resolves the git gem from that local path automatically (it must be on the same branch).

  Either mode lets a sibling checkout "just work" without editing the `Gemfile`.

## Quickstart — the full pipeline

The three stages, with real commands. (The middle stage runs the **engine**, not this repo.)

### 1. Collect — capture + anonymize your codebase

```bash
RBENV_VERSION=ruby-3.4.2 bundle exec archbuddy collect PATH --out-dir ./out
# → ./out/graph.yml      (opaque, shareable)
# → ./out/id-map.yml     (SECRET — gitignored, never share/commit)
```

For a **non-Rails gem or library** (no controllers), the default entrypoint strategy may find no
entrypoints; `collect` warns on stderr and suggests:

```bash
RBENV_VERSION=ruby-3.4.2 bundle exec archbuddy collect PATH --out-dir ./out --entrypoints all_public
```

`--entrypoints` accepts `default | controllers | all_public | none` (M3).

### 2. Analyze — run the engine on the opaque graph

```bash
# in / via the architecture-auditor engine repo:
architecture-auditor analyze ./out/graph.yml --out ./out/findings.yml
# → ./out/findings.yml   (opaque; safe to share — keyed by opaque ids only)
```

The engine **never** receives `id-map.yml` — it analyzes the graph without ever seeing real symbols.

### 3. Report — reconnect findings to real symbols, ranked

```bash
RBENV_VERSION=ruby-3.4.2 bundle exec archbuddy report ./out/findings.yml --id-map ./out/id-map.yml
# add --format yaml|json|dot, --top N, or --graph ./out/graph.yml (required for dot)
```

The report carries **real symbols** → treat it as SECRET/local-only (see below).

### Sample output (Architecture Scores summary + ranked bottlenecks)

```
archbuddy report — clutter ranking

Architecture Scores
------------------------------------------------------------
  Reverse Traceability    58/100  (D)    — can you tell where code is used?
  Forward Discoverability 72/100  (C)    — can you follow where execution goes?

  Reverse Traceability
    top contributors to this dimension (worst-ranked first):
      1. Billing#charge (app/services/billing.rb:8)  [fan_in=42, centrality=0.9000, in_cycle=0]
      2. User#save (app/models/user.rb:12)  [fan_in=2, centrality=0.4000, in_cycle=0]

#1  OrdersController#create  [clutter 9.5000]
    kind: endpoint    app/controllers/orders_controller.rb:5
    metrics:
      path_length  0
      fan_in       0
      fan_out      3
      ...
```

## Reading the report: the two dimensions

The engine scores two **project-level** dimensions (eslint/rubocop-style — the **grade is the
headline**, not any single hotspot):

- **Reverse Traceability** — *"can you tell where code is used?"* Always computable. Driven by
  `fan_in` / `centrality` / `in_cycle` — heavily-depended-on, central, or cyclic nodes are hard to
  trace backward and risky to change.
- **Forward Discoverability** — *"can you follow where execution goes?"* Driven by `path_length` /
  `fan_out`. This is **N/A** when collection found **no entrypoints** (re-collect with
  `--entrypoints all_public`); it renders honestly as `N/A` with that reason, never a fake number.

A **hotspot** is just the worst-*ranked* node for that dimension (a relative top contributor) — on a
clean project the top hotspots may be perfectly benign. Scores are copied **verbatim** from the
engine; archbuddy never recomputes them.

## SECRET: the id-map and de-anonymized reports

`id-map.yml` is the **only** thing that can de-anonymize the opaque graph, and every de-anonymized
report (`terminal` text, `report.yml`, `report.json`, `*.dot`) carries **real file/line/symbol** names.

- **Never commit** the id-map or any report. The repo `.gitignore` already covers `id-map.yml`,
  `*.id-map.yml`, `/out/`, `report.yml/json`, `*.dot`, `graph.yml`, `findings.yml`.
- **Never share them externally.** They stay **local, on this machine**. `collect` even refuses to
  write the id-map unless its path is gitignored (gitignore-before-secret guard).

## CLI reference

```
archbuddy collect PATH --out-dir ./out \
  [--language ruby] [--entrypoints default|controllers|all_public|none] [--entrypoint-pattern REGEX ...]

archbuddy report FINDINGS_YML --id-map ./out/id-map.yml \
  [--format terminal|yaml|json|dot] [--graph ./out/graph.yml] [--top N]
```

## Development

```bash
RBENV_VERSION=ruby-3.4.2 bundle exec rspec     # full suite (65 examples)
RBENV_VERSION=ruby-3.4.2 gem build archbuddy.gemspec   # installability check (delete the .gem after)
```

See [`AGENTS.md`](AGENTS.md) for the docs pyramid, [`ARCHITECTURE.md`](ARCHITECTURE.md) for the
as-built code map, [`CONTRACT.md`](CONTRACT.md) for the data contracts, and
[`.claude/docs/cross-repo.md`](.claude/docs/cross-repo.md) for the client ↔ engine relationship.
</content>
</invoke>
