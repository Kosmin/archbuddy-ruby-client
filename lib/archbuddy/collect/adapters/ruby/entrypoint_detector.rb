# frozen_string_literal: true

module Archbuddy
  module Collect
    module Adapters
      module Ruby
        # Pluggable entrypoint strategy (K-4 / D4). Given the SymbolTable, choose
        # which method symbols are entrypoints. May return an empty list.
        #
        # Strategies:
        #   :default      controller actions + top-level defs
        #   :controllers  controller actions only
        #   :all_public   every instance method (rough "all public" surface)
        #   :none         none
        # Plus an optional regex list: any method whose fq symbol matches is
        # additionally included.
        class EntrypointDetector
          # v0.10 (A1, Reconciliation 2): the deterministic ingress-category
          # precedence — most-specific evidence first, FIRST MATCH WINS, one
          # category per fq. Seeded categories (jobs/rake/middleware/script)
          # come from SymbolTable#entrypoint_category (written once per fq by
          # the root seeders, L4-gated) and slot between the framework-explicit
          # surfaces and the loose top_level/pattern buckets.
          CATEGORY_PRECEDENCE = %w[
            grape routed controllers jobs rake middleware script top_level pattern
          ].freeze

          # The seeded (root-seeder-written) subset of the precedence vocab.
          SEEDED_CATEGORIES = %w[jobs rake middleware script].freeze

          def initialize(config)
            @strategy = config.entrypoint_strategy
            @patterns = config.entrypoint_patterns
          end

          # @return [Array<String>] fq symbols of entrypoint methods.
          #
          # Delegates to detect_categorized so selection stays single-sourced;
          # the flat-array contract (content AND order) is unchanged.
          def detect(table)
            detect_categorized(table).keys
          end

          # v0.10 (A1): the categorized selection — an ORDERED {fq => category}
          # map over exactly the set #detect returns. `category` is a string
          # from CATEGORY_PRECEDENCE chosen by first-match-wins, or nil when no
          # category source matches (unknown is declared, never guessed — L4).
          # Seeded categories are read NIL-TOLERANTLY from the table so this
          # works before/without Deliverable-B seeders.
          #
          # @return [Hash{String => String, nil}]
          def detect_categorized(table)
            base =
              case @strategy
              when :controllers then controller_actions(table)
              when :all_public  then all_instance_methods(table)
              when :none        then []
              else                   default_set(table)
              end

            patterns = pattern_matches(table)

            (base + patterns).uniq.each_with_object({}) do |fq, map|
              map[fq] = category_for(fq, table, patterns)
            end
          end

          private

          # THE PRECEDENCE (Reconciliation 2, first match wins, stop):
          #   grape -> routed -> controllers -> jobs -> rake -> middleware ->
          #   script -> top_level -> pattern
          def category_for(fq, table, pattern_fqs)
            entry = table.methods[fq]

            return "grape"       if entry&.endpoint
            return "routed"      if table.routed_action?(fq)
            return "controllers" if controller_action?(table, entry)

            seeded = seeded_category(table, fq)
            return seeded if seeded && SEEDED_CATEGORIES.include?(seeded)

            return "top_level"   if entry && entry.owner_fq.nil?
            return "pattern"     if pattern_fqs.include?(fq)

            nil
          end

          def controller_action?(table, entry)
            !entry.nil? && !entry.singleton && entry.owner_fq &&
              table.controller_class?(entry.owner_fq)
          end

          # Nil-tolerant seeded-category read (L2): a table without the W1-B
          # category API, or an fq no seeder marked, yields nil. Categories are
          # stored as symbols (:jobs) — normalize to the A1 string vocab.
          def seeded_category(table, fq)
            return nil unless table.respond_to?(:entrypoint_category)

            table.entrypoint_category(fq)&.to_s
          end

          # :default = request surfaces (controllers/grape/routed) + top-level
          # defs + SEEDED categorized roots (v0.10 W1-B: jobs; later rake/
          # middleware/script). The seeded union lives HERE and not in
          # `controller_actions` because seeded roots are not controller
          # requests — `:controllers` semantics stay clean. Additive: no
          # seeders selected => seeded_roots is [] => today's set, unchanged.
          def default_set(table)
            (controller_actions(table) + top_level_defs(table) + seeded_roots(table)).uniq
          end

          # All category-tagged fqs (root seeders write categories through
          # SymbolTable#mark_entrypoint, which is gated on table.method? —
          # L4, so nothing here is fabricated).
          def seeded_roots(table)
            return [] unless table.respond_to?(:entrypoint_category)

            table.methods.keys.select { |fq| table.entrypoint_category(fq) }
          end

          # Controller actions ∪ Grape endpoint handlers (W2) ∪ routed actions
          # (W4). Grape endpoints and Rails-routes-declared actions are
          # framework-wired request entrypoints just like heuristic controller
          # actions; all three surfaces belong in :default and :controllers.
          # The routed-action union is gated: RouteCatalogue only seeds pairs
          # where table.method? is true (L2), so no fabrication here.
          def controller_actions(table)
            actions = table.methods.values.select do |m|
              !m.singleton && m.owner_fq && table.controller_class?(m.owner_fq)
            end.map(&:fq_symbol)

            routed = table.methods.keys.select { |fq| table.routed_action?(fq) }

            (actions + grape_endpoints(table) + routed).uniq
          end

          def grape_endpoints(table)
            table.methods.values.select(&:endpoint).map(&:fq_symbol)
          end

          def top_level_defs(table)
            table.methods.values.select { |m| m.owner_fq.nil? }.map(&:fq_symbol)
          end

          def all_instance_methods(table)
            table.methods.values.reject(&:singleton).map(&:fq_symbol)
          end

          def pattern_matches(table)
            return [] if @patterns.empty?

            table.methods.values.map(&:fq_symbol).select do |sym|
              @patterns.any? { |re| re.match?(sym) }
            end
          end
        end
      end
    end
  end
end
