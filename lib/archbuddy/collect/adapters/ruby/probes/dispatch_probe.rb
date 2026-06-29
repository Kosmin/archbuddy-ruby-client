# frozen_string_literal: true

require "set"
require "prism"
require_relative "../probe"
require_relative "../resolver"

module Archbuddy
  module Collect
    module Adapters
      module Ruby
        module Probes
          # Resolver-tier probe (R5) for Sidekiq / ActiveJob DISPATCH (W3). An
          # asynchronous dispatch — `Const.perform_async`, `.perform_later`,
          # `.perform_in`, `.perform_at` (and a single `.set(...).perform_*`
          # hop) — provably enqueues work that runs `Const#perform`. The base
          # resolver can't see that edge (the dispatch verb is not `#perform`),
          # so this probe recovers a `caller -> Const#perform` edge.
          #
          # NEVER-FABRICATE (L2): emits the edge ONLY when the receiver resolves
          # to a literal constant AND `table.method?("Const#perform")` is true.
          # Otherwise DECLINES (nil) so the call falls through to R9 `<external>`.
          #
          # Deliberately does NOT match bare `Const.perform` or
          # `Const.perform_now`: `perform`/`perform_now` run inline and are
          # direct calls the base R4 tier already handles when `#perform`
          # exists — matching them would risk double-handling.
          class DispatchProbe < Probe
            DISPATCH_METHODS = %w[perform_async perform_later perform_in perform_at].to_set.freeze

            def self.probe_name
              :sidekiq_dispatch
            end

            def name
              :sidekiq_dispatch
            end

            # @param ctx [RubyResolver::CallContext]
            # @return [RubyResolver::Resolution, nil]
            def resolve(ctx)
              return nil unless DISPATCH_METHODS.include?(ctx.name.to_s)

              const_fq = dispatch_constant_fq(ctx.receiver)
              return nil if const_fq.nil?

              target_fq = "#{const_fq}#perform"
              return nil unless ctx.table.method?(target_fq)

              RubyResolver::Resolution.new(
                tier: :sidekiq_dispatch, action: :edge, target_fq: target_fq, kind: nil
              )
            end

            private

            # The constant root of a dispatch receiver, or nil. Supports:
            #   Const.perform_async                 -> "Const"
            #   Const.set(...).perform_later        -> "Const" (single .set hop)
            # Any deeper / non-constant chain (e.g. `Wrapper.new.perform_later`,
            # implicit self) declines so the call falls through to <external>.
            def dispatch_constant_fq(receiver)
              return nil if receiver.nil?

              receiver = unwrap_set_hop(receiver)
              return nil if receiver.nil?

              case receiver
              when Prism::ConstantReadNode, Prism::ConstantPathNode
                receiver.slice
              end
            end

            # If the receiver is a single `.set(...)` call off some inner
            # receiver, peel it back to that inner receiver; otherwise return the
            # receiver unchanged. Only ONE `.set` hop is unwrapped — a deeper
            # chain leaves a non-constant receiver and declines downstream.
            def unwrap_set_hop(receiver)
              return receiver unless receiver.is_a?(Prism::CallNode)
              return receiver unless receiver.name.to_s == "set"

              receiver.receiver
            end
          end
        end
      end
    end
  end
end
