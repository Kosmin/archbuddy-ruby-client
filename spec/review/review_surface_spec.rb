# frozen_string_literal: true

require "tmpdir"
require "digest"
require "archbuddy"
require "archbuddy/review"
require_relative "../support/stub_vintage"

# v0.15 P1-N4: ReviewSurface — the :pr rule. Block always (enabled +
# evaluable), finding only under the opt-in max_use_cases gate (strict >),
# Q3/Q5 canon shapes, the comment-only honest zero, zero-ep Q8, side-
# specific edges evaluability, the nil→"" fingerprint pin.
RSpec.describe Archbuddy::Review::Rules::ReviewSurface do
  RS_2083 = {
    union: 1, sum: 1,
    eps: [{ file: "app/api/api/v1/redeem_templates.rb",
            ep_symbol: "Api::V1::RedeemTemplates#PATCH[0]",
            branching_log2: 16.0, classification: :matched }],
    unreachable_touched: {
      count: 1,
      nodes: [{ file: "app/models/program/redeem/template.rb",
                symbol: "Program::Redeem::Template#bonus_points?" }]
    }
  }.freeze

  RS_2146 = {
    union: 2, sum: 2,
    eps: [
      { file: "app/api/api/v1/segment_activation_preferences.rb",
        ep_symbol: "Api::V1::SegmentActivationPreferences#PATCH[0]",
        branching_log2: 1.0, classification: :new },
      { file: "app/api/api/v1/segment_activation_preferences.rb",
        ep_symbol: "Api::V1::SegmentActivationPreferences#GET[0]",
        branching_log2: 0.0, classification: :new }
    ],
    unreachable_touched: { count: 0, nodes: [] }
  }.freeze

  def build_config(yaml = nil)
    Dir.mktmpdir do |dir|
      File.write(File.join(dir, ".archbuddy.yml"), yaml) if yaml
      return Archbuddy::Config.load(target_root: dir, cli: {})
    end
  end

  def head_vintage
    ep = ReviewStubs.stub_node(file: "app/api/a.rb", symbol: "A#GET[0]", branches: 2,
                               entrypoint: true, escapes: false, outcome_arity: 2)
    ReviewStubs::StubVintage.new(nodes: [ep], edges: true)
  end

  def evaluate(review_surface:, config: build_config, head: head_vintage)
    base = ReviewStubs::StubVintage.new(nodes: head.nodes, edges: true)
    delta = ReviewStubs::StubDelta.new(base: base, head: head,
                                       review_surface: review_surface)
    Archbuddy::Review::RuleEngine.evaluate(vintage: head, delta: delta,
                                           config: config, todo: nil)
  end

  def rs(result)
    result.findings.select { |f| f.rule == "ReviewSurface" }
  end

  it "produces the block with NO finding at the disclosure-only default (#2083 shape)" do
    result = evaluate(review_surface: RS_2083)
    expect(result.review_surface).to eq(RS_2083)
    expect(result.review_surface[:unreachable_touched][:count]).to eq(1)
    expect(rs(result)).to be_empty
  end

  it "fires at max_use_cases: 0 with the ∪=1 message" do
    config = build_config(<<~YAML)
      version: 1
      rules:
        ReviewSurface:
          max_use_cases: 0
    YAML
    findings = rs(evaluate(review_surface: RS_2083, config: config))
    expect(findings.size).to eq(1)
    f = findings.first
    expect(f.severity).to eq(:warn)
    expect(f.message).to eq(
      "this PR touches 1 use case(s) (limit 0); worst: Api::V1::RedeemTemplates#PATCH[0]"
    )
    expect(f.scope).to eq(:pr)
    expect(f.file).to be_nil
    expect(f.symbol).to be_nil
    expect(f.fingerprint).to eq(Digest::SHA256.hexdigest("ReviewSurface  "))
  end

  it "renders the #2146 worked instance byte-exact at limit 1; strict > at limit 2" do
    at_one = build_config(<<~YAML)
      version: 1
      rules:
        ReviewSurface:
          max_use_cases: 1
    YAML
    f = rs(evaluate(review_surface: RS_2146, config: at_one)).first
    expect(f.message).to eq(
      "this PR touches 2 use case(s) (limit 1); worst: " \
      "Api::V1::SegmentActivationPreferences#PATCH[0], " \
      "Api::V1::SegmentActivationPreferences#GET[0]"
    )

    at_two = build_config(<<~YAML)
      version: 1
      rules:
        ReviewSurface:
          max_use_cases: 2
    YAML
    expect(rs(evaluate(review_surface: RS_2146, config: at_two))).to be_empty
  end

  it "kills block AND finding under enabled: false" do
    config = build_config(<<~YAML)
      version: 1
      rules:
        ReviewSurface:
          enabled: false
          max_use_cases: 0
    YAML
    result = evaluate(review_surface: RS_2083, config: config)
    expect(result.review_surface).to be_nil
    expect(rs(result)).to be_empty
  end

  it "renders the honest zero on a comment-only PR — 0 ≯ 0, nothing to re-verify" do
    config = build_config(<<~YAML)
      version: 1
      rules:
        ReviewSurface:
          max_use_cases: 0
    YAML
    quiet = { union: 0, sum: 0, eps: [], unreachable_touched: { count: 0, nodes: [] } }
    result = evaluate(review_surface: quiet, config: config)
    expect(result.review_surface).to eq(quiet)
    expect(rs(result)).to be_empty
  end

  it "Q8-gates a zero-ep head: not_evaluable, block nil — never a safety claim" do
    lonely = ReviewStubs.stub_node(file: "lib/quiet.rb", symbol: "Quiet#helper",
                                   branches: 2, escapes: false, outcome_arity: 2)
    zero_ep = ReviewStubs::StubVintage.new(nodes: [lonely], edges: true)
    result = evaluate(review_surface: RS_2083, head: zero_ep)
    expect(result.review_surface).to be_nil
    expect(result.not_evaluable).to include(
      rule: "ReviewSurface",
      reason: "vintage has no entrypoints (nothing is reachable — " \
              "check collector entrypoint detection)"
    )
  end

  it "declares the side-specific reason and nils the block when edges are missing" do
    head = head_vintage
    base = ReviewStubs::StubVintage.new(nodes: head.nodes, edges: false)
    delta = ReviewStubs::StubDelta.new(base: base, head: head, review_surface: RS_2083)
    result = Archbuddy::Review::RuleEngine.evaluate(vintage: head, delta: delta,
                                                    config: build_config, todo: nil)
    expect(result.not_evaluable).to include(
      rule: "ReviewSurface", reason: "base vintage carries no edges"
    )
    expect(result.review_surface).to be_nil
  end

  it "never reads presenter cost inputs (A4 grep gate)" do
    source = File.read(File.expand_path(
                         "../../lib/archbuddy/review/rules/review_surface.rb", __dir__
                       ), encoding: "UTF-8")
    expect(source).not_to match(/calibration/i)
  end
end
