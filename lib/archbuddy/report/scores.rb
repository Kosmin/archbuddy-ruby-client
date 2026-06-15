# frozen_string_literal: true

require_relative "model"

module Archbuddy
  module Report
    # R-8: the de-anonymized presentation model for findings.yml's OPTIONAL
    # project-level `scores` block (findings 1.1, additive over the per-node
    # metric kernel).
    #
    # The engine produces two eslint/rubocop-style dimensions, each a project
    # score (0-100 or null) + letter grade + OPAQUE worst-first hotspot ids:
    #
    #   reverse_traceability    — "can you tell where code is USED?"
    #   forward_discoverability — "can you FOLLOW where execution goes?"
    #
    # The reporter copies score/grade VERBATIM (never recomputes — D17), and
    # de-anonymizes each dimension's hotspot ids via the SAME IdMapResolver used
    # everywhere else (graceful `<external …>` placeholders for missing/ext_ ids).
    #
    # A findings 1.0 doc has NO `scores` block; `Scores.from_findings` returns nil
    # in that case and the reporter renders exactly as before (back-compat).
    module Scores
      # Display order: reverse first (it's always computable; forward can be N/A).
      # Each entry: [findings key, human label, one-line framing question].
      DIMENSIONS = [
        ["reverse_traceability",    "Reverse Traceability",    "can you tell where code is used?"],
        ["forward_discoverability", "Forward Discoverability", "can you follow where execution goes?"]
      ].freeze

      # The metric(s) that drive each dimension's per-node penalty (engine
      # ProjectScorer). Surfaced next to each hotspot so the reader sees WHY a
      # node is a top contributor to this dimension — pulled VERBATIM from the
      # per-node `nodes.<id>.metrics` already in findings.yml (D17).
      DRIVING_METRICS = {
        "reverse_traceability"    => %w[fan_in centrality in_cycle],
        "forward_discoverability" => %w[path_length fan_out]
      }.freeze

      # Honest reason rendered when forward_discoverability is N/A because the
      # collection found no entrypoints (M3) — actionable, not a dead end.
      NA_REASON = "no entrypoints — re-collect with --entrypoints all_public"

      # A de-anonymized hotspot: a resolved Location plus the driving-metric
      # values for the dimension it's a hotspot of (verbatim from findings).
      Hotspot = Struct.new(:location, :metrics, keyword_init: true) do
        def symbol
          location.symbol
        end

        def file_line
          location.file_line
        end
      end

      # One dimension's de-anonymized presentation model. score/grade are
      # VERBATIM from findings.yml; hotspots are resolved Locations (worst-first).
      DimensionScore = Struct.new(
        :key, :label, :question, :score, :grade, :hotspots, :na_reason,
        keyword_init: true
      ) do
        # True when the engine could not determine a score (null score / "N/A"
        # grade) — e.g. forward_discoverability with no entrypoints.
        def na?
          score.nil?
        end

        # "58/100  (D)" when scored; "N/A" when undeterminable.
        def display_score
          na? ? "N/A" : "#{score}/100"
        end
      end

      module_function

      # Parse + de-anonymize the `scores` block. Returns an ordered Array of
      # DimensionScore (reverse first), or NIL when the findings doc carries no
      # scores block (a 1.0 doc) — graceful absence (back-compat).
      #
      # @param findings_doc [Hash] parsed findings.yml (string keys)
      # @param resolver     [#resolve] id → Model::Location (the SAME id-map join)
      # @return [Array<DimensionScore>, nil]
      def from_findings(findings_doc, resolver)
        block = (findings_doc || {})["scores"]
        return nil if block.nil? || block.empty?

        DIMENSIONS.map do |key, label, question|
          dim = block[key] || {}
          build_dimension(key, label, question, dim, findings_doc, resolver)
        end
      end

      def build_dimension(key, label, question, dim, findings_doc, resolver)
        score = dim["score"]
        DimensionScore.new(
          key:       key,
          label:     label,
          question:  question,
          score:     score,            # VERBATIM (D17) — 0-100 or nil
          grade:     dim["grade"],     # VERBATIM — "A".."F" or "N/A"
          hotspots:  build_hotspots(key, dim["hotspots"] || [], findings_doc, resolver),
          na_reason: (score.nil? && key == "forward_discoverability" ? NA_REASON : nil)
        )
      end

      # De-anonymize each opaque hotspot id (worst-first order preserved) and
      # attach the dimension's driving-metric values pulled verbatim from the
      # per-node metrics already in findings.yml.
      def build_hotspots(key, opaque_ids, findings_doc, resolver)
        nodes        = (findings_doc || {})["nodes"] || {}
        driving_keys = DRIVING_METRICS.fetch(key, [])

        opaque_ids.map do |id|
          node_metrics = (nodes[id] || {})["metrics"] || {}
          driving      = driving_keys.each_with_object({}) { |k, h| h[k] = node_metrics[k] }

          Hotspot.new(location: resolver.resolve(id), metrics: driving)
        end
      end
    end
  end
end
