# frozen_string_literal: true

require_relative "resolver"

module Archbuddy
  module Collect
    module Adapters
      module Ruby
        # Abstract base for a framework-probe (P1 / L4). A probe is a NEW resolver
        # tier (R5) that sits AFTER the base tiers (R2/R3/R4) and BEFORE the R9
        # `<external>` sink: it recovers edges the base AST resolver can't see
        # because a framework wires them through a DSL (Grape mounts, Sidekiq
        # dispatch, ...). New framework support = a NEW Probe subclass registered
        # into ProbeRegistry, NOT a resolver rewrite.
        #
        # NEVER-FABRICATE (L2): a probe emits a Resolution (claim) ONLY when the
        # framework PROVABLY wires the target AND `ctx.table.method?(target_fq)` is
        # true (the same proof bar R3/R4 enforce — resolver.rb:68-72,88-89). When
        # the form is recognized but the target is unprovable (dynamic / unknown /
        # empty), the probe DECLINES (returns nil) so the call falls through to the
        # next probe / R9 `<external>` — it NEVER guesses an edge.
        #
        # A non-nil Resolution REPLACES the `<external>` fallthrough for that call
        # (P6 — the R5 loop early-returns); a probe never stacks a second edge.
        #
        # Subclasses MUST implement:
        #   #name           => a stable Symbol (e.g. :grape, :sidekiq_dispatch).
        #                      Used for provenance ONLY — rides on
        #                      Resolution#provenance / #tier and the
        #                      diagnostics[:probe_edges] tally. NEVER on graph.yml.
        #   #resolve(ctx)    => a RubyResolver::Resolution (claim) or nil (decline).
        #                      `ctx` is a RubyResolver::CallContext; probes read
        #                      `ctx.node` (the Prism::CallNode) and
        #                      `ctx.table.method?(...)`.
        #
        # Subclasses SHOULD also define a class method `self.probe_name` returning
        # the same Symbol as `#name`, so ProbeRegistry can select probes by name
        # without instantiating them.
        class Probe
          def name
            raise NotImplementedError, "#{self.class}#name must return a stable Symbol"
          end

          def resolve(_ctx)
            raise NotImplementedError,
                  "#{self.class}#resolve(ctx) must return a RubyResolver::Resolution or nil"
          end
        end
      end
    end
  end
end
