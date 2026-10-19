# frozen_string_literal: true

module Archbuddy
  module Review
    # THE STANDING SIGNAL SET for one vintage — the snapshot `diff` cannot give.
    #
    # `SignalDelta` answers "what moved since the base", which is the right
    # question on a PR and the wrong one for a dashboard: a repo that has been
    # quietly bad for a year shows NO movement. This answers "what is flagged
    # right now", which is the series you actually chart.
    #
    # OUTPUT IS BOUNDED, DELIBERATELY. The compute is one pass over nodes the
    # vintage has already materialised, so cost is not the concern — VOLUME is.
    # A real service carries ~1,861 flagged nodes across the three signals, and
    # printing those as terminal lines would bury every other section of the
    # report and make `lint` useless on exactly the repos that need it most.
    # So the headline COUNTS are O(1) in output no matter how large the repo,
    # the detail list is capped, and the cap announces what it withheld rather
    # than silently truncating.
    #
    # THE DENOMINATOR SHIPS WITH THE NUMERATOR. "412 flagged" means nothing
    # without "of 6,635 measured", and `unmeasured` is published beside both:
    # a node whose vintage carried no signals block is UNKNOWN, not clean, and
    # folding it into the healthy majority would flatter every repo that has
    # not re-analyzed recently.
    class SignalCensus
      # Reuse the single producer rather than re-listing the verdicts, so a
      # fourth signal reaches both surfaces with one edit.
      VERDICTS = SignalDelta::VERDICTS

      # Matches the use-case leaderboard's cap, for one reason: a reader should
      # not have to learn a second number for how much of a list they are being
      # shown.
      TOP_N = 20

      Row = Data.define(:file, :symbol, :signal, :strength)

      def initialize(vintage)
        @vintage = vintage
      end

      # {signal => count}. Only signals that actually fire appear — a zero is
      # information a consumer can derive from `measured`, and emitting a row
      # of zeroes would make the summary line unreadable.
      def counts
        @counts ||= flagged_rows.each_with_object(Hash.new(0)) { |r, acc| acc[r.signal] += 1 }
      end

      def measured   = nodes_with_signals.length
      def unmeasured = @vintage.nodes.length - measured
      def flagged    = flagged_rows.length
      def any?       = flagged.positive?

      # Worst-first, capped. Sorted by strength DESC with the symbol as a
      # tiebreak so the list is stable across runs — an unstable top-N would
      # show spurious churn to anyone diffing two reports.
      def top(limit = TOP_N)
        flagged_rows.sort_by { |r| [-(r.strength || 0), r.symbol.to_s] }.first(limit)
      end

      def omitted(limit = TOP_N) = [flagged - limit, 0].max

      private

      def nodes_with_signals
        @nodes_with_signals ||= @vintage.nodes.select { |n| n.respond_to?(:signals) && n.signals }
      end

      def flagged_rows
        @flagged_rows ||= nodes_with_signals.flat_map do |node|
          sig = node.signals
          VERDICTS.filter_map do |verdict, evidence|
            next unless sig[verdict] == true

            Row.new(file: node.file, symbol: node.symbol, signal: verdict,
                    strength: evidence && sig[evidence])
          end
        end
      end
    end
  end
end
