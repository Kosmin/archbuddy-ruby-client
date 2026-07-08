# frozen_string_literal: true

require "archbuddy/cache"
require "tmpdir"
require "fileutils"

# C3 (c): a 1-file source change touches ONLY that file's committed fragment
# (plus genuinely-affected aggregate entries) — a bounded, reviewable diff. An
# unrelated file's fragment stays byte-identical (symbol-keyed ids + canonical
# ordering).
RSpec.describe "bounded 1-file-change diff (C3)" do
  let(:config) { Archbuddy::Collect::Config.new(language: "ruby") }

  def seed(dir)
    FileUtils.mkdir_p(File.join(dir, "app"))
    File.write(File.join(dir, "app/a.rb"), "class A\n  def run\n    helper\n  end\n  def helper\n    1\n  end\nend\n")
    File.write(File.join(dir, "app/b.rb"), "class B\n  def go\n    2\n  end\nend\n")
  end

  def collect_and_write(dir)
    adapter = Archbuddy::Collect::Registry.for("ruby").new(dir, config)
    anon = Archbuddy::Collect::Anonymizer.new(
      adapter.collect(mode: :full), tool: "archbuddy test", adapter: "ruby"
    ).call
    Archbuddy::Cache::Writer.new(project_root: dir).write(graph: anon.graph, id_map: anon.id_map)
  end

  def read(dir, rel)
    File.read(File.join(dir, rel))
  end

  it "changes only the edited file's fragment; the unrelated fragment is byte-identical" do
    Dir.mktmpdir do |dir|
      seed(dir)
      collect_and_write(dir)
      a_before = read(dir, ".archbuddy/app/a.rb.json")
      b_before = read(dir, ".archbuddy/app/b.rb.json")

      # Edit ONLY app/a.rb (add a method) — app/b.rb untouched.
      File.write(File.join(dir, "app/a.rb"),
                 "class A\n  def run\n    helper\n    extra\n  end\n  def helper\n    1\n  end\n  def extra\n    3\n  end\nend\n")
      collect_and_write(dir)

      expect(read(dir, ".archbuddy/app/a.rb.json")).not_to eq(a_before) # edited file changed
      expect(read(dir, ".archbuddy/app/b.rb.json")).to eq(b_before)     # unrelated file UNCHANGED
    end
  end
end
