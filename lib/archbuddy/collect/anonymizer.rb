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
      Ids = ArchitectureAuditor::Contract::Ids

      Result = Struct.new(:graph, :id_map, keyword_init: true)

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

          # V4/P4 (graph 1.2): the db_op-sink customizability proxy `sink_open`
          # is OPTIONAL and emitted ONLY on db_op nodes (function/endpoint/
          # external nodes have no sink semantics → key absent). An opaque
          # boolean — no app semantics — so it belongs in the shareable graph
          # node, NOT the secret id-map.
          node_hash["sink_open"] = raw.sink_open ? true : false if raw.kind == "db_op"

          graph_nodes << node_hash

          @id_map_ids[node_id] = {
            "file"     => raw.rel_file,
            "line"     => raw.line,
            "symbol"   => raw.symbol,
            "kind"     => raw.kind,
            "class_id" => class_id
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
        case raw.kind
        when "external"
          Ids.external_id(raw.rel_file.to_s, raw.line.to_i, raw.symbol)
        else
          Ids.node_id(raw.rel_file.to_s, raw.line.to_i, raw.symbol)
        end
      end

      # Mint the cls_ rollup id for a node's owning class and record it in the
      # id-map (with kind:"class_rollup"). Returns the cls_ id; it is referenced
      # by nodes via class_id but NEVER added to graph nodes[] (D42).
      def class_id_for(raw)
        key = "#{raw.class_rel_file}:#{raw.class_line}:#{raw.class_symbol}"
        @class_ids[key] ||= begin
          cls_id = Ids.class_id(raw.class_rel_file.to_s, raw.class_line.to_i, raw.class_symbol)
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
