# frozen_string_literal: true

require "archbuddy/cache"
require "tmpdir"
require "json"

# v0.10 W3 (A1 aggregate-write — Reconciliation 1): the committed root
# aggregate (serializer v2) carries THREE additive counter blocks —
# `entrypoints` (ingress counts by category), `egress` (exit counts by
# category, folded from diagnostics[:egress_counts] — the single read path),
# and `dynamic_dispatch` (the D coverage tuple; `coverage_ratio` NULL on a
# zero denominator, never a fabricated 0/1 — I2). All three are present on
# BOTH the collect path (diagnostics fresh) and the analyze path (diagnostics
# nil → prior blocks carried forward VERBATIM). A v1 aggregate still parses
# with nil Result fields (back-compat).
RSpec.describe "committed counter blocks (v0.10 W3 / serializer v2)" do
  let(:fixture_root) { File.expand_path("../fixtures/sample", __dir__) }
  let(:config)       { Archbuddy::Collect::Config.new(language: "ruby") }

  ENTRYPOINT_KEYS = %w[
    controllers grape routed top_level jobs rake middleware script pattern
  ].freeze
  EGRESS_KEYS = %w[http gem queue generic].freeze

  # Full opaque interchange + the collect-time diagnostics carrier — the exact
  # producer→writer handshake `cli/collect.rb` threads through the Emitter.
  def collect
    adapter = Archbuddy::Collect::Registry.for("ruby").new(fixture_root, config)
    result  = adapter.collect
    anon    = Archbuddy::Collect::Anonymizer.new(
      result, tool: "archbuddy test", adapter: "ruby"
    ).call
    [anon, result.diagnostics]
  end

  def read_aggregate(dir)
    JSON.parse(File.read(File.join(dir, "archbuddy-findings.json")))
  end

  def write_collect(dir, anon, diagnostics)
    Archbuddy::Cache::Writer.new(project_root: dir)
                            .write(graph: anon.graph, id_map: anon.id_map, diagnostics: diagnostics)
  end

  describe "collect path (diagnostics fresh)" do
    it "writes all three blocks under serializer_version 2" do
      Dir.mktmpdir do |dir|
        anon, diagnostics = collect
        write_collect(dir, anon, diagnostics)

        agg = read_aggregate(dir)
        expect(agg["serializer_version"]).to eq(2)
        expect(agg).to have_key("entrypoints")
        expect(agg).to have_key("egress")
        expect(agg).to have_key("dynamic_dispatch")
      end
    end

    it "entrypoints: FULL closed category key set seeded to 0; by_category sums == total == count" do
      Dir.mktmpdir do |dir|
        anon, diagnostics = collect
        write_collect(dir, anon, diagnostics)

        ep = read_aggregate(dir)["entrypoints"]
        # every closed-vocab category visible even at zero (L2)
        expect(ep["by_category"].keys).to include(*ENTRYPOINT_KEYS)
        expect(ep["by_category"]["controllers"]).to eq(1) # OrdersController#index
        expect(ep["by_category"].values.sum).to eq(ep["total"])
        expect(ep["total"]).to eq(ep["count"])
        # COUNTS only — cost is engine-published (A2); honest null until then
        expect(ep["mean"]).to be_nil
        expect(ep["median"]).to be_nil
      end
    end

    it "egress: folded from diagnostics[:egress_counts] (single read path); sums == total" do
      Dir.mktmpdir do |dir|
        anon, diagnostics = collect
        # the fixture's ExternalTaxApi.compute is an out-of-tree constant → :gem (W2-C)
        expect(diagnostics[:egress_counts]).to eq(gem: 1)
        write_collect(dir, anon, diagnostics)

        eg = read_aggregate(dir)["egress"]
        expect(eg["by_category"]).to eq("http" => 0, "gem" => 1, "queue" => 0, "generic" => 0)
        expect(eg["by_category"].values.sum).to eq(eg["total"])
        expect(eg["total"]).to eq(eg["count"])
      end
    end

    it "dynamic_dispatch: coverage tuple from diagnostics; full visibility → coverage_ratio 1.0" do
      Dir.mktmpdir do |dir|
        anon, diagnostics = collect
        write_collect(dir, anon, diagnostics)

        dd = read_aggregate(dir)["dynamic_dispatch"]
        expect(dd["dynamic_sites"]).to eq(0)   # fixture has no meta-dispatch
        expect(dd["resolved_sites"]).to eq(0)
        expect(dd["total_call_sites"]).to be_positive
        expect(dd["coverage_ratio"]).to eq(1.0)
      end
    end

    it "coverage_ratio is NULL on a zero denominator (honest-undefined, never 0/1 — I2)" do
      Dir.mktmpdir do |dir|
        anon, = collect
        empty = { meta_sites_skipped: 0, meta_resolved: 0, total_call_sites: 0, egress_counts: {} }
        write_collect(dir, anon, empty)

        dd = read_aggregate(dir)["dynamic_dispatch"]
        expect(dd["total_call_sites"]).to eq(0)
        expect(dd["coverage_ratio"]).to be_nil
        # zero egress sites → honest zeros, block still PRESENT (never omitted)
        eg = read_aggregate(dir)["egress"]
        expect(eg["by_category"]).to eq("http" => 0, "gem" => 0, "queue" => 0, "generic" => 0)
        expect(eg["total"]).to eq(0)
      end
    end

    it "buckets a category-less entrypoint under the declared 'unknown' key (never guessed)" do
      Dir.mktmpdir do |dir|
        graph = {
          "nodes"       => [{ "id" => "n_000000000001", "kind" => "function",
                              "branches" => 1, "decisions" => 0 }],
          "edges"       => [],
          "entrypoints" => ["n_000000000001"]
        }
        id_map = {
          "ids" => {
            "n_000000000001" => {
              "file" => "lib/foo.rb", "line" => 1, "symbol" => "foo",
              "kind" => "function", "class_id" => nil,
              "entrypoint_kind" => nil, "terminal_kind" => nil
            }
          }
        }
        Archbuddy::Cache::Writer.new(project_root: dir)
                                .write(graph: graph, id_map: id_map, diagnostics: {})

        ep = read_aggregate(dir)["entrypoints"]
        expect(ep["by_category"]["unknown"]).to eq(1)
        expect(ep["by_category"].values.sum).to eq(ep["total"])
      end
    end

    it "is byte-identical across two collect-path writes (determinism)" do
      Dir.mktmpdir do |dir|
        anon, diagnostics = collect
        write_collect(dir, anon, diagnostics)
        first = File.read(File.join(dir, "archbuddy-findings.json"))
        write_collect(dir, anon, diagnostics)
        expect(File.read(File.join(dir, "archbuddy-findings.json"))).to eq(first)
      end
    end
  end

  describe "analyze path (findings present, diagnostics nil)" do
    let(:findings) do
      {
        "scores" => {
          "forward_discoverability" => { "grade" => "B", "score" => 82.0 },
          "reverse_traceability"    => { "grade" => "C", "score" => 61.0 }
        }
      }
    end

    it "carries the collect-written egress/dynamic_dispatch blocks forward VERBATIM" do
      Dir.mktmpdir do |dir|
        anon, diagnostics = collect
        write_collect(dir, anon, diagnostics)
        collect_time = read_aggregate(dir)

        # the analyze re-transcode: findings folded, NO fresh diagnostics
        Archbuddy::Cache::Writer.new(project_root: dir)
                                .write(graph: anon.graph, id_map: anon.id_map, findings: findings)

        agg = read_aggregate(dir)
        expect(agg["serializer_version"]).to eq(2)
        expect(agg["scores"]).to have_key("forward_discoverability")
        expect(agg["egress"]).to eq(collect_time["egress"])                       # not zero-clobbered
        expect(agg["dynamic_dispatch"]).to eq(collect_time["dynamic_dispatch"])   # carried forward
        expect(agg["entrypoints"]).to eq(collect_time["entrypoints"])             # pure graph fold
      end
    end

    it "still writes all three blocks with NO prior aggregate (honest fallback, never omitted)" do
      Dir.mktmpdir do |dir|
        anon, = collect
        Archbuddy::Cache::Writer.new(project_root: dir)
                                .write(graph: anon.graph, id_map: anon.id_map, findings: findings)

        agg = read_aggregate(dir)
        expect(agg["entrypoints"]["by_category"]["controllers"]).to eq(1)
        # pre-diagnostics fallback: external edges all bucket to `generic`
        expect(agg["egress"]["by_category"].keys).to contain_exactly(*EGRESS_KEYS)
        expect(agg["egress"]["by_category"]["generic"]).to eq(agg["egress"]["total"])
        # no diagnostics + no prior → zero tuple with NULL ratio (undefined)
        expect(agg["dynamic_dispatch"]["total_call_sites"]).to eq(0)
        expect(agg["dynamic_dispatch"]["coverage_ratio"]).to be_nil
      end
    end
  end

  describe "v1-aggregate back-compat (read side)" do
    it "a pre-bump (v1) aggregate still parses — Result counter fields are nil, no raise" do
      Dir.mktmpdir do |dir|
        agg_path = File.join(dir, "archbuddy-findings.json")
        File.write(agg_path, JSON.generate("serializer_version" => 1, "sources" => {}))

        require "archbuddy/report/reconnect"
        result = Archbuddy::Report::Reconnect.from_cache(aggregate_path: agg_path)
        expect(result.entrypoints).to be_nil
        expect(result.egress).to be_nil
        expect(result.dynamic_dispatch).to be_nil
      end
    end
  end
end
