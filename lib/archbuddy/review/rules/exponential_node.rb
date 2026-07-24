# frozen_string_literal: true

require_relative "base"
require_relative "../rule_engine"

module Archbuddy
  module Review
    module Rules
      # The study-calibrated per-node flag (A1): own branching STRICTLY above
      # 2^threshold_log2 (default 5 — the frozen Q4 boundary; 32 does NOT
      # fire, 33 does; 2^k is exact in IEEE so no float hazard at the
      # boundary). Lint universe = all filtered vintage nodes; the diff-mode
      # NEW∪GROWN universe branch is added by the P2 lane ([S:§3] shared-edit
      # order). Universe is reachability-independent (Q8).
      class ExponentialNode < Base
        kind :node
        required_node_keys :branches
        needs_edges false

        def evaluate(ctx)
          ctx.universe_nodes.each do |node|
            next unless node.branches.is_a?(Integer) && node.branches >= 1

            threshold = ctx.rule_config(node.file)["threshold_log2"]
            log2 = Math.log2(node.branches)
            breaching = log2 > threshold
            ctx.node_result(
              node: node, value_raw: node.branches, breaching: breaching,
              message: breaching ? message(node.branches, log2, threshold) : nil,
              value_log2: log2,
              threshold_raw: (2**Float(threshold)).round, threshold_log2: threshold,
              refire_style: :branching
            )
          end
        end

        private

        def message(branches, log2, threshold)
          format("own branching %d (2^%.1f) exceeds 2^%g (Q4 boundary)",
                 branches, log2, threshold)
        end
      end

      RuleEngine.register("ExponentialNode", ExponentialNode)
    end
  end
end
