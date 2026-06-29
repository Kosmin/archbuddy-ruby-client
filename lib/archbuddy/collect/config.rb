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

      attr_reader :language, :ignore, :entrypoint_strategy, :entrypoint_patterns, :probes

      def initialize(
        language: "ruby",
        ignore: DEFAULT_IGNORE,
        entrypoint_strategy: :default,
        entrypoint_patterns: [],
        probes: :all
      )
        @language            = language
        @ignore              = Array(ignore)
        @entrypoint_strategy = normalize_strategy(entrypoint_strategy)
        @entrypoint_patterns = Array(entrypoint_patterns).map { |p| p.is_a?(Regexp) ? p : Regexp.new(p.to_s) }
        @probes              = normalize_probes(probes)
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
    end
  end
end
