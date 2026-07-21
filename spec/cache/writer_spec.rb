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
      # v0.11 (v3, R8): the headline dimension also carries median /
      # median_grade / capped_fraction — null on a pre-1.6 findings doc.
      expect(agg["scores"]["forward_discoverability"]).to eq(
        "grade" => "B", "score" => 82.0,
        "median" => nil, "median_grade" => nil, "capped_fraction" => nil
      )
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
          "multiplexer_proxies"     => [],
          # v0.11 (v3): the carry list extends to every 1.6-fed block
          "blast_radius" => { "max" => 2, "p90" => 2.0, "median" => 1.0, "mean" => 1.5,
                              "reached_nodes" => 2, "total_nodes" => 4, "total_entrypoints" => 2,
                              "pct_use_cases_hit_by_worst" => 1.0, "worst" => [] },
          "forward_depth"    => { "mean" => 2.0, "median" => 2.0, "count" => 2 },
          "reverse_depth"    => { "mean" => 3.0, "median" => 3.0, "count" => 2 },
          "branching_factor" => { "mean" => 1.5, "median" => 1.5, "count" => 2 },
          "egress" => { "grade" => "A", "score" => 4.0, "median" => 4.0, "hotspots" => [] }
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
      # v0.11 (v3): the new blocks + the egress cost keys ride the carry too
      %w[blast_radius forward_depth reverse_depth branching_factor].each do |key|
        expect(after[key]).to eq(rich[key])
      end
      expect(after["egress"]["mean"]).to eq(4.0)
      expect(after["egress"]["median"]).to eq(4.0)
    end
  end

  # v0.10 W3 (A1, serializer v2): the fragment node carries the ingress
  # category string beside the `entrypoint` boolean (from the W1-A1 id-map
  # stamp) — a category word, NOT a line (C1 line-free invariant untouched).
  it "stamps entrypoint_kind on fragment nodes beside the entrypoint boolean (serializer v2)" do
    Dir.mktmpdir do |dir|
      write_into(dir)

      frag = JSON.parse(File.read(File.join(dir, ".archbuddy/app/controllers/orders_controller.rb.json")))
      expect(frag["serializer_version"]).to eq(5)
      action = frag["nodes"].find { |n| n["symbol"] == "OrdersController#index" }
      expect(action["entrypoint"]).to be(true)
      expect(action["entrypoint_kind"]).to eq("controllers")

      model = JSON.parse(File.read(File.join(dir, ".archbuddy/app/models/invoice.rb.json")))
      plain = model["nodes"].find { |n| n["symbol"] == "Billing::Invoice#total" }
      expect(plain["entrypoint"]).to be(false)
      expect(plain["entrypoint_kind"]).to be_nil
    end
  end

  # --- v0.12 (serializer v4): the findings-1.7 variety_mass fold -------------

  # A full 1.7-shaped variety_mass block (doc-shaped — the I3-4/I3-9 keys):
  # composite + BOTH disclosures (capped_fraction = CAP, fallback_fraction =
  # THE L17 one) + first-class component stats + by_category, with opaque
  # hotspot id lists at both levels (which the committed fold must DROP).
  def vm_17_block
    {
      "score" => 57.0, "median" => 57.0, "count" => 2,
      "capped_fraction" => 0.0, "fallback_fraction" => 0.5,
      "hotspots" => %w[n_aaa n_bbb],
      "variety" => { "mean" => 16.0, "median" => 16.0, "count" => 2 },
      "mass"    => { "mean" => 41.0, "median" => 41.0, "count" => 2 },
      "by_category" => {
        "controllers" => {
          "score" => 57.0, "median" => 57.0, "count" => 2,
          "capped_fraction" => 0.0, "fallback_fraction" => 0.5,
          "hotspots" => %w[n_aaa],
          "variety" => { "mean" => 16.0, "median" => 16.0, "count" => 2 },
          "mass"    => { "mean" => 41.0, "median" => 41.0, "count" => 2 }
        }
      }
    }
  end

  def findings_with_vm(vm)
    {
      "scores" => {
        "forward_discoverability" => { "grade" => "B", "score" => 82.0 },
        "reverse_traceability"    => { "grade" => "F", "score" => 41.0 },
        "multiplexer_proxies"     => [],
        "variety_mass"            => vm
      }
    }
  end

  it "folds the 1.7 variety_mass block verbatim (zero arithmetic), hotspots dropped at both levels" do
    Dir.mktmpdir do |dir|
      write_into(dir, findings: findings_with_vm(vm_17_block))
      agg = JSON.parse(File.read(File.join(dir, "archbuddy-findings.json")))
      vm  = agg["variety_mass"]

      # every folded scalar deep-equals the source (verbatim — D17)
      expect(vm["score"]).to eq(57.0)
      expect(vm["median"]).to eq(57.0)
      expect(vm["count"]).to eq(2)
      expect(vm["capped_fraction"]).to eq(0.0)
      expect(vm["fallback_fraction"]).to eq(0.5)
      expect(vm["variety"]).to eq("mean" => 16.0, "median" => 16.0, "count" => 2)
      expect(vm["mass"]).to eq("mean" => 41.0, "median" => 41.0, "count" => 2)
      # UNGRADED end-to-end: no grade key is ever minted
      expect(vm.keys).not_to include("grade", "median_grade")
      # opaque hotspot id lists dropped — top level AND per kind
      expect(vm).not_to have_key("hotspots")
      cat = vm["by_category"]["controllers"]
      expect(cat).not_to have_key("hotspots")
      expect(cat["score"]).to eq(57.0)
      expect(cat["fallback_fraction"]).to eq(0.5)
      expect(cat["variety"]).to eq("mean" => 16.0, "median" => 16.0, "count" => 2)
    end
  end

  it "writes NO variety_mass key from a 1.6-shaped findings doc (absence, never fabricated)" do
    Dir.mktmpdir do |dir|
      findings = findings_with_vm(nil).tap { |f| f["scores"].delete("variety_mass") }
      write_into(dir, findings: findings)
      agg = JSON.parse(File.read(File.join(dir, "archbuddy-findings.json")))
      expect(agg).not_to have_key("variety_mass")
    end
  end

  it "passes the engine N/A form through as an honest present-but-null block" do
    Dir.mktmpdir do |dir|
      na = {
        "score" => nil, "median" => nil, "count" => 0,
        "capped_fraction" => nil, "fallback_fraction" => nil,
        "hotspots" => [],
        "variety" => { "mean" => nil, "median" => nil, "count" => 0 },
        "mass"    => { "mean" => nil, "median" => nil, "count" => 0 }
      }
      write_into(dir, findings: findings_with_vm(na))
      agg = JSON.parse(File.read(File.join(dir, "archbuddy-findings.json")))
      vm  = agg["variety_mass"]
      expect(vm["score"]).to be_nil
      expect(vm["count"]).to eq(0)
      expect(vm["fallback_fraction"]).to be_nil
      expect(vm["variety"]).to eq("mean" => nil, "median" => nil, "count" => 0)
      # absent by_category on the source → honest empty lens
      expect(vm["by_category"]).to eq({})
    end
  end

  it "carries variety_mass forward on a collect-only write; a v3 prior grafts nothing" do
    Dir.mktmpdir do |dir|
      # analyze write → rich v4 aggregate; collect-only re-write → carried verbatim
      write_into(dir, findings: findings_with_vm(vm_17_block))
      rich = JSON.parse(File.read(File.join(dir, "archbuddy-findings.json")))
      write_into(dir, findings: nil)
      after = JSON.parse(File.read(File.join(dir, "archbuddy-findings.json")))
      expect(after["variety_mass"]).to eq(rich["variety_mass"])

      # v3-vintage prior (no variety_mass key) → a collect manufactures nothing
      prior = after.reject { |k, _| k == "variety_mass" }.merge("serializer_version" => 3)
      File.write(File.join(dir, "archbuddy-findings.json"), JSON.generate(prior))
      write_into(dir, findings: nil)
      regrafted = JSON.parse(File.read(File.join(dir, "archbuddy-findings.json")))
      expect(regrafted).not_to have_key("variety_mass")
    end
  end

  # --- v0.12 (serializer v4, A5): fragment outcome_arity / escapes keys ------

  it "stamps outcome_arity/escapes on fragment nodes from the id-map descriptor (serializer v4)" do
    Dir.mktmpdir do |dir|
      write_into(dir)
      model = JSON.parse(File.read(File.join(dir, ".archbuddy/app/models/invoice.rb.json")))
      model["nodes"].each do |n|
        expect(n).to have_key("outcome_arity")
        expect(n).to have_key("escapes")
        expect(n["outcome_arity"]).to be_an(Integer).and(be >= 1) unless n["outcome_arity"].nil?
        expect([true, false]).to include(n["escapes"])
      end
      # a literal-returning closed method resolves to arity 1 (VALUE)
      subtotal = model["nodes"].find { |n| n["symbol"] == "Billing::Invoice#subtotal" }
      expect(subtotal["outcome_arity"]).to eq(1)
      expect(subtotal["escapes"]).to be(false)
    end
  end

  it "never fabricates fragment arity: an unresolved descriptor writes null, escapes defaults false" do
    Dir.mktmpdir do |dir|
      graph = {
        "schema_version" => "1.0", "language" => "ruby",
        "nodes" => [{ "id" => "n_1", "kind" => "function", "branches" => 1, "decisions" => 0 }],
        "edges" => [], "entrypoints" => []
      }
      id_map = {
        "ids" => {
          # descriptor WITHOUT outcome_arity/escapes — the unresolved shape
          "n_1" => { "symbol" => "Foo#bar", "kind" => "function", "file" => "lib/foo.rb" }
        }
      }
      Archbuddy::Cache::Writer.new(project_root: dir).write(graph: graph, id_map: id_map)
      frag = JSON.parse(File.read(File.join(dir, ".archbuddy/lib/foo.rb.json")))
      node = frag["nodes"].first
      expect(node["outcome_arity"]).to be_nil
      expect(node["escapes"]).to be(false)
    end
  end

  # --- v0.13 (serializer v5): fragment compass stamps + the carry mechanism --

  COMPASS_KEYS = %w[leverage collapse toll_booth quadrant].freeze

  # findings 1.8-shaped inputs for the sample fixture: the top-level per-node
  # `reusability` map (keyed by OPAQUE id) + the scores.reusability_compass
  # summary (worst-lists carry opaque ids the fold must de-anonymize).
  def opaque_id_for(a, symbol)
    id, = a.id_map["ids"].find { |_id, d| d["symbol"] == symbol }
    id
  end

  def compass_findings(a, leverage: 4.0)
    total_id = opaque_id_for(a, "Billing::Invoice#total")
    sub_id   = opaque_id_for(a, "Billing::Invoice#subtotal")
    {
      "scores" => {
        "forward_discoverability" => { "grade" => "B", "score" => 82.0 },
        "reverse_traceability"    => { "grade" => "F", "score" => 41.0 },
        "multiplexer_proxies"     => [],
        "reusability_compass"     => {
          "reuse_index"       => { "mean" => 2.4, "median" => 1.0 },
          "unshared_fraction" => 0.5,
          "toll_booths"       => [{ "node" => sub_id, "blast" => 4, "mass_savings" => 8 }],
          "extraction"        => [{ "node" => total_id, "collapse" => 16.0, "leverage" => leverage }],
          "leverage"          => { "mean" => 3.1, "median" => 2.0, "count" => 2 }
        }
      },
      "reusability" => {
        total_id => { "leverage" => leverage, "collapse" => 2.0, "toll_booth" => false,
                      "blast" => 5, "quadrant" => "load_bearing" },
        sub_id   => { "leverage" => 1.0, "collapse" => 1.0, "toll_booth" => true,
                      "blast" => 4, "quadrant" => "bypass_candidate" }
      }
    }
  end

  it "stamps compass keys on fragment nodes verbatim from the findings 1.8 reusability map (serializer v5)" do
    Dir.mktmpdir do |dir|
      a = anon
      Archbuddy::Cache::Writer.new(project_root: dir)
                              .write(graph: a.graph, id_map: a.id_map, findings: compass_findings(a))
      model = JSON.parse(File.read(File.join(dir, ".archbuddy/app/models/invoice.rb.json")))

      total = model["nodes"].find { |n| n["symbol"] == "Billing::Invoice#total" }
      expect(total["leverage"]).to eq(4.0)
      expect(total["collapse"]).to eq(2.0)
      expect(total["toll_booth"]).to be(false)
      expect(total["quadrant"]).to eq("load_bearing")

      subtotal = model["nodes"].find { |n| n["symbol"] == "Billing::Invoice#subtotal" }
      expect(subtotal["toll_booth"]).to be(true)
      expect(subtotal["quadrant"]).to eq("bypass_candidate")

      # a node WITHOUT a reusability entry carries honest nulls (all four
      # keys PRESENT — the deterministic v5 shape; null = never analyzed)
      other = model["nodes"].find { |n| n["symbol"] == "Billing::Invoice.overdue" }
      COMPASS_KEYS.each do |key|
        expect(other).to have_key(key)
        expect(other[key]).to be_nil
      end
    end
  end

  it "writes null compass stamps from a pre-1.8 findings doc (absence, never derived)" do
    Dir.mktmpdir do |dir|
      write_into(dir, findings: findings_with_vm(vm_17_block)) # a 1.7 doc: no reusability
      model = JSON.parse(File.read(File.join(dir, ".archbuddy/app/models/invoice.rb.json")))
      model["nodes"].each do |n|
        COMPASS_KEYS.each { |key| expect(n[key]).to be_nil }
      end
    end
  end

  it "first-ever collect writes null compass stamps (no prior to carry)" do
    Dir.mktmpdir do |dir|
      write_into(dir) # collect-only into a fresh tree
      model = JSON.parse(File.read(File.join(dir, ".archbuddy/app/models/invoice.rb.json")))
      model["nodes"].each do |n|
        COMPASS_KEYS.each do |key|
          expect(n).to have_key(key)
          expect(n[key]).to be_nil
        end
      end
    end
  end

  it "carries fragment compass stamps through a collect-only rewrite BYTE-identically (the MAJOR-2 mechanism)" do
    Dir.mktmpdir do |dir|
      a = anon
      writer = Archbuddy::Cache::Writer.new(project_root: dir)
      writer.write(graph: a.graph, id_map: a.id_map, findings: compass_findings(a))
      analyzed = read_fragments(dir)
      expect(analyzed).not_to be_empty

      # collect-after-analyze: stamps PRESERVED — every committed FRAGMENT is
      # byte-identical, so the detail tree never churns between collect and
      # analyze (the one-churn-event discipline; a plain stamp would have
      # nulled every compass key here)
      writer.write(graph: a.graph, id_map: a.id_map, findings: nil)
      expect(read_fragments(dir)).to eq(analyzed)
    end
  end

  it "reset+analyze refreshes stamps: fresh findings win over any prior fragment" do
    Dir.mktmpdir do |dir|
      a = anon
      writer = Archbuddy::Cache::Writer.new(project_root: dir)
      writer.write(graph: a.graph, id_map: a.id_map, findings: compass_findings(a, leverage: 4.0))
      writer.write(graph: a.graph, id_map: a.id_map, findings: compass_findings(a, leverage: 9.0))

      model = JSON.parse(File.read(File.join(dir, ".archbuddy/app/models/invoice.rb.json")))
      total = model["nodes"].find { |n| n["symbol"] == "Billing::Invoice#total" }
      expect(total["leverage"]).to eq(9.0)
    end
  end

  it "a v4-vintage prior fragment grafts nothing: stamps stay null, never manufactured" do
    Dir.mktmpdir do |dir|
      a = anon
      writer = Archbuddy::Cache::Writer.new(project_root: dir)
      writer.write(graph: a.graph, id_map: a.id_map, findings: compass_findings(a))

      # simulate a v4 prior: strip the compass keys off the committed fragment
      frag_path = File.join(dir, ".archbuddy/app/models/invoice.rb.json")
      v4 = JSON.parse(File.read(frag_path))
      v4["serializer_version"] = 4
      v4["nodes"].each { |n| COMPASS_KEYS.each { |key| n.delete(key) } }
      File.write(frag_path, JSON.generate(v4))

      writer.write(graph: a.graph, id_map: a.id_map, findings: nil)
      model = JSON.parse(File.read(frag_path))
      model["nodes"].each do |n|
        COMPASS_KEYS.each { |key| expect(n[key]).to be_nil }
      end
    end
  end

  it "drops a gone node's stamps with the node; survivors keep theirs (carry is per surviving symbol)" do
    Dir.mktmpdir do |dir|
      two_nodes = {
        "schema_version" => "1.0", "language" => "ruby",
        "nodes" => [
          { "id" => "n_1", "kind" => "function", "branches" => 1, "decisions" => 0 },
          { "id" => "n_2", "kind" => "function", "branches" => 1, "decisions" => 0 }
        ],
        "edges" => [], "entrypoints" => []
      }
      id_map = {
        "ids" => {
          "n_1" => { "symbol" => "Foo#keep", "kind" => "function", "file" => "lib/foo.rb" },
          "n_2" => { "symbol" => "Foo#gone", "kind" => "function", "file" => "lib/foo.rb" }
        }
      }
      findings = {
        "scores" => {},
        "reusability" => {
          "n_1" => { "leverage" => 2.0, "collapse" => 1.0, "toll_booth" => false, "quadrant" => "glue" },
          "n_2" => { "leverage" => 1.0, "collapse" => 1.0, "toll_booth" => true, "quadrant" => "glue" }
        }
      }
      writer = Archbuddy::Cache::Writer.new(project_root: dir)
      writer.write(graph: two_nodes, id_map: id_map, findings: findings)

      one_node = two_nodes.merge("nodes" => [two_nodes["nodes"].first])
      writer.write(graph: one_node, id_map: id_map, findings: nil) # collect-only

      frag = JSON.parse(File.read(File.join(dir, ".archbuddy/lib/foo.rb.json")))
      symbols = frag["nodes"].map { |n| n["symbol"] }
      expect(symbols).to eq(["Foo#keep"])
      expect(frag["nodes"].first["leverage"]).to eq(2.0) # survivor carried
    end
  end

  # --- v0.13 (serializer v5): the aggregate reusability fold ------------------

  it "folds the 1.8 reusability_compass block verbatim with de-anonymized worst-lists" do
    Dir.mktmpdir do |dir|
      a = anon
      Archbuddy::Cache::Writer.new(project_root: dir)
                              .write(graph: a.graph, id_map: a.id_map, findings: compass_findings(a))
      agg = JSON.parse(File.read(File.join(dir, "archbuddy-findings.json")))
      ru  = agg["reusability"]

      expect(ru["reuse_index"]).to eq("mean" => 2.4, "median" => 1.0)
      expect(ru["unshared_fraction"]).to eq(0.5)
      expect(ru["leverage"]).to eq("mean" => 3.1, "median" => 2.0, "count" => 2)
      # worst-lists de-anonymized to REAL symbols, engine order preserved
      expect(ru["toll_booths"]).to eq(
        [{ "symbol" => "Billing::Invoice#subtotal", "blast" => 4, "mass_savings" => 8 }]
      )
      expect(ru["extraction"]).to eq(
        [{ "symbol" => "Billing::Invoice#total", "collapse" => 16.0, "leverage" => 4.0 }]
      )
      # UNGRADED end-to-end: no grade key is ever minted
      expect(ru.keys).not_to include("grade", "median_grade")
    end
  end

  it "writes NO reusability key from a 1.7-shaped findings doc (absence, never fabricated)" do
    Dir.mktmpdir do |dir|
      write_into(dir, findings: findings_with_vm(vm_17_block))
      agg = JSON.parse(File.read(File.join(dir, "archbuddy-findings.json")))
      expect(agg).not_to have_key("reusability")
    end
  end

  it "carries reusability forward on a collect-only write; a v4 prior grafts nothing" do
    Dir.mktmpdir do |dir|
      a = anon
      writer = Archbuddy::Cache::Writer.new(project_root: dir)
      writer.write(graph: a.graph, id_map: a.id_map, findings: compass_findings(a))
      rich = JSON.parse(File.read(File.join(dir, "archbuddy-findings.json")))

      writer.write(graph: a.graph, id_map: a.id_map, findings: nil)
      after = JSON.parse(File.read(File.join(dir, "archbuddy-findings.json")))
      expect(after["reusability"]).to eq(rich["reusability"])

      # v4-vintage prior (no reusability key) → a collect manufactures nothing
      prior = after.reject { |k, _| k == "reusability" }.merge("serializer_version" => 4)
      File.write(File.join(dir, "archbuddy-findings.json"), JSON.generate(prior))
      writer.write(graph: a.graph, id_map: a.id_map, findings: nil)
      regrafted = JSON.parse(File.read(File.join(dir, "archbuddy-findings.json")))
      expect(regrafted).not_to have_key("reusability")
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

  # The committed DETAIL-TREE fragments only (the root aggregate excluded) —
  # the surface the v5 compass carry must hold byte-stable. Globbed explicitly
  # under the dot-directory (a bare `**/*.json` never descends into it).
  def read_fragments(dir)
    Dir.glob(File.join(dir, ".archbuddy", "**", "*.json"))
       .reject { |p| p.include?("/.archbuddy/.cache/") }
       .sort
       .to_h { |p| [p.sub("#{dir}/", ""), File.read(p)] }
  end

  def deep_dup(obj)
    JSON.parse(JSON.generate(obj))
  end
end
