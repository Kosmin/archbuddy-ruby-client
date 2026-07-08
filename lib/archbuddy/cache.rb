# frozen_string_literal: true

require_relative "cache/canonical_json"
require_relative "cache/layout"
require_relative "cache/writer"
require_relative "cache/reader"
require_relative "cache/detail_tree"
require_relative "cache/change_detector"
require_relative "cache/checker"

module Archbuddy
  # The committed, incrementally-updated `.archbuddy/` metadata cache (v0.8).
  #
  # Splits into a COMMITTED, real-name, line-free layer (root
  # `archbuddy-findings.json` aggregate + `.archbuddy/<mirrored-source>` detail
  # tree, de-anonymized at WRITE) and a GITIGNORED machine-local speed cache
  # (`.archbuddy/.cache/`, raw parse/hash blobs) + the SECRET `.archbuddy/id-map.yml`.
  module Cache
  end
end
