# frozen_string_literal: true

module Archbuddy
  module Report
    # R-1: presentation-agnostic value objects produced by the Reconnect join
    # engine and consumed by the Ranker / Formatters. These carry de-anonymized
    # data but make NO rendering decisions and NEVER recompute anything (D17).
    module Model
      # A de-anonymized location: the real {file, line, symbol} a node resolves
      # to. For ids absent from the id-map (e.g. `ext_` external sinks or any
      # unknown id) this is a graceful PLACEHOLDER — `resolved?` is false and the
      # symbol reads like `<external …>` — and constructing it NEVER raises.
      Location = Struct.new(:id, :file, :line, :symbol, :kind, :class_id, :resolved, keyword_init: true) do
        def resolved?
          resolved
        end

        # "symbol (file:line)" when resolved; the placeholder symbol otherwise.
        # NOTE: currently unused on the hotspot/bottleneck render path — the
        # terminal formatter composes `symbol` + `file_line` itself (the two share
        # the same field set but differ in punctuation). Kept as the canonical
        # single-string rendering of a Location for ad-hoc/future callers.
        def display
          return symbol unless resolved?

          loc = [file, line].compact.join(":")
          loc.empty? ? symbol : "#{symbol} (#{loc})"
        end

        # "file:line" or "" when unresolved/locationless.
        def file_line
          return "" unless resolved?

          [file, line].compact.join(":")
        end
      end

      # A single ranked bottleneck: one opaque node de-anonymized to a real
      # symbol, carrying its VERBATIM 8 metric values + clutter_score (copied
      # straight from findings.yml — never recomputed) and the findings that
      # touch it.
      #
      # @param id            [String] the opaque node id (n_/ext_/cls_)
      # @param location      [Location] resolved {file,line,symbol,…}
      # @param kind          [String,nil] node kind from the id-map (endpoint/db_op/…)
      # @param class_id      [String,nil] owning class rollup id (cls_), if any
      # @param metrics       [Hash{String=>Numeric,nil}] the 8 metric values, VERBATIM
      # @param clutter_score [Numeric] the score, VERBATIM from findings.yml
      # @param findings      [Array<Finding>] findings whose node/path touch this id
      Bottleneck = Struct.new(
        :id, :location, :kind, :class_id, :metrics, :clutter_score, :findings,
        keyword_init: true
      ) do
        # class_rollup bottlenecks (D9) are produced by the Ranker; plain nodes
        # are produced by Reconnect. Defaults to :node.
        def rollup?
          kind == "class_rollup"
        end

        def symbol
          location.symbol
        end
      end

      # A de-anonymized finding. Node-type findings (high_fan_in, high_fan_out,
      # high_centrality, orphan, dead) carry a single resolved `node`. Path-type
      # findings (long_path, cycle) carry an ordered `path_refs` of resolved
      # Locations — the real call chain like `User#save → Billing#charge`.
      Finding = Struct.new(:type, :severity, :node, :path_refs, keyword_init: true) do
        # True for long_path / cycle (ordered path) findings (D38).
        def path?
          !(path_refs.nil? || path_refs.empty?)
        end

        # Render the ordered call chain with an arrow separator.
        def chain(separator: " → ")
          return "" unless path?

          path_refs.map(&:symbol).join(separator)
        end
      end
    end
  end
end
