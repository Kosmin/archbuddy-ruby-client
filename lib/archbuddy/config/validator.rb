# frozen_string_literal: true

require "did_you_mean"
require_relative "schema"
require_relative "boundary_section"
require_relative "../version"

module Archbuddy
  class Config
    # Table-driven validation of the parsed `.archbuddy.yml` document against
    # Config::Schema: unknown key at ANY level → error naming the full key
    # path + did-you-mean (L4); retired rule names checked BEFORE did-you-mean
    # (Q11); type/enum/min checks; overrides structural checks; the C12
    # calibration table.
    class Validator
      RETIRED_TEMPLATE = "unknown rule '%s' at %s — retired: %s; " \
                         "see docs/CONFIGURATION.md#retired-rules"
      EXCLUDE_ENTRYPOINTS_SCOPE_ERROR =
        "exclude_entrypoints is only valid on entrypoint-scoped rules " \
        "(FirewallBreaches, UseCaseComplexity, UseCaseDividend) — found at rules.%s"

      def initialize(doc)
        @doc = doc
        @errors = []
      end

      # @return [Array<String>] every error, one string each
      def validate
        unless @doc.is_a?(Hash)
          return ["config root must be a mapping (got #{@doc.class}) — minimal valid config: 'version: 1'"]
        end

        check_version
        check_unknown_keys(@doc.keys, Schema::TOP_LEVEL_KEYS, "top level")
        check_todo_file_key
        check_all_block
        check_rules_block(@doc["rules"], "rules", overrides: false)
        check_overrides
        check_calibration
        # configurator W4 (C10): the ONE delegation. Everything about the
        # `boundary:` key — the envelope, the engine's schema call, the L17
        # refusal — belongs to Config::BoundarySection; this file deliberately
        # learns none of its key names (see that class's acceptance anchor).
        @errors.concat(BoundarySection.errors(@doc[BoundarySection::KEY]))
        @errors
      end

      private

      def error(msg)
        @errors << msg
      end

      # ---- version ----------------------------------------------------------

      def check_version
        unless @doc.key?("version")
          error("version is required — minimal valid config: 'version: 1'")
          return
        end
        version = @doc["version"]
        unless version.is_a?(Integer)
          error("version must be an integer")
          return
        end
        if version > 1
          error("config schema v#{version} requires a newer archbuddy " \
                "(this is #{Archbuddy::VERSION}, schema v1)")
        elsif version < 1
          error("unsupported config schema version #{version} (schema v1)")
        end
      end

      def check_todo_file_key
        value = @doc["todo_file"]
        return if value.nil? || value.is_a?(String)

        error("todo_file must be a string path or null")
      end

      # ---- all --------------------------------------------------------------

      def check_all_block
        all = @doc["all"]
        return if all.nil?
        return error("all must be a mapping") unless all.is_a?(Hash)

        check_unknown_keys(all.keys, Schema::ALL_KEYS, "all")
        check_string_array(all["exclude"], "all.exclude")
        check_string_array(all["include"], "all.include")
        if all.key?("fail_level") && !Schema::FAIL_LEVELS.include?(all["fail_level"])
          error("all.fail_level must be one of #{Schema::FAIL_LEVELS.join('|')}")
        end
        if all.key?("format") && !Schema::FORMATS.include?(all["format"])
          error("all.format must be one of #{Schema::FORMATS.join('|')}")
        end
      end

      # ---- rules ------------------------------------------------------------

      def check_rules_block(rules, path, overrides:)
        return if rules.nil?
        return error("#{path} must be a mapping") unless rules.is_a?(Hash)

        rules.each do |name, settings|
          next unless check_rule_name(name, path)

          unless settings.is_a?(Hash)
            error("#{path}.#{name} must be a mapping")
            next
          end
          check_rule_settings(name, settings, "#{path}.#{name}", overrides: overrides)
        end
      end

      # @return [Boolean] true when the name names a living rule
      def check_rule_name(name, path)
        return true if Schema::RULES.key?(name)

        # Retired names FIRST (Q11) — the successor guidance beats did-you-mean.
        if Schema::RETIRED_RULES.key?(name)
          error(format(RETIRED_TEMPLATE, name, path, Schema::RETIRED_RULES[name]))
          return false
        end

        if name.include?("/")
          error("unknown rule '#{name}' at #{path} — rule departments ('/') are reserved (schema v1)")
          return false
        end

        candidate = spell_check(name, Schema::RULES.keys)
        if candidate
          error("unknown rule '#{name}' at #{path} — did you mean '#{candidate}'?")
        else
          error("unknown rule '#{name}' at #{path}")
        end
        false
      end

      def check_rule_settings(name, settings, path, overrides:)
        spec = Schema::RULES[name]
        known = Schema::COMMON_RULE_KEYS + spec[:params].keys

        settings.each_key do |key|
          if overrides && key == "exclude"
            error("exclude is not allowed in overrides — scope via paths (at #{path})")
            next
          end
          if overrides && key == "exclude_entrypoints"
            error("exclude_entrypoints is not allowed in overrides — scope via paths (at #{path})")
            next
          end
          if overrides && name == "ComplexityRatchet" && !%w[enabled severity].include?(key)
            if key == "budgets"
              error("budgets are global; scope via budgets[].paths (at #{path})")
            else
              error("ComplexityRatchet overrides may set enabled/severity only (found '#{key}' at #{path})")
            end
            next
          end
          if key == "exclude_entrypoints" && !spec[:params].key?("exclude_entrypoints")
            error(format(EXCLUDE_ENTRYPOINTS_SCOPE_ERROR, name))
            next
          end
          next if known.include?(key)

          unknown_key(key, known, path)
        end

        check_common_keys(settings, path)
        return if overrides && name == "ComplexityRatchet" # enabled/severity only

        spec[:params].each do |param, meta|
          next unless settings.key?(param)
          next if overrides && %w[exclude_entrypoints].include?(param) # already rejected

          check_param(settings[param], param, meta, "#{path}.#{param}")
        end
      end

      def check_common_keys(settings, path)
        if settings.key?("enabled") && ![true, false].include?(settings["enabled"])
          error("#{path}.enabled must be true or false")
        end
        if settings.key?("severity") && !%w[info warn error].include?(settings["severity"])
          error("#{path}.severity must be one of info|warn|error")
        end
        check_string_array(settings["exclude"], "#{path}.exclude") if settings.key?("exclude")
      end

      def check_param(value, param, meta, path)
        case meta[:type]
        when :number
          check_numeric(value, meta, path, integer: false)
        when :integer
          check_numeric(value, meta, path, integer: true)
        when :array_of_strings
          check_string_array(value, path)
        when :budgets
          check_budgets(value, path)
        end
      end

      def check_numeric(value, meta, path, integer:)
        if value.nil?
          error("#{path} must not be null") unless meta[:nullable]
          return
        end

        noun = integer ? "an integer" : "a number"
        ok_type = integer ? value.is_a?(Integer) : (value.is_a?(Numeric) && value != true && value != false)
        bound = meta[:min]
        if !ok_type || (bound && value < bound)
          suffix = bound ? " >= #{bound}" : ""
          error("#{path} must be #{noun}#{suffix}#{meta[:nullable] ? ' or null' : ''}")
        end
      end

      def check_string_array(value, path)
        return if value.nil?
        return if value.is_a?(Array) && value.all? { |v| v.is_a?(String) }

        error("#{path} must be an array of strings")
      end

      # budgets[]: `paths:` XOR `entrypoints:` (G8) + max_increase_log2
      # (may be negative, L6) + optional severity.
      def check_budgets(value, path)
        return error("#{path} must be an array") unless value.is_a?(Array)

        value.each_with_index do |budget, i|
          bpath = "#{path}[#{i}]"
          unless budget.is_a?(Hash)
            error("#{bpath} must be a mapping")
            next
          end

          has_paths = budget.key?("paths")
          has_eps = budget.key?("entrypoints")
          if has_paths == has_eps # both or neither
            error("#{bpath} needs exactly one of paths: XOR entrypoints:")
          end
          check_scope_list(budget["paths"], "#{bpath}.paths") if has_paths
          check_scope_list(budget["entrypoints"], "#{bpath}.entrypoints") if has_eps

          unless budget["max_increase_log2"].is_a?(Numeric)
            error("#{bpath}.max_increase_log2 is required and must be a number (may be negative)")
          end
          if budget.key?("severity") && !%w[info warn error].include?(budget["severity"])
            error("#{bpath}.severity must be one of info|warn|error")
          end
          check_unknown_keys(budget.keys, %w[paths entrypoints max_increase_log2 severity], bpath)
        end
      end

      def check_scope_list(value, path)
        return if value.is_a?(Array) && !value.empty? && value.all? { |v| v.is_a?(String) }

        error("#{path} must be a non-empty array of strings")
      end

      # ---- overrides ---------------------------------------------------------

      def check_overrides
        overrides = @doc["overrides"]
        return if overrides.nil?
        return error("overrides must be an array") unless overrides.is_a?(Array)

        overrides.each_with_index do |entry, i|
          path = "overrides[#{i}]"
          unless entry.is_a?(Hash)
            error("#{path} must be a mapping")
            next
          end
          check_unknown_keys(entry.keys, %w[paths rules], path)
          check_scope_list(entry["paths"], "#{path}.paths")
          check_rules_block(entry["rules"], "#{path}.rules", overrides: true)
        end
      end

      # ---- calibration (the C12 full table — P3-T1's resolution rules) ------

      def check_calibration
        block = @doc["calibration"]
        return if block.nil?
        return error("calibration must be a mapping") unless block.is_a?(Hash)

        value_keys = Schema::CALIBRATION_KEYS - %w[source provenance]
        block.each_key do |key|
          next if Schema::CALIBRATION_KEYS.include?(key)

          unknown_key(key, value_keys, "calibration")
        end

        source = block.fetch("source", "builtin-study-v1")
        unless %w[builtin-study-v1 local none].include?(source)
          error("calibration.source must be one of builtin-study-v1|local|none")
          return
        end

        given = block.keys & (Schema::CALIBRATION_KEYS - ["source"])
        case source
        when "builtin-study-v1"
          unless given.empty?
            error("calibration value overrides require `source: local` with a `provenance` string " \
                  "(found: #{given.sort.join(', ')})")
          end
        when "local"
          unless block["provenance"].is_a?(String) && !block["provenance"].empty?
            error("calibration.provenance is required when source: local")
          end
        when "none"
          unless given.empty?
            error("calibration source 'none' allows no other keys (found: #{given.sort.join(', ')})")
          end
        end

        check_calibration_values(block)
      end

      def check_calibration_values(block)
        %w[latency_multiplier_per_log2_unit cost_per_line_ratio_q4_vs_q1
           bugfix_rate_ratio_q4_vs_q1].each do |key|
          next unless block.key?(key)

          error("calibration.#{key} must be a number") unless block[key].is_a?(Numeric)
        end

        %w[latency_multiplier_ci95 latency_arm_medians_hours].each do |key|
          next unless block.key?(key)
          value = block[key]
          unless value.is_a?(Array) && value.size == 2 && value.all? { |v| v.is_a?(Numeric) }
            error("calibration.#{key} must be a 2-number array")
          end
        end

        if block.key?("t_quartile_cuts")
          cuts = block["t_quartile_cuts"]
          unless cuts.is_a?(Array) && cuts.size == 3 && cuts.all? { |v| v.is_a?(Numeric) } &&
                 cuts.each_cons(2).all? { |a, b| a < b }
            error("calibration.t_quartile_cuts must be 3 ascending numbers")
          end
        end
      end

      # ---- helpers -----------------------------------------------------------

      def check_unknown_keys(keys, known, path)
        (keys - known).each { |key| unknown_key(key, known, path) }
      end

      def unknown_key(key, known, path)
        candidate = spell_check(key, known)
        if candidate
          error("unknown key '#{key}' at #{path} — did you mean '#{candidate}'?")
        else
          error("unknown key '#{key}' at #{path}")
        end
      end

      def spell_check(word, dictionary)
        DidYouMean::SpellChecker.new(dictionary: dictionary).correct(word).first
      end
    end
  end
end
