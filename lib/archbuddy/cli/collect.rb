# frozen_string_literal: true

require "dry/cli"
require "fileutils"
require_relative "../collect"

module Archbuddy
  module CLI
    # `archbuddy collect PATH --out-dir ./out [--entrypoints ...]`
    #
    # The SOLE producer of id-map.yml. Runs the language adapter (via the
    # Registry), anonymizes through the single trust boundary, and emits the
    # opaque graph.yml plus the secret id-map.yml.
    class Collect < Dry::CLI::Command
      desc "Statically capture a codebase into graph.yml + secret id-map.yml"

      argument :path, required: true, desc: "Path to the codebase (dir or .rb file)"

      # The shared `.archbuddy/` workspace convention (mirrored by the engine):
      # collect writes graph.yml + id-map.yml here so the flow needs no flags.
      option :out_dir, desc: "Output directory for graph.yml + id-map.yml (default: #{Archbuddy::Collect::DEFAULT_WORKSPACE_DIR}/)"
      option :language, default: "ruby", desc: "Adapter language"
      option :entrypoints, default: "default",
                           desc: "Entrypoint strategy: default|controllers|all_public|none"
      option :entrypoint_pattern, type: :array, default: [],
                                  desc: "Additional entrypoint fq-symbol regex(es)"
      option :probes, default: "all",
                      desc: "Framework probe selection: all|none|comma,list (e.g. grape,sidekiq_dispatch)"

      def call(path:, language:, entrypoints:, entrypoint_pattern:, probes: "all", out_dir: nil, **)
        # --out-dir is OPTIONAL: default to the shared `.archbuddy/` workspace so
        # `archbuddy collect .` works with no flags. When we fall back to the
        # default AND we're inside a git repo, auto-ensure `.archbuddy/` is
        # LOCALLY ignored (via .git/info/exclude — never the tracked .gitignore)
        # so the existing gitignore-before-secret guard in the Emitter passes
        # without the user thinking about it. For an EXPLICIT --out-dir we do NOT
        # touch any ignore file: the guard refuses if the path the USER chose is
        # not ignored (we never silently edit ignores for a user-chosen path).
        using_default_out_dir = out_dir.nil?
        out_dir ||= Archbuddy::Collect::DEFAULT_WORKSPACE_DIR

        ensure_default_workspace_excluded! if using_default_out_dir

        config = Archbuddy::Collect::Config.new(
          language:            language,
          entrypoint_strategy: entrypoints,
          entrypoint_patterns: entrypoint_pattern,
          probes:              probes
        )

        adapter        = Archbuddy::Collect::Registry.for(language).new(path, config)
        adapter_result =
          begin
            adapter.collect
          rescue Archbuddy::Collect::Adapters::Ruby::FileEnumerator::NoSourceError => e
            warn "error: #{e.message}"
            exit 1
          end

        anon = Archbuddy::Collect::Anonymizer.new(
          adapter_result,
          tool: "archbuddy #{Archbuddy::VERSION}",
          adapter: language
        ).call

        paths = Archbuddy::Collect::Emitter.new(out_dir: out_dir).emit(
          graph: anon.graph, id_map: anon.id_map
        )

        skipped = adapter_result.diagnostics[:meta_sites_skipped].to_i
        if skipped.positive?
          warn "note: #{skipped} metaprogramming call site#{'s' if skipped != 1} skipped (no edges)"
        end

        # Framework-probe provenance (W3 / L5 / P4). The per-probe-name tally
        # rides the diagnostics channel ONLY (never graph.yml). Mirror the
        # meta-sites note: print only when at least one probe resolved an edge.
        probe_edges = adapter_result.diagnostics[:probe_edges] || {}
        probe_total = probe_edges.values.sum
        if probe_total.positive?
          breakdown = probe_edges.map { |probe, count| "#{probe}=#{count}" }.join(" ")
          warn "note: #{probe_total} edge#{'s' if probe_total != 1} recovered by framework probes (#{breakdown})"
        end

        # M3: a run that finds NO entrypoints leaves the engine unable to
        # compute reachability (dead, path_length). Surface that as a clear
        # stderr WARNING — a diagnostic, never graph content — instead of
        # silently emitting `entrypoints: []`. We do NOT auto-switch the
        # strategy; we just tell the user how to get a useful surface.
        if adapter_result.entrypoints.empty?
          warn "warning: no entrypoints detected with strategy '#{entrypoints}'. " \
               "Reachability metrics (dead, path_length) will be unavailable. " \
               "For a non-Rails library, re-run with --entrypoints all_public."
        end

        warn "wrote #{paths[:graph]}"
        warn "wrote #{paths[:id_map]} (SECRET — gitignored, never share)"
      end

      private

      # v0.8 (C1-3): the SECRET sub-paths that must NEVER be committed in an
      # AUDITED repo. The committed layout (archbuddy-findings.json + the
      # `.archbuddy/<mirrored-source>` detail tree) is intentionally LEFT
      # STAGEABLE so a PR shows its score-delta (L1/L5). We therefore narrow the
      # local exclude from the whole `.archbuddy/` dir to ONLY:
      #   - `.archbuddy/id-map.yml`  — the SECRET real↔opaque map
      #   - `.archbuddy/.cache/`     — the machine-local speed cache (re-derivable)
      #   - the opaque interchange graph.yml/findings.yml (never committed)
      #   - de-anonymized report.* exports (real symbols — secret/local-only)
      SECRET_EXCLUDE_PATHS = [
        "#{Archbuddy::Collect::DEFAULT_WORKSPACE_DIR}/id-map.yml",
        "#{Archbuddy::Collect::DEFAULT_WORKSPACE_DIR}/.cache/",
        "#{Archbuddy::Collect::DEFAULT_WORKSPACE_DIR}/graph.yml",
        "#{Archbuddy::Collect::DEFAULT_WORKSPACE_DIR}/findings.yml",
        "#{Archbuddy::Collect::DEFAULT_WORKSPACE_DIR}/report.*"
      ].freeze

      # When the DEFAULT `.archbuddy/` workspace is used inside a git repo, ensure
      # the SECRET sub-paths are locally ignored so the id-map can be written
      # safely — WITHOUT ignoring the committable real-name cache. We append the
      # narrow SECRET paths to `.git/info/exclude` (a LOCAL ignore that does NOT
      # modify the user's tracked `.gitignore`). Idempotent per line, and each
      # line is skipped if already ignored by any means (e.g. the user's own
      # `.gitignore` already ignores the whole dir — a dogfood repo). Outside a
      # git repo we do nothing (no commit risk; the Emitter's filename fallback
      # still covers the secret).
      def ensure_default_workspace_excluded!
        return unless git_repo?

        exclude_file = File.join(git_dir, "info", "exclude")
        FileUtils.mkdir_p(File.dirname(exclude_file))

        SECRET_EXCLUDE_PATHS.each do |line|
          append_exclude_line(exclude_file, line)
        end
      end

      # Append one exclude line idempotently; skip if the target is already
      # ignored (by the tracked .gitignore, a prior run, etc.).
      def append_exclude_line(exclude_file, line)
        return if path_ignored?(line.chomp("/").chomp("*").chomp("."))

        existing = File.exist?(exclude_file) ? File.read(exclude_file) : ""
        return if existing.split("\n").map(&:strip).include?(line) # idempotent

        File.open(exclude_file, "a") do |f|
          f.print("\n") unless existing.empty? || existing.end_with?("\n")
          f.puts(line)
        end
        warn "note: added '#{line}' to .git/info/exclude (local-only) so the SECRET stays uncommitted"
      end

      def git_repo?
        !git_dir.nil?
      end

      # Absolute path to the .git directory (handles worktrees/submodules where
      # `git rev-parse --git-dir` may return a non-default location). nil when
      # CWD is not inside a git repo.
      def git_dir
        return @git_dir if defined?(@git_dir)

        out = `git rev-parse --absolute-git-dir 2>/dev/null`
        @git_dir = ($?.success? && !out.strip.empty?) ? out.strip : nil
      rescue StandardError
        @git_dir = nil
      end

      def path_ignored?(path)
        out = `git check-ignore #{shell_escape(path)} 2>/dev/null`
        $?.success? && !out.strip.empty?
      rescue StandardError
        false
      end

      def shell_escape(str)
        "'#{str.gsub("'", "'\\\\''")}'"
      end
    end
  end
end
