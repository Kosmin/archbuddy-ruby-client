# Changelog

## [0.14.0] — the per-function reusability score (v0.16)

The client half of the v0.16 reusability-score arc: the engine (findings 1.9 / architecture-auditor
0.11.0) now computes a calibrated **−5..+5 per-function score** — negative = false reusability /
extreme multiplexing (break it down before growing it), 0 = equilibrium, positive = a trivially
simple pass-through that could absorb more caller-side complexity — and the client CONSUMES and
surfaces it. Everything ADDITIVE, nil-tolerant, and ADVISORY: pre-1.9 / pre-v6 caches render
byte-identically to 0.13.0 (no score, no new section, no new report block). L6/R-HONEST throughout —
N/A over fabrication (a null triple is never a fabricated 0), constants carry measured provenance,
and no author data leaves the SECRET id-map. Engine dependency floor raised to `"~> 0.11"` (the
score keys need findings 1.9; a fresh clone resolves the engine via the Gemfile git source once
0.11.0 is pushed — until then the documented `ARCHITECTURE_AUDITOR_PATH` dev override applies).

### Added
- **SERIALIZER v6 (T1 — THE one serializer bump of the release, sole owner):** fragment nodes
  gain the three per-node score stamps `{score, score_band, score_raw}` plus the L9-A advisory
  pair `{absorb, absorb_raw}` (the `COMPASS_KEYS` family extension), copied VERBATIM from findings
  1.9's per-node `reusability` map at analyze/reset and carried across collect-only rewrites by the
  existing per-fragment carry (`carry_prior_compass!` iterates `COMPASS_KEYS`, so the new keys ride
  the SAME mechanism — keys drop only with the node; a v5 prior grafts nothing; first-ever collect
  stays null). The aggregate additionally folds the findings-1.9 `score_distribution` stat block
  (present-iff-source) and the top-level `reusability_by_class` map (one committed row per class:
  `{class, min, max, count, n_negative, n_positive, headline}`, `headline` = the engine-computed
  negative-first dominance verdict, published so no consumer re-derives it). Both join the
  collect-only carry list. **Downgrade caveat (repeats v5's):** an OLD (pre-0.14.0) client's
  `collect` over a v6 cache rewrites the committed shape back to its own vintage — acceptable; the
  next `analyze` with a current client restores v6. The v5→v6 stamp churn ships as ONE
  committed-cache churn event per audited repo.
- **Read side (T2/T5):** the score triple + absorb pair parse into `Report::Scores` and the review
  `Vintage::Node` reader (v6 ⇒ populated; v5 ⇒ nil members, absent from `keys_present`); the
  `score_distribution` and per-class `Reusability::ClassRow` (all six keys + `headline` + resolved
  `class` symbol) parse identically from the aggregate and from raw findings. Pre-1.9 docs yield
  nil members throughout — never a fabricated score.
- **8th business rule `ReusabilityScore` (T7/T8):** kind `:node` on the `ExponentialNode` template,
  default severity `:info` (ADVISORY — never exits 1 at the default), params `min_score: -4`
  (fires on nodes at or below the calibrated extreme-multiplexing floor; measured −5 needs
  N ≥ 18.421) and `absorb_min_score: +5` (the absorption-headroom incentive; +5 real needs
  mass_savings ≥ 120). The `absorb_min_score` arm reads the engine `absorb` key (never the score
  key) and renders as a presenter disclosure, never a finding. Diff universe = NEW ∪ GROWN nodes
  only; a stale committed stamp degrades to disclosure, never a gate. Todo grammar accepts the
  negative `min_score` and encodes debt in milli-log2 (`(−score_raw × 1000).round`).
- **13th lint leaderboard key `reusability_score` (T9):** the ep-cone negative-first dominance
  headline (`min` if ≤ −1, else `max` if ≥ +1, else 0; `null` — never 0 — when no cone node
  carries a stamp), lifted via the new public `Graph#cone_nodes` + `Review::ScoreRollup`.
- **Diff-envelope `reusability` block (T10):** `archbuddy diff`'s `archbuddy-diff-report/1` JSON
  envelope gains a per-node `reusability` block (present iff ≥ 1 stamped side) across all three
  formatters (JSON / markdown / terminal), carrying base/head score triples, `delta_raw_milli`
  (null-tolerant deltas on `score_raw` so movement stays visible inside the saturated |5| poles),
  and the L9-A absorb disclosures with per-side staleness provenance. The envelope schema fixture
  was re-cut in the same commit; stored 0.13.0 samples still validate.
- **`--analyze-sides` transport (T11):** an opt-in escape hatch for `archbuddy diff` that runs the
  engine per side (base + head) into scratch caches and folds the fresh stamps through
  `Cache::Writer` — fresh stamps by construction (the antidote to committed-cache staleness). The
  committed-cache path stays the cheap default; engine-absent ⇒ exit 2 with empty stdout; scratch
  is always cleaned.
- **Tier-4 backtest score gates (T15):** `script/backtest` gains an additive tier-4 that replays
  the study corpus through the shipped reader/rules/CLI and asserts the B-marked score canon
  (G-1a/G-1b monster band −4→−5, G-2 toll-booth floors, G-3 pole exclusivity, G-4 distribution
  bands, G-8 churn-free, G-10 all-escapes-negative, G-11 per-class extremes) plus the L9-A
  headroom gates G-12..G-15 — all on engine-EMITTED findings only (never a formula replica — the
  transcription-drift kill). Tiers 0–3 stay byte-untouched; `--tier 4` dispatches it alone;
  corpus-unset ⇒ skip exit 0; a below-0.11.0 engine ⇒ loud skip.
- **`docs/REUSABILITY_SCORE.md` (P3-D1):** the reference for the scale semantics, the F-A formula
  family and its measured constants with provenance, the Q8 product-copy law (never "reuse more"
  with a negative score; never "callers have similar logic" — the +5 pole proves callers CONVERGE
  and absorption is free, never that they share logic), and the L9-A absorption-headroom advisory
  with its FP-honest copy. README and this changelog link to it; neither creates it.

### Changed
- Client version 0.13.0 → 0.14.0.
- Engine dependency floor `"~> 0.2"` → `"~> 0.11"` (findings 1.9 needs engine 0.11.0).
- Doc consistency sweep (M9): README / ARCHITECTURE / CONTRACT serializer-version and findings
  banners advanced to v6 / 1.9; the `--analyze-sides` flag and the diff-envelope `reusability`
  block documented.

## [0.13.0] — the business-metrics architecture reviewer

The v0.14→v0.15 conversion shipped as ONE release: the reviewer prices USE CASES — what each
entrypoint costs to change, verify, and carry — instead of flagging function style. Consolidated
entry (P1/P2/P3 lanes; no other task edits this file).

### Added

- **`archbuddy diff` / `archbuddy lint`** — the CI reviewer commands: PR-delta gating against
  `git merge-base` (or an air-gapped `--base-cache`), whole-repo use-case pricing with the
  leaderboard. Exit map 0/1/2 with exit-2 stdout silence.
- **`.archbuddy.yml` schema v1** with the SEVEN business rules: `UseCaseComplexity`,
  `UseCaseDividend`, `FirewallBreaches`, `ReviewSurface`, `ComplexityRatchet` (path budgets,
  incl. negative; never grandfathered), `ExponentialNode` (strict `> 2^5`, never at it),
  `MultiplicativeGrowth`. Config presence activates gating; no file = advisory.
- **The use-case leaderboard** (worst-first by cone branching) + the MANDATORY
  unreachable-from-entrypoints disclosure in every report.
- **Ep-granular value-pinned todo grandfathering** (`.archbuddy_todo.yml` v1): raw-integer
  pins (native counts / milli-log2), entries excuse today's measured value per use case and
  drop when violations heal; `lint --auto-gen-todo` regenerates.
- **`archbuddy-diff-report/1` JSON envelope** incl. the `use_cases` / `review_surface` blocks;
  `tool.client` derives from `Archbuddy::VERSION` (no literal to bump).
- **builtin-study-v1 calibration** with the honesty laws: provenance-stamped measured-only
  lines (the multiplier exponentiates ONLY net Δlog2; the bugfix caveat is mandatory;
  FirewallBreaches carries no measured cost line); `source: local`/`none` swap/suppress.
- **The backtest harness** (repo-local `script/backtest/`, env-gated, 19 machine-checked
  gates + the author-scan) and the docs set: CONFIGURATION, CI_RECIPES, RECALIBRATION,
  BACKTEST, COMMITTING update. CI_RECIPES + RECALIBRATION now ship in the gem;
  BACKTEST.md and `script/**` stay repo-only.

### Retired (with successors — the one allowed CHANGELOG appearance)

| retired | successor |
|---|---|
| MaxBranching | `UseCaseComplexity` `max_branching_log2` |
| MaxFunctionMass | `UseCaseComplexity` `max_mass` |
| MaxDepth | `UseCaseComplexity` `max_depth` |
| MaxOutDegree | dropped — reach/files components (`max_reach` / `max_files`) |
| NoNewEscapes | `FirewallBreaches` diff mode |
| NoNewTollBooths | dropped — toll-booth data remains a leaderboard/enrichment diagnostic only |

Design note: nothing here was ever released — 0.13.0 is the first shipped reviewer; the
retirement table exists for config authors coming from the plan docs.

## [0.12.0] — v0.13 Reusability Compass wave (V13-C)

The client half of the v0.13 Reusability Compass (engine 0.10.0 / findings 1.8): the release's
single committed-cache serializer bump (v4 → 5) plus the compass read path, the Business Impact
Reuse line, and the per-function side-panel/table surfaces. Everything ADDITIVE, UNGRADED, and
nil-tolerant — pre-1.8/pre-v5 docs render byte-identically to 0.11.0. ADVISORY throughout: a
toll booth is a "bypass candidate", never "must bypass".

### Added
- **SERIALIZER v5 (C1 — THE one serializer bump of the release, sole owner):** fragment nodes
  carry the four per-node compass stamps `{leverage, collapse, toll_booth, quadrant}` beside
  `outcome_arity`, copied VERBATIM from findings 1.8's top-level `reusability` map at
  analyze/reset (all four keys always present on v5; null = never analyzed — `toll_booth` false
  is a real engine verdict, never fabricated from null). **THE CARRY MECHANISM:** compass values
  are analyze-time, so a collect-only rewrite grafts the PRIOR committed fragment's stamps per
  surviving node (`carry_prior_compass!` — `preserve_existing_scores` applied per-fragment;
  keys drop only when the node is gone; a v4 prior grafts nothing; first-ever collect stays
  null). Spec-proven: collect-after-analyze keeps every fragment byte-identical. The aggregate
  additionally carries the `reusability` block folded VERBATIM from
  `scores.reusability_compass` (reuse_index / unshared_fraction / leverage stats; toll-booth +
  extraction worst-lists de-anonymized to real symbols, engine order preserved), and
  `reusability` joins the collect-only carry list.
- **Read side (C2):** `Scores::Reusability` (+`::ReuseIndex`/`::TollBooth`/`::Extraction`/
  `::LeverageStats`) — UNGRADED, no grade member ever; dual-shape nil-on-absent parsers
  `reusability_from_aggregate` / `reusability_from_findings` (ONE builder; legacy worst-list
  `node` ids resolved via the SAME id-map join, missing ids degrade gracefully); threaded
  `Result` → `RenderContext` → CLI as the sixth business-metric field.
- **Business Impact (C2):** the spec-pinned `Reuse` footer — "the average node serves N use
  cases (median M); K toll booths (bypassing saves ~S mass); top extraction candidate X
  (collapse ×C)". Clauses degrade independently (unknown reachability drops the reuse clause;
  unknown blast drops the savings parenthetical); the honest-blank form (vty gate) is OMITTED —
  never a lone "0 toll booths" verdict. `~S` is the display sum of the engine-published
  per-booth `mass_savings`; every other figure is VERBATIM (D17).
- **HTML (C2):** the node side panel gains leverage / collapse / quadrant / "toll booth:
  bypass candidate (advisory)" rows via the binding DATA ROUTE (fragment stamps → DetailTree
  passthrough → `graph_node_data` whitelist → `showNode`) — the click-a-node localization
  surface; plus a `Reusability Compass` section (summary line, quadrant lists grouped from the
  per-node stamps — display-only grouping of engine verdicts, capped at 10 per quadrant — and
  the toll-booth/extraction worst-list tables with the advisory caption). "" on pre-v5 docs.

### Changed
- Client version 0.11.0 → 0.12.0.
- Spec re-baselines: the six committed-stamp assertions read `eq(5)`; v1..v4-vintage doc INPUT
  fixtures retained as tolerance pins (they must keep passing); nil-tolerance matrix rows 11–13
  (v5/1.8 full render, honest-blank omission, legacy opaque 1.8 + id-map).

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
