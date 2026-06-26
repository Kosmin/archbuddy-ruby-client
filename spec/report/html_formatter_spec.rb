# frozen_string_literal: true

require "archbuddy/report"
require "archbuddy/report/reconnect"
require "archbuddy/report/ranker"
require "archbuddy/report/formatter"
require "archbuddy/report/model"
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
      expect(html).to include("cost 58.0")
      expect(html).to include(">D<")          # reverse grade
      expect(html).to include("cost 72.0")
      expect(html).to include(">C<")          # forward grade
      # The score cards must not use "/100" — check the scores section only
      # (the inlined Cytoscape.js vendor asset may contain "/100" in its math).
      scores_section = html[/<section id="scores">(.*?)<\/section>/m, 1]
      expect(scores_section).not_to include("/100")
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

  # --- init-script source ordering (regression: blocking runtime JS bug) ------
  #
  # The node `background-color` style callback calls `byId(...)` during the
  # INITIAL Cytoscape style pass. `var` hoists the declaration but not the
  # assignment, so if `nodeIndex`/`byId` are defined AFTER the `cytoscape({...})`
  # constructor, the callback throws `TypeError: Cannot read properties of
  # undefined` on first paint and nodes never get a metric-driven fill until a
  # control fires `recolor()`. This cheap string-index check fails if anyone
  # reintroduces that ordering bug.
  context "init script source ordering (no first-paint TypeError)" do
    subject(:html) { render(findings: v11_yml, graph: graph_doc) }

    it "defines nodeIndex/byId BEFORE the cytoscape({...}) constructor call" do
      idx_pos    = html.index("var nodeIndex")
      byid_pos   = html.index("function byId")
      cyto_pos   = html.index("cytoscape({")
      expect(idx_pos).not_to be_nil
      expect(byid_pos).not_to be_nil
      expect(cyto_pos).not_to be_nil
      expect(idx_pos).to be < cyto_pos
      expect(byid_pos).to be < cyto_pos
    end

    it "does not redeclare nodeIndex/byId after the constructor (no shadow)" do
      cyto_pos = html.index("cytoscape({")
      after    = html[cyto_pos..]
      expect(after).not_to include("var nodeIndex")
      expect(after).not_to include("function byId")
    end
  end

  # --- table: sortable headers + pagination controls --------------------------
  context "ranked bottleneck table: sort + pagination controls" do
    subject(:html) { render(findings: v11_yml, graph: graph_doc) }

    it "renders sortable header cells with sort-key/type metadata + a click handler hook" do
      # clutter_score + each metric + symbol/file/kind are sortable.
      %w[clutter_score centrality fan_in fan_out path_length].each do |key|
        expect(html).to include(%(data-sort-key="#{key}"))
      end
      expect(html).to include('data-sort-key="symbol"')
      expect(html).to include('data-sort-key="file_line"')
      expect(html).to include('data-sort-key="kind"')
      expect(html).to include('class="sortable"')
      # The JS wires a click handler onto every sortable header and toggles dir.
      expect(html).to include("th.onclick")
      expect(html).to include("sortDir === 'asc' ? '▼' : '▲'").or include("sortDir === 'asc' ? '▲' : '▼'")
    end

    it "defaults to clutter_score descending (current behavior) in the sort state" do
      expect(html).to include("var sortKey = 'clutter_score'")
      expect(html).to include("var sortDir = 'desc'")
    end

    it "renders a page-size selector (25/50/100/All, default 25) + Prev/Next + range indicator" do
      expect(html).to include('id="sel-page-size"')
      expect(html).to include('<option value="25">25</option>')
      expect(html).to include('<option value="50">50</option>')
      expect(html).to include('<option value="100">100</option>')
      expect(html).to include('<option value="all">All</option>')
      expect(html).to include('id="tbl-prev"')
      expect(html).to include('id="tbl-next"')
      expect(html).to include('id="tbl-range"')
      expect(html).to include("var pageSize = 25")
      # the "showing X–Y of Z" indicator text is produced by the JS
      expect(html).to include("'showing '")
    end

    it "sorts null/N/A metric values LAST regardless of direction" do
      # the comparator forces nulls last in both asc and desc
      expect(html).to include("if (av === null) return 1;")
      expect(html).to include("if (bv === null) return -1;")
    end

    it "renders the page client-side without dumping all rows visible at once" do
      # render() detaches all rows then re-appends only the current page slice
      expect(html).to include("tbody.appendChild(ordered[i])")
      expect(html).to include("tr.parentNode.removeChild(tr)")
    end
  end

  # --- graph: minimum clutter-score filter ------------------------------------
  context "call graph: minimum clutter-score filter" do
    subject(:html) { render(findings: v11_yml, graph: graph_doc) }

    it "renders a range slider + synced number input + live count element" do
      expect(html).to include('id="rng-minscore"')
      expect(html).to include('type="range"')
      expect(html).to include('id="num-minscore"')
      expect(html).to include('type="number"')
      expect(html).to include('id="minscore-count"')
    end

    it "shows a live 'showing N of M nodes' count" do
      expect(html).to include("' of ' + totalNodes + ' nodes")
    end

    it "applies a focused default threshold heuristic (top ~120 by clutter)" do
      expect(html).to include("DEFAULT_FOCUS_COUNT = 120")
      expect(html).to include("var defaultThreshold")
      # the slider/number input start AT the default threshold (focused view)
      expect(html).to include("rng.value = defaultThreshold")
      expect(html).to include("numIn.value = defaultThreshold")
    end

    it "hides below-threshold nodes and their incident edges (reversible)" do
      expect(html).to include("addClass('filtered-out')")
      expect(html).to include("removeClass('filtered-out')")
      expect(html).to include("'display': 'none'")
      # incident-edge hide
      expect(html).to include("s.hasClass('filtered-out') || t.hasClass('filtered-out')")
    end

    it "debounces re-layout while dragging the slider" do
      expect(html).to include("clearTimeout(layoutTimer)")
      expect(html).to include("setTimeout(function")
    end

    it "handles a threshold above all scores gracefully (no nodes message, no crash)" do
      expect(html).to include("no nodes ≥ ")
    end
  end

  # --- adversarial escaping (locks in injection-proof output) -----------------
  #
  # The output carries real symbols + paths. An adversarial symbol/path with
  # `< > & " '` and a literal `</script>` must NOT be able to break out of the
  # table markup OR close the inlined <script type="application/json"> blob.
  context "with an adversarial symbol/path (escaping is injection-proof)" do
    # A literal </script> + angle brackets + entity chars + unicode. If escaping
    # regressed, the raw </script> would prematurely close the JSON island and
    # the <script>/<img onerror> would render as live markup.
    let(:evil_symbol) { %(Evil</script><img src=x onerror=alert(1)>#hack & "q" 'q' ✓) }
    let(:evil_path)   { %(app/<b>evil</b>.rb) }

    let(:evil_location) do
      Archbuddy::Report::Model::Location.new(
        id: "n_evil", file: evil_path, line: 13, symbol: evil_symbol,
        kind: "function", class_id: nil, resolved: true
      )
    end

    let(:evil_bottleneck) do
      Archbuddy::Report::Model::Bottleneck.new(
        id: "n_evil", location: evil_location, kind: "function", class_id: nil,
        metrics: { "fan_in" => 1, "fan_out" => 2, "centrality" => 0.5, "path_length" => 3 },
        clutter_score: 7.0, findings: []
      )
    end

    let(:evil_resolver) do
      resolver = Object.new
      loc = evil_location
      resolver.define_singleton_method(:resolve) { |_id| loc }
      resolver
    end

    let(:evil_graph) do
      { "nodes" => [{ "id" => "n_evil", "kind" => "function" }], "edges" => [] }
    end

    subject(:html) do
      context = Archbuddy::Report::Formatter::RenderContext.new(
        ranked: [evil_bottleneck], class_rollups: [], generator: { "tool" => "x" },
        graph: evil_graph, resolver: evil_resolver, scores: nil
      )
      Archbuddy::Report::Formatter.for("html").new(context).render
    end

    # Scope to the bottleneck table section: the symbol/path is interpolated as
    # live HTML there, so it MUST be entity-escaped. (Inside the JSON island the
    # same string is inert text guarded only by the `</` neutralization — tested
    # separately below — so a raw `<img>` is expected and safe there.)
    let(:table_section) { html[/<section id="table">(.*?)<\/section>/m, 1] }

    it "HTML-escapes the symbol/path in the table (no live <script>/<img> markup)" do
      expect(table_section).not_to be_nil
      # The dangerous markup never appears raw in the live table…
      expect(table_section).not_to include("<img src=x onerror=alert(1)>")
      expect(table_section).not_to include("<b>evil</b>")
      # …it appears entity-escaped instead.
      expect(table_section).to include("&lt;img src=x onerror=alert(1)&gt;")
      expect(table_section).to include("&lt;b&gt;evil&lt;/b&gt;")
      expect(table_section).to include("&amp;").and include("&quot;").and include("&#39;")
    end

    it "neutralizes </script> inside the inlined JSON island (stays inert)" do
      json_blob = html[/<script id="archbuddy-data"[^>]*>(.*?)<\/script>/m, 1]
      expect(json_blob).not_to be_nil
      # No raw `</` survives in the island — every one is written as `<\/`.
      expect(json_blob).not_to include("</")
      expect(json_blob).to include('<\/script>')
      # And it's still valid JSON once the neutralization is reversed.
      data = JSON.parse(json_blob.gsub('<\/', "</"))
      node = data["nodes"].find { |n| n["id"] == "n_evil" }
      expect(node["symbol"]).to eq(evil_symbol)
    end
  end
end
