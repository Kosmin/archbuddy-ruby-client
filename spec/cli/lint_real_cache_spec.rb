# frozen_string_literal: true

require "json"
require "yaml"
require "open3"
require "archbuddy"

# v0.15 P1-T9: the app-management real-cache worked example, env-gated
# (ARCHBUDDY_PROBE_APP_MANAGEMENT=1 + the path present). Every number is a
# SAME-MOMENT independent recount of the probe's own cache — never a
# hardcoded plan-time value ([S] posture; V15-F8: the unreachable
# cross-check reads .archbuddy/findings.yml per-node `metrics.dead`, NOT
# the aggregate). The probe repo is READ-ONLY: --trust-cache reads the
# existing cache; porcelain identity is asserted before/after.
RSpec.describe "lint on the app-management committed cache (env-gated)" do
  CLIENT_ROOT_RC = File.expand_path("../..", __dir__)
  PROBE = "/Users/cosmin2/Projects/app-management"

  def probe_enabled?
    ENV["ARCHBUDDY_PROBE_APP_MANAGEMENT"] == "1" && File.directory?(PROBE) &&
      File.file?(File.join(PROBE, "archbuddy-findings.json"))
  end

  def run_exe(*args)
    env = { "ARCHITECTURE_AUDITOR_PATH" => ENV.fetch("ARCHITECTURE_AUDITOR_PATH", nil) }.compact
    stdout, stderr, status = Open3.capture3(
      env, RbConfig.ruby, File.join(CLIENT_ROOT_RC, "exe", "archbuddy"),
      "lint", PROBE, "--trust-cache", *args, chdir: CLIENT_ROOT_RC
    )
    [stdout.force_encoding("UTF-8"), stderr.force_encoding("UTF-8"), status.exitstatus]
  end

  def porcelain
    out, _err, _status = Open3.capture3("git", "-C", PROBE, "status", "--porcelain")
    out
  end

  # Independent ep recount over the cache's own fragment JSONs (pointer-
  # driven; never opens id-map or the engine YAMLs beyond findings.yml).
  def independent_ep_count(aggregate)
    aggregate["sources"].values.sum do |src|
      path = File.join(PROBE, src["path"])
      fragments = File.directory?(path) ? Dir[File.join(path, "*.json")] : [path]
      fragments.sum do |fragment|
        doc = JSON.parse(File.read(fragment, encoding: "UTF-8"))
        (doc["nodes"] || []).count { |n| n["entrypoint"] == true }
      end
    end
  end

  # V15-F8: count findings.yml n_* rows with metrics.dead == 1 (the
  # engine-side per-node stat — NOT any aggregate figure).
  def independent_dead_counts
    doc = YAML.safe_load(File.read(File.join(PROBE, ".archbuddy/findings.yml"),
                                   encoding: "UTF-8"), permitted_classes: [Symbol])
    nodes = doc["nodes"] || doc
    n_keys = nodes.keys.select { |k| k.to_s.start_with?("n_") }
    dead = n_keys.count { |k| nodes[k].is_a?(Hash) && nodes[k].dig("metrics", "dead") == 1 }
    [dead, n_keys.size]
  end

  it "reproduces the worked example with same-moment independent recounts" do
    skip "ARCHBUDDY_PROBE_APP_MANAGEMENT != 1 or probe cache absent — example skipped" unless probe_enabled?

    before = porcelain
    stdout, stderr, code = run_exe("--format", "json")

    expect(code).to eq(0) # no .archbuddy.yml → advisory
    expect(stderr).to include("warning:") # the loud --trust-cache warning
    expect(stderr).not_to include("\"schema\"") # no report content on stderr
    expect(stdout[0]).to eq("{")
    doc = JSON.parse(stdout)

    expect(doc["schema"]).to eq("archbuddy-diff-report/1")
    expect(doc["run"]["command"]).to eq("lint")
    expect(doc).not_to have_key("delta")
    expect(doc).not_to have_key("ratchet")

    aggregate = JSON.parse(File.read(File.join(PROBE, "archbuddy-findings.json"),
                                     encoding: "UTF-8"))
    expect(doc["tool"]["serializer"]).to eq(5)
    expect(aggregate["serializer_version"]).to eq(5)
    expect(doc["run"]["head"]["sources_count"]).to eq(aggregate["sources"].size) # [S:F5]

    expect(doc["use_cases"]["count"]).to eq(independent_ep_count(aggregate))

    dead, total = independent_dead_counts
    unreachable = doc["summary"]["unreachable_from_entrypoints"]
    expect(unreachable["nodes"]).to eq(dead) # V15-F8: findings.yml metrics.dead
    expect(unreachable["share"]).to eq((dead.to_f / total).round(4))

    rows = doc["use_cases"]["leaderboard"]
    expect(rows).not_to be_empty
    expect(rows.map { |r| r["branching_log2"] })
      .to eq(rows.map { |r| r["branching_log2"] }.sort.reverse) # DESC

    # terminal rerun: problem-matcher-friendly finding lines (P5)
    stdout, _stderr, code = run_exe
    expect(code).to eq(0)
    finding_lines = stdout.lines.grep(/\[[A-Za-z]+\] (info|warn|error): /)
    finding_lines.each do |line|
      expect(line).to match(/^\S+: \S.* \[[A-Za-z]+\] (info|warn|error): /)
    end

    expect(porcelain).to eq(before) # read-only proof
  end
end
