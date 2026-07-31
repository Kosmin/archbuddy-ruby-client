# frozen_string_literal: true

require "json"
require "fileutils"

module Backtest
  # Reconstruct a graph.yml (schema 1.4) for a study snapshot from its fragment
  # mirror + id-map (snapshots exclude graph.yml — 11_run_snapshots.sh rsync
  # `--exclude`). This is the tier-4 regeneration substrate (calibration §4.2):
  # stored corpus findings are 1.8 (no score keys), so every tier-4 gate rebuilds
  # the graph and re-runs the CURRENT engine (≥ 0.11.0) to obtain findings 1.9.
  #
  # A faithful Ruby port of the probe's `rebuild_graph.py` (self-test PASS: the
  # regenerated graph re-analyzes EQUIVALENT to the stored findings — the
  # `reusability` map, compass/variety/blast scores, and findings multiset all
  # reproduce; only centrality ULP + hotspot tie-order drift, V16-F3). Output goes
  # to the caller's scratch dir, NEVER into the read-only snapshot.
  #
  # Privacy rail (A6/L6): the id-map is opened HERE only to (a) resolve fragment
  # symbols to opaque node ids and (b) hand the caller an id → (file, symbol,
  # class_id) index for gate identity joins. Its values NEVER enter any emitted
  # report — the tier-4 report refers to nodes by (file, symbol) only, and the
  # author-scan quarantines any leak.
  module GraphRebuild
    Rebuilt = Data.define(:graph_path, :id_index, :class_of, :stats)

    module_function

    # @param snapshot_dir [String] `<corpus>/snapshots/<full-sha>`
    # @param out_path [String] where to write the rebuilt graph.yml (scratch)
    # @return [Rebuilt] graph path + id → (file, symbol) index + id → class_id map
    # @raise [ArgumentError] when the snapshot lacks its id-map
    def rebuild(snapshot_dir, out_path)
      idmap_path = File.join(snapshot_dir, "id-map.json")
      unless File.file?(idmap_path)
        raise ArgumentError, "snapshot #{snapshot_dir} has no id-map.json — cannot rebuild"
      end

      idmap = JSON.parse(File.read(idmap_path, encoding: "UTF-8")).fetch("ids")

      by_file_sym = {}
      by_sym = Hash.new { |h, k| h[k] = [] }
      ext_by_sym = {}
      idmap.each do |nid, meta|
        next if nid.start_with?("cls_")

        if nid.start_with?("ext_")
          ext_by_sym[meta["symbol"]] = nid
          next
        end
        by_file_sym[[meta["file"], meta["symbol"]]] = nid
        by_sym[meta["symbol"]] << nid
      end

      nodes = {}
      edges = []
      entrypoints = []
      stats = Hash.new(0)

      fragment_files(snapshot_dir).each do |fp|
        frag = JSON.parse(File.read(fp, encoding: "UTF-8"))
        file = frag["file"]

        (frag["nodes"] || []).each do |n|
          stats[:frag_nodes] += 1
          nid = by_file_sym[[file, n["symbol"]]]
          if nid.nil?
            stats[:missing_from_node] += 1
            next
          end
          nodes[nid] = node_entry(nid, n, idmap[nid])
          entrypoints << nid if n["entrypoint"]
        end

        (frag["edges"] || []).each do |e|
          stats[:frag_edges] += 1
          src = resolve(by_file_sym, by_sym, file, e["from"])
          if src.nil?
            stats[:unresolved_to] += 1
            next
          end
          dst = resolve_target(by_file_sym, by_sym, ext_by_sym, file, e["to"], stats)
          if dst.nil?
            stats[:unresolved_to] += 1
            next
          end
          edges << [src, dst, e.fetch("calls", 1)]
        end
      end

      # external + any n_ nodes never seen in fragments, straight from the id-map
      idmap.each do |nid, meta|
        next if nid.start_with?("cls_") || nodes.key?(nid)
        next unless nid.start_with?("ext_")

        entry = base_ext_entry(nid)
        entry["terminal_kind"] = meta["terminal_kind"] unless meta["terminal_kind"].nil?
        entry["outcome_arity"] = meta["outcome_arity"] unless meta["outcome_arity"].nil?
        entry["escapes"] = true if meta["escapes"]
        nodes[nid] = entry
      end

      write_graph(out_path, nodes, edges, entrypoints)

      Rebuilt.new(
        graph_path: out_path,
        id_index: idmap.reject { |nid, _| nid.start_with?("cls_") }
                       .transform_values { |m| [m["file"], m["symbol"]] },
        class_of: idmap.reject { |nid, _| nid.start_with?("cls_") }
                       .transform_values { |m| m["class_id"] },
        stats: stats.merge(graph_nodes: nodes.size, graph_edges: edges.size,
                           entrypoints: entrypoints.uniq.size, out: out_path)
      )
    end

    # snapshots store fragments under `archbuddy/**/*.json` (pointer-driven layout)
    def fragment_files(snapshot_dir)
      Dir.glob(File.join(snapshot_dir, "archbuddy", "**", "*.json")).sort
    end

    def node_entry(nid, frag_node, meta)
      entry = {
        "id" => nid, "kind" => frag_node["kind"], "class_id" => meta && meta["class_id"],
        "loc" => nil, "self_time_ms" => nil, "total_time_ms" => nil, "count" => nil,
        "branches" => frag_node.fetch("branches", 1), "decisions" => frag_node.fetch("decisions", 0)
      }
      entry["outcome_arity"] = frag_node["outcome_arity"] unless frag_node["outcome_arity"].nil?
      entry["escapes"] = true if frag_node["escapes"]
      entry["entrypoint_kind"] = frag_node["entrypoint_kind"] unless frag_node["entrypoint_kind"].nil?
      entry["terminal_kind"] = meta["terminal_kind"] if meta && !meta["terminal_kind"].nil?
      entry
    end

    def base_ext_entry(nid)
      { "id" => nid, "kind" => "external", "class_id" => nil, "loc" => nil,
        "self_time_ms" => nil, "total_time_ms" => nil, "count" => nil }
    end

    # exact-file-scoped first, then unambiguous cross-file fallback (probe parity)
    def resolve(by_file_sym, by_sym, file, symbol)
      nid = by_file_sym[[file, symbol]]
      return nid unless nid.nil?

      cands = by_sym[symbol]
      cands.size == 1 ? cands.first : nil
    end

    def resolve_target(by_file_sym, by_sym, ext_by_sym, file, tsym, stats)
      if tsym.start_with?("<external")
        stats[:ext_edges] += 1
        return ext_by_sym[tsym]
      end

      nid = by_file_sym[[file, tsym]]
      return nid unless nid.nil?

      cands = by_sym[tsym]
      if cands.size == 1
        cands.first
      elsif cands.size > 1
        stats[:ambiguous_to] += 1
        nil
      end
    end

    # deterministic scalar quoting — JSON string quoting is valid YAML (probe parity)
    def yaml_scalar(value)
      case value
      when nil then "null"
      when true then "true"
      when false then "false"
      when Integer, Float then value.to_s
      else JSON.generate(value)
      end
    end

    NODE_KEYS = %w[kind class_id loc self_time_ms total_time_ms count branches decisions
                   outcome_arity escapes entrypoint_kind terminal_kind].freeze

    def write_graph(out_path, nodes, edges, entrypoints)
      FileUtils.mkdir_p(File.dirname(out_path))
      File.open(out_path, "w") do |fh|
        fh.write(%(schema_version: "1.4"\n))
        fh.write(%(generator:\n  tool: "archbuddy 0.12.0"\n  adapter: "ruby"\n  capture: "static"\n))
        fh.write("nodes:\n")
        nodes.keys.sort.each do |nid|
          n = nodes[nid]
          fh.write(%(- id: "#{nid}"\n))
          NODE_KEYS.each do |k|
            fh.write("  #{k}: #{yaml_scalar(n[k])}\n") if n.key?(k)
          end
        end
        fh.write("edges:\n")
        edges.each do |src, dst, calls|
          fh.write(%(- from: "#{src}"\n  to: "#{dst}"\n  calls: #{calls}\n  count: null\n  self_time_ms: null\n))
        end
        fh.write("entrypoints:\n")
        entrypoints.uniq.sort.each { |nid| fh.write(%(- "#{nid}"\n)) }
      end
    end
  end
end
