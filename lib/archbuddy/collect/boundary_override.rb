# frozen_string_literal: true

require "digest"
require "yaml"
require_relative "../config"
require_relative "../config/boundary_section"
require_relative "../cache/canonical_json"

module Archbuddy
  module Collect
    # THE PROJECT BOUNDARY OVERRIDE AT COLLECT TIME (configurator W4 / C11) —
    # discovery, validation, merge and failure policy, all four in one class.
    #
    # WHY THIS IS NOT A BRANCH IN `cli/collect.rb` (V-2). MEASURED PREMISE:
    # before this task `cli/collect.rb` mentioned `.archbuddy.yml` ZERO times
    # (the string appears elsewhere in `lib/`, so the count is a real absence and
    # not a broken grep). Reading, validating and merging a config document is
    # therefore a WHOLLY NEW responsibility for that command, not an extension of
    # one it already had — and `collect` is already the longest command in the
    # CLI. It gains ONE line: the argument that asks this class for a section.
    #
    # LOUD OR NOTHING. A malformed override FAILS THE RUN with the offending key
    # named. It never degrades to "ignore the file and carry on": the whole value
    # of a declared boundary is that it is declared, so a declaration the
    # collector silently dropped is strictly worse than no feature at all — the
    # emitted graph would look exactly like a correct one.
    #
    # MERGE = SECTION-LEVEL MERGE, LIST-LEVEL REPLACE. That is not a new rule; it
    # is the shipped `.archbuddy.yml` doctrine (`Config#shallow_merge`: "lists
    # REPLACE, never merge"). A granularity the project declares replaces the
    # profile's list for that granularity; a granularity it does not mention
    # keeps the profile's. Concatenating instead would make a project unable to
    # ever narrow an inherited rule.
    #
    # ONE OVERRIDE PER ROOT. Discovery is the `.archbuddy.yml` sitting AT THE
    # TARGET ROOT and nowhere else — no ancestor walk, no `--config` flag on
    # collect. That is the structural half of C10's L17 refusal: there is no way
    # to point one collect at a second boundary document, so "two instances at
    # one root" cannot be expressed here either.
    module BoundaryOverride
      # Raised when the override document exists but cannot be used. Every
      # message names the offending key or the parse fault; none of them is
      # recoverable by ignoring the file.
      class MalformedOverrideError < StandardError; end

      module_function

      # THE CLI's FAILURE POLICY, mirroring EnginePreflight#check! exactly: this
      # is a precondition, not a recoverable state. There is no useful collect to
      # attempt against a boundary the user declared and we could not read — the
      # emitted graph would be indistinguishable from a correct one.
      #
      # It lives HERE and not in `cli/collect.rb` for the reason the preflight
      # gives: the CLI's job is wiring, and it owns no part of this policy.
      #
      # @return [Hash, nil] the validated section; otherwise warns and exits 1.
      def load!(target_root)
        load(target_root)
      rescue MalformedOverrideError => e
        warn("error: #{e.message}")
        exit 1
      end

      # The project's boundary section for +target_root+, or nil when there is
      # no `.archbuddy.yml` or it declares no `boundary:` key.
      #
      # @param target_root [String]
      # @return [Hash, nil] frozen section
      # @raise [MalformedOverrideError]
      def load(target_root)
        path = document_path(target_root)
        return nil if path.nil?

        section = read(path)[Archbuddy::Config::BoundarySection::KEY]
        return nil if section.nil?

        errors = Archbuddy::Config::BoundarySection.errors(section)
        unless errors.empty?
          raise MalformedOverrideError,
                "#{path}: invalid boundary override\n  - #{errors.join("\n  - ")}"
        end

        deep_freeze(section)
      end

      # The merged section handed to the collector: the project's granularities
      # laid over the profile's own.
      #
      # `nil` in and `nil` out is LOAD-BEARING: `BoundaryRules` short-circuits on
      # a profile with NO boundary section, and that state must survive a run
      # with no override. "No section" and "a section with every list empty" are
      # never collapsed into one another.
      #
      # @param shipped [Hash, nil] the profile document's own boundary section
      # @param override [Hash, nil] the project's section (already validated)
      # @return [Hash, nil]
      def merge(shipped, override)
        return shipped if override.nil?
        return deep_freeze(override) if shipped.nil?

        deep_freeze(shipped.merge(override))
      end

      # THE CACHE-COLLISION GUARD (L17's second half). The collect manifest
      # stamps the VOCABULARY a cache was produced under, so that editing the
      # vocabulary and leaving the sources untouched reads STALE rather than
      # serving a cache built under different rules. An override is vocabulary:
      # without this the shipped profile's digest would be identical for a run
      # with an override and a run without, and the two would collide silently in
      # the one `.archbuddy/` workspace the root has.
      #
      # ABSENT STAYS ABSENT: nil when there is no override, so a repo that never
      # writes a `boundary:` key produces a byte-identical manifest to today and
      # is not force-invalidated once.
      #
      # @return [String, nil] SHA-256 over the canonical section
      def stamp(target_root)
        section = load(target_root)
        return nil if section.nil?

        Digest::SHA256.hexdigest(Cache::CanonicalJson.dump(section))
      end

      # @api private — the ONE discovery rule (see "ONE OVERRIDE PER ROOT").
      def document_path(target_root)
        path = File.join(File.expand_path(target_root.to_s), Archbuddy::Config::FILENAME)
        File.file?(path) ? path : nil
      end

      # @api private
      #
      # The same hardened read the rest of the config surface uses (safe_load,
      # no permitted classes, no aliases). A parse fault is LOUD for the same
      # reason a schema fault is: a document the user believes declares a
      # boundary must never be silently absent from the run.
      def read(path)
        document = YAML.safe_load(File.read(path), permitted_classes: [], aliases: false)
        return {} if document.nil?
        return document if document.is_a?(Hash)

        raise MalformedOverrideError,
              "#{path}: config root must be a mapping (got #{document.class})"
      rescue Psych::Exception => e
        raise MalformedOverrideError, "#{path}: YAML parse error: #{e.message}"
      end

      # @api private
      def deep_freeze(value)
        case value
        when Hash  then value.each_value { |v| deep_freeze(v) }.freeze
        when Array then value.each { |v| deep_freeze(v) }.freeze
        else value.freeze
        end
      end
    end
  end
end
