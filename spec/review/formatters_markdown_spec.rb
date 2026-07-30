# frozen_string_literal: true

require "tmpdir"
require "archbuddy"
require "archbuddy/review"
require_relative "../support/stub_vintage"

# v0.15 P2-T10: markdown — dual-use document under the 65,536-char comment
# cap: findings details capped at 50, use-case table 20 open + 21–120 in
# <details> + tail, ep rows render `—` in value/limit, review-surface
# section, byte-determinism.
RSpec.describe Archbuddy::Review::Formatters::Markdown do
  Ctx = Archbuddy::Review::Formatter::ReviewContext

  def base_ctx(**overrides)
    Ctx.new(
      command: "diff", target: ".", advisory: false, fail_level: :error,
      base: { ref: "main", sha: "a" * 40, vintage: "committed-cache" },
      findings: [], grandfathered: [], not_evaluable: [], ratchet: [],
      excluded_files: [], calibration: { source: "none", provenance: nil, lines: [] },
      exit_code: 0, tool: {}, delta_summary: { counts: {}, net_log2: 0.0 },
      **overrides
    )
  end

  def render(context)
    described_class.new(context).render
  end

  def finding(index, severity: :warn)
    Archbuddy::Review::Finding.new(
      rule: "ExponentialNode", severity: severity, file: "app/f#{index}.rb",
      symbol: "F#{index}#x", message: "own branching 64 (2^6.0) exceeds 2^5 (Q4 boundary)",
      value_raw: 64, threshold_raw: 32
    )
  end

  def leaderboard_row(rank)
    { "rank" => rank, "ep" => "Ep#{rank}#GET[0]", "kind" => "api",
      "file" => "app/api/ep#{rank}.rb", "branching_log2" => 30.0 - (rank * 0.1),
      "mass" => 5, "reach" => 2, "files" => 1, "depth" => 2, "dividend" => 2.0,
      "max_cone_node_log2" => 4.0, "cost_note" => nil }
  end

  it "caps the findings details at 50 rows with the +10 more tail" do
    doc = render(base_ctx(findings: (1..60).map { |i| finding(i) }))
    details = doc[doc.index("<details><summary>All findings (60)</summary>")..]
    expect(details.scan(/^\| ExponentialNode \|/).size).to eq(50)
    expect(details).to include("+10 more (see the JSON artifact)")
    expect(doc.length).to be < 65_536
  end

  it "renders the 130-ep lint leaderboard as 20 open + 100 details + the +10 tail" do
    doc = render(base_ctx(command: "lint", base: nil, delta_summary: nil,
                          use_cases: { count: 130,
                                       leaderboard: (1..130).map { |i| leaderboard_row(i) },
                                       unreachable: nil }))
    open_section = doc[doc.index("### use cases")...doc.index("<details><summary>use cases")]
    expect(open_section.scan(/^\| \d+ \|/).size).to eq(20)
    details = doc[doc.index("<details><summary>use cases 21–120</summary>")..]
    expect(details.scan(/^\| \d+ \|/).size).to eq(100)
    expect(doc).to include("+10 more (see the JSON artifact)")
    expect(doc.length).to be < 65_536
  end

  it "renders — in value/limit on ep findings (multi-component)" do
    ep_finding = Archbuddy::Review::Finding.new(
      rule: "UseCaseComplexity", severity: :warn, file: "app/api/a.rb",
      symbol: "A#GET[0]", message: "use case spans …",
      components: { "max_cone_node_log2" => { value: 16.0, threshold: 5.0, breached: true } }
    )
    doc = render(base_ctx(findings: [ep_finding]))
    expect(doc).to include("| UseCaseComplexity | warn | `A#GET[0]` — app/api/a.rb | — | — | — |")
  end

  it "renders the review-surface section with table + blockquote notes" do
    rs = { union: 2, sum: 2,
           eps: [{ file: "a.rb", ep_symbol: "A#PATCH[0]", branching_log2: 1.0,
                   classification: :new },
                 { file: "a.rb", ep_symbol: "A#GET[0]", branching_log2: 0.0,
                   classification: :new }],
           unreachable_touched: { count: 1, nodes: [{ file: "b.rb", symbol: "B#x" }] } }
    doc = render(base_ctx(review_surface: rs,
                          disclosures: { orphan_touched_files: ["b.rb"],
                                         offsetting_zero_count: 0 }))
    expect(doc).to include("**2 use case(s) to re-verify** (Σ 2 review reads)")
    expect(doc).to include("| `A#PATCH[0]` | NEW | 1.000 |")
    expect(doc).to include("> 1 touched node(s) statically unreachable from any use case")
    expect(doc).to include("> note: 1 touched file(s) not reachable from any entrypoint: b.rb")
  end

  describe "the reusability section (v0.16 T10 — mirrors the envelope block)" do
    def reusability_input(deltas: nil)
      { base: { source: "committed-cache", analyzed: true, serializer: [6],
                scored_nodes: 3, stale_stamps: 0 },
        head: { source: "working-tree-cache", analyzed: true, serializer: [6],
                scored_nodes: 4, stale_stamps: 1 },
        deltas: deltas || [
          { file: "app/api/a.rb", symbol: "A#PATCH[0]", classification: :grown,
            base: { score: -4.23, score_raw: -15.0 },
            head: { score: -4.52, score_raw: -18.75 },
            delta_raw_milli: -3750 },
          { file: "app/api/b.rb", symbol: "B#GET[0]", classification: :new,
            base: nil, head: { score: 0.0, score_raw: 0.0 },
            delta_raw_milli: nil }
        ],
        absorb_candidates: [
          { file: "app/api/c.rb", symbol: "C#collection", score: 0.0,
            absorb: 4.32, absorb_raw: 6.907 }
        ] }
    end

    def delta_row(index)
      { file: "app/api/d#{index}.rb", symbol: "D#{index}#x", classification: :grown,
        base: { score: -1.0, score_raw: -1.5 },
        head: { score: -1.0 - (index / 100.0), score_raw: -1.6 },
        delta_raw_milli: -100 }
    end

    it "renders the provenance line, the null-tolerant delta table, and the absorb blockquote" do
      doc = render(base_ctx(reusability: reusability_input))
      expect(doc).to include("### reusability")
      expect(doc).to include(
        "base committed-cache (3 scored) → head working-tree-cache " \
        "(4 scored, 1 stale) — _committed stamps reflect the last analyze_"
      )
      expect(doc).to include(
        "| `A#PATCH[0]` — app/api/a.rb | GROWN | -4.23 | -4.52 | -3750 |"
      )
      expect(doc).to include("| `B#GET[0]` — app/api/b.rb | NEW | — | +0 | — |")
      expect(doc).to include(
        "> absorb candidates — a listed function or a sibling at its call site " \
        "could absorb caller-side decisions: `C#collection` absorb +4.32 (raw 6.907)"
      )
    end

    it "caps the delta table at 10 open rows with the JSON-artifact tail" do
      doc = render(base_ctx(reusability: reusability_input(
        deltas: (1..14).map { |i| delta_row(i) }
      )))
      section = doc[doc.index("### reusability")..]
      expect(section.scan(/^\| `D\d+#x`/).size).to eq(10)
      expect(section).to include("+4 more (see the JSON artifact)")
    end

    it "renders NO section when the block is nil, and never in lint" do
      expect(render(base_ctx)).not_to include("### reusability")
      lint = base_ctx(command: "lint", base: nil, delta_summary: nil,
                      use_cases: { count: 0, leaderboard: [], unreachable: nil },
                      reusability: reusability_input)
      expect(render(lint)).not_to include("### reusability")
    end
  end

  it "renders the headline + gate + advisory variants deterministically" do
    context = base_ctx(findings: [finding(1, severity: :error)], exit_code: 1)
    doc = render(context)
    expect(doc).to include("## archbuddy diff — 1 error(s), 0 warning(s) (base aaaaaaa)")
    expect(doc).to include("**GATE: exit 1**")
    expect(render(context)).to eq(doc)

    advisory = render(base_ctx(advisory: true))
    expect(advisory).to include("_advisory run — exit 0_")
  end
end
