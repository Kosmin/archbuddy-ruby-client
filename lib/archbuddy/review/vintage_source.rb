# frozen_string_literal: true

require "fileutils"
require_relative "../cache/collect_manifest"

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
    module VintageSource
      AGGREGATE = "archbuddy-findings.json"

      module_function

      # @return [[Vintage, {ref:, sha:, vintage:}]]
      # @raise [Review::VintageError] with the pinned message per failing step
      def base(target:, scratch:, base_ref: nil, base_cache: nil)
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
        if Git.cache_committed_at?(root, base_sha, prefix)
          committed_base(root, base_sha, prefix, ref, scratch)
        else
          stateless_base(root, base_sha, prefix, ref, scratch)
        end
      end

      # @return [[Vintage, {sha:, vintage:, dirty:}]]
      def head(target:, scratch:, trust_cache: false)
        target = File.expand_path(target)
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
        wt = Git.worktree_add(root, base_sha)
        raise VintageError, "error: cannot create a worktree at #{base_sha[0, 7]}" if wt.nil?

        write_root = File.join(scratch, "base")
        begin
          source_root = prefix.to_s.empty? ? wt : File.join(wt, prefix)
          Collector.collect(source_root: source_root, write_root: write_root)
        ensure
          Git.worktree_remove(root, wt)
        end
        vintage = FragmentWalk.read(write_root)
        note_empty_base(vintage)
        [vintage, { ref: ref, sha: base_sha, vintage: "stateless-collect" }]
      end

      # ---- head modes ---------------------------------------------------------

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
