# frozen_string_literal: true

require "archbuddy/cache"
require "tmpdir"
require "json"

# C1-2 / C4: ADAPTIVE SHARDING is a pure function of serialized fragment size.
#   small source file  (< 64 KiB) -> a single <path>.json
#   large source file  (>= 64 KiB) -> a <path>/ directory split per class
#   a single class still >= 64 KiB -> per-method under <path>/<Class>/
RSpec.describe "Cache::Writer adaptive sharding" do
  # Build an opaque graph + id-map with `n_classes` classes each holding
  # `n_methods` methods, ALL in one source file, so the serialized fragment can
  # be pushed over the 64 KiB threshold on demand.
  def synthetic(rel_file:, n_classes:, n_methods:)
    ids   = {}
    nodes = []
    n_classes.times do |ci|
      cls_id = format("cls_%012x", ci)
      cls    = "Big::Class#{ci}"
      ids[cls_id] = { "file" => rel_file, "symbol" => cls, "kind" => "class_rollup",
                      "class_id" => nil, "line" => ci }
      n_methods.times do |mi|
        nid = format("n_%012x", (ci * 10_000) + mi)
        sym = "#{cls}#method_with_a_reasonably_long_name_#{mi}"
        ids[nid] = { "file" => rel_file, "symbol" => sym, "kind" => "function",
                     "class_id" => cls_id, "line" => mi }
        nodes << { "id" => nid, "branches" => 1, "decisions" => 0 }
      end
    end
    graph  = { "nodes" => nodes, "edges" => [], "entrypoints" => [] }
    id_map = { "ids" => ids }
    [graph, id_map]
  end

  it "keeps a small file as one single JSON" do
    Dir.mktmpdir do |dir|
      graph, id_map = synthetic(rel_file: "app/small.rb", n_classes: 1, n_methods: 2)
      result = Archbuddy::Cache::Writer.new(project_root: dir).write(graph: graph, id_map: id_map)
      agg = JSON.parse(File.read(File.join(dir, "archbuddy-findings.json")))
      expect(agg["sources"]["app/small.rb"]["shard_mode"]).to eq(Archbuddy::Cache::Layout::MODE_SINGLE)
      expect(File).to exist(File.join(dir, ".archbuddy/app/small.rb.json"))
      expect(result[:fragments]).to eq([".archbuddy/app/small.rb.json"])
    end
  end

  it "splits a large file (>= 64 KiB) into a per-class directory" do
    Dir.mktmpdir do |dir|
      # ~40 classes * ~30 methods → well over 64 KiB serialized
      graph, id_map = synthetic(rel_file: "app/god.rb", n_classes: 40, n_methods: 30)
      result = Archbuddy::Cache::Writer.new(project_root: dir).write(graph: graph, id_map: id_map)
      agg = JSON.parse(File.read(File.join(dir, "archbuddy-findings.json")))

      expect(agg["sources"]["app/god.rb"]["shard_mode"]).to eq(Archbuddy::Cache::Layout::MODE_PER_CLASS)
      # a directory, one file per class
      expect(File).to be_directory(File.join(dir, ".archbuddy/app/god.rb"))
      per_class = result[:fragments].select { |p| p.start_with?(".archbuddy/app/god.rb/") }
      expect(per_class.length).to eq(40)
      expect(per_class).to include(".archbuddy/app/god.rb/Big__Class0.json")
    end
  end

  it "splits a single god-class (>= 64 KiB alone) into per-method files" do
    Dir.mktmpdir do |dir|
      # 1 class with enough methods to clear 64 KiB on its own
      graph, id_map = synthetic(rel_file: "app/mega.rb", n_classes: 1, n_methods: 1200)
      result = Archbuddy::Cache::Writer.new(project_root: dir).write(graph: graph, id_map: id_map)
      agg = JSON.parse(File.read(File.join(dir, "archbuddy-findings.json")))

      expect(agg["sources"]["app/mega.rb"]["shard_mode"]).to eq(Archbuddy::Cache::Layout::MODE_PER_METHOD)
      per_method = result[:fragments].select { |p| p.include?("/Big__Class0/") }
      expect(per_method.length).to eq(1200)
    end
  end

  it "shard decision is deterministic (same size → same mode across runs)" do
    Dir.mktmpdir do |dir|
      graph, id_map = synthetic(rel_file: "app/god.rb", n_classes: 40, n_methods: 30)
      w = Archbuddy::Cache::Writer.new(project_root: dir)
      first = w.write(graph: graph, id_map: id_map)[:fragments].sort
      second = w.write(graph: graph, id_map: id_map)[:fragments].sort
      expect(second).to eq(first)
    end
  end
end
