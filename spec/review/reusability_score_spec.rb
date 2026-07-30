# frozen_string_literal: true

require "tmpdir"
require "archbuddy"
require "archbuddy/review"
require_relative "../support/stub_vintage"

# v0.16 T8: ReusabilityScore — the 8th family rule (D-C4). Engine-served
# −5..+5 score gated at `score <= min_score` over FRESH stamps only, the
# X-1/M14 published-rounding boundary pair (−4.0 fires / −3.99 quiet), the
# NEW ∪ GROWN diff universe ([S:G4]), the D-C3 staleness disclosure, the
# D-C5 debt-milli todo lifecycle, the null-vs-absent evaluability asymmetry,
# and the Q8 product-copy law — all through the REAL load-time registration.
RSpec.describe Archbuddy::Review::Rules::ReusabilityScore do
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

  def evaluate(vintage, config: build_config, todo: nil, delta: nil)
    Archbuddy::Review::RuleEngine.evaluate(vintage: vintage, delta: delta,
                                           config: config, todo: todo)
  end

  def rs_findings(result)
    result.findings.select { |f| f.rule == "ReusabilityScore" }
  end

  def rs_notes(result)
    result.not_evaluable.select { |n| n[:rule] == "ReusabilityScore" }
  end

  # A FRESH v6-stamped node: carried collapse == round(branches/max(arity,1), 2)
  # (the D-C3 consistency check) with the engine-published score triple.
  def scored_node(symbol:, score:, score_raw:, file: "app/a.rb", score_band: nil,
                  branches: 8, outcome_arity: 1, **overrides)
    ReviewStubs.stub_node(
      file: file, symbol: symbol, branches: branches, outcome_arity: outcome_arity,
      collapse: (branches.to_f / [outcome_arity || 1, 1].max).round(2),
      score: score, score_band: score_band || score&.round,
      score_raw: score_raw, serializer_version: 6, **overrides
    )
  end

  it "is registered under its exact name at load time (C-7 registry consumed)" do
    expect(Archbuddy::Review::RuleEngine.registry["ReusabilityScore"]).to eq(described_class)
    expect(described_class.kind).to eq(:node)
    expect(described_class.needs_edges?).to be(false)
    expect(described_class.required_node_keys).to eq([:score_raw])
  end

  it "lint: fires on a fresh <= -4 node with the pinned break-it-down copy at :info" do
    vintage = ReviewStubs::StubVintage.new(nodes: [
      scored_node(symbol: "A#monster", score: -4.52, score_raw: -18.5, score_band: -5),
      scored_node(symbol: "A#mid", score: -2.11, score_raw: -3.104, score_band: -2),
      scored_node(symbol: "A#zero", score: 0.0, score_raw: 0.0, score_band: 0)
    ], edges: false)

    findings = rs_findings(evaluate(vintage))
    expect(findings.map(&:symbol)).to eq(["A#monster"])
    f = findings.first
    expect(f.severity).to eq(:info)
    expect(f.value_raw).to eq(18_500) # debt milli: (-score_raw * 1000).round
    expect(f.message).to eq(
      "engine reusability score -4.52 (raw -18.5): false reusability — " \
      "break it down before growing it"
    )
  end

  it "X-1/M14 boundary: stamped score exactly -4.0 fires at min_score -4; -3.99 stays quiet" do
    vintage = ReviewStubs::StubVintage.new(nodes: [
      scored_node(symbol: "A#at_boundary", score: -4.0, score_raw: -13.0, score_band: -4),
      scored_node(symbol: "A#just_above", score: -3.99, score_raw: -12.9, score_band: -4)
    ], edges: false)

    findings = rs_findings(evaluate(vintage))
    expect(findings.map(&:symbol)).to eq(["A#at_boundary"])
  end

  it "positive-pole and equilibrium nodes NEVER fire (the +5 incentive is presenter-only)" do
    vintage = ReviewStubs::StubVintage.new(nodes: [
      scored_node(symbol: "A#booth", score: 4.07, score_raw: 6.907, score_band: 4),
      scored_node(symbol: "A#saturated", score: 5.0, score_raw: 11.51, score_band: 5),
      scored_node(symbol: "A#zero", score: 0.0, score_raw: 0.0, score_band: 0)
    ], edges: false)

    expect(rs_findings(evaluate(vintage))).to be_empty
  end

  it "appends the escape caveat (O2) when the breaching node escapes" do
    vintage = ReviewStubs::StubVintage.new(nodes: [
      scored_node(symbol: "A#escape", score: -4.2, score_raw: -14.75, score_band: -4,
                  escapes: true)
    ], edges: false)

    f = rs_findings(evaluate(vintage)).first
    expect(f.message).to eq(
      "engine reusability score -4.2 (raw -14.75): false reusability — " \
      "break it down before growing it (escape: inline surface above contract — " \
      "NOT statically extraction-recoverable)"
    )
  end

  it "Q8 copy law: no message ever says 'reuse more' (source grep-gated too)" do
    vintage = ReviewStubs::StubVintage.new(nodes: [
      scored_node(symbol: "A#monster", score: -5.0, score_raw: -21.3, score_band: -5)
    ], edges: false)
    messages = rs_findings(evaluate(vintage)).map(&:message)
    expect(messages).not_to be_empty
    expect(messages.grep(/reuse more/)).to eq([])

    source = File.read(File.expand_path(
                         "../../lib/archbuddy/review/rules/reusability_score.rb", __dir__
                       ), encoding: "UTF-8")
    expect(source).not_to match(/reuse more/)
    expect(source).not_to match(/calibration/i) # A4 presenter-only grep gate
  end

  describe "diff universe = NEW ∪ GROWN only ([S:G4])" do
    def stub_delta_for(classification, head_node, base_node: nil)
      entry = Archbuddy::Review::Delta::Entry.new(
        file: head_node.file, symbol: head_node.symbol, classification: classification,
        base_branches: base_node&.branches, head_branches: head_node.branches,
        delta_log2: 0.0, base_node: base_node, head_node: head_node,
        moved_from: nil, moved_to: nil
      )
      head = ReviewStubs::StubVintage.new(nodes: [head_node], edges: true)
      base = ReviewStubs::StubVintage.new(nodes: [base_node].compact, edges: true)
      [head, ReviewStubs::StubDelta.new(base: base, head: head, entries: [entry])]
    end

    it "fires exactly once on a GROWN -5 node (the acceptance row) at exit 0 by default" do
      bad = scored_node(symbol: "A#monster", score: -5.0, score_raw: -21.3, score_band: -5)
      head, delta = stub_delta_for(:grown, bad, base_node: scored_node(
        symbol: "A#monster", score: -4.8, score_raw: -19.0, score_band: -5, branches: 4
      ))
      result = evaluate(head, delta: delta)
      expect(rs_findings(result).size).to eq(1)
      expect(rs_findings(result).first.severity).to eq(:info)
      expect(result.exit_code(:error)).to eq(0) # default fail level — advisory
    end

    it "SHRUNK-but-still-bad stays silent (reduction is the desired direction)" do
      still_bad = scored_node(symbol: "A#monster", score: -4.6, score_raw: -18.9,
                              score_band: -5)
      head, delta = stub_delta_for(:shrunk, still_bad, base_node: scored_node(
        symbol: "A#monster", score: -5.0, score_raw: -21.3, score_band: -5, branches: 16
      ))
      expect(rs_findings(evaluate(head, delta: delta))).to be_empty
    end

    it "unchanged monsters in the head vintage stay lint's jurisdiction (empty delta)" do
      bad = scored_node(symbol: "A#monster", score: -5.0, score_raw: -21.3, score_band: -5)
      head = ReviewStubs::StubVintage.new(nodes: [bad], edges: true)
      delta = ReviewStubs::StubDelta.new(base: head, head: head, entries: [])
      expect(rs_findings(evaluate(head, delta: delta))).to be_empty
    end
  end

  describe "D-C3 staleness: the rule evaluates node-fresh stamps only" do
    it "stale stamp => ONE per-node disclosure, NO finding, never a fabricated number" do
      stale = ReviewStubs.stub_node(
        file: "app/a.rb", symbol: "A#drifted", branches: 8, outcome_arity: 1,
        collapse: 3.0, # carried stamp != round(8/1, 2) — body changed since analyze
        score: -5.0, score_band: -5, score_raw: -21.3, serializer_version: 6
      )
      result = evaluate(ReviewStubs::StubVintage.new(nodes: [stale], edges: false))
      expect(rs_findings(result)).to be_empty
      expect(rs_notes(result).map { |n| n[:reason] }).to eq([
        "score stamp stale for app/a.rb:A#drifted — run archbuddy analyze (or --analyze-sides)"
      ])
    end

    it "fresh nodes still evaluate alongside a stale sibling" do
      stale = ReviewStubs.stub_node(
        file: "app/a.rb", symbol: "A#drifted", branches: 8, outcome_arity: 1,
        collapse: 3.0, score: -5.0, score_band: -5, score_raw: -21.3,
        serializer_version: 6
      )
      fresh = scored_node(symbol: "A#monster", score: -4.52, score_raw: -18.5,
                          score_band: -5)
      result = evaluate(ReviewStubs::StubVintage.new(nodes: [stale, fresh], edges: false))
      expect(rs_findings(result).map(&:symbol)).to eq(["A#monster"])
      expect(rs_notes(result).size).to eq(1)
    end
  end

  describe "evaluability: the null-vs-absent asymmetry (L6)" do
    it "keys ABSENT (pre-v6 / never analyzed) => the single pinned not_evaluable note" do
      pre_v6 = ReviewStubs::StubVintage.new(nodes: [
        ReviewStubs.stub_node(file: "app/a.rb", symbol: "A#x", branches: 65_536)
      ], edges: false)
      result = evaluate(pre_v6)
      expect(rs_findings(result)).to be_empty
      expect(rs_notes(result)).to eq([{
        rule: "ReusabilityScore",
        reason: "score stamps absent — serializer < v6 or vintage never analyzed"
      }])
    end

    it "null-valued keys ('analyzed, node unscored') => silent skip: no finding, no note" do
      unscored = ReviewStubs.stub_node(
        file: "app/a.rb", symbol: "A#fragment", branches: 65_536,
        keys_present: %w[file symbol branches score score_band score_raw]
      )
      result = evaluate(ReviewStubs::StubVintage.new(nodes: [unscored], edges: false))
      expect(rs_findings(result)).to be_empty
      expect(rs_notes(result)).to be_empty
    end
  end

  describe "the D-C5 debt-milli todo lifecycle (value_raw <= recorded, verbatim)" do
    let(:todo) do
      build_todo(<<~YAML)
        version: 1
        tool: "archbuddy 0.13.0"
        rule_count: 1
        node_count: 1
        rules:
          ReusabilityScore:
            - node: "app/a.rb: A#monster"
              value: 18500
      YAML
    end

    it "skips at the pinned debt, re-fires past it with the :score_debt message" do
      at_baseline = ReviewStubs::StubVintage.new(nodes: [
        scored_node(symbol: "A#monster", score: -4.52, score_raw: -18.5, score_band: -5)
      ], edges: false)
      result = evaluate(at_baseline, todo: todo)
      expect(rs_findings(result)).to be_empty
      skip_row = result.grandfathered.find { |g| g.rule == "ReusabilityScore" }
      expect(skip_row.recorded).to eq(18_500)
      expect(skip_row.current).to eq(18_500)
      expect(skip_row.healed).to be(false)

      worse = ReviewStubs::StubVintage.new(nodes: [
        scored_node(symbol: "A#monster", score: -4.61, score_raw: -19.2, score_band: -5)
      ], edges: false)
      refire = rs_findings(evaluate(worse, todo: todo)).first
      expect(refire.message).to eq(
        "reusability debt worsened: raw -18.500 → -19.200 (pinned value exceeded)"
      )
      expect(refire.grandfathered_baseline).to eq(18_500)
      expect(refire.value_raw).to eq(19_200)
    end

    it "heals when the node climbs back above min_score" do
      healed = ReviewStubs::StubVintage.new(nodes: [
        scored_node(symbol: "A#monster", score: -2.1, score_raw: -3.05, score_band: -2)
      ], edges: false)
      result = evaluate(healed, todo: todo)
      expect(rs_findings(result)).to be_empty
      skip_row = result.grandfathered.find { |g| g.rule == "ReusabilityScore" }
      expect(skip_row.healed).to be(true)
    end
  end

  describe "exit-code discipline (L7): default-advisory, opt-in gating" do
    let(:vintage) do
      ReviewStubs::StubVintage.new(nodes: [
        scored_node(symbol: "A#monster", score: -4.52, score_raw: -18.5, score_band: -5)
      ], edges: false)
    end

    it ":info never trips exit 1 at the default fail level" do
      result = evaluate(vintage)
      expect(rs_findings(result).size).to eq(1)
      expect(result.exit_code(:error)).to eq(0)
    end

    it "severity: error + fail_level: error => exit 1 (the opt-in gate)" do
      config = build_config(<<~YAML)
        version: 1
        rules:
          ReusabilityScore:
            severity: error
      YAML
      result = evaluate(vintage, config: config)
      expect(rs_findings(result).first.severity).to eq(:error)
      expect(result.exit_code(:error)).to eq(1)
    end

    it "honors a user min_score of -5 (X-4: negative bounds validate as written)" do
      config = build_config(<<~YAML)
        version: 1
        rules:
          ReusabilityScore:
            min_score: -5
      YAML
      result = evaluate(vintage, config: config) # -4.52 > -5 — quiet now
      expect(rs_findings(result)).to be_empty
    end
  end

  describe "degenerate / empty-input behavior (seed-relative rows)" do
    it "empty vintage: :node kind skipped by the engine — zero findings, zero notes" do
      result = nil
      expect do
        result = evaluate(ReviewStubs::StubVintage.new(nodes: []))
      end.to output(/warning: vintage contains 0 nodes/).to_stderr
      expect(rs_findings(result)).to be_empty
      expect(rs_notes(result)).to be_empty
    end

    it "zero-entrypoint vintage does NOT suppress the rule (Q7 G-7: seed-independent)" do
      no_eps = ReviewStubs::StubVintage.new(nodes: [
        scored_node(symbol: "A#monster", score: -4.52, score_raw: -18.5, score_band: -5,
                    entrypoint: false)
      ], edges: false)
      result = evaluate(no_eps)
      expect(rs_findings(result).map(&:symbol)).to eq(["A#monster"])
      q8 = result.not_evaluable.select { |n| n[:reason].include?("no entrypoints") }
      expect(q8.map { |n| n[:rule] }).not_to include("ReusabilityScore")
    end
  end
end
