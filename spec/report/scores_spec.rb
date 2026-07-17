# frozen_string_literal: true

require "archbuddy/report"
require "archbuddy/report/reconnect"
require "archbuddy/report/ranker"
require "archbuddy/report/formatter"
require "architecture_auditor"

# R-8: the reporter surfaces the engine's two PROJECT-level dimension scores
# (findings 1.1) and de-anonymizes each dimension's hotspots to real code, while
# staying fully back-compatible with a 1.0 findings doc that has no scores block.
RSpec.describe "Reporter dimension scores (R-8)" do
  let(:fixtures)    { File.expand_path("../fixtures/report", __dir__) }
  let(:id_map_yml)  { File.join(fixtures, "id_map_fixture.yml") }
  let(:v11_yml)     { File.join(fixtures, "findings_v11_fixture.yml") }
  let(:v13_yml)     { File.join(fixtures, "findings_v13_connectivity_fixture.yml") }
  let(:forward_na)  { File.join(fixtures, "findings_v11_forward_na_fixture.yml") }
  let(:v10_yml)     { File.join(fixtures, "findings_fixture.yml") } # 1.0, NO scores

  def result_for(findings)
    Archbuddy::Report::Reconnect.from_files(
      findings_path: findings, id_map_path: id_map_yml
    ).call
  end

  def context_for(findings)
    result = result_for(findings)
    ranker = Archbuddy::Report::Ranker.new(result)
    Archbuddy::Report::Formatter::RenderContext.new(
      ranked:        ranker.ranked,
      class_rollups: ranker.class_rollups,
      generator:     result.findings_doc["generator"],
      graph:         nil,
      resolver:      Archbuddy::Report::Reconnect::IdMapResolver.new(result.id_map),
      scores:        result.scores,
      connectivity:  result.connectivity
    )
  end

  def render(findings, format)
    Archbuddy::Report::Formatter.for(format).new(context_for(findings)).render
  end

  # --- model: parse + de-anonymize the scores block ---------------------------

  describe "Scores model" do
    let(:scores) { result_for(v11_yml).scores }

    it "parses both dimensions, reverse first" do
      expect(scores.map(&:key)).to eq(%w[reverse_traceability forward_discoverability])
    end

    it "copies score + grade VERBATIM from findings.yml (no recompute, D17)" do
      reverse = scores.find { |d| d.key == "reverse_traceability" }
      forward = scores.find { |d| d.key == "forward_discoverability" }
      expect(reverse.score).to eq(58)
      expect(reverse.grade).to eq("D")
      expect(forward.score).to eq(72)
      expect(forward.grade).to eq("C")
    end

    it "de-anonymizes reverse hotspots worst-first to real symbols + driving metrics" do
      reverse = scores.find { |d| d.key == "reverse_traceability" }
      first   = reverse.hotspots.first
      expect(first.location).to be_resolved
      expect(first.symbol).to eq("Billing#charge")
      expect(first.file_line).to eq("app/services/billing.rb:8")
      # reverse driving metrics pulled verbatim from nodes.<id>.metrics
      expect(first.metrics).to eq("fan_in" => 42, "centrality" => 0.90, "in_cycle" => 0)
    end

    it "de-anonymizes forward hotspots with their driving metrics" do
      forward = scores.find { |d| d.key == "forward_discoverability" }
      top     = forward.hotspots.first
      expect(top.symbol).to eq("OrdersController#create")
      expect(top.metrics).to eq("path_length" => 0, "fan_out" => 3)
    end

    it "resolves a hotspot id absent from the id-map to a graceful placeholder (no raise)" do
      reverse = scores.find { |d| d.key == "reverse_traceability" }
      ghost   = reverse.hotspots.last # ext_e4c31576a772, absent from id-map
      expect { ghost.symbol }.not_to raise_error
      expect(ghost.location).not_to be_resolved
      expect(ghost.symbol).to include("<external")
    end

    it "returns nil for a 1.0 findings doc with no scores block (back-compat)" do
      expect(result_for(v10_yml).scores).to be_nil
    end

    it "renders a null/N-A forward score as N/A with an actionable reason" do
      forward = result_for(forward_na).scores.find { |d| d.key == "forward_discoverability" }
      expect(forward).to be_na
      expect(forward.display_score).to eq("N/A")
      expect(forward.grade).to eq("N/A")
      expect(forward.na_reason).to include("no entrypoints")
      expect(forward.na_reason).to include("--entrypoints all_public")
    end

    it "display_score formats a scored dimension as '58.0' (%.1f, no /100)" do
      reverse = scores.find { |d| d.key == "reverse_traceability" }
      expect(reverse.display_score).to eq("58.0")
      expect(reverse.display_score).not_to include("/100")
    end

    it "display_score tolerates an unbounded cost above 100 (e.g. 137.4 -> '137.4')" do
      dim = Archbuddy::Report::Scores::DimensionScore.new(
        key: "reverse_traceability", label: "Test", question: "?",
        score: 137.4, grade: "F", hotspots: [], na_reason: nil
      )
      expect(dim.display_score).to eq("137.4")
      expect(dim.display_score).not_to include("/100")
    end
  end

  # --- terminal formatter: eslint/rubocop-style summary header ----------------

  describe "terminal summary header" do
    let(:output) { render(v11_yml, "terminal") }

    it "renders the Architecture Scores header with both scores + grades" do
      expect(output).to include("Architecture Scores")
      expect(output).to match(/Reverse Traceability\s+58\.0\s+\(D\)/)
      expect(output).to match(/Forward Discoverability\s+72\.0\s+\(C\)/)
    end

    it "leads with the framing questions (score is the headline, not 'bug')" do
      expect(output).to include("can you tell where code is used?")
      expect(output).to include("can you follow where execution goes?")
      # framing: hotspots are presented as relative contributors, not bugs
      expect(output).to include("top contributors to this dimension")
    end

    it "lists de-anonymized hotspots with real symbol + file:line + driving metric" do
      expect(output).to include("Billing#charge (app/services/billing.rb:8)")
      expect(output).to match(/fan_in=42/)
      expect(output).to match(/centrality=0\.9000/)
      # forward hotspot shows path_length / fan_out
      expect(output).to include("OrdersController#create")
      expect(output).to match(/fan_out=3/)
    end

    it "renders the scores header BEFORE the per-bottleneck list" do
      expect(output.index("Architecture Scores")).to be < output.index("#1  ")
    end

    it "renders an absent hotspot id gracefully as <external …>" do
      expect(output).to include("<external")
    end

    context "when forward is N/A" do
      let(:na_output) { render(forward_na, "terminal") }

      it "renders N/A with the reason rather than a number" do
        expect(na_output).to match(/Forward Discoverability\s+N\/A\s+\(N\/A\)/)
        expect(na_output).to include("no entrypoints — re-collect with --entrypoints all_public")
        # reverse still scored
        expect(na_output).to match(/Reverse Traceability\s+81\.0\s+\(B\)/)
      end
    end

    context "with a 1.0 findings doc (no scores)" do
      let(:plain) { render(v10_yml, "terminal") }

      it "renders no Architecture Scores header and does not crash" do
        expect(plain).not_to include("Architecture Scores")
        expect(plain).to include("Billing#charge") # normal report still works
      end
    end
  end

  # --- Connectivity model (findings 1.3, CR-1 four-field schema) -------------

  describe "Connectivity model" do
    let(:conn) { result_for(v13_yml).connectivity }

    it "parses the four-field connectivity object from a 1.3 findings doc" do
      expect(conn).not_to be_nil
      expect(conn).to be_a(Archbuddy::Report::Scores::Connectivity)
      expect(conn.forward).to eq(0.003)
      expect(conn.reverse).to eq(0.003)
      expect(conn.scored_nodes).to eq(5)
      expect(conn.total_nodes).to eq(1672)
    end

    it "formats forward ratio as a percent string (engine-emitted, client only formats)" do
      expect(conn.forward_pct_display).to eq("0.3%")
    end

    it "returns the scored_ratio as 'N/M' string" do
      expect(conn.scored_ratio).to eq("5/1672")
    end

    it "returns nil for a 1.1 findings doc (no connectivity key) — back-compat" do
      expect(result_for(v11_yml).connectivity).to be_nil
    end

    it "returns nil for a 1.0 findings doc (no scores block) — back-compat" do
      expect(result_for(v10_yml).connectivity).to be_nil
    end

    it "returns nil from connectivity_from_findings({}) — back-compat" do
      expect(Archbuddy::Report::Scores.connectivity_from_findings({})).to be_nil
    end

    it "returns nil from connectivity_from_findings({'scores'=>{}}) — back-compat" do
      expect(Archbuddy::Report::Scores.connectivity_from_findings({ "scores" => {} })).to be_nil
    end

    it "renders an engine-nil forward ratio as 'N/A' (not '0.0%', N1)" do
      c = Archbuddy::Report::Scores::Connectivity.new(
        forward: nil, reverse: 0.5,
        scored_nodes: 10, total_nodes: 100
      )
      expect(c.forward_pct_display).to eq("N/A")
      expect(c.reverse_pct_display).to eq("50.0%")
    end
  end

  # --- terminal connectivity banner -------------------------------------------

  describe "terminal connectivity banner" do
    it "renders the banner ABOVE the dimension rows when connectivity is present" do
      output = render(v13_yml, "terminal")
      expect(output).to include("Connectivity: 5/1672 nodes scored (0.3%)")
      expect(output.index("Connectivity:")).to be < output.index("Reverse Traceability")
    end

    it "renders NO Connectivity: line for a 1.1 doc (no connectivity key)" do
      output = render(v11_yml, "terminal")
      expect(output).not_to include("Connectivity:")
    end
  end

  # --- structured exports include the de-anonymized scores --------------------

  describe "yaml/json exports include scores" do
    it "yaml export includes de-anonymized scores with grades + hotspots" do
      yaml = render(v11_yml, "yaml")
      doc  = ArchitectureAuditor::Contract::Serializer.load_string(yaml)
      expect(doc["scores"]).not_to be_nil
      reverse = doc["scores"]["reverse_traceability"]
      expect(reverse["score"]).to eq(58)
      expect(reverse["grade"]).to eq("D")
      top = reverse["hotspots"].first
      expect(top["symbol"]).to eq("Billing#charge")
      expect(top["file"]).to eq("app/services/billing.rb")
      expect(top["metrics"]["fan_in"]).to eq(42)
    end

    it "json export includes scores too" do
      json = render(v11_yml, "json")
      doc  = JSON.parse(json)
      expect(doc["scores"]["forward_discoverability"]["grade"]).to eq("C")
      expect(doc["scores"]["forward_discoverability"]["hotspots"].first["symbol"])
        .to eq("OrdersController#create")
    end

    it "exports N/A forward honestly (null score, N/A grade, reason)" do
      json = render(forward_na, "json")
      doc  = JSON.parse(json)
      fwd  = doc["scores"]["forward_discoverability"]
      expect(fwd["score"]).to be_nil
      expect(fwd["grade"]).to eq("N/A")
      expect(fwd["na_reason"]).to include("no entrypoints")
    end

    it "omits the scores key entirely for a 1.0 doc (back-compat)" do
      yaml = render(v10_yml, "yaml")
      doc  = ArchitectureAuditor::Contract::Serializer.load_string(yaml)
      expect(doc).not_to have_key("scores")
    end
  end
end

# v0.10 W1-A1: the three committed-aggregate counter structs + parsers
# (EntrypointCount / Egress / DynamicDispatch). Pure presentation — parsed
# VERBATIM from the aggregate doc, nil on absence (pre-SERIALIZER-2 docs),
# honest zero when present-but-empty. The Cache::Writer wires the producing
# fold in W3; these are the consuming halves.
RSpec.describe "counter structs (v0.10 W1-A1)" do
  Scores = Archbuddy::Report::Scores

  describe ".entrypoints_from_aggregate" do
    it "returns nil for an absent block (pre-bump doc), empty block, and nil doc" do
      expect(Scores.entrypoints_from_aggregate({})).to be_nil
      expect(Scores.entrypoints_from_aggregate(nil)).to be_nil
      expect(Scores.entrypoints_from_aggregate("entrypoints" => {})).to be_nil
      expect(Scores.entrypoints_from_aggregate("scores" => { "x" => 1 })).to be_nil
    end

    it "parses a full block verbatim" do
      ep = Scores.entrypoints_from_aggregate(
        "entrypoints" => {
          "total" => 4, "count" => 4,
          "by_category" => { "controllers" => 3, "top_level" => 1, "jobs" => 0 },
          "mean" => nil, "median" => nil,
          "by_category_cost" => { "controllers" => { "mean" => 8.0, "median" => 4.0, "grade" => "A" } }
        }
      )
      expect(ep.total).to eq(4)
      expect(ep.count).to eq(4)
      expect(ep.by_category).to eq("controllers" => 3, "top_level" => 1, "jobs" => 0)
      expect(ep.mean).to be_nil
      expect(ep.median).to be_nil
      # v0.10 W6: the per-category cost lens rides through verbatim
      expect(ep.by_category_cost).to eq("controllers" => { "mean" => 8.0, "median" => 4.0, "grade" => "A" })
    end
  end

  describe Scores::EntrypointCount do
    it "by_category_display skips zero buckets" do
      ep = described_class.new(
        total: 4, count: 4,
        by_category: { "controllers" => 3, "top_level" => 1, "jobs" => 0, "rake" => 0 }
      )
      expect(ep.by_category_display).to eq("controllers 3, top_level 1")
    end

    it "renders an honest 'none' when every bucket is zero (distinct from absence; W4 banners add the parens)" do
      ep = described_class.new(
        total: 0, count: 0, by_category: { "controllers" => 0, "jobs" => 0 }
      )
      expect(ep.by_category_display).to eq("none")
    end

    it "mean/median display an em-dash when the engine has not published cost" do
      ep = described_class.new(total: 1, count: 1, by_category: {}, mean: nil, median: nil)
      expect(ep.mean_display).to eq("—")
      expect(ep.median_display).to eq("—")
    end

    it "mean/median format engine-published cost verbatim (never computed client-side)" do
      ep = described_class.new(total: 1, count: 1, by_category: {}, mean: 12.34, median: 6.0)
      expect(ep.mean_display).to eq("12.3")
      expect(ep.median_display).to eq("6.0")
    end

    # v0.10 W6: the engine per-category cost lens rides the aggregate as
    # `by_category_cost` ({cat => {mean, median, grade}}) — parsed + rendered
    # verbatim, honest-absent (nil display) when unpublished.
    it "by_category_cost_display renders per-category mean/median/grade (W6)" do
      ep = described_class.new(
        total: 4, count: 4, by_category: {},
        by_category_cost: {
          "controllers"   => { "mean" => 82.5, "median" => 41.0, "grade" => "B" },
          "uncategorized" => { "mean" => 3.0, "median" => 3.0, "grade" => "A" }
        }
      )
      expect(ep.by_category_cost_display).to eq(
        "controllers mean 82.5 / median 41.0 (B), uncategorized mean 3.0 / median 3.0 (A)"
      )
    end

    it "by_category_cost_display is nil when the lens is absent, empty, or all-null (pre-1.5 / collect-only)" do
      expect(described_class.new(total: 1, count: 1, by_category: {}).by_category_cost_display).to be_nil
      expect(described_class.new(total: 1, count: 1, by_category: {}, by_category_cost: {})
               .by_category_cost_display).to be_nil
      allnull = { "controllers" => { "mean" => nil, "median" => nil, "grade" => "N/A" } }
      expect(described_class.new(total: 1, count: 1, by_category: {}, by_category_cost: allnull)
               .by_category_cost_display).to be_nil
    end
  end

  describe ".egress_from_aggregate / Egress" do
    it "returns nil on an absent block" do
      expect(Scores.egress_from_aggregate({})).to be_nil
    end

    it "parses the http/gem/queue/generic buckets verbatim" do
      eg = Scores.egress_from_aggregate(
        "egress" => {
          "total" => 5, "count" => 5,
          "by_category" => { "http" => 2, "gem" => 1, "queue" => 0, "generic" => 2 }
        }
      )
      expect(eg.total).to eq(5)
      expect(eg.by_category_display).to eq("http 2, gem 1, generic 2")
    end
  end

  describe ".dynamic_dispatch_from_aggregate / DynamicDispatch" do
    it "returns nil on an absent block" do
      expect(Scores.dynamic_dispatch_from_aggregate({})).to be_nil
    end

    it "parses the coverage tuple verbatim (committed key: coverage_ratio — W3 vocab lock)" do
      dd = Scores.dynamic_dispatch_from_aggregate(
        "dynamic_dispatch" => {
          "dynamic_sites" => 3, "resolved_sites" => 7,
          "total_call_sites" => 100, "coverage_ratio" => 0.42
        }
      )
      expect(dd.dynamic_sites).to eq(3)
      expect(dd.resolved_sites).to eq(7)
      expect(dd.total_call_sites).to eq(100)
      expect(dd.ratio_display).to eq("42.0%")
    end

    it "ratio_display is 'N/A' on a nil ratio (zero call sites — never a fabricated 0/1)" do
      dd = Scores::DynamicDispatch.new(
        dynamic_sites: 0, resolved_sites: 0, total_call_sites: 0, ratio: nil
      )
      expect(dd.ratio_display).to eq("N/A")
    end
  end
end

# v0.11 W-C: the counter-wave read-side structs (BlastRadius / DepthStats /
# BranchingFactor) + the widened DimensionScore / EntrypointCount / Egress.
# Everything parses VERBATIM (D17), nil on absent/empty blocks (v1/v2 docs),
# and the legacy opaque findings-1.6 path resolves worst-entry node ids via
# the SAME id-map join used everywhere else.
RSpec.describe "v0.11 counter structs (W-C)" do
  S = Archbuddy::Report::Scores

  let(:blast_block) do
    {
      "max" => 1569, "p90" => 3.0, "median" => 1.0, "mean" => 121.38,
      "reached_nodes" => 5506, "total_nodes" => 16_173, "total_entrypoints" => 1611,
      "pct_use_cases_hit_by_worst" => 0.9739,
      "worst" => [{ "symbol" => "Foo#bar", "use_cases_affected" => 1569, "added_coupling" => 7.5 }]
    }
  end

  describe ".blast_radius_from_aggregate" do
    it "returns nil for absent/empty blocks and a nil doc (v1/v2 back-compat)" do
      expect(S.blast_radius_from_aggregate({})).to be_nil
      expect(S.blast_radius_from_aggregate(nil)).to be_nil
      expect(S.blast_radius_from_aggregate("blast_radius" => {})).to be_nil
    end

    it "parses a full committed block verbatim (symbol already real-name)" do
      br = S.blast_radius_from_aggregate("blast_radius" => blast_block)
      expect(br.max).to eq(1569)
      expect(br.p90).to eq(3.0)
      expect(br.median).to eq(1.0)
      expect(br.mean).to eq(121.38)
      expect(br.reached_nodes).to eq(5506)
      expect(br.total_nodes).to eq(16_173)
      expect(br.total_entrypoints).to eq(1611)
      expect(br.pct_display).to eq("97.4%")
      expect(br.worst.first.symbol).to eq("Foo#bar")
      expect(br.worst.first.use_cases_affected).to eq(1569)
      expect(br.worst.first.added_coupling).to eq(7.5)
    end

    it "parses the engine N/A form to nil stats + empty worst (pct_display 'N/A')" do
      br = S.blast_radius_from_aggregate(
        "blast_radius" => {
          "max" => nil, "p90" => nil, "median" => nil, "mean" => nil,
          "reached_nodes" => 0, "total_nodes" => 4, "total_entrypoints" => 0,
          "pct_use_cases_hit_by_worst" => nil, "worst" => []
        }
      )
      expect(br.max).to be_nil
      expect(br.pct_display).to eq("N/A")
      expect(br.worst).to eq([])
    end
  end

  describe ".blast_radius_from_findings (legacy opaque path)" do
    it "resolves worst-entry node ids via the id-map join (multiplexer precedent)" do
      resolver = Archbuddy::Report::Reconnect::IdMapResolver.new(
        "ids" => { "n_1" => { "symbol" => "Billing::Invoice#total", "file" => "a.rb", "line" => 1 } }
      )
      doc = { "scores" => { "blast_radius" => blast_block.merge(
        "worst" => [{ "node" => "n_1", "use_cases_affected" => 9, "added_coupling" => nil }]
      ) } }
      br = S.blast_radius_from_findings(doc, resolver)
      expect(br.worst.first.symbol).to eq("Billing::Invoice#total")
      expect(br.worst.first.added_coupling).to be_nil
    end

    it "returns nil when the findings doc has no scores block" do
      expect(S.blast_radius_from_findings({}, nil)).to be_nil
      expect(S.blast_radius_from_findings({ "scores" => {} }, nil)).to be_nil
    end
  end

  describe "depth + branching-factor parsers (flat spellings, guard R1)" do
    it "returns nil on absent/empty blocks" do
      expect(S.forward_depth_from_aggregate({})).to be_nil
      expect(S.reverse_depth_from_aggregate(nil)).to be_nil
      expect(S.branching_factor_from_aggregate("branching_factor" => {})).to be_nil
    end

    it "parses forward_depth with by_category; max stays nil (C3 — not emitted in v0.11)" do
      fd = S.forward_depth_from_aggregate(
        "forward_depth" => { "mean" => 2.83, "median" => 2.0, "count" => 1611,
                             "by_category" => { "controllers" => { "mean" => 2.9, "median" => 2.0, "count" => 1200 } } }
      )
      expect(fd.mean).to eq(2.83)
      expect(fd.median).to eq(2.0)
      expect(fd.count).to eq(1611)
      expect(fd.max).to be_nil
      expect(fd.by_category).to have_key("controllers")
    end

    it "parses reverse_depth (no by_category — R9) and branching_factor (no grade member — L15)" do
      rd = S.reverse_depth_from_aggregate("reverse_depth" => { "mean" => 3.42, "median" => 3.0, "count" => 5506 })
      expect(rd.median).to eq(3.0)
      expect(rd.by_category).to be_nil

      bf = S.branching_factor_from_aggregate("branching_factor" => { "mean" => 2649.6, "median" => 2.416, "count" => 1611 })
      expect(bf.median).to eq(2.416)
      expect(bf).not_to respond_to(:grade)
    end

    it "legacy findings variants read the SAME flat keys under scores" do
      doc = { "scores" => {
        "forward_depth"    => { "mean" => 2.0, "median" => 2.0, "count" => 3 },
        "reverse_depth"    => { "mean" => 4.0, "median" => 4.0, "count" => 5 },
        "branching_factor" => { "mean" => 1.5, "median" => 1.5, "count" => 3 }
      } }
      expect(S.forward_depth_from_findings(doc).count).to eq(3)
      expect(S.reverse_depth_from_findings(doc).count).to eq(5)
      expect(S.branching_factor_from_findings(doc).median).to eq(1.5)
    end
  end

  describe "DimensionScore median/median_grade/capped_fraction (additive)" do
    it "parses the v3/1.6 keys when present" do
      dims = S.from_findings(
        { "scores" => { "reverse_traceability" => {
          "grade" => "F", "score" => 32_402.84, "median" => 1_000_000.0,
          "median_grade" => "F", "capped_fraction" => 0.9764
        } } }, nil
      )
      rev = dims.find { |d| d.key == "reverse_traceability" }
      expect(rev.median).to eq(1_000_000.0)
      expect(rev.median_grade).to eq("F")
      expect(rev.capped_fraction).to eq(0.9764)
    end

    it "is nil on v2/1.5-shaped docs (additive back-compat, never fabricated)" do
      dims = S.from_findings(
        { "scores" => { "reverse_traceability" => { "grade" => "C", "score" => 61.0 } } }, nil
      )
      rev = dims.find { |d| d.key == "reverse_traceability" }
      expect(rev.median).to be_nil
      expect(rev.median_grade).to be_nil
      expect(rev.capped_fraction).to be_nil
    end
  end

  describe "Egress cost fields + shared CostLineDisplay" do
    it "parses the v3 egress cost keys (mirrors entrypoints spellings)" do
      eg = S.egress_from_aggregate(
        "egress" => {
          "total" => 710, "count" => 710,
          "by_category" => { "http" => 6, "gem" => 702, "queue" => 2, "generic" => 0 },
          "mean" => 130.5, "median" => 44.0, "capped_fraction" => 0.0,
          "by_category_cost" => { "gem" => { "mean" => 120.0, "median" => 40.0, "grade" => "C",
                                             "median_grade" => "B", "capped_fraction" => 0.0 } }
        }
      )
      expect(eg.mean).to eq(130.5)
      expect(eg.median_display).to eq("44.0")
      expect(eg.capped_fraction).to eq(0.0)
      # v0.11: the 1.6 secondary letter rides INSIDE the grade parens
      expect(eg.by_category_cost_display).to eq("gem mean 120.0 / median 40.0 (C, median: B)")
    end

    it "keeps v2 egress docs nil-cost (back-compat) and the v0.10 grade-only rendering byte-identical" do
      eg = S.egress_from_aggregate(
        "egress" => { "total" => 1, "count" => 1,
                      "by_category" => { "http" => 0, "gem" => 1, "queue" => 0, "generic" => 0 } }
      )
      expect(eg.mean).to be_nil
      expect(eg.by_category_cost_display).to be_nil

      ep = S::EntrypointCount.new(
        total: 4, count: 4, by_category: {},
        by_category_cost: { "controllers" => { "mean" => 30.0, "median" => 14.0, "grade" => "C" } }
      )
      expect(ep.by_category_cost_display).to eq("controllers mean 30.0 / median 14.0 (C)")
    end

    it "parses entrypoints.capped_fraction (nil on v2 docs)" do
      ep = S.entrypoints_from_aggregate(
        "entrypoints" => { "total" => 1, "count" => 1, "by_category" => {},
                           "capped_fraction" => 0.0214 }
      )
      expect(ep.capped_fraction).to eq(0.0214)

      v2 = S.entrypoints_from_aggregate("entrypoints" => { "total" => 1, "count" => 1, "by_category" => {} })
      expect(v2.capped_fraction).to be_nil
    end
  end
end
