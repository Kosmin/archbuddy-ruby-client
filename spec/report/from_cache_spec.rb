# frozen_string_literal: true

require "tmpdir"
require "fileutils"
require "stringio"
require "json"
require "archbuddy/cache"
require "archbuddy/cli/report"
require "archbuddy/report/reconnect"

# R2-1: `report` reads the COMMITTED, REAL-NAME root aggregate DIRECTLY, with NO
# id-map (the committed layer is de-anonymized at WRITE time, CR-1). This is the
# HARD INVARIANT: a fresh clone renders the multiplexer_proxy smell from the
# committed cache WITHOUT the SECRET id-map.
RSpec.describe "report reads the committed real-name cache (R2-1)" do
  let(:fixture_root) { File.expand_path("../fixtures/sample", __dir__) }
  let(:config)       { Archbuddy::Collect::Config.new(language: "ruby") }

  # Produce a REAL committed aggregate (via the write-time transcode) carrying a
  # multiplexer_proxy smell, exactly as `analyze` would.
  def write_committed_cache(dir)
    adapter = Archbuddy::Collect::Registry.for("ruby").new(fixture_root, config)
    a = Archbuddy::Collect::Anonymizer.new(adapter.collect, tool: "t", adapter: "ruby").call
    proxy_id, = a.id_map["ids"].find { |_id, d| d["symbol"] == "Billing::Invoice#total" }
    findings = {
      "scores" => {
        "forward_discoverability" => { "grade" => "C", "score" => 61.0 },
        "reverse_traceability"    => { "grade" => "B", "score" => 40.0 },
        "multiplexer_proxies"     => [{ "node" => proxy_id, "added_coupling" => 9.0 }]
      }
    }
    Archbuddy::Cache::Writer.new(project_root: dir).write(graph: a.graph, id_map: a.id_map, findings: findings)
  end

  describe "Reconnect.from_cache" do
    it "reads scores + the real-name smell from the aggregate with NO id-map" do
      Dir.mktmpdir do |dir|
        write_committed_cache(dir)
        agg = File.join(dir, "archbuddy-findings.json")

        result = Archbuddy::Report::Reconnect.from_cache(aggregate_path: agg, id_map_path: nil)

        expect(result.scores.map(&:key)).to eq(%w[reverse_traceability forward_discoverability])
        expect(result.multiplexer_proxies.map(&:symbol)).to eq(["Billing::Invoice#total"])
        expect(result.multiplexer_proxies.first.added_coupling).to eq(9.0)
      end
    end
  end

  describe "`archbuddy report` with no args in a fresh checkout (no id-map present)" do
    def capture_report(dir)
      out = StringIO.new
      orig = $stdout
      $stdout = out
      Dir.chdir(dir) { Archbuddy::CLI::Report.new.call(format: "terminal") }
      out.string
    ensure
      $stdout = orig
    end

    it "renders the multiplexer_proxy smell from the committed cache — no id-map on disk" do
      Dir.mktmpdir do |dir|
        write_committed_cache(dir)
        # SIMULATE A FRESH CLONE: the SECRET id-map is gitignored, so it is NOT
        # present. Only the committed real-name cache exists.
        expect(File).not_to exist(File.join(dir, ".archbuddy/id-map.yml"))

        output = capture_report(dir)
        expect(output).to include("Multiplexer Proxy Smell")
        expect(output).to include("Billing::Invoice#total")
        expect(output).to include("added_coupling=9")
        # scores headline is present too
        expect(output).to include("Architecture Scores")
      end
    end
  end
end
