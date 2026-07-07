# The Ruby call-site resolver (D24)

`Collect::Adapters::Ruby::RubyResolver` is **pure tiered decision logic**: given a `CallContext`
(method name, Prism receiver node, enclosing class fq, the `SymbolTable`) it returns a `Resolution`
without touching the AST walk or mutating state. **It never fabricates an edge.** `ResolutionPass` only
calls it for calls inside a known method body (calls at class-body/top-level have no caller node → no edge).

`Resolution.action` ∈ `:edge | :drop | :metaprogramming | :external`. For `:external`, `kind` is either
`"db_op"` (synthesize a db_op node) or `"external"` (route to the single shared sink). The `tier` symbol
is for debugging/tests.

## Tier table (first match wins)

| Tier | Fires when | Action | Result |
|------|-----------|--------|--------|
| **R0** operator | name ∈ `Vocab::OPERATOR_DENY` (`+ - * / == < []` …, D36) | `:drop` | No node, no edge — operators carry no architectural signal. |
| **R1** metaprogramming | name ∈ `Vocab::METAPROGRAMMING` (`send`, `public_send`, `define_method`, `*_eval`, …) | `:metaprogramming` | **Flagged, NO edge** — target is statically unknowable; counted in `diagnostics[:meta_sites_skipped]`. Fabricating an edge would be a lie. |
| **R2** db_op via **class context** | enclosing class is an AR subclass **AND** name ∈ `Vocab::ACTIVE_RECORD` | `:external`, `kind: "db_op"` | Synthesize a `db_op` node `"<EnclosingClass>.<name>"`. **The verified gotcha** — see below. |
| **R3** self method | receiver is nil or `SelfNode` **AND** enclosing class has a known `#name` (then `.name`) method | `:edge` | Edge to `EnclosingClass#name` / `EnclosingClass.name`. |
| **R4** app `Const.method` | receiver is a `ConstantReadNode`/`ConstantPathNode` for a known class | `:edge` (or `:db_op` if the const is a known AR class + AR method) | Edge to `Const.name` / `Const#name`; or a `db_op` `"Const.name"`. |
| **R4.5** typed receiver (L1, v0.6) | receiver's type is PROVABLE from the conservative intra-procedural type scope (`ctx.type_scope`): an intra-method local / same-class ivar / memoized-accessor whose tracked value is exactly `Const.new`, or an inline `Const.new.method` / `Const::Path.new.method` chain — **AND** `table.method?(fq)` is true | `:edge` (or `:db_op` if the inferred const is a known AR class + AR method) | Edge to `Const#name` (instance, preferred for `.new`) / `Const.name`; or a `db_op` `"Const.name"` (mirrors R4's AR branch). **NEVER-FABRICATE:** declines (→ R5 → R9) unless the method provably exists. Pure resolution, NOT a whitelist; AR/Looker/Snowflake are not special-cased. |
| *(R5 probe tier)* | recognized framework DSL (Grape mount / Sidekiq-ActiveJob dispatch) — see ARCHITECTURE.md | `:edge` | Real edge the framework provably wires; runs after R4.5, before R9. |
| **R9** fallthrough | anything else (unresolved, third-party, unknown receiver) | `:external`, `kind: "external"` | Route to the **single shared external sink** (`RubyAdapter::EXTERNAL_SINK_SYMBOL = "<external>"`, one `ext_` node for the whole graph). |

Two other classifications happen in the adapter (not the resolver):
- **endpoint**: `RubyAdapter#endpoint?` marks a node `endpoint` when it is a non-singleton method on a
  controller class (`SymbolTable#controller_class?` — superclass ∈ `CONTROLLER_BASES` or name ends in
  `Controller`).
- **entrypoints**: chosen by `EntrypointDetector` per strategy (see ARCHITECTURE.md / CLI), not the resolver.

## The AR implicit-self gotcha (R2)

```ruby
class Invoice < ApplicationRecord
  def self.overdue
    where(state: "late")   # receiver is NIL (implicit self), NOT a ConstantReadNode
  end
end
```

A naive resolver keyed on receiver shape would miss this — `where` here has **no receiver**. R2 therefore
consults **class context** (`SymbolTable#active_record_class?(enclosing_class)`, which walks the superclass
chain via `chain_any?`), not the receiver. The db_op symbol is keyed by the enclosing class
(`"Invoice.where"`) so different models produce distinct db_op nodes. Asserted by the
`classifies implicit-self where …` example in `spec/collect/collector_spec.rb`.

## What the resolver guarantees

- No edge is ever invented. Unknowns go to the external sink; metaprogramming is flagged but edge-free.
- Determinism: same inputs → same resolution (pure function over the `SymbolTable`).
- All target ids are minted later, only by the Anonymizer via `Contract::Ids` — the resolver works purely
  in real-symbol space.

To change classification: edit `Vocab` (vocab data) and/or the tiers in `resolver.rb`, then update this
table and re-run `spec/collect/collector_spec.rb`.
