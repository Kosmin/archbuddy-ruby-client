# frozen_string_literal: true

require "tmpdir"
require "archbuddy"
require "archbuddy/review"
require_relative "../support/stub_vintage"

# v0.15 P1-N3: FirewallBreaches — dual-mode (lint standing count / diff
# event catch, absorbing the retired NoNewEscapes verbatim), info severity
# both modes, V15-F3 components shape, orphan-event Q8 coverage (the ONE
# reachability-independent use_case diff output — V15-F4), attribution
# honesty (no edges ⇒ not_evaluable entirely, never partial orphan output).
RSpec.describe Archbuddy::Review::Rules::FirewallBreaches do
  EP_FILE = "app/api/api/v1/redeem_templates.rb"
  EP_SYM = "Api::V1::RedeemTemplates#PATCH[0]"
  ESC_FILE = "app/models/program/redeem/template.rb"
  ESC_SYM = "Program::Redeem::Template#dynamic_send"

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

  def evaluate(vintage, config: build_config, delta: nil, todo: nil)
    Archbuddy::Review::RuleEngine.evaluate(vintage: vintage, delta: delta,
                                           config: config, todo: todo)
  end

  def fb(result)
    result.findings.select { |f| f.rule == "FirewallBreaches" }
  end

  def ep_vintage(escapes_in_cone:, file: EP_FILE, symbol: EP_SYM)
    ep = ReviewStubs.stub_node(file: file, symbol: symbol, branches: 8,
                               entrypoint: true, entrypoint_kind: "api",
                               escapes: false, outcome_arity: 2)
    metrics = ReviewStubs.stub_ep_metrics(
      file: file, symbol: symbol, escapes_in_cone: escapes_in_cone,
      cone_size: [escapes_in_cone.length + 1, 1].max
    )
    ReviewStubs::StubVintage.new(
      nodes: [ep], edges: true,
      graph: ReviewStubs::StubGraph.new(ep_metrics: { [file, symbol] => metrics })
    )
  end

  describe "lint count mode" do
    it "fires ONE info finding with the byte-locked message and V15-F3 components" do
      vintage = ep_vintage(escapes_in_cone: [
                             { file: ESC_FILE, symbol: ESC_SYM },
                             { file: ESC_FILE, symbol: "Program::Redeem::Template#eval_hook" }
                           ])
      findings = fb(evaluate(vintage))
      expect(findings.size).to eq(1)
      f = findings.first
      expect(f.severity).to eq(:info)
      expect(f.message)
        .to eq("2 escape node(s) inside this use case's cone — complexity unbounded by contracts")
      expect(f.components)
        .to eq("escapes" => { value: 2, threshold: 0, breached: true })
      expect(f.contributors.map { |c| c[:symbol] })
        .to contain_exactly(ESC_SYM, "Program::Redeem::Template#eval_hook")
    end

    it "stays silent at zero escapes and AT the threshold (strict >)" do
      expect(fb(evaluate(ep_vintage(escapes_in_cone: [])))).to be_empty

      config = build_config(<<~YAML)
        version: 1
        rules:
          FirewallBreaches:
            max_escapes: 2
      YAML
      two = ep_vintage(escapes_in_cone: [
                         { file: ESC_FILE, symbol: ESC_SYM },
                         { file: ESC_FILE, symbol: "Program::Redeem::Template#eval_hook" }
                       ])
      expect(fb(evaluate(two, config: config))).to be_empty
    end

    it "applies the escapes todo channel: 3 skips, 4 re-fires with the count clause" do
      todo = build_todo(<<~YAML)
        version: 1
        tool: "archbuddy 0.12.0"
        rule_count: 1
        node_count: 1
        rules:
          FirewallBreaches:
            - node: "#{EP_FILE}: #{EP_SYM}"
              values: { escapes: 3 }
      YAML
      three = (1..3).map { |i| { file: ESC_FILE, symbol: "E#esc#{i}" } }
      at_baseline = evaluate(ep_vintage(escapes_in_cone: three), todo: todo)
      expect(fb(at_baseline)).to be_empty
      expect(at_baseline.grandfathered.map(&:rule)).to include("FirewallBreaches")

      four = (1..4).map { |i| { file: ESC_FILE, symbol: "E#esc#{i}" } }
      refire = fb(evaluate(ep_vintage(escapes_in_cone: four), todo: todo)).first
      expect(refire.message).to eq("escapes grew past grandfathered baseline 3 → 4")
    end
  end

  describe "diff event mode" do
    def delta_entry(classification, base_escapes:, head_escapes:,
                    file: ESC_FILE, symbol: ESC_SYM)
      base_node = base_escapes.nil? && classification == :new ? nil : ReviewStubs.stub_node(
        file: file, symbol: symbol, branches: 4, escapes: base_escapes, outcome_arity: 2
      )
      head_node = ReviewStubs.stub_node(file: file, symbol: symbol, branches: 4,
                                        escapes: head_escapes, outcome_arity: 2)
      Archbuddy::Review::Delta::Entry.new(
        file: file, symbol: symbol, classification: classification,
        base_branches: base_node&.branches, head_branches: head_node.branches,
        delta_log2: 0.0, base_node: base_node, head_node: head_node,
        moved_from: nil, moved_to: nil
      )
    end

    def diff_fixture(entries:, escapes_in_cone:)
      head = ep_vintage(escapes_in_cone: escapes_in_cone)
      base = ep_vintage(escapes_in_cone: [])
      delta = ReviewStubs::StubDelta.new(base: base, head: head, entries: entries)
      [head, delta]
    end

    it "attributes a false→true flip to its host ep — byte-exact worked instance" do
      head, delta = diff_fixture(
        entries: [delta_entry(:changed_attrs, base_escapes: false, head_escapes: true)],
        escapes_in_cone: [{ file: ESC_FILE, symbol: ESC_SYM }]
      )
      findings = fb(evaluate(head, delta: delta))
      expect(findings.size).to eq(1)
      f = findings.first
      expect(f.severity).to eq(:info)
      expect(f.file).to eq(EP_FILE)
      expect(f.symbol).to eq(EP_SYM)
      expect(f.message).to eq(
        "1 new escape node(s) entered this use case's cone: " \
        "app/models/program/redeem/template.rb: Program::Redeem::Template#dynamic_send"
      )
      expect(f.components).to eq("escapes" => { value: 1, threshold: 0, breached: true })
    end

    it "emits the orphan-event finding verbatim when no cone hosts the node (components nil)" do
      head, delta = diff_fixture(
        entries: [delta_entry(:new, base_escapes: nil, head_escapes: true)],
        escapes_in_cone: [] # the ep's cone does NOT contain the new node
      )
      findings = fb(evaluate(head, delta: delta))
      expect(findings.size).to eq(1)
      f = findings.first
      expect(f.message).to eq(
        "escape introduced outside any use case (not reachable from any entrypoint): " \
        "app/models/program/redeem/template.rb: Program::Redeem::Template#dynamic_send"
      )
      expect(f.file).to eq(ESC_FILE)
      expect(f.symbol).to eq(ESC_SYM)
      expect(f.components).to be_nil
    end

    it "double-fires one event living in TWO cones, each on its own ep identity" do
      ep_a = ReviewStubs.stub_node(file: "app/api/a.rb", symbol: "A#GET[0]", branches: 2,
                                   entrypoint: true, escapes: false, outcome_arity: 2)
      ep_b = ReviewStubs.stub_node(file: "app/api/b.rb", symbol: "B#GET[0]", branches: 2,
                                   entrypoint: true, escapes: false, outcome_arity: 2)
      escape_ref = [{ file: ESC_FILE, symbol: ESC_SYM }]
      graph = ReviewStubs::StubGraph.new(ep_metrics: {
        ["app/api/a.rb", "A#GET[0]"] => ReviewStubs.stub_ep_metrics(
          file: "app/api/a.rb", symbol: "A#GET[0]", escapes_in_cone: escape_ref, cone_size: 2
        ),
        ["app/api/b.rb", "B#GET[0]"] => ReviewStubs.stub_ep_metrics(
          file: "app/api/b.rb", symbol: "B#GET[0]", escapes_in_cone: escape_ref, cone_size: 2
        )
      })
      head = ReviewStubs::StubVintage.new(nodes: [ep_a, ep_b], edges: true, graph: graph)
      base = ReviewStubs::StubVintage.new(nodes: [ep_a, ep_b], edges: true)
      delta = ReviewStubs::StubDelta.new(
        base: base, head: head,
        entries: [delta_entry(:changed_attrs, base_escapes: false, head_escapes: true)]
      )

      findings = fb(evaluate(head, delta: delta))
      expect(findings.map(&:symbol)).to contain_exactly("A#GET[0]", "B#GET[0]")
      expect(findings.map(&:fingerprint).uniq.size).to eq(2)
    end

    it "fires born-true (:new) events and skips nil→true matched pairs silently" do
      head, delta = diff_fixture(
        entries: [
          delta_entry(:new, base_escapes: nil, head_escapes: true,
                      symbol: "Program::Redeem::Template#born_true"),
          delta_entry(:changed_attrs, base_escapes: nil, head_escapes: true,
                      symbol: "Program::Redeem::Template#nil_side")
        ],
        escapes_in_cone: []
      )
      findings = fb(evaluate(head, delta: delta))
      expect(findings.map(&:symbol)).to eq(["Program::Redeem::Template#born_true"])
    end

    it "V15-F4: zero-ep head still fires orphan events (never not_evaluable in diff)" do
      lonely = ReviewStubs.stub_node(file: "lib/quiet.rb", symbol: "Quiet#helper",
                                     branches: 2, escapes: false, outcome_arity: 2)
      head = ReviewStubs::StubVintage.new(
        nodes: [lonely], edges: true,
        graph: ReviewStubs::StubGraph.new(ep_metrics: {})
      )
      base = ReviewStubs::StubVintage.new(nodes: [lonely], edges: true)
      delta = ReviewStubs::StubDelta.new(
        base: base, head: head,
        entries: [delta_entry(:new, base_escapes: nil, head_escapes: true)]
      )

      result = evaluate(head, delta: delta)
      expect(fb(result).size).to eq(1)
      expect(fb(result).first.message).to include("escape introduced outside any use case")
      expect(result.not_evaluable.map { |n| n[:rule] }).not_to include("FirewallBreaches")
      # the ep-seeded siblings ARE Q8-gated on the same run
      q8 = result.not_evaluable.select { |n| n[:reason].include?("no entrypoints") }
      expect(q8.map { |n| n[:rule] }).to include("UseCaseComplexity", "UseCaseDividend")
    end

    it "orphan events fire despite any todo entry (never grandfathered)" do
      todo = build_todo(<<~YAML)
        version: 1
        tool: "archbuddy 0.12.0"
        rule_count: 1
        node_count: 1
        rules:
          FirewallBreaches:
            - node: "#{ESC_FILE}: #{ESC_SYM}"
              values: { escapes: 9 }
      YAML
      head, delta = diff_fixture(
        entries: [delta_entry(:new, base_escapes: nil, head_escapes: true)],
        escapes_in_cone: []
      )
      expect(fb(evaluate(head, delta: delta, todo: todo)).size).to eq(1)
    end
  end

  describe "evaluability (attribution honesty)" do
    it "diff with a v1 base (no escapes stamps) → the carried NoNewEscapes reason" do
      head = ep_vintage(escapes_in_cone: [])
      v1_base = ReviewStubs::StubVintage.new(nodes: [
        ReviewStubs.stub_node(file: "app/a.rb", symbol: "A#x", branches: 2)
      ], edges: true)
      delta = ReviewStubs::StubDelta.new(base: v1_base, head: head, entries: [])
      result = evaluate(head, delta: delta)
      expect(result.not_evaluable).to include(
        rule: "FirewallBreaches", reason: "base vintage lacks 'escapes' (pre-v4 fragments)"
      )
    end

    it "lint without edges → not_evaluable ENTIRELY, never partial orphan output" do
      ep = ReviewStubs.stub_node(file: EP_FILE, symbol: EP_SYM, branches: 2,
                                 entrypoint: true, escapes: true, outcome_arity: 2)
      result = evaluate(ReviewStubs::StubVintage.new(nodes: [ep], edges: false))
      expect(result.not_evaluable).to include(
        rule: "FirewallBreaches", reason: "fragments carry no edges"
      )
      expect(fb(result)).to be_empty
    end
  end

  it "never reads presenter cost inputs (A4 grep gate)" do
    source = File.read(File.expand_path(
                         "../../lib/archbuddy/review/rules/firewall_breaches.rb", __dir__
                       ), encoding: "UTF-8")
    expect(source).not_to match(/calibration/i)
  end
end
