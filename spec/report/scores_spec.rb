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
          "mean" => nil, "median" => nil
        }
      )
      expect(ep.total).to eq(4)
      expect(ep.count).to eq(4)
      expect(ep.by_category).to eq("controllers" => 3, "top_level" => 1, "jobs" => 0)
      expect(ep.mean).to be_nil
      expect(ep.median).to be_nil
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

    it "renders an honest '(none)' when every bucket is zero (distinct from absence)" do
      ep = described_class.new(
        total: 0, count: 0, by_category: { "controllers" => 0, "jobs" => 0 }
      )
      expect(ep.by_category_display).to eq("(none)")
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

    it "parses the coverage tuple verbatim" do
      dd = Scores.dynamic_dispatch_from_aggregate(
        "dynamic_dispatch" => {
          "dynamic_sites" => 3, "resolved_sites" => 7,
          "total_call_sites" => 100, "ratio" => 0.42
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
