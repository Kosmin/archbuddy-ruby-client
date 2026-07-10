# frozen_string_literal: true

# Focused unit coverage for the root-seeder SEAM (v0.10 W1-B): RootSeeder
# base contract, RootSeederRegistry lenient config-driven selection (mirror
# of the probe seam), Config#root_types normalization, and the SymbolTable
# categorized-entrypoint accessors (mark_entrypoint first-write-wins + L4
# gate + nil-tolerant reader).
RSpec.describe "Root-seeder seam (v0.10 W1-B)" do
  R = Archbuddy::Collect::Adapters::Ruby

  # --- RootSeeder abstract contract --------------------------------------------

  it "raises NotImplementedError for the abstract RootSeeder#root_type" do
    expect { R::RootSeeder.new.root_type }.to raise_error(NotImplementedError, /root_type/)
  end

  it "defaults RootSeeder#seed to a no-op (never raises, marks nothing)" do
    table = R::SymbolTable.new
    expect { R::RootSeeder.new.seed(table) }.not_to raise_error
    expect { R::RootSeeder.new.seed(table, fragments: []) }.not_to raise_error
  end

  # --- registry map -------------------------------------------------------------

  it "ships a frozen SEEDERS list in ingress-precedence order (jobs -> rake -> middleware -> script)" do
    expect(R::RootSeederRegistry::SEEDERS).to eq(
      [
        R::RootSeeders::JobSeeder,
        R::RootSeeders::RakeSeeder,
        R::RootSeeders::MiddlewareSeeder,
        R::RootSeeders::ScriptSeeder
      ]
    )
    expect(R::RootSeederRegistry::SEEDERS).to be_frozen
  end

  # --- config-driven selection (lenient — mirror ProbeRegistry) ------------------

  it "selects every registered seeder for :all (the default)" do
    expect(R::RootSeederRegistry.for(Archbuddy::Collect::Config.new).map(&:root_type))
      .to eq(%i[jobs rake middleware script])
  end

  it "selects nothing for :none" do
    expect(R::RootSeederRegistry.for(Archbuddy::Collect::Config.new(root_types: :none))).to eq([])
  end

  it "selects nothing for an unknown name (lenient, no raise)" do
    expect { Archbuddy::Collect::Config.new(root_types: %i[totally_unknown]) }.not_to raise_error
    expect(R::RootSeederRegistry.for(Archbuddy::Collect::Config.new(root_types: %i[totally_unknown])))
      .to eq([])
  end

  it "selects a named subset by root_type" do
    expect(R::RootSeederRegistry.for(Archbuddy::Collect::Config.new(root_types: %i[jobs])).map(&:root_type))
      .to eq(%i[jobs])
  end

  it "selects and instantiates only the named seeders (proven via a stubbed SEEDERS)" do
    fake_a = Class.new(R::RootSeeder) do
      def self.root_type = :fake_a
      def root_type = :fake_a
    end
    fake_b = Class.new(R::RootSeeder) do
      def self.root_type = :fake_b
      def root_type = :fake_b
    end
    stub_const("#{R::RootSeederRegistry}::SEEDERS", [fake_a, fake_b])

    all = R::RootSeederRegistry.for(Archbuddy::Collect::Config.new(root_types: :all))
    expect(all.map(&:class)).to eq([fake_a, fake_b])

    one = R::RootSeederRegistry.for(Archbuddy::Collect::Config.new(root_types: %i[fake_b]))
    expect(one.map(&:root_type)).to eq([:fake_b])

    none = R::RootSeederRegistry.for(Archbuddy::Collect::Config.new(root_types: :none))
    expect(none).to eq([])
  end

  # --- Config root_types normalization (lenient, never raises) -------------------

  it "normalizes root_types selection leniently (mirror of probes)" do
    expect(Archbuddy::Collect::Config.new.root_types).to eq(:all)
    expect(Archbuddy::Collect::Config.new(root_types: "all").root_types).to eq(:all)
    expect(Archbuddy::Collect::Config.new(root_types: :none).root_types).to eq([])
    expect(Archbuddy::Collect::Config.new(root_types: "none").root_types).to eq([])
    expect(Archbuddy::Collect::Config.new(root_types: nil).root_types).to eq([])
    expect(Archbuddy::Collect::Config.new(root_types: []).root_types).to eq([])
    expect(Archbuddy::Collect::Config.new(root_types: %w[jobs]).root_types).to eq([:jobs])
    expect(Archbuddy::Collect::Config.new(root_types: "jobs, rake").root_types).to eq(%i[jobs rake])
  end

  # --- SymbolTable categorized-entrypoint accessors -------------------------------

  describe "SymbolTable#mark_entrypoint" do
    let(:table) do
      R::SymbolTable.new.tap do |t|
        t.add_method(
          R::SymbolTable::MethodEntry.new(
            fq_symbol: "FooWorker#perform", owner_fq: "FooWorker",
            name: "perform", singleton: false, rel_file: "app/workers/foo_worker.rb", line: 2
          )
        )
      end
    end

    it "records the category on the map AND the MethodEntry" do
      table.mark_entrypoint("FooWorker#perform", :jobs)

      expect(table.entrypoint_category("FooWorker#perform")).to eq(:jobs)
      expect(table.method_for("FooWorker#perform").entrypoint_category).to eq(:jobs)
    end

    it "is first-write-wins: a later mark for an already-categorized fq is ignored" do
      table.mark_entrypoint("FooWorker#perform", :jobs)
      table.mark_entrypoint("FooWorker#perform", :pattern)

      expect(table.entrypoint_category("FooWorker#perform")).to eq(:jobs)
      expect(table.method_for("FooWorker#perform").entrypoint_category).to eq(:jobs)
    end

    it "declines to record a category for an unknown method (L4 gate)" do
      table.mark_entrypoint("Ghost#perform", :jobs)

      expect(table.entrypoint_category("Ghost#perform")).to be_nil
    end

    it "reads nil for an uncategorized method (nil-tolerant)" do
      expect(table.entrypoint_category("FooWorker#perform")).to be_nil
    end

    it "defaults MethodEntry#entrypoint_category to nil" do
      expect(table.method_for("FooWorker#perform").entrypoint_category).to be_nil
    end
  end
end
