# frozen_string_literal: true

require "prism"
require_relative "../probe"
require_relative "../resolver"
require_relative "../vocab"

module Archbuddy
  module Collect
    module Adapters
      module Ruby
        module Probes
          # Resolver-tier probe (R5) for LITERAL dynamic dispatch (v0.10 W1-D,
          # L21). A meta-dispatch whose FIRST argument is a literal Symbol or
          # String — `recv.send(:m)`, `public_send("m")`, `__send__(:m)`,
          # `try(:m)`, `try!(:m)` — provably invokes `m` on the receiver, so
          # this probe rewrites it to the direct call and recovers a
          # `caller -> Target#m` edge the base tiers can't see (the call-site
          # NAME is the dispatch verb, not the target).
          #
          # Receiver proof reuses exactly what the resolver can already prove:
          #   - literal constant  (`Const.send(:m)` / `Const::Path.send(:m)`)
          #   - typed variable / ivar via ctx.type_scope (`x = Const.new; x.send(:m)`)
          #   - implicit/explicit self + enclosing class (mirror R3)
          # Anything else (param, computed chain, untyped var) DECLINES.
          #
          # NEVER-FABRICATE (L4/I1): emits the edge ONLY when
          # `ctx.table.method?(target_fq)` is true for the rewritten target
          # (instance form first, then singleton — the plan's Task-3 order).
          # Otherwise DECLINES (nil) so the call falls through to R9
          # `<external>` — never a guessed edge. Dynamic-arg `send`/`public_send`/
          # `__send__` never reach a claim here (no literal name → decline);
          # R1 already flagged them as a metaprogramming blind spot. Dynamic-arg
          # `try`/`try!` simply fall to `<external>`, matching their pre-v0.10
          # behavior (they were never metaprogramming-flagged).
          class MetaSendProbe < Probe
            def self.probe_name
              :meta_send
            end

            def name
              :meta_send
            end

            # @param ctx [RubyResolver::CallContext]
            # @return [RubyResolver::Resolution, nil]
            def resolve(ctx)
              return nil unless Vocab.meta_resolvable?(ctx.name)

              method_name = literal_method_name(ctx.node)
              return nil if method_name.nil? # dynamic arg → decline

              recv_fq = receiver_fq(ctx)
              return nil if recv_fq.nil? # unprovable receiver → decline

              instance_fq  = "#{recv_fq}##{method_name}"
              singleton_fq = "#{recv_fq}.#{method_name}"
              return edge(instance_fq)  if ctx.table.method?(instance_fq)
              return edge(singleton_fq) if ctx.table.method?(singleton_fq)

              nil # target not in the table → decline → R9 <external>
            end

            private

            def edge(target_fq)
              RubyResolver::Resolution.new(
                tier: :meta_send, action: :edge, target_fq: target_fq, kind: nil
              )
            end

            # The dispatched method name when the call's FIRST argument is a
            # literal Symbol/String; nil otherwise (incl. no arguments at all).
            # The probe needs the VALUE (the resolver's literal_dispatch_arg?
            # is a boolean gate — deliberately kept separate and minimal).
            def literal_method_name(node)
              arg = node&.arguments&.arguments&.first
              case arg
              when Prism::SymbolNode, Prism::StringNode
                arg.unescaped
              end
            end

            # The provable FQ of the receiver, mirroring the base tiers:
            # self → enclosing class (R3), literal constant (R4), typed
            # var/ivar via ctx.type_scope (R4.5). nil = decline.
            def receiver_fq(ctx)
              recv = ctx.receiver
              return ctx.enclosing_class if recv.nil? || recv.is_a?(Prism::SelfNode)

              case recv
              when Prism::ConstantReadNode, Prism::ConstantPathNode
                recv.slice
              when Prism::LocalVariableReadNode, Prism::InstanceVariableReadNode
                ctx.type_scope && ctx.type_scope[recv.name.to_s]
              end
            end
          end
        end
      end
    end
  end
end
