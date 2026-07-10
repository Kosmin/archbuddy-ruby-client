# frozen_string_literal: true

require "fileutils"
require_relative "../cache"

module Archbuddy
  module Collect
    # K-7: validate the opaque graph hash against the contract schema BEFORE
    # writing (D37), serialize deterministically via the contract Serializer
    # (D30), and write graph.yml + the SECRET id-map.yml into an output dir.
    #
    # gitignore-before-secret: before writing id-map.yml we VERIFY the output
    # path is covered by .gitignore (the repo already excludes id-map.yml,
    # *.id-map.yml and /out/). If it is not provably ignored, we refuse to write
    # the secret rather than risk committing real symbol names.
    class Emitter
      Validator  = ArchitectureAuditor::Contract::Validator
      Serializer = ArchitectureAuditor::Contract::Serializer

      class SecretNotIgnoredError < StandardError; end

      GRAPH_FILENAME  = "graph.yml"
      ID_MAP_FILENAME = "id-map.yml"

      def initialize(out_dir:, project_root: Dir.pwd)
        @out_dir      = File.expand_path(out_dir)
        @project_root = File.expand_path(project_root)
      end

      # @param graph [Hash] opaque graph
      # @param id_map [Hash] secret id-map
      # @param committed [Boolean] also transcode+write the COMMITTED real-name
      #   `.archbuddy/` cache (root aggregate + detail tree). Default true; the
      #   opaque graph.yml + SECRET id-map.yml are still written (gitignored
      #   internal interchange the engine `analyze` consumes).
      # @param diagnostics [Hash, nil] the collect-time AdapterResult.diagnostics
      #   carrier (v0.10 W3, Reconciliation 1) — counts only (meta/egress/call-site
      #   tallies), NEVER graph content. Threaded through to the committed
      #   aggregate writer so the `egress` + `dynamic_dispatch` blocks fold from
      #   the single producer→writer handshake. Default nil (callers without a
      #   fresh collect keep today's behavior).
      # @return [Hash] { graph:, id_map:, committed: { aggregate:, fragments: } }
      def emit(graph:, id_map:, committed: true, diagnostics: nil)
        # D37: validate before writing — a non-conforming graph never reaches disk.
        Validator.validate!(:graph, graph)

        FileUtils.mkdir_p(@out_dir)

        graph_path  = File.join(@out_dir, GRAPH_FILENAME)
        id_map_path = File.join(@out_dir, ID_MAP_FILENAME)

        File.write(graph_path, Serializer.dump(graph))

        # gitignore-before-secret guard.
        ensure_secret_ignored!(id_map_path)
        File.write(id_map_path, Serializer.dump(id_map))

        result = { graph: graph_path, id_map: id_map_path }

        # DE-ANON-AT-WRITE (C1-2): transcode opaque graph + SECRET id-map into the
        # COMMITTED real-name, line-free layout under the audited project root.
        # `findings: nil` at collect time — the structural aggregate carries the
        # source pointers only; scores + the multiplexer_proxy list are folded in
        # when the aggregate is re-transcoded post-analyze.
        if committed
          result[:committed] = Archbuddy::Cache::Writer.new(project_root: @project_root)
                                                       .write(graph: graph, id_map: id_map,
                                                              diagnostics: diagnostics)
        end

        result
      end

      private

      # Refuse to write the secret unless git would ignore it. Uses
      # `git check-ignore`; if git is unavailable or the repo isn't a git repo,
      # fall back to a filename-pattern check (id-map.yml / *.id-map.yml) which
      # the repo .gitignore already covers.
      def ensure_secret_ignored!(path)
        return if git_ignored?(path)
        return if filename_ignored?(path)

        raise SecretNotIgnoredError,
              "refusing to write secret id-map to #{path}: path is not gitignored. " \
              "Add it to .gitignore (e.g. id-map.yml, *.id-map.yml, or /out/) before retrying."
      end

      def git_ignored?(path)
        out = `git -C #{shell_escape(@project_root)} check-ignore #{shell_escape(path)} 2>/dev/null`
        $?.success? && !out.strip.empty?
      rescue StandardError
        false
      end

      def filename_ignored?(path)
        base = File.basename(path)
        base == ID_MAP_FILENAME || base.end_with?(".id-map.yml")
      end

      def shell_escape(str)
        "'#{str.gsub("'", "'\\\\''")}'"
      end
    end
  end
end
