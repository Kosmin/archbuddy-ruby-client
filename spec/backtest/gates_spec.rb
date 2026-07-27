# frozen_string_literal: true

require "tmpdir"
require "json"
require "open3"
require "fileutils"
require_relative "../../script/backtest/head_scorer"
require_relative "../../script/backtest/repos"

# v0.15 P3-T7: the I8/I13 worked-example gates — both A5 PRs reproduced
# through the SHIPPED CLI (exe/archbuddy, never library calls), asserting
# observable stdout JSON + exit codes, now incl. the v0.15 use-case
# observables ([D3] — R41: TOP-LEVEL `review_surface`). Env-gated: skips
# loudly without ARCHBUDDY_STUDY_REPOS.
RSpec.describe "worked-example CLI gates (A5 through exe/archbuddy)" do
  REPO_ROOT_GATES = File.expand_path("../..", __dir__)
  ARCHIVE = "thanx/thanx-merchant-api-new"
  MERGE_2083_G = "f61b758c21d1"
  MERGE_2146_G = "83cc360c2879"
  BASE_2146_G = "de9630a6f0b9"
  REDEEM_FILE_G = "app/api/api/v1/redeem_templates.rb"
  REDEEM_EP_G = "Api::V1::RedeemTemplates#PATCH[0]"

  GATES_GIT_ENV = {
    "GIT_AUTHOR_NAME" => "spec", "GIT_AUTHOR_EMAIL" => "spec@example.invalid",
    "GIT_COMMITTER_NAME" => "spec", "GIT_COMMITTER_EMAIL" => "spec@example.invalid",
    "GIT_CONFIG_GLOBAL" => "/dev/null", "GIT_CONFIG_SYSTEM" => "/dev/null"
  }.freeze

  def archive_entry
    Backtest::Repos.from_env[ARCHIVE]
  end

  def git!(dir, *args)
    out, err, status = Open3.capture3(GATES_GIT_ENV, "git", "-C", dir, *args)
    raise "git #{args.join(' ')} failed: #{err}" unless status.success?

    out.strip
  end

  def worktree_count(repo)
    git!(repo, "worktree", "list", "--porcelain").scan(/^worktree /).size
  end

  def with_worktree(repo, sha)
    before = worktree_count(repo)
    Dir.mktmpdir do |tmp|
      wt = File.join(File.realpath(tmp), "wt") # /var → /private/var (git toplevel)
      git!(repo, "worktree", "add", "--detach", wt, sha)
      begin
        yield wt
      ensure
        git!(repo, "worktree", "remove", "--force", wt)
        expect(worktree_count(repo)).to eq(before)
      end
    end
  end

  # HeadScorer-fed base cache (reuses tmp/backtest caching — warm re-runs).
  def base_cache_for(sha)
    scorer = Backtest::HeadScorer.new(repos: Backtest::Repos.from_env,
                                      out: File.join(REPO_ROOT_GATES, "tmp", "backtest"))
    result = scorer.score(ARCHIVE, sha)
    raise "head-scoring #{sha} failed: #{result.reason}" unless result.ok?

    result.dir
  end

  # The SHIPPED CLI ([S:R3] arg order): archbuddy diff <target> <base-ref>
  # --base-cache … — stdout must be VALID JSON alone (P5 rides this gate).
  def run_shipped_diff(target, base_ref, base_cache:, config:)
    env = { "ARCHITECTURE_AUDITOR_PATH" => ENV.fetch("ARCHITECTURE_AUDITOR_PATH", nil) }.compact
    stdout, _stderr, status = Open3.capture3(
      env, RbConfig.ruby, File.join(REPO_ROOT_GATES, "exe", "archbuddy"),
      "diff", target, base_ref,
      "--base-cache", base_cache, "--config", config, "--format", "json",
      chdir: REPO_ROOT_GATES
    )
    stdout = stdout.force_encoding("UTF-8")
    expect(stdout[0]).to eq("{") # nothing before the document
    [JSON.parse(stdout), status.exitstatus]
  end

  def fixture_config(name)
    File.expand_path("../fixtures/backtest/#{name}", __dir__)
  end

  def component_value(finding, key)
    finding.dig("components", key, "value")
  end

  it "gate #2083 (blocked-PR profile): node rows + use-case observables, exit 1" do
    entry = archive_entry
    skip "ARCHBUDDY_STUDY_REPOS without #{ARCHIVE} — #2083 CLI gate skipped" if entry.nil?

    merge1 = git!(entry.path, "rev-parse", "#{MERGE_2083_G}^")
    base_cache = base_cache_for(merge1)

    with_worktree(entry.path, MERGE_2083_G) do |target|
      doc, exit_code = run_shipped_diff(target, merge1,
                                        base_cache: base_cache,
                                        config: fixture_config("gate_2083.yml"))
      expect(exit_code).to eq(1) # ExponentialNode error + ratchet breach

      en = doc["findings"].find { |f| f["rule"] == "ExponentialNode" }
      expect(en).to include("file" => REDEEM_FILE_G, "symbol" => REDEEM_EP_G)
      expect(en["value_raw"]).to eq(65_536) # head branches

      mg = doc["findings"].find { |f| f["rule"] == "MultiplicativeGrowth" }
      expect(mg["delta_log2"]).to eq(3.0)

      expect(doc["summary"]["delta"]["net_log2_b_own"]).to eq(3.0)
      ratchet = doc["ratchet"].fetch(0)
      expect(ratchet["verdict"]).to eq("breach")
      expect(ratchet["budget_log2"]).to eq(0.0)

      # v0.15 additions ([D3] + R41: TOP-LEVEL review_surface)
      expect(doc["review_surface"]["union"]).to eq(1)
      expect(doc["review_surface"]["sum"]).to eq(1)
      expect(doc["review_surface"]["eps"].map { |row| row["ep_symbol"] })
        .to eq([REDEEM_EP_G]) # the Q3 changed-node number, NOT 5/11

      ucc = doc["findings"].find { |f| f["rule"] == "UseCaseComplexity" }
      expect(ucc).to include("severity" => "warn", "file" => REDEEM_FILE_G,
                             "symbol" => REDEEM_EP_G)
      expect(component_value(ucc, "branching_log2")).to eq(16.0)
      expect(component_value(ucc, "max_cone_node_log2")).to eq(16.0)

      ucd = doc["findings"].find { |f| f["rule"] == "UseCaseDividend" }
      expect(ucd).to include("severity" => "warn", "file" => REDEEM_FILE_G,
                             "symbol" => REDEEM_EP_G)
      expect(component_value(ucd, "dividend")).to eq(65_536)

      lines = doc["calibration"]["lines"]
      expect(lines).to include(a_string_matching(/use case\(s\) contain a node above the Q4 boundary/))
      expect(lines).to include(a_string_matching(/×65536/))

      expect(doc["summary"]["counts"]["warn"]).to be >= 2 # warns change nothing at error
    end
  end

  it "gate #2146 (clean net-new profile): zero errors, RS 2/2, honest L-RS, exit 0" do
    entry = archive_entry
    skip "ARCHBUDDY_STUDY_REPOS without #{ARCHIVE} — #2146 CLI gate skipped" if entry.nil?

    base_cache = base_cache_for(BASE_2146_G)

    with_worktree(entry.path, MERGE_2146_G) do |target|
      doc, exit_code = run_shipped_diff(target, BASE_2146_G,
                                        base_cache: base_cache,
                                        config: fixture_config("gate_default.yml"))
      expect(exit_code).to eq(0)
      expect(doc["summary"]["counts"]["error"]).to eq(0)
      expect(doc["summary"]["counts"]["warn"]).to eq(0) # no Q4 node; div 1.0/2.0 < 32
      expect(doc["summary"]["delta"]["nodes_new"]).to eq(2)
      expect(doc["summary"]["delta"]["net_log2_b_own"]).to eq(1.0)

      expect(doc["review_surface"]["union"]).to eq(2)
      expect(doc["review_surface"]["sum"]).to eq(2)
      eps = doc["review_surface"]["eps"].sort_by { |row| row["ep_symbol"] }
      expect(eps.map { |row| row["ep_symbol"] })
        .to eq(%w[Api::V1::SegmentActivationPreferences#GET[0]
                  Api::V1::SegmentActivationPreferences#PATCH[0]])
      expect(eps.map { |row| row["classification"] }).to eq(%w[NEW NEW])
      expect(eps.map { |row| row["branching_log2"] }).to eq([0.0, 1.0])

      lines = doc["calibration"]["lines"]
      expect(lines).not_to include(a_string_matching(/Q4 boundary/)) # no L-UC-Q4
      expect(lines).not_to include(a_string_matching(/variety that exists only because/)) # no L-DIV
      # R-HONEST-2's CLI-observable form: the L-RS line quotes no study value
      # (q4_count 0) — NO provenance suffix.
      expect(lines).to include("re-verify 2 use case(s) to land this change")
    end
  end
end
