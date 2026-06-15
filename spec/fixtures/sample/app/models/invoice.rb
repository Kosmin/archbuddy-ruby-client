# frozen_string_literal: true

module Billing
  # AR subclass. The implicit-self `where` inside `def self.overdue` is the
  # verified gotcha: its receiver is nil, so the db_op heuristic must consult
  # CLASS CONTEXT (am I in an AR subclass?), not receiver shape.
  class Invoice < ApplicationRecord
    def self.overdue
      where(state: "late")
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
