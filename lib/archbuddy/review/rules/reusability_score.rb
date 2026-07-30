# frozen_string_literal: true

require "set"
require_relative "base"
require_relative "../rule_engine"
require_relative "../score_rollup"

module Archbuddy
  module Review
    module Rules
      # The 8th family rule (v0.16, D-C4): the engine-served −5..+5 per-node
      # reusability score, gated at `score <= min_score` (default −4) over
      # FRESH v6 stamps only. Default severity :info — advisory at the
      # default fail level; gating is the L7 opt-in (`severity: error` +
      # `fail_level: error`). The client NEVER computes a score (L2/D17):
      # `score` (2 dp) and `score_raw` (3 dp) are engine-published values
      # copied verbatim from the committed stamps.
      #
      # M14 conformance (rules/base.rb:41-58, esp. the ComplexityRatchet
      # precedent at base.rb:49): every user-set threshold gates at PUBLISHED
      # precision. This rule complies BY CONSTRUCTION — the stamped
      # `score`/`score_raw` are engine-published-rounded (2 dp/3 dp) BEFORE
      # stamping, so the gate channel is already the published channel; do
      # NOT wrap with Base#published (a round(6) no-op that would imply a
      # raw-float hazard that structurally cannot exist here). D-C5's
      # debt-milli integer compare ((−score_raw × 1000).round at the engine's
      # value_raw <= recorded predicate) and D-C3's round(2) collapse
      # equality check (ScoreRollup.node_fresh?) are likewise M14-conformant:
      # integer / published-precision comparisons, no raw IEEE float ever
      # enters a gate.
      #
      # Universe discipline (the ExponentialNode template, [S:G4] carried):
      # lint universe = all filtered vintage nodes; diff universe =
      # NEW ∪ GROWN delta entries ONLY — unchanged monsters in touched files
      # stay lint's + the todo's jurisdiction, and SHRUNK-but-still-bad never
      # fires in diff (reduction is the desired direction).
      #
      # Honesty ladder (L6):
      #   * vintage with NO score keys (pre-v6 / never-analyzed) → ONE
      #     not_evaluable note, pinned reason below;
      #   * null-valued keys ("analyzed, node unscored") → silent skip;
      #   * stale stamp (D-C3: carried collapse ≠ recomputed
      #     round(branches/max(arity,1), 2)) → ONE per-node disclosure,
      #     never a finding, never a fabricated number;
      #   * the +5 absorption incentive (`absorb_min_score` reads the engine
      #     `absorb` key, L9-A) is a presenter DISCLOSURE line — this rule
      #     NEVER fires on the positive pole.
      #
      # Product-copy law (Q8, rule 5): the negative pole renders
      # break-it-down copy ONLY — never the quadrant's underused upsell
      # wording — plus the escape caveat (O2) when the node escapes.
      class ReusabilityScore < Base
        kind :node
        required_node_keys :score_raw
        needs_edges false

        NOT_EVALUABLE_REASON =
          "score stamps absent — serializer < v6 or vintage never analyzed"

        MESSAGE_TEMPLATE =
          "engine reusability score %g (raw %g): false reusability — " \
          "break it down before growing it"

        ESCAPE_CAVEAT =
          " (escape: inline surface above contract — NOT statically " \
          "extraction-recoverable)"

        STALE_TEMPLATE =
          "score stamp stale for %s:%s — run archbuddy analyze (or --analyze-sides)"

        def evaluate(ctx)
          unless stamped?(ctx.vintage)
            ctx.not_evaluable!(NOT_EVALUABLE_REASON)
            return
          end

          universe(ctx).each do |node|
            next if node.score.nil? || node.score_raw.nil? # analyzed, unscored

            unless ScoreRollup.node_fresh?(node)
              ctx.not_evaluable!(format(STALE_TEMPLATE, node.file, node.symbol))
              next
            end

            min_score = ctx.rule_config(node.file)["min_score"]
            breaching = !min_score.nil? && node.score <= min_score
            ctx.node_result(
              node: node,
              value_raw: (-node.score_raw * 1000).round, # debt milli (D-C5)
              breaching: breaching,
              message: breaching ? message(node) : nil,
              refire_style: :score_debt
            )
          end
        end

        private

        # Key-presence evaluability (never serializer-version-inferred):
        # ≥1 node carrying the score_raw KEY makes the vintage evaluable;
        # null VALUES are the engine's honest "analyzed, node unscored".
        def stamped?(vintage)
          vintage.nodes.any? do |node|
            Array(node.keys_present).any? { |k| k.to_sym == :score_raw }
          end
        end

        def universe(ctx)
          return ctx.universe_nodes unless ctx.mode == :diff

          allowed = ctx.universe_nodes.to_set { |n| [n.file, n.symbol] }
          ctx.delta.entries.filter_map do |entry|
            next unless %i[new grown].include?(entry.classification)

            node = entry.head_node
            node if node && allowed.include?([node.file, node.symbol])
          end
        end

        def message(node)
          text = format(MESSAGE_TEMPLATE, node.score, node.score_raw)
          node.escapes ? text + ESCAPE_CAVEAT : text
        end
      end

      RuleEngine.register("ReusabilityScore", ReusabilityScore)
    end
  end
end
