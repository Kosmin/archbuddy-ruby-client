# frozen_string_literal: true

module Archbuddy
  module Reflect
    # WHERE A GENERATED METHOD FORWARDS TO — reconciled from two independent
    # derivations.
    #
    # `delegate :merchant, to: :purchase` produces a method with no `def` in
    # source. The parser cannot read its body and the resolver therefore cannot
    # follow it, which is the single largest structured hole in call-site
    # coverage on a real service. Two mechanisms can recover the mapping, and
    # they fail in different directions:
    #
    #   STATIC   — Prism reads the `to:` argument off the macro CALL SITE. Needs
    #              no boot, so it works on an application that cannot start; but
    #              it only knows the macros we have named, and it reads the
    #              DECLARED intent rather than what was generated.
    #   BYTECODE — the probe disassembles the method the macro actually
    #              produced. Framework-agnostic (it reads `delegate`,
    #              `def_delegator` and a hand-rolled `define_method` with one
    #              rule) and reports what really exists; but it needs the app to
    #              boot, and it cannot see through a generic runtime shim such as
    #              ActiveRecord's association reader.
    #
    # WHY BOTH, RATHER THAN THE BETTER ONE. Neither is trustworthy enough alone
    # to move a score. Agreement between two derivations that share no
    # machinery — one reading source text, one reading compiled instructions —
    # is EVIDENCE; either one on its own is an inference. So the sources are
    # kept separate all the way to here and the disagreement is preserved rather
    # than resolved: `:agreed` is what a consumer should act on without
    # hesitation, and a CONFLICT yields NO fact at all, because two mechanisms
    # contradicting each other is precisely the case where guessing is worst.
    module Forwarding
      # `to`  — the method to call on self to obtain the receiver
      # `via` — the method to call on that receiver
      # `source` — :agreed | :bytecode | :static (never :conflict; those are dropped)
      Fact = Struct.new(:cls, :name, :to, :via, :source, keyword_init: true)

      # Macro-generated forwarders whose target is not a sibling method are not
      # representable here and are never emitted. See MacroScan#delegation_target.
      module_function

      # @param manifest [Hash] probe output; method entries may carry "forwards"
      # @param delegations [Hash{String => Hash{String => String}}] class =>
      #   method => `to:` target, from MacroScan#scan_all
      # @return [Table]
      def from(manifest, delegations: {})
        facts     = Hash.new { |h, k| h[k] = {} }
        conflicts = []

        (manifest["methods"] || []).each do |m|
          cls  = m["class"].to_s
          name = m["name"].to_s
          bc   = m["forwards"]
          st   = delegations.dig(cls, name)
          next if bc.nil? && st.nil?

          if bc && st && bc["to"].to_s != st.to_s
            # The declared target and the compiled one disagree. Recorded so the
            # count is visible, but NO fact is produced: this is the one case
            # where either answer is as likely to be wrong as right.
            conflicts << "#{cls}##{name} (static=#{st} bytecode=#{bc['to']})"
            next
          end

          facts[cls][name] =
            if bc && st then Fact.new(cls: cls, name: name, to: bc["to"], via: bc["via"], source: :agreed)
            elsif bc    then Fact.new(cls: cls, name: name, to: bc["to"], via: bc["via"], source: :bytecode)
            else
              # A `delegate :merchant, to: :purchase` generates a method that
              # calls `purchase` and then THE SAME NAME on the result, so `via`
              # is the method's own name. That identity is the macro's
              # definition, not an assumption about this codebase.
              Fact.new(cls: cls, name: name, to: st.to_s, via: name, source: :static)
            end
        end

        # Handed over as a PLAIN hash. Built with a default proc for
        # convenience, but a default proc turns every miss in `fact` into a
        # write, so the table would grow an empty entry for each class anyone
        # merely asked about — and `empty?` would then answer "no" for a table
        # holding nothing.
        Table.new(facts.reject { |_, ms| ms.empty? }, conflicts)
      end

      # Lookup over the reconciled facts. Deliberately narrow: consumers ask
      # about one (class, method) pair and get a Fact or nil.
      class Table
        attr_reader :conflicts

        def initialize(facts = {}, conflicts = [])
          @facts = facts
          @conflicts = conflicts
        end

        def fact(cls, name)
          @facts.dig(cls.to_s, name.to_s)
        end

        def empty? = @facts.empty?

        # Counts by derivation, plus conflicts. Diagnostics only — this is how a
        # consumer sees that (say) the bytecode tier contributed nothing because
        # the app was reflected on a Ruby without RubyVM, rather than silently
        # getting worse answers.
        def stats
          by_source = Hash.new(0)
          @facts.each_value { |ms| ms.each_value { |f| by_source[f.source] += 1 } }
          { total: by_source.values.sum, conflicts: @conflicts.length }.merge(by_source)
        end
      end
    end
  end
end
