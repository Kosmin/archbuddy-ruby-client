# frozen_string_literal: true

require "tmpdir"
require "json"
require "stringio"
require "fileutils"
require "archbuddy/cli"

# v0.15 P1-T7: the lint exit contract — L3 advisory default, gating by
# config-file presence, --advisory/--fail-level overrides, and every
# exit-2 path with EMPTY stdout.
RSpec.describe "archbuddy lint exit codes" do
  def build_fixture(dir)
    FileUtils.mkdir_p(File.join(dir, "app"))
    File.write(File.join(dir, "app", "main.rb"), <<~RUBY)
      class FooController
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

  it "exits 0 with no config (L3 advisory), 1 once `version: 1` gates" do
    Dir.mktmpdir do |dir|
      build_fixture(dir)
      expect(run_lint(target: dir).first).to eq(0)

      File.write(File.join(dir, ".archbuddy.yml"), "version: 1\n")
      expect(run_lint(target: dir).first).to eq(1) # the EN error finding gates
    end
  end

  it "--advisory and --fail-level none suppress the gate" do
    Dir.mktmpdir do |dir|
      build_fixture(dir)
      File.write(File.join(dir, ".archbuddy.yml"), "version: 1\n")
      expect(run_lint(target: dir, advisory: true).first).to eq(0)
      expect(run_lint(target: dir, fail_level: "none").first).to eq(0)
    end
  end

  describe "exit-2 paths (pinned stderr, EMPTY stdout)" do
    it "rejects an unknown --format" do
      Dir.mktmpdir do |dir|
        build_fixture(dir)
        code, stdout, stderr = run_lint(target: dir, format: "bogus")
        expect(code).to eq(2)
        expect(stdout).to eq("")
        expect(stderr).to include("error: unknown format 'bogus' (terminal|markdown|json)")
      end
    end

    it "rejects an unknown --fail-level" do
      Dir.mktmpdir do |dir|
        build_fixture(dir)
        code, stdout, stderr = run_lint(target: dir, fail_level: "bogus")
        expect(code).to eq(2)
        expect(stdout).to eq("")
        expect(stderr).to include("error: unknown fail level 'bogus' (none|info|warn|error)")
      end
    end

    it "rejects --todo combined with --no-todo" do
      Dir.mktmpdir do |dir|
        build_fixture(dir)
        code, stdout, stderr = run_lint(target: dir, todo: "x.yml", no_todo: true)
        expect(code).to eq(2)
        expect(stdout).to eq("")
        expect(stderr).to include("error: --todo and --no-todo are mutually exclusive")
      end
    end

    it "rejects a nonexistent target" do
      code, stdout, stderr = run_lint(target: "/nonexistent/nowhere")
      expect(code).to eq(2)
      expect(stdout).to eq("")
      expect(stderr).to start_with("error:")
      expect(stderr).to include("is not a directory")
    end

    it "exits 2 when no vintage is acquirable (no cache, no collectable sources)" do
      Dir.mktmpdir do |dir|
        code, stdout, stderr = run_lint(target: dir)
        expect(code).to eq(2)
        expect(stdout).to eq("")
        expect(stderr).to match(/error:.*no scored sources/)
      end
    end

    it "surfaces config validation errors (retired-name guidance)" do
      Dir.mktmpdir do |dir|
        build_fixture(dir)
        File.write(File.join(dir, ".archbuddy.yml"),
                   "version: 1\nrules:\n  MaxFanIn: {}\n")
        code, stdout, stderr = run_lint(target: dir)
        expect(code).to eq(2)
        expect(stdout).to eq("")
        expect(stderr).to start_with("error:")
      end
    end
  end

  it "json exit_code field equals the process status both ways" do
    Dir.mktmpdir do |dir|
      build_fixture(dir)
      code, stdout, = run_lint(target: dir, format: "json")
      expect(code).to eq(0)
      expect(JSON.parse(stdout)["exit_code"]).to eq(0)

      File.write(File.join(dir, ".archbuddy.yml"), "version: 1\n")
      code, stdout, = run_lint(target: dir, format: "json")
      expect(code).to eq(1)
      expect(JSON.parse(stdout)["exit_code"]).to eq(1)
    end
  end
end
