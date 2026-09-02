# frozen_string_literal: true

require "prism"

module Archbuddy
  module Collect
    module Adapters
      module Ruby
        module RootDsl
          # GEM RE-ENTRY: app code a GEM calls, declared by a macro in app source.
          #
          # The graph models app -> gem crossings as cost-1 exits and deliberately
          # does not traverse into a dependency. But a gem frequently turns around
          # and calls BACK into the application, and that direction is an INGRESS
          # ROOT, not a crossing: the method runs, carries its own complexity, and
          # has no in-app caller at all. Measured on one service, 358 app methods
          # holding 2,082 branches sit unreachable for exactly this reason — they
          # fall out of every route-based score because nothing in the graph
          # reaches them.
          #
          # This recognizes the subset that is DECLARED IN SOURCE, which is what
          # makes it a fact rather than a guess. Two argument shapes:
          #
          #   SYMBOL args name a method on the DECLARING class:
          #     validate :valid_earn_loyalty      -> Provider::Purchase#valid_earn_loyalty
          #     after_commit :notify              -> ThisClass#notify
          #
          #   CONSTANT args name ANOTHER class whose entry method the gem invokes:
          #     organize Clawback::IdentifyPreviousCustomer, Clawback::Purchases
          #                                       -> each of those classes' #call
          #
          # NOT COVERED, and recorded so the boundary is visible rather than
          # discovered: a callback given a block or a proc (there is no named
          # method to seed), a string argument (`validate "foo"` is legal but
          # rare, and a string is not a provable method reference here), and a
          # dynamically built symbol. Each of those declines.
          #
          # Mirror of RackMiddleware/GrapeDsl: pure functions over Prism nodes,
          # no walk and no state. The seeders own the walk.
          module GemReentry
            # Macros whose SYMBOL arguments name a method on the declaring class,
            # invoked later by the framework.
            #
            # WHY A LIST AND NOT A SHAPE. There is no structural signature for
            # "a gem will call this back" — `validate :foo` and `helper :foo`
            # parse identically and mean different things. So this is vocabulary,
            # and it is kept HERE next to the other framework recognizers rather
            # than inferred, with the same consequence as everywhere else in this
            # codebase: a macro we have not named simply declines.
            CALLBACK_MACROS = %w[
              validate validates_each
              before_validation after_validation
              before_save after_save around_save
              before_create after_create around_create
              before_update after_update around_update
              before_destroy after_destroy around_destroy
              after_commit after_rollback after_initialize after_find
              after_touch
              before_action after_action around_action
              before_enqueue after_enqueue around_enqueue
              before_perform after_perform around_perform
            ].freeze

            # Macros whose CONSTANT arguments name a class the gem will invoke.
            # `organize` is Interactor::Organizer's whole interface.
            ORGANIZER_MACROS = %w[organize].freeze

            # The instance method an organized class exposes to its gem. Named
            # here because it is the organizer contract, not a guess about the
            # app: Interactor::Organizer calls `.call` on each, which reaches
            # `#call`.
            ORGANIZED_ENTRY = "call"

            module_function

            def callback_macro?(name) = CALLBACK_MACROS.include?(name.to_s)
            def organizer_macro?(name) = ORGANIZER_MACROS.include?(name.to_s)

            # Method names a callback macro names on the declaring class.
            #
            # Symbols ONLY. A callback can also take `if:`/`unless:` keyword
            # options whose values are symbols naming OTHER methods the framework
            # calls — those are real re-entry too, so they are collected as well,
            # but ONLY from those two keys. Sweeping every keyword value would
            # pick up `on: :create`, which names a lifecycle event and not a
            # method, and seeding it would invent a root.
            GUARD_KEYS = %w[if unless].freeze

            def callback_targets(call_node)
              args = call_node.arguments&.arguments || []
              named = args.grep(Prism::SymbolNode).map { |s| s.unescaped.to_s }
              named + guard_targets(args)
            end

            def guard_targets(args)
              args.grep(Prism::KeywordHashNode).flat_map do |kw|
                kw.elements.grep(Prism::AssocNode).filter_map do |assoc|
                  next unless assoc.key.is_a?(Prism::SymbolNode)
                  next unless GUARD_KEYS.include?(assoc.key.unescaped.to_s)
                  next unless assoc.value.is_a?(Prism::SymbolNode)

                  assoc.value.unescaped.to_s
                end
              end
            end

            # Constant names an organizer macro names. Accepts both the
            # single-line (`organize A, B`) and parenthesised multi-line forms,
            # which parse to the same argument list.
            def organized_constants(call_node)
              (call_node.arguments&.arguments || []).filter_map do |a|
                a.slice if a.is_a?(Prism::ConstantReadNode) || a.is_a?(Prism::ConstantPathNode)
              end
            end
          end
        end
      end
    end
  end
end
