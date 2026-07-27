# Recalibrating the advisory cost lines on YOUR repo

The builtin calibration (`builtin-study-v1`) was measured on ONE Rails/Grape
service lineage (n=433 merged PRs, 2025-10-22 → 2026-07-22). Every advisory
line says so. When your repo has enough history, replace it with your own
measurements via `calibration: {source: local}`. This document is the
procedure only — it points at no private data.

Small-n honesty: a repo with fewer than ~100 merged PRs should NOT
recalibrate — the quartile cuts and medians are noise at that scale; keep the
builtin provenance (which honestly says "not measured on this repository") or
use `source: none`.

## The 4-step recipe

1. **Fetch merged PRs** (any forge API; the study used
   `gh api 'repos/{org}/{repo}/pulls?state=closed'` pages): record per PR the
   merge latency (`merged_at - ready_for_review_at`, hours), churn
   (additions+deletions), base SHA, and merge SHA.
2. **Snapshot the base of each PR**: check the base SHA out into a TEMPORARY
   worktree, run `archbuddy collect <worktree>`, keep
   `archbuddy-findings.json` + `.archbuddy/`, remove the worktree
   (create → use → REMOVE; ~11 s per snapshot measured ≈ 80 min at 433-PR
   scale).
3. **Roll up per PR**: `T = max log2(branches)` over the PR-touched scored
   files at base (the leaderboard's `branching_log2` per-node inputs). Compute
   quartile cuts with `np.quantile(T, [0.25, 0.5, 0.75], method="linear")`;
   Q4 membership is STRICTLY above the third cut (ties assign low).
4. **Fit the latency model**: OLS
   `log(latency_hours+1) ~ const + T + log1p(churn)` with HC1 robust errors.
   `exp(beta_T)` is your `latency_multiplier_per_log2_unit`; the arm medians
   are `median(latency_hours)` for Q4-touching vs Q1-touching PRs.

## The cost-per-line recipe (ships WITH its number)

`median(latency_hours / churn)` per PR, Q4 arm vs Q1 arm, over the frozen T2
corpus (zero-churn rows excluded):

```
0.372231 / 0.146058 = 2.5485
```

That ratio is the builtin `cost_per_line_ratio_q4_vs_q1`. Recompute both
medians on your corpus and publish the division exactly like this — the
number never ships without its numerator and denominator.

## Writing the results into `.archbuddy.yml`

```yaml
calibration:
  source: local
  provenance: "measured on <repo>, n=<N> merged PRs, <start> → <end>, archbuddy <versions>"
  latency_multiplier_per_log2_unit: 1.08
  t_quartile_cuts: [2.0, 3.0, 5.0]
  cost_per_line_ratio_q4_vs_q1: 2.1
  latency_arm_medians_hours: [52.0, 19.5]
```

`provenance` is MANDATORY with `source: local` (config error without it — the
tool never renders unattributed numbers). Any value key you omit simply drops
its line from the output; nothing is backfilled from the builtin.

## Σ-component thresholds (self-serve percentiles)

Σ-component thresholds (`max_branching_log2`, `max_mass`, `max_reach`,
`max_files`, `max_depth`) ship unset. To tune them, run
`archbuddy lint --format json` on your own repo and read your leaderboard's
percentiles — the CONFIGURATION.md tables are one Rails/Grape lineage's
measurements (two services, three dates), not universal anchors.
