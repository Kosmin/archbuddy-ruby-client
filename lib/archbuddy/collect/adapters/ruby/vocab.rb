# frozen_string_literal: true

module Archbuddy
  module Collect
    module Adapters
      module Ruby
        # AST-SHAPE predicates the resolver consults.
        #
        # WHAT USED TO LIVE HERE: eleven frozen `Set`s of Ruby/Rails
        # vocabulary — operators, metaprogramming verbs, the ActiveRecord
        # method list, ORM/controller/job base classes, the HTTP-client roots.
        # All of it moved, unchanged, into the ENGINE-SHIPPED PROFILE
        # (`Contract::Profiles`, served through `Ruby::Profile` and reached via
        # `SymbolTable#profile`). Vocabulary is DATA about an ecosystem; it does
        # not belong in the collector's source.
        #
        # WHAT STAYS: `literal_dispatch_arg?` is not vocabulary. It asks a
        # question about the SHAPE OF A PRISM NODE ("is the first argument a
        # literal Symbol/String"), which no data document can express and which
        # both the Resolver and the EscapeScanner must answer identically.
        module Vocab
          module_function

          # v0.12 L18 (HOISTED from Resolver so the EscapeScanner shares the
          # ONE spelling — no second copy): true iff the call node's FIRST
          # argument is a literal Symbol/String. A resolvable dispatch verb
          # with a literal arg is resolvable dispatch (MetaSendProbe
          # territory), not a dynamic blind spot.
          def literal_dispatch_arg?(node)
            arg = node&.arguments&.arguments&.first
            arg.is_a?(Prism::SymbolNode) || arg.is_a?(Prism::StringNode)
          end
        end
      end
    end
  end
end
