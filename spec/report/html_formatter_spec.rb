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
  # 1.3 findings (scores + connectivity block, four-field CR-1 shape).
  let(:v13_yml) { File.join(fixtures, "findings_v13_connectivity_fixture.yml") }
  # 1.0 findings (no scores block) for back-compat coverage.
  let(:v10_yml) { File.join(fixtures, "findings_fixture.yml") }
  # forward N/A (null forward score → honest N/A render).
  let(:na_yml)  { File.join(fixtures, "findings_v11_forward_na_fixture.yml") }

  def result_for(findings)
    Archbuddy::Report::Reconnect.from_files(
      findings_path: findings, id_map_path: id_map_yml
    ).call
  end

  def render(findings:, graph: nil, max_nodes: nil, entrypoints: nil, egress: nil, dynamic_dispatch: nil,
             blast_radius: nil, forward_depth: nil, reverse_depth: nil, branching_factor: nil,
             variety_mass: nil)
    result = result_for(findings)
    ranker = Archbuddy::Report::Ranker.new(result)
    context = Archbuddy::Report::Formatter::RenderContext.new(
      ranked:        ranker.ranked,
      class_rollups: ranker.class_rollups,
      generator:     result.findings_doc["generator"],
      graph:         graph,
      resolver:      Archbuddy::Report::Reconnect::IdMapResolver.new(result.id_map),
      scores:        result.scores,
      connectivity:  result.connectivity,
      max_nodes:     max_nodes,
      # v0.10 (W4): the three committed counter blocks (nil = v1 aggregate).
      entrypoints:      entrypoints,
      egress:           egress,
      dynamic_dispatch: dynamic_dispatch,
      # v0.11 (W-C): the four business-metric blocks (nil = pre-1.6 doc).
      blast_radius:     blast_radius,
      forward_depth:    forward_depth,
      reverse_depth:    reverse_depth,
      branching_factor: branching_factor,
      # v0.12 (W-CLI-B): the fifth (nil = pre-v4/pre-1.7 doc).
      variety_mass:     variety_mass
    )
    Archbuddy::Report::Formatter.for("html").new(context).render
  end

  def graph_data(html)
    blob = html[/<script id="archbuddy-data"[^>]*>(.*?)<\/script>/m, 1]
    JSON.parse(blob.gsub('<\/', "</"))
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

  # --- external sinks are EXCLUDED from the graph viz -------------------------
  # v0.8.1: <external> sink nodes (kind "external" / ext_ ids) are the app's
  # boundary — they carry no findings and their high fan-in rendered as giant
  # converging wedges over opaque `<external …>` labels. They are excluded from
  # the graph node set (their inbound edges drop with them). They still appear in
  # the findings/scores — this is a VIZ-only exclusion.

  it "excludes ext_/external sink nodes from the graph viz" do
    html = render(findings: v11_yml, graph: graph_doc)
    json_blob = html[/<script id="archbuddy-data"[^>]*>(.*?)<\/script>/m, 1]
    data = JSON.parse(json_blob.gsub('<\/', "</"))
    expect(data["nodes"].find { |n| n["id"] == "ext_e4c31576a772" }).to be_nil
    # No true external-SINK id (ext_) survives in the graph node set. (An unresolved
    # real `n_` node may still carry the "external" fallback KIND — that's a display
    # label, not a sink; the sink-id exclusion is what kills the fan-in flood.)
    expect(data["nodes"].none? { |n| n["id"].to_s.start_with?("ext_") }).to be(true)
    # ...and its inbound edges drop with it (no edge references the excluded id)
    expect(data["edges"].none? { |e| e["from"] == "ext_e4c31576a772" || e["to"] == "ext_e4c31576a772" }).to be(true)
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

  # --- connectivity banner (findings 1.3, CR-1 four-field schema) -------------

  context "with a 1.3 connectivity block" do
    subject(:html) { render(findings: v13_yml, graph: nil) }

    it "renders a <div class='connectivity'> inside the scores section" do
      expect(html).to include('<div class="connectivity">')
    end

    it "contains the connectivity banner text with scored_nodes/total_nodes and percent" do
      expect(html).to include("Connectivity: 5/1672 nodes scored (0.3%)")
    end

    it "positions the connectivity banner BEFORE the dimension cards" do
      # v0.11: scoped to the scores section — the Business Impact PEER section
      # (which reuses .cards) now legitimately renders earlier on a
      # scores-bearing doc; the scores section's own shape is unchanged.
      scores_section = html[%r{<section id="scores">.*?</section>}m]
      conn_pos  = scores_section.index('<div class="connectivity">')
      cards_pos = scores_section.index('<div class="cards">')
      expect(conn_pos).not_to be_nil
      expect(cards_pos).not_to be_nil
      expect(conn_pos).to be < cards_pos
    end

    it "does NOT render a connectivity div for a 1.1 doc (no connectivity key)" do
      html_v11 = render(findings: v11_yml, graph: nil)
      expect(html_v11).not_to include('<div class="connectivity">')
    end

    it "HTML-escapes the connectivity banner text (trust boundary)" do
      # Verify via a synthetic Connectivity with adversarial text
      evil_conn = Archbuddy::Report::Scores::Connectivity.new(
        forward: 0.5, reverse: nil, scored_nodes: 1, total_nodes: 2
      )
      result = result_for(v11_yml)
      ranker = Archbuddy::Report::Ranker.new(result)
      context = Archbuddy::Report::Formatter::RenderContext.new(
        ranked: ranker.ranked, class_rollups: ranker.class_rollups,
        generator: result.findings_doc["generator"], graph: nil,
        resolver: Archbuddy::Report::Reconnect::IdMapResolver.new(result.id_map),
        scores: result.scores, connectivity: evil_conn
      )
      rendered = Archbuddy::Report::Formatter.for("html").new(context).render
      expect(rendered).to include('<div class="connectivity">')
      # The banner text is escape()d — no raw < or > may appear inside it
      conn_section = rendered[/<div class="connectivity">(.*?)<\/div>/m, 1]
      expect(conn_section).not_to include("<")
      expect(conn_section).not_to include(">")
    end
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

    it "renders a page-size selector (10/30/All, default 10) + Prev/Next + range indicator" do
      expect(html).to include('id="sel-page-size"')
      expect(html).to include('<option value="10">10</option>')
      expect(html).to include('<option value="30">30</option>')
      expect(html).to include('<option value="all">All</option>')
      expect(html).to include('id="tbl-prev"')
      expect(html).to include('id="tbl-next"')
      expect(html).to include('id="tbl-range"')
      expect(html).to include("var pageSize = 10")
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

  # --- polish (v0.9.1): top-N offenders shared by graph + list ----------------
  # The min-score slider is gone (the graph is scoped to the top-N offenders
  # server-side), and --max-nodes now caps BOTH the graph node set AND the
  # bottleneck list to the SAME worst-N, so the two views agree.
  context "top-N offenders cap (graph + list share one --max-nodes knob)" do
    it "removed the min-score slider + its heuristic entirely" do
      html = render(findings: v11_yml, graph: graph_doc)
      expect(html).not_to include('id="rng-minscore"')
      expect(html).not_to include('id="num-minscore"')
      expect(html).not_to include("DEFAULT_FOCUS_COUNT")
      expect(html).not_to include("applyMinScore")
      expect(html).not_to include("filtered-out")
    end

    it "caps the LIST to the top N and titles both sections 'Top N Offenders'" do
      html = render(findings: v11_yml, graph: graph_doc, max_nodes: 2)
      # only the top-2 rows are server-rendered (data-node <tr> count)
      rows = html.scan(/<tr data-node=/).size
      expect(rows).to eq(2)
      # both sections advertise the top-N framing
      expect(html).to include("Top 2 Offenders (by clutter_score)")
      expect(html).to include("Top 2 Offenders — Call Graph")
      # and the data blob's bottlenecks are capped to the same N
      data = graph_data(html)
      expect(data["bottlenecks"].size).to eq(2)
    end

    it "graph node set and list rows are the SAME top-N (agree)" do
      html = render(findings: v11_yml, graph: graph_doc, max_nodes: 2)
      data = graph_data(html)
      list_ids  = html.scan(/<tr data-node="([^"]+)"/).flatten.sort
      graph_ids = data["nodes"].map { |n| n["id"] }.sort
      expect(list_ids).to eq(graph_ids)
    end

    it "shows all offenders (no cap) when max_nodes is 0/nil, keeping the legacy titles" do
      html = render(findings: v11_yml, graph: graph_doc, max_nodes: 0)
      expect(html).to include("Ranked Bottlenecks (by clutter_score)")
      expect(html).to include("Call Graph")
    end

    it "no longer renders the standalone Multiplexer Proxy Smell section" do
      html = render(findings: v11_yml, graph: graph_doc)
      expect(html).not_to include("Multiplexer Proxy Smell")
    end

    # Node size must be LOG-scaled + capped: on the from-cache path clutter is
    # added_coupling (can be ~1e8), and the old linear `20 + clutter*4` made the
    # worst node a screen-filling blob that collapsed the layout.
    it "bounds node size (log-scaled + capped), never linear in clutter" do
      html = render(findings: v11_yml, graph: graph_doc)
      expect(html).to include("function sizeFor(clutter)")
      expect(html).to include("size: sizeFor(n.clutter_score)")
      expect(html).not_to include("size: 20 + num(n.clutter_score) * 4")
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
        graph: evil_graph, resolver: evil_resolver, scores: nil, connectivity: nil
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

  # --max-nodes: cap the graph-viz node set (top N by clutter score) so a huge
  # graph doesn't crash the browser on initial render. Fixture = 6 nodes / 3 edges.
  context "with --max-nodes capping the graph node set" do
    it "renders only the top N nodes by score and drops edges to dropped nodes" do
      data = graph_data(render(findings: v11_yml, graph: graph_doc, max_nodes: 2))

      expect(data["nodes"].size).to eq(2)
      expect(data["node_cap"]).to eq("shown" => 2, "total" => 5)
      # every surviving edge references only surviving nodes (no dangling endpoints)
      kept = data["nodes"].map { |n| n["id"] }
      data["edges"].each do |e|
        expect(kept).to include(e["from"]).and include(e["to"])
      end
    end

    it "keeps the highest-clutter nodes (cap orders by score, not graph order)" do
      full   = graph_data(render(findings: v11_yml, graph: graph_doc)) # uncapped
      top1   = graph_data(render(findings: v11_yml, graph: graph_doc, max_nodes: 1))
      scored = full["nodes"].select { |n| n["clutter_score"] }
                            .max_by { |n| n["clutter_score"] }
      expect(top1["nodes"].map { |n| n["id"] }).to eq([scored["id"]])
    end

    it "shows an honest 'top N of M' banner only when actually capped" do
      capped = render(findings: v11_yml, graph: graph_doc, max_nodes: 2)
      expect(capped).to include("top 2 of 5 nodes")

      uncapped = render(findings: v11_yml, graph: graph_doc, max_nodes: 0)
      expect(uncapped).not_to include("nodes by clutter score")
    end

    it "renders all nodes when the cap is 0 (unlimited) or >= node count" do
      all_zero = graph_data(render(findings: v11_yml, graph: graph_doc, max_nodes: 0))
      all_big  = graph_data(render(findings: v11_yml, graph: graph_doc, max_nodes: 999))
      expect(all_zero["nodes"].size).to eq(5) # 6 fixture nodes − 1 excluded external sink
      expect(all_zero["node_cap"]).to be_nil
      expect(all_big["nodes"].size).to eq(5)
    end
  end

  # --- v0.10 (W4): the three committed counter banners --------------------------
  #
  # A SERIALIZER-v2 aggregate carries `entrypoints`/`egress`/`dynamic_dispatch`;
  # the HTML header renders each as a `<div>` banner beside connectivity. A v1
  # doc parses all three to nil → NO banner markup, header byte-identical to
  # pre-v0.10 (the banners join into the ONE former connectivity interpolation).
  describe "v0.10 counter banners (W4)" do
    let(:scores_mod) { Archbuddy::Report::Scores }
    let(:entrypoints) do
      scores_mod::EntrypointCount.new(
        total: 4, count: 4,
        by_category: { "controllers" => 3, "jobs" => 1, "rake" => 0 },
        mean: 27.14, median: 12.0
      )
    end
    let(:egress) do
      scores_mod::Egress.new(total: 5, count: 5,
                             by_category: { "http" => 2, "gem" => 3, "queue" => 0, "generic" => 0 })
    end
    let(:dynamic_dispatch) do
      scores_mod::DynamicDispatch.new(dynamic_sites: 2, resolved_sites: 8,
                                      total_call_sites: 10, ratio: 0.8)
    end

    it "renders all three banner divs on a v2 aggregate (beside connectivity)" do
      html = render(findings: v13_yml, entrypoints: entrypoints, egress: egress,
                    dynamic_dispatch: dynamic_dispatch)

      expect(html).to include('<div class="connectivity">')
      expect(html).to include('<div class="entrypoints">Entrypoints: 4 total ' \
                              "(controllers 3, jobs 1) — mean 27.1, median 12.0</div>")
      expect(html).to include('<div class="egress">Egress: 5 total (http 2, gem 3)</div>')
      expect(html).to include('<div class="dynamic-dispatch">Dynamic dispatch: ' \
                              "8/10 resolved, 2 dynamic (coverage 80.0%)</div>")
    end

    # v0.10 W6: the per-category cost div — appended ONLY when the engine
    # published the findings-1.5 lens (absent → byte-identical to pre-W6).
    it "renders the entrypoints-cost div when by_category_cost is present (W6)" do
      ep = scores_mod::EntrypointCount.new(
        total: 4, count: 4, by_category: { "controllers" => 3, "jobs" => 1 },
        mean: 27.14, median: 12.0,
        by_category_cost: {
          "controllers" => { "mean" => 30.0, "median" => 14.0, "grade" => "C" }
        }
      )
      html = render(findings: v13_yml, entrypoints: ep)

      expect(html).to include(
        '<div class="entrypoints-cost">Entrypoint cost by category: ' \
        "controllers mean 30.0 / median 14.0 (C)</div>"
      )
    end

    it "emits NO entrypoints-cost div when the lens is absent (pre-W6 docs byte-identical)" do
      html = render(findings: v13_yml, entrypoints: entrypoints)
      expect(html).not_to include('class="entrypoints-cost"')
    end

    it "renders the banners on a COLLECT-ONLY aggregate (no scores — relaxed gate, empty cards)" do
      html = render(findings: v10_yml, entrypoints: entrypoints, egress: egress)

      expect(html).to include('<section id="scores">')
      expect(html).to include('<div class="entrypoints">')
      expect(html).to include('<div class="egress">')
      expect(html).to include('<div class="cards"></div>') # no dimension cards yet
    end

    it "renders NO banner markup on a v1 doc and keeps the header shape byte-stable" do
      html = render(findings: v13_yml)

      expect(html).not_to include('class="entrypoints"')
      expect(html).not_to include('class="egress"')
      expect(html).not_to include('class="dynamic-dispatch"')
      # connectivity div is IMMEDIATELY followed by the cards div — no stray
      # blank lines / placeholders were introduced by the banner seam.
      expect(html).to match(
        %r{<h2>Project Scores</h2>\n  <div class="connectivity">[^<]*</div>\n  <div class="cards">}
      )
    end

    it "keeps a scores-less v1 doc header-free (returns no scores section at all)" do
      html = render(findings: v10_yml)
      expect(html).not_to include('<section id="scores">')
    end
  end

  # --- v0.11 (W-C T8): the Business Impact section -----------------------------
  #
  # A PEER `<section id="business-impact">` between the body header and Project
  # Scores, one .card per answerable question from the ONE shared presenter.
  # "" (no stray section tag) when zero questions are answerable, so v1/v2
  # no-data docs keep their pre-v0.11 shape. Worst-offender symbols are
  # trust-boundary text — everything dynamic goes through `escape`.
  describe "Business Impact section (W-C T8)" do
    let(:scores_mod) { Archbuddy::Report::Scores }
    let(:blast) do
      scores_mod::BlastRadius.new(
        max: 1569, p90: 3.0, median: 1.0, mean: 121.38,
        reached_nodes: 5506, total_nodes: 16_173, total_entrypoints: 1611,
        pct_use_cases_hit_by_worst: 0.9739,
        worst: [scores_mod::BlastRadius::Worst.new(symbol: "Router#dispatch",
                                                   use_cases_affected: 1569, added_coupling: 7.5)]
      )
    end
    let(:fwd_depth)  { scores_mod::DepthStats.new(mean: 2.83, median: 2.0, count: 1611) }
    let(:rev_depth)  { scores_mod::DepthStats.new(mean: 3.42, median: 3.0, count: 5506) }
    let(:branching)  { scores_mod::BranchingFactor.new(mean: 2649.6, median: 2.416, count: 1611) }

    it "renders the section with one card per question (6 on a full doc) before Project Scores" do
      html = render(findings: v13_yml, blast_radius: blast, forward_depth: fwd_depth,
                    reverse_depth: rev_depth, branching_factor: branching)
      section = html[%r{<section id="business-impact">.*?</section>}m]

      expect(section).not_to be_nil
      expect(section).to include("<h2>Business Impact</h2>")
      expect(section.scan('<div class="card">').size).to eq(6)
      # q3 answer verbatim from the presenter, escaped markup intact
      expect(section).to include(
        "the worst single node is reachable from 1569 of 1611 use cases (97.4%) — p90 3, median 1"
      )
      # graded rows (q1/q2 from the v13 fixture dims) reuse the color classes…
      expect(section).to include('<div class="grade grade-C">C</div>')
      expect(section).to include('<div class="grade grade-D">D</div>')
      # …ungraded rows never get a grade div (plain .score headline, L15)
      expect(section.scan('class="grade grade-').size).to eq(2)
      # peer-section ordering: BI before Project Scores
      expect(html.index('<section id="business-impact">'))
        .to be < html.index('<section id="scores">')
    end

    it "renders NO section on a v1/v2 no-data doc (no stray section tag)" do
      html = render(findings: v10_yml)
      expect(html).not_to include('<section id="business-impact">')
      expect(html).not_to include("Business Impact")
    end

    it "escapes a worst-offender symbol containing <script> (trust-boundary text)" do
      hostile = scores_mod::BlastRadius.new(
        max: 9, p90: 2.0, median: 1.0, mean: 1.5,
        reached_nodes: 3, total_nodes: 5, total_entrypoints: 9,
        pct_use_cases_hit_by_worst: 1.0,
        worst: [scores_mod::BlastRadius::Worst.new(symbol: "<script>alert(1)</script>#pwn",
                                                   use_cases_affected: 9, added_coupling: nil)]
      )
      html = render(findings: v10_yml, blast_radius: hostile)

      expect(html).not_to include("<script>alert(1)</script>")
      expect(html).to include("&lt;script&gt;alert(1)&lt;/script&gt;#pwn (9 use cases)")
    end

    # v0.12 W-CLI-B smoke: the VM detail line rides the q1 card through the
    # generic detail_lines rendering — ZERO formatter code change; plain text,
    # nothing new to escape.
    it "renders the v0.12 Variety+Mass detail line inside the q1 card (v4/1.7 context)" do
      vm = scores_mod::VarietyMass.new(
        score: 57.0, median: 57.0, count: 2,
        capped_fraction: 0.0, fallback_fraction: 0.5,
        variety: scores_mod::VarietyMass::Component.new(mean: 16.0, median: 16.0, count: 2),
        mass:    scores_mod::VarietyMass::Component.new(mean: 41.0, median: 41.0, count: 2)
      )
      html = render(findings: v13_yml, variety_mass: vm)
      section = html[%r{<section id="business-impact">.*?</section>}m]

      expect(section).not_to be_nil
      expect(section).to include(
        "variety + mass: complexity 57.0 = variety 16.0 + mass 41.0 (median 57.0)"
      )
    end
  end
end
