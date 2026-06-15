# frozen_string_literal: true

module Archbuddy
  module Report
    # R-6: the Formatter strategy base + an open/closed FORMATS registry. Adding
    # a new output format means adding a Formatter subclass and registering it —
    # it NEVER requires editing the Reconnect join engine or the Ranker.
    #
    # A Formatter receives the already-de-anonymized, already-ranked data (a
    # RenderContext) and turns it into a string. It makes ZERO analytic
    # decisions and NEVER recomputes metrics (D17) — it is pure presentation.
    class Formatter
      # Everything a formatter needs, pre-computed by the CLI/report pipeline.
      #
      # @param ranked        [Array<Model::Bottleneck>] nodes, clutter desc
      # @param class_rollups [Array<Model::Bottleneck>] rollups (D9), clutter desc
      # @param generator     [Hash] findings.yml generator metadata
      # @param graph         [Hash,nil] optional graph.yml (DOT edge list only)
      # @param resolver      [#resolve,nil] id → Model::Location (DOT label de-anon)
      RenderContext = Struct.new(
        :ranked, :class_rollups, :generator, :graph, :resolver, keyword_init: true
      )

      # name => Formatter subclass. Open for extension (register), closed for
      # modification (the pipeline never branches on format).
      FORMATS = {}

      class << self
        # Register a Formatter subclass under a CLI `--format` name.
        def register(name, klass)
          FORMATS[name.to_s] = klass
        end

        # Look up a registered formatter class. Raises a clear error otherwise.
        def for(name)
          FORMATS.fetch(name.to_s) do
            raise ArgumentError,
                  "unknown format #{name.inspect}; available: #{FORMATS.keys.sort.join(', ')}"
          end
        end

        def registered
          FORMATS.keys.sort
        end
      end

      # @param context [RenderContext]
      def initialize(context)
        @context = context
      end

      # @return [String] the rendered report. Subclasses MUST override.
      def render
        raise NotImplementedError, "#{self.class} must implement #render"
      end

      protected

      attr_reader :context

      def metric_keys
        Archbuddy::Report::METRIC_KEYS_FOR_DISPLAY
      end
    end
  end
end

# Eager-require the built-in formatters so registration happens on load. Each
# file calls Formatter.register(...) at the bottom.
require_relative "formatters/terminal_formatter"
require_relative "formatters/yaml_formatter"
require_relative "formatters/json_formatter"
require_relative "formatters/dot_formatter"
