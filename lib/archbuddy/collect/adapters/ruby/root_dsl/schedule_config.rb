# frozen_string_literal: true

require "psych"
require "prism"

module Archbuddy
  module Collect
    module Adapters
      module Ruby
        module RootDsl
          # PURE recognizers for cron schedule config shapes (v0.10 W4b — L8
          # "cron = LINK only"). Mirrors the other RootDsl recognizers: no
          # SymbolTable access, no I/O beyond what the caller hands in, no
          # state. The CronLinkSeeder owns the confirm-or-decline decision;
          # this module only answers "what provable link targets does this
          # config DECLARE?".
          #
          # Two config dialects (L8):
          #   - sidekiq-cron YAML (config/schedule.yml / config/sidekiq_cron.yml):
          #       job_name:
          #         cron:  "* * * * *"
          #         class: "MyJob"
          #     → a `class:` literal constant path is a provable link target.
          #   - whenever DSL (config/schedule.rb):
          #       every :day { rake "db:backup" }          → provable rake link
          #       every :day { runner "MyJob.perform_now" } → provable runner
          #                    link IFF the literal is a Const(.method) path
          #       every :day { command "ls -la" }           → OPAQUE (declined)
          #
          # NEVER-FABRICATE (L4/I1): anything non-literal, non-constant-shaped,
          # or free-form (shell `command`, computed `runner`) is returned in
          # the `opaque` bucket so the seeder DECLINES it. Malformed input →
          # empty result, never a raise (degenerate-input rule).
          module ScheduleConfig
            # A literal Ruby constant path: "MyJob", "Billing::SyncJob".
            CONSTANT_PATH = /\A[A-Z]\w*(::[A-Z]\w*)*\z/
            # A literal "Const.method" runner target: "MyJob.perform_now".
            RUNNER_TARGET = /\A([A-Z]\w*(?:::[A-Z]\w*)*)\.(\w+[?!]?)\z/

            # The parsed whenever/sidekiq-cron declarations of one config
            # source. `rake_names`/`runner_targets`/`job_classes` are provable
            # LITERAL declarations; `opaque` counts declined forms (command /
            # non-literal runner / malformed entries) — surfaced so the seeder
            # can record honest declines.
            Entries = Struct.new(
              :job_classes, :rake_names, :runner_targets, :opaque,
              keyword_init: true
            ) do
              def initialize(*)
                super
                self.job_classes    ||= []
                self.rake_names     ||= []
                self.runner_targets ||= []
                self.opaque         ||= []
              end
            end

            module_function

            # sidekiq-cron YAML doc → Entries. Recognizes the canonical shape
            # {name => {"cron" => …, "class" => "Const"}}; entries without a
            # literal constant-path `class:` (or without `cron:`) are OPAQUE.
            # A non-Hash doc (malformed YAML that still parses — e.g. a bare
            # scalar/array) yields empty Entries.
            def sidekiq_cron_entries(doc)
              entries = Entries.new
              return entries unless doc.is_a?(Hash)

              doc.each do |name, spec|
                unless spec.is_a?(Hash) && spec.key?("cron")
                  entries.opaque << "sidekiq_cron:#{name}"
                  next
                end
                klass = spec["class"]
                if klass.is_a?(String) && klass.match?(CONSTANT_PATH)
                  entries.job_classes << klass
                else
                  entries.opaque << "sidekiq_cron:#{name}"
                end
              end
              entries
            end

            # whenever `schedule.rb` SOURCE → Entries, via a Prism walk over
            # every CallNode. Only LITERAL single-string arguments are
            # provable; interpolation/variables/concats are opaque. Unparseable
            # source yields empty Entries (never a raise).
            def whenever_entries(source)
              entries = Entries.new
              parsed  = Prism.parse(source)
              return entries unless parsed.success?

              walk_calls(parsed.value) do |call|
                classify_whenever_call(call, entries)
              end
              entries
            rescue StandardError
              Entries.new
            end

            # @api private — yield every CallNode in the tree, depth-first.
            def walk_calls(node, &block)
              yield(node) if node.is_a?(Prism::CallNode)
              node.compact_child_nodes.each { |child| walk_calls(child, &block) }
            end

            # @api private
            def classify_whenever_call(call, entries)
              case call.name
              when :rake
                name = literal_string_arg(call)
                name ? entries.rake_names << name : entries.opaque << "rake"
              when :runner
                target = literal_string_arg(call)
                if target&.match?(RUNNER_TARGET)
                  entries.runner_targets << target
                else
                  entries.opaque << "runner"
                end
              when :command
                # Free-form shell — NEVER provable (L8): always opaque.
                entries.opaque << "command"
              end
            end

            # @api private — the call's first argument iff it is a plain
            # (non-interpolated) string literal; nil otherwise.
            def literal_string_arg(call)
              arg = call.arguments&.arguments&.first
              return nil unless arg.is_a?(Prism::StringNode)

              arg.unescaped
            end
          end
        end
      end
    end
  end
end
