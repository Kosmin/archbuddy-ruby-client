# archbuddy backtest — the adoption document

Toolchain: client 0.12.0, engine 0.10.0, serializer 5.
Corpus: n=433 merged PRs, two repos (thanx/thanx-merchant-api-new,
thanx/nexus services/merchant-api), window 2025-10-22 → 2026-07-22.

> IN-SAMPLE DISCLOSURE: the ExponentialNode threshold (strictly > 2^5) is this same corpus's frozen Q4 boundary; Tier 1 restates the study through the tool's read/rollup/flag path and is NOT out-of-sample validation. Its non-circular content: the cross-implementation reproduction (Tier 0) and the flag RATE — the adoption noise cost.

> All outcome associations are observational, not causal: complex code attracts
> harder changes; no randomization was performed.

## 2. The adoption pitch (Tier 1)

| metric | Q4-touch flagged | Q1 unflagged | ratio | source |
|---|---|---|---|---|
| flag rate | 21/239 edit = 8.8% (21/433 = 4.8% of all) | — | — | tier1.json |
| median merge latency | 69.8 h | 21.9 h | ×3.2 | tier1.json medians |
| review-window hours per changed line | 0.372 | 0.146 | ×2.5 | h2_pr_table.csv medians (0.372231/0.146058) |
| bugfix rate per kLOC-month | 0.342 | 0.107 | ×3.19 (directional: bugfix labels failed the study's validation bar) | excess-bugfix worklist |
| P(Q4 PR slower than Q1 PR) | 66.6% | — | Cliff's δ 0.331 | results/h2_arm_mw.json |

### 2b. The use-case leaderboard of the study era

| rank | ep | kind | branching_log2 | mass | reach | files | depth | dividend | max_cone_node_log2 | cost_note |
|---|---|---|---|---|---|---|---|---|---|---|
| 1 | Api::V1::Campaigns::Requirements#GET[0] | grape | 53.0 | 300 | 41 | 3 | 10 | 1.0 | 4.0 | — |
| 2 | Api::V1::PointsProducts#PATCH[0] | grape | 48.585 | 293 | 37 | 3 | 8 | 4.0 | 5.585 | contains a Q4-boundary node |
| 3 | Api::V1::AppLandingPageThemes#PUT[0] | grape | 43.0 | 244 | 29 | 3 | 9 | 16.0 | 5.0 | — |
| 4 | Api::V1::Campaigns#PATCH[0] | grape | 41.0 | 267 | 34 | 2 | 7 | 8.0 | 5.0 | — |
| 5 | Api::V1::AppLandingPageThemes::NavigationTabs#PUT[0] | grape | 40.585 | 202 | 27 | 2 | 9 | 4.0 | 5.0 | — |
| 6 | Api::V1::Promotions#PATCH[0] | grape | 31.585 | 137 | 11 | 2 | 5 | 4.0 | 8.0 | contains a Q4-boundary node |
| 7 | Api::V1::AppOnboardingSlideshow#PUT[0] | grape | 27.0 | 141 | 19 | 3 | 9 | 2.0 | 5.0 | — |
| 8 | Api::V1::AppLandingPage::Headers#PUT[0] | grape | 25.0 | 128 | 18 | 3 | 8 | 2.0 | 5.0 | — |
| 9 | Api::V1::AppLandingPage::Links#PUT[0] | grape | 25.0 | 128 | 18 | 3 | 8 | 2.0 | 5.0 | — |
| 10 | Api::V1::OrderingLinks#PUT[0] | grape | 25.0 | 131 | 18 | 3 | 8 | 2.0 | 5.0 | — |

PR #2083 grew one use case's argument surface from 2^13 to 2^16 in a single change; at the end of the study window that use case was still the repo's #1 extraction target (dividend ×65536 — all of it inline decisions), and after the port into nexus it had grown again to 2^17 (measured at pr_base `0146ad98…`).

leaderboard values are repo-state inventory, not outcome calibration.

## 3. Tier 2 — delta-rule replay

| rule | n fired | median latency fired (h) | median latency not fired (h) |
|---|---|---|---|
| ComplexityRatchet | 0 | — | 43.58 |
| ExponentialNode | 9 | 71.91 | 41.62 |
| FirewallBreaches | 5 | 166.9 | 43.1 |
| MultiplicativeGrowth | 19 | 25.58 | 43.93 |
| ReviewSurface | 0 | — | 43.58 |
| UseCaseComplexity | 24 | 66.29 | 43.165 |
| UseCaseDividend | 22 | 91.185 | 38.915 |

Method: (pr_base, merge) pairs restricted to PR-touched files; residual confound — another PR merged in the same window touching the SAME file can contribute; sensitivity mode `--pairs merge-parent` isolates PRs exactly at double collect cost.

The trap, demonstrated live: the same #2083 pair UNRESTRICTED yields net +14.0 log2 (global churn) vs the PR-scoped +3.0 — the number that justifies merge-base isolation in live CI.

ReviewSurface ∪ distribution (merge-parent sweep, n=430): p50=0, p75=0, p90=2, p95=4, p99=10, max=15.

All outcome associations are observational, not causal: complex code attracts harder changes; no randomization was performed.

File-level diagnostic: rs2083_file_level = {union: 5, sum: 11} — file-level variant — inflated by an unchanged shared helper (`#collection`, blast 5); diagnostic only, not the rule's number

## 4. Tier 3 — ratchet counterfactual (7 scope PRs)

| PR | merged_at | Δ scope Σlog2 | verdict (budget 0) | verdict (budget -1) |
|---|---|---|---|---|
| thanx/thanx-merchant-api-new#2004 | 2025-12-12T15:17:38Z | 0.0 | pass | breach |
| thanx/thanx-merchant-api-new#2063 | 2026-02-17T16:37:28Z | 0.0 | pass | breach |
| thanx/thanx-merchant-api-new#2083 | 2026-02-17T16:41:46Z | 3.0 | breach | breach |
| thanx/thanx-merchant-api-new#2075 | 2026-02-18T18:00:46Z | 0.0 | pass | breach |
| thanx/nexus#154 | 2026-05-07T23:39:17Z | 0.0 | pass | breach |
| thanx/nexus#453 | 2026-06-15T19:45:46Z | 1.0 | breach | breach |
| thanx/nexus#579 | 2026-06-29T21:29:44Z | 0.0 | pass | breach |

Entrypoints-budget variant (`Api::V1::RedeemTemplates#PATCH[0]` at budget +0.000, the clean (merge^1, merge) pair): verdict **breach**, observed +3.000.

## 5. Worked examples (the Q5 canon)

Node-level (#2083): `Api::V1::RedeemTemplates#PATCH[0]` 8192 → 65536 branches (Δ +3.000 log2); restricted scope net +3.000 breaches a 0-budget ratchet; exit 1.

| ep metric | merge^1 | merge |
|---|---|---|
| branching_log2 | 13.0 | 16.0 |
| mass | 73 | 83 |
| reach/files/depth | 2/1/2 | 2/1/2 |
| V_now | 2^13 | 2^16 |
| V_floor | 2^0 | 2^0 |
| dividend | ×8192 | ×65536 |
| review surface | ∪=1/Σ=1 | |

What clean looks like (#2146): 2 NEW use cases (GET[0] {0.0, mass 7}, PATCH[0] {1.0, mass 22}), net +1.000, RS ∪=2 — landing it required re-verifying nothing pre-existing.

## 6. Gates (19)

| gate | value |
|---|---|
| t0_rollup_433 | true |
| t1_flag_set_q4 | true |
| pr2083_net_3000 | true |
| pr2083_grown_patch0 | true |
| pr2083_new_b1 | true |
| pr2083_fires_exp_growth | true |
| pr2083_trap_14 | true |
| uc2083_branching_13_16 | true |
| uc2083_dividend_8192_65536 | true |
| uc2083_mass_73_83 | true |
| uc2083_shape_stable | true |
| rs2083_union_1_sum_1 | true |
| rs2146_union_2_sum_2 | true |
| uc2146_new_ep_values | true |
| pr2083_cli_blocked | true |
| pr2146_cli_clean | true |
| t3_seven_prs | true |
| t3_ep_budget_breach | true |
| author_scan_clean | true |

## 7. Method + privacy appendix

Read-only corpus; per-file column whitelist (author columns unreachable by construction); id-map never read; head scores cached under gitignored tmp/; worktrees created → used → REMOVED per run; base reads ≈ 2 s from committed caches vs 35.4 s/side stateless collect (measured).

Merge-parent sensitivity appendix: the one-shot `--pairs merge-parent` sweep feeds both the sensitivity check and the ReviewSurface distribution above (double collect cost, documented).
