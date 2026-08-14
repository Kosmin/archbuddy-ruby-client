# frozen_string_literal: true

module Archbuddy
  module Collect
    # The ENGINE FLOOR CHECK (configurator W2 / C1).
    #
    # From W2 on, the collector reads its ecosystem vocabulary from a profile
    # document the ENGINE ships (`ArchitectureAuditor::Contract::Profiles`).
    # The gemspec declares that floor — and the gemspec is NOT ENFORCED on the
    # two wiring modes a developer actually uses: a `git:` source in the
    # Gemfile and `ARCHITECTURE_AUDITOR_PATH` both load whatever checkout they
    # are pointed at, at any version. So the range is documentation for
    # installers and this is the check that actually runs.
    #
    # ONE FAILURE, ONE MESSAGE. Without it, an engine below the floor fails
    # LATER and WRONGER: a `NameError: uninitialized constant …::Profiles`
    # raised from deep inside the resolver, which reads as a collector bug
    # rather than "your engine is too old". The message names the version
    # FOUND, so the fix is obvious from the one line.
    #
    # It lives in its own module, not inline in the CLI, because the CLI's job
    # is wiring: `cli/collect.rb` delegates in one line and owns no part of
    # this policy.
    module EnginePreflight
      # The engine version that first shipped Contract::Profiles.
      MINIMUM_VERSION = "0.12"

      module_function

      # @return [true] when the loaded engine satisfies the floor; otherwise
      #   warns and exits 1 (this is a precondition, not a recoverable state —
      #   there is no useful collect to attempt without a profile).
      def check!
        return true if satisfied?

        warn(message)
        exit 1
      end

      # Two independent facts, both required: the CAPABILITY (the constant the
      # collector calls) and the DECLARED version. Either alone can lie — a
      # partially-updated checkout can carry the constant under an old version
      # stamp, and a bumped version stamp does not conjure the constant.
      def satisfied?
        ArchitectureAuditor::Contract.const_defined?(:Profiles) &&
          Gem::Version.new(engine_version) >= Gem::Version.new(MINIMUM_VERSION)
      rescue ArgumentError
        false # unparseable version string -> unprovable -> refuse
      end

      def message
        "architecture_auditor >= #{MINIMUM_VERSION} required, found #{engine_version}"
      end

      def engine_version
        ArchitectureAuditor::VERSION
      end
    end
  end
end
