# frozen_string_literal: true

require "archbuddy/cache"
require "tmpdir"
require "fileutils"

# C3-1a: `reset` = full re-collect (mode :full, ignore the speed cache) + full
# analyze from scratch. The full-mode contract is what makes reset a from-scratch
# rebuild: even with a fully-primed, hash-matching cache, :full re-parses every
# file (it never consults the Reader), so a model/tool change is picked up.
RSpec.describe "reset full re-collect semantics (C3-1a)" do
  let(:config) { Archbuddy::Collect::Config.new(language: "ruby") }

  def seed(dir)
    FileUtils.mkdir_p(File.join(dir, "app"))
    File.write(File.join(dir, "app/a.rb"), "class A\n  def run\n    1\n  end\nend\n")
    File.write(File.join(dir, "app/b.rb"), "class B\n  def go\n    2\n  end\nend\n")
  end

  it "mode :full re-parses every file even when a valid cache exists (reset semantics)" do
    Dir.mktmpdir do |dir|
      seed(dir)
      adapter = Archbuddy::Collect::Registry.for("ruby").new(dir, config)
      adapter.collect(mode: :incremental) # prime the .cache/

      # :full must NOT reuse the primed cache — it re-parses all files.
      expect(Prism).to receive(:parse).twice.and_call_original
      adapter.collect(mode: :full)
    end
  end

  it "reset registers as a CLI command" do
    require "archbuddy/cli"
    expect(Archbuddy::CLI.get(["reset"]).command).to eq(Archbuddy::CLI::Reset)
  end

  it "full-mode result equals incremental result on an unchanged tree (reset == steady state)" do
    Dir.mktmpdir do |dir|
      seed(dir)
      adapter = Archbuddy::Collect::Registry.for("ruby").new(dir, config)
      adapter.collect(mode: :incremental) # prime

      serialize = ->(r) { Archbuddy::Collect::Anonymizer.new(r, tool: "t", adapter: "ruby").call.graph }

      full = serialize.call(adapter.collect(mode: :full))
      incr = serialize.call(adapter.collect(mode: :incremental))
      expect(incr).to eq(full)
    end
  end
end
