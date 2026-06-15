# frozen_string_literal: true

require_relative "../formatter"

module Archbuddy
  module Report
    module Formatters
      # Optional, NON-CONTRACT graph visualization. DOT needs the EDGE LIST,
      # which lives in graph.yml — NOT in findings.yml. It is therefore only
      # available when the user passes `--graph graph.yml`; without it, DOT is
      # unavailable and we say so clearly (rather than emitting an empty graph).
      #
      # Node labels are de-anonymized via the same id-map resolver, so the .dot
      # output contains real symbols and is SECRET/local-only.
      class DotFormatter < Formatter
        # Raised by the CLI pipeline path; render returns the message inline too.
        class GraphRequiredError < StandardError; end

        UNAVAILABLE_MESSAGE =
          "DOT output requires the graph edge list. Re-run with " \
          "`--graph path/to/graph.yml` (the edge list is in graph.yml, not findings.yml)."

        def render
          return UNAVAILABLE_MESSAGE if context.graph.nil?

          lines = ["digraph archbuddy {", "  rankdir=LR;", "  node [shape=box];"]
          lines.concat(node_lines)
          lines.concat(edge_lines)
          lines << "}"
          "#{lines.join("\n")}\n"
        end

        private

        def edges
          context.graph["edges"] || []
        end

        def graph_nodes
          context.graph["nodes"] || []
        end

        def node_lines
          graph_nodes.map do |node|
            id = node["id"]
            %(  "#{id}" [label="#{escape(label_for(id))}"];)
          end
        end

        def edge_lines
          edges.map do |edge|
            %(  "#{edge['from']}" -> "#{edge['to']}";)
          end
        end

        # De-anonymize an opaque id to its real symbol; graceful placeholder for
        # ids missing from the id-map (e.g. ext_ sinks). Never raises.
        def label_for(id)
          return id if context.resolver.nil?

          context.resolver.resolve(id).symbol
        end

        def escape(text)
          text.to_s.gsub('\\', '\\\\\\\\').gsub('"', '\\"')
        end
      end
    end
  end
end

Archbuddy::Report::Formatter.register(
  "dot", Archbuddy::Report::Formatters::DotFormatter
)
