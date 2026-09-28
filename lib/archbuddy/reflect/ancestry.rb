# frozen_string_literal: true

module Archbuddy
  module Reflect
    # THE SUPERCLASS LINKS A PARSER CANNOT SEE.
    #
    # `class Foo < Bar` is a fact about one file. Ruby lets the same class be
    # opened in several, and only the first of them names a superclass — so a
    # collector reading a REOPENING records `superclass = nil` and every
    # chain-walked predicate built on it stops after one step. This is not an
    # exotic case: a Rails app that keeps its models in an engine and reopens
    # them per-service produces it for every model it touches. Measured on one
    # service, 215 of 997 parsed classes had exactly this shape, and nothing
    # downstream could tell they were ORM models at all.
    #
    # READS, NEVER INFERS. The probe writes one immediate-superclass name per
    # class from the booted process; this class hands that map back. There is no
    # heuristic here and deliberately so — an earlier attempt typed models by
    # their `method_missing` source (`ActiveModel::AttributeMethods`), which is
    # a PROXY: it is present on ActiveModel-only classes that have no `find` and
    # no table, so it would have answered a question about persistence with
    # evidence about attributes. The superclass IS the fact; record the fact.
    #
    # ABSENT IS THE DEFAULT. A manifest written before schema 5 has no
    # `superclasses` section, and yields `{}` — the exact behaviour every
    # consumer had before this existed. Consumers layer it UNDER their parsed
    # data (see SymbolTable#superclass_of), so a stale manifest can only ever
    # supply links source did not have; it can never overrule one it did.
    class Ancestry
      # @return [Hash{String=>String}] class name => immediate superclass name
      def self.from_manifest(manifest)
        section = (manifest || {})["superclasses"]
        return {} unless section.is_a?(Hash)

        section.each_with_object({}) do |(child, parent), acc|
          next unless child.is_a?(String) && parent.is_a?(String)
          next if child.empty? || parent.empty?

          acc[child] = parent
        end
      end
    end
  end
end
