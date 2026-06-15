# frozen_string_literal: true

require_relative "../formatter"
require_relative "../explanation"

module Archbuddy
  module Report
    module Formatters
      # The default human-facing formatter. For each ranked bottleneck it shows
      # the REAL symbol, file:line, clutter_score AND the full 8-metric breakdown
      # (the user's "direct scoring on each bottleneck"), plus the de-anonymized
      # finding explanations — including long_path / cycle findings rendered as
      # real ordered call chains (User#save → Billing#charge).
      #
      # All values are shown VERBATIM as they came from findings.yml (D17). The
      # output contains real symbols, so it is SECRET/local-only.
      class TerminalFormatter < Formatter
        def render
          lines = []
          lines << header
          lines.concat(bottleneck_sections)
          lines.concat(rollup_section) unless context.class_rollups.empty?
          lines << ""
          lines.join("\n")
        end

        private

        def header
          gen = context.generator || {}
          tool = gen["tool"] || gen[:tool] || "unknown"
          "archbuddy report — clutter ranking (source: #{tool})\n" \
            "#{'=' * 60}"
        end

        def bottleneck_sections
          context.ranked.each_with_index.flat_map do |b, i|
            section_for(b, i + 1)
          end
        end

        def section_for(bottleneck, rank)
          loc   = bottleneck.location
          score = format_score(bottleneck.clutter_score)

          lines = []
          lines << ""
          lines << "##{rank}  #{loc.symbol}  [clutter #{score}]"
          lines << "    kind: #{bottleneck.kind || 'unknown'}    #{location_line(loc)}"
          lines << "    metrics:"
          metric_keys.each do |key|
            lines << "      #{key.ljust(12)} #{format_metric(bottleneck.metrics[key])}"
          end
          unless bottleneck.findings.empty?
            lines << "    findings:"
            bottleneck.findings.each { |f| lines.concat(finding_lines(f)) }
          end
          lines
        end

        def finding_lines(finding)
          lines = ["      - #{Explanation.describe(finding)}"]
          lines << "        chain: #{finding.chain}" if finding.path?
          lines
        end

        def rollup_section
          lines = ["", "Class rollups (D9 — summed clutter by class)", "-" * 60]
          context.class_rollups.each_with_index do |r, i|
            count = r.metrics["member_count"]
            lines << "  ##{i + 1}  #{r.location.symbol}  " \
                     "[clutter #{format_score(r.clutter_score)}, #{count} member#{'s' if count != 1}]"
          end
          lines
        end

        def location_line(loc)
          loc.resolved? ? loc.file_line : "(unresolved — #{loc.symbol})"
        end

        def format_score(value)
          return "n/a" if value.nil?

          format("%.4f", value)
        end

        def format_metric(value)
          return "null" if value.nil?
          return value.to_s if value.is_a?(Integer)

          format("%.4f", value)
        rescue TypeError
          value.inspect
        end
      end
    end
  end
end

Archbuddy::Report::Formatter.register(
  "terminal", Archbuddy::Report::Formatters::TerminalFormatter
)
