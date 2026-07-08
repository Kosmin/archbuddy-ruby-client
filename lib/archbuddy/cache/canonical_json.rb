# frozen_string_literal: true

require "json"

module Archbuddy
  module Cache
    # Canonical, byte-STABLE JSON serialization for the committed cache (P2/L5).
    #
    # The committed `.archbuddy/` layer must diff cleanly and pass the CI
    # freshness gate (`collect --check` / `git diff --exit-code`), so two runs
    # over the same tree MUST produce byte-identical bytes. The engine's
    # Serializer sorts HASH keys but PRESERVES array order; the committed layer
    # needs BOTH: sorted object keys AND a canonical, caller-imposed array order.
    #
    # This module provides:
    #   - `.dump(value)`  — deterministic JSON: object keys sorted recursively at
    #                       every level, fixed float precision, trailing newline.
    #     (Array ORDER is the caller's responsibility — the writer sorts nodes by
    #      class-path key, edges by [from,to,calls], findings by (type,id) BEFORE
    #      handing arrays here; see Cache::Writer / C3 tiebreaker.)
    #   - `.round_float(f)` — the single fixed-precision rounding all committed
    #     floats pass through, so a numerically-unchanged score serializes
    #     identically run-to-run (no jitter → no spurious `--check` diff).
    #
    # Determinism rules:
    #   * object keys sorted ascending by String key at EVERY nesting level
    #   * floats rounded to FLOAT_PRECISION decimals; an integral float (2.0)
    #     is emitted as `2.0` (not `2`) so the type is stable across runs
    #   * NaN/Infinity are never valid committed values (scores are finite);
    #     they raise rather than emit non-portable JSON
    #   * exactly one trailing "\n" (POSIX text file; stable `git diff`)
    module CanonicalJson
      # Fixed committed-float precision. Chosen to comfortably exceed the score
      # model's own rounding while staying well inside a Float's exact range, so
      # rounding is idempotent and a re-run never jitters the last digit.
      FLOAT_PRECISION = 6

      module_function

      # @param value [Object] a JSON-able Ruby value (Hash/Array/String/Numeric/
      #   true/false/nil). Object keys are sorted recursively; floats are rounded.
      # @return [String] canonical JSON with a single trailing newline.
      def dump(value)
        "#{JSON.generate(canonicalize(value))}\n"
      end

      # Round a float to the fixed committed precision. Integers pass through
      # unchanged (they are already exact). A float that is integral after
      # rounding stays a Float (2.0), preserving type stability.
      def round_float(number)
        return number if number.is_a?(Integer)

        unless number.finite?
          raise ArgumentError, "cannot serialize non-finite float into committed cache: #{number.inspect}"
        end

        number.round(FLOAT_PRECISION)
      end

      # Recursively impose canonical form: sort Hash keys (by their String form),
      # round Floats, recurse into Arrays (order preserved — the CALLER canonicalizes
      # array order before calling dump).
      def canonicalize(value)
        case value
        when Hash
          value
            .sort_by { |k, _v| k.to_s }
            .each_with_object({}) { |(k, v), acc| acc[k.to_s] = canonicalize(v) }
        when Array
          value.map { |v| canonicalize(v) }
        when Float
          round_float(value)
        else
          value
        end
      end
    end
  end
end
