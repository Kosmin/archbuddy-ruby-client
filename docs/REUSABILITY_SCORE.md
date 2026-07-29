# The Reusability Score (−5..+5)

The per-function (and per-class) **reusability score** answers one question
per node: *would restructuring this function reduce project complexity?* It is
computed by the **engine** (`architecture_auditor` ≥ 0.11.0, findings schema
1.9) from Reusability Compass ingredients the analyze pass already measures —
`collapse`, `blast`, `toll_booth`, `mass_savings`, and the escape flag — with
zero new graph traversals. This client consumes the published values verbatim
(SERIALIZER v6 fragment stamps, report/lint surfaces, the `ReusabilityScore`
review rule) and **never computes a score itself**; per-PR deltas are
subtraction of published values, client-side.

Calibration provenance: every constant, band, and example below was measured
on 4 real vintages of one production Rails/Grape service lineage
(~1,800–1,940 in-tree nodes each). Node references are (file, symbol) only.

## Scale semantics

**The reusability score** is a per-function (and per-class) value on −5..+5,
published as `score` (real, 2 dp), `score_band` (integer −5..+5), and
`score_raw` (signed log2-units magnitude, 3 dp). **0 is the ideal**: the node
is at equilibrium — no statically visible restructuring of THIS node reduces
project complexity (a claim about this node's topology, NOT about where new
features belong). **Negative** = false reusability: the node keeps decision
surface inline above its contract width (`collapse`), amplified when many use
cases route through it (`blast`); −5 means break it down NOW. **Positive** =
proven absorb/bypass capacity: a logic-free pass-through (toll booth) whose
bypass or absorption recovers exactly `mass_savings` project-wide; +5 means
this seam is where shared caller logic belongs. Scores come from the engine
only; clients never compute them (they subtract published values for per-PR
deltas). Absence semantics: no `outcome_arity` stamps → the whole surface is
ABSENT; unknown ingredients → `null` — never a fabricated 0.

Encoding order law: `score_band` is derived from the FULL-PRECISION score
before the 2 dp emit rounding (round half away from zero, clamped ±5) — never
re-derived from the published 2-dp value. Likewise, published 2-dp values come
from the full-precision score — never re-round the 3-dp `score_raw`. Under the
locked constants: band +5 ⇔ `mass_savings ≥ 120`; band −5 ⇔ N ≥ 18.421.

## The formula (engine-side, for reference)

The engine computes on its unrounded internal ingredients (`collapse` =
`branches / max(outcome_arity, 1)` at full precision), inside the existing
single compute pass:

```
G  = collapse > 0 ? max(0, log2(collapse)) : 0
G' = max(0, G − DEADBAND)                       # own extractable gap
Gx = escape ? max(G', ESCAPE_FLOOR) : G'        # the escape floor
A  = 1 + log2(1 + blast) / AMP_DIVISOR          # blast null → A = 1 (disclosed)
N  = Gx × A                                     # negative magnitude
P  = toll_booth ? log2(1 + mass_savings) : 0    # ms null → positive side null

score      = −5 × (1 − e^(−N / NEG_DIVISOR))    if N > 0
           = +5 × (1 − e^(−P / POS_DIVISOR))    if N = 0 and P > 0
           = 0                                   otherwise
score_band = clamp(round_half_away(score), −5, +5)   # from the unrounded score
score_raw  = N > 0 ? −N : (P > 0 ? +P : 0)           # signed log2 units, 3 dp
```

Pole exclusivity is structural: a toll booth carries no escape and no own gap,
so N = 0 — no node can ever sit on both poles (0 overlaps measured across all
4 calibration vintages).

Honest N/A ladder: (1) zero `outcome_arity` stamps → the whole score surface
is ABSENT; (2) `collapse` null → `score: null` (booth false by construction);
(3) no live entrypoints → the negative side is published with A = 1 plus a
disclosure, booth scores are null (`mass_savings` is seed-dependent); `blast
= 0` with live seeds is a KNOWN zero → booth ms = 0 → score 0, not null;
(4) non-vertex/external/db_op nodes carry no score key at all.

## Published surfaces (key names are law)

| surface | where | shape |
|---|---|---|
| per node | findings 1.9 `reusability` map; client v6 fragment stamps | `score` (2 dp) / `score_band` (integer) / `score_raw` (3 dp), plus advisory `absorb` / `absorb_raw` when eligible |
| per class | findings top-level `reusability_by_class`, keyed by opaque `cls_` ids | `{min, max, count, n_negative, n_positive, headline}` |
| distribution | `reusability_compass.score_distribution` | `{n_scored, n_null, zero_share, bands}` |

Per-class semantics: statistics over the PUBLISHED 2-dp member scores (so any
consumer can recompute them); `n_negative` counts members ≤ −1, `n_positive`
counts ≥ +1; `headline` is the negative-first dominance value (`min` if
min ≤ −1, else `max` if max ≥ +1, else 0) — published by the engine precisely
so no consumer re-implements the rule. `count` rides along so 1–2-node classes
read honestly (worst-of extremes on a tiny class are weak evidence). Nodes
without a `class_id` are omitted; a classless graph carries no
`reusability_by_class` key. This client lifts the same dominance rule to the
use-case cone as `lint`'s 13th leaderboard key `reusability_score` (null when
no cone node carries a stamp — never a fabricated 0).

`score_distribution` publishes `{n_scored, n_null, zero_share, bands}`; on a
vintage with zero scored nodes it degrades to an honest blank (`zero_share:
null`), never invented numbers. Mean-based class aggregation was measured and
rejected: the #2083 monster's class ranks bottom-6/374 by `min` but 88/374 by
mean — means provably dilute breakdown debt.

## Worked examples (measured on the calibration corpus)

### The #2083 monster (negative pole, band-visible delta)

Node: (`app/api/api/v1/redeem_templates.rb`,
`Api::V1::RedeemTemplates#PATCH[0]`), base vintage `68abf831`, head
`f61b758c`:

| side | collapse | blast | G | G′=Gx | A | N | score_raw | score | score_band |
|---|---|---|---|---|---|---|---|---|---|
| base | 8192 | 1 | 13 | 12 | 1.25 | 15.00 | −15.000 | **−4.23** | **−4** |
| head | 65536 | 1 | 16 | 15 | 1.25 | 18.75 | −18.750 | **−4.52** | **−5** |

Δraw −3.750 (= Δlog2 collapse +3 × A). The merge that grew this node is
visible on the PUBLISHED BAND (−4 → −5), not just in the raw value — the
exact product story: "this PR pushed a −4 node to −5".

### Toll booths (positive pole)

| node (file, symbol) | blast | ms | P | score_raw | score | score_band |
|---|---|---|---|---|---|---|
| (`app/api/api/v1/locations.rb`, `Api::V1::Locations#collection`) — rank-1 by `mass_savings` on all 4 vintages, source-verified | 8 | 32 | 5.044 | +5.044 | **+4.07** | **+4** |
| (`app/api/api/v1/redeem_templates.rb`, `Api::V1::RedeemTemplates#collection`) — the monster's class-mate | 5 | 10 | 3.459 | +3.459 | **+3.42** | **+3** |
| band +5 threshold (arithmetic) | — | ≥ 120 | ≥ 6.908 | — | ≥ +4.50 | **+5** |

### Escapes (floor behavior)

(`app/interactors/batch/process_record.rb`,
`Batch::ProcessRecord#destroy_association`): collapse 16, blast 5, escape →
G′ 3 (floor inactive — the gap is real), A 1.646, N 4.939 → **−2.30,
band −2**. Floor-active contrast, at head `f61b758c`:
(`app/classes/rpc/response.rb`, `Rpc::Response.create`): collapse 1, blast 11,
escape → Gx 1.0, N 1.896 → **−1.06, band −1**. Floor-only escapes land
≈ −0.59..−1.11 (the formula range under the locked constants for A ∈ [1, 2];
measured corpus max −1.06 at blast 11) — band −1 throughout.

### Per-class signed extremes (head vintage)

```
"Api::V1::RedeemTemplates": { "min": -4.52, "max": 3.42, "count": 9,
                              "n_negative": 1, "n_positive": 1, "headline": -4.52 }
```

Rank 1 of 374 classes by `min`. The one-class-two-poles example: a breakdown
monster AND an absorb booth in the same class; negative-first dominance
headlines the breakdown. Bottom-3 classes on the head vintage:
`Api::V1::RedeemTemplates` (−4.52), `Api::V1::PointsProducts` (−3.77),
`Api::V1::Feedbacks` (−3.04). The `PointsProducts` class-min node is
(`app/api/api/v1/points_products.rb`, `Api::V1::PointsProducts#POST[1]`),
collapse 1024, blast 1: full precision −3.774697 → published 2-dp −3.77
(score_raw −11.25, band −4).

### Equilibrium (the clean-PR contrast)

#2146's two NEW thin endpoints (branches 1 and 2, arity ≥ 1): G ≤ 1 →
G′ = 0 → **score 0, band 0**. Adding a use case as a new thin endpoint is
free — exactly the product contrast to #2083's inline growth.

## The absorption-headroom advisory (`absorb` / `absorb_raw`)

A SEPARATE advisory surface — never the score's positive pole, and never
folded into `score`. The toll-booth pole proves callers converge and that
bypassing is free; absorption headroom measures something complementary: how
much decision complexity sits in a node's IMMEDIATE callers relative to the
node's own downstream. A simple function whose direct callers are heavy, and
whose own subtree does not fan out, can absorb one shared caller-side
decision and make it linear (one place) instead of multiplexed (one copy per
caller path).

```
H          = log2(Σ over immediate callers of branches(caller)) − log2(V_now)
absorb     = 5 × (1 − e^(−H / ABSORB_DIVISOR))   # 2 dp, range (0, +5)
absorb_raw = H                                    # log2 units, 3 dp
```

The keys are ABSENT unless ALL eligibility clauses hold: at least 1 immediate
caller ∧ H > 0 ∧ not an escape ∧ **N = 0** (the load-bearing exclusivity
clause — an absorb candidate can never sit on the negative pole) ∧
V_now ≤ 4 (downstream smallness — the low-fan-out gate that prevents
re-multiplication). Immediate callers only, by design: only complexity
sitting in the direct callers around the call sites is absorbable into the
node in one step, and immediate-caller measures cannot be moved by distant
refactors (the churn-free property survives: 0 advisory band changes on
untouched inputs across consecutive vintages).

Why a separate tier (measured): only 9/20 top toll booths reach ≥ +3 under
headroom at any sane constant — `mass_savings` measures transitive traffic,
headroom measures local caller complexity; complementary, not nested. Folding
both into one number measurably degrades both signals.

**The advisory is a SIGNAL, not a guarantee — and it is honest about false
positives.** In the top-20 candidate inspection, ~4–5 of 20 were
trivial-accessor weak-FPs where the absorbable decision actually lives in a
sibling at the same call sites. The rendered copy is therefore hedged:
**"this function or a sibling at this call site could absorb caller-side
decisions"** — never a named-certainty claim about THIS function.

Client rendering law (the Q8 law extended): absorb copy renders only when
`score` ≥ 0. The `ReusabilityScore` rule's `absorb_min_score` param (default
+5) reads the `absorb` key — never the score — and the +5 routing incentive
is a presenter DISCLOSURE line, never a finding.

## Honest limits

- **The positive pole is ADVISORY.** `toll_booth × mass_savings` proves
  callers CONVERGE here and that absorbing/bypassing is free at zero variety
  cost — it does NOT prove the callers have similar logic. Caller-body
  similarity is not statically computable from the graph (no statement-level
  data); product copy may claim "callers converge here and absorbing shared
  logic is free", NEVER "callers have similar logic". (FP example on record:
  a memoized client factory reads as an absorb target; the compass's own
  advisory for the same signal is "bypass candidate" — same magnitude, and
  the action is a product decision: one diagnosis, two remedies.)
- **Escape nodes** (findings per-node key `escape`, emit-when-true): the
  engine's floor model says extraction cannot statically recover an escape's
  inline surface; the score flags them negative anyway (owner semantics) with
  the copy "inline surface above contract — NOT statically
  extraction-recoverable".
- **Saturation**: `score_band` pins at |5|; movement inside the poles reads
  only on `score_raw` (log2 units) — delta gates and value-pinned todos must
  use `score_raw` or ingredient deltas, never the clamped band. (The todo
  grammar pins debt-milli: `(−score_raw × 1000).round`.)
- **Seed dependence**: `blast` and `mass_savings` are entrypoint-relative. No
  live entrypoints → the amplifier goes quiet (A = 1, disclosed) and booth
  scores are null. Zero-arity graphs carry NO score surface at all — never a
  fabricated 0.
- **Stamp staleness (committed transport)**: committed fragments carry the
  LAST ANALYZE's scores (the v5-carry design), so a vintage's stamps can
  predate its tree. Per-side provenance is disclosed in every report;
  score-gating rules require analyze-fresh sides or degrade to disclosure.
  A node whose own body changed since its stamp is caught by the per-node
  consistency check; routing changes elsewhere (blast-only staleness) are
  undetectable client-side — a stated limit, not a solved problem.

## Product-copy law (Q8)

The compass quadrant (leverage × blast) labels the worst multiplexing
monsters "underused" — a measured product-copy hazard. The score is the
surface that cannot mislabel them. Five rules, all spec-gated client-side:

1. The score is the HEADLINE surface; the quadrant stays diagnostic.
2. "underused / reuse more" renders ONLY when `score` ≥ 0.
3. `bypass_candidate` + positive score renders the one-diagnosis-two-remedies
   copy: "under-utilized pass-through: absorb shared logic here, or bypass
   it — saves `mass_savings`".
4. `load_bearing` + negative score renders "protect the boundary, break down
   the inline surface".
5. NO node may render "reuse more" with `score` < 0 (asserted as a
   cross-surface presenter property spec).

## How this client surfaces it (0.14.0)

- **Stamps**: SERIALIZER v6 committed fragments carry the per-node triple
  verbatim (`score` / `score_band` / `score_raw`); pre-1.9 findings stamp
  honest nulls.
- **Reports**: the Business-Impact section gains a reusability-score
  question; the HTML report gains score columns and the per-class table
  (with the engine's `headline`).
- **Lint**: the 13th leaderboard key `reusability_score` (cone dominance,
  null when unstamped).
- **Review rule**: `ReusabilityScore`, the 8th family rule, default `:info`
  (advisory — it never fails a build at defaults). It fires when a fresh-
  stamped node in the rule universe (diff universe: NEW ∪ GROWN only) has
  `score ≤ min_score` (default −4). Thresholds gate engine-published values:
  a stamped score of exactly −4.0 fires `min_score: -4`; −3.99 stays quiet.
  `absorb_min_score` (default +5) drives the absorb disclosure line (see
  above). See `docs/CONFIGURATION.md` for params and todo grammar.
- **Deltas**: the diff envelope's `reusability` block carries per-side
  provenance and `score_raw`-based deltas (`delta_raw_milli`).

## Calibration: the constants (values verbatim from the engine's `Scoring::ScoreConstants`)

| constant | value | provenance (measured, never taste) |
|---|---|---|
| `DEADBAND` | 1.0 | one binary decision above contract width tolerated; with it, 35% of nodes have collapse > 1 but only ~14% land negative — collapse-2 nodes land exactly 0 (measured, 4 vintages) |
| `ESCAPE_FLOOR` | 1.0 | the escape-floor form (`Gx = escape ? max(G', 1) : G'`): 13/13 real escapes land negative at base AND head; reproduces the worst-escape anchor N=4.939 exactly |
| `AMP_DIVISOR` | 4.0 | spans A ∈ [1, 2] over the measured blast range (max blast 15 → A = 2.0, mono vintage `0146ad98`; p95 blast 3–4 → A ≈ 1.5–1.58) |
| `NEG_DIVISOR` | 8.0 | distribution-sanity pass on 4 vintages (mode-0 78.9–79.4%, ≤−3 0.33–0.36%, ≤−4 0.10–0.11%, −5 pole ≤ 0.055%); keeps the #2083 band delta visible (−4 → −5); the conservative arm |
| `POS_DIVISOR` | 3.0 | calibrated so the measured top-20 booth ms floor (6/7/7/8 across 4 vintages) clears +3.0 (ms ≥ 6 ⇔ real ≥ +3.039; exact real-+3.0 threshold ms ≥ 5.72); band +5 at ms ≥ 120 |
| `CLAMP` | 5 | the owner scale is −5..+5; published band = clamp(round-half-away(score), −5, +5); band +5 ⇔ ms ≥ 120, band −5 ⇔ N ≥ 18.421 |
| `RAW_ROUND` | 3 | `score_raw` published at 3 dp (the milli-log2 precedent) — the delta surface inside saturated \|5\| poles; the smallest real ingredient move measured (±1 mass_savings at ms=32) moves raw by 0.043 |
| `ABSORB_DIVISOR` | 5.0 | at divisor 5.0 under the V_now gate: absorb ≥ +3 = 3.61–3.66% and +5 ≤ 0.055% of scored nodes (4 vintages); +5 needs H ≥ 5·ln10 ≈ 11.51 — exactly 1 node at head, mirroring the booth pole's ms ≥ 120 rarity |
| `ABSORB_GATE_VNOW` | 4.0 | V_now ≤ 4 is the cleanest downstream-smallness gate — eligible 26.4–27.1% of scored nodes; gated-H p50 ≈ 2 / p90 = 4 / p99 = 6.58; exclusivity with the negative pole rides the N = 0 eligibility clause |

**Absolute constants, not percentiles**: percentile calibration lets
unrelated repo growth move untouched nodes' scores, breaking per-PR deltas
and value-pinned todos. The absolute encoding measured churn-free: zero score
changes on unchanged-ingredient nodes across consecutive vintages.
Recalibration = re-run the calibration probe on ≥ 3 current vintages and
re-lock against the distribution-sanity gates; percentile drift tables are
guidance for humans, never formula inputs. The calibration canon is
re-asserted on ENGINE-EMITTED findings (never a formula replica) by the
tier-4 backtest gates.

## Why these choices (the measured rationale)

| decision | shipped | the measured story |
|---|---|---|
| Negative divisor 8 (not 6) | 8.0 | both pass distribution sanity on 4 vintages; only 8 keeps the #2083 deterioration visible on the published band (−4 → −5; divisor 6 saturates −5/−5 and hides the direction in raw). Monster margins vs the ≤ −4.0 gate: −4.23 (d=8) vs −4.59 (d=6). |
| Escape handling = floor | `max(G', 1)` | 13/13 real escapes land negative at base AND head; the model-faithful alternative reads a 2^4-surface escape hub as 0 = "ideal", which contradicts the owner scale. |
| Conservative negative tail | kept | band −5 under divisor 8 needs N ≥ 18.42 — only the 2^16-collapse monster reaches it; aggressive tails would put collapse-16 escapes (−2.30 territory) at −5. |
| Multiplexer proxies | OFF (two-pole purity) | added-coupling proxy nodes land 0 unless collapse > 2; the seam stays one kwarg away engine-side. Revisit only if real proxies the owner expects negative sit at 0 in use. |
| Mode-0 ceiling kept tight | 80% (measured max 79.39%) | < 1pp headroom is deliberate: crossing it means the distribution genuinely drifted, which is the gate's job to catch. The remedy is documented recalibration, never band-widening. |
| Absorb: tier-split, not union | separate advisory surface | a union fold-in breaches distribution sanity at every tested constant except one with < 0.25pp margin; the split keeps both signals sharp (booth containment under headroom is only 9/20). |
| Absorb downstream gate | V_now ≤ 4 | the stricter ≤ 2 variant trades coverage for fewer weak-FPs; ≤ 4 ships because the N = 0 clause already carries pole exclusivity. |
| Absorb FP copy | hedged | ~4–5/20 top candidates are trivial-accessor weak-FPs, so the copy is "this function or a sibling at this call site could absorb caller-side decisions" — never named-certainty. |
