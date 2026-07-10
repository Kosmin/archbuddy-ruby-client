# frozen_string_literal: true

module Archbuddy
  module Collect
    # THE single trust boundary (K-5). Converts neutral Raw* value objects (real
    # symbol space) into:
    #
    #   (a) the OPAQUE graph hash — zero app semantics: opaque node ids, the
    #       contract kind set, class_id refs (cls_ ids that appear ONLY here as
    #       references, never as their own nodes[] entry — D42), all timing
    #       fields null (static capture — D4).
    #
    #   (b) the SECRET id-map hash — { "ids" => { opaque_id => {file,line,symbol,
    #       kind,class_id} } } including kind:"class_rollup" entries for every
    #       cls_ class id so the reporter can de-anonymize class rollups.
    #
    # This is the ONLY collector code that mints ids, and it mints them solely
    # via ArchitectureAuditor::Contract::Ids (D25/D41 — never reimplemented).
    class Anonymizer
      Ids       = ArchitectureAuditor::Contract::Ids
      Validator = ArchitectureAuditor::Contract::Validator

      Result = Struct.new(:graph, :id_map, keyword_init: true)

      # v0.10 W1-A1 emission gate probe: a minimal, otherwise-valid graph whose
      # single node carries `entrypoint_kind`. VERIFIED against the live engine
      # (v0.6, graph 1.2): the node schema sets additionalProperties:false
      # (graph.v1.schema.json:44) and Emitter runs Validator.validate! before
      # writing — so an undeclared `entrypoint_kind` key would FAIL D37
      # validation, NOT be ignored. Until the engine declares the OPTIONAL
      # field (W6/graph 1.3), the category is held CLIENT-SIDE (RawNode +
      # id-map descriptor); this probe makes the graph.yml passthrough light
      # up automatically once the installed engine schema accepts the key.
      ENTRYPOINT_KIND_PROBE_GRAPH = {
        "schema_version" => ArchitectureAuditor::Contract::SCHEMA_VERSION,
        "generator"      => {
          "tool" => "archbuddy-probe", "adapter" => "ruby", "capture" => "static"
        },
        "nodes"       => [{
          "id"              => "n_000000000000",
          "kind"            => "function",
          "class_id"        => nil,
          "loc"             => nil,
          "self_time_ms"    => nil,
          "total_time_ms"   => nil,
          "count"           => nil,
          "entrypoint_kind" => "controllers"
        }],
        "edges"       => [],
        "entrypoints" => []
      }.freeze

      # True when the installed engine's graph schema accepts an
      # `entrypoint_kind` node property (memoized once per process).
      def self.graph_schema_accepts_entrypoint_kind?
        return @graph_schema_accepts_entrypoint_kind unless @graph_schema_accepts_entrypoint_kind.nil?

        @graph_schema_accepts_entrypoint_kind =
          Validator.valid?(:graph, ENTRYPOINT_KIND_PROBE_GRAPH)
      end

      def initialize(adapter_result, tool:, adapter:)
        @adapter_result = adapter_result
        @tool           = tool
        @adapter        = adapter
      end

      def call
        @id_for_key   = {}   # RawNode#real_key => opaque node/ext id
        @class_ids    = {}   # class real key   => cls_ id
        @id_map_ids   = {}   # opaque id        => secret descriptor
        graph_nodes   = []

        @adapter_result.nodes.each do |raw|
          node_id  = mint_node_id(raw)
          class_id = raw.class_rollup? ? class_id_for(raw) : nil

          # FIRST-DEF-WINS (v0.8): dropping `line` from identity means two raws with
          # the same (rel_file, symbol) now share a real_key and mint the SAME id.
          # The SymbolTable already collapses same-fq source defs upstream, but we
          # guard here too: the first def owns the id + its id-map (line) payload;
          # a later same-key raw is NOT emitted as a duplicate graph node and does
          # NOT overwrite the payload. This is a deterministic collapse, NOT a
          # fabricated merge of two distinct methods.
          if @id_for_key.key?(raw.real_key)
            next
          end

          @id_for_key[raw.real_key] = node_id

          node_hash = {
            "id"            => node_id,
            "kind"          => raw.kind,
            "class_id"      => class_id,
            # D7/D16/D18: graph.yml carries ZERO app semantics. The real
            # rel_file:line lives ONLY in the secret id-map (below, as
            # file/line). The opaque node's loc is therefore always null
            # (the schema types loc as ["string","null"]). Emitting the real
            # path here would leak app file paths into the shareable graph.
            "loc"           => nil,
            "self_time_ms"  => nil,
            "total_time_ms" => nil,
            "count"         => nil,
            # Opaque path-cost integers (graph schema 1.1, P3+P9). These carry NO
            # app semantics — just two counts — so they belong in the shareable
            # graph node, NOT the secret id-map. branches=Π(arm-count) (≥1),
            # decisions=raw decision-point count (≥0).
            "branches"      => raw.branches,
            "decisions"     => raw.decisions
          }

          # L3 (v0.6): the client no longer emits the `sink_open` proxy. A db_op
          # is a plain COST-1 terminal; the engine no longer consumes the field
          # and keeps it DECLARED-but-optional in the graph schema (graph stays
          # 1.2 — absent `sink_open` validates).

          # v0.10 W1-A1: emit the ingress category onto the shareable graph node
          # ONLY when non-nil AND the installed engine schema declares the field
          # (see ENTRYPOINT_KIND_PROBE_GRAPH — a 1.2 engine REJECTS unknown node
          # keys, it does not ignore them). The category is a non-secret string
          # (no app symbols), so it is safe on both surfaces.
          if raw.entrypoint_kind && self.class.graph_schema_accepts_entrypoint_kind?
            node_hash["entrypoint_kind"] = raw.entrypoint_kind
          end

          graph_nodes << node_hash

          @id_map_ids[node_id] = {
            "file"            => raw.rel_file,
            "line"            => raw.line,
            "symbol"          => raw.symbol,
            "kind"            => raw.kind,
            "class_id"        => class_id,
            # v0.10 W1-A1: ingress category (nil for non-entrypoints and for
            # category-unknown entrypoints) — read back by the aggregate
            # writer (W3) via the Deanonymizer descriptor.
            "entrypoint_kind" => raw.entrypoint_kind
          }
        end

        graph = {
          "schema_version" => ArchitectureAuditor::Contract::SCHEMA_VERSION,
          "generator"      => {
            "tool"    => @tool,
            "adapter" => @adapter,
            "capture" => "static"
          },
          "nodes"       => graph_nodes,
          "edges"       => build_edges,
          "entrypoints" => build_entrypoints
        }

        Result.new(graph: graph, id_map: { "ids" => @id_map_ids })
      end

      private

      def mint_node_id(raw)
        # The external sink has no real file/line; mint it as an ext_ id keyed by
        # its synthetic symbol so it is stable and matches the D41 regex.
        # v0.8: identity is (rel_file, symbol) — NO line. `line` stays in the
        # id-map DISPLAY payload only (below), never in the minted id.
        case raw.kind
        when "external"
          Ids.external_id(raw.rel_file.to_s, raw.symbol)
        else
          Ids.node_id(raw.rel_file.to_s, raw.symbol)
        end
      end

      # Mint the cls_ rollup id for a node's owning class and record it in the
      # id-map (with kind:"class_rollup"). Returns the cls_ id; it is referenced
      # by nodes via class_id but NEVER added to graph nodes[] (D42).
      def class_id_for(raw)
        # v0.8: class identity is (class_rel_file, class_symbol) — NO class_line.
        # The dedup key mirrors the engine canonical key (NUL-joined, line-free).
        key = "#{raw.class_rel_file}\x00#{raw.class_symbol}"
        @class_ids[key] ||= begin
          cls_id = Ids.class_id(raw.class_rel_file.to_s, raw.class_symbol)
          @id_map_ids[cls_id] = {
            "file"     => raw.class_rel_file,
            "line"     => raw.class_line,
            "symbol"   => raw.class_symbol,
            "kind"     => "class_rollup",
            "class_id" => nil
          }
          cls_id
        end
      end

      def build_edges
        @adapter_result.edges.filter_map do |edge|
          from = @id_for_key[edge.from_key]
          to   = @id_for_key[edge.to_key]
          next if from.nil? || to.nil?

          {
            "from"         => from,
            "to"           => to,
            "calls"        => edge.calls,
            "count"        => nil,
            "self_time_ms" => nil
          }
        end
      end

      def build_entrypoints
        @adapter_result.entrypoints.filter_map do |ep|
          @id_for_key[ep.node_key]
        end.uniq
      end
    end
  end
end
