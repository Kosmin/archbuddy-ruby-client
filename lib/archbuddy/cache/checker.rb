# frozen_string_literal: true

require "fileutils"
require_relative "layout"

module Archbuddy
  module Cache
    # R3-1: the CI STALENESS GATE (`collect --check`). Like a lockfile check or
    # `jest --ci`, it asserts the COMMITTED cache is up-to-date with the source:
    #
    #   1. RE-COLLECT from scratch (full re-hash of every file + regenerate the
    #      committed fragments + root aggregate, byte-for-byte via the same
    #      canonical Writer). A collect-only regenerate PRESERVES the committed
    #      scores + multiplexer_proxy block (Writer#preserve_existing_scores), so
    #      it re-derives exactly the STRUCTURAL layer a fresh `collect` would.
    #   2. `git diff --exit-code` over the COMMITTED paths (root aggregate + the
    #      `.archbuddy/<detail>` tree). Any drift → the committed cache is STALE.
    #
    # Exit contract (the caller `exit`s these):
    #   0  — clean: the regenerated committed cache matches what is committed.
    #   1  — DRIFT: the committed cache is stale (a `git diff` remained). The
    #        author must run `archbuddy collect` / `reset` + commit.
    #   2  — NO BASELINE: `.archbuddy/` (or the root aggregate) is absent. This is
    #        a LOUD failure, NEVER a vacuous pass — an audited repo that has not
    #        run collect must be told to, not silently green-lit.
    #
    # The check NEVER reads the SECRET id-map (the committed cache is real-name,
    # readable without it) — it only touches source + the committed cache + git.
    class Checker
      CLEAN       = 0
      DRIFT       = 1
      NO_BASELINE = 2

      def initialize(project_root: Dir.pwd, out: $stderr)
        @project_root = File.expand_path(project_root)
        @out          = out
      end

      # @param regenerate [#call] a zero-arg callable that regenerates the
      #   committed cache in place (a full `collect` + de-anon-at-write). Injected
      #   so the checker owns ONLY the baseline + diff policy, not the collect
      #   pipeline (separation of concerns).
      # @return [Integer] one of CLEAN / DRIFT / NO_BASELINE
      def check(&regenerate)
        return no_baseline unless baseline?

        regenerate.call

        if committed_cache_dirty?
          drift
        else
          clean
        end
      end

      private

      # A baseline exists iff the committed root aggregate is present. Without it
      # there is nothing to diff against — a fresh repo that never ran collect.
      def baseline?
        File.exist?(File.join(@project_root, Layout::ROOT_AGGREGATE))
      end

      # `git diff --exit-code` limited to the COMMITTED cache paths (root
      # aggregate + the .archbuddy/ detail tree). We EXCLUDE the gitignored
      # secret/speed paths defensively via pathspec so a stray untracked .cache/
      # blob never trips the gate. Returns true when git reports a diff (stale).
      #
      # Uses `git diff` (working tree vs index/HEAD) so it catches a regenerate
      # that changed a tracked committed file. Untracked NEW committed files
      # (e.g. a brand-new source file's fragment that was never committed) are
      # caught via `git status --porcelain` on the same pathspec.
      def committed_cache_dirty?
        pathspec = [
          Layout::ROOT_AGGREGATE,
          Layout::DETAIL_DIR,
          ":(exclude)#{Layout::SECRET_ID_MAP}",
          ":(exclude)#{Layout::SPEED_CACHE}/**"
        ]
        # Tracked-file modifications:
        tracked_diff = !run_git("diff", "--quiet", "--", *pathspec)
        # Untracked / staged additions or deletions on the committed paths:
        status = run_git_capture("status", "--porcelain", "--", *pathspec)
        untracked_or_staged = !status.to_s.strip.empty?

        tracked_diff || untracked_or_staged
      end

      # Run a git command; true on exit 0.
      def run_git(*args)
        system("git", "-C", @project_root, *args, out: File::NULL, err: File::NULL)
      end

      def run_git_capture(*args)
        IO.popen(["git", "-C", @project_root, *args], err: File::NULL, &:read)
      rescue StandardError
        nil
      end

      def no_baseline
        @out.puts "error: no committed archbuddy cache found (#{Layout::ROOT_AGGREGATE} is absent). " \
                  "This repo has no baseline to check against — run `archbuddy reset .` " \
                  "(first run) or `archbuddy collect .` + commit the result first."
        NO_BASELINE
      end

      def drift
        @out.puts "error: the committed archbuddy cache is STALE — regenerating it produced a diff. " \
                  "Run `archbuddy collect .` (or `archbuddy reset .`) and COMMIT the updated " \
                  "#{Layout::ROOT_AGGREGATE} + .archbuddy/ tree, then re-run the check."
        DRIFT
      end

      def clean
        @out.puts "archbuddy cache is up-to-date (no drift)."
        CLEAN
      end
    end
  end
end
