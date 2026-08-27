# frozen_string_literal: true

module Archbuddy
  module Reflect
    # Picks the boot strategy for a project. Order matters: the most specific
    # framework wins, and RequireGlobBoot is LAST because it always claims to
    # apply (it is the no-framework fallback, not a real detection).
    #
    # An explicit config choice ALWAYS beats detection — detection is a
    # convenience, never a mandate, so a project can override it when its layout
    # is unusual.
    class Registry
      BUILTIN = [RailsBoot, SinatraBoot, RackupBoot, GemBoot, RequireGlobBoot].freeze

      def self.strategies
        BUILTIN.map(&:new)
      end

      # @param root [String]
      # @param config [Hash, nil] the `reflect:` section of project config
      # @return [BootStrategy]
      def self.for(root, config: nil)
        cfg = normalize(config)
        if cfg[:command] || !cfg[:requires].empty? || cfg[:eager]
          return CustomBoot.new(requires: cfg[:requires], eager: cfg[:eager], command: cfg[:command])
        end

        if (named = cfg[:boot])
          found = strategies.find { |s| s.key.to_s == named.to_s }
          raise ArgumentError, "unknown reflect.boot #{named.inspect} " \
                               "(known: #{strategies.map(&:key).join(', ')})" unless found

          return found
        end

        strategies.find { |s| s.detect?(root) }
      end

      def self.normalize(config)
        c = config || {}
        {
          boot:     c["boot"]     || c[:boot],
          requires: Array(c["requires"] || c[:requires]),
          eager:    c["eager"]    || c[:eager],
          command:  c["command"]  || c[:command]
        }
      end
    end
  end
end
