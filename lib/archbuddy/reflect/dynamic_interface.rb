# frozen_string_literal: true

module Archbuddy
  module Reflect
    # WHERE RESOLUTION IS NOT MERELY HARD BUT IMPOSSIBLE.
    #
    # Every resolution tier rests on one assumption: that a class's method table
    # describes the calls it answers. `method_missing` voids that assumption, and
    # where it is in force no amount of reflection will ever resolve a call —
    # the answer is not in the class.
    #
    # WHY THIS MATTERS MORE THAN IT RESOLVES. It resolves nothing. What it does
    # is split one label into three. Today every unresolved call site carries the
    # same mark, which reads as "the resolver is weak"; measured on one service,
    # 2,170 of them are calls through OpenStruct-backed objects where there is
    # nothing to find and never will be. Calling that a failure is the same
    # category of dishonesty as the shared `<external>` sink was: an absence of
    # knowledge reported as a finding. A boundary we can PROVE is undecidable is
    # a fact about the code, not a gap in the tool.
    #
    # THE THREE KINDS, and what each is worth:
    #
    #   :delegator — re-dispatches the missing name onto an object it fetches
    #                from itself. RECOVERABLE: type that object and every call
    #                through it resolves. `via` names the fetch.
    #   :bag       — never re-dispatches; reads instance state that a CALLER
    #                populated at runtime. Not recoverable from any class-level
    #                fact, only from dataflow across the sites that filled it.
    #                OpenStruct, and therefore Interactor's context.
    #   :unknown   — dynamic, but neither shape. Recoverable only with
    #                framework-specific knowledge, so this bucket is a WORKLIST:
    #                it names, ranked by call sites, the gems worth teaching.
    #   :native    — a C-defined method_missing. Dynamic, nothing more known.
    #
    # The classification is produced by the probe from bytecode (see
    # ArchbuddyReflectProbe#classify_dynamism); this class only reads it. ABSENT
    # is the default everywhere: a manifest written before the probe published
    # this section makes every class look ORDINARY, which is exactly the
    # behaviour every consumer had before it existed.
    class DynamicInterface
      Source = Struct.new(:name, :kind, :via, :reads, keyword_init: true)

      def self.from_manifest(manifest)
        section = (manifest || {})["dynamic_interfaces"] || {}
        sources = (section["sources"] || {}).each_with_object({}) do |(name, meta), acc|
          acc[name] = Source.new(name: name, kind: (meta["kind"] || "unknown").to_sym,
                                 via: meta["via"], reads: meta["reads"] || [])
        end
        new(section["classes"] || {}, sources)
      end

      def initialize(by_class = {}, sources = {})
        @by_class = by_class
        @sources  = sources
      end

      # Does this class answer calls its method table does not list?
      def dynamic?(cls) = @by_class.key?(cls.to_s)

      # The module supplying the dynamism, or nil.
      def source_of(cls) = @by_class[cls.to_s]

      # :delegator | :bag | :unknown | :native, or nil when the class is ordinary.
      def kind_of(cls)
        s = @sources[@by_class[cls.to_s]]
        s&.kind
      end

      # For a :delegator, the method that produces the object it forwards to —
      # the one thing you would need to type to make its calls resolvable.
      def unwrap_of(cls)
        s = @sources[@by_class[cls.to_s]]
        s&.kind == :delegator ? s.via : nil
      end

      def empty? = @by_class.empty?

      def stats
        by_kind = Hash.new(0)
        @by_class.each_value { |src| by_kind[@sources[src]&.kind || :unknown] += 1 }
        { classes: @by_class.size, sources: @sources.size }.merge(by_kind)
      end

      # Sources ranked by how many classes sit on them, for the worklist. Takes
      # an optional weight per class (e.g. call-site counts) because "how many
      # classes" and "how much of the graph" are different questions and the
      # second is the one worth acting on.
      #
      # `kinds:` filters, and the default is not "everything". `native` reaches
      # 1,302 classes on a real service because Exception owns a C-defined
      # method_missing that every error class inherits — true, and useless: an
      # exception is never the receiver of a call we were trying to resolve. It
      # would head an unfiltered ranking and bury every row anyone could act on.
      # The count stays in `stats`; it just does not lead the worklist.
      ACTIONABLE = %i[bag delegator unknown].freeze

      def sources_by_reach(weight: nil, kinds: ACTIONABLE)
        tally = Hash.new(0)
        @by_class.each do |cls, src|
          next if kinds && !kinds.include?(@sources[src]&.kind)

          tally[src] += weight ? weight.call(cls).to_i : 1
        end
        tally.sort_by { |_, n| -n }.map do |src, n|
          s = @sources[src]
          { source: src, kind: s&.kind || :unknown, via: s&.via, reach: n }
        end
      end
    end
  end
end
