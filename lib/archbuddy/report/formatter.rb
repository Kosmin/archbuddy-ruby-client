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
      # @param scores        [Array<Scores::DimensionScore>,nil] project dimension
      #                       scores (findings 1.1); nil for a 1.0 doc (back-compat)
      # @param connectivity  [Scores::Connectivity,nil] project-level connectivity
      #                       scalar (findings 1.3); nil when absent (back-compat)
      # @param multiplexer_proxies [Array<Scores::MultiplexerProxy>,nil] the v0.7
      #                       smell (findings 1.4), worst-first, VERBATIM; nil when
      #                       absent (pre-1.4 / no scores block), [] when scored
      #                       but no proxy / forward N/A (renders an explicit note)
      # @param entrypoints   [Scores::EntrypointCount,nil] the committed v0.10
      #                       `entrypoints` counter block (SERIALIZER v2); nil on a
      #                       v1 aggregate / legacy doc → no banner (back-compat)
      # @param egress        [Scores::Egress,nil] the committed v0.10 `egress`
      #                       counter block; nil when absent → no banner
      # @param dynamic_dispatch [Scores::DynamicDispatch,nil] the committed v0.10
      #                       `dynamic_dispatch` coverage block; nil when absent
      RenderContext = Struct.new(
        :ranked, :class_rollups, :generator, :graph, :resolver, :scores, :connectivity,
        :max_nodes, :multiplexer_proxies,
        :entrypoints, :egress, :dynamic_dispatch,
        keyword_init: true
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
require_relative "formatters/html_formatter"
