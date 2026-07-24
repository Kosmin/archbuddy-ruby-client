# frozen_string_literal: true

require "tmpdir"
require "fileutils"
require "json"
require "open3"
require_relative "../../script/backtest/head_scorer"
require_relative "../../script/backtest/repos"

# v0.15 P3-T5: HeadScorer — worktree create→use→REMOVE, pointer-driven copy
# (id-map exclusion), resume idempotency, .partial rename; plus the env-gated
# live smoke on the archived probe repo (merge^1 of #2083).
RSpec.describe Backtest::HeadScorer do
  GIT_ENV = {
    "GIT_AUTHOR_NAME" => "spec", "GIT_AUTHOR_EMAIL" => "spec@example.invalid",
    "GIT_COMMITTER_NAME" => "spec", "GIT_COMMITTER_EMAIL" => "spec@example.invalid",
    "GIT_CONFIG_GLOBAL" => "/dev/null", "GIT_CONFIG_SYSTEM" => "/dev/null"
  }.freeze

  def git!(dir, *args)
    out, err, status = Open3.capture3(GIT_ENV, "git", "-C", dir, *args)
    raise "git #{args.join(' ')} failed: #{err}" unless status.success?

    out.strip
  end

  def build_fixture_clone(dir)
    git!(dir, "init", "-q", "-b", "main")
    git!(dir, "config", "user.name", "spec")
    git!(dir, "config", "user.email", "spec@example.invalid")
    File.write(File.join(dir, "lib.rb"), "def main\n  helper\nend\n\ndef helper\n  1\nend\n")
    git!(dir, "add", ".")
    git!(dir, "commit", "-q", "-m", "one")
    File.write(File.join(dir, "lib.rb"), "def main\n  helper\nend\n\ndef helper\n  2\nend\n")
    git!(dir, "add", ".")
    git!(dir, "commit", "-q", "-m", "two")
    git!(dir, "rev-parse", "HEAD")
  end

  describe "fixture-clone lifecycle" do
    it "scores collect-only, copies pointer-driven, removes the worktree, resumes git-free" do
      Dir.mktmpdir do |dir|
        clone = File.join(dir, "clone")
        FileUtils.mkdir_p(clone)
        sha = build_fixture_clone(clone)
        out = File.join(dir, "out")

        repos = { "fake/repo" => Backtest::Repos::Entry.new(key: "fake/repo", path: clone, subdir: nil) }
        scorer = described_class.new(repos: repos, out: out)

        result = scorer.score("fake/repo", sha)
        expect(result.ok?).to be(true)

        # cache shape: aggregate + pointed fragments, none of the SECRETs
        expect(File).to exist(File.join(result.dir, "archbuddy-findings.json"))
        aggregate = JSON.parse(File.read(File.join(result.dir, "archbuddy-findings.json")))
        expect(aggregate["serializer_version"]).to eq(5)
        all_files = Dir.glob(File.join(result.dir, "**", "*"), File::FNM_DOTMATCH)
                       .select { |p| File.file?(p) }
        expect(all_files.grep(%r{id-map|graph\.yml|findings\.yml|/\.cache/})).to eq([])
        expect(all_files.grep(/\.json\z/).size).to be >= 2 # aggregate + ≥1 fragment
        expect(Dir.glob(File.join(result.dir, "**", "*.partial"))).to eq([])

        # worktree hygiene: exactly the main tree remains
        porcelain = git!(clone, "worktree", "list", "--porcelain")
        expect(porcelain.scan(/^worktree /).size).to eq(1)
        expect(File.directory?(File.join(out, "worktrees", "wt-#{sha}"))).to be(false)

        # resume: zero git commands (Open3 spy) and the cache returned
        expect(Open3).not_to receive(:capture3)
        expect(Open3).not_to receive(:capture2e)
        resumed = scorer.score("fake/repo", sha)
        expect(resumed.ok?).to be(true)
        expect(resumed.reason).to eq(:cached)
        expect(resumed.dir).to eq(result.dir)
      end
    end

    it "skips unresolvable SHAs without attempting a worktree" do
      Dir.mktmpdir do |dir|
        clone = File.join(dir, "clone")
        FileUtils.mkdir_p(clone)
        build_fixture_clone(clone)
        repos = { "fake/repo" => Backtest::Repos::Entry.new(key: "fake/repo", path: clone, subdir: nil) }
        scorer = described_class.new(repos: repos, out: File.join(dir, "out"))

        result = scorer.score("fake/repo", "0" * 40)
        expect(result.status).to eq(:skipped)
        expect(result.reason).to eq(:unresolvable_sha)
        expect(Dir.glob(File.join(dir, "out", "worktrees", "*"))).to eq([])
        expect(Dir.glob(File.join(dir, "out", "head_scores", "*"))).to eq([])
      end
    end

    it "records collect failures with the log path and leaves no partial cache" do
      Dir.mktmpdir do |dir|
        clone = File.join(dir, "clone")
        FileUtils.mkdir_p(clone)
        git!(clone, "init", "-q", "-b", "main")
        git!(clone, "config", "user.name", "spec")
        git!(clone, "config", "user.email", "spec@example.invalid")
        File.write(File.join(clone, "README.md"), "no ruby here\n")
        git!(clone, "add", ".")
        git!(clone, "commit", "-q", "-m", "no sources")
        sha = git!(clone, "rev-parse", "HEAD")

        repos = { "fake/repo" => Backtest::Repos::Entry.new(key: "fake/repo", path: clone, subdir: nil) }
        scorer = described_class.new(repos: repos, out: File.join(dir, "out"))

        result = scorer.score("fake/repo", sha)
        expect(result.status).to eq(:skipped)
        expect(result.reason).to eq(:collect_failed)
        expect(File).to exist(result.log)
        expect(Dir.glob(File.join(dir, "out", "head_scores", "*"))).to eq([])
        porcelain = git!(clone, "worktree", "list", "--porcelain")
        expect(porcelain.scan(/^worktree /).size).to eq(1)
      end
    end
  end

  describe "live smoke (env-gated via ARCHBUDDY_STUDY_REPOS)" do
    MERGE_2083 = "f61b758c21d1"

    it "scores the #2083 merge^1 of the archived repo in <= 15 s, worktrees clean" do
      repos = Backtest::Repos.from_env
      entry = repos["thanx/thanx-merchant-api-new"]
      skip "ARCHBUDDY_STUDY_REPOS without thanx/thanx-merchant-api-new — live smoke skipped" if entry.nil?

      Dir.mktmpdir do |out|
        scorer = described_class.new(repos: repos, out: out)
        sha, _err, status = Open3.capture3("git", "-C", entry.path, "rev-parse", "#{MERGE_2083}^")
        raise "cannot resolve #{MERGE_2083}^ in the archived clone" unless status.success?

        t0 = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        result = scorer.score("thanx/thanx-merchant-api-new", sha.strip)
        wall = Process.clock_gettime(Process::CLOCK_MONOTONIC) - t0

        expect(result.ok?).to be(true)
        aggregate = JSON.parse(File.read(File.join(result.dir, "archbuddy-findings.json")))
        expect(aggregate["serializer_version"]).to eq(5)
        expect(wall).to be <= 15.0

        porcelain, _e, _s = Open3.capture3("git", "-C", entry.path, "worktree", "list", "--porcelain")
        expect(porcelain.scan(/^worktree /).size).to eq(1)
      end
    end
  end
end
