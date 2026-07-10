# frozen_string_literal: true

require "tmpdir"
require "fileutils"
require "stringio"
require "json"
require "set"
require "archbuddy/cache"
require "archbuddy/cli/report"
require "archbuddy/report/reconnect"

# R2-1: `report` reads the COMMITTED, REAL-NAME root aggregate DIRECTLY, with NO
# id-map (the committed layer is de-anonymized at WRITE time, CR-1). This is the
# HARD INVARIANT: a fresh clone renders the multiplexer_proxy smell from the
# committed cache WITHOUT the SECRET id-map.
RSpec.describe "report reads the committed real-name cache (R2-1)" do
  let(:fixture_root) { File.expand_path("../fixtures/sample", __dir__) }
  let(:config)       { Archbuddy::Collect::Config.new(language: "ruby") }

  # Produce a REAL committed aggregate (via the write-time transcode) carrying a
  # multiplexer_proxy smell, exactly as `analyze` would.
  def write_committed_cache(dir)
    adapter = Archbuddy::Collect::Registry.for("ruby").new(fixture_root, config)
    a = Archbuddy::Collect::Anonymizer.new(adapter.collect, tool: "t", adapter: "ruby").call
    proxy_id, = a.id_map["ids"].find { |_id, d| d["symbol"] == "Billing::Invoice#total" }
    findings = {
      "scores" => {
        "forward_discoverability" => { "grade" => "C", "score" => 61.0 },
        "reverse_traceability"    => { "grade" => "B", "score" => 40.0 },
        "multiplexer_proxies"     => [{ "node" => proxy_id, "added_coupling" => 9.0 }]
      }
    }
    Archbuddy::Cache::Writer.new(project_root: dir).write(graph: a.graph, id_map: a.id_map, findings: findings)
  end

  describe "Reconnect.from_cache" do
    it "reads scores + the real-name smell from the aggregate with NO id-map" do
      Dir.mktmpdir do |dir|
        write_committed_cache(dir)
        agg = File.join(dir, "archbuddy-findings.json")

        result = Archbuddy::Report::Reconnect.from_cache(aggregate_path: agg, id_map_path: nil)

        expect(result.scores.map(&:key)).to eq(%w[reverse_traceability forward_discoverability])
        expect(result.multiplexer_proxies.map(&:symbol)).to eq(["Billing::Invoice#total"])
        expect(result.multiplexer_proxies.first.added_coupling).to eq(9.0)
      end
    end
  end

  describe "`archbuddy report` with no args in a fresh checkout (no id-map present)" do
    def capture_report(dir)
      out = StringIO.new
      orig = $stdout
      $stdout = out
      Dir.chdir(dir) { Archbuddy::CLI::Report.new.call(format: "terminal") }
      out.string
    ensure
      $stdout = orig
    end

    it "renders the multiplexer_proxy smell from the committed cache — no id-map on disk" do
      Dir.mktmpdir do |dir|
        write_committed_cache(dir)
        # SIMULATE A FRESH CLONE: the SECRET id-map is gitignored, so it is NOT
        # present. Only the committed real-name cache exists.
        expect(File).not_to exist(File.join(dir, ".archbuddy/id-map.yml"))

        output = capture_report(dir)
        expect(output).to include("Multiplexer Proxy Smell")
        expect(output).to include("Billing::Invoice#total")
        expect(output).to include("added_coupling=9")
        # scores headline is present too
        expect(output).to include("Architecture Scores")
      end
    end
  end

  # v0.9 W2: the DEFAULT from_cache report builds its interactive graph from the
  # committed REAL-NAME detail tree — real method names, external sinks excluded,
  # clutter-ranked by the committed per-symbol proxies — WITHOUT the id-map.
  describe "v0.9 W2: default from_cache report renders a REAL-NAME graph (no id-map)" do
    # Parse the <script id="archbuddy-data"> island back into a Ruby hash.
    def graph_data_from_html(html)
      island = html[%r{<script id="archbuddy-data" type="application/json">(.*?)</script>}m, 1]
      JSON.parse(island.gsub('<\/', "</"))
    end

    def render_html(dir, max_nodes: 100)
      out = StringIO.new
      orig = $stdout
      $stdout = out
      Dir.chdir(dir) { Archbuddy::CLI::Report.new.call(format: "html", max_nodes: max_nodes) }
      out.string
    ensure
      $stdout = orig
    end

    it "renders REAL method names as graph nodes (no opaque n_/ext_ ids)" do
      Dir.mktmpdir do |dir|
        write_committed_cache(dir)
        expect(File).not_to exist(File.join(dir, ".archbuddy/id-map.yml"))

        data = graph_data_from_html(render_html(dir))
        symbols = data["nodes"].map { |n| n["symbol"] }

        # Real symbols from the fixture (Billing::Invoice#…) are present.
        expect(symbols).to include("Billing::Invoice#total", "Billing::Invoice#subtotal", "Billing::Invoice#tax")
        # NOTHING opaque: no n_/ext_ ids leaked into the graph node labels.
        expect(symbols).to all(satisfy { |s| s !~ /\A(n_|ext_|cls_)/ })
        # Every node resolved (identity de-anon — no <external …> placeholder).
        expect(data["nodes"]).to all(include("resolved" => true))
      end
    end

    it "excludes the <external> sink from the graph nodes + drops its dangling edges" do
      Dir.mktmpdir do |dir|
        write_committed_cache(dir)
        data = graph_data_from_html(render_html(dir))
        symbols = data["nodes"].map { |n| n["symbol"] }

        # The unresolved external boundary (ExternalTaxApi.compute -> <external>)
        # is NOT a rendered node...
        expect(symbols).not_to include("<external>")
        expect(data["nodes"].map { |n| n["kind"] }).not_to include("external")
        # ...and no rendered edge references it (both-endpoints-in-set guard).
        rendered = symbols.to_set
        expect(data["edges"]).to all(satisfy { |e| rendered.include?(e["from"]) && rendered.include?(e["to"]) })
      end
    end

    it "ranks the graph node cap by REAL committed clutter (top proxy first)" do
      Dir.mktmpdir do |dir|
        write_committed_cache(dir)
        # Cap to a single node: the kept node must be the top committed-clutter
        # hotspot (Billing::Invoice#total, the only proxy — added_coupling 9.0).
        data = graph_data_from_html(render_html(dir, max_nodes: 1))
        expect(data["nodes"].map { |n| n["symbol"] }).to eq(["Billing::Invoice#total"])
        expect(data["node_cap"]).to include("shown" => 1)
        # The ranked bottleneck table also leads with the real hotspot.
        expect(data["bottlenecks"].first["symbol"]).to eq("Billing::Invoice#total")
      end
    end

    it "Reconnect.from_cache carries a real-name graph + clutter-ranked bottlenecks" do
      Dir.mktmpdir do |dir|
        write_committed_cache(dir)
        agg = File.join(dir, "archbuddy-findings.json")

        result = Archbuddy::Report::Reconnect.from_cache(aggregate_path: agg, id_map_path: nil)

        expect(result).to be_real_name
        expect(result.graph["nodes"].map { |n| n["id"] }).to include("Billing::Invoice#total")
        # bottlenecks are the committed proxies, real-name, clutter = added_coupling.
        expect(result.bottlenecks.map(&:id)).to eq(["Billing::Invoice#total"])
        expect(result.bottlenecks.first.clutter_score).to eq(9.0)
        # resolve() is identity on this path — symbol == id, resolved.
        loc = result.resolve("Billing::Invoice#total")
        expect(loc.symbol).to eq("Billing::Invoice#total")
        expect(loc).to be_resolved
      end
    end
  end

  # v0.10 W3 (A1): from_cache parses the three committed counter blocks off the
  # serializer-v2 aggregate into nil-tolerant presentation structs; a v1
  # (pre-bump) aggregate yields nil fields — back-compat, no raise.
  describe "v0.10 W3: committed counter blocks on the Result" do
    it "populates entrypoints/egress/dynamic_dispatch structs from a v2 aggregate" do
      Dir.mktmpdir do |dir|
        write_committed_cache(dir)
        agg = File.join(dir, "archbuddy-findings.json")

        result = Archbuddy::Report::Reconnect.from_cache(aggregate_path: agg, id_map_path: nil)

        expect(result.entrypoints).to be_a(Archbuddy::Report::Scores::EntrypointCount)
        expect(result.entrypoints.by_category["controllers"]).to eq(1)
        expect(result.egress).to be_a(Archbuddy::Report::Scores::Egress)
        expect(result.egress.by_category.keys).to include("http", "gem", "queue", "generic")
        expect(result.dynamic_dispatch).to be_a(Archbuddy::Report::Scores::DynamicDispatch)
      end
    end

    it "returns nil fields (no raise) on a v1 pre-bump aggregate" do
      Dir.mktmpdir do |dir|
        agg = File.join(dir, "archbuddy-findings.json")
        File.write(agg, JSON.generate("serializer_version" => 1, "sources" => {}))

        result = Archbuddy::Report::Reconnect.from_cache(aggregate_path: agg, id_map_path: nil)

        expect(result.entrypoints).to be_nil
        expect(result.egress).to be_nil
        expect(result.dynamic_dispatch).to be_nil
      end
    end
  end

  # Back-compat: the LEGACY opaque path (explicit findings.yml + SECRET id-map)
  # still de-anonymizes at read time and renders real names via the id-map.
  describe "back-compat: legacy findings.yml + id-map path still works" do
    it "de-anonymizes the graph via the id-map (Reconnect.from_files)" do
      Dir.mktmpdir do |dir|
        adapter = Archbuddy::Collect::Registry.for("ruby").new(fixture_root, config)
        a = Archbuddy::Collect::Anonymizer.new(adapter.collect, tool: "t", adapter: "ruby").call
        # Write the opaque interchange to disk (gitignored in real use).
        FileUtils.mkdir_p(File.join(dir, ".archbuddy"))
        ser = Archbuddy::Report::Reconnect::Serializer
        File.write(File.join(dir, ".archbuddy/graph.yml"), ser.dump(a.graph))
        File.write(File.join(dir, ".archbuddy/id-map.yml"), ser.dump(a.id_map))
        # A minimal opaque findings doc (one scored node) for the legacy join.
        node_id, = a.id_map["ids"].find { |_id, d| d["symbol"] == "Billing::Invoice#total" }
        findings = { "nodes" => { node_id => { "metrics" => {}, "clutter_score" => 5.0 } }, "findings" => [] }
        File.write(File.join(dir, ".archbuddy/findings.yml"), ser.dump(findings))

        result = Archbuddy::Report::Reconnect.from_files(
          findings_path: File.join(dir, ".archbuddy/findings.yml"),
          id_map_path:   File.join(dir, ".archbuddy/id-map.yml")
        ).call

        expect(result.real_name).to be_falsey
        # The opaque node id de-anonymizes to the real symbol via the id-map.
        expect(result.bottlenecks.map { |b| b.location.symbol }).to include("Billing::Invoice#total")
      end
    end
  end
end
