# frozen_string_literal: true

require "tmpdir"
require "archbuddy/config"

# v0.15 P1-T2: Config.load — discovery, YAML handling, version rows, todo
# resolution (F9), and the R15/C11 accessors.
#
# The "full example" below is the v0.15 re-base of the substrate R2-Q3
# example (its v0.14 taxonomy and pre-R4 calibration sketch are superseded):
# same structure, every schema surface exercised, the eight rules (Q11 + the
# v0.16 ReusabilityScore).
RSpec.describe Archbuddy::Config do
  FULL_EXAMPLE = <<~YAML
    version: 1
    todo_file: .archbuddy_todo.yml
    all:
      exclude:
        - "vendor/**/*"
        - "db/**/*"
        - "spec/**/*"
      include: []
      fail_level: error
      format: terminal
    rules:
      UseCaseComplexity:
        enabled: true
        severity: warn
        max_cone_node_log2: 5.0
        max_branching_log2: null
        max_mass: null
        max_depth: null
        max_reach: 120
        max_files: null
        exclude: []
        exclude_entrypoints: []
      UseCaseDividend:
        enabled: true
        severity: warn
        min_dividend: 32
        exclude_entrypoints: ["Legacy::Api#GET[0]"]
      FirewallBreaches:
        enabled: true
        severity: info
        max_escapes: 0
      ReviewSurface:
        enabled: true
        severity: warn
        max_use_cases: null
      ExponentialNode:
        enabled: true
        severity: error
        threshold_log2: 5
        exclude: []
      ReusabilityScore:
        enabled: true
        severity: info
        min_score: -4
        absorb_min_score: 5
      MultiplicativeGrowth:
        enabled: true
        severity: error
        max_increase_log2: 2
      ComplexityRatchet:
        enabled: true
        severity: error
        budgets:
          - paths: ["app/**/*"]
            max_increase_log2: 4.0
          - paths: ["app/services/billing/**/*"]
            max_increase_log2: -1.0
            severity: error
          - entrypoints: ["Api::V1::RedeemTemplates#PATCH[0]"]
            max_increase_log2: 0.0
    overrides:
      - paths: ["app/jobs/**/*"]
        rules:
          ExponentialNode: { threshold_log2: 6 }
      - paths: ["engines/*/app/**/*"]
        rules:
          ComplexityRatchet: { enabled: false }
      - paths: ["app/api/**/*"]
        rules:
          UseCaseComplexity: { max_cone_node_log2: 8.0 }
    calibration:
      source: local
      provenance: "internal 2026-Q3 remeasure"
      latency_multiplier_per_log2_unit: 1.05
      t_quartile_cuts: [2.0, 3.0, 5.0]
  YAML

  def with_config(yaml, todo: false)
    Dir.mktmpdir do |dir|
      File.write(File.join(dir, ".archbuddy.yml"), yaml) unless yaml.nil?
      File.write(File.join(dir, ".archbuddy_todo.yml"), "version: 1\n") if todo
      yield dir
    end
  end

  it "loads the FULL v0.15 example with zero errors" do
    with_config(FULL_EXAMPLE, todo: true) do |dir|
      config = described_class.load(target_root: dir)
      expect(config.config_file_present?).to be(true)
      expect(config.effective_fail_level).to eq(:error)
      expect(config.all_excludes).to eq(["vendor/**/*", "db/**/*", "spec/**/*"])
      expect(config.budgets.size).to eq(3)
      expect(config.calibration["source"]).to eq("local")
      expect(config.collect_options).to eq({}) # the C11 v1 stub
    end
  end

  it "returns an advisory defaults-only config when no file exists (REPL probe row)" do
    Dir.mktmpdir do |dir|
      config = described_class.load(target_root: dir)
      expect(config.config_file_present?).to be(false)
      expect(config.effective_fail_level).to eq(:none)
      expect(config.gating?).to be(false)
      expect(config.calibration).to be_nil
      # The rule set is IDENTICAL with/without a file (L3).
      expect(config.rule_for("ExponentialNode", file: nil).threshold_log2).to eq(5)
      expect(config.enabled_rules(mode: :diff).sort).to eq(Archbuddy::Config::Schema::RULES.keys.sort)
    end
  end

  it "errors on an explicit --config pointing at a missing file" do
    Dir.mktmpdir do |dir|
      expect { described_class.load(target_root: dir, config_path: File.join(dir, "nope.yml")) }
        .to raise_error(described_class::ValidationError, /config file .*nope\.yml.*not found/)
    end
  end

  describe "version rows" do
    it "empty YAML fails version naming the minimal valid config" do
      with_config("") do |dir|
        expect { described_class.load(target_root: dir) }
          .to raise_error(described_class::ValidationError, /version is required — minimal valid config: 'version: 1'/)
      end
    end

    it "non-integer version" do
      with_config("version: \"one\"\n") do |dir|
        expect { described_class.load(target_root: dir) }
          .to raise_error(described_class::ValidationError, /version must be an integer/)
      end
    end

    it "newer schema" do
      with_config("version: 2\n") do |dir|
        expect { described_class.load(target_root: dir) }
          .to raise_error(described_class::ValidationError, /config schema v2 requires a newer archbuddy/)
      end
    end

    it "non-mapping root" do
      with_config("- just\n- a\n- list\n") do |dir|
        expect { described_class.load(target_root: dir) }
          .to raise_error(described_class::ValidationError, /config root must be a mapping/)
      end
    end
  end

  describe "todo_path resolution (F9)" do
    it "config todo_file naming a nonexistent path is a ValidationError" do
      with_config("version: 1\ntodo_file: missing_todo.yml\n") do |dir|
        expect { described_class.load(target_root: dir) }
          .to raise_error(described_class::ValidationError,
                          /todo file 'missing_todo\.yml' \(config todo_file\) not found — remove the key, fix the path, or generate it with --auto-gen-todo/)
      end
    end

    it "todo_file: null stays ignore-todo" do
      with_config("version: 1\ntodo_file: null\n", todo: true) do |dir|
        expect(described_class.load(target_root: dir).todo_path).to be_nil
      end
    end

    it "absent key = default path, nil when the default file is missing" do
      with_config("version: 1\n") do |dir|
        expect(described_class.load(target_root: dir).todo_path).to be_nil
      end
      with_config("version: 1\n", todo: true) do |dir|
        expect(described_class.load(target_root: dir).todo_path)
          .to eq(File.join(File.expand_path(dir), ".archbuddy_todo.yml"))
      end
    end

    it "cli no_todo wins; explicit missing --todo errors" do
      with_config("version: 1\n", todo: true) do |dir|
        expect(described_class.load(target_root: dir, cli: { no_todo: true }).todo_path).to be_nil
        expect { described_class.load(target_root: dir, cli: { todo_path: "absent.yml" }) }
          .to raise_error(described_class::ValidationError, /todo file 'absent\.yml' \(--todo\) not found/)
      end
    end
  end

  describe "degenerate no-ops" do
    it "version: 1 alone is fully valid — gating active, Q11 starter defaults live" do
      with_config("version: 1\n") do |dir|
        config = described_class.load(target_root: dir)
        expect(config.gating?).to be(true)
        expect(config.effective_fail_level).to eq(:error)
        # The starter: all eight default-enabled, Q4-trigger + dividend>=32 + FB-info
        # + score<=-4-info live.
        expect(config.enabled_rules(mode: :diff).size).to eq(8)
        expect(config.rule_for("UseCaseComplexity", file: nil).max_cone_node_log2).to eq(5.0)
        expect(config.rule_for("UseCaseDividend", file: nil).min_dividend).to eq(32)
        expect(config.rule_for("FirewallBreaches", file: nil).severity).to eq(:info)
        expect(config.rule_for("ReusabilityScore", file: nil).min_score).to eq(-4)
        expect(config.rule_for("ReusabilityScore", file: nil).severity).to eq(:info)
      end
    end

    it "a config enabling/disabling ReusabilityScore round-trips the loader (v0.16)" do
      yaml = <<~YAML
        version: 1
        rules:
          ReusabilityScore:
            enabled: false
            min_score: -3
      YAML
      with_config(yaml) do |dir|
        config = described_class.load(target_root: dir)
        rule = config.rule_for("ReusabilityScore", file: nil)
        expect(rule.enabled).to be(false)
        expect(rule.min_score).to eq(-3)
        expect(rule.absorb_min_score).to eq(5) # untouched param keeps its default
        expect(config.enabled_rules(mode: :diff)).not_to include("ReusabilityScore")
      end
    end

    it "empty overrides/budgets/excludes are valid no-ops" do
      yaml = <<~YAML
        version: 1
        all: { exclude: [] }
        rules:
          ComplexityRatchet: { budgets: [] }
        overrides: []
      YAML
      with_config(yaml) do |dir|
        config = described_class.load(target_root: dir)
        expect(config.budgets).to eq([])
        expect(config.all_excludes).to eq([])
      end
    end
  end
end
