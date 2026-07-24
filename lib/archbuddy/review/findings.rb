# frozen_string_literal: true

require_relative "../config/schema"

module Archbuddy
  module Review
    # The canonical result object (G1 member set + the v0.15 additive
    # #review_surface, I-P6'). Grandfathered skips, no_match ratchet entries,
    # lint ratchet context, and not_evaluable notes NEVER gate; the exit math
    # is finding-OR-breach at severity ≥ the effective fail level.
    class Findings
      # One value-pinned todo skip (raw integers — G7/Q7).
      GrandfatherSkip = Struct.new(:rule, :file, :symbol, :recorded, :current, :healed,
                                   keyword_init: true)

      # One ratchet budget outcome. Diff: verdict :pass|:breach|:no_match +
      # observed_log2. Lint: verdict nil + current_total_log2 + matched_files.
      # Both: scope (rendered), kind 'paths'|'entrypoint', scope_paths,
      # budget_log2, severity, empty_scope, contributors, message.
      RatchetEntry = Struct.new(:scope, :kind, :scope_paths, :budget_log2, :verdict,
                                :observed_log2, :current_total_log2, :matched_files,
                                :empty_scope, :severity, :contributors, :message,
                                keyword_init: true)

      attr_reader :findings, :grandfathered, :not_evaluable, :ratchet
      attr_accessor :review_surface

      def initialize(findings: [], grandfathered: [], not_evaluable: [], ratchet: [],
                     review_surface: nil, vintage_empty: false)
        @findings = findings
        @grandfathered = grandfathered
        @not_evaluable = not_evaluable
        @ratchet = ratchet
        @review_surface = review_surface
        @vintage_empty = vintage_empty
      end

      def vintage_empty?
        @vintage_empty
      end

      # Findings only — skips/notes/context never counted.
      def counts
        @counts ||= begin
          tally = { error: 0, warn: 0, info: 0 }
          @findings.each { |f| tally[f.severity] += 1 if tally.key?(f.severity) }
          tally
        end
      end

      # 1 iff level ≠ :none AND ≥1 finding-OR-BREACH at severity ≥ level
      # ([S:C5] — the single owner of gate math).
      def exit_code(effective_fail_level)
        return 0 if effective_fail_level.nil? || effective_fail_level == :none

        rank = Config::Schema::SEVERITIES
        floor = rank.fetch(effective_fail_level)
        gating_finding = @findings.any? { |f| rank.fetch(f.severity, 0) >= floor }
        gating_breach = @ratchet.any? do |entry|
          entry.verdict == :breach && rank.fetch(entry.severity || :error, 0) >= floor
        end
        gating_finding || gating_breach ? 1 : 0
      end

      def grandfather_summary
        {
          entries: @grandfathered.size,
          nodes: @grandfathered.map { |s| [s.file, s.symbol] }.uniq.size,
          rules: @grandfathered.map(&:rule).uniq.size,
          healed: @grandfathered.count(&:healed)
        }
      end
    end
  end
end
