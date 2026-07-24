# frozen_string_literal: true

require "tmpdir"
require "archbuddy"
require "archbuddy/review"
require_relative "../support/stub_vintage"

# v0.15 P1-T5: ExponentialNode — the ONE surviving :node rule (Q11a; the
# four cap classes are retired with successor guidance, no off-by-default
# hatches). Boundary pair 32/33 (STRICT > 2^5, A1), the byte-locked message
# template, exclude emission-gating, and the node 4-step todo path — all
# through the REAL load-time registration (never a double).
RSpec.describe Archbuddy::Review::Rules::ExponentialNode do
  def build_config(yaml = nil, cli: {})
    Dir.mktmpdir do |dir|
      File.write(File.join(dir, ".archbuddy.yml"), yaml) if yaml
      return Archbuddy::Config.load(target_root: dir, cli: cli)
    end
  end

  def build_todo(yaml)
    Dir.mktmpdir do |dir|
      path = File.join(dir, ".archbuddy_todo.yml")
      File.write(path, yaml)
      return Archbuddy::Config::Todo.load(path)
    end
  end

  def evaluate(vintage, config: build_config, todo: nil)
    Archbuddy::Review::RuleEngine.evaluate(vintage: vintage, config: config, todo: todo)
  end

  def en_findings(result)
    result.findings.select { |f| f.rule == "ExponentialNode" }
  end

  it "is registered under its exact Q11 name at load time" do
    expect(Archbuddy::Review::RuleEngine.registry["ExponentialNode"]).to eq(described_class)
    expect(described_class.kind).to eq(:node)
    expect(described_class.needs_edges?).to be(false)
  end

  it "fires STRICTLY above 2^5: 32 passes, 33 fires (A1 boundary, both sides)" do
    vintage = ReviewStubs::StubVintage.new(nodes: [
      ReviewStubs.stub_node(file: "app/a.rb", symbol: "A#pass", branches: 32),
      ReviewStubs.stub_node(file: "app/a.rb", symbol: "A#fire", branches: 33)
    ], edges: false)

    findings = en_findings(evaluate(vintage))
    expect(findings.map(&:symbol)).to eq(["A#fire"])
    f = findings.first
    expect(f.severity).to eq(:error)
    expect(f.value_raw).to eq(33)
    expect(f.value_log2).to be_within(1e-9).of(Math.log2(33))
    expect(f.threshold_raw).to eq(32)
    expect(f.threshold_log2).to eq(5)
  end

  it "renders the worked message instance byte-for-byte" do
    vintage = ReviewStubs::StubVintage.new(nodes: [
      ReviewStubs.stub_node(file: "app/api/api/v1/redeem_templates.rb",
                            symbol: "Api::V1::RedeemTemplates#PATCH[0]", branches: 65_536)
    ], edges: false)

    f = en_findings(evaluate(vintage)).first
    expect(f.message).to eq("own branching 65536 (2^16.0) exceeds 2^5 (Q4 boundary)")
  end

  it "honors a per-rule exclude (emission-only, engine universe filter)" do
    config = build_config(<<~YAML)
      version: 1
      rules:
        ExponentialNode:
          exclude: ["app/legacy/**"]
    YAML
    vintage = ReviewStubs::StubVintage.new(nodes: [
      ReviewStubs.stub_node(file: "app/legacy/old.rb", symbol: "Old#x", branches: 65_536),
      ReviewStubs.stub_node(file: "app/api/new.rb", symbol: "New#x", branches: 65_536)
    ], edges: false)

    findings = en_findings(evaluate(vintage, config: config))
    expect(findings.map(&:file)).to eq(["app/api/new.rb"])
  end

  it "applies the node 4-step todo: skip at baseline, re-fire past it (R21 full replacement)" do
    todo = build_todo(<<~YAML)
      version: 1
      tool: "archbuddy 0.12.0"
      rule_count: 1
      node_count: 1
      rules:
        ExponentialNode:
          - node: "app/a.rb: A#big"
            value: 65536
    YAML

    at_baseline = ReviewStubs::StubVintage.new(nodes: [
      ReviewStubs.stub_node(file: "app/a.rb", symbol: "A#big", branches: 65_536)
    ], edges: false)
    result = evaluate(at_baseline, todo: todo)
    expect(en_findings(result)).to be_empty
    skip_row = result.grandfathered.find { |g| g.rule == "ExponentialNode" }
    expect(skip_row.recorded).to eq(65_536)
    expect(skip_row.healed).to be(false)

    grown = ReviewStubs::StubVintage.new(nodes: [
      ReviewStubs.stub_node(file: "app/a.rb", symbol: "A#big", branches: 131_072)
    ], edges: false)
    refire = en_findings(evaluate(grown, todo: todo)).first
    expect(refire.message)
      .to eq("grew past grandfathered baseline 65536 (2^16.0) → 131072 (2^17.0)")
    expect(refire.grandfathered_baseline).to eq(65_536)
  end

  it "never reads presenter cost inputs (A4 grep gate)" do
    source = File.read(File.expand_path(
                         "../../lib/archbuddy/review/rules/exponential_node.rb", __dir__
                       ), encoding: "UTF-8")
    expect(source).not_to match(/calibration/i)
  end
end
