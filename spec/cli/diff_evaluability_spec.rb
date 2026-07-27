# frozen_string_literal: true

require "tmpdir"
require "json"
require "stringio"
require "fileutils"
require "json-schema"
require "archbuddy/cli"

# v0.15 P2-T13(e): the CLI-level 7-family evaluability battery
# ([S:R25] filename) — cross-vintage honesty through `archbuddy diff`.
# The NoNewTollBooths rows are struck (rule retired, Q11); the escape rows
# live on FirewallBreaches; UseCaseDividend adds the arity reason. Nothing
# is ever fabricated (P8's honest-N/A observable).
RSpec.describe "diff evaluability cross-vintage (7-family)" do
  FIXTURES_EV = File.expand_path("../fixtures/review/vintages", __dir__)
  SCHEMA_EV = File.expand_path("../fixtures/review/archbuddy-diff-report-1.schema.json", __dir__)

  def fixture(name) = File.join(FIXTURES_EV, name)

  def run_diff(**kwargs)
    out = StringIO.new
    err = StringIO.new
    orig_out = $stdout
    orig_err = $stderr
    $stdout = out
    $stderr = err
    code = nil
    begin
      Archbuddy::CLI::Diff.new.call(**kwargs)
    rescue SystemExit => e
      code = e.status
    ensure
      $stdout = orig_out
      $stderr = orig_err
    end
    [code, out.string, err.string]
  end

  def run_json(target:, base_cache:)
    code, stdout, = run_diff(target: target, base_cache: base_cache,
                             trust_cache: true, format: "json")
    expect(code).to eq(0) # advisory throughout — honesty never gates
    doc = JSON.parse(stdout)
    expect(JSON::Validator.fully_validate(SCHEMA_EV, doc)).to eq([]) # schema-valid
    doc
  end

  def na_rows(doc)
    doc["summary"]["not_evaluable"]
  end

  # A pre-v4 vintage: edges PRESENT, escapes/outcome_arity stamps ABSENT
  # (the committed v1_small has no edges at all, so its edge gate fires
  # FIRST — the Wave-4 battery pinned that order; these are the arity/escape
  # reason rows the [D2] battery needs).
  def write_pre_v4(dir)
    FileUtils.mkdir_p(File.join(dir, ".archbuddy/app/api"))
    File.write(File.join(dir, ".archbuddy/app/api/old.rb.json"), JSON.generate(
                                                                   "serializer_version" => 3, "file" => "app/api/old.rb",
                                                                   "nodes" => [
                                                                     { "symbol" => "Api::Old#GET[0]", "kind" => "function", "class" => "Api::Old",
                                                                       "branches" => 4, "decisions" => 2, "entrypoint" => true,
                                                                       "entrypoint_kind" => "grape" },
                                                                     { "symbol" => "Api::Old#helper", "kind" => "function", "class" => "Api::Old",
                                                                       "branches" => 2, "decisions" => 1, "entrypoint" => false }
                                                                   ],
                                                                   "edges" => [
                                                                     { "from" => "Api::Old#GET[0]", "to" => "Api::Old#helper", "calls" => 1 },
                                                                     { "from" => "Api::Old#helper", "to" => "Ext.sink", "calls" => 1 }
                                                                   ]
                                                                 ))
    File.write(File.join(dir, "archbuddy-findings.json"), JSON.generate(
                                                            "serializer_version" => 5,
                                                            "sources" => { "app/api/old.rb" => {
                                                              "path" => ".archbuddy/app/api/old.rb.json", "shard_mode" => "single"
                                                            } }
                                                          ))
    dir
  end

  it "v4 base × v5 head: no pre-v4 reasons anywhere — FB/UCD evaluable" do
    doc = run_json(target: fixture("v5_small"), base_cache: fixture("v4_small"))
    reasons = na_rows(doc).map { |row| row["reason"] }
    expect(reasons.grep(/escapes|outcome_arity|pre-v4/)).to eq([])
    rules = na_rows(doc).map { |row| row["rule"] }
    expect(rules).not_to include("FirewallBreaches")
    expect(rules).not_to include("UseCaseDividend")
  end

  it "pre-v4 base (edges, no stamps) × v5 head: FB escapes reason + UCD arity reason" do
    Dir.mktmpdir do |dir|
      base = write_pre_v4(File.join(dir, "base").tap { |d| FileUtils.mkdir_p(d) })
      doc = run_json(target: fixture("v5_small"), base_cache: base)
      expect(na_rows(doc)).to include(
        "rule" => "FirewallBreaches",
        "reason" => "base vintage lacks 'escapes' (pre-v4 fragments)"
      )
      expect(na_rows(doc)).to include(
        "rule" => "UseCaseDividend",
        "reason" => "base vintage lacks 'outcome_arity' (pre-v4 fragments)"
      )
    end
  end

  it "v1 base (no edges at all): the edges gate fires FIRST, side-specific" do
    doc = run_json(target: fixture("v5_small"), base_cache: fixture("v1_small"))
    %w[UseCaseComplexity ReviewSurface UseCaseDividend FirewallBreaches].each do |rule|
      expect(na_rows(doc)).to include(
        "rule" => rule, "reason" => "base vintage carries no edges"
      )
    end
  end

  it "edges-free HEAD: UCC/RS declare the head-side reason" do
    doc = run_json(target: fixture("v1_small"), base_cache: fixture("v5_small"))
    %w[UseCaseComplexity ReviewSurface].each do |rule|
      expect(na_rows(doc)).to include(
        "rule" => rule, "reason" => "head vintage carries no edges"
      )
    end
    expect(doc).not_to have_key("review_surface") # not evaluable ⇒ key absent
  end

  it "branching rules + ratchet stay evaluable throughout; nothing fabricated" do
    [
      run_json(target: fixture("v5_small"), base_cache: fixture("v1_small")),
      run_json(target: fixture("v1_small"), base_cache: fixture("v5_small")),
      run_json(target: fixture("v5_small"), base_cache: fixture("v4_small"))
    ].each do |doc|
      na_rules = na_rows(doc).map { |row| row["rule"] }
      expect(na_rules).not_to include("ExponentialNode")
      expect(na_rules).not_to include("MultiplicativeGrowth")
      expect(na_rules).not_to include("ComplexityRatchet")
      expect(na_rules).not_to include("NoNewTollBooths") # the ghost never returns
      # fabrication guard: no finding from a not-evaluable rule
      expect(doc["findings"].map { |f| f["rule"] } & na_rules).to eq([])
    end
  end
end
