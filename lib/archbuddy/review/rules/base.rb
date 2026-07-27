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

        # The ONE pinned rounding rule (2026-07-27 adversarial review; M2
        # published-rounding doctrine, M14): every user-set threshold gates
        # the value at PUBLISHED precision — the same round(6) the
        # components/message channels render — never the raw IEEE float.
        # Folded floats are composition-dependent at the boundary
        # (exp(ln 64 − ln 2) = 31.999999999999986 for a mathematical ×32;
        # Σ-ln folds carry 1-ulp noise around integer log2 boundaries).
        # ComplexityRatchet already gates at ITS published precision
        # (round(3), the %+.3f template) — the same rule on its own channel.
        PUBLISHED_PRECISION = 6

        private

        # Gate-side view of a folded value at published precision.
        def published(value)
          value.round(PUBLISHED_PRECISION)
        end
      end
    end
  end
end
