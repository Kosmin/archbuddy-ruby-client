# frozen_string_literal: true

require "tmpdir"
require "fileutils"
require "stringio"
require "json"
require "archbuddy/review"
require "archbuddy/cache/detail_tree"

# v0.15 P2-T1: the A6 fragment-walk reader — pointer-driven, (file, symbol)
# attribution, evaluability by key presence, exported-layout fallback, loud
# corrupt-file exclusion.
RSpec.describe Archbuddy::Review::FragmentWalk do
  FIXTURES = File.expand_path("../fixtures/review/vintages", __dir__)

  def read_capturing_stderr(root)
    stderr = StringIO.new
    orig = $stderr
    $stderr = stderr
    begin
      vintage = described_class.read(root)
    ensure
      $stderr = orig
    end
    [vintage, stderr.string]
  end

  describe "v5_small (13-key nodes, per_class shard dir)" do
    let(:vintage) { read_capturing_stderr(File.join(FIXTURES, "v5_small")).first }

    it "yields fragment integers and 13-key evaluability" do
      node = vintage["app/api/widgets.rb", "Api::Widgets#GET[0]"]
      expect(node.branches).to eq(4)
      expect(node.keys_present.size).to eq(13)
      expect(node.entrypoint).to be(true)
      expect(node.entrypoint_kind).to eq("grape")
      expect(node.outcome_arity).to eq(2)
      expect(node.toll_booth).to be_nil # collect-only honesty: key present, null
      expect(node.keys_present).to include("toll_booth")
    end

    it "reads 7 nodes across 3 files with 2 eps" do
      expect(vintage.node_count).to eq(7)
      expect(vintage.files).to eq(%w[app/api/widgets.rb app/jobs/sync_job.rb app/models/widget_helper.rb])
      expect(vintage.eps.map(&:symbol).sort).to eq(["Api::Widgets#GET[0]", "SyncJob#perform"])
      expect(vintage.edges?).to be(true)
      expect(vintage.meta[:sources_count]).to eq(3)
      expect(vintage.meta[:serializer_versions]).to eq([5])
    end

    it "attributes shard-dir nodes to the SHARDED FILE's path (the reassemble drop)" do
      %w[Api::WidgetHelper#lookup Api::WidgetOther#noop].each do |sym|
        expect(vintage["app/models/widget_helper.rb", sym]).not_to be_nil
      end

      # DetailTree#reassemble drops file attribution — its node hashes carry
      # no file key at all; the fragment walk keeps it.
      reassembled = Archbuddy::Cache::DetailTree
                    .new(project_root: File.join(FIXTURES, "v5_small"))
                    .reassemble
      shard_node = reassembled["nodes"].find { |n| n["symbol"] == "Api::WidgetHelper#lookup" }
      expect(shard_node).not_to be_nil
      expect(shard_node).not_to have_key("file")
    end
  end

  describe "v4_small / v1_small key-presence evaluability" do
    it "v4 nodes lack compass keys (9 keys present)" do
      vintage = read_capturing_stderr(File.join(FIXTURES, "v4_small")).first
      node = vintage["lib/orders.rb", "Orders#place"]
      expect(node.keys_present.size).to eq(9)
      expect(node.keys_present).not_to include("toll_booth")
      expect(node.escapes).to be(false)
      expect(vintage.edges?).to be(true)
    end

    it "v1 nodes carry 6 keys and no edges" do
      vintage = read_capturing_stderr(File.join(FIXTURES, "v1_small")).first
      node = vintage["lib/legacy.rb", "Legacy#run"]
      expect(node.keys_present.size).to eq(6)
      expect(node.escapes).to be_nil
      expect(node.outcome_arity).to be_nil
      expect(vintage.edges?).to be(false)
    end
  end

  describe "orphaned fixture (pointer-driven proof)" do
    it "never ingests an on-disk fragment absent from sources" do
      vintage = read_capturing_stderr(File.join(FIXTURES, "orphaned")).first
      expect(vintage["lib/pointed.rb", "Pointed#run"]).not_to be_nil
      expect(vintage.by_identity.keys.map(&:last)).not_to include("Orphan#ghost")
      expect(vintage.node_count).to eq(1)
    end
  end

  describe "corrupt fixture (whole-file exclusion, loud)" do
    it "excludes the file, records it, and warns" do
      vintage, stderr = read_capturing_stderr(File.join(FIXTURES, "corrupt"))
      expect(vintage.corrupt_files).to eq(["lib/bad.rb"])
      expect(vintage.by_identity.keys.map(&:first)).not_to include("lib/bad.rb")
      expect(vintage["lib/good.rb", "Good#ok"]).not_to be_nil
      expect(stderr).to match(/^warning: unreadable fragment for lib\/bad\.rb — file excluded from review$/)
    end
  end

  describe "exported layout (dotted pointers, un-dotted disk)" do
    it "prefix-swaps and matches the dotted twin's node set, one note" do
      vintage, stderr = read_capturing_stderr(File.join(FIXTURES, "exported_layout"))
      expect(stderr.scan(/^note: reading detail tree from 'archbuddy\/' \(exported layout\)$/).size).to eq(1)

      # Build the dotted-layout twin in a tmpdir and compare node sets.
      Dir.mktmpdir do |dir|
        FileUtils.cp(File.join(FIXTURES, "exported_layout", "archbuddy-findings.json"),
                     File.join(dir, "archbuddy-findings.json"))
        src = File.join(FIXTURES, "exported_layout", "archbuddy")
        FileUtils.mkdir_p(File.join(dir, ".archbuddy"))
        FileUtils.cp_r(Dir[File.join(src, "*")], File.join(dir, ".archbuddy"))

        twin, twin_stderr = read_capturing_stderr(dir)
        expect(vintage.node_count).to eq(twin.node_count)
        expect(vintage.by_identity.keys.sort).to eq(twin.by_identity.keys.sort)
        expect(twin_stderr).not_to include("exported layout")
      end
    end
  end

  describe "zero_ep fixture (the Q8 degenerate seed)" do
    it "reads a valid ep-less vintage silently — honesty is downstream's duty" do
      vintage, stderr = read_capturing_stderr(File.join(FIXTURES, "zero_ep"))
      expect(vintage.eps).to eq([])
      expect(vintage.nodes.size).to be >= 2
      expect(vintage.edges?).to be(true)
      expect(stderr).to eq("")
    end
  end

  describe "degenerate / empty-input behavior" do
    it "sources: {} yields a legal empty vintage, no error" do
      Dir.mktmpdir do |dir|
        File.write(File.join(dir, "archbuddy-findings.json"),
                   JSON.generate("serializer_version" => 5, "sources" => {}))
        vintage, = read_capturing_stderr(dir)
        expect(vintage).to be_empty
        expect(vintage.nodes).to eq([])
      end
    end

    it "missing aggregate raises VintageError (exit 2 at the CLI)" do
      Dir.mktmpdir do |dir|
        expect { described_class.read(dir) }
          .to raise_error(Archbuddy::Review::VintageError, /no readable archbuddy-findings\.json at/)
      end
    end

    it "unparseable aggregate raises VintageError" do
      Dir.mktmpdir do |dir|
        File.write(File.join(dir, "archbuddy-findings.json"), "{nope")
        expect { described_class.read(dir) }
          .to raise_error(Archbuddy::Review::VintageError, /no readable archbuddy-findings\.json/)
      end
    end

    it "warns once about nodes without branch data (kept, excluded from log2 math)" do
      Dir.mktmpdir do |dir|
        File.write(File.join(dir, "archbuddy-findings.json"), JSON.generate(
                                                                "serializer_version" => 5,
                                                                "sources" => { "x.rb" => { "path" => ".archbuddy/x.rb.json", "shard_mode" => "single" } }
                                                              ))
        FileUtils.mkdir_p(File.join(dir, ".archbuddy"))
        File.write(File.join(dir, ".archbuddy/x.rb.json"), JSON.generate(
                                                             "serializer_version" => 5, "file" => "x.rb",
                                                             "nodes" => [
                                                               { "symbol" => "X#a", "branches" => nil },
                                                               { "symbol" => "X#b", "branches" => 0 },
                                                               { "symbol" => "X#c", "branches" => 2 }
                                                             ], "edges" => []
                                                           ))
        vintage, stderr = read_capturing_stderr(dir)
        expect(vintage.node_count).to eq(3) # kept
        expect(stderr.scan(/^warning: 2 node\(s\) without branch data — excluded from delta math$/).size).to eq(1)
      end
    end
  end
end
