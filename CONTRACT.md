# CONTRACT.md — data contracts

This repo has **no database**. This file is the **contract/schema** doc: it documents the **data contracts** —
what the **collector EMITS** (`graph.yml` + `id-map.yml`) and what **`report` CONSUMES** (`findings.yml`).

All three shapes are owned canonically by the **engine Contract** (`ArchitectureAuditor::Contract`). The
authoritative JSON schemas live in the sibling repo at
`../architecture-auditor/lib/architecture_auditor/contract/schemas/{graph,findings}.v1.schema.json`.
This doc summarizes those shapes for quick reference — **the schemas are the source of truth; do not let
this doc drift from them.** Graph schema is `"1.1"` (`Contract::GRAPH_SCHEMA_VERSION`); findings schema
is `"1.2"` (`Contract::FINDINGS_SCHEMA_VERSION`). Both are MINOR / additive; old 1.0 docs still validate.

Opaque-id format everywhere: `^(n_|ext_|cls_)[0-9a-f]{12}([0-9a-f]{4})?$` (minted only by `Contract::Ids`).

---

## EMITTED by `collect` → `graph.yml` (shareable, OPAQUE, zero app semantics)

Validated against `graph.v1.schema.json` **before writing** (D37). Produced by `Collect::Anonymizer`.

```yaml
schema_version: "1.1"
generator:               # all 3 keys required
  tool: "archbuddy 0.2.0"
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
    decisions: 0          # OPTIONAL (graph 1.1+); integer ≥ 0; raw decision-point count
edges:                    # array; each edge:
  - from: "n_…"
    to: "n_…"             # unresolved calls all point at the single shared ext_ sink
    calls: 1              # integer >= 1 (duplicate (from,to) pairs collapsed)
    count: null
    self_time_ms: null
entrypoints:              # array of node_id (may be EMPTY → M3 warning)
  - "n_…"
```

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
    file: "app/models/user.rb"     # repo-relative; null for the external sink
    line: 12                       # 1-based; null for the external sink
    symbol: "User#save"            # fully-qualified real symbol
    kind: "function"               # function | endpoint | db_op | external
    class_id: "cls_…"              # owning class rollup id, or null
  "cls_…":                # one entry per class rollup (D42) — id-map ONLY
    file: "app/models/user.rb"
    line: 1
    symbol: "User"
    kind: "class_rollup"
    class_id: null
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
schema_version: "1.2"
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

### Optional `scores` block (findings 1.2 — additive, back-compat)

`findings.yml` **MAY** carry an OPTIONAL top-level `scores` block (added in schema 1.1, extended in 1.2; a
1.0 or 1.1 doc without the newer fields still validates and `report` still works unchanged). The block is
**owned canonically by the engine** — `findings.v1.schema.json` `#/properties/scores` →
`#/definitions/dimension_score` is the source of truth; this is a quick-reference summary only. It carries
two **project-level** dimension scores:

```yaml
scores:                                # OPTIONAL; absent in 1.0 docs
  reverse_traceability:                # "can you tell where code is USED?" — always computable
    score: 27.1                        # UNBOUNDED cost (≥ 0, no maximum), OR null when undeterminable
    grade: "B"                         # A|B|C|D|F|N/A (ceiling bands: A<10, B<30, C<50, D<80, F≥80)
    hotspots: ["n_…", "ext_…", …]      # OPAQUE node-ids, worst-first by this dimension's cost
    raw_value: 27.1                    # OPTIONAL (1.2+); raw per-dimension cost before any clamping
    overflow: false                    # OPTIONAL (1.2+); true when the route product overflowed Float
  forward_discoverability:             # "can you FOLLOW where execution goes?"
    score: null                        # null/"N/A" when collection found NO entrypoints (M3)
    grade: "N/A"
    hotspots: []
```

**Score semantics (findings 1.2):** `score` is an **unbounded architectural cost** (≥ 0, no upper limit) —
lower is better. The grade uses **inverted ceiling bands** (lower cost = better grade):

| Grade | Cost ceiling |
|-------|-------------|
| A     | < 10         |
| B     | < 30         |
| C     | < 50         |
| D     | < 80         |
| F     | ≥ 80         |

`report` **consumes** this block (R-8): `score`/`grade` are project-level and copied **verbatim** (D17 — the
client NEVER recomputes them); `hotspots` are **OPAQUE** ids de-anonymized locally via the SAME secret id-map
as everything else (graceful `<external …>` for missing/`ext_` ids). The optional `raw_value`/`overflow`
fields are passed through verbatim if present. A hotspot is just the worst-RANKED node for that dimension —
on a low-cost project the top hotspots may be benign; the **cost number is the headline** and the grade is
a tentative secondary indicator. A null/`N/A` forward score renders honestly as `N/A` with a one-line reason
(`no entrypoints — re-collect with --entrypoints all_public`), never a fabricated number.

---

## PRODUCED by `report` (de-anonymized output — SECRET/local-only)

Rendered by the Formatter strategy; all carry real symbols → gitignored, never shared.

| `--format` | Output | Shape |
|------------|--------|-------|
| `terminal` (default) | stdout text | When findings carry `scores` (1.1): an `Architecture Scores` summary header FIRST — each dimension's `score/grade` + framing question (the headline), then its de-anonymized hotspots as "top contributors to this dimension (worst-first)" with real symbol + `file:line` + driving metric(s), or `N/A` + reason. Then ranked bottlenecks: symbol, `file:line`, `clutter_score`, 8-metric breakdown, finding explanations (with real `A → B` chains), class rollups. |
| `yaml` | `report.yml` | `{ generator, bottlenecks[ {id,symbol,file,line,kind,class_id,resolved,clutter_score,metrics{8},findings[]} ], class_rollups[ {class_id,symbol,file,line,resolved,clutter_score,member_count} ] }` via `StructuredExport`; plus, when present (1.1), `scores{ <dimension> => {score,grade,question,na_reason?,hotspots[ {symbol,file,line,resolved,metrics} ]} }` (de-anonymized; the key is omitted entirely for a 1.0 doc). |
| `json` | `report.json` | Same structured shape (incl. the optional de-anonymized `scores`), `JSON.pretty_generate`. |
| `dot` | `*.dot` | Graphviz digraph with de-anonymized labels. **Requires `--graph graph.yml`** (edge list source). |
| `html` | `report.html` | A SINGLE, fully self-contained, fully **OFFLINE** Cytoscape.js dashboard: dimension-score grade cards + an interactive call graph + the ranked bottleneck table. Cytoscape.js + all CSS/JS are **inlined** (zero external/CDN refs). Uses `--graph graph.yml` for the call graph (degrades to scores + table without it). De-anonymized real symbols → **SECRET/local-only**; redirect to a gitignored path (e.g. `out/report.html`). |

Unresolved ids (e.g. `ext_` sinks, ids absent from the id-map) render as graceful `<external …>`
placeholders (`resolved: false`) — never an error.
