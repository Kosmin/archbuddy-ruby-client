# frozen_string_literal: true

module Billing
  # AR subclass. The implicit-self `where` inside `def self.overdue` is the
  # verified gotcha: its receiver is nil, so the db_op heuristic must consult
  # CLASS CONTEXT (am I in an AR subclass?), not receiver shape.
  class Invoice < ApplicationRecord
    def self.overdue
      where(state: "late")
    end

    # V4/P4 write sinks. `mark_paid!` writes a symbol-keyed literal hash =>
    # SPECIFIC (sink_open false). `bulk_update` writes a variable hash =>
    # OPEN_ENDED (sink_open true). Distinct db_op nodes (distinct Class.method).
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
