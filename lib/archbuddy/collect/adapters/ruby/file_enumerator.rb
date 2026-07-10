# frozen_string_literal: true

module Archbuddy
  module Collect
    module Adapters
      module Ruby
        # Enumerate Ruby source files under a root, honoring the config ignore
        # list. Yields [absolute_path, rel_file] pairs with deterministic
        # ordering so the whole capture is reproducible (D30).
        #
        # v0.10 W2-B: enumeration admits `**/*.rb` PLUS the rake surfaces —
        # `**/*.rake` and the extensionless `Rakefile` — which Prism parses as
        # plain Ruby. This is the PREREQUISITE for rake root detection (`task`
        # DSL lives in files the old `.rb`-only glob never saw). Repos with no
        # `.rake`/`Rakefile` enumerate byte-identically to before.
        class FileEnumerator
          # Raised when the capture target cannot produce a meaningful graph —
          # either the path does not exist or it contains zero .rb files. Failing
          # loudly here prevents emitting a near-empty graph (just the external
          # sink) with no signal, which silently masks a misconfigured target.
          class NoSourceError < StandardError; end

          # The glob patterns of the Ruby-source family we enumerate.
          SOURCE_GLOBS = ["**/*.rb", "**/*.rake", "**/Rakefile"].freeze

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
              unless ruby_source?(@root)
                raise NoSourceError, "target file is not a .rb file (or .rake/Rakefile): #{@root}"
              end
              return [[@root, File.basename(@root)]]
            end

            found =
              SOURCE_GLOBS
                .flat_map { |pattern| Dir.glob(File.join(@root, pattern)) }
                .uniq
                .reject { |path| ignored?(path) }
                .sort
                .map { |abs| [abs, rel(abs)] }

            if found.empty?
              raise NoSourceError,
                    "no .rb files (or .rake/Rakefile) found under #{@root} (after applying the ignore list)"
            end

            found
          end

          private

          # The Ruby-source family for a single-file target: .rb, .rake, or
          # an extensionless Rakefile (all plain Ruby to Prism).
          def ruby_source?(path)
            path.end_with?(".rb", ".rake") || File.basename(path) == "Rakefile"
          end

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
