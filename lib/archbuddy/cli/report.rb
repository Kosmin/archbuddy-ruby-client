# frozen_string_literal: true

require "dry/cli"
require_relative "../collect"
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

      # FINDINGS_YML, --id-map and --graph all default into the shared
      # `.archbuddy/` workspace so `archbuddy report` works with NO args right
      # after `collect` + `analyze`. Explicit args/flags override.
      WORKSPACE = Archbuddy::Collect::DEFAULT_WORKSPACE_DIR

      argument :findings, required: false,
                          desc: "Path to findings.yml (opaque, from `analyze`; default: #{WORKSPACE}/findings.yml)"

      option :id_map, desc: "Path to the SECRET id-map.yml (from `collect`; default: #{WORKSPACE}/id-map.yml)"
      option :format, default: "terminal",
                      desc: "Output format: terminal|yaml|json|dot|html"
      option :graph, desc: "Path to graph.yml (edge list; default: #{WORKSPACE}/graph.yml; required for --format dot, used by --format html)"
      option :top, type: :integer, desc: "Show only the top N bottlenecks"

      def call(format:, findings: nil, id_map: nil, graph: nil, top: nil, **)
        findings ||= File.join(WORKSPACE, "findings.yml")
        id_map   ||= File.join(WORKSPACE, "id-map.yml")
        # --graph defaults to the workspace graph.yml only when it actually
        # exists, so formats that don't need it (terminal/yaml/json) don't warn
        # about a missing default and html/dot degrade/explain as before.
        graph ||= default_graph_path

        missing_input!("findings", findings, "architecture-auditor analyze") unless File.exist?(findings)
        missing_input!("id-map", id_map, "archbuddy collect .") unless File.exist?(id_map)

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
          resolver:      Archbuddy::Report::Reconnect::IdMapResolver.new(result.id_map),
          scores:        result.scores,
          connectivity:  result.connectivity
        )

        puts formatter_class.new(context).render
      end

      private

      # Use the workspace graph.yml as the --graph default only if it's present
      # (so terminal/yaml/json don't emit a spurious missing-graph notice).
      def default_graph_path
        candidate = File.join(WORKSPACE, "graph.yml")
        File.exist?(candidate) ? candidate : nil
      end

      # A clear, friendly error (not a stack trace) when a default/expected
      # input file is missing — tells the user which command produces it.
      def missing_input!(label, path, producer)
        warn "error: no #{label} at #{path} — run `#{producer}` first " \
             "(or pass an explicit path)."
        exit 1
      end
    end
  end
end
