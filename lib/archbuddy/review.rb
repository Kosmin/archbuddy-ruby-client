# frozen_string_literal: true

module Archbuddy
  # v0.15: the Review namespace — vintage acquisition, engine-exact client
  # traversal, delta math, business rules, and the reviewer formatters
  # (the `archbuddy diff` / `archbuddy lint` CI architecture reviewer).
  #
  # Everything in this namespace computes FRAGMENTS-FIRST from the committed
  # real-name cache (aggregate + detail tree): no engine invocation anywhere
  # on the review path.
  module Review
    # Hard acquisition/read failure (missing aggregate, no scored sources,
    # unresolvable refs, invalid vintage data). The CLI maps this to exit 2.
    class VintageError < StandardError; end
  end
end

require_relative "review/vintage"
require_relative "review/fragment_walk"
require_relative "review/graph"
require_relative "review/git"
require_relative "review/collector"
require_relative "review/delta"
