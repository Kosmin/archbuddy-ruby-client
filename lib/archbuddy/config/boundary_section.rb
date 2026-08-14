# frozen_string_literal: true

require "json"

module Archbuddy
  class Config
    # THE PROJECT BOUNDARY OVERRIDE, VALIDATED BY THE ENGINE (configurator W4 /
    # C10) — the ONE key `.archbuddy.yml` gains in this wave: `boundary:`.
    #
    # WHY THE ENGINE'S SCHEMA AND NOT A SECOND TABLE IN Config::Schema. The
    # boundary grammar already has exactly one producer: the `boundary`
    # sub-schema inside the engine's `profile.v1.schema.json`. Re-typing that
    # grammar into `Config::Schema`'s key registry would create a SECOND source
    # of the same canon, and the two would drift the first time the engine adds
    # a granularity. So this class does not describe the grammar at all — it
    # WRAPS the project's section in a minimal, schema-derived profile envelope
    # and hands the whole document to the engine's `Contract::Validator`.
    #
    # THE STRUCTURAL CONSEQUENCE, WHICH IS THE POINT. Because validation is the
    # engine's JSON Schema and not this repo's `check_unknown_keys`, a project
    # CANNOT invent grammar the profile does not have:
    #
    #   * an unknown key anywhere under `boundary:` is rejected by the schema's
    #     own `additionalProperties: false`, not by a key list maintained here;
    #   * `role:` on a path or class rule is rejected for the SAME reason — the
    #     "only a call rule may carry a role" restriction is structural in the
    #     schema, so it is inherited rather than re-asserted.
    #
    # A key list maintained here would have to be remembered and updated; an
    # `additionalProperties` error cannot be forgotten.
    #
    # WHY A CLASS AND NOT A BRANCH IN Config::Validator (V-6). The envelope
    # construction, the engine call, the error-path rewrite and the L17 refusal
    # all live HERE. `config/validator.rb` gains ONE line that appends whatever
    # this class returns. That is also what makes the acceptance anchor
    # structurally guaranteed rather than conventional: `Config::Validator`
    # never learns the boundary key names, so it has no way to reject one, so
    # the rejection can only come from the schema.
    class BoundarySection
      # The top-level `.archbuddy.yml` key this class owns. Registered in
      # Schema::TOP_LEVEL_KEYS so the generic unknown-key check passes it
      # through to here (see the acceptance anchor above).
      KEY = "boundary"

      # The synthetic envelope's `profile_id`. It is never loaded, served or
      # digested — it exists only so the envelope satisfies the schema's own
      # `required` list. Shaped to the schema's `profile_id` pattern.
      ENVELOPE_PROFILE_ID = "archbuddy_yml.project_override"

      # L17 — SAME-ROOT MULTI-INSTANCE, PRICED AND REJECTED.
      #
      # Declaring several boundaries for ONE repo root (a sequence of sections,
      # one per component of a monorepo) was priced and rejected: every instance
      # would have to carry its own `.archbuddy/` namespace, and the committed
      # cache, the id-map and the collect manifest all key off the repo root
      # alone. DIFFERENT ROOTS ALREADY WORK and need no new machinery — each
      # root gets its own workspace for free.
      #
      # So the attempt is REFUSED, LOUDLY, naming the shape that does work. The
      # alternative is not "it silently analyses the first instance"; it is two
      # runs writing the same `.archbuddy/` cache under different vocabularies
      # with nothing recording which one produced it.
      #
      # SCOPED TO THE SEQUENCE SHAPE ON PURPOSE. A sequence is the only spelling
      # that unambiguously means "more than one of these", and it is a shape the
      # schema's `additionalProperties` can never see (that keyword applies to
      # objects). Guarding a mapping with unfamiliar keys here instead would
      # PREEMPT the additionalProperties rejection above — the one thing this
      # class exists to preserve.
      MULTI_INSTANCE_ERROR =
        "boundary must be a single mapping, not a sequence — declaring several " \
        "boundary instances for ONE repo root is not supported. One .archbuddy.yml " \
        "declares ONE boundary for ONE repo root; to audit two components under " \
        "different boundaries, run archbuddy separately at each component root " \
        "(separate roots already get separate .archbuddy/ workspaces)."

      # Raised when the ENVELOPE itself is malformed — i.e. the engine reported a
      # violation OUTSIDE `#/boundary`, which can only mean this class built a
      # document the profile schema rejects. LOUD-SKIP OVER SILENT-SKIP: filtering
      # such an error away would let an envelope bug masquerade as "the project's
      # boundary is fine".
      class EnvelopeError < StandardError; end

      # The JSON-pointer prefix every error we are willing to report must carry.
      FRAGMENT_PREFIX = "#/#{KEY}"

      # `json-schema` appends " in schema <uri>" to every message. The URI names
      # the ENGINE's schema, not the project's config, so it is noise in a
      # user-facing config error.
      SCHEMA_SUFFIX = / in schema \S+\z/

      class << self
        # @param section [Object, nil] the raw value of the `boundary:` key
        # @return [Array<String>] zero or more errors, one string each. `nil`
        #   (the key is absent) yields [] — an absent override is not an error.
        # @raise [EnvelopeError] when the engine faults the envelope rather than
        #   the project's section.
        def errors(section)
          return [] if section.nil?
          return [MULTI_INSTANCE_ERROR] if section.is_a?(Array)

          contract::Validator.fully_validate(:profile, envelope(section)).map do |message|
            rewrite(message)
          end
        end

        private

        # The engine's contract hub. Resolved LAZILY, not bound to a constant at
        # load time: `archbuddy/config` is requirable on its own, and a load-time
        # reference would make that require order-dependent on the engine.
        def contract
          ArchitectureAuditor::Contract
        end

        # The minimal document that carries `section` to the profile schema.
        #
        # DERIVED FROM THE PRODUCER, NOT RE-TYPED: the required key list is read
        # out of the schema file itself, so the envelope cannot fall out of step
        # with the contract it is built to satisfy. Only the two SCALAR required
        # keys are filled with values (the version from its own constant); every
        # other required key is an empty tier object, which the schema
        # explicitly permits ("May carry all-empty (or absent) lists").
        def envelope(section)
          base = required_keys.to_h { |key| [key, {}] }
          base["profile_schema_version"] = contract::PROFILE_SCHEMA_VERSION
          base["profile_id"]             = ENVELOPE_PROFILE_ID
          base.merge(KEY => section)
        end

        def required_keys
          @required_keys ||= JSON.parse(
            File.read(contract::Validator.schema_path(:profile))
          ).fetch("required").freeze
        end

        # Turn one engine message into a config-surface message: the JSON
        # pointer becomes the `.archbuddy.yml` key path that produced it, and
        # the engine's schema URI is dropped.
        #
        #   The property '#/boundary/classes/0' contains additional properties …
        #     => The property 'boundary.classes[0]' contains additional properties …
        def rewrite(message)
          fragment = message[%r{'(#/\S*?)'}, 1]
          unless fragment&.start_with?(FRAGMENT_PREFIX)
            raise EnvelopeError,
                  "boundary validation faulted outside #{FRAGMENT_PREFIX}: #{message}"
          end

          message.sub("'#{fragment}'", "'#{key_path(fragment)}'").sub(SCHEMA_SUFFIX, "")
        end

        # `#/boundary/classes/0/kind` => `boundary.classes[0].kind`
        def key_path(fragment)
          fragment.delete_prefix("#/").split("/").each_with_object(+"") do |part, path|
            if part.match?(/\A\d+\z/)
              path << "[#{part}]"
            else
              path << "." unless path.empty?
              path << part
            end
          end
        end
      end
    end
  end
end
