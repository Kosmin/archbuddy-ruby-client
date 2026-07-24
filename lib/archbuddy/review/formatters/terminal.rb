# frozen_string_literal: true

require_relative "../formatter"

module Archbuddy
  module Review
    module Formatters
      # Problem-matcher-friendly terminal renderer. Diff document order:
      # findings (+ ep contributor sub-lines) → ratchet lines → review
      # surface (2b) → disclosures (2c) → grandfathered → not-evaluable →
      # impact → summary. Lint order (Q9): summary FIRST → findings →
      # use-case leaderboard → ratchet context → grandfathered →
      # calibration footer. Both units wherever a branching value appears
      # (P7); finding lines NEVER contain a line number (fragments are
      # line-free — D7).
      class Terminal < Formatter
        def render
          lines = context.command == "lint" ? lint_document : diff_document
          "#{lines.join("\n")}\n"
        end

        private

        def diff_document
          lines = []
          lines.concat(finding_lines)
          lines << "" if lines.any? && ratchet_lines.any?
          lines.concat(ratchet_lines)
          lines.concat(review_surface_lines) # item 2b
          lines.concat(disclosure_lines)     # item 2c
          lines.concat(grandfathered_lines)
          lines.concat(not_evaluable_lines)
          lines.concat(impact_lines)
          lines << diff_summary_line
          lines
        end

        def lint_document
          lines = [lint_summary_line]
          lines.concat(finding_lines)
          lines.concat(leaderboard_lines)
          lines.concat(ratchet_lines)
          lines.concat(grandfathered_lines)
          lines.concat(not_evaluable_lines)
          lines.concat(impact_lines)
          lines
        end

        # ---- findings ------------------------------------------------------------

        def finding_lines
          sorted_findings.flat_map do |f|
            head = f.file || f.symbol ? "#{f.file}: #{f.symbol} " : ""
            line = "#{head}[#{f.rule}] #{f.severity}: #{f.message}"
            f.contributors&.any? ? [line, contributor_line(f)] : [line]
          end
        end

        def contributor_line(finding)
          parts = finding.contributors.first(5).map do |c|
            part = c[:symbol].to_s
            if c[:value_raw]
              part += " #{c[:value_raw]} (2^#{format('%.1f', c[:value_log2])})"
            end
            part += " [coupling flip]" if c[:coupling_flip]
            part
          end
          line = "  contributors: #{parts.join('; ')}"
          omitted = finding.contributors_omitted.to_i
          line += " (+#{omitted} more)" if omitted.positive?
          line
        end

        # ---- ratchet -------------------------------------------------------------

        def ratchet_lines
          @ratchet_lines ||= (context.ratchet || []).map do |entry|
            if entry.verdict.nil? # lint context (C14/F7) — never gates
              lint_ratchet_line(entry)
            elsif entry.verdict == :no_match
              "ratchet #{entry.scope}: budget #{format('%+.3f', entry.budget_log2)} " \
                "— no_match (scope matched no files/entrypoints)"
            else
              "ratchet #{entry.scope}: net #{format('%+.3f', entry.observed_log2)} log2 " \
                "vs budget #{format('%+.3f', entry.budget_log2)} — #{entry.verdict}"
            end
          end
        end

        def lint_ratchet_line(entry)
          unit = entry.kind == "entrypoint" ? "entrypoint(s)" : "file(s)"
          line = "ratchet #{entry.scope}: current total " \
                 "#{format('%.3f', entry.current_total_log2 || 0.0)} log2 — budget " \
                 "#{format('%+.3f', entry.budget_log2)} per change " \
                 "(#{entry.matched_files.to_i} #{unit} matched)"
          line += " — warning: scope matches nothing" if entry.empty_scope
          line
        end

        # ---- review surface + disclosures (diff only) ------------------------------

        def review_surface_lines
          rs = context.review_surface
          return [] if rs.nil?

          line = "review surface: #{rs[:union]} use case(s) to re-verify " \
                 "(Σ #{rs[:sum]} review reads)"
          unreachable = rs[:unreachable_touched]
          if unreachable && unreachable[:count].to_i.positive?
            line += " — #{unreachable[:count]} touched node(s) statically unreachable " \
                    "from any use case (unresolved dispatch likely)"
          end
          lines = [line]
          worst = (rs[:eps] || []).first(5).map { |e| e[:ep_symbol] }
          lines << "  worst: #{worst.join(', ')}" if worst.any?
          lines
        end

        def disclosure_lines
          disclosures = context.disclosures
          return [] if disclosures.nil?

          lines = []
          files = disclosures[:orphan_touched_files] || []
          if files.any?
            shown = files.first(5).join(", ")
            extra = files.length > 5 ? ", +#{files.length - 5} more" : ""
            lines << "note: #{files.length} touched file(s) not reachable from any " \
                     "entrypoint: #{shown}#{extra}"
          end
          offsetting = disclosures[:offsetting_zero_count].to_i
          if offsetting.positive?
            lines << "note: #{offsetting} use case(s) have changed nodes in their cone " \
                     "with no net metric movement"
          end
          lines
        end

        # ---- leaderboard (lint only, Q9) -------------------------------------------

        def leaderboard_lines
          use_cases = context.use_cases
          return [] if use_cases.nil?

          rows = (use_cases[:leaderboard] || [])
                 .sort_by { |r| [-r["branching_log2"], r["ep"].to_s] }
          total = use_cases[:count].to_i
          lines = []
          if rows.any?
            lines << "use cases (worst #{[total, 20].min} of #{total} by cone branching):"
            rows.first(20).each { |row| lines << leaderboard_row(row) }
            if total > 20
              lines << "  #{total - 20} more use cases — --format json for the full table"
            end
          end
          lines.concat(unreachable_note(use_cases[:unreachable]))
          lines
        end

        def leaderboard_row(row)
          dividend = row["dividend"] ? format("%g", row["dividend"]) : "—"
          line = "  #{row['rank']}. #{row['ep']} — branching " \
                 "2^#{format('%.1f', row['branching_log2'])}, mass #{row['mass']}, " \
                 "reach #{row['reach']}, files #{row['files']}, depth #{row['depth']}, " \
                 "dividend ×#{dividend}"
          line += " — #{row['cost_note']}" if row["cost_note"]
          line
        end

        def unreachable_note(unreachable)
          return [] if unreachable.nil?

          nodes = unreachable[:nodes]
          share = unreachable[:share].to_f
          total = share.positive? ? (nodes / share).round : nodes
          ["note: #{nodes} of #{total} nodes (#{format('%.1f', share * 100)}%) not " \
           "reachable from any entrypoint — excluded from use-case metrics; still " \
           "covered by ExponentialNode, MultiplicativeGrowth, FirewallBreaches " \
           "events, and ratchet path budgets"]
        end

        # ---- shared tail sections ---------------------------------------------------

        def grandfathered_lines
          skips = context.grandfathered || []
          return [] if skips.empty?

          nodes = skips.map { |s| [s.file, s.symbol] }.uniq.size
          rules = skips.map(&:rule).uniq.size
          healed = skips.count(&:healed)
          ["grandfathered: #{nodes} node(s) across #{rules} rule(s) " \
           "(#{healed} healed — regenerate the todo to shrink it)"]
        end

        def not_evaluable_lines
          (context.not_evaluable || []).map do |entry|
            "note: #{entry[:rule]} not evaluable: #{entry[:reason]}"
          end
        end

        def impact_lines
          lines = context.calibration && context.calibration[:lines]
          (lines || []).map { |line| "impact: #{line}" }
        end

        def diff_summary_line
          tally = counts
          net = context.delta_summary ? context.delta_summary[:net_log2] : 0.0
          sha = context.base && context.base[:sha]
          base_label = sha ? sha[0, 7] : "injected"
          "archbuddy diff: #{tally[:error]} error(s), #{tally[:warn]} warning(s), " \
            "#{tally[:info]} info — net Δlog2 #{format('%+.3f', net)} (base #{base_label})"
        end

        def lint_summary_line
          tally = counts
          "archbuddy lint: #{tally[:error]} error(s), #{tally[:warn]} warning(s), " \
            "#{tally[:info]} info"
        end
      end

      Formatter.register("terminal", Terminal)
    end
  end
end
