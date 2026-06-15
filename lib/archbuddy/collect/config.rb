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

      attr_reader :language, :ignore, :entrypoint_strategy, :entrypoint_patterns

      def initialize(
        language: "ruby",
        ignore: DEFAULT_IGNORE,
        entrypoint_strategy: :default,
        entrypoint_patterns: []
      )
        @language            = language
        @ignore              = Array(ignore)
        @entrypoint_strategy = normalize_strategy(entrypoint_strategy)
        @entrypoint_patterns = Array(entrypoint_patterns).map { |p| p.is_a?(Regexp) ? p : Regexp.new(p.to_s) }
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
    end
  end
end
