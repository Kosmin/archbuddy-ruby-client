# frozen_string_literal: true

require "rubygems"

# Regression guard for a real packaging bug: the html formatter reads a vendored,
# non-.rb Cytoscape.js asset at render time. The gemspec's `spec.files` glob was
# `lib/**/*.rb` only, which silently dropped the asset from the BUILT gem — so
# `gem install`ed copies raised Errno::ENOENT while `bundle exec` from the repo
# worked (the asset was present in the working tree). These specs assert the
# asset is packaged and that the formatter's path constant points at a real file.
RSpec.describe "gem packaging" do
  GEMSPEC_PATH = File.expand_path("../archbuddy.gemspec", __dir__)
  CYTOSCAPE_ASSET = "lib/archbuddy/report/assets/cytoscape.min.js"
  LICENSE_ASSET = "lib/archbuddy/report/assets/CYTOSCAPE_LICENSE"

  let(:spec) { Gem::Specification.load(GEMSPEC_PATH) }

  it "includes the vendored Cytoscape.js asset in the packaged files" do
    expect(spec.files).to include(CYTOSCAPE_ASSET)
  end

  it "includes the Cytoscape license in the packaged files" do
    expect(spec.files).to include(LICENSE_ASSET)
  end

  it "ships an html formatter asset path that points at an existing file" do
    require "archbuddy"
    require "archbuddy/report/formatters/html_formatter"
    path = Archbuddy::Report::Formatters::HtmlFormatter::CYTOSCAPE_PATH
    expect(File.file?(path)).to be(true)
  end

  # v0.15 P3-T13: the reviewer docs an installed gem should carry.
  it "includes the CI recipes doc in the packaged files" do
    expect(spec.files).to include("docs/CI_RECIPES.md")
  end

  it "includes the recalibration doc in the packaged files" do
    expect(spec.files).to include("docs/RECALIBRATION.md")
  end

  # Repo-only artifacts stay OUT of the gem: the backtest harness (env-gated
  # scripts) and its generated adoption document.
  it "excludes script/ and docs/BACKTEST.md from the packaged files" do
    expect(spec.files.grep(%r{\Ascript/})).to be_empty
    expect(spec.files).not_to include("docs/BACKTEST.md")
  end
end
