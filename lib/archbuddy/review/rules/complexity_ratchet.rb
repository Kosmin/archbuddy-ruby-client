# frozen_string_literal: true

require "set"
require_relative "base"
require_relative "../rule_engine"

module Archbuddy
  module Review
    module Rules
      # The scope-budget ratchet (L6/G8/F7) — dual-mode:
      #
      #   diff: one verdict per paths budget (net over in-scope entries,
      #     STRICT > breaches) and one verdict PER MATCHED EP for
      #     entrypoints budgets (over Delta#ep_deltas, keyed (file,
      #     ep_symbol) — Q7; `scope` renders the SYMBOL). Breaches live
      #     ONLY in Findings#ratchet as RatchetEntry (verdict :breach,
      #     R24 message template) — never a Finding.
      #
      #   lint (C14/F7): context entries per budget of EITHER kind
      #     (verdict nil, additive kind: 'paths'|'entrypoint';
      #     current_total_log2 = Σ log2 branches over matched files /
      #     Σ subtree_log2_by_ep over matched eps — the SAME memoized
      #     graph the leaderboard uses, §5-C31). Context NEVER gates.
      #
      # G8 empty-scope: zero in-scope records + budget ≥ 0 → :no_match with
      # empty_scope (wording distinguishes files-unchanged from matched no
      # files); a NEGATIVE budget over an empty scope → :breach (+0.000 —
      # a forced decrease is unmet by no change). NEVER grandfathered (L5):
      # the todo is never read (the engine hands :delta kinds none).
      class ComplexityRatchet < Base
        kind :delta
        required_node_keys :branches

        BREACH_TEMPLATE = "scope %s: net %+.3f log2 exceeds budget %+.3f"

        def evaluate(ctx)
          budgets = ctx.config.budgets
          return if budgets.empty?

          budgets.each do |budget|
            if ctx.mode == :diff
              diff_budget(ctx, budget)
            else
              lint_budget(ctx, budget)
            end
          end
        end

        private

        # ---- diff verdicts -----------------------------------------------------

        def diff_budget(ctx, budget)
          if budget["paths"]
            diff_paths(ctx, budget)
          else
            diff_entrypoints(ctx, budget)
          end
        end

        def diff_paths(ctx, budget)
          globs = budget["paths"]
          limit = Float(budget["max_increase_log2"])
          in_scope = ctx.delta.entries.select do |entry|
            Config::PathMatcher.match?(globs, entry.file)
          end

          if in_scope.empty?
            return empty_scope_verdict(
              ctx, budget, scope: globs.join(","), kind: "paths", limit: limit,
              matched: ctx.delta.scope_match?(paths: globs)
            )
          end

          net = in_scope.sum(&:delta_log2).round(3)
          emit(ctx, budget,
               scope: globs.join(","), kind: "paths", scope_paths: globs,
               verdict: net > limit ? :breach : :pass, observed: net, limit: limit,
               matched_files: in_scope.map(&:file).uniq.size,
               contributors: contributors(in_scope))
        end

        def diff_entrypoints(ctx, budget)
          globs = budget["entrypoints"]
          limit = Float(budget["max_increase_log2"])
          matched = ctx.delta.ep_deltas.select do |(_file, ep_symbol), _row|
            Config::PathMatcher.match_symbol?(globs, ep_symbol)
          end

          if matched.empty?
            return empty_scope_verdict(ctx, budget, scope: globs.join(","),
                                       kind: "entrypoint", limit: limit, matched: false)
          end

          matched.sort_by { |(file, ep_symbol), _row| [file, ep_symbol] }
                 .each do |(_file, ep_symbol), row|
            net = row[:delta].round(3)
            emit(ctx, budget,
                 scope: ep_symbol, kind: "entrypoint", scope_paths: globs,
                 verdict: net > limit ? :breach : :pass, observed: net, limit: limit,
                 matched_files: 1)
          end
        end

        # G8: budget ≥ 0 → no_match (info-class context, never a gate);
        # negative budget → breach at +0.000 (forced decrease unmet).
        def empty_scope_verdict(ctx, budget, scope:, kind:, limit:, matched:)
          if limit.negative?
            emit(ctx, budget, scope: scope, kind: kind,
                 scope_paths: budget["paths"] || budget["entrypoints"],
                 verdict: :breach, observed: 0.0, limit: limit,
                 matched_files: 0, empty_scope: true)
          else
            emit(ctx, budget, scope: scope, kind: kind,
                 scope_paths: budget["paths"] || budget["entrypoints"],
                 verdict: :no_match, observed: nil, limit: limit,
                 matched_files: 0, empty_scope: true,
                 note: matched ? "files unchanged" : "matched no files")
          end
        end

        # ---- lint context (C14/F7 — verdict nil, never gates) ------------------

        def lint_budget(ctx, budget)
          if budget["paths"]
            globs = budget["paths"]
            nodes = ctx.universe_nodes.select do |node|
              Config::PathMatcher.match?(globs, node.file)
            end
            total = nodes.sum { |n| valid_branches?(n) ? Math.log2(n.branches) : 0.0 }
            emit(ctx, budget, scope: globs.join(","), kind: "paths", scope_paths: globs,
                 verdict: nil, limit: Float(budget["max_increase_log2"]),
                 current_total: total.round(3),
                 matched_files: nodes.map(&:file).uniq.size,
                 empty_scope: nodes.empty?)
          else
            globs = budget["entrypoints"]
            matched = ctx.graph.subtree_log2_by_ep.select do |ep_symbol, _log2|
              Config::PathMatcher.match_symbol?(globs, ep_symbol)
            end
            emit(ctx, budget, scope: globs.join(","), kind: "entrypoint",
                 scope_paths: globs, verdict: nil,
                 limit: Float(budget["max_increase_log2"]),
                 current_total: matched.values.sum.round(3),
                 matched_files: matched.size, empty_scope: matched.empty?)
          end
        end

        # ---- entry assembly ----------------------------------------------------

        def emit(ctx, budget, scope:, kind:, limit:, verdict:, scope_paths: nil,
                 observed: nil, current_total: nil, matched_files: nil,
                 empty_scope: false, contributors: nil, note: nil)
          severity = (budget["severity"] || ctx.rule_config.severity).to_sym
          message =
            if verdict == :breach
              format(BREACH_TEMPLATE, scope, observed, limit)
            else
              note
            end
          ctx.ratchet_entry(
            scope: scope, kind: kind, scope_paths: scope_paths,
            budget_log2: limit, verdict: verdict, observed_log2: observed,
            current_total_log2: current_total, matched_files: matched_files,
            empty_scope: empty_scope, severity: severity,
            contributors: contributors, message: message
          )
        end

        def contributors(entries)
          entries.sort_by { |e| [-e.delta_log2.abs, e.file, e.symbol] }.first(5).map do |e|
            { file: e.file, symbol: e.symbol,
              value_raw: e.head_branches, value_log2: log2_or_nil(e.head_branches),
              delta_log2: e.delta_log2, coupling_flip: false }
          end
        end

        def log2_or_nil(branches)
          branches.is_a?(Integer) && branches >= 1 ? Math.log2(branches) : nil
        end

        def valid_branches?(node)
          node.branches.is_a?(Integer) && node.branches >= 1
        end
      end

      RuleEngine.register("ComplexityRatchet", ComplexityRatchet)
    end
  end
end
