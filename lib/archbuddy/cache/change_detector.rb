# frozen_string_literal: true

require "digest"
require_relative "reader"

module Archbuddy
  module Cache
    # C2 change detection: decide which enumerated source files must be RE-PARSED
    # vs reused from the machine-local speed cache.
    #
    #   * AUTHORITATIVE trigger = per-file CONTENT HASH (SHA-256 of the exact
    #     bytes Prism parses, with the collector version folded in — C2 stamp).
    #     Correct under rebase/squash/clone/dirty-tree; independent of VCS state.
    #   * OPTIONAL fast-path pre-filter = `git diff --name-only <base>...HEAD` to
    #     shrink the candidate set in a PR/CI context. NEVER the source of truth
    #     (misses dirty edits, wrong across squash/rebase) — it only narrows which
    #     files we even bother to hash; the content hash still confirms.
    #   * mtime is NEVER consulted (false pos/neg — see the incrementality model).
    #
    # `content_hash(source)` FOLDS the collector version into the digest so a
    # collector/serializer upgrade changes every file's effective hash → forces a
    # full re-parse (the C2 collector-version guarantee, hash-side). The Reader's
    # blob also carries the raw version stamp as a second, independent guard.
    class ChangeDetector
      # The exact digest a fragment's content hash is compared against. Folds the
      # collector version in so a version bump invalidates every prior hash.
      def self.content_hash(source)
        Digest::SHA256.hexdigest("#{Reader::COLLECTOR_VERSION}\x00#{source}")
      end

      def initialize(project_root: Dir.pwd)
        @project_root = File.expand_path(project_root)
      end

      # The set of enumerated files to CONSIDER re-parsing (rel_file strings).
      # With a base ref + git available, narrow to the changed set ∩ enumerated;
      # otherwise consider ALL enumerated files (the safe default). This is a
      # PRE-FILTER only — the caller still confirms each candidate by content hash.
      #
      # @param enumerated [Array<String>] all enumerated rel_files (authoritative universe)
      # @param base_ref [String, nil] optional git base ref for the fast path
      # @return [Array<String>] the candidate rel_files to re-hash/re-parse
      def candidate_files(enumerated, base_ref: nil)
        return enumerated if base_ref.nil?

        changed = git_changed(base_ref)
        return enumerated if changed.nil? # git unavailable / bad ref → consider all

        enumerated & changed
      end

      private

      # `git diff --name-only <base>...HEAD`, repo-relative. nil when git is
      # unavailable, not a repo, or the ref does not resolve (→ caller falls back
      # to considering all files; the content hash remains authoritative).
      def git_changed(base_ref)
        out = `git -C #{shell_escape(@project_root)} diff --name-only #{shell_escape(base_ref)}...HEAD 2>/dev/null`
        return nil unless $?.success?

        out.split("\n").map(&:strip).reject(&:empty?)
      rescue StandardError
        nil
      end

      def shell_escape(str)
        "'#{str.gsub("'", "'\\\\''")}'"
      end
    end
  end
end
