# frozen_string_literal: true

require "tmpdir"
require "set"
require "archbuddy"
require "archbuddy/review"
require_relative "../support/stub_vintage"

# v0.15 P1-N1: UseCaseComplexity — per-ep components (5 Σ-components + the
# set-by-default Q4-node trigger, strict >), ONE finding per ep (L8),
# contributors, exclude_entrypoints emission gating (anti-gaming), U_metric
# diff mode (head-side; :removed never level-checked), Q5 canon literals.
RSpec.describe Archbuddy::Review::Rules::UseCaseComplexity do
  REDEEM_FILE = "app/api/api/v1/redeem_templates.rb"
  REDEEM_EP = "Api::V1::RedeemTemplates#PATCH[0]"

  def build_config(yaml = nil)
    Dir.mktmpdir do |dir|
      File.write(File.join(dir, ".archbuddy.yml"), yaml) if yaml
      return Archbuddy::Config.load(target_root: dir, cli: {})
    end
  end

  def evaluate(vintage, config: build_config, delta: nil)
    Archbuddy::Review::RuleEngine.evaluate(vintage: vintage, delta: delta,
                                           config: config, todo: nil)
  end

  def ucc(result)
    result.findings.select { |f| f.rule == "UseCaseComplexity" }
  end

  def redeem_metrics(**overrides)
    ReviewStubs.stub_ep_metrics(
      file: REDEEM_FILE, symbol: REDEEM_EP,
      branching_log2: 16.0, mass: 83, reach: 2, files: 1, depth: 2,
      own_branches: 65_536,
      max_cone_node: { file: REDEEM_FILE, symbol: REDEEM_EP, branches: 65_536, log2: 16.0 },
      vty_log: Math.log(65_536), vty_floor_log: 0.0,
      dividend: 65_536.0, dividend_log2: 16.0,
      entrypoint_kind: "api",
      top_nodes: [{ file: REDEEM_FILE, symbol: REDEEM_EP, branches: 65_536, log2: 16.0 }],
      cone_size: 2, **overrides
    )
  end

  def vintage_for(metrics, file: REDEEM_FILE, symbol: REDEEM_EP)
    ep = ReviewStubs.stub_node(file: file, symbol: symbol, branches: 65_536,
                               entrypoint: true, entrypoint_kind: "api",
                               escapes: false, outcome_arity: 2)
    ReviewStubs::StubVintage.new(
      nodes: [ep], edges: true,
      graph: ReviewStubs::StubGraph.new(ep_metrics: { [file, symbol] => metrics })
    )
  end

  it "fires the Q5 worked instance byte-for-byte (ONE warn finding per ep)" do
    findings = ucc(evaluate(vintage_for(redeem_metrics)))
    expect(findings.size).to eq(1)
    f = findings.first
    expect(f.severity).to eq(:warn)
    expect(f.message).to eq(
      "use case spans 65536 (2^16.0) total branching over 2 node(s) / 1 file(s) " \
      "(mass 83, depth 2) — worst cone node 65536 (2^16.0) exceeds 2^5 (Q4 boundary)"
    )
    expect(f.file).to eq(REDEEM_FILE)
    expect(f.symbol).to eq(REDEEM_EP)
    expect(f.value_raw).to be_nil
    expect(f.value_log2).to be_nil
    expect(f.entrypoint_kind).to eq("api")
    expect(f.contributors).to eq([{ file: REDEEM_FILE, symbol: REDEEM_EP,
                                    value_raw: 65_536, value_log2: 16.0,
                                    delta_log2: nil, coupling_flip: false }])
    expect(f.contributors_omitted).to eq(1)
    expect(f.components["max_cone_node_log2"][:breached]).to be(true)
    expect(f.components["own_branching_log2"][:threshold]).to be_nil
  end

  it "gates the Q4 trigger STRICTLY: cone-node log2 5.0 passes, 5.044 fires" do
    at_boundary = redeem_metrics(
      branching_log2: 5.0, own_branches: 32,
      max_cone_node: { file: REDEEM_FILE, symbol: REDEEM_EP, branches: 32, log2: 5.0 }
    )
    expect(ucc(evaluate(vintage_for(at_boundary)))).to be_empty

    just_past = redeem_metrics(
      branching_log2: Math.log2(33), own_branches: 33,
      max_cone_node: { file: REDEEM_FILE, symbol: REDEEM_EP, branches: 33,
                       log2: Math.log2(33) }
    )
    expect(ucc(evaluate(vintage_for(just_past))).size).to eq(1)
  end

  # 2026-07-27 adversarial review (M14): Σ-log2 folds carry 1-ulp noise (the
  # probe measured 4.9999999999999991 for a mathematical 5.0), so user
  # thresholds gate at published precision — raw fold noise around the
  # boundary must never flip a strict-> verdict in either direction.
  it "gates Σ-log2 at published rounding: 1-ulp fold noise never flips a user threshold (M14)" do
    config = build_config(<<~YAML)
      version: 1
      rules:
        UseCaseComplexity:
          max_branching_log2: 5
    YAML
    quiet_node = { file: REDEEM_FILE, symbol: REDEEM_EP, branches: 32, log2: 5.0 }

    # mathematical Σ-log2 of exactly 5.0, measured 1 ulp HIGH through the
    # fold — pre-M14 this spuriously breached strict >
    noisy = redeem_metrics(branching_log2: 5.0.next_float, own_branches: 32,
                           max_cone_node: quiet_node)
    expect(ucc(evaluate(vintage_for(noisy), config: config))).to be_empty

    # one published-precision step above the threshold still fires
    past = redeem_metrics(branching_log2: 5.000001, own_branches: 32,
                          max_cone_node: quiet_node)
    findings = ucc(evaluate(vintage_for(past), config: config))
    expect(findings.size).to eq(1)
    expect(findings.first.components["branching_log2"][:breached]).to be(true)
  end

  it "aggregates multiple breaching components into ONE finding (L8)" do
    config = build_config(<<~YAML)
      version: 1
      rules:
        UseCaseComplexity:
          max_reach: 120
    YAML
    metrics = redeem_metrics(reach: 142, cone_size: 142)
    findings = ucc(evaluate(vintage_for(metrics), config: config))

    expect(findings.size).to eq(1)
    f = findings.first
    expect(f.message).to include("reach 142 nodes exceeds 120; ")
    expect(f.message).to include("worst cone node 65536 (2^16.0) exceeds 2^5 (Q4 boundary)")
    breached = f.components.select { |_k, c| c[:breached] }.keys
    expect(breached).to contain_exactly("reach", "max_cone_node_log2")
  end

  it "emits nothing when ALL thresholds are null (valid config)" do
    config = build_config(<<~YAML)
      version: 1
      rules:
        UseCaseComplexity:
          max_cone_node_log2: null
    YAML
    expect(ucc(evaluate(vintage_for(redeem_metrics), config: config))).to be_empty
  end

  it "applies exclude_entrypoints via the exact-string branch — emission ONLY (anti-gaming)" do
    config = build_config(<<~YAML)
      version: 1
      rules:
        UseCaseComplexity:
          exclude_entrypoints: ["Api::V1::RedeemTemplates#PATCH[0]"]
    YAML
    vintage = vintage_for(redeem_metrics)
    expect(ucc(evaluate(vintage, config: config))).to be_empty
    # the graph input is untouched by the exclude — cone data still there
    expect(vintage.graph.ep_metrics).to have_key([REDEEM_FILE, REDEEM_EP])
  end

  it "keeps the fingerprint stable across component-set changes" do
    q4_only = ucc(evaluate(vintage_for(redeem_metrics))).first
    reach_config = build_config(<<~YAML)
      version: 1
      rules:
        UseCaseComplexity:
          max_cone_node_log2: null
          max_reach: 1
    YAML
    reach_only = ucc(evaluate(vintage_for(redeem_metrics(reach: 142)),
                              config: reach_config)).first
    expect(reach_only.fingerprint).to eq(q4_only.fingerprint)
  end

  it "passes an ep whose cone is only itself (reach 1, mass 0 — evaluates, no N/A)" do
    lonely = ReviewStubs.stub_ep_metrics(
      file: "app/api/tiny.rb", symbol: "Tiny#GET[0]",
      branching_log2: 1.0, mass: 0, reach: 1, files: 1, depth: 1, own_branches: 2,
      cone_size: 1
    )
    result = evaluate(vintage_for(lonely, file: "app/api/tiny.rb", symbol: "Tiny#GET[0]"))
    expect(ucc(result)).to be_empty
    expect(result.not_evaluable.map { |n| n[:rule] }).not_to include("UseCaseComplexity")
  end

  describe "evaluability" do
    it "lint without edges → `fragments carry no edges`, zero findings" do
      ep = ReviewStubs.stub_node(file: "app/a.rb", symbol: "A#GET[0]", branches: 65_536,
                                 entrypoint: true)
      result = evaluate(ReviewStubs::StubVintage.new(nodes: [ep], edges: false))
      expect(result.not_evaluable).to include(
        rule: "UseCaseComplexity", reason: "fragments carry no edges"
      )
      expect(ucc(result)).to be_empty
    end

    it "diff with an edge-less base → the side-specific reason" do
      head = vintage_for(redeem_metrics)
      base = ReviewStubs::StubVintage.new(nodes: [], edges: false)
      delta = ReviewStubs::StubDelta.new(base: base, head: head, ep_entries: [])
      result = evaluate(head, delta: delta)
      expect(result.not_evaluable).to include(
        rule: "UseCaseComplexity", reason: "base vintage carries no edges"
      )
    end
  end

  describe "diff mode (U_metric, head-side levels — Q2)" do
    def entry(classification, head:, base: nil)
      Archbuddy::Review::Delta::EpDelta::Entry.new(
        file: REDEEM_FILE, ep_symbol: REDEEM_EP, classification: classification,
        base: base, head: head,
        delta: { branching_log2: 3.0, mass: 10, reach: 0, files: 0, depth: 0,
                 dividend_log2: 3.0 },
        contributors: [{ file: REDEEM_FILE, symbol: REDEEM_EP, value_raw: 65_536,
                         value_log2: 16.0, delta_log2: 3.0, coupling_flip: false }],
        contributors_omitted: 0
      )
    end

    it "level-checks the HEAD side of a :matched mover" do
      head_vintage = vintage_for(redeem_metrics)
      delta = ReviewStubs::StubDelta.new(
        base: vintage_for(redeem_metrics(branching_log2: 13.0)), head: head_vintage,
        ep_entries: [entry(:matched, head: redeem_metrics,
                           base: redeem_metrics(branching_log2: 13.0))]
      )
      findings = ucc(evaluate(head_vintage, delta: delta))
      expect(findings.size).to eq(1)
      expect(findings.first.message).to include("worst cone node 65536 (2^16.0)")
      expect(findings.first.contributors.first[:delta_log2]).to eq(3.0)
    end

    it "stays silent on an empty U_metric (comment-only PR)" do
      head_vintage = vintage_for(redeem_metrics)
      delta = ReviewStubs::StubDelta.new(base: vintage_for(redeem_metrics),
                                         head: head_vintage, ep_entries: [])
      expect(ucc(evaluate(head_vintage, delta: delta))).to be_empty
    end

    it "NEVER level-checks a :removed ep" do
      head_vintage = vintage_for(redeem_metrics)
      delta = ReviewStubs::StubDelta.new(
        base: vintage_for(redeem_metrics), head: head_vintage,
        ep_entries: [entry(:removed, head: nil, base: redeem_metrics)]
      )
      expect(ucc(evaluate(head_vintage, delta: delta))).to be_empty
    end
  end

  it "never reads presenter cost inputs (A4 grep gate)" do
    source = File.read(File.expand_path(
                         "../../lib/archbuddy/review/rules/use_case_complexity.rb", __dir__
                       ), encoding: "UTF-8")
    expect(source).not_to match(/calibration/i)
  end
end
