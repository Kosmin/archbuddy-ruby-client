# frozen_string_literal: true

require "tmpdir"

RSpec.describe "Collector end-to-end (K-1..K-8)" do
  let(:fixture_root) { File.expand_path("../fixtures/sample", __dir__) }
  let(:config) { Archbuddy::Collect::Config.new(language: "ruby") }

  def anonymize
    adapter = Archbuddy::Collect::Registry.for("ruby").new(fixture_root, config)
    Archbuddy::Collect::Anonymizer.new(
      adapter.collect, tool: "archbuddy test", adapter: "ruby"
    ).call
  end

  let(:result) { anonymize }
  let(:graph)  { result.graph }
  let(:id_map) { result.id_map }
  let(:ids)    { ArchitectureAuditor::Contract::Ids }

  # --- helpers ----------------------------------------------------------------

  def id_map_entry_for_symbol(symbol)
    id_map["ids"].find { |_id, desc| desc["symbol"] == symbol }
  end

  def node_for_symbol(symbol)
    opaque_id, = id_map_entry_for_symbol(symbol)
    graph["nodes"].find { |n| n["id"] == opaque_id }
  end

  # --- contract validity ------------------------------------------------------

  it "produces a graph that validates against the engine's graph schema (D37)" do
    expect {
      ArchitectureAuditor::Contract::Validator.validate!(:graph, graph)
    }.not_to raise_error
  end

  it "carries the static-capture generator metadata" do
    expect(graph["generator"]).to eq(
      "tool" => "archbuddy test", "adapter" => "ruby", "capture" => "static"
    )
    expect(graph["schema_version"]).to eq(ArchitectureAuditor::Contract::SCHEMA_VERSION)
  end

  # --- ids (D25/D41) ----------------------------------------------------------

  it "mints every node id via Contract::Ids and matches the D41 regex" do
    expect(graph["nodes"]).not_to be_empty
    graph["nodes"].each do |node|
      expect(ids.valid?(node["id"])).to be(true), "bad id: #{node['id']}"
    end
    graph["entrypoints"].each { |id| expect(ids.valid?(id)).to be(true) }
    graph["edges"].each do |edge|
      expect(ids.valid?(edge["from"])).to be(true)
      expect(ids.valid?(edge["to"])).to be(true)
    end
  end

  it "mints node ids that equal the contract Ids mint for the real triple" do
    opaque_id, desc = id_map_entry_for_symbol("Billing::Invoice#total")
    expected = ids.node_id(desc["file"], desc["line"], desc["symbol"])
    expect(opaque_id).to eq(expected)
  end

  # --- the verified AR implicit-self gotcha (db_op via class context) ---------

  it "classifies implicit-self `where` inside def self.x of an AR subclass as db_op" do
    entry = id_map_entry_for_symbol("Billing::Invoice.where")
    expect(entry).not_to be_nil, "expected a db_op node for the implicit-self where"

    opaque_id, desc = entry
    expect(desc["kind"]).to eq("db_op")

    node = graph["nodes"].find { |n| n["id"] == opaque_id }
    expect(node["kind"]).to eq("db_op")
  end

  # --- operator deny-list (D36) -----------------------------------------------

  it "drops operator methods (no `+` node, no edge to one)" do
    expect(id_map_entry_for_symbol("Billing::Invoice#+")).to be_nil
    plus_ids = id_map["ids"].select { |_id, d| d["symbol"].to_s.end_with?("#+") }
    expect(plus_ids).to be_empty
  end

  # --- single shared external sink --------------------------------------------

  it "routes an unresolved call to a single shared external sink" do
    external_nodes = graph["nodes"].select { |n| n["kind"] == "external" }
    expect(external_nodes.length).to eq(1)
    expect(external_nodes.first["id"]).to start_with("ext_")

    # tax -> external sink edge exists.
    tax_id, = id_map_entry_for_symbol("Billing::Invoice#tax")
    ext_id  = external_nodes.first["id"]
    edge    = graph["edges"].find { |e| e["from"] == tax_id && e["to"] == ext_id }
    expect(edge).not_to be_nil
    expect(edge["calls"]).to be >= 1
  end

  # --- resolvable cross-class edge --------------------------------------------

  it "builds a resolvable edge for an app Const.method call" do
    from_id, = id_map_entry_for_symbol("OrdersController#index")
    to_id,   = id_map_entry_for_symbol("Billing::Invoice.overdue")
    edge = graph["edges"].find { |e| e["from"] == from_id && e["to"] == to_id }
    expect(edge).not_to be_nil
    expect(edge["calls"]).to be >= 1
  end

  it "marks controller actions as endpoint nodes" do
    node = node_for_symbol("OrdersController#index")
    expect(node["kind"]).to eq("endpoint")
  end

  # --- id-map secret content + class rollups (D42) ----------------------------

  it "records real symbols and cls_ class_rollup entries in the id-map" do
    rollups = id_map["ids"].select { |_id, d| d["kind"] == "class_rollup" }
    expect(rollups).not_to be_empty

    invoice_rollup = rollups.find { |_id, d| d["symbol"] == "Billing::Invoice" }
    expect(invoice_rollup).not_to be_nil
    cls_id, = invoice_rollup
    expect(cls_id).to start_with("cls_")
    expect(ids.valid?(cls_id)).to be(true)

    # a method node references its class rollup via class_id
    total = node_for_symbol("Billing::Invoice#total")
    expect(total["class_id"]).to eq(cls_id)
  end

  it "NEVER emits a cls_ id as a graph nodes[] entry (D42)" do
    expect(graph["nodes"].map { |n| n["id"] }).to all(satisfy { |id| !id.start_with?("cls_") })
  end

  # --- static timing fields null (D4) -----------------------------------------

  it "writes all static timing fields as null" do
    graph["nodes"].each do |n|
      expect(n["self_time_ms"]).to be_nil
      expect(n["total_time_ms"]).to be_nil
      expect(n["count"]).to be_nil
      expect(n).to have_key("class_id")
      expect(n).to have_key("loc")
    end
    graph["edges"].each do |e|
      expect(e["count"]).to be_nil
      expect(e["self_time_ms"]).to be_nil
    end
  end
end
