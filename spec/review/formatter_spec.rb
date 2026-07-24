# frozen_string_literal: true

require "archbuddy"
require "archbuddy/review"

# v0.15 P2-T9: the review-side formatter registry — a SEPARATE class from
# the report registry (R1 §2), unknown names raise listing the registered
# set, ReviewContext carries the I-C5' members.
RSpec.describe Archbuddy::Review::Formatter do
  it "raises ArgumentError listing registered formats for unknown names" do
    expect { described_class.for("nope") }.to raise_error(ArgumentError, /terminal/)
  end

  it "resolves the terminal formatter" do
    expect(described_class.for("terminal")).to eq(Archbuddy::Review::Formatters::Terminal)
    expect(described_class.registered).to include("terminal")
  end

  it "is a separate registry from the report formatter (no cross-registration)" do
    expect(described_class::FORMATS).not_to equal(Archbuddy::Report::Formatter::FORMATS)
    expect(Archbuddy::Report::Formatter::FORMATS.values)
      .not_to include(*described_class::FORMATS.values)
    expect(described_class::FORMATS["terminal"])
      .not_to eq(Archbuddy::Report::Formatter::FORMATS["terminal"])
  end

  it "carries the v0.15 ReviewContext members (I-C5' + [S:F11] delta_index)" do
    members = described_class::ReviewContext.members
    expect(members).to include(:use_cases, :review_surface, :disclosures, :delta_index,
                               :findings, :ratchet, :calibration, :exit_code, :tool)
  end
end
