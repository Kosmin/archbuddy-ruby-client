# frozen_string_literal: true

require_relative "../config/schema"
require_relative "../config/path_matcher"
require_relative "../config/todo"
require_relative "finding"
require_relative "findings"

module Archbuddy
  module Review
    # The engine skeleton (I-P3, signature verbatim):
    #
    #   RuleEngine.evaluate(vintage:, delta: nil, config:, todo:) → Findings
    #
    # Mode dispatch (normative): lint evaluates :node + :use_case kinds
    # (:delta/:pr lint-inert — no findings, no N/A noise — EXCEPT
    # ComplexityRatchet context entries [S:C14]); diff evaluates all four.
    #
    # The ENGINE applies the todo to GRANDFATHERABLE kinds in BOTH modes
    # (:node 4-step; :use_case per-metric 4-step, integer comparison ONLY —
    # milli-log2 for log2 metrics, Q7); :delta/:pr NEVER receive it.
    #
    # Q8 zero-ep degenerate (V15-F4 dispatch carve-out): on a non-empty
    # vintage with ZERO entrypoints, UseCaseComplexity + UseCaseDividend
    # (both modes), FirewallBreaches (LINT only), and ReviewSurface (diff)
    # emit ONE not_evaluable note each with the pinned reason and are never
    # evaluated; FirewallBreaches DIFF mode still runs (its event universe is
    # reachability-independent — orphan-event findings fire).
    #
    # Lazy-graph predicate (R52): the engine itself never touches
    # vintage.graph — rules reach it through Ctx#graph only when they run.
    class RuleEngine
      Q8_REASON = "vintage has no entrypoints (nothing is reachable — " \
                  "check collector entrypoint detection)"

      @registry = {}

      class << self
        attr_reader :registry

        def register(name, klass)
          @registry[name] = klass
        end

        def unregister(name)
          @registry.delete(name)
        end

        # @param vintage [Review::Vintage] (head side in diff mode)
        # @param delta [Review::Delta, nil] nil = lint mode
        # @param config [Archbuddy::Config]
        # @param todo [Config::Todo, nil] REQUIRED keyword — pass nil explicitly
        # @return [Review::Findings]
        def evaluate(vintage:, delta: nil, config:, todo:)
          new(vintage: vintage, delta: delta, config: config, todo: todo).evaluate
        end
      end

      def initialize(vintage:, delta:, config:, todo:)
        @vintage = vintage
        @delta = delta
        @config = config
        @todo = todo
        @mode = delta.nil? ? :lint : :diff
        @collector = Collector.new
        @consumed = {}
        @dispatched_grandfatherable = []
      end

      def evaluate
        vintage_empty = @vintage.empty?
        warn "warning: vintage contains 0 nodes" if vintage_empty
        warn_all_excluded unless vintage_empty

        dispatch_rules(vintage_empty)
        finalize_healed_entries
        note_disabled_rule_entries

        Findings.new(
          findings: @collector.findings,
          grandfathered: @collector.grandfathered,
          not_evaluable: @collector.not_evaluable,
          ratchet: @collector.ratchet,
          review_surface: @collector.review_surface,
          vintage_empty: vintage_empty
        )
      end

      private

      def dispatch_rules(vintage_empty)
        Config::Schema::RULES.keys.sort.each do |name|
          klass = self.class.registry[name]
          next if klass.nil?

          kind = klass.kind
          next unless rule_enabled?(name)
          next unless mode_dispatch?(name, kind)
          # Empty-vintage precedence: the loud 0-node warning wins; node and
          # use-case universes are empty by construction — skip them (zero
          # findings, zero notes). :delta/:pr still evaluate in diff.
          next if vintage_empty && %i[node use_case].include?(kind)

          @dispatched_grandfatherable << name if grandfatherable?(name)

          if q8_gate?(name, kind, vintage_empty)
            @collector.not_evaluable!(name, Q8_REASON)
            next
          end

          klass.new.evaluate(Ctx.new(engine: self, collector: @collector,
                                     rule_name: name, rule_kind: kind))
        end
      end

      def mode_dispatch?(name, kind)
        return true if @mode == :diff

        %i[node use_case].include?(kind) || name == "ComplexityRatchet"
      end

      def rule_enabled?(name)
        @config.rule_for(name, file: nil).enabled?
      end

      def grandfatherable?(name)
        Config::Schema::GRANDFATHERABLE.include?(name)
      end

      # V15-F4: the zero-ep not_evaluable set is UCC + UCD (both modes),
      # FirewallBreaches (LINT only), ReviewSurface (diff only — :pr never
      # dispatches in lint).
      def q8_gate?(name, kind, vintage_empty)
        return false if vintage_empty
        return false unless @vintage.eps.empty?

        case kind
        when :use_case
          !(name == "FirewallBreaches" && @mode == :diff)
        when :pr
          @mode == :diff
        else
          false
        end
      end

      def warn_all_excluded
        return if @vintage.nodes.empty?
        return unless @vintage.nodes.none? { |n| global_universe?(n.file) }

        warn "warning: all #{@vintage.node_count} nodes excluded by config"
      end

      # ---- universe filtering (shared with Ctx) --------------------------------

      def global_universe?(file)
        includes = @config.all_includes
        return false if !includes.empty? && !Config::PathMatcher.match?(includes, file)

        !Config::PathMatcher.match?(@config.all_excludes, file)
      end

      def universe_nodes(rule_name)
        @vintage.nodes.select do |node|
          next false unless global_universe?(node.file)

          rc = @config.rule_for(rule_name, file: node.file)
          rc.enabled? && !Config::PathMatcher.match?(rc.exclude, node.file)
        end
      end

      # Ep universe = eps passing the node filters + exclude_entrypoints
      # (EMISSION only — the anti-gaming pin: cone membership, component
      # values, leaderboard rows, and RS counts are computed upstream and
      # never altered by any exclude).
      def universe_eps(rule_name)
        universe = @vintage.eps.select { |ep| global_universe?(ep.file) }
        universe.select do |ep|
          rc = @config.rule_for(rule_name, file: ep.file)
          rc.enabled? &&
            !Config::PathMatcher.match?(rc.exclude, ep.file) &&
            !Config::PathMatcher.match_symbol?(rc.exclude_entrypoints || [], ep.symbol)
        end
      end

      # ---- todo application (engine-owned; rules never read the todo) ---------

      def todo_entry(rule_name, file, symbol)
        return nil if @todo.nil?
        return nil unless grandfatherable?(rule_name)

        @todo.entry_for(rule_name, file, symbol)
      end

      def consume_entry(rule_name, file, symbol)
        @consumed[[rule_name, file, symbol]] = true
      end

      # :node 4-step ([S] order): pass→healed / no-entry→finding /
      # ≤recorded→skip / >recorded→re-fire.
      def gate_node_result(rule_name, node:, value_raw:, breaching:, finding_kw:, refire_style:)
        entry = todo_entry(rule_name, node.file, node.symbol)
        unless breaching
          if entry
            consume_entry(rule_name, node.file, node.symbol)
            @collector.skip(rule_name, node.file, node.symbol,
                            recorded: entry[:value], current: value_raw, healed: true)
          end
          return
        end

        if entry.nil?
          @collector.finding(Finding.new(rule: rule_name, file: node.file,
                                         symbol: node.symbol, value_raw: value_raw,
                                         **finding_kw))
          return
        end

        consume_entry(rule_name, node.file, node.symbol)
        recorded = entry[:value]
        if value_raw <= recorded
          @collector.skip(rule_name, node.file, node.symbol,
                          recorded: recorded, current: value_raw, healed: false)
        else
          message = node_refire_message(refire_style, recorded, value_raw)
          @collector.finding(Finding.new(rule: rule_name, file: node.file,
                                         symbol: node.symbol, value_raw: value_raw,
                                         **finding_kw.merge(
                                           message: message,
                                           grandfathered_baseline: recorded
                                         )))
        end
      end

      def node_refire_message(style, recorded, current)
        if style == :count
          format("grew past grandfathered baseline %d → %d", recorded, current)
        else
          format("grew past grandfathered baseline %d (2^%.1f) → %d (2^%.1f)",
                 recorded, Math.log2(recorded), current, Math.log2(current))
        end
      end

      # :use_case per-metric 4-step (Q7): for each SET-threshold component —
      # (1) not breaching → recorded ⇒ counts toward healed; (2) breaching +
      # not recorded → fires; (3) breaching + current_int ≤ recorded_int →
      # skip; (4) breaching + current_int > recorded_int → re-fire. ONE
      # finding per ep aggregates fire/re-fire clauses; skip-only ⇒ one
      # GrandfatherSkip per (rule, ep).
      def gate_ep_result(rule_name, file:, symbol:, components:, clauses:,
                         message_builder:, finding_kw:)
        entry = todo_entry(rule_name, file, symbol)
        recorded_values = entry ? entry[:values] : nil
        consume_entry(rule_name, file, symbol) if entry

        mapping = Config::Todo::COMPONENT_TO_METRIC.fetch(rule_name, {})
        fired = {}
        refired = {}
        skipped = {}

        components.each do |component_key, component|
          key = component_key.to_s
          next if component[:threshold].nil? # unset — reported, never gated
          next unless component[:breached]

          metric_key, encoding = mapping[key]
          if metric_key.nil?
            # No todo channel for this component (never grandfatherable) —
            # a breach always fires.
            fired[key] = clauses[component_key] || clauses[key]
            next
          end

          recorded = recorded_values && recorded_values[metric_key]
          current_int = encode_metric(component[:value], encoding)
          if recorded.nil?
            fired[key] = clauses[component_key] || clauses[key]
          elsif current_int <= recorded
            skipped[key] = [recorded, current_int]
          else
            refired[key] = [
              refire_clause(metric_key, recorded, component[:value], current_int),
              recorded
            ]
          end
        end

        if fired.any? || refired.any?
          clause_list = components.keys.map(&:to_s).filter_map do |key|
            fired[key] || refired[key]&.first
          end
          message = message_builder.call(clause_list)
          baseline = refired.values.map(&:last).first
          @collector.finding(Finding.new(rule: rule_name, file: file, symbol: symbol,
                                         components: components,
                                         **finding_kw.merge(
                                           message: message,
                                           grandfathered_baseline: baseline
                                         )))
        elsif skipped.any?
          recorded, current = skipped[skipped.keys.min]
          @collector.skip(rule_name, file, symbol,
                          recorded: recorded, current: current, healed: false)
        elsif entry
          # every recorded metric is below threshold now — healed
          @collector.skip(rule_name, file, symbol,
                          recorded: recorded_values.values.first, current: nil, healed: true)
        end
      end

      def encode_metric(value, encoding)
        encoding == :millilog2 ? (value * 1000).round : Integer(value)
      end

      # Re-fire clause templates (the §2.8 grammar family, per metric).
      def refire_clause(metric_key, recorded_int, current_value, current_int)
        case metric_key
        when "max_cone_node_millilog2"
          format("worst cone node grew past grandfathered baseline %d (2^%.1f) → %d (2^%.1f)",
                 (2**(recorded_int / 1000.0)).round, recorded_int / 1000.0,
                 (2**current_value).round, current_value)
        when "branching_millilog2"
          format("cone branching grew past grandfathered baseline 2^%.1f → 2^%.1f",
                 recorded_int / 1000.0, current_value)
        when "dividend_millilog2"
          format("dividend grew past grandfathered baseline ×%g (2^%.1f) → ×%g (2^%.1f)",
                 2**(recorded_int / 1000.0), recorded_int / 1000.0,
                 2**current_value, current_value)
        else
          format("%s grew past grandfathered baseline %d → %d",
                 metric_key, recorded_int, current_int)
        end
      end

      # Entries never consumed by a dispatched grandfatherable rule → healed
      # (node/ep vanished from the vintage, or was never surfaced).
      def finalize_healed_entries
        return if @todo.nil?

        @dispatched_grandfatherable.each do |rule_name|
          (@todo.entries_by_rule[rule_name] || []).each do |entry|
            file, symbol = entry["node"].split(": ", 2)
            next if @consumed[[rule_name, file, symbol]]

            recorded = entry["value"] || entry["values"]&.sort&.first&.last
            @collector.skip(rule_name, file, symbol,
                            recorded: recorded, current: nil, healed: true)
          end
        end
      end

      def note_disabled_rule_entries
        return if @todo.nil?

        count = @todo.entries_by_rule.sum do |rule_name, entries|
          grandfatherable?(rule_name) && !rule_enabled?(rule_name) ? entries.size : 0
        end
        warn "note: #{count} todo entries for disabled rules (not evaluated)" if count.positive?
      end

      # ---- result accumulation -------------------------------------------------

      # Engine-internal accumulator shared across rules.
      class Collector
        attr_reader :findings, :grandfathered, :not_evaluable, :ratchet
        attr_accessor :review_surface

        def initialize
          @findings = []
          @grandfathered = []
          @not_evaluable = []
          @ratchet = []
          @review_surface = nil
        end

        def finding(finding)
          @findings << finding
        end

        def not_evaluable!(rule, reason)
          return if @not_evaluable.any? { |n| n[:rule] == rule && n[:reason] == reason }

          @not_evaluable << { rule: rule, reason: reason }
        end

        def skip(rule, file, symbol, recorded:, current:, healed:)
          @grandfathered << Findings::GrandfatherSkip.new(
            rule: rule, file: file, symbol: symbol,
            recorded: recorded, current: current, healed: healed
          )
        end

        def ratchet_entry(entry)
          @ratchet << entry
        end
      end

      # The per-rule evaluation context handed to Rules::Base#evaluate.
      class Ctx
        attr_reader :rule_name, :rule_kind

        def initialize(engine:, collector:, rule_name:, rule_kind:)
          @engine = engine
          @collector = collector
          @rule_name = rule_name
          @rule_kind = rule_kind
        end

        def vintage = @engine.send(:instance_variable_get, :@vintage)
        def delta = @engine.send(:instance_variable_get, :@delta)
        def config = @engine.send(:instance_variable_get, :@config)
        def mode = @engine.send(:instance_variable_get, :@mode)

        # The ONE memoized graph (R7/R52) — touch only when the rule runs.
        def graph
          vintage.graph
        end

        def rule_config(file = nil)
          config.rule_for(@rule_name, file: file)
        end

        def universe_nodes
          @engine.send(:universe_nodes, @rule_name)
        end

        def universe_eps
          @engine.send(:universe_eps, @rule_name)
        end

        def not_evaluable!(reason)
          @collector.not_evaluable!(@rule_name, reason)
        end

        # Direct finding — :delta/:pr rules and non-gated emissions.
        def add_finding(**kw)
          @collector.finding(Finding.new(rule: @rule_name, **kw))
        end

        # :node kind, engine todo-gated. Report EVERY universe node (breaching
        # or not) so healed entries are detected. `message` is used on the
        # fresh-fire path; re-fires replace it (R21 full-replacement).
        def node_result(node:, value_raw:, breaching:, message: nil, severity: nil,
                        refire_style: :branching, **finding_kw)
          severity ||= rule_config(node.file).severity
          kw = { severity: severity, message: message, kind: node.respond_to?(:kind) ? node.kind : nil,
                 enrichment: enrichment_for(node) }.merge(finding_kw)
          @engine.send(:gate_node_result, @rule_name,
                       node: node, value_raw: value_raw, breaching: breaching,
                       finding_kw: kw, refire_style: refire_style)
        end

        # :use_case kind, engine todo-gated per metric. `components` =
        # {key → {value:, threshold:, breached:}} (insertion order = clause
        # order); `clauses` = fire-clause string per breaching component;
        # `message_builder` receives the final clause list.
        def ep_result(file:, symbol:, components:, clauses:, message_builder: nil,
                      severity: nil, entrypoint_kind: nil, contributors: nil,
                      contributors_omitted: nil, **finding_kw)
          severity ||= rule_config(file).severity
          builder = message_builder || ->(list) { list.join("; ") }
          kw = { severity: severity, entrypoint_kind: entrypoint_kind,
                 contributors: contributors, contributors_omitted: contributors_omitted }
               .merge(finding_kw)
          @engine.send(:gate_ep_result, @rule_name,
                       file: file, symbol: symbol, components: components,
                       clauses: clauses, message_builder: builder, finding_kw: kw)
        end

        def ratchet_entry(**kw)
          @collector.ratchet_entry(Findings::RatchetEntry.new(**kw))
        end

        def review_surface=(block)
          @collector.review_surface = block
        end

        private

        def enrichment_for(node)
          return {} unless vintage.respond_to?(:analyzed?) && vintage.analyzed?

          %i[quadrant toll_booth leverage collapse].each_with_object({}) do |key, acc|
            acc[key] = node.public_send(key) if node.respond_to?(key)
          end
        end
      end
    end
  end
end
