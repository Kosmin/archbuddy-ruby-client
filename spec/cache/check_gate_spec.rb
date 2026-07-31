# frozen_string_literal: true

require "tmpdir"
require "fileutils"
require "stringio"
require "yaml"
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

  # v0.16 (serializer v6): `--check` regenerates via a COLLECT-ONLY pass —
  # the carry (fragment stamps via carry_prior_compass!, aggregate blocks via
  # preserve_existing_scores) must reproduce an analyze-stamped cache
  # byte-identically, or every analyzed repo would read permanently stale.
  it "exits 0 (clean) after an analyze stamps v6 scores — the carry keeps the rewrite byte-identical" do
    Dir.mktmpdir do |dir|
      init_repo(dir)
      seed(dir)
      run_collect(dir)

      # simulate `archbuddy analyze`: re-write the committed cache WITH a
      # findings-1.9 doc (score stamps + distribution + by_class folds).
      graph  = YAML.safe_load(File.read(File.join(dir, ".archbuddy/graph.yml")))
      id_map = YAML.safe_load(File.read(File.join(dir, ".archbuddy/id-map.yml")))
      node_id, = id_map["ids"].find { |_id, d| d["file"] == "app/x.rb" }
      bands = { "-5" => 0, "-4" => 0, "-3" => 0, "-2" => 0, "-1" => 0,
                "0" => 0, "1" => 1, "2" => 0, "3" => 0, "4" => 0, "5" => 0 }
      findings = {
        "scores" => {
          "reusability_compass" => {
            "reuse_index" => nil, "unshared_fraction" => nil,
            "toll_booths" => [], "extraction" => [], "leverage" => nil,
            "score_distribution" => { "n_scored" => 1, "n_null" => 0,
                                      "zero_share" => 0.0, "bands" => bands }
          }
        },
        "reusability" => {
          node_id => { "leverage" => 1.0, "collapse" => 1.0, "toll_booth" => false,
                       "quadrant" => "glue", "score" => 1.02, "score_band" => 1,
                       "score_raw" => 0.585, "absorb" => 1.09, "absorb_raw" => 1.2 }
        },
        "reusability_by_class" => {
          "cls_feedfacefeed" => { "min" => 1.02, "max" => 1.02, "count" => 1,
                                  "n_negative" => 0, "n_positive" => 1, "headline" => 1.02 }
        }
      }
      Archbuddy::Cache::Writer.new(project_root: dir)
                              .write(graph: graph, id_map: id_map, findings: findings)
      git(dir, "add", "-A")
      git(dir, "commit", "-qm", "analyze stamps")

      code, msg = run_check(dir)
      expect(code).to eq(Archbuddy::Cache::Checker::CLEAN)
      expect(msg).to match(/up-to-date|no drift/i)
    end
  end

  # M6: an analyze that publishes a `forward_discoverability` cost stamps the
  # `entrypoints` aggregate with mean/median/capped_fraction/by_category_cost.
  # The `--check` collect-only regen must CARRY those forward (mirroring the
  # egress carry) or the `entrypoints` block drifts and the gate exits 1 after
  # every real analyze. Without carry_entrypoint_cost! this exits DRIFT.
  it "exits 0 (clean) after an analyze stamps entrypoints forward cost — the carry keeps it clean (M6)" do
    Dir.mktmpdir do |dir|
      init_repo(dir)
      seed(dir)
      run_collect(dir)

      # simulate `archbuddy analyze` with a findings-1.5+ forward_discoverability
      # cost surface (headline + per-category lens) → entrypoints block gets cost.
      graph  = YAML.safe_load(File.read(File.join(dir, ".archbuddy/graph.yml")))
      id_map = YAML.safe_load(File.read(File.join(dir, ".archbuddy/id-map.yml")))
      findings = {
        "scores" => {
          "forward_discoverability" => {
            "grade" => "C", "score" => 3.4, "median" => 2.0, "capped_fraction" => 0.25
          },
          "forward_discoverability_by_category" => {
            "top_level" => { "score" => 3.4, "median" => 2.0, "grade" => "C",
                             "median_grade" => "B", "capped_fraction" => 0.25 }
          }
        }
      }
      Archbuddy::Cache::Writer.new(project_root: dir)
                              .write(graph: graph, id_map: id_map, findings: findings)
      git(dir, "add", "-A")
      git(dir, "commit", "-qm", "analyze stamps entrypoints cost")

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
