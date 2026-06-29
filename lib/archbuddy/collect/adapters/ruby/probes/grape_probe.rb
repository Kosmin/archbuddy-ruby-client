# frozen_string_literal: true

require "prism"
require_relative "../probe"
require_relative "../resolver"
require_relative "../grape_dsl"

module Archbuddy
  module Collect
    module Adapters
      module Ruby
        module Probes
          # Resolver-tier probe (R5) for the Grape MOUNT tree (W3). When a
          # `mount Const` call appears inside a Grape::API, Grape PROVABLY
          # composes the mounted API into the host's route tree. The base
          # resolver can't see this edge (a `mount` call has no app target), so
          # this probe recovers it: an edge from the mounting context to a
          # REPRESENTATIVE endpoint node of the mounted API.
          #
          # NEVER-FABRICATE (L2): the probe emits an edge ONLY when
          #   1. the call is a `mount Const` with a literal constant argument
          #      (a dynamic `mount build_api()` or `mount` of a non-constant
          #      declines), AND
          #   2. the mounted constant is a KNOWN Grape::API class
          #      (`table.class_for(fq)&.grape_api?`), AND
          #   3. that API has at least one minted endpoint node whose FQ is in
          #      the table (`table.method?`).
          # Otherwise it DECLINES (returns nil) so the call falls through to the
          # next probe / R9 `<external>`. It NEVER points an edge at a class (not
          # a node) or a non-existent endpoint.
          class GrapeProbe < Probe
            # The Grape HTTP verbs, in a stable order, used to search for the
            # mounted API's representative (first-declared) endpoint node. We
            # probe the lowest ordinal of each verb in turn (GET[0], POST[0], …)
            # and take the first that resolves to a known node — the same FQ
            # space DefinitionPass mints via GrapeDsl.endpoint_fq.
            REPRESENTATIVE_VERBS = GrapeDsl::HTTP_VERBS

            def self.probe_name
              :grape
            end

            def name
              :grape
            end

            # @param ctx [RubyResolver::CallContext]
            # @return [RubyResolver::Resolution, nil]
            def resolve(ctx)
              node = ctx.node
              return nil unless GrapeDsl.mount_call?(node)

              mounted_fq = mounted_constant_fq(node)
              return nil if mounted_fq.nil?

              klass = ctx.table.class_for(mounted_fq)
              return nil unless klass&.grape_api?

              target_fq = representative_endpoint_fq(ctx.table, mounted_fq)
              return nil if target_fq.nil?

              RubyResolver::Resolution.new(
                tier: :probe_grape, action: :edge, target_fq: target_fq, kind: nil
              )
            end

            private

            # Extract the mounted constant's fq name from the first argument of a
            # `mount` call. Supports `mount Const` and `mount Const => "/path"`
            # (the hash-key form). Returns nil for anything that isn't a literal
            # constant (dynamic mount → decline, L2).
            def mounted_constant_fq(node)
              first = node.arguments&.arguments&.first
              return nil if first.nil?

              const = constant_node(first)
              const&.slice
            end

            # Resolve an argument node to its constant node, or nil. A bare
            # constant is itself; a `mount Const => "/path"` hash uses the first
            # element's KEY as the mounted constant.
            def constant_node(arg)
              case arg
              when Prism::ConstantReadNode, Prism::ConstantPathNode
                arg
              when Prism::KeywordHashNode, Prism::HashNode
                first_pair = arg.elements.first
                return nil unless first_pair.is_a?(Prism::AssocNode)

                key = first_pair.key
                key if key.is_a?(Prism::ConstantReadNode) || key.is_a?(Prism::ConstantPathNode)
              end
            end

            # The mounted API's representative endpoint node: the first declared
            # endpoint (lowest ordinal) of the lowest-priority verb that has a
            # KNOWN node in the table. Probes ordinal 0 of each verb in
            # REPRESENTATIVE_VERBS order. Returns nil when the mounted API has NO
            # minted endpoint node (empty API) — decline, never fabricate.
            def representative_endpoint_fq(table, mounted_fq)
              REPRESENTATIVE_VERBS.each do |verb|
                candidate = GrapeDsl.endpoint_fq(mounted_fq, verb, 0)
                return candidate if table.method?(candidate)
              end
              nil
            end
          end
        end
      end
    end
  end
end
