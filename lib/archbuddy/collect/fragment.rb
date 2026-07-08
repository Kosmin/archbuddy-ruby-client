# frozen_string_literal: true

module Archbuddy
  module Collect
    # The per-file CACHE UNIT of an incremental collect (v0.8, C1-1).
    #
    # `RubyAdapter#collect` used to be one whole-project pipeline whose ONLY
    # per-file step is the Prism parse; definitions, resolution, edge-building
    # and anonymization are cross-file (global). So the sound incremental unit
    # is a per-file fragment: the parsed AST for ONE source file plus the
    # content hash that authoritatively decides whether it changed.
    #
    # A Fragment is a pure function of one file's bytes:
    #   - rel_file:      repo-relative path (deterministic key + committed path)
    #   - content_hash:  SHA-256 of the exact bytes Prism parsed (the C2
    #                    change-detection trigger — authoritative, NOT mtime)
    #   - parsed_value:  the Prism AST root node for this file (transient — the
    #                    global assemble consumes it; NEVER serialized/committed)
    #
    # Definitions and raw call sites are DERIVED from `parsed_value` during
    # `assemble` (the DefinitionPass / RouteCatalogue / ResolutionPass run over
    # the fragments' parsed values into the shared SymbolTable + Accumulator).
    # Keeping the fragment AST-backed makes C1-1 a PURE BYTE-PARITY refactor:
    # `assemble(all fragments)` reconstructs the exact inputs the old whole-
    # project pipeline consumed, in the same deterministic (sorted) file order.
    #
    # C1 line-stability invariant: a Fragment carries NO line-derived field in
    # any COMMITTED value — `content_hash` is over source bytes (a pure line
    # move changes the bytes, so the hash MAY change, but the committed cache
    # VALUES the writer derives from a fragment omit line entirely; line stays
    # display-only in the gitignored id-map). See Cache::Writer / CanonicalJson.
    Fragment = Struct.new(:rel_file, :content_hash, :parsed_value, keyword_init: true)
  end
end
