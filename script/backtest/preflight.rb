# frozen_string_literal: true

require "open3"

module Backtest
  # Git pre-flight (R4 caveat): verify every needed SHA resolves in its probe
  # clone BEFORE any tier spends collect time. Missing SHAs mark their PRs
  # `skipped: unresolvable_sha` (hard error only with --strict).
  module Preflight
    module_function

    # @param clone_path [String]
    # @param shas [Array<String>]
    # @return [{resolvable: [String], missing: [String]}]
    def check(clone_path, shas)
      resolvable = []
      missing = []
      Open3.popen2("git", "-C", clone_path, "cat-file", "--batch-check") do |stdin, stdout|
        shas.each do |sha|
          stdin.puts("#{sha}^{commit}")
          line = stdout.gets.to_s
          if line.include?(" missing")
            missing << sha
          else
            resolvable << sha
          end
        end
        stdin.close
      end
      { resolvable: resolvable, missing: missing }
    rescue SystemCallError
      { resolvable: [], missing: shas.dup }
    end

    def report(clone_path, shas, io: $stderr)
      result = check(clone_path, shas)
      io.puts "note: preflight #{clone_path}: resolvable #{result[:resolvable].size}/#{shas.size}"
      result
    end
  end
end
