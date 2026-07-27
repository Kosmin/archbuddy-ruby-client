# frozen_string_literal: true

require "tmpdir"
require "json"
require "stringio"
require "fileutils"
require "open3"
require "archbuddy/cli"

# v0.15 P1-T7: `archbuddy lint [TARGET]` — the always-on Q9 leaderboard
# (12-key rows, R39) over the live-collected controller fixture, the
# exclude_entrypoints anti-gaming contract, zero-ep Q8 honesty, the 0-node
# precedence pin, --trust-cache reuse, and stdout purity.
RSpec.describe Archbuddy::CLI::Lint do
  REPO_ROOT = File.expand_path("../..", __dir__)
  TWELVE_KEYS = %w[rank ep kind file branching_log2 mass reach files depth
                   dividend max_cone_node_log2 cost_note].freeze

  # The [D1] tmpdir fixture: a 6-decision guard-style single-outcome action
  # (branches 64 = 2^6; V_floor stays 1) + one unreached helper. The class
  # name drives entrypoint detection (…Controller → kind "controllers").
  def build_fixture(dir, klass: "FooController")
    FileUtils.mkdir_p(File.join(dir, "app"))
    File.write(File.join(dir, "app", "main.rb"), <<~RUBY)
      class #{klass}
        def show
          x = 1 if p1
          x = 2 if p2
          x = 3 if p3
          x = 4 if p4
          x = 5 if p5
          x = 6 if p6
          :ok
        end
      end
    RUBY
    File.write(File.join(dir, "app", "helper.rb"), <<~RUBY)
      class Helper
        def tiny
          :ok
        end
      end
    RUBY
    dir
  end

  def run_lint(**kwargs)
    out = StringIO.new
    err = StringIO.new
    orig_out = $stdout
    orig_err = $stderr
    $stdout = out
    $stderr = err
    code = nil
    begin
      described_class.new.call(**kwargs)
    rescue SystemExit => e
      code = e.status
    ensure
      $stdout = orig_out
      $stderr = orig_err
    end
    [code, out.string, err.string]
  end

  describe "--help" do
    it "exits 0 and shows all 9 flags + the target argument (I-P7)" do
      output, status = Open3.capture2e(
        { "ARCHITECTURE_AUDITOR_PATH" => ENV.fetch("ARCHITECTURE_AUDITOR_PATH", nil) }.compact,
        RbConfig.ruby, File.join(REPO_ROOT, "exe", "archbuddy"), "lint", "--help",
        chdir: REPO_ROOT
      )
      expect(status.exitstatus).to eq(0)
      expect(output).to include("TARGET")
      %w[format config trust-cache fail-level advisory todo no-todo
         auto-gen-todo stamp].each do |flag|
        expect(output).to match(/--(\[no-\])?#{Regexp.escape(flag)}/)
      end
    end
  end

  it "no config: [ExponentialNode] AND [UseCaseComplexity] printed, exit 0 (advisory)" do
    Dir.mktmpdir do |dir|
      build_fixture(dir)
      code, stdout, = run_lint(target: dir)
      expect(code).to eq(0)
      expect(stdout).to include("[ExponentialNode]")
      expect(stdout).to include("[UseCaseComplexity]")
    end
  end

  describe "--format json (the Q9 leaderboard, 12-key rows)" do
    it "renders use_cases.count 1 with the R39 row + unreachable share" do
      Dir.mktmpdir do |dir|
        build_fixture(dir)
        code, stdout, = run_lint(target: dir, format: "json")
        expect(code).to eq(0)
        expect(stdout[0]).to eq("{") # stdout purity
        doc = JSON.parse(stdout)

        expect(doc["run"]["command"]).to eq("lint")
        expect(doc["run"]).not_to have_key("base")
        expect(doc).not_to have_key("delta")
        expect(doc).not_to have_key("ratchet") # no verdict keys in lint (I-P8)

        expect(doc["use_cases"]["count"]).to eq(1)
        row = doc["use_cases"]["leaderboard"].fetch(0)
        expect(row.keys.sort).to eq(TWELVE_KEYS.sort) # the 12-key set (R39)
        expect(row["branching_log2"]).to eq(6.0)
        expect(row["kind"]).to eq("controllers")
        expect(row["ep"]).to eq("FooController#show")
        # dividend self-consistency — read from output, never hardcoded
        # (guard-style single outcome ⇒ V_floor 1 ⇒ dividend = 2^branching).
        expect(row["dividend"]).to be_within(1e-6).of(2**row["branching_log2"])

        unreachable = doc["summary"]["unreachable_from_entrypoints"]
        expect(unreachable["nodes"]).to be >= 0
        # fixture total = 2 app nodes (show + tiny helper)
        expect(unreachable["share"]).to eq((unreachable["nodes"] / 2.0).round(4))
      end
    end
  end

  describe "exclude_entrypoints (end-to-end anti-gaming)" do
    it "drops the UCC finding but the leaderboard row STAYS" do
      Dir.mktmpdir do |dir|
        build_fixture(dir)
        File.write(File.join(dir, ".archbuddy.yml"), <<~YAML)
          version: 1
          rules:
            UseCaseComplexity:
              exclude_entrypoints: ["FooController#show"]
        YAML
        code, stdout, = run_lint(target: dir, format: "json", advisory: true)
        expect(code).to eq(0)
        doc = JSON.parse(stdout)
        expect(doc["findings"].map { |f| f["rule"] }).not_to include("UseCaseComplexity")
        expect(doc["use_cases"]["count"]).to eq(1)
        expect(doc["use_cases"]["leaderboard"].fetch(0)["ep"]).to eq("FooController#show")
      end
    end
  end

  describe "zero-ep honesty (Q8)" do
    it "count 0, no unreachable key, the Q8 stderr note, exit unchanged" do
      Dir.mktmpdir do |dir|
        build_fixture(dir, klass: "FooService") # not a Controller → zero eps
        code, stdout, stderr = run_lint(target: dir, format: "json")
        expect(code).to eq(0) # exit unchanged by the note
        doc = JSON.parse(stdout)
        expect(doc["use_cases"]["count"]).to eq(0)
        expect(doc["use_cases"]["leaderboard"]).to eq([])
        expect(doc["summary"]).not_to have_key("unreachable_from_entrypoints")
        expect(stderr).to include(
          "vintage has no entrypoints (nothing is reachable — check collector entrypoint detection)"
        )
      end
    end
  end

  describe "0-node vintage (pinned precedence: the empty-vintage warning wins)" do
    it "warns, suppresses the Q8 note, renders the 0-count summary, exit 0" do
      Dir.mktmpdir do |dir|
        File.write(File.join(dir, "archbuddy-findings.json"),
                   JSON.generate(serializer_version: 5, sources: {}))
        code, stdout, stderr = run_lint(target: dir, trust_cache: true, format: "json")
        expect(code).to eq(0)
        expect(stderr).to include("warning: vintage contains 0 nodes")
        expect(stderr).not_to include("no entrypoints") # Q8 suppressed
        doc = JSON.parse(stdout)
        expect(doc["summary"]["counts"].values).to all(eq(0))
      end
    end
  end

  describe "--trust-cache" do
    it "reuses a dirty working-tree cache LOUDLY, without re-collecting" do
      Dir.mktmpdir do |dir|
        build_fixture(dir)
        Archbuddy::Review::Collector.collect(source_root: dir, write_root: dir)
        # dirty the source: grow to 7 decisions (branches 128 = 2^7)
        File.write(File.join(dir, "app", "main.rb"), <<~RUBY)
          class FooController
            def show
              x = 1 if p1
              x = 2 if p2
              x = 3 if p3
              x = 4 if p4
              x = 5 if p5
              x = 6 if p6
              x = 7 if p7
              :ok
            end
          end
        RUBY
        code, stdout, stderr = run_lint(target: dir, trust_cache: true, format: "json")
        expect(code).to eq(0)
        expect(stderr).to include("warning:")
        doc = JSON.parse(stdout)
        # the STALE cache renders (6.0, not 7.0) — no re-collect happened
        expect(doc["use_cases"]["leaderboard"].fetch(0)["branching_log2"]).to eq(6.0)
      end
    end
  end
end
