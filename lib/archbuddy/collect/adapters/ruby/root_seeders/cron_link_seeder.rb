# frozen_string_literal: true

require "psych"
require_relative "../root_seeder"
require_relative "../root_dsl/schedule_config"

module Archbuddy
  module Collect
    module Adapters
      module Ruby
        module RootSeeders
          # Cron LINK seeder (v0.10 W4b — L8 "cron = LINK only"). DEFAULT OFF:
          # registered in the RootSeederRegistry but EXCLUDED from the
          # `--root-types all` default set until the W7 validation wave proves
          # a reachability lift (R10). Select explicitly: `--root-types
          # jobs,rake,cron`.
          #
          # Cron introduces NO new root method — it LINKS an ALREADY-seeded
          # job/rake root as "reachable even if never enqueued in-tree". Its
          # ONLY action is CONFIRM-OR-DECLINE against the existing table
          # (I1/L4 — the highest-fabrication-risk root, so it never mints):
          #   - sidekiq-cron YAML `class: "MyJob"` → CONFIRMED iff
          #     `MyJob#perform` is ALREADY a seeded root (entrypoint_category
          #     non-nil). A class absent from the table, or present but not a
          #     seeded root → DECLINED (never invent a root from a config name).
          #   - whenever `rake "db:backup"` → CONFIRMED iff a minted
          #     `rake:db:backup[N]` root exists (F5 FQ shape, any ordinal).
          #   - whenever `runner "MyJob.perform_now"` → resolvable iff the
          #     literal is Const.perform-family AND `Const#perform` is an
          #     already-seeded root; anything else DECLINED.
          #   - whenever `command "…"` / non-literal runner / clockwork →
          #     OPAQUE → DECLINED (L8).
          #
          # CONFIRM IS A TABLE NO-OP: the target root is already categorized
          # (first-write-wins), so the entrypoint set and every category count
          # are UNCHANGED — the category stays :jobs/:rake, never re-tagged
          # :cron. The confirm/decline ledger below is the seeder's only
          # output (reachability documentation + spec surface).
          #
          # OUT OF THE PURE-AST PATH (by design, W4b): schedule configs are
          # read directly by CONVENTION PATH (never via FileEnumerator),
          # Psych.safe_load'd / Prism-parsed defensively — malformed or
          # unreadable config → declined/skip, NEVER a crashed collect.
          class CronLinkSeeder < RootSeeder
            # Convention paths (relative to the audited root) — L8 dialects.
            SIDEKIQ_CRON_PATHS = ["config/schedule.yml", "config/sidekiq_cron.yml"].freeze
            WHENEVER_PATH      = "config/schedule.rb"

            # Runner method names that provably target a job's #perform root.
            PERFORM_FAMILY = %w[perform perform_now perform_async perform_later perform_inline].freeze

            def self.root_type = :cron

            def root_type = :cron

            # The confirm/decline ledger for THIS seed run:
            #   confirmed — ["MyJob#perform", "rake:db:backup[0]", …] linked roots
            #   declined  — ["class:Ghost", "runner", "command", …] evidence tags
            attr_reader :confirmed, :declined

            def initialize
              super
              @confirmed = []
              @declined  = []
            end

            # LINK-only: no marks, no nodes, no edges — confirm-or-decline.
            def seed(table, fragments: nil, root: nil)
              return if root.nil? # disk-shaped evidence needs the capture root

              SIDEKIQ_CRON_PATHS.each { |rel| link_sidekiq_cron(table, File.join(root, rel)) }
              link_whenever(table, File.join(root, WHENEVER_PATH))
            end

            private

            def link_sidekiq_cron(table, path)
              doc = safe_yaml(path)
              return if doc == :absent

              if doc == :malformed
                @declined << "sidekiq_cron:#{File.basename(path)}:malformed"
                return
              end

              entries = RootDsl::ScheduleConfig.sidekiq_cron_entries(doc)
              entries.job_classes.each { |klass| link_job_class(table, klass) }
              @declined.concat(entries.opaque)
            end

            def link_whenever(table, path)
              source = safe_read(path)
              return if source.nil?

              entries = RootDsl::ScheduleConfig.whenever_entries(source)
              entries.rake_names.each { |name| link_rake_task(table, name) }
              entries.runner_targets.each { |target| link_runner(table, target) }
              @declined.concat(entries.opaque)
            end

            # `class: "MyJob"` → CONFIRM iff MyJob#perform is already a seeded
            # root. Absent class / unseeded perform → DECLINE (I1).
            def link_job_class(table, klass)
              fq = "#{klass}#perform"
              if table.entrypoint_category(fq)
                @confirmed << fq
              else
                @declined << "class:#{klass}"
              end
            end

            # `rake "db:backup"` → CONFIRM iff a minted rake root with the F5
            # FQ shape `rake:db:backup[N]` exists (any ordinal — within-file
            # re-declarations mint distinct ordinals, M5).
            def link_rake_task(table, name)
              pattern = /\Arake:#{Regexp.escape(name)}\[\d+\]\z/
              linked  = table.methods.keys.select do |fq|
                fq.match?(pattern) && table.entrypoint_category(fq)
              end
              if linked.empty?
                @declined << "rake:#{name}"
              else
                @confirmed.concat(linked)
              end
            end

            # `runner "MyJob.perform_now"` → CONFIRM iff perform-family AND
            # Const#perform is an already-seeded root; else DECLINE (L8
            # "resolvable runner" = resolves to an already-detected root).
            def link_runner(table, target)
              match = target.match(RootDsl::ScheduleConfig::RUNNER_TARGET)
              const, meth = match && match.captures
              unless const && PERFORM_FAMILY.include?(meth)
                @declined << "runner:#{target}"
                return
              end

              link_job_class(table, const)
            end

            # :absent (no file) | :malformed (unparseable/unsafe) | parsed doc.
            def safe_yaml(path)
              raw = safe_read(path)
              return :absent if raw.nil?

              Psych.safe_load(raw) || :malformed
            rescue Psych::Exception
              :malformed
            end

            def safe_read(path)
              return nil unless File.file?(path)

              File.read(path)
            rescue SystemCallError, IOError
              nil
            end
          end
        end
      end
    end
  end
end
