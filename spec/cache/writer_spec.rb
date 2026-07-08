# frozen_string_literal: true

require "archbuddy/cache"
require "tmpdir"
require "json"

# C1-2: DE-ANON-AT-WRITE committed cache. Cache::Writer transcodes the opaque
# graph + SECRET id-map (+ optional opaque findings) into the REAL-NAME,
# LINE-FREE committed layout. A fresh clone reads it with NO id-map.
RSpec.describe Archbuddy::Cache::Writer do
  let(:fixture_root) { File.expand_path("../fixtures/sample", __dir__) }
  let(:config)       { Archbuddy::Collect::Config.new(language: "ruby") }

  # Full opaque interchange for the sample fixture (graph + id-map), the exact
  # inputs the Writer de-anonymizes.
  def anon
    adapter = Archbuddy::Collect::Registry.for("ruby").new(fixture_root, config)
    Archbuddy::Collect::Anonymizer.new(
      adapter.collect, tool: "archbuddy test", adapter: "ruby"
    ).call
  end

  def write_into(dir, findings: nil)
    a = anon
    Archbuddy::Cache::Writer.new(project_root: dir)
                            .write(graph: a.graph, id_map: a.id_map, findings: findings)
  end

  it "writes a real-name, line-free fragment per source file" do
    Dir.mktmpdir do |dir|
      write_into(dir)
      frag_path = File.join(dir, ".archbuddy/app/models/invoice.rb.json")
      expect(File).to exist(frag_path)

      frag = JSON.parse(File.read(frag_path))
      expect(frag["file"]).to eq("app/models/invoice.rb")
      # REAL names (class-path keyed), NOT opaque ids
      symbols = frag["nodes"].map { |n| n["symbol"] }
      expect(symbols).to include("Billing::Invoice#total", "Billing::Invoice.overdue")
      # LINE-FREE: no node carries any line-derived field
      frag["nodes"].each { |n| expect(n.keys).not_to include("line", "loc") }
      # opaque ids never leak into the committed cache
      expect(File.read(frag_path)).not_to match(/\bn_[0-9a-f]{12}\b/)
    end
  end

  it "writes a compact ROOT aggregate with POINTERS, not inlined payload" do
    Dir.mktmpdir do |dir|
      write_into(dir)
      agg = JSON.parse(File.read(File.join(dir, "archbuddy-findings.json")))
      expect(agg["sources"].keys).to contain_exactly(
        "app/controllers/orders_controller.rb", "app/models/invoice.rb"
      )
      ptr = agg["sources"]["app/models/invoice.rb"]
      expect(ptr["path"]).to eq(".archbuddy/app/models/invoice.rb.json")
      expect(ptr["shard_mode"]).to eq(Archbuddy::Cache::Layout::MODE_SINGLE)
      # compact: no per-node detail inlined in the aggregate
      expect(agg).not_to have_key("nodes")
    end
  end

  it "de-anonymizes findings scores + the multiplexer_proxy list into the aggregate" do
    Dir.mktmpdir do |dir|
      findings = {
        "scores" => {
          "forward_discoverability" => { "grade" => "B", "score" => 82.0, "hotspots" => ["n_x"] },
          "reverse_traceability"    => { "grade" => "F", "score" => 41.0 },
          "multiplexer_proxies"     => [] # empty smell → passes through as []
        }
      }
      write_into(dir, findings: findings)
      agg = JSON.parse(File.read(File.join(dir, "archbuddy-findings.json")))
      expect(agg["scores"]["forward_discoverability"]).to eq("grade" => "B", "score" => 82.0)
      # opaque hotspot id list dropped from the compact headline
      expect(agg["scores"]["forward_discoverability"]).not_to have_key("hotspots")
      expect(agg["multiplexer_proxies"]).to eq([])
    end
  end

  it "renders multiplexer_proxy real names worst-first, verbatim added_coupling" do
    Dir.mktmpdir do |dir|
      a = anon
      # pick a real opaque id from the id-map for a known method
      proxy_id, = a.id_map["ids"].find { |_id, d| d["symbol"] == "Billing::Invoice#total" }
      findings = {
        "scores" => {
          "forward_discoverability" => { "grade" => "A", "score" => 2.0 },
          "reverse_traceability"    => { "grade" => "A", "score" => 2.0 },
          "multiplexer_proxies"     => [{ "node" => proxy_id, "added_coupling" => 7.5 }]
        }
      }
      Archbuddy::Cache::Writer.new(project_root: dir)
                              .write(graph: a.graph, id_map: a.id_map, findings: findings)
      agg = JSON.parse(File.read(File.join(dir, "archbuddy-findings.json")))
      expect(agg["multiplexer_proxies"]).to eq(
        [{ "symbol" => "Billing::Invoice#total", "added_coupling" => 7.5 }]
      )
    end
  end

  # A collect-only re-write (findings: nil) must PRESERVE the scores +
  # multiplexer_proxy block a prior analyze/reset committed — so a plain collect
  # after an analyze does NOT clobber the aggregate's score block (which would
  # trip --check and break the blank-line-clean invariant for the real flow).
  it "preserves an existing aggregate's scores when re-written by a collect-only pass" do
    Dir.mktmpdir do |dir|
      findings = {
        "scores" => {
          "forward_discoverability" => { "grade" => "C", "score" => 60.0 },
          "reverse_traceability"    => { "grade" => "D", "score" => 50.0 },
          "multiplexer_proxies"     => []
        }
      }
      # analyze/reset write (with findings) → rich aggregate.
      write_into(dir, findings: findings)
      rich = JSON.parse(File.read(File.join(dir, "archbuddy-findings.json")))
      expect(rich).to have_key("scores")

      # collect-only re-write (findings: nil) → scores PRESERVED byte-identically.
      write_into(dir, findings: nil)
      after = JSON.parse(File.read(File.join(dir, "archbuddy-findings.json")))
      expect(after["scores"]).to eq(rich["scores"])
      expect(after["multiplexer_proxies"]).to eq(rich["multiplexer_proxies"])
    end
  end

  it "produces byte-identical committed output across two runs (determinism)" do
    Dir.mktmpdir do |dir|
      write_into(dir)
      first = read_committed(dir)
      write_into(dir)
      expect(read_committed(dir)).to eq(first)
    end
  end

  # C1 VALUE-LEVEL LINE STABILITY: a fragment built from an id-map whose `line`
  # values differ (a pure line move) is byte-identical — line is display-only,
  # never serialized into a committed value.
  it "committed values are line-free: shifting every id-map line leaves the cache identical" do
    Dir.mktmpdir do |dir|
      a = anon
      shifted = deep_dup(a.id_map)
      shifted["ids"].each_value { |d| d["line"] = d["line"].to_i + 100 if d["line"] }

      w = Archbuddy::Cache::Writer.new(project_root: dir)
      w.write(graph: a.graph, id_map: a.id_map)
      before = read_committed(dir)
      w.write(graph: a.graph, id_map: shifted)
      expect(read_committed(dir)).to eq(before)
    end
  end

  def read_committed(dir)
    Dir.glob(File.join(dir, "**", "*.json"))
       .reject { |p| p.include?("/.archbuddy/.cache/") }
       .sort
       .to_h { |p| [p.sub("#{dir}/", ""), File.read(p)] }
  end

  def deep_dup(obj)
    JSON.parse(JSON.generate(obj))
  end
end
