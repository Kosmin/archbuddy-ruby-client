# frozen_string_literal: true

require "tmpdir"
require "fileutils"

# END-TO-END rake task rooting (v0.10 W2-B). Feeds inline `.rake`/`Rakefile`
# fixtures through the REAL adapter and asserts the whole rake pipeline:
#
#   - Pass 1 MINTS a synthetic :rake MethodEntry per `task NAME do..end`
#     block (mirror of Grape's mint_endpoint; owner_fq nil, FQ carries the
#     namespace path + a per-(namespace, name) source-order ordinal).
#   - Pass 2 pushes the BYTE-IDENTICAL FQ (F5 ordinal parity) so task-body
#     calls are recovered as EDGES — the parity proof IS the edge recovery.
#   - the :rake category is stamped at mint (ONE entrypoint_category write).
#   - never-fabricate declines: a `task` call in a non-rake .rb file, a
#     blockless declaration, and a computed task name are all NOT minted.
#
# Pattern: Dir.mktmpdir + inline fixtures + real adapter (same as
# job_seeder_spec.rb / middleware_seeder_spec.rb).
RSpec.describe "Rake task rooting (v0.10 W2-B e2e)" do
  let(:config) { Archbuddy::Collect::Config.new(language: "ruby") }

  CLEANER = <<~RUBY
    class Cleaner
      def self.purge
        1
      end
    end
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

  def id_for(result, sym)
    entry = result.id_map["ids"].find { |_i, d| d["symbol"] == sym }
    entry&.first
  end

  def entrypoint?(result, sym)
    id = id_for(result, sym)
    return false unless id

    result.graph["entrypoints"].include?(id)
  end

  # True iff a directed edge from_sym -> to_sym exists in the graph.
  def edge?(result, from_sym, to_sym)
    from_id = id_for(result, from_sym)
    to_id   = id_for(result, to_sym)
    return false unless from_id && to_id

    result.graph["edges"].any? { |e| e["from"] == from_id && e["to"] == to_id }
  end

  # Pass 1 only — the minted table, inspectable for category/branches.
  def minted_table(dir)
    m     = Archbuddy::Collect::Adapters::Ruby
    table = m::SymbolTable.new
    m::FileEnumerator.new(dir, config).files.each do |abs, rel|
      Prism.parse(File.read(abs)).value.accept(m::DefinitionPass.new(table, rel))
    end
    table
  end

  # --- the mint -------------------------------------------------------------------

  it "mints a task block in a .rake file as an entrypoint node" do
    in_repo("lib/tasks/cleanup.rake" => "task :cleanup do\n  Cleaner.purge\nend\n",
            "app/models/cleaner.rb"  => CLEANER) do |dir|
      expect(entrypoint?(anonymize(dir), "rake:cleanup[0]")).to be(true)
    end
  end

  it "mints a task block in an extensionless Rakefile" do
    in_repo("Rakefile" => "task :default do\n  1\nend\n") do |dir|
      expect(entrypoint?(anonymize(dir), "rake:default[0]")).to be(true)
    end
  end

  it "mints the `name => deps` hash form under the hash-key name" do
    in_repo("lib/tasks/db.rake" => "task backup: :environment do\n  1\nend\n") do |dir|
      expect(entrypoint?(anonymize(dir), "rake:backup[0]")).to be(true)
    end
  end

  it "stamps the :rake category at mint (owner_fq nil — top-level-ish root)" do
    in_repo("lib/tasks/cleanup.rake" => "task :cleanup do\n  1\nend\n") do |dir|
      table = minted_table(dir)
      expect(table.entrypoint_category("rake:cleanup[0]")).to eq(:rake)
      expect(table.method_for("rake:cleanup[0]").owner_fq).to be_nil
    end
  end

  # --- namespaced FQ ----------------------------------------------------------------

  it "carries the namespace path in the FQ for nested `namespace` blocks" do
    in_repo(
      "lib/tasks/db.rake" => <<~RUBY
        namespace :db do
          namespace :cache do
            task :clear do
              1
            end
          end
        end
      RUBY
    ) do |dir|
      expect(entrypoint?(anonymize(dir), "rake:db:cache:clear[0]")).to be(true)
    end
  end

  # --- Pass-2 edge recovery (the F5 parity proof) ------------------------------------

  it "recovers task-body calls as edges (Pass-2 pushes the byte-identical FQ)" do
    in_repo(
      "lib/tasks/cleanup.rake" => "task :cleanup do\n  Cleaner.purge\nend\n",
      "app/models/cleaner.rb"  => CLEANER
    ) do |dir|
      expect(edge?(anonymize(dir), "rake:cleanup[0]", "Cleaner.purge")).to be(true)
    end
  end

  it "recovers namespaced task-body edges too" do
    in_repo(
      "lib/tasks/db.rake"     => "namespace :db do\n  task :purge do\n    Cleaner.purge\n  end\nend\n",
      "app/models/cleaner.rb" => CLEANER
    ) do |dir|
      expect(edge?(anonymize(dir), "rake:db:purge[0]", "Cleaner.purge")).to be(true)
    end
  end

  # --- two-task ordinal parity --------------------------------------------------------

  it "gives two same-name task blocks distinct ordinals AND recovers edges from BOTH bodies" do
    in_repo(
      "lib/tasks/twice.rake" => <<~RUBY,
        task :sync do
          Cleaner.purge
        end

        task :sync do
          Auditor.check
        end
      RUBY
      "app/models/cleaner.rb" => CLEANER,
      "app/models/auditor.rb" => "class Auditor\n  def self.check\n    1\n  end\nend\n"
    ) do |dir|
      result = anonymize(dir)
      expect(entrypoint?(result, "rake:sync[0]")).to be(true)
      expect(entrypoint?(result, "rake:sync[1]")).to be(true)
      # Parity is proven per-ordinal: each body's edge hangs off ITS node.
      expect(edge?(result, "rake:sync[0]", "Cleaner.purge")).to be(true)
      expect(edge?(result, "rake:sync[1]", "Auditor.check")).to be(true)
      expect(edge?(result, "rake:sync[0]", "Auditor.check")).to be(false)
    end
  end

  it "keeps ordinals independent per (namespace, name) key" do
    in_repo(
      "lib/tasks/mixed.rake" => <<~RUBY
        task :sync do
          1
        end

        namespace :db do
          task :sync do
            1
          end
        end
      RUBY
    ) do |dir|
      result = anonymize(dir)
      # Different namespace path => different key => both are ordinal 0.
      expect(entrypoint?(result, "rake:sync[0]")).to be(true)
      expect(entrypoint?(result, "rake:db:sync[0]")).to be(true)
    end
  end

  # --- empty body + declines (never-fabricate) -----------------------------------------

  it "mints an empty-body task as a valid root with the b=1,d=0 default and no out-edges" do
    in_repo("lib/tasks/noop.rake" => "task :noop do\nend\n") do |dir|
      table = minted_table(dir)
      entry = table.method_for("rake:noop[0]")
      expect(entry).not_to be_nil
      expect(entry.branches).to eq(1)
      expect(entry.decisions).to eq(0)

      result = anonymize(dir)
      expect(entrypoint?(result, "rake:noop[0]")).to be(true)
      id = id_for(result, "rake:noop[0]")
      expect(result.graph["edges"].none? { |e| e["from"] == id }).to be(true)
    end
  end

  it "does NOT mint a `task` call in a non-rake .rb file (rake_file? guard)" do
    in_repo("lib/builder.rb" => "task :foo do\n  1\nend\n") do |dir|
      expect(id_for(anonymize(dir), "rake:foo[0]")).to be_nil
    end
  end

  it "does NOT mint a blockless task declaration (no body to root)" do
    in_repo("lib/tasks/decl.rake" => "task :environment\ntask :real do\n  1\nend\n") do |dir|
      result = anonymize(dir)
      expect(id_for(result, "rake:environment[0]")).to be_nil
      expect(entrypoint?(result, "rake:real[0]")).to be(true)
    end
  end

  it "DECLINES a computed task name (unprovable — L4)" do
    in_repo("lib/tasks/dyn.rake" => "name = :dyn\ntask name do\n  1\nend\n") do |dir|
      result = anonymize(dir)
      expect(result.id_map["ids"].none? { |_i, d| d["symbol"].start_with?("rake:") }).to be(true)
    end
  end
end
