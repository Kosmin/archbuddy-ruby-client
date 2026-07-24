# frozen_string_literal: true

require "set"
require_relative "base"
require_relative "../rule_engine"

module Archbuddy
  module Review
    module Rules
      # The "cost that shouldn't exist" rule (Q11): per ep, the PUBLISHED
      # dividend (engine-mirrored cap 1e6) gated GTE against min_dividend —
      # the ONE pinned deviation from the strict-> family convention (both
      # boundary sides spec-asserted). null disables the gate entirely
      # (leaderboard column only).
      #
      # The todo channel pins the RAW dividend_log2 (milli-log2 integers,
      # cap-immune — saturation can never mask growth, Q7). The engine owns
      # the per-metric 4-step; the gated component is `dividend_log2` (the
      # Config::Todo::COMPONENT_TO_METRIC key — see mismatch M5); `dividend`
      # carries the published display truth; Finding#threshold_raw =
      # min_dividend and #value_log2 = dividend_log2 per §5-C26.
      class UseCaseDividend < Base
        kind :use_case
        required_node_keys :branches, :outcome_arity, :escapes
        needs_edges true

        def evaluate(ctx)
          return unless evaluable?(ctx)

          if ctx.mode == :diff
            evaluate_diff(ctx)
          else
            ctx.universe_eps.each do |ep|
              metrics = ctx.graph.ep_metrics[[ep.file, ep.symbol]]
              next if metrics.nil?

              check_ep(ctx, ep.file, ep.symbol, metrics)
            end
          end
        end

        private

        def evaluable?(ctx)
          if ctx.mode == :diff
            check(ctx, ctx.delta.base, "base vintage carries no edges",
                  "base vintage lacks 'outcome_arity' (pre-v4 fragments)",
                  "base vintage lacks 'escapes' (pre-v4 fragments)") &&
              check(ctx, ctx.delta.head, "head vintage carries no edges",
                    "head vintage lacks 'outcome_arity' (pre-v4 fragments)",
                    "head vintage lacks 'escapes' (pre-v4 fragments)")
          else
            check(ctx, ctx.vintage, "fragments carry no edges",
                  "outcome_arity absent from fragments (pre-v4 serializer)",
                  "escapes absent from fragments (serializer v1)")
          end
        end

        def check(ctx, vintage, edges_reason, arity_reason, escapes_reason)
          return na(ctx, edges_reason) unless vintage.edges?
          return na(ctx, arity_reason) unless key_present?(vintage, :outcome_arity)
          return na(ctx, escapes_reason) unless key_present?(vintage, :escapes)

          true
        end

        def na(ctx, reason)
          ctx.not_evaluable!(reason)
          false
        end

        # Fragment key presence (real vintages carry string keys, stubs
        # symbols — normalize).
        def key_present?(vintage, key)
          vintage.nodes.any? do |node|
            Array(node.keys_present).any? { |k| k.to_sym == key }
          end
        end

        def evaluate_diff(ctx)
          allowed = ctx.universe_eps.to_set { |ep| [ep.file, ep.symbol] }
          ctx.delta.ep_entries.each do |entry|
            next if entry.classification == :removed
            next unless allowed.include?([entry.file, entry.ep_symbol])

            metrics = entry.head
            next if metrics.nil?

            check_ep(ctx, entry.file, entry.ep_symbol, metrics)
          end
        end

        def check_ep(ctx, file, symbol, metrics)
          dividend = metrics.dividend
          return if dividend.nil? # per-ep arity N/A — legal, never fabricated

          min = ctx.rule_config(file)["min_dividend"]
          breach = !min.nil? && dividend >= min # GTE — pinned deviation (Q11 letter)

          ctx.ep_result(
            file: file, symbol: symbol,
            components: components(metrics, min, breach),
            clauses: { "dividend_log2" => message(metrics) },
            entrypoint_kind: metrics.entrypoint_kind,
            contributors: contributors(metrics),
            contributors_omitted: omitted(metrics),
            value_log2: metrics.dividend_log2,
            threshold_raw: min
          )
        end

        def components(metrics, min, breach)
          {
            "dividend" => { value: metrics.dividend.round(6), threshold: nil,
                            breached: breach },
            "dividend_log2" => { value: metrics.dividend_log2,
                                 threshold: min && Math.log2(min), breached: breach },
            "v_now_log2" => { value: metrics.v_now_log2, threshold: nil, breached: false },
            "v_floor_log2" => { value: metrics.v_floor_log2, threshold: nil, breached: false }
          }
        end

        def message(metrics)
          format(
            "dividend ×%g: V_now %g (2^%.1f) vs V_floor %g (2^%.1f) — " \
            "variety that exists only because decisions are inline",
            metrics.dividend.round(6), metrics.published_variety.round(6),
            metrics.v_now_log2, Math.exp(metrics.vty_floor_log).round(6),
            metrics.v_floor_log2
          )
        end

        # The nodes whose extraction pays the dividend.
        def contributors(metrics)
          (metrics.top_dividend_nodes || []).map do |node|
            { file: node[:file], symbol: node[:symbol],
              value_raw: node[:branches], value_log2: node[:log2],
              delta_log2: nil, coupling_flip: false }
          end
        end

        def omitted(metrics)
          [metrics.cone_size - (metrics.top_dividend_nodes || []).length, 0].max
        end
      end

      RuleEngine.register("UseCaseDividend", UseCaseDividend)
    end
  end
end
