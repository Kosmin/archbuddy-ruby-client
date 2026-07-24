# frozen_string_literal: true

require "tmpdir"
require "archbuddy"
require "archbuddy/review"
require_relative "../support/stub_vintage"

# v0.15 P1-T5: the re-based evaluability battery over the SEVEN-rule family
# ([D1] §P1-T5 — replaces the substrate v1/v4/v5 × 9-rule cross-product).
# Grows along the Wave-4 chain: each rule task adds its rows as its class
# registers; the fabrication guard below is family-generic from day one.
#
#   v1  (6-key nodes, no edges): ExponentialNode evaluates; UCC/FB/UCD →
#        `fragments carry no edges`; zero fabricated findings.
#   v4  (edges + escapes + outcome_arity, no compass): ALL seven evaluate.
#   v5 pair (unanalyzed vs analyzed): identical rule results — analyzed
#        adds Finding#enrichment ONLY.
RSpec.describe "Rule-family evaluability battery" do
  def build_config(yaml = nil)
    Dir.mktmpdir do |dir|
      File.write(File.join(dir, ".archbuddy.yml"), yaml) if yaml
      return Archbuddy::Config.load(target_root: dir, cli: {})
    end
  end

  def evaluate(vintage, config: build_config, todo: nil)
    Archbuddy::Review::RuleEngine.evaluate(vintage: vintage, config: config, todo: todo)
  end

  def v1_vintage
    # 6-key fragments: no edges, no escapes, no outcome_arity stamps.
    # One ep so the edge/arity reasons are reached (not the Q8 zero-ep gate).
    ReviewStubs::StubVintage.new(nodes: [
      ReviewStubs.stub_node(file: "app/a.rb", symbol: "A#monster", branches: 65_536,
                            entrypoint: true),
      ReviewStubs.stub_node(file: "app/a.rb", symbol: "A#tiny", branches: 2)
    ], edges: false)
  end

  it "v1: ExponentialNode evaluates without edges and fires on the monster" do
    result = evaluate(v1_vintage)
    en = result.findings.select { |f| f.rule == "ExponentialNode" }
    expect(en.map(&:symbol)).to eq(["A#monster"])
    expect(result.not_evaluable.map { |n| n[:rule] }).not_to include("ExponentialNode")
  end

  it "v1: UseCaseComplexity honestly declares `fragments carry no edges`" do
    result = evaluate(v1_vintage)
    expect(result.not_evaluable).to include(
      rule: "UseCaseComplexity", reason: "fragments carry no edges"
    )
    expect(result.findings.map(&:rule)).not_to include("UseCaseComplexity")
  end

  it "v1: UseCaseDividend hits the edges gate FIRST (before the arity reason)" do
    result = evaluate(v1_vintage)
    expect(result.not_evaluable).to include(
      rule: "UseCaseDividend", reason: "fragments carry no edges"
    )
    expect(result.findings.map(&:rule)).not_to include("UseCaseDividend")
  end

  it "v1: FirewallBreaches declares `fragments carry no edges` (cone attribution)" do
    result = evaluate(v1_vintage)
    expect(result.not_evaluable).to include(
      rule: "FirewallBreaches", reason: "fragments carry no edges"
    )
    expect(result.findings.map(&:rule)).not_to include("FirewallBreaches")
  end

  it "fabrication guard: findings NEVER contain a not-evaluable rule's entries" do
    result = evaluate(v1_vintage)
    na_rules = result.not_evaluable.map { |n| n[:rule] }
    expect(result.findings.map(&:rule) & na_rules).to eq([])
  end

  it "ships base + exactly the SEVEN Q11 rule class files (no NoNew* files)" do
    rules_dir = File.expand_path("../../lib/archbuddy/review/rules", __dir__)
    files = Dir[File.join(rules_dir, "*.rb")].map { |f| File.basename(f) }.sort
    expect(files).to eq(%w[
      base.rb complexity_ratchet.rb exponential_node.rb firewall_breaches.rb
      multiplicative_growth.rb review_surface.rb use_case_complexity.rb
      use_case_dividend.rb
    ])
  end

  it "v4 (edges + escapes + outcome_arity, no compass): ALL seven evaluate — zero N/A" do
    ep = ReviewStubs.stub_node(file: "app/api/a.rb", symbol: "A#GET[0]", branches: 4,
                               entrypoint: true, entrypoint_kind: "api",
                               escapes: false, outcome_arity: 2)
    metrics = ReviewStubs.stub_ep_metrics(file: "app/api/a.rb", symbol: "A#GET[0]",
                                          branching_log2: 2.0, own_branches: 4,
                                          vty_log: Math.log(4), vty_floor_log: Math.log(2),
                                          dividend: 2.0, dividend_log2: 1.0)
    v4 = ReviewStubs::StubVintage.new(
      nodes: [ep], edges: true,
      graph: ReviewStubs::StubGraph.new(
        ep_metrics: { ["app/api/a.rb", "A#GET[0]"] => metrics }
      )
    )
    lint = evaluate(v4)
    expect(lint.not_evaluable).to eq([])
    expect(lint.findings).to eq([])

    delta = ReviewStubs::StubDelta.new(base: v4, head: v4, review_surface: { union: 0,
                                                                             sum: 0, eps: [], unreachable_touched: { count: 0, nodes: [] } })
    diff = Archbuddy::Review::RuleEngine.evaluate(vintage: v4, delta: delta,
                                                  config: build_config, todo: nil)
    expect(diff.not_evaluable).to eq([])
    expect(diff.findings).to eq([])
  end

  def v5_nodes
    [ReviewStubs.stub_node(file: "app/a.rb", symbol: "A#monster", branches: 65_536,
                           escapes: false, outcome_arity: 2, toll_booth: false,
                           quadrant: "Q4", leverage: 1.5, collapse: 0.2)]
  end

  it "v5 pair: analyzed adds enrichment ONLY — rule results identical" do
    unanalyzed = evaluate(ReviewStubs::StubVintage.new(nodes: v5_nodes, edges: false,
                                                       analyzed: false))
    analyzed = evaluate(ReviewStubs::StubVintage.new(nodes: v5_nodes, edges: false,
                                                     analyzed: true))

    a = unanalyzed.findings.select { |f| f.rule == "ExponentialNode" }
    b = analyzed.findings.select { |f| f.rule == "ExponentialNode" }
    expect(a.map { |f| [f.rule, f.symbol, f.message, f.value_raw, f.severity] })
      .to eq(b.map { |f| [f.rule, f.symbol, f.message, f.value_raw, f.severity] })
    expect(a.first.enrichment).to eq({})
    expect(b.first.enrichment)
      .to eq(quadrant: "Q4", toll_booth: false, leverage: 1.5, collapse: 0.2)
  end
end
