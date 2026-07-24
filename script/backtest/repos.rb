# frozen_string_literal: true

module Backtest
  # ARCHBUDDY_STUDY_REPOS parser (G5): `org/name=abs_path[:subdir]`,
  # comma-separated, e.g.
  #   thanx/thanx-merchant-api-new=/abs/path,thanx/nexus=/abs/nexus:services/merchant-api
  # No absolute paths are ever committed — env-only.
  module Repos
    Entry = Data.define(:key, :path, :subdir) do
      # The collect target inside a worktree of this clone.
      def target_in(worktree)
        subdir ? File.join(worktree, subdir) : worktree
      end
    end

    module_function

    # @return [Hash{String => Entry}] keyed by org/name
    def parse(env_value)
      return {} if env_value.nil? || env_value.strip.empty?

      env_value.split(",").each_with_object({}) do |pair, acc|
        key, rest = pair.strip.split("=", 2)
        if key.nil? || key.empty? || rest.nil? || rest.empty?
          raise ArgumentError, "bad ARCHBUDDY_STUDY_REPOS entry '#{pair}' (want org/name=abs_path[:subdir])"
        end

        path, subdir = rest.split(":", 2)
        acc[key] = Entry.new(key: key, path: path, subdir: subdir)
      end
    end

    def from_env
      parse(ENV.fetch("ARCHBUDDY_STUDY_REPOS", nil))
    end
  end
end
