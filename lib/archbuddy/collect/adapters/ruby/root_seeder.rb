# frozen_string_literal: true

module Archbuddy
  module Collect
    module Adapters
      module Ruby
        # Abstract base for an ingress ROOT SEEDER (v0.10 W1-B — mirror of
        # Probe, but for entrypoints instead of edges). A seeder inspects the
        # fully-built SymbolTable (and, for AST-shaped roots like rake tasks,
        # optionally the parsed fragments) and TAGS methods that are provably
        # execution roots with an ingress category via
        # `table.mark_entrypoint(fq, category)`.
        #
        # THE SEEDER CONTRACT:
        #   - NO nodes, NO edges. A seeder only categorizes methods that
        #     ALREADY exist in the table.
        #   - NEVER-FABRICATE (L4): every mark is gated on
        #     `table.method?(fq)` — when the root's handler method is not
        #     provably defined in-tree, the seeder DECLINES (marks nothing).
        #   - ONE category per fq: `mark_entrypoint` is first-write-wins, so
        #     registry order IS the deterministic ingress precedence
        #     (Reconciliation 2).
        #   - Category vocab is PLURAL (:jobs, :rake, :middleware, :script).
        #
        # Seeders run ONCE per collect, after Pass 1 + the route catalogue
        # (they read already-built table facts — superclass chains, mixins,
        # methods), NOT per-fragment.
        #
        # Subclasses MUST implement:
        #   .root_type / #root_type => a stable Symbol (e.g. :jobs). Used by
        #                              RootSeederRegistry's lenient
        #                              config-driven selection (--root-types).
        # Subclasses SHOULD override:
        #   #seed(table, fragments: nil) => tag roots. Default is a no-op.
        #     Table-walker seeders (jobs) ignore `fragments`; AST-shaped
        #     seeders (rake, later waves) re-walk them.
        class RootSeeder
          def root_type
            raise NotImplementedError, "#{self.class}#root_type must return a stable Symbol"
          end

          def seed(table, fragments: nil); end
        end
      end
    end
  end
end
