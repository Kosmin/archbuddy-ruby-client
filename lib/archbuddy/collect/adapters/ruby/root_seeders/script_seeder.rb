# frozen_string_literal: true

require "prism"
require_relative "../root_seeder"

module Archbuddy
  module Collect
    module Adapters
      module Ruby
        module RootSeeders
          # Tags top-level defs of REAL script files as :script ingress
          # roots (v0.10 W2-B). A FRAGMENT-AWARE seeder: it re-tags the
          # top-level rooting that already exists (top-level defs are
          # already entrypoints via the :default strategy) with the more
          # specific :script category — it never adds nodes or roots.
          #
          # A fragment is a REAL script iff ALL hold (L8):
          #   1. its rel_file lives under `scripts/**`, `script/**`, or
          #      directly in `bin/` (binstub home — one level only),
          #   2. the file starts with a shebang (`#!...`) — read from disk,
          #      since the parsed AST does not carry leading comments,
          #   3. its top-level body is NOT loader-only — a body consisting
          #      solely of `require`/`require_relative`/`load` calls is the
          #      Bundler/Rails binstub shape (`load Gem.bin_path(...)`,
          #      `require "bundler/setup"`,
          #      `require_relative "../config/boot"`) and is DECLINED.
          #
          # NEVER-FABRICATE (L4): any unprovable step (no `root` to read
          # the source from, unreadable file, no shebang, loader-only body)
          # DECLINES the whole file. Tagging is via
          # SymbolTable#mark_entrypoint, which is itself `method?`-gated.
          class ScriptSeeder < RootSeeder
            SCRIPT_DIRS = %w[scripts script].freeze

            # Loader/binstub call names: a top-level body made ONLY of these
            # is a loader, not a script.
            LOADER_CALLS = %w[require require_relative load].freeze

            def self.root_type = :script

            def root_type = :script

            def seed(table, fragments: nil, root: nil)
              return if fragments.nil? || root.nil?

              fragments.each do |fragment|
                next unless script_path?(fragment.rel_file)
                next unless shebang?(source_path(root, fragment.rel_file))
                next unless real_body?(fragment.parsed_value)

                tag_top_level_defs(table, fragment.rel_file)
              end
            end

            private

            # scripts/** and script/** at any depth; bin/ direct children
            # only (nested bin subtrees are not the binstub convention).
            def script_path?(rel_file)
              segments = rel_file.split("/")
              return false if segments.length < 2

              SCRIPT_DIRS.include?(segments.first) ||
                (segments.first == "bin" && segments.length == 2)
            end

            # The adapter root may be the repo dir (rel_file joins under it)
            # or a single-file target (the root IS the file).
            def source_path(root, rel_file)
              File.directory?(root) ? File.join(root, rel_file) : root
            end

            def shebang?(abs_path)
              File.file?(abs_path) && File.open(abs_path) { |f| f.readline(chomp: true) }.start_with?("#!")
            rescue StandardError
              false # unreadable / empty -> unprovable -> decline (L4)
            end

            # True when the top-level statements contain ANYTHING besides
            # loader calls. An empty body or a pure require/load chain (the
            # binstub shape) is declined.
            def real_body?(program_node)
              statements = program_node.statements&.body || []
              return false if statements.empty?

              statements.any? { |stmt| !loader_call?(stmt) }
            end

            def loader_call?(node)
              node.is_a?(Prism::CallNode) &&
                (node.receiver.nil? || node.receiver.is_a?(Prism::SelfNode)) &&
                LOADER_CALLS.include?(node.name.to_s)
            end

            # Re-tag THIS file's top-level defs (owner_fq nil — already
            # roots via :default/top_level) with :script. mark_entrypoint is
            # first-write-wins, so an fq some earlier seeder categorized
            # keeps its more-specific category.
            def tag_top_level_defs(table, rel_file)
              table.methods.each_value do |entry|
                next unless entry.owner_fq.nil? && entry.rel_file == rel_file

                table.mark_entrypoint(entry.fq_symbol, :script)
              end
            end
          end
        end
      end
    end
  end
end
