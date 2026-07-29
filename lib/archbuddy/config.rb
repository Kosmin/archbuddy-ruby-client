# frozen_string_literal: true

require "yaml"
require_relative "version"
require_relative "config/schema"
require_relative "config/path_matcher"
require_relative "config/validator"

module Archbuddy
  # `.archbuddy.yml` schema v1 (v0.16 — the eight rules: Q11 +
  # ReusabilityScore): loader,
  # precedence (CLI > file > defaults, L4/L3), and per-file effective rule
  # resolution (last-match-wins overrides).
  #
  # File presence toggles GATING only: the rule set + default severities are
  # IDENTICAL with and without a config file (L3 advisory default).
  class Config
    # message = ALL errors, one per line.
    class ValidationError < StandardError; end

    FILENAME = ".archbuddy.yml"
    DEFAULT_TODO_FILENAME = ".archbuddy_todo.yml"

    # The effective per-(rule, file) view after overrides resolution.
    class RuleConfig
      def initialize(name, settings)
        @name = name
        @settings = settings.freeze
      end

      attr_reader :name

      def enabled
        @settings.fetch("enabled")
      end
      alias enabled? enabled

      def severity
        @settings.fetch("severity").to_sym
      end

      def exclude
        @settings.fetch("exclude", [])
      end

      def exclude_entrypoints
        @settings.fetch("exclude_entrypoints", [])
      end

      def [](key)
        @settings[key.to_s]
      end

      def to_h
        @settings.dup
      end

      def method_missing(name, *args)
        key = name.to_s
        return @settings[key] if args.empty? && @settings.key?(key)

        super
      end

      def respond_to_missing?(name, include_private = false)
        @settings.key?(name.to_s) || super
      end
    end

    class << self
      # @param target_root [String]
      # @param config_path [String, nil] explicit --config PATH (missing = error)
      # @param cli [Hash] fail_level:, advisory:, format:, todo_path:, no_todo:
      # @raise [ValidationError]
      def load(target_root:, config_path: nil, cli: {})
        target_root = File.expand_path(target_root)
        doc, present = read_document(target_root, config_path)

        errors = doc.nil? ? [] : Validator.new(doc).validate
        errors.concat(todo_file_errors(target_root, doc, cli))
        raise ValidationError, errors.join("\n") unless errors.empty?

        new(target_root: target_root, doc: doc || {}, present: present, cli: cli)
      end

      private

      def read_document(target_root, config_path)
        path =
          if config_path
            expanded = File.expand_path(config_path)
            unless File.file?(expanded)
              raise ValidationError, "config file '#{config_path}' (--config) not found"
            end
            expanded
          else
            default = File.join(target_root, FILENAME)
            File.file?(default) ? default : nil
          end
        return [nil, false] if path.nil?

        raw = begin
          YAML.safe_load(File.read(path), permitted_classes: [], aliases: false)
        rescue Psych::Exception => e
          raise ValidationError, "config YAML parse error at #{path}: #{e.message}"
        end
        [raw.nil? ? {} : raw, true]
      end

      # F9 hardening + explicit --todo existence (the explicit ask must not
      # silently no-op).
      def todo_file_errors(target_root, doc, cli)
        errors = []
        if doc.is_a?(Hash) && doc["todo_file"].is_a?(String)
          path = File.expand_path(doc["todo_file"], target_root)
          unless File.file?(path)
            errors << "todo file '#{doc['todo_file']}' (config todo_file) not found — " \
                      "remove the key, fix the path, or generate it with --auto-gen-todo"
          end
        end
        if cli[:todo_path] && !File.file?(File.expand_path(cli[:todo_path], target_root))
          errors << "todo file '#{cli[:todo_path]}' (--todo) not found"
        end
        errors
      end
    end

    def initialize(target_root:, doc:, present:, cli:)
      @target_root = target_root
      @doc = doc
      @present = present
      @cli = cli
      @rule_memo = {}
    end

    attr_reader :target_root

    def config_file_present?
      @present
    end

    # CLI --fail-level ‖ (--advisory → :none) ‖ file all.fail_level (default
    # error) when a file is present ‖ :none (L3 advisory).
    def effective_fail_level
      return @cli[:fail_level].to_sym if @cli[:fail_level]
      return :none if @cli[:advisory]
      return :none unless @present

      (all_block["fail_level"] || "error").to_sym
    end

    def gating?
      effective_fail_level != :none
    end

    def format
      (@cli[:format] || all_block["format"] || "terminal").to_s
    end

    # nil = no todo (normal day-one state / --no-todo / todo_file: null).
    def todo_path
      return nil if @cli[:no_todo]
      return File.expand_path(@cli[:todo_path], @target_root) if @cli[:todo_path]

      if @doc.key?("todo_file")
        value = @doc["todo_file"]
        return value.nil? ? nil : File.expand_path(value, @target_root)
      end

      default = File.join(@target_root, DEFAULT_TODO_FILENAME)
      File.file?(default) ? default : nil
    end

    # The validated raw `calibration:` block (R15) — consumed by
    # Calibration.resolve; presenters only.
    def calibration
      @doc["calibration"]
    end

    # v1 stub: schema v1 carries no collect keys; the seam exists for
    # Review::Collector (C11).
    def collect_options
      {}
    end

    def all_excludes
      all_block["exclude"] || []
    end

    def all_includes
      all_block["include"] || []
    end

    # Global ratchet budgets (never per-override — G8).
    def budgets
      @doc.dig("rules", "ComplexityRatchet", "budgets") || []
    end

    # Effective settings for (rule, file) after last-match-wins overrides;
    # memoized. USE_CASE rules resolve by the EP's DEFINING file.
    def rule_for(name, file:)
      @rule_memo[[name, file]] ||= begin
        settings = default_settings(name)
        settings = shallow_merge(settings, @doc.dig("rules", name))
        (@doc["overrides"] || []).each do |override|
          next unless file && PathMatcher.match?(override["paths"] || [], file)

          settings = shallow_merge(settings, override.dig("rules", name))
        end
        RuleConfig.new(name, settings)
      end
    end

    # Rule names enabled at the global (file-independent) level, filtered by
    # mode dispatch: lint = :node + :use_case kinds + ComplexityRatchet
    # (context entries, [S:C14]); diff = all kinds.
    def enabled_rules(mode: :lint)
      Schema::RULES.keys.sort.select do |name|
        next false unless rule_for(name, file: nil).enabled

        kind = Schema::RULES[name][:kind]
        case mode
        when :diff then true
        else
          %i[node use_case].include?(kind) || name == "ComplexityRatchet"
        end
      end
    end

    private

    def all_block
      @doc["all"] || {}
    end

    def default_settings(name)
      spec = Schema::RULES.fetch(name) do
        raise ArgumentError, "unknown rule '#{name}' (schema v1 registry)"
      end
      base = {
        "enabled" => spec[:default_enabled],
        "severity" => spec[:default_severity].to_s,
        "exclude" => []
      }
      spec[:params].each { |param, meta| base[param] = meta[:default] }
      base
    end

    # Shallow param replace — lists REPLACE, never merge (R2 Q3c rule b).
    def shallow_merge(base, layer)
      return base if layer.nil?

      base.merge(layer)
    end
  end
end
