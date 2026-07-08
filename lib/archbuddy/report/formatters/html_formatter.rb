# frozen_string_literal: true

require "json"
require_relative "../formatter"
require_relative "structured_export"

module Archbuddy
  module Report
    module Formatters
      # R-6 (open/closed): a NEW formatter peer to terminal/yaml/json/dot. Emits a
      # SINGLE, fully self-contained, fully OFFLINE .html dashboard as a string on
      # stdout (the CLI `puts`es it; the user redirects to a gitignored path).
      #
      # The dashboard shows the two project dimension scores as headline cards,
      # an interactive Cytoscape.js call graph (when `--graph` is supplied), and a
      # ranked bottleneck table. Like the dot formatter it needs the edge list,
      # which lives in graph.yml — so the graph is rendered only when `--graph` is
      # passed; without it the scores header + table still render (graceful
      # degradation) with a visible notice.
      #
      # OFFLINE GUARANTEE: Cytoscape.js + all CSS/JS are INLINED into the output.
      # There are ZERO external resource references (no <script src="http…">, no
      # CDN). A spec asserts this. The library is the committed, version-pinned
      # vendored asset (see report/assets/CYTOSCAPE_LICENSE).
      #
      # SECRET: the output carries real de-anonymized symbols + file:line, so it
      # is SECRET/local-only (D16/D21) — gitignored, never committed, never shared.
      #
      # Everything is VERBATIM (D17): scores/metrics/clutter come straight from the
      # already-joined findings; this formatter makes ZERO analytic decisions and
      # de-anonymizes ONLY via the existing resolver.
      class HtmlFormatter < Formatter
        ASSET_DIR = File.expand_path("../assets", __dir__)
        CYTOSCAPE_PATH = File.join(ASSET_DIR, "cytoscape.min.js")

        NO_GRAPH_NOTICE =
          "No call graph: pass --graph graph.yml to render the interactive network."

        # Node fill is driven by a selectable metric; default centrality.
        COLORABLE_METRICS = %w[centrality fan_in fan_out path_length clutter_score].freeze

        def render
          <<~HTML
            <!DOCTYPE html>
            <html lang="en">
            <head>
            <meta charset="utf-8">
            <meta name="viewport" content="width=device-width, initial-scale=1">
            <title>archbuddy — architecture clutter report</title>
            <style>#{styles}</style>
            </head>
            <body>
            #{body_header}
            #{scores_header_html}
            #{multiplexer_proxies_html}
            #{graph_section_html}
            #{bottleneck_table_html}
            <script>#{cytoscape_library}</script>
            <script id="archbuddy-data" type="application/json">#{data_json}</script>
            <script>#{init_script}</script>
            </body>
            </html>
          HTML
        end

        private

        # ---- inlined assets ----------------------------------------------------

        # The vendored, version-pinned Cytoscape.js library, read at render time
        # and inlined verbatim. This is what makes the report work offline.
        def cytoscape_library
          # Force UTF-8 so it composes cleanly with the UTF-8 HTML template
          # (the template contains ↔ / → glyphs); the asset is ASCII-safe JS.
          File.read(CYTOSCAPE_PATH, encoding: "UTF-8")
        end

        def styles
          <<~CSS
            :root{--bg:#0f1419;--panel:#1b232c;--ink:#e6edf3;--muted:#8b98a5;--line:#2d3742;--accent:#58a6ff;}
            *{box-sizing:border-box;}
            body{margin:0;font:14px/1.5 -apple-system,Segoe UI,Roboto,Helvetica,Arial,sans-serif;background:var(--bg);color:var(--ink);}
            header.top{padding:16px 24px;border-bottom:1px solid var(--line);}
            header.top h1{margin:0;font-size:18px;} header.top .src{color:var(--muted);font-size:12px;}
            .secret{color:#f0883e;font-size:12px;margin-top:4px;}
            section{padding:16px 24px;border-bottom:1px solid var(--line);}
            h2{font-size:14px;text-transform:uppercase;letter-spacing:.05em;color:var(--muted);margin:0 0 12px;}
            .cards{display:flex;gap:16px;flex-wrap:wrap;}
            .card{background:var(--panel);border:1px solid var(--line);border-radius:8px;padding:16px;min-width:240px;flex:1;}
            .card .grade{font-size:40px;font-weight:700;line-height:1;}
            .card .score{font-size:13px;color:var(--muted);} .card .label{font-weight:600;margin-bottom:6px;}
            .card .q{color:var(--muted);font-size:12px;margin-top:6px;}
            .card.na .grade{color:var(--muted);} .card .na-reason{color:#f0883e;font-size:12px;margin-top:6px;}
            .grade-A{color:#3fb950;}.grade-B{color:#56d364;}.grade-C{color:#d29922;}.grade-D{color:#db6d28;}.grade-F{color:#f85149;}
            .controls{display:flex;gap:8px;flex-wrap:wrap;align-items:center;margin-bottom:12px;}
            .controls label{color:var(--muted);font-size:12px;}
            button,select{background:var(--panel);color:var(--ink);border:1px solid var(--line);border-radius:6px;padding:6px 10px;font-size:12px;cursor:pointer;}
            button:hover{border-color:var(--accent);}
            #cy{width:100%;height:520px;background:var(--panel);border:1px solid var(--line);border-radius:8px;}
            .layout{display:flex;gap:16px;align-items:flex-start;}
            .layout #cy{flex:3;} #side{flex:1;min-width:240px;background:var(--panel);border:1px solid var(--line);border-radius:8px;padding:14px;max-height:520px;overflow:auto;}
            #side h3{margin:0 0 8px;font-size:14px;} #side .muted{color:var(--muted);}
            #side dl{display:grid;grid-template-columns:auto 1fr;gap:2px 10px;margin:8px 0;font-size:12px;}
            #side dt{color:var(--muted);} #side dd{margin:0;}
            .notice{background:#21262d;border:1px dashed var(--line);border-radius:8px;padding:16px;color:var(--muted);}
            table{width:100%;border-collapse:collapse;font-size:13px;}
            th,td{text-align:left;padding:7px 10px;border-bottom:1px solid var(--line);}
            th{color:var(--muted);font-weight:600;text-transform:uppercase;font-size:11px;letter-spacing:.04em;}
            tbody tr{cursor:pointer;} tbody tr:hover{background:#21262d;}
            td.num{text-align:right;font-variant-numeric:tabular-nums;}
            .unresolved{color:#f0883e;}
            th.sortable{cursor:pointer;user-select:none;} th.sortable:hover{color:var(--ink);}
            th.sortable .arrow{margin-left:4px;color:var(--accent);}
            .muted-inline{color:var(--muted);font-size:12px;}
            input[type=number]{background:var(--panel);color:var(--ink);border:1px solid var(--line);border-radius:6px;padding:5px 8px;font-size:12px;width:80px;}
            input[type=range]{accent-color:var(--accent);vertical-align:middle;}
            .filter-controls,.table-controls{margin-top:8px;}
          CSS
        end

        # ---- static HTML scaffolding -------------------------------------------

        def body_header
          gen  = context.generator || {}
          tool = gen["tool"] || gen[:tool] || "unknown"
          <<~HTML
            <header class="top">
              <h1>archbuddy — architecture clutter report</h1>
              <div class="src">source: #{escape(tool)}</div>
              <div class="secret">SECRET / local-only — contains real symbols; never commit or share this file.</div>
            </header>
          HTML
        end

        def scores_header_html
          return "" if context.scores.nil? || context.scores.empty?

          cards = context.scores.map { |dim| score_card(dim) }.join("\n")
          <<~HTML
            <section id="scores">
              <h2>Project Scores</h2>
              #{connectivity_banner_html}
              <div class="cards">#{cards}</div>
            </section>
          HTML
        end

        # Connectivity banner (V8) ABOVE the dimension cards. Engine-emitted
        # figures rendered VERBATIM (D17); the verdict string is `escape`d
        # (trust-boundary text). "" when connectivity is absent (1.0/1.1/1.2
        # doc) ⇒ nothing rendered. nil ratio ⇒ "(N/A)", never "(0.0%)", N1.
        def connectivity_banner_html
          conn = context.connectivity
          return "" if conn.nil?

          ratio = conn.scored_ratio
          pct   = conn.forward_pct_display
          text  = "Connectivity: #{[ratio, "nodes scored (#{pct})"].compact.join(' ')}"
          %(<div class="connectivity">#{escape(text)}</div>)
        end

        def score_card(dim)
          grade = dim.grade.to_s
          if dim.na?
            <<~HTML
              <div class="card na">
                <div class="label">#{escape(dim.label)}</div>
                <div class="grade">N/A</div>
                <div class="score">no score</div>
                <div class="q">#{escape(dim.question)}</div>
                <div class="na-reason">#{escape(dim.na_reason || 'undeterminable')}</div>
              </div>
            HTML
          else
            <<~HTML
              <div class="card">
                <div class="label">#{escape(dim.label)}</div>
                <div class="grade grade-#{escape(grade)}">#{escape(grade)}</div>
                <div class="score">cost #{escape(format("%.1f", dim.score))}</div>
                <div class="q">#{escape(dim.question)}</div>
              </div>
            HTML
          end
        end

        # R1: the v0.7 multiplexer_proxy smell as an ADDITIVE section peer to
        # scores_header_html. Rendered VERBATIM worst-first (D17). "" when absent
        # (nil — no scores block); an explicit "(none)" note when scored-but-empty
        # (never a fabricated verdict). Symbol + added-coupling are `escape`d
        # (trust-boundary text). No opaque id is needed here — the committed path
        # is real-name; graph annotation uses the opaque-id key in data_json.
        def multiplexer_proxies_html
          proxies = context.multiplexer_proxies
          return "" if proxies.nil?

          body =
            if proxies.empty?
              %(<div class="notice">No multiplexer_proxy detected, or forward-discoverability is N/A.</div>)
            else
              rows = proxies.each_with_index.map do |proxy, i|
                coupling = proxy.coupling_display
                coupling_cell = coupling.empty? ? "&mdash;" : escape(coupling)
                "<tr><td class=\"num\">#{i + 1}</td><td>#{escape(proxy.where)}</td>" \
                  "<td class=\"num\">#{coupling_cell}</td></tr>"
              end.join("\n")
              <<~HTML
                <table>
                  <thead><tr><th>#</th><th>Method</th><th>added_coupling</th></tr></thead>
                  <tbody>#{rows}</tbody>
                </table>
              HTML
            end

          <<~HTML
            <section id="multiplexer-proxies">
              <h2>Multiplexer Proxy Smell</h2>
              #{body}
            </section>
          HTML
        end

        def graph_section_html
          if context.graph.nil?
            return <<~HTML
              <section id="graph">
                <h2>Call Graph</h2>
                <div class="notice">#{escape(NO_GRAPH_NOTICE)}</div>
              </section>
            HTML
          end

          color_opts = COLORABLE_METRICS.map { |m| %(<option value="#{m}">#{m}</option>) }.join
          hotspot_buttons = (context.scores || []).reject(&:na?).map do |dim|
            %(<button data-hotspot="#{escape(dim.key)}">Highlight #{escape(dim.label)} hotspots</button>)
          end.join

          <<~HTML
            <section id="graph">
              <h2>Call Graph</h2>
              #{node_cap_banner_html}
              <div class="controls">
                <button id="btn-labels">Toggle labels: real ↔ opaque</button>
                <label>Layout
                  <select id="sel-layout">
                    <option value="cose">cose</option>
                    <option value="grid">grid</option>
                    <option value="breadthfirst">breadthfirst</option>
                    <option value="circle">circle</option>
                  </select>
                </label>
                <label>Color by
                  <select id="sel-metric">#{color_opts}</select>
                </label>
                #{hotspot_buttons}
                <button id="btn-reset">Reset highlight</button>
              </div>
              <div class="controls filter-controls">
                <label for="rng-minscore">Min clutter score</label>
                <input type="range" id="rng-minscore" min="0" max="0" step="0.01" value="0">
                <input type="number" id="num-minscore" min="0" step="0.01" value="0">
                <span id="minscore-count" class="muted-inline"></span>
              </div>
              <div class="layout">
                <div id="cy"></div>
                <div id="side"><span class="muted">Click a node to inspect it.</span></div>
              </div>
            </section>
          HTML
        end

        # The metric columns shown in the bottleneck table. `clutter_score` is the
        # default sort key (desc) — see init_script's sort state defaults.
        TABLE_METRIC_COLS = %w[clutter_score centrality fan_in fan_out path_length].freeze

        def bottleneck_table_html
          metric_cols = TABLE_METRIC_COLS
          # Each header carries data-sort-key so the JS knows what to sort by, and
          # data-sort-type so numeric vs text comparison is chosen correctly. The
          # rank column (#) is not sortable (it reflects the current sort order).
          headers = [
            { label: "#", key: nil },
            { label: "Symbol", key: "symbol", type: "text" },
            { label: "file:line", key: "file_line", type: "text" },
            { label: "kind", key: "kind", type: "text" }
          ] + metric_cols.map { |m| { label: m, key: m, type: "num" } }

          head = headers.map do |h|
            if h[:key]
              %(<th class="sortable" data-sort-key="#{escape(h[:key])}" data-sort-type="#{h[:type]}">) \
                "#{escape(h[:label])}<span class=\"arrow\"></span></th>"
            else
              "<th>#{escape(h[:label])}</th>"
            end
          end.join

          <<~HTML
            <section id="table">
              <h2>Ranked Bottlenecks (by clutter_score)</h2>
              <div class="controls table-controls">
                <label>Rows per page
                  <select id="sel-page-size">
                    <option value="25">25</option>
                    <option value="50">50</option>
                    <option value="100">100</option>
                    <option value="all">All</option>
                  </select>
                </label>
                <button id="tbl-prev">&laquo; Prev</button>
                <button id="tbl-next">Next &raquo;</button>
                <span id="tbl-range" class="muted-inline"></span>
              </div>
              <table>
                <thead><tr>#{head}</tr></thead>
                <tbody id="tbl-body">#{table_rows_html(metric_cols)}</tbody>
              </table>
            </section>
          HTML
        end

        # All rows are rendered server-side (HTML-escaped, injection-proof — the
        # symbol/path are interpolated as live markup here, so escape() guards
        # them). The init script then SORTS and PAGINATES purely by reordering /
        # showing-hiding these existing <tr> elements — it never re-emits the
        # escaped content, so the escaping guarantee is preserved end-to-end. Each
        # row carries data-* sort keys (numeric metrics + text symbol/file/kind).
        def table_rows_html(metric_cols)
          context.ranked.each_with_index.map do |b, i|
            bottleneck_row(b, i + 1, metric_cols)
          end.join("\n")
        end

        def bottleneck_row(bottleneck, rank, metric_cols)
          loc = bottleneck.location
          sym = loc.resolved? ? escape(loc.symbol) : %(<span class="unresolved">#{escape(loc.symbol)}</span>)
          kind = bottleneck.kind || "unknown"
          # Per-metric sort keys live in a data-s attribute on each <td>; nil/N/A
          # metrics get data-na="1" (and no data-s) so the JS sort can push them
          # last in EITHER direction. Text sort keys for symbol/file/kind ride on
          # the <tr>. data-rank preserves the original (default clutter desc) rank.
          cells = metric_cols.map do |key|
            val = key == "clutter_score" ? bottleneck.clutter_score : bottleneck.metrics[key]
            attr = val.nil? ? %(data-na="1") : %(data-s="#{escape(val)}")
            disp = val.nil? ? "N/A" : escape(format_num(val))
            %(<td class="num" #{attr}>#{disp}</td>)
          end.join
          <<~HTML.chomp
            <tr data-node="#{escape(bottleneck.id)}" data-rank="#{rank}" data-s-symbol="#{escape(loc.symbol)}" data-s-file_line="#{escape(loc.file_line)}" data-s-kind="#{escape(kind)}">
              <td class="num rank">#{rank}</td><td>#{sym}</td>
              <td>#{escape(loc.file_line)}</td><td>#{escape(kind)}</td>
              #{cells}
            </tr>
          HTML
        end

        # ---- inlined data ------------------------------------------------------

        # The whole dashboard's data as one JSON blob the init script consumes.
        # Nodes/edges come from graph.yml (de-anonymized via the resolver);
        # bottlenecks/scores reuse the StructuredExport shapes (verbatim).
        def data_json
          payload = {
            "nodes"       => graph_node_data,
            "edges"       => graph_edge_data,
            "bottlenecks" => context.ranked.map { |b| StructuredExport.node_hash(b, metric_keys) },
            "scores"      => scores_data,
            "hotspots"    => hotspot_ids_by_dimension,
            "multiplexer_proxies" => multiplexer_proxy_data,
            "node_cap"    => node_cap_info,
            "default_metric" => "centrality"
          }
          # Embed as JSON inside a <script type="application/json"> — escape the
          # only sequence that could close the tag early so the blob stays inert.
          JSON.generate(payload).gsub("</", '<\/')
        end

        # The set of node ids to render in the graph viz, as a Hash id => true for
        # O(1) lookup. When `--max-nodes N` is in effect and the graph exceeds N,
        # keep the top N by clutter_score (scored nodes first, unscored last,
        # deterministic id tiebreak); otherwise nil = render all. This bounds the
        # cytoscape payload so a huge graph (e.g. nexus ~1949 nodes) doesn't crash
        # the browser on initial render. The bottleneck TABLE is unaffected (it uses
        # context.ranked / --top).
        def kept_node_ids
          return @kept_node_ids if defined?(@kept_node_ids)

          cap = context.max_nodes
          @kept_node_ids =
            if cap.nil? || cap <= 0 || graph_nodes.size <= cap
              nil
            else
              score = {}
              context.ranked.each { |b| score[b.id] = b.clutter_score if b.clutter_score }
              graph_nodes
                .map { |gn| gn["id"] }
                .sort_by { |id| [score[id] ? -score[id] : Float::INFINITY, id] }
                .first(cap)
                .each_with_object({}) { |id, h| h[id] = true }
            end
        end

        # Truncation summary for the payload/banner, or nil when uncapped.
        def node_cap_info
          return nil unless kept_node_ids

          { "shown" => kept_node_ids.size, "total" => graph_nodes.size }
        end

        def node_cap_banner_html
          info = node_cap_info
          return "" unless info

          %(<div class="notice">Graph shows the top #{info["shown"]} of #{info["total"]} nodes ) +
            %(by clutter score (pass <code>--max-nodes 0</code> for all). ) +
            %(The bottleneck table below is unaffected.</div>)
        end

        # One entry per graph.yml node (capped to kept_node_ids), de-anonymized.
        # Metrics/clutter joined from the ranked bottlenecks (verbatim) keyed by id.
        def graph_node_data
          by_id = context.ranked.each_with_object({}) { |b, h| h[b.id] = b }
          nodes = kept_node_ids ? graph_nodes.select { |gn| kept_node_ids.include?(gn["id"]) } : graph_nodes
          nodes.map do |gn|
            id  = gn["id"]
            b   = by_id[id]
            loc = resolve(id)
            findings = b ? b.findings.map(&:type).uniq : []
            {
              "id"            => id,
              "symbol"        => loc.symbol,
              "opaque"        => id,
              "file"          => loc.file,
              "line"          => loc.line,
              "kind"          => (b && b.kind) || loc.kind || gn["kind"] || "external",
              "resolved"      => loc.resolved?,
              "class_id"      => loc.class_id,
              "clutter_score" => b&.clutter_score,
              "metrics"       => b ? metric_keys.each_with_object({}) { |k, m| m[k] = b.metrics[k] } : {},
              "findings"      => findings
            }
          end
        end

        # Edges among the rendered nodes only: when the node set is capped, an edge
        # to a dropped node would dangle in cytoscape, so keep only edges whose BOTH
        # endpoints survive the cap.
        def graph_edge_data
          kept = kept_node_ids
          es = kept ? edges.select { |e| kept.include?(e["from"]) && kept.include?(e["to"]) } : edges
          es.map { |e| { "from" => e["from"], "to" => e["to"], "calls" => e["calls"] || 1 } }
        end

        def scores_data
          return nil if context.scores.nil? || context.scores.empty?

          context.scores.each_with_object({}) do |dim, h|
            h[dim.key] = {
              "label" => dim.label, "question" => dim.question,
              "score" => dim.score, "grade" => dim.grade, "na_reason" => dim.na_reason
            }.compact
          end
        end

        # The multiplexer_proxy smell for the data blob (worst-first, VERBATIM).
        # Carries the opaque node id when known (legacy path — for graph node
        # annotation) alongside the real symbol + added_coupling. [] when absent
        # or empty (the section HTML handles the visible "(none)"/omit distinction).
        def multiplexer_proxy_data
          (context.multiplexer_proxies || []).map do |proxy|
            {
              "id"             => proxy.location&.id,
              "symbol"         => proxy.symbol,
              "added_coupling" => proxy.added_coupling
            }.compact
          end
        end

        def hotspot_ids_by_dimension
          return {} if context.scores.nil?

          context.scores.each_with_object({}) do |dim, h|
            h[dim.key] = dim.hotspots.map { |hs| hs.location.id }
          end
        end

        def init_script
          # Vanilla JS: parse the inlined data, wire the table (sort + paginate),
          # then — only if a graph is present — build the Cytoscape graph (built-in
          # layouts only) and wire the controls, min-score filter, side panel, and
          # table cross-select. The TABLE block runs unconditionally so sort +
          # pagination work in the no-graph degradation path too.
          <<~'JS'
            (function () {
              var data = JSON.parse(document.getElementById('archbuddy-data').textContent);
              function num(v) { return (typeof v === 'number' && isFinite(v)) ? v : 0; }

              // ===== Bottleneck table: client-side sort + pagination ============
              // Operates purely by REORDERING / showing-hiding the server-rendered
              // (already HTML-escaped) <tr> elements — never re-emits their content,
              // so the injection-proof escaping guarantee is preserved end-to-end.
              (function () {
                var tbody = document.getElementById('tbl-body');
                if (!tbody) return;
                var allRows = Array.prototype.slice.call(tbody.querySelectorAll('tr[data-node]'));
                if (!allRows.length) return;

                var sortKey = 'clutter_score';   // default sort = clutter_score desc
                var sortDir = 'desc';            //   (matches the pre-sort ranking)
                var sortType = 'num';
                var pageSize = 25;               // default page size
                var page = 1;
                var ordered = allRows.slice();

                var sizeSel = document.getElementById('sel-page-size');
                var prevBtn = document.getElementById('tbl-prev');
                var nextBtn = document.getElementById('tbl-next');
                var rangeEl = document.getElementById('tbl-range');

                // Numeric sort value for a row's metric cell: null/N/A (data-na)
                // returns null so it can be forced LAST regardless of direction.
                function cellNum(tr, key) {
                  var th = headerFor(key);
                  var idx = th ? th.cellIndex : -1;
                  if (idx < 0) return null;
                  var td = tr.children[idx];
                  if (!td || td.getAttribute('data-na') === '1') return null;
                  var s = td.getAttribute('data-s');
                  var v = parseFloat(s);
                  return isFinite(v) ? v : null;
                }
                function cellText(tr, key) {
                  var v = tr.getAttribute('data-s-' + key);
                  return v === null ? '' : v.toLowerCase();
                }
                var headerEls = Array.prototype.slice.call(document.querySelectorAll('th.sortable'));
                function headerFor(key) {
                  for (var i = 0; i < headerEls.length; i++) {
                    if (headerEls[i].getAttribute('data-sort-key') === key) return headerEls[i];
                  }
                  return null;
                }

                function applySort() {
                  var dirMul = sortDir === 'asc' ? 1 : -1;
                  ordered = allRows.slice().sort(function (a, b) {
                    if (sortType === 'num') {
                      var av = cellNum(a, sortKey), bv = cellNum(b, sortKey);
                      // null/N/A always last, regardless of direction.
                      if (av === null && bv === null) return 0;
                      if (av === null) return 1;
                      if (bv === null) return -1;
                      if (av === bv) return 0;
                      return av < bv ? -1 * dirMul : 1 * dirMul;
                    }
                    var as = cellText(a, sortKey), bs = cellText(b, sortKey);
                    if (as === bs) return 0;
                    return as < bs ? -1 * dirMul : 1 * dirMul;
                  });
                  page = 1;
                  updateArrows();
                  render();
                }

                function updateArrows() {
                  headerEls.forEach(function (th) {
                    var arrow = th.querySelector('.arrow');
                    if (!arrow) return;
                    if (th.getAttribute('data-sort-key') === sortKey) {
                      arrow.textContent = sortDir === 'asc' ? '▲' : '▼';
                    } else {
                      arrow.textContent = '';
                    }
                  });
                }

                function pageCount() {
                  if (pageSize === 'all') return 1;
                  return Math.max(1, Math.ceil(ordered.length / pageSize));
                }

                function render() {
                  var total = ordered.length;
                  var start, end;
                  if (pageSize === 'all') { start = 0; end = total; }
                  else {
                    if (page > pageCount()) page = pageCount();
                    start = (page - 1) * pageSize;
                    end = Math.min(start + pageSize, total);
                  }
                  // Detach then re-append only the current page's rows in order.
                  allRows.forEach(function (tr) { if (tr.parentNode) tr.parentNode.removeChild(tr); });
                  for (var i = start; i < end; i++) tbody.appendChild(ordered[i]);
                  if (rangeEl) {
                    rangeEl.textContent = total === 0 ? 'showing 0 of 0'
                      : 'showing ' + (start + 1) + '–' + end + ' of ' + total;
                  }
                  if (prevBtn) prevBtn.disabled = (pageSize === 'all' || page <= 1);
                  if (nextBtn) nextBtn.disabled = (pageSize === 'all' || page >= pageCount());
                }

                headerEls.forEach(function (th) {
                  th.onclick = function () {
                    var key = th.getAttribute('data-sort-key');
                    var type = th.getAttribute('data-sort-type') || 'text';
                    if (sortKey === key) {
                      sortDir = sortDir === 'asc' ? 'desc' : 'asc';
                    } else {
                      sortKey = key; sortType = type;
                      // sensible initial direction: numbers desc (worst first),
                      // text asc (A→Z).
                      sortDir = type === 'num' ? 'desc' : 'asc';
                    }
                    applySort();
                  };
                });
                if (sizeSel) sizeSel.onchange = function () {
                  pageSize = this.value === 'all' ? 'all' : parseInt(this.value, 10);
                  page = 1; render();
                };
                if (prevBtn) prevBtn.onclick = function () { if (page > 1) { page--; render(); } };
                if (nextBtn) nextBtn.onclick = function () { if (page < pageCount()) { page++; render(); } };

                applySort(); // initial: clutter_score desc, page 1, default size
              })();

              // ===== Call graph (only when a graph is present) ==================
              var cyEl = document.getElementById('cy');
              if (!cyEl || typeof cytoscape === 'undefined' || !data.nodes.length) return;

              var SHAPE = { function: 'ellipse', endpoint: 'round-rectangle', db_op: 'diamond', external: 'hexagon' };

              function metricRange(metric) {
                var vals = data.nodes.map(function (n) {
                  return metric === 'clutter_score' ? num(n.clutter_score) : num((n.metrics || {})[metric]);
                });
                return { min: Math.min.apply(null, vals.concat([0])), max: Math.max.apply(null, vals.concat([1])) };
              }
              function colorFor(n, metric, range) {
                var v = metric === 'clutter_score' ? num(n.clutter_score) : num((n.metrics || {})[metric]);
                var t = range.max > range.min ? (v - range.min) / (range.max - range.min) : 0;
                var r = Math.round(56 + t * 192), g = Math.round(160 - t * 120), b = Math.round(255 - t * 200);
                return 'rgb(' + r + ',' + g + ',' + b + ')';
              }

              var elements = [];
              data.nodes.forEach(function (n) {
                elements.push({ data: {
                  id: n.id, real: n.symbol, opaque: n.opaque, kind: n.kind,
                  clutter: num(n.clutter_score), size: 20 + num(n.clutter_score) * 4,
                  shape: SHAPE[n.kind] || 'ellipse'
                }});
              });
              var present = {}; data.nodes.forEach(function (n) { present[n.id] = true; });
              data.edges.forEach(function (e, i) {
                if (present[e.from] && present[e.to]) {
                  elements.push({ data: { id: 'e' + i, source: e.from, target: e.to, w: 1 + num(e.calls) } });
                }
              });

              var useReal = true; // local view defaults to real symbols
              var metric = data.default_metric || 'centrality';
              var range = metricRange(metric);

              // Defined BEFORE cytoscape(...) so the node 'background-color' style
              // callback can resolve byId() during the INITIAL style pass. `var`
              // hoists the name but not the assignment, so declaring these after
              // the constructor left nodeIndex undefined on first paint (TypeError;
              // nodes got no metric-driven fill until a control triggered recolor).
              var nodeIndex = {}; data.nodes.forEach(function (n) { nodeIndex[n.id] = n; });
              function byId(id) { return nodeIndex[id] || {}; }

              var cy = cytoscape({
                container: cyEl,
                elements: elements,
                style: [
                  { selector: 'node', style: {
                    'label': useReal ? 'data(real)' : 'data(opaque)',
                    'width': 'data(size)', 'height': 'data(size)',
                    'shape': 'data(shape)', 'background-color': function (n) { return colorFor(byId(n.id()), metric, range); },
                    'border-width': 2, 'border-color': '#0f1419',
                    'color': '#e6edf3', 'font-size': 9, 'text-valign': 'bottom', 'text-halign': 'center',
                    'text-outline-width': 2, 'text-outline-color': '#0f1419'
                  }},
                  { selector: 'edge', style: {
                    'width': 'data(w)', 'line-color': '#3d4853', 'target-arrow-color': '#3d4853',
                    'target-arrow-shape': 'triangle', 'curve-style': 'bezier'
                  }},
                  { selector: '.hot', style: { 'border-color': '#f85149', 'border-width': 4 } },
                  { selector: '.sel', style: { 'border-color': '#58a6ff', 'border-width': 4 } },
                  // Min-score filter hides (not deletes) nodes/edges so the filter
                  // is fully reversible and node data stays intact for tap/recolor.
                  { selector: '.filtered-out', style: { 'display': 'none' } }
                ],
                layout: { name: 'cose' }
              });

              function relabel() {
                cy.style().selector('node').style('label', useReal ? 'data(real)' : 'data(opaque)').update();
              }
              function recolor() {
                range = metricRange(metric);
                cy.style().selector('node').style('background-color', function (n) { return colorFor(byId(n.id()), metric, range); }).update();
              }

              var labelBtn = document.getElementById('btn-labels');
              if (labelBtn) labelBtn.onclick = function () { useReal = !useReal; relabel(); };
              var metricSel = document.getElementById('sel-metric');
              if (metricSel) { metricSel.value = metric; metricSel.onchange = function () { metric = this.value; recolor(); }; }
              var layoutSel = document.getElementById('sel-layout');
              if (layoutSel) layoutSel.onchange = function () { cy.layout({ name: this.value }).run(); };

              // ----- Min clutter-score filter -----------------------------------
              // DEFAULT HEURISTIC: focus on the worst offenders so the initial graph
              // isn't an overwhelming hairball. We sort all nodes by clutter desc and
              // pick the threshold that yields ~the top 120 nodes (midpoint of the
              // 100–150 target); if there are fewer than 120 scored nodes we keep the
              // threshold at 0 (show everything). The user can drag the slider to 0
              // to reveal the full graph. Re-layout is DEBOUNCED so dragging stays
              // smooth (visibility toggles immediately; layout runs after a pause).
              var DEFAULT_FOCUS_COUNT = 120;
              var clutterOf = {}; data.nodes.forEach(function (n) { clutterOf[n.id] = num(n.clutter_score); });
              var sortedClutter = data.nodes.map(function (n) { return num(n.clutter_score); }).sort(function (a, b) { return b - a; });
              var maxClutter = sortedClutter.length ? sortedClutter[0] : 0;
              var defaultThreshold = 0;
              if (sortedClutter.length > DEFAULT_FOCUS_COUNT) {
                // threshold = clutter of the (DEFAULT_FOCUS_COUNT)-th worst node, so
                // roughly the top ~DEFAULT_FOCUS_COUNT survive (>=, ties may add a few).
                defaultThreshold = sortedClutter[DEFAULT_FOCUS_COUNT - 1];
              }

              var rng = document.getElementById('rng-minscore');
              var numIn = document.getElementById('num-minscore');
              var countEl = document.getElementById('minscore-count');
              var totalNodes = data.nodes.length;
              var layoutTimer = null;

              function applyMinScore(threshold, relayout) {
                var shown = 0;
                cy.batch(function () {
                  cy.nodes().forEach(function (node) {
                    var c = clutterOf[node.id()];
                    if (c === undefined) c = 0;
                    if (c >= threshold) { node.removeClass('filtered-out'); shown++; }
                    else { node.addClass('filtered-out'); }
                  });
                  // Hide edges incident to any hidden node.
                  cy.edges().forEach(function (edge) {
                    var s = edge.source(), t = edge.target();
                    if (s.hasClass('filtered-out') || t.hasClass('filtered-out')) edge.addClass('filtered-out');
                    else edge.removeClass('filtered-out');
                  });
                });
                if (countEl) {
                  countEl.textContent = shown === 0
                    ? 'no nodes ≥ ' + (Math.round(threshold * 100) / 100) + ' — showing 0 of ' + totalNodes + ' nodes'
                    : 'showing ' + shown + ' of ' + totalNodes + ' nodes (min clutter ' + (Math.round(threshold * 100) / 100) + ')';
                }
                if (relayout) {
                  if (layoutTimer) clearTimeout(layoutTimer);
                  layoutTimer = setTimeout(function () {
                    var visible = cy.nodes().not('.filtered-out');
                    if (visible.length) visible.layout({ name: (layoutSel && layoutSel.value) || 'cose' }).run();
                  }, 200); // debounce: only re-layout after the drag pauses
                }
              }

              function setThreshold(v, relayout) {
                if (rng) rng.value = v;
                if (numIn) numIn.value = v;
                applyMinScore(parseFloat(v) || 0, relayout);
              }

              if (rng) {
                rng.min = 0; rng.max = maxClutter || 0; rng.step = (maxClutter > 0 ? maxClutter / 200 : 0.01) || 0.01;
                rng.value = defaultThreshold;
                rng.oninput = function () { if (numIn) numIn.value = this.value; applyMinScore(parseFloat(this.value) || 0, true); };
              }
              if (numIn) {
                numIn.max = maxClutter || 0;
                numIn.value = defaultThreshold;
                numIn.oninput = function () { if (rng) rng.value = this.value; applyMinScore(parseFloat(this.value) || 0, true); };
              }
              // Initial focused view (no re-layout needed — cose just ran on init).
              applyMinScore(defaultThreshold, false);

              document.querySelectorAll('button[data-hotspot]').forEach(function (btn) {
                btn.onclick = function () {
                  cy.nodes().removeClass('hot');
                  (data.hotspots[this.getAttribute('data-hotspot')] || []).forEach(function (id) {
                    var ele = cy.getElementById(id);
                    // A hotspot can be below the active min-score threshold; reveal
                    // it (drop filtered-out) so highlighting always shows it rather
                    // than silently no-op'ing on a hidden node.
                    ele.removeClass('filtered-out').addClass('hot');
                  });
                };
              });
              var resetBtn = document.getElementById('btn-reset');
              if (resetBtn) resetBtn.onclick = function () { cy.nodes().removeClass('hot sel'); };

              var side = document.getElementById('side');
              function showNode(n) {
                if (!side) return;
                var m = n.metrics || {};
                var rows = Object.keys(m).map(function (k) {
                  return '<dt>' + k + '</dt><dd>' + (m[k] === null ? 'null' : m[k]) + '</dd>';
                }).join('');
                var fl = n.resolved ? (n.file || '') + (n.line ? ':' + n.line : '') : '(unresolved)';
                var findings = (n.findings && n.findings.length) ? n.findings.join(', ') : 'none';
                side.innerHTML = '<h3>' + esc(n.symbol) + '</h3>' +
                  '<div class="muted">' + esc(fl) + ' &middot; ' + esc(n.kind) + '</div>' +
                  '<dl><dt>clutter</dt><dd>' + (n.clutter_score === null ? 'n/a' : n.clutter_score) + '</dd>' + rows + '</dl>' +
                  '<div class="muted">findings:</div><div>' + esc(findings) + '</div>';
              }
              function esc(s) { return String(s).replace(/[&<>]/g, function (c) { return { '&': '&amp;', '<': '&lt;', '>': '&gt;' }[c]; }); }

              cy.on('tap', 'node', function (evt) {
                cy.nodes().removeClass('sel'); evt.target.addClass('sel');
                showNode(byId(evt.target.id()));
              });

              // Event DELEGATION on <tbody>, not per-row handlers: pagination
              // detaches/re-attaches <tr> elements, so a handler bound to each row
              // at init would be lost for rows that weren't on the first page. A
              // single delegated listener survives every re-render.
              var tblBody = document.getElementById('tbl-body');
              if (tblBody) tblBody.addEventListener('click', function (evt) {
                var tr = evt.target.closest ? evt.target.closest('tr[data-node]') : null;
                if (!tr) return;
                var id = tr.getAttribute('data-node');
                var ele = cy.getElementById(id);
                if (ele && ele.length) {
                  // The clicked row may target a node hidden by the min-score
                  // filter; reveal it so center+highlight is visible.
                  ele.removeClass('filtered-out');
                  cy.nodes().removeClass('sel'); ele.addClass('sel');
                  cy.animate({ center: { eles: ele }, zoom: 1.5 }, { duration: 300 });
                  showNode(byId(id));
                }
              });
            })();
          JS
        end

        # ---- shared helpers ----------------------------------------------------

        def graph_nodes
          (context.graph && context.graph["nodes"]) || []
        end

        def edges
          (context.graph && context.graph["edges"]) || []
        end

        def resolve(id)
          return context.resolver.resolve(id) if context.resolver

          Model::Location.new(id: id, symbol: id, resolved: false)
        end

        def format_num(value)
          return "" if value.nil?
          return value.to_s if value.is_a?(Integer)
          return format("%.4f", value) if value.is_a?(Float)

          value.to_s
        end

        # HTML-escape text content / attribute values.
        def escape(text)
          text.to_s
              .gsub("&", "&amp;").gsub("<", "&lt;").gsub(">", "&gt;")
              .gsub('"', "&quot;").gsub("'", "&#39;")
        end
      end
    end
  end
end

Archbuddy::Report::Formatter.register(
  "html", Archbuddy::Report::Formatters::HtmlFormatter
)
