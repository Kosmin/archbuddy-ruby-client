# frozen_string_literal: true

require "tmpdir"
require "fileutils"
require "stringio"
require "archbuddy/cli"
require "archbuddy/cli/analyze"

# R2: the `analyze` CLI command scores the collected graph.yml (engine) and
# writes the committed real-name cache (de-anon-at-write). It is registered, and
# it errors loudly (does not silently pass) when there is no graph.yml to score.
RSpec.describe "Archbuddy::CLI::Analyze (R2)" do
  it "registers as a CLI command" do
    expect(Archbuddy::CLI.get(["analyze"]).command).to eq(Archbuddy::CLI::Analyze)
  end

  it "errors (exit 1) with a producer hint when there is no graph.yml to score" do
    Dir.mktmpdir do |dir|
      err = StringIO.new
      orig = $stderr
      $stderr = err
      code = nil
      Dir.chdir(dir) do
        begin
          Archbuddy::CLI::Analyze.new.call
        rescue SystemExit => e
          code = e.status
        end
      end
      expect(code).to eq(1)
      expect(err.string).to include("no .archbuddy/graph.yml")
      expect(err.string).to include("archbuddy collect")
    ensure
      $stderr = orig
    end
  end

  # v0.16 T11: the engine shell-out ladder is delegated to the shared
  # Archbuddy::EngineRunner — behavior-identical here: EngineRunner raises,
  # and THIS command keeps its historical `exit 1` contract + pinned message
  # at the CLI layer (the diff transport maps the same error to exit 2).
  it "keeps the exit-1 contract when the delegated engine run fails (T11 EngineRunner seam)" do
    Dir.mktmpdir do |dir|
      FileUtils.mkdir_p(File.join(dir, ".archbuddy"))
      File.write(File.join(dir, ".archbuddy/graph.yml"), "nodes: []\n")
      allow(Archbuddy::EngineRunner).to receive(:analyze)
        .and_raise(Archbuddy::EngineRunner::EngineError, "ladder exhausted")

      err = StringIO.new
      orig = $stderr
      $stderr = err
      code = nil
      Dir.chdir(dir) do
        begin
          Archbuddy::CLI::Analyze.new.call
        rescue SystemExit => e
          code = e.status
        end
      end
      expect(code).to eq(1)
      expect(err.string).to include(
        "error: engine `architecture-auditor analyze` failed — cannot write the committed cache"
      )
      real = File.realpath(dir) # macOS /var → /private/var (Dir.pwd resolves)
      expect(Archbuddy::EngineRunner).to have_received(:analyze)
        .with(File.join(real, ".archbuddy/graph.yml"),
              out: File.join(real, ".archbuddy/findings.yml"))
    ensure
      $stderr = orig
    end
  end
end
