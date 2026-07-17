# frozen_string_literal: true

require "archbuddy/report"
require "archbuddy/report/formatter"
require "archbuddy/report/business_impact"

# v0.11 W-C (L6/L17): the ONE shared Business Impact presenter — five verbatim
# business questions + the ungraded branching footer, every number a VERBATIM
# engine figure, omission-not-fabrication throughout. These specs pin the
# EXACT copy strings (byte-level) and the nil-tolerance rules both formatters
# rely on.
RSpec.describe Archbuddy::Report::BusinessImpact do
  BI = described_class
  RS = Archbuddy::Report::Scores

  def context_with(**fields)
    Archbuddy::Report::Formatter::RenderContext.new(
      ranked: [], class_rollups: [], generator: {}, **fields
    )
  end

  def dim(key, score:, grade:, median: nil, median_grade: nil, capped_fraction: nil)
    RS::DimensionScore.new(
      key: key, label: key, question: "", score: score, grade: grade,
      hotspots: [], median: median, median_grade: median_grade,
      capped_fraction: capped_fraction
    )
  end

  # The MEASURED plan numbers (L14/L15/L16 — the I8 worked examples).
  let(:blast) do
    RS::BlastRadius.new(
      max: 1569, p90: 3.0, median: 1.0, mean: 121.38,
      reached_nodes: 5506, total_nodes: 16_173, total_entrypoints: 1611,
      pct_use_cases_hit_by_worst: 0.9739,
      worst: [
        RS::BlastRadius::Worst.new(symbol: "Router#dispatch", use_cases_affected: 1569, added_coupling: 7.5),
        RS::BlastRadius::Worst.new(symbol: "App#boot", use_cases_affected: 900, added_coupling: nil)
      ]
    )
  end
  let(:fwd_depth) { RS::DepthStats.new(mean: 2.83, median: 2.0, count: 1611) }
  let(:rev_depth) { RS::DepthStats.new(mean: 3.42, median: 3.0, count: 5506) }
  let(:branching) { RS::BranchingFactor.new(mean: 2649.6, median: 2.416, count: 1611) }
  let(:reverse_dim) do
    dim("reverse_traceability", score: 32_402.84, grade: "F",
                                median: 1_000_000.0, median_grade: "F", capped_fraction: 0.9764)
  end
  let(:forward_dim) do
    dim("forward_discoverability", score: 30_992.17, grade: "F",
                                   median: 2.0, median_grade: "A", capped_fraction: 0.0214)
  end

  describe "the pinned verbatim question copy (L17)" do
    it "pins each question's text string byte-exactly" do
      expect(BI::Q1_TEXT).to eq("Implementing a new feature: how much complexity will a developer face?")
      expect(BI::Q2_TEXT).to eq("Fixing a bug: how hard is it to trace where the code you're changing is used?")
      expect(BI::Q3_TEXT).to eq("Breaking something: how many use cases can a single change put at risk?")
      expect(BI::Q4_TEXT).to eq("Implementing a new feature: how many steps does a new flow travel end-to-end?")
      expect(BI::Q5_TEXT).to eq("Fixing a bug: how deep is the trace from a use case down to the code?")
      expect(BI::BF_TEXT).to eq("Branching")
    end
  end

  describe "the I8 worked examples (byte-exact answers)" do
    it "q3: the measured nexus blast numbers" do
      qs = BI.questions(context_with(blast_radius: blast))
      q3 = qs.find { |q| q.id == "q3" }
      expect(q3.answer).to eq(
        "the worst single node is reachable from 1569 of 1611 use cases (97.4%) — p90 3, median 1"
      )
      expect(q3.grade).to be_nil # ungraded row
      # factors displayed SEPARATELY (R7) — the product is never printed
      expect(q3.detail_lines).to eq(
        ["worst offenders: Router#dispatch (1569 use cases, +7.5 coupling); App#boot (900 use cases)"]
      )
    end

    it "q2: capped reverse dimension → median 'at cap' + lower-bound note" do
      qs = BI.questions(context_with(scores: [reverse_dim]))
      q2 = qs.find { |q| q.id == "q2" }
      expect(q2.answer).to eq(
        "cost mean 32402.8 (F, median: F) · median at cap — 97.6% of routes at cap (lower bound)"
      )
      expect(q2.grade).to eq("F")
    end

    it "q4: depth medians pin to one decimal; the worst clause drops (no max in 1.6 — C3)" do
      qs = BI.questions(context_with(forward_depth: fwd_depth))
      q4 = qs.find { |q| q.id == "q4" }
      expect(q4.answer).to eq("a typical use case is 2.0 functions deep (mean 2.8)")
    end

    it "q5: reverse depth" do
      qs = BI.questions(context_with(reverse_depth: rev_depth))
      q5 = qs.find { |q| q.id == "q5" }
      expect(q5.answer).to eq("a typical trace is 3.0 functions deep (mean 3.4)")
    end

    it "bf: median-FIRST (L15 — the mean is degenerate-dominated)" do
      qs = BI.questions(context_with(branching_factor: branching))
      bf = qs.find { |q| q.id == "bf" }
      expect(bf.answer).to eq("each step of tracing multiplies the choices ×2.42 (median; mean 2649.6)")
      expect(bf.grade).to be_nil
    end
  end

  describe "cap-note thresholds" do
    it "renders NO cap note at capped_fraction 0 (and none when nil — unknown is not zero)" do
      zero = dim("reverse_traceability", score: 61.0, grade: "C", median: 30.0, capped_fraction: 0.0)
      q2 = BI.questions(context_with(scores: [zero])).find { |q| q.id == "q2" }
      expect(q2.answer).to eq("cost mean 61.0 (C) · median 30.0")

      unknown = dim("reverse_traceability", score: 61.0, grade: "C", median: 30.0)
      q2 = BI.questions(context_with(scores: [unknown])).find { |q| q.id == "q2" }
      expect(q2.answer).to eq("cost mean 61.0 (C) · median 30.0")
    end

    it "annotates 0 < f < 0.5 with the lower-bound note but keeps the real median number" do
      partial = dim("reverse_traceability", score: 61.0, grade: "C", median: 30.0, capped_fraction: 0.12)
      q2 = BI.questions(context_with(scores: [partial])).find { |q| q.id == "q2" }
      expect(q2.answer).to eq("cost mean 61.0 (C) · median 30.0 — 12.0% of routes at cap (lower bound)")
    end

    it "renders 'at cap' instead of the falsely-precise median at f >= 0.5" do
      capped = dim("reverse_traceability", score: 61.0, grade: "C", median: 1_000_000.0, capped_fraction: 0.5)
      q2 = BI.questions(context_with(scores: [capped])).find { |q| q.id == "q2" }
      expect(q2.answer).to eq("cost mean 61.0 (C) · median at cap — 50.0% of routes at cap (lower bound)")
    end
  end

  describe "q1 sourcing (entrypoints first, dimension fallback)" do
    it "reads mean/median from the committed entrypoints block with the by-category detail line" do
      ep = RS::EntrypointCount.new(
        total: 4, count: 4, by_category: { "controllers" => 4 },
        mean: 27.14, median: 12.0,
        by_category_cost: { "controllers" => { "mean" => 30.0, "median" => 14.0, "grade" => "C" } }
      )
      q1 = BI.questions(context_with(entrypoints: ep, scores: [forward_dim])).find { |q| q.id == "q1" }
      expect(q1.answer).to eq(
        "cost mean 27.1 (F, median: A) · median 12.0 — 2.1% of routes at cap (lower bound)"
      )
      expect(q1.detail_lines).to eq(["by category: controllers mean 30.0 / median 14.0 (C)"])
      expect(q1.grade).to eq("F")
    end

    it "falls back to the forward dimension on a v1 scores-bearing doc (mean+grade only, no median clause)" do
      v1_fwd = dim("forward_discoverability", score: 82.0, grade: "B")
      q1 = BI.questions(context_with(scores: [v1_fwd])).find { |q| q.id == "q1" }
      expect(q1.answer).to eq("cost mean 82.0 (B)")
      expect(q1.detail_lines).to eq([])
    end
  end

  describe "omission, never fabrication" do
    it "returns [] on an all-nil context (both formatters omit the whole section)" do
      expect(BI.questions(context_with)).to eq([])
    end

    it "omits each question independently when its source struct is nil" do
      qs = BI.questions(context_with(blast_radius: blast, forward_depth: fwd_depth))
      expect(qs.map(&:id)).to eq(%w[q3 q4])
    end

    it "omits q3 on the engine N/A blast form (zero entrypoints — never '0 use cases at risk')" do
      na = RS::BlastRadius.new(
        max: nil, p90: nil, median: nil, mean: nil,
        reached_nodes: 0, total_nodes: 4, total_entrypoints: 0,
        pct_use_cases_hit_by_worst: nil, worst: []
      )
      qs = BI.questions(context_with(blast_radius: na, scores: [forward_dim]))
      expect(qs.map(&:id)).to eq(%w[q1]) # q1 still renders; q3 omitted
    end

    it "omits q4/q5/bf on the engine degenerate stat form (median nil, count 0)" do
      empty = RS::DepthStats.new(mean: nil, median: nil, count: 0)
      qs = BI.questions(context_with(forward_depth: empty, reverse_depth: empty,
                                     branching_factor: RS::BranchingFactor.new(mean: nil, median: nil, count: 0)))
      expect(qs).to eq([])
    end

    it "orders answerable questions q1..bf" do
      qs = BI.questions(context_with(
                          scores: [reverse_dim, forward_dim],
                          blast_radius: blast, forward_depth: fwd_depth,
                          reverse_depth: rev_depth, branching_factor: branching
                        ))
      expect(qs.map(&:id)).to eq(%w[q1 q2 q3 q4 q5 bf])
    end
  end

  describe "detail-line conventions" do
    it "q4 renders the per-category depth line when the engine grouped (honest absence otherwise)" do
      grouped = RS::DepthStats.new(
        mean: 2.83, median: 2.0, count: 1611,
        by_category: { "controllers" => { "mean" => 2.9, "median" => 2.0, "count" => 1200 } }
      )
      q4 = BI.questions(context_with(forward_depth: grouped)).find { |q| q.id == "q4" }
      expect(q4.detail_lines).to eq(["by category: controllers mean 2.9 / median 2.0"])
    end

    it "drops the coupling suffix on a nil added_coupling (never a fabricated 0)" do
      solo = RS::BlastRadius.new(
        max: 9, p90: 2.0, median: 1.0, mean: 1.5,
        reached_nodes: 3, total_nodes: 5, total_entrypoints: 9,
        pct_use_cases_hit_by_worst: 1.0,
        worst: [RS::BlastRadius::Worst.new(symbol: "A#b", use_cases_affected: 9, added_coupling: nil)]
      )
      q3 = BI.questions(context_with(blast_radius: solo)).find { |q| q.id == "q3" }
      expect(q3.detail_lines).to eq(["worst offenders: A#b (9 use cases)"])
    end
  end
end
