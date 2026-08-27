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

      # Built from the manifest ALONE. `proven_crossing?` needs only
      # `external_site`, which the probe records directly, so the primary use —
      # upgrading an unresolved call into a proven one — has no dependency on
      # the static pass. `macro_calls` is OPTIONAL enrichment: supplying it lets
      # a has_many product be typed as a DATABASE crossing rather than a generic
      # one. Absent, the method is still a proven crossing, just untyped — which
      # is exactly what the generic "exit" category is for.
      def self.from_manifest(manifest, macro_calls: {})
        table = Hash.new { |h, k| h[k] = {} }
        (manifest["methods"] || []).each do |m|
          macro = macro_calls.dig(m["class"], m["name"])
          table[m["class"]][m["name"]] = Fact.new(
            cls: m["class"], name: m["name"], scope: m["scope"],
            file: m["file"], line: m["line"], external_site: m["external_site"],
            kind: kind_for(macro), macro: macro
          )
        end
        new(table)
      end

      def self.kind_for(macro)
        return nil if macro.nil?
        return :generated_relation if Merge::RELATION_MACROS.include?(macro)
        return :generated_trivial if Merge::TRIVIAL_MACROS.include?(macro)
        return :generated_delegation if Merge::DELEGATION_MACROS.include?(macro)

        :generated_other
      end

      def initialize(table = {})
        @table = table
      end

      # name => the single class declaring it as a RELATION, when exactly one does.
      #
      # WHY THIS IS SAFE HERE AND NOT IN GENERAL. Bare name lookup across all
      # methods is hopeless — `call` is declared by 129 classes on a real service,
      # so the name carries no information. RELATION names are different in kind:
      # they are domain nouns (`loyalty_programs`, `rpush_android_app`), and 85%
      # of them (51 of 60, measured) are declared by exactly ONE class. The
      # uniqueness test is applied per-name, so the 15% that collide are EXCLUDED
      # rather than guessed at — an ambiguous name simply stays unresolved.
      def unambiguous_relations
        @unambiguous_relations ||= begin
          by_name = Hash.new { |h, k| h[k] = [] }
          @table.each do |cls, methods|
            methods.each { |name, fact| by_name[name] << cls if fact.relation? }
          end
          by_name.filter_map { |name, classes| [name, classes.first] if classes.uniq.size == 1 }.to_h
        end
      end

      # The owning class when `name` is a relation on exactly one class, else nil.
      def sole_relation_owner(name)
        unambiguous_relations[name]
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
