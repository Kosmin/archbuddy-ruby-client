# frozen_string_literal: true

require "archbuddy/cache"
require "tmpdir"
require "json"

# v0.9 W2: Cache::DetailTree reassembles the COMMITTED, REAL-NAME detail tree
# (adaptively sharded per class / method) back into ONE real-name node/edge set
# so the default report can render a clean real-name graph WITHOUT the id-map.
# The reader must reassemble edges ACROSS shards (a large file's fragment is
# split per class), which is the C4 gotcha noted in the design.
RSpec.describe "Cache::DetailTree reassembly (v0.9 W2)" do
  # Build an opaque graph + id-map with `n_classes` classes, `n_methods` each,
  # ALL in one source file (so it can be pushed over the 64 KiB shard threshold),
  # plus one edge per class from method 0 -> method 1 (an intra-class edge that
  # must survive the per-class split) and one CROSS-class edge class0 -> class1
  # (which must be reassembled from two different shards).
  def synthetic(rel_file:, n_classes:, n_methods:)
    ids   = {}
    nodes = []
    edges = []
    first_of = {}
    n_classes.times do |ci|
      cls_id = format("cls_%012x", ci)
      cls    = "Big::Class#{ci}"
      ids[cls_id] = { "file" => rel_file, "symbol" => cls, "kind" => "class_rollup",
                      "class_id" => nil, "line" => ci }
      method_ids = []
      n_methods.times do |mi|
        nid = format("n_%012x", (ci * 10_000) + mi)
        sym = "#{cls}#method_with_a_reasonably_long_name_#{mi}"
        ids[nid] = { "file" => rel_file, "symbol" => sym, "kind" => "function",
                     "class_id" => cls_id, "line" => mi }
        nodes << { "id" => nid, "branches" => 1, "decisions" => 0 }
        method_ids << nid
      end
      first_of[ci] = method_ids.first
      edges << { "from" => method_ids[0], "to" => method_ids[1], "calls" => 1 } if method_ids.size > 1
    end
    # A CROSS-class edge: class0.method0 -> class1.method0 (endpoints land in
    # different per-class shards, so reassembly must union across files).
    edges << { "from" => first_of[0], "to" => first_of[1], "calls" => 3 } if n_classes > 1

    graph  = { "nodes" => nodes, "edges" => edges, "entrypoints" => [] }
    id_map = { "ids" => ids }
    [graph, id_map]
  end

  def write_and_reassemble(dir, graph, id_map)
    Archbuddy::Cache::Writer.new(project_root: dir).write(graph: graph, id_map: id_map)
    agg = JSON.parse(File.read(File.join(dir, "archbuddy-findings.json")))
    Archbuddy::Cache::DetailTree.new(project_root: dir).reassemble(aggregate: agg)
  end

  it "reassembles a SINGLE-mode fragment into real-name nodes + edges" do
    Dir.mktmpdir do |dir|
      graph, id_map = synthetic(rel_file: "app/small.rb", n_classes: 2, n_methods: 2)
      reassembled = write_and_reassemble(dir, graph, id_map)

      # 2 classes * 2 methods = 4 real-name nodes; ids ARE the real symbols.
      expect(reassembled["nodes"].size).to eq(4)
      expect(reassembled["nodes"].map { |n| n["id"] }).to all(start_with("Big::Class"))
      # 2 intra-class edges + 1 cross-class edge.
      expect(reassembled["edges"].size).to eq(3)
      cross = reassembled["edges"].find { |e| e["calls"] == 3 }
      expect(cross["from"]).to eq("Big::Class0#method_with_a_reasonably_long_name_0")
      expect(cross["to"]).to eq("Big::Class1#method_with_a_reasonably_long_name_0")
    end
  end

  it "reassembles edges ACROSS per-class shards for a large (sharded) file" do
    Dir.mktmpdir do |dir|
      # ~40 classes * ~30 methods → well over 64 KiB → per-class directory shards.
      graph, id_map = synthetic(rel_file: "app/god.rb", n_classes: 40, n_methods: 30)

      Archbuddy::Cache::Writer.new(project_root: dir).write(graph: graph, id_map: id_map)
      agg = JSON.parse(File.read(File.join(dir, "archbuddy-findings.json")))
      # Confirm it actually sharded (not a single file) — otherwise the test is vacuous.
      expect(agg["sources"]["app/god.rb"]["shard_mode"]).to eq(Archbuddy::Cache::Layout::MODE_PER_CLASS)

      reassembled = Archbuddy::Cache::DetailTree.new(project_root: dir).reassemble(aggregate: agg)

      # All 40*30 = 1200 real-name method nodes recovered across shards.
      expect(reassembled["nodes"].size).to eq(1200)
      # The CROSS-class edge (endpoints in two DIFFERENT shard files) survived.
      cross = reassembled["edges"].find { |e| e["calls"] == 3 }
      expect(cross).not_to be_nil
      expect(cross["from"]).to eq("Big::Class0#method_with_a_reasonably_long_name_0")
      expect(cross["to"]).to eq("Big::Class1#method_with_a_reasonably_long_name_0")
    end
  end

  it "returns an empty graph when there is no aggregate / detail tree" do
    Dir.mktmpdir do |dir|
      reassembled = Archbuddy::Cache::DetailTree.new(project_root: dir).reassemble
      expect(reassembled).to eq("nodes" => [], "edges" => [])
    end
  end
end
