# frozen_string_literal: true

require "prism"
require_relative "../probe"
require_relative "../resolver"
require_relative "../vocab"
require_relative "dispatch_probe"

module Archbuddy
  module Collect
    module Adapters
      module Ruby
        module Probes
          # Resolver-tier probe (R5, v0.10 W2-C, L16/L18) sub-classifying the
          # generic `<external>` fallthrough into an EGRESS CATEGORY on a
          # PROVABLE literal-constant receiver:
          #
          #   :http  — known HTTP-client constant root (Vocab::EGRESS_HTTP_
          #            CONSTANTS + the `Aws::` prefix) AND an HTTP verb
          #            (`Faraday.get`, `Net::HTTP.start`). The verb gate keeps
          #            a local const misnamed `HTTP` from being classified on
          #            name alone.
          #   :queue — the DispatchProbe-declined enqueue shape: a
          #            `perform_async`/`perform_later`/... verb on a literal
          #            constant whose `#perform` is NOT in-tree (an in-tree
          #            enqueue already resolved to an EDGE in DispatchProbe,
          #            registered BEFORE this probe — it never reaches here).
          #   :gem   — any other literal constant ABSENT from the SymbolTable
          #            (an out-of-tree gem call, today's generic external).
          #
          # NEVER-FABRICATE (L4/I1): the probe never mints an in-tree edge and
          # never guesses. It only ENRICHES the existing external action with a
          # category, and ONLY when the receiver is a literal Const/Const::Path
          # that is provably out-of-tree. A variable/computed receiver, or an
          # in-tree constant (the base tiers / earlier probes own those),
          # DECLINES (nil) so the call falls through to R9 — the generic
          # `<external>` sink, exactly as today.
          #
          # Registered LAST in ProbeRegistry (after Grape/Dispatch/MetaSend):
          # egress classification must never shadow a recoverable real edge.
          class EgressProbe < Probe
            def self.probe_name
              :egress
            end

            def name
              :egress
            end

            # @param ctx [RubyResolver::CallContext]
            # @return [RubyResolver::Resolution, nil]
            def resolve(ctx)
              const_fq = literal_constant_fq(ctx.receiver)
              return nil if const_fq.nil?            # variable/computed → generic <external>
              return nil if in_tree?(ctx.table, const_fq) # base tiers/probes own in-tree consts

              category = classify(const_fq, ctx.name.to_s)
              return nil if category.nil?

              external(category)
            end

            private

            # :http / :queue / :gem for a provably out-of-tree literal constant.
            # :gem is the catch-all — the constant is literal and absent from
            # the table, which IS the "call into a gem" evidence (L18).
            def classify(const_fq, verb)
              if Vocab.egress_http_constant?(const_fq) && Vocab.egress_http_verb?(verb)
                :http
              elsif DispatchProbe::DISPATCH_METHODS.include?(verb)
                :queue
              else
                :gem
              end
            end

            # In-tree = the constant names a known class/module OR owns any
            # captured method (covers method-only surfaces like a module with
            # singleton defs). An in-tree receiver is never egress.
            def in_tree?(table, const_fq)
              !table.class_for(const_fq).nil?
            end

            # The receiver's FQ when it is a LITERAL constant (`Const` /
            # `Const::Path`); nil otherwise. Deliberately duplicated small
            # (the resolver's constant_receiver_fq is private; probes stay
            # self-contained — the DispatchProbe pattern).
            def literal_constant_fq(receiver)
              case receiver
              when Prism::ConstantReadNode, Prism::ConstantPathNode
                receiver.slice
              end
            end

            def external(category)
              RubyResolver::Resolution.new(
                tier: :egress, action: :external, target_fq: nil,
                kind: "external", egress_category: category
              )
            end
          end
        end
      end
    end
  end
end
