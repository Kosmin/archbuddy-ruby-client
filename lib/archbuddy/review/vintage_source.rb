# frozen_string_literal: true

require "fileutils"
require "architecture_auditor"
require_relative "../cache/collect_manifest"
require_relative "../cache"
require_relative "../engine_runner"

module Archbuddy
  module Review
    # The base/head vintage resolvers (L7/A2/A6/P6) — every mode, precedence,
    # message, and label pinned.
    #
    #   BASE precedence: injected > committed > stateless
    #   HEAD precedence: trust-cache > tracked+clean > manifest-fresh > re-collect
    #
    # NEVER a silent stale reuse (L7): every reuse path names its
    # justification on stderr. Worktrees are create/use/REMOVE (ensure-paired).
    # Non-git targets skip the tracked+clean check (repo_root nil) and fall
    # through manifest → re-collect.
    #
    # v0.16 T11 (Q6 escape hatch, D-C2): `analyze_sides: true` BYPASSES the
    # committed/reuse rungs on BOTH sides — each side is a scratch collect
    # + EngineRunner.analyze + Cache::Writer fold into the SAME scratch
    # (one stamp-semantics path, serializer v6 tested once; no second
    # id-map join — the id-map is born and dies in scratch, L6), then the
    # ordinary FragmentWalk.read picks up score stamps that are fresh BY
    # CONSTRUCTION (D-C3). Provenance label: "analyze-sides". A committed
    # cache has no graph.yml (gitignored), so analyze REQUIRES the scratch
    # collect — the committed/injected rungs cannot serve this mode.
    module VintageSource
      AGGREGATE = "archbuddy-findings.json"

      module_function

      # @return [[Vintage, {ref:, sha:, vintage:}]]
      # @raise [Review::VintageError] with the pinned message per failing step
      def base(target:, scratch:, base_ref: nil, base_cache: nil, analyze_sides: false)
        return injected_base(base_cache, base_ref) if base_cache

        root = Git.repo_root(target)
        if root.nil?
          raise VintageError,
                "error: '#{target}' is not inside a git repository; " \
                "pass --base-cache DIR or run inside a git checkout"
        end

        ref = base_ref || Git.default_base_ref(root)
        if ref.nil?
          raise VintageError,
                "error: cannot determine a default base ref (tried origin/main, " \
                "origin/master, main, master); pass BASE_REF explicitly"
        end

        ref_sha = Git.resolve_ref(root, ref)
        raise VintageError, "error: cannot resolve base ref '#{ref}'" if ref_sha.nil?

        base_sha = Git.merge_base(root, ref_sha)
        if base_sha.nil?
          raise VintageError,
                "error: no merge-base between '#{ref}' and HEAD — shallow clone? " \
                "fetch full history (fetch-depth: 0) or git fetch --unshallow"
        end

        prefix = Git.prefix(target)
        if analyze_sides
          analyzed_base(root, base_sha, prefix, ref, scratch)
        elsif Git.cache_committed_at?(root, base_sha, prefix)
          committed_base(root, base_sha, prefix, ref, scratch)
        else
          stateless_base(root, base_sha, prefix, ref, scratch)
        end
      end

      # @return [[Vintage, {sha:, vintage:, dirty:}]]
      def head(target:, scratch:, trust_cache: false, analyze_sides: false)
        target = File.expand_path(target)
        return analyzed_head(target, scratch) if analyze_sides

        aggregate = File.join(target, AGGREGATE)
        return trusted_head(target, aggregate) if trust_cache

        root = Git.repo_root(target)
        prefix = root ? Git.prefix(target) : nil

        if root && File.file?(aggregate) && tracked_and_clean?(root, prefix)
          warn "note: head vintage from committed working-tree cache (tracked + clean)"
          return [FragmentWalk.read(target), head_label(target, root, prefix, "working-tree-cache")]
        end

        if File.file?(aggregate) && Cache::CollectManifest.fresh?(project_root: target)
          warn "note: head vintage from working-tree cache (manifest-verified fresh)"
          return [FragmentWalk.read(target), head_label(target, root, prefix, "working-tree-cache")]
        end

        if File.file?(aggregate)
          warn "note: working-tree cache is not verifiably fresh — re-collecting head " \
               "(commit the cache and pair with 'archbuddy collect --check', or run " \
               "'archbuddy collect .' to refresh the manifest)"
        end
        write_root = File.join(scratch, "head")
        Collector.collect(source_root: target, write_root: write_root)
        [FragmentWalk.read(write_root), head_label(target, root, prefix, "fresh-collect")]
      end

      # ---- base modes ---------------------------------------------------------

      def injected_base(base_cache, base_ref)
        dir = File.expand_path(base_cache)
        unless File.file?(File.join(dir, AGGREGATE))
          raise VintageError,
                "error: --base-cache #{base_cache} does not contain archbuddy-findings.json"
        end

        vintage = FragmentWalk.read(dir)
        note_empty_base(vintage)
        [vintage, { ref: base_ref, sha: nil, vintage: "injected-dir" }]
      end

      def committed_base(root, base_sha, prefix, ref, scratch)
        warn "note: base vintage from committed cache at #{base_sha[0, 7]}"
        extracted = Git.extract_cache(root, base_sha, prefix, File.join(scratch, "base-cache"))
        if extracted.nil?
          raise VintageError, "error: cannot extract the committed cache at #{base_sha[0, 7]}"
        end

        vintage = FragmentWalk.read(extracted)
        note_empty_base(vintage)
        [vintage, { ref: ref, sha: base_sha, vintage: "committed-cache" }]
      end

      def stateless_base(root, base_sha, prefix, ref, scratch)
        warn "note: no committed archbuddy cache at #{base_sha[0, 7]} — " \
             "collecting base in a temporary worktree"
        write_root = collect_base_worktree(root, base_sha, prefix, scratch)
        vintage = FragmentWalk.read(write_root)
        note_empty_base(vintage)
        [vintage, { ref: ref, sha: base_sha, vintage: "stateless-collect" }]
      end

      # v0.16 T11 (Q6/D-C2): the --analyze-sides base — scratch worktree
      # collect (committed rung DELIBERATELY bypassed: no graph.yml rides a
      # committed cache) + engine analyze + writer fold. Fresh stamps by
      # construction.
      def analyzed_base(root, base_sha, prefix, ref, scratch)
        warn "note: --analyze-sides: collecting base at #{base_sha[0, 7]} in a " \
             "temporary worktree + engine analyze (fresh score stamps; " \
             "~4-10 s/side at ~2k nodes, ~98 s/side at 16k — R4/R1 measured)"
        write_root = collect_base_worktree(root, base_sha, prefix, scratch)
        analyze_scratch_side!(write_root, "base")
        vintage = FragmentWalk.read(write_root)
        note_empty_base(vintage)
        [vintage, { ref: ref, sha: base_sha, vintage: "analyze-sides" }]
      end

      # The ONE worktree-collect lifecycle owner (create/use/REMOVE,
      # ensure-paired) — shared by the stateless and analyze-sides base
      # rungs. @return [String] the scratch write_root holding the vintage.
      def collect_base_worktree(root, base_sha, prefix, scratch)
        wt = Git.worktree_add(root, base_sha)
        raise VintageError, "error: cannot create a worktree at #{base_sha[0, 7]}" if wt.nil?

        write_root = File.join(scratch, "base")
        begin
          source_root = prefix.to_s.empty? ? wt : File.join(wt, prefix)
          Collector.collect(source_root: source_root, write_root: write_root)
        ensure
          Git.worktree_remove(root, wt)
        end
        write_root
      end

      # ---- head modes ---------------------------------------------------------

      # v0.16 T11 (Q6/D-C2): the --analyze-sides head — fresh scratch collect
      # (trust/tracked/manifest reuse rungs DELIBERATELY bypassed) + engine
      # analyze + writer fold. Fresh stamps by construction.
      def analyzed_head(target, scratch)
        warn "note: --analyze-sides: collecting head + engine analyze " \
             "(fresh score stamps; ~4-10 s/side at ~2k nodes, " \
             "~98 s/side at 16k — R4/R1 measured)"
        write_root = File.join(scratch, "head")
        Collector.collect(source_root: target, write_root: write_root)
        analyze_scratch_side!(write_root, "head")
        root = Git.repo_root(target)
        prefix = root ? Git.prefix(target) : nil
        [FragmentWalk.read(write_root), head_label(target, root, prefix, "analyze-sides")]
      end

      # ---- analyze-sides transport (v0.16 T11, Q6/D-C2) ------------------------

      # Run the engine over one scratch side's opaque graph.yml, then fold
      # the fresh findings into the SAME scratch via Cache::Writer — the
      # cli/analyze.rb `rewrite_aggregate` pattern (D-C2): ONE stamp-semantics
      # path (serializer v6 tested once), no second id-map join — the id-map
      # is born and dies in scratch (L6). CLEAN-STDOUT: the engine
      # subprocess's stdout is routed to STDERR (`stdout: $stderr`) — in diff
      # context the rendered document is stdout's ONLY write. Engine failure
      # (absent from the bundle AND from PATH, or nonzero exit) maps to
      # VintageError — the diff CLI's exit-2 discipline, stdout EMPTY.
      def analyze_scratch_side!(write_root, side)
        workspace    = File.join(write_root, Archbuddy::Collect::DEFAULT_WORKSPACE_DIR)
        graph_yml    = File.join(workspace, "graph.yml")
        findings_yml = File.join(workspace, "findings.yml")
        begin
          EngineRunner.analyze(graph_yml, out: findings_yml, stdout: $stderr)
        rescue EngineRunner::EngineError
          raise VintageError,
                "error: --analyze-sides: engine `architecture-auditor analyze` failed on " \
                "the #{side} side — the flag requires the architecture_auditor engine " \
                "(bundle it or put `architecture-auditor` on PATH); drop --analyze-sides " \
                "to use the cached acquisition path"
        end

        serializer = ArchitectureAuditor::Contract::Serializer
        Cache::Writer.new(project_root: write_root).write(
          graph:    serializer.load(graph_yml),
          id_map:   serializer.load(File.join(workspace, "id-map.yml")),
          findings: serializer.load(findings_yml)
        )
      end

      def trusted_head(target, aggregate)
        unless File.file?(aggregate)
          raise VintageError,
                "error: --trust-cache given but no archbuddy-findings.json at #{target}"
        end

        warn "warning: --trust-cache: using the working-tree cache WITHOUT a freshness " \
             "check — findings may not reflect current sources"
        root = Git.repo_root(target)
        prefix = root ? Git.prefix(target) : nil
        [FragmentWalk.read(target), head_label(target, root, prefix, "trusted-cache")]
      end

      # P6 verbatim: aggregate tracked AND no porcelain line whose path
      # (either rename side) is the aggregate, under `<prefix>.archbuddy/`,
      # or a `*.rb` file under the prefix. Trust is delegated to the repo's
      # paired `collect --check` CI gate; over-strict filtering is the
      # pinned safe direction.
      def tracked_and_clean?(root, prefix)
        p = prefix.to_s.empty? ? "" : "#{prefix}/"
        return false unless Git.tracked?(root, "#{p}#{AGGREGATE}")

        lines = Git.status_porcelain(root, prefix.to_s.empty? ? "." : prefix)
        lines.none? do |line|
          porcelain_paths(line).any? do |path|
            path == "#{p}#{AGGREGATE}" ||
              path.start_with?("#{p}.archbuddy/") ||
              (path.start_with?(p) && path.end_with?(".rb"))
          end
        end
      end

      # Both rename sides of one porcelain line.
      def porcelain_paths(line)
        body = line[3..].to_s
        body.split(" -> ").map { |path| path.delete_prefix('"').delete_suffix('"') }
      end

      def head_label(_target, root, prefix, vintage)
        sha = root ? Git.resolve_ref(root, "HEAD") : nil
        dirty = root ? !Git.status_porcelain(root, prefix.to_s.empty? ? "." : prefix).empty? : false
        { sha: sha, vintage: vintage, dirty: dirty }
      end

      def note_empty_base(vintage)
        return unless vintage.empty?

        warn "note: base vintage is empty (0 nodes) — all head nodes count as NEW"
      end
    end
  end
end
