# frozen_string_literal: true

require "tmpdir"
require "archbuddy"
require "archbuddy/review"

# v0.15 P1-T6: the Q9 one-computation equality contract (§5-C31) — an
# entrypoints budget naming the exact `[0]` symbol yields a lint context
# row whose current_total_log2 equals that ep's leaderboard branching_log2
# at 3dp, and BOTH read the SAME memoized vintage.graph (object identity).
RSpec.describe "Ratchet lint-context equality (Q9 one-computation)" do
  RLC_FIXTURES = File.expand_path("../fixtures/review/vintages", __dir__)
  RLC_EP = "Api::V1::RedeemTemplates#PATCH[0]"
  RLC_FILE = "app/api/api/v1/redeem_templates.rb"

  def read(name)
    Archbuddy::Review::FragmentWalk.read(File.join(RLC_FIXTURES, name))
  end

  def build_config(yaml)
    Dir.mktmpdir do |dir|
      File.write(File.join(dir, ".archbuddy.yml"), yaml)
      return Archbuddy::Config.load(target_root: dir, cli: {})
    end
  end

  it "equates the [0]-ep budget context with the leaderboard fold at 3dp on ONE graph" do
    vintage = read("twin_2083_head")
    config = build_config(<<~YAML)
      version: 1
      rules:
        ComplexityRatchet:
          budgets:
            - { entrypoints: ["#{RLC_EP}"], max_increase_log2: 0.0 }
    YAML

    # ONE computation (§5-C31): the engine's context fold and the
    # leaderboard read below must share a single Graph construction.
    allow(Archbuddy::Review::Graph).to receive(:new).and_call_original

    result = Archbuddy::Review::RuleEngine.evaluate(vintage: vintage, config: config,
                                                    todo: nil)
    entry = result.ratchet.find { |e| e.kind == "entrypoint" }
    expect(entry.verdict).to be_nil
    expect(entry.matched_files).to eq(1)

    # The SAME memoized graph object (R7/R52) serves the leaderboard fold.
    graph = vintage.graph
    expect(vintage.graph).to equal(graph)
    leaderboard_blog2 = graph.ep_metrics[[RLC_FILE, RLC_EP]].branching_log2
    expect(entry.current_total_log2.round(3)).to eq(leaderboard_blog2.round(3))
    expect(graph.subtree_log2_by_ep[RLC_EP].round(3)).to eq(leaderboard_blog2.round(3))
    expect(Archbuddy::Review::Graph).to have_received(:new).once
  end

  it "emits the full-shape paths context row (C14/F7 contract home)" do
    vintage = read("twin_2083_head")
    config = build_config(<<~YAML)
      version: 1
      rules:
        ComplexityRatchet:
          budgets:
            - { paths: ["app/**/*"], max_increase_log2: 0.0 }
    YAML
    result = Archbuddy::Review::RuleEngine.evaluate(vintage: vintage, config: config,
                                                    todo: nil)
    entry = result.ratchet.first
    expect(entry.kind).to eq("paths")
    expect(entry.scope_paths).to eq(["app/**/*"])
    expect(entry.budget_log2).to eq(0.0)
    expect(entry.verdict).to be_nil # context NEVER gates
    expect(entry.observed_log2).to be_nil
    expect(entry.current_total_log2).to eq(16.0) # Σ log2 branches over matched nodes
    expect(entry.matched_files).to eq(2)
    expect(entry.empty_scope).to be(false)
    expect(entry.message).to be_nil
  end

  it "renders the empty-scope PATHS context honestly (0 files → 0.0 + empty_scope)" do
    vintage = read("twin_2083_head")
    config = build_config(<<~YAML)
      version: 1
      rules:
        ComplexityRatchet:
          budgets:
            - { paths: ["nowhere/**"], max_increase_log2: 0.0 }
    YAML
    result = Archbuddy::Review::RuleEngine.evaluate(vintage: vintage, config: config,
                                                    todo: nil)
    entry = result.ratchet.first
    expect(entry.kind).to eq("paths")
    expect(entry.verdict).to be_nil
    expect(entry.current_total_log2).to eq(0.0)
    expect(entry.matched_files).to eq(0)
    expect(entry.empty_scope).to be(true)
  end

  it "renders the empty-scope lint context honestly on a zero-match glob" do
    vintage = read("twin_2083_head")
    config = build_config(<<~YAML)
      version: 1
      rules:
        ComplexityRatchet:
          budgets:
            - { entrypoints: ["Api::V1::LegalDoc#PATCH[0]"], max_increase_log2: 0.0 }
    YAML
    result = Archbuddy::Review::RuleEngine.evaluate(vintage: vintage, config: config,
                                                    todo: nil)
    entry = result.ratchet.first
    expect(entry.verdict).to be_nil
    expect(entry.empty_scope).to be(true)
    expect(entry.current_total_log2).to eq(0.0)
    expect(result.exit_code(:error)).to eq(1) # gated by EN/UCC/UCD findings, never the context
  end
end
