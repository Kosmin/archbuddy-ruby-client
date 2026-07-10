# frozen_string_literal: true

require "tmpdir"
require "fileutils"

# END-TO-END job root seeder (v0.10 W1-B). Feeds inline worker/job source
# through the REAL adapter and asserts that Sidekiq/ActiveJob `#perform`
# methods become CATEGORIZED entrypoints — and that unprovable cases decline.
#
# Invariants tested (L4 / L8 / Reconciliation 2):
#   - modern Sidekiq `include Sidekiq::Job` (mixin path, L14) seeds #perform
#   - legacy `class Foo < Sidekiq::Worker` (superclass path) seeds #perform
#   - ActiveJob `< ApplicationJob` seeds #perform
#   - intermediate in-app base (`< BaseJob < ApplicationJob`) seeds via chain
#   - missing #perform => DECLINE (never-fabricate)
#   - category vocab is PLURAL :jobs (CR-4)
#   - --root-types none => no seeded roots; existing entrypoints unchanged
#   - :controllers strategy does NOT include seeded jobs (default_set only)
#
# Pattern: Dir.mktmpdir + inline .rb fixtures + real adapter (same as
# route_catalogue_spec.rb).
RSpec.describe "Job root seeder (v0.10 W1-B e2e)" do
  let(:config) { Archbuddy::Collect::Config.new(language: "ruby") }

  def collect(root, cfg = config)
    Archbuddy::Collect::Registry.for("ruby").new(root, cfg).collect
  end

  def anonymize(root, cfg = config)
    Archbuddy::Collect::Anonymizer.new(
      collect(root, cfg), tool: "archbuddy test", adapter: "ruby"
    ).call
  end

  # Write multiple files into a tmpdir, yield the dir path, clean up.
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

  # True when `sym` appears as an entrypoint in the anonymized result.
  def entrypoint?(result, sym)
    entry = result.id_map["ids"].find { |_i, d| d["symbol"] == sym }
    return false unless entry

    result.graph["entrypoints"].include?(entry.first)
  end

  # --- Sidekiq via modern include-mixin (L14 path) ------------------------------

  it "seeds #perform for `include Sidekiq::Job` as a :jobs root" do
    in_repo(
      "app/workers/foo_worker.rb" => <<~RUBY
        class FooWorker
          include Sidekiq::Job

          def perform
            1
          end
        end
      RUBY
    ) do |dir|
      expect(entrypoint?(anonymize(dir), "FooWorker#perform")).to be(true)
    end
  end

  it "seeds #perform for the older `include Sidekiq::Worker` mixin" do
    in_repo(
      "app/workers/old_worker.rb" => <<~RUBY
        class OldWorker
          include Sidekiq::Worker

          def perform
            1
          end
        end
      RUBY
    ) do |dir|
      expect(entrypoint?(anonymize(dir), "OldWorker#perform")).to be(true)
    end
  end

  # --- Sidekiq via legacy superclass --------------------------------------------

  it "seeds #perform for legacy `class Foo < Sidekiq::Worker`" do
    in_repo(
      "app/workers/legacy_worker.rb" => <<~RUBY
        class LegacyWorker < Sidekiq::Worker
          def perform
            1
          end
        end
      RUBY
    ) do |dir|
      expect(entrypoint?(anonymize(dir), "LegacyWorker#perform")).to be(true)
    end
  end

  # --- ActiveJob ------------------------------------------------------------------

  it "seeds #perform for an ActiveJob subclass (< ApplicationJob)" do
    in_repo(
      "app/jobs/foo_job.rb" => <<~RUBY
        class FooJob < ApplicationJob
          def perform
            1
          end
        end
      RUBY
    ) do |dir|
      expect(entrypoint?(anonymize(dir), "FooJob#perform")).to be(true)
    end
  end

  it "seeds #perform through an intermediate in-app base class (chain walk)" do
    in_repo(
      "app/jobs/base_job.rb" => <<~RUBY,
        class BaseJob < ApplicationJob
        end
      RUBY
      "app/jobs/child_job.rb" => <<~RUBY
        class ChildJob < BaseJob
          def perform
            1
          end
        end
      RUBY
    ) do |dir|
      expect(entrypoint?(anonymize(dir), "ChildJob#perform")).to be(true)
    end
  end

  # --- never-fabricate decline (L4) ------------------------------------------------

  it "declines a job class whose #perform is not defined in-tree" do
    in_repo(
      "app/workers/ghost_worker.rb" => <<~RUBY
        class GhostWorker
          include Sidekiq::Job

          def helper
            1
          end
        end
      RUBY
    ) do |dir|
      result = anonymize(dir)
      # No #perform node exists, so nothing may be seeded or fabricated.
      expect(result.id_map["ids"].any? { |_i, d| d["symbol"] == "GhostWorker#perform" }).to be(false)
      expect(entrypoint?(result, "GhostWorker#helper")).to be(false)
    end
  end

  it "does not seed a plain class (no job evidence)" do
    in_repo(
      "app/models/plain.rb" => <<~RUBY
        class Plain
          def perform
            1
          end
        end
      RUBY
    ) do |dir|
      expect(entrypoint?(anonymize(dir), "Plain#perform")).to be(false)
    end
  end

  # --- category vocab (CR-4: PLURAL :jobs) -----------------------------------------

  it "stamps the PLURAL :jobs category on the seeded MethodEntry" do
    in_repo(
      "app/workers/foo_worker.rb" => <<~RUBY
        class FooWorker
          include Sidekiq::Job

          def perform
            1
          end
        end
      RUBY
    ) do |dir|
      table = Archbuddy::Collect::Adapters::Ruby::SymbolTable.new
      seeder_table_probe(dir, table)

      expect(table.entrypoint_category("FooWorker#perform")).to eq(:jobs)
      expect(table.method_for("FooWorker#perform").entrypoint_category).to eq(:jobs)
    end
  end

  # Run Pass 1 + the JobSeeder directly over the repo so the table (with its
  # seeded categories) is inspectable — the adapter's public result carries
  # only anonymized output.
  def seeder_table_probe(dir, table)
    m = Archbuddy::Collect::Adapters::Ruby
    Archbuddy::Collect::Adapters::Ruby::FileEnumerator.new(dir, config).files.each do |abs, rel|
      Prism.parse(File.read(abs)).value.accept(m::DefinitionPass.new(table, rel))
    end
    m::RootSeeders::JobSeeder.new.seed(table)
  end

  # --- selection: --root-types none --------------------------------------------------

  it "seeds nothing with root_types: :none while leaving existing entrypoints unchanged" do
    cfg = Archbuddy::Collect::Config.new(language: "ruby", root_types: :none)
    in_repo(
      "app/workers/foo_worker.rb" => <<~RUBY,
        class FooWorker
          include Sidekiq::Job

          def perform
            1
          end
        end
      RUBY
      "app/controllers/things_controller.rb" => <<~RUBY
        class ThingsController < ApplicationController
          def index
            1
          end
        end
      RUBY
    ) do |dir|
      result = anonymize(dir, cfg)
      expect(entrypoint?(result, "FooWorker#perform")).to be(false)
      expect(entrypoint?(result, "ThingsController#index")).to be(true)
    end
  end

  # --- strategy scoping: seeded roots live in :default only ---------------------------

  it "keeps :controllers strategy clean of seeded jobs" do
    cfg = Archbuddy::Collect::Config.new(language: "ruby", entrypoint_strategy: :controllers)
    in_repo(
      "app/workers/foo_worker.rb" => <<~RUBY,
        class FooWorker
          include Sidekiq::Job

          def perform
            1
          end
        end
      RUBY
      "app/controllers/things_controller.rb" => <<~RUBY
        class ThingsController < ApplicationController
          def index
            1
          end
        end
      RUBY
    ) do |dir|
      result = anonymize(dir, cfg)
      expect(entrypoint?(result, "FooWorker#perform")).to be(false)
      expect(entrypoint?(result, "ThingsController#index")).to be(true)
    end
  end
end
