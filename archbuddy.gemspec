# frozen_string_literal: true

require_relative "lib/archbuddy/version"

Gem::Specification.new do |spec|
  spec.name        = "archbuddy"
  spec.version     = Archbuddy::VERSION
  spec.authors     = ["Kosmin"]
  spec.summary     = "Ruby client for the architecture-auditor engine: static-AST collector + reporter."
  spec.description = <<~DESC
    archbuddy captures a language-neutral call graph from a Ruby codebase via a
    static prism AST pass, anonymizes it through a single trust boundary into an
    opaque graph.yml plus a SECRET local-only id-map.yml, and reconnects the
    engine's findings back to real symbols. The pluggable Adapter interface keeps
    Ruby as just one language seam.
  DESC
  spec.homepage = "https://github.com/Kosmin/archbuddy-ruby-client"
  spec.license  = "MIT"

  spec.required_ruby_version = ">= 3.2"

  spec.files = Dir[
    "lib/**/*.rb",
    # Vendored, non-.rb runtime assets the html formatter reads at render time
    # (see lib/archbuddy/report/formatters/html_formatter.rb). These MUST ship in
    # the gem or `gem install`ed copies raise Errno::ENOENT. A spec guards this.
    "lib/archbuddy/report/assets/cytoscape.min.js",
    "lib/archbuddy/report/assets/CYTOSCAPE_LICENSE",
    "exe/*",
    "README.md"
  ]
  spec.require_paths = ["lib"]
  spec.bindir        = "exe"
  spec.executables   = ["archbuddy"]

  # The shared contract (Ids, Serializer, Validator, bundled schemas) — D47.
  # Sourced via the Gemfile (git source by default; local override for dev).
  spec.add_dependency "architecture_auditor", "~> 0.2"
  spec.add_dependency "prism", "~> 1.0"
  spec.add_dependency "dry-cli", "~> 1.4"

  spec.add_development_dependency "rspec", "~> 3.13"
end
