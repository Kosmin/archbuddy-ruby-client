# frozen_string_literal: true

require "set"
require_relative "../config/path_matcher"

module Archbuddy
  module Review
    # The delta table over (file, symbol) identities (L6/P3) + the v0.15
    # ep-level surfaces:
    #
    #   #entries        node-level NEW/GROWN/SHRUNK/REMOVED/CHANGED_ATTRS
    #   #net_log2       L6 NET over ALL entries (positive AND negative)
    #   #ep_deltas      Hash[[file, ep_symbol] → subtree deltas] — ALL eps,
    #                   unchanged at 0.0 (the ratchet ep-budget seam, Q7/R43)
    #   #ep_entries     the U_metric universe (Q2): NEW/REMOVED eps + matched
    #                   eps whose metric vector moved (exact !=)
    #   #review_surface Q3: ∪ of distinct eps whose side-appropriate reflexive
    #                   cone contains any CHANGED node; Σ diagnostic; blast-0
    #                   changed nodes → unreachable_touched (NEVER safety)
    #   #disclosures    Q2's two standing disclosures
    class Delta
      ROUND_DECIMALS = 3

      Entry = Data.define(:file, :symbol, :classification, :base_branches, :head_branches,
                          :delta_log2, :base_node, :head_node, :moved_from, :moved_to)

      module EpDelta
        Entry = Data.define(:file, :ep_symbol, :classification, :base, :head, :delta,
                            :contributors, :contributors_omitted)
      end

      # The U_metric trigger vector (Q2 + the G7 dividend rider).
      METRIC_KEYS = %i[branching_log2 mass reach files depth dividend_log2].freeze

      def initialize(base:, head:)
        @base = base
        @head = head
      end

      attr_reader :base, :head

      # ---- node-level surface ([S] verbatim) ---------------------------------

      def entries
        @entries ||= begin
          excluded = excluded_files.to_set
          identities = (@base.by_identity.keys | @head.by_identity.keys)
                       .reject { |(file, _sym)| excluded.include?(file) }
                       .sort
          rows = identities.filter_map { |identity| classify(identity) }
          annotate_moves(rows)
        end
      end

      # L6 NET over ALL entries; compare/display .round(3), JSON .round(6).
      def net_log2
        @net_log2 ||= entries.sum(&:delta_log2)
      end

      def counts
        @counts ||= begin
          tally = { new: 0, grown: 0, shrunk: 0, removed: 0 }
          entries.each do |entry|
            tally[entry.classification] += 1 if tally.key?(entry.classification)
          end
          tally
        end
      end

      # Files appearing in ANY materialized entry (C10 — edge-only ripple
      # files deliberately excluded; lint's jurisdiction).
      def touched_files
        @touched_files ||= entries.map(&:file).to_set
      end

      def scope_net(paths:)
        entries.select { |e| Config::PathMatcher.match?(paths, e.file) }
               .sum(&:delta_log2)
      end

      def scope_match?(paths:)
        (@base.files | @head.files).any? { |file| Config::PathMatcher.match?(paths, file) }
      end

      def excluded_files
        @excluded_files ||= (@base.corrupt_files | @head.corrupt_files).sort
      end

      # ---- ep-level surfaces (v0.15) -----------------------------------------

      # ALL eps (union of both sides), keyed (file, ep_symbol); unchanged eps
      # carry delta 0.0 — the ComplexityRatchet entrypoints-budget seam.
      def ep_deltas
        @ep_deltas ||= begin
          base_metrics = @base.graph.ep_metrics
          head_metrics = @head.graph.ep_metrics
          (base_metrics.keys | head_metrics.keys).sort.each_with_object({}) do |key, acc|
            base_subtree = base_metrics[key]&.branching_log2
            head_subtree = head_metrics[key]&.branching_log2
            classification =
              if base_subtree && head_subtree then :matched
              elsif head_subtree then :new
              else :removed
              end
            acc[key] = {
              base_subtree: base_subtree,
              head_subtree: head_subtree,
              delta: (head_subtree || 0.0) - (base_subtree || 0.0),
              classification: classification
            }
          end
        end
      end

      # The U_metric universe (Q2), materialized ONLY for eps NEW, REMOVED, or
      # metric-moved. nil side rendered absent, NEVER 0.
      def ep_entries
        @ep_entries ||= begin
          base_metrics = @base.graph.ep_metrics
          head_metrics = @head.graph.ep_metrics
          rows = (base_metrics.keys | head_metrics.keys).sort.filter_map do |key|
            base_row = base_metrics[key]
            head_row = head_metrics[key]
            if base_row && head_row
              delta = metric_delta(base_row, head_row)
              next if delta.nil? # metric-quiet — not in U_metric

              build_ep_entry(key, :matched, base_row, head_row, delta)
            elsif head_row
              build_ep_entry(key, :new, nil, head_row, nil)
            else
              build_ep_entry(key, :removed, base_row, nil, nil)
            end
          end
          rows.sort_by do |entry|
            move = entry.delta ? -entry.delta[:branching_log2].abs : 0.0
            [move, entry.classification.to_s, entry.file.to_s, entry.ep_symbol.to_s]
          end
        end
      end

      # Q3: ∪ of distinct eps whose side-appropriate reflexive cone contains
      # any CHANGED node; Σ = Σ per-node blast counts (diagnostic — honest as
      # "review reads"); blast-0 changed nodes → unreachable_touched.
      def review_surface
        @review_surface ||= begin
          union = {}
          sum = 0
          unreachable = []
          changed_nodes.each do |entry|
            graph = entry.classification == :removed ? @base.graph : @head.graph
            reaching = eps_reaching(graph, entry.symbol)
            sum += reaching.size
            if reaching.empty?
              unreachable << { file: entry.file, symbol: entry.symbol }
            else
              reaching.each { |ep_key, blog2| union[ep_key] ||= blog2 }
            end
          end

          eps = union.map do |(file, ep_symbol), branching_log2|
            {
              file: file, ep_symbol: ep_symbol, branching_log2: branching_log2,
              classification: ep_deltas.dig([file, ep_symbol], :classification) || :matched
            }
          end
          eps.sort_by! { |row| [-row[:branching_log2], row[:ep_symbol].to_s] }

          {
            union: union.size,
            sum: sum,
            eps: eps,
            unreachable_touched: {
              count: unreachable.size,
              nodes: unreachable.uniq.sort_by { |n| [n[:file], n[:symbol]] }
            }
          }
        end
      end

      # Q2's two standing disclosures.
      def disclosures
        @disclosures ||= {
          orphan_touched_files: orphan_touched_files,
          offsetting_zero_count: offsetting_zero_count
        }
      end

      private

      # ---- node classification -----------------------------------------------

      def classify(identity)
        base_node = @base.by_identity[identity]
        head_node = @head.by_identity[identity]
        file, symbol = identity

        if base_node && head_node.nil?
          entry(file, symbol, :removed, base_node, nil, -log2_of(base_node))
        elsif head_node && base_node.nil?
          entry(file, symbol, :new, nil, head_node, +log2_of(head_node))
        elsif base_node.branches != head_node.branches
          classification = branch_count(head_node) > branch_count(base_node) ? :grown : :shrunk
          entry(file, symbol, classification, base_node, head_node,
                log2_of(head_node) - log2_of(base_node))
        elsif attrs_changed?(base_node, head_node)
          entry(file, symbol, :changed_attrs, base_node, head_node, 0.0)
        end
      end

      def entry(file, symbol, classification, base_node, head_node, delta_log2)
        Entry.new(
          file: file, symbol: symbol, classification: classification,
          base_branches: base_node&.branches, head_branches: head_node&.branches,
          delta_log2: delta_log2, base_node: base_node, head_node: head_node,
          moved_from: nil, moved_to: nil
        )
      end

      def attrs_changed?(base_node, head_node)
        base_node.escapes != head_node.escapes ||
          base_node.toll_booth != head_node.toll_booth ||
          base_node.outcome_arity != head_node.outcome_arity
      end

      def log2_of(node)
        valid_branches?(node) ? Math.log2(node.branches) : 0.0
      end

      def branch_count(node)
        node.branches.is_a?(Integer) ? node.branches : 0
      end

      def valid_branches?(node)
        node.branches.is_a?(Integer) && node.branches >= 1
      end

      # MOVED annotation (display-only; math stays remove+add per P3):
      # REMOVED(file A, s) + NEW(file B, s) with identical branches+decisions.
      def annotate_moves(rows)
        removed_by_symbol = rows.select { |e| e.classification == :removed }.group_by(&:symbol)
        new_by_symbol = rows.select { |e| e.classification == :new }.group_by(&:symbol)

        rows.map do |row|
          if row.classification == :removed
            twin = (new_by_symbol[row.symbol] || []).find { |n| same_payload?(row.base_node, n.head_node) }
            twin ? row.with(moved_to: twin.file) : row
          elsif row.classification == :new
            twin = (removed_by_symbol[row.symbol] || []).find { |r| same_payload?(r.base_node, row.head_node) }
            twin ? row.with(moved_from: twin.file) : row
          else
            row
          end
        end
      end

      def same_payload?(base_node, head_node)
        base_node && head_node &&
          base_node.branches == head_node.branches &&
          base_node.decisions == head_node.decisions
      end

      # ---- U_metric ------------------------------------------------------------

      # Per-metric Δ hash for matched eps; nil when NO component moved.
      # Exact != (folds over identical inputs in pinned sorted order are
      # bitwise-reproducible); dividend_log2 nil↔nil = no move, nil↔value = move.
      def metric_delta(base_row, head_row)
        moved = false
        delta = {}
        METRIC_KEYS.each do |key|
          base_value = base_row.public_send(key)
          head_value = head_row.public_send(key)
          moved ||= base_value != head_value
          delta[key] = base_value && head_value ? head_value - base_value : nil
        end
        moved ? delta : nil
      end

      def build_ep_entry(key, classification, base_row, head_row, delta)
        file, ep_symbol = key
        contributors, omitted = contributors_for(key, classification, base_row, head_row)
        EpDelta::Entry.new(
          file: file, ep_symbol: ep_symbol, classification: classification,
          base: base_row, head: head_row, delta: delta,
          contributors: contributors, contributors_omitted: omitted
        )
      end

      # Contributor selection (Q9): changed nodes within cone(base) ∪
      # cone(head) ranked |Δlog2 b_own| desc, ties (file, symbol) asc, top-5;
      # payload-unchanged nodes whose edge set changed tag coupling_flip.
      def contributors_for(key, classification, _base_row, _head_row)
        _file, ep_symbol = key
        cone = Set.new
        cone.merge(cone_symbols(@base.graph, ep_symbol)) unless classification == :new
        cone.merge(cone_symbols(@head.graph, ep_symbol)) unless classification == :removed

        candidates = changed_nodes.select { |entry| cone.include?(entry.symbol) }.map do |entry|
          value_node = entry.head_node || entry.base_node
          {
            file: entry.file, symbol: entry.symbol,
            value_raw: value_node.branches,
            value_log2: valid_branches?(value_node) ? Math.log2(value_node.branches) : nil,
            delta_log2: entry.delta_log2,
            coupling_flip: false
          }
        end

        candidates += coupling_flip_candidates(cone)
        ranked = candidates.sort_by do |c|
          [-(c[:delta_log2] || 0.0).abs, c[:file].to_s, c[:symbol].to_s]
        end
        [ranked.first(5), [ranked.size - 5, 0].max]
      end

      # Payload-unchanged, edge-set-changed cone members (the resolution-flip
      # signal).
      def coupling_flip_candidates(cone)
        cone.sort.filter_map do |symbol|
          base_node = @base.graph.node_by_symbol[symbol]
          head_node = @head.graph.node_by_symbol[symbol]
          next if base_node.nil? || head_node.nil?
          next unless same_payload?(base_node, head_node)
          next if @base.out_edges(symbol) == @head.out_edges(symbol)

          {
            file: head_node.file, symbol: symbol,
            value_raw: head_node.branches,
            value_log2: valid_branches?(head_node) ? Math.log2(head_node.branches) : nil,
            delta_log2: nil,
            coupling_flip: true
          }
        end
      end

      def cone_symbols(graph, ep_symbol)
        comp = graph.comp_of[ep_symbol]
        return [] if comp.nil?

        graph.reachable_comps(comp).flat_map do |c|
          graph.components[c].select { |s| graph.node_by_symbol.key?(s) }
        end
      end

      # ---- review surface helpers ----------------------------------------------

      # Changed nodes = ALL materialized node entries (payload/NEW/REMOVED/
      # attr transitions — edge-only ripple produces no entry by construction).
      def changed_nodes
        entries
      end

      # [[ [file, ep_symbol], side_branching_log2 ], …] for eps whose
      # reflexive cone contains the symbol on the given graph.
      def eps_reaching(graph, symbol)
        node_comp = graph.comp_of[symbol]
        return [] if node_comp.nil?

        graph.ep_metrics.filter_map do |ep_key, row|
          ep_comp = graph.comp_of[ep_key.last]
          [ep_key, row.branching_log2] if graph.reachable_comps(ep_comp).include?(node_comp)
        end
      end

      # Files ALL of whose base∪head nodes have blast 0 on their respective
      # sides (the template.rb case — cones never see the touch).
      def orphan_touched_files
        touched_files.sort.select do |file|
          base_ok = @base.nodes.select { |n| n.file == file }
                         .all? { |n| eps_reaching(@base.graph, n.symbol).empty? }
          head_ok = @head.nodes.select { |n| n.file == file }
                         .all? { |n| eps_reaching(@head.graph, n.symbol).empty? }
          base_ok && head_ok
        end
      end

      # Matched eps NOT in U_metric whose cone(base)∪cone(head) contains ≥1
      # changed node (U_node_cone \ U_metric — count only, never findings).
      def offsetting_zero_count
        in_u_metric = ep_entries.map { |e| [e.file, e.ep_symbol] }.to_set
        changed_symbols = changed_nodes.map(&:symbol).to_set

        ep_deltas.count do |key, meta|
          next false unless meta[:classification] == :matched
          next false if in_u_metric.include?(key)

          cone = Set.new(cone_symbols(@base.graph, key.last))
          cone.merge(cone_symbols(@head.graph, key.last))
          cone.intersect?(changed_symbols)
        end
      end
    end
  end
end
