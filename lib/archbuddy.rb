# frozen_string_literal: true

require "architecture_auditor"

require_relative "archbuddy/version"
require_relative "archbuddy/collect"

# archbuddy — the Ruby client for the architecture-auditor engine.
#
# The collector statically walks a Ruby codebase into a language-neutral call
# graph, then anonymizes it through a single trust boundary (the Anonymizer)
# into:
#   - graph.yml    — opaque, zero app semantics, safe to hand to the engine
#   - id-map.yml   — SECRET, local-only, gitignored: opaque id -> real symbol
module Archbuddy
  class Error < StandardError; end
end
