# frozen_string_literal: true

require "archbuddy/review"

# v0.16 T6: Review::ScoreRollup — presenter-lane SELECTION over
# engine-published score stamps (D-C1 dominance headline, D-C3 freshness
# consistency check, per-side provenance counts). D17 boundary: nothing in
# here computes a score; every expectation below selects/counts published
# values verbatim.
RSpec.describe Archbuddy::Review::ScoreRollup do
  FIXTURES = File.expand_path("../fixtures/review/vintages", __dir__)

  def node(score: nil, score_band: nil, score_raw: nil, branches: nil,
           outcome_arity: nil, collapse: nil, toll_booth: nil,
           absorb: nil, absorb_raw: nil, file: "a.rb", symbol: "A#m")
    Archbuddy::Review::Vintage::Node.new(
      file: file, symbol: symbol, kind: "function", klass: nil,
      branches: branches, decisions: 0, entrypoint: false,
      entrypoint_kind: nil, escapes: false, outcome_arity: outcome_arity,
      toll_booth: toll_booth, quadrant: nil, leverage: nil,
      collapse: collapse, score: score, score_band: score_band,
      score_raw: score_raw, absorb: absorb, absorb_raw: absorb_raw,
      serializer_version: 6,
      keys_present: %w[score score_band score_raw]
    )
  end

  describe ".ep_headline (D-C1 negative-first dominance truth table)" do
    it "selects min when min <= -1 ({-4.5, +4} => -4.5)" do
      expect(described_class.ep_headline([node(score: -4.5), node(score: 4.0)]))
        .to eq(-4.5)
    end

    it "negative-first: min <= -1 wins even against a larger positive ({-1.0, +4.5} => -1.0)" do
      expect(described_class.ep_headline([node(score: -1.0), node(score: 4.5)]))
        .to eq(-1.0)
    end

    it "selects max when no negative dominates and max >= +1 ({+4, 0} => +4, never a masking 0)" do
      expect(described_class.ep_headline([node(score: 4.0), node(score: 0.0)]))
        .to eq(4.0)
    end

    it "fires the poles exactly at the +/-1 boundary" do
      expect(described_class.ep_headline([node(score: -1.0)])).to eq(-1.0)
      expect(described_class.ep_headline([node(score: 1.0)])).to eq(1.0)
    end

    it "returns 0.0 when scored nodes exist but neither pole dominates ({0, 0} => 0)" do
      expect(described_class.ep_headline([node(score: 0.0), node(score: 0.0)])).to eq(0.0)
      expect(described_class.ep_headline([node(score: -0.99), node(score: 0.99)])).to eq(0.0)
    end

    it "returns nil on an empty cone ({} => nil — honest N/A, never 0)" do
      expect(described_class.ep_headline([])).to be_nil
    end

    it "returns nil when NO cone node carries a stamp (all-nil => nil)" do
      expect(described_class.ep_headline([node(score: nil), node(score: nil)])).to be_nil
    end

    it "selects over non-nil stamps only (nil stamps never mask a scored node)" do
      expect(described_class.ep_headline([node(score: nil), node(score: -4.5)]))
        .to eq(-4.5)
    end

    it "returns nil over a real pre-v6 vintage cone (v5 fixture — headline absent, never 0)" do
      graph = Archbuddy::Review::FragmentWalk.read(File.join(FIXTURES, "v5_small")).graph
      expect(described_class.ep_headline(graph.cone_nodes("Api::Widgets#GET[0]"))).to be_nil
    end
  end

  describe ".node_fresh? (D-C3 consistency-check truth table)" do
    it "is fresh when carried collapse equals round(branches / max(arity, 1), 2)" do
      expect(described_class.node_fresh?(
               node(branches: 8, outcome_arity: 2, collapse: 4.0)
             )).to be(true)
    end

    it "is stale when the body changed since the stamp (branches moved, collapse carried)" do
      expect(described_class.node_fresh?(
               node(branches: 16, outcome_arity: 2, collapse: 4.0)
             )).to be(false)
    end

    it "is false on a nil collapse stamp (never fresh by default)" do
      expect(described_class.node_fresh?(
               node(branches: 8, outcome_arity: 2, collapse: nil)
             )).to be(false)
    end

    it "is false on nil branches" do
      expect(described_class.node_fresh?(
               node(branches: nil, outcome_arity: 2, collapse: 1.0)
             )).to be(false)
    end

    it "treats nil arity as 1 (collapse == branches)" do
      expect(described_class.node_fresh?(
               node(branches: 3, outcome_arity: nil, collapse: 3.0)
             )).to be(true)
    end

    it "compares at the writer's round(2) published precision" do
      expect(described_class.node_fresh?(
               node(branches: 10, outcome_arity: 3, collapse: 3.33)
             )).to be(true)
      expect(described_class.node_fresh?(
               node(branches: 10, outcome_arity: 3, collapse: 3.3333333333)
             )).to be(false)
    end
  end

  describe ".side_provenance" do
    let(:analyzed_vintage) do
      Archbuddy::Review::Vintage.new(
        nodes: [
          node(file: "a.rb", symbol: "A#fresh", score: -4.5, branches: 8,
               outcome_arity: 2, collapse: 4.0, toll_booth: false),
          node(file: "a.rb", symbol: "A#stale", score: 2.0, branches: 16,
               outcome_arity: 2, collapse: 4.0, toll_booth: false),
          node(file: "b.rb", symbol: "B#unscored", score: nil, branches: 2,
               outcome_arity: 2, collapse: 1.0, toll_booth: false)
        ],
        edges: [],
        meta: { serializer_versions: [6], sources_count: 2 }
      )
    end

    it "counts scored nodes and stale stamps from the D-C3 detector" do
      expect(described_class.side_provenance(
               analyzed_vintage, source_label: "committed-cache", fresh_analyze: false
             )).to eq(
               source: "committed-cache",
               analyzed: true,
               serializer: [6],
               scored_nodes: 2,
               stale_stamps: 1
             )
    end

    it "reports zero stale stamps by construction on a fresh-analyze side (D-C3)" do
      provenance = described_class.side_provenance(
        analyzed_vintage, source_label: "analyze-sides", fresh_analyze: true
      )
      expect(provenance[:source]).to eq("analyze-sides")
      expect(provenance[:stale_stamps]).to eq(0)
      expect(provenance[:scored_nodes]).to eq(2)
    end

    it "reports a never-analyzed side honestly (analyzed false, zero counts)" do
      bare = Archbuddy::Review::Vintage.new(
        nodes: [node(file: "a.rb", symbol: "A#m", branches: 2, outcome_arity: 1)],
        edges: [],
        meta: { serializer_versions: [5], sources_count: 1 }
      )
      expect(described_class.side_provenance(
               bare, source_label: "stateless-collect", fresh_analyze: false
             )).to eq(
               source: "stateless-collect",
               analyzed: false,
               serializer: [5],
               scored_nodes: 0,
               stale_stamps: 0
             )
    end
  end
end
