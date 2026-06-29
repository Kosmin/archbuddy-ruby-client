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

          # AR op-kind partition (V4/P4). Every name in ACTIVE_RECORD falls into
          # exactly one of write/destroy/read so the collector can classify a
          # db_op call site's effect. Used ONLY to derive the opaque `sink_open`
          # boolean the engine consumes (L2) — never serialized as op-kind.
          AR_WRITE = %w[
            create create! new save save! update update! update_all
            update_column update_columns increment! decrement! touch
            insert insert_all upsert upsert_all
            find_or_create_by find_or_create_by!
          ].to_set.freeze

          AR_DESTROY = %w[
            destroy destroy! destroy_all delete delete_all
          ].to_set.freeze

          # Everything else in ACTIVE_RECORD is a read (queries/scopes/aggregates).
          AR_READ = (ACTIVE_RECORD - AR_WRITE - AR_DESTROY).freeze

          # Field-naming writes: the subset of AR_WRITE whose arguments carry the
          # written field payload, so write `specificity` (symbol-keyed literal
          # hash = specific vs. variable/splat/string-SQL = open_ended) is
          # meaningful. `save`/`touch`/`find_or_create_by` carry no inspectable
          # field hash at the call site, so they are NOT customizability concerns
          # (specificity n/a → engine factor 1).
          AR_FIELD_WRITE = %w[
            create create! new update update! update_all update_columns
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

          def active_record_method?(name)
            ACTIVE_RECORD.include?(name.to_s)
          end

          # Classify an AR method's effect (V4/P4). Only meaningful when
          # active_record_method?(name) is already true. destroy > write > read.
          def ar_op_kind(name)
            n = name.to_s
            return "destroy" if AR_DESTROY.include?(n)
            return "write"   if AR_WRITE.include?(n)

            "read"
          end

          # The subset of writes whose argument shape determines write
          # specificity (open_ended vs. specific). See AR_FIELD_WRITE.
          def ar_field_write?(name)
            AR_FIELD_WRITE.include?(name.to_s)
          end
        end
      end
    end
  end
end
