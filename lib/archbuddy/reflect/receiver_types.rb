# frozen_string_literal: true

module Archbuddy
  module Reflect
    # OBSERVED RETURN TYPES from a bag-backed receiver, read back from a trace.
    #
    # The one fact no static or reflective analysis can supply. `context.merchant`
    # has no method to find and no owner to look up, because the value was put
    # into an instance hash by a caller in another file. An execution can see it;
    # nothing else can.
    #
    # THIS IS EVIDENCE OF A DIFFERENT KIND from everything else the tool reads,
    # and the difference is load-bearing rather than pedantic:
    #
    #   graph.yml        deterministic, complete over PARSED SOURCE
    #   reflection.json  deterministic, complete over BOOTED CLASSES
    #   receiver_types   NON-deterministic, partial over EXECUTED PATHS
    #
    # So it is never merged into the graph and nothing requires it. Its absence
    # changes no score. Merging it would destroy a property the rest of the tool
    # depends on: that absence means absence. Once a missing entry might mean
    # "this path was not exercised", "no callers" stops being a fact and
    # `collect --check` stops being able to gate on drift.
    #
    # AMBIGUITY IS PRESERVED, NOT RESOLVED. Two flows can legitimately put
    # different types under one key — `context.source` really is a Purchase here
    # and a Receipt there. `type_of` returns nil for those and `observations`
    # hands back everything seen, because a union type is the true answer and
    # picking the most frequent member would be a fabrication dressed as a
    # measurement.
    class ReceiverTypes
      Observation = Struct.new(:cls, :name, :counts, keyword_init: true) do
        # The single observed type, or nil when zero or MORE THAN ONE was seen.
        def sole_type
          counts.size == 1 ? counts.keys.first : nil
        end

        def ambiguous? = counts.size > 1
        def total = counts.values.sum
      end

      def self.from_file(path)
        return new unless path && File.file?(path)

        require "json"
        from_manifest(JSON.parse(File.read(path)))
      rescue StandardError
        new
      end

      def self.from_manifest(doc)
        rows = (doc || {})["types"] || []
        table = rows.each_with_object({}) do |r, acc|
          counts = r["observed"] || {}
          # nil observations are dropped as TYPES while still counted upstream:
          # "it was nil once" is not a type, and letting NilClass win a
          # single-observation key would invent one.
          counts = counts.reject { |k, _| k == "NilClass" }
          next if counts.empty?

          acc[[r["class"].to_s, r["name"].to_s]] =
            Observation.new(cls: r["class"].to_s, name: r["name"].to_s, counts: counts)
        end
        new(table, (doc || {})["unattached"] || [])
      end

      def initialize(table = {}, unattached = [])
        @table = table
        @unattached = unattached
      end

      # The class `cls#name` was observed to return, when exactly one was seen.
      def type_of(cls, name)
        @table[[cls.to_s, name.to_s]]&.sole_type
      end

      def observation(cls, name) = @table[[cls.to_s, name.to_s]]

      def empty? = @table.empty?

      # Bag sources the probe never managed to attach to. Surfaced because a
      # thin trace should read as a coverage problem, not as "nothing to find".
      attr_reader :unattached

      def stats
        {
          pairs: @table.size,
          unambiguous: @table.count { |_, o| o.sole_type },
          ambiguous: @table.count { |_, o| o.ambiguous? },
          unattached: @unattached.length
        }
      end
    end
  end
end
