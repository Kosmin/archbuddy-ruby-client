# frozen_string_literal: true

require "tmpdir"
require "fileutils"

# END-TO-END script root seeder (v0.10 W2-B). Feeds inline script fixtures
# through the REAL adapter (and Pass 1 + the seeder directly, for category
# inspection) and asserts that top-level defs of REAL scripts are re-tagged
# with the :script category — and that every unprovable shape DECLINES
# (never-fabricate: the seeder only re-tags rooting that already exists;
# it never adds nodes).
#
# A REAL script = under scripts/**, script/**, or bin/* (one level) AND a
# shebang first line AND a top-level body that is NOT loader-only (the
# Bundler/Rails binstub shape).
#
# Pattern: Dir.mktmpdir + inline fixtures + real adapter (same as
# job_seeder_spec.rb / middleware_seeder_spec.rb).
RSpec.describe "Script root seeder (v0.10 W2-B e2e)" do
  let(:config) { Archbuddy::Collect::Config.new(language: "ruby") }

  REAL_SCRIPT = <<~RUBY
    #!/usr/bin/env ruby

    def run
      1
    end

    run
  RUBY

  # The Bundler/Rails binstub loader shape: shebang + require/load-only body.
  BINSTUB = <<~RUBY
    #!/usr/bin/env ruby
    require "bundler/setup"
    require_relative "../config/boot"
    load Gem.bin_path("rails", "rails")
  RUBY

  def anonymize(root, cfg = config)
    Archbuddy::Collect::Anonymizer.new(
      Archbuddy::Collect::Registry.for("ruby").new(root, cfg).collect,
      tool: "archbuddy test", adapter: "ruby"
    ).call
  end

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

  def entrypoint?(result, sym)
    entry = result.id_map["ids"].find { |_i, d| d["symbol"] == sym }
    return false unless entry

    result.graph["entrypoints"].include?(entry.first)
  end

  # Pass 1 + the ScriptSeeder directly so the seeded table is inspectable.
  def seeded_table(dir)
    m     = Archbuddy::Collect::Adapters::Ruby
    table = m::SymbolTable.new
    fragments = m::FileEnumerator.new(dir, config).files.map do |abs, rel|
      Archbuddy::Collect::Fragment.new(
        rel_file: rel, content_hash: "x", parsed_value: Prism.parse(File.read(abs)).value
      )
    end
    fragments.each { |f| f.parsed_value.accept(m::DefinitionPass.new(table, f.rel_file)) }
    m::RootSeeders::ScriptSeeder.new.seed(table, fragments: fragments, root: dir)
    table
  end

  # --- real scripts are tagged ------------------------------------------------------

  it "tags the top-level defs of a scripts/** file as :script" do
    in_repo("scripts/backfill.rb" => REAL_SCRIPT) do |dir|
      expect(seeded_table(dir).entrypoint_category("run")).to eq(:script)
    end
  end

  it "tags script/** (singular) files too" do
    in_repo("script/migrate.rb" => REAL_SCRIPT) do |dir|
      expect(seeded_table(dir).entrypoint_category("run")).to eq(:script)
    end
  end

  it "tags direct bin/ children that are real scripts (not loaders)" do
    in_repo("bin/audit.rb" => REAL_SCRIPT) do |dir|
      expect(seeded_table(dir).entrypoint_category("run")).to eq(:script)
    end
  end

  it "keeps the tagged def an entrypoint end-to-end (it was already top-level rooted)" do
    in_repo("scripts/backfill.rb" => REAL_SCRIPT) do |dir|
      expect(entrypoint?(anonymize(dir), "run")).to be(true)
    end
  end

  it "surfaces the seeded category as \"script\" through detect_categorized (beats top_level)" do
    in_repo("scripts/backfill.rb" => REAL_SCRIPT) do |dir|
      m = Archbuddy::Collect::Adapters::Ruby
      categorized = m::EntrypointDetector.new(config).detect_categorized(seeded_table(dir))
      expect(categorized["run"]).to eq("script")
    end
  end

  # --- declines (never-fabricate: prefer the false negative) -------------------------

  it "DECLINES a binstub (shebang + loader-only body)" do
    in_repo("bin/rails.rb" => BINSTUB, "scripts/keep.rb" => REAL_SCRIPT) do |dir|
      table = seeded_table(dir)
      # The binstub defines no top-level defs anyway — prove nothing from it
      # was categorized while the sibling real script still was.
      expect(table.entrypoint_category("run")).to eq(:script)
      expect(table.methods.keys.select { |fq| table.entrypoint_category(fq) }).to eq(["run"])
    end
  end

  it "DECLINES a loader-only scripts/ file even when it defines nothing else" do
    in_repo("scripts/boot.rb" => "#!/usr/bin/env ruby\nrequire \"bundler/setup\"\nload \"other.rb\"\n") do |dir|
      table = seeded_table(dir)
      expect(table.methods.keys.select { |fq| table.entrypoint_category(fq) }).to be_empty
    end
  end

  it "DECLINES a script-shaped file WITHOUT a shebang" do
    in_repo("scripts/backfill.rb" => "def run\n  1\nend\nrun\n") do |dir|
      expect(seeded_table(dir).entrypoint_category("run")).to be_nil
    end
  end

  it "DECLINES files outside the script dirs (path guard)" do
    in_repo("lib/backfill.rb" => REAL_SCRIPT) do |dir|
      expect(seeded_table(dir).entrypoint_category("run")).to be_nil
    end
  end

  it "DECLINES nested bin/ subtrees (bin/* is one level only)" do
    in_repo("bin/tools/deep.rb" => REAL_SCRIPT) do |dir|
      expect(seeded_table(dir).entrypoint_category("run")).to be_nil
    end
  end

  it "DECLINES everything when no root is provided (shebang unprovable — L4)" do
    in_repo("scripts/backfill.rb" => REAL_SCRIPT) do |dir|
      m     = Archbuddy::Collect::Adapters::Ruby
      table = m::SymbolTable.new
      fragments = m::FileEnumerator.new(dir, config).files.map do |abs, rel|
        Archbuddy::Collect::Fragment.new(
          rel_file: rel, content_hash: "x", parsed_value: Prism.parse(File.read(abs)).value
        )
      end
      fragments.each { |f| f.parsed_value.accept(m::DefinitionPass.new(table, f.rel_file)) }
      m::RootSeeders::ScriptSeeder.new.seed(table, fragments: fragments, root: nil)

      expect(table.entrypoint_category("run")).to be_nil
    end
  end

  it "does not re-categorize an fq an earlier seeder already claimed (first-write-wins)" do
    in_repo("scripts/backfill.rb" => REAL_SCRIPT) do |dir|
      table = seeded_table(dir)
      table.mark_entrypoint("run", :pattern) # later mark is ignored
      expect(table.entrypoint_category("run")).to eq(:script)
    end
  end
end
