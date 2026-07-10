# frozen_string_literal: true

require "tmpdir"
require "fileutils"

RSpec.describe "Collector end-to-end (K-1..K-8)" do
  let(:fixture_root) { File.expand_path("../fixtures/sample", __dir__) }
  let(:config) { Archbuddy::Collect::Config.new(language: "ruby") }

  def anonymize
    adapter = Archbuddy::Collect::Registry.for("ruby").new(fixture_root, config)
    Archbuddy::Collect::Anonymizer.new(
      adapter.collect, tool: "archbuddy test", adapter: "ruby"
    ).call
  end

  # Pre-anonymization adapter result (carries the diagnostics channel).
  def collect_raw
    Archbuddy::Collect::Registry.for("ruby").new(fixture_root, config).collect
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

  it "mints node ids that equal the contract Ids mint for the (rel_file, symbol) pair (id-parity, v0.8)" do
    opaque_id, desc = id_map_entry_for_symbol("Billing::Invoice#total")
    # v0.8 id-parity: the client-minted opaque id == the engine mint on the same
    # (rel_file, fq_symbol) pair — NO line (identity is name, not line).
    expected = ids.node_id(desc["file"], desc["symbol"])
    expect(opaque_id).to eq(expected)
  end

  it "id-parity: the client real_key equals the engine canonical_key for (rel_file, symbol)" do
    # The single most load-bearing cross-repo invariant: the client's RawNode
    # real_key (used for edge/entrypoint resolution + first-def-wins dedup) MUST be
    # byte-identical to the engine's canonical hashed key, so both repos mint the
    # SAME opaque id for the same symbol. Drift here silently corrupts the graph.
    raw = Archbuddy::Collect::Raw::RawNode.new(
      rel_file: "app/models/user.rb", line: 12, symbol: "User#save", kind: "function"
    )
    expect(raw.real_key).to eq(ids.canonical_key("app/models/user.rb", "User#save"))
  end

  it "move-a-def-id-stable: real_key/id does NOT change when a def moves (line differs)" do
    at_line_12 = Archbuddy::Collect::Raw::RawNode.new(
      rel_file: "app/models/user.rb", line: 12, symbol: "User#save", kind: "function"
    )
    at_line_99 = Archbuddy::Collect::Raw::RawNode.new(
      rel_file: "app/models/user.rb", line: 99, symbol: "User#save", kind: "function"
    )
    expect(at_line_99.real_key).to eq(at_line_12.real_key)
    expect(ids.node_id(at_line_99.rel_file, at_line_99.symbol))
      .to eq(ids.node_id(at_line_12.rel_file, at_line_12.symbol))
  end

  it "first-def-wins: two same-(file,symbol) raws collapse to ONE graph node (not a fabricated merge)" do
    # After dropping line from identity, a reopened class / conditional re-def
    # produces two raws with the same (rel_file, symbol). The Anonymizer must
    # collapse them to ONE node (the first def owns the id + its id-map line
    # payload) — a deterministic collapse, NOT two nodes and NOT a merge of two
    # distinct methods.
    first  = Archbuddy::Collect::Raw::RawNode.new(
      rel_file: "app/models/user.rb", line: 10, symbol: "User#save", kind: "function"
    )
    reopen = Archbuddy::Collect::Raw::RawNode.new(
      rel_file: "app/models/user.rb", line: 42, symbol: "User#save", kind: "function"
    )
    adapter_result = Struct.new(:nodes, :edges, :entrypoints).new([first, reopen], [], [])
    res = Archbuddy::Collect::Anonymizer.new(
      adapter_result, tool: "t", adapter: "ruby"
    ).call

    save_nodes = res.graph["nodes"].select { |n| n["id"] == ids.node_id("app/models/user.rb", "User#save") }
    expect(save_nodes.size).to eq(1)                        # collapsed to one
    expect(res.id_map["ids"].size).to eq(1)                 # one id-map entry
    expect(res.id_map["ids"].values.first["line"]).to eq(10) # FIRST def owns the line payload
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

  # --- probe seam diagnostic (W1 / P1) ----------------------------------------

  it "exposes a probe_edges diagnostic (empty until a probe is registered)" do
    diagnostics = collect_raw.diagnostics
    expect(diagnostics).to have_key(:probe_edges)
    expect(diagnostics[:probe_edges]).to eq({})
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

  # --- agnostic-boundary leak guard (D7/D16/D18) ------------------------------

  it "emits a null loc for every node (no real file:line leaks into graph.yml)" do
    expect(graph["nodes"]).not_to be_empty
    graph["nodes"].each do |node|
      expect(node).to have_key("loc")
      expect(node["loc"]).to be_nil, "node #{node['id']} leaked a loc: #{node['loc'].inspect}"
    end
  end

  it "keeps the REAL location ONLY in the secret id-map, never in graph.yml" do
    # The id-map still carries real file/line for de-anonymization...
    _opaque_id, desc = id_map_entry_for_symbol("OrdersController#index")
    expect(desc["file"]).to eq("app/controllers/orders_controller.rb")
    expect(desc["line"]).to be_a(Integer)

    # ...but that same real path appears NOWHERE in the graph hash.
    node = node_for_symbol("OrdersController#index")
    expect(node["loc"]).to be_nil
  end

  it "contains ZERO real app paths/symbols anywhere in the serialized graph.yml" do
    serialized = ArchitectureAuditor::Contract::Serializer.dump(graph)

    # Real file paths / extensions and fixture symbol names must not appear in
    # the shareable, supposedly-agnostic graph. Only opaque ids, kinds,
    # class_id refs, and null/numeric weights are allowed.
    %w[
      app/ .rb
      Invoice Orders overdue subtotal ApplicationRecord ExternalTaxApi
      Billing controllers models
    ].each do |needle|
      expect(serialized).not_to include(needle),
        "graph.yml leaked app semantics: found #{needle.inspect}"
    end

    # Belt-and-suspenders regex covering the same boundary.
    expect(serialized).not_to match(%r{app/|\.rb|Invoice|Orders|overdue})
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

  # --- branch/decision path-cost integers (graph 1.1, P3+P9) ------------------

  it "emits an integer branches(>=1)/decisions(>=0) on every graph node" do
    expect(graph["nodes"]).not_to be_empty
    graph["nodes"].each do |n|
      expect(n).to have_key("branches")
      expect(n).to have_key("decisions")
      expect(n["branches"]).to be_a(Integer)
      expect(n["decisions"]).to be_a(Integer)
      expect(n["branches"]).to be >= 1
      expect(n["decisions"]).to be >= 0
    end
  end

  it "keeps branches/decisions OUT of the secret id-map (graph node only)" do
    id_map["ids"].each_value do |desc|
      expect(desc).not_to have_key("branches")
      expect(desc).not_to have_key("decisions")
    end
  end

  it "defaults the external sink and db_op sinks to branches:1/decisions:0" do
    external = graph["nodes"].find { |n| n["kind"] == "external" }
    expect(external["branches"]).to eq(1)
    expect(external["decisions"]).to eq(0)

    db_id, = id_map_entry_for_symbol("Billing::Invoice.where")
    db_node = graph["nodes"].find { |n| n["id"] == db_id }
    expect(db_node["branches"]).to eq(1)
    expect(db_node["decisions"]).to eq(0)
  end

  # --- db_op nodes are plain COST-1 terminals; NO sink_open (L3, v0.6) ----------

  it "still mints db_op nodes (kind survives) for read/specific-write/open-write AR calls" do
    %w[Billing::Invoice.where Billing::Invoice.update_all Billing::Invoice.update].each do |sym|
      db_id, = id_map_entry_for_symbol(sym)
      db_node = graph["nodes"].find { |n| n["id"] == db_id }
      expect(db_node).not_to be_nil, "expected a #{sym} db_op node"
      expect(db_node["kind"]).to eq("db_op")
    end
  end

  it "does NOT emit sink_open on db_op nodes (L3: a db_op is a plain COST-1 terminal)" do
    %w[Billing::Invoice.where Billing::Invoice.update_all Billing::Invoice.update].each do |sym|
      db_id, = id_map_entry_for_symbol(sym)
      db_node = graph["nodes"].find { |n| n["id"] == db_id }
      expect(db_node).not_to be_nil, "expected a #{sym} db_op node"
      expect(db_node).not_to have_key("sink_open")
    end
  end

  it "emits sink_open on NO node of ANY kind (the field is fully retired client-side)" do
    graph["nodes"].each do |n|
      expect(n).not_to have_key("sink_open"),
        "node #{n['id']} (#{n['kind']}) carried sink_open"
    end
  end
end

RSpec.describe Archbuddy::Collect::Adapters::Ruby::BranchCounter do
  # b(n) = Π over decision points of arm-count (TRUE total execution paths);
  # d(n) = raw decision-point count. Worked snippets pin both. (P3+P9)
  def counts_for(method_src)
    body = Prism.parse(method_src).value.statements.body.first.body
    c = described_class.count(body)
    [c.branches, c.decisions]
  end

  {
    "straight-line body => (1, 0)" => [
      "def m\n  a = 1\n  b = a + 2\n  puts b\nend", [1, 0]
    ],
    "guard-if => (2, 1)" => [
      "def m(a)\n  return 1 if a\nend", [2, 1]
    ],
    "5-way case, no else => (5, 1)" => [
      "def m(a)\n  case a\n  when 1 then 1\n  when 2 then 2\n" \
      "  when 3 then 3\n  when 4 then 4\n  when 5 then 5\n  end\nend", [5, 1]
    ],
    "5-way case + else => (6, 1)" => [
      "def m(a)\n  case a\n  when 1 then 1\n  when 2 then 2\n" \
      "  when 3 then 3\n  when 4 then 4\n  when 5 then 5\n  else 0\n  end\nend", [6, 1]
    ],
    # V7/P5 de-idiomatized: only the business `if a` (×2) and the nested
    # modifier-`if b` (×2) multiply b => 4. The `||=` and `&.` idioms still
    # COUNT in decisions (4 total) but no longer inflate branches.
    "||= + if + nested modifier-if + safe-nav => (4, 4)" => [
      "def m(a, b)\n  x ||= 5\n  if a\n    y = 1 if b\n  end\n  a&.foo\nend", [4, 4]
    ],
    # V7/P5: begin/rescue is a defensive idiom — counted in decisions (1) but
    # no longer multiplies branches (was 4 = happy+2 rescue+else arms).
    "begin + 2 rescue + else => (1, 1)" => [
      "def m\n  begin\n    x\n  rescue A\n    y\n  rescue B\n    z\n  else\n    w\n  end\nend", [1, 1]
    ],
    "empty def => (1, 0)" => [
      "def m\nend", [1, 0]
    ],
    "nested def: outer excludes inner => (2, 1)" => [
      "def outer(a, b)\n  z if a\n  def inner\n    return if b\n  end\nend", [2, 1]
    ]
  }.each do |label, (src, expected)|
    it "counts #{label}" do
      expect(counts_for(src)).to eq(expected)
    end
  end

  it "multiplies arm-counts across independent decision points (two binary ifs => 4)" do
    expect(counts_for("def m(a, b)\n  x if a\n  y if b\nend")).to eq([4, 2])
  end
end

# v0.10 W1-A1: the entrypoint_kind thread — categorized detection (THE
# PRECEDENCE, Reconciliation 2), RawNode stamping, id-map carry, and the
# graph.yml emission GATE (a 1.2 engine schema REJECTS unknown node keys —
# additionalProperties:false — so the category is held client-side until the
# engine declares the OPTIONAL field in graph 1.3).
RSpec.describe "entrypoint_kind thread (v0.10 W1-A1)" do
  let(:config) { Archbuddy::Collect::Config.new(language: "ruby") }

  def anonymize(root, cfg = config)
    adapter = Archbuddy::Collect::Registry.for("ruby").new(root, cfg)
    Archbuddy::Collect::Anonymizer.new(
      adapter.collect, tool: "archbuddy test", adapter: "ruby"
    ).call
  end

  def in_repo(files)
    Dir.mktmpdir do |dir|
      files.each do |rel_path, content|
        abs = File.join(dir, rel_path)
        FileUtils.mkdir_p(File.dirname(abs))
        File.write(abs, content)
      end
      yield dir
    end
  end

  def desc_for(result, sym)
    _id, desc = result.id_map["ids"].find { |_i, d| d["symbol"] == sym }
    desc
  end

  def graph_node_for(result, sym)
    opaque_id, = result.id_map["ids"].find { |_i, d| d["symbol"] == sym }
    result.graph["nodes"].find { |n| n["id"] == opaque_id }
  end

  CONTROLLER_SRC = <<~RUBY
    class OrdersController < ApplicationController
      def index
        1
      end
    end
  RUBY

  # --- id-map carry + category correctness ------------------------------------

  it "stamps a controller action as entrypoint_kind 'controllers' in the id-map descriptor" do
    in_repo("app/controllers/orders_controller.rb" => CONTROLLER_SRC) do |dir|
      result = anonymize(dir)
      expect(desc_for(result, "OrdersController#index")["entrypoint_kind"]).to eq("controllers")
    end
  end

  it "stamps a top-level def as 'top_level' and a non-entrypoint method as nil" do
    in_repo(
      "app/controllers/orders_controller.rb" => CONTROLLER_SRC,
      "lib/tasks_helper.rb" => "def helper_entry\n  1\nend\n",
      "app/models/invoice.rb" => "class Invoice\n  def total\n    1\n  end\nend\n"
    ) do |dir|
      result = anonymize(dir)
      expect(desc_for(result, "helper_entry")["entrypoint_kind"]).to eq("top_level")
      expect(desc_for(result, "Invoice#total")["entrypoint_kind"]).to be_nil
    end
  end

  # --- THE PRECEDENCE (first match wins, ONE category per fq) -----------------

  it "grape beats controllers/top_level: a minted Grape endpoint is 'grape'" do
    in_repo(
      "app/api/users.rb" => <<~RUBY
        class Users < Grape::API
          get "/a" do
            1
          end
        end
      RUBY
    ) do |dir|
      result = anonymize(dir)
      grape_desc = result.id_map["ids"].values.find { |d| d["symbol"].include?("GET") }
      expect(grape_desc).not_to be_nil
      expect(grape_desc["entrypoint_kind"]).to eq("grape")
    end
  end

  it "routed beats controllers: a routes.draw-declared action is 'routed', not 'controllers'" do
    in_repo(
      "config/routes.rb" => <<~RUBY,
        Rails.application.routes.draw do
          get "/orders", to: "orders#index"
        end
      RUBY
      "app/controllers/orders_controller.rb" => CONTROLLER_SRC
    ) do |dir|
      result = anonymize(dir)
      expect(desc_for(result, "OrdersController#index")["entrypoint_kind"]).to eq("routed")
    end
  end

  it "jobs (seeded) beats pattern: a Sidekiq #perform matched by a pattern stays 'jobs'" do
    cfg = Archbuddy::Collect::Config.new(
      language: "ruby", entrypoint_patterns: [/perform/]
    )
    in_repo(
      "app/workers/foo_worker.rb" => <<~RUBY
        class FooWorker
          include Sidekiq::Job
          def perform
            1
          end
        end
      RUBY
    ) do |dir|
      result = anonymize(dir, cfg)
      expect(desc_for(result, "FooWorker#perform")["entrypoint_kind"]).to eq("jobs")
    end
  end

  it "controllers beats pattern: a pattern-matched controller action stays 'controllers'" do
    cfg = Archbuddy::Collect::Config.new(
      language: "ruby", entrypoint_patterns: [/index/]
    )
    in_repo("app/controllers/orders_controller.rb" => CONTROLLER_SRC) do |dir|
      result = anonymize(dir, cfg)
      expect(desc_for(result, "OrdersController#index")["entrypoint_kind"]).to eq("controllers")
    end
  end

  it "pattern is the last resort: a plain instance method admitted only by pattern is 'pattern'" do
    cfg = Archbuddy::Collect::Config.new(
      language: "ruby", entrypoint_patterns: [/Invoice#total/]
    )
    in_repo("app/models/invoice.rb" => "class Invoice\n  def total\n    1\n  end\nend\n") do |dir|
      result = anonymize(dir, cfg)
      expect(desc_for(result, "Invoice#total")["entrypoint_kind"]).to eq("pattern")
    end
  end

  # --- detect delegation + nil-tolerance ---------------------------------------

  it "#detect returns exactly detect_categorized.keys (selection unchanged)" do
    in_repo(
      "app/controllers/orders_controller.rb" => CONTROLLER_SRC,
      "lib/tasks_helper.rb" => "def helper_entry\n  1\nend\n"
    ) do |dir|
      table = Archbuddy::Collect::Adapters::Ruby::SymbolTable.new
      Dir.glob(File.join(dir, "**/*.rb")).sort.each do |abs|
        rel = abs.sub("#{dir}/", "")
        Prism.parse(File.read(abs)).value.accept(
          Archbuddy::Collect::Adapters::Ruby::DefinitionPass.new(table, rel)
        )
      end
      detector = Archbuddy::Collect::Adapters::Ruby::EntrypointDetector.new(config)
      expect(detector.detect(table)).to eq(detector.detect_categorized(table).keys)
      expect(detector.detect(table)).to match_array(
        ["OrdersController#index", "helper_entry"]
      )
    end
  end

  it "categorizes nil-tolerantly on a table WITHOUT the seeded-category API (pre-B tables)" do
    entry = Struct.new(:fq_symbol, :endpoint, :singleton, :owner_fq, keyword_init: true)
    bare_table = Class.new do
      def initialize(entries) = @entries = entries
      def methods = @entries
      def routed_action?(_fq) = false
      def controller_class?(_fq) = false
    end.new(
      "helper_entry" => entry.new(
        fq_symbol: "helper_entry", endpoint: false, singleton: false, owner_fq: nil
      )
    )

    detector = Archbuddy::Collect::Adapters::Ruby::EntrypointDetector.new(config)
    expect(detector.detect_categorized(bare_table)).to eq("helper_entry" => "top_level")
  end

  # --- graph.yml emission gate (no 1.2 contract break) --------------------------

  it "emits a graph that STILL validates against the installed engine schema" do
    in_repo("app/controllers/orders_controller.rb" => CONTROLLER_SRC) do |dir|
      result = anonymize(dir)
      expect {
        ArchitectureAuditor::Contract::Validator.validate!(:graph, result.graph)
      }.not_to raise_error
    end
  end

  it "holds entrypoint_kind OFF the graph node while the engine schema rejects the key" do
    in_repo("app/controllers/orders_controller.rb" => CONTROLLER_SRC) do |dir|
      result = anonymize(dir)
      node = graph_node_for(result, "OrdersController#index")
      if Archbuddy::Collect::Anonymizer.graph_schema_accepts_entrypoint_kind?
        # W6 posture (engine graph 1.3 installed): the stamp rides through.
        expect(node["entrypoint_kind"]).to eq("controllers")
      else
        # Phase-alpha posture (1.2 engine): held client-side, graph unpolluted.
        expect(node).not_to have_key("entrypoint_kind")
      end
    end
  end

  it "gate probe agrees with the schema: probe result == whether a stamped graph validates" do
    probe = Archbuddy::Collect::Anonymizer::ENTRYPOINT_KIND_PROBE_GRAPH
    expect(Archbuddy::Collect::Anonymizer.graph_schema_accepts_entrypoint_kind?).to eq(
      ArchitectureAuditor::Contract::Validator.valid?(:graph, probe)
    )
  end
end
