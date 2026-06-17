# frozen_string_literal: true

require "archbuddy/report"
require "archbuddy/report/reconnect"
require "archbuddy/report/ranker"
require "archbuddy/report/formatter"
require "architecture_auditor"

# R-6 (open/closed): the OFFLINE Cytoscape.js `html` formatter. A single
# self-contained .html dashboard: project dimension scores (cards), an
# interactive call graph (when --graph is supplied), and a ranked bottleneck
# table. The output carries real symbols → SECRET/local-only (never committed).
RSpec.describe Archbuddy::Report::Formatters::HtmlFormatter do
  let(:fixtures)    { File.expand_path("../fixtures/report", __dir__) }
  let(:id_map_yml)  { File.join(fixtures, "id_map_fixture.yml") }
  let(:graph_yml)   { File.join(fixtures, "graph_fixture.yml") }
  let(:graph_doc)   { ArchitectureAuditor::Contract::Serializer.load(graph_yml) }

  # 1.1 findings (has the project `scores` block + hotspots).
  let(:v11_yml) { File.join(fixtures, "findings_v11_fixture.yml") }
  # 1.0 findings (no scores block) for back-compat coverage.
  let(:v10_yml) { File.join(fixtures, "findings_fixture.yml") }
  # forward N/A (null forward score → honest N/A render).
  let(:na_yml)  { File.join(fixtures, "findings_v11_forward_na_fixture.yml") }

  def result_for(findings)
    Archbuddy::Report::Reconnect.from_files(
      findings_path: findings, id_map_path: id_map_yml
    ).call
  end

  def render(findings:, graph: nil)
    result = result_for(findings)
    ranker = Archbuddy::Report::Ranker.new(result)
    context = Archbuddy::Report::Formatter::RenderContext.new(
      ranked:        ranker.ranked,
      class_rollups: ranker.class_rollups,
      generator:     result.findings_doc["generator"],
      graph:         graph,
      resolver:      Archbuddy::Report::Reconnect::IdMapResolver.new(result.id_map),
      scores:        result.scores
    )
    Archbuddy::Report::Formatter.for("html").new(context).render
  end

  # --- registry ---------------------------------------------------------------

  it "registers under the `html` format name" do
    expect(Archbuddy::Report::Formatter.registered).to include("html")
    expect(Archbuddy::Report::Formatter.for("html")).to eq(described_class)
  end

  # --- full dashboard (scores + graph) ----------------------------------------

  context "with --graph and a 1.1 scores block" do
    subject(:html) { render(findings: v11_yml, graph: graph_doc) }

    it "is non-empty, valid-ish self-contained HTML" do
      expect(html).to start_with("<!DOCTYPE html>")
      expect(html).to include("<html").and include("</html>")
      expect(html).to include('<div id="cy">')                       # cytoscape container
      expect(html).to include('<script id="archbuddy-data"')         # inlined data JSON
    end

    it "inlines the real Cytoscape.js library (offline)" do
      # The vendored library's source comment + the factory call are present.
      expect(html).to include("Cytoscape")
      expect(html).to include("cytoscape({")
      # The inlined lib is large — proves it's the real file, not a stub.
      expect(html.bytesize).to be > 200_000
    end

    # KEY OFFLINE GUARANTEE: zero external resource references.
    it "has ZERO external resource references" do
      expect(html).not_to include('src="http')
      expect(html).not_to include('src="//')
      expect(html).not_to include('href="http')
      expect(html).not_to include('href="//')
      expect(html).not_to match(%r{//cdn})
      expect(html).not_to include("unpkg")
      expect(html).not_to include("cdnjs")
    end

    it "shows BOTH dimension scores and their grades" do
      expect(html).to include("Reverse Traceability")
      expect(html).to include("Forward Discoverability")
      expect(html).to include("58/100")
      expect(html).to include(">D<")          # reverse grade
      expect(html).to include("72/100")
      expect(html).to include(">C<")          # forward grade
    end

    it "de-anonymizes real symbols AND file:line" do
      expect(html).to include("Billing#charge")
      expect(html).to include("OrdersController#create")
      expect(html).to include("app/services/billing.rb")
      expect(html).to include("app/services/billing.rb:8")
    end

    it "renders the ranked bottleneck table verbatim (no recompute)" do
      expect(html).to include("Ranked Bottlenecks")
      # OrdersController#create ranks first (clutter 9.5); the absurd fan_in 42
      # from the fixture must appear verbatim.
      expect(html).to match(/OrdersController#create/)
      expect(html).to include("42")          # verbatim fan_in for Billing#charge
      expect(html).to include("9.5000")      # verbatim top clutter_score
    end

    it "embeds graph nodes + edges as inlined JSON data" do
      json_blob = html[/<script id="archbuddy-data"[^>]*>(.*?)<\/script>/m, 1]
      expect(json_blob).not_to be_nil
      data = JSON.parse(json_blob.gsub('<\/', "</"))
      expect(data["nodes"].map { |n| n["id"] }).to include("n_e188e5adb49f")
      expect(data["edges"]).to include("from" => "n_9806809c4b1f", "to" => "n_4452f2ecaf84", "calls" => 3)
      # de-anonymized symbol carried on the node datum
      charge = data["nodes"].find { |n| n["id"] == "n_e188e5adb49f" }
      expect(charge["symbol"]).to eq("Billing#charge")
      expect(charge["metrics"]["fan_in"]).to eq(42)   # verbatim
    end

    it "exposes hotspot ids per dimension for the highlight buttons" do
      expect(html).to include("Highlight Reverse Traceability hotspots")
      json_blob = html[/<script id="archbuddy-data"[^>]*>(.*?)<\/script>/m, 1]
      data = JSON.parse(json_blob.gsub('<\/', "</"))
      expect(data["hotspots"]["reverse_traceability"]).to include("n_e188e5adb49f")
    end
  end

  # --- ext_/missing id graceful de-anon on a graph node -----------------------

  it "renders an ext_/missing id graph node as a graceful <external …>" do
    html = render(findings: v11_yml, graph: graph_doc)
    json_blob = html[/<script id="archbuddy-data"[^>]*>(.*?)<\/script>/m, 1]
    data = JSON.parse(json_blob.gsub('<\/', "</"))
    ext = data["nodes"].find { |n| n["id"] == "ext_e4c31576a772" }
    expect(ext).not_to be_nil
    expect(ext["resolved"]).to be(false)
    expect(ext["symbol"]).to include("<external")
  end

  # --- no-graph degradation ---------------------------------------------------

  context "without --graph" do
    subject(:html) { render(findings: v11_yml, graph: nil) }

    it "still renders scores + table + a visible notice, no crash" do
      expect(html).to start_with("<!DOCTYPE html>")
      expect(html).to include("Reverse Traceability")     # scores still render
      expect(html).to include("Ranked Bottlenecks")       # table still renders
      expect(html).to include("Billing#charge")
      expect(html).to include("pass --graph graph.yml")   # the notice
      expect(html).not_to include('<div id="cy">')        # no network graph
    end

    it "is still fully offline" do
      expect(html).not_to include('src="http')
      expect(html).not_to include("cdnjs")
    end
  end

  # --- forward N/A honesty ----------------------------------------------------

  it "renders an N/A forward dimension honestly with its reason" do
    html = render(findings: na_yml, graph: graph_doc)
    expect(html).to include("Forward Discoverability")
    expect(html).to include("N/A")
    expect(html).to include("no entrypoints")
  end

  # --- 1.0 back-compat (no scores block) --------------------------------------

  it "renders without a scores header for a 1.0 doc (back-compat, no crash)" do
    html = render(findings: v10_yml, graph: graph_doc)
    expect(html).to start_with("<!DOCTYPE html>")
    expect(html).to include("Ranked Bottlenecks")
    expect(html).not_to include("Project Scores")
    expect(html).to include("Billing#charge")
  end
end
