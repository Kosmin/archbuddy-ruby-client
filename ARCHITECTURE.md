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
| `Contract::SCHEMA_VERSION` | `"1.1"` (alias for `GRAPH_SCHEMA_VERSION`) stamped into emitted graphs | `Collect::Anonymizer` |
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
| `lib/archbuddy/version.rb` | `Archbuddy::VERSION` (`"0.2.0"`). |
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
| `anonymizer.rb` (`Anonymizer`) | **THE single trust boundary (K-5).** Converts `AdapterResult` → `Result(graph, id_map)`. The ONLY code that mints ids, solely via `Contract::Ids` (D25/D41). Produces: **(a)** the opaque graph hash — opaque node ids, contract `kind`s, `class_id` refs (`cls_`), all timing/`loc` fields **null** (D4/D7/D16/D18); **(b)** the secret id-map `{ "ids" => { opaque_id => {file,line,symbol,kind,class_id} } }`, including `kind:"class_rollup"` entries for every `cls_` id. `mint_node_id` uses `Ids.external_id` for `external` kind, else `Ids.node_id`. `class_id_for` memoizes the `cls_` mint and records it in the id-map but **never** adds it to `graph.nodes[]` (D42). `build_edges`/`build_entrypoints` map `real_key`s → opaque ids and drop dangling refs. |
| `emitter.rb` (`Emitter`) | **Validate → serialize → write (K-7).** `Validator.validate!(:graph, graph)` BEFORE writing (D37) — a non-conforming graph never reaches disk. Writes `graph.yml` then, **gitignore-before-secret**, verifies the id-map path is gitignored (`git check-ignore`, falling back to a filename check for `id-map.yml`/`*.id-map.yml`) and raises `SecretNotIgnoredError` rather than risk committing real symbols. Filenames: `graph.yml`, `id-map.yml`. |

### Ruby adapter (`collect/adapters/`)

| File / Class | Responsibility |
|--------------|----------------|
| `ruby_adapter.rb` (`Adapters::RubyAdapter`) | Orchestrates Ruby capture (K-6): enumerate `.rb` → parse all via `Prism.parse` → Pass 1 into a shared `SymbolTable` → Pass 2 into a shared `Accumulator` → assemble `Raw*` (method nodes with `class_id` refs, synthesized `db_op` nodes, ONE shared `external` sink at `EXTERNAL_SINK_SYMBOL = "<external>"`), edges (collapsing duplicate `(from,to)` pairs into `calls >= 1`), and entrypoints. `endpoint?` = non-singleton method on a controller class. Reports `meta_sites_skipped` as a diagnostic. **No id minting here.** |
| `ruby/file_enumerator.rb` (`FileEnumerator`) | Enumerates `.rb` files under a root honoring the ignore list, deterministically sorted (D30). Matches ignore patterns as contiguous path-segment subsequences. Raises `NoSourceError` if the path is missing, a non-`.rb` single file, or yields zero `.rb` files (fail loud, never emit a near-empty graph). |
| `ruby/definition_pass.rb` (`DefinitionPass < Prism::Visitor`) | **Pass 1 (D23).** Walks class/module/def building the `SymbolTable` (fq symbols, class superclass/controller?/AR? metadata). Tracks a namespace stack; classifies a `def` as singleton (`Foo.x`, receiver present) vs instance (`Foo#x`). Top-level defs are owner-less (bare name). |
| `ruby/symbol_table.rb` (`SymbolTable`, `ClassEntry`, `MethodEntry`) | Catalogue of discovered classes + methods (first definition wins, so reopened classes keep a stable def site). `ClassEntry#active_record?`/`#controller?` test superclass vocab + the `*Controller` name convention. `chain_any?` walks the superclass chain so subclasses of intermediate AR/controller bases still count (`active_record_class?`, `controller_class?`). |
| `ruby/resolution_pass.rb` (`ResolutionPass < Prism::Visitor`, `Accumulator`) | **Pass 2 (D23).** Walks call sites inside method bodies; tracks enclosing class fq + current method fq so the resolver gets class context and each edge has a real `from`. Routes each `Resolution` into the `Accumulator` (`add_method_edge` / `add_db_op_edge` / `add_external_edge` / `flag_metaprogramming`). Calls at class-body/top-level (no caller method) are NOT edges. |
| `ruby/resolver.rb` (`RubyResolver`, `CallContext`, `Resolution`) | **Pure tiered decision logic (D24).** See the [resolver tier table](.claude/docs/resolver.md). Decides `:edge` / `:drop` / `:metaprogramming` / `:external` (with `kind` `db_op`/`external`) WITHOUT touching the AST walk. **Never fabricates an edge.** |
| `ruby/vocab.rb` (`Vocab`) | Pure static vocabularies the resolver consults: `OPERATOR_DENY` (D36), `METAPROGRAMMING`, `ACTIVE_RECORD` query/persistence methods, `ACTIVE_RECORD_BASES`, `CONTROLLER_BASES`. |
| `ruby/entrypoint_detector.rb` (`EntrypointDetector`) | Pluggable entrypoint strategy (K-4/D4). `default` = controller actions + top-level defs; `controllers` = controller actions; `all_public` = every instance method; `none` = []. Optional regex patterns are additively unioned. May return `[]` (→ the M3 warning in the CLI). |

---

## Concern 2 — Reporter (`lib/archbuddy/report/`)

Pipeline: **Reconnect (join findings × secret id-map) → Ranker (order + class rollups) → Formatter (render).**
Everything is **verbatim** (D17) — no metric is ever recomputed.

| File / Class | Responsibility |
|--------------|----------------|
| `report.rb` (`Report`) | Defines `METRIC_KEYS_FOR_DISPLAY` — the 8 display metric keys as a **named constant** (D43), asserted == engine `Analyze::METRIC_KEYS`. Autoloads the model/reconnect/ranker/explanation/formatter + the five formatters (terminal/yaml/json/dot/html). |
| `model.rb` (`Model::Location/Bottleneck/Finding`) | Presentation-agnostic value objects (R-1). `Location` is a de-anonymized `{id,file,line,symbol,kind,class_id,resolved}` — `resolved?` false ⇒ a graceful `<external …>` placeholder (never raises). `Bottleneck` = one node + its verbatim 8 metrics + `clutter_score` + the findings touching it (`rollup?` true when `kind=="class_rollup"`). `Finding` = node-type (single `node`) or path-type (`path_refs` chain, `path?`/`chain`). |
| `scores.rb` (`Scores`, `Scores::DimensionScore/Hotspot`) | **R-8: the de-anonymized presentation model for findings.yml's OPTIONAL project-level `scores` block (findings 1.2, additive).** `Scores.from_findings(doc, resolver)` parses the two dimensions (**reverse_traceability** always-computable + **forward_discoverability** which is **N/A when there are no entrypoints**), copies each dimension's `score`/`grade` **verbatim** (D17 — never recomputed; they come straight from findings.yml), and de-anonymizes each dimension's **worst-first OPAQUE `hotspots`** via the SAME `IdMapResolver` (graceful `<external …>` for missing/`ext_` ids). Each `Hotspot` carries the dimension's **driving-metric values** (`DRIVING_METRICS`: reverse ⇒ fan_in/centrality/in_cycle; forward ⇒ path_length/fan_out) pulled verbatim from the per-node `nodes.<id>.metrics`. **Returns `nil` for a 1.0 doc with no scores block** (back-compat). `DimensionScore#display_score` formats the verbatim cost as `"%.1f"` (unbounded, no `/100` suffix); `nil` renders as `"N/A"`. The cost number is the headline; the grade is a tentative secondary indicator. |
| `reconnect.rb` (`Reconnect`, `IdMapResolver`) | **R-2 join engine.** `from_files` loads findings.yml + the SECRET id-map.yml via `Serializer`. De-anonymizes at the three contract join sites: `findings.nodes.<id>`, each `findings[].node`, each `findings[].path[]` element. Metrics/score copied **verbatim** (D17). `IdMapResolver.resolve(id)` → `Location`; ids absent from the map (e.g. `ext_` sinks, unknown ids) resolve to a graceful placeholder and **never raise**. Path findings attach to the first node on their path. Also builds the optional `Scores` model (R-8) and exposes it on `Result#scores` (`nil` for a 1.0 doc). |
| `ranker.rb` (`Ranker`) | **R-3.** `ranked(top:)` sorts bottlenecks by `clutter_score` desc, deterministic tiebreak by opaque id (nil scores last). `class_rollups(top:)` groups by `class_id`, **sums** members' verbatim scores (a presentation aggregate, not recomputation), de-anonymizes the `cls_` id (D9). Never recomputes a node metric. |
| `explanation.rb` (`Explanation`) | **R-4 (D19).** `TABLE` maps all 7 finding types → plain-English "why is this clutter" along two axes: **forward discoverability** vs **reverse traceability**. `describe(finding)` renders a one-line, value-aware explanation. |

### Formatters (`report/formatters/`)

| File / Class | Format | Responsibility |
|--------------|--------|----------------|
| `formatter.rb` (`Formatter`, `RenderContext`) | — | **R-6 strategy base + open/closed `FORMATS` registry.** `register(name, klass)` / `for(name)`. Receives an already-de-anonymized, already-ranked `RenderContext(ranked, class_rollups, generator, graph, resolver, scores)`; makes ZERO analytic decisions. `scores` is the optional R-8 dimension-scores model (`nil` for a 1.0 doc). Eager-requires the five built-ins so registration happens on load. |
| `terminal_formatter.rb` (`TerminalFormatter`) | `terminal` (default) | **R-8 summary header FIRST** (when `context.scores` present): an eslint/rubocop-style `Architecture Scores` block that **LEADS with each dimension's verbatim cost + grade** (e.g. `27.1  (B)` — the cost number is the headline, the grade is tentative/advisory) + framing question, then lists that dimension's de-anonymized hotspots as **"top contributors to this dimension (worst-ranked first)"** (relative, not "these are bugs") with real symbol + `file:line` + driving metric(s); an `N/A` dimension renders the reason (`no entrypoints — re-collect with --entrypoints all_public`) instead of a number. Then per bottleneck: real symbol, `file:line`, `clutter_score`, the **full 8-metric breakdown**, de-anonymized finding explanations (incl. `long_path`/`cycle` as real ordered chains `A → B`), and a class-rollups section. All values verbatim (D17 — no recompute). **Output carries real symbols → SECRET/local-only.** |
| `structured_export.rb` (`StructuredExport`) | — | Shared builder turning a `RenderContext` → plain-data Hash (bottlenecks + class_rollups + the optional **R-8 `scores`** block with de-anonymized hotspots; the `scores` key is omitted entirely for a 1.0 doc). Used by yaml + json. Verbatim. |
| `yaml_formatter.rb` (`YamlFormatter`) | `yaml` | `Serializer.dump` of the structured export (deterministic, diffable). **SECRET/local-only.** |
| `json_formatter.rb` (`JsonFormatter`) | `json` | `JSON.pretty_generate` of the structured export. **SECRET/local-only.** |
| `dot_formatter.rb` (`DotFormatter`) | `dot` | Optional, non-contract graphviz. **Requires `--graph` (edge list lives in graph.yml, not findings.yml)**; without it returns a clear unavailable message. Node labels de-anonymized via the resolver. **SECRET/local-only.** |
| `html_formatter.rb` (`HtmlFormatter`) | `html` | A SINGLE, fully self-contained, fully **OFFLINE** Cytoscape.js dashboard string: dimension-score grade cards (R-8) + an interactive call graph + the ranked bottleneck table. **Inlines** the vendored Cytoscape.js library + all CSS/JS — ZERO external/CDN references (asserted by spec). Like `dot` it uses `--graph` for the edge list; **without `--graph` the scores header + table still render** (visible notice, no graph). Embeds an inlined data JSON (de-anonymized nodes/edges + verbatim bottlenecks/scores via `StructuredExport`) consumed by a small vanilla-JS init script. Built-in layouts only (cose/grid/breadthfirst/circle). The **ranked table is client-side sortable** (click any header — clutter/metrics/symbol/file/kind; toggles asc/desc with a ▲/▼ indicator; null/`N/A` sort last) and **paginated** (25/50/100/All, default 25; Prev/Next + "showing X–Y of Z"); rows are server-rendered (escaped) and only reordered/shown-hidden, so escaping never regresses, and sort/paginate work even in the no-graph path. The **call graph has a minimum clutter-score filter** (range slider + synced number input) that hides below-threshold nodes + their incident edges with a live "showing N of M nodes" count, defaulting to a focused view of the worst offenders (~top 120 by clutter; debounced re-layout). All sorting/filtering is presentation over the already-emitted findings — ZERO recompute. Carries real symbols → **SECRET/local-only.** |
| `assets/cytoscape.min.js` + `assets/CYTOSCAPE_LICENSE` | — | Vendored, version-pinned (3.30.3) Cytoscape.js minified library (MIT) read at render time and inlined by `HtmlFormatter` to make the report offline. A **runtime dependency, not a secret** → committed (unlike generated reports). License/provenance in `CYTOSCAPE_LICENSE`. |

---

## CLI

`Archbuddy::CLI` (dry-cli, D48) registers exactly two commands. Both are the only readers/producers of the
secret id-map.

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

### `archbuddy report FINDINGS_YML` — `cli/report.rb`

The other id-map reader. Defaults all inputs into the shared `.archbuddy/` workspace, then resolves the
formatter (`Formatter.for`, `exit 1` on unknown), runs `Reconnect.from_files`, builds a `Ranker`, assembles a
`RenderContext`, and prints `formatter.render`. A missing default findings/id-map produces a friendly
`exit 1` error (`missing_input!`) naming the producing command — never a stack trace.

| Option | Default | Meaning |
|--------|---------|---------|
| `FINDINGS_YML` (arg) | `.archbuddy/findings.yml` | Opaque findings.yml from `analyze`. OPTIONAL — defaults into the workspace. |
| `--id-map` | `.archbuddy/id-map.yml` | The SECRET id-map.yml from `collect`. |
| `--format` | `terminal` | `terminal\|yaml\|json\|dot\|html`. |
| `--graph` | `.archbuddy/graph.yml` **if present** | Path to graph.yml; **required for `--format dot`**, used by `--format html` (html degrades gracefully without it). Default only applies when the workspace file exists, so terminal/yaml/json don't warn about a missing graph. |
| `--top` | — | Show only the top N bottlenecks. |

---

## Tests (`spec/`)

| Spec | Covers |
|------|--------|
| `spec/spec_helper.rb` | Loads `archbuddy` + `archbuddy/collect`; random order. |
| `spec/collect/collector_spec.rb` | End-to-end capture on `spec/fixtures/sample`: schema validity, id minting via Contract::Ids, the AR implicit-self `where` gotcha, operator drop, single external sink, resolvable cross-class edge, endpoint marking, `cls_` rollups in id-map only, **null `loc` / zero-leak guard**, null timing. |
| `spec/collect/emitter_spec.rb` | Validate-before-write + **gitignore-before-secret** guard. |
| `spec/collect/cli_collect_warning_spec.rb` | M3 zero-entrypoint stderr warning + that it stays out of graph/id-map. |
| `spec/collect/cli_collect_default_dir_spec.rb` | **`.archbuddy/` default workspace + secret safety**: no-`--out-dir` writes to `.archbuddy/` (non-git just writes; git repo auto-adds `.archbuddy/` to `.git/info/exclude`, id-map ends up `git check-ignore`d, idempotent on a 2nd run); an EXPLICIT non-ignored `--out-dir` still trips the Emitter refuse-guard and does NOT edit any ignore file. |
| `spec/collect/capture_diagnostics_spec.rb` | `NoSourceError` cases + metaprogramming diagnostic count staying out of graph data. |
| `spec/report/reporter_spec.rb` | Ranking, `--top`, three-site de-anon, graceful missing ids, class rollups, **verbatim metrics**, terminal/yaml/json/dot formatters, all 7 explanation types, formatter registry. |
| `spec/report/cli_report_default_dir_spec.rb` | **`.archbuddy/` default workspace for `report`**: no-args reads `.archbuddy/{findings,id-map}.yml`; missing default findings/id-map → friendly `exit 1` error naming the producing command (no stack trace); explicit args override the workspace defaults. |
| `spec/report/html_formatter_spec.rb` | **Offline `html` formatter**: registry, valid-ish self-contained HTML (cy container + inlined cytoscape lib >200KB + inlined data JSON), **ZERO external resource refs** (the offline guarantee), both dimension scores+grades, de-anonymized real symbols + file:line, **verbatim** bottleneck table, graph nodes/edges in the data JSON, hotspot ids per dimension, graceful `<external>` graph node, **no-graph degradation** (scores+table+notice), forward **N/A**, **1.0 back-compat** (no scores header), **table sort/pagination controls** (sortable headers w/ keys+handler, default clutter desc, page-size 25/50/100/All, Prev/Next, null-last sort), and the **graph min-score filter** (slider+number, focused-default heuristic, incident-edge hide, debounced re-layout, graceful empty-threshold). Headless-verified with Playwright. |
| `spec/report/scores_spec.rb` | **R-8 project dimension scores**: parse + verbatim unbounded cost/grade, worst-first hotspot de-anon with driving metrics, graceful `<external>` for absent hotspot ids, **N/A forward** (null score → reason, not a number), terminal summary header (cost number is the headline, grade is parenthetical/advisory; hotspots framed as relative contributors, rendered BEFORE the bottleneck list), yaml/json exports include the scores, and **1.0 back-compat** (no header, no `scores` export key). |
| `spec/report/metric_kernel_consistency_spec.rb` | **4c metric-kernel lockstep**: client constant == engine `METRIC_KEYS` (set + order). Unaffected by scores (scores are separate from the 8 per-node metrics). |
| `spec/fixtures/sample/` | Tiny Rails-shaped fixture (`OrdersController`, `Billing::Invoice < ApplicationRecord`) exercising each resolver tier. |
| `spec/fixtures/report/` | `findings_fixture.yml` (1.0, no scores; deliberately-absurd `fan_in=42` to prove no-recompute) + `id_map_fixture.yml` (with a deliberately-absent `ext_` id to prove graceful de-anon) + `findings_v11_fixture.yml` (1.1 with both dimensions scored + hotspots) + `findings_v11_forward_na_fixture.yml` (1.1 with forward N/A) + `graph_fixture.yml` (opaque graph.yml edge list — nodes/edges incl. the absent `ext_` sink — for the dot/html graph render). |

Run all: `bundle exec rspec` (91 examples; prefix with `RBENV_VERSION=ruby-3.4.2` if your shell
doesn't auto-switch from `.ruby-version`).

## Adding a new language adapter

Summary: add `Collect::Adapters::<Lang>Adapter < Adapter` returning an `AdapterResult` of `Raw*` value
objects, and add one `Registry::ADAPTERS` entry. The Anonymizer/Emitter/Reporter need **no changes**. Full
walkthrough: [`.claude/docs/adapter-extension.md`](.claude/docs/adapter-extension.md).
