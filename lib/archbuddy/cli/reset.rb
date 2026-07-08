# frozen_string_literal: true

require "dry/cli"
require "architecture_auditor"
require_relative "../collect"
require_relative "../cache"
require_relative "collect"
require_relative "analyze"

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
        # W1: `path` is the TARGET repo root. Both the collect output (graph.yml +
        # id-map.yml + detail tree) and the analyze transcode (committed aggregate)
        # go under the TARGET's `.archbuddy/`, not Dir.pwd — so `reset <target>`
        # from any CWD writes the committed cache into the target repo.
        target_root = File.expand_path(path)
        target_ws   = File.join(target_root, Archbuddy::Collect::DEFAULT_WORKSPACE_DIR)

        # 1. FULL collect (never incremental) — writes graph.yml + id-map.yml +
        #    the committed structural detail tree (findings not yet available)
        #    into the TARGET workspace.
        Archbuddy::CLI::Collect.new.call(
          path: path, language: language, entrypoints: entrypoints,
          entrypoint_pattern: entrypoint_pattern, probes: probes, changed: false,
          out_dir: target_ws
        )

        # 2+3. Analyze (engine score graph.yml -> findings.yml) + DE-ANON-AT-WRITE
        #      transcode into the committed root aggregate UNDER THE TARGET.
        #      Delegated to the `analyze` command so there is ONE implementation
        #      of the score+transcode step (reset = full collect + analyze).
        Archbuddy::CLI::Analyze.new.call(path: target_root)

        warn "reset complete: full re-collect + analyze; committed cache refreshed"
      end
    end
  end
end
