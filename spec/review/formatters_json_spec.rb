# frozen_string_literal: true

require "tmpdir"
require "json"
require "json-schema"
require "digest"
require "archbuddy"
require "archbuddy/review"
require_relative "../support/stub_vintage"

# v0.15 P2-T10: the archbuddy-diff-report/1 envelope — schema validation
# across six contexts, the #2083 canon rows, absent-vs-null posture
# (unreachable_from_entrypoints / review_surface — Q8), values-null on ep
# findings ([S:F11]), fingerprint canon, byte-determinism.
RSpec.describe Archbuddy::Review::Formatters::Json do
  JSON_FIXTURES = File.expand_path("../fixtures/review/vintages", __dir__)
  SCHEMA = File.expand_path("../fixtures/review/archbuddy-diff-report-1.schema.json", __dir__)

  Ctx = Archbuddy::Review::Formatter::ReviewContext

  def read(name)
    Archbuddy::Review::FragmentWalk.read(File.join(JSON_FIXTURES, name))
  end

  def build_config(yaml = nil)
    Dir.mktmpdir do |dir|
      File.write(File.join(dir, ".archbuddy.yml"), yaml) if yaml
      return Archbuddy::Config.load(target_root: dir, cli: {})
    end
  end

  def base_ctx(**overrides)
    Ctx.new(
      command: "diff", target: ".", config_path: nil, advisory: false,
      fail_level: :error,
      base: { ref: "main", sha: "a" * 40, vintage: "committed-cache", sources_count: 1 },
      head: { sha: "b" * 40, vintage: "working-tree-cache", dirty: false, sources_count: 2 },
      findings: [], grandfathered: [], not_evaluable: [], ratchet: [],
      excluded_files: [], calibration: { source: "none", provenance: nil, lines: [] },
      exit_code: 0, tool: { client: Archbuddy::VERSION, engine: nil, serializer: 5 },
      delta_summary: { counts: {}, net_log2: 0.0 }, delta_top: [],
      **overrides
    )
  end

  def twin_ctx(base_name, head_name, budget: nil)
    base = read(base_name)
    head = read(head_name)
    delta = Archbuddy::Review::Delta.new(base: base, head: head)
    yaml = budget && <<~YAML
      version: 1
      rules:
        ComplexityRatchet:
          budgets:
            - #{budget}
    YAML
    result = Archbuddy::Review::RuleEngine.evaluate(vintage: head, delta: delta,
                                                    config: build_config(yaml), todo: nil)
    index = delta.entries.to_h do |e|
      [[e.file, e.symbol], { base_branches: e.base_branches, head_branches: e.head_branches }]
    end
    top = delta.entries.sort_by { |e| [-e.delta_log2.abs, e.file, e.symbol] }.first(20).map do |e|
      { file: e.file, symbol: e.symbol, classification: e.classification,
        base_branches: e.base_branches, head_branches: e.head_branches,
        delta_log2: e.delta_log2 }
    end
    base_ctx(
      findings: result.findings, grandfathered: result.grandfathered,
      not_evaluable: result.not_evaluable, ratchet: result.ratchet,
      delta_summary: { counts: delta.counts, net_log2: delta.net_log2 },
      delta_top: top, delta_index: index,
      review_surface: result.review_surface, disclosures: delta.disclosures,
      exit_code: result.exit_code(:error)
    )
  end

  def render_doc(context)
    JSON.parse(described_class.new(context).render)
  end

  def validate!(doc)
    errors = JSON::Validator.fully_validate(SCHEMA, doc)
    expect(errors).to eq([])
  end

  def lint_ctx(rows:, count:, unreachable: nil)
    base_ctx(command: "lint", base: nil, delta_summary: nil, delta_top: nil,
             use_cases: { count: count, leaderboard: rows, unreachable: unreachable })
  end

  def leaderboard_row(rank)
    { "rank" => rank, "ep" => "Ep#{rank}#GET[0]", "kind" => "api",
      "file" => "app/api/ep#{rank}.rb", "branching_log2" => 30.0 - (rank * 0.1),
      "mass" => 5, "reach" => 2, "files" => 1, "depth" => 2, "dividend" => 2.0,
      "max_cone_node_log2" => 4.0, "cost_note" => nil }
  end

  it "schema-validates all six pinned contexts" do
    validate!(render_doc(twin_ctx("twin_2083_base", "twin_2083_head",
                                  budget: '{ paths: ["app/api/**/*"], max_increase_log2: 0.0 }')))
    validate!(render_doc(twin_ctx("twin_2146_base", "twin_2146_head")))
    validate!(render_doc(base_ctx)) # empty diff
    validate!(render_doc(lint_ctx(rows: (1..130).map { |i| leaderboard_row(i) }, count: 130,
                                  unreachable: { nodes: 83, share: 0.6748, files: 12 })))
    validate!(render_doc(lint_ctx(rows: [], count: 0))) # zero-ep lint
    # not-evaluable diff: edges-present base WITHOUT arity stamps — the
    # V15-F5 re-based fixture shape: UseCaseDividend, base-arity reason
    # (the retired NoNewTollBooths ghost never returns).
    na_base = ReviewStubs::StubVintage.new(nodes: [
      ReviewStubs.stub_node(file: "app/a.rb", symbol: "A#x", branches: 2, escapes: false)
    ], edges: true)
    head = read("twin_2083_head")
    delta = ReviewStubs::StubDelta.new(base: na_base, head: head, entries: [],
                                       ep_entries: [])
    result = Archbuddy::Review::RuleEngine.evaluate(vintage: head, delta: delta,
                                                    config: build_config, todo: nil)
    doc = render_doc(base_ctx(not_evaluable: result.not_evaluable,
                              findings: result.findings))
    validate!(doc)
    expect(doc["summary"]["not_evaluable"]).to include(
      "rule" => "UseCaseDividend",
      "reason" => "base vintage lacks 'outcome_arity' (pre-v4 fragments)"
    )
    expect(doc["summary"]["not_evaluable"].map { |n| n["rule"] })
      .not_to include("NoNewTollBooths")
  end

  describe "the #2083-twin canon rows" do
    let(:doc) do
      render_doc(twin_ctx("twin_2083_base", "twin_2083_head",
                          budget: '{ paths: ["app/api/**/*"], max_increase_log2: 0.0 }'))
    end

    it "renders review_surface / disclosures / components / contributors exactly" do
      expect(doc["review_surface"]["union"]).to eq(1)
      expect(doc["review_surface"]["sum"]).to eq(1)
      expect(doc["review_surface"]["unreachable_touched"]["nodes"][0]["symbol"])
        .to eq("Program::Redeem::Template#bonus_points?")
      expect(doc["summary"]["disclosures"]["orphan_touched_files"])
        .to eq(["app/models/program/redeem/template.rb"])

      ucc = doc["findings"].find { |f| f["rule"] == "UseCaseComplexity" }
      expect(ucc["components"]["max_cone_node_log2"]["breached"]).to be(true)
      expect(ucc["contributors"].length).to eq(1)
      expect(ucc["values"]).to be_nil
      expect(ucc["value_raw"]).to be_nil
      expect(ucc["entrypoint_kind"]).to eq("grape")
    end

    it "feeds values from the delta_index on NODE findings only + the canonical fingerprint" do
      en = doc["findings"].find { |f| f["rule"] == "ExponentialNode" }
      expect(en["values"]).to eq("base_branches" => 8192, "head_branches" => 65_536)
      expect(en["fingerprint"]).to eq(
        Digest::SHA256.hexdigest("ExponentialNode #{en['file']} #{en['symbol']}")
      )
      expect(doc["findings"][0]["rule"]).to eq("ExponentialNode") # sort determinism
      expect(en["line"]).to be_nil
    end

    it "renders twice byte-identically" do
      context = twin_ctx("twin_2083_base", "twin_2083_head",
                         budget: '{ paths: ["app/api/**/*"], max_increase_log2: 0.0 }')
      expect(described_class.new(context).render).to eq(described_class.new(context).render)
    end
  end

  it "renders the #2146 canon: 2 NEW, net +1.0, both delta_top identities, exit 0" do
    doc = render_doc(twin_ctx("twin_2146_base", "twin_2146_head"))
    expect(doc["summary"]["delta"]).to eq(
      "nodes_new" => 2, "nodes_grown" => 0, "nodes_shrunk" => 0, "nodes_removed" => 0,
      "net_log2_b_own" => 1.0
    )
    expect(doc["delta_top"].map { |r| r["delta_log2"] }).to contain_exactly(1.0, 0.0)
    expect(doc["exit_code"]).to eq(0)
  end

  describe "absent-vs-null posture (Q8)" do
    it "omits unreachable_from_entrypoints + leaderboard rows on a zero-ep lint" do
      doc = render_doc(lint_ctx(rows: [], count: 0))
      expect(doc["summary"]).not_to have_key("unreachable_from_entrypoints")
      expect(doc["use_cases"]).to eq("count" => 0, "leaderboard" => [])
    end

    it "keeps the 130-ep lint leaderboard UNCAPPED in JSON" do
      doc = render_doc(lint_ctx(rows: (1..130).map { |i| leaderboard_row(i) }, count: 130,
                                unreachable: { nodes: 83, share: 0.6748, files: 12 }))
      expect(doc["use_cases"]["leaderboard"].length).to eq(130)
      expect(doc["summary"]["unreachable_from_entrypoints"])
        .to eq("nodes" => 83, "share" => 0.6748, "files" => 12)
    end

    it "omits the review_surface key when nil (disabled / not evaluable) — never null" do
      doc = render_doc(base_ctx(review_surface: nil))
      expect(doc).not_to have_key("review_surface")
      lint_doc = render_doc(lint_ctx(rows: [], count: 0))
      expect(lint_doc).not_to have_key("review_surface")
      expect(lint_doc).not_to have_key("delta_top")
      expect(lint_doc).not_to have_key("ratchet")
    end

    it "keeps a union-0 review_surface block VALID (never dropped when evaluable)" do
      rs = { union: 0, sum: 0, eps: [], unreachable_touched: { count: 0, nodes: [] } }
      doc = render_doc(base_ctx(review_surface: rs))
      expect(doc["review_surface"]).to eq(
        "union" => 0, "sum" => 0, "eps" => [], "unreachable_touched" => { "count" => 0, "nodes" => [] }
      )
      validate!(doc)
    end
  end
end
