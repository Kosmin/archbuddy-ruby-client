# frozen_string_literal: true

require "prism"

module Archbuddy
  module Collect
    module Adapters
      module Ruby
        # Shared, pure recognizer for the Grape endpoint DSL (W2). Single source
        # of truth used by BOTH Pass 1 (DefinitionPass — mints the endpoint NODE)
        # and Pass 2 (ResolutionPass — opens the handler-block scope so its calls
        # resolve as EDGES). Both passes MUST agree byte-for-byte on what counts
        # as an endpoint and on the synthetic FQ they mint/push, or edges silently
        # vanish (F5 ordinal-parity invariant) — keeping the detection here is the
        # mechanism that guarantees that agreement.
        #
        # Pure functions over Prism nodes only — no AST walk, no state, no app
        # boot (L7/P2 static-DSL-aware).
        module GrapeDsl
          # The Grape HTTP verb methods that, called with a block inside a
          # Grape::API subclass, declare an endpoint handler.
          HTTP_VERBS = %w[get post put patch delete].freeze

          # Superclass names that mark a class as a Grape API. A subclass of one
          # of these is where endpoint verb-blocks live.
          GRAPE_API_BASES = %w[Grape::API Grape::API::Instance].freeze

          module_function

          # True when `str` names a Grape::API superclass (the value of
          # `class Foo < Grape::API`). nil/empty -> false.
          def grape_api_superclass?(str)
            return false if str.nil?

            GRAPE_API_BASES.include?(str.to_s)
          end

          # True when `node` is an endpoint-declaring verb call: a CallNode whose
          # name is one of HTTP_VERBS, carrying a block, with an implicit-self /
          # explicit-self / nil receiver (Grape endpoints are declared on the
          # API's own DSL surface — `get "/x" do ... end`). A verb call on some
          # OTHER receiver (`client.get`) is NOT an endpoint.
          def endpoint_verb_call?(node)
            return false unless node.is_a?(Prism::CallNode)
            return false unless HTTP_VERBS.include?(node.name.to_s)
            return false if node.block.nil?

            self_receiver?(node.receiver)
          end

          # True when `node` mounts another API into the tree (`mount Foo::API`).
          # Receiver must be self/implicit; the first argument is the mounted
          # constant. (Recognition only — the mount PROBE lives in W3.)
          def mount_call?(node)
            return false unless node.is_a?(Prism::CallNode)
            return false unless node.name.to_s == "mount"

            self_receiver?(node.receiver)
          end

          # True when `node` opens a `helpers do ... end` block (shared helper
          # method defs for the surrounding API). Recognition only.
          def helpers_block_call?(node)
            return false unless node.is_a?(Prism::CallNode)
            return false unless node.name.to_s == "helpers"
            return false if node.block.nil?

            self_receiver?(node.receiver)
          end

          # The synthetic fully-qualified symbol for an endpoint handler block.
          # Stable, source-order-stamped so Pass 1 (mint) and Pass 2 (push) agree:
          #   "Api::Users#GET[0]"  — first GET endpoint declared in Api::Users.
          # The ordinal disambiguates multiple same-verb endpoints in one class
          # (`get "/a" do; end; get "/b" do; end`).
          def endpoint_fq(class_fq, verb, ordinal)
            "#{class_fq}##{verb.to_s.upcase}[#{ordinal}]"
          end

          def self_receiver?(receiver)
            receiver.nil? || receiver.is_a?(Prism::SelfNode)
          end
        end
      end
    end
  end
end
