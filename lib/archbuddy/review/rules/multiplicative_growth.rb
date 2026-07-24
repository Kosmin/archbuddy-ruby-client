# frozen_string_literal: true

require_relative "base"
require_relative "../rule_engine"

module Archbuddy
  module Review
    module Rules
      # Diff-only growth catch: GROWN entries whose delta_log2 meets the
      # threshold (GTE — L11's letter; default 2). Never fires on NEW nodes
      # (that is ExponentialNode's diff jurisdiction), never grandfathered
      # (:delta kind — the engine hands it no todo), lint-inert per the
      # dispatch matrix. Universe is reachability-independent (Q8/[S:G4]).
      class MultiplicativeGrowth < Base
        kind :delta
        required_node_keys :branches

        TEMPLATE = "branching grew +%.1f log2 (%d → %d, 2^%.1f → 2^%.1f) — threshold +%g"

        def evaluate(ctx)
          allowed = ctx.universe_nodes.to_set { |n| [n.file, n.symbol] }
          ctx.delta.entries.each do |entry|
            next unless entry.classification == :grown
            next unless allowed.include?([entry.file, entry.symbol])

            rule_config = ctx.rule_config(entry.file)
            threshold = rule_config["max_increase_log2"]
            next if threshold.nil? || entry.delta_log2 < threshold # GTE fires

            head_branches = entry.head_branches
            ctx.add_finding(
              severity: rule_config.severity,
              file: entry.file, symbol: entry.symbol,
              kind: entry.head_node.respond_to?(:kind) ? entry.head_node.kind : nil,
              message: format(TEMPLATE, entry.delta_log2, entry.base_branches,
                              head_branches, Math.log2(entry.base_branches),
                              Math.log2(head_branches), threshold),
              value_raw: head_branches, value_log2: Math.log2(head_branches),
              delta_log2: entry.delta_log2, threshold_log2: threshold
            )
          end
        end
      end

      RuleEngine.register("MultiplicativeGrowth", MultiplicativeGrowth)
    end
  end
end
