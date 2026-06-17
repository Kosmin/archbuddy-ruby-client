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
              <div class="cards">#{cards}</div>
            </section>
          HTML
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
                <div class="score">#{escape(dim.score)}/100</div>
                <div class="q">#{escape(dim.question)}</div>
              </div>
            HTML
          end
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
              <div class="layout">
                <div id="cy"></div>
                <div id="side"><span class="muted">Click a node to inspect it.</span></div>
              </div>
            </section>
          HTML
        end

        def bottleneck_table_html
          metric_cols = %w[clutter_score centrality fan_in fan_out path_length]
          head = (["#", "Symbol", "file:line", "kind"] + metric_cols)
                 .map { |h| "<th>#{escape(h)}</th>" }.join
          rows = context.ranked.each_with_index.map do |b, i|
            bottleneck_row(b, i + 1, metric_cols)
          end.join("\n")

          <<~HTML
            <section id="table">
              <h2>Ranked Bottlenecks (by clutter_score)</h2>
              <table>
                <thead><tr>#{head}</tr></thead>
                <tbody>#{rows}</tbody>
              </table>
            </section>
          HTML
        end

        def bottleneck_row(bottleneck, rank, metric_cols)
          loc = bottleneck.location
          sym = loc.resolved? ? escape(loc.symbol) : %(<span class="unresolved">#{escape(loc.symbol)}</span>)
          cells = metric_cols.map do |key|
            val = key == "clutter_score" ? bottleneck.clutter_score : bottleneck.metrics[key]
            %(<td class="num">#{escape(format_num(val))}</td>)
          end.join
          <<~HTML.chomp
            <tr data-node="#{escape(bottleneck.id)}">
              <td class="num">#{rank}</td><td>#{sym}</td>
              <td>#{escape(loc.file_line)}</td><td>#{escape(bottleneck.kind || 'unknown')}</td>
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
            "default_metric" => "centrality"
          }
          # Embed as JSON inside a <script type="application/json"> — escape the
          # only sequence that could close the tag early so the blob stays inert.
          JSON.generate(payload).gsub("</", '<\/')
        end

        # One entry per graph.yml node, de-anonymized. Metrics/clutter joined from
        # the ranked bottlenecks (verbatim) keyed by opaque id.
        def graph_node_data
          by_id = context.ranked.each_with_object({}) { |b, h| h[b.id] = b }
          graph_nodes.map do |gn|
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

        def graph_edge_data
          edges.map { |e| { "from" => e["from"], "to" => e["to"], "calls" => e["calls"] || 1 } }
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

        def hotspot_ids_by_dimension
          return {} if context.scores.nil?

          context.scores.each_with_object({}) do |dim, h|
            h[dim.key] = dim.hotspots.map { |hs| hs.location.id }
          end
        end

        def init_script
          # Vanilla JS: parse the inlined data, build the Cytoscape graph (built-in
          # layouts only), wire the controls, side panel, and table cross-select.
          <<~'JS'
            (function () {
              var data = JSON.parse(document.getElementById('archbuddy-data').textContent);
              var cyEl = document.getElementById('cy');
              if (!cyEl || typeof cytoscape === 'undefined' || !data.nodes.length) return;

              var SHAPE = { function: 'ellipse', endpoint: 'round-rectangle', db_op: 'diamond', external: 'hexagon' };
              function num(v) { return (typeof v === 'number' && isFinite(v)) ? v : 0; }

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
                  { selector: '.sel', style: { 'border-color': '#58a6ff', 'border-width': 4 } }
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

              document.querySelectorAll('button[data-hotspot]').forEach(function (btn) {
                btn.onclick = function () {
                  cy.nodes().removeClass('hot');
                  (data.hotspots[this.getAttribute('data-hotspot')] || []).forEach(function (id) {
                    cy.getElementById(id).addClass('hot');
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

              document.querySelectorAll('tbody tr[data-node]').forEach(function (tr) {
                tr.onclick = function () {
                  var id = this.getAttribute('data-node');
                  var ele = cy.getElementById(id);
                  if (ele && ele.length) {
                    cy.nodes().removeClass('sel'); ele.addClass('sel');
                    cy.animate({ center: { eles: ele }, zoom: 1.5 }, { duration: 300 });
                    showNode(byId(id));
                  }
                };
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
