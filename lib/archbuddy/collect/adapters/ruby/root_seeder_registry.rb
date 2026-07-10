# frozen_string_literal: true

require_relative "root_seeder"
require_relative "root_seeders/job_seeder"
require_relative "root_seeders/rake_seeder"
require_relative "root_seeders/middleware_seeder"
require_relative "root_seeders/script_seeder"

module Archbuddy
  module Collect
    module Adapters
      module Ruby
        # Ordered, config-selected registry of ingress root seeders
        # (v0.10 W1-B — mirror of ProbeRegistry). Selection is driven by
        # `config.root_types` (the --root-types CLI flag) and is LENIENT —
        # an unknown name selects nothing, never raises — because root-type
        # names are owned by seeder waves this seam can't enumerate.
        #
        # ORDER MATTERS: `SEEDERS` order is the deterministic ingress
        # precedence for seeded categories (Reconciliation 2 —
        # jobs -> rake -> middleware -> script), because
        # SymbolTable#mark_entrypoint is first-write-wins. New root category
        # = a NEW RootSeeder subclass appended IN PRECEDENCE ORDER here.
        # NOTE: cron (W4b, LINK-only) will be OFF by default when it lands —
        # excluded from the default-on set, not just appended.
        #
        # THE RAKE ASYMMETRY (v0.10 W2-B): RakeSeeder is a documenting
        # no-op — task blocks have no DefNode, so rake roots are MINTED (and
        # :rake-categorized) in Pass 1 (DefinitionPass#mint_rake_task, F5
        # parity with ResolutionPass), BEFORE any seeder runs. It is listed
        # here so the precedence order reads complete and :rake is a known
        # --root-types name; selection does not gate the mint (rake is
        # structural, like Grape endpoints).
        module RootSeederRegistry
          # Ordered seeder classes in ingress-precedence order.
          SEEDERS = [
            RootSeeders::JobSeeder,
            RootSeeders::RakeSeeder,
            RootSeeders::MiddlewareSeeder,
            RootSeeders::ScriptSeeder
          ].freeze

          module_function

          # @param config [Collect::Config]
          # @return [Array<RootSeeder>] ordered, config-selected seeders, instantiated.
          def for(config)
            selected(config).map(&:new)
          end

          # @param config [Collect::Config]
          # @return [Array<Class>] the selected seeder classes (uninstantiated).
          def selected(config)
            names = config.root_types # :all OR Array<Symbol> (lenient-normalized)
            return SEEDERS if names == :all
            return [] if names.nil? || names.empty?

            SEEDERS.select { |klass| names.include?(root_type_for(klass)) }
          end

          # Read a seeder class's root type without instantiating it when possible.
          def root_type_for(klass)
            klass.respond_to?(:root_type) ? klass.root_type : klass.new.root_type
          end
        end
      end
    end
  end
end
