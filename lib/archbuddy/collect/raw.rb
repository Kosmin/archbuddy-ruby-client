# frozen_string_literal: true

module Archbuddy
  module Collect
    # Neutral, language-agnostic value objects produced by an Adapter.
    #
    # These live entirely in REAL-symbol space: they carry file paths, line
    # numbers, and fully-qualified symbol names. They are the *input* to the
    # Anonymizer and are NEVER serialized into graph.yml. The Anonymizer is the
    # single trust boundary that converts Raw* into opaque ids.
    #
    # `kind` uses the contract's node-kind vocabulary: "function", "endpoint",
    # "db_op", "external".
    module Raw
      # A definition site (method / endpoint / db_op / external sink) in real
      # symbol space.
      #
      # - rel_file:  repo-relative path (e.g. "app/models/user.rb"); nil for the
      #              synthetic external sink.
      # - line:      1-based start line; nil for the external sink. DISPLAY-ONLY
      #              (v0.8): `line` is NOT part of identity — it is carried into the
      #              id-map payload for de-anonymization/display, but a node's id
      #              (and its `real_key`) is keyed on (rel_file, symbol) only, so
      #              moving a def within a file does NOT change its id.
      # - symbol:    fully-qualified symbol, e.g. "User#save" / "User.find".
      # - kind:      contract node kind.
      # - class_rel_file / class_line / class_symbol: the owning class's def site,
      #              used to mint the cls_ class rollup id (id-map only, D42).
      #              All nil when the node has no owning app class.
      # - branches:  b(n) = Π(arm-count), the multiplicative path factor the cost
      #              model consumes (P3+P9). Defaults to 1 so non-method sinks
      #              (db_op / external) contribute a single path.
      # - decisions: d(n) = raw decision-point count. Defaults to 0.
      # - entrypoint_kind: v0.10 (A1) OPTIONAL ingress category string for
      #              detected entrypoints — one of controllers|grape|routed|
      #              top_level|pattern|jobs|rake|middleware|script (plural
      #              vocab, Reconciliation 2). nil for non-entrypoints and for
      #              entrypoints with no category evidence (never guessed).
      # - terminal_kind: v0.10 (C, CR-5) OPTIONAL egress category string for
      #              category-bearing external sinks — one of http|gem|queue
      #              (the sink-side twin of entrypoint_kind; NOT a 5th node
      #              kind). nil everywhere else, INCLUDING the generic
      #              `<external>` sink (absent → uncategorized).
      RawNode = Struct.new(
        :rel_file, :line, :symbol, :kind,
        :class_rel_file, :class_line, :class_symbol,
        :branches, :decisions, :entrypoint_kind, :terminal_kind,
        keyword_init: true
      ) do
        def initialize(*)
          super
          self.branches  ||= 1
          self.decisions ||= 0
        end

        def class_rollup?
          !class_symbol.nil?
        end

        # A stable identity key for this node in REAL space, so edges can refer
        # to endpoints before ids are minted and the Anonymizer can dedupe.
        #
        # v0.8: keyed on (rel_file, symbol) ONLY, NUL-joined — it MUST match the
        # engine's canonical key `SHA256("rel_file\x00fq_symbol")` byte-for-byte
        # (asserted by the id-parity spec: `real_key == Ids.canonical_key(rel_file,
        # symbol)`). `line` is DROPPED from identity so a def that moves within a
        # file keeps its id, and so two same-(file,symbol) raws collapse to one
        # node (first-def-wins). The NUL separator is injective (impossible in a
        # POSIX path or a Ruby symbol).
        def real_key
          "#{rel_file}\x00#{symbol}"
        end
      end

      # A directed call relationship between two RawNode real_keys.
      RawEdge = Struct.new(:from_key, :to_key, :calls, keyword_init: true) do
        def initialize(*)
          super
          self.calls ||= 1
        end
      end

      # An entrypoint, referenced by the real_key of its RawNode.
      RawEntrypoint = Struct.new(:node_key, keyword_init: true)
    end
  end
end
