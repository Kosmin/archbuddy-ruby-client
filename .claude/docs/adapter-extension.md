# Adding a new language adapter

The `Adapter` interface is the language seam (D6). A future React/Node adapter (or any other language) is a
**new file plus one Registry entry** — the Anonymizer, Emitter, Reporter, and CLI need **no changes**,
because everything downstream of the adapter is language-agnostic and works purely in opaque-id space after
the trust boundary.

## The contract an adapter must satisfy

Subclass `Archbuddy::Collect::Adapter` and implement `#collect`, returning an
`Archbuddy::Collect::AdapterResult` of neutral `Raw*` value objects **in real-symbol space**:

```ruby
AdapterResult.new(
  nodes:       [Raw::RawNode, …],        # method/endpoint/db_op/external definition sites
  edges:       [Raw::RawEdge, …],        # directed call relationships between RawNode#real_key values
  entrypoints: [Raw::RawEntrypoint, …],  # reachability roots, by node_key
  diagnostics: { meta_sites_skipped: N } # NON-SEMANTIC; consumed by the CLI ONLY, never the graph
)
```

`Raw*` shapes (see `lib/archbuddy/collect/raw.rb`):
- `RawNode(rel_file, line, symbol, kind, class_rel_file, class_line, class_symbol)` — `kind` MUST be one of
  the contract kinds `function | endpoint | db_op | external`. The `class_*` fields (the owning class's def
  site) are how the Anonymizer mints the `cls_` rollup id; leave them nil when there is no owning app class.
  `real_key` = `"rel_file:line:symbol"` is the identity edges/entrypoints reference.
- `RawEdge(from_key, to_key, calls)` — both keys must be `RawNode#real_key`s; `calls` defaults to 1.
- `RawEntrypoint(node_key)` — a `RawNode#real_key`.

## Rules an adapter MUST follow

1. **Real-symbol space only.** Adapters carry real file/line/symbol. **Do NOT mint ids** — that is the
   Anonymizer's sole job (D25/D41). Producing your own ids would bypass the single mint and is forbidden.
2. **Use the contract kinds.** Map your language's constructs onto `function/endpoint/db_op/external`.
   Use a single shared `external` sink for unresolved calls (mirror `RubyAdapter::EXTERNAL_SINK_SYMBOL`).
3. **Never fabricate edges.** Unknown/dynamic call targets go to the external sink; constructs you can't
   statically resolve should be flagged into `diagnostics`, not invented as edges.
4. **Keep diagnostics non-semantic and out of the graph.** They are for CLI stderr only.
5. **Deterministic output** (sort file enumeration, etc.) so captures are reproducible (D30).

## Wiring it in

Add one entry to `lib/archbuddy/collect/registry.rb`:

```ruby
ADAPTERS = {
  "ruby" => Adapters::RubyAdapter,
  "node" => Adapters::NodeAdapter,   # ← new
}.freeze
```

Then `archbuddy collect PATH --language node` routes to it. The Anonymizer turns your `Raw*` into the
opaque `graph.yml` + secret `id-map.yml`; the Emitter validates against the **same** contract schema
(D37) and applies the gitignore-before-secret guard; the engine analyzes the graph identically regardless
of source language; and `report` reconnects findings the same way. None of that changes.

## What to model on

`lib/archbuddy/collect/adapters/ruby_adapter.rb` is the reference implementation: enumerate sources →
build a symbol catalogue → resolve call sites with a tiered, never-fabricating resolver → assemble `Raw*`
+ a single external sink → return the `AdapterResult`. Mirror that structure; only the parsing and
resolution heuristics are language-specific.

---

## What is language-agnostic vs Ruby-specific

The single most important fact for building a new adapter: **only the adapter parses source.** Everything
else in the client already works in opaque-id space (after the Anonymizer) or in real-name space derived
purely from the id-map, so it does not care which language produced the graph.

| Language-AGNOSTIC — reuse unchanged | Ruby-SPECIFIC — the whole adapter, replace |
|-------------------------------------|--------------------------------------------|
| **`Anonymizer`** — the single id mint (real symbols → opaque graph + secret id-map) | **`RubyAdapter`** — orchestrates parse → assemble |
| **`Emitter`** — validate-before-write + gitignore-before-secret guard | The **Prism passes**: `DefinitionPass` (Pass 1), `RouteCatalogue` (Pass 1b), `ResolutionPass` (Pass 2) |
| **`Cache`** — `canonical_json`, `layout`, `writer`, `reader`, `change_detector`, `checker` | **`SymbolTable`** (+ `ClassEntry`/`MethodEntry`) — the discovered-symbol catalogue |
| The **committed-cache flow** (de-anon-at-write, adaptive sharding, `--check` gate) | **`RubyResolver`** — the tiered R0–R9 call-site resolver + `Vocab` |
| **`Fragment`** — the per-file incremental cache unit (AST-backed; only `parsed_value` is language-shaped) | **`EntrypointDetector`** — the entrypoint strategies |
| **`Report`** — `Reconnect`, `Ranker`, all formatters (terminal/yaml/json/dot/html), `Scores` | The **probes** (`GrapeProbe`, `DispatchProbe`) + `GrapeDsl` recognizer |
| The **engine** `analyze` (opaque graph → findings) | The **parser choice** (Prism) + all parse/resolution heuristics |

`Fragment` is *mostly* neutral: its `content_hash` (SHA-256 of source bytes) and `rel_file` are
language-independent; only `parsed_value` (the AST) is language-shaped, and it is transient — the global
`assemble` step (adapter-owned) consumes it and it is NEVER committed. So a new adapter reuses the
Fragment / Reader / ChangeDetector plumbing and supplies only its own parse + assemble.

### The adapter contract (the whole interface)

Produce, in real-symbol space, an `AdapterResult`:

- **nodes** — `RawNode`s with `kind ∈ function | endpoint | db_op | external`, carrying `branches`
  (business control-flow count) and `decisions`, plus the owning-class def site for the `cls_` rollup.
- **edges** — `RawEdge`s (directed `from_key → to_key` between `RawNode#real_key`s, `calls` count).
- **entrypoints** — `RawEntrypoint`s (reachability roots by `real_key`).
- **diagnostics** — non-semantic, CLI-only (never in the graph).

That is the entire boundary. The Anonymizer mints ids; the Emitter validates against the **same** contract
schema regardless of source language; the Cache de-anonymizes + shards + commits identically; the engine
scores the opaque graph identically. **None of that changes for a new language.**

---

## Concrete guide: a JavaScript / TypeScript adapter

A JS/TS adapter is the archetypal second language (React/React-Native ride on top of it). This is a guide
detailed enough to **build the adapter from the docs**, without reverse-engineering the whole client.

### 1. Parser choice (an open design point — flag it)

This client is a **Ruby** process, so a JS adapter has two shapes; pick one deliberately:

- **(A) Separate collector process / subshell** — a small Node program (using `@babel/parser`, the
  **TypeScript compiler API** for real type info, or **tree-sitter**) that walks the JS/TS tree and emits
  the **same `graph.yml` + id-map** this client would. The Ruby side then skips straight to `analyze` /
  `report`. Cleanest reuse of the JS ecosystem's own parsers; the seam is the on-disk graph, not a Ruby
  object. **Recommended default.**
- **(B) In-process Ruby binding** — drive tree-sitter's C bindings (or an embedded JS engine) from a Ruby
  `JsAdapter < Adapter` so it plugs into `Registry.for("javascript")` like `RubyAdapter`. Tighter
  integration (reuses `Anonymizer`/`Emitter`/`Cache` directly) but couples the Ruby process to a native
  parser.

Either way the **downstream contract is identical** — (A) emits the graph the Anonymizer would have; (B)
emits `Raw*` and lets the Anonymizer mint. Decide (A) vs (B) before writing code; it is the one real fork.

### 2. Map JS/TS constructs onto the model

| JS/TS construct | archbuddy model |
|-----------------|-----------------|
| `function` decl / arrow fn / class **method** / object method | **node** (`kind: function`) |
| `class` / `module` (ES module = file) | node owner → the `cls_` rollup (module-as-class for top-level fns) |
| `import` / `require` / `export` | resolve call targets across files (symbol-table lookup) — not edges themselves |
| function **call** / method call | **edge** `caller → callee` |
| `new Foo()` then a method call | typed-receiver resolution (the R4.5 analog — see below) |
| `if` / `switch` / ternary `?:` / `&&` / `\|\|` / optional-chaining `?.` | **branches + decisions**. Mirror Ruby's de-idiomatization: `if`/`switch`/loops multiply into `branches` (business control flow); `&&`/`\|\|`/`?.`/`??` count only in `decisions` (idioms). |
| unresolved / third-party (`node_modules`) call | the single shared **`external`** sink |

### 3. The two-pass architecture carries over verbatim

The Ruby adapter's shape is language-neutral and you should mirror it exactly:

1. **Pass 1 (definition):** walk every file building a **symbol table** of classes/modules/functions with
   **first-def-wins** (a re-declared name keeps its first def site — a stable node). Record owning
   module/class for the `cls_` rollup.
2. **Pass 1b (route/entrypoint seeder):** the framework-route analog (see §5) — seed entrypoints for
   known-defined symbols only (never fabricate).
3. **Pass 2 (resolution):** walk call sites inside function bodies; resolve each against the symbol table
   with a **tiered, never-fabricating resolver**. Unknown/dynamic targets → the `external` sink; never
   guess an edge.

The **typed-receiver tier (Ruby's R4.5)** maps directly: TS gives you *better* type info than Ruby's
intra-procedural inference — use the TS compiler's checker (option A/TS) or a conservative local
`const x = new Foo()` scan to resolve `x.bar()` to `Foo#bar` **only when the method provably exists**.

**Symbol-keyed ids apply UNCHANGED:** the identity key shape `"rel_file\x00fq_symbol"` (line dropped from
identity, display-only) is language-independent — a JS symbol like `src/api/orders.ts\x00OrdersService#create`
keys exactly like a Ruby one. The Anonymizer and the committed cache need no changes.

### 4. Determinism + the never-fabricate invariant (non-negotiable)

Same as Ruby: sort file enumeration, collapse duplicate edges, and route every unresolvable/dynamic call
(`obj[dynamicKey]()`, `eval`, reflection) to the `external` sink or into `diagnostics` — NEVER invent an
edge. This is what keeps the committed cache byte-stable and the `--check` gate meaningful.

---

## Framework dispatch: React & React-Native

Frameworks are handled the way Ruby handles Rails/Grape/Sidekiq — as **entrypoint seeders** (node side)
and **probes** (edge side) layered on the base JS/TS adapter. The base adapter stands alone; framework
awareness is additive.

### React (web)

| React concept | archbuddy model |
|---------------|-----------------|
| Component (function or class) | **node**; the component tree is the call/render graph |
| Hooks (`useState`/`useEffect`/`useMemo`/custom `useX`) | calls → **edges** from the component to the hook |
| Context provider / `useContext` | edges from consumer → provider (a resolution tier, like Ruby's mount probe) |
| **prop-drilling**, a **context provider with many consumers**, or a **`switch`-on-`type` render** | **`multiplexer_proxy` candidates** — the exact smell the engine already surfaces; the adapter just needs to produce the fan-in/fan-out topology and the engine scores it |
| the render tree (parent renders children) | parent-component → child-component **edges** |

### React-Native

Same as React, plus:

- **Navigation stacks** (React Navigation: `Stack.Screen`, `navigation.navigate("Route")`) — an
  **entrypoint seeder** (screens are reachability roots) + a dispatch **probe** (`navigate("X")` →
  the `X` screen component), mirroring Ruby's `RouteCatalogue` + `GrapeProbe`.

### Entrypoints for JS/TS

The `EntrypointDetector` analog seeds reachability roots from framework surface:

- **HTTP routes** — Express/Koa/Fastify handlers, **Next.js** `pages/`/`app/` route files & API routes.
- **Exported React components** (especially screen/page components).
- **Event handlers** (`onClick`, DOM/RN listeners) as leaf entrypoints where relevant.

### `db_op` and `external` analogs

- **`db_op`** — ORM calls: **Prisma** (`prisma.user.findMany`), **TypeORM**, **Sequelize**, plus raw
  query builders. Synthesize a `db_op` node the same way Ruby does for ActiveRecord (a plain COST-1
  terminal). RN local stores (`AsyncStorage`, SQLite) are `db_op` candidates too.
- **`external`** — anything in `node_modules` / out-of-tree, and network I/O (`fetch`/`axios`) whose
  target is not an app symbol → the single shared `external` sink.

---

## The engine needs ZERO changes

Worth restating because it is the whole point of the seam: adding JS/React/React-Native is **a new adapter
only**. The Anonymizer, id-map, Cache, committed-cache flow, and Report are all language-neutral, and the
**engine already scores an opaque graph without knowing its source language**. A JS adapter that emits a
conformant `graph.yml` gets dimension scores, the `multiplexer_proxy` smell, and the full report for free.
Cross-reference: the engine repo's **"Scoring a non-Ruby codebase"** doc.
