# frozen_string_literal: true

module Archbuddy
  module Review
    module Rules
      # The rule-class contract (I-P7'): class-level declarations consumed by
      # the engine, one instance method `#evaluate(ctx)`.
      #
      #   kind ∈ {:node, :use_case, :delta, :pr}
      #   required_node_keys — fragment keys the rule reads per node
      #   needs_edges?       — whether the rule requires vintage.edges?
      #
      # Rules NEVER read the todo (the ENGINE applies it to GRANDFATHERABLE
      # kinds — :node 4-step, :use_case per-metric 4-step; :delta/:pr never
      # receive it) and NEVER read presenter cost inputs (A4 presenter-only).
      class Base
        class << self
          def kind(value = nil)
            @kind = value unless value.nil?
            @kind
          end

          def required_node_keys(*keys)
            @required_node_keys = keys.flatten unless keys.empty?
            @required_node_keys || []
          end

          def needs_edges(flag = nil)
            @needs_edges = flag unless flag.nil?
            @needs_edges || false
          end

          def needs_edges?
            needs_edges
          end
        end

        def evaluate(ctx)
          raise NotImplementedError, "#{self.class}#evaluate(ctx)"
        end
      end
    end
  end
end
