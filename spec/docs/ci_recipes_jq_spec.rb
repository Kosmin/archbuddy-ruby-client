# frozen_string_literal: true

require "json"
require "open3"

# v0.15 P3-T9: the documented jq translations, executed FROM THE DOC — the
# spec parses every ```jq fenced block out of docs/CI_RECIPES.md (single
# source; snippets cannot drift from what is tested) and runs each against
# the fixture reports. Null-file (PR-scoped) findings degrade to the repo
# root; null-line findings degrade to line 1; empty reports yield valid
# empty documents.
RSpec.describe "CI_RECIPES.md jq translations" do
  RECIPES_DOC = File.expand_path("../../docs/CI_RECIPES.md", __dir__)
  SAMPLE_REPORT = File.expand_path("../fixtures/docs/sample-diff-report.json", __dir__)
  EMPTY_REPORT = File.expand_path("../fixtures/docs/sample-diff-report-empty.json", __dir__)

  CODECLIMATE_KEYS = %w[check_name description fingerprint location severity].freeze

  def jq_available?
    _out, _err, status = Open3.capture3("jq", "--version")
    status.success?
  rescue Errno::ENOENT
    false
  end

  def jq_blocks
    doc = File.read(RECIPES_DOC, encoding: "UTF-8")
    doc.scan(/```jq\n(.*?)```/m).map { |(block)| block }
  end

  def codeclimate_program
    jq_blocks.find { |b| b.include?("check_name") } or raise "CodeClimate jq block not found"
  end

  def sarif_program
    jq_blocks.find { |b| b.include?("sarif") } or raise "SARIF jq block not found"
  end

  def run_jq(program, fixture)
    out, err, status = Open3.capture3("jq", program, fixture)
    unless status.success?
      raise "jq failed (#{status.inspect}; cwd=#{Dir.pwd}): #{err} / #{out}"
    end

    JSON.parse(out.force_encoding("UTF-8"))
  end

  before do
    skip "jq not on PATH — documented-snippet execution skipped" unless jq_available?
  end

  it "extracts exactly two jq blocks from the doc" do
    expect(jq_blocks.size).to eq(2)
  end

  describe "the CodeClimate translation" do
    it "maps findings with exactly the 5 required keys + honest degrades" do
      rows = run_jq(codeclimate_program, SAMPLE_REPORT)
      expect(rows).to be_an(Array)
      expect(rows.size).to eq(3)
      rows.each do |row|
        expect(row.keys.sort).to eq(CODECLIMATE_KEYS)
        expect(%w[major minor info]).to include(row["severity"])
        expect(row["location"]["lines"]["begin"]).to eq(1) # line-free fragments
      end

      severities = rows.map { |row| row["severity"] }
      expect(severities).to contain_exactly("major", "minor", "info")

      null_file = rows.find { |row| row["check_name"] == "ReviewSurface" }
      expect(null_file["location"]["path"]).to eq(".") # PR-scoped degrade
    end

    it "emits [] for a findings-empty report" do
      expect(run_jq(codeclimate_program, EMPTY_REPORT)).to eq([])
    end
  end

  describe "the SARIF translation" do
    it "maps levels + null-file uri + startLine degrade" do
      doc = run_jq(sarif_program, SAMPLE_REPORT)
      expect(doc["version"]).to eq("2.1.0")
      expect(doc["runs"][0]["tool"]["driver"]["name"]).to eq("archbuddy")

      results = doc["runs"][0]["results"]
      expect(results.map { |r| r["level"] }).to contain_exactly("error", "warning", "note")
      results.each do |result|
        expect(result.dig("locations", 0, "physicalLocation", "region", "startLine")).to eq(1)
      end
      null_file = results.find { |r| r["ruleId"] == "ReviewSurface" }
      expect(null_file.dig("locations", 0, "physicalLocation",
                           "artifactLocation", "uri")).to eq(".")
    end

    it "emits zero results for a findings-empty report" do
      doc = run_jq(sarif_program, EMPTY_REPORT)
      expect(doc["runs"][0]["results"]).to eq([])
    end
  end

  describe "doc content pins" do
    it "carries the four vendor sections, both wiring modes, and the caution markers" do
      doc = File.read(RECIPES_DOC, encoding: "UTF-8")
      expect(doc).to include("## The contract (any CI)")
      expect(doc).to include("## GitHub Actions")
      expect(doc).to include("## GitLab CI")
      expect(doc).to include("## CircleCI")
      expect(doc).to include("## Committed-cache fast path")
      expect(doc).to include("ARCHITECTURE_AUDITOR_PATH") # dev-time wiring
      expect(doc).to include("git:") # distribution-time wiring
      expect(doc).to include("verify on first use") # the deepen-loop marker
      expect(doc).to include("UseCaseComplexity") # Q11 family in prose
      expect(doc).not_to match(/NoNew(Escapes|TollBooths)|Max(Branching|FunctionMass|OutDegree|Depth)\b/)
    end
  end
end
