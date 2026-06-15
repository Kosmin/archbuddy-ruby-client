# frozen_string_literal: true

require "dry/cli"
require_relative "../report"
require_relative "../report/reconnect"
require_relative "../report/ranker"
require_relative "../report/formatter"

module Archbuddy
  module CLI
    # `archbuddy report FINDINGS_YML --id-map ./out/id-map.yml
    #     [--format terminal|yaml|json|dot] [--graph graph.yml] [--top N]`
    #
    # The SECOND and only other command (besides `collect`) that reads the SECRET
    # id-map.yml. It joins the engine's opaque findings.yml back to real symbols
    # (Reconnect), ranks by verbatim clutter_score (Ranker — never recomputed,
    # D17), and renders via the requested Formatter strategy.
    #
    # All non-terminal exports (yaml/json/dot) carry real symbols and are
    # SECRET/local-only — gitignored; never commit, never send externally.
    class Report < Dry::CLI::Command
      desc "De-anonymize + rank the engine's findings.yml into a clutter report"

      argument :findings, required: true, desc: "Path to findings.yml (opaque, from `analyze`)"

      option :id_map, required: true, desc: "Path to the SECRET id-map.yml (from `collect`)"
      option :format, default: "terminal",
                      desc: "Output format: terminal|yaml|json|dot"
      option :graph, desc: "Path to graph.yml (required only for --format dot — supplies the edge list)"
      option :top, type: :integer, desc: "Show only the top N bottlenecks"

      def call(findings:, id_map:, format:, graph: nil, top: nil, **)
        formatter_class =
          begin
            Archbuddy::Report::Formatter.for(format)
          rescue ArgumentError => e
            warn "error: #{e.message}"
            exit 1
          end

        result = Archbuddy::Report::Reconnect.from_files(
          findings_path: findings, id_map_path: id_map
        ).call

        ranker = Archbuddy::Report::Ranker.new(result)
        top_n  = top&.to_i

        context = Archbuddy::Report::Formatter::RenderContext.new(
          ranked:        ranker.ranked(top: top_n),
          class_rollups: ranker.class_rollups(top: top_n),
          generator:     result.findings_doc["generator"] || {},
          graph:         graph && Archbuddy::Report::Reconnect::Serializer.load(graph),
          resolver:      Archbuddy::Report::Reconnect::IdMapResolver.new(result.id_map)
        )

        puts formatter_class.new(context).render
      end
    end
  end
end
