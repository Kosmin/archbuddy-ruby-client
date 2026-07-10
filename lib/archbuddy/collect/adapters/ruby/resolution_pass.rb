# frozen_string_literal: true

require "prism"
require_relative "resolver"
require_relative "grape_dsl"

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
          #   db_ops:   { "Invoice.where" => {class_fq:} }
          #   externals flagged via the single sink (no per-target node).
          attr_reader :calls, :db_ops, :meta_sites, :probe_edges,
                      :total_call_sites, :meta_resolved

          def initialize
            @calls       = []          # [{from_fq:, to:{type:, ...}}]
            @db_ops      = {}          # real_symbol => {class_fq:}
            @meta_sites  = []          # [{from_fq:, name:, line:}] (flagged, no edge)
            @probe_edges = Hash.new(0) # { probe_name(Symbol) => count } (diagnostics-only)
            # v0.10 W1-D coverage tallies (L21): the committed dynamic-dispatch
            # coverage tuple's denominator (every call site reaching #record)
            # and the meta-recovered numerator (MetaSendProbe edges).
            @total_call_sites = 0
            @meta_resolved    = 0
          end

          def tally_probe_edge(probe_name)
            @probe_edges[probe_name] += 1
          end

          def tally_call_site
            @total_call_sites += 1
          end

          def tally_meta_resolved
            @meta_resolved += 1
          end

          def add_method_edge(from_fq, to_fq)
            @calls << { from_fq: from_fq, to: { type: :method, fq: to_fq } }
          end

          # db_ops collapse by Class.method (resolver db_op_symbol), so one node
          # fields many call sites. A db_op is a plain COST-1 terminal (L3) — no
          # write-specificity / sink_open is derived or carried.
          def add_db_op_edge(from_fq, symbol, class_fq)
            @db_ops[symbol] ||= { class_fq: class_fq }
            @calls << { from_fq: from_fq, to: { type: :db_op, fq: symbol } }
          end

          def add_external_edge(from_fq)
            @calls << { from_fq: from_fq, to: { type: :external } }
          end

          def flag_metaprogramming(from_fq, name, line)
            @meta_sites << { from_fq: from_fq, name: name, line: line }
          end
        end

        # L1 pre-scan visitor (two-sub-pass). Walks ONE class body collecting,
        # for that class only:
        #   - ivar_types:       every `@x = Const.new` / `@x ||= Const.new`
        #   - accessor_returns: instance methods whose LAST statement returns a
        #                       `Const.new` (memoized accessor: `def svc; @svc
        #                       ||= Const.new; end`, plain `@x = Const.new`, or a
        #                       bare `Const.new`).
        # It does NOT descend into nested class/module bodies (each nested class
        # gets its own pre-scan from the main visitor) so ivars never leak across
        # class boundaries. Pure collector — never edges, never BranchCounter.
        class ClassTypeScanner < Prism::Visitor
          def initialize(ivar_types, accessor_returns, const_new_fq)
            @ivar_types       = ivar_types
            @accessor_returns = accessor_returns
            @const_new_fq     = const_new_fq
            super()
          end

          # Do NOT recurse into nested classes/modules — their ivars/accessors
          # belong to a different scope (handled by the main visitor's pre-scan).
          def visit_class_node(_node); end
          def visit_module_node(_node); end

          def visit_instance_variable_write_node(node)
            record_ivar(node.name.to_s, @const_new_fq.call(node.value))
            super
          end

          def visit_instance_variable_or_write_node(node)
            record_ivar(node.name.to_s, @const_new_fq.call(node.value))
            super
          end

          def visit_def_node(node)
            # Memoized / const-returning accessor: instance method (nil receiver)
            # whose last body statement evaluates to a `Const.new`.
            if node.receiver.nil?
              fq = accessor_return_fq(node)
              record_accessor(node.name.to_s, fq) if fq
            end
            super
          end

          private

          def record_ivar(name, fq)
            return if fq.nil?

            if @ivar_types.key?(name) && @ivar_types[name] != fq
              @ivar_types.delete(name) # conflict -> decline
            else
              @ivar_types[name] = fq
            end
          end

          def record_accessor(name, fq)
            if @accessor_returns.key?(name) && @accessor_returns[name] != fq
              @accessor_returns.delete(name) # conflict -> decline
            else
              @accessor_returns[name] = fq
            end
          end

          # The const FQ a method's LAST statement returns, when it is exactly a
          # `Const.new` produced by `@x ||= Const.new`, `@x = Const.new`, or a
          # bare `Const.new`. Guards the empty-body case (def x; end -> nil).
          def accessor_return_fq(node)
            body = node.body
            return nil if body.nil?

            # A method whose body is wrapped in `begin/rescue` (or carries a
            # `rescue`/`ensure` clause) parses as a Prism::BeginNode, whose
            # statements live under `.statements` (a StatementsNode), not `.body`.
            # A plain body is already a StatementsNode. Descend to the StatementsNode
            # before reading the last statement; decline on anything else.
            stmts =
              case body
              when Prism::StatementsNode then body
              when Prism::BeginNode      then body.statements
              end
            return nil if stmts.nil?

            last = stmts.body.last
            return nil if last.nil?

            case last
            when Prism::InstanceVariableOrWriteNode,
                 Prism::InstanceVariableWriteNode,
                 Prism::LocalVariableWriteNode,
                 Prism::LocalVariableOrWriteNode
              @const_new_fq.call(last.value)
            when Prism::CallNode
              @const_new_fq.call(last)
            end
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
            # Conservative intra-procedural type scope (L1). Per-Pass-instance
            # (per-file) lifecycle, symmetric with @verb_ordinals (F5) — NEVER
            # global. Records ONLY exact `Const.new` assignments so R4.5 can
            # resolve typed-receiver call sites to REAL edges via the existing
            # SymbolTable#method? gate (never fabricated).
            #   @local_types       => { "x" => "Const" } — reset per def / per
            #                         Grape verb-block (a fresh method scope).
            #   @ivar_types        => { class_fq => { "@x" => "Const" } } —
            #                         accumulated per class via the pre-scan.
            #   @accessor_returns  => { class_fq => { "svc" => "Const" } } —
            #                         memoized-accessor return types, per class.
            @local_types      = {}
            @ivar_types       = Hash.new { |h, k| h[k] = {} }
            @accessor_returns = Hash.new { |h, k| h[k] = {} }
            super()
          end

          def visit_module_node(node)
            push_namespace(node.constant_path.slice) { super }
          end

          def visit_class_node(node)
            superclass = node.superclass && node.superclass.slice
            push_namespace(node.constant_path.slice) do
              # TWO-SUB-PASS (L1, ledger watch-item a): pre-scan the WHOLE class
              # body to collect ivar + memoized-accessor-return types BEFORE the
              # resolving walk, so a reader method appearing in source BEFORE the
              # writer/accessor still sees the class-scoped types (source-order
              # independent). Pure type collection — never touches BranchCounter.
              prescan_class_types(node, current_namespace)

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
            # Locals never leak across methods (L1): reset on def entry. The
            # class-scoped ivar/accessor maps (built by the pre-scan) persist.
            @local_types = {}
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
              # A Grape verb-block is a fresh method scope (L1): reset locals.
              @local_types = {}
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
                node:            node,
                type_scope:      current_type_scope
              )
              record(@resolver.resolve(ctx), from_fq, node)
            end
            super
          end

          # L1 write-node collectors. Each records an exact `Const.new`
          # assignment into the appropriate type map, then calls super so the
          # normal walk (and any nested call sites) proceeds. Pure type-state
          # collectors — they MUST NOT touch BranchCounter (Pass 1 only). They
          # run during the resolving walk to keep @local_types current within a
          # def; the class-scoped ivar map is built by the pre-scan.
          def visit_local_variable_write_node(node)
            record_local_type(node.name.to_s, const_new_fq(node.value))
            super
          end

          def visit_instance_variable_write_node(node)
            record_ivar_type(node.name.to_s, const_new_fq(node.value))
            super
          end

          def visit_instance_variable_or_write_node(node)
            # `@x ||= Const.new` — OrWrite node (P1), the memoize idiom.
            record_ivar_type(node.name.to_s, const_new_fq(node.value))
            super
          end

          private

          def record(resolution, from_fq, node)
            # v0.10 W1-D coverage tallies (L21): denominator = every call site
            # that reached the pass inside a known method body (from_fq
            # guaranteed non-nil by the caller); numerator = call sites the
            # MetaSendProbe rewrote to a direct edge. Diagnostics-only.
            @acc.tally_call_site
            @acc.tally_meta_resolved if resolution.provenance == :meta_send
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
                # L3: a db_op is a plain COST-1 terminal — no sink spec derived.
                @acc.add_db_op_edge(from_fq, resolution.target_fq, enclosing_class_fq)
              else
                @acc.add_external_edge(from_fq)
              end
            end
          end

          def enclosing_class_fq
            current_namespace.empty? ? nil : current_namespace
          end

          # --- L1 type-scope helpers ------------------------------------------

          # The const FQ when `value_node` is EXACTLY `Const.new` /
          # `Const::Path.new` (a CallNode named :new whose receiver is a
          # ConstantReadNode/ConstantPathNode), else nil. The strict gate that
          # keeps L1 conservative: `Foo.build` (name :build) and any non-const
          # receiver decline. Shared by the write collectors and the pre-scan.
          def const_new_fq(value_node)
            return nil unless value_node.is_a?(Prism::CallNode)
            return nil unless value_node.name == :new

            recv = value_node.receiver
            case recv
            when Prism::ConstantReadNode, Prism::ConstantPathNode
              recv.slice
            end
          end

          # Record a local var's tracked type. Conditional-reassignment guard:
          # if the name is already tracked with a DIFFERENT const, drop it to
          # unknown (decline) rather than guess. A non-`Const.new` RHS (fq nil)
          # also clears any prior tracking for that name (reassigned away).
          def record_local_type(name, fq)
            if fq.nil?
              @local_types.delete(name)
            elsif @local_types.key?(name) && @local_types[name] != fq
              @local_types.delete(name)
            else
              @local_types[name] = fq
            end
          end

          # Record a class-scoped ivar's tracked type (current class). Same
          # conflict-decline discipline as locals.
          def record_ivar_type(name, fq)
            scope = @ivar_types[current_namespace]
            if fq.nil?
              scope.delete(name)
            elsif scope.key?(name) && scope[name] != fq
              scope.delete(name)
            else
              scope[name] = fq
            end
          end

          # The read-only merged view handed to R4.5 via ctx.type_scope: the
          # current method's locals OVERLAID on this class's ivar + accessor
          # maps. nil when nothing is tracked (degenerate: R4.5 declines for all
          # receivers → existing R9 <external>, never a fabricated edge).
          def current_type_scope
            cls    = current_namespace
            merged = {}
            merged.merge!(@accessor_returns[cls]) if @accessor_returns.key?(cls)
            merged.merge!(@ivar_types[cls])       if @ivar_types.key?(cls)
            merged.merge!(@local_types)
            merged.empty? ? nil : merged
          end

          # TWO-SUB-PASS pre-scan: collect ivar + memoized-accessor-return types
          # across the WHOLE class body before the resolving walk. Uses a
          # dedicated visitor so it never disturbs @method_stack / @namespace /
          # BranchCounter — it only populates @ivar_types[class_fq] and
          # @accessor_returns[class_fq].
          def prescan_class_types(class_node, class_fq)
            scanner = ClassTypeScanner.new(
              @ivar_types[class_fq], @accessor_returns[class_fq], method(:const_new_fq)
            )
            class_node.body&.accept(scanner)
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
