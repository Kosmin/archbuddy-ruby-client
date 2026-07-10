# frozen_string_literal: true

require "prism"

module Archbuddy
  module Collect
    module Adapters
      module Ruby
        module RootDsl
          # Shared, pure recognizer for mixin declarations (L14 — GENERAL mixin
          # capture, W0). Recognizes `include`/`prepend`/`extend` calls with a
          # self/implicit receiver and extracts ONLY the provable
          # literal-constant module arguments. Everything dynamic — a variable
          # (`include some_var`), a splat (`include(*mods)`), a method call, a
          # conditional expression (`include(flag ? A : B)`) — is DECLINED,
          # never recorded (L4 never-fabricate).
          #
          # Mirror of GrapeDsl: pure functions over Prism nodes only — no AST
          # walk, no state, no app boot. Consumers (DefinitionPass, and later
          # root seeders) decide the semantics of each captured mixin.
          module MixinDsl
            # The three Ruby mixin verbs. All are captured into the SAME
            # ClassEntry#mixins list — a general primitive; a consumer that
            # only cares about `include`/`prepend` (e.g. the Sidekiq job
            # seeder) applies its own filter.
            MIXIN_METHODS = %w[include prepend extend].freeze

            module_function

            # True when `node` is a mixin declaration worth inspecting: a
            # CallNode named include/prepend/extend, on a self/implicit
            # receiver, with at least one argument. (Argument PROVABILITY is
            # judged per-argument by mixin_constants.)
            def mixin_call?(node)
              return false unless node.is_a?(Prism::CallNode)
              return false unless MIXIN_METHODS.include?(node.name.to_s)
              return false unless self_receiver?(node.receiver)

              !node.arguments.nil? && !node.arguments.arguments.empty?
            end

            # The provable literal-constant module names among the call's
            # arguments, in source order (e.g. ["Bar", "Concerns::Trackable"]).
            # Non-constant arguments are SKIPPED — declined, never recorded.
            def mixin_constants(node)
              return [] unless node.is_a?(Prism::CallNode) && node.arguments

              node.arguments.arguments.filter_map do |arg|
                arg.slice if literal_constant?(arg)
              end
            end

            def literal_constant?(node)
              node.is_a?(Prism::ConstantReadNode) ||
                node.is_a?(Prism::ConstantPathNode)
            end

            def self_receiver?(receiver)
              receiver.nil? || receiver.is_a?(Prism::SelfNode)
            end
          end
        end
      end
    end
  end
end
