# frozen_string_literal: true

require "tmpdir"
require "fileutils"

# C1 CORRECTION (value-level line stability — REQUIRED, the completion of E0):
# committed-cache VALUES carry NO line-derived field. Inserting a blank line
# above a method must leave `git status .archbuddy/ archbuddy-findings.json`
# CLEAN (zero diff). This proves a cosmetic edit does not churn the committed
# cache and does not trip the `--check` CI gate.
RSpec.describe "committed cache is clean after a blank-line insert (C1)" do
  let(:fixture_root) { File.expand_path("../fixtures/sample", __dir__) }
  let(:config)       { Archbuddy::Collect::Config.new(language: "ruby") }

  # Run a full collect (fragment build + de-anon-at-write committed layout) with
  # the audited project root = `dir`.
  def collect_into(dir)
    adapter = Archbuddy::Collect::Registry.for("ruby").new(dir, config)
    anon = Archbuddy::Collect::Anonymizer.new(
      adapter.collect, tool: "archbuddy test", adapter: "ruby"
    ).call
    Archbuddy::Collect::Emitter.new(out_dir: File.join(dir, ".archbuddy"), project_root: dir)
                               .emit(graph: anon.graph, id_map: anon.id_map)
  end

  def git(dir, *args)
    out = IO.popen(["git", "-C", dir, *args], &:read)
    raise "git #{args.join(' ')} failed" unless $?.success?

    out
  end

  it "leaves the committed cache byte-identical (clean git status) after a pure line move" do
    Dir.mktmpdir do |dir|
      FileUtils.cp_r(Dir.glob("#{fixture_root}/*"), dir)
      git(dir, "init", "-q")
      git(dir, "config", "user.email", "t@t")
      git(dir, "config", "user.name", "t")

      # First collect → commit the real-name cache (id-map + .cache excluded).
      collect_into(dir)
      File.write(File.join(dir, ".gitignore"), ".archbuddy/id-map.yml\n.archbuddy/.cache/\n.archbuddy/graph.yml\n.archbuddy/*.yml\n")
      git(dir, "add", "-A")
      git(dir, "commit", "-qm", "baseline cache")

      # Insert a blank line above a method — a pure cosmetic line move.
      target = File.join(dir, "app/models/invoice.rb")
      src = File.read(target).sub("    def self.overdue", "\n    def self.overdue")
      File.write(target, src)

      # Re-collect and check the committed cache diff.
      collect_into(dir)
      status = git(dir, "status", "--porcelain", ".archbuddy", "archbuddy-findings.json")

      expect(status).to eq(""), "expected clean committed cache, got:\n#{status}"
    end
  end
end
