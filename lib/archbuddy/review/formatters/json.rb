# frozen_string_literal: true

require "json"
require_relative "../formatter"

module Archbuddy
  module Review
    module Formatters
      # The `archbuddy-diff-report/1` envelope (name UNCHANGED — L4; every
      # v0.15 addition additive; the v0.16 `reusability` key additive the
      # same way). Omission posture: delta/ratchet/delta_top/
      # review_surface/disclosures keys ABSENT (not null) in lint;
      # `use_cases` lint-only after `summary`; TOP-LEVEL `review_surface`
      # after `ratchet` (R41); `summary.unreachable_from_entrypoints` in
      # BOTH commands, key ABSENT when edges absent or zero eps (Q8/R37);
      # `reusability` (v0.16 T10) diff-only AFTER `review_surface`, ABSENT
      # in lint and ABSENT when neither side carries a score stamp (absent
      # ≠ null — the envelope posture). Floats round(6); insertion-ordered
      # hashes + JSON.pretty_generate = byte-deterministic.
      class Json < Formatter
        def render
          JSON.pretty_generate(envelope)
        end

        private

        def lint?
          context.command == "lint"
        end

        def envelope
          doc = {
            "schema" => "archbuddy-diff-report/1",
            "tool" => stringify(context.tool || {}),
            "run" => run_block,
            "summary" => summary_block
          }
          doc["use_cases"] = use_cases_block if lint? && context.use_cases
          doc["findings"] = sorted_findings.map { |f| finding_row(f) }
          unless lint?
            doc["delta_top"] = (context.delta_top || []).map { |row| delta_top_row(row) }
            doc["ratchet"] = ratchet_rows
            doc["review_surface"] = review_surface_block if context.review_surface
            doc["reusability"] = reusability_block if context.reusability
          end
          doc["ratchet_context"] = ratchet_context_rows if lint? && ratchet_context_rows.any?
          doc["grandfathered"] = grandfathered_rows
          doc["calibration"] = calibration_block
          doc["exit_code"] = context.exit_code
          doc
        end

        def run_block
          run = {
            "command" => context.command,
            "target" => context.target,
            "config" => context.config_path,
            "advisory" => !!context.advisory,
            "fail_level" => context.fail_level.to_s
          }
          run["base"] = stringify(context.base) if context.base && !lint?
          run["head"] = stringify(context.head) if context.head
          run
        end

        def summary_block
          tally = counts
          skips = context.grandfathered || []
          summary = {
            "counts" => { "error" => tally[:error], "warn" => tally[:warn],
                          "info" => tally[:info], "grandfathered" => skips.size }
          }
          delta = context.delta_summary
          if delta
            delta_counts = delta[:counts] || {}
            summary["delta"] = {
              "nodes_new" => delta_counts[:new].to_i,
              "nodes_grown" => delta_counts[:grown].to_i,
              "nodes_shrunk" => delta_counts[:shrunk].to_i,
              "nodes_removed" => delta_counts[:removed].to_i,
              "net_log2_b_own" => round6(delta[:net_log2] || 0.0)
            }
          end
          unreachable = unreachable_from_entrypoints
          if unreachable
            summary["unreachable_from_entrypoints"] = {
              "nodes" => unreachable[:nodes],
              "share" => unreachable[:share].to_f.round(4),
              "files" => unreachable[:files]
            }
          end
          if !lint? && context.disclosures
            summary["disclosures"] = {
              "orphan_touched_files" => context.disclosures[:orphan_touched_files] || [],
              "offsetting_zero_count" => context.disclosures[:offsetting_zero_count].to_i
            }
          end
          summary["not_evaluable"] = (context.not_evaluable || []).map do |entry|
            { "rule" => entry[:rule], "reason" => entry[:reason] }
          end
          summary["excluded_files"] = context.excluded_files || []
          summary
        end

        # Lint: the leaderboard's unreachable member; diff: threaded through
        # delta_summary by the CLI (the same head-graph read).
        def unreachable_from_entrypoints
          (context.use_cases && context.use_cases[:unreachable]) ||
            (context.delta_summary && context.delta_summary[:unreachable_from_entrypoints])
        end

        def use_cases_block
          uc = context.use_cases
          {
            "count" => uc[:count].to_i,
            "leaderboard" => (uc[:leaderboard] || []).map { |row| stringify(row) }
          }
        end

        def finding_row(finding)
          row = {
            "rule" => finding.rule,
            "severity" => finding.severity.to_s,
            "file" => finding.file,
            "symbol" => finding.symbol,
            "line" => nil, # ALWAYS null in v1 — fragments are line-free (D7)
            "values" => values_for(finding),
            "value_raw" => finding.value_raw,
            "value_log2" => round6(finding.value_log2),
            "delta_log2" => round6(finding.delta_log2),
            "threshold_raw" => finding.threshold_raw,
            "threshold_log2" => round6(finding.threshold_log2),
            "message" => finding.message,
            "grandfathered" => finding.grandfathered_refire?,
            "fingerprint" => finding.fingerprint
          }
          row["components"] = components_for(finding) if finding.components
          row["contributors"] = contributors_for(finding) if finding.contributors
          row["contributors_omitted"] = finding.contributors_omitted if finding.contributors_omitted
          row["entrypoint_kind"] = finding.entrypoint_kind if finding.entrypoint_kind
          row["scope"] = "pr" if finding.scope == :pr
          row
        end

        # [S:F11]: delta_index feeds NODE findings only — `values` is null on
        # ep findings (components) and :pr findings.
        def values_for(finding)
          return nil if finding.components || finding.scope

          entry = context.delta_index && context.delta_index[[finding.file, finding.symbol]]
          return nil unless entry

          { "base_branches" => entry[:base_branches], "head_branches" => entry[:head_branches] }
        end

        def components_for(finding)
          finding.components.to_h do |key, component|
            [key.to_s, { "value" => round6(component[:value]),
                         "threshold" => round6(component[:threshold]),
                         "breached" => !!component[:breached] }]
          end
        end

        def contributors_for(finding)
          finding.contributors.map do |c|
            { "file" => c[:file], "symbol" => c[:symbol], "value_raw" => c[:value_raw],
              "value_log2" => round6(c[:value_log2]), "delta_log2" => round6(c[:delta_log2]),
              "coupling_flip" => !!c[:coupling_flip] }
          end
        end

        def delta_top_row(row)
          { "file" => row[:file], "symbol" => row[:symbol],
            "classification" => row[:classification].to_s.upcase,
            "base_branches" => row[:base_branches], "head_branches" => row[:head_branches],
            "delta_log2" => round6(row[:delta_log2]) }
        end

        def ratchet_rows
          (context.ratchet || []).map do |entry|
            { "scope" => entry.scope, "kind" => entry.kind,
              "budget_log2" => round6(entry.budget_log2),
              "observed_log2" => round6(entry.observed_log2),
              "verdict" => entry.verdict.to_s, "severity" => entry.severity.to_s,
              "empty_scope" => !!entry.empty_scope }
          end
        end

        def ratchet_context_rows
          @ratchet_context_rows ||= (context.ratchet || []).select { |e| e.verdict.nil? }
                                                           .map do |entry|
            { "scope_paths" => entry.scope_paths, "kind" => entry.kind,
              "budget_log2" => round6(entry.budget_log2),
              "current_total_log2" => round6(entry.current_total_log2),
              "matched_files" => entry.matched_files,
              "empty_scope" => !!entry.empty_scope }
          end
        end

        def review_surface_block
          rs = context.review_surface
          {
            "union" => rs[:union], "sum" => rs[:sum],
            "eps" => (rs[:eps] || []).map do |ep|
              { "file" => ep[:file], "ep_symbol" => ep[:ep_symbol],
                "branching_log2" => round6(ep[:branching_log2]),
                "classification" => ep[:classification].to_s.upcase }
            end,
            "unreachable_touched" => {
              "count" => rs.dig(:unreachable_touched, :count).to_i,
              "nodes" => (rs.dig(:unreachable_touched, :nodes) || []).map do |n|
                { "file" => n[:file], "symbol" => n[:symbol] }
              end
            }
          }
        end

        def grandfathered_rows
          (context.grandfathered || []).map do |skip|
            { "rule" => skip.rule, "file" => skip.file, "symbol" => skip.symbol,
              "recorded" => skip.recorded, "current" => skip.current,
              "healed" => !!skip.healed }
          end
        end

        # v0.16 T10: the reusability block — per-side score provenance
        # (committed stamps reflect the LAST ANALYZE — Q6/D-C3 disclosure),
        # score deltas on published `score_raw` milli (null-tolerant), and
        # the L9-A absorb-candidates disclosure. Every value arrives
        # engine-published (or a published-milli subtraction) from the CLI;
        # round6 is an idempotent pass-through on 2/3 dp reals.
        def reusability_block
          r = context.reusability
          {
            "base" => side_provenance_row(r[:base]),
            "head" => side_provenance_row(r[:head]),
            "deltas" => (r[:deltas] || []).map { |row| score_delta_row(row) },
            "absorb_candidates" => (r[:absorb_candidates] || []).map { |row| absorb_row(row) }
          }
        end

        def side_provenance_row(side)
          { "source" => side[:source], "analyzed" => !!side[:analyzed],
            "serializer" => side[:serializer] || [],
            "scored_nodes" => side[:scored_nodes].to_i,
            "stale_stamps" => side[:stale_stamps].to_i }
        end

        def score_delta_row(row)
          { "file" => row[:file], "symbol" => row[:symbol],
            "classification" => row[:classification].to_s.upcase,
            "base" => score_side(row[:base]), "head" => score_side(row[:head]),
            "delta_raw_milli" => row[:delta_raw_milli] }
        end

        # null when that side lacks the stamp (never fabricated — L6).
        def score_side(side)
          side && { "score" => round6(side[:score]), "score_raw" => round6(side[:score_raw]) }
        end

        def absorb_row(row)
          { "file" => row[:file], "symbol" => row[:symbol],
            "score" => round6(row[:score]), "absorb" => round6(row[:absorb]),
            "absorb_raw" => round6(row[:absorb_raw]) }
        end

        def calibration_block
          calibration = context.calibration || {}
          { "source" => calibration[:source] || "none",
            "provenance" => calibration[:provenance],
            "lines" => calibration[:lines] || [] }
        end

        def round6(value)
          value.is_a?(Float) ? value.round(6) : value
        end

        def stringify(hash)
          hash.to_h { |k, v| [k.to_s, v] }
        end
      end

      Formatter.register("json", Json)
    end
  end
end
