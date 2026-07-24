# frozen_string_literal: true

require "digest"

module Archbuddy
  module Review
    # One rule violation (I-P5'). Node findings carry value_raw/value_log2;
    # ep (use-case) findings carry `components` (multi-component ⇒
    # value_raw/value_log2 nil), `contributors` (≤5 + contributors_omitted),
    # and `entrypoint_kind`; ReviewSurface findings carry `scope: :pr` with
    # nil file/symbol (fingerprint nil→"" pin — deterministic, spec-asserted).
    class Finding
      FIELDS = %i[
        rule severity file symbol kind message
        value_raw value_log2 threshold_raw threshold_log2 delta_log2
        grandfathered_baseline enrichment
        components contributors contributors_omitted entrypoint_kind scope
      ].freeze

      attr_reader(*FIELDS)

      def initialize(rule:, severity:, message:, file: nil, symbol: nil, kind: nil,
                     value_raw: nil, value_log2: nil, threshold_raw: nil,
                     threshold_log2: nil, delta_log2: nil, grandfathered_baseline: nil,
                     enrichment: {}, components: nil, contributors: nil,
                     contributors_omitted: nil, entrypoint_kind: nil, scope: nil)
        @rule = rule
        @severity = severity
        @message = message
        @file = file
        @symbol = symbol
        @kind = kind
        @value_raw = value_raw
        @value_log2 = value_log2
        @threshold_raw = threshold_raw
        @threshold_log2 = threshold_log2
        @delta_log2 = delta_log2
        @grandfathered_baseline = grandfathered_baseline
        @enrichment = enrichment || {}
        @components = components
        @contributors = contributors
        @contributors_omitted = contributors_omitted
        @entrypoint_kind = entrypoint_kind
        @scope = scope
      end

      # Full 64-hex sha256 (P5); nil file/symbol render "" (ReviewSurface pin).
      def fingerprint
        @fingerprint ||= Digest::SHA256.hexdigest("#{@rule} #{@file} #{@symbol}")
      end

      def grandfathered_refire?
        !@grandfathered_baseline.nil?
      end
    end
  end
end
