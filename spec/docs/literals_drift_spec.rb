# frozen_string_literal: true

require "archbuddy"

# v0.15 P3-T12: the doc-contract freeze — every study literal in the committed
# docs equals the shipped constant (rendered ship-form via the SAME format
# strings Calibration::Lines uses), banned comparator spellings and banned
# vocabulary are absent, and the six retired rule names are CONFINED to
# docs/CONFIGURATION.md's Retired-rules region + the CHANGELOG.
#
# Degenerate law: a listed doc missing from disk is a FAILURE (a drift spec
# that silently skips absent docs guards nothing) — the file list is explicit,
# not a glob, for exactly this reason.
RSpec.describe "doc-contract freeze (literals drift)" do
  DRIFT_ROOT = File.expand_path("../..", __dir__)

  # The explicit matrix file list (no silent-skip globs).
  DRIFT_DOCS = %w[
    README.md
    CHANGELOG.md
    ARCHITECTURE.md
    docs/BACKTEST.md
    docs/RECALIBRATION.md
    docs/CONFIGURATION.md
  ].freeze

  def drift_read(rel)
    path = File.join(DRIFT_ROOT, rel)
    expect(File).to exist(path), "listed doc #{rel} missing from disk — the drift matrix guards nothing without it"
    File.read(path, encoding: "UTF-8")
  end

  def builtin = Archbuddy::Review::Calibration::BUILTIN

  # Rendered ship-forms — the SAME format strings calibration/lines.rb uses
  # (expectations derived FROM the constant, never hardcoded twice).
  def cost_ship = format("×%.1f", builtin["cost_per_line_ratio_q4_vs_q1"])          # ×2.5
  def bugfix_ship = format("×%.2f", builtin["bugfix_rate_ratio_q4_vs_q1"])          # ×3.19
  def median_q4_ship = format("%.1f", builtin["latency_arm_medians_hours"][0])      # 69.8
  def median_q1_ship = format("%.1f", builtin["latency_arm_medians_hours"][1])      # 21.9
  def provenance_tail = Archbuddy::Review::Calibration::PROVENANCE_BUILTIN.split(" — ").last

  describe "README.md" do
    subject(:readme) { drift_read("README.md") }

    it "carries the calibration ship-forms + the provenance tail" do
      [cost_ship, bugfix_ship, median_q4_ship, median_q1_ship, provenance_tail].each do |token|
        expect(readme).to include(token), "README.md lost the study literal #{token.inspect}"
      end
    end

    it "names all eight rules (derived from Config::Schema::RULES)" do
      Archbuddy::Config::Schema::RULES.each_key do |rule|
        expect(readme).to include(rule), "rule #{rule} missing from README.md"
      end
    end

    it "carries the disclosure + review-surface vocabulary" do
      expect(readme).to include("not reachable from any entrypoint")
      expect(readme).to include("re-verify")
    end
  end

  describe "docs/RECALIBRATION.md" do
    subject(:recal) { drift_read("docs/RECALIBRATION.md") }

    it "carries the exact derivation literals" do
      expect(recal).to include(builtin["cost_per_line_ratio_q4_vs_q1"].to_s) # 2.5485
      ["0.372231", "0.146058", "log(latency_hours+1)"].each do |token|
        expect(recal).to include(token), "RECALIBRATION.md lost #{token.inspect}"
      end
    end
  end

  describe "docs/BACKTEST.md" do
    subject(:backtest) { drift_read("docs/BACKTEST.md") }

    it "carries the adoption-table + worked-example literals" do
      ["+3.000", "+1.000", "8.8%", "4.8%", median_q4_ship, median_q1_ship, "IN-SAMPLE",
       "13.0", "16.0", "65536", "2^17",
       "repo-state inventory, not outcome calibration", "re-verify"].each do |token|
        expect(backtest).to include(token), "BACKTEST.md lost #{token.inspect}"
      end
    end
  end

  describe "docs/CONFIGURATION.md" do
    subject(:config_doc) { drift_read("docs/CONFIGURATION.md") }

    it "carries the percentile anchors + the honesty copy" do
      ["p90", "9.0", "not reachable from any entrypoint",
       "no measured cost line", "floors"].each do |token|
        expect(config_doc).to include(token), "CONFIGURATION.md lost #{token.inspect}"
      end
    end
  end

  describe "CHANGELOG.md" do
    subject(:changelog) { drift_read("CHANGELOG.md") }

    it "has [#{Archbuddy::VERSION}] as its NEWEST section header (version-drift guard)" do
      newest = changelog[/^## \[.*$/]
      expect(newest).not_to be_nil, "CHANGELOG.md has no '## [' section header"
      expect(newest).to include("[#{Archbuddy::VERSION}]"),
                        "newest CHANGELOG header #{newest.inspect} does not match Archbuddy::VERSION #{Archbuddy::VERSION}"
    end
  end

  describe "banned spellings (committed docs)" do
    BANNED_DOCS = (%w[README.md CHANGELOG.md ARCHITECTURE.md] +
                   Dir[File.join(DRIFT_ROOT, "docs", "*.md")].map { |p| p.sub("#{DRIFT_ROOT}/", "") }).freeze
    # The A1-outlawed comparator reading (the flagged set is described STRICTLY)
    # + the Q8-banned vocabulary ("not reachable from any entrypoint" is the copy).
    BANNED_LITERALS = ["≥ 2^5", ">= 2^5", "b_own ≥ 32", "b_own >= 32",
                       "orphan node", "orphan use case"].freeze

    it "keeps every banned literal out of every committed doc" do
      expect(BANNED_DOCS.size).to be >= 6 # the docs/ glob must not go empty
      BANNED_DOCS.each do |rel|
        text = drift_read(rel)
        BANNED_LITERALS.each do |literal|
          expect(text).not_to include(literal), "#{rel} contains the banned spelling #{literal.inspect}"
        end
      end
    end
  end

  describe "retired-name confinement (repo-wide)" do
    def retired_names = Archbuddy::Config::Schema::RETIRED_RULES.keys

    def retired_pattern = /\b(#{retired_names.join('|')})\b/

    # Scanned set: every committed markdown file EXCEPT CHANGELOG.md (the one
    # allowed CHANGELOG appearance is asserted below); for CONFIGURATION.md the
    # region between '## Retired rules' and the next '^## ' heading is
    # stripped before scanning.
    def scan_files
      files = (Dir[File.join(DRIFT_ROOT, "*.md")] +
               Dir[File.join(DRIFT_ROOT, "docs", "**", "*.md")]).sort
      files.reject { |p| File.basename(p) == "CHANGELOG.md" }
    end

    def configuration_regions(text)
      start = text.index("## Retired rules")
      return [text, ""] if start.nil?

      finish = text.index("\n## ", start + 1) || text.length
      [text[0...start] + text[finish..], text[start...finish]]
    end

    it "finds zero retired names outside the Retired-rules region + CHANGELOG" do
      files = scan_files
      expect(files.size).to be >= 6 # empty glob must not vacuously pass
      files.each do |path|
        text = File.read(path, encoding: "UTF-8")
        text, = configuration_regions(text) if path.end_with?("docs/CONFIGURATION.md")
        expect(text.scan(retired_pattern)).to be_empty,
                                              "#{path.sub("#{DRIFT_ROOT}/", '')} leaks a retired rule name"
      end
    end

    it "presence half: the Retired-rules region itself names all six (the allowance is not vacuous)" do
      _, region = configuration_regions(drift_read("docs/CONFIGURATION.md"))
      retired_names.each do |name|
        expect(region).to include(name), "retired name #{name} missing from the Retired-rules region"
      end
    end

    it "presence half (version-keyed): the [0.13.0] CHANGELOG section names all six" do
      # T12 runs BEFORE T13 writes the [0.13.0] section; the example must
      # never pass vacuously — pre-bump it SKIPS with a named reason and
      # bites at T13's post-bump full-suite re-run.
      skip "awaiting T13's consolidated [0.13.0] entry" unless Archbuddy::VERSION == "0.13.0"

      changelog = drift_read("CHANGELOG.md")
      start = changelog.index("## [0.13.0]")
      expect(start).not_to be_nil, "no [0.13.0] section despite VERSION == 0.13.0"
      finish = changelog.index("\n## ", start + 1) || changelog.length
      section = changelog[start...finish]
      retired_names.each do |name|
        expect(section).to include(name), "retired name #{name} missing from the [0.13.0] CHANGELOG section"
      end
    end
  end
end
