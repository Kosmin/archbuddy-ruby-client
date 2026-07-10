# frozen_string_literal: true

require "prism"

module Archbuddy
  module Collect
    module Adapters
      module Ruby
        module RootDsl
          # Shared, pure recognizer for the Rake task DSL (v0.10 W2-B).
          # Single source of truth used by BOTH Pass 1 (DefinitionPass —
          # MINTS the synthetic task NODE) and Pass 2 (ResolutionPass —
          # opens the task-block scope so its body calls resolve as EDGES).
          # Both passes MUST agree byte-for-byte on what counts as a task
          # and on the synthetic FQ they mint/push, or edges silently vanish
          # (F5 ordinal parity) — keeping the detection AND the FQ builder
          # here is the mechanism that guarantees that agreement (mirror of
          # GrapeDsl.endpoint_fq).
          #
          # Pure functions over Prism nodes only — no AST walk, no state, no
          # app boot (L4 static-only). Everything unprovable — a computed
          # task name (`task name_var do`), a blockless `task :x`
          # declaration, a receiver'd `rake.task` — is DECLINED.
          module RakeDsl
            module_function

            # True when `rel_file` is a rake surface: a `.rake` file or an
            # extensionless `Rakefile` (both admitted by the FileEnumerator
            # as of W2-B). nil -> false (a pass without file context never
            # recognizes rake).
            def rake_file?(rel_file)
              return false if rel_file.nil?

              rel_file.end_with?(".rake") || File.basename(rel_file) == "Rakefile"
            end

            # True when `node` declares a task body we can root: a CallNode
            # named `task`, carrying a block, on a self/implicit receiver,
            # whose NAME is a provable literal (task_name non-nil). A
            # blockless `task :x` (pure declaration/prereq form) has no body
            # to root; a computed name is unprovable — both DECLINE (L4).
            def task_call?(node)
              return false unless node.is_a?(Prism::CallNode)
              return false unless node.name.to_s == "task"
              return false if node.block.nil?
              return false unless self_receiver?(node.receiver)

              !task_name(node).nil?
            end

            # The provable literal task name, covering the three static
            # first-argument shapes:
            #   task :backup do            -> "backup"   (SymbolNode)
            #   task "backup" do           -> "backup"   (StringNode)
            #   task backup: :environment do -> "backup" (hash: name => deps)
            # Anything else (variable, interpolation, computed key) -> nil.
            def task_name(node)
              return nil unless node.is_a?(Prism::CallNode)

              first = node.arguments&.arguments&.first
              literal_task_name(first)
            end

            # True when `node` opens a `namespace :x do ... end` with a
            # provable literal name on a self/implicit receiver.
            def namespace_call?(node)
              return false unless node.is_a?(Prism::CallNode)
              return false unless node.name.to_s == "namespace"
              return false if node.block.nil?
              return false unless self_receiver?(node.receiver)

              !namespace_name(node).nil?
            end

            # The provable literal namespace label (symbol or string), else nil.
            def namespace_name(node)
              return nil unless node.is_a?(Prism::CallNode)

              literal_label(node.arguments&.arguments&.first)
            end

            # The synthetic fully-qualified symbol for a task block. Stable,
            # source-order-stamped so Pass 1 (mint) and Pass 2 (push) agree
            # byte-for-byte (F5):
            #   "rake:db:backup[0]" — first `task :backup` inside
            #                          `namespace :db` in this file.
            # The ordinal disambiguates re-declared same-name tasks within
            # one file (rake merges their bodies; we keep each body walkable
            # under one stable node per (namespace, name) first-declaration).
            def rake_fq(namespace_segments, name, ordinal)
              "rake:#{(namespace_segments + [name]).join(':')}[#{ordinal}]"
            end

            def self_receiver?(receiver)
              receiver.nil? || receiver.is_a?(Prism::SelfNode)
            end

            # A task's first argument: plain label, or the `name => deps`
            # hash whose FIRST key is the name.
            def literal_task_name(arg)
              case arg
              when Prism::KeywordHashNode, Prism::HashNode
                assoc = arg.elements.first
                assoc.is_a?(Prism::AssocNode) ? literal_label(assoc.key) : nil
              else
                literal_label(arg)
              end
            end

            # A provable literal label: a non-interpolated symbol or string.
            def literal_label(node)
              case node
              when Prism::SymbolNode then node.unescaped
              when Prism::StringNode then node.unescaped
              end
            end
          end
        end
      end
    end
  end
end
