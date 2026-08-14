# frozen_string_literal: true

require "archbuddy/config/schema"

# v0.15 P1-T1 (+v0.16 C-1): the Schema tables — 8-rule registry (Q11 +
# ReusabilityScore), kind partitions (R48), retired names, todo metric
# registry. Drift in any default is a red spec.
RSpec.describe Archbuddy::Config::Schema do
  it "registers EXACTLY the eight rule names (Q11 + v0.16 ReusabilityScore)" do
    expect(described_class::RULES.keys.sort).to eq(
      %w[ComplexityRatchet ExponentialNode FirewallBreaches MultiplicativeGrowth
         ReusabilityScore ReviewSurface UseCaseComplexity UseCaseDividend]
    )
  end

  it "enables all eight by default" do
    expect(described_class::RULES.values.map { |r| r[:default_enabled] }).to all(be(true))
  end

  it "pins the default severities (UCC/UCD/RS warn, FB/RScore info, CR/EN/MG error)" do
    severities = described_class::RULES.transform_values { |r| r[:default_severity] }
    expect(severities).to eq(
      "UseCaseComplexity" => :warn, "UseCaseDividend" => :warn,
      "FirewallBreaches" => :info, "ReviewSurface" => :warn,
      "ComplexityRatchet" => :error, "ExponentialNode" => :error,
      "MultiplicativeGrowth" => :error, "ReusabilityScore" => :info
    )
  end

  it "pins the four kind partitions (R48)" do
    expect(described_class::NODE_RULES).to eq(%w[ExponentialNode ReusabilityScore])
    expect(described_class::USE_CASE_RULES).to eq(%w[FirewallBreaches UseCaseComplexity UseCaseDividend])
    expect(described_class::DELTA_RULES).to eq(%w[ComplexityRatchet MultiplicativeGrowth])
    expect(described_class::PR_RULES).to eq(%w[ReviewSurface])
    expect(described_class::RULES.transform_values { |r| r[:kind] }).to eq(
      "ComplexityRatchet" => :delta, "ExponentialNode" => :node,
      "FirewallBreaches" => :use_case, "MultiplicativeGrowth" => :delta,
      "ReusabilityScore" => :node, "ReviewSurface" => :pr,
      "UseCaseComplexity" => :use_case, "UseCaseDividend" => :use_case
    )
  end

  it "pins GRANDFATHERABLE = NODE_RULES ∪ USE_CASE_RULES, sorted (Q7)" do
    expect(described_class::GRANDFATHERABLE).to eq(
      %w[ExponentialNode FirewallBreaches ReusabilityScore UseCaseComplexity UseCaseDividend]
    )
  end

  describe "the param defaults table (v0.15 rule table verbatim)" do
    def param(rule, name)
      described_class::RULES.fetch(rule)[:params].fetch(name)
    end

    it "max_cone_node_log2 5.0 is the ONLY set-by-default use-case threshold (Q11)" do
      expect(param("UseCaseComplexity", "max_cone_node_log2")[:default]).to eq(5.0)
      %w[max_branching_log2 max_mass max_depth max_reach max_files].each do |k|
        expect(param("UseCaseComplexity", k)[:default]).to be_nil
      end
    end

    it "min_dividend defaults to 32 (GTE — the pinned deviation)" do
      expect(param("UseCaseDividend", "min_dividend")[:default]).to eq(32)
      expect(param("UseCaseDividend", "min_dividend")[:min]).to eq(1)
    end

    it "max_escapes defaults to 0 (strict >, info severity)" do
      expect(param("FirewallBreaches", "max_escapes")[:default]).to eq(0)
    end

    it "max_use_cases ships null (disclosure-only default, Q11)" do
      expect(param("ReviewSurface", "max_use_cases")[:default]).to be_nil
      expect(param("ReviewSurface", "max_use_cases")[:nullable]).to be(true)
    end

    it "ExponentialNode keeps threshold_log2 5; MultiplicativeGrowth +2; ratchet budgets []" do
      expect(param("ExponentialNode", "threshold_log2")[:default]).to eq(5)
      expect(param("MultiplicativeGrowth", "max_increase_log2")[:default]).to eq(2)
      expect(param("ComplexityRatchet", "budgets")[:default]).to eq([])
    end

    it "ReusabilityScore min_score defaults to -4 with the NEGATIVE min bound -5 (v0.16/X-4)" do
      expect(param("ReusabilityScore", "min_score")[:default]).to eq(-4)
      expect(param("ReusabilityScore", "min_score")[:min]).to eq(-5)
      expect(param("ReusabilityScore", "min_score")[:nullable]).to be(true)
    end

    it "ReusabilityScore absorb_min_score defaults to +5, min 0, nullable (v0.16)" do
      expect(param("ReusabilityScore", "absorb_min_score")[:default]).to eq(5)
      expect(param("ReusabilityScore", "absorb_min_score")[:min]).to eq(0)
      expect(param("ReusabilityScore", "absorb_min_score")[:nullable]).to be(true)
    end

    it "never defines an own_branching threshold key anywhere (Q10)" do
      described_class::RULES.each_value do |rule|
        expect(rule[:params].keys.grep(/own_branching/)).to eq([])
      end
    end

    it "exclude_entrypoints exists exactly on the three USE_CASE_RULES" do
      with_key = described_class::RULES.select { |_n, r| r[:params].key?("exclude_entrypoints") }.keys.sort
      expect(with_key).to eq(described_class::USE_CASE_RULES)
    end
  end

  describe "RETIRED_RULES (Q11 — six rows, guidance strings verbatim)" do
    it "names exactly the six retired rules" do
      expect(described_class::RETIRED_RULES.keys.sort).to eq(
        %w[MaxBranching MaxDepth MaxFunctionMass MaxOutDegree NoNewEscapes NoNewTollBooths]
      )
    end

    it "carries the exact guidance strings" do
      expect(described_class::RETIRED_RULES).to eq(
        "MaxBranching" => "absorbed into UseCaseComplexity (set max_branching_log2)",
        "MaxFunctionMass" => "absorbed into UseCaseComplexity (set max_mass)",
        "MaxDepth" => "absorbed into UseCaseComplexity (set max_depth)",
        "MaxOutDegree" => "dropped: use UseCaseComplexity max_reach / max_files",
        "NoNewEscapes" => "absorbed into FirewallBreaches (its diff mode)",
        "NoNewTollBooths" => "dropped: toll-booth data remains a leaderboard/enrichment diagnostic"
      )
    end
  end

  it "pins EP_METRIC_KEYS per the Q7 registry" do
    expect(described_class::EP_METRIC_KEYS).to eq(
      "UseCaseComplexity" => %w[branching_millilog2 depth files mass max_cone_node_millilog2 reach],
      "UseCaseDividend" => %w[dividend_millilog2],
      "FirewallBreaches" => %w[escapes]
    )
  end

  it "pins the enum/rank tables" do
    expect(described_class::SEVERITIES).to eq(info: 1, warn: 2, error: 3)
    expect(described_class::FAIL_LEVELS).to eq(%w[none info warn error])
    expect(described_class::FORMATS).to eq(%w[terminal markdown json])
    # configurator W4 (C10): `boundary` APPENDED. It is the only key of the six
    # whose grammar is NOT described in this module — it is registered so the
    # generic unknown-key check passes it through to Config::BoundarySection,
    # which validates it against the engine's profile schema.
    expect(described_class::TOP_LEVEL_KEYS)
      .to eq(%w[version todo_file all rules overrides calibration boundary])
    expect(described_class::ALL_KEYS).to eq(%w[exclude include fail_level format])
  end
end
