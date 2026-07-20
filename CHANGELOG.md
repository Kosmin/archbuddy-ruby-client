# Changelog

## [0.11.0] — v0.12 counter wave (W-CLI-B)

The client half of the v0.12 read/report side: the release's single committed-cache
serializer bump (v3 → v4) plus the `variety_mass` read path, presenter line, and version bump.
Everything ADDITIVE and nil-tolerant — pre-1.7 docs render byte-identically to 0.10.0.

### Added
- **SERIALIZER v4 (R1 — THE one serializer bump of the release, sole owner):** the committed
  aggregate carries the findings-1.7 `variety_mass` block VERBATIM as a top-level peer of
  `blast_radius` (UNGRADED — no grade key exists or is ever minted; `capped_fraction` = the CAP
  disclosure, `fallback_fraction` = THE L17 low-confidence disclosure; first-class `variety`/`mass`
  component stats; opaque `hotspots` lists DROPPED at both levels — the headline_scores posture);
  `preserve_existing_scores` carries it across collect-only rewrites (a v3 prior grafts nothing).
  Fragment nodes additionally carry `outcome_arity` (int|null — null = unresolved, NEVER
  fabricated) + `escapes` (bool) read from the id-map descriptor mirror — the collector wave's
  keys ride THIS stamp (one committed-cache churn event, A5).
- **Read side (R2):** `Scores::VarietyMass` (+`::Component`) incl. `fallback_fraction`
  (`na?` = score nil); dual-shape nil-on-absent parsers `variety_mass_from_aggregate` /
  `variety_mass_from_findings` (ONE builder — the committed and findings spellings are pinned
  1:1); threaded `Result` → `RenderContext` → CLI as the fifth business-metric field.
- **Business Impact (R3):** Q1 gains the spec-pinned Variety+Mass detail line —
  `variety + mass: complexity 57.0 = variety 16.0 + mass 41.0 (median 57.0)` — the "=" equation
  is the common case (the engine caps variety BEFORE summing, A7); a non-reconciling triple
  degrades to the comma form (never a false equation); absent/N/A → NO line. Formatters:
  ZERO code change (generic `detail_lines` rendering). The L9 change-impact ripple line is
  DEFERRED (gated off, zero code — v0.13).

### Changed
- Client version 0.10.0 → 0.11.0.
- Spec re-baselines: the six committed-stamp assertions read `eq(4)`; v1/v2/v3-vintage doc
  INPUT fixtures retained as tolerance pins (they must keep passing).

## [0.11.0] — v0.12 collector wave (W-CLI-A, ships with the counter wave above)

The client half of the engine's v0.12 `cost = Variety + Mass` dimension: extraction of the two
graph-1.4 INPUT facts. Output-compatible with every current setup — emission is probe-gated
(dormant against a graph-1.3 engine; the emitted graph is byte-identical to v0.10.0 there).

### Added
- `OutcomeArityCounter` (CL-A, L16): Layer-1 caller-visible outcome-class extraction over the
  five-class taxonomy `{VALUE, NIL, TRUE, FALSE, RAISE}` (the taxonomy is the cap, k=5), with
  symbolic `[:ref]`/`[:ivar]` seams, intra-def ivar finalization (exact memo-guard collapse),
  unguarded-raise evidence, and the shared `arity` derivation (floor 1; `:unresolved` → nil,
  never fabricated). Prism 1.9.0 vocabulary only; unknown tail kinds default to `:unresolved`.
- `EscapeScanner` (CL-A, L18): the callee-DEFINITION escape property — `yield`, used-`&blk`
  (declared-but-unused is NOT an escape), `block_given?`/`iterator?`, callable-param `.call`,
  dynamic meta-send via the shared `Vocab` predicates (literal `send(:m)` is not an escape).
  Stdlib inline-block call sites are structurally exempt; `case`-on-own-param type dispatch is
  pinned NOT-an-escape. 14-case battery.
- `ArityResolver` (CL-B, L16 Layer 2): the tail-call/ivar-memo arity-inheritance fixpoint in
  `RubyAdapter#assemble` (pre-Anonymizer) — memoized forwarders inherit their delegate's
  outcomes (1→2); cycles/misses fold to opaque value; iteration cap = table size; arity floor
  ≥ 1 enforced. No receiver'd-call resolution (deliberate scope refusal).
- Threading (CL-C): `RawNode#outcome_arity`/`#escapes` → probe-gated `graph.yml` node fields
  (`OUTCOME_ARITY_PROBE_GRAPH`/`ESCAPES_PROBE_GRAPH` schema-acceptance gates — the
  `entrypoint_kind` playbook; arity emits only when resolved, escapes only when true) → id-map
  descriptor keys (unconditional; `outcome_arity` int|null, `escapes` bool). Sinks (db_op /
  external) are never stamped — the engine reads absent-on-external as a lenient single-outcome
  terminal (L17).
- Diagnostics (CL-C, A9): `arity_unresolved` + `escaping_defs` counters (CLI stderr notes only,
  never serialized).
- Specs: the Layer-1 taxonomy battery, the 14-case escape battery, fixpoint specs, both-postures
  emission gates (green under a graph-1.3 OR graph-1.4 engine), and the L16 measure-once anchor
  battery + client-owned D7 input gates (arity floor / firewall / T2 / T3 / never-fabricate).

### Changed
- `Vocab.literal_dispatch_arg?` hoisted from `Resolver` (one spelling; the resolver delegates —
  behavior-preserving).
- `Cache::Reader::COLLECTOR_VERSION` 1 → 2 (the DefinitionPass derivation changed; one forced
  re-parse per machine, per the documented bump policy).

### Explicitly NOT in this wave (the counter wave, W-CLI-B, owns them)
- The committed-cache serializer stamp v3 → v4 + the fragment `outcome_arity`/`escapes` keys
  (one churn event, together).
- The `variety_mass` aggregate fold / read-side structs / Business Impact line.
- The client version bump 0.10.0 → 0.11.0.
