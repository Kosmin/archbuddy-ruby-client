# frozen_string_literal: true

require_relative "receiver_shape"

module Archbuddy
  module Collect
    module Adapters
      module Ruby
        # `receiver_shape_counts` (configurator W4 / C13) — WHY the collector
        # could not resolve a call, counted by receiver shape.
        #
        # The collector already publishes HOW MANY calls fall through to the
        # shared `<external>` sink. That number alone is unactionable: it merges
        # "the receiver is a method parameter" (irreducible without types) with
        # "the receiver is an inline `Const.new`" (recoverable, and the literal-
        # receiver widening's whole target). Splitting the same denominator by
        # {ReceiverShape::SHAPES} turns one opaque number into a work list.
        #
        # WHY A CLASS AND NOT A COUNTER ON THE ACCUMULATOR. The tally needs two
        # decisions — "is this call site unresolved?" and "what shape is its
        # receiver?" — and both are policy. Writing them as a
        # `if resolution.tier == …` branch inside `ResolutionPass#record` would
        # put a new behaviour inline in an existing class. Instead the
        # Accumulator COMPOSES one of these (a field, not a branch) and the Pass
        # hands it every (ctx, resolution) pair unconditionally. Neither of them
        # knows what "unresolved" means.
        #
        # DIAGNOSTICS ONLY — NEVER GRAPH CONTENT. This rides the same carrier as
        # `probe_edges` and `egress_counts`: counts out to the CLI, nothing into
        # graph.yml, id-map.yml or the committed cache.
        #
        # IT MEASURES, IT DOES NOT WIDEN. Shipping the count is deliberately
        # separated from acting on it: claiming the `:chained` inline-`Const.new`
        # sites would move scores through the A6 back-door and belongs to its own
        # release. THE HONEST CAP, recorded here so the number is not read as a
        # promise: that widening would be bounded to the inline `Const.new`
        # idiom and EXCLUDES constructor-injected clients (`def initialize(gw)`),
        # so the more a codebase uses dependency injection the less of its
        # `:local`/`:ivar` bucket it could ever recover.
        class ReceiverShapeTally
          def initialize
            @counts = Hash.new(0)
          end

          # One observation per call site the resolution pass handled.
          #
          # THE PREDICATE LIVES HERE. "Unresolved" is the resolver's R9
          # fallthrough — every earlier tier either produced an edge, a db_op, a
          # declared crossing, a drop or a metaprogramming flag. The tier name is
          # read from its PRODUCER (RubyResolver::UNRESOLVED_TIER) rather than
          # re-typed, so renaming the tier cannot silently empty this tally.
          #
          # @param ctx [RubyResolver::CallContext]
          # @param resolution [RubyResolver::Resolution]
          # @return [void]
          def observe(ctx, resolution)
            return unless resolution.tier == RubyResolver::UNRESOLVED_TIER

            @counts[ReceiverShape.of(ctx.receiver)] += 1
          end

          # @return [Hash{Symbol => Integer}] observed shapes only. A shape that
          #   never occurred is ABSENT, not a fabricated zero — `{}` therefore
          #   means "nothing was unresolved", which is a real and different fact
          #   from "every bucket happens to be empty".
          def counts
            @counts.dup.freeze
          end

          def total
            @counts.values.sum
          end
        end
      end
    end
  end
end
