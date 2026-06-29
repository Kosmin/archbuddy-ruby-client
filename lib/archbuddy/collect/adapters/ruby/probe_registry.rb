# frozen_string_literal: true

require_relative "probe"
require_relative "probes/grape_probe"
require_relative "probes/dispatch_probe"

module Archbuddy
  module Collect
    module Adapters
      module Ruby
        # Ordered, config-selected registry of framework probes (P1 / L4).
        # Mirrors Collect::Registry but is ORDERED — each call site is offered to
        # probes in priority order until one claims it (first non-nil wins) — and
        # config-selected (mirroring EntrypointDetector's config-driven selection).
        #
        # The single ordered KNOWN map holds the concrete probes (W3): the Grape
        # mount-tree probe (`grape`) and the Sidekiq/ActiveJob dispatch probe
        # (`sidekiq_dispatch`). Each call site is offered to them in this order;
        # the two never claim the same call shape (mount vs perform_* dispatch),
        # so order is incidental — first non-nil still wins. Rails-routes is a
        # SEEDER, not a probe, and is deliberately NOT in this map.
        module ProbeRegistry
          # Ordered probe classes in priority order (P3: Grape before dispatch).
          PROBES = [
            Probes::GrapeProbe,
            Probes::DispatchProbe
          ].freeze

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
