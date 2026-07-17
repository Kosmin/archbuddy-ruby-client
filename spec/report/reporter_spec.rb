# frozen_string_literal: true

require "archbuddy/report"
require "archbuddy/report/reconnect"
require "archbuddy/report/ranker"
require "archbuddy/report/formatter"
require "architecture_auditor"

RSpec.describe "Reporter end-to-end (R-1..R-7)" do
  let(:fixtures)     { File.expand_path("../fixtures/report", __dir__) }
  let(:findings_yml) { File.join(fixtures, "findings_fixture.yml") }
  let(:id_map_yml)   { File.join(fixtures, "id_map_fixture.yml") }

  let(:result) do
    Archbuddy::Report::Reconnect.from_files(
      findings_path: findings_yml, id_map_path: id_map_yml
    ).call
  end
  let(:ranker) { Archbuddy::Report::Ranker.new(result) }

  def bottleneck(symbol)
    result.bottlenecks.find { |b| b.location.symbol == symbol }
  end

  # --- R-2 / R-3: ranking by clutter_score ------------------------------------

  it "ranks bottlenecks by clutter_score descending (deterministic)" do
    ranked = ranker.ranked
    expect(ranked.map(&:clutter_score)).to eq([9.5, 8.0, 5.0, 2.0])
    expect(ranked.map { |b| b.location.symbol }).to eq(
      ["OrdersController#create", "Billing#charge", "User#save", "Billing#refund"]
    )
  end

  it "honors --top N" do
    top2 = ranker.ranked(top: 2)
    expect(top2.length).to eq(2)
    expect(top2.map { |b| b.location.symbol }).to eq(
      ["OrdersController#create", "Billing#charge"]
    )
  end

  # --- R-2: de-anonymization at the three join sites --------------------------

  it "de-anonymizes a high_fan_in node to its real symbol" do
    charge = bottleneck("Billing#charge")
    expect(charge).not_to be_nil
    expect(charge.location).to be_resolved
    expect(charge.location.file).to eq("app/services/billing.rb")
    expect(charge.location.line).to eq(8)

    fan_in = charge.findings.find { |f| f.type == "high_fan_in" }
    expect(fan_in).not_to be_nil
    expect(fan_in.node.symbol).to eq("Billing#charge")
  end

  it "renders a long_path finding as a real ordered call chain" do
    create = bottleneck("OrdersController#create")
    long_path = create.findings.find { |f| f.type == "long_path" }
    expect(long_path).not_to be_nil
    expect(long_path.path?).to be(true)
    # ordered chain, de-anonymized; the trailing ext_ sink is a placeholder.
    expect(long_path.path_refs.map(&:symbol)).to eq(
      ["OrdersController#create", "User#save", "Billing#charge", "<external sink ext_e4c31576a772>"]
    )
    expect(long_path.chain).to eq(
      "OrdersController#create → User#save → Billing#charge → <external sink ext_e4c31576a772>"
    )
  end

  # --- graceful external/missing id (no raise) --------------------------------

  it "resolves an ext_/missing id to a graceful placeholder without raising" do
    expect {
      loc = result.resolve("ext_e4c31576a772")
      expect(loc.resolved?).to be(false)
      expect(loc.symbol).to include("<external")
    }.not_to raise_error
  end

  it "resolves a totally unknown id gracefully too" do
    loc = result.resolve("n_deadbeefdead")
    expect(loc.resolved?).to be(false)
    expect(loc.symbol).to include("<external")
  end

  # --- R-3: class rollups via cls_ de-anon (D9) -------------------------------

  it "rolls up bottlenecks by class_id and de-anonymizes the cls_ id" do
    rollups = ranker.class_rollups
    billing = rollups.find { |r| r.location.symbol == "Billing" }
    expect(billing).not_to be_nil
    expect(billing).to be_rollup
    # Billing#charge (8.0) + Billing#refund (2.0) = 10.0
    expect(billing.clutter_score).to eq(10.0)
    expect(billing.metrics["member_count"]).to eq(2)

    user = rollups.find { |r| r.location.symbol == "User" }
    expect(user.clutter_score).to eq(5.0)

    # ranked by summed score desc
    expect(rollups.map { |r| r.location.symbol }).to eq(["Billing", "User"])
  end

  # --- D17: metrics copied VERBATIM, never recomputed -------------------------

  it "shows the full 8-metric breakdown VERBATIM (no recomputation)" do
    charge = bottleneck("Billing#charge")
    # The fixture deliberately sets fan_in=42 and clutter_score=8.0 — numbers
    # that do not derive from one another. The reporter must echo them exactly.
    Archbuddy::Report::METRIC_KEYS_FOR_DISPLAY.each do |key|
      expect(charge.metrics).to have_key(key)
    end
    expect(charge.metrics["fan_in"]).to eq(42)
    expect(charge.metrics["centrality"]).to eq(0.90)
    expect(charge.metrics["path_length"]).to eq(2)
    expect(charge.clutter_score).to eq(8.0)

    # null metrics survive as nil
    refund = bottleneck("Billing#refund")
    expect(refund.metrics["path_length"]).to be_nil
    expect(refund.metrics["instability"]).to be_nil
  end

  # --- R-6: terminal formatter ------------------------------------------------

  describe "terminal formatter" do
    let(:output) do
      context = Archbuddy::Report::Formatter::RenderContext.new(
        ranked:        ranker.ranked,
        class_rollups: ranker.class_rollups,
        generator:     result.findings_doc["generator"],
        graph:         nil,
        resolver:      Archbuddy::Report::Reconnect::IdMapResolver.new(result.id_map)
      )
      Archbuddy::Report::Formatter.for("terminal").new(context).render
    end

    it "shows real symbol, file:line, clutter_score and the 8-metric breakdown" do
      expect(output).to include("Billing#charge")
      expect(output).to include("app/services/billing.rb:8")
      expect(output).to include("clutter 8.0000")
      Archbuddy::Report::METRIC_KEYS_FOR_DISPLAY.each do |key|
        expect(output).to include(key)
      end
      # verbatim absurd fan_in value rendered
      expect(output).to match(/fan_in\s+42/)
    end

    it "renders the de-anonymized long_path chain and explanations" do
      expect(output).to include("OrdersController#create → User#save → Billing#charge")
      expect(output).to match(/High fan-in/)
      expect(output).to match(/Long path/)
    end

    it "shows class rollups" do
      expect(output).to include("Class rollups")
      expect(output).to match(/Billing.*clutter 10\.0000/)
    end
  end

  # --- v0.10 (W4): the three committed counter banners (terminal) -------------
  #
  # SERIALIZER-v2 aggregates carry `entrypoints`/`egress`/`dynamic_dispatch`;
  # the terminal formatter renders each as a nil-guarded banner mirroring the
  # connectivity banner. A v1 aggregate parses all three to nil → NO banner and
  # NO "Architecture Scores" section change (byte-identical back-compat).
  describe "v0.10 counter banners (terminal, W4)" do
    S = Archbuddy::Report::Scores unless defined?(S)

    let(:entrypoints) do
      S::EntrypointCount.new(
        total: 4, count: 4,
        by_category: { "controllers" => 3, "jobs" => 1, "rake" => 0, "script" => 0 },
        mean: nil, median: nil
      )
    end
    let(:egress) do
      S::Egress.new(total: 5, count: 5,
                    by_category: { "http" => 2, "gem" => 3, "queue" => 0, "generic" => 0 })
    end
    let(:dynamic_dispatch) do
      S::DynamicDispatch.new(dynamic_sites: 2, resolved_sites: 8,
                             total_call_sites: 10, ratio: 0.8)
    end

    def render(**fields)
      context = Archbuddy::Report::Formatter::RenderContext.new(
        ranked:        ranker.ranked,
        class_rollups: ranker.class_rollups,
        generator:     result.findings_doc["generator"],
        graph:         nil,
        resolver:      Archbuddy::Report::Reconnect::IdMapResolver.new(result.id_map),
        **fields
      )
      Archbuddy::Report::Formatter.for("terminal").new(context).render
    end

    it "renders all three banners on a COLLECT-ONLY v2 aggregate (scores nil — relaxed gate, no raise)" do
      out = render(entrypoints: entrypoints, egress: egress, dynamic_dispatch: dynamic_dispatch)

      expect(out).to include("Architecture Scores")
      expect(out).to include("Entrypoints: 4 total (controllers 3, jobs 1)") # zero buckets elided
      expect(out).to include("Egress: 5 total (http 2, gem 3)")
      expect(out).to include("Dynamic dispatch: 8/10 resolved, 2 dynamic (coverage 80.0%)")
    end

    it "drops the mean/median suffix entirely on a collect-only cache (both nil — honest absence)" do
      out = render(entrypoints: entrypoints)
      expect(out).to include("Entrypoints: 4 total (controllers 3, jobs 1)\n")
      expect(out).not_to include("mean")
      expect(out).not_to include("median")
    end

    it "shows engine-published mean AND median verbatim when present (L7)" do
      ep  = S::EntrypointCount.new(total: 4, count: 4,
                                   by_category: { "controllers" => 4 }, mean: 27.14, median: 12.0)
      out = render(entrypoints: ep)
      expect(out).to include("Entrypoints: 4 total (controllers 4) — mean 27.1, median 12.0")
    end

    # v0.10 W6: the per-category cost line — rendered ONLY when the engine
    # published the findings-1.5 per-category lens (nil-tolerant absence).
    it "renders the per-category cost line when the engine published the 1.5 lens (W6)" do
      ep = S::EntrypointCount.new(
        total: 4, count: 4, by_category: { "controllers" => 3, "jobs" => 1 },
        mean: 27.14, median: 12.0,
        by_category_cost: {
          "controllers" => { "mean" => 30.0, "median" => 14.0, "grade" => "C" },
          "jobs"        => { "mean" => 5.0, "median" => 5.0, "grade" => "A" }
        }
      )
      out = render(entrypoints: ep)
      expect(out).to include(
        "Entrypoint cost by category: controllers mean 30.0 / median 14.0 (C), " \
        "jobs mean 5.0 / median 5.0 (A)"
      )
    end

    it "omits the per-category cost line entirely when the lens is absent/empty (pre-1.5 — honest absence)" do
      out = render(entrypoints: entrypoints) # by_category_cost nil
      expect(out).not_to include("Entrypoint cost by category")

      ep_empty = S::EntrypointCount.new(total: 4, count: 4,
                                        by_category: { "controllers" => 4 }, by_category_cost: {})
      expect(render(entrypoints: ep_empty)).not_to include("Entrypoint cost by category")
    end

    it "renders honest degenerate values: 0 total => (none); nil ratio => coverage N/A (I2)" do
      out = render(
        entrypoints: S::EntrypointCount.new(total: 0, count: 0, by_category: {}),
        dynamic_dispatch: S::DynamicDispatch.new(dynamic_sites: 0, resolved_sites: 0,
                                                 total_call_sites: 0, ratio: nil)
      )
      expect(out).to include("Entrypoints: 0 total (none)")
      expect(out).to include("Dynamic dispatch: 0/0 resolved, 0 dynamic (coverage N/A)")
    end

    it "renders NO banner and NO scores section on a v1 aggregate (nil blocks — back-compat)" do
      out = render

      expect(out).not_to include("Entrypoints:")
      expect(out).not_to include("Egress:")
      expect(out).not_to include("Dynamic dispatch:")
      expect(out).not_to include("Architecture Scores") # gate stays closed, as today
      # Byte-identity: an explicit-nil context renders the SAME bytes as one
      # that never set the fields (the pre-v0.10 construction shape).
      expect(out).to eq(render(entrypoints: nil, egress: nil, dynamic_dispatch: nil))
    end

    it "keeps a v1 SCORES-bearing doc byte-stable: dimension rows render, banners absent" do
      v11 = Archbuddy::Report::Reconnect.from_files(
        findings_path: File.join(fixtures, "findings_v11_fixture.yml"),
        id_map_path:   id_map_yml
      ).call
      out = render(scores: v11.scores)

      expect(out).to include("Architecture Scores")
      expect(out).not_to include("Entrypoints:")
      expect(out).not_to include("Egress:")
      expect(out).not_to include("Dynamic dispatch:")
    end
  end

  # --- v0.11 (W-C T7): the Business Impact section (terminal) -----------------
  #
  # A PEER section between the header and Architecture Scores, rendered from
  # the ONE shared BusinessImpact presenter (all copy/nil-guards live THERE —
  # the formatter is pure markup). Zero answerable questions → [] → the whole
  # section is omitted and v1/v2 docs render byte-identically to v0.10 (the
  # :259-271 byte-stability gates above re-run UNMODIFIED as that proof).
  describe "Business Impact section (terminal, W-C)" do
    S = Archbuddy::Report::Scores unless defined?(S)

    def render(**fields)
      context = Archbuddy::Report::Formatter::RenderContext.new(
        ranked:        ranker.ranked,
        class_rollups: ranker.class_rollups,
        generator:     result.findings_doc["generator"],
        graph:         nil,
        resolver:      Archbuddy::Report::Reconnect::IdMapResolver.new(result.id_map),
        **fields
      )
      Archbuddy::Report::Formatter.for("terminal").new(context).render
    end

    # The MEASURED plan numbers (L14/L15/L16 — the I8 worked examples).
    let(:blast) do
      S::BlastRadius.new(
        max: 1569, p90: 3.0, median: 1.0, mean: 121.38,
        reached_nodes: 5506, total_nodes: 16_173, total_entrypoints: 1611,
        pct_use_cases_hit_by_worst: 0.9739,
        worst: [S::BlastRadius::Worst.new(symbol: "Router#dispatch",
                                          use_cases_affected: 1569, added_coupling: 7.5)]
      )
    end
    let(:fwd_depth) { S::DepthStats.new(mean: 2.83, median: 2.0, count: 1611) }
    let(:rev_depth) { S::DepthStats.new(mean: 3.42, median: 3.0, count: 5506) }
    let(:branching) { S::BranchingFactor.new(mean: 2649.6, median: 2.416, count: 1611) }

    it "renders the full six-question section between header and scores (pinned lines)" do
      out = render(
        scores: [
          S::DimensionScore.new(key: "forward_discoverability", label: "f", question: "",
                                score: 30_992.17, grade: "F", hotspots: [], median: 2.0,
                                median_grade: "A", capped_fraction: 0.0214),
          S::DimensionScore.new(key: "reverse_traceability", label: "r", question: "",
                                score: 32_402.84, grade: "F", hotspots: [], median: 1_000_000.0,
                                median_grade: "F", capped_fraction: 0.9764)
        ],
        blast_radius: blast, forward_depth: fwd_depth,
        reverse_depth: rev_depth, branching_factor: branching
      )

      expect(out).to include("\nBusiness Impact\n#{'-' * 60}\n")
      expect(out).to include("  Q1 Implementing a new feature: how much complexity will a developer face?")
      expect(out).to include("     cost mean 30992.2 (F, median: A) · median 2.0 — 2.1% of routes at cap (lower bound)")
      expect(out).to include("  Q3 Breaking something: how many use cases can a single change put at risk?")
      expect(out).to include(
        "     the worst single node is reachable from 1569 of 1611 use cases (97.4%) — p90 3, median 1"
      )
      expect(out).to include("     worst offenders: Router#dispatch (1569 use cases, +7.5 coupling)")
      expect(out).to include("  Q4 Implementing a new feature: how many steps does a new flow travel end-to-end?")
      expect(out).to include("     a typical use case is 2.0 functions deep (mean 2.8)")
      expect(out).to include("  BF Branching")
      expect(out).to include("     each step of tracing multiplies the choices ×2.42 (median; mean 2649.6)")
      # peer-section ordering: BI sits BEFORE Architecture Scores
      expect(out.index("Business Impact")).to be < out.index("Architecture Scores")
    end

    it "renders only the answerable questions (per-question omission, no placeholder rows)" do
      out = render(blast_radius: blast, forward_depth: fwd_depth)

      expect(out).to include("Business Impact")
      expect(out).to include("  Q3 ")
      expect(out).to include("  Q4 ")
      expect(out).not_to include("  Q1 ")
      expect(out).not_to include("  Q2 ")
      expect(out).not_to include("  Q5 ")
      expect(out).not_to include("  BF ")
    end

    it "omits the whole section on a no-data doc — explicit-nil byte-identity over the four new fields" do
      out = render

      expect(out).not_to include("Business Impact")
      # the :266-268 explicit-nil byte-identity idiom extended to the four
      # v0.11 context fields: an explicit-nil context renders the SAME bytes
      # as one that never set them (v1/v2 docs stay byte-identical to v0.10).
      expect(out).to eq(render(blast_radius: nil, forward_depth: nil,
                               reverse_depth: nil, branching_factor: nil))
    end
  end

  # --- R-6: structured exports ------------------------------------------------

  describe "yaml/json exports" do
    def context
      Archbuddy::Report::Formatter::RenderContext.new(
        ranked:        ranker.ranked,
        class_rollups: ranker.class_rollups,
        generator:     result.findings_doc["generator"],
        graph:         nil,
        resolver:      Archbuddy::Report::Reconnect::IdMapResolver.new(result.id_map)
      )
    end

    it "yaml export round-trips with verbatim metrics" do
      yaml = Archbuddy::Report::Formatter.for("yaml").new(context).render
      doc  = ArchitectureAuditor::Contract::Serializer.load_string(yaml)
      charge = doc["bottlenecks"].find { |b| b["symbol"] == "Billing#charge" }
      expect(charge["metrics"]["fan_in"]).to eq(42)
      expect(charge["clutter_score"]).to eq(8.0)
    end

    it "json export is valid JSON with de-anonymized symbols" do
      json = Archbuddy::Report::Formatter.for("json").new(context).render
      doc  = JSON.parse(json)
      expect(doc["bottlenecks"].first["symbol"]).to eq("OrdersController#create")
    end
  end

  # --- R-6: dot formatter (optional / needs --graph) --------------------------

  describe "dot formatter" do
    def context(graph:)
      Archbuddy::Report::Formatter::RenderContext.new(
        ranked:        ranker.ranked,
        class_rollups: ranker.class_rollups,
        generator:     result.findings_doc["generator"],
        graph:         graph,
        resolver:      Archbuddy::Report::Reconnect::IdMapResolver.new(result.id_map)
      )
    end

    it "is unavailable with a clear message when --graph is absent" do
      out = Archbuddy::Report::Formatter.for("dot").new(context(graph: nil)).render
      expect(out).to include("requires the graph edge list")
      expect(out).to include("--graph")
    end

    it "emits a de-anonymized digraph when graph is supplied" do
      graph = {
        "nodes" => [
          { "id" => "n_9806809c4b1f" },
          { "id" => "n_e188e5adb49f" }
        ],
        "edges" => [
          { "from" => "n_9806809c4b1f", "to" => "n_e188e5adb49f" }
        ]
      }
      out = Archbuddy::Report::Formatter.for("dot").new(context(graph: graph)).render
      expect(out).to include("digraph archbuddy {")
      expect(out).to include("OrdersController#create")
      expect(out).to include("Billing#charge")
      expect(out).to include('"n_9806809c4b1f" -> "n_e188e5adb49f"')
    end
  end

  # --- R-4: explanation table covers all 7 finding types ----------------------

  it "has an explanation for all 7 contract finding types (D38)" do
    expected = %w[high_fan_in high_fan_out high_centrality orphan dead long_path cycle]
    expect(Archbuddy::Report::Explanation::TABLE.keys.sort).to eq(expected.sort)
    expected.each do |type|
      entry = Archbuddy::Report::Explanation.for(type)
      expect(entry[:summary]).to be_a(String)
      expect(entry[:axis]).to match(/discoverability|traceability|both/)
    end
  end

  # --- open/closed registry ---------------------------------------------------

  it "registers the four built-in formats" do
    expect(Archbuddy::Report::Formatter.registered).to include("terminal", "yaml", "json", "dot")
  end
end
