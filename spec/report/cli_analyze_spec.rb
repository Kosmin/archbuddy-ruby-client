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
end
