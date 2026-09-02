# frozen_string_literal: true

require "prism"
require "digest"
require_relative "../adapter"
require_relative "../raw"
require_relative "../fragment"
require_relative "../../cache/change_detector"
require_relative "../../cache/reader"
require_relative "ruby/file_enumerator"
require_relative "ruby/symbol_table"
require_relative "ruby/definition_pass"
require_relative "ruby/resolution_pass"
require_relative "ruby/entrypoint_detector"
require_relative "ruby/probe_registry"
require_relative "ruby/root_seeder_registry"
require_relative "ruby/route_catalogue"
require_relative "ruby/arity_resolver"
require_relative "../../reflect"
require_relative "ruby/egress_role_aggregate"
require_relative "ruby/generated_nodes"
require_relative "ruby/unresolved_census"

module Archbuddy
  module Collect
    module Adapters
      # Orchestrates the Ruby static capture (K-6): enumerate .rb files, run
      # Pass 1 (definitions) across all files into a shared SymbolTable, then
      # Pass 2 (resolution) per file into a shared Accumulator, then assemble
      # neutral Raw* value objects (method nodes with class_id refs, synthesized
      # db_op nodes, and a SINGLE shared external sink) plus edges + entrypoints.
      #
      # No id minting happens here — that is the Anonymizer's sole job. Edges and
      # entrypoints reference nodes by their RawNode#real_key, computed once per
      # node so the wiring stays internally consistent.
      class RubyAdapter < Adapter
        # Real-space symbol for the shared GENERIC external sink (D24). Always
        # minted (back-compat: exactly one <external> node when no categorized
        # egress exists); every unresolved/uncategorized call points here.
        EXTERNAL_SINK_SYMBOL = "<external>"
        # The analysis boundary: tracking stopped here because the call could not be
        # resolved. NOT one of the proven-crossing words — it says the opposite.
        UNKNOWN_TERMINAL_KIND = "unknown"


        # v0.8 (C1-1/C2): the whole-project capture is a two-phase pipeline —
        # a PER-FILE fragment builder (`collect_file_fragment`, the only per-file
        # step, cacheable) + a GLOBAL `assemble` over all fragments (SymbolTable
        # merge, resolution, edges, entrypoints — inherently cross-file).
        #
        # `mode`:
        #   :full        (default) — parse every enumerated file (first run / reset)
        #   :incremental (C2)      — reuse an UNCHANGED file's parse from the
        #                            machine-local `.archbuddy/.cache/` (content-hash
        #                            + collector-version gated); re-parse only
        #                            changed files. `assemble` is UNCHANGED — it
        #                            consumes fragments regardless of origin, so the
        #                            incremental result == a full recompute for the
        #                            changed set (the C2 reuse==recompute invariant).
        #
        # An empty/fully-stale cache in :incremental mode degrades to a FULL parse
        # (every file misses the reuse gate) — NOT an empty graph.
        #
        # @param mode [Symbol] :full | :incremental
        # @param base_ref [String, nil] optional git base ref (fast-path pre-filter)
        # The boot-reflection table, or nil when reflection did not run.
        #
        # Loaded from `.archbuddy/reflection.json` under the project root (the
        # path the standalone probe writes to), or from an explicit
        # `reflection_path` in config. Memoised, and DELIBERATELY forgiving: a
        # missing or malformed manifest yields nil rather than raising, because
        # reflection ENRICHES the static graph and must never be able to fail a
        # collection that would otherwise succeed.
        def reflection_table
          load_reflection unless defined?(@reflection_table)
          @reflection_table
        end

        # The reconciled DSL forwarding facts, or nil when reflection did not
        # run. Loaded in the SAME pass as the method table because both are
        # derived from one manifest plus one macro scan, and that scan globs and
        # parses every `.rb` in the project — doing it twice would double the
        # cost of every collect to answer a second question about the same files.
        def reflection_forwarding
          load_reflection unless defined?(@reflection_forwarding)
          @reflection_forwarding
        end

        def load_reflection
          @reflection_table = nil
          @reflection_forwarding = nil

          path = (config.respond_to?(:reflection_path) && config.reflection_path) ||
                 File.join(root, ".archbuddy", "reflection.json")
          return unless File.file?(path)

          require "json"
          manifest = JSON.parse(File.read(path))
          return unless manifest.is_a?(Hash) && manifest["methods"].is_a?(Array)

          scan = Archbuddy::Reflect::MacroScan.scan_all(Dir.glob(File.join(root, "**", "*.rb")))
          @reflection_table = Archbuddy::Reflect::MethodTable.from_manifest(manifest, macro_calls: scan.macros)
          @reflection_forwarding = Archbuddy::Reflect::Forwarding.from(manifest, delegations: scan.delegations)
          s = @reflection_table.stats
          f = @reflection_forwarding.stats
          warn "note: reflection loaded — #{s[:methods]} methods, " \
               "#{s[:proven_crossings]} proven crossings, #{s[:relations]} relations, " \
               "#{f[:total]} forwarding facts (#{f[:conflicts]} conflicts)"
        rescue StandardError => e
          warn "note: reflection manifest at #{path} could not be used (#{e.class}); " \
               "continuing with static collection only"
          @reflection_table = nil
          @reflection_forwarding = nil
        end

        # Observed return types from `archbuddy trace`, or nil.
        #
        # nil is the NORMAL case and changes nothing: no trace has been run, so
        # R4.9 never fires and the graph is exactly what it was. Loaded with the
        # same forgiveness as the reflection manifest — a missing or corrupt file
        # must never fail a collection that would otherwise succeed.
        #
        # DELIBERATELY NOT MERGED into any other table. A trace is partial and
        # non-deterministic where the graph and the boot manifest are complete
        # and reproducible; keeping it a separate optional input is what stops
        # "no callers" from quietly coming to mean "not exercised".
        def traced_types
          return @traced_types if defined?(@traced_types)

          path = File.join(root, ".archbuddy", "receiver_types.json")
          types = Archbuddy::Reflect::ReceiverTypes.from_file(path)
          if types.empty?
            @traced_types = nil
          else
            s = types.stats
            warn "note: receiver trace loaded — #{s[:addresses_unambiguous]} of #{s[:addresses]} " \
                 "observed call addresses carry a single type (#{s[:ambiguous]} ambiguous, left unresolved)"
            @traced_types = types
          end
        end

        def collect(mode: :full, base_ref: nil)
          files = Ruby::FileEnumerator.new(root, config).files

          fragments =
            if mode == :incremental
              collect_incremental(files, base_ref: base_ref)
            else
              files.map { |abs, rel_file| collect_file_fragment(abs, rel_file) }
            end

          assemble(fragments)
        end

        # PER-FILE cache unit (C1-1). A pure function of ONE file's bytes: parse
        # it with Prism and capture the version-folded content hash (the C2 change
        # trigger). Reads NO cross-file state. `abs` is the absolute source path;
        # `rel_file` the repo-relative key. Returns a Collect::Fragment.
        #
        # `reader` (optional): when supplied, a hash-matching, version-matching
        # cached parse is REUSED verbatim instead of re-parsing; a fresh parse is
        # stored for next run. Same content_hash either way, so the fragment (and
        # thus the assembled graph) is byte-identical to a re-parse.
        def collect_file_fragment(abs, rel_file, reader: nil)
          source = File.read(abs)
          hash   = Cache::ChangeDetector.content_hash(source)

          parsed = reader&.reuse(rel_file, hash)
          if parsed.nil?
            parsed = Prism.parse(source).value
            reader&.store(rel_file, hash, parsed)
          end

          Fragment.new(rel_file: rel_file, content_hash: hash, parsed_value: parsed)
        end

        # GLOBAL assemble (C1-1). Runs the identical Pass-1 (definitions) + route
        # catalogue + Pass-2 (resolution) over the fragments' parsed ASTs — in
        # the fragments' given (deterministically-sorted) order — then builds the
        # neutral Raw* AdapterResult. Byte-identical to the old whole-project body
        # for the same fragment set (the C1-1 parity contract). `#collect`'s public
        # return type (AdapterResult) is unchanged so `cli/collect.rb` keeps working.
        def assemble(fragments)
          table = Ruby::SymbolTable.new(
            profile: Ruby::Profile.for(config.profile_id, boundary_override: config.boundary_override)
          )
          run_definition_pass(fragments, table)
          run_route_catalogue(fragments, table)   # W4: seed routed actions before entrypoints
          run_root_seeders(table, fragments, root) # v0.10 W1-B/W2-B: categorize ingress roots

          # v0.12 CL-B (L16 Layer 2): the tail-call/ivar-memo arity-inheritance
          # fixpoint runs in the same table-complete, PRE-Anonymizer window the
          # root seeders use (REF tokens carry real symbols — K-5 trust
          # boundary). {fq => Integer|nil}; threaded onto RawNodes in CL-C.
          arity_by_fq = Ruby::ArityResolver.new(table).resolve

          # MACRO-GENERATED METHODS JOIN THE TABLE BEFORE RESOLUTION, and the
          # position is the whole point. R3 answers a receiverless call by asking
          # `table.method?("#{enclosing}##{name}")`; if `delegate :merchant` never
          # reaches the table, every call to `merchant` falls through to the
          # unresolved sink no matter how much reflection knows. Minting the node
          # afterwards fixed the missing FUNCTION and left all 2,277 of its call
          # sites unresolved — measured, on a run that reported 880 new nodes and
          # not one new edge.
          #
          # AFTER the route catalogue, the root seeders and the arity resolver,
          # though. Each of those reads `table.methods`, and a generated method
          # is not a route target, not an ingress root, and has no parsed body to
          # infer an outcome arity from — so it must not be visible to them.
          minted = register_generated_methods!(table)

          acc = Ruby::Accumulator.new
          run_resolution_pass(fragments, table, acc)

          # v0.10 W1-A1: ONE categorized detection ({fq => category}, ordered,
          # first-match-wins precedence). The keys ARE the entrypoint set (the
          # detector's flat contract); the values are stamped onto the method
          # RawNodes as entrypoint_kind so the category rides the id-map (and
          # graph.yml once the engine schema declares the field).
          ep_categories = Ruby::EntrypointDetector.new(config).detect_categorized(table)

          # Build nodes first, indexing each by its fq symbol -> real_key so edges
          # and entrypoints reference the exact same keys.
          nodes      = []
          key_for_fq = {}

          # Generated methods are ordinary MethodEntries by now, so they get
          # their nodes here with everything else — no second minting path.
          add_method_nodes(table, nodes, key_for_fq, ep_categories, arity_by_fq)
          add_db_op_nodes(table, acc, nodes, key_for_fq)
          # configurator W3 (C7): the ONE delegation — per-sink role unanimity
          # and its suppression tally are decided entirely inside this class.
          egress_roles  = Ruby::EgressRoleAggregate.new(acc.calls)
          external_keys = add_external_sinks(nodes, acc, egress_roles)

          edges, unresolved, unresolved_names = build_edges(acc, key_for_fq, external_keys, nodes)
          edges.concat(generated_edges(minted, key_for_fq))
          stamp_unresolved!(nodes, unresolved)
          # AFTER the edges are final: the census asks whether a call's real
          # target would have had anything BELOW it, and out-degree is not known
          # until every edge exists.
          census = unresolved_census(table, key_for_fq, edges, unresolved_names)
          entrypoints = build_entrypoints(ep_categories.keys, key_for_fq)

          AdapterResult.new(
            nodes: nodes, edges: edges, entrypoints: entrypoints,
            # Honest about metaprogramming blind spots (D-intent): these call
            # sites were detected but produce no edges (we cannot statically
            # resolve their targets). Surfaced as a diagnostic count only —
            # never as graph content.
            diagnostics: {
              meta_sites_skipped: acc.meta_sites.length,
              # Per-probe-name tally of framework-probe-resolved call sites
              # (L5/P4). CLI/diagnostics-only — NEVER serialized into graph.yml.
              # {} when no probes are selected / none resolve a call.
              probe_edges: acc.probe_edges,
              # v0.10 W1-D coverage tuple producers (L21, Reconciliation 1):
              # meta_resolved = literal meta-dispatch sites the MetaSendProbe
              # rewrote to real edges; total_call_sites = every call site the
              # resolution pass recorded (the coverage denominator). Consumed
              # by the A1 aggregate writer in W3 — additive sibling keys
              # (egress_counts joins in W2-C, entrypoints in W1-A1).
              meta_resolved: acc.meta_resolved,
              total_call_sites: acc.total_call_sites,
              # v0.10 W2-C egress producer (L16, Reconciliation 1): per-category
              # external-edge tally { :http/:gem/:queue/:generic => count }.
              # {} when no external edges exist. Consumed by the A1 aggregate
              # writer in W3 (the single egress read path — the writer never
              # re-parses sink symbols).
              egress_counts: acc.egress_counts,
              # v0.12 CL-C (A9): the two arity/escape counters. CLI-only —
              # NEVER graph/serialized content (the per-reason escape_reasons
              # histogram is a v0.13 candidate, deliberately not shipped).
              # arity_unresolved = method entries whose final arity is nil
              # (field omitted everywhere — the L17 honest blind-spot count);
              # escaping_defs = defs the EscapeScanner flagged.
              arity_unresolved: arity_by_fq.values.count(&:nil?),
              escaping_defs: table.methods.values.count { |m| m.escapes },
              # configurator W3 (C7/C8): the two INERT-role honesty counters.
              # CLI/diagnostics-only — NEVER graph.yml content.
              # cco_role_suppressed  = per-target egress sinks whose merged call
              #   sites DISAGREED on the role, so the key was omitted rather
              #   than fabricated ({} when none did).
              # cco_role_unattachable = call sites whose role has no node to
              #   ride at all — today only the in-tree enqueue, which the
              #   DispatchProbe recovers as an edge ({} when none occurred).
              cco_role_suppressed: egress_roles.suppressed,
              cco_role_unattachable: acc.cco_role_unattachable,
              # configurator W4 (C13): WHY the unresolved call sites are
              # unresolved, split by receiver shape (self / literal_const /
              # local / ivar / chained / other). Same channel and print
              # discipline as the counters above — CLI/diagnostics only, NEVER
              # graph.yml. {} when nothing went unresolved.
              receiver_shape_counts: acc.receiver_shapes.counts,
              # How much of that unresolved population could have CHANGED a
              # score. Same channel and discipline as the counters above.
              # nil when nothing went unresolved.
              unresolved_census: census
            }
          )
        end

        private

        # C2 incremental build: reuse unchanged files' parses from the speed
        # cache, re-parse only changed files. The candidate set is (optionally)
        # narrowed by a git-diff fast path, but the content hash + collector
        # version in the Reader gate is AUTHORITATIVE — a file the fast path did
        # not flag but whose cache blob misses (hash/version mismatch, or no blob)
        # is still re-parsed via `collect_file_fragment`. Deleted files simply
        # never enumerate, so their fragments are dropped. The Reader stores every
        # fresh parse, so the NEXT run can reuse it.
        def collect_incremental(files, base_ref: nil)
          reader   = Cache::Reader.new(project_root: incremental_project_root)
          detector = Cache::ChangeDetector.new(project_root: incremental_project_root)

          enumerated  = files.map { |_abs, rel| rel }
          # Fast-path pre-filter is advisory: it may shrink which files we bother
          # to hash, but every enumerated file still gets a fragment (reused or
          # re-parsed) so `assemble` sees the WHOLE tree, never a partial graph.
          _candidates = detector.candidate_files(enumerated, base_ref: base_ref)

          files.map do |abs, rel_file|
            collect_file_fragment(abs, rel_file, reader: reader)
          end
        end

        # The audited project root for the machine-local `.cache/`. The adapter's
        # `root` may be a file or a dir; use its directory so `.archbuddy/.cache/`
        # anchors at the repo root the CLI runs in (CWD-relative, matching collect).
        def incremental_project_root
          File.directory?(root) ? root : File.dirname(root)
        end

        def run_definition_pass(fragments, table)
          fragments.each do |fragment|
            fragment.parsed_value.accept(Ruby::DefinitionPass.new(table, fragment.rel_file))
          end
        end

        # W4: Run the RouteCatalogue over every parsed file. The catalogue self-
        # selects (only acts on files containing routes.draw blocks) and seeds
        # (controller_fq, action) pairs into the SymbolTable only when the method
        # already exists there (L2 never-fabricate gate inside the catalogue).
        def run_route_catalogue(fragments, table)
          fragments.each do |fragment|
            fragment.parsed_value.accept(Ruby::RouteCatalogue.new(table, fragment.rel_file))
          end
        end

        # v0.10 W1-B/W2-B: run the config-selected root seeders ONCE over the
        # fully-built table (they walk table.classes — superclass chains,
        # mixins, methods — so they need Pass 1 + the route catalogue done,
        # not a per-fragment visit). Fragments are passed through for
        # AST-shaped seeders (middleware); `root` for disk-shaped evidence
        # (the script seeder's shebang read); table-walkers ignore both.
        # Empty selection (--root-types none) => [] => no-op.
        def run_root_seeders(table, fragments, root)
          Ruby::RootSeederRegistry.for(config).each do |seeder|
            seeder.seed(table, fragments: fragments, root: root)
          end
        end

        def run_resolution_pass(fragments, table, acc)
          # Build the config-selected probes ONCE (stateless; reused per file).
          # Empty in the seam wave (ProbeRegistry::PROBES == []) -> [] -> no-op.
          # `rel_file` (v0.10 W2-B) lets the pass recognize rake surfaces so
          # task-body calls resolve to edges (F5 mirror push).
          probes = Ruby::ProbeRegistry.for(config)
          fragments.each do |fragment|
            fragment.parsed_value.accept(
              Ruby::ResolutionPass.new(table, acc, probes: probes, rel_file: fragment.rel_file,
                                       reflection: reflection_table,
                                       traced_types: traced_types)
            )
          end
        end

        # `ep_categories` (v0.10 W1-A1): the detector's ordered {fq => category}
        # map. A method that IS a detected entrypoint gets its category (which
        # may be nil — honest "unknown"); a non-entrypoint stays nil.
        # `arity_by_fq` (v0.12 CL-C): the ArityResolver's {fq => Integer|nil}
        # map, threaded exactly like ep_categories. Only METHOD nodes are
        # stamped — db_op/external sinks never carry arity/escape fields (L17).
        def add_method_nodes(table, nodes, key_for_fq, ep_categories, arity_by_fq)
          table.methods.values.each do |m|
            class_ref = m.owner_fq && table.class_for(m.owner_fq)
            node = Raw::RawNode.new(
              rel_file:       m.rel_file,
              line:           m.line,
              symbol:         m.fq_symbol,
              kind:           endpoint?(table, m) ? "endpoint" : "function",
              class_rel_file: class_ref&.rel_file,
              class_line:     class_ref&.line,
              class_symbol:   class_ref&.fq_name,
              # Path-cost integers from the BranchCounter (P3+P9). db_op and
              # external sinks omit these and rely on the RawNode defaults (1/0).
              branches:       m.branches,
              decisions:      m.decisions,
              entrypoint_kind: ep_categories[m.fq_symbol],
              # v0.12 (L16/L17/L18): nil arity = unresolved (absent downstream,
              # never fabricated); escapes rides the MethodEntry flag.
              outcome_arity:  arity_by_fq[m.fq_symbol],
              escapes:        m.escapes
            )
            nodes << node
            key_for_fq[m.fq_symbol] = node.real_key
          end
        end

        # MACRO-GENERATED APPLICATION METHODS the parser could not see.
        #
        # `delegate :merchant, to: :purchase` puts a real method on the class and
        # nothing in the file for Prism to read, so the graph has been missing
        # those functions entirely — 888 of them on one service — and every call
        # to one resolved to nothing for want of a target.
        #
        # No branch counts are supplied: a forwarder has no control flow, and
        # RawNode's defaults (1 branch, 0 decisions) are exactly right. Anything
        # else would put invented cost into the score. `escapes` is false for the
        # same reason — a two-send body has no callable boundary to cross.
        #
        # `add_method` is first-wins, so this cannot displace a parsed `def`
        # even if reflection and the parser disagree about a name.
        #
        # @return [Array<GeneratedNodes::Minted>]
        def register_generated_methods!(table)
          minted = Ruby::GeneratedNodes.build(reflection: reflection_table,
                                              forwarding: reflection_forwarding,
                                              table: table)
          return minted if minted.empty?

          minted.each do |m|
            class_ref = table.class_for(m.owner)
            table.add_method(
              Ruby::SymbolTable::MethodEntry.new(
                fq_symbol: m.fq, owner_fq: m.owner, name: m.name,
                singleton: m.scope.to_s == "singleton",
                rel_file:  m.rel_file || class_ref&.rel_file,
                line:      m.line || class_ref&.line,
                endpoint:  false, escapes: false
              )
            )
          end
          warn "note: #{minted.length} macro-generated methods added to the symbol table " \
               "(#{minted.count { |m| m.forwards_to }} with a recovered forwarding edge)"
          minted
        end

        # HOW MUCH OF THE UNRESOLVED POPULATION COULD EVER HAVE MATTERED.
        #
        # Assembles the three plain inputs the census needs and hands them over.
        # Out-degree is read off the FINAL edge list rather than the accumulator,
        # because the question is what a target actually reaches once generated
        # forwarding edges are in — a forwarder with its edge is not a leaf.
        #
        # Reflection is OPTIONAL here, as everywhere: without it `outside_names`
        # is empty, which collapses the tight bound onto the loose one. That
        # reports a WIDER uncertainty, never a narrower one.
        def unresolved_census(table, key_for_fq, edges, names)
          return nil if names.empty?

          out = Hash.new(0)
          edges.each { |e| out[e.from_key] += 1 }
          degree = ->(fq) { out[key_for_fq[fq]] }

          Ruby::UnresolvedCensus.classify(
            names: names,
            leaf_by_name: Ruby::UnresolvedCensus.leaf_by_name(table.methods.values, degree),
            outside_names: reflection_table&.non_app_method_names || Set.new
          )
        end

        # The out-edge of a forwarder: `Order#merchant` calls `purchase`.
        #
        # ONE edge, not two. The generated body also sends `merchant` to whatever
        # `purchase` returned, but that receiver's type is the very thing we do
        # not know — so the second hop stays unrepresented rather than pointed at
        # a guess.
        def generated_edges(minted, key_for_fq)
          minted.filter_map do |m|
            from_key = key_for_fq[m.fq]
            to_key   = key_for_fq[m.forwards_to]
            next if from_key.nil? || to_key.nil? || from_key == to_key

            Raw::RawEdge.new(from_key: from_key, to_key: to_key, calls: 1)
          end
        end

        def add_db_op_nodes(table, acc, nodes, key_for_fq)
          acc.db_ops.each do |symbol, meta|
            class_ref = meta[:class_fq] && table.class_for(meta[:class_fq])
            # Anchor the synthesized db_op at its owning class def site so its id
            # is stable and the id-map points somewhere real.
            node = Raw::RawNode.new(
              rel_file:       class_ref&.rel_file,
              line:           class_ref&.line,
              symbol:         symbol,
              kind:           "db_op",
              class_rel_file: class_ref&.rel_file,
              class_line:     class_ref&.line,
              class_symbol:   class_ref&.fq_name,
              # L3 (v0.6): no sink_open — a db_op is a plain COST-1 terminal.
              # W3 (C6): the profile's INERT role for this node's ORM verb; nil
              # (an unroled verb, or a rev-1.0 profile) leaves the key ABSENT.
              cco_role:       meta[:cco_role]
            )
            nodes << node
            key_for_fq[symbol] = node.real_key
          end
        end

        # v0.11 E1 (L13): mint the GENERIC `<external>` sink always
        # (back-compat — a repo with no provable egress targets keeps exactly
        # one external node, byte-identical to the pre-E1 behavior) plus ONE
        # per-target sub-sink per DISTINCT [category, target] pair that
        # ACTUALLY appears in the recorded external edges (never fabricated —
        # a target exists only on literal-constant evidence, by probe
        # construction). Sink symbol: `<external:{category}:{const_fq}>`.
        # `terminal_kind` stays the CATEGORY word (never the target) — the
        # graph-side value keeps today's fixed vocab (the engine groups egress
        # cost by it); the target lives ONLY in the real-space symbol (id-map /
        # committed real-name cache, L13 SECRET — never graph.yml). Mint order
        # is the sorted `[category.to_s, target]` order: deterministic, a pure
        # function of the pair set, never discovery order. All sinks stay
        # kind:"external" (I6).
        # Returns { nil => generic_real_key, [category, target] => real_key }.
        def add_external_sinks(nodes, acc, egress_roles)
          keys = {}
          # NO GENERIC SINK (v0.13-locality). An unresolved call is an ABSENCE of
          # knowledge about a target, not a known terminal. Routing every one of
          # them to a single synthetic `<external>` node fabricated two things at
          # once: a convergence that does not exist (on a real service that one
          # node carried 4,527 in-edges — 38.7% of the whole graph, inflating
          # out-degree on 84% of functions and forward complexity by 19.4%), and
          # a BOUNDARY CROSSING that usually did not happen — the unresolved
          # population is dominated by self/chained receivers, i.e. IN-APP calls
          # the resolver missed, not calls that leave the app.
          # They are now counted as `unresolved_calls` on the CALLER instead, so
          # the fact survives without inventing a target or an exit.

          pairs = acc.calls.filter_map do |call|
            to = call[:to]
            next unless to[:type] == :external && to[:category] && to[:target]

            [to[:category], to[:target]]
          end.uniq.sort_by { |category, target| [category.to_s, target] }

          pairs.each do |category, target|
            node = Raw::RawNode.new(
              rel_file: nil, line: nil, symbol: external_sink_symbol(category, target),
              kind: "external", terminal_kind: category.to_s,
              # W3 (C7): the AGGREGATED role — nil when this sink's merged call
              # sites disagree (counted as a suppression) or declare nothing.
              cco_role: egress_roles.role_for(category, target)
            )
            nodes << node
            keys[[category, target]] = node.real_key
          end

          keys
        end

        # I3 canonical sink-symbol spelling (L13): `<external:{category}:{const_fq}>`.
        # One ANALYSIS-BOUNDARY sink per (caller, called-name). Distinct per
        # caller BY DESIGN so unrelated callers never converge on one node.
        # `terminal_kind` is "unknown": it IS a measurement boundary, and the word
        # says the channel was never established — as distinct from `exit`, which
        # asserts a crossing PROVEN by reflection.
        def mint_unknown_sink(nodes, from_key, name)
          return nil if nodes.nil?

          node = Raw::RawNode.new(
            rel_file: nil, line: nil,
            symbol: "<boundary:unknown:#{from_key}:#{name}>",
            kind: "external", terminal_kind: UNKNOWN_TERMINAL_KIND
          )
          nodes << node
          node.real_key
        end

        # Threads the per-caller unresolved count onto its node, so the
        # measurement can state its own COVERAGE rather than silently scoring a
        # graph with a hole in it.
        def stamp_unresolved!(nodes, unresolved)
          return if unresolved.empty?

          by_key = nodes.to_h { |n| [n.real_key, n] }
          unresolved.each do |key, count|
            node = by_key[key]
            node.unresolved_calls = count if node
          end
        end

        def external_sink_symbol(category, target)
          "<external:#{category}:#{target}>"
        end

        # Collapse duplicate (from,to) call pairs into one edge with calls >= 1.
        # `external_keys` (v0.11 E1): the [category, target]→real_key sink map
        # from add_external_sinks; an external edge routes to its pair's sink,
        # falling back to the generic sink for a nil/unminted pair (variable
        # receivers, base-tier R9 fallthrough).
        def build_edges(acc, key_for_fq, external_keys, nodes_ref = nil)
          counts = Hash.new(0)
          unresolved = Hash.new(0)
          # The called NAME of every unresolved site, one entry per SITE. The
          # per-caller counts above cannot answer "how much of this could have
          # mattered" because they have already discarded what was called.
          unresolved_names = []
          unknown_keys = {}

          acc.calls.each do |call|
            from_key = key_for_fq[call[:from_fq]]
            next if from_key.nil?

            to_key =
              case call[:to][:type]
              when :method   then key_for_fq[call[:to][:fq]]
              when :db_op    then key_for_fq[call[:to][:fq]]
              when :external then external_keys[[call[:to][:category], call[:to][:target]]]
              end

            # An external call with no minted sink is UNRESOLVED. It still gets a
            # BOUNDARY node — one PER CALLER+NAME, never a shared one.
            #
            # An exit is not a claim that execution leaves the application; it is
            # the point at which our tracking stops, and an unresolved call is
            # exactly that: the last node we can see. Discounting the unknown
            # subtree to cost 1 is the honest default for COMPLEXITY, and it
            # keeps the caller scoreable — omitting the node entirely left 863
            # nodes with no route to any sink, so their cost became undefined and
            # they fell out of the score, which is a measurement hole rather than
            # caution.
            #
            # The original generic sink's actual defect was being ONE SHARED node
            # (4,527 callers converging on a single target, inflating out-degree
            # and inventing convergence). Per caller+name has neither problem.
            if to_key.nil?
              if call[:to][:type] == :external
                unresolved[from_key] += 1
                unresolved_names << call[:to][:name].to_s
                to_key = unknown_keys[[from_key, call[:to][:name]]] ||=
                  mint_unknown_sink(nodes_ref, from_key, call[:to][:name])
              end
              next if to_key.nil?
            end

            counts[[from_key, to_key]] += 1
          end

          edges = counts.map do |(from_key, to_key), calls|
            Raw::RawEdge.new(from_key: from_key, to_key: to_key, calls: calls)
          end
          [edges, unresolved, unresolved_names]
        end

        # v0.10 W1-A1: consumes the fq list from the ONE categorized detection
        # in `assemble` (== the detector's flat #detect output) so detection
        # runs once. Return shape unchanged: Array<RawEntrypoint>.
        def build_entrypoints(entrypoint_fqs, key_for_fq)
          entrypoint_fqs.filter_map do |fq|
            key = key_for_fq[fq]
            key && Raw::RawEntrypoint.new(node_key: key)
          end
        end

        def endpoint?(table, method_entry)
          # A synthetic Grape endpoint handler block is an endpoint by
          # construction (F3); a controller action is an endpoint via the
          # existing controller-class check. Either makes kind:"endpoint".
          return true if method_entry.endpoint

          !method_entry.singleton &&
            method_entry.owner_fq &&
            table.controller_class?(method_entry.owner_fq)
        end
      end
    end
  end
end
