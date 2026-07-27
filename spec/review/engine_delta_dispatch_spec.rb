# frozen_string_literal: true

require "tmpdir"
require "archbuddy"
require "archbuddy/review"
require_relative "../support/stub_vintage"

# v0.15 P1-T6: the kind-dispatch matrix through the REAL rule family —
# lint: MG/RS fully absent (no findings, no N/A noise), FirewallBreaches
# PRESENT (count mode), ratchet context only; diff: todo applied to
# :use_case (per-rule independence: UCC skips, UCD still fires); zero-ep
# vintages through the FULL engine in both modes.
RSpec.describe "Engine delta dispatch (real rule family)" do
  DISPATCH_FIXTURES = File.expand_path("../fixtures/review/vintages", __dir__)
  RED_FILE_D = "app/api/api/v1/redeem_templates.rb"
  RED_EP_D = "Api::V1::RedeemTemplates#PATCH[0]"

  def read(name)
    Archbuddy::Review::FragmentWalk.read(File.join(DISPATCH_FIXTURES, name))
  end

  def build_config(yaml = nil)
    Dir.mktmpdir do |dir|
      File.write(File.join(dir, ".archbuddy.yml"), yaml) if yaml
      return Archbuddy::Config.load(target_root: dir, cli: {})
    end
  end

  def build_todo(yaml)
    Dir.mktmpdir do |dir|
      path = File.join(dir, ".archbuddy_todo.yml")
      File.write(path, yaml)
      return Archbuddy::Config::Todo.load(path)
    end
  end

  it "lint: MG and RS are fully absent — no findings, no N/A noise; FB present" do
    result = Archbuddy::Review::RuleEngine.evaluate(vintage: read("twin_2083_head"),
                                                    config: build_config, todo: nil)
    %w[MultiplicativeGrowth ReviewSurface].each do |rule|
      expect(result.findings.map(&:rule)).not_to include(rule)
      expect(result.not_evaluable.map { |n| n[:rule] }).not_to include(rule)
    end
    expect(result.review_surface).to be_nil
    # FirewallBreaches lint count mode ran (0 escapes in the twin → quiet,
    # and NOT not_evaluable — it evaluated)
    expect(result.not_evaluable.map { |n| n[:rule] }).not_to include("FirewallBreaches")
  end

  it "diff: the todo gates :use_case rules with per-rule independence (UCC skips, UCD fires)" do
    todo = build_todo(<<~YAML)
      version: 1
      tool: "archbuddy 0.12.0"
      rule_count: 1
      node_count: 1
      rules:
        UseCaseComplexity:
          - node: "#{RED_FILE_D}: #{RED_EP_D}"
            values: { max_cone_node_millilog2: 16000 }
    YAML
    base = read("twin_2083_base")
    head = read("twin_2083_head")
    delta = Archbuddy::Review::Delta.new(base: base, head: head)
    result = Archbuddy::Review::RuleEngine.evaluate(vintage: head, delta: delta,
                                                    config: build_config, todo: todo)

    expect(result.findings.map(&:rule)).not_to include("UseCaseComplexity")
    skip_row = result.grandfathered.find { |g| g.rule == "UseCaseComplexity" }
    expect(skip_row).not_to be_nil
    expect(result.findings.map(&:rule)).to include("UseCaseDividend") # independence
  end

  it "diff: the todo is NEVER applied to :delta/:pr kinds (an EN grandfather mutes nothing else)" do
    todo = build_todo(<<~YAML)
      version: 1
      tool: "archbuddy 0.12.0"
      rule_count: 1
      node_count: 1
      rules:
        ExponentialNode:
          - node: "#{RED_FILE_D}: #{RED_EP_D}"
            value: 65536
    YAML
    config = build_config(<<~YAML)
      version: 1
      rules:
        ComplexityRatchet:
          budgets:
            - { paths: ["app/api/**/*"], max_increase_log2: 0.0 }
    YAML
    base = read("twin_2083_base")
    head = read("twin_2083_head")
    delta = Archbuddy::Review::Delta.new(base: base, head: head)
    result = Archbuddy::Review::RuleEngine.evaluate(vintage: head, delta: delta,
                                                    config: config, todo: todo)

    # The :node grandfather bites…
    expect(result.findings.map(&:rule)).not_to include("ExponentialNode")
    expect(result.grandfathered.map(&:rule)).to include("ExponentialNode")
    # …while :delta and :pr outputs are untouched by the todo.
    expect(result.findings.map(&:rule)).to include("MultiplicativeGrowth")
    breach = result.ratchet.find { |e| e.verdict == :breach }
    expect(breach).not_to be_nil # ComplexityRatchet never grandfathered (L5)
    expect(result.review_surface[:union]).to eq(1) # ReviewSurface never grandfathered
  end

  describe "zero-ep vintages through the FULL engine (Q8)" do
    def zero_ep_vintage
      node = ReviewStubs.stub_node(file: "lib/quiet.rb", symbol: "Quiet#helper",
                                   branches: 2, escapes: false, outcome_arity: 2)
      ReviewStubs::StubVintage.new(nodes: [node], edges: true,
                                   graph: ReviewStubs::StubGraph.new(ep_metrics: {}))
    end

    it "lint: Q8 notes for the use_case family, zero fabricated findings" do
      result = Archbuddy::Review::RuleEngine.evaluate(vintage: zero_ep_vintage,
                                                      config: build_config, todo: nil)
      q8 = result.not_evaluable.select { |n| n[:reason].include?("no entrypoints") }
      expect(q8.map { |n| n[:rule] })
        .to contain_exactly("FirewallBreaches", "UseCaseComplexity", "UseCaseDividend")
      expect(result.findings).to eq([])
    end

    it "diff: ratchet paths budgets still evaluate (reachability-independent)" do
      config = build_config(<<~YAML)
        version: 1
        rules:
          ComplexityRatchet:
            budgets:
              - { paths: ["lib/**/*"], max_increase_log2: -1.0 }
      YAML
      side = zero_ep_vintage
      delta = ReviewStubs::StubDelta.new(base: side, head: side, entries: [], ep_deltas: {})
      result = Archbuddy::Review::RuleEngine.evaluate(vintage: side, delta: delta,
                                                      config: config, todo: nil)
      breach = result.ratchet.find { |e| e.verdict == :breach }
      expect(breach).not_to be_nil # G8: empty scope + negative budget breaches
      expect(result.review_surface).to be_nil # RS Q8-gated
    end

    it "diff: the V15-F4 dispatch matrix — UCC/UCD/RS not_evaluable, FB is NOT" do
      side = zero_ep_vintage
      delta = ReviewStubs::StubDelta.new(base: side, head: side, entries: [], ep_deltas: {})
      result = Archbuddy::Review::RuleEngine.evaluate(vintage: side, delta: delta,
                                                      config: build_config, todo: nil)

      na_rules = result.not_evaluable.map { |n| n[:rule] }
      expect(na_rules).to include("UseCaseComplexity", "UseCaseDividend", "ReviewSurface")
      # FirewallBreaches diff mode is reachability-independent (orphan-event
      # attribution) — it EVALUATES on a zero-ep vintage; quiet here only
      # because this delta carries no escape events.
      expect(na_rules).not_to include("FirewallBreaches")
      expect(result.findings).to eq([])
    end
  end
end
