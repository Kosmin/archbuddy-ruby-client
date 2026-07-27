# frozen_string_literal: true

require "tmpdir"
require "json"
require "stringio"
require "fileutils"
require_relative "../../script/backtest/tier3"
require_relative "../../script/backtest/author_scan"

# v0.15 P3-T6 (Tier 3): the ratchet counterfactual through the REAL rule —
# the ep-budget breach with a `[0]`-bearing symbol ([S:F12] exact-string
# matching), the [S:C13/G8] empty-scope `no_match` honesty, and the loud
# 0-PR-scope failure.
RSpec.describe Backtest::Tier3 do
  VINTAGES = File.expand_path("../fixtures/review/vintages", __dir__)

  def read(name) = Archbuddy::Review::FragmentWalk.read(File.join(VINTAGES, name))

  def quiet
    orig = $stderr
    $stderr = StringIO.new
    result = yield
    [result, $stderr.string]
  ensure
    $stderr = orig
  end

  it "ep-budget breach via the REAL rule on the `[0]`-bearing symbol (F12)" do
    row, = quiet do
      described_class.ratchet_verdict(read("twin_2083_base"), read("twin_2083_head"),
                                      described_class.fixture_config("gate_ratchet_ep0.yml"))
    end
    expect(row["verdict"]).to eq("breach")
    expect(row["observed_log2"]).to be_within(0.0005).of(3.0)
  end

  it "paths budget breaches at 0 and −1 on the twin pair (the real-rule seam)" do
    at0, = quiet do
      described_class.ratchet_verdict(read("twin_2083_base"), read("twin_2083_head"),
                                      described_class.fixture_config("gate_ratchet_0.yml"))
    end
    expect(at0["verdict"]).to eq("breach")
    expect(at0["observed_log2"]).to be_within(0.0005).of(3.0)

    neg1, = quiet do
      described_class.ratchet_verdict(read("twin_2083_base"), read("twin_2083_head"),
                                      described_class.fixture_config("gate_ratchet_neg1.yml"))
    end
    expect(neg1["verdict"]).to eq("breach")
  end

  it "scope matching no fragments either side → no_match ([S:C13/G8] honesty)" do
    row, = quiet do
      # twin_2146 carries no redeem file — the budget scope matches nothing
      described_class.ratchet_verdict(read("twin_2146_base"), read("twin_2146_head"),
                                      described_class.fixture_config("gate_ratchet_0.yml"))
    end
    expect(row["verdict"]).to eq("no_match")
  end

  it "0-PR scope → exit 1 with the loud t3_seven_prs failure" do
    Dir.mktmpdir do |root|
      derived = File.join(root, "data", "derived")
      FileUtils.mkdir_p(derived)
      FileUtils.mkdir_p(File.join(root, "snapshots"))
      File.write(File.join(derived, "prs.csv"), <<~CSV)
        repo,pr_number,latency_hours,churn,arm,is_bugfix,base_sha,merge_commit_sha,size_stratum,merged_at
        thanx/fixture,1,10.0,5,edit,0,basesha1,mergesha1,small,2026-01-01T00:00:00Z
      CSV
      File.write(File.join(derived, "pr_files.csv"), <<~CSV)
        repo,pr_number,path,file_class,change_type,previous_path
        thanx/fixture,1,app/other.rb,scorable_app,modified,
      CSV
      File.write(File.join(derived, "pr_predictors.csv"),
                 "repo,pr_number,base_sha,pr_max_log2_b_own,arm\n")
      File.write(File.join(derived, "h2_pr_table.csv"),
                 "repo,pr_number,t_quartile,t_max_log2_b_own,latency_hours,churn,in_t2_corpus\n")
      corpus = Backtest::Corpus.new(root)

      out = File.join(root, "out")
      code, err = quiet do
        described_class.run(corpus: corpus, opts: { out: out },
                            scorer: Object.new, # never reached
                            repos: { "stub" => true },
                            parent_resolver: ->(_r, _s) { nil })
      end
      expect(code).to eq(1)
      expect(err).to include("0 PRs touch this scope")
      doc = JSON.parse(File.read(File.join(out, "tier3.json"), encoding: "UTF-8"))
      expect(doc["gates"]["t3_seven_prs"]).to be(false)
      # header contract: "budget 0"/"budget -1" spelled out — "verdict@0" reads
      # as an @-handle to the A6 author-scan and quarantines the report
      expect(doc["trajectory_markdown"])
        .to include("| verdict (budget 0) | verdict (budget -1) |")
      expect(Backtest::AuthorScan.scan(doc["trajectory_markdown"])).to be_empty
    end
  end
end
