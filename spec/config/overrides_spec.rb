# frozen_string_literal: true

require "tmpdir"
require "archbuddy/config"

# v0.15 P1-T2: overrides resolution — last match wins, shallow param replace,
# USE_CASE rules override by the EP's DEFINING file.
RSpec.describe "Config overrides resolution" do
  def load_config(yaml)
    Dir.mktmpdir do |dir|
      File.write(File.join(dir, ".archbuddy.yml"), yaml)
      return Archbuddy::Config.load(target_root: dir)
    end
  end

  it "resolves the jobs/engines example" do
    config = load_config(<<~YAML)
      version: 1
      overrides:
        - paths: ["app/jobs/**/*"]
          rules:
            ExponentialNode: { threshold_log2: 6 }
        - paths: ["engines/*/app/**/*"]
          rules:
            ComplexityRatchet: { enabled: false }
    YAML

    expect(config.rule_for("ExponentialNode", file: "app/jobs/x.rb").threshold_log2).to eq(6)
    expect(config.rule_for("ExponentialNode", file: "app/models/y.rb").threshold_log2).to eq(5)
    expect(config.rule_for("ComplexityRatchet", file: "engines/billing/app/models/z.rb").enabled).to be(false)
    expect(config.rule_for("ComplexityRatchet", file: "app/models/z.rb").enabled).to be(true)
  end

  it "resolves the v0.15 UCC row (ep rules override by the EP's defining file)" do
    config = load_config(<<~YAML)
      version: 1
      overrides:
        - paths: ["app/api/**/*"]
          rules:
            UseCaseComplexity: { max_cone_node_log2: 8.0 }
    YAML

    expect(config.rule_for("UseCaseComplexity", file: "app/api/api/v1/redeem_templates.rb")
                 .max_cone_node_log2).to eq(8.0)
    expect(config.rule_for("UseCaseComplexity", file: "app/models/y.rb").max_cone_node_log2).to eq(5.0)
  end

  it "LAST match wins between overlapping overrides" do
    config = load_config(<<~YAML)
      version: 1
      overrides:
        - paths: ["app/**/*"]
          rules:
            ExponentialNode: { threshold_log2: 7 }
        - paths: ["app/jobs/**/*"]
          rules:
            ExponentialNode: { threshold_log2: 9 }
    YAML

    expect(config.rule_for("ExponentialNode", file: "app/jobs/x.rb").threshold_log2).to eq(9)
    expect(config.rule_for("ExponentialNode", file: "app/models/x.rb").threshold_log2).to eq(7)
  end

  it "shallow-replaces params (file layer over defaults) and memoizes per (rule, file)" do
    config = load_config(<<~YAML)
      version: 1
      rules:
        UseCaseDividend: { min_dividend: 64 }
    YAML

    first = config.rule_for("UseCaseDividend", file: "a.rb")
    expect(first.min_dividend).to eq(64)
    expect(first.severity).to eq(:warn) # untouched default rides along
    expect(config.rule_for("UseCaseDividend", file: "a.rb")).to equal(first)
  end

  it "exposes exclude_entrypoints on the effective view (I-P1')" do
    config = load_config(<<~YAML)
      version: 1
      rules:
        UseCaseComplexity: { exclude_entrypoints: ["Api::V1::RedeemTemplates#PATCH[0]"] }
    YAML

    rule = config.rule_for("UseCaseComplexity", file: "app/api/x.rb")
    expect(rule.exclude_entrypoints).to eq(["Api::V1::RedeemTemplates#PATCH[0]"])
    expect(config.rule_for("ExponentialNode", file: nil).exclude_entrypoints).to eq([])
  end
end
