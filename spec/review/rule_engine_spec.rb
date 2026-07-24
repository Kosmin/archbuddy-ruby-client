# frozen_string_literal: true

require "tmpdir"
require "digest"
require "archbuddy"
require "archbuddy/review"
require "archbuddy/review/rule_engine"
require "archbuddy/review/rules/base"
require_relative "../support/stub_vintage"

# v0.15 P1-T4: the RuleEngine core — kind dispatch, todo application
# (:node 4-step + :use_case per-metric 4-step), the Q8 zero-ep degenerate
# with the V15-F4 FirewallBreaches diff carve-out, and the R52 lazy-graph
# predicate. Rule behavior is exercised through spec-local Rules::Base
# doubles registered under real rule names ([S:F10]).
RSpec.describe Archbuddy::Review::RuleEngine do
  Engine = Archbuddy::Review::RuleEngine
  Q8 = "vintage has no entrypoints (nothing is reachable — check collector entrypoint detection)"

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

  def with_rules(mapping)
    mapping.each { |name, klass| Engine.register(name, klass) }
    yield
  ensure
    mapping.each_key { |name| Engine.unregister(name) }
  end

  def node_rule_double(threshold: 5)
    Class.new(Archbuddy::Review::Rules::Base) do
      kind :node
      define_method(:evaluate) do |ctx|
        ctx.universe_nodes.each do |n|
          log2 = Math.log2(n.branches)
          ctx.node_result(
            node: n, value_raw: n.branches, breaching: log2 > threshold,
            message: format("own branching %d (2^%.1f) exceeds 2^%g (Q4 boundary)",
                            n.branches, log2, threshold),
            value_log2: log2, threshold_log2: threshold
          )
        end
      end
    end
  end

  def use_case_rule_double(components: nil, clauses: nil)
    default_components = { "max_cone_node_log2" => { value: 6.0, threshold: 5.0, breached: true } }
    default_clauses = { "max_cone_node_log2" => "worst cone node 64 (2^6.0) exceeds 2^5 (Q4 boundary)" }
    comp = components || default_components
    cls = clauses || default_clauses
    Class.new(Archbuddy::Review::Rules::Base) do
      kind :use_case
      define_method(:evaluate) do |ctx|
        ctx.universe_eps.each do |ep|
          ctx.ep_result(file: ep.file, symbol: ep.symbol, components: comp, clauses: cls,
                        entrypoint_kind: ep.entrypoint_kind)
        end
      end
    end
  end

  def marker_rule_double(kind_sym, note: nil)
    Class.new(Archbuddy::Review::Rules::Base) do
      kind kind_sym
      define_method(:evaluate) do |ctx|
        ctx.not_evaluable!(note) if note
        ctx.add_finding(severity: :warn, message: "#{kind_sym} marker",
                        file: "marker.rb", symbol: "M##{kind_sym}")
      end
    end
  end

  def nodes(*branches)
    branches.each_with_index.map do |b, i|
      ReviewStubs.stub_node(file: "app/x#{i}.rb", symbol: "X#y#{i}", branches: b)
    end
  end

  def evaluate(vintage:, config: build_config, todo: nil, delta: nil)
    Engine.evaluate(vintage: vintage, delta: delta, config: config, todo: todo)
  end

  describe "node-kind dispatch through the ExponentialNode name (F10)" do
    it "fires strictly above 2^5 (33 fires, 32 does not — both asserted)" do
      with_rules("ExponentialNode" => node_rule_double) do
        hot = evaluate(vintage: ReviewStubs::StubVintage.new(nodes: nodes(33)))
        expect(hot.findings.size).to eq(1)
        expect(hot.findings.first.severity).to eq(:error)
        expect(hot.findings.first.message).to eq("own branching 33 (2^5.0) exceeds 2^5 (Q4 boundary)")

        cold = evaluate(vintage: ReviewStubs::StubVintage.new(nodes: nodes(32)))
        expect(cold.findings).to be_empty
      end
    end

    it "computes the canonical fingerprint" do
      with_rules("ExponentialNode" => node_rule_double) do
        vintage = ReviewStubs::StubVintage.new(
          nodes: [ReviewStubs.stub_node(file: "app/x.rb", symbol: "X#y", branches: 64)]
        )
        result = evaluate(vintage: vintage)
        expect(result.findings.first.fingerprint)
          .to eq(Digest::SHA256.hexdigest("ExponentialNode app/x.rb X#y"))
      end
    end
  end

  describe "the :node todo 4-step" do
    let(:todo) do
      build_todo(<<~YAML)
        version: 1
        tool: "archbuddy 0.13.0"
        rule_count: 1
        node_count: 1
        rules:
          ExponentialNode:
            - node: "app/x0.rb: X#y0"
              value: 64
      YAML
    end

    it "skips at the recorded value (counted, never hidden)" do
      with_rules("ExponentialNode" => node_rule_double) do
        result = evaluate(vintage: ReviewStubs::StubVintage.new(nodes: nodes(64)), todo: todo)
        expect(result.findings).to be_empty
        expect(result.grandfathered.size).to eq(1)
        skip = result.grandfathered.first
        expect([skip.recorded, skip.current, skip.healed]).to eq([64, 64, false])
        expect(result.grandfather_summary).to eq(entries: 1, nodes: 1, rules: 1, healed: 0)
      end
    end

    it "re-fires past the baseline with the full-replacement message (R21)" do
      with_rules("ExponentialNode" => node_rule_double) do
        result = evaluate(vintage: ReviewStubs::StubVintage.new(nodes: nodes(65)), todo: todo)
        expect(result.findings.size).to eq(1)
        finding = result.findings.first
        expect(finding.message).to eq("grew past grandfathered baseline 64 (2^6.0) → 65 (2^6.0)")
        expect(finding.grandfathered_baseline).to eq(64)
      end
    end

    it "counts a healed entry when the node passes" do
      with_rules("ExponentialNode" => node_rule_double) do
        result = evaluate(vintage: ReviewStubs::StubVintage.new(nodes: nodes(16)), todo: todo)
        expect(result.findings).to be_empty
        expect(result.grandfathered.size).to eq(1)
        expect(result.grandfathered.first.healed).to be(true)
        expect(result.grandfather_summary[:healed]).to eq(1)
      end
    end

    it "counts a healed entry when the node vanished from the vintage" do
      with_rules("ExponentialNode" => node_rule_double) do
        vintage = ReviewStubs::StubVintage.new(
          nodes: [ReviewStubs.stub_node(file: "app/other.rb", symbol: "O#z", branches: 2)]
        )
        result = evaluate(vintage: vintage, todo: todo)
        expect(result.grandfathered.size).to eq(1)
        expect(result.grandfathered.first.healed).to be(true)
      end
    end
  end

  describe "the :use_case per-metric todo 4-step (Q7)" do
    let(:ep_vintage) do
      ReviewStubs::StubVintage.new(
        nodes: [ReviewStubs.stub_node(file: "app/api/e.rb", symbol: "E#GET[0]", branches: 64,
                                      entrypoint: true, entrypoint_kind: "grape")]
      )
    end

    def ucc_todo
      build_todo(<<~YAML)
        version: 1
        tool: "archbuddy 0.13.0"
        rule_count: 1
        node_count: 1
        rules:
          UseCaseComplexity:
            - node: "app/api/e.rb: E#GET[0]"
              values: { max_cone_node_millilog2: 6000 }
      YAML
    end

    it "skips at 6000 (integer comparison only)" do
      double = use_case_rule_double(
        components: { "max_cone_node_log2" => { value: 6.0, threshold: 5.0, breached: true } }
      )
      with_rules("UseCaseComplexity" => double) do
        result = evaluate(vintage: ep_vintage, todo: ucc_todo)
        expect(result.findings).to be_empty
        expect(result.grandfathered.size).to eq(1)
        expect(result.grandfathered.first.recorded).to eq(6000)
      end
    end

    it "re-fires at 6022 (branches 65) with the byte-locked clause" do
      log2_65 = Math.log2(65)
      double = use_case_rule_double(
        components: { "max_cone_node_log2" => { value: log2_65, threshold: 5.0, breached: true } }
      )
      with_rules("UseCaseComplexity" => double) do
        result = evaluate(vintage: ep_vintage, todo: ucc_todo)
        expect(result.findings.size).to eq(1)
        finding = result.findings.first
        expect(finding.message)
          .to eq("worst cone node grew past grandfathered baseline 64 (2^6.0) → 65 (2^6.0)")
        expect(finding.grandfathered_baseline).to eq(6000)
        expect(result.grandfathered).to be_empty
      end
    end

    it "aggregates fire + re-fire clauses into ONE finding (L8)" do
      log2_65 = Math.log2(65)
      double = use_case_rule_double(
        components: {
          "max_cone_node_log2" => { value: log2_65, threshold: 5.0, breached: true },
          "reach" => { value: 142, threshold: 120, breached: true }
        },
        clauses: { "reach" => "reach 142 nodes exceeds 120" }
      )
      with_rules("UseCaseComplexity" => double) do
        result = evaluate(vintage: ep_vintage, todo: ucc_todo)
        expect(result.findings.size).to eq(1)
        expect(result.findings.first.message).to eq(
          "worst cone node grew past grandfathered baseline 64 (2^6.0) → 65 (2^6.0); " \
          "reach 142 nodes exceeds 120"
        )
        expect(result.findings.first.components.keys)
          .to contain_exactly("max_cone_node_log2", "reach")
      end
    end

    it "heals the entry when every recorded metric is below threshold" do
      double = use_case_rule_double(
        components: { "max_cone_node_log2" => { value: 4.0, threshold: 5.0, breached: false } }
      )
      with_rules("UseCaseComplexity" => double) do
        result = evaluate(vintage: ep_vintage, todo: ucc_todo)
        expect(result.findings).to be_empty
        expect(result.grandfathered.size).to eq(1)
        expect(result.grandfathered.first.healed).to be(true)
      end
    end
  end

  describe "kind dispatch matrix" do
    let(:doubles) do
      {
        "ExponentialNode" => node_rule_double,
        "UseCaseComplexity" => use_case_rule_double,
        "MultiplicativeGrowth" => marker_rule_double(:delta, note: "delta noise"),
        "ReviewSurface" => marker_rule_double(:pr, note: "pr noise")
      }
    end
    let(:vintage) do
      ReviewStubs::StubVintage.new(nodes: [
                                     ReviewStubs.stub_node(file: "app/x.rb", symbol: "X#y", branches: 64),
                                     ReviewStubs.stub_node(file: "app/api/e.rb", symbol: "E#GET[0]",
                                                           branches: 4, entrypoint: true,
                                                           entrypoint_kind: "grape")
                                   ])
    end

    it "lint = node + use_case ONLY — no :pr/:delta findings AND no N/A notes for them" do
      with_rules(doubles) do
        result = evaluate(vintage: vintage)
        expect(result.findings.map(&:rule).uniq.sort)
          .to eq(%w[ExponentialNode UseCaseComplexity])
        expect(result.not_evaluable).to be_empty
      end
    end

    it "diff = all four kinds" do
      with_rules(doubles) do
        result = evaluate(vintage: vintage, delta: ReviewStubs::StubDelta.new)
        expect(result.findings.map(&:rule).uniq.sort)
          .to eq(%w[ExponentialNode MultiplicativeGrowth ReviewSurface UseCaseComplexity])
      end
    end
  end

  describe "the Q8 zero-ep degenerate (V15-F4 dispatch carve-out)" do
    let(:zero_ep_vintage) { ReviewStubs::StubVintage.new(nodes: nodes(2, 3, 4)) }

    it "lint: every use_case rule notes the Q8 reason verbatim, zero findings fabricated" do
      with_rules("UseCaseComplexity" => use_case_rule_double,
                 "FirewallBreaches" => use_case_rule_double) do
        result = evaluate(vintage: zero_ep_vintage)
        expect(result.findings).to be_empty
        expect(result.not_evaluable).to contain_exactly(
          { rule: "FirewallBreaches", reason: Q8 },
          { rule: "UseCaseComplexity", reason: Q8 }
        )
      end
    end

    it "diff: FirewallBreaches STILL evaluates (orphan events fire); UCC/UCD/RS get Q8 notes" do
      fb = marker_rule_double(:use_case)
      with_rules("UseCaseComplexity" => use_case_rule_double,
                 "FirewallBreaches" => fb,
                 "ReviewSurface" => marker_rule_double(:pr)) do
        result = evaluate(vintage: zero_ep_vintage, delta: ReviewStubs::StubDelta.new)
        expect(result.findings.map(&:rule)).to eq(["FirewallBreaches"])
        expect(result.not_evaluable).to contain_exactly(
          { rule: "ReviewSurface", reason: Q8 },
          { rule: "UseCaseComplexity", reason: Q8 }
        )
      end
    end
  end

  describe "degenerates" do
    it "warns loudly on a 0-node vintage and suppresses the Q8 note (empty-vintage wins)" do
      with_rules("UseCaseComplexity" => use_case_rule_double) do
        result = nil
        expect do
          result = evaluate(vintage: ReviewStubs::StubVintage.new(nodes: []))
        end.to output(/warning: vintage contains 0 nodes/).to_stderr
        expect(result.findings).to be_empty
        expect(result.not_evaluable).to be_empty
        expect(result.vintage_empty?).to be(true)
        expect(result.exit_code(:error)).to eq(0)
      end
    end

    it "warns when the config excludes every node" do
      config = build_config(<<~YAML)
        version: 1
        all:
          exclude: ["app/**/*"]
      YAML
      with_rules("ExponentialNode" => node_rule_double) do
        result = nil
        expect do
          result = evaluate(vintage: ReviewStubs::StubVintage.new(nodes: nodes(64, 64, 64)),
                            config: config)
        end.to output(/warning: all 3 nodes excluded by config/).to_stderr
        expect(result.findings).to be_empty
      end
    end

    it "emits zero use_case findings on an empty diff U_metric (comment-only touch, Q2)" do
      ep_iterating = Class.new(Archbuddy::Review::Rules::Base) do
        kind :use_case
        define_method(:evaluate) do |ctx|
          ctx.delta.ep_entries.each do |entry|
            ctx.add_finding(severity: :warn, message: "moved", file: entry.file,
                            symbol: entry.ep_symbol)
          end
        end
      end
      vintage = ReviewStubs::StubVintage.new(
        nodes: [ReviewStubs.stub_node(file: "app/api/e.rb", symbol: "E#GET[0]", branches: 4,
                                      entrypoint: true, entrypoint_kind: "grape")]
      )
      with_rules("UseCaseComplexity" => ep_iterating) do
        result = evaluate(vintage: vintage,
                          delta: ReviewStubs::StubDelta.new(ep_entries: []))
        expect(result.findings).to be_empty
        expect(result.not_evaluable).to be_empty
      end
    end
  end

  describe "the R52 lazy-graph predicate" do
    it "never touches vintage.graph when only node rules run" do
      vintage = ReviewStubs::StubVintage.new(nodes: nodes(64)) # graph raises if touched
      config = build_config(<<~YAML)
        version: 1
        rules:
          UseCaseComplexity: { enabled: false }
          UseCaseDividend: { enabled: false }
          FirewallBreaches: { enabled: false }
          ReviewSurface: { enabled: false }
      YAML
      with_rules("ExponentialNode" => node_rule_double) do
        expect { evaluate(vintage: vintage, config: config) }.not_to raise_error
      end
    end
  end

  describe "todo bookkeeping" do
    it "notes entries for disabled rules once (not evaluated)" do
      config = build_config(<<~YAML)
        version: 1
        rules:
          UseCaseComplexity: { enabled: false }
      YAML
      todo = build_todo(<<~YAML)
        version: 1
        tool: "archbuddy 0.13.0"
        rule_count: 1
        node_count: 1
        rules:
          UseCaseComplexity:
            - node: "app/api/e.rb: E#GET[0]"
              values: { max_cone_node_millilog2: 6000 }
      YAML
      with_rules("UseCaseComplexity" => use_case_rule_double) do
        expect do
          result = evaluate(vintage: ReviewStubs::StubVintage.new(nodes: nodes(2)),
                            config: config, todo: todo)
          expect(result.findings).to be_empty
          expect(result.grandfathered).to be_empty
        end.to output(/note: 1 todo entries for disabled rules \(not evaluated\)/).to_stderr
      end
    end

    it "applies exclude_entrypoints to emission via the exact-string branch (F12)" do
      config = build_config(<<~YAML)
        version: 1
        rules:
          UseCaseComplexity:
            exclude_entrypoints: ["E#GET[0]"]
      YAML
      vintage = ReviewStubs::StubVintage.new(
        nodes: [ReviewStubs.stub_node(file: "app/api/e.rb", symbol: "E#GET[0]", branches: 64,
                                      entrypoint: true, entrypoint_kind: "grape")]
      )
      with_rules("UseCaseComplexity" => use_case_rule_double) do
        result = evaluate(vintage: vintage, config: config)
        expect(result.findings).to be_empty
      end
    end
  end
end
