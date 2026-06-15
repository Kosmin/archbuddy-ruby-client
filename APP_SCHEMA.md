# APP_SCHEMA.md — data contracts

This repo has **no database**. This file adapts the APP_SCHEMA role to document the **data contracts**:
what the **collector EMITS** (`graph.yml` + `id-map.yml`) and what **`report` CONSUMES** (`findings.yml`).

All three shapes are owned canonically by the **engine Contract** (`ArchitectureAuditor::Contract`). The
authoritative JSON schemas live in the sibling repo at
`../architecture-auditor/lib/architecture_auditor/contract/schemas/{graph,findings}.v1.schema.json`.
This doc summarizes those shapes for quick reference — **the schemas are the source of truth; do not let
this doc drift from them.** `schema_version` is `"1.0"` (`Contract::SCHEMA_VERSION`).

Opaque-id format everywhere: `^(n_|ext_|cls_)[0-9a-f]{12}([0-9a-f]{4})?$` (minted only by `Contract::Ids`).

---

## EMITTED by `collect` → `graph.yml` (shareable, OPAQUE, zero app semantics)

Validated against `graph.v1.schema.json` **before writing** (D37). Produced by `Collect::Anonymizer`.

```yaml
schema_version: "1.0"
generator:               # all 3 keys required
  tool: "archbuddy 0.1.0"
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
`graph.yml`, `findings.yml`.

---

## CONSUMED by `report` ← `findings.yml` (OPAQUE, produced by the engine's `analyze`)

`report` reads this + the secret id-map. Owned by `findings.v1.schema.json`. Keyed by **opaque** node ids;
`report` never validates it (the engine does) — it joins it against the id-map. Metrics + `clutter_score`
are copied **verbatim** (D17); the reporter never recomputes.

```yaml
schema_version: "1.0"
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

---

## PRODUCED by `report` (de-anonymized output — SECRET/local-only)

Rendered by the Formatter strategy; all carry real symbols → gitignored, never shared.

| `--format` | Output | Shape |
|------------|--------|-------|
| `terminal` (default) | stdout text | Ranked bottlenecks: symbol, `file:line`, `clutter_score`, 8-metric breakdown, finding explanations (with real `A → B` chains), class rollups. |
| `yaml` | `report.yml` | `{ generator, bottlenecks[ {id,symbol,file,line,kind,class_id,resolved,clutter_score,metrics{8},findings[]} ], class_rollups[ {class_id,symbol,file,line,resolved,clutter_score,member_count} ] }` via `StructuredExport`. |
| `json` | `report.json` | Same structured shape, `JSON.pretty_generate`. |
| `dot` | `*.dot` | Graphviz digraph with de-anonymized labels. **Requires `--graph graph.yml`** (edge list source). |

Unresolved ids (e.g. `ext_` sinks, ids absent from the id-map) render as graceful `<external …>`
placeholders (`resolved: false`) — never an error.
