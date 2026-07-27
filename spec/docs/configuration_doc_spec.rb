# frozen_string_literal: true

require "archbuddy"

# v0.15 P1-T9: the doc-vs-code drift guard — every rule name, every param
# key, and every RETIRED name in Config::Schema must appear in
# docs/CONFIGURATION.md; a missing key is an honest FAILURE, not a warning.
RSpec.describe "docs/CONFIGURATION.md drift guard" do
  CONFIGURATION_DOC = File.expand_path("../../docs/CONFIGURATION.md", __dir__)

  def doc
    @doc ||= File.read(CONFIGURATION_DOC, encoding: "UTF-8")
  end

  it "names all SEVEN rules" do
    Archbuddy::Config::Schema::RULES.each_key do |rule|
      expect(doc).to include(rule), "rule #{rule} missing from CONFIGURATION.md"
    end
  end

  it "names every parameter key of every rule" do
    Archbuddy::Config::Schema::RULES.each do |rule, spec|
      spec[:params].each_key do |param|
        expect(doc).to include(param), "#{rule}.#{param} missing from CONFIGURATION.md"
      end
    end
  end

  it "carries the full Retired rules region (all six names + guidance)" do
    expect(doc).to include("## Retired rules")
    Archbuddy::Config::Schema::RETIRED_RULES.each_key do |name|
      expect(doc).to include(name), "retired name #{name} missing"
    end
  end

  it "confines the six retired names to the Retired rules region" do
    region_start = doc.index("## Retired rules")
    region_end = doc.index("\n## ", region_start + 1) || doc.length
    stripped = doc[0...region_start] + doc[region_end..]
    Archbuddy::Config::Schema::RETIRED_RULES.each_key do |name|
      expect(stripped).not_to include(name),
                              "retired name #{name} escapes the Retired rules region"
    end
  end

  it "carries the pinned P3-N1 sentences (T12 drift-row literals)" do
    expect(doc).to include("p90")
    expect(doc).to include("9.0")
    expect(doc).to include("not reachable from any entrypoint")
    expect(doc).to include("no measured cost line")
    expect(doc).to include("floors")
    expect(doc).to include("measured on one Rails/Grape codebase lineage")
    expect(doc).to include("prices use cases and delivery cost, not function style")
      .or include("prices **use cases and delivery cost, not function style**")
  end

  it "documents the todo grammar (both shapes + milli-log2) and the [0] matcher note" do
    expect(doc).to include("value: 64")
    expect(doc).to include("max_cone_node_millilog2")
    expect(doc).to include("milli-log2")
    expect(doc).to include("exact string")
    expect(doc).to include("[0]")
  end
end
