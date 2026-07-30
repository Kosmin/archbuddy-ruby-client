# frozen_string_literal: true

require "tmpdir"
require "archbuddy"
require "archbuddy/review"
require_relative "../support/stub_vintage"

# v0.15 P2-T9: terminal formatter — the #2083-twin diff golden (finding
# lines, ep contributor sub-line, review-surface line, disclosure note,
# ratchet breach, summary), the Q9 lint document order, leaderboard
# rendering (20-cap + tail + tie sort + unreachable note), nil-tolerance.
RSpec.describe Archbuddy::Review::Formatters::Terminal do
  TERM_FIXTURES = File.expand_path("../fixtures/review/vintages", __dir__)

  Context = Archbuddy::Review::Formatter::ReviewContext

  def read(name)
    Archbuddy::Review::FragmentWalk.read(File.join(TERM_FIXTURES, name))
  end

  def build_config(yaml = nil)
    Dir.mktmpdir do |dir|
      File.write(File.join(dir, ".archbuddy.yml"), yaml) if yaml
      return Archbuddy::Config.load(target_root: dir, cli: {})
    end
  end

  def render(context)
    described_class.new(context).render
  end

  def base_context(**overrides)
    Context.new(
      command: "diff", target: ".", config_path: nil, advisory: false,
      fail_level: :error, base: { ref: "main", sha: "a" * 40, vintage: "committed-cache" },
      head: { sha: "b" * 40, vintage: "working-tree-cache", dirty: false },
      findings: [], grandfathered: [], not_evaluable: [], ratchet: [],
      excluded_files: [], calibration: { source: "none", provenance: nil, lines: [] },
      exit_code: 0, tool: { client: Archbuddy::VERSION, engine: nil, serializer: 5 },
      **overrides
    )
  end

  describe "the #2083-twin diff golden (through the REAL engine + delta)" do
    def twin_context
      base = read("twin_2083_base")
      head = read("twin_2083_head")
      delta = Archbuddy::Review::Delta.new(base: base, head: head)
      config = build_config(<<~YAML)
        version: 1
        rules:
          ComplexityRatchet:
            budgets:
              - { paths: ["app/api/**/*"], max_increase_log2: 0.0 }
      YAML
      result = Archbuddy::Review::RuleEngine.evaluate(vintage: head, delta: delta,
                                                      config: config, todo: nil)
      base_context(
        findings: result.findings, grandfathered: result.grandfathered,
        not_evaluable: result.not_evaluable, ratchet: result.ratchet,
        delta_summary: { counts: delta.counts, net_log2: delta.net_log2 },
        review_surface: result.review_surface, disclosures: delta.disclosures,
        exit_code: result.exit_code(:error)
      )
    end

    it "renders every pinned line byte-exact" do
      doc = render(twin_context)
      expect(doc).to include(
        "app/api/api/v1/redeem_templates.rb: Api::V1::RedeemTemplates#PATCH[0] " \
        "[ExponentialNode] error: own branching 65536 (2^16.0) exceeds 2^5 (Q4 boundary)"
      )
      expect(doc).to include("[MultiplicativeGrowth] error: branching grew +3.0 log2")
      expect(doc).to include("[UseCaseComplexity] warn: use case spans 65536 (2^16.0)")
      expect(doc).to include("\n  contributors: Api::V1::RedeemTemplates#PATCH[0] 65536 (2^16.0)\n")
      expect(doc).to include(
        "review surface: 1 use case(s) to re-verify (Σ 1 review reads) — 1 touched " \
        "node(s) statically unreachable from any use case (unresolved dispatch likely)"
      )
      expect(doc).to include(
        "note: 1 touched file(s) not reachable from any entrypoint: " \
        "app/models/program/redeem/template.rb"
      )
      expect(doc).to include(
        "ratchet app/api/**/*: net +3.000 log2 vs budget +0.000 — breach"
      )
      expect(doc).to include(
        "archbuddy diff: 2 error(s), 2 warning(s), 0 info — net Δlog2 +3.000 (base aaaaaaa)"
      )
      expect(doc).not_to match(/:\d+:/) # finding lines NEVER carry line numbers
    end
  end

  describe "lint document (Q9 order + leaderboard)" do
    def leaderboard_row(rank, ep, blog2, dividend: 2.0, cost_note: nil)
      { "rank" => rank, "ep" => ep, "kind" => "api", "file" => "app/api/#{ep.downcase}.rb",
        "branching_log2" => blog2, "mass" => 10, "reach" => 2, "files" => 1, "depth" => 2,
        "dividend" => dividend, "max_cone_node_log2" => blog2, "cost_note" => cost_note }
    end

    def lint_context(rows:, count:, unreachable: nil, **overrides)
      base_context(
        command: "lint",
        findings: [Archbuddy::Review::Finding.new(rule: "ExponentialNode", severity: :error,
                                                  file: "app/a.rb", symbol: "A#x",
                                                  message: "own branching 65536 (2^16.0) exceeds 2^5 (Q4 boundary)")],
        ratchet: [Archbuddy::Review::Findings::RatchetEntry.new(
          scope: "app/**/*", kind: "paths", scope_paths: ["app/**/*"], budget_log2: 0.0,
          verdict: nil, current_total_log2: 16.0, matched_files: 2, empty_scope: false
        )],
        grandfathered: [Archbuddy::Review::Findings::GrandfatherSkip.new(
          rule: "ExponentialNode", file: "app/b.rb", symbol: "B#y",
          recorded: 64, current: 64, healed: false
        )],
        calibration: { source: "builtin-study-v1", provenance: nil, lines: ["a line"] },
        use_cases: { count: count, leaderboard: rows, unreachable: unreachable },
        **overrides
      )
    end

    it "renders the Q9 section order: summary → findings → leaderboard → ratchet → grandfathered → impact" do
      doc = render(lint_context(rows: [leaderboard_row(1, "A#GET[0]", 6.0)], count: 1))
      order = [
        doc.index("archbuddy lint:"),
        doc.index("[ExponentialNode] error:"),
        doc.index("use cases (worst"),
        doc.index("ratchet app/**/*:"),
        doc.index("grandfathered:"),
        doc.index("impact: ")
      ]
      expect(order).to eq(order.compact.sort)
      expect(order).not_to include(nil)
    end

    it "renders the pinned row shape, sorts DESC with ep ASC tiebreak" do
      rows = [
        leaderboard_row(2, "B#GET[0]", 4.0),
        leaderboard_row(3, "C#GET[0]", 4.0),
        leaderboard_row(1, "A#GET[0]", 6.0, cost_note: "contains a Q4-boundary node")
      ]
      doc = render(lint_context(rows: rows, count: 3))
      expect(doc).to include(
        "  1. A#GET[0] — branching 2^6.0, mass 10, reach 2, files 1, depth 2, " \
        "dividend ×2 — contains a Q4-boundary node"
      )
      expect(doc.index("A#GET[0]")).to be < doc.index("B#GET[0]")
      expect(doc.index("B#GET[0]")).to be < doc.index("C#GET[0]")
    end

    it "caps at 20 rows with the tail line and renders the unreachable note" do
      rows = (1..25).map { |i| leaderboard_row(i, format("Ep%02d#GET[0]", i), 30.0 - i) }
      doc = render(lint_context(rows: rows, count: 25,
                                unreachable: { nodes: 1439, share: 1439.0 / 2366, files: 265 }))
      expect(doc.scan(/^  \d+\. Ep/).size).to eq(20)
      expect(doc).to include("  5 more use cases — --format json for the full table")
      expect(doc).to include(
        "note: 1439 of 2366 nodes (60.8%) not reachable from any entrypoint — excluded " \
        "from use-case metrics; still covered by ExponentialNode, MultiplicativeGrowth, " \
        "FirewallBreaches events, and ratchet path budgets"
      )
    end

    it "renders NO leaderboard section on a zero-ep lint" do
      doc = render(lint_context(rows: [], count: 0))
      expect(doc).not_to include("use cases (worst")
    end
  end

  describe "the reusability section (v0.16 T10 — mirrors the envelope block)" do
    def reusability_input
      { base: { source: "committed-cache", analyzed: true, serializer: [6],
                scored_nodes: 3, stale_stamps: 0 },
        head: { source: "working-tree-cache", analyzed: true, serializer: [6],
                scored_nodes: 4, stale_stamps: 1 },
        deltas: [
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

    it "renders the provenance line, null-tolerant delta lines, and the hedged absorb line" do
      doc = render(base_context(reusability: reusability_input,
                                delta_summary: { counts: {}, net_log2: 0.0 }))
      expect(doc).to include(
        "reusability: base committed-cache (3 scored) -> head " \
        "working-tree-cache (4 scored, 1 stale) — committed stamps reflect the last analyze"
      )
      expect(doc).to include(
        "  score A#PATCH[0] (app/api/a.rb): -4.23 -> -4.52 (Δraw -3750 milli) [GROWN]"
      )
      expect(doc).to include("  score B#GET[0] (app/api/b.rb): n/a -> +0 [NEW]")
      expect(doc).to include(
        "  absorb candidates (a listed function or a sibling at its call site " \
        "could absorb caller-side decisions): C#collection absorb +4.32 (raw 6.907)"
      )
    end

    it "renders NO reusability lines when the block is nil (scoreless sides)" do
      doc = render(base_context(delta_summary: { counts: {}, net_log2: 0.0 }))
      expect(doc).not_to include("reusability:")
    end

    it "renders no absorb line when there are no candidates (never an empty upsell)" do
      block = reusability_input.merge(absorb_candidates: [])
      doc = render(base_context(reusability: block,
                                delta_summary: { counts: {}, net_log2: 0.0 }))
      expect(doc).not_to include("absorb candidates")
    end
  end

  describe "degenerates + nil tolerance" do
    it "renders a summary-only document on an all-nil-optionals diff context" do
      doc = render(base_context(delta_summary: { counts: {}, net_log2: 0.0 }))
      expect(doc).to eq(
        "archbuddy diff: 0 error(s), 0 warning(s), 0 info — net Δlog2 +0.000 (base aaaaaaa)\n"
      )
    end

    it "renders union 0 honestly — never suppressed when the block is non-nil" do
      rs = { union: 0, sum: 0, eps: [], unreachable_touched: { count: 0, nodes: [] } }
      doc = render(base_context(review_surface: rs,
                                delta_summary: { counts: {}, net_log2: 0.0 }))
      expect(doc).to include("review surface: 0 use case(s) to re-verify (Σ 0 review reads)")
    end

    it "tolerates a fully nil-optional context (no crashes, no empty sections)" do
      context = Context.new(command: "diff", findings: nil, ratchet: nil,
                            grandfathered: nil, not_evaluable: nil, calibration: nil,
                            base: nil, delta_summary: nil)
      doc = render(context)
      expect(doc).to include("archbuddy diff: 0 error(s), 0 warning(s), 0 info")
      expect(doc).to include("(base injected)")
    end
  end
end
