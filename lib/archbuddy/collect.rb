# frozen_string_literal: true

require_relative "collect/raw"
require_relative "collect/adapter"
require_relative "collect/config"
require_relative "collect/anonymizer"
require_relative "collect/emitter"
require_relative "collect/adapters/ruby_adapter"
require_relative "collect/registry"

module Archbuddy
  # The collector: static-AST capture of a codebase into the anonymized graph
  # contract plus the secret id-map.
  module Collect
    # The shared `.archbuddy/` workspace convention (relative to CWD), mirrored
    # by the engine: holds graph.yml + id-map.yml (collect) and findings.yml
    # (analyze). This is the flag-free default for `collect`/`report`.
    DEFAULT_WORKSPACE_DIR = ".archbuddy"
  end
end
