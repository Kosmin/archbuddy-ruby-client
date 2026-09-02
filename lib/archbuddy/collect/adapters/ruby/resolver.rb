# frozen_string_literal: true

require "prism"
require_relative "vocab"
require_relative "probe"
require_relative "boundary_rules"
require_relative "receiver_shape"

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
          #   cco_role   => configurator W3 (C6/C7): OPTIONAL INERT crossing-role
          #                 tag ("action"/"configuration"/"no_io") read from the
          #                 PROFILE's per-verb `role` field. Set on db_op
          #                 resolutions (from the ORM verb table) and by the
          #                 EgressProbe on an :http crossing (from the egress
          #                 verb table). nil = the profile declares no role for
          #                 this verb — never defaulted, never guessed. Nothing
          #                 in either repo reads it to decide anything.
          Resolution = Struct.new(
            :tier, :action, :target_fq, :kind, :provenance, :egress_category, :cco_role,
            keyword_init: true
          )

          # The tier name the R9 fallthrough stamps. Named as a CONSTANT so the
          # "this call site went unresolved" question has ONE producer:
          # ReceiverShapeTally reads it rather than re-typing the symbol, and a
          # rename here can no longer silently empty that tally (configurator W4
          # / C13).
          UNRESOLVED_TIER = :external

          def initialize(table, probes: [], reflection: nil, traced_types: nil)
            @table  = table
            @probes = probes
            # OPTIONAL boot-reflection method table. nil when reflection did not
            # run (it is an ENRICHMENT, never a prerequisite) — every rule below
            # behaves exactly as before in that case.
            @reflection = reflection
            # OPTIONAL observed return types from `archbuddy trace`. nil is the
            # NORMAL case — no trace has been run — and every rule behaves
            # exactly as before then. See R4.9.
            @traced_types = traced_types
          end

          # @param ctx [CallContext]
          # @return [Resolution]
          def resolve(ctx)
            name = ctx.name.to_s

            # R0: operator deny-list — drop entirely (D36).
            return drop(:operator) if profile.operator?(name)

            # R1: metaprogramming — flag, emit NO edge (we can't know the target).
            # NARROWED (v0.10 W1-D, L21): flag ONLY when the meta call is
            # DYNAMIC. A resolvable-dispatch verb (`send`/`public_send`/`__send__`)
            # with a literal Symbol/String first arg is statically resolvable —
            # it falls through the tiers to R5 where MetaSendProbe rewrites it
            # to the direct call (gated on table.method?), else R9 <external>.
            # This also fixes the latent name-before-receiver FP: a domain
            # class's OWN `def send`/`try` invoked with a literal arg now
            # resolves via the normal machinery instead of being mis-flagged.
            # `define_method`/`method_missing`/`*_eval`/`instance_exec`/
            # `const_get`... stay ALWAYS-flagged (they are dynamic-dispatch
            # verbs the profile does NOT also list as resolvable).
            return meta(:metaprogramming) if dynamic_meta?(ctx, name)

            # R1.5: DECLARED BOUNDARY (configurator W4 / C9). ABOVE R2..R4.5,
            # unlike an R5 probe, because a declaration must beat an inference or
            # it is not a declaration. The tier's ENTIRE body — three
            # granularities, their precedence, the closed-category gate and the
            # kind:/egress_category: pairing — lives in BoundaryRules; this file
            # learns nothing about crossings.
            #
            # TWO lines, not one, for a PARSE-ORDER reason and no other:
            # `return x if (x = …)` is a NameError in Ruby (the modifier's local
            # is not yet declared when the `return` is parsed). Both lines are
            # pure delegation — no branch on category, kind or role lives here.
            declared = BoundaryRules.resolve(ctx, profile)
            return declared if declared

            # R2: db_op via CLASS CONTEXT. The verified gotcha: `where` inside
            # `def self.x` of an AR subclass has receiver = nil (implicit self),
            # so we must consult the enclosing class, not the receiver shape.
            if active_record_context?(ctx) && profile.orm_method?(name)
              return Resolution.new(
                tier: :db_op_class_context, action: :external, # synthesized sink-like node
                target_fq: db_op_symbol(ctx, name), kind: "db_op",
                cco_role: profile.orm_role(name)
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

            # R3.4: the same receiverless call, resolved along the static
            # ANCESTOR CHAIN — superclasses and the modules they include.
            #
            # R3 asks only whether the ENCLOSING class parsed the method itself,
            # so `include Segmentation::Snowflake` followed by a bare
            # `snowflake_client` resolved to nothing. Measured on a real service,
            # that is 506 of the 920 call sites where real complexity could still
            # be hiding, and not one of them has its target on the calling class.
            #
            # BEFORE R3.5 because this is a PROOF and R3.5 is an enrichment:
            # `mixins`/`superclass` come from literal `include`/`<` in the parsed
            # source, so the answer is exact and needs no boot. R3.5's reflection
            # lookup is keyed by owner and cannot see an inherited method at all,
            # which is why this tier — not a better reflection query — is what
            # closes the mixin case.
            if self_receiver?(ctx.receiver) && ctx.enclosing_class &&
               (ancestor_fq = @table.ancestor_method_fq(ctx.enclosing_class, name))
              return edge(:self_ancestor, ancestor_fq)
            end

            # R3.5: BOOT-REFLECTION fallback for a receiverless call the static
            # table missed. R3 consults only the enclosing class's OWN parsed
            # methods, so an INHERITED, MIXED-IN or MACRO-GENERATED target falls
            # through — the largest structured unresolved bucket on a real
            # service (4,517 `self` sites). Reflection knows the class's COMPLETE
            # loaded method table, so it answers precisely that question.
            #
            # A method OWNED by an application class but DEFINED inside a gem is,
            # by construction, a call that leaves the analysed boundary: that is
            # a PROVEN crossing, not an assumed one, which is what makes stamping
            # it honest here while the unresolved catch-all sink must stay bare.
            if self_receiver?(ctx.receiver) && ctx.enclosing_class &&
               (hit = reflect_crossing(ctx.enclosing_class, name, :reflect_self))
              return hit
            end

            # R4: app `Const.method` / `Const::Path.method` -> known method node.
            if (const_fq = constant_receiver_fq(ctx.receiver))
              singleton_fq = "#{const_fq}.#{name}"
              instance_fq  = "#{const_fq}##{name}"

              # db_op when the constant is a known AR class (e.g. User.where).
              if @table.active_record_class?(const_fq) && profile.orm_method?(name)
                return Resolution.new(
                  tier: :db_op_const_receiver, action: :external,
                  target_fq: "#{const_fq}.#{name}", kind: "db_op",
                  cco_role: profile.orm_role(name)
                )
              end

              return edge(:const_singleton, singleton_fq) if @table.method?(singleton_fq)
              return edge(:const_instance, instance_fq)    if @table.method?(instance_fq)

              # R4.6: the constant is a known class but the method is not in the
              # parsed table — inherited, mixed in, or macro-generated. Reflection
              # knows the class's COMPLETE loaded table and whether the definition
              # lives in a gem.
              if (hit = reflect_crossing(const_fq, name, :reflect_const))
                return hit
              end
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
              if @table.active_record_class?(const_fq) && profile.orm_method?(name)
                return Resolution.new(
                  tier: :db_op_typed_receiver, action: :external,
                  target_fq: "#{const_fq}.#{name}", kind: "db_op",
                  cco_role: profile.orm_role(name)
                )
              end

              # `.new` yields an INSTANCE, so prefer the instance form; also
              # resolve the singleton form (`Const.method`) for completeness,
              # exactly as R4 does for constant receivers.
              instance_fq  = "#{const_fq}##{name}"
              singleton_fq = "#{const_fq}.#{name}"
              return edge(:typed_instance, instance_fq)   if @table.method?(instance_fq)
              return edge(:typed_singleton, singleton_fq) if @table.method?(singleton_fq)

              # R4.7: the receiver's type is PROVABLE but the method is not in the
              # parsed table. This is the ActiveRecord ASSOCIATION path —
              # `order.line_items` is a typed LOCAL receiver, never `self`, so the
              # self tier could never see it. Measured on a real service: 69
              # relations existed in the manifest and produced ZERO db_op nodes
              # until this tier existed.
              if (hit = reflect_crossing(const_fq, name, :reflect_typed))
                return hit
              end
            end

            # R4.8: an ActiveRecord ASSOCIATION reached through a receiver whose
            # type we cannot prove — `order.line_items` where `order` came from a
            # parameter or a query, which is the ordinary case. R4.7 cannot fire
            # (no provable type) and the association would otherwise vanish into
            # the unresolved sink, which is why 69 known relations produced ZERO
            # db_op nodes.
            #
            # Resolved by NAME, but only under a strict uniqueness guard: the name
            # must be declared as a relation by exactly ONE class in the whole
            # corpus. Bare name lookup is worthless in general (`call` is declared
            # by 129 classes), but relation names are domain nouns and 85% are
            # unique. A colliding name is left UNRESOLVED rather than guessed.
            if @reflection && !self_receiver?(ctx.receiver) &&
               (owner = @reflection.sole_relation_owner(name))
              return Resolution.new(
                tier: :reflect_relation_by_name, action: :external,
                target_fq: "#{owner}##{name}", kind: "db_op"
              )
            end

            # R4.9: a chained call whose receiver's type was OBSERVED RUNNING.
            #
            # `purchase.recompute!` where `purchase` is `delegate ..., to:
            # :context`. Nothing static reaches this: the receiver's value came
            # out of an instance hash a caller in another file filled in, so
            # there is no method to find, no owner to look up and no bytecode to
            # read. An execution can see it and nothing else can.
            #
            # LAST OF THE BASE TIERS, deliberately. A trace is weaker evidence
            # than parsed source — partial (it saw only what ran) and
            # non-deterministic (it varies with inputs) — so every rule that can
            # answer from source has already declined by the time we get here.
            #
            # ONLY WHEN THE OBSERVATION IS UNAMBIGUOUS. If two flows put
            # different types under one key the union is the true answer, and
            # `return_type_at` returns nil rather than the popular one; a
            # majority vote over runtime samples would be a fabrication wearing
            # a measurement's clothes.
            #
            # JOINED ON AN ADDRESS, never on a name. The trace records the
            # app-side frame that reached into the bag — for a delegate, its own
            # generated method at the `delegate` line — which is the same
            # (rel_file, line, name) triple the symbol table holds. So this asks
            # "what did THIS method return", not "what does something called
            # `purchase` usually return".
            if @traced_types && (hit = traced_receiver(ctx, name))
              return hit
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
            Resolution.new(tier: UNRESOLVED_TIER, action: :external, target_fq: nil, kind: "external")
          end

          private

          # The engine-shipped ecosystem vocabulary, reached through the ONE
          # seam (configurator W2). Read off the table rather than held as a
          # second ivar so the resolver and the table can never disagree about
          # which profile is in force.
          # Boot-reflection crossing lookup, shared by the self / const / typed
          # tiers. Returns a Resolution ONLY for a PROVEN crossing — a method
          # owned by `cls` whose definition lives outside the project tree. Never
          # infers from the name, and returns nil when reflection did not run.
          #
          # A relation (has_many/belongs_to) crosses to the DATABASE and is typed
          # db_op. Any other gem-defined method is a crossing whose channel is
          # unknown, which is precisely what the generic "exit" category says.
          def reflect_crossing(cls, name, tier)
            return nil unless @reflection && cls

            fact = @reflection.fact(cls, name)
            return nil unless fact

            return reflect_exit(fact, cls, name, tier) if fact.proven_crossing?

            reflect_internal(fact, tier)
          end

          # The method is owned by the class but DEFINED INSIDE the project: a
          # real in-app edge, not a crossing.
          #
          # This is the bulk of what reflection is worth and it was previously
          # dropped: R3 resolves a receiverless call only against the enclosing
          # class's OWN parsed methods, so anything INHERITED or MIXED IN falls
          # through. Measured on a real service, 8,549 self-call sites (25% of ALL
          # call sites) are resolvable this way — more than the entire resolved
          # edge count of the graph before it.
          #
          # The edge is emitted ONLY when the defining owner's method node
          # actually exists in the symbol table. Reflection says WHERE the method
          # lives; it never licenses inventing a node that was never parsed.
          def reflect_internal(fact, tier)
            target = fact.target_fq
            return nil if target.nil?
            return nil unless @table.method?(target)

            edge(:"#{tier}_internal", target)
          end

          # R4.9's body. Three exact steps, each of which declines rather than
          # guesses:
          #   1. the receiver must be a BARE receiverless call — `purchase.x`,
          #      not `a.b.c`. A deeper expression has no single address to look
          #      up, and inventing one is the failure mode this avoids.
          #   2. that receiver must resolve to a method we PARSED, so we have
          #      its address. The ancestor walk is reused, so an inherited or
          #      mixed-in receiver works too.
          #   3. the trace must have seen that address return exactly ONE class,
          #      and the called name must exist on it.
          def traced_receiver(ctx, name)
            rcv = ctx.receiver
            return nil unless rcv.is_a?(Prism::CallNode) && rcv.receiver.nil? &&
                              rcv.arguments.nil? && rcv.block.nil?
            return nil unless ctx.enclosing_class

            rcv_name = rcv.name.to_s
            rcv_fq   = @table.ancestor_method_fq(ctx.enclosing_class, rcv_name) or return nil
            entry    = @table.method_for(rcv_fq) or return nil
            return nil if entry.rel_file.nil? || entry.line.nil?

            observed = @traced_types.return_type_at(entry.rel_file, entry.line, rcv_name) or return nil
            target   = @table.ancestor_method_fq(observed, name) or return nil

            edge(:traced_receiver, target)
          rescue StandardError
            # A trace is an enrichment like reflection: learn nothing here
            # rather than fail a collection that would otherwise succeed.
            nil
          end

          def reflect_exit(fact, cls, name, tier)
            Resolution.new(
              tier: tier, action: :external,
              target_fq: "#{cls}##{name}",
              kind: fact.relation? ? "db_op" : "external",
              egress_category: fact.relation? ? nil : :exit
            )
          end

          def profile
            @table.profile
          end

          # R1 gate (v0.10 W1-D): a meta call is a DYNAMIC blind spot unless it
          # is a resolvable dispatch verb carrying a literal Symbol/String first
          # argument (MetaSendProbe territory). Verbs the profile lists as
          # RESOLVABLE but not as DYNAMIC (`try`/`try!`) are never flagged here.
          def dynamic_meta?(ctx, name)
            return false unless profile.dynamic_dispatch_verb?(name)
            # send/public_send/__send__ with a leading literal Symbol/String arg
            # are RESOLVABLE (MetaSendProbe handles them at R5) — not a blind spot.
            return false if profile.resolvable_dispatch_verb?(name) && literal_dispatch_arg?(ctx.node)

            true # eval/*_eval/method_missing/const_get/define_method/computed send → dynamic
          end

          # True iff the call node's FIRST argument is a literal Symbol/String.
          # Definition HOISTED to Vocab (v0.12 L18) so the EscapeScanner
          # shares the one spelling; this delegation is behavior-preserving.
          def literal_dispatch_arg?(node)
            Vocab.literal_dispatch_arg?(node)
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

          # C13 hoist: one spelling of "is this receiver self". Implicit-self (a
          # nil receiver) and an explicit `self` are the same thing to every
          # consumer, and ReceiverShape is where that is decided.
          def self_receiver?(receiver)
            ReceiverShape.self?(receiver)
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
            return ReceiverShape.constructor_constant_fq(recv) if ReceiverShape.constructor_chain?(recv)

            scope = ctx.type_scope
            return nil if scope.nil?

            # local / ivar / BARE accessor call (`svc.method` where `svc` is a
            # nil-receiver CallNode, resolved via the accessor-return map merged
            # into scope). A call node WITH its own receiver has no scope key and
            # therefore declines, exactly as before the C13 hoist.
            key = ReceiverShape.scope_key(recv)
            key && scope[key]
          end

          # If the receiver is a constant (Foo) or constant path (Foo::Bar),
          # return its fq name; else nil. C13 hoist: the ladder itself lives in
          # ReceiverShape now; the nil guard is redundant there and kept out.
          def constant_receiver_fq(receiver)
            ReceiverShape.constant_fq(receiver)
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
