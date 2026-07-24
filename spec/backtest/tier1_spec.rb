# frozen_string_literal: true

require "json"
require "tmpdir"
require "fileutils"
require_relative "../../script/backtest/tier1"

# v0.15 P3-T4: Tier 1 — flag split (STRICT > 5.0), the byte-exact in-sample
# disclosure, and the Q5 inventory sub-step (12-key leaderboard rows R39,
# zero-ep degenerate, synthetic canon-mismatch → exit 2).
RSpec.describe Backtest::Tier1 do
  let(:corpus_root) { File.expand_path("../fixtures/backtest_corpus", __dir__) }
  let(:corpus) { Backtest::Corpus.new(corpus_root) }

  EP_SNAPSHOT = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
  ZERO_EP_SNAPSHOT = "cccccccccccccccccccccccccccccccccccccccc"

  describe "the flag split" do
    it "flags STRICTLY above 5.0 and never flags nil T" do
      ts = { %w[r 1] => 5.0, %w[r 2] => 5.1, %w[r 3] => nil, %w[r 4] => 2.0 }
      expect(described_class.flagged_keys(ts)).to eq([%w[r 2]])
    end
  end

  describe "the median" do
    it "averages the middle pair on even counts" do
      expect(described_class.median([4.0, 1.0, 3.0, 2.0])).to eq(2.5)
      expect(described_class.median([3.0, 1.0, 2.0])).to eq(2.0)
      expect(described_class.median([])).to be_nil
    end
  end

  describe "the markdown block" do
    it "carries the pinned disclosure verbatim" do
      block = described_class.markdown_block(flagged: 21, all_count: 433, edit_count: 239,
                                             flagged_median: 69.8075, q1_median: 21.8639)
      expect(block).to include(described_class::DISCLOSURE)
      expect(block).to include("21/239 edit PRs = 8.8%")
      expect(block).to include("21/433 all PRs = 4.8%")
    end
  end

  describe "the inventory sub-step" do
    it "emits 12-key leaderboard rows (R39) through the product ep fold" do
      canon = [{ sha: EP_SNAPSHOT, ep_count: 1 }]
      rows, mismatches = described_class.inventory(corpus, canon: canon)

      expect(mismatches).to eq([])
      expect(rows.size).to eq(1)
      row = rows.first
      expect(row["eps"]).to eq(1)
      board = row["leaderboard_top10"]
      expect(board.size).to eq(1) # fewer than 10 eps → emit all rows, never pad
      expect(board.first.keys).to eq(described_class::LEADERBOARD_KEYS)
      expect(board.first["ep"]).to eq("Api::Fixture#GET[0]")
      expect(board.first["branching_log2"]).to eq(3.0) # log2(4) + log2(2)
    end

    it "records the zero-ep degenerate as not_evaluable and fails its keyed assertions" do
      canon = [{ sha: ZERO_EP_SNAPSHOT, ep_count: 5 }]
      rows, mismatches = described_class.inventory(corpus, canon: canon)

      expect(rows.first["not_evaluable"]).to eq("vintage has no entrypoints")
      expect(mismatches.size).to eq(1)
      expect(mismatches.first["field"]).to eq("ep_count")
      expect(mismatches.first["measured"]).to include("not_evaluable")
    end

    it "reports a synthetic canon mismatch with measured-vs-locked values" do
      canon = [{ sha: EP_SNAPSHOT, ep_count: 999 }]
      _rows, mismatches = described_class.inventory(corpus, canon: canon)

      expect(mismatches.size).to eq(1)
      expect(mismatches.first).to include("field" => "ep_count",
                                          "measured" => "1", "locked" => "999")
    end
  end

  describe "the runner" do
    it "exits 2 on a canon mismatch, printing measured-vs-locked" do
      Dir.mktmpdir do |out|
        code = nil
        expect do
          code = described_class.run(corpus: corpus, opts: { out: out },
                                     canon: [{ sha: EP_SNAPSHOT, ep_count: 999 }])
        end.to output(/error: tier1 inventory canon mismatch aaaaaaaa ep_count: measured 1 vs locked 999/)
          .to_stderr
        expect(code).to eq(2)

        doc = JSON.parse(File.read(File.join(out, "tier1.json"), encoding: "UTF-8"))
        expect(doc["inventory_mismatches"].size).to eq(1)
        expect(doc["markdown_block"]).to include(described_class::DISCLOSURE)
      end
    end

    it "exits 2 when the edit-arm join is empty (corrupt corpus, never a 0% report)" do
      Dir.mktmpdir do |sandbox|
        doctored = File.join(sandbox, "corpus")
        FileUtils.cp_r(corpus_root, doctored)
        h2 = File.join(doctored, "data/derived/h2_pr_table.csv")
        File.write(h2, File.read(h2).gsub(",1,TRIPWIRE_NEVER_READ", ",0,TRIPWIRE_NEVER_READ"))

        Dir.mktmpdir do |out|
          code = nil
          expect do
            code = described_class.run(corpus: Backtest::Corpus.new(doctored),
                                       opts: { out: out }, canon: [])
          end.to output(/error: corpus edit-arm join \(in_t2_corpus rows\) is empty/).to_stderr
          expect(code).to eq(2)
        end
      end
    end

    it "exits 1 (never 0) when the fixture corpus misses the real-corpus gates" do
      Dir.mktmpdir do |out|
        code = nil
        expect do
          expect do
            code = described_class.run(corpus: corpus, opts: { out: out },
                                       canon: [{ sha: EP_SNAPSHOT, ep_count: 1 }])
          end.to output(/inventory: 1 snapshots, redeem canon OK\ntier1: flagged 0\/3/).to_stdout
        end.to output(/error: tier1 gate t1_flagged_21 false/).to_stderr
        expect(code).to eq(1)

        doc = JSON.parse(File.read(File.join(out, "tier1.json"), encoding: "UTF-8"))
        expect(doc["gates"]["t1_flagged_21"]).to be(false)
      end
    end
  end
end
