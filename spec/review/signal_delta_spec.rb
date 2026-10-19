# frozen_string_literal: true

require "archbuddy/review"
require "json"
require "json-schema"
require_relative "../support/stub_vintage"

# SIGNAL MOVEMENT BETWEEN TWO VINTAGES.
#
# The score says a change got bigger; the signals say WHAT KIND of bigger.
# These examples pin the three properties that make the section readable
# rather than noisy:
#
#   NEWS ONLY    a flip is reported; a node that was already flagged and still
#                is produces NOTHING, because that is the standing state and
#                repeating it would bury the lines that are actually new.
#   TRI-STATE    nil on either side is "the test could not be run there", so it
#                yields no verdict — never a fabricated fired/cleared.
#   NEVER GATES  movement produces no finding and no exit code. The ratchet
#                gates on SCORE; this reports MOVEMENT, because the correct
#                response to a signal is a judgement call.
RSpec.describe Archbuddy::Review::SignalDelta do
  include ReviewStubs

  FILE = "app/services/handler.rb"
  SYM  = "Handler#run"

  def node(signals, branches: 1)
    stub_node(file: FILE, symbol: SYM, branches: branches, signals: signals)
  end

  # A Delta double exposing just the surface SignalDelta consumes.
  def delta_with(base_signals, head_signals, branches: [1, 2])
    entry = Archbuddy::Review::Delta::Entry.new(
      file: FILE, symbol: SYM, classification: :grown,
      base_branches: branches.first, head_branches: branches.last,
      delta_log2: 1.0,
      base_node: base_signals == :absent ? nil : node(base_signals, branches: branches.first),
      head_node: head_signals == :absent ? nil : node(head_signals, branches: branches.last),
      moved_from: nil, moved_to: nil
    )
    instance_double(Archbuddy::Review::Delta, entries: [entry])
  end

  def directions(sd) = sd.movements.map { |m| [m.signal, m.direction] }

  describe "flips are the news" do
    it "reports a signal that FIRED" do
      sd = described_class.new(delta_with(
        { "fat_onion" => false, "onion_strength" => 1.0 },
        { "fat_onion" => true,  "onion_strength" => 56.0 }
      ))
      expect(directions(sd)).to eq([["fat_onion", :fired]])
      expect(sd.movements.first.base_strength).to eq(1.0)
      expect(sd.movements.first.head_strength).to eq(56.0)
    end

    it "reports a signal that CLEARED — improvement is news too" do
      sd = described_class.new(delta_with(
        { "fat_onion" => true,  "onion_strength" => 56.0 },
        { "fat_onion" => false, "onion_strength" => 1.0 }
      ))
      expect(directions(sd)).to eq([["fat_onion", :cleared]])
    end

    it "reports every verdict independently in one pass" do
      sd = described_class.new(delta_with(
        { "fat_onion" => false, "mixed_fan" => true,  "multiplexed_tree" => false },
        { "fat_onion" => true,  "mixed_fan" => false, "multiplexed_tree" => false }
      ))
      expect(directions(sd)).to contain_exactly(["fat_onion", :fired], ["mixed_fan", :cleared])
    end
  end

  describe "the standing state is NOT news" do
    it "says nothing when a flagged node stays flagged at the same strength" do
      sd = described_class.new(delta_with(
        { "fat_onion" => true, "onion_strength" => 56.0 },
        { "fat_onion" => true, "onion_strength" => 56.0 }
      ))
      expect(sd.movements).to be_empty
      expect(sd).not_to be_any
    end

    it "ignores a strength drift below the material share" do
      sd = described_class.new(delta_with(
        { "fat_onion" => true, "onion_strength" => 100.0 },
        { "fat_onion" => true, "onion_strength" => 105.0 } # +5%
      ))
      expect(sd.movements).to be_empty
    end

    it "DOES report a strength that moved materially while still flagged" do
      sd = described_class.new(delta_with(
        { "fat_onion" => true, "onion_strength" => 100.0 },
        { "fat_onion" => true, "onion_strength" => 400.0 }
      ))
      expect(directions(sd)).to eq([["fat_onion", :strength]])
    end
  end

  describe "tri-state: an unknown side yields no verdict" do
    it "does not call it a flip when the BASE could not be measured" do
      sd = described_class.new(delta_with(
        { "fat_onion" => nil },
        { "fat_onion" => true }
      ))
      expect(sd.movements).to be_empty
    end

    it "does not call it a flip when the HEAD could not be measured" do
      sd = described_class.new(delta_with(
        { "fat_onion" => true },
        { "fat_onion" => nil }
      ))
      expect(sd.movements).to be_empty
    end

    it "is silent when a vintage carried no signals block at all" do
      # A pre-serializer-7 fragment, or a vintage that never analyzed. UNKNOWN,
      # categorically not "no signals fired".
      sd = described_class.new(delta_with(nil, { "fat_onion" => true }))
      expect(sd.movements).to be_empty
    end

    it "is silent when a node exists on only one side" do
      sd = described_class.new(delta_with(:absent, { "fat_onion" => true }))
      expect(sd.movements).to be_empty
    end
  end

  describe "the summary a reviewer reads first" do
    it "counts each direction" do
      sd = described_class.new(delta_with(
        { "fat_onion" => false, "mixed_fan" => true },
        { "fat_onion" => true,  "mixed_fan" => false }
      ))
      expect(sd.summary).to eq(fired: 1, cleared: 1)
    end
  end
  # THE SCHEMA GUARD. The diff report is additionalProperties:false at the top,
  # so a new key fails validation unless declared — and the existing round-trip
  # example never flips a signal, so its fixture would have stayed green while
  # every real run emitting a movement failed. Validate a doc that ACTUALLY
  # carries the block.
  describe "the JSON diff report declares the block" do
    let(:schema) do
      JSON.parse(File.read("spec/fixtures/review/archbuddy-diff-report-1.schema.json"))
    end

    # Validate the block against ITS OWN sub-schema, which is what the full
    # report validation reduces to for this key.
    let(:signals_schema) { schema.fetch("properties").fetch("signals") }

    it "declares `signals`, so a report carrying movement validates" do
      block = {
        "summary" => { "fired" => 1 },
        "movements" => [{ "file" => FILE, "symbol" => SYM, "signal" => "fat_onion",
                          "direction" => "fired",
                          "base_strength" => 1.0, "head_strength" => 56.0 }]
      }
      expect(JSON::Validator.fully_validate(signals_schema, block)).to eq([])
    end

    it "REJECTS an unknown direction — the vocabulary is closed" do
      bad = { "summary" => {}, "movements" => [
        { "file" => FILE, "symbol" => SYM, "signal" => "fat_onion", "direction" => "exploded" }
      ] }
      expect(JSON::Validator.fully_validate(signals_schema, bad)).not_to be_empty
    end

    it "carries NO severity or exit-code field — it cannot gate by construction" do
      props = schema.dig("properties", "signals", "properties")
      expect(props.keys).to contain_exactly("summary", "movements")
      item_props = props.dig("movements", "items", "properties").keys
      expect(item_props).not_to include("severity", "exit_code", "level")
    end
  end
end
