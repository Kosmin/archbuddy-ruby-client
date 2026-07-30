# frozen_string_literal: true

require "archbuddy/review"

# v0.15 P2-T1: the Review::Vintage per-node table keyed (file, symbol) —
# identity, memoized out-edges (R32), eps, evaluability flags (R31), and the
# empty-vintage degenerate.
RSpec.describe Archbuddy::Review::Vintage do
  def node(file:, symbol:, branches: 1, entrypoint: false, toll_booth: nil,
           escapes: false, outcome_arity: 1, keys: nil,
           score: nil, score_band: nil, score_raw: nil)
    described_class::Node.new(
      file: file, symbol: symbol, kind: "function", klass: nil,
      branches: branches, decisions: 0, entrypoint: entrypoint,
      entrypoint_kind: entrypoint ? "grape" : nil, escapes: escapes,
      outcome_arity: outcome_arity, toll_booth: toll_booth, quadrant: nil,
      leverage: nil, collapse: nil, score: score, score_band: score_band,
      score_raw: score_raw, absorb: nil, absorb_raw: nil,
      serializer_version: 5,
      keys_present: keys || %w[branches symbol]
    )
  end

  let(:nodes) do
    [
      node(file: "a.rb", symbol: "A#x", branches: 4, entrypoint: true),
      node(file: "a.rb", symbol: "A#y", branches: 2),
      node(file: "b.rb", symbol: "B#z", branches: 1, toll_booth: false)
    ]
  end

  let(:edges) do
    [
      { from: "A#x", to: "A#y", calls: 2 },
      { from: "A#x", to: "A#y", calls: 3 },  # second (from,to) record: calls SUM (R32)
      { from: "A#x", to: "Ext.sink", calls: 1 },
      { from: "A#y", to: "B#z", calls: 1 }
    ]
  end

  subject(:vintage) { described_class.new(nodes: nodes, edges: edges) }

  it "keys nodes by (file, symbol)" do
    expect(vintage["a.rb", "A#x"].branches).to eq(4)
    expect(vintage["b.rb", "B#z"].branches).to eq(1)
    expect(vintage["a.rb", "missing"]).to be_nil
    expect(vintage.by_identity.keys).to contain_exactly(
      ["a.rb", "A#x"], ["a.rb", "A#y"], ["b.rb", "B#z"]
    )
  end

  it "memoizes out-edges collapsed per (from,to) with calls summed (R32)" do
    expect(vintage.out_edges("A#x")).to contain_exactly(
      { to: "A#y", calls: 5 }, { to: "Ext.sink", calls: 1 }
    )
    expect(vintage.out_edges("A#y")).to eq([{ to: "B#z", calls: 1 }])
    expect(vintage.out_edges("B#z")).to eq([])
    # mass = Σ calls; out_degree = count
    expect(vintage.out_edges("A#x").sum { |e| e[:calls] }).to eq(6)
    expect(vintage.out_edges("A#x").size).to eq(2)
  end

  it "exposes eps, files, node_count" do
    expect(vintage.eps.map(&:symbol)).to eq(["A#x"])
    expect(vintage.files).to eq(%w[a.rb b.rb])
    expect(vintage.node_count).to eq(3)
    expect(vintage).not_to be_empty
  end

  describe "evaluability flags (R31)" do
    it "edges? true when edges were carried" do
      expect(vintage.edges?).to be(true)
    end

    it "edges? honors the explicit fragment-level flag over edge emptiness" do
      no_edges = described_class.new(nodes: nodes, edges: [], edges_present: true)
      expect(no_edges.edges?).to be(true)

      v1_shaped = described_class.new(nodes: nodes, edges: [], edges_present: false)
      expect(v1_shaped.edges?).to be(false)
    end

    it "analyzed? true iff >=1 node carries a non-nil toll_booth" do
      expect(vintage.analyzed?).to be(true) # B#z toll_booth false (a real verdict)

      collect_only = described_class.new(
        nodes: [node(file: "a.rb", symbol: "A#x")], edges: []
      )
      expect(collect_only.analyzed?).to be(false)
    end
  end

  describe "score members (v0.16 T5)" do
    it "carries the engine-published triple verbatim; nil when unstamped" do
      scored = node(file: "a.rb", symbol: "A#m", score: -4.52, score_band: -5,
                    score_raw: -18.75,
                    keys: %w[branches symbol score score_band score_raw])
      expect(scored.score).to eq(-4.52)
      expect(scored.score_band).to eq(-5)
      expect(scored.score_raw).to eq(-18.75)

      bare = node(file: "a.rb", symbol: "A#n")
      expect(bare.score).to be_nil
      expect(bare.score_band).to be_nil
      expect(bare.score_raw).to be_nil
      expect(bare.keys_present).not_to include("score", "score_band", "score_raw")
    end

    it "does not widen analyzed? — the R31 gate stays toll_booth-driven" do
      score_only = described_class.new(
        nodes: [node(file: "a.rb", symbol: "A#m", score: -1.0, score_band: -1,
                     score_raw: -1.5)],
        edges: []
      )
      expect(score_only.analyzed?).to be(false)
    end
  end

  describe "degenerate: empty vintage" do
    it "is a legal value — empty, zero nodes, no error" do
      empty = described_class.new(nodes: [], edges: [])
      expect(empty).to be_empty
      expect(empty.nodes).to eq([])
      expect(empty.node_count).to eq(0)
      expect(empty.eps).to eq([])
      expect(empty.out_edges("anything")).to eq([])
    end
  end

  it "carries meta with serializer_versions and sources_count" do
    v = described_class.new(nodes: [], edges: [],
                            meta: { serializer_versions: [5], sources_count: 3 })
    expect(v.meta).to eq(serializer_versions: [5], sources_count: 3)
  end
end
