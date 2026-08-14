# frozen_string_literal: true

require "prism"

module Archbuddy
  module Collect
    module Adapters
      module Ruby
        # THE ONE SPELLING OF "WHAT SHAPE IS THIS RECEIVER" (configurator W4 /
        # C13) — a pure, stateless classifier over a Prism receiver node.
        #
        # WHY THIS EXISTS. Five places had grown their own copy of the same
        # `case receiver when ConstantReadNode, ConstantPathNode …` ladder:
        # `RubyResolver#constant_receiver_fq` / `#typed_receiver_fq` /
        # `#self_receiver?`, `ResolutionPass#const_new_fq`,
        # `MetaSendProbe#receiver_fq`, `EgressProbe#literal_constant_fq` and
        # `BoundaryRules#receiver_constant_fq`. Each was individually small and
        # collectively a five-way drift risk on the ONE question the collector
        # asks most often.
        #
        # A PURE DE-DUPLICATION, AND ONLY THAT. This module ships NO new
        # capability. In particular the LITERAL-RECEIVER WIDENING (claiming
        # `Const.new.verb` chains the base tiers decline today) is deliberately
        # NOT here: it moves scores through the A6 back-door and belongs to its
        # own release. The proof of pure-de-duplication is byte-identical
        # goldens, and it is a gate rather than a hope.
        #
        # WHY PRIMITIVES AND NOT ONE `receiver_fq(ctx)`. The five call sites do
        # NOT agree, and collapsing them into one function would silently change
        # four of them:
        #
        #   * MetaSendProbe resolves a SELF receiver to the enclosing class; the
        #     resolver's R4.5 does not (R3 already handled self, above it).
        #   * MetaSendProbe declines a CallNode receiver entirely; R4.5 and
        #     BoundaryRules resolve a bare accessor call through the type scope.
        #   * BoundaryRules must NEVER claim a self receiver — "a boundary is a
        #     thing you cross, not a thing you are".
        #
        # So each site keeps its own composition and this module supplies the
        # shared VOCABULARY. The disagreements above become visible in each
        # caller's `case` rather than being buried in a shared conditional.
        module ReceiverShape
          # The closed shape vocabulary. `:self` covers BOTH an implicit-self
          # (nil) receiver and an explicit `self`, because every consumer treats
          # them identically. `:chained` is any call-node receiver — an inline
          # `Const.new`, a bare memoized accessor and a `a.b.c` chain alike;
          # telling those apart is a question about the CHAIN, which the
          # `constructor_*` and `scope_key` primitives below answer.
          SHAPES = %i[self literal_const local ivar chained other].freeze

          module_function

          # @param receiver [Prism::Node, nil]
          # @return [Symbol] one of {SHAPES}
          def of(receiver)
            case receiver
            when nil, Prism::SelfNode                              then :self
            when Prism::ConstantReadNode, Prism::ConstantPathNode  then :literal_const
            when Prism::LocalVariableReadNode                      then :local
            when Prism::InstanceVariableReadNode                   then :ivar
            when Prism::CallNode                                   then :chained
            else :other
            end
          end

          def self?(receiver)
            of(receiver) == :self
          end

          # The fully-qualified constant a LITERAL constant receiver names, or
          # nil. Never touches a scope, never walks a chain.
          def constant_fq(receiver)
            case receiver
            when Prism::ConstantReadNode, Prism::ConstantPathNode
              receiver.slice
            end
          end

          # True when +node+ is exactly a `<something>.new` call — the inline
          # constructor chain. The `<something>` need not be a constant; that is
          # what {constructor_constant_fq} decides (and declines on).
          def constructor_chain?(node)
            node.is_a?(Prism::CallNode) && node.name == :new && !node.receiver.nil?
          end

          # The constant FQ of an inline `Const.new` / `Const::Path.new` chain,
          # or nil when the constructed thing is not a literal constant.
          def constructor_constant_fq(node)
            constant_fq(node.receiver)
          end

          # The key under which a receiver's inferred type would be recorded in
          # the conservative intra-procedural type scope (L1): a local's name, an
          # ivar's name, or a BARE (nil-receiver) call's name — the memoized
          # accessor idiom. nil for everything else, including a call node that
          # has its own receiver.
          #
          # This method does NOT consult a scope. Deciding whether to look a key
          # up at all is the caller's, because the callers disagree (see the
          # module comment).
          def scope_key(receiver)
            case receiver
            when Prism::LocalVariableReadNode, Prism::InstanceVariableReadNode
              receiver.name.to_s
            when Prism::CallNode
              receiver.receiver.nil? ? receiver.name.to_s : nil
            end
          end
        end
      end
    end
  end
end
