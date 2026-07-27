# frozen_string_literal: true

require "tmpdir"
require "json"
require "stringio"
require "fileutils"
require "archbuddy/cli"

# v0.15 P1-T8: `--auto-gen-todo` + the ep-granular 6-step lifecycle on the
# T7 controller fixture (gen → skip → grow → re-fire → heal → regen), the
# V15-F3 FirewallBreaches gen row, and the carried [S] degenerates.
RSpec.describe "lint --auto-gen-todo lifecycle" do
  # Guard-style single-outcome action with `decisions` if-guards →
  # branches 2^decisions, V_floor 1 (dividend = 2^decisions).
  def build_fixture(dir, decisions: 6, klass: "FooController")
    FileUtils.mkdir_p(File.join(dir, "app"))
    guards = (1..decisions).map { |i| "    x = #{i} if p#{i}" }.join("\n")
    File.write(File.join(dir, "app", "main.rb"), <<~RUBY)
      class #{klass}
        def show
      #{guards}
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
      Archbuddy::CLI::Lint.new.call(**kwargs)
    rescue SystemExit => e
      code = e.status
    ensure
      $stdout = orig_out
      $stderr = orig_err
    end
    [code, out.string, err.string]
  end

  def todo_path(dir) = File.join(dir, ".archbuddy_todo.yml")

  it "walks the ep-granular 6-step lifecycle ([D1] P1-T8)" do
    Dir.mktmpdir do |dir|
      build_fixture(dir, decisions: 6)
      File.write(File.join(dir, ".archbuddy.yml"), "version: 1\n")

      # Step 1 — fresh violations gate (Q11 starter: fail_level error).
      code, stdout, = run_lint(target: dir, format: "json")
      expect(code).to eq(1)
      doc = JSON.parse(stdout)
      rules = doc["findings"].map { |f| f["rule"] }
      expect(rules).to include("ExponentialNode")
      expect(rules).to include("UseCaseComplexity")
      # UseCaseDividend self-consistency vs the leaderboard (never hardcoded).
      dividend = doc["use_cases"]["leaderboard"].fetch(0)["dividend"]
      expect(rules.include?("UseCaseDividend")).to eq(dividend >= 32)

      # Step 2 — gen: breaching components ONLY, milli-log2 integers, no stamp.
      code, _, stderr = run_lint(target: dir, auto_gen_todo: true)
      expect(code).to eq(0) # fresh todo grandfathers everything
      expect(File).to exist(todo_path(dir))
      text = File.read(todo_path(dir))
      expect(text).to include("ExponentialNode:")
      expect(text).to include("value: 64")
      expect(text).to include("UseCaseComplexity:")
      expect(text).to include("values: { max_cone_node_millilog2: 6000 }")
      expect(text).not_to include("branching_millilog2") # non-breaching keys absent
      expect(text).not_to match(/\b(mass|depth|reach|files):\s*\d/)
      expect(text).to include("node_count: 1") # one distinct node string
      expect(text).not_to include("Generated at")
      expect(stderr).to include("note: wrote #{todo_path(dir)}:")

      # Step 3 — everything grandfathered (R35 template), E entries ≥ 2.
      code, stdout, = run_lint(target: dir)
      expect(code).to eq(0)
      match = stdout.match(
        /grandfathered: (\d+) entries \(1 nodes\) across (\d+) rules \(0 healed — regenerate the todo to shrink it\)/
      )
      expect(match).not_to be_nil
      entries = Integer(match[1])
      expect(entries).to be >= 2
      expect(Integer(match[2])).to eq(entries) # one entry per rule here

      # Step 4 — grow to 7 decisions (128 branches): per-metric re-fire
      # (integer predicate 7000 > 6000).
      build_fixture(dir, decisions: 7)
      code, stdout, = run_lint(target: dir)
      expect(code).to eq(1)
      expect(stdout).to include("grew past grandfathered baseline 64 (2^6.0) → 128 (2^7.0)")
      expect(stdout).to include(
        "worst cone node grew past grandfathered baseline 64 (2^6.0) → 128 (2^7.0)"
      )

      # Step 5 — heal to 4 decisions (16 branches, log2 4.0 ≤ 5.0).
      build_fixture(dir, decisions: 4)
      code, stdout, = run_lint(target: dir)
      expect(code).to eq(0)
      expect(stdout).to include("(#{entries} healed")

      # Step 6 — regen shrinks to the empty document.
      code, _, stderr = run_lint(target: dir, auto_gen_todo: true)
      expect(code).to eq(0)
      expect(stderr).to include("note: 0 violations to grandfather")
      text = File.read(todo_path(dir))
      expect(text).to include("rule_count: 0")
      expect(text).to include("node_count: 0")
      code, stdout, = run_lint(target: dir)
      expect(code).to eq(0)
      expect(stdout).not_to include("grandfathered:")
    end
  end

  it "gen records a FirewallBreaches escapes row (V15-F3)" do
    Dir.mktmpdir do |dir|
      build_fixture(dir, decisions: 6)
      # A dynamic meta-send with a non-literal arg → escapes: true on the ep.
      File.write(File.join(dir, "app", "main.rb"), <<~RUBY)
        class FooController
          def show
            name = params
            send(name)
          end
        end
      RUBY
      File.write(File.join(dir, ".archbuddy.yml"), "version: 1\n")

      code, stdout, = run_lint(target: dir, format: "json")
      doc = JSON.parse(stdout)
      fb = doc["findings"].find { |f| f["rule"] == "FirewallBreaches" }
      expect(fb).not_to be_nil
      expect(fb["severity"]).to eq("info") # info both modes (Q11)
      expect(code).to eq(0) # info never gates at fail_level error

      code, = run_lint(target: dir, auto_gen_todo: true)
      expect(code).to eq(0)
      text = File.read(todo_path(dir))
      expect(text).to include("FirewallBreaches:")
      expect(text).to match(/values: \{ escapes: \d+ \}/)

      # and the recorded count skips on re-lint
      _, stdout, = run_lint(target: dir, format: "json")
      doc = JSON.parse(stdout)
      expect(doc["findings"].map { |f| f["rule"] }).not_to include("FirewallBreaches")
    end
  end

  it "--auto-gen-todo --no-todo → exit 2 (contradictory)" do
    Dir.mktmpdir do |dir|
      build_fixture(dir)
      code, stdout, stderr = run_lint(target: dir, auto_gen_todo: true, no_todo: true)
      expect(code).to eq(2)
      expect(stdout).to eq("")
      expect(stderr).to include("error: --auto-gen-todo cannot be combined with --no-todo")
    end
  end

  it "notes todo entries for since-disabled rules (not evaluated)" do
    Dir.mktmpdir do |dir|
      build_fixture(dir, decisions: 6)
      File.write(File.join(dir, ".archbuddy.yml"), "version: 1\n")
      code, = run_lint(target: dir, auto_gen_todo: true)
      expect(code).to eq(0)

      File.write(File.join(dir, ".archbuddy.yml"), <<~YAML)
        version: 1
        rules:
          UseCaseComplexity:
            enabled: false
      YAML
      code, _, stderr = run_lint(target: dir)
      expect(code).to eq(0)
      expect(stderr).to include("note: 1 todo entries for disabled rules (not evaluated)")
    end
  end

  it "zero-ep gen → node-rule entries only, no crash ([D1] degenerate)" do
    Dir.mktmpdir do |dir|
      build_fixture(dir, decisions: 6, klass: "FooService") # no entrypoint
      File.write(File.join(dir, ".archbuddy.yml"), "version: 1\n")
      code, _, stderr = run_lint(target: dir, auto_gen_todo: true)
      expect(code).to eq(0)
      text = File.read(todo_path(dir))
      expect(text).to include("ExponentialNode:")
      expect(text).to include("value: 64")
      expect(text).not_to include("UseCaseComplexity")
      expect(text).not_to include("UseCaseDividend")
      expect(text).not_to include("FirewallBreaches")
      expect(stderr).to include("note: wrote")
    end
  end

  it "gen on a 0-node vintage → empty document + the vintage_empty warning" do
    Dir.mktmpdir do |dir|
      File.write(File.join(dir, "archbuddy-findings.json"),
                 JSON.generate(serializer_version: 5, sources: {}))
      code, _, stderr = run_lint(target: dir, trust_cache: true, auto_gen_todo: true)
      expect(code).to eq(0)
      expect(stderr).to include("warning: vintage contains 0 nodes")
      expect(stderr).to include("note: 0 violations to grandfather")
      text = File.read(todo_path(dir))
      expect(text).to include("rule_count: 0")
      expect(text).to include("rules: {}")
    end
  end
end
