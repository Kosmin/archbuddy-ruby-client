# frozen_string_literal: true

require "tmpdir"
require "fileutils"

# FileEnumerator widening (v0.10 W2-B): `**/*.rake` and the extensionless
# `Rakefile` are Ruby source Prism parses fine, and rake root detection needs
# them enumerated. `.rb`-only behavior must stay byte-identical.
RSpec.describe Archbuddy::Collect::Adapters::Ruby::FileEnumerator do
  let(:config) { Archbuddy::Collect::Config.new(language: "ruby") }

  def in_repo(files)
    Dir.mktmpdir do |dir|
      files.each do |rel_path, content|
        abs = File.join(dir, rel_path)
        FileUtils.mkdir_p(File.dirname(abs))
        File.write(abs, content)
      end
      yield dir
    end
  end

  def rel_files(dir)
    described_class.new(dir, config).files.map { |_abs, rel| rel }
  end

  it "admits .rake files and the extensionless Rakefile alongside .rb" do
    in_repo(
      "Rakefile"             => "task :default do\nend\n",
      "lib/tasks/foo.rake"   => "task :foo do\nend\n",
      "lib/thing.rb"         => "class Thing; end\n"
    ) do |dir|
      expect(rel_files(dir)).to eq(%w[Rakefile lib/tasks/foo.rake lib/thing.rb])
    end
  end

  it "keeps a .rb-only repo identical to before (deterministic sorted order)" do
    in_repo(
      "b.rb" => "class B; end\n",
      "a.rb" => "class A; end\n"
    ) do |dir|
      expect(rel_files(dir)).to eq(%w[a.rb b.rb])
    end
  end

  it "applies the ignore list to .rake files too" do
    in_repo(
      "vendor/tasks/skip.rake" => "task :skip do\nend\n",
      "lib/tasks/keep.rake"    => "task :keep do\nend\n",
      "lib/thing.rb"           => "class Thing; end\n"
    ) do |dir|
      expect(rel_files(dir)).to eq(%w[lib/tasks/keep.rake lib/thing.rb])
    end
  end

  it "accepts a single-file .rake target" do
    in_repo("lib/tasks/foo.rake" => "task :foo do\nend\n") do |dir|
      target = File.join(dir, "lib/tasks/foo.rake")
      expect(described_class.new(target, config).files).to eq([[target, "foo.rake"]])
    end
  end

  it "accepts a single-file Rakefile target" do
    in_repo("Rakefile" => "task :default do\nend\n") do |dir|
      target = File.join(dir, "Rakefile")
      expect(described_class.new(target, config).files).to eq([[target, "Rakefile"]])
    end
  end

  it "still rejects a non-Ruby single-file target" do
    in_repo("notes.txt" => "hello\n") do |dir|
      expect { described_class.new(File.join(dir, "notes.txt"), config).files }
        .to raise_error(described_class::NoSourceError, /not a \.rb file/)
    end
  end

  it "still raises when a directory has zero Ruby-family files" do
    in_repo("README.md" => "no ruby here\n") do |dir|
      expect { described_class.new(dir, config).files }
        .to raise_error(described_class::NoSourceError, /no \.rb files/)
    end
  end

  it "no longer raises for a repo containing ONLY a .rake file (it IS Ruby source)" do
    in_repo("lib/tasks/foo.rake" => "task :foo do\nend\n") do |dir|
      expect(rel_files(dir)).to eq(%w[lib/tasks/foo.rake])
    end
  end
end
