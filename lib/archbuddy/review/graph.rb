# frozen_string_literal: true

module Archbuddy
  module Review
    # The per-entrypoint fold row (I-C3'). Non-variety members are computed by
    # Graph#ep_metrics in ONE pass over the memoized reflexive reach; the
    # variety members (vty_log, vty_floor_log, dividend, dividend_log2,
    # top_dividend_nodes) stay nil until the variety-fold replica (P2-N1)
    # fills them — the staged shape equals the arity-N/A-gate shape (Q8).
    #
    # BOTH log vocabularies ship on this one Data class (G8): natural-log
    # members (`vty_log`/`vty_floor_log` — the Q1 fold truth) plus derived
    # nil-safe log2 readers for components/leaderboard consumers.
    EpMetrics = Data.define(
      :branching_log2,     # Float — Σ log2 b_own over cone app nodes (== subtree memo)
      :mass,               # Int — Σ out-edge calls over cone app nodes (G9 client definition)
      :reach,              # Int — reflexive cone app-node count
      :files,              # Int — distinct fragment files over cone app nodes
      :depth,              # Int — hops-to-sink incl. the terminal external hop, floor 1
      :own_branches,       # Int
      :max_cone_node,      # {file:, symbol:, branches:, log2:} — worst cone node by own log2
      :vty_log,            # Float|nil — NATURAL-log variety fold (Q1); nil = arity N/A gate
      :vty_floor_log,      # Float|nil
      :dividend,           # Float|nil — exp(vty_log − vty_floor_log), published-capped 1e6
      :dividend_log2,      # Float|nil — raw, cap-immune (the todo/value channel)
      :escapes_in_cone,    # [{file:, symbol:}] sorted (file, symbol)
      :entrypoint_kind,    # String
      :top_nodes,          # ≤5 by own log2 desc, (file, symbol) asc tiebreak
      :top_dividend_nodes, # ≤5 by (log2 b_own − log2 min(b_own, arity)) gap desc (P2-N1)
      :cone_size           # Int (= reach)
    ) do
      def v_now_log2
        vty_log && vty_log / Math.log(2)
      end

      def v_floor_log2
        vty_floor_log && vty_floor_log / Math.log(2)
      end

      # The engine-published per-ep variety (cost_policy.rb:62-66 mirror):
      # exp(vty_log) capped at 1e6 when vty_log >= ln(1e6).
      def published_variety
        return nil if vty_log.nil?

        vty_log >= Math.log(1_000_000) ? 1_000_000.0 : Math.exp(vty_log)
      end

      def capped?
        !vty_log.nil? && vty_log >= Math.log(1_000_000)
      end
    end

    # Engine-exact client traversal (P2/P4, Q1 construction pins):
    #   * vertex space keyed by SYMBOL, first-def-wins by (file, symbol) sort
    #     (duplicate-symbol warning once per symbol)
    #   * EXTERNAL pseudo-vertices = edge endpoints absent from the node-symbol
    #     set (detection by absence, never name patterns); b = 1 (log 0),
    #     outcome_arity nil (lenient), escapes never true
    #   * adjacency groups the triple-deduped edges by (from, to) and SUMS calls
    #   * ITERATIVE Tarjan SCC → condensation DAG (Set successors, self-edges
    #     dropped — sibling arms are DISTINCT successor comps)
    #   * depth = longest hops-to-sink DP (sinks seed 0, +1 per hop, MAX
    #     combiner, floor 1 at publish; SCC members share one level; the
    #     terminal hop into an external sink COUNTS) — engine
    #     path_count.rb#forward_depth_dp / project_scorer.rb#forward_depth_block
    #   * subtree/reach/blast fold over APP nodes only (externals excluded from
    #     populations and weights — reachability_index.rb asymmetry); mass
    #     INCLUDES edges into externals (the out-weight is owned by the caller)
    #
    # Seed-relative mandate: the Graph NEVER interprets an empty entrypoint
    # seed set — zero eps ⇒ `subtree_log2_by_ep == {}`, `union_reach_count == 0`,
    # blast all 0, `ep_metrics == {}`, `unreachable_from_entrypoints` nil (Q8).
    # Callers (rules, formatters) render a loud no_match/note instead.
    #
    # Determinism (Q7): every fold/iteration order is pinned to sorted node
    # identity — bitwise-reproducible Σ folds (milli-log2 todo soundness).
    class Graph
      def initialize(nodes:, edges:)
        @input_nodes = nodes
        @input_edges = edges
      end

      # ---- vertex space -----------------------------------------------------

      # Winning app-node payload per symbol (first-def-wins by (file, symbol)).
      def node_by_symbol
        build!
        @node_by_symbol
      end

      def externals
        build!
        @externals
      end

      # ---- depth ------------------------------------------------------------

      # Hops-to-sink per vertex symbol (floor 1). SCC members share one level.
      def depth_by_symbol
        @depth_by_symbol ||= begin
          build!
          hops = depth_hops_by_comp
          @vertices.each_with_object({}) do |v, acc|
            acc[v] = [hops.fetch(@comp_of[v], 0), 1].max
          end
        end
      end

      # R8 sugar.
      def depth(symbol)
        depth_by_symbol[symbol] || 1
      end

      # ---- per-ep folds -----------------------------------------------------

      # Σ log2(b_own) over the reflexive forward reach (app nodes only), per
      # distinct ep SYMBOL. Zero eps ⇒ {}.
      def subtree_log2_by_ep
        subtree_fold[:by_ep_symbol]
      end

      def reach_count_by_ep
        subtree_fold[:reach_by_ep_symbol]
      end

      # App nodes reached from ≥1 entrypoint (reflexive). Zero eps ⇒ 0.
      def union_reach_count
        subtree_fold[:union_count]
      end

      # Per app-node symbol: # of ep nodes whose reflexive cone contains it.
      # Zero eps ⇒ all 0 (never "everything dead").
      def blast_by_symbol
        @blast_by_symbol ||= begin
          build!
          acc = Hash.new(0)
          ep_comp_seeds.each do |comp, seeds|
            reachable_comps(comp).each { |c| acc[c] += seeds }
          end
          app_symbols_sorted.each_with_object({}) do |sym, out|
            out[sym] = acc.fetch(@comp_of[sym], 0)
          end
        end
      end

      def max_blast
        blast_by_symbol.values.max || 0
      end

      # ---- v0.15 ep-fold surface (I-C3') -------------------------------------

      # Hash[[file, ep_symbol] → EpMetrics]. ONE per-ep pass over the memoized
      # reflexive reach; branching_log2 reads the SAME memo as
      # #subtree_log2_by_ep (Q9 one-computation). Zero eps ⇒ {}.
      def ep_metrics
        @ep_metrics ||= begin
          build!
          eps.each_with_object({}) do |ep, acc|
            acc[[ep.file, ep.symbol]] = ep_metrics_row(ep)
          end
        end
      end

      # {nodes:, share:, files:} of in-tree nodes outside every ep cone —
      # nil when the graph has zero eps (Q8: the fold NEVER interprets an
      # empty seed set as "everything is unreachable").
      def unreachable_from_entrypoints
        build!
        return nil if eps.empty?

        @unreachable_from_entrypoints ||= begin
          reached = union_reached_comps
          unreachable = app_symbols_sorted.reject { |s| reached.include?(@comp_of[s]) }
          total = app_symbols_sorted.size
          files_all = @node_by_symbol.values.map(&:file).uniq
          reachable_files = app_symbols_sorted
                            .select { |s| reached.include?(@comp_of[s]) }
                            .map { |s| @node_by_symbol[s].file }.uniq
          {
            nodes: unreachable.size,
            share: total.zero? ? 0.0 : unreachable.size.to_f / total,
            files: (files_all - reachable_files).size
          }
        end
      end

      # Entrypoint nodes (winning payloads), sorted (file, symbol).
      def eps
        build!
        @eps ||= @node_by_symbol.values.select(&:entrypoint)
                                .sort_by { |n| [n.file.to_s, n.symbol.to_s] }
      end

      # ---- condensation readers (P2-N1 consumes these) ----------------------

      # @return [Hash{Integer=>Array<String>}] comp index → member symbols
      def components
        build!
        @components
      end

      def comp_of
        build!
        @comp_of
      end

      def comp_succ
        build!
        @comp_succ
      end

      # Reflexive forward reach of a comp (memoized BFS over the condensation).
      def reachable_comps(comp)
        @reach_memo ||= {}
        @reach_memo[comp] ||= begin
          seen = { comp => true }
          queue = [comp]
          until queue.empty?
            c = queue.shift
            @comp_succ[c].each do |s|
              next if seen[s]

              seen[s] = true
              queue << s
            end
          end
          seen.keys.freeze
        end
      end

      # Grouped out-call weight per symbol (Σ calls incl. edges into externals).
      def out_weight(symbol)
        build!
        @out_weight.fetch(symbol, 0)
      end

      private

      # ---- build ------------------------------------------------------------

      def build!
        return if @built

        @built = true
        build_vertex_space
        build_adjacency
        run_tarjan
        build_condensation
      end

      def build_vertex_space
        @node_by_symbol = {}
        dup_warned = {}
        @input_nodes.sort_by { |n| [n.file.to_s, n.symbol.to_s] }.each do |node|
          sym = node.symbol
          if @node_by_symbol.key?(sym)
            unless dup_warned[sym]
              warn "warning: duplicate symbol '#{sym}' across files — graph uses #{@node_by_symbol[sym].file}"
              dup_warned[sym] = true
            end
            next
          end
          @node_by_symbol[sym] = node
        end
      end

      def build_adjacency
        app = @node_by_symbol
        grouped = Hash.new(0)
        endpoints = {}
        @input_edges.each do |e|
          from = e[:from] || e["from"]
          to = e[:to] || e["to"]
          calls = (e[:calls] || e["calls"]).to_i
          grouped[[from, to]] += calls
          endpoints[from] = true
          endpoints[to] = true
        end

        @externals = endpoints.keys.reject { |s| app.key?(s) }.sort.freeze
        @vertices = (app.keys + @externals).sort.freeze

        @adjacency = Hash.new { |h, k| h[k] = [] }
        @out_weight = Hash.new(0)
        grouped.keys.sort_by { |(f, t)| [f.to_s, t.to_s] }.each do |(from, to)|
          @adjacency[from] << to
          @out_weight[from] += grouped[[from, to]]
        end
        @adjacency.each_value(&:freeze)
      end

      EMPTY = [].freeze
      private_constant :EMPTY

      # Iterative Tarjan (cycles are REAL; recursion would blow the stack).
      def run_tarjan
        index = {}
        low = {}
        on_stack = {}
        stack = []
        sccs = []
        counter = 0

        @vertices.each do |root|
          next if index.key?(root)

          work = [[root, 0]]
          until work.empty?
            v, i = work.pop
            if i.zero?
              index[v] = low[v] = counter
              counter += 1
              stack << v
              on_stack[v] = true
            end

            recurse = false
            neighbors = @adjacency.fetch(v, EMPTY)
            while i < neighbors.length
              w = neighbors[i]
              i += 1
              if !index.key?(w)
                work << [v, i]
                work << [w, 0]
                recurse = true
                break
              elsif on_stack[w]
                low[v] = [low[v], index[w]].min
              end
            end
            next if recurse

            if low[v] == index[v]
              comp = []
              loop do
                w = stack.pop
                on_stack[w] = false
                comp << w
                break if w == v
              end
              sccs << comp.sort
            end
            low[work.last[0]] = [low[work.last[0]], low[v]].min unless work.empty?
          end
        end

        @sccs = sccs
      end

      # Mirrors the engine Condensation: succ = Set per comp, self-edges dropped.
      def build_condensation
        @comp_of = {}
        @components = {}
        @sccs.each_with_index do |members, idx|
          @components[idx] = members
          members.each { |s| @comp_of[s] = idx }
        end

        @comp_succ = Hash.new { |h, k| h[k] = ::Set.new }
        @vertices.each do |v|
          cv = @comp_of[v]
          @comp_succ[cv] # ensure present
          @adjacency.fetch(v, EMPTY).each do |w|
            cw = @comp_of[w]
            @comp_succ[cv] << cw unless cw == cv
          end
        end
      end

      # ---- depth DP ----------------------------------------------------------

      # Reverse walk (sinks first) accumulating hop counts: sink comps seed 0,
      # +1 per hop, MAX combiner (worst single downstream route).
      def depth_hops_by_comp
        @depth_hops_by_comp ||= begin
          hops = {}
          reverse_topo_comp_order.each do |c|
            succs = @comp_succ[c]
            hops[c] = succs.empty? ? 0 : 1 + succs.map { |s| hops.fetch(s, 0) }.max
          end
          hops
        end
      end

      def forward_topo_comp_order
        indegree = Hash.new(0)
        comp_ids = @components.keys
        comp_ids.each { |c| indegree[c] = 0 }
        @comp_succ.each_value { |succs| succs.each { |s| indegree[s] += 1 } }

        queue = comp_ids.select { |c| indegree[c].zero? }
        order = []
        until queue.empty?
          c = queue.shift
          order << c
          @comp_succ[c].sort.each do |nxt|
            indegree[nxt] -= 1
            queue << nxt if indegree[nxt].zero?
          end
        end
        order
      end

      def reverse_topo_comp_order
        forward_topo_comp_order.reverse
      end

      # ---- shared folds -----------------------------------------------------

      def app_symbols_sorted
        build!
        @app_symbols_sorted ||= @node_by_symbol.keys.sort.freeze
      end

      # log2 weight per comp over APP members only; nodes without usable branch
      # data contribute 0 (excluded from log2 math — the FragmentWalk warning).
      def comp_weight_log2
        @comp_weight_log2 ||= @components.transform_values do |members|
          members.sum do |sym|
            node = @node_by_symbol[sym]
            next 0.0 if node.nil? # external pseudo-vertex: log2(1) = 0

            valid_branches?(node) ? Math.log2(node.branches) : 0.0
          end
        end
      end

      def valid_branches?(node)
        node.branches.is_a?(Integer) && node.branches >= 1
      end

      # Distinct ep comps with the number of ep NODES seeding each.
      def ep_comp_seeds
        @ep_comp_seeds ||= eps.map { |ep| @comp_of[ep.symbol] }.tally
      end

      def union_reached_comps
        @union_reached_comps ||= begin
          reached = ::Set.new
          ep_comp_seeds.each_key { |comp| reached.merge(reachable_comps(comp)) }
          reached
        end
      end

      # THE one subtree fold (Q9 one-computation): per-ep Σ log2 + reach counts
      # + the union count, memoized together. #subtree_log2_by_ep and
      # #ep_metrics read the SAME result — spec-asserted via a fold-count spy.
      def subtree_fold
        @subtree_fold ||= compute_subtree_fold
      end

      def compute_subtree_fold
        build!
        by_ep = {}
        reach_by_ep = {}
        eps.each do |ep|
          comps = reachable_comps(@comp_of[ep.symbol])
          by_ep[ep.symbol] = comps.sum { |c| comp_weight_log2[c] }
          reach_by_ep[ep.symbol] = comps.sum { |c| app_member_count(c) }
        end
        union = union_reached_comps.sum { |c| app_member_count(c) }
        union = 0 if eps.empty?
        { by_ep_symbol: by_ep, reach_by_ep_symbol: reach_by_ep, union_count: union }
      end

      def app_member_count(comp)
        @app_member_count ||= {}
        @app_member_count[comp] ||= @components[comp].count { |s| @node_by_symbol.key?(s) }
      end

      # ---- the per-ep row ----------------------------------------------------

      def ep_metrics_row(ep)
        comps = reachable_comps(@comp_of[ep.symbol])
        cone = comps.flat_map { |c| @components[c].select { |s| @node_by_symbol.key?(s) } }
                    .map { |s| @node_by_symbol[s] }
                    .sort_by { |n| [n.file.to_s, n.symbol.to_s] }

        ranked = cone.select { |n| valid_branches?(n) }
                     .sort_by { |n| [-Math.log2(n.branches), n.file.to_s, n.symbol.to_s] }
        worst = ranked.first || ep

        EpMetrics.new(
          branching_log2: subtree_fold[:by_ep_symbol][ep.symbol],
          mass: cone.sum { |n| @out_weight.fetch(n.symbol, 0) },
          reach: cone.size,
          files: cone.map(&:file).uniq.size,
          depth: depth(ep.symbol),
          own_branches: ep.branches,
          max_cone_node: node_ref(worst),
          escapes_in_cone: cone.select { |n| n.escapes == true }
                               .map { |n| { file: n.file, symbol: n.symbol } },
          entrypoint_kind: ep.entrypoint_kind,
          top_nodes: ranked.first(5).map { |n| node_ref(n) },
          cone_size: cone.size,
          **variety_members(ep, cone)
        )
      end

      # ---- the client variety-fold replica (P2-N1, Q1) -----------------------

      LOG_CAP = Math.log(1_000_000)
      NATURAL_LOG2 = Math.log(2)

      # Per-ep variety members: nil under the HARD N/A GATE
      # (path_count.rb:332-336 — NO vertex carries outcome_arity ⇒ the fold
      # never runs; never all-fallback garbage).
      def variety_members(ep, cone)
        fold = variety_fold
        if fold[:vty].nil?
          return { vty_log: nil, vty_floor_log: nil, dividend: nil,
                   dividend_log2: nil, top_dividend_nodes: nil }
        end

        comp = @comp_of[ep.symbol]
        ep_vty_log = fold[:vty][comp]
        ep_floor_log = fold[:floor][comp]
        gap = ep_vty_log - ep_floor_log
        {
          vty_log: ep_vty_log,
          vty_floor_log: ep_floor_log,
          # exp(vty_log − vty_floor_log) capped at published_cap
          # (project_scorer.rb:664-672 mirror).
          dividend: gap >= LOG_CAP ? 1_000_000.0 : Math.exp(gap),
          # raw, cap-immune — the todo/value channel.
          dividend_log2: gap / NATURAL_LOG2,
          top_dividend_nodes: top_dividend_nodes(cone)
        }
      end

      # Cone app nodes ranked by the extraction gap
      # (log2 b_own − log2 min(b_own, arity)); nil-arity nodes rank by full
      # log2 b_own (extraction can't collapse them); tie (file, symbol) asc.
      def top_dividend_nodes(cone)
        cone.select { |n| valid_branches?(n) }
            .sort_by do |n|
              own_log2 = Math.log2(n.branches)
              gap = if n.outcome_arity.nil?
                      own_log2
                    else
                      own_log2 - Math.log2([n.branches, n.outcome_arity].min)
                    end
              [-gap, n.file.to_s, n.symbol.to_s]
            end
            .first(5)
            .map { |n| node_ref(n) }
      end

      # Fallback taint per ep symbol (spec-internal observable): nil under the
      # N/A gate; else true iff the ep's comp is tainted (path_count.rb:390-397).
      def variety_fallback?(ep_symbol)
        fold = variety_fold
        return nil if fold[:taint].nil?

        fold[:taint][@comp_of[ep_symbol]]
      end
      public :variety_fallback?

      NIL_VARIETY_FOLD = { vty: nil, floor: nil, taint: nil }.freeze
      private_constant :NIL_VARIETY_FOLD

      def variety_fold
        @variety_fold ||= begin
          build!
          if @node_by_symbol.values.none?(&:outcome_arity)
            NIL_VARIETY_FOLD
          else
            compute_variety_fold
          end
        end
      end

      # The engine variety DP replica (path_count.rb:331-397, natural-log
      # folds — log2 at display only, Q1):
      #   vty[C]   = b_log(C) + Σ_arms arm(S)
      #   floor[C] = floor_term(C) + Σ_arms arm(S)   (same arm substitution)
      #   arm(S)   = (esc[S] || fallback[S]) ? accumulated(S) : a_log(S)
      #   floor_term = (esc||fallback) ? full b_log : min(b_log, a_log)
      # Sink comps (out-degree 0) seed at their own term. Lambda locals are
      # named distinctly from method locals (the R2 closure-capture trap).
      def compute_variety_fold
        b_log = comp_b_log
        a_log = comp_a_log
        esc = comp_escape_flags
        arm = lambda do |arm_comp, arm_accumulated|
          esc[arm_comp] || a_log[arm_comp] == :fallback ? arm_accumulated : a_log[arm_comp]
        end

        order = reverse_topo_comp_order
        vty = {}
        order.each do |comp|
          vty[comp] = b_log[comp] +
                      @comp_succ[comp].sort.sum { |succ_comp| arm.call(succ_comp, vty[succ_comp]) }
        end

        floor_term = lambda do |term_comp|
          if esc[term_comp] || a_log[term_comp] == :fallback
            b_log[term_comp] # extraction cannot collapse an escape (path_count.rb:362-376)
          else
            [b_log[term_comp], a_log[term_comp]].min
          end
        end
        floor = {}
        order.each do |comp|
          floor[comp] = floor_term.call(comp) +
                        @comp_succ[comp].sort.sum { |succ_comp| arm.call(succ_comp, floor[succ_comp]) }
        end

        taint = {}
        order.each do |comp|
          taint[comp] = a_log[comp] == :fallback ||
                        @comp_succ[comp].any? do |succ_comp|
                          (esc[succ_comp] || a_log[succ_comp] == :fallback) && taint[succ_comp]
                        end
        end

        { vty: vty, floor: floor, taint: taint }
      end

      # Σ ln(branches) over members (externals + branch-less nodes contribute
      # ln(1) = 0).
      def comp_b_log
        @comp_b_log ||= @components.transform_values do |members|
          members.sum do |sym|
            node = @node_by_symbol[sym]
            node && valid_branches?(node) ? Math.log(node.branches) : 0.0
          end
        end
      end

      # A_log per comp (path_count.rb:270-297 mirror): arity stamped →
      # Σ ln(arity) (members SUM — the SCC approximation); nil-arity
      # function/endpoint member ⇒ whole comp :fallback; nil-arity
      # external/db_op (incl. pseudo-vertices) → lenient 0.0; arity < 1 →
      # loud raise (the load-bearing floor).
      def comp_a_log
        @comp_a_log ||= @components.transform_values do |members|
          fallback = members.any? do |sym|
            node = @node_by_symbol[sym]
            node && node.outcome_arity.nil? && %w[function endpoint].include?(node.kind)
          end
          if fallback
            :fallback
          else
            members.sum do |sym|
              node = @node_by_symbol[sym]
              next 0.0 if node.nil? # external pseudo-vertex — lenient a=1

              arity = node.outcome_arity
              next 0.0 if arity.nil? # non-function/endpoint kind — lenient

              if arity < 1
                raise VintageError,
                      "invalid outcome_arity #{arity} on #{node.file}: #{node.symbol}"
              end

              Math.log(arity)
            end
          end
        end
      end

      # true iff ANY member escapes (path_count.rb:302-306; the engine
      # consumes the stamped boolean blindly — never infers).
      def comp_escape_flags
        @comp_escape_flags ||= @components.transform_values do |members|
          members.any? do |sym|
            node = @node_by_symbol[sym]
            node && node.escapes == true
          end
        end
      end

      def node_ref(node)
        log2 = valid_branches?(node) ? Math.log2(node.branches) : 0.0
        { file: node.file, symbol: node.symbol, branches: node.branches, log2: log2 }
      end
    end
  end
end
