# frozen_string_literal: true

require_relative "base"
require_relative "../rule_engine"

module Archbuddy
  module Review
    module Rules
      # The one :pr rule (Q3/Q11): the ∪-count disclosure block ALWAYS
      # (whenever enabled + evaluable), a finding only under the opt-in
      # `max_use_cases` gate (strict >; null = disclosure-only default).
      # Diff-only — the engine's dispatch matrix keeps it lint-inert (no
      # findings, no N/A noise). Never grandfathered; never in the todo
      # (the loader rejects it — L5/R45). No calibrated count line (L-RS is
      # P3-lane presenter copy; R-HONEST-2).
      class ReviewSurface < Base
        kind :pr
        required_node_keys :branches
        needs_edges true

        TEMPLATE = "this PR touches %d use case(s) (limit %d); worst: %s"

        def evaluate(ctx)
          return na(ctx, "base vintage carries no edges") unless ctx.delta.base.edges?
          return na(ctx, "head vintage carries no edges") unless ctx.delta.head.edges?

          block = ctx.delta.review_surface
          return if block.nil?

          # The block is produced whenever enabled + evaluable — the
          # unreachable_touched disclosure NEVER implies safety (Q3).
          ctx.review_surface = block

          max = ctx.rule_config["max_use_cases"]
          return if max.nil? || block[:union] <= max # strict >; 0 ≯ 0

          worst = (block[:eps] || []).first(5).map { |row| row[:ep_symbol] }.join(", ")
          ctx.add_finding(
            severity: ctx.rule_config.severity,
            message: format(TEMPLATE, block[:union], max, worst),
            scope: :pr
          )
        end

        private

        def na(ctx, reason)
          ctx.not_evaluable!(reason)
          nil
        end
      end

      RuleEngine.register("ReviewSurface", ReviewSurface)
    end
  end
end
