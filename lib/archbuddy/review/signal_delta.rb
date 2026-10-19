# frozen_string_literal: true

module Archbuddy
  module Review
    # SIGNAL MOVEMENT BETWEEN TWO VINTAGES — the analytics half of a review.
    #
    # The score answers "is this change bigger or smaller". It does not answer
    # WHY, and the signals exist precisely to narrow that down: which nodes
    # carry the cost and what shape it has. Published for years with no
    # consumer, they were invisible — you could watch the aggregate move and
    # have nothing to attribute it to.
    #
    # This reads the committed fragments both sides already carry, so there is
    # no new collection, no new engine call and no new plumbing: the Delta's
    # entries hold each side's whole node payload, and `signals` has ridden
    # inside it since serializer 7.
    #
    # IT NEVER GATES, and that is a decision rather than an omission. A signal
    # is a bounce rate: worth watching, worth acting on, NOT worth failing a
    # build over, because the remedy is a judgement call and two reasonable
    # remedies for the same signal disagreed by 17 points on the same node set.
    # Gating on a number whose correct response is unknown converts a useful
    # diagnostic into a thing people route around. The ratchet gates on SCORE;
    # this reports MOVEMENT.
    #
    # WHAT COUNTS AS NEWS. A boolean that flipped, in either direction, and a
    # strength that moved materially. A node that was already flagged and still
    # is produces no line — that is the standing state, visible in `lint`, and
    # repeating it here would bury the three lines that are actually new.
    #
    # ABSENT IS NOT OFF. A side with no `signals` key (a pre-serializer-7
    # fragment, or a collect-only vintage that never analyzed) is UNKNOWN, and
    # an unknown side yields no verdict rather than a fabricated "turned off".
    class SignalDelta
      # The published verdicts, each with the evidence field that quantifies it.
      # Read from one place so adding a fourth signal is a one-line change here
      # rather than a hunt through the formatter.
      VERDICTS = {
        "fat_onion" => "onion_strength",
        "mixed_fan" => nil,
        "multiplexed_tree" => "downward"
      }.freeze

      # A strength has to move by more than this fraction to be reported. Small
      # drifts are the normal breathing of a graph under edit; reporting them
      # would make the section noise and train people to skip it.
      MATERIAL_SHARE = 0.10

      Movement = Data.define(:file, :symbol, :signal, :direction, :base_strength, :head_strength)

      def initialize(delta)
        @delta = delta
      end

      # [Movement] — flips first (the news), then material strength moves.
      def movements
        @movements ||= @delta.entries.flat_map { |e| movements_for(e) }
                             .sort_by { |m| [m.direction == :strength ? 1 : 0, m.file.to_s, m.symbol.to_s] }
      end

      def any? = movements.any?

      # Counts for the one-line summary: a reviewer should be able to read the
      # headline without expanding anything.
      def summary
        movements.each_with_object(Hash.new(0)) { |m, acc| acc[m.direction] += 1 }
      end

      private

      def movements_for(entry)
        base = signals_of(entry.base_node)
        head = signals_of(entry.head_node)
        return [] if base.nil? && head.nil?

        VERDICTS.filter_map do |verdict, evidence|
          movement(entry, verdict, evidence, base, head)
        end
      end

      # The Delta hands over a typed Vintage::Node, whose `signals` is the
      # block verbatim or nil. Reading `keys_present` rather than just nil-ness
      # keeps the two absences apart: a fragment that CARRIED the key with a
      # null value (the node was never measured) is a different fact from one
      # written before the key existed, and only the latter means "this vintage
      # cannot answer".
      def signals_of(node)
        return nil if node.nil?
        return nil unless node.respond_to?(:signals)

        node.signals
      end

      def movement(entry, verdict, evidence, base, head)
        b = base && base[verdict]
        h = head && head[verdict]

        # A flip is only a flip between two KNOWN verdicts. nil on either side
        # means the test could not be run there, which is not a change of state.
        if !b.nil? && !h.nil? && b != h
          return build(entry, verdict, h ? :fired : :cleared, base, head, evidence)
        end
        return nil unless evidence && b == h && h == true

        # Still flagged: report only if the evidence moved materially, so the
        # section stays about news rather than restating the standing state.
        bs = base && base[evidence]
        hs = head && head[evidence]
        return nil if bs.nil? || hs.nil? || bs.zero?
        return nil if ((hs - bs).abs / bs.to_f) <= MATERIAL_SHARE

        build(entry, verdict, :strength, base, head, evidence)
      end

      def build(entry, verdict, direction, base, head, evidence)
        Movement.new(file: entry.file, symbol: entry.symbol, signal: verdict,
                     direction: direction,
                     base_strength: evidence && base && base[evidence],
                     head_strength: evidence && head && head[evidence])
      end
    end
  end
end
