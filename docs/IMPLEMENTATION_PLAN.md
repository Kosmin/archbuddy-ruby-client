# Implementation Plan — archbuddy-ruby-client (Ruby client)

This is the client slice of a verified deep-plan (Phase B-Track-1 + Phase C). The full master plan,
decisions ledger (D1–D48), architecture review, and Phase-4 runtime verification live in the
marketplace workspace at `.context/plans/plan_20260615_104605/`. This file is the self-contained
execution brief for THIS repo.

## Scope of this repo (D46)

`archbuddy-ruby-client` owns two concerns:

1. **Collector** — `lib/archbuddy/collect/` (Ruby static-AST capture → graph.yml + secret id-map.yml)
2. **Reconnect + Reporter** — `lib/archbuddy/report/` (join findings.yml × id-map.yml → ranked report)

Gem: `archbuddy` · Module: `Archbuddy` · Binary: `archbuddy`.
**Depends on** the `architecture_auditor` gem (git source) for `ArchitectureAuditor::Contract`
(`Ids`, `Serializer`, `Validator`, bundled schemas) — D47.

## File tree

```
lib/archbuddy/
  collect.rb + collect/
    adapter.rb                        # abstract Adapter interface (language seam, D6)
    raw.rb                            # RawNode/RawEdge/RawEntrypoint neutral value objects
    config.rb                         # ignore list, entrypoint strategy, vocab/sink overrides
    registry.rb                       # { "ruby" => RubyAdapter } — one-line language wiring
    anonymizer.rb                     # THE trust boundary: Raw* → opaque graph + secret id-map
    emitter.rb                        # validate→serialize→write graph.yml/id-map.yml + gitignore guard
    adapters/ruby_adapter.rb
    adapters/ruby/
      file_enumerator.rb symbol_table.rb definition_pass.rb resolution_pass.rb
      resolver.rb vocab.rb entrypoint_detector.rb
  report.rb                           # METRIC_KEYS_FOR_DISPLAY (D43) — asserted == engine METRIC_KEYS (4c)
  report/
    model.rb                          # DeanonModel value objects
    reconnect.rb                      # Join engine (de-anon; graceful on missing/external ids)
    ranker.rb                         # rank by clutter_score + class rollups (D9)
    explanation.rb                    # 7-type → forward/reverse explanation table (D19)
    formatter.rb  formatters/{terminal,yaml,json,dot}_formatter.rb
  cli.rb  cli/collect.rb  cli/report.rb       # D48: collect + report only
spec/collect/  spec/report/                   # incl. grep/arity fitness tests
archbuddy.gemspec  Gemfile (gem "architecture_auditor", git: …)  .ruby-version(3.4.2)
```

## What the collector EMITS (must match the engine's contract field-for-field)

- **graph.yml**: `schema_version:"1.0"`, `generator{tool,adapter:"ruby",capture:"static"}`,
  nodes `{id,kind,class_id?,loc?,self_time_ms(null),total_time_ms(null),count(null)}`,
  edges `{from,to,calls(≥1),count?,self_time_ml?}`, `entrypoints[]`.
  - All node-ids minted via `ArchitectureAuditor::Contract::Ids` → satisfy the D41 regex.
  - Static capture = all timing fields null (D4). `cls_` ids go ONLY into id-map.yml (D42) — never nodes[].
- **id-map.yml** (SECRET, gitignored): `ids:{<opaque_id> => {file,line,symbol,kind,class_id}}`.
  Includes `kind: class_rollup` entries for `cls_` ids. **Never passed to `analyze`.**

## Collector specifics (verified against prism 1.9.0)

- Two-pass `Prism::Visitor` (D23): `DefinitionPass` builds a `SymbolTable` (fq symbols, superclass,
  controller?/active_record? context), then `ResolutionPass` resolves call sites.
- **Tiered resolver (D24):** operators dropped (D36); metaprogramming flagged, no edge; implicit-self /
  self / app-`Const.method` → resolvable edges; AR-vocab calls → `db_op`; Controller convention →
  `endpoint`; everything else → a single `external` sink. **Never fabricate edges.**
- **Verified gotcha:** `where` inside `def self.x` of an `ApplicationRecord` subclass has receiver
  = **nil** (implicit self), not a ConstantReadNode — the db_op heuristic must consult class context,
  not just receiver shape.
- **Entrypoints:** default = controller actions + top-level defs; overridable
  (`--entrypoints controllers|all_public|none` or a regex list).
- **Anonymizer** is the single trust boundary: the only collector code that mints ids, via the
  contract's `Ids` mint. graph.yml carries NO app semantics.
- **Emitter** validates graph.yml against the contract schema (D37) before writing, serializes
  deterministically (D30), and ensures id-map.yml is gitignored before writing it.

## Reporter specifics

- **Reconnect** loads findings.yml + the SECRET id-map.yml and de-anonymizes at the three contract
  join sites: `findings.nodes.<id>`, every `findings[].node`, and every element of each
  `findings[].path[]` (→ real call chains like `User#save → Billing#charge`). Missing ids
  (e.g. `ext_` sinks) resolve to `<external …>`, never raise.
- Metrics + clutter_score are copied **verbatim** — the reporter never recomputes (Reporter-only, D17).
- **Ranker** sorts by clutter_score (D19) + class rollups (D9, `cls_` de-anon via id-map).
- **Formatter strategy** (open/closed): terminal default shows per bottleneck the real symbol,
  file:line, clutter_score AND the full 8-metric breakdown (the "direct scoring on each bottleneck").
  `yaml`/`json`/`dot` exports are SECRET/local-only (contain real symbols) — gitignored.
- **Explanation table** maps each of the 7 finding types to forward-discoverability vs
  reverse-traceability meaning so the report teaches WHY each item is clutter.

## Build order (this repo)

Both tracks depend on the `architecture_auditor` contract gem sha existing first.

### Phase B Track-1 — Collector
- **K-1** Adapter interface + Raw* value objects.
- **K-2** SymbolTable + DefinitionPass (Pass 1).
- **K-3** RubyResolver + ResolutionPass + vocab (Pass 2; tiered R0–R9).
- **K-4** EntrypointDetector (pluggable).
- **K-5** Anonymizer (trust boundary; mints via Contract::Ids; no cls_ nodes in graph).
- **K-6** RubyAdapter orchestration.
- **K-7** Emitter (validate-before-write; gitignore-before-secret).
- **K-8** `collect` dry-cli command + Config + adapter Registry (sole id-map producer).

### Phase C — Reporter (after collector; uses the contract for findings shape)
- **R-1..R-4** model → reconnect (join) → ranker → explanation.
- **R-5** expose `Archbuddy::Report::METRIC_KEYS_FOR_DISPLAY` as a named constant (D43); the client
  spec asserts it equals the engine gem's `METRIC_KEYS` (the 4c contract test, client side).
- **R-6** formatter strategy + terminal/yaml/json/dot formatters.
- **R-7** `report` dry-cli command (reader of id-map; the other id-map consumer besides `collect`).

## Security / handling rules
- `id-map.yml` and all de-anonymized exports (`report.yml/json`, `.dot`) are **secret, local-only**,
  and gitignored — they contain real file/symbol names. Never commit, never send externally.
- The engine never receives id-map.yml; `analyze` has no `--id-map` option by construction.
