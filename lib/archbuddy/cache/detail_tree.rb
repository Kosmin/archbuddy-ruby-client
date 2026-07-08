# frozen_string_literal: true

require "json"
require_relative "layout"

module Archbuddy
  module Cache
    # v0.9 (W2): reader for the COMMITTED, REAL-NAME detail tree. The committed
    # cache is two layers:
    #
    #   * the ROOT aggregate (`archbuddy-findings.json`) — headline scores + the
    #     multiplexer_proxy smell + POINTERS into the detail tree, AND
    #   * the DETAIL TREE (`.archbuddy/<mirrored-source>[.json | /…]`) — the
    #     real-name nodes (symbol/kind/class/branches/decisions/entrypoint) + the
    #     real-name edges (from/to/calls), adaptively sharded per class / method.
    #
    # This reassembles the sharded fragments back into ONE real-name node/edge set
    # so the DEFAULT `archbuddy report` can render a clean real-name call graph
    # WITHOUT the SECRET id-map (the committed layer is de-anonymized at WRITE,
    # CR-1). It is the read-side counterpart to Cache::Writer.
    #
    # Node ids on the real-name path ARE the real symbols (identity) — there is no
    # opaque id to resolve. `<external>` sink endpoints appear ONLY as edge targets
    # (the writer never emits an external node), so they are naturally excluded
    # from the node set and the report's `graphable_nodes` drops their dangling
    # edges.
    class DetailTree
      # @param project_root [String] the audited repo root (holds the aggregate +
      #   the `.archbuddy/` detail tree). Defaults to CWD.
      def initialize(project_root: Dir.pwd)
        @project_root = File.expand_path(project_root)
      end

      # Reassemble the whole committed detail tree into a graph.yml-shaped hash so
      # the existing HTML formatter consumes it unchanged:
      #
      #   { "nodes" => [{ "id" => <symbol>, "symbol" =>, "kind" =>, "class" =>,
      #                   "entrypoint" =>, "branches" =>, "decisions" => }, …],
      #     "edges" => [{ "from" => <symbol>, "to" => <symbol>, "calls" => }, …] }
      #
      # Nodes are de-duplicated by symbol (a symbol appears once even if it shows
      # up in multiple shards); edges are de-duplicated by [from, to, calls].
      # Deterministically ordered (nodes by id, edges by [from,to,calls]) so the
      # reassembled graph is stable regardless of filesystem traversal order.
      #
      # @param aggregate [Hash] the parsed root aggregate (carries `sources`
      #   pointers). When nil, reads the ROOT_AGGREGATE under project_root.
      # @return [Hash] the reassembled real-name graph
      def reassemble(aggregate: nil)
        agg = aggregate || load_aggregate
        pointers = (agg && agg["sources"]) || {}

        nodes_by_symbol = {}
        edges_seen      = {}

        pointers.each_value do |ptr|
          each_fragment_file(ptr) do |fragment|
            (fragment["nodes"] || []).each do |node|
              sym = node["symbol"]
              next if sym.nil?

              # First occurrence wins; the writer emits identical node payloads
              # for a symbol across shards, so this is order-independent.
              nodes_by_symbol[sym] ||= node.merge("id" => sym)
            end

            (fragment["edges"] || []).each do |edge|
              key = [edge["from"], edge["to"], edge["calls"]]
              edges_seen[key] ||= { "from" => edge["from"], "to" => edge["to"], "calls" => edge["calls"] }
            end
          end
        end

        {
          "nodes" => nodes_by_symbol.values.sort_by { |n| n["id"].to_s },
          "edges" => edges_seen.values.sort_by { |e| [e["from"].to_s, e["to"].to_s, e["calls"].to_i] }
        }
      end

      private

      def load_aggregate
        path = File.join(@project_root, Layout::ROOT_AGGREGATE)
        return nil unless File.exist?(path)

        JSON.parse(File.read(path))
      rescue StandardError
        nil
      end

      # Yield the parsed JSON of every committed fragment file a pointer covers.
      # SINGLE mode → one `<path>.json`; a sharded mode → every `*.json` under the
      # `<path>/` directory (per-class or per-method). Reads relative to the
      # aggregate's `path` pointer so the reader never re-derives the layout — it
      # trusts what the writer recorded. A missing/corrupt fragment is skipped
      # (fail-safe: a partial graph is better than a crash on a stale tree).
      def each_fragment_file(pointer)
        rel = pointer && pointer["path"]
        return if rel.nil?

        abs = File.join(@project_root, rel)

        if File.directory?(abs)
          Dir.glob(File.join(abs, "**", "*.json")).sort.each do |f|
            yield_parsed(f) { |doc| yield doc }
          end
        elsif File.file?(abs)
          yield_parsed(abs) { |doc| yield doc }
        end
      end

      def yield_parsed(path)
        yield JSON.parse(File.read(path))
      rescue StandardError
        nil # skip a corrupt/unreadable fragment
      end
    end
  end
end
