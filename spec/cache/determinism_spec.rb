# frozen_string_literal: true

require "archbuddy/cache"
require "tmpdir"
require "fileutils"

# C3 (a): the committed cache is DETERMINISTIC — two runs over the same tree
# produce byte-identical committed output (canonical order + fixed float
# precision), so `git status` is clean on the second run (the lockfile idiom).
RSpec.describe "committed cache determinism (C3)" do
  let(:fixture_root) { File.expand_path("../fixtures/sample", __dir__) }
  let(:config)       { Archbuddy::Collect::Config.new(language: "ruby") }

  def collect_and_write(dir)
    adapter = Archbuddy::Collect::Registry.for("ruby").new(dir, config)
    anon = Archbuddy::Collect::Anonymizer.new(
      adapter.collect(mode: :full), tool: "archbuddy test", adapter: "ruby"
    ).call
    Archbuddy::Cache::Writer.new(project_root: dir).write(graph: anon.graph, id_map: anon.id_map)
  end

  def committed_snapshot(dir)
    files = [File.join(dir, "archbuddy-findings.json")] +
            Dir.glob(File.join(dir, ".archbuddy/**/*.json"))
                .reject { |p| p.include?("/.cache/") }
    files.sort.to_h { |p| [p.sub("#{dir}/", ""), File.read(p)] }
  end

  it "produces byte-identical committed output across two runs" do
    Dir.mktmpdir do |dir|
      FileUtils.cp_r(Dir.glob("#{fixture_root}/*"), dir)
      collect_and_write(dir)
      first = committed_snapshot(dir)
      collect_and_write(dir)
      expect(committed_snapshot(dir)).to eq(first)
    end
  end

  it "leaves a clean `git status` on the second run (lockfile freshness idiom)" do
    Dir.mktmpdir do |dir|
      FileUtils.cp_r(Dir.glob("#{fixture_root}/*"), dir)
      git(dir, "init", "-q")
      git(dir, "config", "user.email", "t@t")
      git(dir, "config", "user.name", "t")
      File.write(File.join(dir, ".gitignore"), ".archbuddy/id-map.yml\n.archbuddy/.cache/\n.archbuddy/*.yml\n")

      collect_and_write(dir)
      git(dir, "add", "-A")
      git(dir, "commit", "-qm", "cache")

      collect_and_write(dir)
      status = git(dir, "status", "--porcelain", ".archbuddy", "archbuddy-findings.json")
      expect(status).to eq("")
    end
  end

  def git(dir, *args)
    out = IO.popen(["git", "-C", dir, *args], &:read)
    raise "git #{args.join(' ')} failed" unless $?.success?

    out
  end
end
