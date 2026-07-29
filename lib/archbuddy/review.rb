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
require_relative "review/score_rollup"
require_relative "review/git"
require_relative "review/collector"
require_relative "review/delta"
require_relative "review/vintage_source"
require_relative "review/finding"
require_relative "review/findings"
require_relative "review/rules/base"
require_relative "review/rule_engine"
require_relative "review/rules/exponential_node"
require_relative "review/rules/use_case_complexity"
require_relative "review/rules/use_case_dividend"
require_relative "review/rules/firewall_breaches"
require_relative "review/rules/review_surface"
require_relative "review/rules/multiplicative_growth"
require_relative "review/rules/complexity_ratchet"
require_relative "review/formatter"
require_relative "review/formatters/terminal"
require_relative "review/formatters/markdown"
require_relative "review/formatters/json"
require_relative "review/calibration"
require_relative "review/calibration/lines"
