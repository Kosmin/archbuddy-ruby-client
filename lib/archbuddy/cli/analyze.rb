# frozen_string_literal: true

require "dry/cli"
require "architecture_auditor"
require_relative "../collect"
require_relative "../cache"

module Archbuddy
  module CLI
    # `archbuddy analyze [PATH]` (R2): the SCORE + de-anon-at-write step of the
    # committed-cache flow. It assumes `collect` has already assembled the opaque
    # interchange (`.archbuddy/graph.yml` + SECRET `.archbuddy/id-map.yml`) — the
    # per-file fragment assembly is `collect`'s job (incremental or full) — and:
    #
    #   1. runs the ENGINE `analyze` (graph.yml -> findings.yml, opaque);
    #   2. TRANSCODES at WRITE time (CR-1): de-anonymizes the opaque findings +
    #      SECRET id-map into the COMMITTED, REAL-NAME root `archbuddy-findings.json`
    #      (headline scores + the multiplexer_proxy smell) — folding the fresh
    #      scores into the committed aggregate that `report` reads directly.
    #
    # The engine stays YAML-native (graph.yml -> findings.yml); the client owns
    # the de-anon-at-write transcode (only the client holds the id-map). This is
    # the steady-state counterpart to `reset`: `reset` forces a full re-collect
    # first, then delegates the analyze+transcode here.
    #
    # PATH is accepted for symmetry with collect/reset but is NOT re-collected —
    # analyze scores whatever `collect` last produced. Pass nothing to score the
    # current `.archbuddy/graph.yml`.
    class Analyze < Dry::CLI::Command
      desc "Score the collected graph + write the committed real-name cache (engine analyze + de-anon-at-write)"

      argument :path, required: false, desc: "(unused — analyze scores the graph.yml collect produced)"

      def call(**)
        workspace    = Archbuddy::Collect::DEFAULT_WORKSPACE_DIR
        graph_yml    = File.join(workspace, "graph.yml")
        id_map_yml   = File.join(workspace, "id-map.yml")
        findings_yml = File.join(workspace, "findings.yml")

        unless File.exist?(graph_yml)
          warn "error: no #{graph_yml} — run `archbuddy collect .` (or `archbuddy reset .`) first."
          exit 1
        end

        run_engine_analyze(graph_yml, findings_yml)
        rewrite_aggregate(graph_yml, id_map_yml, findings_yml)

        warn "analyze complete: engine scored graph.yml -> findings.yml; committed cache refreshed"
      end

      # Invoke the engine `analyze` the way a user does. Prefer the bundled
      # binstub; fall back to a plain `architecture-auditor` on PATH. Raises a
      # clear error (never a silent partial write) if analyze fails.
      def run_engine_analyze(graph_yml, findings_yml)
        ok = system("bundle", "exec", "architecture-auditor", "analyze", graph_yml, "--out", findings_yml)
        ok ||= system("architecture-auditor", "analyze", graph_yml, "--out", findings_yml)
        return if ok

        warn "error: engine `architecture-auditor analyze` failed — cannot write the committed cache"
        exit 1
      end

      # DE-ANON-AT-WRITE (CR-1): fold the fresh de-anonymized scores +
      # multiplexer_proxy smell into the committed root aggregate. The SECRET
      # id-map is read HERE (client-side) and NEVER committed.
      def rewrite_aggregate(graph_yml, id_map_yml, findings_yml)
        return unless File.exist?(findings_yml)

        serializer = ArchitectureAuditor::Contract::Serializer
        Archbuddy::Cache::Writer.new(project_root: Dir.pwd).write(
          graph:    serializer.load(graph_yml),
          id_map:   serializer.load(id_map_yml),
          findings: serializer.load(findings_yml)
        )
      end
    end
  end
end
