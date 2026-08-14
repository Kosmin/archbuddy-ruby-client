# frozen_string_literal: true

require "set"
require "prism"
require_relative "../../../config/path_matcher"
require_relative "receiver_shape"

module Archbuddy
  module Collect
    module Adapters
      module Ruby
        # THE DECLARED BOUNDARY (configurator W4 / C9) — resolver tier R1.5.
        #
        # A profile may DECLARE that a call crosses out of the tree. R1.5 sits
        # between the R1 metaprogramming guard and the R2..R4.5 in-tree
        # inference tiers, because **a declaration must beat an inference or it
        # is not a declaration**. That placement is the whole point: an R5 probe
        # (which runs AFTER the base tiers) could never override a real in-tree
        # edge, so a boundary expressed as a probe would silently do nothing for
        # exactly the classes a user most wants to declare opaque.
        #
        # WHY THIS IS A CLASS AND NOT A BRANCH IN THE RESOLVER (V-3). The whole
        # tier — the three granularities, the precedence, the load-time category
        # gate, and the `kind:`/`egress_category:` pairing the A6 back-door
        # invariants guard — lives HERE. `resolver.rb` gains ONE line that asks
        # this class for a Resolution and returns it if there is one. The
        # resolver therefore learns nothing about crossings, and a future change
        # to the boundary vocabulary cannot reach it.
        #
        # THREE GRANULARITIES, MOST-SPECIFIC-WINS, FIRST NON-NIL WINS:
        #
        #   1. call  — receiver constant AND verb both match. The ONLY
        #              granularity that may carry a `role` (structurally, via
        #              the profile schema's additionalProperties).
        #   2. class — the receiver constant's IDENTITY or ANCESTRY.
        #   3. path  — the TARGET's definition-site path matches a glob (L15:
        #              "is this crossing out of my tree" is a question about the
        #              callee, so the CALLER's path is irrelevant).
        #
        # CLASS RULES MATCH IDENTITY OR ANCESTRY, NEVER AST SHAPE. That is what
        # makes the middleware hazard STRUCTURALLY INEXPRESSIBLE: a rule saying
        # "anything with the Rack `#call(env)` + `@app` shape is a framework
        # black box" cannot be written here, because that shape is byte-identical
        # for the owner's own `app/middleware/` code and for a vendored class.
        # The shipped precedent for the discrimination that DOES work is the
        # MiddlewareSeeder's three-part conjunction (shape + registration +
        # definition-site capture); no new mechanism is introduced here. The
        # correct lever for the "vendored subtree" case is a PATH rule, and it
        # is the only one offered.
        #
        # SEVERING CONSEQUENCE, DOCUMENTED NOT DISCOVERED. Because R1.5 sits
        # above R3/R4, declaring an IN-TREE class a boundary SEVERS the real
        # edges that used to reach it; its methods become unreachable from their
        # former callers and surface as orphan/dead unless independently seeded.
        # That is the intended "a black box is O(1) from outside" semantics —
        # recursion is by re-run at a deeper root, not by sub-node structure.
        #
        # NEVER FABRICATES. A rule with no `category` yields a crossing with NO
        # category, which routes to the generic `<external>` sink and stamps NO
        # `terminal_kind` — ABSENT, never defaulted to a plausible-looking
        # `"gem"`. A rule that matches nothing mints nothing (`add_external_sinks`
        # mints only pairs that actually appear in the recorded external edges).
        #
        # OPT-IN BY CONSTRUCTION. The shipped reference profile declares
        # `boundary: {paths: [], classes: [], calls: []}` — every list empty — so
        # with no rules this tier returns nil for every call site and the emitted
        # bytes are unchanged. A profile with NO boundary section at all
        # short-circuits one step earlier still (`Profile#boundary` is nil), and
        # the two states stay distinguishable rather than being collapsed into a
        # fabricated `{}`.
        class BoundaryRules
          # A declared category outside the ONE producer of the closed egress
          # vocabulary. The profile schema deliberately leaves `category` an
          # unconstrained string (re-typing the words into JSON Schema would be a
          # second source of the same canon); THIS gate is what keeps the value
          # space closed in practice.
          class UnknownCategoryError < StandardError; end

          # Two rules of the same granularity claiming the same normalised match
          # key. Deterministic-and-loud beats last-one-wins: a duplicate is
          # always a mistake and is never silently resolved.
          class DuplicateRuleError < StandardError; end

          # Evaluation order IS the precedence. Most specific first.
          GRANULARITIES = %w[calls classes paths].freeze

          # The closed category vocabulary, read from its ONE producer.
          def self.allowed_categories
            ArchitectureAuditor::Contract::TERMINAL_KINDS
          end

          class << self
            # THE ENTRY POINT — the whole of resolver R1.5.
            #
            # @param ctx [RubyResolver::CallContext]
            # @param profile [Profile]
            # @return [RubyResolver::Resolution, nil] nil = declines (no profile
            #   boundary section, no rules, no constant receiver, or no match)
            def resolve(ctx, profile)
              rules = for_profile(profile)
              return nil if rules.nil?

              rules.resolve(ctx)
            end

            # The compiled index for a profile, or nil when the profile declares
            # no boundary section at all.
            #
            # MEMOISED ON THE SECTION ITSELF, not on the Profile instance. The
            # section comes back deep-frozen from the engine's profile loader, so
            # two Profile objects built from the same document share one index
            # (Hash lookup is by value here) and the memo is bounded by the
            # number of DISTINCT boundary declarations in a process, not by the
            # number of Profile objects a test suite happens to construct.
            def for_profile(profile)
              section = profile.boundary
              return nil if section.nil?

              (@index ||= {})[section] ||= new(section)
            end

            # @api private — test seam.
            def reset_index!
              @index = {}
            end
          end

          # One compiled rule. `match` is the granularity-specific predicate
          # (a lambda of (ctx, const_fq)); `category` is a Symbol or nil; `role`
          # is a String or nil; `glob` is the path rule's raw pattern (nil for the
          # other two) and exists ONLY so the ordinal path ordering is a pure
          # function of the compiled set.
          Rule = Struct.new(:granularity, :category, :role, :match, :glob, keyword_init: true)

          def initialize(section)
            @calls   = compile_calls(Array(section["calls"]))
            @classes = compile_classes(Array(section["classes"]))
            @paths   = compile_paths(Array(section["paths"]))
            @declared = !(@calls.empty? && @classes.empty? && @paths.empty?)
            freeze
          end

          # True when the section declares at least one rule. A section present
          # but empty is NOT the same state as a section absent, and neither is
          # reported as the other.
          def declared?
            @declared
          end

          # @return [RubyResolver::Resolution, nil]
          def resolve(ctx)
            return nil unless @declared

            const_fq = receiver_constant_fq(ctx)
            return nil if const_fq.nil?

            rule = match(@calls, ctx, const_fq) ||
                   match(@classes, ctx, const_fq) ||
                   match(@paths, ctx, const_fq)
            return nil if rule.nil?

            crossing(rule, const_fq)
          end

          private

          # The declared crossing. `kind` is "external" UNCONDITIONALLY — never
          # derived from the category or the role (C12 invariant 3). `provenance`
          # is deliberately LEFT NIL: R1.5 is not a probe, so a declared crossing
          # must never appear in the `probe_edges` diagnostic and the exact-list
          # probe-order pin stays untouched.
          def crossing(rule, const_fq)
            RubyResolver::Resolution.new(
              tier: :boundary,
              action: :external,
              target_fq: normalize_target(const_fq),
              kind: "external",
              egress_category: rule.category,
              cco_role: rule.role
            )
          end

          def match(rules, ctx, const_fq)
            rules.find { |rule| rule.match.call(ctx, const_fq) }
          end

          # --- compilation ------------------------------------------------------

          # calls[]: { receiver: {kind:, values:}, verbs: [], category?, role? }
          def compile_calls(entries)
            seen = {}
            entries.map do |entry|
              receiver = entry.fetch("receiver")
              verbs    = Array(entry["verbs"]).map(&:to_s)
              constant = constant_matcher(receiver)
              guard_unique!(seen, "calls", receiver, verbs)

              verb_set = verbs.to_set
              Rule.new(
                granularity: :call,
                category: category_for(entry["category"], "calls"),
                role: entry["role"]&.to_s,
                match: ->(ctx, fq) { verb_set.include?(ctx.name.to_s) && constant.call(ctx, fq) }
              )
            end.freeze
          end

          # classes[]: { kind:, values: [], category? }
          def compile_classes(entries)
            seen = {}
            entries.map do |entry|
              constant = constant_matcher(entry)
              guard_unique!(seen, "classes", entry, nil)

              Rule.new(
                granularity: :class,
                category: category_for(entry["category"], "classes"),
                role: nil, # STRUCTURAL: the schema rejects `role` on a class rule.
                match: constant
              )
            end.freeze
          end

          # paths[]: { glob:, category? }
          #
          # Globs cannot be compared for specificity statically, so evaluation
          # orders by LONGEST LITERAL PREFIX — an ordinal rule with no magic
          # number, and a pure function of the rule set (never declaration order).
          def compile_paths(entries)
            seen = {}
            compiled = entries.map do |entry|
              glob = entry.fetch("glob").to_s
              guard_unique!(seen, "paths", glob, nil)

              Rule.new(
                granularity: :path,
                category: category_for(entry["category"], "paths"),
                role: nil, # STRUCTURAL: the schema rejects `role` on a path rule.
                match: path_matcher(glob),
                glob: glob
              )
            end
            compiled.sort_by { |rule| -literal_prefix_length(rule.glob) }.freeze
          end

          # The ONE membership gate on the closed egress vocabulary. Absent stays
          # ABSENT (nil): a crossing with no declared category routes to the
          # generic sink rather than inventing a category for it.
          def category_for(raw, where)
            return nil if raw.nil?

            allowed = self.class.allowed_categories
            unless allowed.include?(raw.to_s)
              raise UnknownCategoryError,
                    "boundary.#{where} declares category #{raw.to_s.inspect}; " \
                    "allowed categories are #{allowed.inspect}"
            end

            raw.to_s.to_sym
          end

          def guard_unique!(seen, granularity, key, extra)
            normalised = [normalise_key(key), extra && extra.map(&:to_s).sort].inspect
            if seen.key?(normalised)
              raise DuplicateRuleError,
                    "boundary.#{granularity} declares #{normalised} twice; " \
                    "a duplicate rule is never resolved by declaration order"
            end
            seen[normalised] = true
          end

          # Order-insensitive normal form for a match key, so `values: [A, B]`
          # and `values: [B, A]` are recognised as the same declaration.
          def normalise_key(key)
            case key
            when Hash  then key.reject { |k, _| %w[category role].include?(k) }
                              .transform_values { |v| normalise_key(v) }
                              .sort.to_h
            when Array then key.map(&:to_s).sort
            else key.to_s
            end
          end

          # --- matchers ---------------------------------------------------------

          # IDENTITY OR ANCESTRY ONLY. There is no branch here that could inspect
          # an AST node, and that is the structural guarantee, not a convention.
          def constant_matcher(spec)
            values = Array(spec.fetch("values")).map(&:to_s)
            case spec.fetch("kind").to_s
            when "constant_exact"  then exact_matcher(values.to_set)
            when "constant_prefix" then prefix_matcher(values.freeze)
            when "ancestor_of"     then ancestor_matcher(values.to_set)
            else
              raise ArgumentError, "unknown constant match kind #{spec["kind"].inspect}"
            end
          end

          def exact_matcher(values)
            ->(_ctx, fq) { values.include?(fq) }
          end

          def prefix_matcher(values)
            ->(_ctx, fq) { values.any? { |prefix| fq.start_with?(prefix) } }
          end

          # Ancestry is the SUPERCLASS chain and the mixins reachable along it —
          # the two primitives the SymbolTable already ships (`chain_any?` /
          # `chain_any_module?`), used exactly as the ORM and controller
          # discriminators use them. Self-identity is NOT ancestry: an
          # `ancestor_of` rule naming a class does not match that class itself
          # (that is what `constant_exact` is for). An out-of-tree constant has no
          # captured chain and therefore never matches — honestly, not silently.
          def ancestor_matcher(values)
            lambda do |ctx, fq|
              ctx.table.chain_any?(fq) { |entry| values.include?(entry.superclass.to_s) } ||
                ctx.table.chain_any_module?(fq) { |mixin_fq| values.include?(mixin_fq.to_s) }
            end
          end

          # The TARGET's definition-site path (L15), through the already-shipped
          # glob matcher. A receiver whose constant is not in the table has no
          # definition site here, so a path rule declines it rather than guessing.
          def path_matcher(glob)
            globs = [glob].freeze
            lambda do |ctx, fq|
              entry = ctx.table.class_for(fq)
              !entry.nil? && Archbuddy::Config::PathMatcher.match?(globs, entry.rel_file)
            end
          end

          def literal_prefix_length(glob)
            index = glob.index(Archbuddy::Config::PathMatcher::GLOB_CHARS)
            index.nil? ? glob.length : index
          end

          # --- receiver shape ---------------------------------------------------

          # The receiver's constant FQ when it is PROVABLE, else nil.
          #
          # An implicit-self receiver yields nil BY CONSTRUCTION, so R1.5 can
          # never claim a call the object makes on itself — a boundary is a thing
          # you cross, not a thing you are.
          #
          # C13's receiver-shape HOIST has now happened: the node-class ladder
          # lives in ReceiverShape and this method is pure composition. The
          # `:self` decline stays EXPLICIT rather than falling out of an omitted
          # branch — it is the load-bearing claim of the tier ("a boundary is a
          # thing you cross, not a thing you are"), not an accident of which node
          # classes a `case` happened to list.
          def receiver_constant_fq(ctx)
            recv = ctx.receiver
            return nil if ReceiverShape.self?(recv)

            # inline `Const.new` / `Const::Path.new`
            return ReceiverShape.constructor_constant_fq(recv) if ReceiverShape.constructor_chain?(recv)

            literal = ReceiverShape.constant_fq(recv)
            return literal unless literal.nil?

            typed_constant_fq(ctx, recv)
          end

          # The conservative intra-procedural type scope (L1), read ONLY — never
          # mutated. nil scope / untyped receiver => nil (decline).
          def typed_constant_fq(ctx, recv)
            scope = ctx.type_scope
            return nil if scope.nil?

            key = ReceiverShape.scope_key(recv)
            key && scope[key]
          end

          # Sink-identity normalization, mirroring `EgressProbe#normalize_target`
          # so a declared crossing and an inferred one on the same constant share
          # ONE sink: collapse whitespace, strip the leading `::` cbase.
          def normalize_target(const_fq)
            const_fq.gsub(/\s+/, "").delete_prefix("::")
          end
        end
      end
    end
  end
end
