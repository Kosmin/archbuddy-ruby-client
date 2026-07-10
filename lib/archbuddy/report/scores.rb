# frozen_string_literal: true

require_relative "model"

module Archbuddy
  module Report
    # R-8: the de-anonymized presentation model for findings.yml's OPTIONAL
    # project-level `scores` block (findings 1.1, additive over the per-node
    # metric kernel).
    #
    # The engine produces two eslint/rubocop-style dimensions, each a project
    # cost (unbounded, ≥0, or null) + letter grade + OPAQUE worst-first hotspot ids:
    #
    #   reverse_traceability    — "can you tell where code is USED?"
    #   forward_discoverability — "can you FOLLOW where execution goes?"
    #
    # The reporter copies score/grade VERBATIM (never recomputes — D17), and
    # de-anonymizes each dimension's hotspot ids via the SAME IdMapResolver used
    # everywhere else (graceful `<external …>` placeholders for missing/ext_ ids).
    #
    # A findings 1.0 doc has NO `scores` block; `Scores.from_findings` returns nil
    # in that case and the reporter renders exactly as before (back-compat).
    module Scores
      # Display order: reverse first (it's always computable; forward can be N/A).
      # Each entry: [findings key, human label, one-line framing question].
      DIMENSIONS = [
        ["reverse_traceability",    "Reverse Traceability",    "can you tell where code is used?"],
        ["forward_discoverability", "Forward Discoverability", "can you follow where execution goes?"]
      ].freeze

      # The metric(s) that drive each dimension's per-node penalty (engine
      # ProjectScorer). Surfaced next to each hotspot so the reader sees WHY a
      # node is a top contributor to this dimension — pulled VERBATIM from the
      # per-node `nodes.<id>.metrics` already in findings.yml (D17).
      DRIVING_METRICS = {
        "reverse_traceability"    => %w[fan_in centrality in_cycle],
        "forward_discoverability" => %w[path_length fan_out]
      }.freeze

      # Honest reason rendered when forward_discoverability is N/A because the
      # collection found no entrypoints (M3) — actionable, not a dead end.
      NA_REASON = "no entrypoints — re-collect with --entrypoints all_public"

      # A de-anonymized hotspot: a resolved Location plus the driving-metric
      # values for the dimension it's a hotspot of (verbatim from findings).
      Hotspot = Struct.new(:location, :metrics, keyword_init: true) do
        def symbol
          location.symbol
        end

        def file_line
          location.file_line
        end
      end

      # R1: the de-anonymized presentation model for the v0.7 `multiplexer_proxy`
      # smell (findings 1.4 `scores.multiplexer_proxies`). A multiplexer_proxy is
      # a method whose forward-discoverability arms are so divergent that it acts
      # as a hidden routing layer, ADDING coupling the call graph can't attribute
      # to any one caller. The engine ranks them worst-first by `added_coupling`.
      #
      # The report renders these VERBATIM (D17) — the client NEVER recomputes the
      # smell or its ranking. Two producer shapes are accepted:
      #
      #   * COMMITTED cache (real-name, the authoritative path): each entry is
      #     `{ "symbol" => "Klass#meth", "added_coupling" => <num> }` — already
      #     de-anonymized at WRITE time, so NO id-map/resolver is needed to read.
      #   * LEGACY opaque findings.yml: each entry is `{ "node" => <opaque id>,
      #     "added_coupling" => <num> }` — resolved via the SAME IdMapResolver used
      #     everywhere else (graceful `<external …>` placeholder for a missing id).
      #
      # `added_coupling` is copied verbatim; the model only FORMATS it for display.
      MultiplexerProxy = Struct.new(:location, :symbol, :added_coupling, keyword_init: true) do
        # "7.5" when present; "" when the producer emitted no coupling scalar
        # (an ids-only engine build — degrades gracefully, never fabricates a 0).
        def coupling_display
          return "" if added_coupling.nil?
          return added_coupling.to_s if added_coupling.is_a?(Integer)

          format("%.4f", added_coupling)
        rescue TypeError
          added_coupling.to_s
        end

        # "Klass#meth (app/x.rb:8)" when a Location resolved a file:line; the bare
        # symbol otherwise (the committed real-name path carries no line, so it is
        # symbol-only by design — line is display-only and stays in the id-map).
        def where
          return symbol if location.nil? || !location.resolved?

          fl = location.file_line
          fl.empty? ? symbol : "#{symbol} (#{fl})"
        end
      end

      # One dimension's de-anonymized presentation model. score/grade are
      # VERBATIM from findings.yml; hotspots are resolved Locations (worst-first).
      DimensionScore = Struct.new(
        :key, :label, :question, :score, :grade, :hotspots, :na_reason,
        keyword_init: true
      ) do
        # True when the engine could not determine a score (null score / "N/A"
        # grade) — e.g. forward_discoverability with no entrypoints.
        def na?
          score.nil?
        end

        # "58.0" (unbounded cost, 1 decimal) when scored; "N/A" when undeterminable.
        def display_score
          na? ? "N/A" : format("%.1f", score)
        end
      end

      # A project-level connectivity scalar (findings 1.3) — engine-emitted (D17).
      # NOT a dimension, NOT a metric kernel key. Surfaces an unrepresentative
      # sample (e.g. nexus 5/1672 nodes scored) instead of silently scoring "great".
      # Parallel to DimensionScore; explicitly NOT inside DIMENSIONS.map.
      #
      # Sub-fields conform to the four-field contract schema shape (CR-1):
      #   forward       — |reachable-from-entrypoints| / |nodes| (0..1 ratio or nil)
      #   reverse       — |connected-to-a-db_op-sink| / |nodes| (0..1 ratio or nil)
      #   scored_nodes  — integer ≥ 0
      #   total_nodes   — integer ≥ 1
      #
      # nil-tolerant: a 1.0/1.1/1.2 findings doc without the field → connectivity
      # is nil → no banner rendered, every existing assertion still passes.
      Connectivity = Struct.new(
        :forward, :reverse, :scored_nodes, :total_nodes,
        keyword_init: true
      ) do
        # "0.3%" from an engine-emitted ratio (0..1); "N/A" when the engine
        # emitted nil (e.g. a direction with no entrypoints, N1). Client only
        # FORMATS — D17. Never derives the percentage itself.
        def forward_pct_display
          pct_display(forward)
        end

        def reverse_pct_display
          pct_display(reverse)
        end

        # "5/1672" verbatim from engine counts; nil-safe.
        def scored_ratio
          return nil if scored_nodes.nil? || total_nodes.nil?

          "#{scored_nodes}/#{total_nodes}"
        end

        private

        def pct_display(ratio)
          return "N/A" if ratio.nil?

          format("%.1f%%", ratio * 100)
        end
      end

      # v0.10 (A1): shared display helper for the {category => count} maps on
      # the EntrypointCount / Egress counter structs. Skips zero buckets for
      # brevity; an all-zero (or absent) map renders "(none)" — an honest zero,
      # distinct from an absent block (which parses to nil upstream).
      module ByCategoryDisplay
        def by_category_display
          present = (by_category || {}).reject { |_cat, count| count.to_i.zero? }
          return "(none)" if present.empty?

          present.map { |cat, count| "#{cat} #{count}" }.join(", ")
        end
      end

      # v0.10 (A1): the committed `entrypoints` aggregate block — ingress
      # COUNTS by category. `mean`/`median` are engine-published per-category
      # cost (A2) copied VERBATIM at analyze time; nil on a collect-only cache
      # (never computed client-side — D17). Written by Cache::Writer in W3.
      EntrypointCount = Struct.new(
        :total, :count, :by_category, :mean, :median,
        keyword_init: true
      ) do
        include ByCategoryDisplay

        def mean_display
          cost_display(mean)
        end

        def median_display
          cost_display(median)
        end

        private

        # "—" when the engine has not published cost (collect-only cache /
        # pre-A2 engine) — an honest absence, never a fabricated number.
        def cost_display(value)
          return "—" if value.nil?

          format("%.1f", value)
        end
      end

      # v0.10 (A1/C): the committed `egress` aggregate block — exit COUNTS by
      # egress category ({http, gem, queue, generic}; generic = the untagged
      # `<external>` bucket). Counts only; written by Cache::Writer in W3.
      Egress = Struct.new(
        :total, :count, :by_category,
        keyword_init: true
      ) do
        include ByCategoryDisplay
      end

      # v0.10 (A1/D): the committed `dynamic_dispatch` coverage block —
      # {dynamic_sites, resolved_sites, total_call_sites, coverage_ratio}.
      # `ratio` (the parsed `coverage_ratio` — the visible share of dispatch,
      # 1 - dynamic/total) is nil (NOT 0.0 / 1.0) when there are zero call
      # sites — a ratio over an empty denominator is undefined, and rendering
      # a confident number would fabricate a coverage claim (L21 /
      # connectivity honesty).
      DynamicDispatch = Struct.new(
        :dynamic_sites, :resolved_sites, :total_call_sites, :ratio,
        keyword_init: true
      ) do
        def ratio_display
          return "N/A" if ratio.nil?

          format("%.1f%%", ratio * 100)
        end
      end

      module_function

      # Parse the OPTIONAL top-level scores.connectivity object. Returns a
      # Connectivity, or NIL when absent (1.0/1.1/1.2 docs) — graceful back-compat.
      #
      # @param findings_doc [Hash] parsed findings.yml (string keys)
      # @return [Connectivity, nil]
      def connectivity_from_findings(findings_doc)
        block = (findings_doc || {})["scores"]
        return nil if block.nil? || block.empty?

        conn = block["connectivity"]
        return nil if conn.nil? || conn.empty?

        Connectivity.new(
          forward:      conn["forward"],
          reverse:      conn["reverse"],
          scored_nodes: conn["scored_nodes"],
          total_nodes:  conn["total_nodes"]
        )
      end

      # v0.10 (A1): parse the OPTIONAL top-level `entrypoints` aggregate block.
      # Returns an EntrypointCount, or NIL when absent/empty (a pre-SERIALIZER-2
      # doc) — graceful back-compat, exactly like connectivity_from_findings.
      #
      # @param doc [Hash] parsed committed-aggregate doc (string keys)
      # @return [EntrypointCount, nil]
      def entrypoints_from_aggregate(doc)
        block = (doc || {})["entrypoints"]
        return nil if block.nil? || block.empty?

        EntrypointCount.new(
          total:       block["total"],
          count:       block["count"],
          by_category: block["by_category"],
          mean:        block["mean"],
          median:      block["median"]
        )
      end

      # v0.10 (A1/C): parse the OPTIONAL top-level `egress` aggregate block.
      #
      # @param doc [Hash] parsed committed-aggregate doc (string keys)
      # @return [Egress, nil]
      def egress_from_aggregate(doc)
        block = (doc || {})["egress"]
        return nil if block.nil? || block.empty?

        Egress.new(
          total:       block["total"],
          count:       block["count"],
          by_category: block["by_category"]
        )
      end

      # v0.10 (A1/D): parse the OPTIONAL top-level `dynamic_dispatch` coverage
      # block.
      #
      # @param doc [Hash] parsed committed-aggregate doc (string keys)
      # @return [DynamicDispatch, nil]
      def dynamic_dispatch_from_aggregate(doc)
        block = (doc || {})["dynamic_dispatch"]
        return nil if block.nil? || block.empty?

        DynamicDispatch.new(
          dynamic_sites:    block["dynamic_sites"],
          resolved_sites:   block["resolved_sites"],
          total_call_sites: block["total_call_sites"],
          # The committed key is `coverage_ratio` (v0.10 W3 vocab lock — the
          # synthesis gate name, superseding this plan's earlier `ratio`).
          ratio:            block["coverage_ratio"]
        )
      end

      # R1: parse the OPTIONAL `scores.multiplexer_proxies` smell list (findings
      # 1.4). Returns, in the engine's worst-first order (VERBATIM — never
      # re-sorted):
      #
      #   * an Array<MultiplexerProxy> (possibly EMPTY) when a `scores` block
      #     exists — [] means "scored, but no proxy / forward N/A" (NEVER a
      #     fabricated verdict — the caller renders an explicit "(none)" note).
      #   * NIL when there is no `scores` block at all (a 1.0/1.1/1.2/1.3 doc, or
      #     a committed aggregate written before analyze) — the caller OMITS the
      #     section entirely (absence, not emptiness).
      #
      # Accepts BOTH producer shapes: the committed real-name `{symbol, …}` entry
      # (resolver not consulted — already de-anonymized at WRITE) and the legacy
      # opaque `{node, …}` entry (resolved via the id-map). `resolver` may be nil
      # on the committed path (there is no id-map to read).
      #
      # @param findings_doc [Hash] parsed findings/aggregate doc (string keys)
      # @param resolver     [#resolve, nil] id → Model::Location (legacy path only)
      # @return [Array<MultiplexerProxy>, nil]
      def multiplexer_proxies_from_findings(findings_doc, resolver = nil)
        block = (findings_doc || {})["scores"]
        return nil if block.nil? || block.empty?
        return nil unless block.key?("multiplexer_proxies")

        (block["multiplexer_proxies"] || []).map do |proxy|
          build_multiplexer_proxy(proxy, resolver)
        end
      end

      # R2-1: parse the COMMITTED aggregate's TOP-LEVEL real-name smell list
      # (Cache::Writer emits `multiplexer_proxies: [{symbol, added_coupling}]` at
      # the doc root, worst-first). Already de-anonymized — no resolver, no
      # id-map. `list` is the array (possibly []); returns Array<MultiplexerProxy>
      # in the same worst-first order (VERBATIM).
      def multiplexer_proxies_from_committed(list)
        (list || []).map do |proxy|
          MultiplexerProxy.new(location: nil, symbol: proxy["symbol"], added_coupling: proxy["added_coupling"])
        end
      end

      # Build one MultiplexerProxy from either producer shape (VERBATIM order).
      def build_multiplexer_proxy(proxy, resolver)
        added = proxy["added_coupling"]

        if proxy.key?("symbol")
          # Committed real-name path: symbol is authoritative, no id-map needed.
          MultiplexerProxy.new(location: nil, symbol: proxy["symbol"], added_coupling: added)
        else
          # Legacy opaque path: resolve the node id via the same id-map join.
          loc = resolver ? resolver.resolve(proxy["node"]) : nil
          MultiplexerProxy.new(location: loc, symbol: loc&.symbol || proxy["node"], added_coupling: added)
        end
      end

      # Parse + de-anonymize the `scores` block. Returns an ordered Array of
      # DimensionScore (reverse first), or NIL when the findings doc carries no
      # scores block (a 1.0 doc) — graceful absence (back-compat).
      #
      # @param findings_doc [Hash] parsed findings.yml (string keys)
      # @param resolver     [#resolve] id → Model::Location (the SAME id-map join)
      # @return [Array<DimensionScore>, nil]
      def from_findings(findings_doc, resolver)
        block = (findings_doc || {})["scores"]
        return nil if block.nil? || block.empty?

        DIMENSIONS.map do |key, label, question|
          dim = block[key] || {}
          build_dimension(key, label, question, dim, findings_doc, resolver)
        end
      end

      def build_dimension(key, label, question, dim, findings_doc, resolver)
        score = dim["score"]
        DimensionScore.new(
          key:       key,
          label:     label,
          question:  question,
          score:     score,            # VERBATIM (D17) — unbounded cost (≥0) or nil
          grade:     dim["grade"],     # VERBATIM — "A".."F" or "N/A"
          hotspots:  build_hotspots(key, dim["hotspots"] || [], findings_doc, resolver),
          # Intentional for the current two-dimension contract: only
          # forward_discoverability can be N/A (no entrypoints, M3). reverse is
          # always computable, so a null reverse score gets no reason string. If
          # a future dimension becomes N/A-able, generalize this to a per-key map.
          na_reason: (score.nil? && key == "forward_discoverability" ? NA_REASON : nil)
        )
      end

      # De-anonymize each opaque hotspot id (worst-first order preserved) and
      # attach the dimension's driving-metric values pulled verbatim from the
      # per-node metrics already in findings.yml.
      def build_hotspots(key, opaque_ids, findings_doc, resolver)
        nodes        = (findings_doc || {})["nodes"] || {}
        driving_keys = DRIVING_METRICS.fetch(key, [])

        opaque_ids.map do |id|
          node_metrics = (nodes[id] || {})["metrics"] || {}
          driving      = driving_keys.each_with_object({}) { |k, h| h[k] = node_metrics[k] }

          Hotspot.new(location: resolver.resolve(id), metrics: driving)
        end
      end
    end
  end
end
