# frozen_string_literal: true

require "prism"
require_relative "vocab"
require_relative "probe"

module Archbuddy
  module Collect
    module Adapters
      module Ruby
        # Pure tiered decision logic (D24). Given a call site and its enclosing
        # context, decide what the call resolves to WITHOUT touching the AST
        # walk or mutating state — so each tier is independently testable.
        #
        # The single source of truth for "what kind of thing did this call hit".
        # NEVER fabricates an edge: an unknown call routes to the shared external
        # sink, metaprogramming yields :metaprogramming (no edge), operators are
        # dropped (:drop).
        class RubyResolver
          # Context for a single call site.
          #   name              => Symbol/String method name
          #   receiver          => the Prism receiver node (or nil for implicit self)
          #   enclosing_class   => fq name of the class the call lexically sits in (or nil)
          #   table             => SymbolTable
          #   node              => the raw Prism::CallNode for this call site (or
          #                        nil); probes read node.arguments / node.block.
          #                        Base tiers ignore it.
          #   type_scope        => read-only view of the conservative intra-procedural
          #                        type scope (L1) for THIS call site: a Hash merging
          #                        the current method's local-var types over the
          #                        enclosing class's ivar + memoized-accessor-return
          #                        types ({ "x" => "Const", "@y" => "Const::Path",
          #                        "accessor" => "Const" }). nil/empty when no types
          #                        are tracked. Consumed ONLY by R4.5 (typed receiver).
          CallContext = Struct.new(
            :name, :receiver, :enclosing_class, :table, :node, :type_scope, keyword_init: true
          )

          # A resolution outcome.
          #   tier       => Symbol describing which rule fired (for debugging/tests)
          #   action     => :edge | :drop | :metaprogramming | :external
          #   target_fq  => fq symbol of the resolved app target (for :edge to a known method)
          #   kind       => contract node kind for the *target* when synthesizing it
          #                 (:db_op / :external); nil when target is an existing method node
          #   provenance => Symbol naming the probe that produced this resolution
          #                 (e.g. :grape), or nil for base tiers. Trust/diagnostics
          #                 ONLY — never reaches graph.yml.
          #   egress_category => v0.10 W2-C (L16/L18): OPTIONAL egress category
          #                 (:http / :gem / :queue) enriching an :external
          #                 action. Set ONLY by the EgressProbe on a provable
          #                 literal-constant receiver; nil everywhere else
          #                 (base tiers never set it — the call stays the
          #                 generic <external> bucket).
          Resolution = Struct.new(
            :tier, :action, :target_fq, :kind, :provenance, :egress_category,
            keyword_init: true
          )

          def initialize(table, probes: [])
            @table  = table
            @probes = probes
          end

          # @param ctx [CallContext]
          # @return [Resolution]
          def resolve(ctx)
            name = ctx.name.to_s

            # R0: operator deny-list — drop entirely (D36).
            return drop(:operator) if Vocab.operator?(name)

            # R1: metaprogramming — flag, emit NO edge (we can't know the target).
            # NARROWED (v0.10 W1-D, L21): flag ONLY when the meta call is
            # DYNAMIC. A META_RESOLVABLE verb (`send`/`public_send`/`__send__`)
            # with a literal Symbol/String first arg is statically resolvable —
            # it falls through the tiers to R5 where MetaSendProbe rewrites it
            # to the direct call (gated on table.method?), else R9 <external>.
            # This also fixes the latent name-before-receiver FP: a domain
            # class's OWN `def send`/`try` invoked with a literal arg now
            # resolves via the normal machinery instead of being mis-flagged.
            # `define_method`/`method_missing`/`*_eval`/`instance_exec`/
            # `const_get`... stay ALWAYS-flagged (not in META_RESOLVABLE).
            return meta(:metaprogramming) if dynamic_meta?(ctx, name)

            # R2: db_op via CLASS CONTEXT. The verified gotcha: `where` inside
            # `def self.x` of an AR subclass has receiver = nil (implicit self),
            # so we must consult the enclosing class, not the receiver shape.
            if active_record_context?(ctx) && Vocab.active_record_method?(name)
              return Resolution.new(
                tier: :db_op_class_context, action: :external, # synthesized sink-like node
                target_fq: db_op_symbol(ctx, name), kind: "db_op"
              )
            end

            # R3: implicit-self / explicit-self call to a method on the enclosing
            # class. e.g. `tax` inside `Invoice#total` -> Invoice#tax (if known).
            if self_receiver?(ctx.receiver) && ctx.enclosing_class
              instance_fq = "#{ctx.enclosing_class}##{name}"
              singleton_fq = "#{ctx.enclosing_class}.#{name}"
              if @table.method?(instance_fq)
                return edge(:self_instance, instance_fq)
              elsif @table.method?(singleton_fq)
                return edge(:self_singleton, singleton_fq)
              end
            end

            # R4: app `Const.method` / `Const::Path.method` -> known method node.
            if (const_fq = constant_receiver_fq(ctx.receiver))
              singleton_fq = "#{const_fq}.#{name}"
              instance_fq  = "#{const_fq}##{name}"

              # db_op when the constant is a known AR class (e.g. User.where).
              if @table.active_record_class?(const_fq) && Vocab.active_record_method?(name)
                return Resolution.new(
                  tier: :db_op_const_receiver, action: :external,
                  target_fq: "#{const_fq}.#{name}", kind: "db_op"
                )
              end

              return edge(:const_singleton, singleton_fq) if @table.method?(singleton_fq)
              return edge(:const_instance, instance_fq)    if @table.method?(instance_fq)
            end

            # R4.5: TYPED variable / ivar / memoized-accessor / inline-`Const.new`
            # receiver -> known method node, via the conservative intra-procedural
            # type scope (L1). Fires ONLY when R3/R4 did NOT match (a genuine
            # self/const edge is never shadowed) and the receiver's type is
            # PROVABLE from ctx.type_scope (or an inline `Const.new` chain).
            # NEVER fabricates: emits ONLY when @table.method?(fq) is true; else
            # falls through to R5 -> R9 (<external>). AR/Looker/Snowflake are NOT
            # special-cased — resolution is pure symbol-table lookup; the db_op
            # branch fires only via active_record_class?, exactly as R4 does.
            if (const_fq = typed_receiver_fq(ctx))
              # db_op when the inferred type is a known AR class (mirror of R4:
              # 89-94): `x = User.new; x.where` -> db_op, NOT a fabricated edge.
              if @table.active_record_class?(const_fq) && Vocab.active_record_method?(name)
                return Resolution.new(
                  tier: :db_op_typed_receiver, action: :external,
                  target_fq: "#{const_fq}.#{name}", kind: "db_op"
                )
              end

              # `.new` yields an INSTANCE, so prefer the instance form; also
              # resolve the singleton form (`Const.method`) for completeness,
              # exactly as R4 does for constant receivers.
              instance_fq  = "#{const_fq}##{name}"
              singleton_fq = "#{const_fq}.#{name}"
              return edge(:typed_instance, instance_fq)   if @table.method?(instance_fq)
              return edge(:typed_singleton, singleton_fq) if @table.method?(singleton_fq)
            end

            # R5: framework probes (P1). Recognized framework dynamic-dispatch
            # DSLs resolve to REAL edges the framework PROVABLY wires. Run AFTER
            # all base tiers (never shadow a known app edge) and BEFORE <external>
            # (so a recognized route/job resolves instead of dead-ending). Each
            # probe claims (returns a Resolution, which REPLACES the <external>
            # fallthrough for this call — never stacks a 2nd edge, P6) or declines
            # (nil -> next probe / R9). First non-nil wins (same discipline as R2-R4).
            @probes.each do |probe|
              resolution = probe.resolve(ctx)
              if resolution
                resolution.provenance ||= probe.name # provenance carry (L5/P4)
                return resolution
              end
            end

            # R9: everything unresolved -> the single shared external sink.
            Resolution.new(tier: :external, action: :external, target_fq: nil, kind: "external")
          end

          private

          # R1 gate (v0.10 W1-D): a meta call is a DYNAMIC blind spot unless it
          # is a resolvable dispatch verb carrying a literal Symbol/String first
          # argument (MetaSendProbe territory). Verbs in META_RESOLVABLE but NOT
          # in METAPROGRAMMING (`try`/`try!`) are never flagged here at all.
          def dynamic_meta?(ctx, name)
            return false unless Vocab.metaprogramming?(name)
            # send/public_send/__send__ with a leading literal Symbol/String arg
            # are RESOLVABLE (MetaSendProbe handles them at R5) — not a blind spot.
            return false if Vocab.meta_resolvable?(name) && literal_dispatch_arg?(ctx.node)

            true # eval/*_eval/method_missing/const_get/define_method/computed send → dynamic
          end

          # True iff the call node's FIRST argument is a literal Symbol/String.
          def literal_dispatch_arg?(node)
            arg = node&.arguments&.arguments&.first
            arg.is_a?(Prism::SymbolNode) || arg.is_a?(Prism::StringNode)
          end

          def active_record_context?(ctx)
            ctx.enclosing_class && @table.active_record_class?(ctx.enclosing_class)
          end

          # A db_op target symbol in real space. For implicit-self AR calls we key
          # it by the enclosing class so `Invoice.where` and `Order.where` are
          # distinct db_op nodes; the bare method name keeps them readable.
          def db_op_symbol(ctx, name)
            "#{ctx.enclosing_class}.#{name}"
          end

          def self_receiver?(receiver)
            receiver.nil? || receiver.is_a?(Prism::SelfNode)
          end

          # R4.5: the inferred constant FQ of a typed receiver, or nil (decline).
          # Resolution by receiver shape — every path is conservative and returns
          # nil unless the type is PROVABLE:
          #   - inline `Const.new` / `Const::Path.new` chain: the receiver is a
          #     CallNode named :new whose own receiver is a Constant(Path) node →
          #     the const FQ via constant_receiver_fq (no scope state needed).
          #   - LocalVariableReadNode  → ctx.type_scope[name]   (e.g. "x")
          #   - InstanceVariableReadNode → ctx.type_scope[name]  (e.g. "@svc")
          #   - nil-receiver CallNode (bare memoized-accessor call) →
          #     ctx.type_scope[name] (the accessor-return map merged in by the Pass)
          #   - anything else (param, block arg, unknown) → nil.
          # Reads ctx.type_scope ONLY; never mutates it.
          def typed_receiver_fq(ctx)
            recv = ctx.receiver

            # inline `Const.new` / `Const::Path.new` chain
            if recv.is_a?(Prism::CallNode) && recv.name == :new &&
               !recv.receiver.nil?
              return constant_receiver_fq(recv.receiver)
            end

            scope = ctx.type_scope
            return nil if scope.nil?

            case recv
            when Prism::LocalVariableReadNode, Prism::InstanceVariableReadNode
              scope[recv.name.to_s]
            when Prism::CallNode
              # Bare accessor call (`svc.method` where `svc` is a nil-receiver
              # CallNode): resolve via the accessor-return map (merged into scope).
              recv.receiver.nil? ? scope[recv.name.to_s] : nil
            end
          end

          # If the receiver is a constant (Foo) or constant path (Foo::Bar),
          # return its fq name; else nil.
          def constant_receiver_fq(receiver)
            return nil if receiver.nil?

            case receiver
            when Prism::ConstantReadNode, Prism::ConstantPathNode
              receiver.slice
            end
          end

          def edge(tier, target_fq)
            Resolution.new(tier: tier, action: :edge, target_fq: target_fq, kind: nil)
          end

          def drop(tier)
            Resolution.new(tier: tier, action: :drop, target_fq: nil, kind: nil)
          end

          def meta(tier)
            Resolution.new(tier: tier, action: :metaprogramming, target_fq: nil, kind: nil)
          end
        end
      end
    end
  end
end
