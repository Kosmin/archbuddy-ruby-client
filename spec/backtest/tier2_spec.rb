# frozen_string_literal: true

require "tmpdir"
require "json"
require "stringio"
require "fileutils"
require_relative "../../script/backtest/tier2"

# v0.15 P3-T6 (Tier 2): fixture-level rows — restriction on/off changing
# NET, merge-parent-only ep rows, empty-U_metric pair, unreachable-touched
# disclosure, skip accounting keys, and the pairing-consistency assert
# (doctored mismatch → exit 2).
RSpec.describe Backtest::Tier2 do
  VINTAGES = File.expand_path("../fixtures/review/vintages", __dir__)

  StubResult = Struct.new(:status, :dir, :reason, :log) do
    def ok? = status == :ok
  end

  # Maps sha → fixture vintage dir; records every requested sha.
  class StubScorer
    attr_reader :requested

    def initialize(map)
      @map = map
      @requested = []
    end

    def score(_repo, sha)
      @requested << sha
      dir = @map[sha]
      return StubResult.new(:skipped, nil, :unresolvable_sha, nil) if dir.nil?

      StubResult.new(:ok, dir, :cached, nil)
    end
  end

  def fixture(name) = File.join(VINTAGES, name)

  def read(name) = Archbuddy::Review::FragmentWalk.read(fixture(name))

  def quiet
    orig = $stderr
    $stderr = StringIO.new
    result = yield
    [result, $stderr.string]
  ensure
    $stderr = orig
  end

  # Minimal corpus: one PR touching the redeem file, one PR with no
  # scorable pr_files rows (arm non_app).
  def write_corpus(root)
    derived = File.join(root, "data", "derived")
    FileUtils.mkdir_p(derived)
    FileUtils.mkdir_p(File.join(root, "snapshots", "basesha1"))
    FileUtils.cp_r(File.join(fixture("twin_2083_base"), "."),
                   File.join(root, "snapshots", "basesha1")) # incl. .archbuddy/
    File.write(File.join(derived, "prs.csv"), <<~CSV)
      repo,pr_number,latency_hours,churn,arm,is_bugfix,base_sha,merge_commit_sha,size_stratum,merged_at
      thanx/fixture,1,10.0,5,edit,0,basesha1,mergesha1,small,2026-01-01T00:00:00Z
      thanx/fixture,2,20.0,1,non_app,0,basesha1,mergesha2,small,2026-01-02T00:00:00Z
    CSV
    File.write(File.join(derived, "pr_files.csv"), <<~CSV)
      repo,pr_number,path,file_class,change_type,previous_path
      thanx/fixture,1,app/api/api/v1/redeem_templates.rb,scorable_app,modified,
      thanx/fixture,1,app/models/program/redeem/template.rb,scorable_app,added,
      thanx/fixture,2,README.md,doc,modified,
    CSV
    File.write(File.join(derived, "pr_predictors.csv"), <<~CSV)
      repo,pr_number,base_sha,pr_max_log2_b_own,arm
      thanx/fixture,1,basesha1,13.0,edit
    CSV
    File.write(File.join(derived, "h2_pr_table.csv"), <<~CSV)
      repo,pr_number,t_quartile,t_max_log2_b_own,latency_hours,churn,in_t2_corpus
      thanx/fixture,1,4,13.0,10.0,5,1
    CSV
    Backtest::Corpus.new(root)
  end

  describe ".restrict (the A5 trap fix)" do
    it "restriction on/off changes NET on the twin pair" do
      base = read("twin_2083_base")
      head = read("twin_2083_head")
      full = Archbuddy::Review::Delta.new(base: base, head: head)
      expect(full.net_log2).to be_within(1e-6).of(3.0)

      # restricted to the untouched model file only → nothing moves
      files = ["app/models/program/redeem/template.rb"].to_set
      restricted = Archbuddy::Review::Delta.new(
        base: described_class.restrict(base, files),
        head: described_class.restrict(head, files)
      )
      expect(restricted.net_log2).to eq(0.0) # NEW b=1 node → +0.000
    end
  end

  describe ".sweep pairings" do
    it "base-merge: node rows only + the merge-parent-only stderr note" do
      Dir.mktmpdir do |root|
        corpus = write_corpus(root)
        scorer = StubScorer.new("mergesha1" => fixture("twin_2083_head"))
        (rows, skipped, _empty), err = quiet do
          described_class.sweep(corpus, { pairs: "base-merge" }, scorer,
                                described_class.gate_config,
                                parent_resolver: ->(_r, _s) { raise "never called" })
        end
        expect(err).to include("ep-level rows require --pairs merge-parent")
        expect(rows.size).to eq(1)
        expect(rows.first).not_to have_key("rs_union") # no per-PR ep rows
        expect(rows.first["net_log2"]).to be_within(1e-6).of(3.0) # restricted
        expect(rows.first["fired"]).to include("ExponentialNode")
        # skip accounting: the no-scorable-files PR, keyed by arm
        expect(skipped["no_touched_files"]).to eq("non_app" => 1)
      end
    end

    it "merge-parent: resolves sha^, records rs/ep rows incl. the disclosure" do
      Dir.mktmpdir do |root|
        corpus = write_corpus(root)
        scorer = StubScorer.new(
          "mergesha1" => fixture("twin_2083_head"),
          "mergesha1^" => fixture("twin_2083_base"),
          "mergesha2" => fixture("twin_2146_head"),
          "mergesha2^" => fixture("twin_2146_head") # identical pair → U_metric empty
        )
        (rows, _skipped, _empty), = quiet do
          described_class.sweep(corpus, { pairs: "merge-parent" }, scorer,
                                described_class.gate_config,
                                parent_resolver: ->(_repo, sha) { "#{sha}^" })
        end
        expect(scorer.requested).to include("mergesha1^") # parent pairing
        expect(rows.size).to eq(2)

        row1 = rows.find { |r| r["pr_number"] == "1" }
        expect(row1["rs_union"]).to eq(1)
        expect(row1["rs_sum"]).to eq(1)
        expect(row1["eps_metric_changed"]).to eq(1)
        expect(row1["unreachable_touched_nodes"]).to eq(1) # template.rb node

        # empty-U_metric pair → recorded honestly, never skipped
        row2 = rows.find { |r| r["pr_number"] == "2" }
        expect(row2["rs_union"]).to eq(0)
        expect(row2["eps_metric_changed"]).to eq(0)
      end
    end
  end

  describe ".ep_gate_path" do
    def stub_scorer(merge1_dir:)
      StubScorer.new(
        "5f2b8a6f-full" => merge1_dir, # what the resolver returns for merge^1
        described_class::MERGE_2083 => fixture("twin_2083_head"),
        described_class::BASE_2146 => fixture("twin_2146_base"),
        described_class::MERGE_2146 => fixture("twin_2146_head")
      )
    end

    def resolver
      ->(_repo, sha) { sha == described_class::MERGE_2083 ? "5f2b8a6f-full" : "#{sha}^" }
    end

    it "all 7 ep gates true on the canon-shaped twins" do
      (gates, rows, diagnostics, exit2), = quiet do
        described_class.ep_gate_path(stub_scorer(merge1_dir: fixture("twin_2083_base")),
                                     parent_resolver: resolver)
      end
      expect(exit2).to be_nil
      %w[uc2083_branching_13_16 uc2083_dividend_8192_65536 uc2083_mass_73_83
         uc2083_shape_stable rs2083_union_1_sum_1 rs2146_union_2_sum_2
         uc2146_new_ep_values].each do |gate|
        expect(gates[gate]).to be(true), "gate #{gate} false"
      end
      expect(rows["redeem_merge1"]["branching_log2"]).to eq(13.0)
      expect(diagnostics["rs2083_file_level"]).to include("union", "sum")
      expect(diagnostics["rs2083_file_level_label"]).to include("diagnostic only")
    end

    it "doctored merge^1 row → pairing-consistency mismatch → exit 2" do
      # head fixture as merge^1: redeem row 16.0 ≠ the Tier-1 base row 13.0
      (_gates, _rows, _diag, exit2), err = quiet do
        described_class.ep_gate_path(stub_scorer(merge1_dir: fixture("twin_2083_head")),
                                     parent_resolver: resolver)
      end
      expect(exit2).to eq(2)
      expect(err).to include("pairing-consistency mismatch")
      expect(err).to include("merge^1 row")
      expect(err).to include("tier1 row")
    end
  end

  describe ".pairing_consistent?" do
    it "flags the diverging fields" do
      tier1 = Backtest::Tier1::CANON[0][:redeem]
      good = { "branching_log2" => 13.0, "dividend" => 8192.0, "mass" => 73,
               "reach" => 2, "files" => 1, "depth" => 2 }
      expect(described_class.pairing_consistent?(good, tier1)).to eq([true, "consistent"])

      doctored = good.merge("mass" => 74)
      ok, message = described_class.pairing_consistent?(doctored, tier1)
      expect(ok).to be(false)
      expect(message).to include("mass")
    end
  end

  describe ".association" do
    it "excludes nothing itself — the runner filters evaluated_empty rows" do
      rows = [
        { "fired" => ["ExponentialNode"], "latency_hours" => "10.0" },
        { "fired" => [], "latency_hours" => "2.0" }
      ]
      table = described_class.association(rows)
      en = table.find { |r| r["rule"] == "ExponentialNode" }
      expect(en["n_fired"]).to eq(1)
      expect(en["median_latency_fired"]).to eq(10.0)
      expect(en["median_latency_not_fired"]).to eq(2.0)
    end
  end
end
