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
      # - line:      1-based start line; nil for the external sink.
      # - symbol:    fully-qualified symbol, e.g. "User#save" / "User.find".
      # - kind:      contract node kind.
      # - class_rel_file / class_line / class_symbol: the owning class's def site,
      #              used to mint the cls_ class rollup id (id-map only, D42).
      #              All nil when the node has no owning app class.
      RawNode = Struct.new(
        :rel_file, :line, :symbol, :kind,
        :class_rel_file, :class_line, :class_symbol,
        keyword_init: true
      ) do
        def class_rollup?
          !class_symbol.nil?
        end

        # A stable identity key for this node in REAL space, so edges can refer
        # to endpoints before ids are minted and the Anonymizer can dedupe.
        def real_key
          "#{rel_file}:#{line}:#{symbol}"
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
