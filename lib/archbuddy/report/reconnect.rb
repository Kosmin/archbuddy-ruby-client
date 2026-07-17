# frozen_string_literal: true

require "json"
require "architecture_auditor"
require_relative "model"
require_relative "scores"
require_relative "../cache/detail_tree"

module Archbuddy
  module Report
    # R-2: the Reconnect (join) engine. Loads findings.yml + the SECRET
    # id-map.yml via the contract Serializer (safe_load) and de-anonymizes at
    # EXACTLY the three contract join sites:
    #
    #   1. `findings.nodes.<id>`        — every scored node (→ a Bottleneck)
    #   2. every `findings[].node`      — node-type findings
    #   3. every element of every
    #      `findings[].path[]`          — ordered real call chains
    #
    # Metrics + clutter_score are copied VERBATIM — the Reconnect engine NEVER
    # recomputes them (Reporter-only, D17). Ids absent from the id-map (e.g.
    # `ext_` external sinks, or any unknown id) resolve GRACEFULLY to an
    # `<external …>` placeholder Location and NEVER raise.
    class Reconnect
      Serializer = ArchitectureAuditor::Contract::Serializer

      # Result of a join: ranked-able Bottleneck objects + the resolver so the
      # Ranker can de-anonymize cls_ rollups against the same id-map. `scores`
      # is the optional de-anonymized project-level dimension scores (findings
      # 1.1) — NIL for a 1.0 findings doc with no scores block (back-compat).
      # `connectivity` is the optional project-level connectivity scalar (findings
      # 1.3) — NIL when absent; no resolver needed (counts/ratios only, no opaque ids).
      # `multiplexer_proxies` is the optional de-anonymized v0.7 smell list
      # (findings 1.4 `scores.multiplexer_proxies`, worst-first) — an
      # Array<Scores::MultiplexerProxy> when a scores block is present (possibly
      # EMPTY = scored-but-no-proxy), NIL when absent (pre-1.4 / no scores block).
      # `graph` is the OPTIONAL reassembled REAL-NAME graph (nodes/edges) for the
      # from_cache path (v0.9 W2) — nil on the legacy opaque path (there the CLI
      # loads the opaque graph.yml). `real_name` flags the committed path so the
      # CLI wires an IDENTITY resolver (nodes are already real; no id-map).
      # `entrypoints` / `egress` / `dynamic_dispatch` (v0.10 W3) are the three
      # OPTIONAL committed counter blocks parsed off the serializer-v2 aggregate
      # (Scores::EntrypointCount / Scores::Egress / Scores::DynamicDispatch) —
      # NIL on a v1 (pre-bump) aggregate or a legacy findings doc (back-compat;
      # absence, never a fabricated zero).
      # `blast_radius` / `forward_depth` / `reverse_depth` / `branching_factor`
      # (v0.11 W-C, serializer v3 / findings 1.6) are the four OPTIONAL
      # business-metric blocks (Scores::BlastRadius / Scores::DepthStats x2 /
      # Scores::BranchingFactor) — FLAT fields, same spellings as the findings
      # keys (guard R1); NIL on v1/v2 aggregates and pre-1.6 findings.
      Result = Struct.new(
        :bottlenecks, :id_map, :findings_doc, :scores, :connectivity,
        :multiplexer_proxies, :graph, :real_name,
        :entrypoints, :egress, :dynamic_dispatch,
        :blast_radius, :forward_depth, :reverse_depth, :branching_factor,
        keyword_init: true
      ) do
        # Look up a (possibly missing) opaque id → Model::Location. Memoize the
        # resolver so repeated lookups don't rebuild the id-map wrapper each call.
        # On the real-name (from_cache) path this is identity — the id IS the
        # symbol, so there is nothing to join.
        def resolve(id)
          @resolver ||= real_name ? IdentityResolver.new : IdMapResolver.new(id_map)
          @resolver.resolve(id)
        end

        # True for the committed real-name (from_cache) path — the CLI uses this
        # to pick an IDENTITY resolver + the reassembled real-name graph.
        def real_name?
          real_name
        end
      end

      # v0.9 W2: the resolver for the COMMITTED real-name path. The node id IS the
      # real symbol (identity de-anon-at-write), so `resolve` returns a resolved
      # Location whose symbol == id. No id-map, no `<external …>` placeholder — the
      # external sink is never a node on this path (the writer excludes it). Kept
      # duck-type-compatible with IdMapResolver (`#resolve(id) -> Model::Location`).
      class IdentityResolver
        def resolve(id)
          Model::Location.new(
            id:       id,
            file:     nil,
            line:     nil,
            symbol:   id,
            kind:     nil,
            class_id: nil,
            resolved: true
          )
        end
      end

      # Wraps the id-map's `ids` table and resolves opaque ids to real symbols,
      # falling back to a graceful placeholder for anything missing.
      class IdMapResolver
        def initialize(id_map)
          @ids = (id_map || {})["ids"] || {}
        end

        # @return [Model::Location] always — resolved? is false for missing ids.
        def resolve(id)
          desc = @ids[id]
          return placeholder(id) if desc.nil?

          Model::Location.new(
            id:       id,
            file:     desc["file"],
            line:     desc["line"],
            symbol:   desc["symbol"],
            kind:     desc["kind"],
            class_id: desc["class_id"],
            resolved: true
          )
        end

        private

        # An id absent from the id-map (ext_ sinks, pruned/unknown ids). We never
        # raise: external sinks have no real symbol by design, so we surface a
        # readable placeholder that still carries the opaque id for traceability.
        def placeholder(id)
          label =
            if id.to_s.start_with?("ext_")
              "<external sink #{id}>"
            else
              "<external #{id}>"
            end

          Model::Location.new(
            id:       id,
            file:     nil,
            line:     nil,
            symbol:   label,
            kind:     "external",
            class_id: nil,
            resolved: false
          )
        end
      end

      # Build a Reconnect from file paths (the LEGACY opaque path): opaque
      # findings.yml + the SECRET id-map.yml joined at READ time.
      def self.from_files(findings_path:, id_map_path:)
        new(
          findings_doc: Serializer.load(findings_path),
          id_map:       Serializer.load(id_map_path)
        )
      end

      # R2-1 / v0.9 W2: build a Result DIRECTLY from the COMMITTED, REAL-NAME
      # cache — the de-anon-at-write layer (CR-1). This is the DEFAULT report
      # path: a fresh clone reads it with NO id-map (the committed layer is
      # already real-name; the SECRET id-map stays gitignored and is NEVER
      # consulted here). `id_map_path` is accepted but DEFAULTS TO NIL and is
      # intentionally ignored on this path — the signature documents that the
      # committed read needs no secret.
      #
      # Two layers are read:
      #   * the ROOT aggregate — headline dimension scores + the multiplexer_proxy
      #     smell + source pointers, VERBATIM (no resolver needed), AND
      #   * the DETAIL TREE — reassembled (Cache::DetailTree) into a REAL-NAME
      #     node/edge `graph` so the default report renders a clean real-name call
      #     graph WITHOUT the id-map (the v0.9 headline).
      #
      # `bottlenecks` are the committed per-symbol clutter proxies turned into
      # real-name Model::Bottlenecks (clutter_score = added_coupling, worst-first
      # from the engine) so the Ranker ranks the graph's `kept_node_ids` by REAL
      # clutter (top-N real hotspots). The node id IS the symbol (identity) — the
      # Result is flagged `real_name` so the CLI wires an IdentityResolver.
      #
      # @param aggregate_path [String] path to the committed ROOT aggregate.
      # @param id_map_path     [nil] accepted for signature parity; ignored.
      # @param project_root    [String,nil] the audited repo root that holds the
      #   detail tree; defaults to the aggregate's directory.
      def self.from_cache(aggregate_path:, id_map_path: nil, project_root: nil) # rubocop:disable Lint/UnusedMethodArgument
        doc = JSON.parse(File.read(aggregate_path))
        root = project_root || File.dirname(File.expand_path(aggregate_path))

        # The COMMITTED aggregate shape differs from findings.yml: the headline
        # dimension scores live under `scores` (grade + score, no opaque hotspot
        # ids), and the multiplexer_proxy smell is a TOP-LEVEL, already-real-name
        # `multiplexer_proxies` list (Cache::Writer). No resolver is needed — the
        # doc is de-anonymized (CR-1). `nil` when the aggregate carries no smell
        # block (a collect-only aggregate written before analyze).
        smell =
          if doc.key?("multiplexer_proxies")
            Scores.multiplexer_proxies_from_committed(doc["multiplexer_proxies"])
          end

        # Reassemble the real-name detail tree into a graph.yml-shaped node/edge
        # set (identity ids = real symbols). nil when the tree carries no nodes
        # (a scores-only aggregate, or no detail tree on disk) so the report
        # degrades to the scores header + table with the "no graph" notice,
        # exactly as before (graceful degradation).
        reassembled = Archbuddy::Cache::DetailTree.new(project_root: root).reassemble(aggregate: doc)
        graph = reassembled["nodes"].empty? ? nil : reassembled

        Result.new(
          bottlenecks:         bottlenecks_from_committed(smell),
          id_map:              {},
          findings_doc:        doc,
          scores:              Scores.from_findings(doc, nil),
          connectivity:        Scores.connectivity_from_findings(doc),
          multiplexer_proxies: smell,
          graph:               graph,
          real_name:           true,
          # v0.10 W3: the three committed counter blocks (serializer v2, doc
          # ROOT — peers of `scores`). NIL on a v1 aggregate (back-compat).
          entrypoints:         Scores.entrypoints_from_aggregate(doc),
          egress:              Scores.egress_from_aggregate(doc),
          dynamic_dispatch:    Scores.dynamic_dispatch_from_aggregate(doc),
          # v0.11 W-C: the four v3 business-metric blocks (doc ROOT, already
          # real-name — no resolver). NIL on v1/v2 aggregates (back-compat).
          blast_radius:        Scores.blast_radius_from_aggregate(doc),
          forward_depth:       Scores.forward_depth_from_aggregate(doc),
          reverse_depth:       Scores.reverse_depth_from_aggregate(doc),
          branching_factor:    Scores.branching_factor_from_aggregate(doc)
        )
      end

      # v0.9 W2: turn the committed real-name multiplexer_proxy list (symbol +
      # added_coupling, worst-first) into ranked-able Model::Bottlenecks so the
      # graph's node cap ranks by REAL committed clutter. The node id IS the
      # symbol (identity). `clutter_score` is the VERBATIM engine `added_coupling`
      # — the client never recomputes it (D17). Nodes with no committed clutter
      # (not a proxy) simply carry no Bottleneck and rank last in the viz cap.
      # nil smell (pre-analyze aggregate) → no bottlenecks.
      def self.bottlenecks_from_committed(proxies)
        (proxies || []).map do |proxy|
          Model::Bottleneck.new(
            id:            proxy.symbol,
            location:      IdentityResolver.new.resolve(proxy.symbol),
            kind:          nil,
            class_id:      nil,
            metrics:       {},
            clutter_score: proxy.added_coupling,
            findings:      []
          )
        end
      end

      # @param findings_doc [Hash] parsed findings.yml (string keys)
      # @param id_map       [Hash] parsed id-map.yml (string keys; SECRET)
      def initialize(findings_doc:, id_map:)
        @findings_doc = findings_doc || {}
        @id_map       = id_map || {}
        @resolver     = IdMapResolver.new(@id_map)
      end

      # Join findings × id-map → de-anonymized Bottlenecks (one per scored node),
      # each carrying the findings that touch it. Returns a Result.
      def call
        findings_by_node = group_findings_by_node

        bottlenecks = nodes.map do |id, node_entry|
          # Resolve once — kind/class_id are read off the same Location.
          location = @resolver.resolve(id)
          Model::Bottleneck.new(
            id:            id,
            location:      location,
            kind:          location.kind,
            class_id:      location.class_id,
            # VERBATIM copy — never recomputed (D17). Whatever findings.yml says,
            # even if deliberately "wrong", is exactly what we carry/display.
            metrics:       node_entry["metrics"] || {},
            clutter_score: node_entry["clutter_score"],
            findings:      findings_by_node.fetch(id, [])
          )
        end

        Result.new(
          bottlenecks:  bottlenecks,
          id_map:       @id_map,
          findings_doc: @findings_doc,
          # Optional findings-1.1 project scores, de-anonymized via the SAME
          # resolver. NIL when absent (1.0 doc) — graceful, no header rendered.
          scores:        Scores.from_findings(@findings_doc, @resolver),
          # Optional findings-1.3 connectivity scalar. NIL when absent (1.0/1.1/1.2
          # doc) — back-compat; no resolver needed (counts/ratios only, no opaque ids).
          connectivity:  Scores.connectivity_from_findings(@findings_doc),
          # Optional findings-1.4 multiplexer_proxy smell (worst-first, VERBATIM).
          # On the legacy opaque findings path this resolves opaque node ids via
          # the SAME resolver; NIL when absent, [] when scored-but-no-proxy.
          multiplexer_proxies: Scores.multiplexer_proxies_from_findings(@findings_doc, @resolver),
          # v0.10 W3: the three committed counter blocks live at the AGGREGATE
          # doc root; a legacy findings.yml has none → all NIL (nil-tolerant,
          # keeps this path from raising on the new struct fields).
          entrypoints:         Scores.entrypoints_from_aggregate(@findings_doc),
          egress:              Scores.egress_from_aggregate(@findings_doc),
          dynamic_dispatch:    Scores.dynamic_dispatch_from_aggregate(@findings_doc),
          # v0.11 W-C: the four 1.6 blocks off the OPAQUE findings doc
          # (`scores.*`, flat spellings) — blast worst ids resolved via the
          # SAME resolver, so a findings-1.6 + id-map doc renders FULL
          # (nil-tolerance matrix row 6). NIL on pre-1.6 docs.
          blast_radius:        Scores.blast_radius_from_findings(@findings_doc, @resolver),
          forward_depth:       Scores.forward_depth_from_findings(@findings_doc),
          reverse_depth:       Scores.reverse_depth_from_findings(@findings_doc),
          branching_factor:    Scores.branching_factor_from_findings(@findings_doc)
        )
      end

      private

      def nodes
        @findings_doc["nodes"] || {}
      end

      def raw_findings
        @findings_doc["findings"] || []
      end

      # De-anonymize every finding and index node-type findings by their node id
      # so each Bottleneck can carry the findings touching it. Path-type findings
      # are attached to the FIRST resolvable node on their path (so a long_path /
      # cycle shows up on the bottleneck where the chain originates).
      def group_findings_by_node
        index = Hash.new { |h, k| h[k] = [] }

        raw_findings.each do |raw|
          finding = deanonymize_finding(raw)

          if finding.path?
            anchor = raw["path"]&.first
            index[anchor] << finding if anchor
          elsif finding.node
            index[finding.node.id] << finding
          end
        end

        index
      end

      # Join site #2 (findings[].node) and #3 (findings[].path[]).
      def deanonymize_finding(raw)
        node_id = raw["node"]
        path    = raw["path"]

        Model::Finding.new(
          type:      raw["type"],
          severity:  raw["severity"],
          node:      node_id && @resolver.resolve(node_id),
          path_refs: path && path.map { |pid| @resolver.resolve(pid) }
        )
      end
    end
  end
end
