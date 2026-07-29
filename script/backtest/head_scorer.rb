# frozen_string_literal: true

require "open3"
require "fileutils"
require "json"

module Backtest
  # Score arbitrary SHAs of the probe repos COLLECT-ONLY (P8: fragments
  # suffice for every delta rule), caching committed-cache-shaped results
  # OUTSIDE the study workspace (L12/A6) under `<out>/head_scores/<sha>/`.
  #
  # Worktree posture (the sanctioned study-runner discipline): create → use →
  # REMOVE, verified per run; the worktree dir lives under `<out>/worktrees/`
  # (never inside the probe repo tree); probe repos receive ZERO writes beyond
  # git's own transient `.git/worktrees` metadata. The copy step is
  # POINTER-DRIVEN: the aggregate + exactly its pointed fragment files —
  # NEVER `id-map.yml`, `.cache/`, `graph.yml`, `findings.yml` (the id-map is
  # born and dies inside the disposable worktree).
  class HeadScorer
    Result = Data.define(:status, :dir, :reason, :log) do
      def ok?
        status == :ok
      end
    end

    CLIENT_ROOT = File.expand_path("../..", __dir__)

    # @param repos [Hash{String => Repos::Entry}]
    # @param out [String] output root (gitignored tmp/backtest by convention)
    def initialize(repos:, out:)
      @repos = repos
      @out = File.expand_path(out)
    end

    # @param repo_key [String] org/name
    # @param sha [String]
    # @return [Result]
    def score(repo_key, sha)
      cache_dir = File.join(@out, "head_scores", sha)
      return Result.new(status: :ok, dir: cache_dir, reason: :cached, log: nil) if cached?(cache_dir)

      entry = @repos.fetch(repo_key) do
        return Result.new(status: :skipped, dir: nil, reason: :unknown_repo, log: nil)
      end

      unless resolvable?(entry.path, sha)
        return Result.new(status: :skipped, dir: nil, reason: :unresolvable_sha, log: nil)
      end

      log_path = File.join(@out, "logs", "#{sha}.log")
      FileUtils.mkdir_p(File.dirname(log_path))

      worktree = File.join(@out, "worktrees", "wt-#{sha}")
      begin
        add_worktree(entry.path, worktree, sha)
        target = entry.target_in(worktree)
        unless collect(target, log_path)
          return Result.new(status: :skipped, dir: nil, reason: :collect_failed, log: log_path)
        end

        copy_pointer_driven(target, cache_dir)
        Result.new(status: :ok, dir: cache_dir, reason: :collected, log: log_path)
      ensure
        remove_worktree(entry.path, worktree)
      end
    end

    private

    # Resume check (idempotent): a parseable CURRENT-serializer (v6, the
    # v0.16 score wave) aggregate short-circuits with ZERO git commands; an
    # older-vintage cached dir re-scores (stale committed shape).
    def cached?(cache_dir)
      aggregate = File.join(cache_dir, "archbuddy-findings.json")
      return false unless File.file?(aggregate)

      JSON.parse(File.read(aggregate))["serializer_version"] == 6
    rescue JSON::ParserError, SystemCallError
      false
    end

    def resolvable?(clone, sha)
      _out, _err, status = Open3.capture3(
        "git", "-C", clone, "rev-parse", "--verify", "--quiet", "#{sha}^{commit}"
      )
      status.success?
    end

    def add_worktree(clone, worktree, sha)
      FileUtils.mkdir_p(File.dirname(worktree))
      _out, err, status = Open3.capture3(
        "git", "-C", clone, "worktree", "add", "--detach", worktree, sha
      )
      raise "worktree add failed for #{sha}: #{err}" unless status.success?
    end

    def remove_worktree(clone, worktree)
      return unless File.directory?(worktree)

      Open3.capture3("git", "-C", clone, "worktree", "remove", "--force", worktree)
      FileUtils.remove_entry(worktree) if File.directory?(worktree)
      Open3.capture3("git", "-C", clone, "worktree", "prune")
    end

    # Subprocess collect from the client repo (inherits the RBENV/engine env);
    # stdout+stderr captured to the log.
    def collect(target, log_path)
      out, status = Open3.capture2e(
        "bundle", "exec", "exe/archbuddy", "collect", target, chdir: CLIENT_ROOT
      )
      File.write(log_path, out)
      status.success?
    end

    # Copy the aggregate + EXACTLY its pointed fragment files into
    # `<dir>.partial`, renaming on success — never a partial cache dir.
    def copy_pointer_driven(target, cache_dir)
      partial = "#{cache_dir}.partial"
      FileUtils.rm_rf(partial)
      FileUtils.mkdir_p(partial)

      aggregate_path = File.join(target, "archbuddy-findings.json")
      aggregate = JSON.parse(File.read(aggregate_path))
      FileUtils.cp(aggregate_path, File.join(partial, "archbuddy-findings.json"))

      (aggregate["sources"] || {}).each_value do |pointer|
        rel = pointer["path"]
        next if rel.nil?

        abs = File.join(target, rel)
        fragment_files =
          if File.directory?(abs)
            Dir.glob(File.join(abs, "**", "*.json")).sort
          elsif File.file?(abs)
            [abs]
          else
            []
          end
        fragment_files.each do |src|
          dest = File.join(partial, src.delete_prefix("#{target}/"))
          FileUtils.mkdir_p(File.dirname(dest))
          FileUtils.cp(src, dest)
        end
      end

      FileUtils.rm_rf(cache_dir)
      File.rename(partial, cache_dir)
    end
  end
end
