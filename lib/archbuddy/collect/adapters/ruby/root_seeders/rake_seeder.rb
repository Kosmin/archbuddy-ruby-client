# frozen_string_literal: true

require_relative "../root_seeder"

module Archbuddy
  module Collect
    module Adapters
      module Ruby
        module RootSeeders
          # Registry stand-in for the :rake root type (v0.10 W2-B).
          #
          # THE RAKE ASYMMETRY: rake roots CANNOT be seeded here. A
          # `task NAME do ... end` block has no DefNode, so its MethodEntry
          # must be MINTED during Pass 1 (DefinitionPass#mint_rake_task,
          # mirroring Grape's mint_endpoint) — and Pass 2 must push the
          # byte-identical FQ for its body calls to become edges (F5 ordinal
          # parity). Both happen BEFORE seeders run, and the :rake category
          # is stamped AT MINT via SymbolTable#mark_entrypoint (the one
          # entrypoint_category write for the fq). Like Grape endpoints —
          # and unlike the table-walker/AST seeders — rake detection is
          # therefore structural and NOT --root-types-selectable.
          #
          # This class exists so the registry's SEEDERS list documents the
          # FULL ingress precedence (jobs -> rake -> middleware -> script)
          # and so :rake is a recognized --root-types name rather than a
          # silently-unknown one. Its #seed is intentionally a no-op: the
          # mint already did the work (nothing to re-affirm — first-write-
          # wins already holds).
          class RakeSeeder < RootSeeder
            def self.root_type = :rake

            def root_type = :rake

            def seed(table, fragments: nil, root: nil); end
          end
        end
      end
    end
  end
end
