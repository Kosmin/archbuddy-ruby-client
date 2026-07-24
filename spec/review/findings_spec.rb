# frozen_string_literal: true

require "digest"
require "archbuddy/review"
require "archbuddy/review/finding"
require "archbuddy/review/findings"

# v0.15 P1-T4: the Findings result object — counts, finding-OR-breach exit
# math ([S:C5]), grandfather summary, and the fingerprint pins (incl. the
# ReviewSurface nil→"" literal).
RSpec.describe Archbuddy::Review::Findings do
  Finding = Archbuddy::Review::Finding

  def finding(severity:, rule: "ExponentialNode", file: "app/x.rb", symbol: "X#y")
    Finding.new(rule: rule, severity: severity, message: "m", file: file, symbol: symbol)
  end

  def breach(severity:)
    described_class::RatchetEntry.new(
      scope: "app/**/*", kind: "paths", scope_paths: ["app/**/*"], budget_log2: 0.0,
      verdict: :breach, observed_log2: 3.0, empty_scope: false, severity: severity,
      message: "scope app/**/*: net +3.000 log2 exceeds budget +0.000"
    )
  end

  it "counts findings only" do
    result = described_class.new(findings: [finding(severity: :error),
                                            finding(severity: :warn),
                                            finding(severity: :warn)])
    expect(result.counts).to eq(error: 1, warn: 2, info: 0)
  end

  describe "#exit_code (finding-OR-breach)" do
    it "gates on findings at ≥ the fail level" do
      result = described_class.new(findings: [finding(severity: :error)])
      expect(result.exit_code(:error)).to eq(1)
      expect(result.exit_code(:none)).to eq(0)
    end

    it "never gates warn findings at :error" do
      result = described_class.new(findings: [finding(severity: :warn)])
      expect(result.exit_code(:error)).to eq(0)
      expect(result.exit_code(:warn)).to eq(1)
    end

    it "gates on a breach at its own severity" do
      result = described_class.new(ratchet: [breach(severity: :warn)])
      expect(result.exit_code(:error)).to eq(0)
      expect(result.exit_code(:warn)).to eq(1)
    end

    it "never gates no_match entries or grandfathered skips" do
      no_match = described_class::RatchetEntry.new(
        scope: "gone/**", kind: "paths", verdict: :no_match, empty_scope: true,
        severity: :error
      )
      skip = described_class::GrandfatherSkip.new(
        rule: "ExponentialNode", file: "a.rb", symbol: "A#x",
        recorded: 64, current: 64, healed: false
      )
      result = described_class.new(ratchet: [no_match], grandfathered: [skip])
      expect(result.exit_code(:info)).to eq(0)
    end

    it "never gates lint ratchet context entries (verdict nil)" do
      context_entry = described_class::RatchetEntry.new(
        scope: "app/**/*", kind: "paths", verdict: nil, current_total_log2: 12.0,
        matched_files: 3, empty_scope: false, severity: :error
      )
      result = described_class.new(ratchet: [context_entry])
      expect(result.exit_code(:info)).to eq(0)
    end
  end

  it "summarizes grandfathered entries (one node under two rules = 1 node)" do
    skips = [
      described_class::GrandfatherSkip.new(rule: "ExponentialNode", file: "a.rb",
                                           symbol: "A#x", recorded: 64, current: 64,
                                           healed: false),
      described_class::GrandfatherSkip.new(rule: "UseCaseComplexity", file: "a.rb",
                                           symbol: "A#x", recorded: 6000, current: nil,
                                           healed: true)
    ]
    result = described_class.new(grandfathered: skips)
    expect(result.grandfather_summary).to eq(entries: 2, nodes: 1, rules: 2, healed: 1)
  end

  describe "fingerprints" do
    it "hashes rule + file + symbol" do
      f = finding(severity: :error)
      expect(f.fingerprint).to eq(Digest::SHA256.hexdigest("ExponentialNode app/x.rb X#y"))
    end

    it "renders nil file/symbol as empty strings (the ReviewSurface pin)" do
      f = Finding.new(rule: "ReviewSurface", severity: :warn, message: "m",
                      file: nil, symbol: nil, scope: :pr)
      expect(f.fingerprint).to eq(Digest::SHA256.hexdigest("ReviewSurface  "))
    end
  end

  it "defaults review_surface to nil (I-P6' — set only by an evaluable ReviewSurface)" do
    expect(described_class.new.review_surface).to be_nil
  end
end
