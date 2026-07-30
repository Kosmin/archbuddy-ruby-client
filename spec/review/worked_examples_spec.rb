# frozen_string_literal: true

require "tmpdir"
require "archbuddy"
require "archbuddy/review"
require_relative "../support/stub_vintage"

# v0.15 P1-T6: the Q5 canon at ENGINE level — the new A5-equivalents.
# #2083: EXACTLY EN(error) + MG(error) + UCC(warn, Q4 clause) + UCD(warn,
# ×65536) + the ratchet breach + review_surface union 1; counts
# {error: 2, warn: 2}; exit 1. #2146: ZERO findings from all eight rules,
# net +1.000, union 2, exit 0 — what clean looks like.
RSpec.describe "Engine-level worked examples (Q5 canon)" do
  WE_FIXTURES = File.expand_path("../fixtures/review/vintages", __dir__)

  def read(name)
    Archbuddy::Review::FragmentWalk.read(File.join(WE_FIXTURES, name))
  end

  def build_config(yaml = nil)
    Dir.mktmpdir do |dir|
      File.write(File.join(dir, ".archbuddy.yml"), yaml) if yaml
      return Archbuddy::Config.load(target_root: dir, cli: {})
    end
  end

  def evaluate_pair(base_name, head_name, config: build_config, todo: nil)
    base = read(base_name)
    head = read(head_name)
    delta = Archbuddy::Review::Delta.new(base: base, head: head)
    [Archbuddy::Review::RuleEngine.evaluate(vintage: head, delta: delta,
                                            config: config, todo: todo), delta]
  end

  describe "#2083 (the monster grows: 8192 → 65536)" do
    let(:config) do
      build_config(<<~YAML)
        version: 1
        rules:
          ComplexityRatchet:
            budgets:
              - { paths: ["app/api/**/*"], max_increase_log2: 0.0 }
      YAML
    end

    it "fires EXACTLY the four canon findings + the breach + the union-1 block" do
      result, delta = evaluate_pair("twin_2083_base", "twin_2083_head", config: config)

      rules = result.findings.map(&:rule).sort
      expect(rules).to eq(%w[ExponentialNode MultiplicativeGrowth
                             UseCaseComplexity UseCaseDividend])

      ucc = result.findings.find { |f| f.rule == "UseCaseComplexity" }
      expect(ucc.severity).to eq(:warn)
      expect(ucc.message).to include("worst cone node 65536 (2^16.0) exceeds 2^5 (Q4 boundary)")

      ucd = result.findings.find { |f| f.rule == "UseCaseDividend" }
      expect(ucd.severity).to eq(:warn)
      expect(ucd.message).to include("dividend ×65536")

      breach = result.ratchet.find { |e| e.verdict == :breach }
      expect(breach.message).to eq("scope app/api/**/*: net +3.000 log2 exceeds budget +0.000")

      expect(result.review_surface[:union]).to eq(1)
      expect(result.review_surface[:sum]).to eq(1)

      counts = result.counts
      expect(counts[:error]).to eq(2)
      expect(counts[:warn]).to eq(2)
      expect(result.exit_code(:error)).to eq(1)
      expect(result.exit_code(:none)).to eq(0)
      expect(delta.net_log2.round(3)).to eq(3.0)
    end
  end

  describe "#2146 (two small NEW eps — what clean looks like)" do
    it "yields ZERO findings from all eight rules, net +1.000, union 2, exit 0" do
      result, delta = evaluate_pair("twin_2146_base", "twin_2146_head")

      expect(result.findings).to eq([])
      expect(delta.net_log2.round(3)).to eq(1.0)
      expect(result.review_surface[:union]).to eq(2)
      expect(result.review_surface[:sum]).to eq(2)
      expect(result.exit_code(:error)).to eq(0)
      expect(result.counts).to eq(error: 0, warn: 0, info: 0)

      new_eps = delta.ep_entries.select { |e| e.classification == :new }
      expect(new_eps.size).to eq(2)
      vectors = new_eps.map do |e|
        [e.head.branching_log2, e.head.mass, e.head.reach, e.head.files, e.head.depth,
         e.head.dividend&.round(6)]
      end
      expect(vectors).to contain_exactly([0.0, 7, 1, 1, 1, 1.0], [1.0, 22, 1, 1, 1, 2.0])
    end
  end

  describe "MultiplicativeGrowth on NEW nodes (NEW ≠ GROWN)" do
    it "never fires on a NEW node with head_branches 65536 — EN owns that flag" do
      node = ReviewStubs.stub_node(file: "app/api/big.rb", symbol: "Api::Big#call",
                                   branches: 65_536, escapes: false, outcome_arity: 1)
      vintage = ReviewStubs::StubVintage.new(
        nodes: [node], edges: true, graph: ReviewStubs::StubGraph.new(ep_metrics: {})
      )
      entry = Archbuddy::Review::Delta::Entry.new(
        file: node.file, symbol: node.symbol, classification: :new,
        base_branches: nil, head_branches: 65_536, delta_log2: 16.0,
        base_node: nil, head_node: node, moved_from: nil, moved_to: nil
      )
      delta = ReviewStubs::StubDelta.new(entries: [entry], base: vintage, head: vintage,
                                         net_log2: 16.0, ep_deltas: {})
      result = Archbuddy::Review::RuleEngine.evaluate(vintage: vintage, delta: delta,
                                                      config: build_config, todo: nil)

      expect(result.findings.map(&:rule)).not_to include("MultiplicativeGrowth")
      en = result.findings.select { |f| f.rule == "ExponentialNode" }
      expect(en.size).to eq(1) # the NEW monster is EN's diff jurisdiction
    end
  end

  describe "negative budgets (L6 forced decrease, nonempty scope)" do
    def shrink_delta(delta_log2)
      node = ReviewStubs.stub_node(file: "app/api/x.rb", symbol: "Api::X#call",
                                   branches: 4, escapes: false, outcome_arity: 2)
      vintage = ReviewStubs::StubVintage.new(
        nodes: [node], edges: true, graph: ReviewStubs::StubGraph.new(ep_metrics: {})
      )
      entry = Archbuddy::Review::Delta::Entry.new(
        file: node.file, symbol: node.symbol, classification: :shrunk,
        base_branches: 8, head_branches: 4, delta_log2: delta_log2,
        base_node: node, head_node: node, moved_from: nil, moved_to: nil
      )
      [vintage, ReviewStubs::StubDelta.new(entries: [entry], base: vintage, head: vintage,
                                           net_log2: delta_log2, ep_deltas: {})]
    end

    let(:config) do
      build_config(<<~YAML)
        version: 1
        rules:
          ComplexityRatchet:
            budgets:
              - { paths: ["app/**/*"], max_increase_log2: -1.0 }
      YAML
    end

    it "breaches at net -0.5 vs budget -1.0 (a decrease, but not ENOUGH decrease)" do
      vintage, delta = shrink_delta(-0.5)
      result = Archbuddy::Review::RuleEngine.evaluate(vintage: vintage, delta: delta,
                                                      config: config, todo: nil)
      entry = result.ratchet.first
      expect(entry.verdict).to eq(:breach)
      expect(entry.message).to eq("scope app/**/*: net -0.500 log2 exceeds budget -1.000")
      expect(result.exit_code(:error)).to eq(1)
    end

    it "passes at net -1.0 vs budget -1.0 (≤ satisfies the forced decrease)" do
      vintage, delta = shrink_delta(-1.0)
      result = Archbuddy::Review::RuleEngine.evaluate(vintage: vintage, delta: delta,
                                                      config: config, todo: nil)
      entry = result.ratchet.first
      expect(entry.verdict).to eq(:pass)
      expect(result.exit_code(:error)).to eq(0)
    end
  end

  describe "degenerates" do
    it "identical vintages → net +0.000, no findings, no ratchet output, exit 0" do
      result, delta = evaluate_pair("twin_2083_head", "twin_2083_head")

      expect(delta.net_log2).to eq(0.0)
      expect(result.findings).to eq([])
      expect(result.ratchet).to eq([]) # budgets: [] (default) → no ratchet output at all
      expect(result.exit_code(:error)).to eq(0)
    end
  end
end
