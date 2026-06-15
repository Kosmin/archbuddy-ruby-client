# frozen_string_literal: true

require "architecture_auditor"
require_relative "model"
require_relative "scores"

module Archbuddy
  module Report
    # R-2: the Reconnect (join) engine. Loads findings.yml + the SECRET
    # id-map.yml via the contract Serializer (safe_load) and de-anonymizes at
    # EXACTLY the three contract join sites:
    #
    #   1. `findings.nodes.<id>`        — every scored node (→ a Bottleneck)
    #   2. every `findings[].node`      — node-type findings
    #   3. every element of every
    #      `findings[].path[]`          — ordered real call chains
    #
    # Metrics + clutter_score are copied VERBATIM — the Reconnect engine NEVER
    # recomputes them (Reporter-only, D17). Ids absent from the id-map (e.g.
    # `ext_` external sinks, or any unknown id) resolve GRACEFULLY to an
    # `<external …>` placeholder Location and NEVER raise.
    class Reconnect
      Serializer = ArchitectureAuditor::Contract::Serializer

      # Result of a join: ranked-able Bottleneck objects + the resolver so the
      # Ranker can de-anonymize cls_ rollups against the same id-map. `scores`
      # is the optional de-anonymized project-level dimension scores (findings
      # 1.1) — NIL for a 1.0 findings doc with no scores block (back-compat).
      Result = Struct.new(:bottlenecks, :id_map, :findings_doc, :scores, keyword_init: true) do
        # Look up a (possibly missing) opaque id → Model::Location.
        def resolve(id)
          IdMapResolver.new(id_map).resolve(id)
        end
      end

      # Wraps the id-map's `ids` table and resolves opaque ids to real symbols,
      # falling back to a graceful placeholder for anything missing.
      class IdMapResolver
        def initialize(id_map)
          @ids = (id_map || {})["ids"] || {}
        end

        # @return [Model::Location] always — resolved? is false for missing ids.
        def resolve(id)
          desc = @ids[id]
          return placeholder(id) if desc.nil?

          Model::Location.new(
            id:       id,
            file:     desc["file"],
            line:     desc["line"],
            symbol:   desc["symbol"],
            kind:     desc["kind"],
            class_id: desc["class_id"],
            resolved: true
          )
        end

        private

        # An id absent from the id-map (ext_ sinks, pruned/unknown ids). We never
        # raise: external sinks have no real symbol by design, so we surface a
        # readable placeholder that still carries the opaque id for traceability.
        def placeholder(id)
          label =
            if id.to_s.start_with?("ext_")
              "<external sink #{id}>"
            else
              "<external #{id}>"
            end

          Model::Location.new(
            id:       id,
            file:     nil,
            line:     nil,
            symbol:   label,
            kind:     "external",
            class_id: nil,
            resolved: false
          )
        end
      end

      # Build a Reconnect from file paths (the CLI path).
      def self.from_files(findings_path:, id_map_path:)
        new(
          findings_doc: Serializer.load(findings_path),
          id_map:       Serializer.load(id_map_path)
        )
      end

      # @param findings_doc [Hash] parsed findings.yml (string keys)
      # @param id_map       [Hash] parsed id-map.yml (string keys; SECRET)
      def initialize(findings_doc:, id_map:)
        @findings_doc = findings_doc || {}
        @id_map       = id_map || {}
        @resolver     = IdMapResolver.new(@id_map)
      end

      # Join findings × id-map → de-anonymized Bottlenecks (one per scored node),
      # each carrying the findings that touch it. Returns a Result.
      def call
        findings_by_node = group_findings_by_node

        bottlenecks = nodes.map do |id, node_entry|
          Model::Bottleneck.new(
            id:            id,
            location:      @resolver.resolve(id),
            kind:          @resolver.resolve(id).kind,
            class_id:      @resolver.resolve(id).class_id,
            # VERBATIM copy — never recomputed (D17). Whatever findings.yml says,
            # even if deliberately "wrong", is exactly what we carry/display.
            metrics:       node_entry["metrics"] || {},
            clutter_score: node_entry["clutter_score"],
            findings:      findings_by_node.fetch(id, [])
          )
        end

        Result.new(
          bottlenecks:  bottlenecks,
          id_map:       @id_map,
          findings_doc: @findings_doc,
          # Optional findings-1.1 project scores, de-anonymized via the SAME
          # resolver. NIL when absent (1.0 doc) — graceful, no header rendered.
          scores:       Scores.from_findings(@findings_doc, @resolver)
        )
      end

      private

      def nodes
        @findings_doc["nodes"] || {}
      end

      def raw_findings
        @findings_doc["findings"] || []
      end

      # De-anonymize every finding and index node-type findings by their node id
      # so each Bottleneck can carry the findings touching it. Path-type findings
      # are attached to the FIRST resolvable node on their path (so a long_path /
      # cycle shows up on the bottleneck where the chain originates).
      def group_findings_by_node
        index = Hash.new { |h, k| h[k] = [] }

        raw_findings.each do |raw|
          finding = deanonymize_finding(raw)

          if finding.path?
            anchor = raw["path"]&.first
            index[anchor] << finding if anchor
          elsif finding.node
            index[finding.node.id] << finding
          end
        end

        index
      end

      # Join site #2 (findings[].node) and #3 (findings[].path[]).
      def deanonymize_finding(raw)
        node_id = raw["node"]
        path    = raw["path"]

        Model::Finding.new(
          type:      raw["type"],
          severity:  raw["severity"],
          node:      node_id && @resolver.resolve(node_id),
          path_refs: path && path.map { |pid| @resolver.resolve(pid) }
        )
      end
    end
  end
end
