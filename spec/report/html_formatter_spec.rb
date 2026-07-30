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
             variety_mass: nil, reusability: nil)
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
      variety_mass:     variety_mass,
      # v0.13 (V13-C): the sixth (nil = pre-v5/pre-1.8 doc).
      reusability:      reusability
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

  # --- v0.13 (V13-C): the Reusability Compass section + node side panel --------
  #
  # The binding DATA ROUTE: fragment stamps → DetailTree passthrough →
  # graph_node_data whitelist → showNode rows. The compass section renders the
  # committed `reusability` block (VERBATIM engine figures, ADVISORY wording)
  # plus the quadrant lists grouped from the per-node stamps the reassembled
  # graph carries. Pre-v5/pre-1.8 docs render NO section (back-compat).
  describe "Reusability Compass section + side panel (v0.13 V13-C)" do
    let(:scores_mod) { Archbuddy::Report::Scores }
    let(:compass) do
      scores_mod::Reusability.new(
        reuse_index: scores_mod::Reusability::ReuseIndex.new(mean: 2.4, median: 1.0),
        unshared_fraction: 0.5,
        toll_booths: [scores_mod::Reusability::TollBooth.new(
          symbol: "LandingPageThemesController#content_block_type", blast: 4, mass_savings: 4
        )],
        extraction: [scores_mod::Reusability::Extraction.new(
          symbol: "Api::V1::LandingPageThemesController#build_style", collapse: 16.0, leverage: 32.0
        )],
        leverage: scores_mod::Reusability::LeverageStats.new(mean: 3.1, median: 2.0, count: 107)
      )
    end
    # A committed-shaped (real-name) graph whose nodes carry the v5 fragment
    # stamps — exactly what DetailTree#reassemble passes through wholesale.
    let(:stamped_graph) do
      {
        "nodes" => [
          { "id" => "Foo#booth", "symbol" => "Foo#booth", "kind" => "function",
            "leverage" => 1.0, "collapse" => 1.0, "toll_booth" => true, "quadrant" => "bypass_candidate" },
          { "id" => "Foo#core", "symbol" => "Foo#core", "kind" => "function",
            "leverage" => 4.0, "collapse" => 2.0, "toll_booth" => false, "quadrant" => "load_bearing" },
          { "id" => "Foo#plain", "symbol" => "Foo#plain", "kind" => "function",
            "leverage" => nil, "collapse" => nil, "toll_booth" => nil, "quadrant" => nil }
        ],
        "edges" => []
      }
    end

    it "renders the section: summary line, quadrant lists, advisory toll-booth + extraction tables" do
      html = render(findings: v10_yml, graph: stamped_graph, reusability: compass)
      section = html[%r{<section id="reusability-compass">.*?</section>}m]

      expect(section).not_to be_nil
      expect(section).to include("<h2>Reusability Compass</h2>")
      # summary — VERBATIM engine figures, display-formatted only
      expect(section).to include("Reuse index: mean 2.4 / median 1.0")
      expect(section).to include("unshared fraction 50.0%")
      expect(section).to include("leverage mean 3.1 / median 2.0")
      # quadrant lists grouped from the per-node stamps (display-only grouping)
      expect(section).to include("Bypass candidates (toll booths — advisory)")
      expect(section).to include("Load-bearing (protect the contract)")
      expect(section).to include("Foo#booth")
      expect(section).to include("Foo#core")
      # ADVISORY wording — candidates, never mandates
      expect(section).to include("Candidates, never mandates.")
      expect(section).not_to include("must bypass")
      # worst-lists verbatim
      expect(section).to include("LandingPageThemesController#content_block_type")
      expect(section).to include("Api::V1::LandingPageThemesController#build_style")
    end

    it "renders NO section on a pre-v5/pre-1.8 doc (nil block, unstamped graph — back-compat)" do
      html = render(findings: v10_yml, graph: graph_doc)
      expect(html).not_to include('<section id="reusability-compass">')
      expect(html).not_to include("Reusability Compass")
    end

    it "whitelists the four compass keys into the data blob; unstamped nodes carry honest nulls" do
      html = render(findings: v10_yml, graph: stamped_graph, reusability: compass)
      nodes = graph_data(html)["nodes"]

      booth = nodes.find { |n| n["id"] == "Foo#booth" }
      expect(booth["leverage"]).to eq(1.0)
      expect(booth["collapse"]).to eq(1.0)
      expect(booth["toll_booth"]).to be(true)
      expect(booth["quadrant"]).to eq("bypass_candidate")

      plain = nodes.find { |n| n["id"] == "Foo#plain" }
      %w[leverage collapse toll_booth quadrant].each do |key|
        expect(plain).to have_key(key)
        expect(plain[key]).to be_nil
      end
      # the side panel renders the advisory wording, never a mandate
      expect(html).to include("bypass candidate (advisory)")
    end

    it "escapes a hostile symbol in the compass tables (trust-boundary text)" do
      hostile = scores_mod::Reusability.new(
        reuse_index: nil, unshared_fraction: nil,
        toll_booths: [scores_mod::Reusability::TollBooth.new(
          symbol: "<script>alert(1)</script>#pwn", blast: 1, mass_savings: 1
        )],
        extraction: [], leverage: nil
      )
      html = render(findings: v10_yml, reusability: hostile)

      expect(html).not_to include("<script>alert(1)</script>#pwn")
      expect(html).to include("&lt;script&gt;alert(1)&lt;/script&gt;#pwn")
    end
  end

  # --- v0.16 (T4): score surfaces + the Q8 product-copy law --------------------
  #
  # The v6 stamp family (score/score_band/score_raw/absorb/absorb_raw —
  # findings-1.9 names VERBATIM) rides the same fragment-stamp → DetailTree →
  # whitelist → side-panel route as the v0.13 compass keys. The SCORE is the
  # HEADLINE surface; the quadrant stays diagnostic (Q8 rule 1). The five copy
  # rules (calibration canon §5.3) are spec-gated here, rule 5 as THE
  # cross-surface property machine-checked over the whole rendered document.
  describe "v0.16 (T4): score surfaces + Q8 copy law" do
    let(:scores_mod) { Archbuddy::Report::Scores }

    let(:by_class_rows) do
      [
        scores_mod::Reusability::ClassRow.new(
          symbol: "Api::V1::RedeemTemplates", min: -4.52, max: 3.42, count: 9,
          n_negative: 1, n_positive: 1, headline: -4.52
        ),
        scores_mod::Reusability::ClassRow.new(
          symbol: "Api::V1::Feedbacks", min: -3.04, max: 0.0, count: 2,
          n_negative: 1, n_positive: 0, headline: -3.04
        )
      ]
    end

    let(:score_compass) do
      scores_mod::Reusability.new(
        reuse_index: scores_mod::Reusability::ReuseIndex.new(mean: 2.4, median: 1.0),
        unshared_fraction: 0.5,
        toll_booths: [scores_mod::Reusability::TollBooth.new(
          symbol: "Gateway#relay", blast: 8, mass_savings: 32
        )],
        extraction: [scores_mod::Reusability::Extraction.new(
          symbol: "Billing#split", collapse: 16.0, leverage: 32.0
        )],
        leverage: scores_mod::Reusability::LeverageStats.new(mean: 3.1, median: 2.0, count: 107),
        by_class: by_class_rows
      )
    end

    # The MIXED fixture: a v6-shaped committed graph covering every Q8 rule
    # plus the null back-compat path. Contains the probe's misread class — a
    # negative-score node the compass labels "underused" (01-probe §4b).
    # Symbols deliberately avoid the banned copy tokens so the property
    # spec's block-matching is unambiguous.
    let(:scored_graph) do
      {
        "nodes" => [
          # quadrant says underused; score says monster (rule 2 relabel)
          { "id" => "Billing#split", "symbol" => "Billing#split", "kind" => "function",
            "quadrant" => "underused", "escapes" => false,
            "score" => -4.52, "score_band" => -5, "score_raw" => -18.75,
            "absorb" => nil, "absorb_raw" => nil },
          # score-consistent positive underused entry (rule 2 keeps the copy)
          { "id" => "Templates#fetch", "symbol" => "Templates#fetch", "kind" => "function",
            "quadrant" => "underused", "escapes" => false,
            "score" => 0.75, "score_band" => 1, "score_raw" => 0.8,
            "absorb" => nil, "absorb_raw" => nil },
          # null stamps (pre-v6 carry / never analyzed) — copy untouched
          { "id" => "Legacy#helper", "symbol" => "Legacy#helper", "kind" => "function",
            "quadrant" => "underused", "escapes" => false,
            "score" => nil, "score_band" => nil, "score_raw" => nil,
            "absorb" => nil, "absorb_raw" => nil },
          # bypass_candidate + positive score → one diagnosis, two remedies (rule 3)
          { "id" => "Gateway#relay", "symbol" => "Gateway#relay", "kind" => "function",
            "quadrant" => "bypass_candidate", "toll_booth" => true, "escapes" => false,
            "score" => 4.07, "score_band" => 4, "score_raw" => 5.044,
            "absorb" => 2.31, "absorb_raw" => 2.5 },
          # bypass_candidate + null score → the v0.13 advisory copy untouched
          { "id" => "Booth#idle", "symbol" => "Booth#idle", "kind" => "function",
            "quadrant" => "bypass_candidate", "toll_booth" => true, "escapes" => false,
            "score" => nil, "score_band" => nil, "score_raw" => nil },
          # load_bearing + negative + escape-flagged → rule 4 + the O2 caveat
          { "id" => "Core#dispatch", "symbol" => "Core#dispatch", "kind" => "function",
            "quadrant" => "load_bearing", "escapes" => true,
            "score" => -2.3, "score_band" => -2, "score_raw" => -4.939 },
          # glue at equilibrium (score 0 — no relabel, annotation only)
          { "id" => "Glue#misc", "symbol" => "Glue#misc", "kind" => "function",
            "quadrant" => "glue", "escapes" => false,
            "score" => 0.0, "score_band" => 0, "score_raw" => 0.0 }
        ],
        "edges" => []
      }
    end

    let(:fixture_scores) { scored_graph["nodes"].to_h { |gn| [gn["symbol"], gn["score"]] } }

    subject(:html) { render(findings: v10_yml, graph: scored_graph, reusability: score_compass) }

    def section(doc = html)
      doc[%r{<section id="reusability-compass">.*?</section>}m]
    end

    def q_divs(doc = html)
      section(doc).scan(%r{<div class="q">.*?</div>}m)
    end

    # ---- THE Q8 CROSS-SURFACE PROPERTY (rule 5, machine-checked) ------------
    it "never renders 'reuse more'/'underused' copy against a negative score, anywhere in the document" do
      visible = html.gsub(%r{<script\b[^>]*>.*?</script>}m, "")
      blocks  = visible.scan(%r{<div class="q">.*?</div>}m) +
                visible.scan(%r{<tr[^>]*>.*?</tr>}m) +
                visible.scan(%r{<h3>.*?</h3>}m)
      negative = fixture_scores.select { |_sym, s| s && s.negative? }.keys
      expect(negative).not_to be_empty # the fixture MUST exercise the property

      negative.each do |sym|
        owning = blocks.select { |b| b.include?(sym) }
        expect(owning).not_to be_empty # every negative node IS rendered
        owning.each do |block|
          expect(block).not_to match(/reuse\s+more/i),
                               "Q8 rule 5 violated for #{sym} in: #{block}"
          expect(block).not_to match(/underused/i),
                               "Q8 rule 5 violated for #{sym} in: #{block}"
        end
      end
    end

    # ---- rule 2: "underused / reuse more" ONLY when score ≥ 0 ---------------
    it "keeps reuse-more copy for score ≥ 0 / null entries and relabels negative entries to breakdown copy" do
      reuse_div = q_divs.find { |d| d.include?("Underused abstractions (reuse more)") }
      expect(reuse_div).not_to be_nil
      expect(reuse_div).to include("Templates#fetch (score 0.75)")
      expect(reuse_div).to include("Legacy#helper")          # null score — bare entry
      expect(reuse_div).not_to include("Legacy#helper (score")
      expect(reuse_div).not_to include("Billing#split")      # relabeled out

      breakdown_div = q_divs.find { |d| d.include?("false reusability: break it down") }
      expect(breakdown_div).not_to be_nil
      expect(breakdown_div).to include("Billing#split (score -4.52)")
    end

    # ---- rule 3: bypass_candidate + positive score = one diagnosis, two remedies
    it "renders one-diagnosis-two-remedies copy for a positive-score bypass candidate" do
      two_remedies = q_divs.find { |d| d.include?("absorb shared logic here, or bypass it") }
      expect(two_remedies).not_to be_nil
      expect(two_remedies).to include("Gateway#relay (score 4.07)")

      default_booth = q_divs.find { |d| d.include?("Bypass candidates (toll booths — advisory)") }
      expect(default_booth).to include("Booth#idle")
      expect(default_booth).not_to include("Gateway#relay")
    end

    # ---- rule 4 + the (d) escape caveat --------------------------------------
    it "renders protect-the-boundary copy + the O2 escape caveat for a negative load-bearing escape node" do
      lb = q_divs.find { |d| d.include?("protect the boundary, break down the inline surface") }
      expect(lb).not_to be_nil
      expect(lb).to include("Core#dispatch (score -2.30)")
      expect(lb).to include("[escape: inline surface above contract — NOT statically extraction-recoverable]")
    end

    it "annotates a no-relabel quadrant entry with its published score (glue at equilibrium)" do
      glue = q_divs.find { |d| d.include?("<strong>Glue</strong>") }
      expect(glue).to include("Glue#misc (score 0.00)")
    end

    # ---- the per-class signed-extremes table (C-3: headline column) ---------
    it "renders the per-class table with all seven columns INCLUDING the engine headline (C-3)" do
      expect(section).to include("<h3>Reusability score by class</h3>")
      expect(section).to include("<th>Class</th><th>min</th><th>max</th><th>count</th>" \
                                 "<th>n ≤ −1</th><th>n ≥ +1</th><th>headline</th>")
      row = section[%r{<tr><td>Api::V1::RedeemTemplates</td>.*?</tr>}m]
      expect(row).to eq(
        "<tr><td>Api::V1::RedeemTemplates</td>" \
        '<td class="num">-4.52</td><td class="num">3.42</td><td class="num">9</td>' \
        '<td class="num">1</td><td class="num">1</td><td class="num">-4.52</td></tr>'
      )
      # count ALWAYS shown (Q4 small-class caveat) — the 2-node class row too
      expect(section).to include("<td>Api::V1::Feedbacks</td>")
        .and include('<td class="num">2</td>')
    end

    it "renders the table present-IFF-by_class (nil member ⇒ no table, no fabrication)" do
      expect(html).to include("Reusability score by class")

      no_by_class = scores_mod::Reusability.new(
        reuse_index: score_compass.reuse_index, unshared_fraction: 0.5,
        toll_booths: score_compass.toll_booths, extraction: score_compass.extraction,
        leverage: score_compass.leverage
      )
      html2 = render(findings: v10_yml, graph: scored_graph, reusability: no_by_class)
      expect(html2).not_to include("Reusability score by class")
      expect(html2).not_to include("<th>headline</th>")
    end

    it "escapes a hostile class symbol in the per-class table (trust-boundary text)" do
      hostile = scores_mod::Reusability.new(
        by_class: [scores_mod::Reusability::ClassRow.new(
          symbol: "<script>alert(1)</script>::Pwn", min: -1.0, max: 0.0, count: 1,
          n_negative: 1, n_positive: 0, headline: -1.0
        )]
      )
      rendered = render(findings: v10_yml, reusability: hostile)
      expect(rendered).not_to include("<script>alert(1)</script>::Pwn")
      expect(rendered).to include("&lt;script&gt;alert(1)&lt;/script&gt;::Pwn")
    end

    # ---- data blob: the stamp family rides the whitelist ---------------------
    it "whitelists the five score stamps + escapes into the data blob (honest nulls unstamped)" do
      nodes = graph_data(html)["nodes"]

      relay = nodes.find { |n| n["id"] == "Gateway#relay" }
      expect(relay["score"]).to eq(4.07)
      expect(relay["score_band"]).to eq(4)
      expect(relay["score_raw"]).to eq(5.044)
      expect(relay["absorb"]).to eq(2.31)
      expect(relay["absorb_raw"]).to eq(2.5)

      idle = nodes.find { |n| n["id"] == "Booth#idle" }
      %w[score score_band score_raw absorb absorb_raw].each do |key|
        expect(idle).to have_key(key)
        expect(idle[key]).to be_nil
      end

      dispatch = nodes.find { |n| n["id"] == "Core#dispatch" }
      expect(dispatch["escapes"]).to be(true)
      expect(dispatch["score_raw"]).to eq(-4.939)
    end

    # ---- side panel (JS source pins — the Q8 guards are load-bearing) --------
    describe "side-panel script (Q8 headline + gates)" do
      it "emits the score row FIRST (rule 1 — score is the headline)" do
        expect(html).to include("'<dt>score</dt><dd>'")
        expect(html.index("'<dt>score</dt><dd>'")).to be < html.index("'<dt>leverage</dt><dd>'")
      end

      it "never shows the 'underused' quadrant label against a negative score (rule 2/5)" do
        expect(html).to include(
          "if (quad === 'underused' && hasScore && n.score < 0) " \
          "quad = 'diagnostic overridden by negative score — break it down';"
        )
      end

      it "appends the O2 escape caveat only on escape-flagged negative nodes (rule set d)" do
        expect(html).to include("if (n.escapes === true && hasScore && n.score < 0)")
        expect(html).to include("inline surface above contract — NOT statically extraction-recoverable")
      end

      it "gates absorb copy on score >= 0 (L9-A extension of the Q8 law)" do
        expect(html).to include("hasScore && n.score >= 0) compass += '<dt>absorb</dt><dd>'")
      end
    end

    # ---- pre-v6 back-compat: the v5 rendering path is byte-identical ---------

    # The v0.13 section bytes for THIS fixture — a SNAPSHOT, not authored:
    # captured 2026-07-30 by rendering the exact `absent`/`v5_compass` inputs
    # below under the db8449c formatter ("[v0.15 REVIEW-FIX] gate user
    # thresholds at published rounding (M14)" — the v0.16 fork point) in a
    # detached scratch worktree. The two EMPTY lines are v0.13's own shape
    # (trailing heredoc newlines of the two tables); note there is NO
    # whitespace-only line anywhere — the T4 review caught the added
    # `#{score_by_class_table_html(ru)}` heredoc line leaving a "  " line on
    # every by_class-less (= every pre-v6/v5) document. Comparing against
    # pinned prior bytes is the ONLY spec form that can catch such drift —
    # null-stamped vs stamp-less both render under the NEW code and stay
    # equal even when both drift together.
    let(:v013_section_snapshot) do
      <<~V13.chomp
        <section id="reusability-compass">
          <h2>Reusability Compass</h2>
          <div class="compass-summary">Reuse index: mean 2.4 / median 1.0 · unshared fraction 50.0% · leverage mean 3.1 / median 2.0</div>
          <div class="quadrants">
        <div class="q"><strong>Bypass candidates (toll booths — advisory)</strong> (2): Gateway#relay, Booth#idle</div>
        <div class="q"><strong>Load-bearing (protect the contract)</strong> (1): Core#dispatch</div>
        <div class="q"><strong>Underused abstractions (reuse more)</strong> (3): Billing#split, Templates#fetch, Legacy#helper</div>
        <div class="q"><strong>Glue</strong> (1): Glue#misc</div>
        </div>
          <h3>Toll booths — bypass candidates (advisory)</h3>
        <div class="q">Bypassing a toll booth (callers call its sole callee directly) saves the listed mass at zero variety cost — but thin proxies can carry invisible value (memoization, naming, test seams). Candidates, never mandates.</div>
        <table><thead><tr><th>Symbol</th><th>blast</th><th>mass savings</th></tr></thead>
        <tbody><tr><td>Gateway#relay</td><td class="num">8</td><td class="num">32</td></tr></tbody></table>

          <h3>Extraction candidates (collapse potential)</h3>
        <table><thead><tr><th>Symbol</th><th>collapse</th><th>leverage</th></tr></thead>
        <tbody><tr><td>Billing#split</td><td class="num">16.0000</td><td class="num">32.0000</td></tr></tbody></table>

        </section>
      V13
    end

    it "renders a null-stamped tree byte-identical to a stamp-less (v5) tree — no score column, no table, no relabel" do
      strip = %w[score score_band score_raw absorb absorb_raw]
      absent = scored_graph["nodes"].map { |gn| gn.reject { |k, _| strip.include?(k) } }
      nulled = scored_graph["nodes"].map { |gn| gn.merge(strip.to_h { |k| [k, nil] }) }
      v5_compass = scores_mod::Reusability.new(
        reuse_index: score_compass.reuse_index, unshared_fraction: 0.5,
        toll_booths: score_compass.toll_booths, extraction: score_compass.extraction,
        leverage: score_compass.leverage
      )

      sec_absent = section(render(findings: v10_yml, graph: { "nodes" => absent, "edges" => [] },
                                  reusability: v5_compass))
      sec_nulled = section(render(findings: v10_yml, graph: { "nodes" => nulled, "edges" => [] },
                                  reusability: v5_compass))

      expect(sec_absent).to eq(sec_nulled)                       # byte-identical
      # THE back-compat gate: byte-identical to the PINNED v0.13 output —
      # not merely internally consistent under the new code.
      expect(sec_absent).to eq(v013_section_snapshot)
      # no whitespace-only line may appear (the exact defect class the
      # snapshot exists to catch — an empty part interpolated on its own
      # heredoc line); v0.13's empty lines ("") are NOT whitespace-only.
      expect(sec_absent.lines.grep(/\A[ \t]+\Z/)).to be_empty
      expect(sec_absent).not_to include("(score ")               # no score values
      expect(sec_absent).not_to include("Reusability score by class")
      expect(sec_absent).not_to include("false reusability: break it down") # no Q8 relabeling
      # the exact v0.13 entry byte-shape survives (bare symbols, quadrant order)
      expect(sec_absent).to include(
        '<div class="q"><strong>Underused abstractions (reuse more)</strong> (3): ' \
        "Billing#split, Templates#fetch, Legacy#helper</div>"
      )
    end
  end
end
