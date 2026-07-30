# frozen_string_literal: true

require_relative "../formatter"

module Archbuddy
  module Review
    module Formatters
      # Single markdown document (GH step-summary + PR/MR comment dual-use;
      # the 65,536-char comment cap binds — findings details capped at 50
      # rows, use-case details at rows 21–120 [R4 §Q4], tails name the JSON
      # artifact). Ep-finding rows render `—` in value/limit columns when
      # value_raw is null (multi-component — the components live in the
      # message clause text).
      class Markdown < Formatter
        FINDINGS_DETAILS_CAP = 50
        USE_CASE_OPEN_CAP = 20
        USE_CASE_DETAILS_CAP = 120

        def render
          sections = [headline, verdict_line, counts_table]
          if lint?
            sections << use_cases_section
          else
            sections << delta_top_table
          end
          sections << findings_table
          unless lint?
            sections << ratchet_table
            sections << review_surface_section
            sections << reusability_section # v0.16 T10 — mirrors the envelope block
          end
          sections << calibration_blockquote
          sections << findings_details
          sections << grandfathered_details
          sections << not_evaluable_details
          "#{sections.compact.reject(&:empty?).join("\n\n")}\n"
        end

        private

        def lint?
          context.command == "lint"
        end

        def headline
          tally = counts
          sha = context.base && context.base[:sha]
          base_label = sha ? " (base #{sha[0, 7]})" : ""
          "## archbuddy #{context.command} — #{tally[:error]} error(s), " \
            "#{tally[:warn]} warning(s)#{base_label}"
        end

        def verdict_line
          context.advisory ? "_advisory run — exit 0_" : "**GATE: exit #{context.exit_code}**"
        end

        def counts_table
          tally = counts
          rows = ["| errors | warnings | info | grandfathered |",
                  "|---|---|---|---|",
                  "| #{tally[:error]} | #{tally[:warn]} | #{tally[:info]} | " \
                  "#{(context.grandfathered || []).size} |"]
          delta = context.delta_summary
          if delta
            delta_counts = delta[:counts] || {}
            rows << ""
            rows << "| new | grown | shrunk | removed | net Δlog2 |"
            rows << "|---|---|---|---|---|"
            rows << "| #{delta_counts[:new].to_i} | #{delta_counts[:grown].to_i} | " \
                    "#{delta_counts[:shrunk].to_i} | #{delta_counts[:removed].to_i} | " \
                    "#{format('%+.3f', delta[:net_log2] || 0.0)} |"
          end
          rows.join("\n")
        end

        def delta_top_table
          rows = (context.delta_top || []).first(10)
          return nil if rows.empty?

          table = ["| Δlog2 | node | b_own | class |", "|---|---|---|---|"]
          rows.each do |row|
            table << "| #{format('%+.3f', row[:delta_log2])} | #{node_cell(row[:file], row[:symbol])} " \
                     "| #{row[:head_branches] || row[:base_branches]} " \
                     "| #{row[:classification].to_s.upcase} |"
          end
          table.join("\n")
        end

        # F8: the first 10 findings in pre-sort order, header "top findings".
        def findings_table
          findings = sorted_findings
          return nil if findings.empty?

          lines = ["### top findings", "",
                   "| rule | severity | node | value | limit | Δlog2 |",
                   "|---|---|---|---|---|---|"]
          findings.first(10).each { |f| lines << finding_row(f) }
          if findings.size > 10
            lines << ""
            lines << "+#{findings.size - 10} more in the details section below"
          end
          lines.join("\n")
        end

        def finding_row(finding)
          value = finding.value_raw || "—"
          limit = finding.threshold_raw || "—"
          "| #{finding.rule} | #{finding.severity} | " \
            "#{node_cell(finding.file, finding.symbol)} | #{value} | #{limit} | " \
            "#{finding.delta_log2 ? format('%+.3f', finding.delta_log2) : '—'} |"
        end

        def node_cell(file, symbol)
          return "PR" if file.nil? && symbol.nil?

          "`#{symbol}` — #{file}"
        end

        def ratchet_table
          entries = context.ratchet || []
          return nil if entries.empty?

          lines = ["| scope | kind | budget | net | verdict |", "|---|---|---|---|---|"]
          entries.each do |e|
            net = e.observed_log2 ? format("%+.3f", e.observed_log2) : "—"
            lines << "| #{e.scope} | #{e.kind} | #{format('%+.3f', e.budget_log2)} " \
                     "| #{net} | #{e.verdict || 'context'} |"
          end
          lines.join("\n")
        end

        def review_surface_section
          rs = context.review_surface
          return nil if rs.nil?

          lines = ["### review surface", "",
                   "**#{rs[:union]} use case(s) to re-verify** (Σ #{rs[:sum]} review reads)"]
          eps = rs[:eps] || []
          if eps.any?
            lines << ""
            lines << "| use case | class | branching_log2 |"
            lines << "|---|---|---|"
            eps.first(20).each do |ep|
              lines << "| `#{ep[:ep_symbol]}` | #{ep[:classification].to_s.upcase} " \
                       "| #{format('%.3f', ep[:branching_log2])} |"
            end
            lines << "+#{eps.size - 20} more (see the JSON artifact)" if eps.size > 20
          end
          unreachable = rs[:unreachable_touched]
          if unreachable && unreachable[:count].to_i.positive?
            lines << ""
            lines << "> #{unreachable[:count]} touched node(s) statically unreachable " \
                     "from any use case (unresolved dispatch likely)"
          end
          disclosures = context.disclosures
          if disclosures
            files = disclosures[:orphan_touched_files] || []
            if files.any?
              lines << "> note: #{files.length} touched file(s) not reachable from any " \
                       "entrypoint: #{files.first(5).join(', ')}" \
                       "#{files.length > 5 ? ", +#{files.length - 5} more" : ''}"
            end
            offsetting = disclosures[:offsetting_zero_count].to_i
            if offsetting.positive?
              lines << "> note: #{offsetting} use case(s) have changed nodes in their " \
                       "cone with no net metric movement"
            end
          end
          lines.join("\n")
        end

        # v0.16 T10 (diff only): compact mirror of the envelope
        # `reusability` block — per-side score-provenance line (Q6/D-C3:
        # committed stamps reflect the last analyze), worst-head-first
        # score-delta table (10 open, +N tail; envelope caps at 20), and
        # the L9-A absorb-candidates blockquote with the O8 hedged copy
        # (candidates carry score ≥ 0 only — the Q8 law extended, so the
        # absorb upsell never renders on a negative-pole node).
        REUSABILITY_OPEN_CAP = 10

        def reusability_section
          r = context.reusability
          return nil if r.nil?

          lines = ["### reusability", "",
                   "base #{side_cell(r[:base])} → head #{side_cell(r[:head])} — " \
                   "_committed stamps reflect the last analyze_"]
          lines.concat(reusability_delta_table(r[:deltas] || []))
          lines.concat(absorb_blockquote(r[:absorb_candidates] || []))
          lines.join("\n")
        end

        def side_cell(side)
          cell = "#{side[:source]} (#{side[:scored_nodes]} scored"
          cell += ", #{side[:stale_stamps]} stale" if side[:stale_stamps].to_i.positive?
          "#{cell})"
        end

        def reusability_delta_table(rows)
          return [] if rows.empty?

          lines = ["", "| node | class | base | head | Δraw (milli) |",
                   "|---|---|---|---|---|"]
          rows.first(REUSABILITY_OPEN_CAP).each do |row|
            lines << "| #{node_cell(row[:file], row[:symbol])} " \
                     "| #{row[:classification].to_s.upcase} " \
                     "| #{score_cell(row[:base])} | #{score_cell(row[:head])} " \
                     "| #{row[:delta_raw_milli] ? format('%+d', row[:delta_raw_milli]) : '—'} |"
          end
          if rows.size > REUSABILITY_OPEN_CAP
            lines << ""
            lines << "+#{rows.size - REUSABILITY_OPEN_CAP} more (see the JSON artifact)"
          end
          lines
        end

        def score_cell(side)
          side ? format("%+g", side[:score]) : "—"
        end

        def absorb_blockquote(candidates)
          return [] if candidates.empty?

          parts = candidates.map do |c|
            raw = c[:absorb_raw] ? format("%g", c[:absorb_raw]) : "n/a"
            "`#{c[:symbol]}` absorb #{format('%+g', c[:absorb])} (raw #{raw})"
          end
          ["",
           "> absorb candidates — a listed function or a sibling at its call " \
           "site could absorb caller-side decisions: #{parts.join('; ')}"]
        end

        # Lint: top-20 open + rows 21–120 in <details> (cap 120 — R4 §Q4;
        # ~17 KB worst case, far under the 65,536-char budget).
        def use_cases_section
          uc = context.use_cases
          return nil if uc.nil? || (uc[:leaderboard] || []).empty?

          rows = uc[:leaderboard]
          total = uc[:count].to_i
          lines = ["### use cases", "", table_header]
          rows.first(USE_CASE_OPEN_CAP).each { |row| lines << use_case_row(row) }
          hidden = rows[USE_CASE_OPEN_CAP, USE_CASE_DETAILS_CAP - USE_CASE_OPEN_CAP] || []
          if hidden.any?
            lines << ""
            lines << "<details><summary>use cases 21–#{[total, USE_CASE_DETAILS_CAP].min}</summary>"
            lines << ""
            lines << table_header
            hidden.each { |row| lines << use_case_row(row) }
            lines << ""
            lines << "</details>"
          end
          if total > USE_CASE_DETAILS_CAP
            lines << ""
            lines << "+#{total - USE_CASE_DETAILS_CAP} more (see the JSON artifact)"
          end
          lines.join("\n")
        end

        def table_header
          "| # | use case | kind | branching_log2 | mass | reach | files | depth " \
            "| dividend | max_cone_node_log2 | cost_note |\n" \
            "|---|---|---|---|---|---|---|---|---|---|---|"
        end

        def use_case_row(row)
          dividend = row["dividend"] ? format("%g", row["dividend"]) : "—"
          "| #{row['rank']} | #{node_cell(row['file'], row['ep'])} | #{row['kind']} " \
            "| #{format('%.3f', row['branching_log2'])} | #{row['mass']} | #{row['reach']} " \
            "| #{row['files']} | #{row['depth']} | #{dividend} " \
            "| #{format('%.3f', row['max_cone_node_log2'])} | #{row['cost_note'] || '—'} |"
        end

        def calibration_blockquote
          calibration = context.calibration || {}
          lines = (calibration[:lines] || []).map { |line| "> #{line}" }
          return nil if lines.empty?

          lines << "> _#{calibration[:provenance]}_" if calibration[:provenance]
          lines.join("\n")
        end

        def findings_details
          findings = sorted_findings
          return nil if findings.empty?

          lines = ["<details><summary>All findings (#{findings.size})</summary>", "",
                   "| rule | severity | node | value | limit | Δlog2 |",
                   "|---|---|---|---|---|---|"]
          findings.first(FINDINGS_DETAILS_CAP).each { |f| lines << finding_row(f) }
          if findings.size > FINDINGS_DETAILS_CAP
            lines << ""
            lines << "+#{findings.size - FINDINGS_DETAILS_CAP} more (see the JSON artifact)"
          end
          lines << ""
          lines << "</details>"
          lines.join("\n")
        end

        def grandfathered_details
          skips = context.grandfathered || []
          return nil if skips.empty?

          healed = skips.count(&:healed)
          lines = ["<details><summary>Grandfathered: #{skips.size} (#{healed} healed)</summary>", ""]
          skips.each do |s|
            lines << "- #{s.rule} `#{s.symbol}` — #{s.file} (recorded #{s.recorded}" \
                     "#{s.healed ? ', healed' : ''})"
          end
          lines << ""
          lines << "</details>"
          lines.join("\n")
        end

        def not_evaluable_details
          notes = context.not_evaluable || []
          excluded = context.excluded_files || []
          return nil if notes.empty? && excluded.empty?

          lines = ["<details><summary>Not evaluable / excluded files</summary>", ""]
          notes.each { |n| lines << "- #{n[:rule]}: #{n[:reason]}" }
          excluded.each { |f| lines << "- excluded: #{f}" }
          lines << ""
          lines << "</details>"
          lines.join("\n")
        end
      end

      Formatter.register("markdown", Markdown)
    end
  end
end
