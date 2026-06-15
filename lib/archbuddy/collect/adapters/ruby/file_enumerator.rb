# frozen_string_literal: true

module Archbuddy
  module Collect
    module Adapters
      module Ruby
        # Enumerate .rb files under a root, honoring the config ignore list.
        # Yields [absolute_path, rel_file] pairs with deterministic ordering so
        # the whole capture is reproducible (D30).
        class FileEnumerator
          def initialize(root, config)
            @root   = File.expand_path(root)
            @ignore = config.ignore
          end

          # @return [Array<Array(String, String)>] [[abs_path, rel_file], ...]
          def files
            if File.file?(@root)
              return [[@root, File.basename(@root)]]
            end

            Dir.glob(File.join(@root, "**", "*.rb"))
               .reject { |path| ignored?(path) }
               .sort
               .map { |abs| [abs, rel(abs)] }
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
