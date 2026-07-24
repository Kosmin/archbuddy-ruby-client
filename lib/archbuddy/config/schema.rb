# frozen_string_literal: true

module Archbuddy
  class Config
    # The declarative heart of `.archbuddy.yml` schema v1 (v0.15 — the SEVEN
    # Q11 business-taxonomy rules): known-key registry, per-rule param specs
    # with defaults/types/enums, starter severities, severity ranking, kind
    # partitions, the retired-name table, and the todo metric registry.
    # Validator, engine, docs, and specs all read THIS one source of truth.
    module Schema
      # Common per-rule keys valid on every rule (params below are per-rule).
      COMMON_RULE_KEYS = %w[enabled severity exclude].freeze

      # The SEVEN rule classes, names EXACT (Q11). kind ∈
      # {:node, :use_case, :delta, :pr} (I-P7').
      RULES = {
        "ComplexityRatchet" => {
          kind: :delta, default_enabled: true, default_severity: :error,
          metric_unit: :log2_units,
          params: {
            "budgets" => { type: :budgets, default: [] }
          }
        },
        "ExponentialNode" => {
          kind: :node, default_enabled: true, default_severity: :error,
          metric_unit: :branches,
          params: {
            "threshold_log2" => { type: :number, default: 5, min: 0, nullable: false }
          }
        },
        "FirewallBreaches" => {
          kind: :use_case, default_enabled: true, default_severity: :info,
          metric_unit: :escapes,
          params: {
            "max_escapes" => { type: :integer, default: 0, min: 0, nullable: false },
            "exclude_entrypoints" => { type: :array_of_strings, default: [] }
          }
        },
        "MultiplicativeGrowth" => {
          kind: :delta, default_enabled: true, default_severity: :error,
          metric_unit: :log2_units,
          params: {
            "max_increase_log2" => { type: :number, default: 2, min: 0, nullable: false }
          }
        },
        "ReviewSurface" => {
          kind: :pr, default_enabled: true, default_severity: :warn,
          metric_unit: :use_cases,
          params: {
            # Disclosure-only default (Q11): the review_surface block always
            # renders when enabled+evaluable; null never gates.
            "max_use_cases" => { type: :integer, default: nil, min: 0, nullable: true }
          }
        },
        "UseCaseComplexity" => {
          kind: :use_case, default_enabled: true, default_severity: :warn,
          metric_unit: :ep_metrics,
          params: {
            # The ONLY set-by-default use-case threshold (Q11) — strict >.
            "max_cone_node_log2" => { type: :number, default: 5.0, min: 0, nullable: true },
            "max_branching_log2" => { type: :number, default: nil, min: 0, nullable: true },
            "max_mass" => { type: :integer, default: nil, min: 0, nullable: true },
            "max_depth" => { type: :integer, default: nil, min: 0, nullable: true },
            "max_reach" => { type: :integer, default: nil, min: 0, nullable: true },
            "max_files" => { type: :integer, default: nil, min: 0, nullable: true },
            "exclude_entrypoints" => { type: :array_of_strings, default: [] }
          }
        },
        "UseCaseDividend" => {
          kind: :use_case, default_enabled: true, default_severity: :warn,
          metric_unit: :ep_metrics,
          params: {
            # GTE — the ONE pinned deviation from the strict-> family
            # convention, per Q11's "≥32" letter.
            "min_dividend" => { type: :number, default: 32, min: 1, nullable: true },
            "exclude_entrypoints" => { type: :array_of_strings, default: [] }
          }
        }
      }.freeze

      # Kind partitions (R48).
      NODE_RULES = %w[ExponentialNode].freeze
      USE_CASE_RULES = %w[FirewallBreaches UseCaseComplexity UseCaseDividend].freeze
      DELTA_RULES = %w[ComplexityRatchet MultiplicativeGrowth].freeze
      PR_RULES = %w[ReviewSurface].freeze
      GRANDFATHERABLE = (NODE_RULES + USE_CASE_RULES).sort.freeze

      # The six retired v0.14 names (Q11) — checked BEFORE did-you-mean at
      # `rules.*`, in the todo loader, and in overrides. Error template:
      #   unknown rule '<name>' at <path> — retired: <guidance>;
      #   see docs/CONFIGURATION.md#retired-rules
      RETIRED_RULES = {
        "MaxBranching" => "absorbed into UseCaseComplexity (set max_branching_log2)",
        "MaxFunctionMass" => "absorbed into UseCaseComplexity (set max_mass)",
        "MaxDepth" => "absorbed into UseCaseComplexity (set max_depth)",
        "MaxOutDegree" => "dropped: use UseCaseComplexity max_reach / max_files",
        "NoNewEscapes" => "absorbed into FirewallBreaches (its diff mode)",
        "NoNewTollBooths" => "dropped: toll-booth data remains a leaderboard/enrichment diagnostic"
      }.freeze

      # Todo metric registry (Q7): the per-metric `values:` keys each
      # grandfatherable USE_CASE rule may record. `*_millilog2` keys carry
      # `(metric_log2 × 1000).round`; the rest are native counts.
      EP_METRIC_KEYS = {
        "UseCaseComplexity" => %w[branching_millilog2 depth files mass max_cone_node_millilog2 reach].freeze,
        "UseCaseDividend" => %w[dividend_millilog2].freeze,
        "FirewallBreaches" => %w[escapes].freeze
      }.freeze

      TOP_LEVEL_KEYS = %w[version todo_file all rules overrides calibration].freeze
      ALL_KEYS = %w[exclude include fail_level format].freeze
      CALIBRATION_KEYS = %w[
        source provenance latency_multiplier_per_log2_unit latency_multiplier_ci95
        t_quartile_cuts cost_per_line_ratio_q4_vs_q1 bugfix_rate_ratio_q4_vs_q1
        latency_arm_medians_hours
      ].freeze

      SEVERITIES = { info: 1, warn: 2, error: 3 }.freeze
      FAIL_LEVELS = %w[none info warn error].freeze
      FORMATS = %w[terminal markdown json].freeze
    end
  end
end
