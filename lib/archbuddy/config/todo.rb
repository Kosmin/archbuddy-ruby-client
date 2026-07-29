# frozen_string_literal: true

require "yaml"
require "did_you_mean"
require_relative "schema"

module Archbuddy
  class Config
    # `.archbuddy_todo.yml` v1 (Q7 — value-pinned grandfathering at node AND
    # (file, ep-symbol) granularity):
    #
    #   * node-kind entries, two `value:` flavors (both RAW integers):
    #       - ExponentialNode: raw branches
    #       - ReusabilityScore (v0.16): reusability debt milli —
    #         `(-score_raw × 1000).round`, a positive integer that GROWS as
    #         the node worsens, so the engine's `value_raw <= recorded` skip
    #         predicate works verbatim
    #   * use-case entries (UseCaseComplexity/UseCaseDividend/FirewallBreaches):
    #     per-metric `values:` map of RAW INTEGERS — milli-log2
    #     `(metric_log2 × 1000).round` for `*_millilog2` keys, native counts
    #     elsewhere. Integer comparison ONLY downstream — no float anywhere in
    #     the skip predicate.
    #
    # The loader is STRICT: never-grandfatherable rule keys (R45 template),
    # retired names (RETIRED_RULES error), unknown rules (did-you-mean over
    # the 5 GRANDFATHERABLE), shape confusion, non-integers, malformed node
    # strings, and stale header counts are all ValidationErrors.
    class Todo
      # Component-key → [todo metric key, encoding] (Q7). millilog2 encodes
      # the component's LOG2 value; native keys copy the integer count.
      COMPONENT_TO_METRIC = {
        "UseCaseComplexity" => {
          "branching_log2" => ["branching_millilog2", :millilog2],
          "max_cone_node_log2" => ["max_cone_node_millilog2", :millilog2],
          "mass" => ["mass", :native],
          "depth" => ["depth", :native],
          "reach" => ["reach", :native],
          "files" => ["files", :native]
        }.freeze,
        "UseCaseDividend" => {
          "dividend_log2" => ["dividend_millilog2", :millilog2]
        }.freeze,
        "FirewallBreaches" => {
          "escapes" => ["escapes", :native]
        }.freeze
      }.freeze

      NEVER_GRANDFATHERED = %w[ComplexityRatchet MultiplicativeGrowth ReviewSurface].freeze
      REJECT_TEMPLATE = "'%s' is never grandfathered (L5) — grandfatherable: " \
                        "ExponentialNode, FirewallBreaches, ReusabilityScore, " \
                        "UseCaseComplexity, UseCaseDividend"

      UNIT_NOTE = [
        "# values are raw integers: native counts (mass, depth, reach, files, escapes, branches)",
        "# or milli-log2 ((log2 x 1000).round) for *_millilog2 keys; display renders log2 to 1dp",
        "# ReusabilityScore value: is debt milli ((-score_raw x 1000).round); grows as the node worsens"
      ].freeze

      class << self
        # @param path [String]
        # @return [Todo]
        # @raise [Config::ValidationError]
        def load(path)
          raw = begin
            YAML.safe_load(File.read(path), permitted_classes: [], aliases: false)
          rescue Psych::Exception => e
            raise ValidationError, "todo YAML parse error at #{path}: #{e.message}"
          rescue SystemCallError
            raise ValidationError, "todo file '#{path}' not found"
          end

          errors = []
          entries = parse_document(raw.nil? ? {} : raw, errors)
          raise ValidationError, errors.join("\n") unless errors.empty?

          new(entries)
        end

        # Deterministic YAML (rules alphabetical, entries by node string,
        # counts computed; no timestamp unless stamp:).
        # @param findings [Array] #rule/#file/#symbol + #value_raw (node kind)
        #   or #components (use-case kind, {value:, threshold:, breached:}
        #   triples — BREACHING components only are recorded)
        def generate(findings:, command_line:, tool_version:, stamp: false)
          entries = {}
          findings.each do |finding|
            rule = finding.rule
            next unless Schema::GRANDFATHERABLE.include?(rule)

            node = node_string(finding.file, finding.symbol)
            entry = { "node" => node }
            if Schema::NODE_RULES.include?(rule)
              entry["value"] = Integer(finding.value_raw)
            else
              values = encode_components(rule, finding)
              next if values.empty?

              entry["values"] = values
            end
            (entries[rule] ||= []) << entry
          end
          render(entries, command_line: command_line, tool_version: tool_version, stamp: stamp)
        end

        def node_string(file, symbol)
          if file.to_s.include?(": ")
            raise ValidationError,
                  "cannot generate a todo node string for '#{file}' (path contains ': ')"
          end
          "#{file}: #{symbol}"
        end

        # Record BREACHING components only, at their current values (Q7).
        def encode_components(rule, finding)
          mapping = COMPONENT_TO_METRIC.fetch(rule)
          components = finding.components || {}
          out = {}
          mapping.each do |component_key, (metric_key, encoding)|
            component = components[component_key] || components[component_key.to_sym]
            next if component.nil?

            breached = component.is_a?(Hash) ? component[:breached] || component["breached"] : true
            next unless breached

            value = component.is_a?(Hash) ? component[:value] || component["value"] : component
            next if value.nil?

            out[metric_key] = encoding == :millilog2 ? (value * 1000).round : Integer(value)
          end
          out.sort.to_h
        end

        def render(entries_by_rule, command_line:, tool_version:, stamp: false)
          lines = []
          lines << "# Auto-generated by `#{command_line}`"
          lines << "# using #{tool_version}. Do not edit by hand; entries drop when violations heal."
          lines.concat(UNIT_NOTE)
          lines << "# Generated at: #{Time.now.utc.strftime('%Y-%m-%dT%H:%M:%SZ')}" if stamp
          lines << "version: 1"
          lines << "tool: \"#{tool_version}\""

          sorted = entries_by_rule.sort.to_h
          node_count = sorted.values.flatten.map { |e| e["node"] }.uniq.size
          lines << "rule_count: #{sorted.size}"
          lines << "node_count: #{node_count}"

          if sorted.empty?
            lines << "rules: {}"
          else
            lines << "rules:"
            sorted.each do |rule, entries|
              lines << "  #{rule}:"
              entries.sort_by { |e| e["node"] }.each do |entry|
                lines << "    - node: \"#{entry['node']}\""
                if entry.key?("value")
                  lines << "      value: #{entry['value']}"
                else
                  rendered = entry["values"].sort.map { |k, v| "#{k}: #{v}" }.join(", ")
                  lines << "      values: { #{rendered} }"
                end
              end
            end
          end
          "#{lines.join("\n")}\n"
        end

        private

        # rubocop-style document walk collecting ALL errors.
        def parse_document(doc, errors)
          unless doc.is_a?(Hash)
            errors << "todo root must be a mapping"
            return {}
          end

          (doc.keys - %w[version tool rule_count node_count rules]).each do |key|
            errors << "unknown key '#{key}' at todo top level"
          end
          errors << "todo version must be 1" unless doc["version"] == 1

          rules = doc["rules"] || {}
          unless rules.is_a?(Hash)
            errors << "todo rules must be a mapping"
            return {}
          end

          entries = {}
          rules.each do |rule, list|
            next unless validate_rule_key(rule, errors)

            unless list.is_a?(Array)
              errors << "todo rules.#{rule} must be an array of entries"
              next
            end
            entries[rule] = list.filter_map { |raw| parse_entry(rule, raw, errors) }
          end

          check_header_counts(doc, entries, errors)
          entries
        end

        def validate_rule_key(rule, errors)
          return true if Schema::GRANDFATHERABLE.include?(rule)

          if NEVER_GRANDFATHERED.include?(rule)
            errors << format(REJECT_TEMPLATE, rule)
          elsif Schema::RETIRED_RULES.key?(rule)
            errors << "unknown rule '#{rule}' at todo rules — retired: " \
                      "#{Schema::RETIRED_RULES[rule]}; see docs/CONFIGURATION.md#retired-rules"
          else
            checker = DidYouMean::SpellChecker.new(dictionary: Schema::GRANDFATHERABLE)
            candidate = checker.correct(rule).first
            errors << if candidate
                        "unknown rule '#{rule}' at todo rules — did you mean '#{candidate}'?"
                      else
                        "unknown rule '#{rule}' at todo rules"
                      end
          end
          false
        end

        def parse_entry(rule, raw, errors)
          unless raw.is_a?(Hash)
            errors << "#{rule} entry must be a mapping"
            return nil
          end

          (raw.keys - %w[node value values]).each do |key|
            errors << "unknown key '#{key}' at #{rule} entry"
          end

          node = raw["node"]
          unless node.is_a?(String) && node.include?(": ")
            errors << "#{rule} entry node must be a \"<file>: <symbol>\" string"
            return nil
          end

          node_kind = Schema::NODE_RULES.include?(rule)
          if node_kind
            return nil unless check_shape(rule, raw, "value", "values", :node, errors)

            unless raw["value"].is_a?(Integer)
              errors << "#{rule} entry value must be a raw integer"
              return nil
            end
          else
            return nil unless check_shape(rule, raw, "values", "value", :use_case, errors)

            return nil unless validate_values_map(rule, raw["values"], errors)
          end
          raw
        end

        def check_shape(rule, raw, wanted, forbidden, kind, errors)
          if raw.key?(forbidden) || !raw.key?(wanted)
            errors << "'#{rule}' entries use #{wanted}: (kind #{kind})"
            return false
          end
          true
        end

        def validate_values_map(rule, values, errors)
          unless values.is_a?(Hash)
            errors << "#{rule} entry values must be a map of metric → raw integer"
            return false
          end
          if values.empty?
            errors << "empty values map at #{rule} entry"
            return false
          end

          known = Schema::EP_METRIC_KEYS.fetch(rule)
          ok = true
          values.each do |key, value|
            unless known.include?(key)
              errors << "unknown metric '#{key}' at #{rule} entry — known: #{known.join(', ')}"
              ok = false
            end
            unless value.is_a?(Integer)
              errors << "#{rule} entry metric '#{key}' must be a raw integer " \
                        "(milli-log2 for *_millilog2 keys)"
              ok = false
            end
          end
          ok
        end

        def check_header_counts(doc, entries, errors)
          return unless doc["rules"].is_a?(Hash) # structural errors already recorded

          expected_rules = entries.count { |_r, list| !list.empty? }
          expected_nodes = entries.values.flatten.map { |e| e["node"] }.uniq.size
          declared_rules = doc["rule_count"]
          declared_nodes = doc["node_count"]
          return if declared_rules == expected_rules && declared_nodes == expected_nodes

          errors << "todo header counts stale — regenerate"
        end
      end

      def initialize(entries_by_rule)
        @entries_by_rule = entries_by_rule
        @index = {}
        entries_by_rule.each do |rule, entries|
          entries.each do |entry|
            file, symbol = entry["node"].split(": ", 2)
            @index[[rule, file, symbol]] = entry
          end
        end
      end

      attr_reader :entries_by_rule

      # I-P2' dual-shape lookup: `{value: Integer}` (node kind) |
      # `{values: Hash[String→Integer]}` (use-case kind) | nil.
      def entry_for(rule, file, symbol)
        entry = @index[[rule, file, symbol]]
        return nil if entry.nil?

        if entry.key?("value")
          { value: entry["value"] }
        else
          { values: entry["values"] }
        end
      end

      # Re-emit the loaded document (round-trip byte-stability with the same
      # header inputs).
      def regenerate(command_line:, tool_version:, stamp: false)
        self.class.render(@entries_by_rule,
                          command_line: command_line, tool_version: tool_version, stamp: stamp)
      end
    end
  end
end
