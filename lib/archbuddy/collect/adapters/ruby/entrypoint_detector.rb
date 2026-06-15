# frozen_string_literal: true

module Archbuddy
  module Collect
    module Adapters
      module Ruby
        # Pluggable entrypoint strategy (K-4 / D4). Given the SymbolTable, choose
        # which method symbols are entrypoints. May return an empty list.
        #
        # Strategies:
        #   :default      controller actions + top-level defs
        #   :controllers  controller actions only
        #   :all_public   every instance method (rough "all public" surface)
        #   :none         none
        # Plus an optional regex list: any method whose fq symbol matches is
        # additionally included.
        class EntrypointDetector
          def initialize(config)
            @strategy = config.entrypoint_strategy
            @patterns = config.entrypoint_patterns
          end

          # @return [Array<String>] fq symbols of entrypoint methods.
          def detect(table)
            base =
              case @strategy
              when :controllers then controller_actions(table)
              when :all_public  then all_instance_methods(table)
              when :none        then []
              else                   default_set(table)
              end

            (base + pattern_matches(table)).uniq
          end

          private

          def default_set(table)
            (controller_actions(table) + top_level_defs(table)).uniq
          end

          def controller_actions(table)
            table.methods.values.select do |m|
              !m.singleton && m.owner_fq && table.controller_class?(m.owner_fq)
            end.map(&:fq_symbol)
          end

          def top_level_defs(table)
            table.methods.values.select { |m| m.owner_fq.nil? }.map(&:fq_symbol)
          end

          def all_instance_methods(table)
            table.methods.values.reject(&:singleton).map(&:fq_symbol)
          end

          def pattern_matches(table)
            return [] if @patterns.empty?

            table.methods.values.map(&:fq_symbol).select do |sym|
              @patterns.any? { |re| re.match?(sym) }
            end
          end
        end
      end
    end
  end
end
