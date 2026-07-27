# frozen_string_literal: true

require "tmpdir"
require "fileutils"
require "open3"
require_relative "../../script/backtest/corpus"
require_relative "../../script/backtest/snapshot_reader"
require_relative "../../script/backtest/repos"

# v0.15 P3-T3: corpus access layer + SnapshotReader privacy rails + the
# script/backtest.rb env-gating exit map.
RSpec.describe "Backtest corpus access" do
  CORPUS = File.expand_path("../fixtures/backtest_corpus", __dir__)
  SCRIPT = File.expand_path("../../script/backtest.rb", __dir__)
  SNAP_A = File.join(CORPUS, "snapshots", "a" * 40) # undotted (exported) layout
  SNAP_B = File.join(CORPUS, "snapshots", "b" * 40) # dotted layout
  SNAP_C = File.join(CORPUS, "snapshots", "c" * 40) # zero-entrypoint (Q8)

  # [S:F2]: the corrected spy-ban pattern — the aggregate archbuddy-findings.json
  # the reader MUST open no longer trips the ban; id-map.{json,yml}, bare
  # findings.{json,yml}, provenance.json stay banned.
  SPY_BAN = /id-map|(?<!archbuddy-)findings\.(json|yml)|provenance/

  describe Backtest::SnapshotReader do
    it "opens NO banned path (File.read spy over the whole fixture read)" do
      read_paths = []
      allow(File).to receive(:read).and_wrap_original do |original, *args, **kwargs|
        read_paths << args.first.to_s
        original.call(*args, **kwargs)
      end

      described_class.read(SNAP_A)
      described_class.read(SNAP_B)
      described_class.read(SNAP_C)

      banned = read_paths.grep(SPY_BAN)
      expect(banned).to eq([])
      expect(read_paths.grep(/archbuddy-findings\.json/)).not_to be_empty
    end

    it "loads dotted and undotted snapshots to identical node tables" do
      undotted = described_class.read(SNAP_A)
      dotted = described_class.read(SNAP_B)
      expect(undotted.by_identity.keys.sort).to eq(dotted.by_identity.keys.sort)
      expect(undotted.node_count).to eq(2)
      expect(undotted.eps.map(&:symbol)).to eq(["Api::Fixture#GET[0]"])
    end

    it "reads the zero-ep degenerate snapshot honestly (eps == [], Q8 downstream)" do
      vintage = described_class.read(SNAP_C)
      expect(vintage.eps).to eq([])
      expect(vintage.node_count).to eq(2)
      expect(vintage.edges?).to be(true)
      expect(vintage.graph.unreachable_from_entrypoints).to be_nil # NEVER "all unreachable"
    end
  end

  describe Backtest::Corpus do
    it "validates the fixture corpus and reads whitelisted rows" do
      corpus = described_class.new(CORPUS)
      expect(corpus.validate!).to be(true)
      expect(corpus.prs.size).to eq(3)
      expect(corpus.pr_files.first["path"]).to eq("app/api/fixture.rb")
      expect(corpus.snapshot_dir("a" * 40)).to eq(SNAP_A)
    end

    it "raises loudly on a 0-PR corpus (a confident empty report is forbidden)" do
      Dir.mktmpdir do |dir|
        FileUtils.mkdir_p(File.join(dir, "data/derived"))
        FileUtils.mkdir_p(File.join(dir, "snapshots"))
        Backtest::Corpus::ALLOWLISTS.each do |name, allow|
          File.write(File.join(dir, "data/derived", name), "#{allow.join(',')}\n")
        end
        expect { described_class.new(dir).validate! }
          .to raise_error(Backtest::Corpus::CorpusError, /corpus has 0 PRs — wrong ARCHBUDDY_STUDY_CORPUS\?/)
      end
    end
  end

  describe Backtest::Repos do
    it "parses org/name=abs_path[:subdir] CSV" do
      repos = described_class.parse(
        "thanx/thanx-merchant-api-new=/abs/old,thanx/nexus=/abs/nexus:services/merchant-api"
      )
      expect(repos.keys).to eq(%w[thanx/thanx-merchant-api-new thanx/nexus])
      expect(repos["thanx/nexus"].subdir).to eq("services/merchant-api")
      expect(repos["thanx/nexus"].target_in("/wt")).to eq("/wt/services/merchant-api")
      expect(repos["thanx/thanx-merchant-api-new"].target_in("/wt")).to eq("/wt")
    end

    it "returns {} for unset/empty and raises on malformed entries" do
      expect(described_class.parse(nil)).to eq({})
      expect(described_class.parse("")).to eq({})
      expect { described_class.parse("garbage") }.to raise_error(ArgumentError, /bad ARCHBUDDY_STUDY_REPOS entry/)
    end
  end

  describe "script/backtest.rb env gating (A6 exit map)" do
    def run_script(env, *args)
      # F13: pinned commands run under the bundler env (the suite itself runs
      # under `bundle exec`, so the subprocess inherits BUNDLE_GEMFILE etc.).
      out, err, status = Open3.capture3(
        env, "bundle", "exec", "ruby", SCRIPT, *args,
        chdir: File.expand_path("../..", __dir__)
      )
      [out, err, status.exitstatus]
    end

    it "exits 0 with the pinned note when ARCHBUDDY_STUDY_CORPUS is unset" do
      _out, err, code = run_script({ "ARCHBUDDY_STUDY_CORPUS" => nil }, "--tier", "0")
      expect(code).to eq(0)
      expect(err).to include("note: backtest skipped: ARCHBUDDY_STUDY_CORPUS not set")
    end

    it "exits 2 when the corpus root does not exist" do
      _out, err, code = run_script({ "ARCHBUDDY_STUDY_CORPUS" => "/nonexistent" }, "--tier", "0")
      expect(code).to eq(2)
      expect(err).to match(/^error: /)
    end

    it "exits 0 on the fixture corpus (graceful tier-2 skip without repos env)" do
      # tier 2 registered at P3-T6 — without ARCHBUDDY_STUDY_REPOS it skips loudly
      out, err, code = run_script({ "ARCHBUDDY_STUDY_CORPUS" => CORPUS,
                                    "ARCHBUDDY_STUDY_REPOS" => nil }, "--tier", "2")
      expect(code).to eq(0)
      expect(err).to include("note: tier2 skipped: ARCHBUDDY_STUDY_REPOS not set")
      expect(out).to eq("")
    end

    it "exits 2 on usage errors" do
      _out, err, code = run_script({ "ARCHBUDDY_STUDY_CORPUS" => CORPUS }, "--tier", "9")
      expect(code).to eq(2)
      expect(err).to include("error: unknown --tier '9'")
    end
  end
end
