# frozen_string_literal: true

require "dry/cli"
require "architecture_auditor"
require_relative "../collect"
require_relative "../cache"
require_relative "collect"

module Archbuddy
  module CLI
    # `archbuddy reset PATH` (L3): the FULL reset / overhaul mode. Re-collects
    # the ENTIRE cache from scratch (ignoring the incremental speed cache) and
    # runs a full analyze, then re-transcodes the committed root aggregate WITH
    # the fresh scores + multiplexer_proxy smell folded in. Use on first run or
    # when the scoring model changes.
    #
    # This is the deterministic, from-scratch counterpart to `collect --changed`:
    #   1. FULL collect (mode :full — never trusts the .cache/) → graph.yml +
    #      id-map.yml + the committed structural detail tree.
    #   2. engine analyze (graph.yml → findings.yml, opaque).
    #   3. re-transcode: fold the de-anonymized scores + multiplexer_proxy list
    #      into the committed root archbuddy-findings.json (DE-ANON-AT-WRITE).
    class Reset < Dry::CLI::Command
      desc "Full reset: re-collect the whole cache from scratch + analyze (first run / model change)"

      argument :path, required: true, desc: "Path to the codebase (dir or .rb file)"

      option :language, default: "ruby", desc: "Adapter language"
      option :entrypoints, default: "default",
                           desc: "Entrypoint strategy: default|controllers|all_public|none"
      option :entrypoint_pattern, type: :array, default: [],
                                  desc: "Additional entrypoint fq-symbol regex(es)"
      option :probes, default: "all", desc: "Framework probe selection: all|none|comma,list"

      def call(path:, language: "ruby", entrypoints: "default", entrypoint_pattern: [], probes: "all", **)
        workspace = Archbuddy::Collect::DEFAULT_WORKSPACE_DIR
        graph_yml = File.join(workspace, "graph.yml")
        id_map_yml = File.join(workspace, "id-map.yml")
        findings_yml = File.join(workspace, "findings.yml")

        # 1. FULL collect (never incremental) — writes graph.yml + id-map.yml +
        #    the committed structural detail tree (findings not yet available).
        Archbuddy::CLI::Collect.new.call(
          path: path, language: language, entrypoints: entrypoints,
          entrypoint_pattern: entrypoint_pattern, probes: probes, changed: false
        )

        # 2. Full analyze (engine): graph.yml -> findings.yml (opaque). Shell out
        #    to the engine binary — the engine loads its own analyze pipeline via
        #    its entrypoint (its require graph is not laid out for a partial
        #    in-process require), and this mirrors the documented user flow.
        run_engine_analyze(graph_yml, findings_yml)

        # 3. Re-transcode the committed root aggregate WITH the fresh findings so
        #    scores + the multiplexer_proxy smell (de-anonymized) are folded in.
        rewrite_aggregate(graph_yml, id_map_yml, findings_yml)

        warn "reset complete: full re-collect + analyze; committed cache refreshed"
      end

      private

      # Invoke the engine `analyze` the way a user does. Prefer the bundled
      # binstub; fall back to a plain `architecture-auditor` on PATH. Raises a
      # clear error (never a silent partial reset) if analyze fails.
      def run_engine_analyze(graph_yml, findings_yml)
        ok = system("bundle", "exec", "architecture-auditor", "analyze", graph_yml, "--out", findings_yml)
        ok ||= system("architecture-auditor", "analyze", graph_yml, "--out", findings_yml)
        return if ok

        warn "error: engine `architecture-auditor analyze` failed — cannot complete reset"
        exit 1
      end

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
