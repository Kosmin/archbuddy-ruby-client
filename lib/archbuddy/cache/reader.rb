# frozen_string_literal: true

require "fileutils"
require "digest"

module Archbuddy
  module Cache
    # C2: the machine-local, GITIGNORED speed cache (`.archbuddy/.cache/`) that
    # holds per-file raw-parse blobs so an UNCHANGED file can be reused WITHOUT
    # re-parsing (the `.tsbuildinfo`/Turborepo model). This is re-derivable and
    # NEVER committed — it is purely an incremental-collect performance store.
    #
    # A cached blob is trusted for reuse ONLY when BOTH:
    #   1. the file's content hash matches (source unchanged), AND
    #   2. the blob's COLLECTOR_VERSION matches the current collector.
    # (2) is the C2 collector-version stamp: a blob written by an OLDER collector
    # is NOT reused even if the source is byte-identical (a tool upgrade may parse
    # or derive differently), so incremental output can never silently diverge
    # from a from-scratch collect. On any mismatch we force a re-parse.
    #
    # The blob stores the marshaled Prism AST (the exact parse output) keyed by
    # the mirrored source path, so reuse hands `assemble` the SAME parsed value a
    # re-parse would — byte-identical assembled graph (the C2 reuse==recompute
    # invariant).
    class Reader
      # Bump when the collector's parse/derivation behavior changes (e.g. a Prism
      # upgrade, a DefinitionPass/ResolutionPass change, or a Marshal-format shift)
      # so hash-matching blobs from an older collector are NOT reused. This is the
      # C2 collector-version stamp; it is folded into the reuse gate below AND
      # into the on-disk blob so a version bump invalidates every stale blob.
      # 2 = v0.12 CL-C (the DefinitionPass now derives outcome_classes/escapes
      # — the documented bump policy names a DefinitionPass change; blobs store
      # marshaled ASTs only, so this costs one forced re-parse per machine).
      # 3 = v0.13-usage (the ResolutionPass now derives a per-call-site usage
      # class and folds it into a per-edge histogram — the documented bump
      # policy names a ResolutionPass change). Same one-forced-re-parse cost as
      # the version-2 bump, and the same reasoning: "blobs store marshaled ASTs
      # that do not change" was considered AND REJECTED there, because the
      # reuse gate is about whether an older collector would DERIVE the same
      # output, not about whether the stored bytes moved. Without this bump a
      # hash-matching pre-usage blob is reused for an unchanged file and its
      # edges carry no histogram at all — which a consumer cannot distinguish
      # from an honest ABSENT, silently corrupting the very signal the
      # histogram exists to supply and presenting as an inflated unknown rate.
      COLLECTOR_VERSION = 3

      CACHE_SUBDIR = ".cache"

      def initialize(project_root: Dir.pwd, workspace_dir: Archbuddy::Collect::DEFAULT_WORKSPACE_DIR)
        @project_root = File.expand_path(project_root)
        @cache_root   = File.join(@project_root, workspace_dir, CACHE_SUBDIR)
      end

      # Return a reusable parsed AST for `rel_file` IFF a cached blob exists AND
      # its content hash matches `content_hash` AND its collector version matches.
      # nil otherwise (caller must re-parse). NEVER raises on a corrupt/legacy
      # blob — a load failure is treated as a miss (force re-parse), the
      # fail-safe direction.
      def reuse(rel_file, content_hash)
        path = blob_path(rel_file)
        return nil unless File.exist?(path)

        blob = Marshal.load(File.binread(path))
        return nil unless blob.is_a?(Hash)
        return nil unless blob[:collector_version] == COLLECTOR_VERSION
        return nil unless blob[:content_hash] == content_hash

        blob[:parsed_value]
      rescue StandardError
        nil # corrupt / incompatible blob → miss → re-parse (fail safe)
      end

      # Persist a freshly-parsed AST for reuse next run. Stamps the blob with the
      # content hash + the collector version.
      def store(rel_file, content_hash, parsed_value)
        path = blob_path(rel_file)
        FileUtils.mkdir_p(File.dirname(path))
        File.binwrite(path, Marshal.dump(
          collector_version: COLLECTOR_VERSION,
          content_hash:      content_hash,
          parsed_value:      parsed_value
        ))
      end

      private

      # Blob path: `.archbuddy/.cache/<sha1(rel_file)>.bin`. A hashed filename
      # keeps the path flat + filesystem-safe regardless of the source path shape.
      def blob_path(rel_file)
        File.join(@cache_root, "#{Digest::SHA1.hexdigest(rel_file)}.bin")
      end
    end
  end
end
