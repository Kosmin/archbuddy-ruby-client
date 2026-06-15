# frozen_string_literal: true

require "tmpdir"
require "fileutils"
require "stringio"
require "archbuddy/cli/collect"

# M3 (client half): the `collect` CLI must emit a clear stderr WARNING when a
# run produces ZERO entrypoints, so the user knows reachability metrics (dead,
# path_length) will be meaningless. The warning is a diagnostic only — it must
# NOT leak into graph.yml or id-map.yml. We do NOT auto-switch strategies.
RSpec.describe "Archbuddy::CLI::Collect zero-entrypoint warning" do
  # A plain module-nested gem: no controllers, no top-level defs. The :default
  # strategy finds NOTHING here.
  NON_RAILS_GEM = <<~RUBY
    module Widgets
      class Builder
        def assemble
          finalize
        end

        def finalize
          1
        end
      end
    end
  RUBY

  # A target WITH an entrypoint under the :default strategy: a top-level def.
  HAS_ENTRYPOINT = <<~RUBY
    def main
      helper
    end

    def helper
      1
    end
  RUBY

  def run_collect(source:, entrypoints: "default")
    Dir.mktmpdir do |dir|
      File.write(File.join(dir, "lib.rb"), source)
      out_dir = File.join(dir, "out")

      stderr = StringIO.new
      orig_stderr = $stderr
      $stderr = stderr
      begin
        Archbuddy::CLI::Collect.new.call(
          path:               dir,
          out_dir:            out_dir,
          language:           "ruby",
          entrypoints:        entrypoints,
          entrypoint_pattern: []
        )
      ensure
        $stderr = orig_stderr
      end

      yield(stderr.string, out_dir)
    end
  end

  it "warns on stderr when ZERO entrypoints are detected" do
    run_collect(source: NON_RAILS_GEM) do |err, _out|
      expect(err).to include("warning: no entrypoints detected with strategy 'default'")
      expect(err).to include("Reachability metrics (dead, path_length) will be unavailable")
      expect(err).to include("--entrypoints all_public")
    end
  end

  it "names the actual strategy used in the warning" do
    run_collect(source: NON_RAILS_GEM, entrypoints: "controllers") do |err, _out|
      expect(err).to include("warning: no entrypoints detected with strategy 'controllers'")
    end
  end

  it "does NOT warn when entrypoints ARE detected" do
    run_collect(source: HAS_ENTRYPOINT) do |err, _out|
      expect(err).not_to include("warning: no entrypoints detected")
    end
  end

  it "keeps the warning OUT of graph.yml and id-map.yml" do
    run_collect(source: NON_RAILS_GEM) do |_err, out_dir|
      graph  = File.read(File.join(out_dir, "graph.yml"))
      id_map = File.read(File.join(out_dir, "id-map.yml"))

      [graph, id_map].each do |content|
        expect(content).not_to include("no entrypoints detected")
        expect(content).not_to include("Reachability metrics")
        expect(content).not_to match(/^\s*warning:/)
      end
    end
  end
end
