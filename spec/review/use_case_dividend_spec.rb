# frozen_string_literal: true

require "tmpdir"
require "archbuddy"
require "archbuddy/review"
require_relative "../support/stub_vintage"

# v0.15 P1-N2: UseCaseDividend — GTE gate over the PUBLISHED dividend
# (min_dividend 32 default; the ONE pinned strict-> deviation), cap-immune
# raw-log2 todo channel, arity honesty, published_cap rendering. The
# dividend-identity property gate lives in spec/review/dividend_identity_spec.rb
# (P2-N1 owns the file — §5-C27; its assertions are the shared contract).
RSpec.describe Archbuddy::Review::Rules::UseCaseDividend do
  RED_FILE = "app/api/api/v1/redeem_templates.rb"
  RED_EP = "Api::V1::RedeemTemplates#PATCH[0]"

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

  def ucd(result)
    result.findings.select { |f| f.rule == "UseCaseDividend" }
  end

  def dividend_metrics(dividend_log2, file: RED_FILE, symbol: RED_EP)
    dividend = 2.0**dividend_log2
    ReviewStubs.stub_ep_metrics(
      file: file, symbol: symbol,
      branching_log2: dividend_log2, own_branches: [dividend.round, 1].max,
      vty_log: dividend_log2 * Math.log(2), vty_floor_log: 0.0,
      dividend: dividend, dividend_log2: dividend_log2,
      entrypoint_kind: "api",
      top_dividend_nodes: [{ file: file, symbol: symbol,
                             branches: [dividend.round, 1].max, log2: dividend_log2 }],
      cone_size: 2
    )
  end

  def vintage_for(metrics, file: RED_FILE, symbol: RED_EP)
    ep = ReviewStubs.stub_node(file: file, symbol: symbol, branches: 65_536,
                               entrypoint: true, entrypoint_kind: "api",
                               escapes: false, outcome_arity: 2)
    ReviewStubs::StubVintage.new(
      nodes: [ep], edges: true,
      graph: ReviewStubs::StubGraph.new(ep_metrics: { [file, symbol] => metrics })
    )
  end

  it "fires the Q5 worked instance byte-for-byte (warn; C26 finding shape)" do
    findings = ucd(evaluate(vintage_for(dividend_metrics(16.0))))
    expect(findings.size).to eq(1)
    f = findings.first
    expect(f.severity).to eq(:warn)
    expect(f.message).to eq(
      "dividend ×65536: V_now 65536 (2^16.0) vs V_floor 1 (2^0.0) — " \
      "variety that exists only because decisions are inline"
    )
    expect(f.value_raw).to be_nil
    expect(f.value_log2).to eq(16.0)
    expect(f.threshold_raw).to eq(32)
    expect(f.components.keys)
      .to eq(%w[dividend dividend_log2 v_now_log2 v_floor_log2])
    expect(f.components["dividend"][:value]).to eq(65_536.0)
    expect(f.components["v_now_log2"][:value]).to be_within(1e-9).of(16.0)
    expect(f.components["v_floor_log2"][:value]).to eq(0.0)
    expect(f.contributors.first[:value_log2]).to eq(16.0)
  end

  it "gates GTE: dividend 32 FIRES, 31.9 does not (both boundary sides)" do
    at_32 = dividend_metrics(5.0) # 2^5 = 32 exactly
    expect(ucd(evaluate(vintage_for(at_32))).size).to eq(1)

    below = dividend_metrics(Math.log2(31.9))
    expect(ucd(evaluate(vintage_for(below)))).to be_empty
  end

  # 2026-07-27 adversarial review (M14): the boundary verdict must not be
  # composition-dependent. dividend_metrics builds 2.0**log2 (exact at the
  # 32 boundary), but the pinned formula (graph.rb variety_members, the
  # project_scorer.rb:664-672 mirror) does not round-trip: a V_now 64 /
  # V_floor 2 ep — mathematically ×32 — computes exp(ln 64 − ln 2) =
  # 31.999999999999986 (measured, ruby-3.4.2) and silently failed the raw
  # GTE gate while every display channel rendered ×32.
  it "fires at the COMPOSITION boundary: V_now 64 / V_floor 2 (raw exp() 1 ulp below ×32)" do
    gap = Math.log(64) - Math.log(2)
    raw = Math.exp(gap)
    expect(raw).to be < 32.0 # the hazard is real on this platform (M14)
    composed = ReviewStubs.stub_ep_metrics(
      file: RED_FILE, symbol: RED_EP,
      branching_log2: 6.0, own_branches: 64,
      vty_log: Math.log(64), vty_floor_log: Math.log(2),
      dividend: raw, dividend_log2: gap / Math.log(2),
      entrypoint_kind: "api",
      top_dividend_nodes: [{ file: RED_FILE, symbol: RED_EP,
                             branches: 64, log2: 6.0 }],
      cone_size: 1
    )
    findings = ucd(evaluate(vintage_for(composed)))
    expect(findings.size).to eq(1)
    expect(findings.first.components["dividend"][:value]).to eq(32.0)
  end

  it "stays quiet just below published rounding: raw dividend 31.999 (M14)" do
    below = dividend_metrics(Math.log2(31.999))
    expect(below.dividend.round(6)).to be < 32 # genuinely below, not fold noise
    expect(ucd(evaluate(vintage_for(below)))).to be_empty
  end

  it "never fires with min_dividend: null (gate disabled, leaderboard-only)" do
    config = build_config(<<~YAML)
      version: 1
      rules:
        UseCaseDividend:
          min_dividend: null
    YAML
    expect(ucd(evaluate(vintage_for(dividend_metrics(16.0)), config: config))).to be_empty
  end

  it "passes the #2146-shaped new eps (dividends 1.0 / 2.0)" do
    expect(ucd(evaluate(vintage_for(dividend_metrics(0.0))))).to be_empty
    expect(ucd(evaluate(vintage_for(dividend_metrics(1.0))))).to be_empty
  end

  it "applies the cap-immune todo channel: 13000 skips, 16000 re-fires byte-exact" do
    todo = build_todo(<<~YAML)
      version: 1
      tool: "archbuddy 0.12.0"
      rule_count: 1
      node_count: 1
      rules:
        UseCaseDividend:
          - node: "#{RED_FILE}: #{RED_EP}"
            values: { dividend_millilog2: 13000 }
    YAML

    at_baseline = evaluate(vintage_for(dividend_metrics(13.0)), todo: todo)
    expect(ucd(at_baseline)).to be_empty
    expect(at_baseline.grandfathered.map(&:rule)).to include("UseCaseDividend")

    grown = ucd(evaluate(vintage_for(dividend_metrics(16.0)), todo: todo)).first
    expect(grown.message)
      .to eq("dividend grew past grandfathered baseline ×8192 (2^13.0) → ×65536 (2^16.0)")
    expect(grown.grandfathered_baseline).to eq(13_000)
  end

  it "declares arity N/A honestly — never all-fallback garbage" do
    ep = ReviewStubs.stub_node(file: RED_FILE, symbol: RED_EP, branches: 65_536,
                               entrypoint: true, escapes: false) # no outcome_arity key
    result = evaluate(ReviewStubs::StubVintage.new(
                        nodes: [ep], edges: true,
                        graph: ReviewStubs::StubGraph.new(ep_metrics: {})
                      ))
    expect(result.not_evaluable).to include(
      rule: "UseCaseDividend",
      reason: "outcome_arity absent from fragments (pre-v4 serializer)"
    )
    expect(ucd(result)).to be_empty
  end

  it "skips a per-ep nil dividend silently (mixed vintage, identity-spec legal shape)" do
    na_metrics = ReviewStubs.stub_ep_metrics(file: RED_FILE, symbol: RED_EP,
                                             dividend: nil, dividend_log2: nil)
    result = evaluate(vintage_for(na_metrics))
    expect(ucd(result)).to be_empty
    expect(result.not_evaluable.map { |n| n[:rule] }).not_to include("UseCaseDividend")
  end

  it "renders the published cap while the raw log2 channel carries 20.0 (Q1 synthetic gate)" do
    capped = ReviewStubs.stub_ep_metrics(
      file: RED_FILE, symbol: RED_EP,
      vty_log: 20.0 * Math.log(2), vty_floor_log: 0.0,
      dividend: 1_000_000.0, dividend_log2: 20.0, own_branches: 1_048_576,
      top_dividend_nodes: [], cone_size: 1
    )
    f = ucd(evaluate(vintage_for(capped))).first
    expect(f.components["dividend"][:value]).to eq(1_000_000.0)
    expect(f.value_log2).to eq(20.0)
  end

  describe "diff mode (U_metric head-side)" do
    def entry(classification, head:, base: nil)
      Archbuddy::Review::Delta::EpDelta::Entry.new(
        file: RED_FILE, ep_symbol: RED_EP, classification: classification,
        base: base, head: head, delta: nil, contributors: [], contributors_omitted: 0
      )
    end

    it "fires on a :matched mover's head side; silent on an empty U_metric" do
      head_vintage = vintage_for(dividend_metrics(16.0))
      base_vintage = vintage_for(dividend_metrics(13.0))
      delta = ReviewStubs::StubDelta.new(
        base: base_vintage, head: head_vintage,
        ep_entries: [entry(:matched, head: dividend_metrics(16.0),
                           base: dividend_metrics(13.0))]
      )
      expect(ucd(evaluate(head_vintage, delta: delta)).size).to eq(1)

      quiet = ReviewStubs::StubDelta.new(base: base_vintage, head: head_vintage,
                                         ep_entries: [])
      expect(ucd(evaluate(head_vintage, delta: quiet))).to be_empty
    end
  end

  it "never reads presenter cost inputs (A4 grep gate)" do
    source = File.read(File.expand_path(
                         "../../lib/archbuddy/review/rules/use_case_dividend.rb", __dir__
                       ), encoding: "UTF-8")
    expect(source).not_to match(/calibration/i)
  end
end
