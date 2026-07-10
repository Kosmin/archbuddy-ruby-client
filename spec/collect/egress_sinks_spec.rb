# frozen_string_literal: true

require "tmpdir"

# Category-bearing external sinks (v0.10 W2-C, L18/CR-5). The ONE historical
# `<external>` sink is sub-classified into per-category sinks
# (`<external:http>` / `<external:gem>` / `<external:queue>`) plus the
# always-minted generic `<external>` — ALL still kind:"external" (closed
# 4-kind vocab untouched, I6). Each category sink carries the OPTIONAL
# RawNode#terminal_kind stamp (the sink-side twin of entrypoint_kind); the
# generic sink carries NONE. Graph emission of terminal_kind is GATED on the
# installed engine schema (a 1.2 engine REJECTS unknown node keys — the same
# verified posture as entrypoint_kind / M4).
RSpec.describe "Egress category sinks (W2-C)" do
  let(:config) { Archbuddy::Collect::Config.new(language: "ruby") }

  MULTI_CATEGORY_SRC = <<~RUBY
    class Caller
      def go
        Faraday.get("/x")
        SomeGem::Client.foo
        mystery.call_it
      end
    end
  RUBY

  NO_EGRESS_SRC = <<~RUBY
    class Quiet
      def calc
        double(2)
      end

      def double(x)
        x * 2
      end
    end
  RUBY

  def in_repo(source, filename: "app.rb")
    Dir.mktmpdir do |dir|
      File.write(File.join(dir, filename), source)
      yield dir
    end
  end

  def collect(dir)
    Archbuddy::Collect::Registry.for("ruby").new(dir, config).collect
  end

  def anonymize(dir)
    Archbuddy::Collect::Anonymizer.new(
      collect(dir), tool: "archbuddy test", adapter: "ruby"
    ).call
  end

  def id_for(result, sym)
    result.id_map["ids"].find { |_i, d| d["symbol"] == sym }&.first
  end

  it "mints one sink per category that appears, plus the generic sink — all kind external" do
    in_repo(MULTI_CATEGORY_SRC) do |dir|
      raw = collect(dir)
      externals = raw.nodes.select { |n| n.kind == "external" }
      expect(externals.map(&:symbol))
        .to contain_exactly("<external>", "<external:http>", "<external:gem>")
      # No empty-category sink: nothing enqueued, so no <external:queue>.
      expect(raw.nodes.map(&:symbol)).not_to include("<external:queue>")
    end
  end

  it "stamps terminal_kind on category sinks and NOT on the generic sink (CR-5)" do
    in_repo(MULTI_CATEGORY_SRC) do |dir|
      raw   = collect(dir)
      by_sym = raw.nodes.to_h { |n| [n.symbol, n] }
      expect(by_sym.fetch("<external:http>").terminal_kind).to eq("http")
      expect(by_sym.fetch("<external:gem>").terminal_kind).to eq("gem")
      expect(by_sym.fetch("<external>").terminal_kind).to be_nil
      # Non-sink nodes never carry a terminal_kind.
      expect(by_sym.fetch("Caller#go").terminal_kind).to be_nil
    end
  end

  it "mints DISTINCT ext_ opaque ids per category sink" do
    in_repo(MULTI_CATEGORY_SRC) do |dir|
      result = anonymize(dir)
      ids = ["<external>", "<external:http>", "<external:gem>"].map { |s| id_for(result, s) }
      expect(ids).to all(start_with("ext_"))
      expect(ids.uniq.length).to eq(3)
    end
  end

  it "routes each external edge to its category's sink" do
    in_repo(MULTI_CATEGORY_SRC) do |dir|
      result = anonymize(dir)
      go_id = id_for(result, "Caller#go")
      %w[<external:http> <external:gem> <external>].each do |sink_sym|
        sink_id = id_for(result, sink_sym)
        edge = result.graph["edges"].find { |e| e["from"] == go_id && e["to"] == sink_id }
        expect(edge).not_to be_nil, "expected an edge Caller#go -> #{sink_sym}"
      end
    end
  end

  it "produces a dangling-free graph (every edge endpoint is a node)" do
    in_repo(MULTI_CATEGORY_SRC) do |dir|
      graph    = anonymize(dir).graph
      node_ids = graph["nodes"].map { |n| n["id"] }.to_set
      graph["edges"].each do |e|
        expect(node_ids).to include(e["from"])
        expect(node_ids).to include(e["to"])
      end
    end
  end

  it "keeps the no-egress repo byte-compatible: exactly ONE generic <external> sink" do
    in_repo(NO_EGRESS_SRC) do |dir|
      raw = collect(dir)
      externals = raw.nodes.select { |n| n.kind == "external" }
      expect(externals.map(&:symbol)).to eq(["<external>"])
      expect(raw.diagnostics[:egress_counts]).to eq({})
    end
  end

  it "exposes egress_counts in diagnostics matching the sink split" do
    in_repo(MULTI_CATEGORY_SRC) do |dir|
      counts = collect(dir).diagnostics[:egress_counts]
      expect(counts[:http]).to eq(1)
      expect(counts[:gem]).to eq(1)
      expect(counts[:generic]).to be >= 1 # mystery + mystery.call_it
      expect(counts).not_to have_key(:queue)
      # CR-3 vocab lock: the nil bucket is :generic, NEVER :unknown.
      expect(counts).not_to have_key(:unknown)
    end
  end

  it "records terminal_kind in the id-map descriptor for category sinks only" do
    in_repo(MULTI_CATEGORY_SRC) do |dir|
      result = anonymize(dir)
      desc = ->(sym) { result.id_map["ids"].fetch(id_for(result, sym)) }
      expect(desc.call("<external:http>")["terminal_kind"]).to eq("http")
      expect(desc.call("<external:gem>")["terminal_kind"]).to eq("gem")
      expect(desc.call("<external>")["terminal_kind"]).to be_nil
      expect(desc.call("Caller#go")["terminal_kind"]).to be_nil
    end
  end

  it "holds terminal_kind OFF the graph node while the engine schema rejects the key" do
    in_repo(MULTI_CATEGORY_SRC) do |dir|
      result  = anonymize(dir)
      http_id = id_for(result, "<external:http>")
      node    = result.graph["nodes"].find { |n| n["id"] == http_id }
      if Archbuddy::Collect::Anonymizer.graph_schema_accepts_terminal_kind?
        # W6 posture (engine graph 1.3 installed): the stamp rides through.
        expect(node["terminal_kind"]).to eq("http")
      else
        # Phase-alpha posture (1.2 engine): held client-side, graph unpolluted.
        expect(node).not_to have_key("terminal_kind")
      end
    end
  end

  it "gate probe agrees with the schema: probe result == whether a stamped graph validates" do
    probe = Archbuddy::Collect::Anonymizer::TERMINAL_KIND_PROBE_GRAPH
    expect(Archbuddy::Collect::Anonymizer.graph_schema_accepts_terminal_kind?).to eq(
      ArchitectureAuditor::Contract::Validator.valid?(:graph, probe)
    )
  end

  it "produces a graph that validates against the engine's graph schema" do
    in_repo(MULTI_CATEGORY_SRC) do |dir|
      graph = anonymize(dir).graph
      expect {
        ArchitectureAuditor::Contract::Validator.validate!(:graph, graph)
      }.not_to raise_error
    end
  end

  it "keeps the category label OUT of the serialized graph while gated (I8)" do
    in_repo(MULTI_CATEGORY_SRC) do |dir|
      graph = anonymize(dir).graph
      serialized = ArchitectureAuditor::Contract::Serializer.dump(graph)
      unless Archbuddy::Collect::Anonymizer.graph_schema_accepts_terminal_kind?
        expect(serialized).not_to include("terminal_kind")
      end
      # The real out-of-tree constant names NEVER reach the graph either way.
      expect(serialized).not_to include("Faraday")
      expect(serialized).not_to include("SomeGem")
    end
  end
end
