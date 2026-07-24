# frozen_string_literal: true

require "tmpdir"
require "archbuddy"
require "archbuddy/review"
require_relative "../support/stub_vintage"

# v0.15 P2-T8 (delta rules, part 1): ExponentialNode's diff universe
# (NEW ∪ GROWN only — [S:G4]) and MultiplicativeGrowth (GROWN, GTE), on the
# P2-T4-authored #2083/#2146 twins. Todo interplay: EN grandfathered skip /
# R21 re-fire while MG STILL fires (never grandfathered).
RSpec.describe "Delta rules (ExponentialNode diff + MultiplicativeGrowth)" do
  FIXTURES = File.expand_path("../fixtures/review/vintages", __dir__) unless defined?(FIXTURES)
  X_FILE = "app/api/api/v1/redeem_templates.rb"
  X_SYM = "Api::V1::RedeemTemplates#PATCH[0]"

  def read(name)
    Archbuddy::Review::FragmentWalk.read(File.join(FIXTURES, name))
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

  def evaluate_twin(base_name, head_name, config: build_config, todo: nil)
    base = read(base_name)
    head = read(head_name)
    delta = Archbuddy::Review::Delta.new(base: base, head: head)
    Archbuddy::Review::RuleEngine.evaluate(vintage: head, delta: delta,
                                           config: config, todo: todo)
  end

  def by_rule(result, rule)
    result.findings.select { |f| f.rule == rule }
  end

  it "#2083-twin: EN(error) + MG(error) fire on X; NEW Y (b=1) yields NOTHING" do
    result = evaluate_twin("twin_2083_base", "twin_2083_head")

    en = by_rule(result, "ExponentialNode")
    expect(en.map(&:symbol)).to eq([X_SYM])
    expect(en.first.severity).to eq(:error)
    expect(en.first.message).to eq("own branching 65536 (2^16.0) exceeds 2^5 (Q4 boundary)")

    mg = by_rule(result, "MultiplicativeGrowth")
    expect(mg.map(&:symbol)).to eq([X_SYM])
    expect(mg.first.severity).to eq(:error)
    expect(mg.first.message).to eq(
      "branching grew +3.0 log2 (8192 → 65536, 2^13.0 → 2^16.0) — threshold +2"
    )
    expect(mg.first.delta_log2).to eq(3.0)

    new_y = result.findings.select { |f| f.symbol == "Program::Redeem::Template#bonus_points?" }
    expect(new_y).to be_empty
  end

  it "#2146-twin: ZERO findings from EN and MG" do
    result = evaluate_twin("twin_2146_base", "twin_2146_head")
    expect(by_rule(result, "ExponentialNode")).to be_empty
    expect(by_rule(result, "MultiplicativeGrowth")).to be_empty
  end

  describe "boundaries (in-spec deltas)" do
    def stub_delta_for(base_branches, head_branches, classification)
      base_node = base_branches && ReviewStubs.stub_node(
        file: "app/a.rb", symbol: "A#x", branches: base_branches,
        escapes: false, outcome_arity: 2
      )
      head_node = ReviewStubs.stub_node(file: "app/a.rb", symbol: "A#x",
                                        branches: head_branches,
                                        escapes: false, outcome_arity: 2)
      entry = Archbuddy::Review::Delta::Entry.new(
        file: "app/a.rb", symbol: "A#x", classification: classification,
        base_branches: base_branches, head_branches: head_branches,
        delta_log2: Math.log2(head_branches) - (base_branches ? Math.log2(base_branches) : 0.0),
        base_node: base_node, head_node: head_node, moved_from: nil, moved_to: nil
      )
      head = ReviewStubs::StubVintage.new(nodes: [head_node], edges: true)
      base = ReviewStubs::StubVintage.new(nodes: [base_node].compact, edges: true)
      [head, ReviewStubs::StubDelta.new(base: base, head: head, entries: [entry])]
    end

    def run(head, delta, todo: nil)
      Archbuddy::Review::RuleEngine.evaluate(vintage: head, delta: delta,
                                             config: build_config, todo: todo)
    end

    it "EN diff: b=32 head does NOT fire (strict >, the Q3 tie class); b=33 fires" do
      head32, delta32 = stub_delta_for(16, 32, :grown)
      expect(by_rule(run(head32, delta32), "ExponentialNode")).to be_empty

      head33, delta33 = stub_delta_for(16, 33, :grown)
      expect(by_rule(run(head33, delta33), "ExponentialNode").size).to eq(1)
    end

    it "EN diff universe is NEW∪GROWN only — SHRUNK-but-still-huge never fires" do
      head, delta = stub_delta_for(131_072, 65_536, :shrunk)
      expect(by_rule(run(head, delta), "ExponentialNode")).to be_empty
    end

    it "MG fires AT Δlog2 == 2.0 exactly (GTE) and never on NEW entries" do
      head, delta = stub_delta_for(16, 64, :grown) # Δ exactly 2.0
      mg = by_rule(run(head, delta), "MultiplicativeGrowth")
      expect(mg.size).to eq(1)
      expect(mg.first.message).to eq(
        "branching grew +2.0 log2 (16 → 64, 2^4.0 → 2^6.0) — threshold +2"
      )

      head_new, delta_new = stub_delta_for(nil, 64, :new)
      expect(by_rule(run(head_new, delta_new), "MultiplicativeGrowth")).to be_empty
    end
  end

  describe "todo interplay on the #2083-twin" do
    it "EN skips at recorded 65536 while MG STILL fires (never grandfathered)" do
      todo = build_todo(<<~YAML)
        version: 1
        tool: "archbuddy 0.12.0"
        rule_count: 1
        node_count: 1
        rules:
          ExponentialNode:
            - node: "#{X_FILE}: #{X_SYM}"
              value: 65536
      YAML
      result = evaluate_twin("twin_2083_base", "twin_2083_head", todo: todo)
      expect(by_rule(result, "ExponentialNode")).to be_empty
      expect(result.grandfathered.map(&:rule)).to include("ExponentialNode")
      expect(by_rule(result, "MultiplicativeGrowth").size).to eq(1)
    end

    it "EN re-fires past recorded 8192 with the R21 full-replacement template" do
      todo = build_todo(<<~YAML)
        version: 1
        tool: "archbuddy 0.12.0"
        rule_count: 1
        node_count: 1
        rules:
          ExponentialNode:
            - node: "#{X_FILE}: #{X_SYM}"
              value: 8192
      YAML
      result = evaluate_twin("twin_2083_base", "twin_2083_head", todo: todo)
      en = by_rule(result, "ExponentialNode").first
      expect(en.message).to eq("grew past grandfathered baseline 8192 (2^13.0) → 65536 (2^16.0)")
      expect(en.grandfathered_baseline).to eq(8192)
    end
  end

  it "both rules are lint-inert (dispatch matrix — no findings, no N/A noise)" do
    head = read("twin_2083_head")
    result = Archbuddy::Review::RuleEngine.evaluate(vintage: head, config: build_config,
                                                    todo: nil)
    expect(by_rule(result, "MultiplicativeGrowth")).to be_empty
    expect(result.not_evaluable.map { |n| n[:rule] }).not_to include("MultiplicativeGrowth")
  end
end
