# frozen_string_literal: true

require_relative "../../lib/archbuddy/review/calibration"

# v0.15 P3-T1: Calibration — the A4 frozen exacts + source resolution.
RSpec.describe Archbuddy::Review::Calibration do
  describe "BUILTIN (A4 byte-equality)" do
    it "pins every entry" do
      expect(described_class::BUILTIN).to eq(
        "source" => "builtin-study-v1",
        "provenance" => described_class::PROVENANCE_BUILTIN,
        "latency_multiplier_per_log2_unit" => 1.11184,
        "latency_multiplier_ci95" => [1.0496, 1.1778],
        "t_quartile_cuts" => [2.0, 3.0, 5.0],
        "cost_per_line_ratio_q4_vs_q1" => 2.5485,
        "bugfix_rate_ratio_q4_vs_q1" => 3.18969,
        "latency_arm_medians_hours" => [69.8075, 21.8639]
      )
    end

    it "keeps VALUE_KEYS set-equal to the substrate list (NO new keys)" do
      expect(described_class::VALUE_KEYS.sort).to eq(
        %w[bugfix_rate_ratio_q4_vs_q1 cost_per_line_ratio_q4_vs_q1
           latency_arm_medians_hours latency_multiplier_ci95
           latency_multiplier_per_log2_unit t_quartile_cuts]
      )
      expect(described_class::SOURCES).to eq(%w[builtin-study-v1 local none])
    end

    it "ends the builtin provenance with the honesty clause" do
      expect(described_class::PROVENANCE_BUILTIN).to end_with("not measured on this repository")
    end
  end

  describe ".resolve (one example per table row)" do
    it "nil block → builtin" do
      resolved = described_class.resolve(nil)
      expect(resolved.source).to eq("builtin-study-v1")
      expect(resolved.provenance).to eq(described_class::PROVENANCE_BUILTIN)
      expect(resolved.values).to eq(described_class::BUILTIN)
    end

    it "source builtin with no value keys → same as absent" do
      resolved = described_class.resolve("source" => "builtin-study-v1")
      expect(resolved.values).to eq(described_class::BUILTIN)
    end

    it "source builtin WITH a value key → invalid" do
      expect do
        described_class.resolve("source" => "builtin-study-v1", "cost_per_line_ratio_q4_vs_q1" => 9.9)
      end.to raise_error(ArgumentError, /calibration value overrides require `source: local` with a `provenance` string/)
    end

    it "source builtin WITH a provenance key → invalid" do
      expect do
        described_class.resolve("source" => "builtin-study-v1", "provenance" => "mine")
      end.to raise_error(ArgumentError, /require `source: local`/)
    end

    it "source local + provenance + subset → local values, NEVER backfilled" do
      resolved = described_class.resolve(
        "source" => "local", "provenance" => "internal 2026-Q3 study",
        "latency_multiplier_per_log2_unit" => 1.05
      )
      expect(resolved.source).to eq("local")
      expect(resolved.provenance).to eq("internal 2026-Q3 study")
      expect(resolved.values).to eq("latency_multiplier_per_log2_unit" => 1.05)
      expect(resolved.values).not_to have_key("latency_arm_medians_hours")
    end

    it "source local without provenance → invalid naming calibration.provenance" do
      expect do
        described_class.resolve("source" => "local", "latency_multiplier_per_log2_unit" => 1.05)
      end.to raise_error(ArgumentError, /calibration\.provenance is required when source: local/)
    end

    it "source none with nothing else → all lines suppressed" do
      resolved = described_class.resolve("source" => "none")
      expect(resolved.source).to eq("none")
      expect(resolved.provenance).to be_nil
      expect(resolved.values).to eq({})
    end

    it "source none + any other key → invalid" do
      expect do
        described_class.resolve("source" => "none", "provenance" => "x")
      end.to raise_error(ArgumentError, /source 'none' allows no other keys/)
    end

    it "unknown key anywhere → invalid with did-you-mean over VALUE_KEYS" do
      expect do
        described_class.resolve("source" => "local", "provenance" => "p",
                                "latency_multiplier_per_log2_uni" => 1.0)
      end.to raise_error(ArgumentError, /did you mean 'latency_multiplier_per_log2_unit'/)
    end

    it "unknown source → invalid listing the enum" do
      expect do
        described_class.resolve("source" => "bogus")
      end.to raise_error(ArgumentError, /unknown calibration source 'bogus' \(builtin-study-v1\|local\|none\)/)
    end
  end
end
