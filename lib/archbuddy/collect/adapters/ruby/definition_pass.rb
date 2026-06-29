# frozen_string_literal: true

require "prism"
require_relative "symbol_table"
require_relative "grape_dsl"

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
            # Grape endpoint discovery (W2). Tracks whether we are lexically
            # inside a Grape::API subclass, and a PER-PASS-INSTANCE (per-file)
            # source-order ordinal per (class_fq, verb) so the minted endpoint FQ
            # is stable and matches the FQ Pass 2 pushes (F5 ordinal parity). The
            # adapter news a fresh DefinitionPass per file, so per-file reset is
            # symmetric with ResolutionPass.
            @grape_stack    = [] # class_fq strings of enclosing Grape::API classes
            @verb_ordinals  = Hash.new(0) # [class_fq, verb] => next ordinal
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
            name       = constant_name(node.constant_path)
            superclass = node.superclass && constant_name(node.superclass)
            push_namespace(name) do
              register_class(node, superclass: superclass)
              if GrapeDsl.grape_api_superclass?(superclass)
                @grape_stack.push(current_namespace)
                begin
                  super # walk nested resource/namespace blocks + helper defs
                ensure
                  @grape_stack.pop
                end
              else
                super
              end
            end
          end

          # Grape endpoint NODE discovery (W2). While inside a Grape::API
          # subclass, each `get/post/... do ... end` verb-block declares an
          # endpoint handler that has no DefNode — mint a synthetic endpoint
          # MethodEntry for it. Always `super` so calls nested inside
          # resource/namespace blocks (and helper defs) are still walked.
          def visit_call_node(node)
            mint_endpoint(node) if @grape_stack.last && GrapeDsl.endpoint_verb_call?(node)
            super
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

          # Mint one synthetic endpoint MethodEntry for a Grape verb-block. The
          # FQ is stamped with a per-(class,verb) source-order ordinal so it is
          # stable and IDENTICAL to the FQ ResolutionPass pushes for the same
          # block (F5). branches/decisions come from the BranchCounter over the
          # block body — the handler's path cost, same as a def body.
          def mint_endpoint(node)
            class_fq = @grape_stack.last
            verb     = node.name.to_s
            ordinal  = @verb_ordinals[[class_fq, verb]]
            @verb_ordinals[[class_fq, verb]] += 1

            fq_symbol = GrapeDsl.endpoint_fq(class_fq, verb, ordinal)
            counter   = BranchCounter.count(node.block&.body)

            @table.add_method(
              SymbolTable::MethodEntry.new(
                fq_symbol: fq_symbol,
                owner_fq:  class_fq,
                name:      "#{verb.upcase}[#{ordinal}]",
                singleton: false,
                rel_file:  @rel_file,
                line:      node.block&.location&.start_line || node.location.start_line,
                branches:  counter.branches,
                decisions: counter.decisions,
                endpoint:  true
              )
            )
          end

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
        # De-idiomatization (V7/P5): only BUSINESS control flow multiplies into
        # the `branches` product. Defensive/idiomatic constructs (`&&`/`||`,
        # safe-nav `&.`, the `||=`/`&&=` operator-write family, modifier+begin
        # `rescue`, pattern-match predicates) are still COUNTED in `decisions`
        # but DO NOT inflate `branches` — they pass `business: false` to `record`.
        #
        # Arm-counts per construct:
        #   if/unless/while/until/for  ..... factor 2 (BUSINESS — multiplies b)
        #   case / case-in  .... conditions.length (+1 when an else is present)
        #                        (BUSINESS — multiplies b)
        #   &&/||, rescue-modifier, match-predicate (`x in Pat`), match-required
        #     (`x => Pat`)  ................. factor 2 (IDIOM — decisions only)
        #   the `||=`/`&&=` operator-write family (8 target shapes ×2)
        #                                     factor 2 (IDIOM — decisions only)
        #   safe navigation `x&.y` (CallNode#safe_navigation?)
        #                                     factor 2 (IDIOM — decisions only)
        #   begin/rescue  ...... 1 + (#rescue clauses) (+1 when an else present)
        #                        (IDIOM — decisions only)
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

          # --- single-factor (binary) BUSINESS decision points -------------------
          # Each adds one decision and doubles the path count, then descends so
          # nested decision points inside the construct are also counted.
          %i[
            visit_if_node visit_unless_node visit_while_node visit_until_node
            visit_for_node
          ].each do |meth|
            define_method(meth) do |node|
              record(2)
              super(node)
            end
          end

          # --- single-factor (binary) IDIOM decision points (V7/P5) --------------
          # `&&`/`||` short-circuit guards, modifier `rescue`, and pattern-match
          # predicates are idioms: counted in `decisions` but NOT multiplied into
          # `branches`. Still descend so any nested business decision inside the
          # idiom (e.g. `x && (if d; …; end)`) still multiplies b.
          %i[
            visit_and_node visit_or_node visit_rescue_modifier_node
            visit_match_predicate_node visit_match_required_node
          ].each do |meth|
            define_method(meth) do |node|
              record(2, business: false)
              super(node)
            end
          end

          # The `||=`/`&&=` operator-write family is an idiom (assign-if-unset):
          # counted in `decisions`, NOT multiplied into `branches` (V7/P5).
          BINARY_OP_WRITE.each do |klass|
            define_method(:"visit_#{snake_case(klass)}") do |node|
              record(2, business: false)
              super(node)
            end
          end

          # `x&.y` — a safe-navigation call short-circuits on nil. An IDIOM under
          # V7/P5: counted in `decisions`, NOT multiplied into `branches`. A plain
          # `x.y` call is not a decision. Either way, descend.
          def visit_call_node(node)
            record(2, business: false) if node.safe_navigation?
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
          # rescue clause, plus one for an else fall-through if present. Defensive
          # `rescue` handling is an IDIOM under V7/P5: counted in `decisions`, NOT
          # multiplied into `branches`.
          def visit_begin_node(node)
            arms = 1 + rescue_count(node) + (node.else_clause.nil? ? 0 : 1)
            record(arms, business: false)
            super
          end

          # STOP at a nested def — an inner method gets its own counts (it is
          # visited as its own MethodEntry by the DefinitionPass). Do NOT descend.
          def visit_def_node(node); end

          private

          # The single mutation choke point (V7/P5). Every decision point bumps
          # `@decisions` (diagnostic count of ALL constructs); only BUSINESS
          # control flow (`business: true`, the default) multiplies the
          # `branches` product. Idiom constructs pass `business: false` so they
          # count toward `decisions` but never inflate `branches`.
          def record(arm_count, business: true)
            @decisions += 1
            @product   *= arm_count if business
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
