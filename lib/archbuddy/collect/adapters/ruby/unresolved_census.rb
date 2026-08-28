# frozen_string_literal: true

require "set"

module Archbuddy
  module Collect
    module Adapters
      module Ruby
        # HOW MUCH OF THE UNRESOLVED POPULATION COULD EVER HAVE MATTERED.
        #
        # `23069 unresolved call sites` reads as a two-thirds failure. It is not
        # one, and the reason is a property of the SCORE rather than of the
        # resolver: an unresolved call already mints a boundary node with
        # branches 1, decisions 0 and no successors. So for any call whose real
        # target is a leaf — a schema attribute, an `attr_reader`, a gem call,
        # any data access — perfect resolution would produce EXACTLY what the
        # failure produces. Cost 1 either way. There is nothing behind it to
        # traverse and nothing to recover.
        #
        # Measured on one service, 65.9% of unresolved sites are in that state.
        # Reporting them as a gap overstates the tool's blind spot by an order of
        # magnitude, and it sent this author off to build a resolver tier whose
        # entire output would have been replacing cost-1 leaves with different
        # cost-1 leaves.
        #
        # WHY NAMES, WHEN NAMES ARE UNRELIABLE. This is deliberately a
        # DIAGNOSTIC and never graph content, which is what makes a name-keyed
        # heuristic acceptable here: the worst case is a number that reads
        # slightly wrong, not an edge that is wrong. It is reported as a RANGE
        # for the same reason — see `complex` versus `complex_exclusive`.
        #
        # THE OVERRIDE CASE IS SAFE, and it is the one worth stating because it
        # is the obvious objection. If someone overrides an attribute accessor
        # with real logic, that override is a `def` in application source: the
        # definition pass parses it, `add_method` is first-wins, and the node
        # carries its real branch count. A hand-written body can never be
        # mistaken for a cost-1 accessor.
        module UnresolvedCensus
          # `cost_1`            provably cost-1 however it resolved
          # `complex`           LOOSE upper bound: some application method of
          #                     that name has a subtree
          # `complex_exclusive` TIGHT: as above, and no method of that name is
          #                     defined outside the application, so the match is
          #                     unlikely to be a coincidence of naming
          Result = Struct.new(:total, :cost_1, :complex, :complex_exclusive, :top_names,
                              keyword_init: true) do
            def cost_1_share = total.zero? ? 0.0 : cost_1.to_f / total
          end

          module_function

          # @param names [Array<String>] the called name of every unresolved
          #   call site — one entry per SITE, not per distinct name
          # @param leaf_by_name [Hash{String => Boolean}] for each name that any
          #   application method bears: true when EVERY such method is a cost-1
          #   leaf. A name absent from this hash has no application definition at
          #   all, which is the strongest cost-1 evidence there is.
          # @param outside_names [Set<String>] names also defined outside the app
          # @return [Result]
          def classify(names:, leaf_by_name:, outside_names: Set.new)
            cost1 = complex = exclusive = 0
            hot = Hash.new(0)

            names.each do |n|
              if !leaf_by_name.key?(n) || leaf_by_name[n]
                cost1 += 1
              else
                complex += 1
                next if outside_names.include?(n)

                exclusive += 1
                hot[n] += 1
              end
            end

            Result.new(total: names.length, cost_1: cost1, complex: complex,
                       complex_exclusive: exclusive,
                       top_names: hot.sort_by { |n, c| [-c, n] }.first(5).to_h)
          end

          # Which application methods share each bare name, and whether they are
          # ALL leaves.
          #
          # A leaf is out-degree 0 AND at most one branch. Both halves are
          # needed: out-degree 0 alone would call an unparsed-body method a leaf,
          # and a low branch count alone says nothing about what it calls.
          #
          # @param methods [Enumerable] symbol-table method entries
          # @param out_degree [#call] fq symbol -> Integer successors
          def leaf_by_name(methods, out_degree)
            methods.each_with_object({}) do |m, acc|
              name = m.name.to_s
              leaf = m.branches.to_i <= 1 && out_degree.call(m.fq_symbol).zero?
              acc[name] = acc.key?(name) ? (acc[name] && leaf) : leaf
            end
          end
        end
      end
    end
  end
end
