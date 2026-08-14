# frozen_string_literal: true

require "json"
require "fileutils"
require_relative "layout"
require_relative "reader"
require_relative "writer"
require_relative "change_detector"
require_relative "canonical_json"
require_relative "../collect"
require_relative "../collect/boundary_override"

module Archbuddy
  module Cache
    # The P6 exactness upgrade: a GITIGNORED per-machine manifest recording the
    # exact enumerated file set + per-file content hashes of the last collect,
    # enabling the <1 s exact head-freshness check + warm-run reuse.
    #
    # Lives under `.archbuddy/.cache/` (already in SECRET_EXCLUDE_PATHS and
    # gitignored by convention → ZERO C1 committed-diff impact; the committed
    # fragments themselves stay hash-free). mtime is NEVER consulted
    # (doctrine — ChangeDetector). Any mismatch reads STALE: a false-stale is
    # a wasted re-collect, never wrong data.
    module CollectManifest
      FILENAME = "collect-manifest.json"

      module_function

      def path(project_root)
        File.join(project_root, Layout::SPEED_CACHE, FILENAME)
      end

      # Write the manifest for the enumerated files (rel paths). Canonical
      # JSON, keys sorted, byte-deterministic. Versions are read from the
      # producing constants, never literals.
      # @param project_root [String]
      # @param files [Array<String>] enumerated rel_file paths
      def write(project_root:, files:)
        hashes = files.sort.each_with_object({}) do |rel, acc|
          abs = File.join(project_root, rel)
          next unless File.file?(abs)

          acc[rel] = ChangeDetector.content_hash(File.read(abs))
        end

        doc = {
          "collector_version" => Reader::COLLECTOR_VERSION,
          "serializer_version" => Writer::SERIALIZER_VERSION,
          "profile" => profile_stamp(project_root),
          "files" => hashes
        }

        target = path(project_root)
        FileUtils.mkdir_p(File.dirname(target))
        File.write(target, CanonicalJson.dump(doc))
        target
      end

      # Exact freshness: manifest exists AND both versions match AND the
      # CURRENT enumeration yields EXACTLY the manifest's key set AND every
      # content hash matches. Absent/unparseable/mismatched → false (silent,
      # safe — head resolution falls through to re-collect).
      # @param project_root [String]
      # @return [Boolean]
      def fresh?(project_root:)
        doc = read(project_root)
        return false if doc.nil?
        return false unless doc["collector_version"] == Reader::COLLECTOR_VERSION
        return false unless doc["serializer_version"] == Writer::SERIALIZER_VERSION
        # The PROFILE is a producer version too (configurator W2). Without this
        # line, editing the vocabulary and leaving the sources untouched serves
        # a stale cache under "manifest-verified fresh" — the .tsbuildinfo
        # failure mode. Compared as a WHOLE STAMP so a manifest with NO profile
        # key reads STALE: `doc.dig("profile","digest") == current_digest`
        # would compare nil to nil for both a legacy manifest and a broken
        # producer, i.e. fail open in exactly the direction that reintroduces
        # the bug.
        return false unless doc["profile"] == profile_stamp(project_root)

        recorded = doc["files"]
        return false unless recorded.is_a?(Hash)

        current = enumerate(project_root)
        return false if current.nil?
        return false unless current.map(&:last).sort == recorded.keys.sort

        current.all? do |abs, rel|
          ChangeDetector.content_hash(File.read(abs)) == recorded[rel]
        rescue SystemCallError, IOError
          false
        end
      end

      def read(project_root)
        target = path(project_root)
        return nil unless File.file?(target)

        JSON.parse(File.read(target))
      rescue JSON::ParserError, SystemCallError, IOError
        nil
      end

      # The identity of the vocabulary this collect ran against: the profile's
      # own declared id plus the SHA-256 of its shipped bytes, both read from
      # the producer (never recomputed, never retyped here).
      #
      # configurator W4 (C11) — THE CACHE-COLLISION GUARD. A project
      # `boundary:` override IS vocabulary: it changes the emitted bytes while
      # leaving the SHIPPED profile's digest untouched. Without this key, a run
      # with an override and a run without would produce the same stamp and
      # collide silently in the one `.archbuddy/` workspace a root has — the
      # exact `.tsbuildinfo` failure mode the profile key above was added to
      # close, one level up. The digest is BoundaryOverride's to compute; this
      # method only asks for it.
      #
      # ABSENT STAYS ABSENT: the key is omitted entirely when there is no
      # override, so a repo that never writes a `boundary:` key keeps producing
      # a byte-identical manifest and is not force-invalidated once.
      def profile_stamp(project_root)
        profile = Archbuddy::Collect::Adapters::Ruby::Profile.reference
        stamp   = { "id" => profile.id, "digest" => profile.digest }
        override = Archbuddy::Collect::BoundaryOverride.stamp(project_root)
        override.nil? ? stamp : stamp.merge("boundary_override" => override)
      end

      # The same default-config enumeration the collect pipeline uses.
      # @return [Array<Array(String, String)>, nil] [[abs, rel], …]; nil when
      #   the root no longer enumerates (stale by definition)
      def enumerate(project_root)
        config = Archbuddy::Collect::Config.new(language: "ruby")
        Archbuddy::Collect::Adapters::Ruby::FileEnumerator.new(project_root, config).files
      rescue Archbuddy::Collect::Adapters::Ruby::FileEnumerator::NoSourceError
        nil
      end
    end
  end
end
