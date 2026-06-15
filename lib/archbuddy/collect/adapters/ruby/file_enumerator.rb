# frozen_string_literal: true

module Archbuddy
  module Collect
    module Adapters
      module Ruby
        # Enumerate .rb files under a root, honoring the config ignore list.
        # Yields [absolute_path, rel_file] pairs with deterministic ordering so
        # the whole capture is reproducible (D30).
        class FileEnumerator
          # Raised when the capture target cannot produce a meaningful graph —
          # either the path does not exist or it contains zero .rb files. Failing
          # loudly here prevents emitting a near-empty graph (just the external
          # sink) with no signal, which silently masks a misconfigured target.
          class NoSourceError < StandardError; end

          def initialize(root, config)
            @root   = File.expand_path(root)
            @ignore = config.ignore
          end

          # @return [Array<Array(String, String)>] [[abs_path, rel_file], ...]
          # @raise [NoSourceError] if the root does not exist or yields no .rb files
          def files
            unless File.exist?(@root)
              raise NoSourceError, "target path does not exist: #{@root}"
            end

            if File.file?(@root)
              unless @root.end_with?(".rb")
                raise NoSourceError, "target file is not a .rb file: #{@root}"
              end
              return [[@root, File.basename(@root)]]
            end

            found =
              Dir.glob(File.join(@root, "**", "*.rb"))
                 .reject { |path| ignored?(path) }
                 .sort
                 .map { |abs| [abs, rel(abs)] }

            if found.empty?
              raise NoSourceError, "no .rb files found under #{@root} (after applying the ignore list)"
            end

            found
          end

          private

          def rel(abs)
            abs.delete_prefix("#{@root}/")
          end

          def ignored?(abs)
            segments = rel(abs).split("/")
            @ignore.any? do |pattern|
              parts = pattern.split("/")
              # Match the ignore pattern as a contiguous segment subsequence,
              # so "db/migrate" ignores app/db/migrate/* too and "vendor"
              # ignores any vendor/ directory.
              segments.each_cons(parts.length).any? { |window| window == parts }
            end
          end
        end
      end
    end
  end
end
