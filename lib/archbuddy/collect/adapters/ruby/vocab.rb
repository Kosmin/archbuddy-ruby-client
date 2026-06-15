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
          OPERATOR_DENY = %w[
            + - * / % ** == != < > <= >= <=> === =~ !~
            << >> & | ^ ~ ! [] []= +@ -@ call
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
        end
      end
    end
  end
end
