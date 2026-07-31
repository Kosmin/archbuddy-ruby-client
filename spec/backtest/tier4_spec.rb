# frozen_string_literal: true

require "tmpdir"
require "json"
require "stringio"
require "fileutils"
require_relative "../../script/backtest/tier4"

# v0.16 T15 (C-2): tier-4 reusability-score gates. The gate LOGIC is exercised
# here on synthetic engine-shaped findings (deterministic, corpus-free); the
# canon-value PASS across the 4 real calibration vintages is proven by the live
# engine run (probe/verify_engine_scores.py is the P3-V1 twin). These specs pin
# that each gate has TEETH (catches its violation), the degenerate/skip/exit
# orchestration, and the CLI dispatch (X-5 / V16-F5).
RSpec.describe Backtest::Tier4 do
  G = Backtest::Tier4::Gates

  def quiet
    orig = $stderr
    $stderr = StringIO.new
    result = yield
    [result, $stderr.string]
  ensure
    $stderr = orig
  end

  def with_env(overrides)
    saved = overrides.keys.to_h { |k| [k, ENV.fetch(k, nil)] }
    overrides.each { |k, v| v.nil? ? ENV.delete(k) : (ENV[k] = v) }
    yield
  ensure
    saved.each { |k, v| v.nil? ? ENV.delete(k) : (ENV[k] = v) }
  end

  # Build a per-vintage bundle in the exact internal shape Gates methods consume.
  def bundle(sha:, reus:, booth_ms: {}, ident: {}, class_of: {}, edges: [],
             entrypoints: [], score_distribution: nil, by_class: nil)
    scored = reus.select { |_k, e| !e["score"].nil? }
    booths = booth_ms.map { |nid, ms| { "node" => nid, "mass_savings" => ms } }
    doc = {
      "reusability" => reus,
      "reusability_by_class" => by_class,
      "scores" => { "reusability_compass" => { "toll_booths" => booths,
                                               "score_distribution" => score_distribution } }
    }
    by_fs = {}
    reus.each_key { |nid| (fs = ident[nid]) && (by_fs[fs] = nid) }
    { sha: sha, doc: doc, reus: reus, scored: scored, ident: ident, class_of: class_of,
      booth_ms: booth_ms, by_fs: by_fs, graph: { "edges" => edges, "entrypoints" => entrypoints } }
  end

  def node(score:, band:, raw:, collapse: 1.0, blast: 0, toll_booth: false, escape: nil, absorb: nil)
    e = { "score" => score, "score_band" => band, "score_raw" => raw,
          "collapse" => collapse, "blast" => blast, "toll_booth" => toll_booth }
    e["escape"] = true if escape
    e.merge!("absorb" => absorb, "absorb_raw" => absorb) if absorb
    e
  end

  describe "the gate registry" do
    it "derives 13 gate families (9 B-marked canon + 4 L9-A advisory)" do
      expect(described_class::GATE_FAMILIES.size).to eq(13)
      expect(described_class::GATE_FAMILIES).to include("G-5", "G-12", "G-13", "G-14", "G-15")
    end

    it "self-registers tier '4' in the CLI auto-discovery registry" do
      Backtest::CLI.load_tiers
      expect(Backtest::CLI::TIERS).to have_key("4")
    end
  end

  describe "band_of (round-half-away-from-zero, clamp ±5 — V16-F1)" do
    it "rounds halves away from zero and clamps" do
      expect(G.band_of(4.5)).to eq(5)
      expect(G.band_of(-4.5)).to eq(-5)
      expect(G.band_of(2.5)).to eq(3)
      expect(G.band_of(4.4999)).to eq(4)
      expect(G.band_of(7.0)).to eq(5)   # clamp
      expect(G.band_of(0.4)).to eq(0)
    end
  end

  describe "G.bundle (surface presence / honest N/A)" do
    rebuilt = Backtest::GraphRebuild::Rebuilt.new(
      graph_path: nil, id_index: {}, class_of: {}, stats: {}
    )

    it "returns nil when the reusability surface is absent (never a fabricated 0)" do
      expect(G.bundle("s", { "schema_version" => "1.9" }, rebuilt)).to be_nil
    end

    it "returns nil when every node is score-null (zero scored)" do
      doc = { "reusability" => { "n_1" => { "score" => nil } } }
      expect(G.bundle("s", doc, rebuilt)).to be_nil
    end
  end

  describe "G-3 pole exclusivity" do
    it "passes when no negative booth and no positive non-booth exist" do
      b = bundle(sha: "s", reus: {
                   "n_1" => node(score: -1.0, band: -1, raw: -1.5, toll_booth: false),
                   "n_2" => node(score: 3.0, band: 3, raw: 3.0, toll_booth: true)
                 })
      expect(G.g3(b)).to be(true)
    end

    it "fails on a negative toll_booth node (pole leak)" do
      b = bundle(sha: "s", reus: {
                   "n_1" => node(score: -1.0, band: -1, raw: -1.5, toll_booth: true)
                 })
      expect(G.g3(b)).to be(false)
    end

    it "fails on a positive non-booth node" do
      b = bundle(sha: "s", reus: {
                   "n_1" => node(score: 2.0, band: 2, raw: 2.0, toll_booth: false)
                 })
      expect(G.g3(b)).to be(false)
    end
  end

  describe "G-4 distribution sanity" do
    def dist_bundle(sha, hist)
      n = hist.values.sum
      reus = {}
      i = 0
      hist.each do |band, count|
        count.times do
          reus["n_#{i += 1}"] = node(score: band.to_i * 1.0, band: band.to_i, raw: band.to_i * 1.0)
        end
      end
      sd = { "n_scored" => n, "n_null" => 0, "bands" => hist, "zero_share" => 0.79 }
      bundle(sha: sha, reus: reus, score_distribution: sd)
    end

    it "passes on the archived base histogram (canon n + hist + envelope)" do
      b = dist_bundle(described_class::BASE, described_class::EXPECTED_HIST[described_class::BASE])
      expect(G.g4(b)).to be(true)
    end

    it "fails when the histogram diverges from the archived canon" do
      hist = described_class::EXPECTED_HIST[described_class::BASE].merge("0" => 1430)
      b = dist_bundle(described_class::BASE, hist)
      expect(G.g4(b)).to be(false)
    end

    it "fails (never vacuous) when n_scored is zero" do
      b = bundle(sha: described_class::BASE, reus: {},
                 score_distribution: { "n_scored" => 0, "n_null" => 0, "bands" => {} })
      expect(G.g4(b)).to be(false)
    end
  end

  describe "G-10 escapes negative (findings key `escape`, singular — V16-F9)" do
    it "passes when every escape-flagged scored node is < 0 (non-anchor vintage)" do
      b = bundle(sha: described_class::MID, reus: {
                   "n_1" => node(score: -0.72, band: -1, raw: -1.25, collapse: 4.0, escape: true),
                   "n_2" => node(score: -1.06, band: -1, raw: -1.9, collapse: 1.0, escape: true),
                   "n_3" => node(score: 0.0, band: 0, raw: 0.0) # non-escape ignored
                 })
      expect(G.g10(b)).to be(true)
    end

    it "fails when an escape node scores >= 0" do
      b = bundle(sha: described_class::MID, reus: {
                   "n_1" => node(score: 0.0, band: 0, raw: 0.0, escape: true)
                 })
      expect(G.g10(b)).to be(false)
    end
  end

  describe "G-12 absorb exclusivity (N==0 / no escape / collapse<=2)" do
    it "passes when absorb rides only eligible nodes" do
      b = bundle(sha: "s", reus: {
                   "n_1" => node(score: 0.0, band: 0, raw: 0.0, collapse: 1.0, absorb: 1.0),
                   "n_2" => node(score: -1.0, band: -1, raw: -1.5, collapse: 4.0) # no absorb
                 })
      expect(G.g12(b)).to be(true)
    end

    it "fails when an escape node carries absorb (leak)" do
      b = bundle(sha: "s", reus: {
                   "n_1" => node(score: 0.0, band: 0, raw: 0.0, escape: true, absorb: 1.0)
                 })
      expect(G.g12(b)).to be(false)
    end

    it "fails when a collapse>2 node carries absorb (leak)" do
      b = bundle(sha: "s", reus: {
                   "n_1" => node(score: 0.0, band: 0, raw: 0.0, collapse: 4.0, absorb: 1.0)
                 })
      expect(G.g12(b)).to be(false)
    end
  end

  describe "G-14 absorb distribution envelope" do
    it "passes inside the [10,35]% eligible / [1,5]% >=+3 / <=0.5% +5 envelope" do
      reus = {}
      # 100 scored nodes: 26 eligible (absorb ~2), 3 of them >=+3, none >=+5
      74.times { |i| reus["z_#{i}"] = node(score: 0.0, band: 0, raw: 0.0) }
      23.times { |i| reus["a_#{i}"] = node(score: 0.0, band: 0, raw: 0.0, absorb: 2.0) }
      3.times { |i| reus["b_#{i}"] = node(score: 0.0, band: 0, raw: 0.0, absorb: 3.2) }
      b = bundle(sha: "s", reus: reus)
      expect(G.g14(b)).to be(true)
    end

    it "fails when the eligible share escapes the envelope" do
      reus = {}
      50.times { |i| reus["z_#{i}"] = node(score: 0.0, band: 0, raw: 0.0) }
      50.times { |i| reus["a_#{i}"] = node(score: 0.0, band: 0, raw: 0.0, absorb: 2.0) }
      b = bundle(sha: "s", reus: reus)
      expect(G.g14(b)).to be(false) # 50% eligible > 35%
    end
  end

  describe "G-15 zero-pred entrypoints carry no absorb" do
    it "passes when zero-pred eps have no absorb key" do
      b = bundle(sha: "s",
                 reus: { "ep_1" => node(score: 0.0, band: 0, raw: 0.0) },
                 entrypoints: ["ep_1"], edges: [])
      expect(G.g15(b)).to be(true)
    end

    it "fails when a zero-pred ep carries absorb" do
      b = bundle(sha: "s",
                 reus: { "ep_1" => node(score: 0.0, band: 0, raw: 0.0, absorb: 1.0) },
                 entrypoints: ["ep_1"], edges: [])
      expect(G.g15(b)).to be(false)
    end
  end

  describe "families fold + degenerate handling" do
    it "forces a per-vintage gate FALSE when a needed vintage is degenerate (no scored nodes)" do
      docs = described_class::VINTAGES.to_h { |v| [v, :degenerate] }
      fams = G.families(docs)
      expect(fams["G-4"]).to be(false)
      expect(fams["G-10"]).to be(false)
    end
  end

  describe "engine preflight (loud-skip below 0.11.0)" do
    it "skips with exit 0 and a note when the resolved engine is < 0.11.0" do
      allow(described_class).to receive(:engine_version).and_return("0.10.0")
      corpus = instance_double(Backtest::Corpus)
      Dir.mktmpdir do |dir|
        code, err = quiet { described_class.run(corpus: corpus, opts: { out: dir }) }
        expect(code).to eq(0)
        expect(err).to include("< 0.11.0")
      end
    end
  end

  describe "corpus without the calibration vintages" do
    it "skips loudly with exit 0 (never a vacuous pass)" do
      allow(described_class).to receive(:engine_ok?).and_return(true)
      Dir.mktmpdir do |root|
        FileUtils.mkdir_p(File.join(root, "snapshots", "deadbeef000000"))
        corpus = Backtest::Corpus.new(root)
        code, err = quiet { described_class.run(corpus: corpus, opts: { out: File.join(root, "out") }) }
        expect(code).to eq(0)
        expect(err).to include("none of the calibration vintages")
      end
    end
  end

  describe "G-5 (#2146 pair) — source-repo dependent" do
    it "skips loudly (never false, never vacuous pass) when the study repo is absent" do
      Dir.mktmpdir do |dir|
        result, err = quiet { described_class.evaluate_g5(dir, described_class.method(:analyze), {}) }
        expect(result).to eq(:skipped)
        expect(err).to include("G-5 skipped")
      end
    end
  end

  describe "write_report exit codes + author-scan" do
    it "returns 0 and marks author_scan_clean when all gates pass (skipped gates don't fail)" do
      Dir.mktmpdir do |dir|
        gates = described_class::GATE_FAMILIES.to_h { |g| [g, g == "G-5" ? :skipped : true] }
        code, = quiet do
          described_class.write_report(File.join(dir, "t4"), dir,
                                       gates: gates, docs: { "68abf831" => {} }, absent: [])
        end
        expect(code).to eq(0)
        json = JSON.parse(File.read(File.join(dir, "tier4.json"), encoding: "UTF-8"))
        expect(json["gates"]["author_scan_clean"]).to be(true)
        expect(json["gates"]["G-5"]).to eq("skipped")
        expect(json["gate_count"]).to eq(13)
        expect(json["schema"]).to eq("archbuddy-tier4/1")
      end
    end

    it "returns 1 when any gate is false" do
      Dir.mktmpdir do |dir|
        gates = { "G-1a" => true, "G-4" => false }
        code, = quiet do
          described_class.write_report(File.join(dir, "t4"), dir,
                                       gates: gates, docs: {}, absent: [])
        end
        expect(code).to eq(1)
      end
    end
  end

  describe "CLI dispatch (X-5 / V16-F5)" do
    around do |ex|
      saved = Backtest::CLI::TIERS.dup
      ex.run
      Backtest::CLI::TIERS.clear
      Backtest::CLI::TIERS.merge!(saved)
    end

    it "accepts --tier 4 and rejects unknown tiers with the (0|1|2|3|4|all) error" do
      expect(Backtest::CLI.parse(["--tier", "4"])[:tier]).to eq("4")
      out, err = quiet { Backtest::CLI.parse(["--tier", "5"]) }
      expect(out).to be_nil
      expect(err).to include("(0|1|2|3|4|all)")
    end

    it "dispatches tier 4 ALONE for --tier 4 (never runs the report fold)" do
      ran = []
      allow(Backtest::CLI).to receive(:load_tiers) do
        %w[0 1 2 3 4].each { |t| Backtest::CLI.register_tier(t, ->(corpus:, opts:) { ran << t; 0 }) }
      end
      corpus = instance_double(Backtest::Corpus)
      allow(Backtest::Corpus).to receive(:new).and_return(corpus)
      allow(corpus).to receive(:validate!).and_return(true)
      with_env("ARCHBUDDY_STUDY_CORPUS" => Dir.mktmpdir) do
        code = quiet { Backtest::CLI.run(["--tier", "4"]) }.first
        expect(code).to eq(0)
      end
      expect(ran).to eq(["4"])
    end

    it "corpus unset → exit 0 (graceful skip before any tier loads)" do
      with_env("ARCHBUDDY_STUDY_CORPUS" => nil) do
        code, err = quiet { Backtest::CLI.run(["--tier", "4"]) }
        expect(code).to eq(0)
        expect(err).to include("ARCHBUDDY_STUDY_CORPUS not set")
      end
    end
  end
end
