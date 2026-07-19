# frozen_string_literal: true

require "prism"
require "set"

module Archbuddy
  module Collect
    module Adapters
      module Ruby
        # Layer-1 outcome-class extraction (v0.12, L16): computes the
        # caller-visible OUTCOME-CLASS SET of a method body over the fixed
        # five-class taxonomy {VALUE, NIL, TRUE, FALSE, RAISE}. The taxonomy
        # IS the cap (k = 5; measured max on 17k real defs is 4).
        #
        # API mirrors BranchCounter.count: class method, fresh instance per
        # body, nil-safe. Stored on MethodEntry#outcome_classes; consumed by
        # the Layer-2 ArityResolver fixpoint (which substitutes the symbolic
        # [:ref, name] tokens) and, from there, by graph emission.
        #
        # Token vocabulary:
        #   :value :nil :true :false :raise  — the five taxonomy classes
        #   [:ref, name]   — bare self-call tail; a Layer-2 seam (the
        #                    ArityResolver substitutes the callee's final
        #                    class set; leftover refs fold to :value)
        #   [:ivar, name]  — ivar-read tail; resolved AT FINALIZATION (here,
        #                    intra-def) to the union of classes assigned to
        #                    that ivar in this def; never assigned → :value
        #   :unresolved    — unhandled node kind at a tail. NEVER guessed
        #                    (L10/L17 never-fabricate): final arity = nil →
        #                    the field stays ABSENT downstream.
        #
        # Exit set (rule 1): implicit body tail ∪ every explicit `return`
        # (the walk descends into blocks — a block's `return` exits the
        # method; STOPS at nested DefNode — the BranchCounter stop; a
        # LambdaNode's own `return` is NOT a method return, but lambdas ARE
        # walked for raise evidence) ∪ raise evidence (any bare raise/fail
        # not lexically inside a rescue-guarded begin body; a raise in a
        # rescue clause body still counts).
        #
        # Prism 1.9.0 vocabulary note: there is no StringConcatNode in 1.9.0
        # (adjacent string literals parse as InterpolatedStringNode → VALUE);
        # the visitor is written against the 1.9.0 node vocabulary ONLY, and
        # any genuinely unhandled kind at a tail falls to :unresolved.
        class OutcomeArityCounter
          TAXONOMY = %i[value nil true false raise].freeze

          RAISE_NAMES = %w[raise fail].freeze

          def self.classes(body)
            new(body).classes
          end

          # THE arity derivation — one spelling, shared with the Layer-2
          # ArityResolver (which calls it after REF substitution):
          # arity = |taxonomy ∩ set| after folding leftover symbolic tokens
          # (ref/ivar) to :value; any :unresolved → nil (field ABSENT
          # downstream — never a guessed value, never 0). Floor ≥ 1 holds by
          # construction (an empty exit set is impossible: a nil body is
          # `{:nil}`, a raise-only body is `{:raise}`).
          def self.arity(tokens)
            return nil if tokens.nil? || tokens.include?(:unresolved)

            core = tokens.map { |t| t.is_a?(::Array) ? :value : t }
            (TAXONOMY & core).size
          end

          def initialize(body)
            @body = body
          end

          def classes
            return [:nil] if @body.nil? # empty body returns nil — truthful, floor 1

            evidence = EvidenceWalker.new
            evidence.visit(@body)

            tokens = Set.new
            tokens.merge(Classifier.tail_classes(@body, guarded: false))
            tokens.merge(evidence.return_tokens)
            tokens << :raise if evidence.raise?

            finalize_ivars(tokens, evidence.ivar_classes).to_a
          end

          private

          # Finalization: substitute [:ivar, name] tokens with the union of
          # classes assigned to that ivar IN THIS def (exact memo-guard
          # collapsing). Never assigned in-def → opaque :value. [:ref, ...]
          # tokens survive (the Layer-2 seam).
          def finalize_ivars(tokens, ivar_map)
            out = Set.new
            tokens.each do |t|
              if t.is_a?(::Array) && t.first == :ivar
                out.merge(resolve_ivar(t.last, ivar_map, Set.new))
              else
                out << t
              end
            end
            out
          end

          def resolve_ivar(name, map, seen)
            return Set[:value] if seen.include?(name) # ivar-chain cycle → opaque

            assigned = map[name]
            return Set[:value] if assigned.nil? || assigned.empty?

            seen << name
            out = Set.new
            assigned.each do |t|
              if t.is_a?(::Array) && t.first == :ivar
                out.merge(resolve_ivar(t.last, map, seen))
              else
                out << t
              end
            end
            out
          end

          # Recursive tail/expression classifier (rules 2–9). `guarded:` is
          # true while lexically inside a rescue-guarded begin BODY: a raise
          # there transfers control to a rescue arm (whose tail is already in
          # the exit set) and contributes nothing.
          module Classifier
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

            PLAIN_WRITES = [
              Prism::LocalVariableWriteNode, Prism::InstanceVariableWriteNode,
              Prism::ClassVariableWriteNode, Prism::GlobalVariableWriteNode,
              Prism::ConstantWriteNode, Prism::ConstantPathWriteNode
            ].freeze

            OPERATOR_WRITES = [
              Prism::LocalVariableOperatorWriteNode, Prism::InstanceVariableOperatorWriteNode,
              Prism::ClassVariableOperatorWriteNode, Prism::GlobalVariableOperatorWriteNode,
              Prism::ConstantOperatorWriteNode, Prism::ConstantPathOperatorWriteNode,
              Prism::IndexOperatorWriteNode, Prism::CallOperatorWriteNode
            ].freeze

            # Rule 8: literal / provably-value node kinds → VALUE. Everything
            # NOT enumerated anywhere in the classifier → :unresolved (rule 9).
            VALUE_NODES = [
              Prism::StringNode, Prism::InterpolatedStringNode,
              Prism::SymbolNode, Prism::InterpolatedSymbolNode,
              Prism::IntegerNode, Prism::FloatNode,
              Prism::RationalNode, Prism::ImaginaryNode,
              Prism::ArrayNode, Prism::HashNode, Prism::KeywordHashNode,
              Prism::RegularExpressionNode, Prism::InterpolatedRegularExpressionNode,
              Prism::RangeNode, Prism::LambdaNode,
              Prism::ConstantReadNode, Prism::ConstantPathNode,
              Prism::LocalVariableReadNode, Prism::ClassVariableReadNode,
              Prism::GlobalVariableReadNode, Prism::BackReferenceReadNode,
              Prism::NumberedReferenceReadNode,
              Prism::SelfNode, Prism::SuperNode, Prism::ForwardingSuperNode,
              Prism::DefinedNode, Prism::DefNode,
              Prism::SourceFileNode, Prism::SourceLineNode, Prism::SourceEncodingNode,
              Prism::XStringNode, Prism::InterpolatedXStringNode,
              Prism::MatchLastLineNode, Prism::InterpolatedMatchLastLineNode
            ].freeze

            module_function

            def tail_classes(node, guarded:)
              case node
              when nil then Set[:nil] # empty arm / empty body → implicit nil
              when Prism::StatementsNode
                return Set[:nil] if node.body.empty?

                tail_classes(node.body.last, guarded: guarded)
              when Prism::ParenthesesNode
                tail_classes(node.body, guarded: guarded)
              when Prism::BeginNode
                begin_tail(node, guarded: guarded)
              when Prism::IfNode
                tail_classes(node.statements, guarded: guarded) |
                  (node.subsequent ? tail_classes(node.subsequent, guarded: guarded) : Set[:nil])
              when Prism::UnlessNode
                tail_classes(node.statements, guarded: guarded) |
                  (node.else_clause ? tail_classes(node.else_clause, guarded: guarded) : Set[:nil])
              when Prism::ElseNode
                tail_classes(node.statements, guarded: guarded)
              when Prism::CaseNode, Prism::CaseMatchNode
                arms = node.conditions.map { |c| tail_classes(c.statements, guarded: guarded) }
                arms << (node.else_clause ? tail_classes(node.else_clause, guarded: guarded) : Set[:nil])
                arms.reduce(Set.new, :|)
              when Prism::WhileNode, Prism::UntilNode, Prism::ForNode
                Set[:nil]
              when Prism::ReturnNode
                return_classes(node, guarded: guarded)
              when Prism::AndNode
                # a && b → {NIL} ∪ classes(b) (documented approximation:
                # an opaque falsy lhs folds to NIL)
                Set[:nil] | tail_classes(node.right, guarded: guarded)
              when Prism::OrNode
                truthy(tail_classes(node.left, guarded: guarded)) |
                  tail_classes(node.right, guarded: guarded)
              when Prism::RescueModifierNode
                tail_classes(node.expression, guarded: true) |
                  tail_classes(node.rescue_expression, guarded: guarded)
              when *PLAIN_WRITES
                tail_classes(node.value, guarded: guarded) # classify by RHS
              when *OR_WRITES
                # x ||= e → {VALUE} ∪ classes(e) (prior truthy value or e)
                Set[:value] | tail_classes(node.value, guarded: guarded)
              when *AND_WRITES
                Set[:nil] | tail_classes(node.value, guarded: guarded)
              when *OPERATOR_WRITES
                Set[:value]
              when Prism::MultiWriteNode
                Set[:value] # evaluates to the RHS array
              when Prism::CallNode
                call_classes(node, guarded: guarded)
              when Prism::InstanceVariableReadNode
                Set[[:ivar, node.name]]
              when Prism::NilNode then Set[:nil]
              when Prism::TrueNode then Set[:true]
              when Prism::FalseNode then Set[:false]
              when Prism::YieldNode then Set[:value] # the block's value — opaque
              when *VALUE_NODES then Set[:value]
              else
                Set[:unresolved] # rule 9 — unknown kind, never guessed
              end
            end

            def return_classes(node, guarded:)
              args = node.arguments&.arguments
              return Set[:nil] if args.nil? || args.empty?
              return Set[:value] if args.size > 1 # `return a, b` → array

              tail_classes(args.first, guarded: guarded)
            end

            def call_classes(node, guarded:)
              return Set[:nil, :value] if node.safe_navigation? # provably nil-or-value

              if raise_call?(node)
                # Unguarded raise is a caller-visible outcome; a rescue-guarded
                # raise transfers to a rescue arm and contributes nothing.
                return guarded ? Set.new : Set[:raise]
              end

              if node.receiver.nil?
                Set[[:ref, node.name]] # bare self-call — the Layer-2 seam
              else
                Set[:value] # opaque receiver'd call
              end
            end

            def raise_call?(node)
              node.receiver.nil? && RAISE_NAMES.include?(node.name.to_s)
            end

            # begin/rescue tails: else-clause tail REPLACES the begin tail;
            # EVERY rescue-clause tail contributes (rescue-body returns). The
            # begin body is rescue-guarded (raises there are caught); else and
            # rescue bodies are not (they run unprotected by THIS rescue).
            def begin_tail(node, guarded:)
              body_guarded = guarded || !node.rescue_clause.nil?
              out =
                if node.else_clause
                  tail_classes(node.else_clause, guarded: guarded)
                else
                  tail_classes(node.statements, guarded: body_guarded)
                end
              clause = node.rescue_clause
              while clause
                out |= tail_classes(clause.statements, guarded: guarded)
                clause = clause.subsequent
              end
              out
            end

            def truthy(set)
              set - [:nil, :false]
            end
          end

          # Whole-body evidence walk: explicit returns (descending into
          # blocks; NOT lambda-own returns), unguarded raise evidence
          # (including inside lambdas), and per-ivar assignment classes for
          # finalization. Stops at nested DefNode (an inner def is its own
          # MethodEntry — the BranchCounter stop discipline).
          class EvidenceWalker < Prism::Visitor
            attr_reader :return_tokens, :ivar_classes

            def initialize
              @return_tokens = Set.new
              @ivar_classes  = Hash.new { |h, k| h[k] = Set.new }
              @raise         = false
              @lambda_depth  = 0
              @rescue_depth  = 0
              super()
            end

            def raise?
              @raise
            end

            # STOP: an inner def gets its own entry — do NOT descend.
            def visit_def_node(node); end

            # A lambda's own `return` is not a method return; still walk it
            # for the raise/ivar evidence set.
            def visit_lambda_node(node)
              @lambda_depth += 1
              begin
                super
              ensure
                @lambda_depth -= 1
              end
            end

            def visit_return_node(node)
              if @lambda_depth.zero?
                @return_tokens.merge(
                  Classifier.return_classes(node, guarded: @rescue_depth.positive?)
                )
              end
              super
            end

            def visit_begin_node(node)
              if node.rescue_clause
                @rescue_depth += 1
                begin
                  visit(node.statements) if node.statements
                ensure
                  @rescue_depth -= 1
                end
                visit(node.rescue_clause)
                visit(node.else_clause) if node.else_clause
                visit(node.ensure_clause) if node.ensure_clause
              else
                super
              end
            end

            def visit_rescue_modifier_node(node)
              @rescue_depth += 1
              begin
                visit(node.expression)
              ensure
                @rescue_depth -= 1
              end
              visit(node.rescue_expression)
            end

            def visit_call_node(node)
              if Classifier.raise_call?(node) && @rescue_depth.zero?
                @raise = true # guard shapes (`raise X if cond`) anywhere count
              end
              super
            end

            def visit_instance_variable_write_node(node)
              record_ivar(node.name, Classifier.tail_classes(node.value, guarded: guarded?))
              super
            end

            def visit_instance_variable_or_write_node(node)
              record_ivar(node.name, Set[:value] | Classifier.tail_classes(node.value, guarded: guarded?))
              super
            end

            def visit_instance_variable_and_write_node(node)
              record_ivar(node.name, Set[:nil] | Classifier.tail_classes(node.value, guarded: guarded?))
              super
            end

            def visit_instance_variable_operator_write_node(node)
              record_ivar(node.name, Set[:value])
              super
            end

            private

            def guarded?
              @rescue_depth.positive?
            end

            def record_ivar(name, tokens)
              @ivar_classes[name].merge(tokens)
            end
          end
        end
      end
    end
  end
end
