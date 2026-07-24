# frozen_string_literal: true

require "archbuddy/review"

# v0.15 P2-N1: the client variety-fold replica — V_now/V_floor/dividend per
# ep, natural-log folds mirroring the engine (path_count.rb:331-397,
# cost_policy.rb:62-66, project_scorer.rb:664-672), the hard N/A gate, the
# published_cap synthetic, and the fallback taint.
#
# Exact-integer expectations are asserted at PUBLISHED ROUNDING (round(6)):
# IEEE exp(ln(x)) does not round-trip bitwise (Math.exp(Math.log(8192)) ==
# 8191.9999999999945) — the same bar R2's block-exact parity used (M2).
RSpec.describe "Review::Graph variety folds (P2-N1)" do
  FIXTURES = File.expand_path("../fixtures/review/vintages", __dir__)

  def node(symbol:, file: "x.rb", branches: 1, kind: "function", entrypoint: false,
           entrypoint_kind: nil, escapes: false, outcome_arity: 1)
    Archbuddy::Review::Vintage::Node.new(
      file: file, symbol: symbol, kind: kind, klass: nil,
      branches: branches, decisions: 0, entrypoint: entrypoint,
      entrypoint_kind: entrypoint_kind, escapes: escapes,
      outcome_arity: outcome_arity, toll_booth: nil, quadrant: nil,
      leverage: nil, collapse: nil, serializer_version: 5,
      keys_present: %w[branches symbol outcome_arity escapes]
    )
  end

  def edge(from, to, calls = 1)
    { from: from, to: to, calls: calls }
  end

  def graph(nodes, edges)
    Archbuddy::Review::Graph.new(nodes: nodes, edges: edges)
  end

  describe "the redeem-shaped Q5 base profile (all inline decisions, arity-1 contract)" do
    let(:row) do
      g = graph(
        [node(symbol: "ep", branches: 8192, kind: "endpoint", entrypoint: true,
              entrypoint_kind: "grape", outcome_arity: 1),
         node(symbol: "callee", branches: 1, outcome_arity: 1)],
        [edge("ep", "callee"), edge("ep", "Ext.save"), edge("callee", "Ext.where")]
      )
      g.ep_metrics[["x.rb", "ep"]]
    end

    it "folds vty_log == ln(8192), floor 0, dividend 8192" do
      expect(row.vty_log).to be_within(1e-9).of(Math.log(8192))
      expect(row.v_now_log2).to be_within(1e-9).of(13.0)
      expect(row.vty_floor_log).to eq(0.0)
      expect(row.v_floor_log2).to eq(0.0)
      expect(row.dividend.round(6)).to eq(8192.0)
      expect(row.dividend_log2).to be_within(1e-9).of(13.0)
      expect(row.published_variety.round(6)).to eq(8192.0)
      expect(row.capped?).to be(false)
    end
  end

  describe "the escape variant (path_count.rb:362-376 — extraction cannot collapse an escape)" do
    it "keeps FULL b_log in the floor's own term on the escaping comp" do
      g = graph(
        [node(symbol: "ep", branches: 1, kind: "endpoint", entrypoint: true,
              entrypoint_kind: "grape", outcome_arity: 1),
         node(symbol: "callee", branches: 8192, outcome_arity: 1, escapes: true)],
        [edge("ep", "callee"), edge("callee", "Ext.where")]
      )
      row = g.ep_metrics[["x.rb", "ep"]]
      expect(row.vty_log).to be_within(1e-9).of(Math.log(8192))
      expect(row.vty_floor_log).to be_within(1e-9).of(Math.log(8192))
      expect(row.vty_floor_log).to be > 0
      expect(row.dividend).to eq(1.0) # exact: exp(0.0)
    end
  end

  describe "the fallback variant (L17 conservative — nil-arity function comp)" do
    it "substitutes the full subtree value in BOTH folds and taints the ep" do
      g = graph(
        [node(symbol: "ep", branches: 4, kind: "endpoint", entrypoint: true,
              entrypoint_kind: "grape", outcome_arity: 1),
         node(symbol: "callee", branches: 8, kind: "function", outcome_arity: nil)],
        [edge("ep", "callee"), edge("callee", "Ext.where")]
      )
      row = g.ep_metrics[["x.rb", "ep"]]
      expect(row.vty_log).to be_within(1e-9).of(Math.log(4) + Math.log(8))
      expect(row.vty_floor_log).to be_within(1e-9).of(Math.log(8))
      expect(row.dividend.round(6)).to eq(4.0)
      expect(g.variety_fallback?("ep")).to be(true)
      expect(g.variety_fallback?("callee")).to be(true)
    end
  end

  describe "the HARD N/A gate (path_count.rb:332-336 — the fold never runs)" do
    it "keeps every variety member nil when NO vertex carries outcome_arity" do
      g = graph(
        [node(symbol: "ep", branches: 8192, kind: "endpoint", entrypoint: true,
              entrypoint_kind: "grape", outcome_arity: nil),
         node(symbol: "callee", branches: 2, outcome_arity: nil)],
        [edge("ep", "callee")]
      )
      row = g.ep_metrics[["x.rb", "ep"]]
      expect(row.vty_log).to be_nil
      expect(row.vty_floor_log).to be_nil
      expect(row.dividend).to be_nil
      expect(row.dividend_log2).to be_nil
      expect(row.top_dividend_nodes).to be_nil
      expect(row.published_variety).to be_nil
      expect(g.variety_fallback?("ep")).to be_nil
      # non-variety members unaffected
      expect(row.branching_log2).to eq(Math.log2(8192) + 1.0)
      expect(row.reach).to eq(2)
    end
  end

  describe "the published_cap fixture (Q1 — never exercised by real data)" do
    it "caps published variety AND dividend at 1e6; dividend_log2 stays raw" do
      vintage = Archbuddy::Review::FragmentWalk.read(File.join(FIXTURES, "published_cap"))
      row = vintage.graph.ep_metrics[["app/api/capped.rb", "Api::Capped#GET[0]"]]
      expect(row.capped?).to be(true)
      expect(row.published_variety).to eq(1_000_000.0)
      expect(row.dividend).to eq(1_000_000.0)
      expect(row.dividend_log2).to be_within(1e-6).of(20.0)
      expect(row.vty_floor_log).to eq(0.0)
    end
  end

  describe "the arity floor (load-bearing — Math.log(0) would poison the fold)" do
    it "raises VintageError loudly on outcome_arity < 1" do
      g = graph(
        [node(symbol: "ep", branches: 2, kind: "endpoint", entrypoint: true,
              entrypoint_kind: "grape", outcome_arity: 0),
         node(symbol: "other", branches: 2, outcome_arity: 1)],
        [edge("ep", "other")]
      )
      expect { g.ep_metrics }
        .to raise_error(Archbuddy::Review::VintageError, /invalid outcome_arity 0 on x\.rb: ep/)
    end
  end

  describe "top_dividend_nodes (extraction-gap ranking)" do
    it "ranks by (log2 b_own − log2 min(b_own, arity)) desc; nil-arity ranks by full log2" do
      g = graph(
        [node(symbol: "ep", branches: 2, kind: "endpoint", entrypoint: true,
              entrypoint_kind: "grape", outcome_arity: 1),
         node(symbol: "wide_contract", branches: 64, outcome_arity: 64), # gap 0
         node(symbol: "collapsible", branches: 64, outcome_arity: 2),    # gap 5
         node(symbol: "unknowable", branches: 16, outcome_arity: nil, kind: "db_op")], # gap 4
        [edge("ep", "wide_contract"), edge("ep", "collapsible"), edge("ep", "unknowable")]
      )
      row = g.ep_metrics[["x.rb", "ep"]]
      expect(row.top_dividend_nodes.map { |n| n[:symbol] })
        .to eq(%w[collapsible unknowable ep wide_contract])
    end
  end
end
