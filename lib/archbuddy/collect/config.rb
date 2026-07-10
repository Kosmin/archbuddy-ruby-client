# frozen_string_literal: true

module Archbuddy
  module Collect
    # Collector configuration: file ignore list, entrypoint strategy, and
    # optional vocab/sink overrides. Plain value object so the CLI, adapters,
    # and tests share one shape.
    class Config
      # Directories/segments ignored when enumerating .rb files.
      DEFAULT_IGNORE = %w[
        vendor node_modules tmp log coverage .git .bundle
        spec test db/migrate
      ].freeze

      # Entrypoint strategies (D4 / K-4).
      ENTRYPOINT_STRATEGIES = %i[default controllers all_public none].freeze

      attr_reader :language, :ignore, :entrypoint_strategy, :entrypoint_patterns, :probes, :root_types

      def initialize(
        language: "ruby",
        ignore: DEFAULT_IGNORE,
        entrypoint_strategy: :default,
        entrypoint_patterns: [],
        probes: :all,
        root_types: :all
      )
        @language            = language
        @ignore              = Array(ignore)
        @entrypoint_strategy = normalize_strategy(entrypoint_strategy)
        @entrypoint_patterns = Array(entrypoint_patterns).map { |p| p.is_a?(Regexp) ? p : Regexp.new(p.to_s) }
        @probes              = normalize_probes(probes)
        @root_types          = normalize_root_types(root_types)
      end

      private

      def normalize_strategy(strategy)
        sym = strategy.to_s.to_sym
        unless ENTRYPOINT_STRATEGIES.include?(sym)
          raise ArgumentError,
                "unknown entrypoint strategy #{strategy.inspect}; expected one of #{ENTRYPOINT_STRATEGIES.inspect}"
        end
        sym
      end

      # Probe selection (P1 / L4). INTENTIONALLY LENIENT — unlike
      # normalize_strategy, this NEVER raises on an unknown name (F2): probe
      # names are owned by probe waves the seam can't enumerate, so an unknown
      # name simply selects nothing (ProbeRegistry filters it out). Accepts:
      #   :all (sentinel — every registered probe; the default)
      #   :none / nil / [] -> [] (run no probes)
      #   Array/Symbol/String/comma-string -> Array<Symbol> selected by #name
      def normalize_probes(probes)
        return :all if probes == :all || probes.to_s == "all"
        return [] if probes.nil? || probes == :none || probes.to_s == "none"

        list =
          if probes.is_a?(String)
            probes.split(",")
          else
            Array(probes)
          end
        list.map { |p| p.to_s.strip.to_sym }.reject { |s| s.to_s.empty? }
      end

      # Root-seeder selection (v0.10 W1-B / --root-types). Same LENIENT
      # semantics as normalize_probes — NEVER raises on an unknown name:
      # root-type names are owned by seeder waves this seam can't enumerate,
      # so an unknown name simply selects nothing (RootSeederRegistry filters
      # it out). Accepts:
      #   :all (sentinel — every registered seeder; the default. NOTE: cron,
      #         when it lands in a later wave, will be excluded from :all's
      #         default-on set — LINK-only, opt-in)
      #   :none / nil / [] -> [] (seed no roots)
      #   Array/Symbol/String/comma-string -> Array<Symbol> selected by root_type
      def normalize_root_types(root_types)
        return :all if root_types == :all || root_types.to_s == "all"
        return [] if root_types.nil? || root_types == :none || root_types.to_s == "none"

        list =
          if root_types.is_a?(String)
            root_types.split(",")
          else
            Array(root_types)
          end
        list.map { |t| t.to_s.strip.to_sym }.reject { |s| s.to_s.empty? }
      end
    end
  end
end
