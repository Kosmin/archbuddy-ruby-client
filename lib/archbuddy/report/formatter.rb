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
      # @param blast_radius  [Scores::BlastRadius,nil] the v0.11 (serializer v3 /
      #                       findings 1.6) blast-radius block; nil when absent
      # @param forward_depth [Scores::DepthStats,nil] v0.11 forward-depth stats
      #                       (flat spelling, guard R1); nil when absent
      # @param reverse_depth [Scores::DepthStats,nil] v0.11 reverse-depth stats;
      #                       nil when absent
      # @param branching_factor [Scores::BranchingFactor,nil] v0.11 ungraded
      #                       per-hop branching density (median-first); nil when
      #                       absent — all four feed the Business Impact section
      # @param variety_mass  [Scores::VarietyMass,nil] the v0.12 (serializer v4 /
      #                       findings 1.7) UNGRADED Variety+Mass composite;
      #                       nil when absent → no Q1 detail line (back-compat)
      # @param reusability   [Scores::Reusability,nil] the v0.13 (serializer v5 /
      #                       findings 1.8) UNGRADED Reusability Compass summary
      #                       (ADVISORY worst-lists); nil when absent → no Reuse
      #                       line and no compass section (back-compat)
      RenderContext = Struct.new(
        :ranked, :class_rollups, :generator, :graph, :resolver, :scores, :connectivity,
        :max_nodes, :multiplexer_proxies,
        :entrypoints, :egress, :dynamic_dispatch,
        :blast_radius, :forward_depth, :reverse_depth, :branching_factor,
        :variety_mass, :reusability,
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
