# frozen_string_literal: true

require_relative "probe"

module Archbuddy
  module Collect
    module Adapters
      module Ruby
        # Ordered, config-selected registry of framework probes (P1 / L4).
        # Mirrors Collect::Registry but is ORDERED — each call site is offered to
        # probes in priority order until one claims it (first non-nil wins) — and
        # config-selected (mirroring EntrypointDetector's config-driven selection).
        #
        # PROBES ships EMPTY in the seam wave so behavior is byte-identical to
        # today: `for(config)` returns [] for every config value until a concrete
        # probe is appended (W3 adds `grape` + `sidekiq_dispatch`). Routes-dispatch
        # is a SEEDER, not a probe, and is NOT in this map.
        module ProbeRegistry
          # Ordered probe classes in priority order. EMPTY in the seam wave —
          # W3 appends the concrete probe classes here (one line each).
          PROBES = [].freeze

          module_function

          # @param config [Collect::Config]
          # @return [Array<Probe>] ordered, config-selected probes, instantiated.
          def for(config)
            selected(config).map(&:new)
          end

          # @param config [Collect::Config]
          # @return [Array<Class>] the selected probe classes (uninstantiated).
          def selected(config)
            names = config.probes # Symbol :all/:none-normalized-to-[] OR Array<Symbol>
            return PROBES if names == :all
            return [] if names.nil? || names.empty?

            PROBES.select { |klass| names.include?(probe_name_for(klass)) }
          end

          # Read a probe class's name without instantiating it when possible.
          def probe_name_for(klass)
            klass.respond_to?(:probe_name) ? klass.probe_name : klass.new.name
          end
        end
      end
    end
  end
end
