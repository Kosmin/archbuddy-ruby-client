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
          # v0.11 E1 (L13): alongside the category, the probe now CARRIES the
          # literal constant FQ it classified on — normalized for sink identity
          # (whitespace collapsed, leading `::` stripped) and emitted as
          # `Resolution#target_fq` — so the adapter can mint one per-target
          # sub-sink `<external:{category}:{const_fq}>` per distinct pair.
          # Category ⇒ target present, by construction: `external` is reachable
          # only after the `const_fq.nil?` early return.
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

              external(category, const_fq)
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

            # v0.11 E1 (L13): carry the literal constant FQ on the existing
            # Resolution#target_fq member (db_op precedent) so the adapter can
            # mint one sink per distinct [category, target].
            def external(category, const_fq)
              RubyResolver::Resolution.new(
                tier: :egress, action: :external, target_fq: normalize_target(const_fq),
                kind: "external", egress_category: category
              )
            end

            # Sink-identity normalization, applied at MINT time only —
            # `classify` still sees the raw slice, so egress_counts categories
            # stay byte-identical (a `::Faraday` classifies :gem today and
            # keeps classifying :gem; only the SINK identity is normalized).
            #   - collapse whitespace: `Foo :: Bar` / multi-line constant paths
            #     are cosmetic Ruby syntax for the same constant (C5)
            #   - strip the leading `::` (cbase): `::Faraday` ≡ `Faraday`
            def normalize_target(const_fq)
              const_fq.gsub(/\s+/, "").delete_prefix("::")
            end
          end
        end
      end
    end
  end
end
