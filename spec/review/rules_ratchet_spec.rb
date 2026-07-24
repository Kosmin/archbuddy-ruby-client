# frozen_string_literal: true

require "tmpdir"
require "archbuddy"
require "archbuddy/review"
require_relative "../support/stub_vintage"

# v0.15 P2-T8 (delta rules, part 2): ComplexityRatchet — paths budgets
# (net over in-scope entries, STRICT >), entrypoints budgets over
# Delta#ep_deltas keyed (file, ep_symbol) matched via
# PathMatcher.match_symbol? (I-P10, the `[0]` exact-string branch), G8
# empty-scope semantics, per-budget severity gating, and the C14/F7 lint
# context (verdict nil, kind rows, never gates).
RSpec.describe Archbuddy::Review::Rules::ComplexityRatchet do
  VINTAGE_FIXTURES = File.expand_path("../fixtures/review/vintages", __dir__)
  EP_SYMBOL = "Api::V1::RedeemTemplates#PATCH[0]"

  def read(name)
    Archbuddy::Review::FragmentWalk.read(File.join(VINTAGE_FIXTURES, name))
  end

  def config_with_budgets(budgets_yaml)
    Dir.mktmpdir do |dir|
      File.write(File.join(dir, ".archbuddy.yml"), <<~YAML)
        version: 1
        rules:
          ComplexityRatchet:
            budgets:
        #{budgets_yaml.gsub(/^/, '      ')}
      YAML
      return Archbuddy::Config.load(target_root: dir, cli: {})
    end
  end

  def evaluate_diff(base, head, config)
    delta = Archbuddy::Review::Delta.new(base: base, head: head)
    Archbuddy::Review::RuleEngine.evaluate(vintage: head, delta: delta,
                                           config: config, todo: nil)
  end

  describe "paths budgets on the #2083-twin" do
    it "breaches at budget 0.0 with the R24 message; passes at budget 3.0 (strict >)" do
      config = config_with_budgets('- { paths: ["app/**/*"], max_increase_log2: 0.0 }')
      result = evaluate_diff(read("twin_2083_base"), read("twin_2083_head"), config)
      entry = result.ratchet.first
      expect(entry.verdict).to eq(:breach)
      expect(entry.observed_log2).to eq(3.0)
      expect(entry.message).to eq("scope app/**/*: net +3.000 log2 exceeds budget +0.000")
      expect(entry.kind).to eq("paths")
      expect(result.exit_code(:error)).to eq(1)

      relaxed = config_with_budgets('- { paths: ["app/**/*"], max_increase_log2: 3.0 }')
      result = evaluate_diff(read("twin_2083_base"), read("twin_2083_head"), relaxed)
      entry = result.ratchet.first
      expect(entry.verdict).to eq(:pass) # net exactly AT budget passes (strict >)
      expect(entry.message).to be_nil
    end

    it "gates by per-budget severity (warn breach: exit 0 at :error, 1 at :warn)" do
      config = config_with_budgets(
        '- { paths: ["app/**/*"], max_increase_log2: -1.0, severity: warn }'
      )
      # all-unchanged delta: same fixture both sides
      result = evaluate_diff(read("twin_2083_head"), read("twin_2083_head"), config)
      entry = result.ratchet.first
      expect(entry.verdict).to eq(:breach)
      expect(entry.severity).to eq(:warn)
      expect(entry.message).to eq("scope app/**/*: net +0.000 log2 exceeds budget -1.000")
      expect(result.exit_code(:error)).to eq(0)
      expect(result.exit_code(:warn)).to eq(1)
    end
  end

  describe "G8 empty-scope semantics" do
    it "no_match + empty_scope at budget ≥ 0 — wording splits unchanged vs unmatched" do
      unchanged = config_with_budgets('- { paths: ["app/**/*"], max_increase_log2: 0.0 }')
      result = evaluate_diff(read("twin_2083_head"), read("twin_2083_head"), unchanged)
      entry = result.ratchet.first
      expect(entry.verdict).to eq(:no_match)
      expect(entry.empty_scope).to be(true)
      expect(entry.message).to eq("files unchanged")
      expect(result.exit_code(:error)).to eq(0) # never a gate

      unmatched = config_with_budgets('- { paths: ["nowhere/**"], max_increase_log2: 0.0 }')
      result = evaluate_diff(read("twin_2083_base"), read("twin_2083_head"), unmatched)
      entry = result.ratchet.first
      expect(entry.verdict).to eq(:no_match)
      expect(entry.message).to eq("matched no files")
    end

    it "breaches an EMPTY scope under a negative budget (forced decrease unmet)" do
      config = config_with_budgets('- { paths: ["nowhere/**"], max_increase_log2: -1.0 }')
      result = evaluate_diff(read("twin_2083_base"), read("twin_2083_head"), config)
      entry = result.ratchet.first
      expect(entry.verdict).to eq(:breach)
      expect(entry.observed_log2).to eq(0.0)
      expect(entry.empty_scope).to be(true)
    end
  end

  describe "entrypoints budgets (Q7 keys, I-P10 matcher)" do
    it "breaches the `[0]`-bearing EXACT symbol at budget 0.0 — the t3 shape" do
      config = config_with_budgets(
        "- { entrypoints: [\"#{EP_SYMBOL}\"], max_increase_log2: 0.0 }"
      )
      result = evaluate_diff(read("twin_2083_base"), read("twin_2083_head"), config)
      entry = result.ratchet.first
      expect(entry.kind).to eq("entrypoint")
      expect(entry.scope).to eq(EP_SYMBOL) # scope renders the SYMBOL
      expect(entry.verdict).to eq(:breach)
      expect(entry.message)
        .to eq("scope #{EP_SYMBOL}: net +3.000 log2 exceeds budget +0.000")
    end

    it "renames leave a stale-symbol budget at no_match — config follows the rename" do
      config = config_with_budgets(
        '- { entrypoints: ["Api::V1::LegalDoc#PATCH[0]"], max_increase_log2: 0.0 }'
      )
      result = evaluate_diff(read("twin_2083_base"), read("twin_2083_head"), config)
      entry = result.ratchet.first
      expect(entry.verdict).to eq(:no_match)
      expect(entry.empty_scope).to be(true)
    end

    it "zero eps on both sides → no_match, NEVER a confident pass" do
      node = ReviewStubs.stub_node(file: "lib/quiet.rb", symbol: "Quiet#helper",
                                   branches: 2, escapes: false, outcome_arity: 2)
      side = ReviewStubs::StubVintage.new(nodes: [node], edges: true,
                                          graph: ReviewStubs::StubGraph.new(ep_metrics: {}))
      delta = ReviewStubs::StubDelta.new(base: side, head: side, ep_deltas: {})
      config = config_with_budgets(
        '- { entrypoints: ["Api::**"], max_increase_log2: 0.0 }'
      )
      result = Archbuddy::Review::RuleEngine.evaluate(vintage: side, delta: delta,
                                                      config: config, todo: nil)
      ratchet = result.ratchet.select { |e| e.kind == "entrypoint" }
      expect(ratchet.size).to eq(1)
      expect(ratchet.first.verdict).to eq(:no_match)
    end
  end

  describe "lint context (C14/F7 — verdict nil, never gates)" do
    it "emits a paths context row with current_total_log2 + matched_files" do
      config = config_with_budgets('- { paths: ["app/**/*"], max_increase_log2: 0.0 }')
      result = Archbuddy::Review::RuleEngine.evaluate(vintage: read("twin_2083_head"),
                                                      config: config, todo: nil)
      entry = result.ratchet.first
      expect(entry.verdict).to be_nil
      expect(entry.kind).to eq("paths")
      expect(entry.current_total_log2).to eq(16.0)
      expect(entry.matched_files).to eq(2)
      expect(entry.empty_scope).to be(false)
    end

    it "emits an entrypoint context row: Σ subtree_log2_by_ep over matched eps (F7)" do
      config = config_with_budgets(
        "- { entrypoints: [\"#{EP_SYMBOL}\"], max_increase_log2: 0.0 }"
      )
      result = Archbuddy::Review::RuleEngine.evaluate(vintage: read("twin_2083_head"),
                                                      config: config, todo: nil)
      entry = result.ratchet.first
      expect(entry.verdict).to be_nil
      expect(entry.kind).to eq("entrypoint")
      expect(entry.current_total_log2).to eq(16.0)
      expect(entry.matched_files).to eq(1)
    end
  end

  it "never reads the todo (L5 — :delta kinds get none from the engine)" do
    source = File.read(File.expand_path(
                         "../../lib/archbuddy/review/rules/complexity_ratchet.rb", __dir__
                       ), encoding: "UTF-8")
    expect(source).not_to match(/entry_for|todo_entry|gate_node_result|gate_ep_result/)
    expect(source).not_to match(/calibration/i)
  end
end
