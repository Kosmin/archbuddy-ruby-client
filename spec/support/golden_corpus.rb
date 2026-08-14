# frozen_string_literal: true

require "tmpdir"
require "fileutils"
require "prism"

module Archbuddy
  # THE PURITY GATE's corpus + capture harness (configurator W2).
  #
  # The profile migration is a DATA MOVE: the collector's ecosystem vocabulary
  # stops being hardcoded Ruby constants and starts being read from the
  # engine-shipped profile document. The proof that such a move is correct is
  # that the EMITTED BYTES DO NOT CHANGE — so this module captures graph.yml +
  # id-map.yml for a set of synthetic corpora, and the golden spec asserts they
  # match committed bytes produced BEFORE the migration.
  #
  # EVERY CORPUS IS SYNTHETIC AND PUBLIC (L9): inline sources authored here, no
  # analysed-repo data, no developer paths. The tmpdir root never reaches the
  # captured bytes (rel_file keys only).
  #
  # WHY `TOOL` IS FROZEN: `generator.tool` carries `Archbuddy::VERSION`, which
  # is a release stamp, not vocabulary. Pinning it here keeps a version bump
  # from churning the golden; nothing else in the captured bytes is normalized.
  #
  # WHY THE CRON LEDGER IS A SEPARATE ARTIFACT: the cron seeder is LINK-only —
  # it confirms roots other seeders already tagged and mutates nothing. Its
  # vocabulary (schedule config paths, the perform-family runner verbs) is
  # therefore INVISIBLE in graph.yml. Capturing its confirm/decline ledger is
  # the only way the gate can see a cron-vocabulary regression at all.
  #
  # REGENERATE (only ever from PRE-migration code, or when a corpus changes):
  #   ARCHITECTURE_AUDITOR_PATH=... bundle exec ruby \
  #     -Ilib -Ispec -e 'require "spec_helper"; \
  #       require "support/golden_corpus"; Archbuddy::GoldenCorpus.write_golden!'
  module GoldenCorpus
    GOLDEN_DIR = File.expand_path("../fixtures/golden", __dir__)

    # Pinned generator stamp — see "WHY `TOOL` IS FROZEN" above.
    TOOL = "archbuddy golden"

    # Every root seeder INCLUDING cron (which `:all` deliberately excludes),
    # so the cron corpus exercises the link path.
    ALL_ROOT_TYPES = "jobs,rake,middleware,script,cron"

    module_function

    # @return [Hash{String => Hash}] corpus name => { files:, root_types:, entrypoints: }
    #   `files` nil means "use the on-disk fixture at `path`".
    def corpora
      {
        "sample" => { path: File.expand_path("../fixtures/sample", __dir__) },
        "rails"  => { files: rails_files },
        "jobs"   => { files: jobs_files, root_types: ALL_ROOT_TYPES },
        "egress" => { files: egress_files },
        "roots"  => { files: roots_files, root_types: ALL_ROOT_TYPES }
      }
    end

    # The corpus whose cron ledger is captured (the only one carrying schedule
    # configs).
    CRON_CORPUS = "jobs"

    # Capture one corpus. @return [Hash{String => String}] artifact => bytes
    def capture(name)
      spec = corpora.fetch(name)
      with_root(spec) do |root|
        artifacts = graph_artifacts(root, config_for(spec))
        artifacts["cron-ledger"] = cron_ledger(root) if name == CRON_CORPUS
        artifacts
      end
    end

    def golden_path(name, artifact)
      File.join(GOLDEN_DIR, "#{name}.#{artifact}.yml")
    end

    def write_golden!
      FileUtils.mkdir_p(GOLDEN_DIR)
      corpora.each_key do |name|
        capture(name).each do |artifact, bytes|
          File.write(golden_path(name, artifact), bytes)
        end
      end
    end

    # --- capture internals -------------------------------------------------

    def config_for(spec)
      Collect::Config.new(
        language:            "ruby",
        entrypoint_strategy: spec[:entrypoints] || :default,
        probes:              :all,
        root_types:          spec[:root_types] || :all
      )
    end

    def with_root(spec)
      return yield(spec[:path]) if spec[:path]

      Dir.mktmpdir("archbuddy-golden") do |dir|
        spec[:files].each do |rel, source|
          abs = File.join(dir, rel)
          FileUtils.mkdir_p(File.dirname(abs))
          File.write(abs, source)
        end
        yield(dir)
      end
    end

    def graph_artifacts(root, config)
      adapter = Collect::Registry.for("ruby").new(root, config)
      result  = Collect::Anonymizer.new(adapter.collect, tool: TOOL, adapter: "ruby").call
      dump    = ArchitectureAuditor::Contract::Serializer

      { "graph" => dump.dump(result.graph), "id-map" => dump.dump(result.id_map) }
    end

    # Rebuild just enough of the pipeline (Pass 1 + the seeder chain) to reach
    # the cron seeder INSTANCE and read its ledger — the adapter builds its
    # seeders internally and discards them.
    def cron_ledger(root)
      ruby   = Collect::Adapters::Ruby
      config = Collect::Config.new(language: "ruby", root_types: ALL_ROOT_TYPES)

      fragments = ruby::FileEnumerator.new(root, config).files.map do |abs, rel|
        source = File.read(abs)
        Collect::Fragment.new(
          rel_file:     rel,
          content_hash: Cache::ChangeDetector.content_hash(source),
          parsed_value: Prism.parse(source).value
        )
      end

      table = ruby::SymbolTable.new
      fragments.each { |f| f.parsed_value.accept(ruby::DefinitionPass.new(table, f.rel_file)) }

      seeders = ruby::RootSeederRegistry.for(config)
      seeders.each { |seeder| seeder.seed(table, fragments: fragments, root: root) }

      cron = seeders.find { |seeder| seeder.root_type == :cron }
      ArchitectureAuditor::Contract::Serializer.dump(
        "confirmed" => cron.confirmed.sort, "declined" => cron.declined.sort
      )
    end

    # --- the corpora -------------------------------------------------------

    # ORM vocabulary (implicit-self AND constant receiver), the ORM + controller
    # base classes, the controller NAME SUFFIX, the operator deny-list, the
    # metaprogramming flag set, and the resolvable-dispatch set.
    def rails_files
      {
        "app/models/widget.rb" => <<~RUBY,
          class Widget < ApplicationRecord
            def self.recent
              where(active: true).order(:created_at).limit(10)
            end

            def refresh!
              reload
              touch
              update!(seen: true)
            end
          end
        RUBY
        "app/models/ledger_entry.rb" => <<~RUBY,
          class LedgerEntry < ActiveRecord::Base
            def self.totals
              group(:kind).sum(:amount)
            end
          end
        RUBY
        "app/models/archived_widget.rb" => <<~RUBY,
          class ArchivedWidget < Widget
            def purge
              destroy_all
            end
          end
        RUBY
        "app/controllers/widgets_controller.rb" => <<~RUBY,
          class WidgetsController < ApplicationController
            def index
              Widget.where(archived: false).pluck(:id)
            end

            def create
              Widget.create!(name: "w")
            end
          end
        RUBY
        "app/controllers/api_controller.rb" => <<~RUBY,
          class ApiController < ActionController::API
            def show
              Widget.find_by(id: 1)
            end
          end
        RUBY
        # Controller BASE CLASSES, each on a class whose name does NOT end in
        # `Controller` — otherwise the name-suffix rule masks the base rule and
        # dropping a base from the profile changes nothing observable.
        "app/api/public_endpoints.rb" => <<~RUBY,
          class PublicEndpoints < ActionController::API
            def show
              Widget.pluck(:id)
            end
          end
        RUBY
        "app/legacy/base_actions.rb" => <<~RUBY,
          class BaseActions < ActionController::Base
            def edit
              Widget.first
            end
          end
        RUBY
        "app/legacy/app_actions.rb" => <<~RUBY,
          class AppActions < ApplicationController
            def update
              Widget.update_all(seen: true)
            end
          end
        RUBY
        "app/legacy/reports_controller.rb" => <<~RUBY,
          class ReportsController
            def summary
              LedgerEntry.totals
            end
          end
        RUBY
        "app/services/dynamics.rb" => <<~RUBY,
          class Dynamics
            def arithmetic(a, b)
              (a + b) * 2 - 1 <= a[0]
            end

            def resolvable
              Widget.send(:recent)
              Widget.public_send("recent")
            end

            def blind(name)
              Widget.send(name)
              define_method(:generated) { 1 }
              instance_eval("1 + 1")
              const_get(:Widget)
            end

            def tried(obj)
              obj.try(:recent)
            end
          end
        RUBY
      }
    end

    # Job discriminators (modern mixin, legacy base, ActiveJob base, an
    # inherited in-app base), the async DISPATCH verbs, and both schedule
    # config dialects.
    def jobs_files
      {
        "app/jobs/mailer_worker.rb" => <<~RUBY,
          class MailerWorker
            include Sidekiq::Job

            def perform(id)
              id
            end
          end
        RUBY
        "app/jobs/legacy_worker.rb" => <<~RUBY,
          class LegacyWorker < Sidekiq::Worker
            def perform
              :ok
            end
          end
        RUBY
        "app/jobs/report_job.rb" => <<~RUBY,
          class ReportJob < ApplicationJob
            def perform
              :ok
            end
          end
        RUBY
        "app/jobs/base_job.rb" => <<~RUBY,
          class BaseJob < ActiveJob::Base
          end

          class NestedJob < BaseJob
            def perform
              :ok
            end
          end
        RUBY
        "app/jobs/ghost_job.rb" => <<~RUBY,
          class GhostJob < ApplicationJob
          end
        RUBY
        "app/services/enqueuer.rb" => <<~RUBY,
          class Enqueuer
            def call
              MailerWorker.perform_async(1)
              ReportJob.perform_later
              LegacyWorker.perform_in(60)
              NestedJob.set(wait: 5).perform_at(1)
              MailerWorker.perform_now
            end
          end
        RUBY
        "lib/tasks/reports.rake" => <<~RUBY,
          namespace :db do
            task :backup do
              ReportJob.perform_later
            end
          end
        RUBY
        "config/schedule.yml" => <<~YAML,
          nightly_report:
            cron: "0 0 * * *"
            class: "ReportJob"
          ghost_entry:
            cron: "0 1 * * *"
            class: "MissingJob"
        YAML
        "config/schedule.rb" => <<~RUBY
          every 1.day do
            rake "db:backup"
            runner "MailerWorker.perform_async"
            runner "ReportJob.perform_now"
            runner "ReportJob.deliver"
            command "/usr/bin/true"
          end
        RUBY
      }
    end

    # Egress roots (exact constants AND the `Aws::` prefix), the HTTP verb
    # guard, the queue category, and the plain gem category.
    def egress_files
      {
        "app/clients/http_client.rb" => <<~RUBY,
          class HttpClient
            def fetch
              Faraday.get("https://example.test")
              Net::HTTP.start("example.test")
              HTTParty.post("https://example.test")
              RestClient.put("https://example.test", {})
              Typhoeus.head("https://example.test")
              Excon.request(method: :get)
              HTTP.delete("https://example.test")
            end

            def guarded
              HTTP.configure
              Faraday.default_adapter
            end
          end
        RUBY
        "app/clients/storage.rb" => <<~RUBY,
          class Storage
            def put
              Aws::S3::Client.new.put_object(bucket: "b")
              Aws::SNS::Client.new
            end
          end
        RUBY
        "app/clients/queue_client.rb" => <<~RUBY,
          class QueueClient
            def enqueue
              OutOfTreeWorker.perform_async(1)
              OutOfTreeJob.perform_later
            end
          end
        RUBY
        "app/clients/gem_client.rb" => <<~RUBY
          class GemClient
            def call
              SomeGem.configure
              Another::Gem.build
            end
          end
        RUBY
      }
    end

    # Grape endpoints, Rack middleware + its registration, a real `script/`
    # shebang file, a binstub-shaped decline, and rake tasks.
    def roots_files
      {
        "app/api/users_api.rb" => <<~RUBY,
          class UsersApi < Grape::API
            get "/users" do
              Widget.all
            end

            post "/users" do
              Widget.create!(name: "w")
            end
          end
        RUBY
        "app/api/admin_api.rb" => <<~RUBY,
          class AdminApi < Grape::API::Instance
            mount UsersApi

            delete "/admin" do
              :ok
            end
          end
        RUBY
        "app/models/widget.rb" => <<~RUBY,
          class Widget < ApplicationRecord
          end
        RUBY
        "app/middleware/request_timer.rb" => <<~RUBY,
          class RequestTimer
            def initialize(app)
              @app = app
            end

            def call(env)
              @app.call(env)
            end
          end
        RUBY
        "app/middleware/unregistered_timer.rb" => <<~RUBY,
          class UnregisteredTimer
            def initialize(app)
              @app = app
            end

            def call(env)
              @app.call(env)
            end
          end
        RUBY
        "config/application.rb" => <<~RUBY,
          module Sample
            class Application
              def configure(config)
                config.middleware.use RequestTimer
              end
            end
          end
        RUBY
        "script/import.rb" => <<~RUBY,
          #!/usr/bin/env ruby

          def import_everything
            Widget.all
          end

          import_everything
        RUBY
        "scripts/backfill.rb" => <<~RUBY,
          #!/usr/bin/env ruby

          def backfill
            :ok
          end
        RUBY
        "bin/setup.rb" => <<~RUBY,
          #!/usr/bin/env ruby

          require "bundler/setup"
          require_relative "../config/application"
        RUBY
        "lib/tasks/maintenance.rake" => <<~RUBY
          task :vacuum do
            Widget.all
          end
        RUBY
      }
    end
  end
end
