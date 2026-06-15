# frozen_string_literal: true

require_relative "model"
require_relative "reconnect"

module Archbuddy
  module Report
    # R-3: ranks de-anonymized Bottlenecks by clutter_score (descending) with a
    # deterministic tiebreak (by opaque id), supports an optional `--top N`, and
    # rolls bottlenecks up by `class_id` into class-level rollups (D9),
    # de-anonymizing the `cls_` ids via the same id-map.
    #
    # The Ranker is pure presentation ordering: it NEVER recomputes a node's
    # metrics or clutter_score (D17). For rollups it SUMS the children's
    # (verbatim) clutter_scores into a class total — a presentation aggregate,
    # not a re-derivation of any node metric.
    class Ranker
      def initialize(result)
        @result   = result
        @resolver = Reconnect::IdMapResolver.new(result.id_map)
      end

      # Bottlenecks sorted by clutter_score desc, deterministic tiebreak by id.
      # @param top [Integer,nil] keep only the N highest-scoring (nil = all)
      def ranked(top: nil)
        sorted = sort(@result.bottlenecks)
        top ? sorted.first(top) : sorted
      end

      # Class-level rollups (D9): group nodes by class_id, sum the children's
      # verbatim clutter_scores, de-anonymize the cls_ id, and rank the rollups
      # by their summed score (deterministic tiebreak by cls_ id).
      #
      # @param top [Integer,nil] keep only the N highest-scoring rollups
      def class_rollups(top: nil)
        grouped = @result.bottlenecks.group_by(&:class_id).reject { |cid, _| cid.nil? }

        rollups = grouped.map do |class_id, members|
          location = @resolver.resolve(class_id)
          total    = members.map { |b| b.clutter_score.to_f }.sum

          Model::Bottleneck.new(
            id:            class_id,
            location:      location,
            kind:          "class_rollup",
            class_id:      nil,
            # Aggregate display metric: number of member bottlenecks. We do NOT
            # synthesize the 8 node metrics for a class (that would be
            # recomputation); the rollup's score is the sum of member scores.
            metrics:       { "member_count" => members.length },
            clutter_score: total,
            findings:      members.flat_map(&:findings)
          )
        end

        sorted = sort(rollups)
        top ? sorted.first(top) : sorted
      end

      private

      # clutter_score DESC, then opaque id ASC for a stable, deterministic order.
      # nil scores sort last (treated as -infinity).
      def sort(bottlenecks)
        bottlenecks.sort_by do |b|
          score = b.clutter_score.nil? ? -Float::INFINITY : b.clutter_score.to_f
          [-score, b.id.to_s]
        end
      end
    end
  end
end
