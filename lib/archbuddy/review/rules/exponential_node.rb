# frozen_string_literal: true

require "set"
require_relative "base"
require_relative "../rule_engine"

module Archbuddy
  module Review
    module Rules
      # The study-calibrated per-node flag (A1): own branching STRICTLY above
      # 2^threshold_log2 (default 5 — the frozen Q4 boundary; 32 does NOT
      # fire, 33 does; 2^k is exact in IEEE so no float hazard at the DEFAULT
      # boundary — but log2 of a non-power-of-2 vs a user-set threshold is
      # not, so the gate reads published precision like every rule, M14).
      # Lint universe = all filtered vintage nodes; diff universe
      # = NEW ∪ GROWN entries ONLY ([S:G4] — unchanged monsters in touched
      # files stay lint's + the todo's jurisdiction; SHRUNK-but-still-huge
      # never fires in diff, reduction is the desired direction). Universe
      # is reachability-independent (Q8).
      class ExponentialNode < Base
        kind :node
        required_node_keys :branches
        needs_edges false

        def evaluate(ctx)
          universe(ctx).each do |node|
            next unless node.branches.is_a?(Integer) && node.branches >= 1

            threshold = ctx.rule_config(node.file)["threshold_log2"]
            log2 = Math.log2(node.branches)
            breaching = published(log2) > threshold # published precision (M14)
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

        def universe(ctx)
          return ctx.universe_nodes unless ctx.mode == :diff

          allowed = ctx.universe_nodes.to_set { |n| [n.file, n.symbol] }
          ctx.delta.entries.filter_map do |entry|
            next unless %i[new grown].include?(entry.classification)

            node = entry.head_node
            node if node && allowed.include?([node.file, node.symbol])
          end
        end

        def message(branches, log2, threshold)
          format("own branching %d (2^%.1f) exceeds 2^%g (Q4 boundary)",
                 branches, log2, threshold)
        end
      end

      RuleEngine.register("ExponentialNode", ExponentialNode)
    end
  end
end
