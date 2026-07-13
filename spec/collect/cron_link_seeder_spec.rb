# frozen_string_literal: true

require "tmpdir"
require "fileutils"

# Cron LINK seeder (v0.10 W4b — L8 "cron = LINK only", DEFAULT OFF until W7).
#
# Invariants tested (I1/L4/L8/R10):
#   - sidekiq-cron YAML `class:` naming an ALREADY-seeded job root => CONFIRMED
#     (a table no-op: category stays :jobs, entrypoint set unchanged)
#   - `class:` naming a class ABSENT from the table => DECLINED (never mint)
#   - `class:` naming a present-but-UNSEEDED method => DECLINED (LINK-only)
#   - whenever `rake "name"` => confirmed iff a minted rake:name[N] root exists
#   - whenever `command` / opaque `runner` => DECLINED
#   - malformed YAML => rescued, no crash, nothing marked
#   - no config files => no-op
#   - e2e: cron is EXCLUDED from --root-types all; explicit "jobs,cron" runs it
#     without changing any category or count
RSpec.describe "Cron LINK seeder (v0.10 W4b)" do
  RB = Archbuddy::Collect::Adapters::Ruby unless defined?(RB)

  # A table with one seeded :jobs root (MyJob#perform), one unseeded method
  # (Plain#perform), and one minted :rake root (rake:db:backup[0]).
  def seeded_table
    table = RB::SymbolTable.new
    {
      "MyJob#perform"      => %w[MyJob perform],
      "Plain#perform"      => %w[Plain perform],
      "rake:db:backup[0]"  => [nil, "backup"]
    }.each do |fq, (owner, name)|
      table.add_method(
        RB::SymbolTable::MethodEntry.new(
          fq_symbol: fq, owner_fq: owner, name: name, singleton: false,
          rel_file: "app/x.rb", line: 1
        )
      )
    end
    table.mark_entrypoint("MyJob#perform", :jobs)
    table.mark_entrypoint("rake:db:backup[0]", :rake)
    table
  end

  def in_root(files)
    Dir.mktmpdir do |dir|
      files.each do |rel_path, content|
        abs = File.join(dir, rel_path)
        FileUtils.mkdir_p(File.dirname(abs))
        File.write(abs, content)
      end
      yield dir
    end
  end

  # NOTE: `table` is a POSITIONAL default (not a kwarg) so braceless-hash
  # `files` callers stay positional under Ruby 3 kwargs separation.
  def seed(files, table = seeded_table)
    seeder = RB::RootSeeders::CronLinkSeeder.new
    in_root(files) { |dir| seeder.seed(table, root: dir) }
    [seeder, table]
  end

  # --- sidekiq-cron YAML `class:` ------------------------------------------------

  it "CONFIRMS a schedule.yml class: naming an already-seeded job root (category stays :jobs)" do
    seeder, table = seed(
      "config/schedule.yml" => <<~YAML
        my_job:
          cron: "* * * * *"
          class: "MyJob"
      YAML
    )

    expect(seeder.confirmed).to eq(["MyJob#perform"])
    expect(seeder.declined).to be_empty
    # LINK-only: confirm is a table NO-OP — category unchanged, nothing re-tagged.
    expect(table.entrypoint_category("MyJob#perform")).to eq(:jobs)
  end

  it "also reads the config/sidekiq_cron.yml convention path" do
    seeder, = seed(
      "config/sidekiq_cron.yml" => %(j:\n  cron: "0 * * * *"\n  class: "MyJob"\n)
    )

    expect(seeder.confirmed).to eq(["MyJob#perform"])
  end

  it "DECLINES a class: absent from the table (never mints a root from a config name)" do
    seeder, table = seed(
      "config/schedule.yml" => %(ghost:\n  cron: "* * * * *"\n  class: "GhostJob"\n)
    )

    expect(seeder.confirmed).to be_empty
    expect(seeder.declined).to include("class:GhostJob")
    expect(table.entrypoint_category("GhostJob#perform")).to be_nil
  end

  it "DECLINES a class whose #perform exists but is NOT an already-seeded root (LINK-only)" do
    seeder, table = seed(
      "config/schedule.yml" => %(p:\n  cron: "* * * * *"\n  class: "Plain"\n)
    )

    expect(seeder.confirmed).to be_empty
    expect(seeder.declined).to include("class:Plain")
    expect(table.entrypoint_category("Plain#perform")).to be_nil
  end

  it "DECLINES entries without cron:/class: or with a non-constant class (opaque)" do
    seeder, = seed(
      "config/schedule.yml" => <<~YAML
        no_class:
          cron: "* * * * *"
        no_cron:
          class: "MyJob"
        computed:
          cron: "* * * * *"
          class: "my_job.camelize"
      YAML
    )

    expect(seeder.confirmed).to be_empty
    expect(seeder.declined).to contain_exactly(
      "sidekiq_cron:no_class", "sidekiq_cron:no_cron", "sidekiq_cron:computed"
    )
  end

  it "rescues malformed YAML — no crash, nothing confirmed, decline recorded" do
    seeder = nil
    expect {
      seeder, = seed("config/schedule.yml" => "{{ not: yaml: at: all")
    }.not_to raise_error

    expect(seeder.confirmed).to be_empty
    expect(seeder.declined).to eq(["sidekiq_cron:schedule.yml:malformed"])
  end

  # --- whenever schedule.rb ------------------------------------------------------

  it "CONFIRMS a whenever rake 'name' entry against the minted rake root (any ordinal)" do
    seeder, = seed(
      "config/schedule.rb" => <<~RUBY
        every 1.day do
          rake "db:backup"
        end
      RUBY
    )

    expect(seeder.confirmed).to eq(["rake:db:backup[0]"])
    expect(seeder.declined).to be_empty
  end

  it "DECLINES a rake entry with no minted root" do
    seeder, = seed("config/schedule.rb" => %(every(1.day) { rake "db:missing" }\n))

    expect(seeder.confirmed).to be_empty
    expect(seeder.declined).to eq(["rake:db:missing"])
  end

  it "CONFIRMS a resolvable runner (Const.perform-family targeting a seeded job root)" do
    seeder, = seed("config/schedule.rb" => %(every(1.day) { runner "MyJob.perform_now" }\n))

    expect(seeder.confirmed).to eq(["MyJob#perform"])
  end

  it "DECLINES opaque whenever forms: command, non-perform runner, computed runner" do
    seeder, = seed(
      "config/schedule.rb" => <<~RUBY
        every 1.day do
          command "ls -la"
          runner "Plain.do_something"
          runner "my_job_class.perform_now"
          runner some_variable
          rake computed_name
        end
      RUBY
    )

    expect(seeder.confirmed).to be_empty
    expect(seeder.declined).to contain_exactly(
      "command", "runner:Plain.do_something", "runner", "runner", "rake"
    )
  end

  it "treats unparseable schedule.rb as empty (no crash)" do
    seeder = nil
    expect {
      seeder, = seed("config/schedule.rb" => "every(1.day do <<< nope")
    }.not_to raise_error

    expect(seeder.confirmed).to be_empty
  end

  # --- degenerate inputs -----------------------------------------------------------

  it "is a no-op with no cron config files at all" do
    seeder, table = seed({})

    expect(seeder.confirmed).to be_empty
    expect(seeder.declined).to be_empty
    expect(table.entrypoint_category("MyJob#perform")).to eq(:jobs)
  end

  it "is a no-op when root is nil (disk evidence unavailable)" do
    seeder = RB::RootSeeders::CronLinkSeeder.new
    expect { seeder.seed(seeded_table, root: nil) }.not_to raise_error
    expect(seeder.confirmed).to be_empty
  end

  # --- e2e: default OFF through the real adapter ----------------------------------

  describe "e2e through the adapter (DEFAULT OFF — R10)" do
    let(:worker_src) do
      <<~RUBY
        class MyJob
          include Sidekiq::Job

          def perform
            42
          end
        end
      RUBY
    end
    let(:schedule_yml) { %(my_job:\n  cron: "* * * * *"\n  class: "MyJob"\n) }

    def entrypoint_ids(dir, root_types)
      cfg    = Archbuddy::Collect::Config.new(language: "ruby", root_types: root_types)
      result = Archbuddy::Collect::Registry.for("ruby").new(dir, cfg).collect
      anon   = Archbuddy::Collect::Anonymizer.new(result, tool: "t", adapter: "ruby").call
      anon.graph["entrypoints"].sort
    end

    it "produces the IDENTICAL entrypoint set with cron off (default) and explicitly on" do
      in_root(
        "app/workers/my_job.rb" => worker_src,
        "config/schedule.yml"   => schedule_yml
      ) do |dir|
        expect(entrypoint_ids(dir, "all")).to eq(entrypoint_ids(dir, "jobs,cron"))
      end
    end

    it "does not crash a collect on malformed cron config when cron is explicitly on" do
      in_root(
        "app/workers/my_job.rb" => worker_src,
        "config/schedule.yml"   => "{{ malformed",
        "config/schedule.rb"    => "every(1.day do <<< nope"
      ) do |dir|
        expect { entrypoint_ids(dir, "jobs,cron") }.not_to raise_error
      end
    end
  end
end
