# frozen_string_literal: true

require "set"

module Archbuddy
  class Config
    # Glob matching for `.archbuddy.yml` scopes.
    #
    # PATHS (`match?`): `File.fnmatch?(glob, path, File::FNM_PATHNAME |
    # File::FNM_EXTGLOB)` against TARGET-relative forward-slash fragment
    # paths verbatim (A6), with an exact-string fast path (Set) for glob-free
    # patterns (matters at todo scale).
    #
    # EP SYMBOLS (`match_symbol?`, I-P10 — THE single home for ep-symbol
    # matching: `exclude_entrypoints` AND ratchet `entrypoints:` budgets):
    # EXACT-STRING equality FIRST, then `File.fnmatch?(glob, ep_symbol,
    # File::FNM_EXTGLOB)` (no FNM_PATHNAME — symbols are not paths). The
    # order is CORRECTNESS, not speed: `[0]` parses as a character class, so
    # every grape symbol (`#VERB[n]`) would otherwise never self-match (F12).
    module PathMatcher
      PATH_FLAGS = File::FNM_PATHNAME | File::FNM_EXTGLOB
      SYMBOL_FLAGS = File::FNM_EXTGLOB
      GLOB_CHARS = /[*?\[\]{}]/

      module_function

      # @param globs [Array<String>]
      # @param path [String] target-relative forward-slash path
      def match?(globs, path)
        return false if globs.nil? || globs.empty?
        return false if path.nil? || path.empty?

        exact, patterns = split(globs)
        return true if exact.include?(path)

        patterns.any? { |g| File.fnmatch?(g, path, PATH_FLAGS) }
      end

      # @param globs [Array<String>]
      # @param ep_symbol [String]
      def match_symbol?(globs, ep_symbol)
        return false if globs.nil? || globs.empty?
        return false if ep_symbol.nil? || ep_symbol.empty?

        globs.include?(ep_symbol) ||
          globs.any? { |g| File.fnmatch?(g, ep_symbol, SYMBOL_FLAGS) }
      end

      # Split glob-free exact strings (Set membership) from real patterns.
      def split(globs)
        @split_cache ||= {}
        @split_cache[globs] ||= begin
          exact = Set.new
          patterns = []
          globs.each { |g| g =~ GLOB_CHARS ? patterns << g : exact << g }
          [exact, patterns.freeze].freeze
        end
      end
    end
  end
end
