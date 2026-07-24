# frozen_string_literal: true

require "open3"
require "tmpdir"
require "fileutils"

module Archbuddy
  module Review
    # The ONLY place `archbuddy diff` shells out to git. Every command runs as
    # an Open3 argv array (no shell interpolation). Callers own the pinned
    # error messages (VintageSource) — this layer returns nil/false on
    # failure, never raises for ordinary git negatives.
    module Git
      module_function

      # @return [String, nil] the repo toplevel containing target, nil outside git
      def repo_root(target)
        out, _err, status = Open3.capture3("git", "-C", target.to_s, "rev-parse", "--show-toplevel")
        status.success? ? out.strip : nil
      rescue SystemCallError
        nil
      end

      # Relative path of target from its repo root, "" when equal, forward
      # slashes (monorepo prefix — study mono vintages live at
      # services/merchant-api).
      def prefix(target)
        root = repo_root(target)
        return nil if root.nil?

        expanded = File.expand_path(target)
        return "" if expanded == root

        expanded.delete_prefix("#{root}/").tr("\\", "/")
      end

      # @return [String, nil] full sha of ref^{commit}, nil when unresolvable
      def resolve_ref(root, ref)
        out, _err, status = Open3.capture3(
          "git", "-C", root.to_s, "rev-parse", "--verify", "--quiet", "#{ref}^{commit}"
        )
        status.success? ? out.strip : nil
      end

      # First of origin/main, origin/master, main, master that resolves.
      def default_base_ref(root)
        %w[origin/main origin/master main master].find { |ref| resolve_ref(root, ref) }
      end

      # Merge-base of sha and HEAD (we always diff FROM the merge-base —
      # BASE_REF...HEAD triple-dot semantics, never two-dot).
      def merge_base(root, sha)
        out, _err, status = Open3.capture3("git", "-C", root.to_s, "merge-base", sha.to_s, "HEAD")
        status.success? ? out.strip : nil
      end

      # true iff the committed tree at sha carries the aggregate under prefix.
      def cache_committed_at?(root, sha, prefix)
        p = prefix.nil? || prefix.empty? ? "" : "#{prefix}/"
        _out, _err, status = Open3.capture3(
          "git", "-C", root.to_s, "cat-file", "-e", "#{sha}:#{p}archbuddy-findings.json"
        )
        status.success?
      end

      # Whole-tree archive extraction (the ONLY per-file-scaling-safe read —
      # measured 0.87–1.16 s at nexus scale; per-file `git show` ≈ 40 s, do
      # not regress to it). The `.archbuddy` pathspec joins only when the
      # committed tree carries it (a fragment-less committed aggregate must
      # not fail the archive). Returns the extracted dir (dest + prefix).
      def extract_cache(root, sha, prefix, dest)
        p = prefix.nil? || prefix.empty? ? "" : "#{prefix}/"
        pathspecs = ["#{p}archbuddy-findings.json"]
        if path_committed_at?(root, sha, "#{p}.archbuddy")
          pathspecs << "#{p}.archbuddy"
        end

        FileUtils.mkdir_p(dest)
        statuses = Open3.pipeline(
          ["git", "-C", root.to_s, "archive", sha.to_s, *pathspecs],
          ["tar", "-x", "-C", dest.to_s]
        )
        return nil unless statuses.all?(&:success?)

        File.join(dest, prefix.to_s)
      end

      # true iff any committed object exists at sha:<path> (dir or file).
      def path_committed_at?(root, sha, path)
        _out, _err, status = Open3.capture3(
          "git", "-C", root.to_s, "cat-file", "-e", "#{sha}:#{path}"
        )
        status.success?
      end

      # Detached worktree in a tmpdir. Callers MUST pair with #worktree_remove
      # via begin/ensure (create/use/REMOVE — the study-runner posture).
      # @return [String, nil] the worktree dir
      def worktree_add(root, sha)
        dir = Dir.mktmpdir("archbuddy-wt-")
        _out, _err, status = Open3.capture3(
          "git", "-C", root.to_s, "worktree", "add", "--detach", dir, sha.to_s
        )
        unless status.success?
          FileUtils.remove_entry(dir) if File.directory?(dir)
          return nil
        end
        dir
      end

      def worktree_remove(root, dir)
        return if dir.nil?

        _out, _err, status = Open3.capture3(
          "git", "-C", root.to_s, "worktree", "remove", "--force", dir.to_s
        )
        return if status.success? && !File.directory?(dir)

        FileUtils.remove_entry(dir) if File.directory?(dir)
        Open3.capture3("git", "-C", root.to_s, "worktree", "prune")
        nil
      end

      def tracked?(root, relpath)
        _out, _err, status = Open3.capture3(
          "git", "-C", root.to_s, "ls-files", "--error-unmatch", relpath.to_s
        )
        status.success?
      end

      # stdout lines of `git status --porcelain -- <pathspec>`.
      def status_porcelain(root, pathspec)
        out, _err, status = Open3.capture3(
          "git", "-C", root.to_s, "status", "--porcelain", "--", pathspec.to_s
        )
        status.success? ? out.lines.map(&:chomp) : []
      end
    end
  end
end
