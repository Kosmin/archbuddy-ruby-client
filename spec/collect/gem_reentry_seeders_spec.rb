# frozen_string_literal: true

require "spec_helper"
require "prism"
require "archbuddy/collect"
require "archbuddy/collect/adapters/ruby/root_seeder_registry"
require "archbuddy/collect/adapters/ruby/definition_pass"

# GEM RE-ENTRY. The graph treats app -> gem as a cost-1 exit and never traverses
# into a dependency. But a gem calls BACK, and that direction is an ingress root:
# the method runs, carries its branches, and has no in-app caller. Measured on a
# real service, 358 app methods holding 2,082 branches were unreachable for
# exactly this reason.
RSpec.describe "gem re-entry ingress roots" do
  def rb = Archbuddy::Collect::Adapters::Ruby

  # Seeded through the REAL definition pass rather than a hand-built table, so
  # the fq spellings and the `table.method?` gate are the production ones.
  def seed(source, seeder:, root_types: :all)
    fragment = Archbuddy::Collect::Fragment.new(
      rel_file: "app/x.rb", content_hash: "h", parsed_value: Prism.parse(source).value
    )
    table = rb::SymbolTable.new
    fragment.parsed_value.accept(rb::DefinitionPass.new(table, "app/x.rb"))
    seeder.seed(table, fragments: [fragment], root: "/srv/app")
    table
  end

  describe Archbuddy::Collect::Adapters::Ruby::RootSeeders::CallbackSeeder do
    it "seeds a validation callback target — ActiveModel calls it, nothing here does" do
      t = seed(<<~RUBY, seeder: described_class.new)
        class Provider::Purchase
          validate :valid_earn_loyalty
          def valid_earn_loyalty; end
        end
      RUBY
      expect(t.entrypoint_category("Provider::Purchase#valid_earn_loyalty")).to eq(:callbacks)
    end

    it "seeds several targets from one declaration" do
      t = seed(<<~RUBY, seeder: described_class.new)
        class Order
          after_commit :notify, :reindex
          def notify; end
          def reindex; end
        end
      RUBY
      expect(t.entrypoint_category("Order#notify")).to eq(:callbacks)
      expect(t.entrypoint_category("Order#reindex")).to eq(:callbacks)
    end

    it "seeds an `if:` GUARD method — the framework calls that back too" do
      t = seed(<<~RUBY, seeder: described_class.new)
        class Order
          before_save :touch_total, if: :changed?
          def touch_total; end
          def changed?; end
        end
      RUBY
      expect(t.entrypoint_category("Order#changed?")).to eq(:callbacks)
    end

    it "does NOT seed a lifecycle option value — `on: :create` names an event, not a method" do
      t = seed(<<~RUBY, seeder: described_class.new)
        class Order
          after_commit :notify, on: :create
          def notify; end
          def create; end
        end
      RUBY
      expect(t.entrypoint_category("Order#create")).to be_nil
    end

    # THE GATE THAT MATTERS. `before_action :authenticate!` routinely names a
    # method a base class or a gem supplies; seeding a root for a method this
    # class does not define would invent an entrypoint.
    it "DECLINES a target the declaring class does not define" do
      t = seed(<<~RUBY, seeder: described_class.new)
        class UsersController
          before_action :authenticate!
        end
      RUBY
      expect(t.entrypoint_category("UsersController#authenticate!")).to be_nil
    end

    it "declines a callback given a BLOCK — there is no named method to seed" do
      t = seed(<<~RUBY, seeder: described_class.new)
        class Order
          before_save { self.total = 0 }
          def total=(v); end
        end
      RUBY
      expect(t.entrypoint_category("Order#total=")).to be_nil
    end

    it "ignores a macro we have not named — an unknown vocabulary declines, never guesses" do
      t = seed(<<~RUBY, seeder: described_class.new)
        class Order
          some_unknown_macro :notify
          def notify; end
        end
      RUBY
      expect(t.entrypoint_category("Order#notify")).to be_nil
    end
  end

  # THE STEPS ARE EDGES, NOT ROOTS. Seeding each step was the first design and
  # the weaker one: they became reachable but stayed disconnected, so the
  # organizer had no cost and "what does Clawback do" returned nothing.
  describe Archbuddy::Collect::Adapters::Ruby::OrganizerNodes do
    def build(source)
      fragment = Archbuddy::Collect::Fragment.new(
        rel_file: "app/x.rb", content_hash: "h", parsed_value: Prism.parse(source).value
      )
      table = rb::SymbolTable.new
      fragment.parsed_value.accept(rb::DefinitionPass.new(table, "app/x.rb"))
      [described_class.build(fragments: [fragment], table: table), table]
    end

    it "mints the organizer's `#call` — app source never declares it" do
      # Verified on a real service: all 25 organizer classes had NO `#call`
      # node, because Interactor::Organizer supplies it and it is gem-defined.
      out, = build(<<~RUBY)
        class Step::One
          def call; end
        end
        class Flow
          organize Step::One
        end
      RUBY
      expect(out.map(&:call_fq)).to eq(["Flow#call"])
      expect(out.first.step_fqs).to eq(["Step::One#call"])
    end

    it "anchors the minted node at the `organize` DECLARATION, so the id-map points at real code" do
      out, = build("class Flow\n  include Interactor::Organizer\n  organize A\nend\nclass A; def call; end; end\n")
      expect([out.first.rel_file, out.first.line]).to eq(["app/x.rb", 3])
    end

    it "links every step of a multi-line declaration in source order" do
      out, = build(<<~RUBY)
        class A; def call; end; end
        class B; def call; end; end
        class Flow
          organize(
            A,
            B
          )
        end
      RUBY
      expect(out.first.step_fqs).to eq(["A#call", "B#call"])
    end

    it "resolves an INHERITED entry method along the ancestor chain" do
      # An interactor commonly inherits `#call` from an in-app base; an
      # own-class-only test declines exactly those.
      out, = build(<<~RUBY)
        class BaseStep
          def call; end
        end
        class Sub < BaseStep; end
        class Flow
          organize Sub
        end
      RUBY
      expect(out.first.step_fqs).to eq(["BaseStep#call"])
    end

    it "DROPS a step whose entry method was never parsed, rather than inventing an edge" do
      out, = build("class Flow\n  organize SomeEngine::Elsewhere\nend\n")
      expect(out.first.step_fqs).to eq([])
    end

    it "records NOTHING for a wholly dynamic declaration" do
      # `organize steps` names no provable class, so there is no sequence to
      # model. Declining entirely and minting a step-less node cost the same
      # (a caller's `Flow.call` becomes a cost-1 boundary either way), so the
      # honest one wins: do not assert a node exists on the strength of a
      # declaration we could not read.
      out, = build("class Flow\n  organize steps\nend\n")
      expect(out).to eq([])
    end

    it "mints nothing for a class the parser never saw" do
      fragment = Archbuddy::Collect::Fragment.new(
        rel_file: "app/x.rb", content_hash: "h",
        parsed_value: Prism.parse("Flow.organize A").value
      )
      expect(described_class.build(fragments: [fragment], table: rb::SymbolTable.new)).to eq([])
    end
  end

  describe Archbuddy::Collect::Adapters::Ruby::RootSeeders::OrganizedSeeder do
    # 18 of 25 organizers on a real service ARE invoked from app source and get
    # their in-edge from R4; 7 are not, and anchor nothing without a root. This
    # seeds the ORGANIZER, mirroring JobSeeder: being an ingress is a property
    # of the declaration, not of whether a caller happens to exist.
    it "roots the organizer's own `#call`, once the adapter has minted it" do
      source = <<~RUBY
        class Step::One
          def call; end
        end
        class Flow
          organize Step::One
        end
      RUBY
      fragment = Archbuddy::Collect::Fragment.new(
        rel_file: "app/x.rb", content_hash: "h", parsed_value: Prism.parse(source).value
      )
      table = rb::SymbolTable.new
      fragment.parsed_value.accept(rb::DefinitionPass.new(table, "app/x.rb"))
      # What the adapter does before any seeder runs.
      table.add_method(rb::SymbolTable::MethodEntry.new(
                         fq_symbol: "Flow#call", owner_fq: "Flow", name: "call",
                         rel_file: "app/x.rb", line: 5
                       ))

      described_class.new.seed(table, fragments: [fragment], root: "/srv/app")
      expect(table.entrypoint_category("Flow#call")).to eq(:organized)
      # The step is reached by an EDGE, so it must not also be claimed as a root.
      expect(table.entrypoint_category("Step::One#call")).to be_nil
    end

    it "DECLINES when the organizer's `#call` was never minted" do
      source = "class Flow\n  organize A\nend\nclass A; def call; end; end\n"
      fragment = Archbuddy::Collect::Fragment.new(
        rel_file: "app/x.rb", content_hash: "h", parsed_value: Prism.parse(source).value
      )
      table = rb::SymbolTable.new
      fragment.parsed_value.accept(rb::DefinitionPass.new(table, "app/x.rb"))
      described_class.new.seed(table, fragments: [fragment], root: "/srv/app")
      expect(table.entrypoint_category("Flow#call")).to be_nil
    end
  end

  describe "precedence" do
    # mark_entrypoint is first-write-wins and the registry order IS the
    # precedence. A worker that also declares a callback must read as a JOB:
    # the job is why it runs; the callback is a detail of that run.
    it "lets an earlier seeder keep a method the callback seeder would also claim" do
      source = <<~RUBY
        class CleanupJob
          include Sidekiq::Job
          after_perform :perform
          def perform; end
        end
      RUBY
      fragment = Archbuddy::Collect::Fragment.new(
        rel_file: "app/x.rb", content_hash: "h", parsed_value: Prism.parse(source).value
      )
      table = rb::SymbolTable.new
      fragment.parsed_value.accept(rb::DefinitionPass.new(table, "app/x.rb"))
      rb::RootSeederRegistry.for(Archbuddy::Collect::Config.new).each do |s|
        s.seed(table, fragments: [fragment], root: "/srv/app")
      end
      expect(table.entrypoint_category("CleanupJob#perform")).to eq(:jobs)
    end
  end
end
