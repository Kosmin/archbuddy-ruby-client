# frozen_string_literal: true

require "set"
require_relative "base"
require_relative "../rule_engine"

module Archbuddy
  module Review
    module Rules
      # The flagship business rule (Q11): per-ENTRYPOINT component evaluation
      # over the graph's ep fold — 5 Σ-components (branching_log2, mass,
      # depth, reach, files) plus the set-by-default Q4-node trigger
      # (max_cone_node_log2: 5.0, strict >). ONE finding per ep (L8)
      # enumerates every breaching component; `own_branching_log2` is
      # reported, NEVER thresholded (Q10 — no config key exists).
      #
      # Cone mass = Σ fragment-local call sites over cone app nodes (the
      # [S:G9] CLIENT definition) — deliberately NOT the engine's
      # variety_mass; the docs pin the unit (no silent parameter).
      #
      # Diff mode: head-side levels for U_metric eps only (Q2) — :matched
      # and :new entries through the SAME predicate; :removed eps are never
      # level-checked. The engine owns the per-metric todo 4-step.
      class UseCaseComplexity < Base
        kind :use_case
        required_node_keys :branches
        needs_edges true

        # component key → config threshold key (all strict >).
        THRESHOLDS = {
          "branching_log2" => "max_branching_log2",
          "mass" => "max_mass",
          "depth" => "max_depth",
          "reach" => "max_reach",
          "files" => "max_files",
          "max_cone_node_log2" => "max_cone_node_log2"
        }.freeze

        CLAUSE_TEMPLATES = {
          "branching_log2" => "cone branching %.1f log2 exceeds %.1f",
          "mass" => "cone mass %d call sites exceeds %d",
          "reach" => "reach %d nodes exceeds %d",
          "files" => "file scatter %d files exceeds %d",
          "depth" => "depth %d levels exceeds %d"
        }.freeze

        def evaluate(ctx)
          return unless edges_evaluable?(ctx)

          if ctx.mode == :diff
            evaluate_diff(ctx)
          else
            ctx.universe_eps.each do |ep|
              metrics = ctx.graph.ep_metrics[[ep.file, ep.symbol]]
              next if metrics.nil?

              check_ep(ctx, ep.file, ep.symbol, metrics,
                       contributors: lint_contributors(metrics),
                       contributors_omitted: [metrics.cone_size - metrics.top_nodes.length, 0].max)
            end
          end
        end

        private

        def edges_evaluable?(ctx)
          if ctx.mode == :diff
            return not_evaluable(ctx, "base vintage carries no edges") unless ctx.delta.base.edges?
            return not_evaluable(ctx, "head vintage carries no edges") unless ctx.delta.head.edges?
          else
            return not_evaluable(ctx, "fragments carry no edges") unless ctx.vintage.edges?
          end
          true
        end

        def not_evaluable(ctx, reason)
          ctx.not_evaluable!(reason)
          false
        end

        # U_metric universe only (Q2): the Delta materializes exactly the
        # moved/NEW/REMOVED eps; emission still passes the config universe
        # (exclude/exclude_entrypoints — anti-gaming, emission-only).
        def evaluate_diff(ctx)
          allowed = ctx.universe_eps.to_set { |ep| [ep.file, ep.symbol] }
          ctx.delta.ep_entries.each do |entry|
            next if entry.classification == :removed
            next unless allowed.include?([entry.file, entry.ep_symbol])

            metrics = entry.head
            next if metrics.nil?

            check_ep(ctx, entry.file, entry.ep_symbol, metrics,
                     contributors: entry.contributors,
                     contributors_omitted: entry.contributors_omitted)
          end
        end

        def check_ep(ctx, file, symbol, metrics, contributors:, contributors_omitted:)
          rc = ctx.rule_config(file)
          components = build_components(metrics, rc)
          ctx.ep_result(
            file: file, symbol: symbol,
            components: components,
            clauses: build_clauses(metrics, components),
            message_builder: message_builder(metrics),
            entrypoint_kind: metrics.entrypoint_kind,
            contributors: contributors, contributors_omitted: contributors_omitted
          )
        end

        def build_components(metrics, rule_config)
          components = THRESHOLDS.to_h do |key, config_key|
            value = key == "max_cone_node_log2" ? metrics.max_cone_node[:log2] : metrics.public_send(key)
            threshold = rule_config[config_key]
            [key, { value: value, threshold: threshold,
                    breached: !threshold.nil? && value > threshold }]
          end
          own = metrics.own_branches
          components["own_branching_log2"] = {
            value: own.is_a?(Integer) && own >= 1 ? Math.log2(own) : nil,
            threshold: nil, breached: false # reported, NEVER thresholded (Q10)
          }
          components
        end

        def build_clauses(metrics, components)
          clauses = {}
          CLAUSE_TEMPLATES.each do |key, template|
            component = components[key]
            next unless component[:breached]

            clauses[key] = format(template, component[:value], component[:threshold])
          end
          q4 = components["max_cone_node_log2"]
          if q4[:breached]
            node = metrics.max_cone_node
            clauses["max_cone_node_log2"] = format(
              "worst cone node %d (2^%.1f) exceeds 2^%g (Q4 boundary)",
              node[:branches], node[:log2], q4[:threshold]
            )
          end
          clauses
        end

        def message_builder(metrics)
          lambda do |clause_list|
            format(
              "use case spans %d (2^%.1f) total branching over %d node(s) / %d file(s) " \
              "(mass %d, depth %d) — %s",
              (2**metrics.branching_log2).round, metrics.branching_log2,
              metrics.reach, metrics.files, metrics.mass, metrics.depth,
              clause_list.join("; ")
            )
          end
        end

        def lint_contributors(metrics)
          (metrics.top_nodes || []).map do |node|
            { file: node[:file], symbol: node[:symbol],
              value_raw: node[:branches], value_log2: node[:log2],
              delta_log2: nil, coupling_flip: false }
          end
        end
      end

      RuleEngine.register("UseCaseComplexity", UseCaseComplexity)
    end
  end
end
