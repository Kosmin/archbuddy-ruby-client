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
