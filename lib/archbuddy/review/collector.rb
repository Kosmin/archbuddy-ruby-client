# frozen_string_literal: true

require_relative "../collect"

module Archbuddy
  module Review
    # In-process, TARGET-INERT collect: runs the existing collect pipeline
    # (Config → Registry → adapter → Anonymizer → Emitter) scanning
    # `source_root` while writing the vintage to `write_root` (scratch) —
    # `diff` never mutates the target or a worktree. The id-map is born and
    # dies in scratch (the Emitter's id-map.yml filename fallback passes with
    # ZERO exclude-file management — no `.git/info/exclude` writes, ever).
    #
    # Replicates cli/collect.rb:71-106 verbatim, only `project_root`
    # redirected. Fragment `file` keys come out relative to `source_root` —
    # the target-relative identity space (monorepo-correct when source_root =
    # `<worktree>/<prefix>`).
    module Collector
      module_function

      # @param source_root [String] the tree to scan (never written)
      # @param write_root [String] scratch dir receiving aggregate + .archbuddy/
      # @param options [Hash] collect options (Config#collect_options — {}-safe)
      # @return [String] write_root (now holding the vintage)
      # @raise [Review::VintageError] when the source has no scored sources
      def collect(source_root:, write_root:, options: {})
        language = options.fetch(:language, "ruby")
        config = Archbuddy::Collect::Config.new(
          language: language,
          entrypoint_strategy: options.fetch(:entrypoints, "default"),
          entrypoint_patterns: options.fetch(:entrypoint_pattern, []),
          probes: options.fetch(:probes, "all"),
          root_types: options.fetch(:root_types, "all")
        )

        adapter = Archbuddy::Collect::Registry.for(language).new(source_root, config)
        result =
          begin
            adapter.collect(mode: :full)
          rescue Archbuddy::Collect::Adapters::Ruby::FileEnumerator::NoSourceError
            raise VintageError, "no scored sources at #{source_root}"
          end

        anon = Archbuddy::Collect::Anonymizer.new(
          result,
          tool: "archbuddy #{Archbuddy::VERSION}",
          adapter: language
        ).call

        Archbuddy::Collect::Emitter
          .new(out_dir: File.join(write_root, ".archbuddy"), project_root: write_root)
          .emit(graph: anon.graph, id_map: anon.id_map, diagnostics: result.diagnostics)

        write_root
      end
    end
  end
end
