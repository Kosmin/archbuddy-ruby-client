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
      # v0.11 (v3/1.6): `median` (the P50 beside the outlier-dominated mean),
      # `median_grade` (the ENGINE-graded secondary letter — the client never
      # grades, D17) and `capped_fraction` (the censoring share; a capped mean
      # reads as a LOWER BOUND) ride along nil-tolerantly — all nil on v2/1.5
      # docs (additive-safe keyword_init members).
      DimensionScore = Struct.new(
        :key, :label, :question, :score, :grade, :hotspots, :na_reason,
        :median, :median_grade, :capped_fraction,
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
      # brevity; an all-zero (or absent) map renders "none" — an honest zero,
      # distinct from an absent block (which parses to nil upstream). Callers
      # (the W4 banners) supply the surrounding parentheses, so the empty case
      # reads "(none)", never "((none))".
      module ByCategoryDisplay
        def by_category_display
          present = (by_category || {}).reject { |_cat, count| count.to_i.zero? }
          return "none" if present.empty?

          present.map { |cat, count| "#{cat} #{count}" }.join(", ")
        end
      end

      # v0.11 (W-C): the ONE cost-line display helper shared by the
      # EntrypointCount and Egress counter structs (extracted from
      # EntrypointCount, behavior-preserving — existing rendered strings are
      # byte-identical). Expects `mean`/`median`/`by_category_cost` members.
      #
      # v0.11 addition: when a per-category entry carries a non-nil
      # `median_grade` (engine findings 1.6), the letter is appended INSIDE
      # the grade parens — "… (C, median: B)" (L17 secondary-letter
      # placement); absent → byte-identical to the v0.10 rendering.
      module CostLineDisplay
        def mean_display
          cost_display(mean)
        end

        def median_display
          cost_display(median)
        end

        # v0.10 W6: per-category cost line — e.g. "controllers mean 3.0 /
        # median 3.0 (B), uncategorized mean 1.0 / median 1.0 (A)". nil when
        # the engine has not published the per-category lens (collect-only
        # cache / pre-1.5 findings) so callers can omit the line entirely —
        # an honest absence, never noise beside real counts.
        def by_category_cost_display
          present = (by_category_cost || {}).reject do |_cat, dim|
            dim.nil? || (dim["mean"].nil? && dim["median"].nil?)
          end
          return nil if present.empty?

          present.map do |cat, dim|
            "#{cat} mean #{cost_display(dim['mean'])} / median #{cost_display(dim['median'])}#{grade_suffix(dim)}"
          end.join(", ")
        end

        private

        # " (C)" — or " (C, median: B)" when the engine published the 1.6
        # secondary letter (never computed client-side, D17). "" gradeless.
        def grade_suffix(dim)
          return "" unless dim["grade"]
          return " (#{dim['grade']})" if dim["median_grade"].nil?

          " (#{dim['grade']}, median: #{dim['median_grade']})"
        end

        # "—" when the engine has not published cost (collect-only cache /
        # pre-A2 engine) — an honest absence, never a fabricated number.
        def cost_display(value)
          return "—" if value.nil?

          format("%.1f", value)
        end
      end

      # v0.10 (A1): the committed `entrypoints` aggregate block — ingress
      # COUNTS by category. `mean`/`median` are the engine-published headline
      # per-entrypoint cost and `by_category_cost` the engine's per-category
      # lens ({cat => {mean, median, grade[, median_grade, capped_fraction]}}),
      # all copied VERBATIM at analyze time (W6/v0.11); nil/{} on a
      # collect-only cache (never computed client-side — D17).
      # v0.11: `capped_fraction` — the censoring share beside the mean.
      EntrypointCount = Struct.new(
        :total, :count, :by_category, :mean, :median, :by_category_cost,
        :capped_fraction,
        keyword_init: true
      ) do
        include ByCategoryDisplay
        include CostLineDisplay
      end

      # v0.10 (A1/C): the committed `egress` aggregate block — exit COUNTS by
      # egress category ({http, gem, queue, generic}; generic = the untagged
      # `<external>` bucket). v0.11 (v3): also carries the engine-published
      # egress COST keys (`mean`/`median`/`capped_fraction`/`by_category_cost`
      # — per-exit-point averages once E1 splits the sinks), mirroring the
      # `entrypoints` spellings exactly; all nil/absent on v2 docs.
      Egress = Struct.new(
        :total, :count, :by_category,
        :mean, :median, :capped_fraction, :by_category_cost,
        keyword_init: true
      ) do
        include ByCategoryDisplay
        include CostLineDisplay
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

      # v0.11 (W-C, L14): the `blast_radius` presentation model — Q3 "how many
      # use cases can a single change put at risk?". Everything VERBATIM from
      # the committed aggregate / findings 1.6 (D17); the ONLY arithmetic is
      # `ratio * 100` display formatting (the Connectivity#pct_display idiom).
      # The N/A form (zero entrypoints / nothing non-external reached) parses
      # to nil stats + empty worst — the presenter omits the question.
      BlastRadius = Struct.new(
        :max, :p90, :median, :mean, :reached_nodes, :total_nodes,
        :total_entrypoints, :pct_use_cases_hit_by_worst, :worst,
        keyword_init: true
      ) do
        # "97.4%" from the engine-emitted 0..1 ratio; "N/A" on the N/A form.
        def pct_display
          return "N/A" if pct_use_cases_hit_by_worst.nil?

          format("%.1f%%", pct_use_cases_hit_by_worst * 100)
        end
      end

      # One worst-offender entry ({symbol, use_cases_affected, added_coupling}
      # — factors displayed SEPARATELY, the reach x amplification product is
      # never computed/persisted, R7). added_coupling nil unless the node is
      # also a multiplexer proxy (never fabricated).
      BlastRadius::Worst = Struct.new(:symbol, :use_cases_affected, :added_coupling, keyword_init: true)

      # v0.11 (W-C, L15/L16): a findings-1.6 `stat_summary` block ({mean,
      # median, count} + optional by_category) for the flat forward_depth /
      # reverse_depth keys. `max` is a nil-only member in v0.11 (the engine
      # does not emit it — synthesis C3 deferred it to a 1.7 candidate; the
      # presenter's "worst {max}" clause drops nil-tolerantly).
      DepthStats = Struct.new(
        :mean, :median, :count, :max, :by_category,
        keyword_init: true
      )

      # v0.11 (W-C, L15): the ungraded per-hop branching density b-bar.
      # NO grade member EVER (grading hop counts against cost bands is a
      # category error); consumers render MEDIAN-FIRST (the mean is
      # degenerate-dominated on real graphs).
      BranchingFactor = Struct.new(
        :mean, :median, :count, :by_category,
        keyword_init: true
      )

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
          total:            block["total"],
          count:            block["count"],
          by_category:      block["by_category"],
          mean:             block["mean"],
          median:           block["median"],
          # v0.10 W6: engine per-category cost lens (nil/{} on pre-W6 docs —
          # graceful back-compat, the display helper treats both as absent)
          by_category_cost: block["by_category_cost"],
          # v0.11 (v3): the censoring share — nil on v2 docs (back-compat)
          capped_fraction:  block["capped_fraction"]
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
          by_category: block["by_category"],
          # v0.11 (v3): the engine-published egress cost keys — all nil on v2
          # docs (back-compat; per-exit-point averages post-E1)
          mean:             block["mean"],
          median:           block["median"],
          capped_fraction:  block["capped_fraction"],
          by_category_cost: block["by_category_cost"]
        )
      end

      # v0.11 (W-C): parse the committed aggregate's TOP-LEVEL `blast_radius`
      # block (already real-name — worst entries carry `symbol`). Returns a
      # BlastRadius, or NIL when absent/empty (v1/v2 docs) — the
      # entrypoints_from_aggregate nil-on-absent pattern.
      #
      # @param doc [Hash] parsed committed-aggregate doc (string keys)
      # @return [BlastRadius, nil]
      def blast_radius_from_aggregate(doc)
        block = (doc || {})["blast_radius"]
        return nil if block.nil? || block.empty?

        build_blast_radius(block) { |w| w["symbol"] }
      end

      # v0.11 (W-C): LEGACY variant — parse `scores.blast_radius` off an
      # opaque findings-1.6 doc, resolving each worst entry's `node` id via
      # the SAME id-map join (the multiplexer_proxies_from_findings pattern;
      # a missing id degrades to the opaque id, never raises).
      #
      # @param findings_doc [Hash] parsed findings.yml (string keys)
      # @param resolver     [#resolve, nil] id → Model::Location
      # @return [BlastRadius, nil]
      def blast_radius_from_findings(findings_doc, resolver = nil)
        block = ((findings_doc || {})["scores"] || {})["blast_radius"]
        return nil if block.nil? || block.empty?

        build_blast_radius(block) do |w|
          id  = w["node"]
          loc = resolver ? resolver.resolve(id) : nil
          loc&.symbol || id
        end
      end

      # Build one BlastRadius from either producer shape. The worst-entry
      # symbol comes from the yielded block (committed: `symbol` verbatim;
      # legacy: resolved `node` id). Everything else VERBATIM (D17).
      def build_blast_radius(block)
        BlastRadius.new(
          max:                        block["max"],
          p90:                        block["p90"],
          median:                     block["median"],
          mean:                       block["mean"],
          reached_nodes:              block["reached_nodes"],
          total_nodes:                block["total_nodes"],
          total_entrypoints:          block["total_entrypoints"],
          pct_use_cases_hit_by_worst: block["pct_use_cases_hit_by_worst"],
          worst: (block["worst"] || []).map do |w|
            BlastRadius::Worst.new(
              symbol:             yield(w),
              use_cases_affected: w["use_cases_affected"],
              added_coupling:     w["added_coupling"]
            )
          end
        )
      end

      # v0.11 (W-C): the flat `forward_depth` / `reverse_depth` aggregate
      # blocks (guard R1 — SAME spellings as findings; no `depth` grouping).
      # NIL on absent/empty (v1/v2 docs).
      def forward_depth_from_aggregate(doc)
        depth_stats_from((doc || {})["forward_depth"])
      end

      def reverse_depth_from_aggregate(doc)
        depth_stats_from((doc || {})["reverse_depth"])
      end

      # Legacy variants — the SAME flat keys under `scores` on an opaque
      # findings-1.6 doc (no ids inside → no resolver needed).
      def forward_depth_from_findings(findings_doc)
        depth_stats_from(((findings_doc || {})["scores"] || {})["forward_depth"])
      end

      def reverse_depth_from_findings(findings_doc)
        depth_stats_from(((findings_doc || {})["scores"] || {})["reverse_depth"])
      end

      # v0.11 (W-C): the ungraded `branching_factor` block. NIL on absent/empty.
      def branching_factor_from_aggregate(doc)
        branching_factor_from((doc || {})["branching_factor"])
      end

      def branching_factor_from_findings(findings_doc)
        branching_factor_from(((findings_doc || {})["scores"] || {})["branching_factor"])
      end

      # {mean, median, count[, max, by_category]} → DepthStats; nil on an
      # absent/empty block (absence, never a fabricated zero-struct). The
      # engine's degenerate {mean: nil, median: nil, count: 0} form parses to
      # an honest present-but-nil struct (the presenter omits the question).
      def depth_stats_from(block)
        return nil if block.nil? || block.empty?

        DepthStats.new(
          mean:        block["mean"],
          median:      block["median"],
          count:       block["count"],
          max:         block["max"], # nil-only in v0.11 (synthesis C3)
          by_category: block["by_category"]
        )
      end

      def branching_factor_from(block)
        return nil if block.nil? || block.empty?

        BranchingFactor.new(
          mean:        block["mean"],
          median:      block["median"],
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
          # v0.11 (v3/1.6): the committed `scores.<dim>` and findings
          # `scores.<dim>` spellings mirror 1:1 (guard R1), so this ONE
          # parser serves both paths — all three nil on v2/1.5 docs.
          median:          dim["median"],
          median_grade:    dim["median_grade"],
          capped_fraction: dim["capped_fraction"],
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
