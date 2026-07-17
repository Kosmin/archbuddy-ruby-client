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
    it "writes all three blocks under serializer_version 3" do
      Dir.mktmpdir do |dir|
        anon, diagnostics = collect
        write_collect(dir, anon, diagnostics)

        agg = read_aggregate(dir)
        expect(agg["serializer_version"]).to eq(3)
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
        expect(agg["serializer_version"]).to eq(3)
        expect(agg["scores"]).to have_key("forward_discoverability")
        expect(agg["egress"]).to eq(collect_time["egress"])                       # not zero-clobbered
        expect(agg["dynamic_dispatch"]).to eq(collect_time["dynamic_dispatch"])   # carried forward
        # counts stay the pure graph fold (W6 re-baseline: engine cost now
        # rides in from findings on the analyze path — W6 examples below)
        expect(agg["entrypoints"]["by_category"]).to eq(collect_time["entrypoints"]["by_category"])
        expect(agg["entrypoints"]["total"]).to eq(collect_time["entrypoints"]["total"])
        # the fixture findings carry a forward score → mean copied VERBATIM;
        # no `median` key (pre-1.5 shape) → honest null (nil-tolerant)
        expect(agg["entrypoints"]["mean"]).to eq(82.0)
        expect(agg["entrypoints"]["median"]).to be_nil
      end
    end

    # v0.10 W6: engine findings 1.5 publishes the per-entrypoint cost
    # surfaces; the writer copies them VERBATIM into the committed
    # `entrypoints` block (D17 — never computed client-side).
    describe "W6 engine-cost verbatim read" do
      let(:findings_15) do
        {
          "scores" => {
            "forward_discoverability" => {
              "grade" => "B", "score" => 82.5, "median" => 41.0,
              "hotspots" => [], "raw_value" => 82.5, "overflow" => false
            },
            "forward_discoverability_by_category" => {
              "controllers"   => { "score" => 82.5, "grade" => "B", "median" => 41.0,
                                   "hotspots" => %w[n_aaaaaaaaaaaa] },
              "uncategorized" => { "score" => 3.0, "grade" => "A", "median" => 3.0,
                                   "hotspots" => [] }
            }
          }
        }
      end

      it "copies mean/median + by_category_cost VERBATIM from 1.5 findings (hotspots dropped)" do
        Dir.mktmpdir do |dir|
          anon, = collect
          Archbuddy::Cache::Writer.new(project_root: dir)
                                  .write(graph: anon.graph, id_map: anon.id_map, findings: findings_15)

          ep = read_aggregate(dir)["entrypoints"]
          expect(ep["mean"]).to eq(82.5)     # headline dimension `score` (the mean)
          expect(ep["median"]).to eq(41.0)   # its 1.5 `median` sibling (L7)
          # v0.11 (v3): the lens shape widens with median_grade/capped_fraction
          # — null on 1.5 findings (keys written, never fabricated values).
          expect(ep["by_category_cost"]).to eq(
            "controllers"   => { "mean" => 82.5, "median" => 41.0, "grade" => "B",
                                 "median_grade" => nil, "capped_fraction" => nil },
            "uncategorized" => { "mean" => 3.0, "median" => 3.0, "grade" => "A",
                                 "median_grade" => nil, "capped_fraction" => nil }
          )
        end
      end

      it "stays nil-tolerant on pre-1.5 findings (no cost surfaces → null/{}, never fabricated)" do
        Dir.mktmpdir do |dir|
          anon, = collect
          pre15 = { "scores" => { "reverse_traceability" => { "grade" => "C", "score" => 61.0 } } }
          Archbuddy::Cache::Writer.new(project_root: dir)
                                  .write(graph: anon.graph, id_map: anon.id_map, findings: pre15)

          ep = read_aggregate(dir)["entrypoints"]
          expect(ep["mean"]).to be_nil
          expect(ep["median"]).to be_nil
          expect(ep["by_category_cost"]).to eq({})
        end
      end

      it "collect path (no findings) keeps cost null/{} — counts only" do
        Dir.mktmpdir do |dir|
          anon, diagnostics = collect
          write_collect(dir, anon, diagnostics)

          ep = read_aggregate(dir)["entrypoints"]
          expect(ep["mean"]).to be_nil
          expect(ep["median"]).to be_nil
          expect(ep["by_category_cost"]).to eq({})
        end
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

  # v0.11 W-C (serializer v3): the aggregate carries the findings-1.6 blocks
  # VERBATIM — blast_radius (worst de-anonymized), flat forward_depth /
  # reverse_depth (guard R1 — no `depth` grouping), branching_factor — plus
  # median/median_grade/capped_fraction beside every cost stat and the 1.5
  # egress cost keys. Carry-forward extends to every v3 block; a v2 prior
  # never manufactures them.
  describe "serializer v3 (v0.11 W-C)" do
    def anon_with_proxy_id
      adapter = Archbuddy::Collect::Registry.for("ruby").new(fixture_root, config)
      anon = Archbuddy::Collect::Anonymizer.new(
        adapter.collect, tool: "archbuddy test", adapter: "ruby"
      ).call
      proxy_id, = anon.id_map["ids"].find { |_id, d| d["symbol"] == "Billing::Invoice#total" }
      [anon, proxy_id]
    end

    # A synthetic findings-1.6 doc with the MEASURED plan numbers (L14/L15/L16).
    def findings_16(proxy_id)
      {
        "scores" => {
          "forward_discoverability" => {
            "grade" => "F", "score" => 30_992.17, "median" => 2.0,
            "median_grade" => "A", "capped_fraction" => 0.0214, "hotspots" => []
          },
          "reverse_traceability" => {
            "grade" => "F", "score" => 32_402.84, "median" => 1_000_000.0,
            "median_grade" => "F", "capped_fraction" => 0.9764, "hotspots" => []
          },
          "egress" => {
            "grade" => "C", "score" => 130.5, "median" => 44.0,
            "median_grade" => "B", "capped_fraction" => 0.0, "hotspots" => []
          },
          "egress_by_category" => {
            "gem" => { "score" => 120.0, "median" => 40.0, "grade" => "C",
                       "median_grade" => "B", "capped_fraction" => 0.0, "hotspots" => [] }
          },
          "blast_radius" => {
            "max" => 1569, "p90" => 3.0, "median" => 1.0, "mean" => 121.38,
            "reached_nodes" => 5506, "total_nodes" => 16_173, "total_entrypoints" => 1611,
            "pct_use_cases_hit_by_worst" => 0.9739,
            "worst" => [{ "node" => proxy_id, "use_cases_affected" => 1569, "added_coupling" => 7.5 }]
          },
          "forward_depth" => {
            "mean" => 2.83, "median" => 2.0, "count" => 1611,
            "by_category" => { "controllers" => { "mean" => 2.9, "median" => 2.0, "count" => 1200 } }
          },
          "reverse_depth" => { "mean" => 3.42, "median" => 3.0, "count" => 5506 },
          "branching_factor" => { "mean" => 2649.6, "median" => 2.416, "count" => 1611 }
        }
      }
    end

    it "folds every 1.6 block VERBATIM (byte-equal numbers), worst-list de-anonymized" do
      Dir.mktmpdir do |dir|
        anon, proxy_id = anon_with_proxy_id
        Archbuddy::Cache::Writer.new(project_root: dir)
                                .write(graph: anon.graph, id_map: anon.id_map,
                                       findings: findings_16(proxy_id))
        agg = read_aggregate(dir)

        expect(agg["serializer_version"]).to eq(3)
        expect(agg["blast_radius"]).to eq(
          "max" => 1569, "p90" => 3.0, "median" => 1.0, "mean" => 121.38,
          "reached_nodes" => 5506, "total_nodes" => 16_173, "total_entrypoints" => 1611,
          "pct_use_cases_hit_by_worst" => 0.9739,
          "worst" => [{ "symbol" => "Billing::Invoice#total",
                        "use_cases_affected" => 1569, "added_coupling" => 7.5 }]
        )
        # FLAT spellings, 1:1 with findings (guard R1) — never a `depth` key.
        expect(agg).not_to have_key("depth")
        expect(agg["forward_depth"]).to eq(
          "mean" => 2.83, "median" => 2.0, "count" => 1611,
          "by_category" => { "controllers" => { "mean" => 2.9, "median" => 2.0, "count" => 1200 } }
        )
        expect(agg["reverse_depth"]).to eq("mean" => 3.42, "median" => 3.0, "count" => 5506)
        expect(agg["branching_factor"]).to eq("mean" => 2649.6, "median" => 2.416, "count" => 1611)
        expect(agg["branching_factor"]).not_to have_key("grade") # UNGRADED (L15)
      end
    end

    it "widens scores.<dim> with median/median_grade/capped_fraction (R8 — the v2 median-gap fix)" do
      Dir.mktmpdir do |dir|
        anon, proxy_id = anon_with_proxy_id
        Archbuddy::Cache::Writer.new(project_root: dir)
                                .write(graph: anon.graph, id_map: anon.id_map,
                                       findings: findings_16(proxy_id))
        rev = read_aggregate(dir)["scores"]["reverse_traceability"]

        expect(rev).to eq(
          "grade" => "F", "score" => 32_402.84, "median" => 1_000_000.0,
          "median_grade" => "F", "capped_fraction" => 0.9764
        )
      end
    end

    it "reads the egress cost keys + entrypoints.capped_fraction (mirrors the entrypoints spellings)" do
      Dir.mktmpdir do |dir|
        anon, proxy_id = anon_with_proxy_id
        Archbuddy::Cache::Writer.new(project_root: dir)
                                .write(graph: anon.graph, id_map: anon.id_map,
                                       findings: findings_16(proxy_id))
        agg = read_aggregate(dir)

        expect(agg["egress"]["mean"]).to eq(130.5)
        expect(agg["egress"]["median"]).to eq(44.0)
        expect(agg["egress"]["capped_fraction"]).to eq(0.0)
        expect(agg["egress"]["by_category_cost"]).to eq(
          "gem" => { "mean" => 120.0, "median" => 40.0, "grade" => "C",
                     "median_grade" => "B", "capped_fraction" => 0.0 }
        )
        expect(agg["entrypoints"]["capped_fraction"]).to eq(0.0214)
      end
    end

    it "a findings-1.5 doc yields v3 with NO 1.6 blocks (absence, never fabricated nulls) but median + egress cost populated" do
      Dir.mktmpdir do |dir|
        anon, = anon_with_proxy_id
        findings_15 = {
          "scores" => {
            "forward_discoverability" => { "grade" => "B", "score" => 82.5, "median" => 41.0,
                                           "hotspots" => [] },
            "reverse_traceability"    => { "grade" => "C", "score" => 61.0, "median" => 30.0,
                                           "hotspots" => [] },
            "egress" => { "grade" => "A", "score" => 10.0, "median" => 8.0, "hotspots" => [] },
            "egress_by_category" => {}
          }
        }
        Archbuddy::Cache::Writer.new(project_root: dir)
                                .write(graph: anon.graph, id_map: anon.id_map, findings: findings_15)
        agg = read_aggregate(dir)

        expect(agg["serializer_version"]).to eq(3)
        %w[blast_radius forward_depth reverse_depth branching_factor depth].each do |key|
          expect(agg).not_to have_key(key)
        end
        expect(agg["scores"]["forward_discoverability"]["median"]).to eq(41.0)
        expect(agg["scores"]["reverse_traceability"]["median"]).to eq(30.0)
        # 1.5 emits no median_grade/capped_fraction → honest null, never fabricated
        expect(agg["scores"]["reverse_traceability"]["median_grade"]).to be_nil
        expect(agg["egress"]["mean"]).to eq(10.0)
        expect(agg["egress"]["median"]).to eq(8.0)
        expect(agg["egress"]["capped_fraction"]).to be_nil
        expect(agg["egress"]["by_category_cost"]).to eq({})
      end
    end

    it "carry-forward: a collect-only rewrite keeps every v3 block byte-identical (counts fresh, cost carried)" do
      Dir.mktmpdir do |dir|
        anon, proxy_id = anon_with_proxy_id
        Archbuddy::Cache::Writer.new(project_root: dir)
                                .write(graph: anon.graph, id_map: anon.id_map,
                                       findings: findings_16(proxy_id))
        analyzed = read_aggregate(dir)

        # collect-only rewrite with fresh diagnostics (the real collect flow)
        _, diagnostics = collect
        write_collect(dir, anon, diagnostics)
        after = read_aggregate(dir)

        %w[blast_radius forward_depth reverse_depth branching_factor scores multiplexer_proxies].each do |key|
          expect(after[key]).to eq(analyzed[key])
        end
        # counts FRESH from diagnostics (the analyze write only had the
        # generic graph-edge fallback)…
        expect(after["egress"]["by_category"]).to eq("http" => 0, "gem" => 1, "queue" => 0, "generic" => 0)
        # …while the engine-published cost keys are CARRIED (never recomputed)
        expect(after["egress"]["mean"]).to eq(130.5)
        expect(after["egress"]["median"]).to eq(44.0)
        expect(after["egress"]["by_category_cost"]).to eq(analyzed["egress"]["by_category_cost"])
      end
    end

    it "a v2 prior manufactures NOTHING: collect over a v2 cache adds no v3 blocks or cost keys" do
      Dir.mktmpdir do |dir|
        v2 = {
          "serializer_version" => 2,
          "sources" => {},
          "scores" => { "forward_discoverability" => { "grade" => "B", "score" => 82.0 } },
          "egress" => { "total" => 1, "count" => 1,
                        "by_category" => { "http" => 0, "gem" => 1, "queue" => 0, "generic" => 0 } }
        }
        File.write(File.join(dir, "archbuddy-findings.json"), JSON.generate(v2))

        anon, diagnostics = collect
        write_collect(dir, anon, diagnostics)
        agg = read_aggregate(dir)

        expect(agg["serializer_version"]).to eq(3)
        %w[blast_radius forward_depth reverse_depth branching_factor depth].each do |key|
          expect(agg).not_to have_key(key)
        end
        expect(agg["scores"]).to eq(v2["scores"]) # carried verbatim
        %w[mean median capped_fraction by_category_cost].each do |key|
          expect(agg["egress"]).not_to have_key(key) # no manufactured cost
        end
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
