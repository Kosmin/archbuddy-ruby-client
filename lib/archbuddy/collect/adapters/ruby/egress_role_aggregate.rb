# frozen_string_literal: true

module Archbuddy
  module Collect
    module Adapters
      module Ruby
        # THE EGRESS ROLE AGGREGATE (configurator W3 / C7).
        #
        # A `db_op` node's crossing role is homogeneous BY CONSTRUCTION — its
        # symbol embeds the method (`Class.method`), so every call site that
        # collapses onto one node ran the same verb. An EGRESS SINK is not:
        # `<external:{category}:{target}>` fields EVERY call site that reached
        # that library through that category, and those call sites may run
        # different verbs with different roles (`Faraday.get` is a read,
        # `Faraday.post` is a write, and both land on ONE sink).
        #
        # So the sink's role has to be AGGREGATED, and the only honest
        # aggregation is UNANIMITY:
        #
        #   every merged call site declares the SAME role  => stamp that role
        #   the merged call sites DISAGREE                 => ABSENT, and COUNTED
        #   no merged call site declares any role          => ABSENT, not counted
        #
        # WHY DISAGREEMENT IS NOT A DEFAULT. The plausible-wrong implementation
        # is last-write-wins: it passes every homogeneous fixture and silently
        # stamps `"action"` on a sink that is half reads. A "pick the safer one"
        # rule is the same defect wearing a conservative hat — it invents a fact
        # about the sink that no call site supports. The key is simply not
        # emitted, and the suppression is TALLIED so the omission is visible as
        # a number rather than inferred from an absence.
        #
        # WHY AN UNDECLARED CALL SITE COUNTS AS A DISAGREEMENT. A sink whose
        # call sites are `Faraday.get` (configuration) and `Faraday.request`
        # (unroled — `request` takes its verb as a runtime argument) cannot
        # truthfully be called `configuration`: one of its members is a crossing
        # this build cannot classify. nil is therefore a DISTINCT observed value,
        # not a wildcard that agrees with everything. The all-nil case is the
        # separate, honest "this profile declares nothing here" state and is not
        # counted as a suppression.
        #
        # THE TAG IS INERT. Nothing downstream reads the value to decide
        # anything — see spec/collect/cco_role_inertness_spec.rb (client) and
        # spec/analyze/cco_role_backdoor_lock_spec.rb (engine).
        #
        # THIS CLASS OWNS THE WHOLE RULE. It exists so that the group-by, the
        # unanimity test and the suppression counter live in ONE place with one
        # reason to change: `ruby_adapter.rb` gains a single delegation and a
        # single stamp, and knows nothing about how the answer was reached.
        class EgressRoleAggregate
          # The one reason a sink's role is suppressed. A Symbol, so the tally
          # can never accumulate free-form strings.
          HETEROGENEOUS = :egress_heterogeneous

          # @param calls [Array<Hash>] the Accumulator's raw call records. Only
          #   `to[:type] == :external` records carrying BOTH a category and a
          #   target participate — those are exactly the records that mint a
          #   per-target sink. The generic `<external>` sink (target nil) has no
          #   provable library behind it and is never stamped.
          def initialize(calls)
            @roles      = {}
            @suppressed = Hash.new(0)
            build(calls)
          end

          # @param category [Symbol] the egress category of the sink
          # @param target [String] the normalized literal constant FQ
          # @return [String, nil] the unanimous role, or nil when the sink's
          #   members disagree or declare nothing. nil means ABSENT: the caller
          #   must omit the key, never substitute a value.
          def role_for(category, target)
            @roles[[category, target]]
          end

          # @return [Hash{Symbol => Integer}] suppression tally by reason; {}
          #   when nothing was suppressed. A genuine zero is an EMPTY hash, not
          #   a fabricated `{egress_heterogeneous: 0}` — "no sink disagreed" and
          #   "the counter never ran" stay distinguishable.
          attr_reader :suppressed

          private

          def build(calls)
            observed = Hash.new { |hash, key| hash[key] = [] }

            calls.each do |call|
              to = call[:to]
              next unless to[:type] == :external && to[:category] && to[:target]

              observed[[to[:category], to[:target]]] << to[:cco_role]
            end

            observed.each do |pair, roles|
              distinct = roles.uniq
              if distinct.size > 1
                @suppressed[HETEROGENEOUS] += 1 # ABSENT, and visible
              elsif !distinct.first.nil?
                @roles[pair] = distinct.first
              end
            end
          end
        end
      end
    end
  end
end
