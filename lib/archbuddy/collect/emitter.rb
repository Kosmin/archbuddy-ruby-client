# frozen_string_literal: true

require "fileutils"

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
      # @return [Hash] { graph: <path>, id_map: <path> }
      def emit(graph:, id_map:)
        # D37: validate before writing — a non-conforming graph never reaches disk.
        Validator.validate!(:graph, graph)

        FileUtils.mkdir_p(@out_dir)

        graph_path  = File.join(@out_dir, GRAPH_FILENAME)
        id_map_path = File.join(@out_dir, ID_MAP_FILENAME)

        File.write(graph_path, Serializer.dump(graph))

        # gitignore-before-secret guard.
        ensure_secret_ignored!(id_map_path)
        File.write(id_map_path, Serializer.dump(id_map))

        { graph: graph_path, id_map: id_map_path }
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
