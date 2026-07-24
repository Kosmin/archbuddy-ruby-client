# frozen_string_literal: true

require "set"
require_relative "base"
require_relative "../rule_engine"

module Archbuddy
  module Review
    module Rules
      # Standing per-ep escape audit (lint) + the NoNewEscapes event catch
      # re-attributed to use cases (diff) — severity INFO in BOTH modes
      # (Q11). Absorbs the retired NoNewEscapes verbatim: the diff event
      # universe (matched `escapes false→true` ∪ NEW `escapes: true`) is
      # reachability-independent (Q8/V15-F4) — on a zero-ep head the engine
      # still dispatches this rule's diff mode and every event fires through
      # the orphan path.
      #
      # V15-F3: ep findings carry components ==
      # {escapes: {value: <cone count>, threshold: max_escapes, breached:}}
      # in both modes; orphan-event findings carry components nil and are
      # NEVER todo-generated or todo-consulted.
      class FirewallBreaches < Base
        kind :use_case
        required_node_keys :branches, :escapes
        needs_edges true

        LINT_TEMPLATE = "%d escape node(s) inside this use case's cone — " \
                        "complexity unbounded by contracts"
        EVENT_TEMPLATE = "%d new escape node(s) entered this use case's cone: %s"
        ORPHAN_TEMPLATE = "escape introduced outside any use case " \
                          "(not reachable from any entrypoint): %s: %s"

        def evaluate(ctx)
          ctx.mode == :diff ? evaluate_diff(ctx) : evaluate_lint(ctx)
        end

        private

        def evaluate_lint(ctx)
          return na(ctx, "fragments carry no edges") unless ctx.vintage.edges?
          unless key_present?(ctx.vintage, :escapes)
            return na(ctx, "escapes absent from fragments (serializer v1)")
          end

          ctx.universe_eps.each do |ep|
            metrics = ctx.graph.ep_metrics[[ep.file, ep.symbol]]
            next if metrics.nil?

            nodes = metrics.escapes_in_cone || []
            emit_ep(ctx, ep.file, ep.symbol, metrics,
                    clause: format(LINT_TEMPLATE, nodes.length),
                    event_nodes: nodes.map { |n| [n[:file], n[:symbol]] })
          end
        end

        # Event mode ONLY (standing counts are lint's jurisdiction — Q2).
        def evaluate_diff(ctx)
          return na(ctx, "base vintage carries no edges") unless ctx.delta.base.edges?
          return na(ctx, "head vintage carries no edges") unless ctx.delta.head.edges?
          unless key_present?(ctx.delta.base, :escapes)
            return na(ctx, "base vintage lacks 'escapes' (pre-v4 fragments)")
          end
          unless key_present?(ctx.delta.head, :escapes)
            return na(ctx, "head vintage lacks 'escapes' (pre-v4 fragments)")
          end

          events = escape_events(ctx.delta)
          return if events.empty?

          ep_metrics = ctx.graph.ep_metrics
          allowed = ctx.universe_eps.to_set { |ep| [ep.file, ep.symbol] }
          affected, orphans = attribute(events, ep_metrics)

          affected.sort.each do |(file, symbol), nodes|
            next unless allowed.include?([file, symbol]) # emission-only exclude

            emit_ep(ctx, file, symbol, ep_metrics[[file, symbol]],
                    clause: event_message(nodes),
                    event_nodes: nodes.map { |n| [n.file, n.symbol] })
          end

          # The node-level catch survives reachability (Q8) — components nil,
          # never grandfathered, never in the todo (V15-F3).
          orphans.each do |node|
            ctx.add_finding(
              severity: ctx.rule_config(node.file).severity,
              file: node.file, symbol: node.symbol,
              message: format(ORPHAN_TEMPLATE, node.file, node.symbol)
            )
          end
        end

        # ONE finding per (rule, ep) — the engine owns the escapes-count todo
        # channel ({escapes: N} native ints; head count must exceed the
        # recorded count to re-fire).
        def emit_ep(ctx, file, symbol, metrics, clause:, event_nodes:)
          count = (metrics.escapes_in_cone || []).length
          max = ctx.rule_config(file)["max_escapes"]
          components = {
            "escapes" => { value: count, threshold: max, breached: count > max }
          }
          contributors = event_nodes.first(5).map do |(node_file, node_symbol)|
            { file: node_file, symbol: node_symbol, value_raw: nil, value_log2: nil,
              delta_log2: nil, coupling_flip: false }
          end
          ctx.ep_result(
            file: file, symbol: symbol, components: components,
            clauses: { "escapes" => clause },
            entrypoint_kind: metrics.entrypoint_kind,
            contributors: contributors,
            contributors_omitted: [event_nodes.length - 5, 0].max
          )
        end

        # Matched pair escapes false→true ∪ NEW node escapes: true ([S] row
        # verbatim); a nil-side matched pair is silently non-evaluable.
        def escape_events(delta)
          delta.entries.filter_map do |entry|
            head = entry.head_node
            next if head.nil? || head.escapes != true

            if entry.classification == :new
              head
            elsif entry.base_node && entry.base_node.escapes == false
              head
            end
          end
        end

        # Ep attribution via I-C3' data ONLY: the event node IS an escape, so
        # its host eps are exactly the rows listing it in escapes_in_cone.
        def attribute(events, ep_metrics)
          affected = Hash.new { |acc, key| acc[key] = [] }
          orphans = []
          events.each do |node|
            hosts = ep_metrics.select do |_key, metrics|
              (metrics.escapes_in_cone || []).any? do |escape|
                escape[:file] == node.file && escape[:symbol] == node.symbol
              end
            end
            if hosts.empty?
              orphans << node
            else
              hosts.each_key { |key| affected[key] << node }
            end
          end
          [affected, orphans]
        end

        def event_message(nodes)
          named = nodes.first(5).map { |n| "#{n.file}: #{n.symbol}" }.join(", ")
          suffix = nodes.length > 5 ? " +#{nodes.length - 5} more" : ""
          format(EVENT_TEMPLATE, nodes.length, "#{named}#{suffix}")
        end

        def na(ctx, reason)
          ctx.not_evaluable!(reason)
          nil
        end

        def key_present?(vintage, key)
          vintage.nodes.any? do |node|
            Array(node.keys_present).any? { |k| k.to_sym == key }
          end
        end
      end

      RuleEngine.register("FirewallBreaches", FirewallBreaches)
    end
  end
end
