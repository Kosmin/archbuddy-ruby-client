# ARCHITECTURE.md — archbuddy-ruby-client

The as-built code map. Find any responsibility **by name** here without opening source. For data
contracts (graph/id-map/findings shapes) see [`CONTRACT.md`](CONTRACT.md). For deep topics see
[`.claude/docs/`](.claude/docs/). For rationale see [`docs/IMPLEMENTATION_PLAN.md`](docs/IMPLEMENTATION_PLAN.md).

## Two concerns, one gem

```
your repo ──▶ COLLECTOR (collect) ──▶ graph.yml + id-map.yml(SECRET)
                                          │
              graph.yml ──▶ architecture_auditor analyze (OTHER repo) ──▶ findings.yml
                                          │
              findings.yml + id-map.yml ──▶ REPORTER (report) ──▶ ranked clutter report
```

- **Collector** captures + anonymizes (Ruby → opaque graph + secret map). The only producer of `id-map.yml`.
- **Reporter** re-joins (findings + secret map → ranked report). The only other reader of `id-map.yml`.
- **The engine repo** sits between them: it analyzes the opaque graph and never sees the id-map.

The boundary that makes this safe is the **Anonymizer** (single trust boundary): real symbols enter, an
opaque graph and a secret map leave. See the [trust boundary](#the-trust-boundary) section.

## Dependency on the engine Contract

This gem requires the `architecture_auditor` gem and uses exactly four things from it
(`require "architecture_auditor"`):

| Used | What it provides | Where used here |
|------|------------------|-----------------|
| `Contract::Ids` | The single id mint (`node_id`/`class_id`/`external_id`, `valid?`, `ID_REGEX`) | `Collect::Anonymizer` (the ONLY minting site) |
| `Contract::Serializer` | Deterministic YAML `dump`/`load`/`load_string` (D30) | `Collect::Emitter`, `Report::Reconnect`, yaml formatter |
| `Contract::Validator` | JSON-schema `validate!`/`valid?` against bundled graph/findings schemas (D37) | `Collect::Emitter` (validate-before-write) |
| `Contract::SCHEMA_VERSION` | `"1.2"` (alias for `GRAPH_SCHEMA_VERSION`) stamped into emitted graphs | `Collect::Anonymizer` |
| `Analyze::METRIC_KEYS` | Canonical 8-key metric set (engine source of truth) | asserted == client constant in the metric-kernel spec |

The contract is the language-neutral hub both halves depend on; it references no
collector/processor/reporter concepts. The Gemfile defaults to a **git source** (distribution, D47) so a
fresh clone installs standalone; local dev overrides to the `../architecture-auditor` sibling via
`ARCHITECTURE_AUDITOR_PATH` or `bundle config local.architecture_auditor` (M2). See
[`.claude/docs/cross-repo.md`](.claude/docs/cross-repo.md).

---

## Top-level load map

| File | Responsibility |
|------|----------------|
| `lib/archbuddy.rb` | Entry require: loads the contract, `collect`, `report`; defines `Archbuddy::Error`. |
| `lib/archbuddy/version.rb` | `Archbuddy::VERSION` (`"0.4.0"`). |
| `lib/archbuddy/cli.rb` | `Archbuddy::CLI` — `Dry::CLI::Registry` registering `collect` + `report` (D48). |
| `lib/archbuddy/cli/collect.rb` | `collect` command — see [CLI](#cli). Sole producer of id-map.yml. |
| `lib/archbuddy/cli/report.rb` | `report` command — see [CLI](#cli). Other consumer of id-map.yml. |
| `exe/archbuddy` | Binary: `Dry::CLI.new(Archbuddy::CLI).call`. |

---

## Concern 1 — Collector (`lib/archbuddy/collect/`)

Pipeline: **enumerate → Pass 1 (definitions) → Pass 2 (resolution) → assemble Raw\* → Anonymize → Emit.**
Only the Anonymizer mints ids; everything before it lives in real-symbol space.

### Pipeline + neutral seam

| File / Class | Responsibility |
|--------------|----------------|
| `collect.rb` (`Collect`) | Requires the pipeline pieces. |
| `adapter.rb` (`Adapter`, `AdapterResult`) | **Abstract language seam (D6).** `Adapter#collect` → `AdapterResult(nodes, edges, entrypoints, diagnostics)`. Every language adapter returns this neutral shape; the rest of the pipeline is language-agnostic. `diagnostics` is consumed by the **CLI only**, never by the Anonymizer (must not leak into the graph). |
| `raw.rb` (`Raw::RawNode/RawEdge/RawEntrypoint`) | Neutral **real-symbol-space** value objects. `RawNode` carries `rel_file/line/symbol/kind` + owning-class def site (`class_rel_file/line/symbol`) used to mint the `cls_` rollup id (id-map only, D42). `real_key` = `"file:line:symbol"` — the identity edges/entrypoints reference before ids exist. `kind` ∈ `function|endpoint|db_op|external`. |
| `config.rb` (`Config`) | Value object: `ignore` list (`DEFAULT_IGNORE`: vendor, node_modules, tmp, log, coverage, .git, .bundle, spec, test, db/migrate), `entrypoint_strategy` (validated against `ENTRYPOINT_STRATEGIES = default|controllers|all_public|none`), `entrypoint_patterns` (regexes). Unknown strategy raises `ArgumentError`. |
| `registry.rb` (`Registry`) | One-line language wiring (D6): `ADAPTERS = { "ruby" => Adapters::RubyAdapter }`. `Registry.for(lang)` fetches or raises. **Adding a language = one entry here** (plus the adapter file). |

### The trust boundary

| File / Class | Responsibility |
|--------------|----------------|
| `anonymizer.rb` (`Anonymizer`) | **THE single trust boundary (K-5).** Converts `AdapterResult` → `Result(graph, id_map)`. The ONLY code that mints ids, solely via `Contract::Ids` (D25/D41). Produces: **(a)** the opaque graph hash — opaque node ids, contract `kind`s, `class_id` refs (`cls_`), all timing/`loc` fields **null** (D4/D7/D16/D18). As of v0.6 (L3) the client no longer emits `sink_open` on `db_op` nodes — a db_op is a plain COST-1 terminal (the field stays DECLARED-but-optional in the engine schema; graph stays 1.2); **(b)** the secret id-map `{ "ids" => { opaque_id => {file,line,symbol,kind,class_id} } }`, including `kind:"class_rollup"` entries for every `cls_` id. `mint_node_id` uses `Ids.external_id` for `external` kind, else `Ids.node_id`. `class_id_for` memoizes the `cls_` mint and records it in the id-map but **never** adds it to `graph.nodes[]` (D42). `build_edges`/`build_entrypoints` map `real_key`s → opaque ids and drop dangling refs. |
| `emitter.rb` (`Emitter`) | **Validate → serialize → write (K-7).** `Validator.validate!(:graph, graph)` BEFORE writing (D37) — a non-conforming graph never reaches disk. Writes `graph.yml` then, **gitignore-before-secret**, verifies the id-map path is gitignored (`git check-ignore`, falling back to a filename check for `id-map.yml`/`*.id-map.yml`) and raises `SecretNotIgnoredError` rather than risk committing real symbols. Filenames: `graph.yml`, `id-map.yml`. |

### Ruby adapter (`collect/adapters/`)

| File / Class | Responsibility |
|--------------|----------------|
| `ruby_adapter.rb` (`Adapters::RubyAdapter`) | Orchestrates Ruby capture (K-6): enumerate `.rb` → parse all via `Prism.parse` → Pass 1 (`DefinitionPass`) into a shared `SymbolTable` → Pass 1b `RouteCatalogue` (seeds routed actions) → Pass 2 (`ResolutionPass`) with config-selected probes into a shared `Accumulator` → assemble `Raw*` (method nodes with `class_id` refs, synthesized `db_op` nodes, ONE shared `external` sink at `EXTERNAL_SINK_SYMBOL = "<external>"`), edges (collapsing duplicate `(from,to)` pairs into `calls >= 1`), and entrypoints. `endpoint?` = Grape endpoint handler block (`method_entry.endpoint`) OR non-singleton method on a controller class. Reports `meta_sites_skipped` and `probe_edges` as diagnostics. **No id minting here.** |
| `ruby/file_enumerator.rb` (`FileEnumerator`) | Enumerates `.rb` files under a root honoring the ignore list, deterministically sorted (D30). Matches ignore patterns as contiguous path-segment subsequences. Raises `NoSourceError` if the path is missing, a non-`.rb` single file, or yields zero `.rb` files (fail loud, never emit a near-empty graph). |
| `ruby/definition_pass.rb` (`DefinitionPass < Prism::Visitor`) | **Pass 1 (D23).** Walks class/module/def building the `SymbolTable` (fq symbols, class superclass/controller?/AR?/grape_api? metadata). Tracks a namespace stack + a Grape-class stack; classifies a `def` as singleton (`Foo.x`, receiver present) vs instance (`Foo#x`). Top-level defs are owner-less (bare name). Mints one `MethodEntry` with `endpoint: true` per Grape HTTP verb-block (stable FQ via `GrapeDsl.endpoint_fq`). Uses `BranchCounter` with V7/P5 de-idiomatization: only business control flow (`if`/`unless`/`case`/`while`/`until`/`for`) multiplies into `branches`; idioms (`&&`/`||`, `&.`, `||=`/`&&=`, `rescue`, pattern-match predicates) count only in `decisions`. |
| `ruby/symbol_table.rb` (`SymbolTable`, `ClassEntry`, `MethodEntry`) | Catalogue of discovered classes + methods (first definition wins, so reopened classes keep a stable def site). `ClassEntry#active_record?`/`#controller?`/`#grape_api?` test superclass vocab + name convention. `chain_any?` walks the superclass chain so subclasses of intermediate AR/controller/Grape bases still count. `MethodEntry#endpoint` marks Grape endpoint handler nodes (default `false`). `add_routed_action`/`routed_action?` support the rails-routes entrypoint seeder. |
| `ruby/grape_dsl.rb` (`GrapeDsl`) | **Shared, pure Grape recognizer (W2).** Single source of truth for byte-identical detection in Pass 1 and Pass 2: `endpoint_verb_call?`, `grape_api_superclass?`, `mount_call?`, `helpers_block_call?`, and `endpoint_fq(class_fq, verb, ordinal)`. No state, no AST walk, no app boot. Ordinal-parity invariant (F5): both passes use this module to ensure the minted FQ (Pass 1) == the pushed FQ (Pass 2). |
| `ruby/route_catalogue.rb` (`RouteCatalogue < Prism::Visitor`) | **Pass 1b Rails-routes entrypoint seeder (W4).** Walks files looking for `Rails.application.routes.draw` blocks. Collects `to: "controller#action"` explicit routes and `resources`/`resource` RESTful expansions (honouring `only:`/`except:`), with one level of `namespace`/`scope module:` nesting. Seeds `(controller_fq, action)` pairs into the SymbolTable ONLY when `table.method?` is true (L2 never-fabricate). NOT a `Probe`; emits no edges and is not in `ProbeRegistry`. |
| `ruby/resolution_pass.rb` (`ResolutionPass < Prism::Visitor`, `Accumulator`) | **Pass 2 (D23).** Walks call sites inside method bodies; tracks enclosing class fq + current method fq so the resolver gets class context and each edge has a real `from`. For Grape endpoint verb-blocks, opens a synthetic method scope (pushing the endpoint FQ from `GrapeDsl.endpoint_fq`) so handler-body calls are attributed to that endpoint. Passes the raw Prism `node:` to `CallContext` and threads configured probes through to `RubyResolver`. Routes each `Resolution` into the `Accumulator` (`add_method_edge` / `add_db_op_edge` / `add_external_edge` / `flag_metaprogramming`); tallies probe-resolved resolutions into `@probe_edges` (per-probe-name count). Calls at class-body/top-level (no caller method) are NOT edges. |
| `ruby/resolver.rb` (`RubyResolver`, `CallContext`, `Resolution`) | **Pure tiered decision logic (D24).** See the [resolver tier table](.claude/docs/resolver.md) and the [probe seam](#probe-registry--r5-tier) below. `CallContext` carries an optional `node:` (the raw Prism `CallNode`) for probe inspection and an optional `type_scope:` (the conservative intra-procedural type map consumed by R4.5, L1/v0.6). `Resolution` carries an optional `provenance:` (the probe's `#name` Symbol, diagnostics-only). `RubyResolver.new(table, probes: [])` — `probes:` defaults to empty (backward-compat). **Never fabricates an edge.** |
| `ruby/probe.rb` (`Probe`) | **Abstract base for a framework probe (P1 / L4, W1).** Subclasses implement `#name` (stable Symbol) and `#resolve(ctx) -> Resolution\|nil`. Declining returns `nil` so the call falls through to the next probe or R9 `<external>`. A non-nil `Resolution` REPLACES the `<external>` fallthrough (P6). Subclasses SHOULD also define `self.probe_name` for cheap registry filtering. |
| `ruby/probe_registry.rb` (`ProbeRegistry`) | **Ordered, config-selected probe registry (P1 / L4, W1/W3).** `PROBES` = `[GrapeProbe, DispatchProbe]` (priority order). `ProbeRegistry.for(config)` returns instantiated selected probes. `config.probes` can be `:all` (default), `:none`/`[]`, or an explicit `Array<Symbol>` of probe names. Unknown names are silently skipped (F2 — never raises). |
| `ruby/probes/grape_probe.rb` (`GrapeProbe < Probe`) | **Grape mount-tree probe (R5, W3).** `name: :grape`. Resolves `mount Const` calls inside a `Grape::API` to that API's representative endpoint node (the first declared endpoint of the first available verb). Declines on dynamic mounts, unknown constants, unknown classes, or an empty API (no minted endpoints). |
| `ruby/probes/dispatch_probe.rb` (`DispatchProbe < Probe`) | **Sidekiq/ActiveJob dispatch probe (R5, W3).** `name: :sidekiq_dispatch`. Resolves `Const.perform_async/later/in/at` (and a single `.set(...)` hop) to a `Const#perform` edge IFF `table.method?("Const#perform")`. Declines on non-constant receivers, deeper chains, and missing `#perform`. Deliberately excludes bare `perform`/`perform_now` (handled by R4). |
| `ruby/vocab.rb` (`Vocab`) | Pure static vocabularies the resolver consults: `OPERATOR_DENY` (D36), `METAPROGRAMMING`, `ACTIVE_RECORD` query/persistence methods (`active_record_method?`), `ACTIVE_RECORD_BASES`, `CONTROLLER_BASES`. (v0.6/L3: the `AR_WRITE`/`AR_DESTROY`/`ar_op_kind` write-specificity partition was removed with the `sink_open` revert — a db_op is a plain COST-1 terminal.) |
| `ruby/entrypoint_detector.rb` (`EntrypointDetector`) | Pluggable entrypoint strategy (K-4/D4). `default` = controller actions ∪ Grape endpoints ∪ routed actions ∪ top-level defs; `controllers` = controller actions ∪ Grape endpoints ∪ routed actions; `all_public` = every instance method; `none` = []. Optional regex patterns are additively unioned. May return `[]` (→ the M3 warning in the CLI). |

### Probe registry / R5 tier

The resolver's tier sequence is: **R0** operator deny → **R1** metaprogramming → **R2** db_op (class
context) → **R3** self call → **R4** const-receiver → **R4.5** typed-receiver (L1/v0.6 — variable/ivar/
memoized-accessor/inline-`Const.new` types resolved via `ctx.type_scope` + `table.method?`, NEVER
fabricated) → **R5 probe tier** → **R9** `<external>`.

The R5 tier iterates `@probes` (config-selected, instantiated by `ProbeRegistry.for(config)`); the
first non-nil `Resolution` wins and **replaces** the `<external>` fallthrough (P6 — a probe never
stacks a second edge). The probe loop runs AFTER all base tiers so it never shadows a known app edge.

### EDGE-vs-NODE split (static probe architecture)

Two collaborating mechanisms add framework-aware topology:

- **NODE side — Pass-1 discovery:** `DefinitionPass` mints one `MethodEntry` with `endpoint: true` per
  Grape HTTP verb-block. `RouteCatalogue` seeds `(controller_fq, action)` pairs as routed entrypoints.
  Both feed `EntrypointDetector` so framework endpoints appear in `entrypoints[]`.

- **EDGE side — R5 probe tier:** `GrapeProbe` (mount tree) and `DispatchProbe` (Sidekiq/ActiveJob) are
  resolver-tier probes that recover call edges the base AST resolver can't see. A probe is selected by
  `ProbeRegistry`, receives a `CallContext` (with the raw Prism `node:`), and either claims the call
  (returns a `Resolution` with `provenance:`) or declines (`nil`).

Rails routes is a **SEEDER**, not a probe — it emits no edges and is not in `ProbeRegistry`.

`GrapeDsl` is the **single recognizer module** used by both sides: `endpoint_fq(class_fq, verb, ord)`
is the only function that mints and pushes the synthetic endpoint FQ, ensuring ordinal parity (F5) so
no edges are silently lost.

---

## Concern 2 — Reporter (`lib/archbuddy/report/`)

Pipeline: **Reconnect (join findings × secret id-map) → Ranker (order + class rollups) → Formatter (render).**
Everything is **verbatim** (D17) — no metric is ever recomputed.

| File / Class | Responsibility |
|--------------|----------------|
| `report.rb` (`Report`) | Defines `METRIC_KEYS_FOR_DISPLAY` — the 8 display metric keys as a **named constant** (D43), asserted == engine `Analyze::METRIC_KEYS`. Autoloads the model/reconnect/ranker/explanation/formatter + the five formatters (terminal/yaml/json/dot/html). |
| `model.rb` (`Model::Location/Bottleneck/Finding`) | Presentation-agnostic value objects (R-1). `Location` is a de-anonymized `{id,file,line,symbol,kind,class_id,resolved}` — `resolved?` false ⇒ a graceful `<external …>` placeholder (never raises). `Bottleneck` = one node + its verbatim 8 metrics + `clutter_score` + the findings touching it (`rollup?` true when `kind=="class_rollup"`). `Finding` = node-type (single `node`) or path-type (`path_refs` chain, `path?`/`chain`). |
| `scores.rb` (`Scores`, `Scores::DimensionScore/Hotspot`, `Scores::Connectivity`) | **R-8: the de-anonymized presentation model for findings.yml's OPTIONAL project-level `scores` block (findings 1.3, additive).** `Scores.from_findings(doc, resolver)` parses the two dimensions (**reverse_traceability** always-computable + **forward_discoverability** which is **N/A when there are no entrypoints**), copies each dimension's `score`/`grade` **verbatim** (D17 — never recomputed; they come straight from findings.yml), and de-anonymizes each dimension's **worst-first OPAQUE `hotspots`** via the SAME `IdMapResolver` (graceful `<external …>` for missing/`ext_` ids). Each `Hotspot` carries the dimension's **driving-metric values** (`DRIVING_METRICS`: reverse ⇒ fan_in/centrality/in_cycle; forward ⇒ path_length/fan_out) pulled verbatim from the per-node `nodes.<id>.metrics`. **Returns `nil` for a 1.0 doc with no scores block** (back-compat). `DimensionScore#display_score` formats the verbatim cost as `"%.1f"` (unbounded, no `/100` suffix, real-space arithmetic mean — no logarithm); `nil` renders as `"N/A"`. The cost number is the headline; the grade is a tentative secondary indicator. `Scores::Connectivity` (V8, findings 1.3) is a parallel struct (`{forward, reverse, scored_nodes, total_nodes}` — CR-1 four-field shape, no `verdict`) parsed by `connectivity_from_findings`; nil-tolerant for 1.0/1.1/1.2 docs (no banner). `forward`/`reverse` are engine-emitted 0..1 ratios formatted by the client as `"0.3%"` or `"N/A"` (D17 — no recompute). **R1 (v0.8):** `Scores::MultiplexerProxy` + `multiplexer_proxies_from_findings` / `multiplexer_proxies_from_committed` surface the v0.7 `multiplexer_proxy` smell (findings 1.4 `scores.multiplexer_proxies`, worst-first) VERBATIM. Accepts BOTH the committed real-name `{symbol, added_coupling}` shape (no id-map) and the legacy opaque `{node, …}` shape (resolved). Returns `nil` for no scores block (section omitted), `[]` for scored-but-no-proxy (honest `(none)` note — never fabricated); ids-only degrades to a blank coupling. |
| `reconnect.rb` (`Reconnect`, `IdMapResolver`) | **R-2 join engine.** `from_files` loads findings.yml + the SECRET id-map.yml via `Serializer`. De-anonymizes at the three contract join sites: `findings.nodes.<id>`, each `findings[].node`, each `findings[].path[]` element. Metrics/score copied **verbatim** (D17). `IdMapResolver.resolve(id)` → `Location`; ids absent from the map (e.g. `ext_` sinks, unknown ids) resolve to a graceful placeholder and **never raise**. Path findings attach to the first node on their path. Also builds the optional `Scores` model (R-8) and exposes it on `Result#scores` (`nil` for a 1.0 doc). Parses the optional `scores.connectivity` block (findings 1.3) and exposes it on `Result#connectivity` (`nil` for 1.0/1.1/1.2 docs — no resolver needed, counts/ratios only, no opaque ids). |
| `ranker.rb` (`Ranker`) | **R-3.** `ranked(top:)` sorts bottlenecks by `clutter_score` desc, deterministic tiebreak by opaque id (nil scores last). `class_rollups(top:)` groups by `class_id`, **sums** members' verbatim scores (a presentation aggregate, not recomputation), de-anonymizes the `cls_` id (D9). Never recomputes a node metric. |
| `explanation.rb` (`Explanation`) | **R-4 (D19).** `TABLE` maps all 7 finding types → plain-English "why is this clutter" along two axes: **forward discoverability** vs **reverse traceability**. `describe(finding)` renders a one-line, value-aware explanation. |

### Formatters (`report/formatters/`)

| File / Class | Format | Responsibility |
|--------------|--------|----------------|
| `formatter.rb` (`Formatter`, `RenderContext`) | — | **R-6 strategy base + open/closed `FORMATS` registry.** `register(name, klass)` / `for(name)`. Receives an already-de-anonymized, already-ranked `RenderContext(ranked, class_rollups, generator, graph, resolver, scores, connectivity)`; makes ZERO analytic decisions. `scores` is the optional R-8 dimension-scores model (`nil` for a 1.0 doc). `connectivity` is the optional V8 `Scores::Connectivity` struct (`nil` for 1.0/1.1/1.2 docs — keyword_init, nil-default, backward-compatible). Eager-requires the five built-ins so registration happens on load. |
| `terminal_formatter.rb` (`TerminalFormatter`) | `terminal` (default) | **Connectivity banner ABOVE dimension rows** (V8, findings 1.3): when `context.connectivity` is present, prepends a one-line `Connectivity: N/total nodes scored (P%)` banner above the dimension summary rows (nil → empty array → no banner, back-compat). Then **R-8 summary header** (when `context.scores` present): an eslint/rubocop-style `Architecture Scores` block that **LEADS with each dimension's verbatim cost + grade** (e.g. `27.1  (B)` — the cost number is the headline, the grade is tentative/advisory, real-space arithmetic mean) + framing question, then lists that dimension's de-anonymized hotspots as **"top contributors to this dimension (worst-ranked first)"** (relative, not "these are bugs") with real symbol + `file:line` + driving metric(s); an `N/A` dimension renders the reason (`no entrypoints — re-collect with --entrypoints all_public`) instead of a number. Then per bottleneck: real symbol, `file:line`, `clutter_score`, the **full 8-metric breakdown**, de-anonymized finding explanations (incl. `long_path`/`cycle` as real ordered chains `A → B`), and a class-rollups section. All values verbatim (D17 — no recompute, client only formats engine-emitted figures). **Output carries real symbols → SECRET/local-only.** |
| `structured_export.rb` (`StructuredExport`) | — | Shared builder turning a `RenderContext` → plain-data Hash (bottlenecks + class_rollups + the optional **R-8 `scores`** block with de-anonymized hotspots; the `scores` key is omitted entirely for a 1.0 doc). Used by yaml + json. Verbatim. |
| `yaml_formatter.rb` (`YamlFormatter`) | `yaml` | `Serializer.dump` of the structured export (deterministic, diffable). **SECRET/local-only.** |
| `json_formatter.rb` (`JsonFormatter`) | `json` | `JSON.pretty_generate` of the structured export. **SECRET/local-only.** |
| `dot_formatter.rb` (`DotFormatter`) | `dot` | Optional, non-contract graphviz. **Requires `--graph` (edge list lives in graph.yml, not findings.yml)**; without it returns a clear unavailable message. Node labels de-anonymized via the resolver. **SECRET/local-only.** |
| `html_formatter.rb` (`HtmlFormatter`) | `html` | A SINGLE, fully self-contained, fully **OFFLINE** Cytoscape.js dashboard string: dimension-score grade cards (R-8) + an interactive call graph + the ranked bottleneck table. **Inlines** the vendored Cytoscape.js library + all CSS/JS — ZERO external/CDN references (asserted by spec). Like `dot` it uses `--graph` for the edge list; **without `--graph` the scores header + table still render** (visible notice, no graph). Embeds an inlined data JSON (de-anonymized nodes/edges + verbatim bottlenecks/scores via `StructuredExport`) consumed by a small vanilla-JS init script. Built-in layouts only (cose/grid/breadthfirst/circle). The **ranked table is client-side sortable** (click any header — clutter/metrics/symbol/file/kind; toggles asc/desc with a ▲/▼ indicator; null/`N/A` sort last) and **paginated** (25/50/100/All, default 25; Prev/Next + "showing X–Y of Z"); rows are server-rendered (escaped) and only reordered/shown-hidden, so escaping never regresses, and sort/paginate work even in the no-graph path. The **call graph has a minimum clutter-score filter** (range slider + synced number input) that hides below-threshold nodes + their incident edges with a live "showing N of M nodes" count, defaulting to a focused view of the worst offenders (~top 120 by clutter; debounced re-layout). All sorting/filtering is presentation over the already-emitted findings — ZERO recompute. Carries real symbols → **SECRET/local-only.** |
| `assets/cytoscape.min.js` + `assets/CYTOSCAPE_LICENSE` | — | Vendored, version-pinned (3.30.3) Cytoscape.js minified library (MIT) read at render time and inlined by `HtmlFormatter` to make the report offline. A **runtime dependency, not a secret** → committed (unlike generated reports). License/provenance in `CYTOSCAPE_LICENSE`. |

---

## CLI

`Archbuddy::CLI` (dry-cli, D48) registers **four** commands (v0.8 committed-cache surface): `collect`,
`analyze`, `report`, `reset`. `collect` is the sole producer of the SECRET `id-map.yml`; the *committed*
cache is de-anonymized at WRITE time and readable with NO id-map.

### `archbuddy collect PATH` — `cli/collect.rb`

Sole producer of `id-map.yml`. Builds a `Config`, gets the adapter via `Registry`, runs `adapter.collect`
(rescuing `NoSourceError` → `exit 1`), anonymizes, and emits via `Emitter`.

| Option | Default | Meaning |
|--------|---------|---------|
| `PATH` (arg) | — | Codebase dir or single `.rb` file. |
| `--out-dir` | `.archbuddy/` (`DEFAULT_WORKSPACE_DIR`) | Output dir for `graph.yml` + `id-map.yml`. OPTIONAL — the shared workspace default makes `collect .` flag-free. |
| `--language` | `ruby` | Adapter language (Registry key). |
| `--entrypoints` | `default` | `default\|controllers\|all_public\|none`. |
| `--entrypoint-pattern` | `[]` | Extra entrypoint fq-symbol regex(es) (repeatable). |
| `--changed` | `false` | Incremental: reuse unchanged files' cached parse (content-hash trigger), re-parse only changed. |
| `--base-ref` | — | Optional git base ref for the `--changed` fast-path pre-filter (content hash still authoritative). |
| `--check` | `false` | CI staleness gate (`Cache::Checker`): regenerate the committed cache + `git diff`; `exit 1` on drift, `exit 2` (loud) when there is no committed baseline, `exit 0` clean. Never reads the id-map. |

**Default-workspace secret safety (`ensure_default_workspace_excluded!`).** When `--out-dir` is omitted
(the default `.archbuddy/`) AND CWD is inside a git repo, the command appends `.archbuddy/` to
`.git/info/exclude` (a LOCAL ignore — never the tracked `.gitignore`) so the `Emitter`'s
gitignore-before-secret guard passes without user action. Idempotent (no duplicate line; no-op if already
ignored by any means), prints a one-line note, and no-ops outside a git repo. For an EXPLICIT `--out-dir` it
touches no ignore file — the `Emitter` guard refuses a non-ignored user-chosen path (behavior unchanged).

Stderr diagnostics (never graph content): the one-line `.git/info/exclude` note when it auto-excludes; a
metaprogramming-sites-skipped note when > 0; the **M3 zero-entrypoints warning** suggesting
`--entrypoints all_public`; and the two `wrote …` lines (the id-map line is tagged `SECRET — gitignored,
never share`).

### `archbuddy analyze` — `cli/analyze.rb`

The SCORE + de-anon-at-write step. Assumes `collect` already produced the opaque `.archbuddy/graph.yml`
(errors loudly, `exit 1`, with a `collect` hint otherwise). Shells out to the engine `analyze`
(`graph.yml → findings.yml`, opaque), then **transcodes at WRITE time** (`Cache::Writer`) — de-anonymizing
the opaque findings + SECRET id-map into the COMMITTED, real-name root `archbuddy-findings.json` (headline
scores + the `multiplexer_proxy` smell). The engine stays YAML-native; only the client holds the id-map, so
the de-anon-at-write step is client-owned. `reset` delegates its analyze+transcode here (one implementation).

### `archbuddy reset PATH` — `cli/reset.rb`

L3 full reset / overhaul: a FULL (never `--changed`) re-collect from scratch (ignoring the speed cache),
then delegates to `analyze`. Use on first run or when the scoring model changes.

### `archbuddy report [FINDINGS_YML]` — `cli/report.rb`

TWO read paths (R2-1). **DEFAULT** (no explicit findings arg + a committed `archbuddy-findings.json`
present): `Reconnect.from_cache(aggregate_path:, id_map_path: nil)` reads the COMMITTED, real-name aggregate
**directly, with NO id-map** — a fresh clone works. **LEGACY** (explicit findings arg, or no committed
cache): `Reconnect.from_files` joins an opaque `findings.yml` against the SECRET id-map at read time. Then it
resolves the formatter (`Formatter.for`, `exit 1` on unknown), builds a `Ranker`, assembles a
`RenderContext` (now carrying `multiplexer_proxies`), and prints `formatter.render`. Every formatter renders
the **`multiplexer_proxy` smell** (findings 1.4) as an additive section, VERBATIM worst-first: absent scores
block → section omitted; scored-but-empty → an honest `(none)` note (never a fabricated verdict).

| Option | Default | Meaning |
|--------|---------|---------|
| `FINDINGS_YML` (arg) | committed `archbuddy-findings.json` (root) | With no arg, the DEFAULT committed real-name cache is read (no id-map). An explicit path forces the LEGACY opaque path. |
| `--id-map` | `.archbuddy/id-map.yml` | The SECRET id-map.yml — LEGACY path only; NOT read on the committed default path. |
| `--format` | `terminal` | `terminal\|yaml\|json\|dot\|html`. |
| `--graph` | `.archbuddy/graph.yml` **if present** | Path to graph.yml; **required for `--format dot`**, used by `--format html` (html degrades gracefully without it). Default only applies when the workspace file exists, so terminal/yaml/json don't warn about a missing graph. |
| `--top` | — | Show only the top N bottlenecks. |

---

## Tests (`spec/`)

| Spec | Covers |
|------|--------|
| `spec/spec_helper.rb` | Loads `archbuddy` + `archbuddy/collect`; random order. |
| `spec/collect/collector_spec.rb` | End-to-end capture on `spec/fixtures/sample`: schema validity, id minting via Contract::Ids, the AR implicit-self `where` gotcha, operator drop, single external sink, resolvable cross-class edge, endpoint marking, `cls_` rollups in id-map only, **null `loc` / zero-leak guard**, null timing, **`probe_edges == {}`** diagnostic assert. |
| `spec/collect/emitter_spec.rb` | Validate-before-write + **gitignore-before-secret** guard. |
| `spec/collect/cli_collect_warning_spec.rb` | M3 zero-entrypoint stderr warning + that it stays out of graph/id-map. |
| `spec/collect/cli_collect_default_dir_spec.rb` | **`.archbuddy/` default workspace + secret safety**: no-`--out-dir` writes to `.archbuddy/` (non-git just writes; git repo auto-adds `.archbuddy/` to `.git/info/exclude`, id-map ends up `git check-ignore`d, idempotent on a 2nd run); an EXPLICIT non-ignored `--out-dir` still trips the Emitter refuse-guard and does NOT edit any ignore file. |
| `spec/collect/capture_diagnostics_spec.rb` | `NoSourceError` cases + metaprogramming diagnostic count staying out of graph data + **`"probe_edges"` absent from serialized graph** (provenance diagnostics-only guard). |
| `spec/collect/probe_seam_spec.rb` | **W1 probe seam unit spec**: fake probe, R5-after-R4 ordering, decline → R9, REPLACE-not-stack, provenance stamp, `ProbeRegistry` selection, `ResolutionPass` `probe_edges` tally, 1-arg / 2-arg backward-compat. |
| `spec/collect/grape_dsl_spec.rb` | **W2 `GrapeDsl` unit spec**: `endpoint_verb_call?`, `grape_api_superclass?`, `mount_call?`, `endpoint_fq` correctness. |
| `spec/collect/definition_grape_spec.rb` | **W2 `DefinitionPass` Grape unit spec**: endpoint node minting (FQ, `endpoint:true`, ordinals, `BranchCounter`, empty class / empty block). |
| `spec/collect/grape_probe_spec.rb` | **W2 e2e Grape fixture + W3 mount-probe**: endpoint nodes emitting `kind:"endpoint"`; entrypoints; 0→N edge regression guard; mount edge to a known API; decline on dynamic / unknown / empty API. |
| `spec/collect/dispatch_probe_spec.rb` | **W3 dispatch-probe e2e**: `perform_async/later/in/at` + `.set` chain → `Const#perform` edge; decline → `<external>` when target absent / non-const; `probe_edges` tally; serialized graph does not carry provenance. |
| `spec/collect/route_catalogue_spec.rb` | **W4 routes-seeder e2e**: `to:` seeds entrypoint; `resources`/`resource` expansion; `only:`/`except:`; missing-controller no-fabricate; empty-routes no-op; heuristic-missed action caught. |
| `spec/report/reporter_spec.rb` | Ranking, `--top`, three-site de-anon, graceful missing ids, class rollups, **verbatim metrics**, terminal/yaml/json/dot formatters, all 7 explanation types, formatter registry. |
| `spec/report/cli_report_default_dir_spec.rb` | **`.archbuddy/` default workspace for `report`**: no-args reads `.archbuddy/{findings,id-map}.yml`; missing default findings/id-map → friendly `exit 1` error naming the producing command (no stack trace); explicit args override the workspace defaults. |
| `spec/report/html_formatter_spec.rb` | **Offline `html` formatter**: registry, valid-ish self-contained HTML (cy container + inlined cytoscape lib >200KB + inlined data JSON), **ZERO external resource refs** (the offline guarantee), both dimension scores+grades, de-anonymized real symbols + file:line, **verbatim** bottleneck table, graph nodes/edges in the data JSON, hotspot ids per dimension, graceful `<external>` graph node, **no-graph degradation** (scores+table+notice), forward **N/A**, **1.0 back-compat** (no scores header), **table sort/pagination controls** (sortable headers w/ keys+handler, default clutter desc, page-size 25/50/100/All, Prev/Next, null-last sort), the **graph min-score filter** (slider+number, focused-default heuristic, incident-edge hide, debounced re-layout, graceful empty-threshold), and **V8 connectivity banner** (present and positioned BEFORE `.cards` div when findings carry connectivity block; HTML-escaped; absent on 1.1 doc — back-compat). Both `RenderContext.new` call sites updated. Headless-verified with Playwright. |
| `spec/report/scores_spec.rb` | **R-8 project dimension scores + V8 connectivity**: parse + verbatim unbounded cost/grade (real-space arithmetic mean, no K multiplier), worst-first hotspot de-anon with driving metrics, graceful `<external>` for absent hotspot ids, **N/A forward** (null score → reason, not a number), terminal summary header (cost number is the headline, grade is parenthetical/advisory; hotspots framed as relative contributors, rendered BEFORE the bottleneck list), yaml/json exports include the scores, **1.0 back-compat** (no header, no `scores` export key). Also covers `Connectivity` struct: parse four-field block (`forward`/`reverse`/`scored_nodes`/`total_nodes`), `forward_pct_display` formatting (0..1 ratio → "0.3%", nil → "N/A"), `scored_ratio` ("5/1672"), terminal banner format, nil back-compat on 1.0/1.1/1.2 docs. |
| `spec/report/metric_kernel_consistency_spec.rb` | **4c metric-kernel lockstep**: client constant == engine `METRIC_KEYS` (set + order). Unaffected by scores (scores are separate from the 8 per-node metrics). |
| `spec/fixtures/sample/` | Tiny Rails-shaped fixture (`OrdersController`, `Billing::Invoice < ApplicationRecord`) exercising each resolver tier. |
| `spec/fixtures/report/` | `findings_fixture.yml` (1.0, no scores; deliberately-absurd `fan_in=42` to prove no-recompute) + `id_map_fixture.yml` (with a deliberately-absent `ext_` id to prove graceful de-anon) + `findings_v11_fixture.yml` (1.1 with both dimensions scored + hotspots) + `findings_v11_forward_na_fixture.yml` (1.1 with forward N/A) + `graph_fixture.yml` (opaque graph.yml edge list — nodes/edges incl. the absent `ext_` sink — for the dot/html graph render, now includes a `db_op` node with `sink_open: true/false` for W4 assertions) + `findings_v13_connectivity_fixture.yml` (1.3 with four-field `scores.connectivity` block — forward/reverse 0.003, scored_nodes 5, total_nodes 1672; no `verdict`). |

Run all: `bundle exec rspec` (225 examples; prefix with `RBENV_VERSION=ruby-3.4.2` if your shell
doesn't auto-switch from `.ruby-version`).

## Adding a new language adapter

Summary: add `Collect::Adapters::<Lang>Adapter < Adapter` returning an `AdapterResult` of `Raw*` value
objects, and add one `Registry::ADAPTERS` entry. The Anonymizer/Emitter/Reporter need **no changes**. Full
walkthrough: [`.claude/docs/adapter-extension.md`](.claude/docs/adapter-extension.md).
