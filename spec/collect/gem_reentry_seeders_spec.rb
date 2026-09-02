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

  describe Archbuddy::Collect::Adapters::Ruby::RootSeeders::OrganizedSeeder do
    it "seeds every interactor an `organize` names — the GEM calls each of them" do
      t = seed(<<~RUBY, seeder: described_class.new)
        class Step::One
          def call; end
        end
        class Step::Two
          def call; end
        end
        class Flow
          organize Step::One, Step::Two
        end
      RUBY
      expect(t.entrypoint_category("Step::One#call")).to eq(:organized)
      expect(t.entrypoint_category("Step::Two#call")).to eq(:organized)
    end

    it "reads the parenthesised multi-line form, which parses to the same arguments" do
      t = seed(<<~RUBY, seeder: described_class.new)
        class Step::One
          def call; end
        end
        class Flow
          organize(
            Step::One
          )
        end
      RUBY
      expect(t.entrypoint_category("Step::One#call")).to eq(:organized)
    end

    # An interactor commonly inherits `#call` from an in-app base. An
    # own-class-only test declines exactly those — the ownership-versus-ancestry
    # mistake this codebase has paid for four times.
    it "resolves an INHERITED entry method along the ancestor chain" do
      t = seed(<<~RUBY, seeder: described_class.new)
        class BaseStep
          def call; end
        end
        class Step::Sub < BaseStep
        end
        class Flow
          organize Step::Sub
        end
      RUBY
      expect(t.entrypoint_category("BaseStep#call")).to eq(:organized)
    end

    it "DECLINES a constant whose entry method was never parsed" do
      t = seed(<<~RUBY, seeder: described_class.new)
        class Flow
          organize SomeEngine::Elsewhere
        end
      RUBY
      expect(t.entrypoint_category("SomeEngine::Elsewhere#call")).to be_nil
    end

    it "declines a non-constant argument — a variable names no provable class" do
      t = seed(<<~RUBY, seeder: described_class.new)
        class Flow
          organize steps
        end
      RUBY
      expect(t.entrypoint_category("Flow#call")).to be_nil
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
