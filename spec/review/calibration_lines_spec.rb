# frozen_string_literal: true

require_relative "../../lib/archbuddy/review/calibration"

# v0.15 P3-T1: Calibration::Lines — the honest-copy renderer. Emission order
# L-NET, L-Q4, L-BUGFIX, L-UC-Q4, L-RS, L-DIV, L-FB-NONE (G4/R53); rendering
# laws R-HONEST-1/2 (Q6) spec-gated, incl. the ×352 regression.
RSpec.describe Archbuddy::Review::Calibration::Lines do
  CalibrationNS = Archbuddy::Review::Calibration

  CalFindingDouble = Struct.new(:rule, :symbol, :components, :threshold_raw, :contributors,
                             keyword_init: true)
  CalDeltaDouble = Struct.new(:net_log2, keyword_init: true)

  let(:builtin) { CalibrationNS.resolve(nil) }
  let(:prov) { CalibrationNS::PROVENANCE_BUILTIN }

  def en_finding
    CalFindingDouble.new(rule: "ExponentialNode", symbol: "Api::V1::RedeemTemplates#PATCH[0]")
  end

  def ucc_finding(max_cone_node_log2: 16.0, branching_log2: 16.0)
    CalFindingDouble.new(
      rule: "UseCaseComplexity", symbol: "Api::V1::RedeemTemplates#PATCH[0]",
      components: { "branching_log2" => branching_log2, "max_cone_node_log2" => max_cone_node_log2,
                    "mass" => 83, "reach" => 2, "files" => 1, "depth" => 2 }
    )
  end

  def ucd_finding(contributors: [{ symbol: "Api::V1::RedeemTemplates#PATCH[0]", value_log2: 16.0 }])
    CalFindingDouble.new(
      rule: "UseCaseDividend", symbol: "Api::V1::RedeemTemplates#PATCH[0]",
      components: { "dividend" => 65536, "dividend_log2" => 16.0,
                    "v_now_log2" => 16.0, "v_floor_log2" => 0.0 },
      threshold_raw: 32, contributors: contributors
    )
  end

  def fb_finding
    CalFindingDouble.new(rule: "FirewallBreaches", symbol: "Api::V1::RedeemTemplates#PATCH[0]")
  end

  describe "the Q5-canon golden (I8 — diff-shaped input)" do
    it "renders EXACTLY the 6 pinned lines in the pinned order" do
      lines = described_class.build(
        resolved: builtin,
        findings: [ucc_finding, ucd_finding, en_finding],
        delta: CalDeltaDouble.new(net_log2: 3.000),
        review_surface: { union: 1, q4_count: 1 }
      )

      expect(lines).to eq([
        "net +3.000 log2 units → ×1.37 expected review-latency multiplier (95% CI ×1.16–×1.63) — #{prov}",
        "1 node(s) above the Q4 boundary (b_own > 2^5 = 32): Q4-touching PRs merged at median " \
        "69.8h vs 21.9h (Q1) and cost ×2.5 review-window hours per changed line " \
        "(elapsed clock, not engineer-hours) — #{prov}",
        "Q4-touching code carried ×3.19 the bugfix rate (directional: bugfix labels failed " \
        "the study's validation bar) — #{prov}",
        "1 use case(s) contain a node above the Q4 boundary (b_own > 2^5 = 32): PRs touching " \
        "such code merged at median 69.8h vs 21.9h (Q1) and cost ×2.5 review-window hours per " \
        "changed line (elapsed clock, not engineer-hours) — #{prov}",
        "re-verify 1 use case(s) to land this change — 1 of them contain a Q4-boundary node " \
        "(such PRs merged at median 69.8h vs 21.9h) — #{prov}",
        "1 use case(s) carry ≥×32 variety that exists only because decisions are inline " \
        "(worst: Api::V1::RedeemTemplates#PATCH[0] ×65536, V_now 2^16.0 vs V_floor 2^0.0) — " \
        "its dominant contributor is above the Q4 boundary: ×3.19 the bugfix rate " \
        "(directional: bugfix labels failed the study's validation bar) — #{prov}"
      ])
    end
  end

  describe "the substrate #2083-shaped golden" do
    it "renders exactly 3 lines with the provenance suffix on every line" do
      lines = described_class.build(
        resolved: builtin, findings: [en_finding], delta: CalDeltaDouble.new(net_log2: 3.000)
      )
      expect(lines.size).to eq(3)
      expect(lines[0]).to include("net +3.000 log2 units → ×1.37")
      expect(lines[0]).to include("(95% CI ×1.16–×1.63)")
      expect(lines[1]).to include("69.8h vs 21.9h").and include("×2.5")
      expect(lines[2]).to include("×3.19")
      expect(lines).to all(end_with(" — #{prov}"))
    end
  end

  describe "the ×352 regression (R-HONEST-1)" do
    it "never exponentiates a Σ-over-cone level" do
      findings = [ucc_finding(branching_log2: 55.585, max_cone_node_log2: 8.0)]
      lines = described_class.build(resolved: builtin, findings: findings, delta: nil)
      expect(lines.grep(/×3\d\d/)).to eq([])
      expect(lines.grep(/expected review-latency multiplier/)).to eq([])
    end

    it "exponentiates ONLY delta.net_log2 even when huge components ride along" do
      findings = [ucc_finding(branching_log2: 55.585, max_cone_node_log2: 8.0)]
      lines = described_class.build(resolved: builtin, findings: findings,
                                    delta: CalDeltaDouble.new(net_log2: 3.000))
      multiplier_lines = lines.grep(/expected review-latency multiplier/)
      expect(multiplier_lines.size).to eq(1)
      expect(multiplier_lines.first).to include("×1.37")
      expect(lines.grep(/×3\d\d/)).to eq([])
    end
  end

  describe "L-RS (R-HONEST-2 provenance split)" do
    it "renders the uncalibrated count with NO provenance when q4_count is 0" do
      lines = described_class.build(resolved: builtin, findings: [],
                                    review_surface: { union: 3, q4_count: 0 })
      expect(lines).to eq(["re-verify 3 use case(s) to land this change"])
    end

    it "suppresses L-RS at union 0 and for nil review_surface" do
      expect(described_class.build(resolved: builtin, findings: [],
                                   review_surface: { union: 0, q4_count: 0 })).to eq([])
      expect(described_class.build(resolved: builtin, findings: [], review_surface: nil)).to eq([])
    end
  end

  describe "L-DIV degenerates" do
    it "renders without the q4 clause (and without provenance) when contributors are empty" do
      lines = described_class.build(resolved: builtin, findings: [ucd_finding(contributors: [])])
      expect(lines.size).to eq(1)
      expect(lines.first).to start_with("1 use case(s) carry ≥×32 variety")
      expect(lines.first).not_to include("dominant contributor")
      expect(lines.first).not_to end_with(prov)
    end
  end

  describe "L-FB-NONE (Q6/G4 — overrides render-nothing)" do
    it "renders the explicit note under builtin, with NO provenance suffix" do
      lines = described_class.build(resolved: builtin, findings: [fb_finding, fb_finding])
      expect(lines).to eq([
        "2 use case(s) report escape counts — no measured cost line for escape hatches " \
        "(the 2025-10 → 2026-07 study did not measure escape outcomes)"
      ])
    end

    it "renders [] under source: local and source: none" do
      local = CalibrationNS.resolve("source" => "local", "provenance" => "mine")
      expect(described_class.build(resolved: local, findings: [fb_finding])).to eq([])

      none = CalibrationNS.resolve("source" => "none")
      expect(described_class.build(resolved: none, findings: [fb_finding])).to eq([])
    end
  end

  describe ".cost_note (R36 — strict >)" do
    it "returns nil at exactly 5.0 and the pinned string above it" do
      expect(described_class.cost_note(max_cone_node_log2: 5.0)).to be_nil
      expect(described_class.cost_note(max_cone_node_log2: 5.001)).to eq("contains a Q4-boundary node")
      expect(described_class.cost_note(max_cone_node_log2: nil)).to be_nil
    end
  end

  describe "source: local subset rendering" do
    it "renders exactly one line, no caveat, local provenance verbatim" do
      local = CalibrationNS.resolve(
        "source" => "local", "provenance" => "internal 2026-Q3 study",
        "latency_multiplier_per_log2_unit" => 1.11184
      )
      lines = described_class.build(resolved: local, findings: [en_finding],
                                    delta: CalDeltaDouble.new(net_log2: 3.000))
      expect(lines.size).to eq(1)
      expect(lines.first).to eq(
        "net +3.000 log2 units → ×1.37 expected review-latency multiplier — internal 2026-Q3 study"
      )
    end
  end

  describe "degenerate / empty-input behavior" do
    it "clean run → [] (no fabricated advisory copy, no provenance-only line)" do
      expect(described_class.build(resolved: builtin, findings: [], delta: nil)).to eq([])
    end

    it "net within ±0.005 → no L-NET" do
      expect(described_class.build(resolved: builtin, findings: [],
                                   delta: CalDeltaDouble.new(net_log2: 0.004))).to eq([])
    end

    it "source: none → [] unconditionally (L-FB-NONE included)" do
      none = CalibrationNS.resolve("source" => "none")
      lines = described_class.build(
        resolved: none, findings: [en_finding, ucc_finding, ucd_finding, fb_finding],
        delta: CalDeltaDouble.new(net_log2: 3.0), review_surface: { union: 5, q4_count: 2 }
      )
      expect(lines).to eq([])
    end

    it "nil findings is a caller bug (ArgumentError)" do
      expect { described_class.build(resolved: builtin, findings: nil) }
        .to raise_error(ArgumentError, /findings is required/)
    end

    it "a UseCaseComplexity finding lacking max_cone_node_log2 never counts toward k" do
      finding = CalFindingDouble.new(rule: "UseCaseComplexity", symbol: "X#y",
                                  components: { "reach" => 200 })
      lines = described_class.build(resolved: builtin, findings: [finding])
      expect(lines.grep(/use case\(s\) contain a node above the Q4 boundary/)).to eq([])
    end

    it "reads the I-P5' {value:, threshold:, breached:} component triple too" do
      finding = CalFindingDouble.new(
        rule: "UseCaseComplexity", symbol: "X#y",
        components: { "max_cone_node_log2" => { value: 16.0, threshold: 5.0, breached: true } }
      )
      lines = described_class.build(resolved: builtin, findings: [finding])
      expect(lines.grep(/1 use case\(s\) contain a node above the Q4 boundary/).size).to eq(1)
    end
  end
end
