# frozen_string_literal: true

require "tmpdir"
require "yaml"
require "archbuddy/config"

# v0.15 P1-T2: the validation matrix — each row is a spec. Retired names
# (Q11) fire BEFORE did-you-mean; unknown key at ANY level names its full
# path; the C12 calibration table in full.
RSpec.describe Archbuddy::Config::Validator do
  def errors_for(yaml)
    Dir.mktmpdir do |dir|
      File.write(File.join(dir, ".archbuddy.yml"), yaml)
      Archbuddy::Config.load(target_root: dir)
      return []
    end
  rescue Archbuddy::Config::ValidationError => e
    e.message.split("\n")
  end

  describe "retired rule names (all SIX, checked before did-you-mean)" do
    {
      "MaxBranching" => "absorbed into UseCaseComplexity (set max_branching_log2)",
      "MaxFunctionMass" => "absorbed into UseCaseComplexity (set max_mass)",
      "MaxDepth" => "absorbed into UseCaseComplexity (set max_depth)",
      "MaxOutDegree" => "dropped: use UseCaseComplexity max_reach / max_files",
      "NoNewEscapes" => "absorbed into FirewallBreaches (its diff mode)",
      "NoNewTollBooths" => "dropped: toll-booth data remains a leaderboard/enrichment diagnostic"
    }.each do |name, guidance|
      it "errors on retired '#{name}' with the successor guidance" do
        errors = errors_for("version: 1\nrules:\n  #{name}: {}\n")
        expect(errors).to include(
          "unknown rule '#{name}' at rules — retired: #{guidance}; see docs/CONFIGURATION.md#retired-rules"
        )
        expect(errors.join).not_to include("did you mean")
      end
    end

    it "worked instance byte-exact" do
      errors = errors_for("version: 1\nrules:\n  MaxBranching: {enabled: true}\n")
      expect(errors).to eq([
        "unknown rule 'MaxBranching' at rules — retired: absorbed into UseCaseComplexity " \
        "(set max_branching_log2); see docs/CONFIGURATION.md#retired-rules"
      ])
    end
  end

  describe "typo corpus (did-you-mean at every level)" do
    it "living-rule typo" do
      errors = errors_for("version: 1\nrules:\n  UseCaseComplexit: {}\n")
      expect(errors).to include("unknown rule 'UseCaseComplexit' at rules — did you mean 'UseCaseComplexity'?")
    end

    it "param typos" do
      errors = errors_for(<<~YAML)
        version: 1
        rules:
          UseCaseDividend: { min_dividnd: 32 }
          FirewallBreaches: { max_escaps: 1 }
          ExponentialNode: { severty: warn }
          ComplexityRatchet: { budgts: [] }
      YAML
      expect(errors).to include("unknown key 'min_dividnd' at rules.UseCaseDividend — did you mean 'min_dividend'?")
      expect(errors).to include("unknown key 'max_escaps' at rules.FirewallBreaches — did you mean 'max_escapes'?")
      expect(errors).to include("unknown key 'severty' at rules.ExponentialNode — did you mean 'severity'?")
      expect(errors).to include("unknown key 'budgts' at rules.ComplexityRatchet — did you mean 'budgets'?")
    end
  end

  describe "unknown keys at every level (five distinct paths)" do
    it "names the full key path each time" do
      errors = errors_for(<<~YAML)
        version: 1
        bogus_top: 1
        all: { bogus_all: 1 }
        rules:
          ExponentialNode: { bogus_rule: 1 }
        overrides:
          - paths: ["app/**/*"]
            rules: {}
            bogus_override: 1
        calibration: { source: none, bogus_cal: 1 }
      YAML
      expect(errors.join("\n")).to include("unknown key 'bogus_top' at top level")
      expect(errors.join("\n")).to include("unknown key 'bogus_all' at all")
      expect(errors.join("\n")).to include("unknown key 'bogus_rule' at rules.ExponentialNode")
      expect(errors.join("\n")).to include("unknown key 'bogus_override' at overrides[0]")
      expect(errors.join("\n")).to include("unknown key 'bogus_cal' at calibration")
    end
  end

  describe "exclude_entrypoints scoping (Q11)" do
    %w[ExponentialNode ReusabilityScore ReviewSurface ComplexityRatchet
       MultiplicativeGrowth].each do |name|
      it "rejects exclude_entrypoints on #{name}" do
        errors = errors_for("version: 1\nrules:\n  #{name}: { exclude_entrypoints: [\"X#y\"] }\n")
        expect(errors).to include(
          "exclude_entrypoints is only valid on entrypoint-scoped rules " \
          "(FirewallBreaches, UseCaseComplexity, UseCaseDividend) — found at rules.#{name}"
        )
      end
    end

    %w[FirewallBreaches UseCaseComplexity UseCaseDividend].each do |name|
      it "accepts exclude_entrypoints on #{name}" do
        expect(errors_for("version: 1\nrules:\n  #{name}: { exclude_entrypoints: [\"X#y\"] }\n")).to eq([])
      end
    end

    it "forbids exclude_entrypoints inside overrides (like exclude)" do
      errors = errors_for(<<~YAML)
        version: 1
        overrides:
          - paths: ["app/**/*"]
            rules:
              UseCaseComplexity: { exclude_entrypoints: ["X#y"] }
      YAML
      expect(errors.join).to include("exclude_entrypoints is not allowed in overrides — scope via paths")
    end
  end

  describe "overrides structural rules" do
    it "forbids exclude (scope via paths)" do
      errors = errors_for(<<~YAML)
        version: 1
        overrides:
          - paths: ["app/**/*"]
            rules:
              ExponentialNode: { exclude: ["x.rb"] }
      YAML
      expect(errors.join).to include("exclude is not allowed in overrides — scope via paths")
    end

    it "rejects ComplexityRatchet budgets in an override" do
      errors = errors_for(<<~YAML)
        version: 1
        overrides:
          - paths: ["app/**/*"]
            rules:
              ComplexityRatchet: { budgets: [] }
      YAML
      expect(errors.join).to include("budgets are global; scope via budgets[].paths")
    end

    it "requires non-empty paths" do
      errors = errors_for("version: 1\noverrides:\n  - paths: []\n    rules: {}\n")
      expect(errors.join).to include("overrides[0].paths must be a non-empty array of strings")
    end
  end

  describe "param typing (new v0.15 rows)" do
    it "min_dividend below 1" do
      errors = errors_for("version: 1\nrules:\n  UseCaseDividend: { min_dividend: 0.5 }\n")
      expect(errors.join).to include("rules.UseCaseDividend.min_dividend must be a number >= 1")
    end

    it "max_escapes negative" do
      errors = errors_for("version: 1\nrules:\n  FirewallBreaches: { max_escapes: -1 }\n")
      expect(errors.join).to include("rules.FirewallBreaches.max_escapes must be an integer >= 0")
    end

    it "max_use_cases negative" do
      errors = errors_for("version: 1\nrules:\n  ReviewSurface: { max_use_cases: -1 }\n")
      expect(errors.join).to include("rules.ReviewSurface.max_use_cases must be an integer >= 0")
    end

    it "max_cone_node_log2: null is valid; all-null UCC is a VALID config" do
      yaml = <<~YAML
        version: 1
        rules:
          UseCaseComplexity:
            max_cone_node_log2: null
            max_branching_log2: null
            max_mass: null
            max_depth: null
            max_reach: null
            max_files: null
      YAML
      expect(errors_for(yaml)).to eq([])
    end

    it "budgets need paths XOR entrypoints and a numeric max_increase_log2" do
      errors = errors_for(<<~YAML)
        version: 1
        rules:
          ComplexityRatchet:
            budgets:
              - paths: ["a/**/*"]
                entrypoints: ["X#y"]
                max_increase_log2: 1.0
              - paths: ["b/**/*"]
      YAML
      expect(errors.join).to include("budgets[0] needs exactly one of paths: XOR entrypoints:")
      expect(errors.join).to include("budgets[1].max_increase_log2 is required")
    end

    it "negative budgets are legal (L6 forced decrease)" do
      yaml = <<~YAML
        version: 1
        rules:
          ComplexityRatchet:
            budgets:
              - paths: ["app/**/*"]
                max_increase_log2: -1.0
      YAML
      expect(errors_for(yaml)).to eq([])
    end
  end

  describe "ReusabilityScore param typing (new v0.16 rows — the NEGATIVE min bound, X-4)" do
    it "min_score: -5 (the exact bound) is accepted" do
      expect(errors_for("version: 1\nrules:\n  ReusabilityScore: { min_score: -5 }\n")).to eq([])
    end

    it "min_score: -3 validates" do
      expect(errors_for("version: 1\nrules:\n  ReusabilityScore: { min_score: -3 }\n")).to eq([])
    end

    it "min_score: null is valid (nullable)" do
      expect(errors_for("version: 1\nrules:\n  ReusabilityScore: { min_score: null }\n")).to eq([])
    end

    it "min_score below the -5 bound is rejected with the >= -5 message" do
      errors = errors_for("version: 1\nrules:\n  ReusabilityScore: { min_score: -5.5 }\n")
      expect(errors.join).to include("rules.ReusabilityScore.min_score must be a number >= -5")
    end

    it "absorb_min_score negative is rejected (>= 0)" do
      errors = errors_for("version: 1\nrules:\n  ReusabilityScore: { absorb_min_score: -1 }\n")
      expect(errors.join).to include("rules.ReusabilityScore.absorb_min_score must be a number >= 0")
    end
  end

  describe "calibration (the C12 full table)" do
    it "local without provenance" do
      errors = errors_for("version: 1\ncalibration: { source: local }\n")
      expect(errors.join).to include("calibration.provenance is required when source: local")
    end

    it "bogus source lists the enum" do
      errors = errors_for("version: 1\ncalibration: { source: bogus }\n")
      expect(errors.join).to include("calibration.source must be one of builtin-study-v1|local|none")
    end

    it "builtin + any value key (the C12 row)" do
      errors = errors_for("version: 1\ncalibration: { cost_per_line_ratio_q4_vs_q1: 9.9 }\n")
      expect(errors.join).to include("calibration value overrides require `source: local` with a `provenance` string")
    end

    it "none + any other key (the C12 row)" do
      errors = errors_for("version: 1\ncalibration: { source: none, provenance: x }\n")
      expect(errors.join).to include("calibration source 'none' allows no other keys")
    end

    it "cuts must be 3 ascending numbers" do
      errors = errors_for(<<~YAML)
        version: 1
        calibration: { source: local, provenance: p, t_quartile_cuts: [3.0, 2.0, 5.0] }
      YAML
      expect(errors.join).to include("calibration.t_quartile_cuts must be 3 ascending numbers")
    end
  end

  it "joins ALL errors one per line" do
    errors = errors_for("rules:\n  MaxBranching: {}\n  UseCaseComplexit: {}\n")
    expect(errors.size).to be >= 3 # version + retired + did-you-mean
  end
end
