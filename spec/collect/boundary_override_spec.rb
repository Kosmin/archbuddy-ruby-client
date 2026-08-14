# frozen_string_literal: true

require "fileutils"
require "stringio"
require "tmpdir"
require "yaml"
require "archbuddy/cli/collect"
require "archbuddy/collect/boundary_override"

# configurator W4 (C11) — `collect` loads and merges the project override,
# LOUDLY.
#
# Two things have to be true and they are independent, so both are proved
# separately: (1) a malformed override FAILS THE RUN naming the offending key,
# and (2) a well-formed one actually reaches the resolver's R1.5 tier and moves
# the emitted bytes. A feature that validates beautifully and changes nothing
# would pass half of this file.
RSpec.describe Archbuddy::Collect::BoundaryOverride do
  # A corpus with ONE in-tree call whose target a boundary can claim. Kept tiny
  # so the with/without diff is readable rather than merely non-empty.
  # DEFINED AS METHODS, NOT CONSTANTS. A constant assigned inside an
  # `RSpec.describe` block is assigned at the TOP-LEVEL lexical scope, i.e. on
  # Object — so a fixture named `CORPUS` here silently overwrites any other
  # spec file's `CORPUS`. (Measured, not theorised: the first draft of this file
  # broke spec/backtest/corpus_spec.rb under a random seed by doing exactly that.)
  def corpus
    {
      "app/clients/gateway.rb" => <<~RUBY,
        module Payments
          class Gateway
            def charge(amount)
              amount
            end
          end
        end
      RUBY
      "app/services/checkout.rb" => <<~RUBY
        class Checkout
          def call
            Payments::Gateway.new.charge(1)
          end
        end
      RUBY
    }
  end

  def declared
    {
      "version" => 1,
      "boundary" => {
        "calls" => [{ "receiver" => { "kind" => "constant_exact",
                                      "values" => ["Payments::Gateway"] },
                      "verbs" => ["charge"], "category" => "http", "role" => "action" }]
      }
    }
  end

  def with_corpus(config: nil)
    Dir.mktmpdir("archbuddy-c11") do |dir|
      corpus.each do |rel, source|
        abs = File.join(dir, rel)
        FileUtils.mkdir_p(File.dirname(abs))
        File.write(abs, source)
      end
      File.write(File.join(dir, ".archbuddy.yml"), config) if config
      yield(dir)
    end
  end

  # Drive the REAL command, exactly as the shipped CLI runs it. `stderr` is a
  # caller-supplied sink so the capture SURVIVES a SystemExit raised mid-run —
  # the loud-failure path is the one this file most needs to read.
  def run_collect(dir, stderr: StringIO.new)
    out_dir     = File.join(dir, "out")
    orig_stderr = $stderr
    $stderr     = stderr
    begin
      Archbuddy::CLI::Collect.new.call(
        path: dir, out_dir: out_dir, language: "ruby",
        entrypoints: "all_public", entrypoint_pattern: []
      )
    ensure
      $stderr = orig_stderr
    end
    { stderr: stderr.string, out_dir: out_dir,
      graph: File.join(out_dir, "graph.yml") }
  end

  before { Archbuddy::Collect::Adapters::Ruby::Profile.reset_memo! }
  after  { Archbuddy::Collect::Adapters::Ruby::Profile.reset_memo! }

  # --- the measured premise the isolation argument rests on -----------------

  describe "the responsibility stayed OUT of cli/collect.rb (V-2)" do
    let(:collect_source) { File.read(File.expand_path("../../lib/archbuddy/cli/collect.rb", __dir__)) }

    it "the command still names no config filename — with a positive control" do
      # The 0-hit is only meaningful if the pattern can match at all.
      config_source = File.read(File.expand_path("../../lib/archbuddy/config.rb", __dir__))
      expect(config_source).to include(Archbuddy::Config::FILENAME)

      expect(collect_source).not_to include(Archbuddy::Config::FILENAME)
    end

    it "delegates in ONE line and holds none of the policy" do
      delegations = collect_source.lines
                                  .reject { |line| line.strip.start_with?("#", "require") }
                                  .grep(/BoundaryOverride/)
      expect(delegations.size).to eq(1)
      expect(collect_source).not_to include("MalformedOverrideError")
      expect(collect_source).not_to match(/YAML|safe_load/)
    end
  end

  # --- discovery ------------------------------------------------------------

  describe ".load" do
    it "returns nil when the root has no config file at all" do
      with_corpus { |dir| expect(described_class.load(dir)).to be_nil }
    end

    it "returns nil when the config declares no boundary key" do
      with_corpus(config: "version: 1\n") { |dir| expect(described_class.load(dir)).to be_nil }
    end

    it "returns nil for an EMPTY config document (parsed as nil, not a crash)" do
      with_corpus(config: "") { |dir| expect(described_class.load(dir)).to be_nil }
    end

    it "returns the section, deep-frozen, when one is declared" do
      with_corpus(config: declared.to_yaml) do |dir|
        section = described_class.load(dir)
        expect(section).to eq(declared["boundary"])
        expect(section).to be_frozen
        expect(section["calls"].first["receiver"]["values"]).to be_frozen
      end
    end

    it "reads the root's OWN file only — no ancestor walk (the L17 structural half)" do
      with_corpus(config: nil) do |dir|
        nested = File.join(dir, "app")
        File.write(File.join(dir, ".archbuddy.yml"), declared.to_yaml)
        expect(described_class.load(dir)).not_to be_nil
        expect(described_class.load(nested)).to be_nil
      end
    end
  end

  # --- LOUD OR NOTHING ------------------------------------------------------

  describe "a malformed override fails the run, naming the offending key" do
    def malformed(section)
      { "version" => 1, "boundary" => section }.to_yaml
    end

    it "raises naming the offending key, not a generic 'invalid config'" do
      with_corpus(config: malformed("classes" => [{ "kind" => "constant_exact",
                                                    "values" => %w[A], "role" => "action" }])) do |dir|
        expect { described_class.load(dir) }
          .to raise_error(described_class::MalformedOverrideError,
                          /boundary\.classes\[0\].*additional properties \["role"\]/m)
      end
    end

    it "names the L17 supported shape when a SEQUENCE of boundaries is declared" do
      with_corpus(config: malformed([{ "paths" => [] }, { "paths" => [] }])) do |dir|
        expect { described_class.load(dir) }
          .to raise_error(described_class::MalformedOverrideError,
                          /run archbuddy separately at each component root/)
      end
    end

    it "is loud about a YAML parse fault too" do
      with_corpus(config: "version: 1\nboundary: [\n") do |dir|
        expect { described_class.load(dir) }
          .to raise_error(described_class::MalformedOverrideError, /YAML parse error/)
      end
    end

    it "is loud about a non-mapping document root" do
      with_corpus(config: "- one\n- two\n") do |dir|
        expect { described_class.load(dir) }
          .to raise_error(described_class::MalformedOverrideError, /must be a mapping/)
      end
    end

    # THE MUTATION THAT MATTERS. "Ignore the file and carry on" would emit a
    # graph indistinguishable from a correct one, so the only observable proof
    # is that the run STOPS and writes nothing.
    it "STOPS the run — exit 1, key named on stderr, and NO graph written" do
      with_corpus(config: malformed("paths" => [{ "glob" => "x/**", "extra" => 1 }])) do |dir|
        stderr = StringIO.new
        expect { run_collect(dir, stderr: stderr) }
          .to raise_error(SystemExit) { |e| expect(e.status).to eq(1) }

        expect(stderr.string).to match(/boundary\.paths\[0\].*additional properties \["extra"\]/m)
        expect(Dir.glob(File.join(dir, "out", "*"))).to be_empty
      end
    end
  end

  # --- merge: section-level merge, list-level REPLACE ------------------------

  describe ".merge" do
    let(:shipped) do
      { "paths"   => [{ "glob" => "vendor/**" }],
        "classes" => [{ "kind" => "constant_exact", "values" => %w[Shipped] }] }
    end

    it "REPLACES a granularity the project declares (the shipped list doctrine)" do
      merged = described_class.merge(shipped, "paths" => [{ "glob" => "third_party/**" }])
      expect(merged["paths"]).to eq([{ "glob" => "third_party/**" }])
    end

    it "KEEPS a granularity the project does not mention" do
      merged = described_class.merge(shipped, "paths" => [])
      expect(merged["classes"]).to eq(shipped["classes"])
    end

    it "keeps 'no section' and 'an empty section' distinguishable" do
      expect(described_class.merge(nil, nil)).to be_nil
      expect(described_class.merge(nil, {})).to eq({})
      expect(described_class.merge({}, nil)).to eq({})
    end

    it "returns a frozen document either way" do
      expect(described_class.merge(shipped, "paths" => [])).to be_frozen
      expect(described_class.merge(nil, {})).to be_frozen
    end
  end

  # --- IT ACTUALLY REACHES R1.5 --------------------------------------------

  describe "the override reaches the collector" do
    def graph_for(config)
      with_corpus(config: config) do |dir|
        result = run_collect(dir)
        return YAML.safe_load(File.read(result[:graph]), permitted_classes: [Date], aliases: false)
      end
    end

    # The id-map's real shape: `ids` => { opaque_id => { "symbol" => real, … } }.
    def id_map_for(config)
      with_corpus(config: config) do |dir|
        result = run_collect(dir)
        return YAML.safe_load(
          File.read(File.join(result[:out_dir], "id-map.yml")), aliases: false
        ).fetch("ids")
      end
    end

    def symbols_for(config)
      id_map_for(config).values.map { |entry| entry["symbol"] }
    end

    it "NON-DEGENERACY: without an override the call is a REAL in-tree edge" do
      symbols = symbols_for(nil)
      expect(symbols).to include("Payments::Gateway#charge")
      expect(symbols.grep(/\A<external:/)).to be_empty
    end

    it "with the override, the call becomes a declared crossing with the declared category" do
      expect(symbols_for(declared.to_yaml)).to include("<external:http:Payments::Gateway>")
    end

    it "stamps the declared terminal_kind and role on the minted sink" do
      graph  = graph_for(declared.to_yaml)
      id_map = id_map_for(declared.to_yaml)
      sink_id = id_map.find { |_id, e| e["symbol"] == "<external:http:Payments::Gateway>" }&.first
      expect(sink_id).not_to be_nil
      sink    = graph.fetch("nodes").find { |n| n["id"] == sink_id }

      expect(sink["kind"]).to eq("external")
      expect(sink["terminal_kind"]).to eq("http")
      expect(sink["cco_role"]).to eq("action")
    end

    it "with NO config present the emitted graph is byte-identical to the pre-W4 behaviour" do
      # The whole opt-in gate, measured on this corpus rather than asserted.
      absent = with_corpus { |dir| File.read(run_collect(dir)[:graph]) }
      inert  = with_corpus(config: "version: 1\n") { |dir| File.read(run_collect(dir)[:graph]) }
      empty  = with_corpus(config: { "version" => 1, "boundary" => {} }.to_yaml) do |dir|
        File.read(run_collect(dir)[:graph])
      end

      expect(inert).to eq(absent)
      expect(empty).to eq(absent)
    end

    it "a declared rule that matches nothing mints nothing" do
      config = { "version" => 1,
                 "boundary" => { "paths" => [{ "glob" => "no/such/**", "category" => "gem" }] } }
      expect(symbols_for(config.to_yaml).grep(/\A<external:/)).to be_empty
    end
  end

  # --- L17's second half: the cache-collision guard -------------------------

  describe "the collect manifest records the override, so caches cannot collide" do
    def stamp_for(dir)
      JSON.parse(File.read(Archbuddy::Cache::CollectManifest.path(dir))).fetch("profile")
    end

    it "omits the key entirely when there is no override (absent stays absent)" do
      with_corpus do |dir|
        run_collect(dir)
        expect(stamp_for(dir)).not_to have_key("boundary_override")
      end
    end

    it "records a digest when there IS one, and it differs from the no-override stamp" do
      bare = with_corpus { |dir| run_collect(dir); stamp_for(dir) }
      with_corpus(config: declared.to_yaml) do |dir|
        run_collect(dir)
        expect(stamp_for(dir)).to have_key("boundary_override")
        expect(stamp_for(dir)).not_to eq(bare)
      end
    end

    # THE COLLISION, TWO-SIDED. A guard that always reads stale guards nothing.
    it "reads FRESH while the override is unchanged and STALE the moment it changes" do
      with_corpus(config: declared.to_yaml) do |dir|
        run_collect(dir)
        expect(Archbuddy::Cache::CollectManifest.fresh?(project_root: dir)).to be(true)

        rotated = declared
        rotated["boundary"]["calls"][0]["category"] = "gem"
        File.write(File.join(dir, ".archbuddy.yml"), rotated.to_yaml)

        # No source file was touched — only the vocabulary.
        expect(Archbuddy::Cache::CollectManifest.fresh?(project_root: dir)).to be(false)
      end
    end
  end
end
