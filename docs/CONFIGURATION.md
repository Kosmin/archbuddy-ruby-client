# Configuring the archbuddy reviewer (`.archbuddy.yml` v1 + `.archbuddy_todo.yml` v1)

archbuddy prices **use cases and delivery cost, not function style**. The
rule family is organized around entrypoints (a use case = an entrypoint node:
`entrypoint: true` with an `entrypoint_kind` — grape/controllers/jobs/…), the
cost of changing what they reach, and the honest disclosure of what static
analysis cannot see.

## Quick start

No config file → **advisory**: everything evaluates, findings print, exit is
always 0. The moment a `.archbuddy.yml` exists, gating activates:

```yaml
version: 1
```

That bare file IS the starter policy: contains-Q4-node (warn) +
dividend ≥ 32 (warn) + FirewallBreaches escape counts (info) + ReviewSurface
disclosure + ExponentialNode / MultiplicativeGrowth (error) + ComplexityRatchet
(error, no budgets configured) + ReusabilityScore ≤ −4 (info, v0.16) — gating
at `fail_level: error`.

## Full example

```yaml
version: 1
all:
  fail_level: warn          # none|info|warn|error (default error when a config exists)
  format: terminal          # terminal|markdown|json
  include: ["app/**/*", "lib/**/*"]
  exclude: ["app/legacy/**/*"]
todo_file: .archbuddy_todo.yml
rules:
  ExponentialNode:
    threshold_log2: 5       # strict > 2^5 branches (the Q4 boundary)
  UseCaseComplexity:
    max_cone_node_log2: 5.0 # the ONLY set-by-default use-case threshold (strict >)
    max_branching_log2: null # sigma-thresholds ship UNSET — see the percentile tables
    max_mass: null
    max_depth: null
    max_reach: null
    max_files: null
    exclude_entrypoints: []
  UseCaseDividend:
    min_dividend: 32        # GTE — the one comparator deviation, deliberately
  FirewallBreaches:
    max_escapes: 0          # strict >; severity info in BOTH modes
  ReviewSurface:
    max_use_cases: null     # disclosure-only by default
  ReusabilityScore:
    min_score: -4           # v0.16 engine score gate: fires at score <= -4 (info)
    absorb_min_score: 5     # absorption disclosure line at absorb >= +5 (never a finding)
  MultiplicativeGrowth:
    max_increase_log2: 2
  ComplexityRatchet:
    budgets:
      - { paths: ["app/api/**/*"], max_increase_log2: 0.0 }
      - { entrypoints: ["Api::V1::Widgets#PATCH[0]"], max_increase_log2: 0.0 }
overrides:
  - paths: ["app/experimental/**/*"]
    rules:
      UseCaseComplexity: { severity: info }
calibration:
  source: builtin-study-v1  # builtin-study-v1|local|none — see docs/RECALIBRATION.md
```

Globs are **target-relative** (the directory you lint, not your cwd) and use
`File.fnmatch` with extglob.

## The rule family (business taxonomy)

Eight rules, four kinds. `kind` decides the universe, the mode dispatch, and
whether the todo applies (grandfatherable = node + use_case kinds only).

| rule | kind | default | severity | parameters |
|---|---|---|---|---|
| UseCaseComplexity | use_case | enabled | warn | `max_cone_node_log2` (5.0, strict >), `max_branching_log2`, `max_mass`, `max_depth`, `max_reach`, `max_files` (all null = unset), `exclude_entrypoints` |
| UseCaseDividend | use_case | enabled | warn | `min_dividend` (32, **GTE** — both boundary sides spec-asserted), `exclude_entrypoints` |
| FirewallBreaches | use_case | enabled | info | `max_escapes` (0, strict >), `exclude_entrypoints` |
| ReviewSurface | pr | enabled | warn | `max_use_cases` (null = disclosure only) |
| ExponentialNode | node | enabled | error | `threshold_log2` (5, strict > 2^5 branches) |
| ReusabilityScore | node | enabled | info | `min_score` (−4, fires at score ≤ min_score; min bound −5), `absorb_min_score` (5, gates the absorption disclosure line — never a finding) |
| MultiplicativeGrowth | delta | enabled | error | `max_increase_log2` (2) |
| ComplexityRatchet | delta | enabled | error | `budgets` ([]; each budget: `paths:` XOR `entrypoints:` + `max_increase_log2` + optional `severity`) |

Mode dispatch: `lint` evaluates node + use_case kinds (FirewallBreaches in
count mode) — delta/pr rules are lint-inert except the ratchet's context
entries; `diff` evaluates all four kinds (FirewallBreaches in event mode,
UseCaseComplexity/UseCaseDividend on head-side levels of metric-moved
entrypoints only).

`own_branching_log2` is **reported, never thresholded** — no config key
exists for it (ExponentialNode owns that tail; no double-fire).

### ReusabilityScore (v0.16)

The one rule whose value the client never computes: the −5..+5 per-function
reusability score is **engine-served** (findings 1.9, engine ≥ 0.11.0) and
stamped into the committed cache at analyze time. Negative = false
reusability / extreme multiplexing — break it down before growing it;
0 = equilibrium; positive = a routing point where callers converge and
absorption is free at zero variety cost (the copy never claims callers have
similar logic — that is not statically computable). The rule fires when a
node's stamped `score` ≤ `min_score` (default −4, engine-published 2 dp
values; `min_score` accepts down to −5) and the stamp is node-fresh; stale
stamps degrade to a disclosure, never a finding and never a fabricated
number. `absorb_min_score` (default +5) gates the separate
absorption-headroom **disclosure line** — it reads the engine's advisory
`absorb` key and never produces a finding. Default severity `:info` =
advisory under the default fail level; opt into gating with
`severity: error` + `fail_level: error`. Score model, formula constants,
and worked examples: [`docs/REUSABILITY_SCORE.md`](REUSABILITY_SCORE.md).

### `exclude_entrypoints` (emission-only, anti-gaming)

Matches the ENTRYPOINT SYMBOL: exact string equality FIRST, then fnmatch.
Grape symbols contain `[0]` — a character CLASS under bare fnmatch — so
`"Api::V1::Widgets#PATCH[0]"` matches by exact string (write it verbatim, no
escaping). Every exclude affects EMISSION only: cone membership, component
values, leaderboard rows, and review-surface counts never change.

Worked example (anti-gaming): excluding the redeem endpoint drops the
UseCaseComplexity finding —

```yaml
rules:
  UseCaseComplexity:
    exclude_entrypoints: ["Api::V1::RedeemTemplates#PATCH[0]"]
```

— but the leaderboard still ranks that endpoint first and the diff's review
surface still counts it. You can silence the finding; you cannot shrink the
number.

## Retired rules

Six v0.14-era rule names were retired by the business-taxonomy conversion.
Using one anywhere (`rules.*`, overrides, the todo) is a validation error
naming the successor, e.g.:

```
unknown rule 'MaxBranching' at rules — retired: absorbed into UseCaseComplexity (set max_branching_log2); see docs/CONFIGURATION.md#retired-rules
```

| retired name | disposition | successor |
|---|---|---|
| MaxBranching | absorbed | `UseCaseComplexity.max_branching_log2` |
| MaxFunctionMass | absorbed | `UseCaseComplexity.max_mass` |
| MaxDepth | absorbed | `UseCaseComplexity.max_depth` |
| MaxOutDegree | dropped | reach/files components (reported, unset by default: `max_reach` / `max_files`) |
| NoNewEscapes | absorbed | FirewallBreaches diff mode (identical event universe) |
| NoNewTollBooths | dropped | toll-booth data remains a leaderboard/enrichment diagnostic column |

## Per-entrypoint distributions (measured)

Tuning guidance for the ship-unset Σ-thresholds. Percentiles via
`np.quantile(..., method="linear")`.

**mono `0146ad98…` (n=326 entrypoints)**

| metric | p50 | p75 | p90 | p95 | p99 | max | mean |
|---|---|---|---|---|---|---|---|
| branching_log2 (Σ cone) | 1.5 | 4.0 | **9.0** | 15.896 | 42.5 | 55.585 | 3.832 |
| mass (call sites) | 16.5 | 32.75 | **61.5** | 125.75 | 261.0 | 303 | 30.571 |
| reach (in-tree nodes) | 2.0 | 3.0 | **9.0** | 17.0 | 29.75 | 41 | 3.902 |
| files (edit scatter) | 1.0 | 1.0 | **2.0** | 3.0 | 3.0 | 4 | 1.328 |
| depth (hops to sink) | 2.0 | 3.0 | **5.0** | 7.0 | 8.75 | 10 | 2.359 |
| dividend (V_now/V_floor) | 2.0 | 4.0 | **8.0** | 16.0 | 104.0 | 131072 | 409.9 |
| ep own log2(b_own) | 1.0 | 2.0 | 3.0 | 4.0 | 6.5 | 17.0 | 1.329 |
| max_cone_node_log2 | 1.0 | 2.0 | 4.0 | 5.0 | 6.75 | 17.0 | 1.729 |

**old `68abf831…` (n=254 entrypoints)**

| metric | p50 | p75 | p90 | p95 | p99 | max |
|---|---|---|---|---|---|---|
| branching_log2 | 1.0 | 3.896 | 9.0 | 14.555 | 41.94 | 53.0 |
| mass | 15.0 | 28.75 | 57.0 | 123.75 | 254.28 | 292 |
| reach | 2.0 | 3.0 | 8.0 | 17.35 | 31.35 | 41 |
| files | 1.0 | 1.0 | 2.0 | 3.0 | 3.0 | 4 |
| depth | 2.0 | 3.0 | 5.7 | 7.0 | 9.0 | 10 |
| dividend | 2.0 | 4.0 | 8.0 | 16.0 | 77.12 | 8192 |
| max_cone_node_log2 | 1.0 | 2.896 | 4.0 | 5.0 | 6.47 | 13.0 |

**old reference `7eca35c6…` (n=282 entrypoints)**

| metric | p50 | p75 | p90 | p95 | p99 | max |
|---|---|---|---|---|---|---|
| branching_log2 | 2.0 | 4.0 | 9.0 | 16.0 | 41.38 | 53.0 |
| mass | 16.0 | 32.0 | 60.7 | 128.0 | 248.37 | 300 |
| reach | 2.0 | 3.0 | 8.0 | 17.95 | 29.95 | 41 |
| files | 1.0 | 1.75 | 2.0 | 3.0 | 3.19 | 5 |
| depth | 2.0 | 3.0 | 5.9 | 7.0 | 9.0 | 10 |
| dividend | 2.0 | 4.0 | 8.0 | 16.0 | 50.24 | 65536 |
| max_cone_node_log2 | 1.0 | 3.0 | 4.0 | 5.0 | 7.19 | 16.0 |

The distributions are remarkably stable across two services and three dates
(p90 branching_log2 = 9.0 on all three; dividend p95 = 16 on all three; files
p90 = 2 everywhere).

Measured flag rates at candidate defaults:

| candidate trigger | mono0146 | old2083base | oldref |
|---|---|---|---|
| cone contains Q4 node (max_cone_node_log2 > 5.0 strict) | 6/326 (**1.8%**) | 5/254 (2.0%) | 6/282 (2.1%) |
| dividend ≥ 32 | 10/326 (**3.1%**) | 7/254 (2.8%) | 8/282 (2.8%) |
| branching_log2 ≥ 9 (p90) | 35/326 (**10.7%**) | 27/254 (10.6%) | 32/282 (11.3%) |

measured on one Rails/Grape codebase lineage (two services, three dates,
2025-10 → 2026-07); NOT cross-ecosystem evidence — tune from your own
leaderboard (see docs/RECALIBRATION.md).

Why Σ-thresholds ship unset: a p90 anchor flags ~10% of entrypoints **by
construction** — a repo-state percentile, not outcome evidence — and the
leaderboard already delivers the ranking signal a threshold would duplicate.
The two default-on triggers carry their pedigree labels: contains-Q4-node is
the **outcome-measured** arm (the study's latency/bugfix evidence anchors the
2^5 boundary); dividend ≥ 32 is **pinned + labeled** (2× the cross-vintage
p95, rhyming with the Q4 boundary), not outcome-measured.

## What the numbers can and cannot see

- **Floors under dynamic dispatch:** mass/files/reach (and therefore
  ReviewSurface) are floors where calls resolve to `<external:…>`; the
  study's 2^16 use case has a 1-file cone — its model calls resolve
  dynamically; its variety number is exact (own inline branching), its reach
  is a floor.
- **Cross-endpoint coupling** through shared DB/state is outside static
  scope — never silently implied.
- **Unreached code carries no UseCaseComplexity/Dividend price** (the
  measured share is large — 58–67% of nodes across the study vintages); it
  stays policed by ExponentialNode, MultiplicativeGrowth, FirewallBreaches
  events, and ratchet path budgets (reachability-independent universes).
- escape hatches carry no measured cost line — the 2025-10 → 2026-07 study
  did not measure escape outcomes; the rule reports counts only.

### Vocabulary: "not reachable from any entrypoint"

Product copy is **"not reachable from any entrypoint"**; the JSON key is
`summary.unreachable_from_entrypoints` (`{nodes, share, files}`), present in
BOTH commands and ABSENT (not null) when fragments carry no edges or the
vintage has zero entrypoints. Mapping note: the engine's own metrics call
this `dead` (its `orphan` means in-degree-0) — archbuddy surfaces never use
bare "orphan" for nodes.

Zero-entrypoint degenerate: use-case rules report
`not_evaluable: vintage has no entrypoints (nothing is reachable — check
collector entrypoint detection)` — NEVER "everything is unreachable".

## Gating, advisory, exit codes

| exit | meaning |
|---|---|
| 0 | pass, or advisory (no config file / `--advisory` / `fail_level: none`) |
| 1 | ≥1 finding at or above the effective fail level (default `error` once a config exists) |
| 2 | tool/config error (validation failure, unresolvable ref, bad flags) |

Precedence: CLI flags > config `all:` block > defaults. `--fail-level`
overrides the config; `--advisory` forces `none`.

## The todo document (`.archbuddy_todo.yml` v1 — value-pinned grandfathering)

Generate with `archbuddy lint --auto-gen-todo` (add `--stamp` for a
timestamp). Two entry shapes:

```yaml
version: 1
tool: "archbuddy 0.13.0"
rule_count: 3
node_count: 1
rules:
  ExponentialNode:
    - node: "app/api/things.rb: Api::Things#update"
      value: 64                      # node kind: ONE raw integer (branches)
  ReusabilityScore:
    - node: "app/api/things.rb: Api::Things#update"
      value: 11250                   # node kind: debt milli ((-score_raw × 1000).round)
  UseCaseComplexity:
    - node: "app/api/things.rb: Api::Things#update"
      values: { max_cone_node_millilog2: 6000 }   # use-case kind: per-metric map
```

Values are raw integers: native counts (mass, depth, reach, files, escapes,
branches), **milli-log2** (`(log2 × 1000).round`) for `*_millilog2` keys, or
— for `ReusabilityScore` — **debt milli** (`(−score_raw × 1000).round`, a
positive integer that grows as the node worsens, so regressing past the
pinned value re-fires) — integer comparison only, no float ever enters the
skip predicate. Generation records BREACHING components only, at their
current values.

Per-metric lifecycle (each set-threshold component independently): not
breaching → counts toward healed; breaching + not recorded → fires;
breaching + current ≤ recorded → skip; breaching + current > recorded →
re-fire (`worst cone node grew past grandfathered baseline 64 (2^6.0) → 128
(2^7.0)`). One finding per (rule, entrypoint) aggregates the clauses.

Grandfatherable: ExponentialNode, FirewallBreaches, ReusabilityScore,
UseCaseComplexity, UseCaseDividend. ComplexityRatchet / MultiplicativeGrowth /
ReviewSurface are never grandfathered.

Entrypoint renames: an ep rename is remove+add (measured metric-neutral —
net Δ +0.000000 on a real rename PR); the todo entry heals and the new symbol
fires fresh; ratchet `entrypoints:` budgets on the old symbol report
`no_match` — move the config with the rename.

## Calibration

`calibration:` block reference: `source: builtin-study-v1` (default),
`local` (mandatory `provenance`, value keys optional — missing keys drop
their lines), `none` (all advisory lines suppressed). Advisory copy only —
calibration NEVER gates. Recipe: docs/RECALIBRATION.md.

## Boundary (`boundary:` — collect-time, opt-in)

Declares that a call crosses OUT of your tree, at three granularities
(most-specific wins: `calls` > `classes` > `paths`). Consumed by `collect`,
merged over the engine-shipped profile's own boundary section; absent means
today's behaviour, unchanged.

```yaml
boundary:
  paths:
    - glob: "vendor/**/*.rb"
      category: gem
  classes:
    - kind: ancestor_of        # constant_exact | constant_prefix | ancestor_of
      values: ["Vendor::Base"]
      category: gem
  calls:
    - receiver: { kind: constant_exact, values: ["Payments::Gateway"] }
      verbs: ["charge"]
      category: http
      role: action             # action | configuration | no_io — CALL RULES ONLY
```

This key is **not described by this repo**. It is validated against the
`boundary` sub-schema of the engine's framework-profile contract, so a project
cannot invent grammar the profile does not have: an unknown key anywhere under
`boundary:` — including `role:` on a `paths`/`classes` rule — is rejected by
that schema's `additionalProperties`, naming the offending key path.

`category` must be one of the engine's terminal kinds; that membership is
checked when the rules are compiled, with the allowed set named in the error.
A rule with no `category` still severs the call, but stamps no category
(absent, never defaulted).

**One boundary per repo root.** Declaring a *sequence* of boundaries for one
root is refused with an error naming the supported shape: separate roots
already get separate `.archbuddy/` workspaces, so audit each component by
running archbuddy at that component's root.

A malformed `boundary:` **fails the `collect` run** (exit 1) with the offending
key named — it is never ignored, because a silently dropped declaration emits a
graph indistinguishable from a correct one. `collect` reads the `.archbuddy.yml`
at the target root only (no ancestor walk), and records the override's digest in
the machine-local collect manifest, so a cache built under one boundary is never
served for a run under another.

## Worked example: linting a real committed cache

```sh
bundle exec exe/archbuddy lint /path/to/your-repo --trust-cache --format json
```

`--trust-cache` here (a) exercises the escape hatch + its loud stderr warning
end-to-end, (b) pins the run to the EXISTING cache so source counts compare
like-for-like with an independent read of `archbuddy-findings.json`, and (c)
skips a needless collect. The DEFAULT path (no flag) fresh-collects **to a
scratch directory** when the working-tree cache cannot be verified fresh —
the target is never mutated either way.

Observables on this machine (2026-07): exit 0 (no `.archbuddy.yml` →
advisory), 47 sources, serializer 5, `use_cases.count` 29,
`summary.unreachable_from_entrypoints` = 83 of 123 nodes (67.5% — a normal
share; most code is helpers), leaderboard sorted branching_log2 DESC.

## Enrichment (`analyze`-first recipe)

Fragments carry the engine's compass stamps (quadrant/toll_booth/leverage/
collapse) only after an `archbuddy analyze` run wrote them. Run
`archbuddy analyze <target>` before `lint` when you want findings enriched
with those fields; without them findings carry an empty enrichment — never a
fabricated one.
