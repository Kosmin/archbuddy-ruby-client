# frozen_string_literal: true

require "set"
require_relative "../../boundary_override"

module Archbuddy
  module Collect
    module Adapters
      module Ruby
        # The client-side view of an ENGINE-SHIPPED FRAMEWORK PROFILE
        # (configurator W2): a frozen value object wrapping the validated
        # profile document `ArchitectureAuditor::Contract::Profiles.load` hands
        # back, exposing it as the PREDICATES the collector actually asks.
        #
        # WHY A VALUE OBJECT AND NOT THE RAW HASH: every consumer used to ask a
        # `Set#include?` question of a frozen constant. Handing them a Hash
        # would push `dig("framework","orm","methods").map { … }` into a dozen
        # call sites — one document-shape change away from a dozen edits, and
        # a per-call-site allocation on a hot path. The lists become frozen
        # `Set`s HERE, once, at construction; the shape is known in exactly one
        # place.
        #
        # ORDERED LISTS STAY ARRAYS. `cron_config_paths` is iterated in
        # document order (that order IS the dialect precedence); turning it
        # into a Set would silently make the order an implementation detail.
        #
        # NO FALLBACK, BY DESIGN. There is no `profile: nil ⇒ hardcoded vocab`
        # path anywhere: a failure to load the profile PROPAGATES and the
        # collect refuses to run. A silent fallback is the single worst failure
        # mode available here — it would make the whole migration invisible and
        # the purity gate vacuous.
        class Profile
          # The profile this client ships against. The id is the FILE STEM the
          # engine serves; every other identity fact (the document's own
          # `profile_id`, its digest) is read from the producer, never retyped.
          DEFAULT_ID = "ruby.rails"

          Profiles = ArchitectureAuditor::Contract::Profiles

          class << self
            # The default profile, memoised. Errors propagate.
            def reference
              self.for(DEFAULT_ID)
            end

            # @param id [String, nil] profile id; nil selects {DEFAULT_ID}
            # @param boundary_override [Hash, nil] configurator W4 (C11): the
            #   project's validated `boundary:` section. Part of the MEMO KEY, not
            #   just an argument — two Profiles built from the same document under
            #   different overrides are different vocabularies and must never
            #   share a memo slot.
            def for(id = nil, boundary_override: nil)
              key = [(id || DEFAULT_ID).to_s, boundary_override]
              memo[key] ||= new(Profiles.load(key.first), boundary_override: boundary_override)
            end

            # @api private — test seam; the shipped documents cannot change
            #   within a process, so the memo is otherwise permanent.
            def reset_memo!
              @memo = {}
            end

            private

            def memo
              @memo ||= {}
            end
          end

          attr_reader :id, :category_precedence, :cron_config_paths, :cron_whenever_path

          # configurator W4 (C9): the OPTIONAL `boundary` section, handed back as
          # the deep-frozen sub-document the engine validated — NOT as predicates.
          #
          # This is the one field the Profile deliberately does NOT digest into
          # `Set`s: the boundary grammar is three granularities with a precedence
          # order between them, i.e. LOGIC, and logic belongs in `BoundaryRules`,
          # not in this value object. Everything the collector asks of a boundary
          # is asked of that class.
          #
          # nil when the profile declares no boundary section at all (every
          # pre-W4 document). "No section" and "a section with every list empty"
          # are DIFFERENT states and are never collapsed into a fabricated `{}` —
          # `BoundaryRules` short-circuits on the first and compiles an
          # empty-but-real index for the second.
          attr_reader :boundary

          def initialize(document, boundary_override: nil)
            @document = document
            @id       = document.fetch("profile_id")

            language = document.fetch("language")
            @operator_deny             = set_of(language["operator_deny"])
            @dynamic_dispatch_verbs    = set_of(language["dynamic_dispatch_verbs"])
            @resolvable_dispatch_verbs = set_of(language["resolvable_dispatch_verbs"])

            framework = document.fetch("framework")
            load_orm(framework["orm"])
            load_controllers(framework["controllers"])
            load_jobs(framework["jobs"])
            load_entrypoints(framework["entrypoints"])
            load_scripts(framework["scripts"])
            load_cron(framework["cron"])
            load_egress(document["library"])
            # configurator W4 (C11): PURE DELEGATION. The merge rule (section-level
            # merge, list-level replace) is BoundaryOverride's; this value object
            # neither knows it nor branches on it.
            @boundary = BoundaryOverride.merge(document["boundary"], boundary_override)

            freeze
          end

          # SHA-256 of the shipped profile bytes, read from the producer (never
          # recomputed here) — the cache-staleness input.
          def digest
            Profiles.digest(@id)
          end

          # --- language ------------------------------------------------------

          def operator?(name)             = @operator_deny.include?(name.to_s)
          def dynamic_dispatch_verb?(name) = @dynamic_dispatch_verbs.include?(name.to_s)
          def resolvable_dispatch_verb?(name) = @resolvable_dispatch_verbs.include?(name.to_s)

          # --- ORM / controllers ---------------------------------------------

          def orm_method?(name) = @orm_methods.include?(name.to_s)
          def orm_base?(fq)     = @orm_bases.include?(fq.to_s)

          def controller_base?(fq) = @controller_bases.include?(fq.to_s)

          def controller_name_suffix?(fq)
            name = fq.to_s
            @controller_name_suffixes.any? { |suffix| name.end_with?(suffix) }
          end

          # --- jobs -----------------------------------------------------------

          def job_mixin?(fq)         = @job_mixins.include?(fq.to_s)
          def job_base?(fq)          = @job_bases.include?(fq.to_s)
          def job_dispatch_verb?(name) = @job_dispatch_verbs.include?(name.to_s)

          # --- entrypoints ----------------------------------------------------

          def seeded_category?(name) = @seeded_categories.include?(name.to_s)

          # --- scripts / cron --------------------------------------------------

          def script_dir?(segment)     = @script_dirs.include?(segment.to_s)
          def script_loader_call?(name) = @script_loader_calls.include?(name.to_s)
          def cron_runner_verb?(name)  = @cron_runner_verbs.include?(name.to_s)

          # --- egress ----------------------------------------------------------

          # Exact known-root match OR a declared root PREFIX (`Aws::S3::Client`,
          # `Aws::SNS::Client`, … all share one prefix entry). Two mechanisms,
          # deliberately separate fields: folding the prefix into the exact list
          # would silently stop matching every service constant.
          def egress_root?(fq)
            name = fq.to_s
            @egress_roots.include?(name) || @egress_root_prefixes.any? { |p| name.start_with?(p) }
          end

          def egress_verb?(name) = @egress_verbs.include?(name.to_s)

          # --- roles (configurator W3 / E13) ------------------------------------
          #
          # The INERT crossing-role tag the profile declares per VERB. Both
          # readers return nil for a verb the profile leaves unroled — and a
          # rev-1.0 (role-free) profile therefore yields nil for EVERY verb.
          # nil is UNDECLARED and must never be defaulted to a value: the key
          # simply does not appear on the emitted node.
          #
          # `Hash#[]` (not `fetch`) is deliberate — an unknown verb and an
          # unroled verb are the same answer here ("this profile declares no
          # role"), and the callers already gate on the verb being known.

          # @return [String, nil] role for an ORM method name.
          def orm_role(name) = @orm_roles[name.to_s]

          # @return [String, nil] role for an egress (HTTP-client) verb name.
          def egress_verb_role(name) = @egress_verb_roles[name.to_s]

          private

          def load_orm(orm)
            @orm_methods = set_of((orm["methods"] || []).map { |entry| entry["name"] })
            @orm_bases   = set_of(orm["base_classes"])
            @orm_roles   = role_table(orm["methods"])
          end

          def load_controllers(controllers)
            @controller_bases         = set_of(controllers["base_classes"])
            @controller_name_suffixes = frozen_list(controllers["name_suffixes"])
          end

          def load_jobs(jobs)
            @job_mixins         = set_of(jobs["mixins"])
            @job_bases          = set_of(jobs["base_classes"])
            @job_dispatch_verbs = set_of(jobs["dispatch_verbs"])
          end

          def load_entrypoints(entrypoints)
            @category_precedence = frozen_list(entrypoints["category_precedence"])
            @seeded_categories   = set_of(entrypoints["seeded_categories"])
          end

          def load_scripts(scripts)
            @script_dirs         = set_of(scripts["dirs"])
            @script_loader_calls = set_of(scripts["loader_only_calls"])
          end

          def load_cron(cron)
            @cron_config_paths  = frozen_list(cron["config_paths"])
            @cron_whenever_path = cron["whenever_path"]
            @cron_runner_verbs  = set_of(cron["runner_target_verbs"])
          end

          # The `library.egress` tier is a LIST of library entries; the
          # collector asks one flattened question ("is this constant an egress
          # root"), so the roots/prefixes/verbs union across entries.
          def load_egress(library)
            entries = (library && library["egress"]) || []
            @egress_roots         = set_of(entries.flat_map { |e| e["roots"] || [] })
            @egress_root_prefixes = frozen_list(entries.flat_map { |e| e["root_prefixes"] || [] })
            @egress_verbs         = set_of(entries.flat_map { |e| (e["verbs"] || []).map { |v| v["name"] } })
            @egress_verb_roles    = role_table(entries.flat_map { |e| e["verbs"] || [] })
          end

          # {verb_name => role} over a profile verb table, carrying ONLY the
          # entries that actually declare a role. An unroled entry is OMITTED
          # rather than mapped to nil, so `Hash#key?` and `Hash#[]` agree that
          # the profile declares nothing for it.
          def role_table(entries)
            Array(entries).each_with_object({}) do |entry, table|
              role = entry["role"]
              table[entry["name"].to_s] = role.to_s if role
            end.freeze
          end

          def set_of(values)
            Array(values).map(&:to_s).to_set.freeze
          end

          def frozen_list(values)
            Array(values).map(&:to_s).freeze
          end
        end
      end
    end
  end
end
