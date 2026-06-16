# AGENTS.md — archbuddy-ruby-client

> Project-level instructions for AI agents. `CLAUDE.md` is a symlink to this file.

Self-referential documentation entry point. **Read this and the docs it links before reading source.**
Reading docs first is faster than reading code and keeps context usage low.

## What this project is

A Ruby gem — `archbuddy` (module `Archbuddy`, binary `archbuddy`) — that is the **Ruby client** of an
otherwise language-agnostic architecture-clutter auditor. It owns two concerns:

1. **Collector** (`lib/archbuddy/collect/`, CLI `collect`) — statically walks a Ruby codebase (via `prism`)
   into method-level nodes + directed edges, then **anonymizes** them through a single trust boundary,
   emitting `graph.yml` (shareable, opaque) + `id-map.yml` (**SECRET, local, gitignored**).
2. **Reconnect/Reporter** (`lib/archbuddy/report/`, CLI `report`) — joins the engine's `findings.yml` back
   against the secret `id-map.yml` to produce a ranked clutter report scored against real code symbols.

This is **one half of a two-repo system**. The other repo is the **core engine** `architecture_auditor`
(sibling at `../architecture-auditor`), which this client **depends on** for the shared Contract
(`ArchitectureAuditor::Contract`: `Ids` / `Serializer` / `Validator` / JSON schemas). The engine
*analyzes* the graph; this client *captures* it and *reconnects* findings. See
[`.claude/docs/cross-repo.md`](.claude/docs/cross-repo.md).

### End-to-end data flow

```
your repo ──> archbuddy collect ──> graph.yml + id-map.yml(SECRET)
graph.yml ──> architecture_auditor analyze (the OTHER repo) ──> findings.yml
findings.yml + id-map.yml ──> archbuddy report ──> ranked clutter report
```

`id-map.yml` **never leaves this machine** and is the only thing that can de-anonymize the graph.

## Tech stack

| Concern | Choice |
|---------|--------|
| Language / runtime | Ruby **>= 3.2**; on this machine use `RBENV_VERSION=ruby-3.4.2` for all ruby/bundle/rspec |
| AST parser | `prism` (~> 1.0) — two-pass `Prism::Visitor` capture |
| CLI framework | `dry-cli` (~> 1.4) — `Dry::CLI::Registry`, two commands: `collect`, `report` |
| Shared contract | `architecture_auditor` gem — Gemfile defaults to the **git source** (distribution, D47); local dev overrides to the `../architecture-auditor` sibling via `ARCHITECTURE_AUDITOR_PATH` or `bundle config local.architecture_auditor` (M2). See [`.claude/docs/cross-repo.md`](.claude/docs/cross-repo.md) |
| Tests | `rspec` (~> 3.13) |
| Serialization | Always via the contract's `Serializer` (deterministic YAML, D30) — never raw `YAML.dump`/`Psych` |

## Critical invariants (do NOT violate — agents have broken these before)

1. **The Anonymizer is the single trust boundary.** `graph.yml` carries **ZERO app semantics**: only
   opaque ids (`n_`/`ext_`), opaque `cls_` refs as `class_id`, contract `kind`s, and null/numeric weights.
   Real file/line/symbol live **ONLY** in `id-map.yml`. **NEVER** write real paths/symbols (including a
   node's `loc`) into `graph.yml` — this was a real bug, caught and fixed. The spec
   `spec/collect/collector_spec.rb` asserts the serialized graph contains no real paths/symbols, and every
   node's `loc` is `nil`.
2. **`cls_` ids appear ONLY in `id-map.yml` (D42)** — referenced by nodes via `class_id`, but never added
   as their own `graph.nodes[]` entry.
3. **Secret handling (D16/D21).** `id-map.yml` and every de-anonymized export (`report.yml`/`.json`/`.dot`)
   contain real symbols → **SECRET, local-only, gitignored.** Never commit, never send externally. Only
   `collect` and `report` read/produce the id-map; the engine's `analyze` never receives it (no `--id-map`
   option exists there by construction).
4. **Ids are minted ONLY via `ArchitectureAuditor::Contract::Ids` (D25/D41).** Never reimplement hashing.
   All ids match `^(n_|ext_|cls_)[0-9a-f]{12}([0-9a-f]{4})?$`.
5. **Reporter is verbatim-only (D17).** The reporter copies `metrics` + `clutter_score` **verbatim** from
   `findings.yml` — it **NEVER** recomputes them. (Class rollups *sum* member scores as a presentation
   aggregate only; that is not recomputing a node metric.)
6. **Metric kernel lockstep (D43/D39).** `Archbuddy::Report::METRIC_KEYS_FOR_DISPLAY` (a named constant) is
   asserted by `spec/report/metric_kernel_consistency_spec.rb` to equal the engine's
   `ArchitectureAuditor::Analyze::METRIC_KEYS` (exactly 8 keys, same order). Keep them in lockstep.
7. **The resolver never fabricates edges (D24).** Operators dropped, metaprogramming flagged-no-edge,
   AR vocab → `db_op` via **class context** (incl. the implicit-self `where`-in-`def self.x` gotcha),
   Controller convention → `endpoint`, everything unresolved → a **single shared `external` sink**.
8. **Empty-entrypoints warning (M3).** The default entrypoint strategy can find none in a non-Rails gem;
   `collect` then **WARNS on stderr** (never in graph content) and suggests `--entrypoints all_public`.
   It does NOT auto-switch strategies.
9. **Project scores are verbatim + locally de-anonymized (findings 1.1, R-8).** The OPTIONAL `scores` block
   (`reverse_traceability` + `forward_discoverability`) carries **project-level** `score`/`grade` — copied
   **verbatim** (D17, never recomputed: they come straight from findings.yml) — plus **OPAQUE** `hotspots`
   the reporter de-anonymizes via the SAME secret id-map as everything else (graceful `<external>` for
   missing ids). A 1.0 findings doc has **no** scores block → the report renders exactly as before (additive
   / back-compat, never crash). Scores are **separate** from the 8 per-node metrics — they do NOT touch
   `METRIC_KEYS_FOR_DISPLAY` or the 4c lockstep. A hotspot is just the worst-RANKED node for that dimension
   (a relative top contributor), NOT inherently a bug — render so the **grade leads**, not the hotspot.

## How to work in this codebase

Read the self-referential docs in this order before opening source:

1. This file (`AGENTS.md` / `CLAUDE.md`) — stack, invariants, vocabulary, task workflow
2. [`ARCHITECTURE.md`](ARCHITECTURE.md) — the two concerns, trust boundary, module/file map (find any
   responsibility by name without opening files), data flow, dependency on the engine Contract
3. [`CONTRACT.md`](CONTRACT.md) — the **contract/schema** doc: what the collector EMITS
   (`graph.yml` + `id-map.yml` shapes) and what `report` CONSUMES (`findings.yml` shape), by reference to
   the engine's canonical contract. (This repo has **no database**; CONTRACT.md documents the data
   contracts instead.)
4. `.claude/docs/<topic>.md` — deeper topics (resolver tier table, adapter-extension how-to, cross-repo)

**Only open source files when** the docs don't answer the question, you need an exact implementation, or
you're writing/reviewing a diff. If a doc that should answer a question doesn't, the doc is stale — flag it
and patch it on the same turn.

For rationale/decision history (D1–D48, M1–M3) see [`docs/IMPLEMENTATION_PLAN.md`](docs/IMPLEMENTATION_PLAN.md)
— the **PLAN** (the "why"). The pyramid documents the **as-built** system (the "what" and "where").

## Domain vocabulary

| Term | Meaning |
|------|---------|
| **Adapter** | Language seam (D6). `Collect::Adapter` subclass that turns a codebase → `AdapterResult` of neutral `Raw*` value objects. `RubyAdapter` is the only one today; a future React/Node adapter is a new file, not a rewrite. |
| **Raw\* value objects** | `Raw::RawNode` / `RawEdge` / `RawEntrypoint` — neutral, **real-symbol-space** capture output (carry real file/line/symbol). Input to the Anonymizer; never serialized. |
| **Trust boundary** | The `Anonymizer` — the ONE place that mints opaque ids and splits data into the opaque graph vs the secret id-map. |
| **opaque id** | `n_` (function/endpoint/db_op node), `ext_` (external sink), `cls_` (class rollup, id-map only). |
| **db_op** | A synthesized node for an ActiveRecord query/persistence call, classified by class context. |
| **external sink** | A single shared `ext_` node every unresolved call points to (D24). |
| **class rollup** | A `cls_` aggregate over a class's member nodes (D9); de-anonymized + summed by the Ranker. |
| **clutter_score** | The engine's per-node score; the reporter ranks by it and shows it **verbatim** (D17). |
| **findings** | The engine's output (`findings.yml`): per-node metrics/scores + 7 finding types (D38). |
| **entrypoint** | A method the engine treats as a reachability root (controller actions, top-level defs, …). |

## Task workflow (every task ends with this)

A task is complete only when implementation + tests pass **AND** docs are updated:

```
□ Added/changed an Adapter or Raw* shape         → ARCHITECTURE.md (Collector section)
□ Changed the Anonymizer / graph / id-map shape  → ARCHITECTURE.md + CONTRACT.md (emitted shapes)
□ Changed the resolver tiers / vocab             → .claude/docs/resolver.md (tier table)
□ Added a new language adapter                   → ARCHITECTURE.md + .claude/docs/adapter-extension.md + Registry note
□ Changed what `report` consumes (findings shape)→ CONTRACT.md (consumed shape) — coordinate with the engine repo
□ Added/changed a Formatter                      → ARCHITECTURE.md (Reporter section, formats table)
□ Changed a CLI flag (collect/report)            → ARCHITECTURE.md (CLI section) + README.md
□ Changed the metric set                         → report.rb constant + the engine's METRIC_KEYS (lockstep) + CONTRACT.md
□ Introduced a new pattern/convention/invariant  → this file (AGENTS.md)
```

A task with no doc update is NOT done. Apply the **adjacent update rule**: when you change one entry,
verify the entries around it (and cross-references in the engine repo) haven't drifted.

## How to run + test

```bash
# all commands on this machine are prefixed with the rbenv version selector:
RBENV_VERSION=ruby-3.4.2 bundle install
RBENV_VERSION=ruby-3.4.2 bundle exec rspec            # full suite (65 examples)

# Collector: capture a codebase → out/graph.yml + out/id-map.yml(SECRET)
RBENV_VERSION=ruby-3.4.2 bundle exec exe/archbuddy collect PATH \
  --out-dir ./out [--language ruby] \
  [--entrypoints default|controllers|all_public|none] [--entrypoint-pattern REGEX ...]

# Reporter: de-anonymize + rank the engine's findings → clutter report
RBENV_VERSION=ruby-3.4.2 bundle exec exe/archbuddy report FINDINGS_YML \
  --id-map ./out/id-map.yml [--format terminal|yaml|json|dot] [--graph ./out/graph.yml] [--top N]
```

`--graph` is required only for `--format dot` (the edge list lives in `graph.yml`, not `findings.yml`).

## Architecture skills

This project enforces the **`self-aware-project`** skill (kosmin-skills marketplace): every task updates
the relevant docs after a structural change. Load it before making structural changes.
