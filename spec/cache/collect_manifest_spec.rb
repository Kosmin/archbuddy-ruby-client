# frozen_string_literal: true

require "tmpdir"
require "fileutils"
require "json"
require "open3"
require "stringio"
require "archbuddy/cache/collect_manifest"
require "archbuddy/cli/collect"

# v0.15 P2-T6: Cache::CollectManifest — exact, mtime-free head freshness (P6).
RSpec.describe Archbuddy::Cache::CollectManifest do
  SOURCE = <<~RUBY
    def main
      helper
    end

    def helper
      1
    end
  RUBY

  def run_collect(dir)
    stderr = StringIO.new
    orig = $stderr
    $stderr = stderr
    begin
      Archbuddy::CLI::Collect.new.call(
        path: dir, language: "ruby", entrypoints: "default", entrypoint_pattern: []
      )
    ensure
      $stderr = orig
    end
  end

  def with_fixture_app
    Dir.mktmpdir do |dir|
      File.write(File.join(dir, "lib.rb"), SOURCE)
      yield dir
    end
  end

  it "writes the manifest at the pinned speed-cache path after collect" do
    with_fixture_app do |dir|
      run_collect(dir)
      path = File.join(dir, ".archbuddy", ".cache", "collect-manifest.json")
      expect(File).to exist(path)

      doc = JSON.parse(File.read(path))
      expect(doc["collector_version"]).to eq(Archbuddy::Cache::Reader::COLLECTOR_VERSION)
      expect(doc["serializer_version"]).to eq(Archbuddy::Cache::Writer::SERIALIZER_VERSION)
      expect(doc["files"].keys).to eq(["lib.rb"])
    end
  end

  it "is byte-deterministic across consecutive collects" do
    with_fixture_app do |dir|
      run_collect(dir)
      path = File.join(dir, ".archbuddy", ".cache", "collect-manifest.json")
      first = File.read(path)
      run_collect(dir)
      expect(File.read(path)).to eq(first)
    end
  end

  describe ".fresh? (mtime-free proof)" do
    it "true after collect; edit → false; revert (identical bytes) → true" do
      with_fixture_app do |dir|
        run_collect(dir)
        expect(described_class.fresh?(project_root: dir)).to be(true)

        original = File.read(File.join(dir, "lib.rb"))
        File.write(File.join(dir, "lib.rb"), "#{original}\n# changed\n")
        expect(described_class.fresh?(project_root: dir)).to be(false)

        File.write(File.join(dir, "lib.rb"), original)
        expect(described_class.fresh?(project_root: dir)).to be(true)
      end
    end

    it "false when a new enumerable file appears" do
      with_fixture_app do |dir|
        run_collect(dir)
        File.write(File.join(dir, "extra.rb"), "def extra; 2; end\n")
        expect(described_class.fresh?(project_root: dir)).to be(false)
      end
    end

    it "false when a manifest-listed file is deleted" do
      with_fixture_app do |dir|
        File.write(File.join(dir, "second.rb"), "def second; 3; end\n")
        run_collect(dir)
        FileUtils.rm(File.join(dir, "second.rb"))
        expect(described_class.fresh?(project_root: dir)).to be(false)
      end
    end

    it "false when the manifest is absent, unparseable, or version-mismatched" do
      with_fixture_app do |dir|
        expect(described_class.fresh?(project_root: dir)).to be(false)

        run_collect(dir)
        path = described_class.path(dir)

        File.write(path, "{nope")
        expect(described_class.fresh?(project_root: dir)).to be(false)

        doc = { "collector_version" => -1,
                "serializer_version" => Archbuddy::Cache::Writer::SERIALIZER_VERSION,
                "files" => {} }
        File.write(path, JSON.generate(doc))
        expect(described_class.fresh?(project_root: dir)).to be(false)
      end
    end

    it "false for an empty files map against a non-empty enumeration" do
      with_fixture_app do |dir|
        run_collect(dir)
        doc = JSON.parse(File.read(described_class.path(dir)))
        doc["files"] = {}
        File.write(described_class.path(dir), JSON.generate(doc))
        expect(described_class.fresh?(project_root: dir)).to be(false)
      end
    end
  end

  it "is matched by the .archbuddy/.cache/ local exclude (git check-ignore)" do
    with_fixture_app do |dir|
      env = { "GIT_CONFIG_GLOBAL" => "/dev/null", "GIT_CONFIG_SYSTEM" => "/dev/null" }
      Open3.capture3(env, "git", "-C", dir, "init", "-q")
      run_collect(dir)
      out, _err, status = Open3.capture3(
        env, "git", "-C", dir, "check-ignore", ".archbuddy/.cache/collect-manifest.json"
      )
      expect(status.success?).to be(true)
      expect(out.strip).not_to be_empty
    end
  end

  it "leaves the COMMITTED cache bytes unchanged by the manifest write" do
    with_fixture_app do |dir|
      run_collect(dir)
      committed = Dir.glob(File.join(dir, ".archbuddy", "**", "*.json"))
                     .reject { |p| p.include?("/.cache/") }
                     .sort
                     .map { |p| [p, File.read(p)] }
      aggregate = File.read(File.join(dir, "archbuddy-findings.json"))

      run_collect(dir)
      committed.each { |path, bytes| expect(File.read(path)).to eq(bytes) }
      expect(File.read(File.join(dir, "archbuddy-findings.json"))).to eq(aggregate)
    end
  end
end
