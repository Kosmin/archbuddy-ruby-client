# frozen_string_literal: true

require_relative "../root_seeder"
require_relative "../vocab"

module Archbuddy
  module Collect
    module Adapters
      module Ruby
        module RootSeeders
          # Seeds Sidekiq / ActiveJob workers as :jobs ingress roots
          # (v0.10 W1-B). A TABLE-WALKER seeder: jobs are declared through
          # class structure (mixins / superclasses), which Pass 1 already
          # captured — no AST re-walk needed, `fragments` is ignored.
          #
          # A class is a job iff (L8 static discriminators):
          #   - its mixin chain includes Sidekiq::Job or Sidekiq::Worker
          #     (modern `include Sidekiq::Job`, via the L14 general mixin
          #     capture + chain_any_module?), OR
          #   - its superclass chain hits Sidekiq::Worker (legacy
          #     `class Foo < Sidekiq::Worker`), OR
          #   - its superclass chain hits ApplicationJob / ActiveJob::Base
          #     (chain-walked, so an intermediate in-app base still counts).
          #
          # NEVER-FABRICATE (L4): the job's `#perform` instance method must
          # provably exist in the table (`table.method?("Fq#perform")`);
          # otherwise the class is DECLINED — no root, no category.
          class JobSeeder < RootSeeder
            def self.root_type = :jobs

            def root_type = :jobs

            def seed(table, fragments: nil, root: nil)
              table.classes.each_key do |class_fq|
                next unless job_class?(table, class_fq)

                perform_fq = "#{class_fq}#perform"
                next unless table.method?(perform_fq) # L4 gate — decline

                table.mark_entrypoint(perform_fq, :jobs)
              end
            end

            private

            def job_class?(table, class_fq)
              sidekiq_mixin?(table, class_fq) || job_base?(table, class_fq)
            end

            def sidekiq_mixin?(table, class_fq)
              table.chain_any_module?(class_fq) do |mixin_fq|
                Vocab::SIDEKIQ_WORKER_MIXINS.include?(mixin_fq)
              end
            end

            def job_base?(table, class_fq)
              table.chain_any?(class_fq) do |entry|
                superclass = entry.superclass.to_s
                Vocab::SIDEKIQ_WORKER_BASES.include?(superclass) ||
                  Vocab::ACTIVE_JOB_BASES.include?(superclass)
              end
            end
          end
        end
      end
    end
  end
end
