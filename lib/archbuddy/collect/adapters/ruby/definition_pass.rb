# frozen_string_literal: true

require "prism"
require_relative "symbol_table"

module Archbuddy
  module Collect
    module Adapters
      module Ruby
        # Pass 1 (D23): walk class/module/def nodes building a SymbolTable of
        # fully-qualified symbols plus class metadata (superclass, controller?,
        # active_record?). Receiver shape is read here only to classify a def as
        # singleton (`Foo.x`) vs instance (`Foo#x`).
        #
        # One pass instance per file; the same SymbolTable is shared across files
        # so cross-file resolution works in Pass 2.
        class DefinitionPass < Prism::Visitor
          def initialize(symbol_table, rel_file)
            @table     = symbol_table
            @rel_file  = rel_file
            @namespace = [] # stack of constant name segments (e.g. ["Billing", "Invoice"])
            super()
          end

          def visit_module_node(node)
            name = constant_name(node.constant_path)
            push_namespace(name) do
              register_class(node, superclass: nil)
              super
            end
          end

          def visit_class_node(node)
            name = constant_name(node.constant_path)
            push_namespace(name) do
              register_class(node, superclass: node.superclass && constant_name(node.superclass))
              super
            end
          end

          def visit_def_node(node)
            singleton = !node.receiver.nil?
            owner_fq  = current_namespace
            sep       = singleton ? "." : "#"
            # A top-level def (no enclosing class) is owner-less; its fq symbol is
            # just the bare method name so resolution can still reference it.
            fq_symbol =
              if owner_fq.empty?
                node.name.to_s
              else
                "#{owner_fq}#{sep}#{node.name}"
              end

            counter = BranchCounter.count(node.body)

            @table.add_method(
              SymbolTable::MethodEntry.new(
                fq_symbol: fq_symbol,
                owner_fq:  owner_fq.empty? ? nil : owner_fq,
                name:      node.name.to_s,
                singleton: singleton,
                rel_file:  @rel_file,
                line:      node.location.start_line,
                branches:  counter.branches,
                decisions: counter.decisions
              )
            )
            super
          end

          private

          def register_class(node, superclass:)
            fq = current_namespace
            return if fq.empty?

            @table.add_class(
              SymbolTable::ClassEntry.new(
                fq_name:    fq,
                rel_file:   @rel_file,
                line:       node.location.start_line,
                superclass: superclass
              )
            )
          end

          def push_namespace(name)
            @namespace.push(name)
            yield
          ensure
            @namespace.pop
          end

          def current_namespace
            @namespace.join("::")
          end

          # Render a constant path/read node to its source name
          # (e.g. "Billing::Invoice", "ApplicationRecord").
          def constant_name(const_node)
            const_node.slice
          end
        end

        # Computes the two opaque per-method integers the cost model consumes
        # (P3+P9):
        #
        #   branches  b(n) = Π over decision points of arm-count — the TRUE total
        #                    number of execution paths through the body. A 5-arm
        #                    `case` contributes a factor of 5; two binary `if`s
        #                    contribute 2·2=4. Defaults to 1 (a straight-line
        #                    body has exactly one path).
        #   decisions d(n) = raw count of decision points (cyclomatic-style),
        #                    one per branching construct. Defaults to 0.
        #
        # Neither derives from the other (a 5-arm case: d=1, b=5), so both are
        # captured. Computation walks ONLY the given method body: it descends
        # into blocks (do..end / {}) but STOPS at a nested DefNode — an inner def
        # gets its own counts. An empty/nil body yields b=1, d=0.
        #
        # Arm-counts per construct:
        #   if/unless/while/until/for, &&/||, rescue-modifier, match-predicate
        #     (`x in Pat`), match-required (`x => Pat`)  ............ factor 2
        #   the `||=`/`&&=` operator-write family (8 target shapes ×2) factor 2
        #   safe navigation `x&.y` (CallNode#safe_navigation?)  ..... factor 2
        #   case / case-in  .... conditions.length (+1 when an else is present)
        #   begin/rescue  ...... 1 + (#rescue clauses) (+1 when an else present)
        class BranchCounter < Prism::Visitor
          # Operator-write nodes whose `||=`/`&&=` semantics introduce a binary
          # decision (assign-if-unset). The full family across target shapes:
          # local / instance / class / global / constant / constant-path /
          # index / call variable receivers, in both Or and And flavours.
          BINARY_OP_WRITE = [
            Prism::LocalVariableOrWriteNode, Prism::LocalVariableAndWriteNode,
            Prism::InstanceVariableOrWriteNode, Prism::InstanceVariableAndWriteNode,
            Prism::ClassVariableOrWriteNode, Prism::ClassVariableAndWriteNode,
            Prism::GlobalVariableOrWriteNode, Prism::GlobalVariableAndWriteNode,
            Prism::ConstantOrWriteNode, Prism::ConstantAndWriteNode,
            Prism::ConstantPathOrWriteNode, Prism::ConstantPathAndWriteNode,
            Prism::IndexOrWriteNode, Prism::IndexAndWriteNode,
            Prism::CallOrWriteNode, Prism::CallAndWriteNode
          ].freeze

          Counts = Struct.new(:branches, :decisions, keyword_init: true)

          # Maps a Prism node class to its visitor method suffix
          # (LocalVariableOrWriteNode -> "local_variable_or_write_node").
          def self.snake_case(klass)
            klass.name.split("::").last
                 .gsub(/([A-Z]+)([A-Z][a-z])/, '\1_\2')
                 .gsub(/([a-z\d])([A-Z])/, '\1_\2')
                 .downcase
          end

          def self.count(body)
            counter = new
            counter.visit(body) unless body.nil?
            Counts.new(branches: counter.branches, decisions: counter.decisions)
          end

          def initialize
            @product   = 1 # multiplicative path factor; seeds at 1 so a body with
            #                no decision points yields b=1 (one straight-line path)
            @decisions = 0
            super()
          end

          attr_reader :decisions

          def branches
            @product
          end

          # --- single-factor (binary) decision points ---------------------------
          # Each adds one decision and doubles the path count, then descends so
          # nested decision points inside the construct are also counted.
          %i[
            visit_if_node visit_unless_node visit_while_node visit_until_node
            visit_for_node visit_and_node visit_or_node visit_rescue_modifier_node
            visit_match_predicate_node visit_match_required_node
          ].each do |meth|
            define_method(meth) do |node|
              record(2)
              super(node)
            end
          end

          BINARY_OP_WRITE.each do |klass|
            define_method(:"visit_#{snake_case(klass)}") do |node|
              record(2)
              super(node)
            end
          end

          # `x&.y` — a safe-navigation call is a binary decision (short-circuits
          # on nil). A plain `x.y` call is not. Either way, descend.
          def visit_call_node(node)
            record(2) if node.safe_navigation?
            super
          end

          # --- multi-arm decision points ----------------------------------------
          # `case`/`case ... in`: one decision; arm count is the number of
          # when/in conditions, plus one for an else fall-through if present.
          def visit_case_node(node)
            record(arm_count(node))
            super
          end

          def visit_case_match_node(node)
            record(arm_count(node))
            super
          end

          # `begin/rescue/else`: one decision; arms = 1 (the happy path) + one per
          # rescue clause, plus one for an else fall-through if present.
          def visit_begin_node(node)
            arms = 1 + rescue_count(node) + (node.else_clause.nil? ? 0 : 1)
            record(arms)
            super
          end

          # STOP at a nested def — an inner method gets its own counts (it is
          # visited as its own MethodEntry by the DefinitionPass). Do NOT descend.
          def visit_def_node(node); end

          private

          def record(arm_count)
            @decisions += 1
            @product   *= arm_count
          end

          def arm_count(case_node)
            case_node.conditions.length + (case_node.else_clause.nil? ? 0 : 1)
          end

          def rescue_count(begin_node)
            n = 0
            clause = begin_node.rescue_clause
            while clause
              n += 1
              clause = clause.subsequent
            end
            n
          end
        end
      end
    end
  end
end
