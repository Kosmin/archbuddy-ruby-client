# frozen_string_literal: true

require "json"
require "tmpdir"
require "fileutils"
require_relative "../../script/backtest/tier0"

# v0.15 P3-T4: Tier 0 — fixture-corpus rollup cross-check incl. the null-T
# rule (nil must match an EMPTY csv cell; a fabricated 0.0 fails by
# construction).
RSpec.describe Backtest::Tier0 do
  let(:corpus_root) { File.expand_path("../fixtures/backtest_corpus", __dir__) }
  let(:corpus) { Backtest::Corpus.new(corpus_root) }

  it "recomputes T through the product read path (null-T PR included)" do
    ts = described_class.t_by_pr(corpus)
    expect(ts[%w[thanx/alpha 101]]).to eq(2.0)
    expect(ts[%w[thanx/beta 201]]).to be_nil # README-only PR: no scored files
  end

  it "matches every fixture row and emits the gate" do
    Dir.mktmpdir do |out|
      code = nil
      expect do
        code = described_class.run(corpus: corpus, opts: { out: out })
      end.to output("tier0: 3/3 matched\n").to_stdout
      expect(code).to eq(0)

      doc = JSON.parse(File.read(File.join(out, "tier0.json")))
      expect(doc["compared"]).to eq(3)
      expect(doc["matched"]).to eq(3)
      expect(doc["mismatches"]).to eq([])
      expect(doc["gates"]).to eq("t0_rollup_433" => true)
    end
  end

  it "fails loudly, listing every mismatch row" do
    Dir.mktmpdir do |sandbox|
      doctored = File.join(sandbox, "corpus")
      FileUtils.cp_r(corpus_root, doctored)
      predictors = File.join(doctored, "data/derived/pr_predictors.csv")
      File.write(predictors, File.read(predictors).sub(",2.0,edit,TRIPWIRE_NEVER_READ",
                                                       ",9.9,edit,TRIPWIRE_NEVER_READ"))

      Dir.mktmpdir do |out|
        code = nil
        expect do
          expect do
            code = described_class.run(corpus: Backtest::Corpus.new(doctored),
                                       opts: { out: out })
          end.to output("tier0: 2/3 matched\n").to_stdout
        end.to output(/error: tier0 mismatch thanx\/alpha#101: ours=2\.0 csv="9\.9"/).to_stderr
        expect(code).to eq(1)

        doc = JSON.parse(File.read(File.join(out, "tier0.json")))
        expect(doc["gates"]["t0_rollup_433"]).to be(false)
        expect(doc["mismatches"].size).to eq(1)
      end
    end
  end

  it "never matches a fabricated 0.0 against a null cell" do
    expect(described_class.match?(0.0, "")).to be(false)
    expect(described_class.match?(nil, "")).to be(true)
    expect(described_class.match?(nil, "2.0")).to be(false)
    expect(described_class.match?(2.004, "2.0")).to be(true)  # 2dp printing tolerance
    expect(described_class.match?(2.006, "2.0")).to be(false) # |Δ| > 0.005
  end
end
