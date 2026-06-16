# frozen_string_literal: true

source "https://rubygems.org"

gemspec

# D47/M2: the shared contract gem from the sibling engine repo.
#
# Distribution default = git source, so a FRESH clone (no sibling checkout)
# installs cleanly. Local dev keeps its ergonomics two ways:
#
#   1. ENV override (zero config) — point at any local checkout:
#        ARCHITECTURE_AUDITOR_PATH=../architecture-auditor bundle install
#      (an unset/blank value falls through to the git source).
#   2. Bundler local override (persistent, no env needed) — preferred for a
#      permanent sibling checkout:
#        bundle config set --local local.architecture_auditor ../architecture-auditor
#      Bundler then resolves the git gem from that path automatically.
#
# See README.md "Installing the engine dependency" and .claude/docs/cross-repo.md.
if (engine_path = ENV["ARCHITECTURE_AUDITOR_PATH"].to_s.strip) && !engine_path.empty?
  gem "architecture_auditor", path: engine_path
else
  gem "architecture_auditor",
      git:    "https://github.com/Kosmin/architecture-auditor.git",
      branch: "main"
end
