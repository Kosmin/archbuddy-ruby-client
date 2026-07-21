# frozen_string_literal: true

require "fileutils"
require "set"
require "json"
require_relative "canonical_json"
require_relative "layout"

module Archbuddy
  module Cache
    # C1-2: writes the COMMITTED, REAL-NAME, line-free `.archbuddy/` cache by
    # transcoding the opaque interchange (graph + SECRET id-map [+ findings]) at
    # WRITE time (DE-ANON-AT-WRITE — CR-1). A fresh clone reads the committed
    # cache DIRECTLY with NO id-map.
    #
    # Inputs (all string-keyed hashes as produced upstream):
    #   graph    — opaque graph (Anonymizer#call.graph): nodes[], edges[], entrypoints[]
    #   id_map   — SECRET id-map (Anonymizer#call.id_map): {"ids" => {opaque=>desc}}
    #   findings — OPTIONAL opaque findings.yml doc (engine analyze). When present,
    #              the root aggregate carries de-anonymized scores + the
    #              multiplexer_proxy list; when nil, the aggregate carries the
    #              structural summary only (collect-time, pre-analyze).
    #
    # Outputs (real-name, LINE-FREE — line is display-only, stays in the gitignored
    # id-map, NEVER serialized here, so a pure line move produces ZERO committed
    # diff — the C1 value-level line-stability invariant):
    #   archbuddy-findings.json                  ROOT compact aggregate (pointers)
    #   .archbuddy/<mirrored-src>[.json | /…]    adaptively-sharded detail tree
    #
    # v0.10 (SERIALIZER v2): the root aggregate additionally carries the three
    # committed counter blocks — ALWAYS present, honest-zero / null, never
    # fabricated (I2):
    #   entrypoints      — ingress counts {total, count, by_category, mean,
    #                      median, by_category_cost}; by_category seeds the
    #                      closed category set to 0; mean/median are the
    #                      ENGINE-published headline per-entrypoint cost and
    #                      by_category_cost the engine's per-category lens
    #                      ({cat => {mean, median, grade}}), both copied
    #                      verbatim at analyze (A2/W6) — null/{} until then.
    #   egress           — exit counts {total, count, by_category} over
    #                      {http, gem, queue, generic} (generic = untagged).
    #   dynamic_dispatch — {dynamic_sites, resolved_sites, total_call_sites,
    #                      coverage_ratio}; coverage_ratio = 1 - dynamic/total
    #                      (the VISIBLE share of dispatch), NULL on zero denom.
    # Fragment nodes additionally carry `entrypoint_kind` (the ingress category
    # string) beside the `entrypoint` boolean. The report surfaces all three
    # blocks as nil-tolerant banners (terminal + HTML — v0.10 W4).
    #
    # Canonical serialization (Cache::CanonicalJson): sorted object keys; arrays
    # canonically ordered HERE (nodes by symbol; edges by [from,to,calls] — the
    # C3 provably-total tiebreaker; proxies worst-first as the engine emits them);
    # fixed float precision. Two runs over the same tree → byte-identical bytes.
    class Writer
      # Bump when the committed serialization shape or canonical-ordering rule
      # changes, so a fragment written by an OLDER writer is NOT reused verbatim
      # by a newer collector (C2 collector-version stamp). NOTE: the stamp is a
      # SERIALIZATION-shape marker only — the fragment `content_hash` fold that
      # forces AST re-parse is `Reader::COLLECTOR_VERSION` (reader.rb /
      # change_detector.rb); a SERIALIZER bump rewrites every fragment's stamp
      # but does NOT force re-parse.
      #
      # v2 (v0.10 W3 / A1): the aggregate gained the three committed counter
      # blocks (`entrypoints`, `egress`, `dynamic_dispatch`) and fragment nodes
      # the `entrypoint_kind` category string beside the `entrypoint` boolean.
      #
      # v3 (v0.11 W-C — THE one serializer bump of the release, sole owner):
      # the aggregate additionally carries the findings-1.6 blocks VERBATIM —
      # `blast_radius` (worst-list de-anonymized to real symbols), flat
      # `forward_depth` / `reverse_depth` stat blocks, `branching_factor`
      # (UNGRADED, median-first) — plus `median`/`median_grade`/
      # `capped_fraction` beside every committed cost stat (`scores.<dim>`,
      # `entrypoints`, per-category lenses) and the previously-unread 1.5
      # egress cost keys (`egress.{mean, median, capped_fraction,
      # by_category_cost}` — per-exit-point averages post-E1). NOT a contract
      # (graph/findings) change — the committed cache is a client-owned shape.
      #
      # v4 (v0.12 counter wave — THE one serializer bump of the release, sole
      # owner): the aggregate additionally carries the findings-1.7
      # `variety_mass` block VERBATIM (UNGRADED — no grade key exists;
      # components {variety, mass} first-class beside the composite score;
      # `fallback_fraction` is THE L17 disclosure, `capped_fraction` the CAP
      # one; hotspots dropped — opaque, the headline_scores posture); fragment
      # nodes additionally carry `outcome_arity`/`escapes` (the collector
      # wave's keys, read from the id-map descriptor — they ride THIS stamp,
      # no second bump: ONE committed-cache churn event for the release).
      #
      # v5 (v0.13 compass wave — THE one serializer bump of the release, sole
      # owner): fragment nodes additionally carry the four per-node
      # REUSABILITY COMPASS stamps ({leverage, collapse, toll_booth,
      # quadrant} — COMPASS_KEYS), copied VERBATIM from findings 1.8's
      # top-level `reusability` map at analyze/reset; on a COLLECT-ONLY
      # rewrite (no findings) the stamps are CARRIED from the prior committed
      # fragment per surviving node (carry_prior_compass! — the
      # preserve_existing_scores rule applied per-fragment; compass values
      # are analyze-time and are never re-derived here, D17). The aggregate
      # additionally carries the `reusability` block folded VERBATIM from
      # findings-1.8 `scores.reusability_compass` (UNGRADED; toll-booth /
      # extraction worst-lists de-anonymized to real symbols — the
      # deanon_proxies pattern), and `reusability` joins the collect-only
      # carry list.
      SERIALIZER_VERSION = 5

      # v0.13 (v5): the per-node compass stamp keys on committed fragment
      # nodes. All four ALWAYS present on a v5 fragment (deterministic shape,
      # the outcome_arity posture): null = "never analyzed / no compass entry"
      # (non-in-tree kind, the vty N/A gate, a pre-1.8 engine); toll_booth
      # false is a REAL engine verdict, never fabricated from null. `quadrant`
      # rides the stamp because the report side panel's ONLY per-node data
      # route on the default committed path is the fragment (findings.yml is
      # not readable there).
      COMPASS_KEYS = %w[leverage collapse toll_booth quadrant].freeze

      # @param project_root [String] the audited repo root (CWD by default).
      def initialize(project_root: Dir.pwd)
        @project_root = File.expand_path(project_root)
      end

      # Transcode + write the committed cache. Returns the repo-relative paths of
      # every committed file written (for the CLI + `--check`).
      #
      # @param diagnostics [Hash, nil] the collect-time AdapterResult.diagnostics
      #   carrier (v0.10 W3, Reconciliation 1) — the single producer→writer
      #   handshake for the `egress` (`:egress_counts`) and `dynamic_dispatch`
      #   (`:meta_sites_skipped`/`:meta_resolved`/`:total_call_sites`) folds.
      #   nil on a write without a fresh collect (the analyze path): the
      #   previously committed blocks are carried forward VERBATIM (never
      #   zero-clobbered, never recomputed from nothing).
      # @return [Hash] { aggregate: <rel>, fragments: [<rel>, …] }
      def write(graph:, id_map:, findings: nil, diagnostics: nil)
        resolver  = Deanonymizer.new(id_map)
        by_file   = group_nodes_by_file(graph, resolver, findings && findings["reusability"])
        edges     = deanonymize_edges(graph, resolver)
        entry_set = entrypoint_symbols(graph, resolver)

        pointers  = {}
        written   = []

        by_file.each do |rel_file, nodes|
          # v0.13 (v5): compass stamps are ANALYZE-time — a collect-only
          # rewrite grafts the PRIOR committed fragment's stamps (per
          # surviving node) BEFORE the fragment is rebuilt, so a plain
          # collect never clobbers them to null (the preserve_existing_scores
          # rule, per-fragment).
          carry_prior_compass!(rel_file, nodes) if findings.nil?
          fragment = build_fragment(rel_file, nodes, edges, entry_set)
          mode, files = write_fragment(rel_file, fragment)
          pointers[rel_file] = { "path" => committed_path_for(rel_file, mode), "shard_mode" => mode }
          written.concat(files)
        end

        aggregate_rel = write_aggregate(pointers, findings, resolver, graph, diagnostics)
        { aggregate: aggregate_rel, fragments: written }
      end

      private

      # --- fragment assembly (real-name, line-free) -----------------------------

      # Group de-anonymized method/db_op nodes by their owning source file. The
      # external sink (no file) is excluded from the committed detail tree — it
      # carries no app semantics and no real path.
      #
      # `reusability` is findings 1.8's OPTIONAL top-level per-node map (opaque
      # id → compass entry), present only on the analyze/reset path; nil at
      # collect (carry_prior_compass! grafts prior stamps there) and on
      # pre-1.8 findings (stamps write null — honest absence, never derived).
      def group_nodes_by_file(graph, resolver, reusability)
        grouped = Hash.new { |h, k| h[k] = [] }
        (graph["nodes"] || []).each do |node|
          desc = resolver.describe(node["id"])
          file = desc && desc["file"]
          next if file.nil? # external sink / unmapped → not a committed source node

          compass = reusability && reusability[node["id"]]
          grouped[file] << {
            "symbol"    => desc["symbol"],
            "kind"      => desc["kind"],
            # owning class REAL symbol (class-path key), nil for top-level
            "class"     => resolver.class_symbol(desc["class_id"]),
            # opaque path-cost integers carry no app semantics; keep them
            "branches"  => node["branches"],
            "decisions" => node["decisions"],
            # v0.10 W3 (A1): the ingress category string from the id-map
            # descriptor (W1-A1 stamp) — rides the committed fragment beside
            # the `entrypoint` boolean. nil for non-entrypoints and for
            # category-unknown entrypoints. A category word, NOT a line —
            # the C1 line-free invariant is untouched.
            "entrypoint_kind" => desc["entrypoint_kind"],
            # v0.12 (v4): the collector wave's outcome contract, read from the
            # id-map descriptor mirror (unconditional there — the committed
            # layer never re-derives). `outcome_arity` int|null (null =
            # statically unresolved / sink — NEVER fabricated, L17);
            # `escapes` bool (descriptor nil reads false). Not a line, not an
            # id — the C1 line-free invariant is untouched.
            "outcome_arity"   => desc["outcome_arity"],
            "escapes"         => desc["escapes"] || false,
            # v0.13 (v5): the per-node REUSABILITY COMPASS stamps, copied
            # VERBATIM from findings 1.8's top-level `reusability` map
            # (keyed by opaque id) at analyze/reset — real-name
            # localization: any function's leverage / collapse / toll-booth
            # flag / quadrant is browsable in the committed cache. null when
            # the node carries no compass entry (non-in-tree kind, the vty
            # N/A gate, a pre-1.8 engine) — never fabricated; toll_booth
            # false is a real engine verdict, null means "never analyzed".
            # Numbers, booleans, and a quadrant word — NOT a line, NOT an
            # id: the C1 line-free invariant is untouched.
            "leverage"        => compass && compass["leverage"],
            "collapse"        => compass && compass["collapse"],
            "toll_booth"      => compass && compass["toll_booth"],
            "quadrant"        => compass && compass["quadrant"]
            # NO line — display-only, resolved at RENDER from the id-map.
          }
        end
        grouped
      end

      # De-anonymize every graph edge to real (from_symbol, to_symbol, calls).
      # An edge whose endpoint is unmapped (external sink) resolves to the sink's
      # placeholder symbol so the structural signal is preserved.
      def deanonymize_edges(graph, resolver)
        (graph["edges"] || []).map do |edge|
          {
            "from"  => resolver.symbol(edge["from"]),
            "to"    => resolver.symbol(edge["to"]),
            "calls" => edge["calls"]
          }
        end
      end

      def entrypoint_symbols(graph, resolver)
        (graph["entrypoints"] || []).map { |id| resolver.symbol(id) }.compact.to_set
      end

      # A single source file's committed fragment (real-name, line-free), with
      # canonical array ordering imposed here so the bytes are stable.
      def build_fragment(rel_file, nodes, all_edges, entry_set)
        node_symbols = nodes.map { |n| n["symbol"] }.to_set
        file_edges   = all_edges.select { |e| node_symbols.include?(e["from"]) }

        {
          "serializer_version" => SERIALIZER_VERSION,
          "file"               => rel_file,
          "nodes"              => nodes
                                    .map { |n| n.merge("entrypoint" => entry_set.include?(n["symbol"])) }
                                    .sort_by { |n| n["symbol"].to_s },
          "edges"              => file_edges.sort_by { |e| [e["from"].to_s, e["to"].to_s, e["calls"].to_i] }
        }
      end

      # --- v0.13 (v5): the per-fragment compass carry ---------------------------

      # v0.13 (v5, the verifier MAJOR-2 mechanism): compass values exist only
      # in findings (analyze-time), but a collect rewrites every fragment
      # WITHOUT findings — a plain stamp would be CLOBBERED to null on every
      # collect (and `--check` would drift between collect and analyze).
      # Mirror preserve_existing_scores PER FRAGMENT: read the PRIOR committed
      # fragment and graft its compass keys onto each surviving node (matched
      # by real symbol). Keys drop only when the node itself is gone (it is
      # not emitted at all); a prior without the keys (a v4 fragment) grafts
      # nothing — a collect never manufactures stamps; a first-ever collect
      # has no prior — stamps stay null until the first analyze.
      def carry_prior_compass!(rel_file, nodes)
        prior = prior_fragment_compass(rel_file)
        return if prior.empty?

        nodes.each do |node|
          stamps = prior[node["symbol"]]
          next unless stamps

          COMPASS_KEYS.each { |key| node[key] = stamps[key] if stamps.key?(key) }
        end
      end

      # {real symbol => {compass keys the prior fragment node carries}} for one
      # source file's PRIOR committed fragment — reads whichever layout the
      # prior write chose (single file or shard dir; the reader trusts the
      # committed tree, never re-derives the layout choice). {} when there is
      # no prior fragment or no node carries a compass key (a v4-vintage
      # tree). First occurrence wins across shards (the writer emits identical
      # node payloads per symbol — the DetailTree rule).
      def prior_fragment_compass(rel_file)
        index = {}
        prior_fragment_docs(rel_file).each do |doc|
          (doc["nodes"] || []).each do |node|
            sym = node["symbol"]
            next if sym.nil? || index.key?(sym)

            stamps = node.slice(*COMPASS_KEYS)
            index[sym] = stamps unless stamps.empty?
          end
        end
        index
      end

      # Every parsed prior committed fragment doc for a source file — [] when
      # absent; a corrupt/unreadable fragment is skipped (fail-safe: it cannot
      # carry anything, exactly the read_prior_aggregate posture).
      def prior_fragment_docs(rel_file)
        single = File.join(@project_root, Layout.single_path(rel_file))
        shard  = File.join(@project_root, Layout.shard_dir(rel_file))
        paths =
          if File.file?(single)
            [single]
          elsif File.directory?(shard)
            Dir.glob(File.join(shard, "**", "*.json")).sort
          else
            []
          end

        paths.filter_map do |path|
          JSON.parse(File.read(path))
        rescue StandardError
          nil
        end
      end

      # --- committed write + adaptive sharding ---------------------------------

      # Write a fragment, choosing SINGLE vs per-class vs per-method by serialized
      # size (Layout, pure function → deterministic for `--check`). Returns the
      # [shard_mode, [rel_paths_written]].
      def write_fragment(rel_file, fragment)
        serialized = CanonicalJson.dump(fragment)

        if Layout.over_threshold?(serialized.bytesize)
          write_sharded(rel_file, fragment)
        else
          rel = Layout.single_path(rel_file)
          write_file(rel, serialized)
          [Layout::MODE_SINGLE, [rel]]
        end
      end

      # Split a large file per class (then per method for a class still over the
      # threshold). The file-level metadata rides a `_file.json` header so the
      # directory is self-describing without probing.
      def write_sharded(rel_file, fragment)
        dir = Layout.shard_dir(rel_file)
        written = []
        by_class = fragment["nodes"].group_by { |n| n["class"] || n["symbol"] }

        mode = Layout::MODE_PER_CLASS
        by_class.sort_by { |cls, _| cls.to_s }.each do |cls, cls_nodes|
          cls_edges = fragment["edges"].select { |e| cls_nodes.any? { |n| n["symbol"] == e["from"] } }
          cls_doc = {
            "serializer_version" => SERIALIZER_VERSION,
            "file"               => rel_file,
            "class"              => cls,
            "nodes"              => cls_nodes,
            "edges"              => cls_edges
          }
          cls_serialized = CanonicalJson.dump(cls_doc)
          safe_cls = sanitize(cls)

          if Layout.over_threshold?(cls_serialized.bytesize)
            mode = Layout::MODE_PER_METHOD
            cls_nodes.each do |node|
              method_doc = cls_doc.merge(
                "method" => node["symbol"],
                "nodes"  => [node],
                "edges"  => cls_edges.select { |e| e["from"] == node["symbol"] }
              )
              rel = File.join(dir, safe_cls, "#{sanitize(node["symbol"])}.json")
              write_file(rel, CanonicalJson.dump(method_doc))
              written << rel
            end
          else
            rel = File.join(dir, "#{safe_cls}.json")
            write_file(rel, cls_serialized)
            written << rel
          end
        end

        [mode, written.sort]
      end

      # --- root aggregate (compact: scores + smell + POINTERS) -----------------

      def write_aggregate(pointers, findings, resolver, graph, diagnostics)
        rel = Layout::ROOT_AGGREGATE

        doc = {
          "serializer_version" => SERIALIZER_VERSION,
          # POINTERS into the detail tree — payload NOT inlined (stays small).
          "sources"            => pointers.sort.to_h
        }

        # v0.10 W3 (A1, serializer v2): the three committed counter blocks —
        # peers of `scores`, refreshed on every write that carries their data
        # source. `entrypoints` is a pure fold over graph + id-map (always
        # present). `egress`/`dynamic_dispatch` fold from the collect-time
        # `diagnostics` carrier (Reconciliation 1 — the writer never re-parses
        # sink symbols); a diagnostics-free write (analyze re-transcode) carries
        # the previously committed blocks forward VERBATIM. No block is ever
        # OMITTED — an explicit honest zero is distinct from absence (I2).
        prior = diagnostics.nil? ? read_prior_aggregate(rel) : nil
        doc["entrypoints"]      = entrypoint_counts(graph, resolver, findings)
        doc["egress"]           = egress_block(diagnostics, graph, prior)
        doc["dynamic_dispatch"] = dynamic_dispatch_block(diagnostics, prior)

        if findings
          # analyze/reset path: fold in the fresh de-anonymized scores + smell.
          scores = findings["scores"]
          if scores
            doc["scores"]              = headline_scores(scores)
            doc["multiplexer_proxies"] = deanon_proxies(scores, resolver)
            # v0.11 (serializer v3, W-C): the findings-1.6 blocks, copied
            # VERBATIM (D17) — block-present-iff-source-present (a 1.5 doc
            # writes none of them; absence, never fabricated nulls). The ONLY
            # computation is the blast worst-list de-anonymization.
            doc["blast_radius"]     = blast_radius_block(scores, resolver) if scores.key?("blast_radius")
            doc["forward_depth"]    = stat_copy(scores["forward_depth"])   if scores.key?("forward_depth")
            doc["reverse_depth"]    = stat_copy(scores["reverse_depth"])   if scores.key?("reverse_depth")
            doc["branching_factor"] = stat_copy(scores["branching_factor"]) if scores.key?("branching_factor")
            # v0.12 (serializer v4): the findings-1.7 UNGRADED Variety+Mass
            # block, verbatim — block-present-iff-source-present (a 1.6 doc
            # writes no key; the engine N/A form passes through present-but-
            # null). Hotspots dropped at both levels (opaque).
            doc["variety_mass"] = variety_mass_block(scores) if scores.key?("variety_mass")
            # v0.13 (serializer v5): the findings-1.8 UNGRADED Reusability
            # Compass summary, verbatim — block-present-iff-source-present
            # (a 1.7 doc writes no key). The ONLY computation is the
            # toll-booth / extraction worst-list de-anonymization.
            doc["reusability"] = reusability_block(scores, resolver) if scores.key?("reusability_compass")
            # v0.11: light up the (1.5-live, until-now-unread) egress cost
            # keys — per-exit-point averages once E1 splits the sinks.
            merge_egress_cost!(doc["egress"], scores)
          end
        else
          # collect path (no findings yet): PRESERVE any scores + smell already
          # committed by a prior analyze/reset, so a plain `collect` (e.g. an
          # incremental re-collect after a cosmetic edit) refreshes only the
          # structural pointers and does NOT clobber the aggregate's score block
          # — the C1 blank-line-clean invariant holds for the SAME committed doc.
          preserve_existing_scores(rel, doc)
        end

        write_file(rel, CanonicalJson.dump(doc))
        rel
      end

      # Carry forward the scores + multiplexer_proxies from an already-committed
      # aggregate (written by a previous analyze/reset) when the current write is
      # a collect-only (findings nil). No-op if there is no prior aggregate or it
      # carries no scores.
      #
      # v0.11 (v3): the carry list is EXTENDED with every v3 block —
      # blast_radius / forward_depth / reverse_depth / branching_factor ride
      # forward verbatim, and the egress COST keys are grafted onto the
      # freshly-folded counts (counts stay fresh from diagnostics; cost is
      # engine-published and a collect never recomputes it — D17). A v2 prior
      # (no v3 keys) grafts nothing — a collect over a v2 cache does NOT
      # manufacture v3 blocks. v0.12 (v4): `variety_mass` joins the carry
      # list under the same rule — a v3 prior (no v4 key) grafts nothing.
      # v0.13 (v5): `reusability` joins too — a v4 prior grafts nothing.
      def preserve_existing_scores(rel, doc)
        prior = read_prior_aggregate(rel)
        return if prior.nil?

        doc["scores"]              = prior["scores"]              if prior.key?("scores")
        doc["multiplexer_proxies"] = prior["multiplexer_proxies"] if prior.key?("multiplexer_proxies")
        %w[blast_radius forward_depth reverse_depth branching_factor variety_mass reusability].each do |key|
          doc[key] = prior[key] if prior.key?(key)
        end
        carry_egress_cost!(doc["egress"], prior["egress"]) if prior["egress"].is_a?(Hash)
      end

      # v0.11 (v3): graft the prior aggregate's egress COST keys onto the
      # freshly-folded counts block. Only keys the prior actually carries are
      # grafted (a v2 prior has none — nothing manufactured).
      def carry_egress_cost!(egress_doc, prior_egress)
        %w[mean median capped_fraction by_category_cost].each do |key|
          egress_doc[key] = prior_egress[key] if prior_egress.key?(key)
        end
      end

      # The already-committed root aggregate, parsed — or nil when absent or
      # corrupt (a fresh tree / a hand-mangled doc → just write structurally).
      def read_prior_aggregate(rel)
        abs = File.join(@project_root, rel)
        return nil unless File.exist?(abs)

        JSON.parse(File.read(abs))
      rescue StandardError
        nil
      end

      # --- v0.10 W3 (A1): committed counter blocks ------------------------------

      # The CLOSED ingress category vocabulary (Reconciliation 2) — every key is
      # seeded to 0 so a category is visible even at zero (L2: jobs/rake/… read 0
      # until their detectors land). `unknown` is NOT a category: it is the
      # declared "no category data" bucket for a nil `entrypoint_kind` (an
      # entrypoint whose category source is absent — bucketed, never guessed).
      ENTRYPOINT_CATEGORIES = %w[
        controllers grape routed top_level jobs rake middleware script pattern
      ].freeze

      # The closed egress category vocabulary (L18/CR-3): `generic` is the
      # untagged `<external>` bucket (nil-category tally), never `unknown`.
      EGRESS_CATEGORIES = %w[http gem queue generic].freeze

      # A1 ingress COUNTS + engine-published COST: fold the graph
      # `entrypoints:` id list through the id-map descriptor's
      # `entrypoint_kind` (the W1-A1 categorized stamp). Counts are
      # client-computed; COST is copied VERBATIM (D17) from the engine
      # findings when present (v0.10 W6 — the read lit up once engine
      # findings 1.5 published the cost surfaces):
      #   mean/median        — the headline per-entrypoint forward dimension
      #                        (`scores.forward_discoverability`): mean is the
      #                        dimension `score` (the arithmetic mean over
      #                        entrypoints), median its 1.5 `median` sibling
      #                        (L7 — the median beside the outlier-dominated
      #                        mean). Honest null on a collect-only write and
      #                        on pre-1.5 findings (no `median` key → null).
      #   by_category_cost   — `scores.forward_discoverability_by_category`
      #                        ({category => dimension_score}) compacted to
      #                        {category => {mean, median, grade}} (hotspots
      #                        dropped — opaque, exactly like headline_scores).
      #                        {} when the engine has not published the lens.
      # The client NEVER computes cost (D17) — absent source → null/{}.
      def entrypoint_counts(graph, resolver, findings)
        by_category = ENTRYPOINT_CATEGORIES.to_h { |cat| [cat, 0] }
        ids = graph["entrypoints"] || []

        ids.each do |id|
          desc = resolver.describe(id)
          cat  = (desc && desc["entrypoint_kind"]) || "unknown"
          by_category[cat] = by_category.fetch(cat, 0) + 1
        end

        scores  = (findings || {})["scores"] || {}
        forward = scores["forward_discoverability"] || {}

        {
          "total"            => ids.length,
          "count"            => ids.length,
          "by_category"      => by_category,
          "mean"             => forward["score"],
          "median"           => forward["median"],
          # v0.11 (v3): the censoring share beside the graded mean (L8/F2) —
          # verbatim, null until the engine publishes it (1.6).
          "capped_fraction"  => forward["capped_fraction"],
          "by_category_cost" => entrypoint_cost_by_category(scores)
        }
      end

      # v0.10 W6: the per-category ingress cost map, copied VERBATIM from the
      # engine's findings-1.5 `forward_discoverability_by_category` lens.
      # Category keys are the engine's grouping of the client-stamped
      # `entrypoint_kind` (nil-stamp entrypoints bucket under the ENGINE's
      # "uncategorized" key — distinct from the client count bucket "unknown";
      # copied verbatim, never remapped). {} on pre-1.5 findings or a
      # collect-only write — an honest empty, never fabricated (I2).
      def entrypoint_cost_by_category(scores)
        cost_lens_compaction(scores["forward_discoverability_by_category"])
      end

      # v0.11 (v3): the ONE per-category cost-lens compaction — shared by the
      # `entrypoints` and `egress` folds so both carry the SAME shape
      # ({mean, median, grade, median_grade, capped_fraction}; hotspots
      # dropped — opaque, exactly like headline_scores). {} on an absent lens.
      def cost_lens_compaction(lens)
        return {} unless lens.is_a?(Hash)

        lens.to_h do |category, dim|
          [category, {
            "mean"            => dim["score"],
            "median"          => dim["median"],
            "grade"           => dim["grade"],
            "median_grade"    => dim["median_grade"],
            "capped_fraction" => dim["capped_fraction"]
          }]
        end
      end

      # v0.11 (v3): graft the engine's 1.5 egress COST dimension onto the
      # committed egress COUNTS block (counts logic untouched — the E1
      # boundary). `mean` is the dimension `score` (arithmetic mean), exactly
      # the `entrypoints` spelling. Post-E1 per-target sinks these numbers
      # become per-exit-point averages with zero further change. No-op on
      # pre-1.5 findings (no `scores.egress` → no cost keys, absence not
      # fabricated nulls).
      def merge_egress_cost!(egress_doc, scores)
        eg = scores["egress"]
        return unless eg.is_a?(Hash)

        egress_doc["mean"]             = eg["score"]
        egress_doc["median"]           = eg["median"]
        egress_doc["capped_fraction"]  = eg["capped_fraction"]
        egress_doc["by_category_cost"] = cost_lens_compaction(scores["egress_by_category"])
      end

      # C egress COUNTS: the single read path is `diagnostics[:egress_counts]`
      # (the Accumulator's per-call-site tally — Reconciliation 1; the writer
      # never re-parses `<external:*>` sink symbols). Diagnostics-free write →
      # carry the prior committed block forward; no prior either → the pre-C
      # fallback fold over the graph's external edges, all `generic` (summing
      # per-edge `calls` so the fallback keeps the same per-SITE semantics).
      def egress_block(diagnostics, graph, prior)
        counts = diagnostics && diagnostics[:egress_counts]

        if counts
          by_category = EGRESS_CATEGORIES.to_h { |cat| [cat, counts[cat.to_sym].to_i] }
        elsif (carried = prior && prior["egress"]) && carried.is_a?(Hash) && !carried.empty?
          return carried
        else
          generic = (graph["edges"] || [])
                    .select { |e| e["to"].to_s.start_with?("ext_") }
                    .sum { |e| e["calls"].to_i }
          by_category = EGRESS_CATEGORIES.to_h { |cat| [cat, cat == "generic" ? generic : 0] }
        end

        total = by_category.values.sum
        { "total" => total, "count" => total, "by_category" => by_category }
      end

      # D dynamic-dispatch COVERAGE: promotes the stderr-only diagnostics to a
      # committed metric (L21). `coverage_ratio` = the visible share of dispatch,
      # 1 - dynamic_sites/total_call_sites — and NULL on a zero denominator (a
      # ratio over zero sites is undefined; a confident 0/1 would be a
      # fabricated coverage claim — I2). Diagnostics-free write → carry the
      # prior committed block forward (analyze never re-collects).
      def dynamic_dispatch_block(diagnostics, prior)
        if diagnostics.nil? && (carried = prior && prior["dynamic_dispatch"]) &&
           carried.is_a?(Hash) && !carried.empty?
          return carried
        end

        d        = diagnostics || {}
        dynamic  = d[:meta_sites_skipped].to_i
        resolved = d[:meta_resolved].to_i
        total    = d.key?(:total_call_sites) ? d[:total_call_sites].to_i : dynamic + resolved

        {
          "dynamic_sites"    => dynamic,
          "resolved_sites"   => resolved,
          "total_call_sites" => total,
          "coverage_ratio"   => total.zero? ? nil : (1.0 - dynamic.to_f / total).round(4)
        }
      end

      # Headline (compact) dimension scores — grade + score numbers only; drop
      # the opaque hotspot id lists (those live in the detail tree / are opaque).
      # v0.11 (serializer v3, R8 — fixes the v2 median gap): each dimension
      # entry also carries `median` + `median_grade` + `capped_fraction`,
      # copied VERBATIM (null on pre-1.6 keys the engine didn't emit — once
      # the source hash exists, keys are written with null rather than
      # omitted, so the committed shape is deterministic).
      def headline_scores(scores)
        out = {}
        %w[forward_discoverability reverse_traceability].each do |dim|
          d = scores[dim]
          next unless d

          out[dim] = {
            "grade"           => d["grade"],
            "score"           => d["score"],
            "median"          => d["median"],
            "median_grade"    => d["median_grade"],
            "capped_fraction" => d["capped_fraction"]
          }
        end
        if (c = scores["connectivity"])
          out["connectivity"] = {
            "forward" => c["forward"], "reverse" => c["reverse"],
            "scored_nodes" => c["scored_nodes"], "total_nodes" => c["total_nodes"]
          }
        end
        out
      end

      # De-anonymize the E1 multiplexer_proxy list ({node, added_coupling},
      # worst-first) to real names, PRESERVING the engine's worst-first order
      # (verbatim — the client never recomputes). Empty [] passes through as [].
      def deanon_proxies(scores, resolver)
        (scores["multiplexer_proxies"] || []).map do |proxy|
          {
            "symbol"         => resolver.symbol(proxy["node"]),
            "added_coupling" => proxy["added_coupling"]
          }
        end
      end

      # v0.11 (v3): the findings-1.6 `scores.blast_radius` block, copied
      # VERBATIM — the full 8-scalar set — with the worst-list de-anonymized
      # to real symbols (the deanon_proxies pattern; an unmapped id resolves
      # to the graceful `<external …>` placeholder, never a crash). The
      # engine's worst-first order is PRESERVED; the N/A form (null stats,
      # worst []) passes through as an honest present-but-null block.
      def blast_radius_block(scores, resolver)
        blast = scores["blast_radius"]
        {
          "max"                        => blast["max"],
          "p90"                        => blast["p90"],
          "median"                     => blast["median"],
          "mean"                       => blast["mean"],
          "reached_nodes"              => blast["reached_nodes"],
          "total_nodes"                => blast["total_nodes"],
          "total_entrypoints"          => blast["total_entrypoints"],
          "pct_use_cases_hit_by_worst" => blast["pct_use_cases_hit_by_worst"],
          "worst" => (blast["worst"] || []).map do |w|
            {
              "symbol"             => resolver.symbol(w["node"]),
              "use_cases_affected" => w["use_cases_affected"],
              "added_coupling"     => w["added_coupling"]
            }
          end
        }
      end

      # v0.11 (v3): verbatim copy of a findings stat block ({mean, median,
      # count} + `by_category` iff the source carries it — forward_depth /
      # branching_factor only; reverse_depth never groups, R9). SAME FLAT
      # SPELLINGS as the findings keys (guard R1 — no `depth` grouping).
      def stat_copy(block)
        out = {
          "mean"   => block["mean"],
          "median" => block["median"],
          "count"  => block["count"]
        }
        out["by_category"] = block["by_category"] if block.key?("by_category")
        out
      end

      # v0.12 (v4): the findings-1.7 `scores.variety_mass` block, copied
      # VERBATIM (D17) — UNGRADED (no grade key exists on the source; none is
      # ever minted). Opaque hotspot id lists are DROPPED at both levels (the
      # headline_scores posture — VM hotspots are a v0.13 report candidate,
      # not a committed-cache concern). The engine N/A form (score null,
      # count 0) passes through as an honest present-but-null block.
      # `fallback_fraction` is THE L17 low-confidence disclosure (A1/A6) and
      # `capped_fraction` the CAP disclosure — both verbatim, never re-derived.
      def variety_mass_block(scores)
        vm = scores["variety_mass"]
        {
          "score"             => vm["score"],
          "median"            => vm["median"],
          "count"             => vm["count"],
          "capped_fraction"   => vm["capped_fraction"],
          "fallback_fraction" => vm["fallback_fraction"],
          "variety"           => component_stat(vm["variety"]),
          "mass"              => component_stat(vm["mass"]),
          "by_category"       => vm_by_category(vm["by_category"])
        }
      end

      # {mean, median, count} verbatim; non-hash source → nil (absence, never
      # fabricated zeros).
      def component_stat(stat)
        return nil unless stat.is_a?(Hash)

        { "mean" => stat["mean"], "median" => stat["median"], "count" => stat["count"] }
      end

      # Per-kind entries mirror the top shape, hotspots dropped per kind too.
      # {} on an absent lens (the cost_lens_compaction posture).
      def vm_by_category(lens)
        return {} unless lens.is_a?(Hash)

        lens.to_h do |kind, entry|
          [kind, {
            "score"             => entry["score"],
            "median"            => entry["median"],
            "count"             => entry["count"],
            "capped_fraction"   => entry["capped_fraction"],
            "fallback_fraction" => entry["fallback_fraction"],
            "variety"           => component_stat(entry["variety"]),
            "mass"              => component_stat(entry["mass"])
          }]
        end
      end

      # v0.13 (v5): the findings-1.8 `scores.reusability_compass` block, copied
      # VERBATIM (D17) — UNGRADED (no grade key exists on the source; none is
      # ever minted). The toll-booth and extraction worst-lists are
      # de-anonymized to real symbols (the deanon_proxies pattern), the
      # engine's worst-first order PRESERVED. Honest blanks pass through
      # (reuse_index nulls / unshared_fraction null when reachability is
      # unknown; empty lists when nothing qualifies). ADVISORY data: a toll
      # booth is a "bypass candidate", never "must bypass" — wording lives in
      # the report layer, the fold carries only figures.
      def reusability_block(scores, resolver)
        rc = scores["reusability_compass"]
        {
          "reuse_index"       => reuse_index_copy(rc["reuse_index"]),
          "unshared_fraction" => rc["unshared_fraction"],
          "toll_booths"       => (rc["toll_booths"] || []).map do |tb|
            {
              "symbol"       => resolver.symbol(tb["node"]),
              "blast"        => tb["blast"],
              "mass_savings" => tb["mass_savings"]
            }
          end,
          "extraction"        => (rc["extraction"] || []).map do |ex|
            {
              "symbol"   => resolver.symbol(ex["node"]),
              "collapse" => ex["collapse"],
              "leverage" => ex["leverage"]
            }
          end,
          # {mean, median, count} — the leverage distribution stat summary
          # (component_stat carries the exact shape; nil on a non-hash source).
          "leverage"          => component_stat(rc["leverage"])
        }
      end

      # {mean, median} verbatim; non-hash source → nil (absence, never
      # fabricated zeros — the component_stat posture).
      def reuse_index_copy(reuse_index)
        return nil unless reuse_index.is_a?(Hash)

        { "mean" => reuse_index["mean"], "median" => reuse_index["median"] }
      end

      # --- filesystem + helpers ------------------------------------------------

      def committed_path_for(rel_file, mode)
        mode == Layout::MODE_SINGLE ? Layout.single_path(rel_file) : Layout.shard_dir(rel_file)
      end

      def write_file(rel_path, contents)
        abs = File.join(@project_root, rel_path)
        FileUtils.mkdir_p(File.dirname(abs))
        File.write(abs, contents)
      end

      # Make a real symbol safe as a single path segment (FQ separators ::, #, .,
      # etc.). Deterministic + reversible-enough for a committed filename; the
      # authoritative symbol is inside the JSON, this is just the shard filename.
      def sanitize(symbol)
        symbol.to_s.gsub(%r{[/\x00]}, "_").gsub("::", "__")
      end

      # Resolves opaque ids → real descriptors via the SECRET id-map. Mirrors the
      # report IdMapResolver shape but is used at WRITE time to de-anonymize the
      # committed cache (so the committed layer is real-name; the id-map itself
      # stays gitignored and is never committed).
      class Deanonymizer
        def initialize(id_map)
          @ids = (id_map || {})["ids"] || {}
        end

        def describe(opaque_id)
          @ids[opaque_id]
        end

        # Real symbol for an opaque id; a graceful placeholder for the external
        # sink / any unmapped id (never nil, so edges keep a stable endpoint).
        def symbol(opaque_id)
          desc = @ids[opaque_id]
          return desc["symbol"] if desc

          opaque_id.to_s.start_with?("ext_") ? "<external>" : "<external #{opaque_id}>"
        end

        # Real class symbol for a cls_ class_id (nil when top-level / unmapped).
        def class_symbol(class_id)
          return nil if class_id.nil?

          desc = @ids[class_id]
          desc && desc["symbol"]
        end
      end
    end
  end
end
