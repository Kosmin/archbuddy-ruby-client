# frozen_string_literal: true

require "prism"

module Archbuddy
  module Collect
    module Adapters
      module Ruby
        # Per-call-site USAGE classification (v0.13-usage): what does the code
        # at a call site DO with the callee's result? Four classes, derived
        # PURELY from the call site's own LOCAL syntactic position:
        #
        #   :value     — the result is assigned, passed as an argument, returned
        #                explicitly, interpolated, or stored in a literal.
        #   :predicate — the result's TRUTHINESS is tested: an if/unless/while/
        #                until condition, a case subject or `when` condition, the
        #                LEFT operand of `&&`/`||`, a `!`/`not` operand, a rescue
        #                exception match, a pattern or pin.
        #   :effect    — the result is DISCARDED: a non-final statement, any
        #                loop-body statement, an `ensure` body statement.
        #   :unknown   — honestly unclassifiable HERE. Exactly two irreducible
        #                cases, both decided by a caller this scan is not
        #                allowed to look at: the implicit def tail (the method's
        #                last expression, consumed by whoever called the method)
        #                and a block/lambda tail (consumed, or not, by the
        #                iterator receiving the block).
        #
        # ABSENT OVER FABRICATED: nothing here ever guesses. A position nobody
        # reasoned about degrades to :unknown and is COUNTED, never silently
        # assigned a class.
        #
        # WHY A HAND-ROLLED WALKER AND NOT A Prism::Visitor SUBCLASS: the rules
        # are PULL-shaped, not PUSH-shaped — a StatementsNode's last child
        # INHERITS the enclosing context while its siblings are :effect, an
        # AndNode's right operand inherits while its left is :predicate. A
        # visitor's dispatch hands a `visit_call_node` no parent context at all,
        # so expressing "inherit" on it would mean replacing every blanket
        # `super` with hand-written per-child descent. Recursion with an
        # explicit context parameter says the same thing directly.
        #
        # SCOPE: classification STOPS at a nested DefNode (an inner def is its
        # own scope and gets its own scan) — the same stop discipline as
        # EscapeScanner#visit_def_node and OutcomeArityCounter.
        class UsageWalker
          # THE CLOSED VOCABULARY. Nothing else ever escapes `classify`.
          CLASSES = %i[value predicate effect unknown].freeze

          # The two irreducible non-local cases, kept DISTINCT through
          # propagation (so a future diagnostic can report WHICH one produced an
          # unknown) and normalized to :unknown at record time.
          UNKNOWN_SEEDS = %i[unknown_def_tail unknown_block_tail].freeze

          # A context that is not a usage class at all: a parameter TARGET (the
          # bound name), as opposed to a parameter's default VALUE. Carried so
          # the parameter rules read symmetrically; no CallNode is ever recorded
          # under it.
          PARAMS = :params

          PLAIN_WRITES = [
            Prism::LocalVariableWriteNode, Prism::InstanceVariableWriteNode,
            Prism::ClassVariableWriteNode, Prism::GlobalVariableWriteNode,
            Prism::ConstantWriteNode, Prism::ConstantPathWriteNode
          ].freeze

          OR_WRITES = [
            Prism::LocalVariableOrWriteNode, Prism::InstanceVariableOrWriteNode,
            Prism::ClassVariableOrWriteNode, Prism::GlobalVariableOrWriteNode,
            Prism::ConstantOrWriteNode, Prism::ConstantPathOrWriteNode,
            Prism::IndexOrWriteNode, Prism::CallOrWriteNode
          ].freeze

          AND_WRITES = [
            Prism::LocalVariableAndWriteNode, Prism::InstanceVariableAndWriteNode,
            Prism::ClassVariableAndWriteNode, Prism::GlobalVariableAndWriteNode,
            Prism::ConstantAndWriteNode, Prism::ConstantPathAndWriteNode,
            Prism::IndexAndWriteNode, Prism::CallAndWriteNode
          ].freeze

          OPERATOR_WRITES = [
            Prism::LocalVariableOperatorWriteNode, Prism::InstanceVariableOperatorWriteNode,
            Prism::ClassVariableOperatorWriteNode, Prism::GlobalVariableOperatorWriteNode,
            Prism::ConstantOperatorWriteNode, Prism::ConstantPathOperatorWriteNode,
            Prism::IndexOperatorWriteNode, Prism::CallOperatorWriteNode
          ].freeze

          WRITES = (PLAIN_WRITES + OR_WRITES + AND_WRITES + OPERATOR_WRITES).freeze

          # Classify every CallNode reachable from `node` WITHOUT crossing a
          # nested DefNode.
          #
          # `node` may be a DefNode (plain defs — receiver + parameters + body
          # are all walked, so an optional parameter's default expression is
          # classified too; it is already a recorded edge today), a CallNode
          # (the Grape verb / Rake task block-mint seams, where the handler body
          # IS the method scope), or any body node. Nil-safe.
          #
          # `seed` is the context the scope's own TAIL is consumed at. For a def
          # that is :unknown_def_tail — the implicit return's consumer is the
          # caller. For a block-mint seam it is :effect: the framework calls the
          # verb/task for its side effects and discards the declaration's value.
          #
          # @return [Hash{Integer => Symbol}] Prism node_id => usage class,
          #   one entry per CallNode. A scope with no call sites yields {} —
          #   never a fabricated entry.
          def self.classify(node, seed:)
            return {} if node.nil?

            walker = new
            walker.walk_scope(node, seed)
            walker.usages
          end

          attr_reader :usages

          def initialize
            # Prism::Node#node_id is unique within a parse tree and SURVIVES a
            # Marshal round-trip — which matters because the speed cache stores
            # marshaled ASTs, so a cache-hit path must produce the same keys a
            # fresh parse does. (Prism nodes define no value ==/hash, so object
            # identity would work too; node_id is chosen because it is explicit,
            # cheap, and immune to a future Prism release adding structural
            # equality.)
            @usages = {}
          end

          # Entry: walk one fresh method scope from `seed`.
          def walk_scope(node, seed)
            if node.is_a?(Prism::DefNode)
              # `def (expr).foo` — the singleton-def receiver expression is
              # consumed as the object being extended, so :value like any other
              # receiver position.
              walk(node.receiver, :value) if node.receiver
              walk(node.parameters, PARAMS) if node.parameters
              walk(node.body, seed)
            else
              walk(node, seed)
            end
          end

          private

          def record(node, ctx)
            @usages[node.node_id] = UNKNOWN_SEEDS.include?(ctx) || !CLASSES.include?(ctx) ? :unknown : ctx
          end

          # rubocop-free hand dispatch. `ctx` is one of CLASSES, UNKNOWN_SEEDS,
          # or PARAMS.
          def walk(node, ctx) # rubocop:disable Metrics/CyclomaticComplexity
            return if node.nil?

            case node
            when Prism::CallNode             then walk_call(node, ctx)
            when Prism::StatementsNode       then walk_statements(node, ctx)

            # ---- pass-through wrappers: position == the outer ctx ----
            when Prism::ParenthesesNode      then walk(node.body, ctx)
            when Prism::ElseNode             then walk(node.statements, ctx)

            when Prism::IfNode               then walk_if(node, ctx)
            when Prism::UnlessNode           then walk_unless(node, ctx)
            when Prism::CaseNode             then walk_case(node, ctx)
            when Prism::CaseMatchNode        then walk_case_match(node, ctx)
            when Prism::WhenNode             then walk_when(node, ctx)
            when Prism::InNode               then walk_in(node, ctx)
            when Prism::PinnedExpressionNode then walk(node.expression, :predicate)

            # `&&`/`||`: the LEFT operand is always tested for truthiness; the
            # RIGHT operand's value IS the expression's value when reached, so
            # it inherits.
            when Prism::AndNode, Prism::OrNode
              walk(node.left, :predicate)
              walk(node.right, ctx)

            # Both halves can produce the expression's value, so both face the
            # same consumer.
            when Prism::RescueModifierNode
              walk(node.expression, ctx)
              walk(node.rescue_expression, ctx)

            # ---- loop / ensure: the body's own tail is deterministically
            #      discarded REGARDLESS of the outer ctx. This is a resolved
            #      local case, not a pass-through. ----
            when Prism::WhileNode, Prism::UntilNode
              walk(node.predicate, :predicate)
              walk_all_effect(node.statements)

            when Prism::ForNode
              walk(node.collection, :value)
              walk_all_effect(node.statements)

            when Prism::BeginNode            then walk_begin(node, ctx)
            when Prism::RescueNode           then walk_rescue(node, ctx)
            when Prism::EnsureNode           then walk_all_effect(node.statements)

            # An explicit `return`'s argument is NEVER discarded, even in
            # non-final statement position — it overrides the positional ctx.
            when Prism::ReturnNode           then walk_argument_list(node.arguments)
            when Prism::YieldNode            then walk_argument_list(node.arguments)

            # ---- assignment families: the RHS is :value; a receiver / index
            #      argument on an op-assign target is consumed as data too ----
            when *WRITES                     then walk_write(node)
            when Prism::MultiWriteNode       then walk(node.value, :value)

            # ---- data containers: every element is :value ----
            when Prism::ArgumentsNode        then node.arguments.each { |a| walk(a, :value) }
            when Prism::ArrayNode            then node.elements.each { |e| walk(e, :value) }
            when Prism::HashNode, Prism::KeywordHashNode
              node.elements.each { |e| walk(e, :value) }
            when Prism::AssocNode
              walk(node.key, :value)
              walk(node.value, :value)
            when Prism::AssocSplatNode       then walk(node.value, :value)
            when Prism::SplatNode            then walk(node.expression, :value)

            # ---- interpolation: the embedded tail becomes part of the literal,
            #      so it is :value regardless of the literal's own ctx ----
            when Prism::InterpolatedStringNode, Prism::InterpolatedSymbolNode,
                 Prism::InterpolatedXStringNode, Prism::InterpolatedRegularExpressionNode
              node.parts.each { |p| walk(p, :value) }
            when Prism::EmbeddedStatementsNode
              walk_statements_forcing_tail(node.statements, :value)

            # ---- parameters: a default expression becomes the bound param's
            #      value, so :value. The default IS already a recorded edge
            #      today (visit_def_node descends into parameters), so leaving
            #      it out would blow a hole in the totality gate. ----
            when Prism::ParametersNode       then walk_parameters(node)
            when Prism::OptionalParameterNode, Prism::OptionalKeywordParameterNode
              walk(node.value, :value)

            # ---- nested def: its own scope, its own scan ----
            when Prism::DefNode              then nil

            # ---- block / lambda: non-tail statements are discarded; the TAIL
            #      escapes to an iterator we cannot see locally ----
            when Prism::BlockNode, Prism::LambdaNode
              walk(node.parameters, PARAMS) if node.parameters
              walk(node.body, :unknown_block_tail)

            else
              walk_default(node)
            end
          end

          # THE DEFAULT — DESCEND, never stop.
          #
          # Stopping here would be a silent edge-dropper: SuperNode,
          # ForwardingSuperNode, DefinedNode, RangeNode, SingletonClassNode,
          # MatchRequiredNode and a class/module body nested inside a def all
          # carry CallNodes that the resolution walk DOES record. A no-op
          # default would leave those sites with no map entry at all, which the
          # totality gate would then have to tolerate.
          #
          # Descending at :unknown is the honest degradation: the call is still
          # reachable and classified, and the class says exactly what is true —
          # nobody has reasoned about this position yet.
          def walk_default(node)
            return unless node.respond_to?(:compact_child_nodes)

            node.compact_child_nodes.each { |child| walk(child, :unknown) }
          end

          def walk_call(node, ctx)
            record(node, ctx)

            if node.receiver
              # `!x` and `not x` BOTH parse to CallNode(name: :!, receiver: x).
              # The receiver's TRUTHINESS is tested rather than consumed as
              # data — the one receiver position that is :predicate. A safe
              # navigation receiver (`a&.b`) is unaffected: still :value.
              bang = node.name == :! && node.arguments.nil?
              walk(node.receiver, bang ? :predicate : :value)
            end

            walk(node.arguments, :value) if node.arguments
            walk_call_block(node.block) if node.block
          end

          def walk_call_block(block)
            case block
            when Prism::BlockNode
              walk(block.parameters, PARAMS) if block.parameters
              walk(block.body, :unknown_block_tail)
            when Prism::BlockArgumentNode
              walk(block.expression, :value) if block.expression
            end
          end

          def walk_if(node, ctx)
            walk(node.predicate, :predicate)
            walk(node.statements, ctx)
            walk(node.subsequent, ctx) if node.subsequent
          end

          def walk_unless(node, ctx)
            walk(node.predicate, :predicate)
            walk(node.statements, ctx)
            walk(node.else_clause, ctx) if node.else_clause
          end

          def walk_case(node, ctx)
            walk(node.predicate, :predicate)
            node.conditions.each { |w| walk(w, ctx) }
            walk(node.else_clause, ctx) if node.else_clause
          end

          def walk_when(node, ctx)
            node.conditions.each { |c| walk(c, :predicate) }
            walk(node.statements, ctx)
          end

          def walk_case_match(node, ctx)
            walk(node.predicate, :predicate)
            node.conditions.each { |i| walk(i, ctx) }
            walk(node.else_clause, ctx) if node.else_clause
          end

          def walk_in(node, ctx)
            # A pattern GUARD is represented as the pattern itself being an
            # IfNode, and a pin as a PinnedExpressionNode — both are handled by
            # recursing at :predicate, no special case needed.
            walk(node.pattern, :predicate)
            walk(node.statements, ctx)
          end

          def walk_rescue(node, ctx)
            # `rescue Foo` matches via `===` — the same truthiness-test family
            # as a `when` condition.
            node.exceptions.each { |e| walk(e, :predicate) }
            walk(node.statements, ctx)
            walk(node.subsequent, ctx) if node.subsequent
          end

          def walk_begin(node, ctx)
            if node.else_clause
              # With an `else` clause present the body's own tail is NOT the
              # begin's value: control reaches `else` only on success, and it is
              # `else`'s tail that propagates.
              walk_all_effect(node.statements)
              walk(node.else_clause, ctx)
            else
              walk(node.statements, ctx)
            end
            walk(node.rescue_clause, ctx) if node.rescue_clause
            # EnsureNode forces its own all-effect walk internally.
            walk(node.ensure_clause, ctx) if node.ensure_clause
          end

          def walk_write(node)
            walk(node.receiver, :value) if node.respond_to?(:receiver) && node.receiver
            walk(node.arguments, :value) if node.respond_to?(:arguments) && node.arguments
            walk(node.value, :value) if node.respond_to?(:value) && node.value
          end

          # EVERY child, not just the optionals: a parameter kind this table has
          # no rule for still reaches walk_default and descends at :unknown
          # rather than being dropped. The two rows that DO have a rule —
          # OptionalParameterNode / OptionalKeywordParameterNode — are picked
          # out by their own `when` branch, which ignores the ctx handed in.
          def walk_parameters(node)
            node.compact_child_nodes.each { |p| walk(p, PARAMS) }
          end

          def walk_argument_list(arguments)
            arguments&.arguments&.each { |a| walk(a, :value) }
          end

          def walk_statements(stmts, ctx)
            body = stmts.body
            return if body.empty?

            body[0..-2].each { |s| walk(s, :effect) }
            walk(body.last, ctx)
          end

          def walk_statements_forcing_tail(stmts, forced)
            return if stmts.nil?

            body = stmts.body
            return if body.empty?

            body[0..-2].each { |s| walk(s, :effect) }
            walk(body.last, forced)
          end

          def walk_all_effect(stmts)
            return if stmts.nil?

            stmts.body.each { |s| walk(s, :effect) }
          end
        end
      end
    end
  end
end
