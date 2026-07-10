# frozen_string_literal: true

require "set"

module Archbuddy
  module Collect
    module Adapters
      module Ruby
        # Static vocabularies the resolver consults (D24/D36). Pure data — no
        # behavior — so the heuristic tiers stay readable and testable.
        module Vocab
          # D36 operator deny-list: these method names are dropped entirely (no
          # node, no edge). Arithmetic/comparison/indexing/coercion operators
          # carry no architectural signal and would only add noise.
          # NOTE: `call`/`call!` are deliberately NOT denied here. The proc/lambda
          # case (`foo.()` / `foo.call`) has a *variable* receiver, so it never
          # matches R4's constant-receiver tier and falls through to <external> —
          # no fabricated edge. A *constant* receiver whose `#call` is a captured
          # method node (interactors, service/command objects: `SomeInteractor.call`)
          # resolves via R4's const-instance fallback to `<Const>#call` — a real,
          # provable edge. So denying `call` would only blind us to genuine
          # service-object dispatch while the operator gate already kept the noise out.
          OPERATOR_DENY = %w[
            + - * / % ** == != < > <= >= <=> === =~ !~
            << >> & | ^ ~ ! [] []= +@ -@
          ].to_set.freeze

          # Metaprogramming methods: flagged (so the capture is honest about a
          # blind spot) but produce NO edge — we cannot statically know the
          # target, and fabricating one would be a lie (D24).
          METAPROGRAMMING = %w[
            define_method send public_send __send__ method_missing
            instance_eval class_eval module_eval eval instance_exec
            const_get const_set define_singleton_method
          ].to_set.freeze

          # v0.10 W1-D (L21): dispatch verbs whose FIRST literal Symbol/String
          # argument names a resolvable target (`x.send(:foo)` → `x.foo`). A
          # meta verb in THIS set with a literal arg is NOT a dynamic blind
          # spot — the MetaSendProbe (R5) resolves it, gated on table.method?.
          # `try`/`try!` live ONLY here (never in METAPROGRAMMING): a dynamic
          # `.try(name)` falls through to R9 <external> exactly as before —
          # they are resolvable-literal candidates, not metaprogramming flags.
          META_RESOLVABLE = %w[
            send public_send __send__ try try!
          ].to_set.freeze

          # ActiveRecord query/persistence vocabulary. A call to one of these
          # whose class context is an AR subclass is a db_op (D24). This is
          # consulted alongside class context, never on receiver shape alone —
          # see the verified implicit-self gotcha.
          ACTIVE_RECORD = %w[
            all where find find_by find_by! find_each find_in_batches
            first last take pluck pick exists? count sum average minimum maximum
            create create! new save save! update update! update_all update_column
            update_columns destroy destroy! destroy_all delete delete_all
            increment! decrement! touch reload
            order limit offset group having joins includes preload eager_load
            references distinct select having lock readonly
            find_or_create_by find_or_create_by! find_or_initialize_by
            insert insert_all upsert upsert_all
          ].to_set.freeze

          # Base classes that mark a class as an ActiveRecord model.
          ACTIVE_RECORD_BASES = %w[
            ApplicationRecord ActiveRecord::Base
          ].to_set.freeze

          # Base classes that mark a class as a Rails controller.
          CONTROLLER_BASES = %w[
            ApplicationController ActionController::Base ActionController::API
          ].to_set.freeze

          module_function

          def operator?(name)
            OPERATOR_DENY.include?(name.to_s)
          end

          def metaprogramming?(name)
            METAPROGRAMMING.include?(name.to_s)
          end

          def meta_resolvable?(name)
            META_RESOLVABLE.include?(name.to_s)
          end

          def active_record_method?(name)
            ACTIVE_RECORD.include?(name.to_s)
          end

          # --- Ingress root detection (v0.10 W1-B) -------------------------
          # Static discriminators for job classes (L8). Consulted by the
          # JobSeeder root seeder; pure data, appended additively (disjoint
          # from the resolver vocab above).

          # Modern Sidekiq marks a worker with `include Sidekiq::Job` (or the
          # older `include Sidekiq::Worker`). Matched against the L14 general
          # mixin capture (ClassEntry#mixins via chain_any_module?).
          SIDEKIQ_WORKER_MIXINS = %w[
            Sidekiq::Job Sidekiq::Worker
          ].to_set.freeze

          # Legacy Sidekiq subclassing style: `class Foo < Sidekiq::Worker`.
          # Matched against the superclass chain (chain_any?).
          SIDEKIQ_WORKER_BASES = %w[
            Sidekiq::Worker
          ].to_set.freeze

          # ActiveJob subclassing: `class Foo < ApplicationJob` /
          # `< ActiveJob::Base`. Matched against the superclass chain, so an
          # intermediate in-app base class still counts.
          ACTIVE_JOB_BASES = %w[
            ApplicationJob ActiveJob::Base
          ].to_set.freeze
        end
      end
    end
  end
end
