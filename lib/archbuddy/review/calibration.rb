# frozen_string_literal: true

require "did_you_mean"

module Archbuddy
  module Review
    # The single source of truth for calibration: the frozen builtin-study-v1
    # exacts (A4), source-resolution semantics, and (in calibration/lines.rb)
    # the honest-copy line renderer. PRESENTER-ONLY by construction: rules and
    # the exit path never read any of this (grep-gated).
    module Calibration
      PROVENANCE_BUILTIN = "measured on a Rails/Grape service, n=433 merged PRs " \
                           "(239-PR dose-response corpus), 2025-10-22 → 2026-07-22, archbuddy engine 0.10.0 + " \
                           "client 0.12.0 — not measured on this repository" # final clause drops for source: local
      BUGFIX_CAVEAT = " (directional: bugfix labels failed the study's validation bar)"

      BUILTIN = {
        "source" => "builtin-study-v1",
        "provenance" => PROVENANCE_BUILTIN,
        "latency_multiplier_per_log2_unit" => 1.11184, # 95% CI below; β_T 0.106018 HC1
        "latency_multiplier_ci95" => [1.0496, 1.1778].freeze,
        "t_quartile_cuts" => [2.0, 3.0, 5.0].freeze,   # Q4 = STRICTLY above cuts[2] (ties low, A1)
        # median(latency_hours / churn) per PR, Q4 vs Q1 of the frozen T2 corpus
        # (h2_pr_table.csv, n=239 edit PRs, 0 zero-churn rows):
        # 0.372231 / 0.146058 = 2.5485. See docs/RECALIBRATION.md.
        "cost_per_line_ratio_q4_vs_q1" => 2.5485,
        "bugfix_rate_ratio_q4_vs_q1" => 3.18969,       # classifier failed validation → caveat mandatory
        "latency_arm_medians_hours" => [69.8075, 21.8639].freeze
      }.freeze

      VALUE_KEYS = %w[
        latency_multiplier_per_log2_unit latency_multiplier_ci95 t_quartile_cuts
        cost_per_line_ratio_q4_vs_q1 bugfix_rate_ratio_q4_vs_q1 latency_arm_medians_hours
      ].freeze

      SOURCES = %w[builtin-study-v1 local none].freeze

      Resolved = Data.define(:source, :provenance, :values)

      module_function

      # Resolve the parsed `calibration:` block (Hash or nil). P1's validator
      # enforces the same table at config-load time (C12); this re-raises
      # DEFENSIVELY on the identical conditions.
      #
      # | input                                       | result                      |
      # | nil / absent                                | builtin                     |
      # | source builtin + NO value keys              | builtin                     |
      # | source builtin + any value/provenance key   | ArgumentError               |
      # | source local + provenance (+ value subset)  | local (NO builtin backfill) |
      # | source local w/o provenance                 | ArgumentError               |
      # | source none, nothing else                   | none (all lines suppressed) |
      # | source none + any other key                 | ArgumentError               |
      # | unknown key                                 | ArgumentError + did-you-mean|
      def resolve(block)
        return builtin_resolved if block.nil?

        doc = block.transform_keys(&:to_s)
        source = doc.fetch("source", "builtin-study-v1")

        case source
        when "builtin-study-v1"
          extras = doc.keys - ["source"]
          unless extras.empty?
            raise ArgumentError,
                  "calibration value overrides require `source: local` with a `provenance` string " \
                  "(found: #{extras.sort.join(', ')})"
          end
          builtin_resolved
        when "local"
          provenance = doc["provenance"]
          unless provenance.is_a?(String) && !provenance.empty?
            raise ArgumentError, "calibration.provenance is required when source: local"
          end
          check_unknown_keys(doc.keys - %w[source provenance])
          Resolved.new(source: "local", provenance: provenance, values: doc.slice(*VALUE_KEYS).freeze)
        when "none"
          extras = doc.keys - ["source"]
          unless extras.empty?
            raise ArgumentError,
                  "calibration source 'none' allows no other keys (found: #{extras.sort.join(', ')})"
          end
          Resolved.new(source: "none", provenance: nil, values: {}.freeze)
        else
          raise ArgumentError, "unknown calibration source '#{source}' (builtin-study-v1|local|none)"
        end
      end

      def builtin_resolved
        Resolved.new(source: "builtin-study-v1", provenance: PROVENANCE_BUILTIN, values: BUILTIN)
      end

      def check_unknown_keys(keys)
        unknown = keys - VALUE_KEYS
        return if unknown.empty?

        checker = DidYouMean::SpellChecker.new(dictionary: VALUE_KEYS)
        hints = unknown.map do |k|
          candidate = checker.correct(k).first
          candidate ? "unknown calibration key '#{k}' — did you mean '#{candidate}'?" : "unknown calibration key '#{k}'"
        end
        raise ArgumentError, hints.join("\n")
      end
    end
  end
end

require_relative "calibration/lines"
