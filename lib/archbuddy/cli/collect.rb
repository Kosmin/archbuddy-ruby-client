# frozen_string_literal: true

require "dry/cli"
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

      option :out_dir, default: "./out", desc: "Output directory for graph.yml + id-map.yml"
      option :language, default: "ruby", desc: "Adapter language"
      option :entrypoints, default: "default",
                           desc: "Entrypoint strategy: default|controllers|all_public|none"
      option :entrypoint_pattern, type: :array, default: [],
                                  desc: "Additional entrypoint fq-symbol regex(es)"

      def call(path:, out_dir:, language:, entrypoints:, entrypoint_pattern:, **)
        config = Archbuddy::Collect::Config.new(
          language:            language,
          entrypoint_strategy: entrypoints,
          entrypoint_patterns: entrypoint_pattern
        )

        adapter        = Archbuddy::Collect::Registry.for(language).new(path, config)
        adapter_result = adapter.collect

        anon = Archbuddy::Collect::Anonymizer.new(
          adapter_result,
          tool: "archbuddy #{Archbuddy::VERSION}",
          adapter: language
        ).call

        paths = Archbuddy::Collect::Emitter.new(out_dir: out_dir).emit(
          graph: anon.graph, id_map: anon.id_map
        )

        warn "wrote #{paths[:graph]}"
        warn "wrote #{paths[:id_map]} (SECRET — gitignored, never share)"
      end
    end
  end
end
