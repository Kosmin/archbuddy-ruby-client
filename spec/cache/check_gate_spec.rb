# frozen_string_literal: true

require "tmpdir"
require "fileutils"
require "stringio"
require "archbuddy/cli/collect"
require "archbuddy/cache/checker"

# R3-1: `archbuddy collect --check` = CI STALENESS GATE. Regenerates the
# committed cache + asserts it matches what is committed (git diff). Exit 0 clean,
# 1 on drift, 2 (LOUD) when there is no committed baseline — never a vacuous pass.
# NEVER reads the SECRET id-map (committed cache is real-name).
RSpec.describe "collect --check CI staleness gate (R3-1)" do
  def git(dir, *args)
    system("git", "-C", dir, *args, out: File::NULL, err: File::NULL)
  end

  def init_repo(dir)
    git(dir, "init", "-q")
    git(dir, "config", "user.email", "t@t")
    git(dir, "config", "user.name", "t")
    # Audited-repo gitignore template so the committed cache is stageable and
    # the secret/interchange stays ignored.
    FileUtils.cp(
      File.expand_path("../../templates/audited-repo.gitignore", __dir__),
      File.join(dir, ".gitignore")
    )
  end

  def seed(dir, body = "def main\n  helper\nend\n\ndef helper\n  1\nend\n")
    FileUtils.mkdir_p(File.join(dir, "app"))
    File.write(File.join(dir, "app/x.rb"), body)
  end

  # Run `collect --check`, capturing the exit code + stderr message.
  def run_check(dir)
    err = StringIO.new
    orig = $stderr
    $stderr = err
    code = nil
    Dir.chdir(dir) do
      begin
        Archbuddy::CLI::Collect.new.call(
          path: ".", out_dir: nil, language: "ruby",
          entrypoints: "all_public", entrypoint_pattern: [], check: true
        )
      rescue SystemExit => e
        code = e.status
      end
    end
    [code, err.string]
  ensure
    $stderr = orig
  end

  def run_collect(dir)
    err = StringIO.new
    orig = $stderr
    $stderr = err
    Dir.chdir(dir) do
      Archbuddy::CLI::Collect.new.call(
        path: ".", out_dir: nil, language: "ruby",
        entrypoints: "all_public", entrypoint_pattern: []
      )
    end
  ensure
    $stderr = orig
  end

  it "exits 2 (LOUD, no baseline) when there is no committed cache" do
    Dir.mktmpdir do |dir|
      init_repo(dir)
      seed(dir)
      code, msg = run_check(dir)
      expect(code).to eq(Archbuddy::Cache::Checker::NO_BASELINE)
      expect(msg).to match(/no baseline|no committed archbuddy cache/i)
      expect(msg).to match(/archbuddy (reset|collect)/)
    end
  end

  it "exits 0 (clean) right after a fresh collect + commit — cache is up-to-date" do
    Dir.mktmpdir do |dir|
      init_repo(dir)
      seed(dir)
      run_collect(dir)
      git(dir, "add", "-A")
      git(dir, "commit", "-qm", "seed cache")

      code, msg = run_check(dir)
      expect(code).to eq(Archbuddy::Cache::Checker::CLEAN)
      expect(msg).to match(/up-to-date|no drift/i)
    end
  end

  it "exits 1 (DRIFT) when source changed but the committed cache was not regenerated + committed" do
    Dir.mktmpdir do |dir|
      init_repo(dir)
      seed(dir)
      run_collect(dir)
      git(dir, "add", "-A")
      git(dir, "commit", "-qm", "seed cache")

      # Change the source (add a new method + call) WITHOUT re-committing the cache.
      seed(dir, "def main\n  helper\n  extra\nend\n\ndef helper\n  1\nend\n\ndef extra\n  2\nend\n")

      code, msg = run_check(dir)
      expect(code).to eq(Archbuddy::Cache::Checker::DRIFT)
      expect(msg).to match(/stale/i)
    end
  end

  it "never reads the SECRET id-map during a check (real-name committed cache)" do
    Dir.mktmpdir do |dir|
      init_repo(dir)
      seed(dir)
      run_collect(dir)
      git(dir, "add", "-A")
      git(dir, "commit", "-qm", "seed cache")

      # Remove the id-map entirely (simulate a fresh clone / CI checkout where the
      # gitignored secret is absent). The check must still work.
      FileUtils.rm_f(File.join(dir, ".archbuddy/id-map.yml"))
      code, = run_check(dir)
      expect(code).to eq(Archbuddy::Cache::Checker::CLEAN)
    end
  end
end
