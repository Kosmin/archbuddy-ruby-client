# frozen_string_literal: true

module Billing
  # AR subclass. The implicit-self `where` inside `def self.overdue` is the
  # verified gotcha: its receiver is nil, so the db_op heuristic must consult
  # CLASS CONTEXT (am I in an AR subclass?), not receiver shape.
  class Invoice < ApplicationRecord
    def self.overdue
      where(state: "late")
    end

    # AR write sinks. Both are now plain COST-1 db_op terminals (L3/v0.6 — no
    # sink_open / write-specificity). `mark_paid!` and `bulk_update` mint
    # distinct db_op nodes (distinct Class.method); the arg shapes no longer
    # carry any cost signal.
    def self.mark_paid!
      update_all(state: "paid")
    end

    def self.bulk_update(attrs)
      update(attrs)
    end

    def total
      subtotal + tax            # operator `+` must be dropped (D36)
    end

    def subtotal
      100
    end

    def tax
      ExternalTaxApi.compute(self)  # unresolved -> single external sink
    end
  end
end
