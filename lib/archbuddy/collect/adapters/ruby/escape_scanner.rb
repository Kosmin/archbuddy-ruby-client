# frozen_string_literal: true

require "prism"
require_relative "vocab"

module Archbuddy
  module Collect
    module Adapters
      module Ruby
        # Escape detection (v0.12, L18): `escapes` is a property of the
        # CALLEE'S DEFINITION, never of a call site. A def escapes iff its
        # internal path-selection can run CALLER-SUPPLIED executable code
        # across the definition boundary:
        #
        #   1. `yield` anywhere in the body — including inside blocks AND
        #      inside lambdas (both yield the METHOD's block).
        #   2. a bare `block_given?` / `iterator?` check.
        #   3. a declared block param (`&blk` or anonymous `&`) that is USED:
        #      `blk.call`, or passed onward via a BlockArgumentNode.
        #      Declared-but-unused `&blk` is NOT an escape (a dead param
        #      provably never runs caller code).
        #   4. a caller-supplied callable invoked: `cb.call` where `cb` names
        #      a positional/optional/keyword parameter of THIS def.
        #   5. a dynamic meta-send — the resolver's `dynamic_meta?` shape
        #      re-expressed over the SHARED Vocab predicates: flagged
        #      metaprogramming UNLESS it is a resolvable dispatch verb with a
        #      literal Symbol/String arg (`send(:m)` is NOT an escape — the
        #      MetaSendProbe resolves it to a real edge).
        #
        # Stdlib non-escape discriminator is STRUCTURAL: `arr.each { }` is a
        # block-passing CALL SITE into an out-of-tree receiver — the receiver
        # method has no in-tree def, hence no node, hence nothing to flag.
        #
        # Pinned sub-rule (P2, L18 flag): type-dispatch on an own argument's
        # value/class via `case`/`when` (the prepare_variables shape) is NOT
        # an escape — no caller code runs inside the callee; b_own already
        # prices the fork and the return contract collapses it.
        #
        # The walk descends into blocks and lambdas and STOPS at a nested
        # DefNode (an inner def is its own entry).
        class EscapeScanner < Prism::Visitor
          BLOCK_CHECK_NAMES = %w[block_given? iterator?].freeze

          # `node` is a DefNode (plain defs: parameters + body) or a bare
          # body node (the endpoint/rake block-mint seams). Nil-safe.
          def self.escapes?(node)
            return false if node.nil?

            if node.is_a?(Prism::DefNode)
              scanner = new(parameters: node.parameters)
              scanner.visit(node.body) if node.body
              scanner.escapes?
            else
              scanner = new(parameters: nil)
              scanner.visit(node)
              scanner.escapes?
            end
          end

          def initialize(parameters:)
            @param_names      = callable_param_names(parameters)
            @block_param      = parameters&.block
            @block_param_name = @block_param&.name
            @escapes          = false
            super()
          end

          def escapes?
            @escapes
          end

          # STOP: an inner def is its own MethodEntry — never leaks evidence.
          def visit_def_node(node); end

          # Evidence 1: yield anywhere (blocks and lambdas included — the
          # default visitor descent covers both; only DefNode is stopped).
          def visit_yield_node(node)
            @escapes = true
            super
          end

          # Evidence 2 / 4 / 5 over call shapes.
          def visit_call_node(node)
            @escapes = true if block_check?(node) || callable_invocation?(node) || dynamic_meta_send?(node)
            super
          end

          # Evidence 3 (pass-through half): the declared block param forwarded
          # onward — `other(&blk)`, or anonymous `other(&)` when an anonymous
          # `&` param is declared. `other(&:sym)` / `other(&method(:m))` are
          # NOT caller-block forwards.
          def visit_block_argument_node(node)
            if @block_param
              expr = node.expression
              if expr.nil?
                @escapes = true # anonymous & forward
              elsif expr.is_a?(Prism::LocalVariableReadNode) && expr.name == @block_param_name
                @escapes = true
              end
            end
            super
          end

          private

          # Evidence 2: a bare block_given?/iterator? check.
          def block_check?(node)
            node.receiver.nil? && BLOCK_CHECK_NAMES.include?(node.name.to_s)
          end

          # Evidence 3 (call half) + 4: `.call` on a local read naming the
          # declared block param OR a positional/optional/keyword param.
          def callable_invocation?(node)
            return false unless node.name == :call
            return false unless node.receiver.is_a?(Prism::LocalVariableReadNode)

            name = node.receiver.name
            (!@block_param_name.nil? && name == @block_param_name) || @param_names.include?(name)
          end

          # Evidence 5: the resolver's dynamic_meta? shape over the SHARED
          # predicates — literal-arg resolvable dispatch is NOT an escape.
          def dynamic_meta_send?(node)
            name = node.name
            return false unless Vocab.metaprogramming?(name)
            return false if Vocab.meta_resolvable?(name) && Vocab.literal_dispatch_arg?(node)

            true
          end

          # Positional/optional/keyword parameter names a caller can bind a
          # callable to (rule 4). Rest/keyword-rest/block are excluded here
          # (the block param has its own rule-3 handling).
          def callable_param_names(parameters)
            return Set.new if parameters.nil?

            names = []
            parameters.requireds.each { |p| names << p.name if p.respond_to?(:name) }
            parameters.optionals.each { |p| names << p.name }
            parameters.posts.each     { |p| names << p.name if p.respond_to?(:name) }
            parameters.keywords.each  { |p| names << p.name }
            names.compact.to_set
          end
        end
      end
    end
  end
end
