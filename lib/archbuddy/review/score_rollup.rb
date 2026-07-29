# frozen_string_literal: true

module Archbuddy
  module Review
    # v0.16 presenter-lane score rollup (D-C1/D-C3).
    #
    # D17 BOUNDARY (L2 — the score is engine-computed, client-served): every
    # number this module returns is SELECTED or COUNTED from values the
    # engine published (`score`/`score_band`/`score_raw`, findings-1.9 names
    # verbatim, G1) — it NEVER computes, derives, or re-rounds a score.
    # `node_fresh?` is a staleness DETECTOR only; its output is never
    # published as a score.
    module ScoreRollup
      module_function

      # D-C1 negative-first dominance headline over one ep cone: `min` if
      # min <= -1, else `max` if max >= +1, else 0.0 — over the cone nodes
      # carrying a non-nil engine `score` stamp. nil when NO cone node
      # carries one (honest N/A, L6 — never a fabricated 0, which would
      # read "equilibrium", a verdict). Breakdown debt always wins the
      # headline over the absorb signal (min <= -1 first), and a cone of
      # {+4, 0} reads +4, never a masking 0.
      #
      # @param cone_nodes [Array<Vintage::Node>] one ep's cone (Graph#cone_nodes)
      # @return [Float, nil] an engine-published 2 dp score selected verbatim,
      #   0.0 when scored nodes exist but neither pole dominates, nil when none
      def ep_headline(cone_nodes)
        scores = cone_nodes.filter_map(&:score)
        return nil if scores.empty?

        min, max = scores.minmax
        return min if min <= -1
        return max if max >= 1

        0.0
      end

      # D-C3 per-node consistency check: the carried analyze-time `collapse`
      # stamp must equal the value recomputed from the fragment's
      # collect-fresh structural keys (`branches`, `outcome_arity` are
      # collect-time; `collapse` is analyze-time carried). A mismatch means
      # the node's body changed after its last analyze — the stamp is stale
      # and the gating rule degrades to a disclosure (T8), never gates.
      # nil `collapse` or `branches` => false (never fresh by default).
      #
      # HONEST LIMIT (documented, disclosed, never claimed detectable):
      # blast-only staleness — routing changed elsewhere without touching
      # this node — cannot be detected client-side; this check catches the
      # dangerous case (the node's own body changed since its stamp).
      #
      # @param node [Vintage::Node]
      # @return [Boolean]
      def node_fresh?(node)
        return false if node.collapse.nil? || node.branches.nil?

        node.collapse == (node.branches.to_f / [node.outcome_arity || 1, 1].max).round(2)
      end

      # Per-side score-provenance counts for the envelope/disclosures
      # (T10/T11): carried stamps always RENDER; this block discloses what
      # they reflect ("scores reflect the last analyze", D-C3).
      #
      # @param vintage [Review::Vintage] one side
      # @param source_label [String] the vintage_source provenance label
      #   ("committed-cache"/"stateless-collect"/"analyze-sides"/...)
      # @param fresh_analyze [Boolean] true for an `--analyze-sides` side —
      #   stamps are fresh BY CONSTRUCTION (D-C3), so the staleness detector
      #   is skipped and `stale_stamps` is 0 by construction
      # @return [Hash] {source:, analyzed:, serializer:, scored_nodes:,
      #   stale_stamps:} — serializer = the side's fragment serializer
      #   versions (sorted array; mixed-version caches are real);
      #   scored_nodes = nodes carrying a non-nil `score` stamp;
      #   stale_stamps = scored nodes failing the node_fresh? check
      def side_provenance(vintage, source_label:, fresh_analyze:)
        stamped = vintage.nodes.reject { |n| n.score.nil? }
        {
          source: source_label,
          analyzed: vintage.analyzed?,
          serializer: vintage.meta[:serializer_versions],
          scored_nodes: stamped.size,
          stale_stamps: fresh_analyze ? 0 : stamped.count { |n| !node_fresh?(n) }
        }
      end
    end
  end
end
