# frozen_string_literal: true

require "prism"
require_relative "resolver"
require_relative "grape_dsl"
require_relative "db_op_spec"

module Archbuddy
  module Collect
    module Adapters
      module Ruby
        # Pass 2 (D23): walk call sites inside method bodies and, via the pure
        # RubyResolver, record directed call relationships into an Accumulator.
        #
        # The pass tracks the lexical context (enclosing class fq + current
        # method fq) so the resolver can consult class context (the AR gotcha)
        # and so each edge has a real "from" symbol.
        #
        # Accumulator collects findings in REAL symbol space; the RubyAdapter
        # turns them into Raw* value objects, and only the Anonymizer mints ids.
        class Accumulator
          # db_op / external targets discovered, keyed by their real symbol.
          #   db_ops:   { "Invoice.where" => {class_fq:, sink_open:} }
          #   externals flagged via the single sink (no per-target node).
          attr_reader :calls, :db_ops, :meta_sites, :probe_edges

          def initialize
            @calls       = []          # [{from_fq:, to:{type:, ...}}]
            @db_ops      = {}          # real_symbol => {class_fq:, sink_open:}
            @meta_sites  = []          # [{from_fq:, name:, line:}] (flagged, no edge)
            @probe_edges = Hash.new(0) # { probe_name(Symbol) => count } (diagnostics-only)
          end

          def tally_probe_edge(probe_name)
            @probe_edges[probe_name] += 1
          end

          def add_method_edge(from_fq, to_fq)
            @calls << { from_fq: from_fq, to: { type: :method, fq: to_fq } }
          end

          # db_ops collapse by Class.method (resolver db_op_symbol), so one node
          # fields many call sites. Aggregate the per-call sink spec as
          # LEAST-SPECIFIC-WINS (V4/P4): `sink_open` becomes true if ANY incoming
          # write call is open_ended — a sink that SOME caller can mass-assign is
          # customizable even if others are tidy (SAFE; never under-charges).
          # Reads / destroys / specific writes contribute false. Per G1/CR-3 only
          # this derived boolean is emitted on the graph node.
          def add_db_op_edge(from_fq, symbol, class_fq, spec)
            e = (@db_ops[symbol] ||= { class_fq: class_fq, sink_open: false })
            e[:sink_open] ||= spec.open_ended_write?
            @calls << { from_fq: from_fq, to: { type: :db_op, fq: symbol } }
          end

          def add_external_edge(from_fq)
            @calls << { from_fq: from_fq, to: { type: :external } }
          end

          def flag_metaprogramming(from_fq, name, line)
            @meta_sites << { from_fq: from_fq, name: name, line: line }
          end
        end

        class ResolutionPass < Prism::Visitor
          def initialize(symbol_table, accumulator, probes: [])
            @table     = symbol_table
            @acc       = accumulator
            @resolver  = RubyResolver.new(symbol_table, probes: probes)
            @namespace = []
            @method_stack = [] # fq symbols of enclosing methods
            # Grape handler-context tracking (W2) — MIRRORS DefinitionPass so the
            # endpoint FQ pushed here is byte-identical to the FQ minted there
            # (F5 ordinal parity): per-Pass-instance (per-file) state, same
            # source-order ordinals over the same parsed array in the same order.
            @grape_stack   = [] # class_fq strings of enclosing Grape::API classes
            @verb_ordinals = Hash.new(0) # [class_fq, verb] => next ordinal
            super()
          end

          def visit_module_node(node)
            push_namespace(node.constant_path.slice) { super }
          end

          def visit_class_node(node)
            superclass = node.superclass && node.superclass.slice
            push_namespace(node.constant_path.slice) do
              if GrapeDsl.grape_api_superclass?(superclass)
                @grape_stack.push(current_namespace)
                begin
                  super
                ensure
                  @grape_stack.pop
                end
              else
                super
              end
            end
          end

          def visit_def_node(node)
            owner_fq  = current_namespace
            singleton = !node.receiver.nil?
            sep       = singleton ? "." : "#"
            fq_symbol = owner_fq.empty? ? node.name.to_s : "#{owner_fq}#{sep}#{node.name}"

            @method_stack.push(fq_symbol)
            super
          ensure
            @method_stack.pop
          end

          def visit_call_node(node)
            # Grape handler context (W2 — the 277→0 fix). A Grape endpoint
            # verb-block has no DefNode, so without this its body calls would be
            # attributed to no caller and dropped. Open a synthetic method scope
            # for the block: push the SAME endpoint FQ DefinitionPass minted (F5
            # parity — identical per-(class,verb) source-order ordinal), walk the
            # block body so its calls record through the existing R2/R3/R4 tiers
            # via the generic path below, then pop. Returns early (the verb call
            # itself is the endpoint declaration, not an edge).
            if @grape_stack.last && GrapeDsl.endpoint_verb_call?(node)
              class_fq = @grape_stack.last
              verb     = node.name.to_s
              ordinal  = @verb_ordinals[[class_fq, verb]]
              @verb_ordinals[[class_fq, verb]] += 1

              @method_stack.push(GrapeDsl.endpoint_fq(class_fq, verb, ordinal))
              begin
                super # walk the handler block body; its calls record as edges
              ensure
                @method_stack.pop
              end
              return
            end

            from_fq = @method_stack.last
            # Only attribute calls that occur inside a known method body; calls at
            # class body / top level are not edges from a node (no caller node).
            if from_fq
              ctx = RubyResolver::CallContext.new(
                name:            node.name,
                receiver:        node.receiver,
                enclosing_class: current_namespace.empty? ? nil : current_namespace,
                table:           @table,
                node:            node
              )
              record(@resolver.resolve(ctx), from_fq, node)
            end
            super
          end

          private

          def record(resolution, from_fq, node)
            # Provenance tally is orthogonal to action dispatch: a probe-resolved
            # call is counted by probe name regardless of whether it emitted a
            # method edge or a db_op. Base-tier resolutions have provenance == nil
            # and are NOT tallied. Diagnostics-only — never reaches graph.yml.
            @acc.tally_probe_edge(resolution.provenance) if resolution.provenance
            case resolution.action
            when :drop
              # operator: nothing.
            when :metaprogramming
              @acc.flag_metaprogramming(from_fq, node.name.to_s, node.location.start_line)
            when :edge
              @acc.add_method_edge(from_fq, resolution.target_fq)
            when :external
              if resolution.kind == "db_op"
                # V4/P4: classify this AR call's effect/specificity from the
                # CallNode args to derive the sink's open_ended-write bit.
                spec = DbOpSpec.for_call(node)
                @acc.add_db_op_edge(from_fq, resolution.target_fq, enclosing_class_fq, spec)
              else
                @acc.add_external_edge(from_fq)
              end
            end
          end

          def enclosing_class_fq
            current_namespace.empty? ? nil : current_namespace
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
        end
      end
    end
  end
end
