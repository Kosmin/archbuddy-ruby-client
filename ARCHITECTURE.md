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
| `lib/archbuddy/version.rb` | `Archbuddy::VERSION` (`"0.7.0"`). |
| `lib/archbuddy/cli.rb` | `Archbuddy::CLI` — `Dry::CLI::Registry` registering the **four** v0.8 commands `collect` + `analyze` + `report` + `reset` (D48). |
| `lib/archbuddy/cli/collect.rb` | `collect` command — see [CLI](#cli). Sole producer of id-map.yml; writes the committed cache. |
| `lib/archbuddy/cli/analyze.rb` | `analyze` command — engine analyze + de-anon-at-write the committed cache. See [CLI](#cli). |
| `lib/archbuddy/cli/report.rb` | `report` command — see [CLI](#cli). Reads the committed cache (or LEGACY id-map path). |
| `lib/archbuddy/cli/reset.rb` | `reset` command — full re-collect + analyze from scratch. See [CLI](#cli). |
| `lib/archbuddy/cache.rb` | `Archbuddy::Cache` — the committed incremental `.archbuddy/` cache subsystem (v0.8). See [Concern 3](#concern-3--committed-incremental-cache-libarchbuddycache). |
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
| `fragment.rb` (`Collect::Fragment`) | **The per-file CACHE UNIT of an incremental collect (v0.8, C1-1).** `Struct(rel_file, content_hash, parsed_value)` — one source file's Prism AST + the SHA-256 of the exact bytes Prism parsed (the C2 change-detection trigger, **authoritative, NOT mtime**). `parsed_value` is transient (the global `assemble` consumes it; NEVER serialized/committed). Splitting `collect` into per-file parse (cacheable) + a global `assemble` over all fragments is a **pure byte-parity refactor**: `assemble(all fragments)` reconstructs the exact inputs the old whole-project pipeline consumed, in the same deterministic sorted file order (C2 reuse==recompute invariant). |
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
| `ruby_adapter.rb` (`Adapters::RubyAdapter`) | Orchestrates Ruby capture (K-6). **As of v0.8 (C1-1) collect is TWO phases:** a **per-file parse** step (the only per-file work — cacheable → a `Collect::Fragment`) + a **GLOBAL `assemble`** over all fragments (definitions/resolution/edge-building are cross-file). `collect(mode: :full, base_ref: nil)`: enumerate `.rb` → build a `Fragment` per file (`collect_file_fragment`: read bytes → `Cache::ChangeDetector.content_hash` → parse via `Prism.parse` OR reuse the cached parse from the machine-local speed cache) → `assemble(fragments)`. `assemble` runs the identical Pass 1 (`DefinitionPass`) into a shared `SymbolTable` → Pass 1b `RouteCatalogue` (seeds routed actions) → Pass 2 (`ResolutionPass`) with config-selected probes into a shared `Accumulator` → assemble `Raw*` (method nodes with `class_id` refs, synthesized `db_op` nodes, ONE shared `external` sink at `EXTERNAL_SINK_SYMBOL = "<external>"`), edges (collapsing duplicate `(from,to)` pairs into `calls >= 1`), and entrypoints. **`mode: :incremental`** (`collect_incremental`, C2) reuses each UNCHANGED file's parse from `Cache::Reader` (content-hash + collector-version gated) and re-parses only changed files; `assemble` is UNCHANGED and always sees the WHOLE tree (a stale/empty cache degrades to a full parse, never a partial graph). `base_ref` is an optional git fast-path pre-filter (`ChangeDetector.candidate_files`) — narrows which files to re-hash, never authoritative. `endpoint?` = Grape endpoint handler block (`method_entry.endpoint`) OR non-singleton method on a controller class. Reports `meta_sites_skipped` and `probe_edges` as diagnostics. **No id minting here.** |
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
| `scores.rb` (`Scores`, `Scores::DimensionScore/Hotspot`, `Scores::Connectivity`) | **R-8: the de-anonymized presentation model for findings.yml's OPTIONAL project-level `scores` block (findings 1.3, additive).** `Scores.from_findings(doc, resolver)` parses the two dimensions (**reverse_traceability** always-computable + **forward_discoverability** which is **N/A when there are no entrypoints**), copies each dimension's `score`/`grade` **verbatim** (D17 — never recomputed; they come straight from findings.yml), and de-anonymizes each dimension's **worst-first OPAQUE `hotspots`** via the SAME `IdMapResolver` (graceful `<external …>` for missing/`ext_` ids). Each `Hotspot` carries the dimension's **driving-metric values** (`DRIVING_METRICS`: reverse ⇒ fan_in/centrality/in_cycle; forward ⇒ path_length/fan_out) pulled verbatim from the per-node `nodes.<id>.metrics`. **Returns `nil` for a 1.0 doc with no scores block** (back-compat). `DimensionScore#display_score` formats the verbatim cost as `"%.1f"` (unbounded, no `/100` suffix, real-space arithmetic mean — no logarithm); `nil` renders as `"N/A"`. The cost number is the headline; the grade is a tentative secondary indicator. `Scores::Connectivity` (V8, findings 1.3) is a parallel struct (`{forward, reverse, scored_nodes, total_nodes}` — CR-1 four-field shape, no `verdict`) parsed by `connectivity_from_findings`; nil-tolerant for 1.0/1.1/1.2 docs (no banner). `forward`/`reverse` are engine-emitted 0..1 ratios formatted by the client as `"0.3%"` or `"N/A"` (D17 — no recompute). **R1 (v0.8):** `Scores::MultiplexerProxy` + `multiplexer_proxies_from_findings` / `multiplexer_proxies_from_committed` surface the v0.7 `multiplexer_proxy` smell (findings 1.4 `scores.multiplexer_proxies`, worst-first) VERBATIM. Accepts BOTH the committed real-name `{symbol, added_coupling}` shape (no id-map) and the legacy opaque `{node, …}` shape (resolved). Returns `nil` for no scores block (section omitted), `[]` for scored-but-no-proxy (honest `(none)` note — never fabricated); ids-only degrades to a blank coupling. **v0.10 (A1):** `EntrypointCount`/`Egress`/`DynamicDispatch` + `entrypoints_from_aggregate`/`egress_from_aggregate`/`dynamic_dispatch_from_aggregate` parse the three OPTIONAL committed counter blocks (SERIALIZER v2) exactly like `connectivity_from_findings` — nil when absent (v1 aggregate, no banner). `by_category_display` elides zero buckets ("none" when all-zero); `DynamicDispatch#ratio` is the committed `coverage_ratio` (visible share of dispatch), `ratio_display` "N/A" on nil. |
| `reconnect.rb` (`Reconnect`, `IdMapResolver`) | **R-2 join engine.** `from_files` loads findings.yml + the SECRET id-map.yml via `Serializer`. De-anonymizes at the three contract join sites: `findings.nodes.<id>`, each `findings[].node`, each `findings[].path[]` element. Metrics/score copied **verbatim** (D17). `IdMapResolver.resolve(id)` → `Location`; ids absent from the map (e.g. `ext_` sinks, unknown ids) resolve to a graceful placeholder and **never raise**. Path findings attach to the first node on their path. Also builds the optional `Scores` model (R-8) and exposes it on `Result#scores` (`nil` for a 1.0 doc). Parses the optional `scores.connectivity` block (findings 1.3) and exposes it on `Result#connectivity` (`nil` for 1.0/1.1/1.2 docs — no resolver needed, counts/ratios only, no opaque ids). **`from_cache` (v0.9 W2)** reads the COMMITTED real-name cache with NO id-map AND (via `Cache::DetailTree#reassemble`) builds a real-name node/edge `Result#graph` + real-name clutter `Result#bottlenecks` (from the committed `multiplexer_proxies`, `clutter_score = added_coupling`), flagging `Result#real_name?`. `IdentityResolver.resolve(id)` → an identity `Location` (symbol == id, resolved) for that path — no id-map, no `<external …>` placeholder (the writer never emits an external node). |
| `ranker.rb` (`Ranker`) | **R-3.** `ranked(top:)` sorts bottlenecks by `clutter_score` desc, deterministic tiebreak by opaque id (nil scores last). `class_rollups(top:)` groups by `class_id`, **sums** members' verbatim scores (a presentation aggregate, not recomputation), de-anonymizes the `cls_` id (D9). Never recomputes a node metric. |
| `explanation.rb` (`Explanation`) | **R-4 (D19).** `TABLE` maps all 7 finding types → plain-English "why is this clutter" along two axes: **forward discoverability** vs **reverse traceability**. `describe(finding)` renders a one-line, value-aware explanation. |

### Formatters (`report/formatters/`)

| File / Class | Format | Responsibility |
|--------------|--------|----------------|
| `formatter.rb` (`Formatter`, `RenderContext`) | — | **R-6 strategy base + open/closed `FORMATS` registry.** `register(name, klass)` / `for(name)`. Receives an already-de-anonymized, already-ranked `RenderContext(ranked, class_rollups, generator, graph, resolver, scores, connectivity)`; makes ZERO analytic decisions. `scores` is the optional R-8 dimension-scores model (`nil` for a 1.0 doc). `connectivity` is the optional V8 `Scores::Connectivity` struct (`nil` for 1.0/1.1/1.2 docs — keyword_init, nil-default, backward-compatible). Eager-requires the five built-ins so registration happens on load. |
| `terminal_formatter.rb` (`TerminalFormatter`) | `terminal` (default) | **Connectivity banner ABOVE dimension rows** (V8, findings 1.3): when `context.connectivity` is present, prepends a one-line `Connectivity: N/total nodes scored (P%)` banner above the dimension summary rows (nil → empty array → no banner, back-compat). Then **R-8 summary header** (when `context.scores` present): an eslint/rubocop-style `Architecture Scores` block that **LEADS with each dimension's verbatim cost + grade** (e.g. `27.1  (B)` — the cost number is the headline, the grade is tentative/advisory, real-space arithmetic mean) + framing question, then lists that dimension's de-anonymized hotspots as **"top contributors to this dimension (worst-ranked first)"** (relative, not "these are bugs") with real symbol + `file:line` + driving metric(s); an `N/A` dimension renders the reason (`no entrypoints — re-collect with --entrypoints all_public`) instead of a number. Then per bottleneck: real symbol, `file:line`, `clutter_score`, the **full 8-metric breakdown**, de-anonymized finding explanations (incl. `long_path`/`cycle` as real ordered chains `A → B`), and a class-rollups section. All values verbatim (D17 — no recompute, client only formats engine-emitted figures). **Output carries real symbols → SECRET/local-only.** **v0.10 (W4):** three counter banners (`Entrypoints:` / `Egress:` / `Dynamic dispatch:`) render below connectivity, each nil-guarded (absent block → no line, byte-identical back-compat); the scores-section gate is RELAXED to also fire on a collect-only v2 aggregate (counter blocks present, no engine scores — the dimension loops tolerate nil scores). |
| `structured_export.rb` (`StructuredExport`) | — | Shared builder turning a `RenderContext` → plain-data Hash (bottlenecks + class_rollups + the optional **R-8 `scores`** block with de-anonymized hotspots; the `scores` key is omitted entirely for a 1.0 doc). Used by yaml + json. Verbatim. |
| `yaml_formatter.rb` (`YamlFormatter`) | `yaml` | `Serializer.dump` of the structured export (deterministic, diffable). **SECRET/local-only.** |
| `json_formatter.rb` (`JsonFormatter`) | `json` | `JSON.pretty_generate` of the structured export. **SECRET/local-only.** |
| `dot_formatter.rb` (`DotFormatter`) | `dot` | Optional, non-contract graphviz. **Requires `--graph` (edge list lives in graph.yml, not findings.yml)**; without it returns a clear unavailable message. Node labels de-anonymized via the resolver. **SECRET/local-only.** |
| `html_formatter.rb` (`HtmlFormatter`) | `html` | A SINGLE, fully self-contained, fully **OFFLINE** Cytoscape.js dashboard string: dimension-score grade cards (R-8) + an interactive call graph + the ranked bottleneck table. **Inlines** the vendored Cytoscape.js library + all CSS/JS — ZERO external/CDN references (asserted by spec). On the DEFAULT from-cache path the nodes/edges come from the committed REAL-NAME detail tree (`Result#graph`, reassembled by `Cache::DetailTree`) so the graph shows real method names with NO id-map; on the legacy path it uses `--graph`/`graph.yml` de-anonymized via the id-map. Either way, **without a graph the scores header + table still render** (visible notice, no graph). The v0.8.1 `graphable_nodes`/`rendered_node_ids` external-exclusion (drops `kind:"external"` / `ext_` nodes + their dangling edges) + `--max-nodes` cap (top-N by clutter) are reused unchanged. Embeds an inlined data JSON (de-anonymized nodes/edges + verbatim bottlenecks/scores via `StructuredExport`) consumed by a small vanilla-JS init script. Built-in layouts only (cose/grid/breadthfirst/circle). **Graph readability styling (v0.8.1 report-polish):** edge width is **log-scaled and capped** (`min(3.5, 0.8 + log2(1+calls)*0.5)` px) so a hot sink reached by hundreds of calls no longer renders as a giant wedge while the call-count signal survives; **unresolved `<external>` sink nodes are de-emphasized** (`node[kind="external"]`: opacity 0.35, 10×10, dashed muted-grey border, tiny label) so the app boundary recedes and the real call structure reads clearly. The **ranked table is client-side sortable** (click any header — clutter/metrics/symbol/file/kind; toggles asc/desc with a ▲/▼ indicator; null/`N/A` sort last) and **paginated** (25/50/100/All, default 25; Prev/Next + "showing X–Y of Z"); rows are server-rendered (escaped) and only reordered/shown-hidden, so escaping never regresses, and sort/paginate work even in the no-graph path. The **call graph has a minimum clutter-score filter** (range slider + synced number input) that hides below-threshold nodes + their incident edges with a live "showing N of M nodes" count, defaulting to a focused view of the worst offenders (~top 120 by clutter; debounced re-layout). All sorting/filtering is presentation over the already-emitted findings — ZERO recompute. Carries real symbols → **SECRET/local-only.** **v0.10 (W4):** three banner divs (`.entrypoints`/`.egress`/`.dynamic-dispatch`) join connectivity in ONE header interpolation (absent blocks add no markup — byte-stable v1 header); `scores_header_html`'s gate is RELAXED to render on a collect-only v2 aggregate (banners with empty cards). |
| `assets/cytoscape.min.js` + `assets/CYTOSCAPE_LICENSE` | — | Vendored, version-pinned (3.30.3) Cytoscape.js minified library (MIT) read at render time and inlined by `HtmlFormatter` to make the report offline. A **runtime dependency, not a secret** → committed (unlike generated reports). License/provenance in `CYTOSCAPE_LICENSE`. |

---

## Concern 3 — Committed Incremental Cache (`lib/archbuddy/cache/`)

**The v0.8 headline.** `Archbuddy::Cache` turns the auditor from a stateless full-recompute into a
**committed, incrementally-updated metadata cache** — an audited repo commits a small, reviewable,
**REAL-NAME** cache so a PR's architecture-score delta shows in its diff (the lockfile / `.rubocop_todo.yml`
baseline / Jest `__snapshots__` idiom). This module is **entirely language-neutral**: it consumes only the
opaque graph + SECRET id-map (+ optional findings) — it never parses source. See the audited-repo guide
[`docs/COMMITTING_ARCHBUDDY.md`](docs/COMMITTING_ARCHBUDDY.md).

### The three-layer `.archbuddy/` layout

| Layer | Path | Committed? | Keyed by | What |
|-------|------|-----------|----------|------|
| ROOT aggregate | `archbuddy-findings.json` (repo root) | **COMMITTED** | real names | Compact: headline dimension `scores` + the `multiplexer_proxy` list + `sources` **POINTERS** into the detail tree (payload NOT inlined → stays small). |
| Detail tree | `.archbuddy/<mirrored-source-path>` | **COMMITTED** | real names | Real-name, **LINE-FREE** per-file fragments mirroring the source layout. **Adaptively sharded** (C4). |
| Speed cache | `.archbuddy/.cache/` | **GITIGNORED** | `sha1(rel_file)` | Machine-local raw-parse blobs (marshaled Prism AST), collector-version stamped. Re-derivable. |
| SECRET map | `.archbuddy/id-map.yml` | **GITIGNORED** | opaque ids | The real↔opaque map — the only de-anonymizer. Never committed. |

**DE-ANONYMIZED-AT-WRITE (CR-1):** the committed layers hold the audited repo's OWN real class/method
names + file paths (that's your own code, fine to commit); only the id-map + de-anonymized `report.*` stay
secret. So `report` reads the committed cache **directly, with NO id-map** — a fresh clone works.

**LINE-FREE committed values (C1 line-stability invariant):** `line` is display-only and lives ONLY in the
gitignored id-map, resolved at RENDER — so a pure line move produces ZERO committed diff. Symbol-keyed ids:
line is dropped from *identity* (the id key is `rel_file\x00fq_symbol`-shaped), display-only.

### Files

| File / Class | Responsibility |
|--------------|----------------|
| `cache.rb` (`Cache`) | Requires the six pieces; namespace doc for the layout. |
| `cache/canonical_json.rb` (`CanonicalJson`) | **Byte-STABLE JSON (P2/L5)** so the committed layer diffs cleanly + passes `--check`. `dump(value)`: object keys sorted recursively at EVERY level, floats rounded to `FLOAT_PRECISION = 6`, exactly one trailing `\n`. **Array ORDER is the CALLER's job** (the Writer canonicalizes arrays before calling). `round_float` raises on NaN/Infinity (never portable). |
| `cache/layout.rb` (`Layout`) | **Path-mapping + adaptive-shard decision (P7/C4).** Constants: `ROOT_AGGREGATE = "archbuddy-findings.json"`, `DETAIL_DIR = ".archbuddy"`, `SECRET_ID_MAP`, `SPEED_CACHE = ".archbuddy/.cache"`, `SHARD_BYTES = 64 * 1024`, `MODE_SINGLE/PER_CLASS/PER_METHOD`. `single_path(rel_file)` → `.archbuddy/<path>.json`; `shard_dir` → `.archbuddy/<path>/`. `shard_mode_for`/`over_threshold?` are **pure functions of the serialized fragment bytesize** (deterministic for `--check`): < 64 KiB → one JSON; at/over → a per-class directory (then per-method for a single class still over). |
| `cache/writer.rb` (`Writer`, `Writer::Deanonymizer`) | **C1-2: writes the committed cache by transcoding the opaque interchange at WRITE time.** `write(graph:, id_map:, findings: nil, diagnostics: nil)`: de-anonymize nodes/edges/entrypoints via the inner `Deanonymizer` (id-map lookup; graceful `<external>` for unmapped/`ext_`), group nodes by owning file (external sink excluded — no path), build a real-name **line-free** fragment per file (`nodes` sorted by symbol + `entrypoint` flag; `edges` sorted by `[from,to,calls]` — the C3 provably-total tiebreaker), shard by size, and write the compact ROOT aggregate (pointers + `headline_scores` + `deanon_proxies` worst-first VERBATIM). `SERIALIZER_VERSION = 2` (bump on shape change; folded into the ChangeDetector hash). **v0.10 (W3, SERIALIZER v2):** the root aggregate ALWAYS carries the three committed counter blocks — `entrypoints` {total, count, by_category (closed key set seeded to 0), mean, median (engine-published, null until analyze)}, `egress` {total, count, by_category over http/gem/queue/generic} (read from `diagnostics[:egress_counts]`; graph-fold generic fallback), `dynamic_dispatch` {dynamic_sites, resolved_sites, total_call_sites, coverage_ratio = 1 − dynamic/total, NULL on zero denominator}. A diagnostics-free write (analyze path) carries the prior committed egress/dynamic_dispatch blocks forward VERBATIM; fragment nodes carry `entrypoint_kind` beside the `entrypoint` boolean. **`preserve_existing_scores`:** a collect-only write (findings nil) carries forward a prior analyze's committed `scores`/`multiplexer_proxies` so an incremental re-collect refreshes only structural pointers and never clobbers the score block. |
| `cache/reader.rb` (`Reader`) | **C2 machine-local speed cache** (`.archbuddy/.cache/`, gitignored). `reuse(rel_file, content_hash)` returns a cached parsed AST IFF the blob exists AND its `content_hash` matches AND its `COLLECTOR_VERSION` matches (else `nil` → re-parse). `store` persists a marshaled `{collector_version, content_hash, parsed_value}` blob at `.archbuddy/.cache/<sha1(rel_file)>.bin`. `COLLECTOR_VERSION = 1` — bump on any parse/derivation change (Prism upgrade, pass change) so hash-matching OLD blobs are NOT reused. NEVER raises on a corrupt/legacy blob (treated as a miss → re-parse; fail-safe). |
| `cache/detail_tree.rb` (`DetailTree`) | **v0.9 W2: read-side of the committed detail tree.** `reassemble(aggregate:)` walks the aggregate's `sources` pointers and unions every committed fragment (SINGLE `<path>.json` OR every `*.json` under a sharded `<path>/` directory) back into ONE real-name `{nodes, edges}` graph — node id == symbol, nodes de-duped by symbol, edges de-duped by `[from,to,calls]`, deterministically ordered. **Reassembles edges ACROSS shards** (a per-class/per-method split file) — the C4 gotcha. Fail-safe: a missing/corrupt fragment is skipped (partial graph, never a crash). This is what lets the DEFAULT report render a real-name graph with NO id-map. |
| `cache/change_detector.rb` (`ChangeDetector`) | **C2 change detection — content-hash trigger, NOT mtime.** `self.content_hash(source)` = `SHA256("#{COLLECTOR_VERSION}\x00#{source}")` — folds the collector version in so a tool upgrade forces a full re-parse; correct under rebase/squash/clone/dirty-tree. `candidate_files(enumerated, base_ref:)` is an OPTIONAL git fast-path PRE-FILTER (`git diff --name-only <base>...HEAD ∩ enumerated`) to shrink the candidate set in CI; git-unavailable/bad-ref falls back to ALL files; **never authoritative** (the content hash always confirms). |
| `cache/checker.rb` (`Checker`) | **R3-1 CI STALENESS GATE (`collect --check`).** `check(&regenerate)`: (1) `NO_BASELINE (2)` — loud, never a vacuous pass — if the root aggregate is absent; (2) call the injected `regenerate` (a full re-collect + de-anon-at-write); (3) `git diff --exit-code` over the COMMITTED pathspec (root aggregate + `.archbuddy/` detail tree, **excluding** the gitignored id-map + `.cache/**`), plus `git status --porcelain` for untracked new fragments → `DRIFT (1)` on any diff, else `CLEAN (0)`. **NEVER reads the SECRET id-map** (the committed cache is real-name and readable without it) — works in a fresh CI checkout. `regenerate` is injected so the Checker owns ONLY the baseline + diff policy, not the collect pipeline (SoC). |

### The de-anon-at-write flow (who transcodes)

```
collect ──▶ graph.yml + id-map.yml(SECRET) ──▶ Cache::Writer.write(graph, id_map)          ──▶ COMMITTED structural cache (no scores yet)
analyze ──▶ engine findings.yml (opaque)   ──▶ Cache::Writer.write(graph, id_map, findings) ──▶ COMMITTED cache + headline scores + multiplexer_proxy
report  ──▶ Reconnect.from_cache(archbuddy-findings.json + DetailTree.reassemble)  (NO id-map) ──▶ ranked report + REAL-NAME graph
```

The engine stays YAML-native + opaque; only the CLIENT holds the id-map, so the de-anon-at-write transcode
is client-owned (`cli/analyze.rb` reads the SECRET id-map HERE, never commits it).

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
present): `Reconnect.from_cache(aggregate_path:, id_map_path: nil, project_root:)` reads the COMMITTED,
real-name aggregate **directly, with NO id-map** — a fresh clone works. **As of v0.8 (v0.9 in-flight) the
default report also builds its graph from the committed REAL-NAME detail tree:** `from_cache` calls
`Cache::DetailTree#reassemble` to union the sharded `.archbuddy/<mirrored-source>[.json|/…]` fragments back
into one real-name node/edge `graph` (node id == symbol) on `Result#graph`, and turns the committed
`multiplexer_proxies` into real-name `Model::Bottleneck`s (`clutter_score = added_coupling`, VERBATIM) on
`Result#bottlenecks` so the graph's node cap ranks by REAL clutter. `Result#real_name?` is true; the CLI
then wires an `IdentityResolver` (`resolve(id)` → identity Location, symbol == id) and passes
`Result#graph` as the render graph — so the default interactive graph shows **real method names, externals
excluded, clutter-ranked, with no id-map** (the v0.9 headline). **LEGACY** (explicit findings arg, or no
committed cache): `Reconnect.from_files` joins an opaque `findings.yml` against the SECRET id-map at read
time, and the graph comes from `--graph`/`graph.yml` de-anonymized via `IdMapResolver` (unchanged
back-compat). Then it resolves the formatter (`Formatter.for`, `exit 1` on unknown), builds a `Ranker`,
assembles a `RenderContext` (carrying `multiplexer_proxies`), and prints `formatter.render`. Every formatter
renders the **`multiplexer_proxy` smell** (findings 1.4) as an additive section, VERBATIM worst-first:
absent scores block → section omitted; scored-but-empty → an honest `(none)` note (never a fabricated
verdict).

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
| `spec/collect/type_inference_spec.rb` | **R4.5 typed-receiver tier (L1/v0.6)**: local / ivar / memoized-accessor / inline-`Const.new` receiver types resolved via `ctx.type_scope` + `table.method?`; NEVER-FABRICATE decline path. |
| `spec/collect/call_dispatch_spec.rb` | Call-site dispatch / resolver-tier routing coverage (edge vs drop vs db_op vs external). |
| `spec/collect/fragment_split_spec.rb` | **C1-1 per-file `Fragment`**: content-hash identity; parse-vs-reuse byte-parity; `assemble(fragments)` reconstructs the whole-project inputs deterministically. |
| `spec/cache/canonical_json_spec.rb` | **P2/L5 `CanonicalJson`**: recursively-sorted object keys, fixed float precision, single trailing newline, NaN/Infinity raise; byte-stable across runs. |
| `spec/cache/writer_spec.rb` | **C1-2 `Writer`**: de-anon-at-write; real-name line-free fragments; canonical array order (nodes by symbol, edges by `[from,to,calls]`); compact aggregate (pointers + headline scores + `deanon_proxies` verbatim worst-first). |
| `spec/cache/adaptive_shard_spec.rb` | **C4 adaptive sharding**: `< SHARD_BYTES` → single JSON; at/over → per-class dir; a god-class still over → per-method; pure size function → deterministic. |
| `spec/cache/incremental_spec.rb` | **C2 incremental collect**: content-hash (NOT mtime) change detection; unchanged-file parse reuse from the speed cache; `--base-ref` git fast-path pre-filter; stale/empty cache degrades to a full parse (never partial). |
| `spec/cache/determinism_spec.rb` | Two runs over the same tree → byte-identical committed cache (the `--check`-clean invariant). |
| `spec/cache/bounded_diff_spec.rb` | A small source change produces a surgical (bounded) committed diff, not a whole-tree churn. |
| `spec/cache/blank_line_clean_spec.rb` | **C1 line-stability**: a pure line move / blank-line edit produces ZERO committed diff (line is display-only, in the gitignored id-map). |
| `spec/cache/check_gate_spec.rb` | **R3-1 `Checker` / `collect --check`**: exit 0 clean, 1 on drift, 2 (loud) no-baseline; never reads the SECRET id-map; excludes gitignored `.cache/`. |
| `spec/cache/secret_gitignore_spec.rb` | The SECRET id-map + `.cache/` stay gitignored while the committed real-name cache stays stageable. |
| `spec/cache/reset_spec.rb` | **`reset`**: full re-collect (ignores the speed cache) + analyze; committed aggregate re-transcoded with fresh scores + `multiplexer_proxy`. |
| `spec/report/reporter_spec.rb` | Ranking, `--top`, three-site de-anon, graceful missing ids, class rollups, **verbatim metrics**, terminal/yaml/json/dot formatters, all 7 explanation types, formatter registry. |
| `spec/report/from_cache_spec.rb` | **R2-1 committed read path**: `Reconnect.from_cache` reads `archbuddy-findings.json` **with NO id-map** (fresh-clone); LEGACY `from_files` fallback on explicit findings / no committed cache. **v0.9 W2:** the default report renders **REAL method names** in the graph nodes (no opaque `n_`/`ext_`), excludes the `<external>` sink + its dangling edges, ranks the `--max-nodes` cap by REAL committed clutter (top proxy first), and `from_cache` carries a real-name `graph` + clutter `bottlenecks` with identity `resolve`; the legacy id-map path still de-anonymizes (back-compat). |
| `spec/cache/detail_tree_spec.rb` | **v0.9 W2 `Cache::DetailTree`**: reassembles SINGLE + sharded (per-class) fragments into one real-name node/edge graph; **unions edges ACROSS shards** (cross-class edge survives the split); empty graph when there is no aggregate/tree. |
| `spec/cache/write_target_spec.rb` | **v0.9 W1 write-target**: from a CWD DIFFERENT than the target, `collect <target>` / `reset <target>` write the committed cache into the TARGET and leave the CWD clean; `collect .` still writes into the current directory (default-workspace behavior preserved). |
| `spec/report/cli_analyze_spec.rb` | **`analyze`**: requires `graph.yml` (else `exit 1` + collect hint); shells the engine; de-anon-at-write folds scores + smell into the committed aggregate; reads the SECRET id-map but never commits it. |
| `spec/report/multiplexer_proxy_spec.rb` | **R1 (v0.8) `multiplexer_proxy` smell** surfaced VERBATIM worst-first across formatters; committed real-name `{symbol, added_coupling}` shape + legacy opaque shape; absent → section omitted; scored-but-empty → honest `(none)`. |
| `spec/report/audited_gitignore_template_spec.rb` | The shipped `templates/audited-repo.gitignore` ignores the secret/interchange paths but tracks `archbuddy-findings.json` + the `.archbuddy/<source>` detail tree. |
| `spec/packaging_spec.rb` | Gem packaging / installability (gemspec files, exe wiring). |
| `spec/report/cli_report_default_dir_spec.rb` | **`.archbuddy/` default workspace for `report`**: no-args reads `.archbuddy/{findings,id-map}.yml`; missing default findings/id-map → friendly `exit 1` error naming the producing command (no stack trace); explicit args override the workspace defaults. |
| `spec/report/html_formatter_spec.rb` | **Offline `html` formatter**: registry, valid-ish self-contained HTML (cy container + inlined cytoscape lib >200KB + inlined data JSON), **ZERO external resource refs** (the offline guarantee), both dimension scores+grades, de-anonymized real symbols + file:line, **verbatim** bottleneck table, graph nodes/edges in the data JSON, hotspot ids per dimension, graceful `<external>` graph node, **no-graph degradation** (scores+table+notice), forward **N/A**, **1.0 back-compat** (no scores header), **table sort/pagination controls** (sortable headers w/ keys+handler, default clutter desc, page-size 25/50/100/All, Prev/Next, null-last sort), the **graph min-score filter** (slider+number, focused-default heuristic, incident-edge hide, debounced re-layout, graceful empty-threshold), and **V8 connectivity banner** (present and positioned BEFORE `.cards` div when findings carry connectivity block; HTML-escaped; absent on 1.1 doc — back-compat). Both `RenderContext.new` call sites updated. Headless-verified with Playwright. |
| `spec/report/scores_spec.rb` | **R-8 project dimension scores + V8 connectivity**: parse + verbatim unbounded cost/grade (real-space arithmetic mean, no K multiplier), worst-first hotspot de-anon with driving metrics, graceful `<external>` for absent hotspot ids, **N/A forward** (null score → reason, not a number), terminal summary header (cost number is the headline, grade is parenthetical/advisory; hotspots framed as relative contributors, rendered BEFORE the bottleneck list), yaml/json exports include the scores, **1.0 back-compat** (no header, no `scores` export key). Also covers `Connectivity` struct: parse four-field block (`forward`/`reverse`/`scored_nodes`/`total_nodes`), `forward_pct_display` formatting (0..1 ratio → "0.3%", nil → "N/A"), `scored_ratio` ("5/1672"), terminal banner format, nil back-compat on 1.0/1.1/1.2 docs. |
| `spec/report/metric_kernel_consistency_spec.rb` | **4c metric-kernel lockstep**: client constant == engine `METRIC_KEYS` (set + order). Unaffected by scores (scores are separate from the 8 per-node metrics). |
| `spec/fixtures/sample/` | Tiny Rails-shaped fixture (`OrdersController`, `Billing::Invoice < ApplicationRecord`) exercising each resolver tier. |
| `spec/fixtures/report/` | `findings_fixture.yml` (1.0, no scores; deliberately-absurd `fan_in=42` to prove no-recompute) + `id_map_fixture.yml` (with a deliberately-absent `ext_` id to prove graceful de-anon) + `findings_v11_fixture.yml` (1.1 with both dimensions scored + hotspots) + `findings_v11_forward_na_fixture.yml` (1.1 with forward N/A) + `graph_fixture.yml` (opaque graph.yml edge list — nodes/edges incl. the absent `ext_` sink — for the dot/html graph render; the `db_op` node carries **no `sink_open`** — L3/v0.6 revert, a db_op is a plain COST-1 terminal, the field stays DECLARED-but-optional in the schema) + `findings_v13_connectivity_fixture.yml` (1.3, four-field `scores.connectivity` block — forward/reverse 0.003, scored_nodes 5, total_nodes 1672; no `verdict`) + `findings_v14_multiplexer_fixture.yml` (1.4 with a `scores.multiplexer_proxies` worst-first list) + `findings_v14_empty_smell_fixture.yml` (1.4 with an empty proxy list → the honest `(none)` note). |

Run all: `bundle exec rspec` (292 examples across the collect/cache/report suites; prefix with
`RBENV_VERSION=ruby-3.4.2` if your shell doesn't auto-switch from `.ruby-version`). Requires the engine
gem installed (`bundle install` — see the cross-repo doc; the metric-kernel spec loads the live engine
`METRIC_KEYS`).

## Adding a language adapter

The `Adapter` (`collect/adapter.rb`) is the **only** language-specific seam. **Everything else is
language-neutral** and works purely in opaque-id space after the trust boundary:

| Language-AGNOSTIC (no changes to add a language) | Ruby-SPECIFIC (the whole adapter) |
|--------------------------------------------------|-----------------------------------|
| `Anonymizer` (the single mint), `Emitter`, id-map | `RubyAdapter` + its Prism passes: `DefinitionPass`, `RouteCatalogue`, `ResolutionPass`, `SymbolTable`, the tiered `RubyResolver` (R0–R9), `Vocab`, `EntrypointDetector`, the probes (`GrapeProbe`/`DispatchProbe`), `GrapeDsl` |
| `Cache` (canonical_json/layout/writer/reader/change_detector/checker), the committed-cache flow, `Fragment` | The parser choice (Prism) + all parse/resolution heuristics |
| The `Report` (reconnect/ranker/formatters), the engine `analyze` | |

**The adapter CONTRACT** = produce the opaque `graph.yml` (nodes with `branches`/`decisions` + `kind` ∈
`function|endpoint|db_op|external`, edges, entrypoints) + the id-map. Everything downstream is shared and
does not care which language produced the graph — including the engine (**zero engine changes** to score a
non-Ruby codebase; see the engine's "Scoring a non-Ruby codebase" doc).

Summary to add a language: implement `Collect::Adapters::<Lang>Adapter < Adapter` returning an
`AdapterResult(nodes, edges, entrypoints, diagnostics)` of `Raw*` value objects **in real-symbol space**
(never mint ids), and add one `Registry::ADAPTERS` entry. Full walkthrough — including a **concrete
JavaScript/TypeScript + React/React-Native guide** —
[`.claude/docs/adapter-extension.md`](.claude/docs/adapter-extension.md).
