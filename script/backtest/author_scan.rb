# frozen_string_literal: true

module Backtest
  # The A6 author-scan (defense in depth — the whitelist reader already makes
  # author data unreachable by construction). Identifier classes only; the
  # prose word "author" is allowed.
  module AuthorScan
    HANDLE = /@[A-Za-z0-9][A-Za-z0-9-]{0,38}\b/
    EMAIL = /[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}/

    module_function

    # @return [Array<String>] matches (empty = clean; NO allowlist)
    def scan(text)
      (text.scan(EMAIL) + text.scan(HANDLE)).uniq
    end

    # Degenerate guard: an empty document or one without the adoption table
    # must never pass the gate.
    def degenerate?(text)
      text.strip.empty? || !text.include?("| metric |")
    end
  end
end
