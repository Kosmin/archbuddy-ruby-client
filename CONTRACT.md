# CONTRACT.md — data contracts

This repo has **no database**. This file is the **contract/schema** doc: it documents the **data contracts** —
what the **collector EMITS** (`graph.yml` + `id-map.yml`) and what **`report` CONSUMES** (`findings.yml`).

All three shapes are owned canonically by the **engine Contract** (`ArchitectureAuditor::Contract`). The
authoritative JSON schemas live in the sibling repo at
`../architecture-auditor/lib/architecture_auditor/contract/schemas/{graph,findings}.v1.schema.json`.
This doc summarizes those shapes for quick reference — **the schemas are the source of truth; do not let
this doc drift from them.** Graph schema is `"1.3"` (`Contract::GRAPH_SCHEMA_VERSION`); findings schema
is `"1.6"` (`Contract::FINDINGS_SCHEMA_VERSION`, v0.11). All bumps are MINOR / additive; old 1.0–1.5 docs
still validate. `Contract::SUPPORTED_VERSIONS = %w[1.0 1.1 1.2 1.3 1.4 1.5 1.6]` (explicit retain-list,
never derived — new versions are APPENDED to the literal). Verified against the live sibling engine (0.8.0).

Opaque-id format everywhere: `^(n_|ext_|cls_)[0-9a-f]{12}([0-9a-f]{4})?$` (minted only by `Contract::Ids`).

---

## EMITTED by `collect` → `graph.yml` (shareable, OPAQUE, zero app semantics)

Validated against `graph.v1.schema.json` **before writing** (D37). Produced by `Collect::Anonymizer`.

```yaml
schema_version: "1.3"
generator:               # all 3 keys required
  tool: "archbuddy 0.10.0"     # "archbuddy #{Archbuddy::VERSION}"
  adapter: "ruby"
  capture: "static"      # static capture ⇒ all timing fields below are null (D4)
nodes:                    # array; each node:
  - id: "n_…"             # node_id; kind external ⇒ "ext_…"
    kind: "function"      # enum: function | endpoint | db_op | external
    class_id: "cls_…"     # nullable; ref to the owning class rollup (cls_ lives ONLY in id-map, D42)
    loc: null             # ALWAYS null — real file:line would leak app semantics (D7/D16/D18)
    self_time_ms: null    # static ⇒ null
    total_time_ms: null   # static ⇒ null
    count: null           # static ⇒ null
    branches: 1           # OPTIONAL (graph 1.1+); integer ≥ 1; b(n)=Π(arm-counts) per method body
                          # V7/P5 de-idiomatized: only business control flow (if/unless/case/while/
                          # until/for) multiplies into branches; idioms (&&/||, &., ||=/&&=, rescue,
                          # pattern-match) are counted in decisions only.
    decisions: 0          # OPTIONAL (graph 1.1+); integer ≥ 0; raw decision-point count (all constructs)
                          # NOTE (v0.6/L3): the client NO LONGER emits `sink_open`. A db_op is now a
                          # plain COST-1 terminal — no write-specificity / customizable-sink proxy. The
                          # field stays DECLARED-but-optional in the engine graph schema (a node
                          # OMITTING it validates), so old graphs WITH it still load.
    entrypoint_kind: "controllers"  # OPTIONAL (graph 1.3, v0.10 A1); fixed-vocab ingress category
                          # (grape|routed|controllers|jobs|rake|middleware|script|top_level|pattern)
                          # on entrypoint nodes only. Emitted BEHIND THE ACCEPTANCE GATE (below).
    terminal_kind: "http" # OPTIONAL (graph 1.3, v0.10 CR-5); fixed-vocab egress category
                          # (http|gem|queue) — the CATEGORY word, never the target — on per-target
                          # external sinks only (v0.11 E1); the generic <external> sink and every
                          # non-sink node omit it. Same acceptance gate.
edges:                    # array; each edge:
  - from: "n_…"
    to: "n_…"             # unresolved calls point at the shared generic ext_ sink; v0.11 E1: a call
                          # the EgressProbe categorized points at its per-target sub-sink
                          # (<external:{category}:{const_fq}> in the id-map — one ext_ node per
                          # DISTINCT provable [category, target] pair; graph stays 1.3, node
                          # multiplicity only)
    calls: 1              # integer >= 1 (duplicate (from,to) pairs collapsed)
    count: null
    self_time_ms: null
entrypoints:              # array of node_id (may be EMPTY → M3 warning)
  - "n_…"
```

### v0.10: `entrypoint_kind` / `terminal_kind` — the schema-acceptance gate

The two graph-1.3 category fields are emitted **only when the INSTALLED engine schema accepts them**:
`Collect::Anonymizer.graph_schema_accepts_entrypoint_kind?` / `…_terminal_kind?` validate a minimal
probe graph (`ENTRYPOINT_KIND_PROBE_GRAPH` / `TERMINAL_KIND_PROBE_GRAPH`, memoized per process) via
`Contract::Validator.valid?`. A 1.2 engine's node schema is `additionalProperties: false`, so an
undeclared key would FAIL D37 validation, not be ignored — the gate auto-disables the stamp against
an old engine with no version sniffing. **Both fields always ride the id-map descriptor regardless**
(the aggregate writer reads categories from there, schema-independent). Category words are fixed
vocab, never app symbols — safe on the opaque graph (I8).

### v0.11: E1 per-target egress sub-sinks — graph stays 1.3 (node multiplicity only)

The collapsed per-category sinks (`<external:http|gem|queue>`, v0.10) are split into one sub-sink per
DISTINCT provable `[category, target]` pair: symbol `<external:{category}:{const_fq}>` (const_fq
whitespace-collapsed, leading-`::` stripped), `terminal_kind` still the CATEGORY word. No schema
change, no new node keys — the graph gains ext_ NODES, nothing else. The SECRET boundary (L13): sink
symbols can carry app constants (job classes in the queue/gem buckets), so they are
id-map/committed-cache citizens, never graph.yml citizens. Effects on the committed cache: the first
`collect` after v0.11 rewrites committed real-name fragment edges whose `to` was `<external:{cat}>`
to `<external:{cat}:{target}>` (VALUE churn only — shape unchanged); the committed aggregate `egress`
counts block (`{total, count, by_category{http,gem,queue,generic}}`) is byte-identical (no
`by_target`); a no-egress repo sees a zero-line diff.

### v0.6.0: variable-receiver type inference (L1) + sink-cost revert (L3) — graph stays 1.2

Two behavioural changes; **no schema shape change** (graph stays `"1.2"`, findings stays `"1.3"`):

- **Variable-receiver type inference (L1):** the resolver gains a tier **R4.5** between R4
  (const-receiver) and R5 (probes). It resolves variable / ivar / memoized-accessor /
  inline-`Const.new` receivers to REAL `Const#method` edges via the EXISTING `SymbolTable#method?`
  gate — conservative, intra-procedural (intra-method locals + same-class ivars + memoized
  accessors + inline `Const.new` chains), **never a whitelist**. NEVER-FABRICATE: an edge is emitted
  ONLY when the method provably exists; otherwise the call declines to `<external>`. AR receivers
  (`x = User.new; x.where`) mirror R4's AR branch → a `db_op` node, not a fabricated method edge.
- **Sink-cost revert (L3):** the client **stops emitting `sink_open`** and removes the
  `AR_FIELD_WRITE` write-specificity machinery (`Vocab::AR_WRITE`/`AR_DESTROY`/`AR_READ`/
  `AR_FIELD_WRITE`/`ar_op_kind`/`ar_field_write?`) and the `DbOpSpec` module. A `db_op` is now a
  plain COST-1 terminal. The engine stops CONSUMING the `×U` multiplier and keeps `sink_open`
  **DECLARED-but-optional** in the graph schema, so the change is behavioural, not schema-breaking
  (graph stays 1.2; old 1.2 graphs carrying `sink_open` still validate). `db_op` stays a valid
  `kind` enum value — the resolver still classifies AR calls as `db_op` (free provenance, unscored).

### v0.4.0 (W4): de-idiomatized `branches` + `sink_open` (graph 1.2)

The collector emits graph schema `"1.2"` (additive MINOR; old 1.0/1.1 graphs still validate).
Two behavioural changes, zero schema-incompatible edits:

- **De-idiomatized `b(n)` (V7/P5):** `BranchCounter` now splits business vs idiom visitors. Only
  business control flow (`if`/`unless`/`case`/`while`/`until`/`for`) multiplies into `branches`.
  Idioms (`&&`/`||`, `&.`, `||=`/`&&=`, `rescue`, pattern-match predicates) are counted in
  `decisions` only. A `decoded_token`-class method with 30 idiom branches + 1 `unless` previously
  emitted `branches=32`; now it emits `branches=2`. `decisions` still counts every construct
  (diagnostic breadth unchanged).
- **`sink_open` (V4/P4):** a new OPTIONAL boolean emitted ONLY on `db_op` nodes. The collector
  classifies each AR call's op-kind (read/write/destroy via `Vocab::AR_WRITE`/`AR_DESTROY`) and
  write specificity (symbol-keyed literal hash / bare symbols = specific; variable/splat/
  string-SQL = open_ended, the SAFE default). The least-specific call-site result wins per
  `Class.method` accumulator entry. `sink_open: true` on the graph node is the engine's INPUT to
  charge ×U (undifferentiated fan-in via `in_degree`); no `sink_op`/`sink_fields` graph field is
  ever emitted. Non-db_op nodes have no `sink_*` key.

### v0.3.0 (W1–W3): framework probes — NO schema change at that step

v0.3.0 added a **pluggable framework-probe seam** to the collector. The graph and findings schemas were
**UNCHANGED** by those waves: graph stayed `"1.1"`, findings stayed `"1.2"`, `SUPPORTED_VERSIONS`
untouched, engine not re-released at that step.

Why no schema change was needed:

- **Edges are framework-neutral topology.** Every probe-resolved call is emitted as a plain `(from, to)`
  edge — the same shape as any other edge. The framework that wired it is not recorded in graph.yml.
- **The `endpoint` node kind pre-exists.** `kind: "endpoint"` is already in the schema enum and was
  already emitted for Rails controller actions (`ruby_adapter.rb` — `endpoint?`, consumed in
  `add_method_nodes`). v0.3.0 additionally mints it for Grape endpoint handler blocks. No new kind
  value is introduced. (v0.10 keeps the 4-kind vocab closed too: category egress sinks are
  `kind: "external"` with `terminal_kind`, NOT a 5th kind.)
- **Provenance is diagnostics-only.** Per-probe-name edge counts (`probe_edges: { grape: N, ... }`)
  ride `AdapterResult#diagnostics` and the CLI's stderr note only — they are NEVER serialized into
  `graph.yml`. The schema's `additionalProperties: false` constraint remains satisfied with zero edits.

**Invariants for graph.yml (asserted by `spec/collect/collector_spec.rb`):**
- Zero real paths/symbols anywhere — only opaque ids, kinds, `class_id` refs, null/numeric weights.
- Every node's `loc` is `null`; all timing fields `null` (static).
- No `cls_` id ever appears as a `nodes[]` entry (D42) — only as a `class_id` reference.
- Every id validates via `Contract::Ids.valid?`.

## EMITTED by `collect` → `id-map.yml` (SECRET, local-only, GITIGNORED)

The de-anonymization key. Carries real `file:line:symbol`. **Never committed, never sent externally**
(D16/D21). Not schema-validated (it is not a contract document); it is the private inverse of the graph.
Only `collect` produces it; only `report` reads it. **The engine's `analyze` never receives it.**

```yaml
ids:
  "n_…":                  # one entry per opaque node id minted into the graph
    file: "app/models/user.rb"     # repo-relative; null for the external sinks
    line: 12                       # 1-based; null for the external sinks
    symbol: "User#save"            # fully-qualified real symbol; egress sinks are
                                   # "<external>" / "<external:{category}:{const_fq}>" (v0.11 E1;
                                   # category ∈ http|gem|queue). Sink symbols — which may carry app
                                   # constants (e.g. job classes in the queue/gem buckets) — are
                                   # id-map/committed-cache citizens, never graph.yml citizens (L13)
    kind: "function"               # function | endpoint | db_op | external
    class_id: "cls_…"              # owning class rollup id, or null
    entrypoint_kind: null          # v0.10 (A1): ingress category string, or null for
                                   # non-entrypoints / category-unknown entrypoints.
                                   # ALWAYS present here (unlike graph.yml — no gate).
    terminal_kind: null            # v0.10 (CR-5): egress category (http|gem|queue) —
                                   # non-null ONLY on per-target external sinks (v0.11 E1).
  "cls_…":                # one entry per class rollup (D42) — id-map ONLY
    file: "app/models/user.rb"
    line: 1
    symbol: "User"
    kind: "class_rollup"
    class_id: null       # (cls_ entries carry NO entrypoint_kind/terminal_kind keys)
```

`gitignore-before-secret`: `Collect::Emitter` refuses to write this unless the path is gitignored. The
repo `.gitignore` already covers `id-map.yml`, `*.id-map.yml`, `/out/`, plus `report.yml/json`, `*.dot`,
`*.report.html`, `graph.yml`, `findings.yml`. (The vendored `lib/.../assets/cytoscape.min.js` library is
intentionally NOT ignored — a runtime dependency, not a secret.)

---

## CONSUMED by `report` ← `findings.yml` (OPAQUE, produced by the engine's `analyze`)

`report` reads this + the secret id-map. Owned by `findings.v1.schema.json`. Keyed by **opaque** node ids;
`report` never validates it (the engine does) — it joins it against the id-map. Metrics + `clutter_score`
are copied **verbatim** (D17); the reporter never recomputes.

```yaml
schema_version: "1.6"
generator: { tool, adapter, capture }     # same shape as graph
nodes:                                      # map: opaque_id => entry
  "n_…":
    metrics:                                # EXACTLY these 8 keys, this order (D39)
      path_length:  <number|null>
      fan_in:       <number|null>
      fan_out:      <number|null>
      centrality:   <number|null>
      instability:  <number|null>
      in_cycle:     <number|null>
      orphan:       <number|null>
      dead:         <number|null>
    clutter_score: <number >= 0>            # verbatim; ranking key
findings:                                   # array; EXACTLY 7 types (D38), oneOf:
  - { type: high_fan_in|high_fan_out|high_centrality|orphan|dead,  severity: low|medium|high|critical,  node: "n_…" }   # node-type: node, NO path
  - { type: long_path|cycle,                                       severity: …,                          path: ["n_…", …] }  # path-type: path, NO node
```

**Metric-kernel lockstep (D43/D39):** the 8 metric keys above == `Archbuddy::Report::METRIC_KEYS_FOR_DISPLAY`
== `ArchitectureAuditor::Analyze::METRIC_KEYS`. Asserted by `spec/report/metric_kernel_consistency_spec.rb`.
Changing the metric set requires changing **both repos** together.

### Optional `scores` block (findings 1.1–1.6 — additive, back-compat)

`findings.yml` **MAY** carry an OPTIONAL top-level `scores` block (added in schema 1.1, extended in 1.2
[raw_value/overflow], 1.3 [connectivity], 1.4 [multiplexer_proxies], 1.5 [median +
forward_discoverability_by_category], 1.6 [the four business-metric blocks + per-dimension
capped_fraction/median_grade — see below]; an older doc without the newer fields still validates and
`report` still works unchanged). The block is **owned canonically by the engine** — `findings.v1.schema.json`
`#/properties/scores` → `#/definitions/dimension_score` is the source of truth; this is a quick-reference
summary only. It carries two **project-level** dimension scores plus the optional sibling objects:

```yaml
scores:                                # OPTIONAL; absent in 1.0 docs
  reverse_traceability:                # "can you tell where code is USED?" — always computable
    score: 27.1                        # UNBOUNDED cost (≥ 0, no maximum), OR null when undeterminable
    grade: "B"                         # A|B|C|D|F|N/A (ceiling bands — PROVISIONAL, see N3)
    hotspots: ["n_…", "ext_…", …]      # OPAQUE node-ids, worst-first by this dimension's cost
    raw_value: 27.1                    # OPTIONAL (1.2+); raw per-dimension cost before any clamping
    overflow: false                    # OPTIONAL (1.2+); true when the route product overflowed Float
  forward_discoverability:             # "can you FOLLOW where execution goes?"
    score: null                        # null/"N/A" when collection found NO entrypoints (N1/M3)
    grade: "N/A"
    hotspots: []
    median: null                       # OPTIONAL (1.5+, v0.10 W6): the per-entrypoint cost MEDIAN
                                       # beside the mean (`score`) — the antidote to an
                                       # outlier-dominated mean. Read nil-tolerantly.
    capped_fraction: null              # OPTIONAL (1.6+, v0.11): share of routes at the publish cap
                                       # (0..1, 4 dp; null when score is null; > 0 ⟺ overflow).
                                       # Any dimension_score (incl. per-category groups) may carry it.
    median_grade: "N/A"                # OPTIONAL (1.6+, v0.11): the frozen ceiling bands re-applied
                                       # to the published MEDIAN value (A|B|C|D|F|N/A) — the
                                       # secondary letter behind "F (median: A)". ENGINE-emitted;
                                       # the client never grades.
  forward_discoverability_by_category: # OPTIONAL (1.5+, v0.10 W6): the engine's per-category
    controllers:                       # ingress-cost lens — one dimension_score per
      score: 3.0                       # entrypoint_kind group (keys are the ENGINE's grouping of
      median: 3.0                      # the client-stamped categories; nil-stamped entrypoints
      grade: "B"                       # bucket under the engine's "uncategorized"). The client
      hotspots: []                     # compacts it VERBATIM into the committed aggregate's
                                       # entrypoints.by_category_cost {cat=>{mean,median,grade}}.
  multiplexer_proxies: []              # OPTIONAL (1.4+): the worst-first smell list (see R1)
  connectivity:                        # OPTIONAL (1.3+); absent in 1.0/1.1/1.2 docs
    forward: 0.003                     # |reachable-from-entrypoints| / |total nodes| (0..1 ratio or null)
    reverse: 0.003                     # |connected-to-a-db_op-sink| / |total nodes| (0..1 ratio or null)
    scored_nodes: 5                    # integer ≥ 0: nodes that contributed to the score mean
    total_nodes: 1672                  # integer ≥ 1: total graph nodes (excluding <external>)
  blast_radius:                        # OPTIONAL (1.6+, v0.11 — "how many use cases can one change break?")
    max: 70                            # stats over REACHED non-external nodes; blast(n) = count of
    p90: 3.0                           # entrypoints whose forward-reachable set contains n
    median: 1.0
    mean: 1.68
    reached_nodes: 5502                # nodes reachable from any use case (excl. external exit nodes)
    total_nodes: 17546                 # non-external node count
    total_entrypoints: 1611            # the q3 denominator — the client NEVER derives it (M5)
    pct_use_cases_hit_by_worst: 0.0435
    worst:                             # ranked use_cases_affected DESC, node-id ASC tiebreak
      - { node: "n_…", use_cases_affected: 70, added_coupling: null }  # opaque ids; coupling only
                                       # for multiplexer proxies — reach and coupling are displayed
                                       # SEPARATELY, the product is never persisted (R7)
                                       # N/A form (zero entrypoints / externals-only reach): null
                                       # stats + worst: [] + reached_nodes: 0 — never fabricated
  forward_depth:                       # OPTIONAL (1.6+): hops per entrypoint (exp(fd_log), floored ≥ 1)
    mean: 2.83
    median: 2.0
    count: 1611
    by_category: { controllers: { mean: 2.9, median: 2.0, count: 900 } }  # optional, keyed by entrypoint_kind
  reverse_depth:                       # OPTIONAL (1.6+): path_length + 1 per reached non-external node
    mean: 3.41                         # NO by_category (nodes carry no entrypoint_kind — R9)
    median: 3.0
    count: 5502
  branching_factor:                    # OPTIONAL (1.6+): per-route b̄ = exp(bp_log / max(1, hops))
    mean: 2649.6                       # UNGRADED (a hop DENSITY, never a "score"); reads RAW bp_log
    median: 2.416                      # so it does not saturate at the cap — read MEDIAN-FIRST (the
    count: 1611                        # mean is degenerate-dominated by hops=1 routes)
    by_category: { controllers: { mean: 2.5, median: 2.4, count: 900 } }  # optional, forward-only
```

**v0.10 read posture:** the client reads every 1.4/1.5 optional block NIL-TOLERANTLY and copies it
VERBATIM (D17 — mean = the dimension `score`, median its 1.5 sibling, `by_category_cost` compacted from
`forward_discoverability_by_category` with hotspots dropped). Absent blocks → null/{} in the committed
aggregate and no banner/line in the report — an honest absence, never a fabricated number.

**v0.11 read posture + reading conventions (findings 1.6, SERIALIZER v3):** the four 1.6 blocks are
folded into the committed aggregate VERBATIM under the **SAME FLAT SPELLINGS** (`blast_radius`,
`forward_depth`, `reverse_depth`, `branching_factor` — never a grouped `depth` key), with the blast
`worst` list de-anonymized at write to `{symbol, use_cases_affected, added_coupling}`; `headline_scores`
widens to `{grade, score, median, median_grade?, capped_fraction?}` (fixing the v2 median gap) and the
`egress` block gains the 1.5 cost lens (`{mean, median, capped_fraction, by_category_cost}` — per-EXIT-POINT
averages now that E1 splits the sinks; the counts sub-block is untouched). Conventions when reading any
of these numbers: a **capped mean is a LOWER BOUND** (censored data — annotate "N% of routes at cap"
whenever `capped_fraction > 0`; at `capped_fraction ≥ 0.5` even the median is "at cap"); **`median_grade`**
is the frozen ceilings re-applied to the median value (a secondary letter — "F (median: A)" is the
outlier-dominance signature); **b̄ is a DENSITY, not a score** (ungraded, median-first). A 1.5-or-older
doc simply has no 1.6 blocks → no v3 blocks, no Business Impact questions beyond Q1/Q2 — omission, never
fabrication. **Downgrade caveat:** an old (pre-0.10.0) client's `collect` over a v3 cache rewrites the
aggregate back to its own v2 shape — acceptable and probed; the next `analyze` with a current client
restores v3. The E1 fragment-edge symbol churn and the v2→v3 stamp churn ship as ONE committed-cache
churn event per audited repo.

**Score semantics (findings 1.3):** `score` is the **arithmetic mean over controller entrypoints** of each
entrypoint's branch-product round-trip cost to a `db_op` terminal — an **unbounded architectural cost**
(≥ 0, no upper limit), lower is better. The score is computed in **real space** (no logarithm, no K
multiplier, no `/100` normalization). Alternative reaching paths into a node are combined with **MAX**
(fan-in into a plain function adds nothing; only undifferentiated fan-in into an open-ended write sink
is charged ×U via `in_degree`). The grade uses **inverted ceiling bands** (lower cost = better grade,
PROVISIONAL — confirmed/tuned empirically, may be refined):

| Grade | Cost ceiling |
|-------|-------------|
| A     | < 10         |
| B     | < 30         |
| C     | < 60         |
| D     | < 125        |
| F     | ≥ 125        |

`report` **consumes** this block (R-8): `score`/`grade` are project-level and copied **verbatim** (D17 — the
client NEVER recomputes them); `hotspots` are **OPAQUE** ids de-anonymized locally via the SAME secret id-map
as everything else (graceful `<external …>` for missing/`ext_` ids). The optional `raw_value`/`overflow`
fields are passed through verbatim if present. A hotspot is just the worst-RANKED node for that dimension —
on a low-cost project the top hotspots may be benign; the **cost number is the headline** and the grade is
a tentative secondary indicator. A null/`N/A` forward score renders honestly as `N/A` with a one-line reason
(`no entrypoints — re-collect with --entrypoints all_public`), never a fabricated number (N1).

**Connectivity object (findings 1.3, CR-1):** the OPTIONAL `scores.connectivity` block carries four
engine-computed fields — `{forward, reverse, scored_nodes, total_nodes}` — with `additionalProperties:false`.
There is **no `verdict` field** (the client decides no band; D17). The reporter renders the four fields
verbatim as a one-line banner ABOVE the dimension rows: `Connectivity: 5/1672 nodes scored (0.3%)`.
Absent on 1.0/1.1/1.2 docs → no banner rendered (back-compat). A nil `forward` ratio renders as "N/A"
(e.g. when there are no entrypoints — N1). `sink_open` (graph 1.2 — DECLARED-but-optional, NO LONGER
emitted by the client as of v0.6/L3), `connectivity` (findings 1.3), and the 1.6 business-metric
blocks (`blast_radius`/`forward_depth`/`reverse_depth`/`branching_factor` + `capped_fraction`/
`median_grade`) are graph INPUT / project-summary fields, NOT metric-kernel keys; `METRIC_KEYS` stays at 8.

---

## PRODUCED by `report` (de-anonymized output — SECRET/local-only)

Rendered by the Formatter strategy; all carry real symbols → gitignored, never shared.

| `--format` | Output | Shape |
|------------|--------|-------|
| `terminal` (default) | stdout text | v0.11: a `Business Impact` PEER section FIRST (between the header and the scores) when any of the five questions is answerable — rendered from the ONE shared `Report::BusinessImpact` presenter, omitted entirely otherwise (v1/v2 docs byte-identical to v0.10). Then, when findings carry `scores` (1.1) OR the committed aggregate carries the counter blocks (SERIALIZER v2+): an `Architecture Scores` summary header — the connectivity banner + the three v0.10 counter banners (`Entrypoints:`/`Egress:`/`Dynamic dispatch:`, each nil-guarded; entrypoints appends engine mean/median + a per-category cost line when published), then each dimension's `score/grade` + framing question (the headline), then its de-anonymized hotspots as "top contributors to this dimension (worst-first)" with real symbol + `file:line` + driving metric(s), or `N/A` + reason. Then ranked bottlenecks: symbol, `file:line`, `clutter_score`, 8-metric breakdown, finding explanations (with real `A → B` chains), class rollups. |
| `yaml` | `report.yml` | `{ generator, bottlenecks[ {id,symbol,file,line,kind,class_id,resolved,clutter_score,metrics{8},findings[]} ], class_rollups[ {class_id,symbol,file,line,resolved,clutter_score,member_count} ] }` via `StructuredExport`; plus, when present (1.1), `scores{ <dimension> => {score,grade,question,na_reason?,hotspots[ {symbol,file,line,resolved,metrics} ]} }` (de-anonymized; the key is omitted entirely for a 1.0 doc). |
| `json` | `report.json` | Same structured shape (incl. the optional de-anonymized `scores`), `JSON.pretty_generate`. |
| `dot` | `*.dot` | Graphviz digraph with de-anonymized labels. **Requires `--graph graph.yml`** (edge list source). |
| `html` | `report.html` | A SINGLE, fully self-contained, fully **OFFLINE** Cytoscape.js dashboard: a `<section id="business-impact">` card row (v0.11 — same shared presenter, all dynamic text escaped, absent when no questions) + dimension-score grade cards + an interactive call graph + the ranked bottleneck table. Cytoscape.js + all CSS/JS are **inlined** (zero external/CDN refs). Uses `--graph graph.yml` for the call graph (degrades to scores + table without it). De-anonymized real symbols → **SECRET/local-only**; redirect to a gitignored path (e.g. `out/report.html`). |

Unresolved ids (e.g. `ext_` sinks, ids absent from the id-map) render as graceful `<external …>`
placeholders (`resolved: false`) — never an error.
