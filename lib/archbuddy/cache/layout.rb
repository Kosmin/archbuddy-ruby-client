# frozen_string_literal: true

module Archbuddy
  module Cache
    # The committed `.archbuddy/` layout (P7): path-mapping + adaptive-shard
    # decision for the detail tree.
    #
    # Committed shape (all REAL-name, de-anonymized at WRITE, line-free):
    #   archbuddy-findings.json                      ROOT compact aggregate
    #                                                (headline scores + the
    #                                                multiplexer_proxy list +
    #                                                POINTERS — payload NOT inlined)
    #   .archbuddy/<mirrored-source-path>.json       small file  -> ONE fragment JSON
    #   .archbuddy/<mirrored-source-path>/           large file  -> DIRECTORY,
    #     <ClassName>.json                             one file per class
    #     <ClassName>/<method>.json                    per-method when a class alone
    #                                                  is still >= the threshold
    #
    # GITIGNORED (never committed): .archbuddy/id-map.yml (SECRET), .archbuddy/.cache/
    # (machine-local speed cache), the opaque graph.yml/findings.yml, report.*.
    #
    # ADAPTIVE SHARDING (C4): the split is a PURE FUNCTION of the serialized
    # fragment size, so it is deterministic and reproducible for `--check`.
    # A source file whose serialized fragment is < SHARD_BYTES becomes a single
    # `<path>.json`; at/over the threshold it becomes a `<path>/` directory split
    # per class (then per method for a single class still over the threshold).
    module Layout
      # The committed root aggregate filename (repo-relative), lockfile-style
      # (package-lock.json / .rubocop_todo.yml). Real-name, readable in a fresh
      # clone with NO id-map.
      ROOT_AGGREGATE = "archbuddy-findings.json"

      # The committed detail-tree root (repo-relative).
      DETAIL_DIR = ".archbuddy"

      # GITIGNORED sub-paths under DETAIL_DIR (never committed).
      SECRET_ID_MAP = "#{DETAIL_DIR}/id-map.yml"
      SPEED_CACHE   = "#{DETAIL_DIR}/.cache"

      # Adaptive shard threshold: serialized fragment size at/over which a source
      # file's committed fragment splits into a per-class directory. 64 KiB —
      # small enough that a git textual diff stays surgical, large enough to
      # avoid over-sharding an ordinary multi-class file. A god-class file (nexus
      # has 1,323 files > 64 KiB) forces the split so diffs stay bounded even
      # inside it. Named constant → tunable; pure size function → deterministic.
      SHARD_BYTES = 64 * 1024

      # Shard modes recorded in the aggregate pointer so a reader knows the shape
      # without probing the filesystem.
      MODE_SINGLE     = "single"      # one <path>.json
      MODE_PER_CLASS  = "per_class"   # <path>/<ClassName>.json
      MODE_PER_METHOD = "per_method"  # <path>/<ClassName>/<method>.json

      module_function

      # The committed fragment path for a source file in SINGLE mode (relative to
      # the audited repo root): mirror the source path under DETAIL_DIR, suffix
      # `.json`. e.g. "app/models/user.rb" -> ".archbuddy/app/models/user.rb.json".
      def single_path(rel_file)
        File.join(DETAIL_DIR, "#{rel_file}.json")
      end

      # The committed directory for a source file in a SHARDED mode:
      # ".archbuddy/app/models/user.rb/".
      def shard_dir(rel_file)
        File.join(DETAIL_DIR, rel_file)
      end

      # Decide the shard mode from the SERIALIZED fragment bytes (pure function of
      # size). `serialized` is the canonical-JSON bytes of the whole-file fragment.
      # Under threshold -> single. At/over -> per_class (the writer further splits
      # a single class to per_method when that class alone is at/over threshold).
      def shard_mode_for(serialized_bytesize)
        serialized_bytesize >= SHARD_BYTES ? MODE_PER_CLASS : MODE_SINGLE
      end

      # True when a serialized chunk is at/over the threshold and must split
      # further (a per-class file that is itself a god-class → per-method).
      def over_threshold?(serialized_bytesize)
        serialized_bytesize >= SHARD_BYTES
      end
    end
  end
end
