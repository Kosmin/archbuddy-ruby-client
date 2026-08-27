# frozen_string_literal: true

module Archbuddy
  module Reflect
    # The reflected method table, made queryable: class name => method name => facts.
    #
    # WHAT THIS IS FOR. The static resolver's receiverless-call rule consults only
    # the enclosing class's OWN parsed methods, so every call to an INHERITED or
    # MIXED-IN or MACRO-GENERATED method fails to resolve — measured at 4,517
    # unresolved `self` call sites on one real service, the largest structured
    # bucket after chained calls. Reflection knows the COMPLETE method table of a
    # loaded class, including everything the parser cannot see, so it answers
    # exactly the question the static rule gets wrong.
    #
    # It also answers WHERE each method was defined, which is what upgrades an
    # UNRESOLVED call into a PROVEN CROSSING: a method owned by an application
    # class but defined inside a gem is, by construction, a call that leaves the
    # analysed boundary. That distinction is the whole reason the generic exit
    # stamp is honest here and dishonest on the unresolved sink.
    class MethodTable
      Fact = Struct.new(:cls, :name, :scope, :file, :line, :external_site, :kind, :macro,
                        keyword_init: true) do
        # A crossing is PROVEN when the owner is an application class but the
        # definition lives outside the project tree — i.e. gem code supplies the
        # behaviour. Never inferred from the name.
        def proven_crossing? = external_site == true

        def relation? = kind == :generated_relation
        def trivial? = kind == :generated_trivial
      end

      def self.from(manifest, entries)
        by_kind = entries.to_h { |e| [[e.cls, e.name], e] }
        table = Hash.new { |h, k| h[k] = {} }
        (manifest["methods"] || []).each do |m|
          e = by_kind[[m["class"], m["name"]]]
          table[m["class"]][m["name"]] = Fact.new(
            cls: m["class"], name: m["name"], scope: m["scope"],
            file: m["file"], line: m["line"], external_site: m["external_site"],
            kind: e&.kind, macro: e&.macro
          )
        end
        new(table)
      end

      def initialize(table = {})
        @table = table
      end

      def empty? = @table.empty?

      # Exact lookup: does THIS class expose THIS method, and what do we know?
      def fact(cls, name)
        @table.dig(cls, name)
      end

      def known_class?(cls) = @table.key?(cls)

      # Methods on a class that are gem-defined — the proven crossings.
      def crossings_for(cls)
        (@table[cls] || {}).values.select(&:proven_crossing?)
      end

      def stats
        all = @table.values.flat_map(&:values)
        {
          classes: @table.size,
          methods: all.size,
          proven_crossings: all.count(&:proven_crossing?),
          relations: all.count(&:relation?),
          trivial: all.count(&:trivial?)
        }
      end
    end
  end
end
