# frozen_string_literal: true

require "archbuddy/review"
require "json"
require "json-schema"
require_relative "../support/stub_vintage"

# THE STANDING SIGNAL SET — what `lint` reports and `diff` structurally cannot.
#
# `diff` answers "what moved since the base", which is right on a PR and wrong
# for a trend: a repo that has been quietly bad for a year shows NO movement.
# This answers "what is flagged right now".
#
# The property that earns its place in `lint` is BOUNDED OUTPUT. The compute is
# one pass over nodes the vintage already holds, so cost was never the risk —
# VOLUME was. A 300-file fixture carries 1,200 flagged nodes; rendering those
# as lines would bury every other section and make lint useless on exactly the
# repos that need it. The counts line is O(1) in output at any repo size, the
# detail is capped, and the cap SAYS what it withheld.
RSpec.describe Archbuddy::Review::SignalCensus do
  include ReviewStubs

  def node_with(symbol, signals, file: "app/s.rb")
    stub_node(file: file, symbol: symbol, signals: signals)
  end

  def vintage_of(*nodes)
    instance_double(Archbuddy::Review::Vintage, nodes: nodes)
  end

  let(:flagged_onion) do
    node_with("A#run", { "fat_onion" => true, "onion_strength" => 56.0, "mixed_fan" => false })
  end
  let(:flagged_fan)   { node_with("B#run", { "fat_onion" => false, "mixed_fan" => true }) }
  let(:clean)         { node_with("C#run", { "fat_onion" => false, "mixed_fan" => false }) }
  let(:unmeasured)    { node_with("D#run", nil) }

  describe "the headline numbers" do
    subject(:census) { described_class.new(vintage_of(flagged_onion, flagged_fan, clean, unmeasured)) }

    it "counts flagged per signal, omitting signals that never fire" do
      expect(census.counts).to eq("fat_onion" => 1, "mixed_fan" => 1)
      expect(census.counts).not_to have_key("multiplexed_tree")
    end

    it "ships the DENOMINATOR with the numerator" do
      # "2 flagged" is meaningless alone; "2 of 3 measured" is the fact.
      expect(census.flagged).to eq(2)
      expect(census.measured).to eq(3)
    end

    it "publishes the unmeasured remainder rather than folding it into clean" do
      # A node whose vintage carried no signals block is UNKNOWN. Counting it
      # as healthy would flatter every repo that has not re-analyzed recently.
      expect(census.unmeasured).to eq(1)
    end

    it "reports nothing flagged as a real zero, not as absence" do
      quiet = described_class.new(vintage_of(clean))
      expect(quiet).not_to be_any
      expect(quiet.measured).to eq(1)
      expect(quiet.flagged).to eq(0)
    end
  end

  describe "bounded output — the reason this is safe on a large repo" do
    subject(:census) do
      nodes = (1..1200).map { |i| node_with("S#{i}#run", { "fat_onion" => true, "onion_strength" => i.to_f }) }
      described_class.new(vintage_of(*nodes))
    end

    it "caps the detail list no matter how many are flagged" do
      expect(census.flagged).to eq(1200)
      expect(census.top.length).to eq(described_class::TOP_N)
    end

    it "says what it withheld rather than truncating silently" do
      expect(census.omitted).to eq(1200 - described_class::TOP_N)
    end

    it "orders worst-first so the cap keeps the ones that matter" do
      expect(census.top.first.strength).to eq(1200.0)
    end

    it "is STABLE across runs — an unstable top-N shows spurious churn" do
      a = census.top.map(&:symbol)
      b = described_class.new(census.instance_variable_get(:@vintage)).top.map(&:symbol)
      expect(a).to eq(b)
    end
  end

  describe "ties to the single verdict producer" do
    it "reads the verdict list from SignalDelta, so a new signal reaches both" do
      expect(described_class::VERDICTS).to equal(Archbuddy::Review::SignalDelta::VERDICTS)
    end
  end

  describe "the lint JSON block is declared" do
    let(:schema) do
      JSON.parse(File.read("spec/fixtures/review/archbuddy-diff-report-1.schema.json"))
        .fetch("properties").fetch("signals")
    end

    it "validates a census block" do
      block = { "measured" => 3, "unmeasured" => 1, "flagged" => 2,
                "counts" => { "fat_onion" => 1 },
                "nodes" => [{ "file" => "app/s.rb", "symbol" => "A#run",
                              "signal" => "fat_onion", "strength" => 56.0 }] }
      expect(JSON::Validator.fully_validate(schema, block)).to eq([])
    end

    it "is a DIFFERENT key from diff's movement block — different questions" do
      full = JSON.parse(File.read("spec/fixtures/review/archbuddy-diff-report-1.schema.json"))
      expect(full["properties"]).to have_key("signals")
      expect(full["properties"]).to have_key("signal_movement")
      # One key carrying both shapes would force every consumer to sniff which
      # it got before reading it.
      expect(schema["properties"].keys).not_to include("movements")
    end

    it "requires the denominator, so a producer cannot publish a bare count" do
      expect(schema["required"]).to include("measured", "unmeasured", "flagged")
    end
  end
end
