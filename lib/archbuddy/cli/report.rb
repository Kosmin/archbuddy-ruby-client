# frozen_string_literal: true

require "dry/cli"
require_relative "../collect"
require_relative "../cache/layout"
require_relative "../report"
require_relative "../report/reconnect"
require_relative "../report/ranker"
require_relative "../report/formatter"

module Archbuddy
  module CLI
    # `archbuddy report [FINDINGS_YML] [--id-map ./.archbuddy/id-map.yml]
    #     [--format terminal|yaml|json|dot|html] [--graph graph.yml] [--top N]`
    #
    # TWO read paths (R2-1):
    #
    #   * DEFAULT — the COMMITTED, REAL-NAME root aggregate
    #     `archbuddy-findings.json`. Read DIRECTLY with NO id-map (the committed
    #     layer is de-anonymized at write time, CR-1). A fresh clone runs
    #     `archbuddy report` with no args, no secret, and sees the scores + the
    #     multiplexer_proxy smell. This is the produce-via-`archbuddy analyze`
    #     flow.
    #   * LEGACY — an explicit opaque `findings.yml` (or the default
    #     `.archbuddy/findings.yml`) joined against the SECRET id-map at read
    #     time (`Reconnect.from_files`). Used when there is no committed aggregate
    #     yet, or when an explicit findings path is passed.
    #
    # Non-terminal exports (yaml/json/dot/html) carry real symbols; on the LEGACY
    # path they are SECRET/local-only (gitignored). The committed aggregate is
    # already committed real-name (an audited repo's own code), so a report
    # rendered from it carries nothing the committed cache doesn't already hold.
    class Report < Dry::CLI::Command
      desc "Render the architecture report (committed real-name cache by default; legacy findings.yml + id-map on request)"

      # The COMMITTED real-name root aggregate (repo-relative), the DEFAULT source.
      ROOT_AGGREGATE = Archbuddy::Cache::Layout::ROOT_AGGREGATE

      # FINDINGS_YML, --id-map and --graph all default into the shared
      # `.archbuddy/` workspace so the LEGACY path works with NO args right
      # after `collect` + engine `analyze`. Explicit args/flags override.
      WORKSPACE = Archbuddy::Collect::DEFAULT_WORKSPACE_DIR

      argument :findings, required: false,
                          desc: "Path to opaque findings.yml (LEGACY path; default committed source: #{ROOT_AGGREGATE})"

      option :id_map, desc: "Path to the SECRET id-map.yml (LEGACY path only; default: #{WORKSPACE}/id-map.yml)"
      option :format, default: "terminal",
                      desc: "Output format: terminal|yaml|json|dot|html"
      option :graph, desc: "Path to graph.yml (edge list; default: #{WORKSPACE}/graph.yml; required for --format dot, used by --format html)"
      option :top, type: :integer, desc: "Show only the top N bottlenecks"
      option :max_nodes, type: :integer, default: 30,
                         desc: "HTML report: show only the top N offenders by clutter score in BOTH the graph and the list (0 = all; default: 30). The list paginates the top N."

      def call(format:, findings: nil, id_map: nil, graph: nil, top: nil, max_nodes: 30, **)
        graph ||= default_graph_path

        formatter_class =
          begin
            Archbuddy::Report::Formatter.for(format)
          rescue ArgumentError => e
            warn "error: #{e.message}"
            exit 1
          end

        result = load_result(findings, id_map)

        ranker = Archbuddy::Report::Ranker.new(result)
        top_n  = top&.to_i

        # v0.9 W2: the DEFAULT from_cache path already carries a reassembled
        # REAL-NAME graph (nodes/edges are real symbols) + an IDENTITY resolver —
        # so the default report renders real names in the graph WITHOUT an id-map.
        # The LEGACY opaque path keeps loading graph.yml + the IdMapResolver.
        if result.real_name?
          render_graph = result.graph
          resolver     = Archbuddy::Report::Reconnect::IdentityResolver.new
        else
          render_graph = graph && Archbuddy::Report::Reconnect::Serializer.load(graph)
          resolver     = Archbuddy::Report::Reconnect::IdMapResolver.new(result.id_map)
        end

        context = Archbuddy::Report::Formatter::RenderContext.new(
          ranked:        ranker.ranked(top: top_n),
          class_rollups: ranker.class_rollups(top: top_n),
          generator:     result.findings_doc["generator"] || {},
          graph:         render_graph,
          resolver:      resolver,
          scores:        result.scores,
          connectivity:  result.connectivity,
          multiplexer_proxies: result.multiplexer_proxies,
          max_nodes:     max_nodes&.to_i,
          # v0.10 (W4): the three committed counter blocks (SERIALIZER v2),
          # parsed nil-tolerantly by Reconnect — nil on a v1 aggregate / legacy
          # doc, so the formatters render no banner (back-compat).
          entrypoints:      result.entrypoints,
          egress:           result.egress,
          dynamic_dispatch: result.dynamic_dispatch
        )

        puts formatter_class.new(context).render
      end

      private

      # Choose the read path (R2-1). With NO explicit findings arg, PREFER the
      # committed real-name root aggregate (read directly, NO id-map). Fall back
      # to the LEGACY opaque findings.yml + SECRET id-map only when there is no
      # committed aggregate (or when an explicit findings path is given).
      def load_result(findings, id_map)
        if findings.nil? && File.exist?(ROOT_AGGREGATE)
          # DEFAULT: committed real-name cache. NO id-map is read here — the
          # committed layer is already de-anonymized (CR-1). A fresh clone works.
          Archbuddy::Report::Reconnect.from_cache(aggregate_path: ROOT_AGGREGATE, id_map_path: nil)
        else
          load_legacy_result(findings, id_map)
        end
      end

      # LEGACY: opaque findings.yml joined against the SECRET id-map at read time.
      def load_legacy_result(findings, id_map)
        findings ||= File.join(WORKSPACE, "findings.yml")
        id_map   ||= File.join(WORKSPACE, "id-map.yml")

        unless File.exist?(findings)
          warn "error: no committed cache (#{ROOT_AGGREGATE}) and no findings at #{findings} — " \
               "run `archbuddy analyze .` (committed cache) or `architecture-auditor analyze` first " \
               "(or pass an explicit path)."
          exit 1
        end
        missing_input!("id-map", id_map, "archbuddy collect .") unless File.exist?(id_map)

        Archbuddy::Report::Reconnect.from_files(findings_path: findings, id_map_path: id_map).call
      end

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
