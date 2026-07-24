# frozen_string_literal: true

require "tmpdir"
require "fileutils"
require "digest"
require "open3"
require "archbuddy/review"
require "archbuddy/review/collector"

# v0.15 P2-T5: Review::Collector — collect to scratch, ZERO target mutation.
RSpec.describe Archbuddy::Review::Collector do
  SAMPLE = File.expand_path("../fixtures/sample", __dir__)

  def tree_hash(root)
    Dir.glob(File.join(root, "**", "*"), File::FNM_DOTMATCH)
       .select { |p| File.file?(p) }
       .sort
       .map { |p| [p.delete_prefix(root), Digest::SHA256.hexdigest(File.read(p))] }
  end

  it "writes the vintage into write_root and FragmentWalk reads >= 1 node" do
    Dir.mktmpdir do |write_root|
      described_class.collect(source_root: SAMPLE, write_root: write_root)

      expect(File).to exist(File.join(write_root, "archbuddy-findings.json"))
      expect(File.directory?(File.join(write_root, ".archbuddy"))).to be(true)

      vintage = Archbuddy::Review::FragmentWalk.read(write_root)
      expect(vintage.node_count).to be >= 1
    end
  end

  it "leaves the SOURCE tree byte-identical (zero-mutation observable)" do
    Dir.mktmpdir do |write_root|
      before = tree_hash(SAMPLE)
      described_class.collect(source_root: SAMPLE, write_root: write_root)
      expect(tree_hash(SAMPLE)).to eq(before)
    end
  end

  it "never touches .git/info/exclude in a git-controlled source" do
    Dir.mktmpdir do |dir|
      source = File.join(dir, "src")
      FileUtils.mkdir_p(source)
      FileUtils.cp_r(Dir[File.join(SAMPLE, "*")], source)
      env = { "GIT_CONFIG_GLOBAL" => "/dev/null", "GIT_CONFIG_SYSTEM" => "/dev/null" }
      Open3.capture3(env, "git", "-C", source, "init", "-q")
      exclude = File.join(source, ".git", "info", "exclude")
      before = File.exist?(exclude) ? File.read(exclude) : nil

      Dir.mktmpdir do |write_root|
        described_class.collect(source_root: source, write_root: write_root)
      end

      after = File.exist?(exclude) ? File.read(exclude) : nil
      expect(after).to eq(before)
    end
  end

  it "keeps the id-map inside scratch (born and dies there)" do
    Dir.mktmpdir do |write_root|
      described_class.collect(source_root: SAMPLE, write_root: write_root)
      expect(File).to exist(File.join(write_root, ".archbuddy", "id-map.yml"))
      expect(Dir.glob(File.join(SAMPLE, "**", "id-map*"))).to eq([])
    end
  end

  describe "degenerate / empty-input behavior" do
    it "raises VintageError on a dir with zero enumerable sources" do
      Dir.mktmpdir do |empty_source|
        Dir.mktmpdir do |write_root|
          expect do
            described_class.collect(source_root: empty_source, write_root: write_root)
          end.to raise_error(Archbuddy::Review::VintageError, /no scored sources/)
        end
      end
    end
  end
end
